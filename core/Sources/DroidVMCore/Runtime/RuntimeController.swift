// SPDX-License-Identifier: GPL-2.0-or-later
//
// RuntimeController: the one façade the UI is allowed to talk to.
//
// THE OWNERSHIP MODEL
//
//   SwiftUI
//      -> RuntimeController                     <- views stop here
//         -> DroidVMCore protocols              (VMEngine, JITProvider, DisplayBackend,
//                                                GuestControl, DiagnosticsSink, ...)
//            -> platform / runtime adapters     (engine/, Apple-only)
//               -> QEMU and the iOS low level
//
// A view never constructs a command line, reaches into executable memory, touches a guest
// filesystem, controls a snapshot or manipulates renderer state. That is not a style
// preference: the reference implementation let views read boot state directly -- a
// percentage from one type, a readiness flag from another, a display kind from a third --
// and its boot overlay was consequently dismissible by a signal that meant something
// different from what the view assumed. One façade with one state makes that class of bug
// unrepresentable.
//
// THREAD SAFETY
//
// DroidVM's runtime executor only -- the main thread in the app. Stated rather than
// enforced, for the same reason as the diagnostics recorder: the alternative is a lock on
// a path reached from the frame loop.
//
// DRIVING THE STATE MACHINE
//
// Everything -- a start request, a guest signal, a display poll -- funnels into one
// `reevaluate()`, which folds the current evidence into the lifecycle and publishes the
// result. There is no second place a state can change.

import Foundation

// MARK: - Published state

/// What the UI is allowed to see. One value, one read, internally consistent.
///
/// Everything here is derived from `LifecycleState` and the current evidence at the same
/// instant, so a label can never describe a different moment than the number beside it --
/// which is exactly what happened when a progress bar was computed from milestone scores
/// while its caption came from whichever milestone matched most recently.
public struct RuntimeSnapshot: Equatable, Sendable {

    // What the user sees.
    public var state: LifecycleState
    public var progressPercent: Int
    public var label: String
    public var permitsOverlayDismissal: Bool

    // What the app reasons about.
    public var isRunning: Bool
    public var isDegraded: Bool
    public var runtimeReadiness: RuntimeReadiness
    public var guestAlive: TriState
    public var services: GuestServices
    public var displayCounters: DisplayCounters
    public var stallCause: FrameStallCause

    /// Hard reasons Android is not usable yet.
    public var blockers: [String]

    /// Things that could not be verified. Never reasons for refusal.
    public var advisories: [String]

    // Advanced mode only.
    public var machineStamp: String?
    public var technicalDetail: String

    /// A fresh snapshot, before anything has been asked for.
    public static let initial = RuntimeSnapshot(
        state: .idle,
        progressPercent: LifecyclePresentation.percent(for: .idle),
        label: LifecycleState.idle.consumerLabel,
        permitsOverlayDismissal: false,
        isRunning: false,
        isDegraded: false,
        runtimeReadiness: .unknown,
        guestAlive: .unknown,
        services: .unknown,
        displayCounters: .zero,
        stallCause: .noUpdates,
        blockers: [],
        advisories: [],
        machineStamp: nil,
        technicalDetail: "")
}

// MARK: - Policy
//
// Chosen by DroidVM, not by the user. The brief is explicit that a normal user does not
// pick a RAM size or a resolution.

public struct RuntimeProfile: Equatable, Sendable {

    public var guestRAMBytes: UInt64
    public var cpuCount: Int
    public var displaySize: DisplaySize
    public var audioEnabled: Bool
    public var networkEnabled: Bool
    public var displayMode: QEMUDisplayMode

    public init(guestRAMBytes: UInt64 = 4 << 30,
                cpuCount: Int = 4,
                displaySize: DisplaySize = DisplaySize(width: 360, height: 640),
                audioEnabled: Bool = true,
                networkEnabled: Bool = true,
                displayMode: QEMUDisplayMode = .software) {
        self.guestRAMBytes = guestRAMBytes
        self.cpuCount = cpuCount
        self.displaySize = displaySize
        self.audioEnabled = audioEnabled
        self.networkEnabled = networkEnabled
        self.displayMode = displayMode
    }

    /// The machine shape this profile produces. Used to decide snapshot compatibility
    /// before anything is downloaded or restored.
    public var machineShape: QEMUMachineShape {
        QEMUMachineShape(cpuCount: cpuCount,
                         guestRAMBytes: guestRAMBytes,
                         displayMode: displayMode,
                         displaySize: displaySize,
                         audioEnabled: audioEnabled,
                         networkEnabled: networkEnabled)
    }

    public func configuration(mayRestoreSnapshot: Bool) -> VMConfiguration {
        VMConfiguration(guestRAMBytes: guestRAMBytes,
                        cpuCount: cpuCount,
                        displaySize: displaySize,
                        audioEnabled: audioEnabled,
                        networkEnabled: networkEnabled,
                        mayRestoreSnapshot: mayRestoreSnapshot)
    }
}

// MARK: - The controller

public final class RuntimeController {

    // Collaborators.
    private let engine: VMEngine
    private let jit: JITProvider
    private let display: DisplayBackend?
    private let recorder: DiagnosticsRecorder
    private let profile: RuntimeProfile
    private let clock: () -> Date

    /// Called when the snapshot changes. One closure per listener, keyed so it can be
    /// removed. A closure list rather than Combine or an observer protocol, because this
    /// package must build on Linux and neither exists there.
    private var observers: [(id: UUID, notify: (RuntimeSnapshot) -> Void)] = []

    // The lifecycle, owned here and nowhere else.
    private let lifecycle: LifecycleEngine

    // Evidence, in one place.
    private var evidence = BootEvidence()
    private var bootCompletedAt: Date?
    private var lastMilestoneAt: Date?
    private var lastExitReason: String?

    /// What the display looked like at the last poll, so a window can be computed.
    private let displayTracker = DisplayStatsTracker()
    private var lastEmittedCause: FrameStallCause?

    public private(set) var snapshot: RuntimeSnapshot = .initial

    /// The machine shape currently in use, once prepared.
    public var machineStamp: String? { snapshot.machineStamp }

    /// Diagnostics, exposed so the app can attach file and system-log sinks and so the
    /// Advanced view can show the ring buffer.
    public var diagnostics: DiagnosticsRecorder { recorder }

    public init(engine: VMEngine,
                jit: JITProvider,
                display: DisplayBackend? = nil,
                profile: RuntimeProfile = RuntimeProfile(),
                recorder: DiagnosticsRecorder = DiagnosticsRecorder(),
                lifecycle: LifecycleEngine = LifecycleEngine(),
                clock: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.jit = jit
        self.display = display
        self.profile = profile
        self.recorder = recorder
        self.lifecycle = lifecycle
        self.clock = clock
    }

    // MARK: observers

    @discardableResult
    public func addObserver(_ notify: @escaping (RuntimeSnapshot) -> Void) -> UUID {
        let id = UUID()
        observers.append((id, notify))
        notify(snapshot)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeAll { $0.id == id }
    }

    private func publish() {
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        for observer in observers { observer.notify(snapshot) }
    }

    private var lastPublished: RuntimeSnapshot = .initial

    // MARK: lifecycle driving

    /// Fold everything currently known into the lifecycle and publish.
    ///
    /// The single funnel. Nothing else writes `snapshot.state`.
    @discardableResult
    public func reevaluate() -> LifecycleDecision {
        let now = clock()

        evidence.runtimeReadiness = runtimeReadiness()
        evidence.bootCompletedAge = bootCompletedAt.map { now.timeIntervalSince($0) }
        evidence.bootMilestoneAge = lastMilestoneAt.map { now.timeIntervalSince($0) }
        evidence.counters = displayTracker.cumulative
        evidence.displayAttached = displayTracker.currentContext.attached

        let decision = lifecycle.evaluate(evidence)

        if decision.changed {
            recorder.lifecycleChanged(from: decision.previous,
                                      to: decision.state,
                                      reason: decision.reason,
                                      evidence: ["blockers": .string(decision.blockers.joined(separator: ",")),
                                                 "advisories": .string(decision.advisories.joined(separator: ","))])
        }

        snapshot = RuntimeSnapshot(
            state: decision.state,
            progressPercent: decision.progressPercent,
            label: decision.state.consumerLabel,
            permitsOverlayDismissal: decision.state.permitsOverlayDismissal,
            isRunning: decision.state.isRunning,
            isDegraded: decision.state == .degraded,
            runtimeReadiness: evidence.runtimeReadiness,
            guestAlive: evidence.guestAlive,
            services: evidence.services,
            displayCounters: displayTracker.cumulative,
            stallCause: displayTracker.lastCause,
            blockers: decision.blockers,
            advisories: decision.advisories,
            machineStamp: evidence.vmStatus == .idle ? nil : machineStampValue,
            technicalDetail: technicalDetail())

        publish()
        return decision
    }

    private var machineStampValue: String?

    /// Read straight from the provider: `readiness` is declared on the protocol and is
    /// synchronous by design, so the UI can read it while rendering. An earlier version of
    /// this method cast to the concrete manager and kept a cached copy; both were
    /// unnecessary, and the cache was a second source of truth for a value that has one.
    private func runtimeReadiness() -> RuntimeReadiness { jit.readiness }

    private func technicalDetail() -> String {
        var parts: [String] = []
        if let stamp = machineStampValue { parts.append("machine=\(stamp)") }
        parts.append("display=\(profile.displayMode.rawValue)")
        parts.append(displayTracker.cumulative.summary)
        parts.append("stall=\(displayTracker.lastCause.rawValue)")
        if let reason = lastExitReason { parts.append("lastExit=\(reason)") }
        return parts.joined(separator: " ")
    }

    // MARK: the two operations

    /// Bring Android up, as far as the environment allows.
    ///
    /// Reports progress through the lifecycle rather than throwing, because "Android cannot
    /// start here" is a normal product outcome that has to reach the screen. The failure
    /// detail is in the snapshot and in diagnostics.
    public func start() async {
        guard !evidence.startRequested else { return }

        evidence.startRequested = true
        evidence.stopRequested = false
        reevaluate()   // -> preparing

        // 1. executable memory.
        //
        // Readiness is marked *in progress* before awaiting, so the lifecycle really does
        // pass through `checkingRuntime` instead of jumping from `preparing` to
        // `startingVM`. The user is told "Checking…" while this happens, which is the truth.
        evidence.runtimeReadiness = .preparing
        reevaluate()   // -> checkingRuntime

        let readiness = await jit.prepareRuntime()
        evidence.runtimeReadiness = readiness
        reevaluate()

        guard readiness.isReady else {
            // The lifecycle is already `failed`, with the provider's plain-language reason.
            return
        }

        // 2. the machine definition
        let configuration = profile.configuration(mayRestoreSnapshot: false)
        do {
            try await engine.prepare(configuration)
        } catch let error as VMFailureError {
            recordEngineFailure(error.failure)
        } catch {
            recordEngineFailure(VMFailure(stage: .preparation,
                                          reason: "Android could not be prepared.",
                                          technical: String(describing: error)))
        }
        await syncEngineStatus()
        machineStampValue = (engine as? VMEngineAdapter)?.shape?.stamp
        reevaluate()

        guard evidence.vmStatus.canStart else { return }

        // 3. start it
        do {
            try await engine.start()
        } catch let error as VMFailureError {
            recordEngineFailure(error.failure)
        } catch {
            recordEngineFailure(VMFailure(stage: .launch,
                                          reason: "Android could not be started.",
                                          technical: String(describing: error)))
        }
        await syncEngineStatus()
        lastMilestoneAt = clock()
        reevaluate()
    }

    /// Stop the machine and give the executable region back.
    public func stop() async {
        evidence.stopRequested = true
        reevaluate()   // -> stopping

        await engine.stop()
        await syncEngineStatus()

        await display?.detach()
        await jit.release()
        evidence.runtimeReadiness = .unknown

        reevaluate()   // -> stopped
    }

    private func syncEngineStatus() async {
        if let adapter = engine as? VMEngineAdapter {
            evidence.vmStatus = adapter.status
        } else if await engine.isRunning {
            evidence.vmStatus = .running
        }
        // Otherwise leave the status alone: a backend that is not the adapter has not told
        // us anything new, and inventing a status here would be a second source of truth.
    }

    private func recordEngineFailure(_ failure: VMFailure) {
        evidence.vmStatus = .failed(failure)
        recorder.emit(DiagnosticEventName.vmStartFailed, [
            DiagnosticField.reason: .string(failure.reason),
            DiagnosticField.stage: .string(failure.stage.rawValue),
            DiagnosticField.detail: .string(failure.technical),
        ])
    }

    // MARK: evidence ingestion

    /// Fold one observation from the guest monitor into the evidence.
    ///
    /// Non-mutating for anything the monitor cannot actually know: a signal that arrives
    /// with an unanswered probe stays `unknown`, and `unknown` never becomes a fault.
    public func ingest(_ signal: GuestSignal) {
        switch signal {
        case .vmStarted:
            evidence.vmStatus = .running
            lastMilestoneAt = clock()

        case .vmExited(let reason):
            lastExitReason = reason
            // Android reboots itself on purpose -- most importantly to repair an
            // inconsistent /data -- so an exit is only a failure if boot never completed.
            if evidence.bootCompleted {
                evidence.vmStatus = .stopped
            } else {
                evidence.vmStatus = .failed(VMFailure(
                    stage: .run,
                    reason: "Android stopped before it finished starting.",
                    technical: reason))
            }

        case .guestLiveness(let alive):
            evidence.guestAlive = TriState(alive)

        case .bootProgress(let milestone, let fraction):
            lastMilestoneAt = clock()
            var fields: [String: DiagnosticValue] = [
                DiagnosticField.stage: .string(milestone),
            ]
            if let fraction { fields["fraction"] = .double(fraction) }
            recorder.emit(DiagnosticEventName.guestBootProgress, fields)

        case .bootCompleted(let restored):
            evidence.bootCompleted = true
            evidence.restoredFromSnapshot = restored
            bootCompletedAt = clock()
            lastMilestoneAt = clock()

        case .services(let services):
            evidence.services = services

        case .displayAttached:
            evidence.displayAttached = true
            recorder.emit(DiagnosticEventName.displayAttached, [:])

        case .displayDetached(let reason):
            evidence.displayAttached = false
            recorder.emit(DiagnosticEventName.displayDetached, [
                DiagnosticField.reason: .string(reason),
            ])

        case .frameWindow(let presented, let cause):
            // Informational: the authoritative counters come from the display backend via
            // `refreshDisplay()`. This signal exists so a monitor can report a window it
            // observed without owning the counters.
            if presented > 0 {
                recorder.emit(DiagnosticEventName.framePresented, [
                    DiagnosticField.count: .int(presented > UInt64(Int.max)
                                                ? Int.max : Int(presented)),
                    DiagnosticField.cause: .string(cause.rawValue),
                ])
            }

        case .memory(let reading):
            evidence.memory = reading
            recorder.memorySample(reading)

        case .snapshotRestored:
            evidence.restoredFromSnapshot = true
        }

        reevaluate()
    }

    /// Poll the display backend and fold the result in.
    ///
    /// Separate from `ingest` because the counters are absolute readings rather than
    /// events, and because this is the one place a frame event is emitted -- from the
    /// classified window, so an empty window always carries a named cause.
    public func refreshDisplay() async {
        guard let display else { return }

        let attached = await display.attached
        let counters = await display.counters
        let context = DisplayContext(attached: attached,
                                     hasGraphicsContext: attached)

        guard counters != displayTracker.cumulative || context != displayTracker.currentContext
        else { return }

        let (window, cause) = displayTracker.update(counters: counters, context: context)

        // Emit only when something happened or the diagnosis changed: a frame event per
        // poll would bury the log in identical lines.
        if window != .zero || cause != lastEmittedCause {
            recorder.frameWindow(window, cause: cause)
            lastEmittedCause = cause
        }

        reevaluate()
    }

    // MARK: test seams

    /// Replace the evidence wholesale. For tests and for a monitor that owns more context
    /// than the individual signals carry.
    public func applyEvidence(_ mutate: (inout BootEvidence) -> Void) {
        mutate(&evidence)
        if evidence.bootCompleted, bootCompletedAt == nil { bootCompletedAt = clock() }
        reevaluate()
    }

    /// Record that a boot milestone was seen, for the stall rule.
    public func noteBootMilestone() {
        lastMilestoneAt = clock()
    }

    /// Record that boot completed, with the time it happened.
    public func noteBootCompleted(restoredFromSnapshot: Bool, at date: Date? = nil) {
        evidence.bootCompleted = true
        evidence.restoredFromSnapshot = restoredFromSnapshot
        bootCompletedAt = date ?? clock()
    }

    /// The lifecycle's own view of things, for tests and diagnostics.
    public var currentState: LifecycleState { snapshot.state }
    public var currentEvidence: BootEvidence { evidence }
}
