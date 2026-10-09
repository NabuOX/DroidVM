// SPDX-License-Identifier: GPL-2.0-or-later
//
// Level D: the engine-run coordinator.
//
// This drives the REAL start path -- `JITProvider` -> `NativeBridgeProbing` -> `VMEngine` ->
// `DisplayBackend` -- and stops at "the engine confirmed it is running". It is not a
// simulation of the path and there is no substitute branch: every collaborator here is one of
// DroidVM's own protocols, and the app hands it the same concrete adapters the product uses.
//
// THE THREE WAYS THIS COULD LIE, AND WHAT STOPS EACH
//
// 1. "The call returned, so it worked." `engine.start()` returning proves only that a function
//    returned. A backend can accept the request and die a moment later, and the reference
//    implementation's variant of this mistake is why it could report a running machine that
//    was not running. So `engineStarted` is entered only after `confirmRunning()` asks the
//    engine about ITSELF (`await engine.isRunning`) and gets `true`. The coordinator's own
//    bookkeeping is never the evidence.
//
// 2. "Enough time passed, so it worked." There is no timer in this file and no `Task.sleep`
//    in the path. Every transition is caused by a value that came back from a collaborator.
//    A machine that never confirms stays in `startingEngine` and then fails; it cannot drift
//    into `engineStarted` by waiting.
//
// 3. "Executable memory is granted, so it is ready." Readiness comes from
//    `JITProvider.prepareRuntime()` and its returned `RuntimeReadiness` -- a value produced by
//    an acquisition that performed an execute self-test. Nothing here inspects an entitlement,
//    an Info.plist key or a build flag. `unavailable` is recorded as `unavailable`, not as a
//    fault and not as a failure of the engine.

import Foundation

// MARK: - The native bridge boundary

/// What the Swift -> C bridge answered.
///
/// `detail` is for the log and the device report, never for a user.
public struct NativeBridgeStatus: Equatable, Sendable {
    public var ok: Bool
    public var detail: String

    public init(ok: Bool, detail: String) {
        self.ok = ok
        self.detail = detail
    }
}

/// Whether the Swift -> C bridge works on this device.
///
/// Behind a protocol because the implementation needs the C symbols, and DroidVMCore must
/// build and be tested on Linux and Windows where they do not exist. The engine layer provides
/// the real conformance; the host tests provide a stub.
public protocol NativeBridgeProbing: AnyObject, Sendable {
    /// Call into C and report whether the answer was the one Swift expects.
    ///
    /// Must be non-destructive: it is called before the engine is asked to start, and it must
    /// not allocate, trap or mutate engine state.
    func probe() async -> NativeBridgeStatus
}

/// The result of one display attempt, as a value.
///
/// Exists so the deadline helper can race a non-throwing closure. Declared at file scope
/// because Swift does not allow a type declaration inside a function body.
private enum DisplayStep: Sendable {
    case attached(Bool)
    case failed(String)
}

// MARK: - The coordinator

/// Drives Level D and owns its state and its report.
///
/// Thread-safety contract: DroidVM's runtime executor only, the same as `RuntimeController`
/// and for the same reason. Stated rather than enforced; the alternative is a lock on a path
/// reached from the frame loop.
public final class EngineRunCoordinator {

    private let engine: VMEngine
    private let jit: JITProvider
    private let bridge: NativeBridgeProbing
    private let confirmer: RuntimeConfirming
    private let display: DisplayBackend?
    /// The engine's own display telemetry, when the runtime can provide it. A closure rather than
    /// a protocol: there is one production source and one test stub, and a protocol for that is
    /// ceremony that has to be implemented twice.
    private let displayTelemetry: (() -> EngineRunReport.DisplayObservation)?
    /// Told whether a host surface is bound, from the display result this coordinator already
    /// decides. Not a second observer: `MetalDisplaySurface` used to report this too, which meant
    /// two detection paths for one fact and two chances to disagree.
    private let noteHostAttachment: ((Bool) -> Void)?
    /// Where the run records how far it got, so a kill inside a stage is still diagnosable.
    private let breadcrumbs: StageBreadcrumbRecording?
    private let surface: DisplaySurfaceHandle?
    private let recorder: DiagnosticsRecorder
    private let profile: RuntimeProfile

    /// Injectable so that timeout behaviour can be tested in milliseconds. The defaults are the
    /// product values; a test passing something tiny is still exercising the same code path.
    private let confirmationTimeout: TimeInterval
    private let displayTimeout: TimeInterval

    public private(set) var state: EngineRunState = .idle
    public private(set) var report = EngineRunReport()

    /// One closure per listener, keyed so it can be removed. A closure list rather than
    /// Combine, because DroidVMCore must build on Linux.
    private var observers: [(id: UUID, notify: (EngineRunState, EngineRunReport) -> Void)] = []

    public init(engine: VMEngine,
                jit: JITProvider,
                bridge: NativeBridgeProbing,
                confirmer: RuntimeConfirming,
                display: DisplayBackend? = nil,
                surface: DisplaySurfaceHandle? = nil,
                displayTelemetry: (() -> EngineRunReport.DisplayObservation)? = nil,
                noteHostAttachment: ((Bool) -> Void)? = nil,
                breadcrumbs: StageBreadcrumbRecording? = nil,
                profile: RuntimeProfile = RuntimeProfile(),
                confirmationTimeout: TimeInterval = engineConfirmationTimeout,
                displayTimeout: TimeInterval = displayAttachmentTimeout,
                recorder: DiagnosticsRecorder = DiagnosticsRecorder()) {
        self.engine = engine
        self.jit = jit
        self.bridge = bridge
        self.confirmer = confirmer
        self.confirmationTimeout = confirmationTimeout
        self.displayTimeout = displayTimeout
        self.display = display
        self.surface = surface
        self.displayTelemetry = displayTelemetry
        self.noteHostAttachment = noteHostAttachment
        self.breadcrumbs = breadcrumbs
        self.profile = profile
        self.recorder = recorder
    }

    // MARK: observers

    @discardableResult
    public func addObserver(_ notify: @escaping (EngineRunState, EngineRunReport) -> Void) -> UUID {
        let id = UUID()
        observers.append((id, notify))
        notify(state, report)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeAll { $0.id == id }
    }

    private func publish() {
        // Notify only on a real change. `transition` publishes, and `finish` publishes again to
        // carry the final report -- without this guard an observer sees the last state twice,
        // which looks like a second transition that never happened. Same rule, and the same
        // reason, as `RuntimeController.publish()`.
        if lastPublishedState == state, lastPublishedReport == report { return }
        lastPublishedState = state
        lastPublishedReport = report
        for observer in observers { observer.notify(state, report) }
    }

    private var lastPublishedState: EngineRunState?
    private var lastPublishedReport: EngineRunReport?

    private func transition(to next: EngineRunState) {
        state = next
        publish()
    }

    // MARK: the run

    /// Run Level D. Returns the report; the state is published as it goes.
    ///
    /// Never throws. "The engine did not start here" is a normal product outcome that has to
    /// reach the screen with a reason, not an error swallowed at a call site -- which is the
    /// same rule `RuntimeController.start()` follows.
    @discardableResult
    public func run() async -> EngineRunReport {

        // A run already in flight is left alone rather than restarted underneath itself.
        guard !state.isInProgress else { return report }

        report = EngineRunReport()

        // The trail is cleared first so a previous run's last stage cannot be read as this one's.
        breadcrumbs?.reset()
        breadcrumbs?.record(.appLaunch)

        // Reaching this line IS the app-launch evidence: this code runs inside the app process
        // on the device. Recorded explicitly rather than defaulted, so that a report produced
        // without running anything cannot claim it.
        report.appLaunch = .pass
        report.runtimeController = .pass

        breadcrumbs?.record(.runtimeControllerEntered)
        transition(to: .preparing)
        breadcrumbs?.record(.runtimeControllerReturned)

        // ---- 1. executable memory ------------------------------------------------------
        transition(to: .checkingJIT)
        // Around the call, not inside it: this is the boundary the first device run died on, and
        // a trail ending at `jitProbeEntered` names it without needing a crash log.
        breadcrumbs?.record(.jitProbeEntered)
        let readiness = await jit.prepareRuntime()
        breadcrumbs?.record(.jitProbeReturned)

        // RECORD THE BRING-UP STAGES ON EVERY OUTCOME, not only on success. A report that says
        // `jit: FAILED` and nothing else cannot say WHICH stage failed, and telling a rejected range
        // from a failed readback from a stub that faulted is the entire purpose of running the whole
        // pipeline in one device session.
        if let stages = jit.bringUp {
            report.providerPrepare = Self.verdict(stages.providerPrepare)
            report.providerRange = Self.verdict(stages.providerRange)
            report.rwAlias = Self.verdict(stages.rwAlias)
            report.readback = Self.verdict(stages.readback)
            report.jitSelfTest = Self.verdict(stages.jitSelfTest)
        }

        switch readiness {
        case .ready:
            report.jit = .ready

        case .unavailable(let why):
            // NOT an engine failure, and the wording says so. The environment declined; the
            // engine was never asked. There is nothing to retry from here and nothing broken.
            report.jit = .unavailable
            // `why` is the sentence a person reads; `technicalDetail` is the evidence. Both go in
            // the report, because a device run whose evidence never arrives has to be repeated.
            report.jitReason = Self.jitReason(plain: why, detail: jit.technicalDetail)
            return fail(stage: .jit,
                        reason: why,
                        technical: jit.technicalDetail.isEmpty
                            ? "runtime unavailable: \(why)" : jit.technicalDetail)

        case .failed(let why):
            report.jit = .failed
            report.jitReason = Self.jitReason(plain: why, detail: jit.technicalDetail)
            return fail(stage: .jit,
                        reason: why,
                        technical: jit.technicalDetail.isEmpty
                            ? "runtime preparation failed: \(why)" : jit.technicalDetail)

        case .unknown, .preparing:
            // We asked and did not get an answer. Reported as "did not get that far" rather
            // than as either a success or a refusal -- a probe that did not run is not a
            // negative result.
            report.jit = .notProbed
            report.jitReason = "runtime provider returned \(readiness) after prepareRuntime()"
            return fail(stage: .jit,
                        reason: "Android could not be prepared on this device.",
                        technical: report.jitReason ?? "")
        }

        // ---- 2. the Swift -> C bridge --------------------------------------------------
        breadcrumbs?.record(.nativeBridgeEntered)
        let bridgeStatus = await bridge.probe()
        breadcrumbs?.record(.nativeBridgeReturned)
        report.nativeBridge = bridgeStatus.ok ? .pass : .fail
        guard bridgeStatus.ok else {
            return fail(stage: .nativeBridge,
                        reason: "The engine could not be reached.",
                        technical: bridgeStatus.detail)
        }

        // ---- 3. the machine definition -------------------------------------------------
        transition(to: .startingEngine)
        let configuration = profile.configuration(mayRestoreSnapshot: false)
        do {
            try await engine.prepare(configuration)
            report.qemuInit = .pass
        } catch {
            report.qemuInit = .fail
            let failure = (error as? VMFailureError)?.failure
            return fail(stage: .enginePrepare,
                        reason: failure?.reason ?? "Android could not be prepared.",
                        technical: failure?.technical ?? String(describing: error))
        }

        // ---- 4. start, then CONFIRM ----------------------------------------------------
        do {
            try await engine.start()
        } catch {
            report.qemuStarted = .fail
            let failure = (error as? VMFailureError)?.failure
            return fail(stage: .engineStart,
                        reason: failure?.reason ?? "Android could not be started.",
                        technical: failure?.technical ?? String(describing: error))
        }

        // ---- 4b. CONFIRM the execution path is running --------------------------------
        //
        // The engine is asked about itself through `RuntimeConfirming`, which is the only thing
        // that may produce `engineStarted`. `engine.isRunning` is NOT used here: it is set after
        // `qemu_init` returns and before `qemu_main_loop` is entered, so it is true before
        // anything executes. See `RuntimeConfirmation`.
        switch await confirmRunning() {
        case .running:
            report.qemuStarted = .pass
            transition(to: .engineStarted)

        case .notRunning:
            report.qemuStarted = .fail
            return fail(stage: .engineConfirm,
                        reason: "Android could not be started.",
                        technical: "engine.start() returned without error, but the engine "
                                 + "reports that its execution path is not running")

        case .timedOut:
            report.qemuStarted = .fail
            return fail(stage: .engineConfirmTimeout,
                        reason: "Android did not finish starting.",
                        technical: "no confirmation from the engine within "
                                 + "\(Int(confirmationTimeout))s")

        case .unavailable(let why):
            // NOT a pass. The question could not be asked, so it was not answered, and Level D
            // requires the answer. Recorded as a blocker in its own right rather than folded
            // into a generic failure, so the missing mechanism is legible in the report.
            report.qemuStarted = .fail
            return fail(stage: .runtimeConfirmationUnavailable,
                        reason: "Android could not be started.",
                        technical: why)
        }

        // ---- 5. the display path -------------------------------------------------------
        //
        // Recorded, and deliberately NOT a gate on `result`. The brief requires the display
        // result to be observed; it does not require frames, and a display that cannot attach
        // is not an engine that failed to start. Both facts are in the report, side by side,
        // rather than one being hidden behind the other.
        await attemptDisplay()

        // EXACTLY ONE FINAL REPORT PER RUN.
        //
        // `fail(...)` already calls `finish()`, and since the display failure paths were routed
        // through it, an unconditional `finish()` here emitted a SECOND `level_d_report` for the same
        // press -- two acceptance records, and possibly two different telemetry snapshots. A run that
        // has already failed is already finished.
        if !state.isFailure {
            finish()
        }
        return report
    }

    /// Ask the engine whether its execution path is running, with a bounded wait.
    ///
    /// Separate and named, because this is the line the whole level rests on. The deadline is
    /// applied here rather than trusted to the callee, so a confirmer that ignores its own
    /// timeout cannot hang the UI: if it does not answer in time, the answer is `.timedOut`.
    private func confirmRunning() async -> RuntimeConfirmation {
        let deadline = confirmationTimeout
        let result = await withDeadline(deadline) { [confirmer] in
            await confirmer.confirmRunning(timeout: deadline)
        }
        return result ?? .timedOut
    }

    /// One attempt at the display, reduced to a value so the deadline helper can race it.
    ///
    /// The error is folded in here rather than thrown through the race: `withDeadline` has no
    /// error channel, and an error raised inside a cancelled task would be lost rather than
    /// reported.
    private func attemptDisplay() async {
        guard let display, let surface else {
            report.displayInit = .notRun
            return
        }

        let deadline = displayTimeout
        let step = await withDeadline(deadline) { [display, surface] in
            do {
                try await display.attach(surface: surface)
                return DisplayStep.attached(await display.attached)
            } catch {
                return DisplayStep.failed(String(describing: error))
            }
        }

        guard let step else {
            // No answer inside the deadline. The engine may well be running; the surface is not,
            // and Level D requires it, so this fails rather than being recorded and forgotten.
            report.displayInit = .fail
            fail(stage: .displayAttachTimeout,
                 reason: "The display did not finish starting.",
                 technical: "no attachment within \(Int(deadline))s")
            return
        }

        switch step {
        case .attached(true):
            report.displayInit = .pass
            noteHostAttachment?(true)
            transition(to: .displayReady)

        case .attached(false):
            report.displayInit = .fail
            noteHostAttachment?(false)
            fail(stage: .display,
                 reason: "The display could not be started.",
                 technical: "the display backend reported that it is not attached")

        case .failed(let detail):
            report.displayInit = .fail
            recorder.emit(DiagnosticEventName.displayAttached, [
                DiagnosticField.reason: .string(detail),
            ])
            fail(stage: .display,
                 reason: "The display could not be started.",
                 technical: detail)
        }
    }

    // MARK: failure and finish

    /// Enter `failed` with a reason, and return the report.
    ///
    /// Every failure path in `run()` comes through here, so there is exactly one place a
    /// failure state is produced and no path that can leave the UI on a spinner.
    /// The one place a bring-up stage becomes a report verdict.
    private static func verdict(_ stage: BringUpStages.Stage) -> EngineRunReport.Verdict {
        switch stage {
        case .notRun: return .notRun
        case .passed: return .pass
        case .failed: return .fail
        }
    }

    private func fail(stage: EngineRunFailure.Stage,
                      reason: String,
                      technical: String) -> EngineRunReport {
        report.failureStage = stage.rawValue
        let failure = EngineRunFailure(stage: stage, reason: reason, technical: technical)
        report.failureReason = reason
        report.technicalDetail = "\(stage.rawValue): \(technical)"
        recorder.emit(DiagnosticEventName.runtimeFailed, [
            DiagnosticField.stage: .string(stage.rawValue),
            DiagnosticField.reason: .string(reason),
            DiagnosticField.detail: .string(technical),
        ])
        transition(to: .failed(failure))
        finish()
        return report
    }

    /// The plain sentence, plus the evidence when there is any. Kept as one function so the two
    /// failure paths cannot drift apart in how they report.
    private static func jitReason(plain: String, detail: String) -> String {
        detail.isEmpty ? plain : "\(plain) | \(detail)"
    }

    /// Emit the report to the diagnostic stream.
    ///
    /// The rendered text goes into the log as one event, so the evidence survives the app
    /// being closed and does not depend on a screenshot of the screen.
    private func finish() {
        report.display = displayTelemetry?() ?? report.display

        var fields: [String: DiagnosticValue] = [
            DiagnosticField.result: .string(report.result.rawValue),
            DiagnosticField.detail: .string(report.rendered.replacingOccurrences(of: "\n", with: " | ")),
            DiagnosticField.displayState: .string(report.display.state.reportName),
            DiagnosticField.displayUpdates: .int(Int(clamping: report.display.updates)),
            DiagnosticField.displaySurfaceReplacements:
                .int(Int(clamping: report.display.surfaceReplacements)),
        ]
        // Absent, never zero, until a surface has been observed.
        if let width = report.display.width { fields[DiagnosticField.displayWidth] = .int(width) }
        if let height = report.display.height { fields[DiagnosticField.displayHeight] = .int(height) }
        if let stride = report.display.stride { fields[DiagnosticField.displayStride] = .int(stride) }
        fields[DiagnosticField.displayLastReason] =
            report.display.reason.map { DiagnosticValue.string($0) } ?? .unknown

        recorder.emit(DiagnosticEventName.levelDReport, fields)
        publish()
    }

    /// Stop the machine and give the runtime back.
    public func stop() async {
        await engine.stop()
        await display?.detach()
        await jit.release()
        report = EngineRunReport()
        transition(to: .idle)
    }

    // MARK: test seams

    /// Mark the process as having crashed. Called by the app's crash reporter, if it has one.
    public func noteCrash() {
        report.crashed = true
        publish()
    }
}
