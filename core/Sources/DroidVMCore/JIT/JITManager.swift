// SPDX-License-Identifier: GPL-2.0-or-later
//
// Obtaining executable memory, and reporting it in product terms.
//
// THE PRODUCT CONTRACT (Phase 1 brief, section 5)
//
//   prepareRuntime()
//   status
//   failure reason
//
// and the normal UI eventually cares about exactly three things:
//
//   runtime ready
//   runtime unavailable
//   runtime failed
//
// It is never told about a debugger, a pairing protocol, a helper application or a
// vendor framework. Those are how DroidVM obtains the memory; they are not what happened
// from the user's point of view. So the product-facing state is `RuntimeReadiness`, and
// the mechanism lives in `technicalDetail`, which only diagnostics read.
//
// WHY THIS IS A MANAGER AND NOT JUST A CALL
//
// Obtaining executable memory on iOS is the single most failure-prone step in the whole
// system, and it fails in ways that are indistinguishable from success unless you check:
// a region can be returned that is mapped but cannot execute, and a flag can be set before
// the check that would falsify it. So preparation is a small state machine that records
// what it tried, what came back, and why it stopped -- which is also what makes the
// failure branch worth reading in a log.

import Foundation

// MARK: - Product-facing readiness

/// What the user's app is allowed to know about runtime preparation.
public enum RuntimeReadiness: Equatable, Sendable {

    /// Not yet attempted.
    case unknown

    /// In progress. The UI shows "Checking…".
    case preparing

    /// Executable memory is held and has passed an execute self-test.
    case ready

    /// Definitively not obtainable, and will not become obtainable by retrying here.
    /// Distinguished from `failed`: nothing is broken, the environment simply does not
    /// permit it yet (typically: no debugger attached).
    case unavailable(reason: String)

    /// An attempt was made and did not work, for a reason that may not repeat.
    case failed(reason: String)

    public var isReady: Bool { self == .ready }

    /// Whether a user could plausibly do something about it. Drives whether the app
    /// offers guidance or simply reports.
    public var isActionableByUser: Bool {
        switch self {
        case .unavailable, .failed: return true
        case .unknown, .preparing, .ready: return false
        }
    }

    public var reason: String? {
        switch self {
        case .unavailable(let r), .failed(let r): return r
        case .unknown, .preparing, .ready: return nil
        }
    }
}

// MARK: - The backend boundary

/// The mechanism by which executable memory is obtained. Platform-specific.
///
/// Kept behind this protocol so that `JITManager` -- the part with the state machine, the
/// diagnostics and the failure classification -- is portable and testable, and so the
/// hard part can be replaced without touching any of the above.
///
/// Deliberately **synchronous**. The real implementation issues a trap and waits for an
/// attached debugger to service it; modelling that as `async` would invite a caller to
/// assume it is cancellable, and it is not. The Apple adapter is responsible for not
/// calling it on the main thread.
public protocol ExecutableMemoryBackend: AnyObject {

    /// Non-destructive: is executable memory obtainable? Must not allocate or trap.
    func probe() -> JITAvailability

    /// Obtain a region of at least `bytes`, mapped executable and writable through a
    /// separate alias. Throws `ExecutableMemoryError` on failure.
    func acquire(bytes: Int) throws -> ExecutableRegion

    /// Give the region back, if the platform allows it.
    func release()
}

/// A region of executable memory and its writable alias.
///
/// Two addresses because the whole technique is split-W^X: the guest's translated code
/// executes from one mapping while the translator writes through another. Conflating them
/// would misdescribe the design.
public struct ExecutableRegion: Equatable, Sendable {
    public let executableAddress: UInt
    public let writableAddress: UInt
    public let size: Int

    public init(executableAddress: UInt, writableAddress: UInt, size: Int) {
        self.executableAddress = executableAddress
        self.writableAddress = writableAddress
        self.size = size
    }
}

/// Why executable memory could not be obtained.
///
/// Typed rather than a string, so the manager can decide whether the condition is
/// "unavailable" (nothing broken, retry later) or "failed" (something went wrong).
public enum ExecutableMemoryError: Error, Equatable {

    /// The platform or the current process state does not permit it. Typically the app was
    /// launched without the entitlement, or no debugger is attached.
    case notPermitted(reason: String)

    /// The mapping or the alias could not be created.
    case allocationFailed(reason: String)

    /// A region was mapped but executing from it did not work, so it is not usable.
    /// This is the failure the reference implementation did not check for.
    case selfTestFailed(reason: String)

    /// The platform is not one this backend supports.
    case unsupportedPlatform(reason: String)

    /// Already holding a region. Releasing first is required.
    case alreadyHeld(regionBytes: Int)

    /// A reason suitable for a log. Not for a user.
    public var technicalReason: String {
        switch self {
        case .notPermitted(let r): return "not permitted: \(r)"
        case .allocationFailed(let r): return "allocation failed: \(r)"
        case .selfTestFailed(let r): return "execute self-test failed: \(r)"
        case .unsupportedPlatform(let r): return "unsupported platform: \(r)"
        case .alreadyHeld(let n): return "already holding \(n) bytes"
        }
    }

    /// Whether this is a permanent environment limitation rather than a fault.
    ///
    /// `notPermitted` and `unsupportedPlatform` mean the environment does not allow it;
    /// the others mean something was tried and did not work.
    public var isEnvironmentLimitation: Bool {
        switch self {
        case .notPermitted, .unsupportedPlatform: return true
        case .allocationFailed, .selfTestFailed, .alreadyHeld: return false
        }
    }

    /// A plain explanation. Still not shown to a user verbatim -- the lifecycle owns the
    /// user-facing wording -- but written to be sayable.
    public var plainReason: String {
        switch self {
        case .notPermitted: return "Android needs a permission this app does not have yet."
        case .allocationFailed: return "Android could not reserve the memory it needs."
        case .selfTestFailed: return "Android could not run code in the memory it reserved."
        case .unsupportedPlatform: return "This device is not supported."
        case .alreadyHeld: return "Android is already prepared."
        }
    }
}

// MARK: - The manager

/// Owns runtime preparation: the state machine, the diagnostics, and the product-facing
/// status.
///
/// Thread-safety contract: DroidVM's runtime executor only. `@unchecked Sendable` records
/// that the compiler cannot see this discipline; the alternative is a lock on a path that
/// is called from the frame loop, which this project refuses.
public final class JITManager: JITProvider, @unchecked Sendable {

    private let backend: ExecutableMemoryBackend
    private let recorder: DiagnosticsSink?
    private let requestedBytes: Int

    /// The region currently held, if any.
    public private(set) var region: ExecutableRegion?

    /// The low-level probe result, kept for diagnostics.
    public private(set) var availability: JITAvailability = .unknown

    /// The product-facing status.
    public private(set) var readiness: RuntimeReadiness = .unknown

    /// How many times preparation has been attempted in this process.
    public private(set) var attempts: Int = 0

    /// The last failure, if any. Retained so a later diagnostic can explain a state that
    /// was reached minutes ago.
    public private(set) var lastFailure: ExecutableMemoryError?

    public init(backend: ExecutableMemoryBackend,
                requestedBytes: Int = 1 << 30,
                recorder: DiagnosticsSink? = nil) {
        self.backend = backend
        self.requestedBytes = requestedBytes
        self.recorder = recorder
    }

    // MARK: preparation

    /// The whole of the product contract: get ready, or say why not.
    @discardableResult
    public func prepareRuntime() async -> RuntimeReadiness {

        // Idempotent while held: preparing twice must not leak the first region, and must
        // not report a failure for something that is already true.
        if case .ready = readiness, region != nil { return readiness }

        attempts += 1
        readiness = .preparing
        recorder?.record(DiagnosticEvent(
            name: DiagnosticEventName.runtimePrepareStarted.rawValue,
            fields: ["requested_bytes": .int(requestedBytes),
                     "attempt": .int(attempts)]))

        // Probe first, without side effects. A probe that says "no" is a clean
        // unavailable; a probe that cannot answer is not evidence either way, so we try
        // anyway rather than refusing on ignorance.
        availability = backend.probe()
        if case .unavailable(let why) = availability {
            let error = ExecutableMemoryError.notPermitted(reason: why)
            return conclude(with: error)
        }

        do {
            let acquired = try backend.acquire(bytes: requestedBytes)
            region = acquired
            availability = .available(regionBytes: acquired.size)
            readiness = .ready
            recorder?.record(DiagnosticEvent(
                name: DiagnosticEventName.runtimeReady.rawValue,
                fields: ["region_bytes": .int(acquired.size),
                         "executable": .string(hex(acquired.executableAddress)),
                         "writable": .string(hex(acquired.writableAddress))]))
            return readiness
        } catch let error as ExecutableMemoryError {
            return conclude(with: error)
        } catch {
            return conclude(with: .allocationFailed(reason: String(describing: error)))
        }
    }

    private func conclude(with error: ExecutableMemoryError) -> RuntimeReadiness {
        lastFailure = error
        availability = .unavailable(reason: error.technicalReason)

        // The distinction matters to the caller, and only this layer can make it: an
        // environment limitation is not a fault, and reporting it as one sends people
        // looking for a bug that is not there.
        readiness = error.isEnvironmentLimitation
            ? .unavailable(reason: error.plainReason)
            : .failed(reason: error.plainReason)

        recorder?.record(DiagnosticEvent(
            name: DiagnosticEventName.runtimeFailed.rawValue,
            fields: ["reason": .string(error.plainReason),
                     "technical": .string(error.technicalReason),
                     "environment_limitation": .bool(error.isEnvironmentLimitation),
                     "attempt": .int(attempts)]))
        return readiness
    }

    // MARK: teardown

    public func release() async {
        backend.release()
        region = nil
        availability = .unknown
        readiness = .unknown
        lastFailure = nil
    }

    // MARK: JITProvider

    public func probeAvailability() async -> JITAvailability {
        availability = backend.probe()
        return availability
    }

    /// Technical detail for a log line. Never the product state.
    public var technicalDetail: String {
        var parts: [String] = ["attempts=\(attempts)"]
        if let region { parts.append("region=\(region.size) bytes") }
        if let lastFailure { parts.append("last=\(lastFailure.technicalReason)") }
        return parts.joined(separator: " ")
    }

    private func hex(_ value: UInt) -> String { "0x" + String(value, radix: 16) }
}
