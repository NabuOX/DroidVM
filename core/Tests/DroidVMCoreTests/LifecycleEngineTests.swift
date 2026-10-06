// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The lifecycle state machine.
///
/// The cases here are the ones that cost real debugging time when they were wrong, so they
/// are asserted one at a time rather than in aggregate. The most important is `caseB`:
/// a machine that reports boot complete the instant it restores, with nothing drawn.
final class LifecycleEngineTests: XCTestCase {

    private func engine() -> LifecycleEngine {
        LifecycleEngine(memoryFloorBytes: 350 << 20,
                        graphicsStallSeconds: 20,
                        bootStallSeconds: 90)
    }

    // MARK: - the ladder

    func testColdBootWalksTheLadderInOrder() {
        let e = engine()

        XCTAssertEqual(e.evaluate(.idle).state, .idle)

        var ev = BootEvidence()
        ev.startRequested = true
        XCTAssertEqual(e.evaluate(ev).state, .preparing)

        // Actively obtaining executable memory is its own state, and the user is told
        // something different about it.
        ev.runtimeReadiness = .preparing
        XCTAssertEqual(e.evaluate(ev).state, .checkingRuntime)

        ev.runtimeReadiness = .ready
        XCTAssertEqual(e.evaluate(ev).state, .startingVM)

        ev.vmStatus = .prepared
        XCTAssertEqual(e.evaluate(ev).state, .startingVM)

        ev.vmStatus = .running
        XCTAssertEqual(e.evaluate(ev).state, .bootingAndroid)

        // Services beginning to answer is real progress before boot completes.
        ev.services.systemServer = .yes
        XCTAssertEqual(e.evaluate(ev).state, .startingServices)

        ev.bootCompleted = true
        ev.bootCompletedAge = 1
        XCTAssertEqual(e.evaluate(ev).state, .waitingForDisplay,
                       "boot_completed alone is NOT readiness")

        ev.counters = DisplayCounters(entered: 10, received: 10, presented: 10)
        XCTAssertEqual(e.evaluate(ev).state, .waitingForSystemUI)

        ev.services.systemUI = .yes
        XCTAssertEqual(e.evaluate(ev).state, .waitingForLauncher)

        ev.services.launcher = .yes
        ev.displayAttached = true
        ev.guestAlive = .yes
        ev.memory = MemoryReading(availableBeforeKillBytes: 1 << 30)
        XCTAssertEqual(e.evaluate(ev).state, .ready)
    }

    /// Progress must never move backwards along the ladder, and the percentage is derived
    /// from the state, so a later state can never show a smaller number.
    func testProgressIsMonotonicAlongTheLadder() {
        let percents = LifecycleState.bootSequence.map(LifecyclePresentation.percent(for:))
        for (a, b) in zip(percents, percents.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "boot sequence percentages must not decrease")
        }
        XCTAssertEqual(LifecyclePresentation.percent(for: .idle), 0)
        XCTAssertEqual(LifecyclePresentation.percent(for: .ready), 100)
    }

    // MARK: - the restore race
    //
    // THE case. A restored machine reports boot complete the instant it restores, while the
    // compositor has not drawn anything. Treating that property as readiness is what put a
    // dismissed overlay over a black screen.

    func testCaseBRestoreWithBootCompleteAndNoFrameIsNotReady() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.counters = .zero                 // nothing drawn
        ev.restoredFromSnapshot = true
        ev.bootCompletedAge = 0.5           // true immediately
        ev.services.systemUI = .unknown
        ev.services.launcher = .unknown

        let decision = e.evaluate(ev)
        XCTAssertEqual(decision.state, .waitingForDisplay)
        XCTAssertFalse(decision.state.permitsOverlayDismissal,
                       "the overlay must stay up: nothing has been drawn")
        XCTAssertEqual(decision.state.consumerLabel, "Loading display…")
        XCTAssertTrue(decision.blockers.contains("no_frame_presented"))
    }

    /// And once a frame arrives it moves on by itself.
    func testCaseBResolvesWhenAFrameArrives() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.counters = .zero
        ev.restoredFromSnapshot = true
        XCTAssertEqual(e.evaluate(ev).state, .waitingForDisplay)

        ev.counters = DisplayCounters(entered: 1, received: 1, presented: 1)
        XCTAssertEqual(e.evaluate(ev).state, .ready)
    }

    // MARK: - the ready gate

    /// ABSENCE BLOCKS, IGNORANCE DOES NOT.
    ///
    /// Requiring a confirmed yes would leave the overlay up forever where a probe cannot
    /// answer; treating unknown as absent would report a fault that is not there.
    func testUnknownServicesDoNotBlockButAreReported() {
        var ev = TestFixtures.readyEvidence()
        ev.services.systemUI = .unknown
        ev.services.launcher = .unknown

        let gate = ReadyGate.evaluate(ev)
        XCTAssertTrue(gate.isSatisfied, "ignorance must not block readiness")
        XCTAssertTrue(gate.blockers.isEmpty)
        XCTAssertTrue(gate.advisories.contains("systemui_unverified"))
        XCTAssertTrue(gate.advisories.contains("launcher_unverified"),
                      "and it must not be silent about it")
    }

    func testConfirmedAbsenceBlocks() {
        var ev = TestFixtures.readyEvidence()
        ev.services.systemUI = .no
        var gate = ReadyGate.evaluate(ev)
        XCTAssertFalse(gate.isSatisfied)
        XCTAssertTrue(gate.blockers.contains("systemui_absent"))

        ev = TestFixtures.readyEvidence()
        ev.services.launcher = .no
        gate = ReadyGate.evaluate(ev)
        XCTAssertFalse(gate.isSatisfied)
        XCTAssertTrue(gate.blockers.contains("launcher_absent"))
    }

    func testGateRequiresEveryBootCheck() {
        for mutate in [
            { (e: inout BootEvidence) in e.bootCompleted = false },
            { (e: inout BootEvidence) in e.displayAttached = false },
            { (e: inout BootEvidence) in e.counters = .zero },
            { (e: inout BootEvidence) in e.guestAlive = .no },
            { (e: inout BootEvidence) in e.memory = MemoryReading(availableBeforeKillBytes: 1 << 20) },
        ] {
            var ev = TestFixtures.readyEvidence()
            mutate(&ev)
            XCTAssertFalse(ReadyGate.evaluate(ev).isSatisfied,
                           "the gate must refuse: \(ev)")
        }
    }

    /// An unmeasurable memory figure must not block readiness -- and must be reported.
    func testUnmeasuredMemoryAdvisoryWithoutBlocking() {
        var ev = TestFixtures.readyEvidence()
        ev.memory = .unknown
        let gate = ReadyGate.evaluate(ev)
        XCTAssertTrue(gate.isSatisfied)
        XCTAssertTrue(gate.advisories.contains("memory_unmeasured"))
    }

    // MARK: - degradation

    func testDegradedWhenBootedAttachedAndNeverDrawn() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.counters = .zero
        ev.bootCompletedAge = 25            // past the 20s graphics window

        let decision = e.evaluate(ev)
        XCTAssertEqual(decision.state, .degraded)
        XCTAssertFalse(decision.state.permitsOverlayDismissal)
        XCTAssertTrue(decision.reason.contains("no frame"),
                      "the reason must name the condition: \(decision.reason)")
    }

    /// Before the window elapses, a booted machine with nothing drawn is merely waiting.
    func testNotDegradedBeforeTheWindowElapses() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.counters = .zero
        ev.bootCompletedAge = 5
        XCTAssertEqual(e.evaluate(ev).state, .waitingForDisplay)
    }

    /// THE application-compilation case: a first boot is quiet on the console for minutes
    /// while the boot animation is drawing. If a frame has ever been presented, quiet is
    /// not a stall.
    func testQuietConsoleWithFramesDrawnIsNotDegraded() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.bootCompleted = false
        ev.bootMilestoneAge = 600           // ten minutes of silence
        ev.counters = DisplayCounters(entered: 50, received: 50, presented: 50)
        ev.services.systemUI = .unknown

        XCTAssertNotEqual(e.evaluate(ev).state, .degraded,
                          "a quiet console while frames are being drawn is normal")
    }

    /// And the same silence with nothing ever drawn IS degraded.
    func testQuietConsoleWithNothingDrawnIsDegraded() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.bootCompleted = false
        ev.bootMilestoneAge = 120
        ev.counters = .zero
        ev.guestAlive = .yes

        let decision = e.evaluate(ev)
        XCTAssertEqual(decision.state, .degraded)
        XCTAssertTrue(decision.reason.contains("90") || decision.reason.contains("milestone"),
                      "the reason should name the silence: \(decision.reason)")
    }

    /// Unknown liveness must not produce a stall report: an unanswered probe is not a fact.
    func testUnknownLivenessWithSilenceIsNotDegraded() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.bootCompleted = false
        ev.bootMilestoneAge = 600
        ev.counters = .zero
        ev.guestAlive = .unknown

        XCTAssertNotEqual(e.evaluate(ev).state, .degraded,
                          "ignorance must not become a fault report")
    }

    func testDegradedOnConfirmedAbsentSystemUIAfterBoot() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.services.systemUI = .no
        XCTAssertEqual(e.evaluate(ev).state, .degraded)
    }

    /// The lifecycle must not react to time alone.
    func testNothingMovesForWantOfAClock() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.counters = .zero
        ev.bootCompletedAge = 5
        XCTAssertEqual(e.evaluate(ev).state, .waitingForDisplay)

        // Ten more evaluations with identical evidence, no time passing.
        for _ in 0..<10 { XCTAssertEqual(e.evaluate(ev).state, .waitingForDisplay) }

        // And with the age advancing, it degrades only because the *evidence* changed.
        ev.bootCompletedAge = 30
        XCTAssertEqual(e.evaluate(ev).state, .degraded)
    }

    /// `degraded` is the one state a machine may come back from, and it does so as soon as
    /// the evidence clears.
    func testDegradedRecoversWhenEvidenceClears() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.counters = .zero
        ev.bootCompletedAge = 30
        XCTAssertEqual(e.evaluate(ev).state, .degraded)

        ev.counters = DisplayCounters(entered: 1, received: 1, presented: 1)
        ev.services.systemUI = .yes
        ev.services.launcher = .yes
        XCTAssertEqual(e.evaluate(ev).state, .ready,
                       "degraded is recoverable; forward-only applies to the ladder")
    }

    // MARK: - ready is terminal

    /// Once booted, a phone that goes quiet -- a probe timing out, a service answering
    /// unknown -- must not be dragged back down the ladder.
    func testReadyIsStickyAgainstEverythingButStopAndFailure() {
        let e = engine()
        let ready = TestFixtures.readyEvidence()
        XCTAssertEqual(e.evaluate(ready).state, .ready)

        for mutate in [
            { (ev: inout BootEvidence) in ev.counters = .zero },
            { (ev: inout BootEvidence) in ev.services = .unknown },
            { (ev: inout BootEvidence) in ev.bootCompleted = false },
            { (ev: inout BootEvidence) in ev.displayAttached = false },
            { (ev: inout BootEvidence) in ev.guestAlive = .unknown },
        ] {
            var ev = ready
            mutate(&ev)
            XCTAssertEqual(e.evaluate(ev).state, .ready,
                           "ready must hold; a booted system does not become unbooted")
        }
    }

    func testFailureAndStopStillWorkFromReady() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        XCTAssertEqual(e.evaluate(ev).state, .ready)

        ev.stopRequested = true
        XCTAssertEqual(e.evaluate(ev).state, .stopping)

        let e2 = engine()
        var failing = TestFixtures.readyEvidence()
        XCTAssertEqual(e2.evaluate(failing).state, .ready)
        failing.vmStatus = .failed(VMFailure(stage: .run, reason: "gone", technical: "gone"))
        XCTAssertEqual(e2.evaluate(failing).state, .failed)
    }

    // MARK: - failure and stopping

    func testRuntimeUnavailableIsAFailureWithAPlainReason() {
        let e = engine()
        var ev = BootEvidence()
        ev.startRequested = true
        ev.runtimeReadiness = .unavailable(reason: "Android needs a permission this app "
                                          + "does not have yet.")

        let decision = e.evaluate(ev)
        XCTAssertEqual(decision.state, .failed)
        XCTAssertTrue(decision.reason.contains("permission"),
                      "the plain reason must reach the lifecycle: \(decision.reason)")
        XCTAssertEqual(decision.state.consumerLabel, "Android could not start")
    }

    func testStopSequence() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        XCTAssertEqual(e.evaluate(ev).state, .ready)

        ev.stopRequested = true
        XCTAssertEqual(e.evaluate(ev).state, .stopping)

        ev.vmStatus = .stopped
        XCTAssertEqual(e.evaluate(ev).state, .stopped)
        XCTAssertTrue(e.evaluate(ev).state.isTerminal)
    }

    // MARK: - diagnostics of a decision

    func testEveryChangingDecisionCarriesAReason() {
        let e = engine()
        var ev = BootEvidence()
        ev.startRequested = true
        let first = e.evaluate(ev)
        XCTAssertTrue(first.changed)
        XCTAssertFalse(first.reason.isEmpty,
                       "a transition with no recorded reason is a bug")

        let same = e.evaluate(ev)
        XCTAssertFalse(same.changed, "identical evidence must not report a change")
        XCTAssertEqual(same.previous, same.state)
    }

    func testDecisionExposesTheGateOutputForTheLog() {
        let e = engine()
        var ev = TestFixtures.readyEvidence()
        ev.services.systemUI = .unknown
        let decision = e.evaluate(ev)
        XCTAssertTrue(decision.advisories.contains("systemui_unverified"),
                      "the gate's advisories must travel with the decision")
    }
}
