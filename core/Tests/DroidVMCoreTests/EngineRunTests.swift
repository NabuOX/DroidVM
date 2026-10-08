// SPDX-License-Identifier: GPL-2.0-or-later
//
// Level D: the engine-run state machine, the confirmation, and the device report.
//
// These run on the HOST and prove the LOGIC. They cannot prove a device: no test here starts
// QEMU, and none of them is evidence that anything runs on an iPhone. Level D remains a manual
// device gate -- see docs/level-d-device-test.md.
//
// What they DO prove is that the path cannot report success without a confirmed engine AND a
// confirmed display, which is the part that is easy to get wrong and impossible to notice from
// a green screen.

import XCTest
@testable import DroidVMCore

// MARK: - Doubles

private final class StubEngine: VMEngine, @unchecked Sendable {
    var prepareError: Error?
    var startError: Error?
    /// Adapter-side state. It is deliberately NOT what the coordinator consults -- a test below
    /// sets it true while the confirmer says otherwise, to prove it is not the evidence.
    var runningAfterStart = true

    private(set) var prepareCalls = 0
    private(set) var startCalls = 0
    private var running = false

    func prepare(_ configuration: VMConfiguration) async throws {
        prepareCalls += 1
        if let prepareError { throw prepareError }
    }

    func start() async throws {
        startCalls += 1
        if let startError { throw startError }
        running = runningAfterStart
    }

    func stop() async { running = false }

    var isRunning: Bool {
        get async { running }
    }
}

private final class StubJIT: JITProvider, @unchecked Sendable {
    var result: RuntimeReadiness = .ready
    private(set) var prepareCalls = 0
    private(set) var readiness: RuntimeReadiness = .unknown

    @discardableResult
    func prepareRuntime() async -> RuntimeReadiness {
        prepareCalls += 1
        readiness = result
        return result
    }

    func probeAvailability() async -> JITAvailability { .unknown }
    func release() async { readiness = .unknown }
}

/// Records the trail in memory. The file-backed one is exercised in StageBreadcrumbsTests; here
/// the question is WHICH stages a run reaches, and in what order.
private final class RecordingBreadcrumbs: StageBreadcrumbRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var trail: [LevelDStage] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        trail = []
    }

    func record(_ stage: LevelDStage) {
        lock.lock(); defer { lock.unlock() }
        trail.append(stage)
    }

    var recorded: [LevelDStage] {
        lock.lock(); defer { lock.unlock() }
        return trail
    }
}

private final class StubBridge: NativeBridgeProbing, @unchecked Sendable {
    var status = NativeBridgeStatus(ok: true, detail: "stub agrees")
    private(set) var probeCalls = 0

    func probe() async -> NativeBridgeStatus {
        probeCalls += 1
        return status
    }
}

private final class StubConfirmer: RuntimeConfirming, @unchecked Sendable {
    var answer: RuntimeConfirmation = .running
    /// When true, `confirmRunning` ignores the deadline and never returns.
    var neverAnswers = false
    private(set) var calls = 0

    func confirmRunning(timeout: TimeInterval) async -> RuntimeConfirmation {
        calls += 1
        if neverAnswers {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .timedOut
        }
        return answer
    }
}

private final class StubSurface: DisplaySurfaceHandle {}

private final class StubDisplay: DisplayBackend, @unchecked Sendable {
    var attachError: Error?
    var attachSucceeds = true
    /// When true, `attach` never returns.
    var neverAttaches = false
    private(set) var attachCalls = 0
    private var attachedFlag = false

    func attach(surface: DisplaySurfaceHandle) async throws {
        attachCalls += 1
        if neverAttaches {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return
        }
        if let attachError { throw attachError }
        attachedFlag = attachSucceeds
    }

    func detach() async { attachedFlag = false }

    var attached: Bool {
        get async { attachedFlag }
    }

    var counters: DisplayCounters {
        get async { .zero }
    }
}

private struct StubError: Error { let text: String }

// MARK: - Tests

final class EngineRunTests: XCTestCase {

    /// A coordinator whose whole path can succeed, unless a test makes one part fail.
    ///
    /// Tiny deadlines so timeout behaviour is exercised in milliseconds rather than seconds.
    private func makeCoordinator(
        engine: StubEngine = StubEngine(),
        jit: StubJIT = StubJIT(),
        bridge: StubBridge = StubBridge(),
        confirmer: StubConfirmer = StubConfirmer(),
        display: StubDisplay? = StubDisplay(),
        withSurface: Bool = true,
        telemetry: (() -> EngineRunReport.DisplayObservation)? = nil,
        breadcrumbs: StageBreadcrumbRecording? = nil,
        recorder: DiagnosticsRecorder = DiagnosticsRecorder()
    ) -> EngineRunCoordinator {
        EngineRunCoordinator(engine: engine,
                             jit: jit,
                             bridge: bridge,
                             confirmer: confirmer,
                             display: display,
                             surface: withSurface ? StubSurface() : nil,
                             displayTelemetry: telemetry,
                             breadcrumbs: breadcrumbs,
                             confirmationTimeout: 0.05,
                             displayTimeout: 0.05,
                             recorder: recorder)
    }

    /// Run a coordinator with the engine's display telemetry, and return the `level_d_report`
    /// line it emitted.
    private func runAndCapture(
        _ observation: EngineRunReport.DisplayObservation = EngineRunReport.DisplayObservation()
    ) async -> String {
        let ring = RingBufferSink(capacity: 50)
        let recorder = DiagnosticsRecorder()
        recorder.add(ring)
        _ = await makeCoordinator(telemetry: { observation }, recorder: recorder).run()
        return ring.contents.last { $0.contains("level_d_report") } ?? ""
    }

    // MARK: 6. the full path passes only when everything passes

    func testFullConfirmedRunPasses() async {
        let engine = StubEngine()
        let coordinator = makeCoordinator(engine: engine)

        let report = await coordinator.run()

        XCTAssertEqual(coordinator.state, .displayReady)
        XCTAssertTrue(coordinator.state.engineIsRunning)
        XCTAssertEqual(report.jit, .ready)
        XCTAssertEqual(report.qemuInit, .pass)
        XCTAssertEqual(report.qemuStarted, .pass)
        XCTAssertEqual(report.displayInit, .pass)
        XCTAssertEqual(report.result, .pass)
        XCTAssertEqual(engine.startCalls, 1)
    }

    func testStateVisitsEveryStageInOrder() async {
        final class Recorder: @unchecked Sendable { var seen: [EngineRunState] = [] }
        let seen = Recorder()
        let coordinator = makeCoordinator()
        coordinator.addObserver { state, _ in seen.seen.append(state) }

        _ = await coordinator.run()

        XCTAssertEqual(seen.seen,
                       [.idle, .preparing, .checkingJIT, .startingEngine,
                        .engineStarted, .displayReady])
    }

    // MARK: 1 and 2. display

    /// `display_init: FAIL` must NOT be able to produce a passing level.
    func testDisplayFailureFailsTheLevel() async {
        let display = StubDisplay()
        display.attachError = StubError(text: "no listener registered in the engine")
        let coordinator = makeCoordinator(display: display)

        let report = await coordinator.run()

        XCTAssertEqual(report.displayInit, .fail)
        XCTAssertEqual(report.result, .fail, "a failed display must fail Level D")
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure.stage, .display)
        // The engine itself did start, and that is still recorded honestly.
        XCTAssertEqual(report.qemuStarted, .pass)
    }

    func testDisplayThatDoesNotStickFailsTheLevel() async {
        let display = StubDisplay()
        display.attachSucceeds = false
        let coordinator = makeCoordinator(display: display)

        let report = await coordinator.run()

        XCTAssertEqual(report.displayInit, .fail)
        XCTAssertEqual(report.result, .fail)
        XCTAssertNotEqual(coordinator.state, .displayReady)
    }

    /// A display that never returns must time out and fail, not hang.
    func testDisplayAttachTimeoutFailsTheLevel() async {
        let display = StubDisplay()
        display.neverAttaches = true
        let coordinator = makeCoordinator(display: display)

        let report = await coordinator.run()

        XCTAssertEqual(report.displayInit, .fail)
        XCTAssertEqual(report.result, .fail)
        XCTAssertFalse(coordinator.state.isInProgress,
                       "a timed-out display must not leave the UI in progress")
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure.stage, .displayAttachTimeout)
    }

    func testNoDisplayConfiguredCannotPass() async {
        let coordinator = makeCoordinator(display: nil, withSurface: false)

        let report = await coordinator.run()

        XCTAssertEqual(report.displayInit, .notRun)
        XCTAssertEqual(report.result, .fail, "Level D requires display initialisation")
    }

    // MARK: 3, 4, 5. engine confirmation

    /// 4. `start()` succeeding while the engine is not running must fail.
    func testStartSuccessWithNotRunningFails() async {
        let engine = StubEngine()
        engine.runningAfterStart = false
        let confirmer = StubConfirmer()
        confirmer.answer = .notRunning
        let coordinator = makeCoordinator(engine: engine, confirmer: confirmer)

        let report = await coordinator.run()

        XCTAssertEqual(engine.startCalls, 1, "the engine really was asked to start")
        XCTAssertNotEqual(coordinator.state, .engineStarted)
        XCTAssertFalse(coordinator.state.engineIsRunning)
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure.stage, .engineConfirm)
        XCTAssertEqual(report.qemuStarted, .fail)
        XCTAssertEqual(report.result, .fail)
    }

    /// 5. Adapter-side acceptance alone must not promote `engineStarted`.
    ///
    /// The engine's own `isRunning` says TRUE and the report still fails, because the
    /// coordinator does not consult it. This is the test that would fail if someone
    /// "simplified" the confirmation back to `engine.isRunning`.
    func testAdapterSideIsRunningIsNotTheEvidence() async {
        let engine = StubEngine()
        engine.runningAfterStart = true          // adapter believes it is running
        let confirmer = StubConfirmer()
        confirmer.answer = .notRunning           // the engine says it is not
        let coordinator = makeCoordinator(engine: engine, confirmer: confirmer)

        let report = await coordinator.run()

        XCTAssertEqual(engine.startCalls, 1)
        XCTAssertNotEqual(coordinator.state, .engineStarted)
        XCTAssertEqual(report.qemuStarted, .fail)
        XCTAssertEqual(report.result, .fail)
        XCTAssertEqual(confirmer.calls, 1, "the confirmer is what was asked")
    }

    /// 3. A confirmation that never arrives must time out and fail.
    func testEngineConfirmationTimeoutFails() async {
        let confirmer = StubConfirmer()
        confirmer.neverAnswers = true
        let coordinator = makeCoordinator(confirmer: confirmer)

        let report = await coordinator.run()

        XCTAssertEqual(report.qemuStarted, .fail)
        XCTAssertEqual(report.result, .fail)
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure.stage, .engineConfirmTimeout)
    }

    /// There is no mechanism to ask, so the level cannot pass. This is the CURRENT state of the
    /// engine, and it is asserted deliberately so that shipping a build which cannot answer the
    /// question is a visible failure rather than a silent pass.
    func testUnavailableConfirmationCannotPass() async {
        let confirmer = StubConfirmer()
        confirmer.answer = .unavailable(reason: "the engine publishes no execution-state marker")
        let coordinator = makeCoordinator(confirmer: confirmer)

        let report = await coordinator.run()

        XCTAssertEqual(report.qemuStarted, .fail)
        XCTAssertEqual(report.result, .fail)
        XCTAssertTrue(report.technicalDetail?.contains("no execution-state marker") ?? false)
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure.stage, .runtimeConfirmationUnavailable)
    }

    // MARK: the PASS predicate

    /// Each criterion is individually required, and none may be relaxed.
    func testEveryCriterionIsRequiredForPass() {
        func passing() -> EngineRunReport {
            var r = EngineRunReport()
            r.appLaunch = .pass
            r.runtimeController = .pass
            r.jit = .ready
            r.nativeBridge = .pass
            r.qemuInit = .pass
            r.qemuStarted = .pass
            r.displayInit = .pass
            return r
        }

        XCTAssertEqual(passing().result, .pass)

        // Each one, on its own, is enough to fail the level.
        var r = passing(); r.appLaunch = .fail;        XCTAssertEqual(r.result, .fail, "app_launch")
        r = passing(); r.runtimeController = .fail;    XCTAssertEqual(r.result, .fail, "runtime_controller")
        r = passing(); r.jit = .unavailable;           XCTAssertEqual(r.result, .fail, "jit unavailable")
        r = passing(); r.jit = .failed;                XCTAssertEqual(r.result, .fail, "jit failed")
        r = passing(); r.jit = .notProbed;             XCTAssertEqual(r.result, .fail, "jit not probed")
        r = passing(); r.nativeBridge = .fail;         XCTAssertEqual(r.result, .fail, "native_bridge")
        r = passing(); r.qemuInit = .fail;             XCTAssertEqual(r.result, .fail, "qemu_init")
        r = passing(); r.qemuStarted = .fail;          XCTAssertEqual(r.result, .fail, "qemu_started")
        r = passing(); r.displayInit = .fail;          XCTAssertEqual(r.result, .fail, "display_init fail")
        r = passing(); r.displayInit = .notRun;        XCTAssertEqual(r.result, .fail, "display_init not run")
        r = passing(); r.crashed = true;               XCTAssertEqual(r.result, .fail, "crash")
    }

    // MARK: JIT

    func testJITUnavailableIsRecordedAndStopsTheRun() async {
        let jit = StubJIT()
        jit.result = .unavailable(reason: "Android needs a permission this app does not have yet.")
        let engine = StubEngine()
        let coordinator = makeCoordinator(engine: engine, jit: jit)

        let report = await coordinator.run()

        XCTAssertEqual(report.jit, .unavailable)
        XCTAssertEqual(report.jitReason, "Android needs a permission this app does not have yet.")
        XCTAssertEqual(engine.startCalls, 0, "the engine was never asked")
        XCTAssertEqual(report.result, .fail)
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(failure.stage, .jit)
    }

    func testJITFailedIsDistinctFromUnavailable() async {
        let jit = StubJIT()
        jit.result = .failed(reason: "Android could not reserve the memory it needs.")
        let report = await makeCoordinator(jit: jit).run()

        XCTAssertEqual(report.jit, .failed)
        XCTAssertNotEqual(report.jit, .unavailable)
        XCTAssertEqual(report.result, .fail)
    }

    func testJITThatDidNotAnswerIsNotProbed() async {
        let jit = StubJIT()
        jit.result = .unknown
        let report = await makeCoordinator(jit: jit).run()

        XCTAssertEqual(report.jit, .notProbed)
        XCTAssertEqual(report.result, .fail)
    }

    // MARK: bridge

    func testBridgeFailureStopsBeforeTheEngineIsAsked() async {
        let bridge = StubBridge()
        bridge.status = NativeBridgeStatus(ok: false, detail: "counter layout mismatch")
        let engine = StubEngine()
        let coordinator = makeCoordinator(engine: engine, bridge: bridge)

        let report = await coordinator.run()

        XCTAssertEqual(report.nativeBridge, .fail)
        XCTAssertEqual(engine.prepareCalls, 0)
        XCTAssertEqual(report.result, .fail)
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(failure.stage, .nativeBridge)
    }

    // MARK: engine failures

    func testEnginePrepareFailurePropagatesItsStage() async {
        let engine = StubEngine()
        engine.prepareError = VMFailureError(
            VMFailure(stage: .preparation, reason: "Android could not be prepared.",
                      technical: "no firmware"))
        let report = await makeCoordinator(engine: engine).run()

        XCTAssertEqual(report.qemuInit, .fail)
        XCTAssertEqual(engine.startCalls, 0)
        XCTAssertEqual(report.failureReason, "Android could not be prepared.")
        XCTAssertEqual(report.result, .fail)
    }

    func testEngineStartFailurePropagatesItsStage() async {
        let engine = StubEngine()
        engine.startError = VMFailureError(
            VMFailure(stage: .launch, reason: "Android could not be started.",
                      technical: "dylib missing"))
        let coordinator = makeCoordinator(engine: engine)

        let report = await coordinator.run()

        XCTAssertEqual(report.qemuInit, .pass, "prepare succeeded and is recorded as such")
        XCTAssertEqual(report.qemuStarted, .fail)
        XCTAssertEqual(report.result, .fail)
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(failure.stage, .engineStart)
    }

    // MARK: 8. the UI never hangs

    /// Whatever fails, the UI must leave the in-progress state.
    func testEveryFailureLeavesTheUiOutOfProgress() async {
        // jit unavailable
        let j1 = StubJIT(); j1.result = .unavailable(reason: "x")
        // bridge fault
        let b1 = StubBridge(); b1.status = NativeBridgeStatus(ok: false, detail: "y")
        // engine not running
        let c1 = StubConfirmer(); c1.answer = .notRunning
        // confirmation never answers
        let c2 = StubConfirmer(); c2.neverAnswers = true
        // display never attaches
        let d1 = StubDisplay(); d1.neverAttaches = true
        // display throws
        let d2 = StubDisplay(); d2.attachError = StubError(text: "z")

        let coordinators = [
            makeCoordinator(jit: j1),
            makeCoordinator(bridge: b1),
            makeCoordinator(confirmer: c1),
            makeCoordinator(confirmer: c2),
            makeCoordinator(display: d1),
            makeCoordinator(display: d2),
        ]

        for (index, coordinator) in coordinators.enumerated() {
            let report = await coordinator.run()
            XCTAssertFalse(coordinator.state.isInProgress,
                           "case \(index) left the UI in progress")
            XCTAssertTrue(coordinator.state.isTerminal || coordinator.state == .failed(
                EngineRunFailure(stage: .jit, reason: "", technical: "")),
                          "case \(index) did not reach a settled state")
            XCTAssertEqual(report.result, .fail, "case \(index) unexpectedly passed")
        }
    }

    // MARK: 7. no Android-ready state

    func testNoAndroidClaimIsMade() async {
        let report = await makeCoordinator().run()

        let text = report.rendered.lowercased()
        for forbidden in ["android", "boot", "launcher", "systemui", "system_ui",
                          "frame", "ready_to_use"] {
            XCTAssertFalse(text.contains(forbidden),
                           "the Level D report must not mention '\(forbidden)'")
        }
    }

    func testNoStateIsMistakableForAndroidReady() {
        let states: [EngineRunState] = [
            .idle, .preparing, .checkingJIT, .startingEngine, .engineStarted, .displayReady,
            .failed(EngineRunFailure(stage: .jit, reason: "x", technical: "y")),
        ]
        for state in states {
            XCTAssertFalse(state.diagnosticLabel.lowercased().contains("android"))
        }
        XCTAssertTrue(EngineRunState.engineStarted.engineIsRunning)
    }

    // MARK: report shape

    func testReportRendersTheAgreedShape() async {
        let report = await makeCoordinator().run()
        let lines = report.rendered.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.first, "LEVEL D DEVICE REPORT")
        XCTAssertEqual(Array(lines.dropFirst().map { String($0.split(separator: ":")[0]) }),
                       // The display observation sits with the verdict it qualifies. These
                       // keys are part of the report format, so adding one is deliberate.
                       ["app_launch", "runtime_controller", "jit", "jit_reason",
                        "native_bridge", "qemu_init", "qemu_started", "display_init",
                        "display_state", "display_width", "display_height", "display_stride",
                        "display_updates", "display_surface_replacements", "display_last_reason",
                        "crash", "failure_reason", "result"])
        XCTAssertTrue(report.rendered.hasSuffix("result: PASS"))
    }

    func testReportRenderingIsDeterministic() {
        var report = EngineRunReport()
        report.appLaunch = .pass
        report.qemuStarted = .pass
        XCTAssertEqual(report.rendered, report.rendered)
    }

    // MARK: vocabulary

    func testConsumerLabelsCarryNoMechanism() {
        let states: [EngineRunState] = [
            .idle, .preparing, .checkingJIT, .startingEngine, .engineStarted, .displayReady,
            .failed(EngineRunFailure(stage: .jit, reason: "x", technical: "y")),
        ]
        let forbidden = ["jit", "qemu", "metal", "renderer", "virtio", "bridge",
                         "vulkan", "emulat", "vm ", "debug"]
        for state in states {
            let label = state.consumerLabel.lowercased()
            for word in forbidden {
                XCTAssertFalse(label.contains(word),
                               "'\(label)' for \(state) exposes '\(word)' to a user")
            }
        }
    }

    func testDiagnosticLabelsNameTheStage() {
        XCTAssertEqual(EngineRunState.checkingJIT.diagnosticLabel, "checkingJIT")
        XCTAssertEqual(
            EngineRunState.failed(EngineRunFailure(stage: .nativeBridge,
                                                   reason: "x", technical: "y")).diagnosticLabel,
            "failed(native_bridge)")
    }

    // MARK: lifecycle and diagnostics

    func testStopReturnsToIdleAndClearsTheReport() async {
        let coordinator = makeCoordinator()
        _ = await coordinator.run()
        await coordinator.stop()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.report.qemuStarted, .notRun)
    }

    func testCrashMakesTheReportFail() async {
        let coordinator = makeCoordinator()
        _ = await coordinator.run()
        coordinator.noteCrash()

        XCTAssertTrue(coordinator.report.crashed)
        XCTAssertEqual(coordinator.report.result, .fail)
        XCTAssertTrue(coordinator.report.rendered.contains("crash: YES"))
    }

    func testTheReportIsEmittedToTheDiagnosticStream() async {
        let ring = RingBufferSink(capacity: 50)
        let recorder = DiagnosticsRecorder()
        recorder.add(ring)

        let coordinator = EngineRunCoordinator(engine: StubEngine(),
                                               jit: StubJIT(),
                                               bridge: StubBridge(),
                                               confirmer: StubConfirmer(),
                                               display: StubDisplay(),
                                               surface: StubSurface(),
                                               recorder: recorder)
        _ = await coordinator.run()

        let joined = ring.contents.joined()
        XCTAssertTrue(joined.contains("level_d_report"),
                      "the device report must be in the log, not only on the screen")
        XCTAssertTrue(joined.contains("LEVEL D DEVICE REPORT"))
    }

    /// The deadline helper returns `nil` on expiry and the operation's own value otherwise. It
    /// never invents a value, which is the difference between a deadline and a timer.
    func testDeadlineReturnsTheOperationsValueOrNil() async {
        let quick = await withDeadline(5.0) { 42 }
        XCTAssertEqual(quick, 42)

        let slow = await withDeadline(0.05) { () -> Int in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return 7
        }
        XCTAssertNil(slow, "an operation that outlives its deadline yields no value")
    }

    // MARK: display telemetry in the diagnostics export

    /// The display state reaches the structured export, so a device log says which stage ran.
    func testDiagnosticsCarryTheDisplayState() async {
        var observation = EngineRunReport.DisplayObservation()
        observation.state = .listenerRegistered
        observation.reason = "display listener registered against console 0"

        let line = await runAndCapture(observation)

        XCTAssertTrue(line.contains("\"display_state\":\"LISTENER REGISTERED\""), line)
        XCTAssertTrue(line.contains("\"display_last_reason\":\"display listener registered"), line)
    }

    /// THE rule of this level: geometry is ABSENT until a surface exists, never zero. A zero would
    /// be indistinguishable from a guest that is drawing nothing.
    func testGeometryIsAbsentUntilASurfaceIsObserved() async {
        var observation = EngineRunReport.DisplayObservation()
        observation.state = .listenerRegistered

        let line = await runAndCapture(observation)

        XCTAssertFalse(line.contains("\"display_width\""), "a width was invented: \(line)")
        XCTAssertFalse(line.contains("\"display_height\""), "a height was invented")
        XCTAssertFalse(line.contains("\"display_stride\""), "a stride was invented")
        XCTAssertTrue(line.contains("\"display_last_reason\":null"),
                      "an unknown reason must be null, not an empty string: \(line)")
    }

    /// And when a surface IS observed, the geometry is the surface's.
    func testObservedGeometryIsReported() async {
        var observation = EngineRunReport.DisplayObservation()
        observation.state = .attached
        observation.width = 1280
        observation.height = 720
        observation.stride = 5120
        observation.updates = 3
        observation.surfaceReplacements = 1

        let line = await runAndCapture(observation)

        XCTAssertTrue(line.contains("\"display_width\":1280"), line)
        XCTAssertTrue(line.contains("\"display_height\":720"), line)
        XCTAssertTrue(line.contains("\"display_stride\":5120"), line)
        XCTAssertTrue(line.contains("\"display_updates\":3"), line)
        XCTAssertTrue(line.contains("\"display_surface_replacements\":1"), line)
    }




    /// Unobserved geometry renders as `-`, in the report's existing style, rather than as 0.
    func testUnobservedGeometryRendersAsAbsent() {
        let lines = EngineRunReport.DisplayObservation().renderedLines
        XCTAssertTrue(lines.contains("display_width: -"), "\(lines)")
        XCTAssertTrue(lines.contains("display_height: -"))
        XCTAssertTrue(lines.contains("display_stride: -"))
        XCTAssertTrue(lines.contains("display_last_reason: -"))
        XCTAssertTrue(lines.contains("display_updates: 0"))
    }


    // MARK: no JIT environment stops the run, and the trail says where

    /// THE DEVICE FAILURE, as a test. With no JIT-enabling environment the run must stop at the JIT
    /// stage and never reach the engine -- and, before this fix, "reaching the engine" was not the
    /// risk: the process died inside the probe itself, executing a trap nothing would service.
    ///
    /// The stub stands in for the probe's ANSWER. What is proven here is the coordinator's
    /// behaviour given that answer: nothing downstream is attempted, and the level cannot pass.
    func testJITUnavailableStopsBeforeTheEngineIsAsked() async {
        let jit = StubJIT()
        jit.result = .unavailable(reason: "no JIT-enabling environment is attached")

        let engine = StubEngine()
        let bridge = StubBridge()
        let coordinator = makeCoordinator(engine: engine, jit: jit, bridge: bridge)

        let report = await coordinator.run()

        XCTAssertEqual(report.jit, .unavailable)
        XCTAssertEqual(report.jitReason, "no JIT-enabling environment is attached")
        XCTAssertEqual(report.nativeBridge, .notRun)
        XCTAssertEqual(report.qemuInit, .notRun)
        XCTAssertEqual(report.qemuStarted, .notRun)
        XCTAssertEqual(report.displayInit, .notRun)
        XCTAssertEqual(report.result, .fail, "an unavailable JIT produced a passing level")

        XCTAssertEqual(engine.prepareCalls, 0, "the engine was asked to prepare")
        XCTAssertEqual(engine.startCalls, 0, "the engine was asked to start")
        XCTAssertEqual(bridge.probeCalls, 0, "the bridge was probed")
    }

    /// An unavailable JIT is not a failure of the engine, and the report must say so rather than
    /// blaming QEMU for something QEMU was never asked to do.
    func testJITUnavailableIsNotReportedAsAnEngineFailure() async {
        let jit = StubJIT()
        jit.result = .unavailable(reason: "nothing is attached to service the trap")
        let report = await makeCoordinator(jit: jit).run()

        XCTAssertEqual(report.jit, .unavailable)
        XCTAssertEqual(report.failureReason, "nothing is attached to service the trap",
                       "the reason must be the environment's, not a generic engine message")
    }

    /// The trail brackets the probe, so a process killed inside it is attributable without a crash
    /// log: the trail ends at `jitProbeEntered` and a reader knows exactly which stage died.
    func testTheTrailBracketsTheJITProbe() async {
        let breadcrumbs = RecordingBreadcrumbs()
        let jit = StubJIT()
        jit.result = .unavailable(reason: "no JIT-enabling environment is attached")

        _ = await makeCoordinator(jit: jit, breadcrumbs: breadcrumbs).run()
        let trail = breadcrumbs.recorded

        XCTAssertEqual(trail.prefix(5), [.appLaunch, .runtimeControllerEntered,
                                         .runtimeControllerReturned,
                                         .jitProbeEntered, .jitProbeReturned])
        XCTAssertFalse(trail.contains(.nativeBridgeEntered),
                       "the run advanced past the JIT stage it could not satisfy")
    }

    /// The trail is cleared before a run, so the previous run's last stage cannot be read as this
    /// run's progress.
    func testTheTrailIsResetAtTheStartOfARun() async {
        let breadcrumbs = RecordingBreadcrumbs()
        breadcrumbs.record(.qemuInitReturned)

        _ = await makeCoordinator(breadcrumbs: breadcrumbs).run()

        XCTAssertEqual(breadcrumbs.recorded.first, .appLaunch)
        XCTAssertEqual(breadcrumbs.recorded.filter { $0 == .qemuInitReturned }.count,
                       0, "a stage from a previous run survived into this one")
    }
}
