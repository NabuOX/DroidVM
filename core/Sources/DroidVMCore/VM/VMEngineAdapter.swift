// SPDX-License-Identifier: GPL-2.0-or-later
//
// The VM engine adapter: DroidVM's `VMEngine` over a narrow runtime backend.
//
// WHAT THE REST OF THE APPLICATION IS NOT ALLOWED TO KNOW
//
// The Phase 1 brief is explicit: everything above this file must not know about the QEMU
// command-line layout, environment variables, QEMU symbols, guest image internals or
// low-level file-descriptor setup. All of that is here or below, and the boundary is a
// single method that hands a prepared plan to a backend.
//
// The split is deliberate. `VMEngineAdapter` -- status machine, failure classification,
// diagnostics, plan construction -- is portable and tested on the host. `VMRuntimeBackend`
// is the only thing that needs an Apple device, and it is small enough to read in one
// sitting: load a library, hand it arguments, run its main loop on a thread, stop it.

import Foundation

// MARK: - Status

/// Where the machine is.
public enum VMStatus: Equatable, Sendable {
    case idle
    case preparing
    case prepared
    case starting
    case running
    case stopping
    case stopped
    case failed(VMFailure)

    public var isRunning: Bool { self == .running }

    /// Whether the machine can be started from here.
    public var canStart: Bool { self == .prepared || self == .stopped }

    public var failure: VMFailure? {
        if case .failed(let f) = self { return f }
        return nil
    }
}

/// A machine failure, with enough context to be actionable.
///
/// The *stage* is the part that matters. "QEMU exited with status 1" is not a diagnosis;
/// "the engine failed to launch because it could not load the library" is.
public struct VMFailure: Equatable, Sendable {

    public enum Stage: String, Equatable, Sendable, CaseIterable {
        /// Building or validating the machine definition.
        case preparation
        /// Handing the machine to the engine and starting it.
        case launch
        /// Something went wrong after it was running.
        case run
        /// Stopping it.
        case stop
    }

    public var stage: Stage

    /// For the user-facing lifecycle. Plain, and never a raw engine string.
    public var reason: String

    /// For the log. May contain engine detail.
    public var technical: String

    public init(stage: Stage, reason: String, technical: String) {
        self.stage = stage
        self.reason = reason
        self.technical = technical
    }
}

// MARK: - The backend boundary

/// The only part of the engine that requires the platform.
///
/// Implementations load the engine, translate a plan into its expected argv, run its main
/// loop, and report what happened. Nothing above this protocol knows how.
///
/// Deliberately synchronous: these wrap a C API that must run on its own thread, and
/// modelling them as `async` would suggest a cancellability that does not exist. The
/// adapter's caller is responsible for not invoking it on the main thread.
public protocol VMRuntimeBackend: AnyObject {

    /// Validate and stage the machine. Must not begin executing the guest.
    func prepare(plan: QEMULaunchPlan) throws

    /// Begin executing. Returns once running, not once Android is usable.
    func start() throws

    /// Ask the machine to stop and return when it has.
    func stop()

    var isRunning: Bool { get }
}

// MARK: - The adapter

/// DroidVM's VM engine.
///
/// Thread-safety contract: DroidVM's runtime executor only. `@unchecked Sendable` records
/// a discipline the compiler cannot see; the alternative is locking a path that is called
/// from the frame loop.
public final class VMEngineAdapter: VMEngine, @unchecked Sendable {

    private let backend: VMRuntimeBackend
    private let recorder: DiagnosticsSink?

    // Machine definition inputs that do not come from `VMConfiguration`.
    private let paths: QEMULaunchPaths
    private let displayMode: QEMUDisplayMode
    private let guestShellPort: Int
    private let adbPort: Int
    private let snapshotNodeName: String
    private let restoresSnapshot: Bool

    public private(set) var status: VMStatus = .idle

    /// The last plan handed to the backend. Kept so diagnostics can explain a machine that
    /// is already running, and so a failure can be reported against the exact definition
    /// that produced it.
    public private(set) var plan: QEMULaunchPlan?

    /// The shape this machine was built with. Snapshot compatibility is decided against it.
    public private(set) var shape: QEMUMachineShape?

    /// The configuration last handed to `prepare`.
    public private(set) var configuration: VMConfiguration?

    public init(backend: VMRuntimeBackend,
                paths: QEMULaunchPaths,
                displayMode: QEMUDisplayMode = .software,
                guestShellPort: Int = 5599,
                adbPort: Int = 5555,
                snapshotNodeName: String = "droidvmvmstate",
                restoresSnapshot: Bool = false,
                recorder: DiagnosticsSink? = nil) {
        self.backend = backend
        self.paths = paths
        self.displayMode = displayMode
        self.guestShellPort = guestShellPort
        self.adbPort = adbPort
        self.snapshotNodeName = snapshotNodeName
        self.restoresSnapshot = restoresSnapshot
        self.recorder = recorder
    }

    // MARK: VMEngine

    public func prepare(_ configuration: VMConfiguration) async throws {
        guard !backend.isRunning else {
            // Preparing a running machine would build a second definition and discard the
            // first. Report rather than silently do nothing, because a caller that expects
            // a fresh machine and gets the old one has a bug that is invisible otherwise.
            let failure = VMFailure(stage: .preparation,
                                    reason: "Android is already running.",
                                    technical: "prepare() called while backend.isRunning")
            status = .failed(failure)
            report(failure)
            throw VMFailureError(failure)
        }

        status = .preparing
        self.configuration = configuration

        let shape = QEMUMachineShape(
            cpuModel: QEMUMachineShape.defaultCPUModel,
            cpuCount: configuration.cpuCount,
            guestRAMBytes: configuration.guestRAMBytes,
            displayMode: displayMode,
            displaySize: configuration.displaySize,
            audioEnabled: configuration.audioEnabled,
            networkEnabled: configuration.networkEnabled)
        self.shape = shape

        let request = QEMULaunchRequest(shape: shape,
                                        paths: paths,
                                        snapshotNodeName: snapshotNodeName,
                                        guestShellPort: guestShellPort,
                                        adbPort: adbPort,
                                        restoresSnapshot: restoresSnapshot
                                            && configuration.mayRestoreSnapshot)
        let plan = QEMULaunchPlanBuilder.make(request)
        self.plan = plan

        do {
            try backend.prepare(plan: plan)
        } catch {
            let failure = VMFailure(stage: .preparation,
                                    reason: "Android could not be prepared.",
                                    technical: describe(error))
            status = .failed(failure)
            report(failure)
            throw VMFailureError(failure)
        }

        status = .prepared
    }

    public func start() async throws {
        recorder?.record(DiagnosticEvent(
            name: DiagnosticEventName.vmStartRequested.rawValue,
            fields: ["machine": .string(shape?.stamp ?? "unknown"),
                     "display": .string(displayMode.rawValue),
                     "restore": .bool(restoresSnapshot)]))

        guard status.canStart else {
            let failure = VMFailure(
                stage: .launch,
                reason: "Android could not be started.",
                technical: "start() from status \(status)")
            status = .failed(failure)
            recorder?.record(DiagnosticEvent(
                name: DiagnosticEventName.vmStartFailed.rawValue,
                fields: ["reason": .string(failure.reason),
                         "technical": .string(failure.technical),
                         "stage": .string(failure.stage.rawValue)]))
            throw VMFailureError(failure)
        }

        status = .starting
        do {
            try backend.start()
        } catch {
            let failure = VMFailure(stage: .launch,
                                    reason: "Android could not be started.",
                                    technical: describe(error))
            status = .failed(failure)
            report(failure)
            throw VMFailureError(failure)
        }

        status = .running
        var fields: [String: DiagnosticValue] = [
            "machine": .string(shape?.stamp ?? "unknown"),
        ]
        if let plan {
            // The full argument line, once per start. It is the machine definition, and
            // a log that does not contain it cannot explain the machine it came from.
            fields["arguments"] = .string(plan.argumentLine())
            fields["notes"] = .string(plan.notes.joined(separator: " | "))
        }
        recorder?.record(DiagnosticEvent(
            name: DiagnosticEventName.vmStarted.rawValue, fields: fields))
    }

    public func stop() async {
        guard status.isRunning || status == .starting || status == .prepared else {
            status = .stopped
            return
        }
        status = .stopping
        backend.stop()

        // A machine that stopped on its own before we asked is still stopped, and saying
        // so is not an error.
        status = .stopped
        recorder?.record(DiagnosticEvent(
            name: DiagnosticEventName.vmStopped.rawValue,
            fields: ["machine": .string(shape?.stamp ?? "unknown")]))
    }

    public var isRunning: Bool { backend.isRunning }

    // MARK: notifications

    /// Called by the platform adapter when the machine exits without being asked to.
    ///
    /// A guest that reboots is not a failure -- Android reboots itself deliberately, most
    /// importantly to repair an inconsistent `/data`. Only an exit that happens while we
    /// still believe we are running is worth reporting, and even then it is a `run`-stage
    /// failure rather than a launch one, because the diagnosis is different.
    public func noteUnexpectedExit(technical: String) {
        guard status.isRunning || status == .starting else { return }
        let failure = VMFailure(stage: .run,
                                reason: "Android stopped unexpectedly.",
                                technical: technical)
        status = .failed(failure)
        report(failure)
    }

    private func report(_ failure: VMFailure) {
        recorder?.record(DiagnosticEvent(
            name: failure.stage == .preparation
                ? DiagnosticEventName.runtimeFailed.rawValue
                : DiagnosticEventName.vmStartFailed.rawValue,
            fields: ["reason": .string(failure.reason),
                     "technical": .string(failure.technical),
                     "stage": .string(failure.stage.rawValue)]))
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? VMFailureError { return e.failure.technical }
        return String(describing: error)
    }
}

/// Carries a `VMFailure` out through a `throws` signature, so the protocol stays simple
/// while the failure detail is not lost. `VMEngine` still throws for genuinely exceptional
/// conditions; the difference here is that the failure is also recorded in `status`, so a
/// caller that ignores the throw still cannot miss it.
public struct VMFailureError: Error, Equatable {
    public let failure: VMFailure
    public init(_ failure: VMFailure) { self.failure = failure }
    public var localizedDescription: String { failure.reason }
}
