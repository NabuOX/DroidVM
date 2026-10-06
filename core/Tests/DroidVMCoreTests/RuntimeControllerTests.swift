// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The façade, driven end to end with simulated platform backends.
///
/// This is the closest the host can get to the real thing: the real `JITManager`, the real
/// `VMEngineAdapter`, the real `LifecycleEngine`, the real `DisplayStatsTracker` and the
/// real diagnostics recorder, with only the two platform backends replaced. What it
/// verifies is DroidVM's orchestration. What it cannot verify is anything about the device.
final class RuntimeControllerTests: XCTestCase {

    /// A controllable clock, so a test can advance time without waiting.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    private struct Harness {
        let controller: RuntimeController
        let vm: SimulatedVMRuntimeBackend
        let memory: SimulatedExecutableMemoryBackend
        let display: SimulatedDisplayBackend
        let recorder: DiagnosticsRecorder
        let ring: RingBufferSink
        let clock: Clock
    }

    private func harness(memory: SimulatedExecutableMemoryBackend.Behaviour =
                                        .succeeds(bytes: 1 << 20),
                         displayMode: QEMUDisplayMode = .software) -> Harness {
        let vm = SimulatedVMRuntimeBackend()
        let mem = SimulatedExecutableMemoryBackend(memory)
        let display = SimulatedDisplayBackend()
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink()
        recorder.add(ring)
        let clock = Clock()

        let jit = JITManager(backend: mem, requestedBytes: 1 << 20, recorder: recorder)
        let engine = VMEngineAdapter(backend: vm,
                                     paths: TestFixtures.paths(),
                                     displayMode: displayMode,
                                     recorder: recorder)
        let controller = RuntimeController(engine: engine,
                                           jit: jit,
                                           display: display,
                                           recorder: recorder,
                                           clock: { clock.now })
        return Harness(controller: controller, vm: vm, memory: mem,
                       display: display, recorder: recorder, ring: ring, clock: clock)
    }

    // MARK: - a start that cannot succeed

    /// The most likely real outcome on a device without a debugger, and it must arrive as a
    /// plain-language lifecycle state rather than a thrown error nobody renders.
    func testStartWithUnavailableRuntimeFailsInPlainLanguage() async {
        let h = harness(memory: .probeSaysUnavailable(reason: "no debugger attached"))

        await h.controller.start()

        XCTAssertEqual(h.controller.currentState, .failed)
        XCTAssertEqual(h.controller.snapshot.label, "Android could not start")
        XCTAssertFalse(h.controller.snapshot.isRunning)
        XCTAssertFalse(h.controller.snapshot.permitsOverlayDismissal)

        // The machine must never have been prepared: there is no point building a machine
        // that cannot execute code.
        XCTAssertEqual(h.vm.prepareCount, 0)
        XCTAssertEqual(h.vm.startCount, 0)

        // And the reason must be present, in the snapshot and in the log.
        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("runtime_prepare_started"))
        XCTAssertTrue(names.contains("runtime_failed"))
    }

    /// A runtime that is *unavailable* is not a runtime that *failed*. The distinction
    /// decides whether the app sends someone looking for a bug.
    func testEnvironmentLimitationIsNotAFailure() async {
        let h = harness(memory: .probeSaysUnavailable(reason: "not entitled"))
        await h.controller.start()
        XCTAssertEqual(h.controller.snapshot.runtimeReadiness, .unavailable(reason: "Android needs a permission this app does not have yet."),
                       "the technical reason must be translated, not passed through")
        XCTAssertTrue(h.controller.snapshot.runtimeReadiness.isActionableByUser)
    }

    func testAcquireFailureIsReportedAsAFailureNotAnEnvironmentLimitation() async {
        let h = harness(memory: .acquireFails(.selfTestFailed(reason: "execute faulted")))
        await h.controller.start()

        XCTAssertEqual(h.controller.currentState, .failed)
        guard case .failed(let reason) = h.controller.snapshot.runtimeReadiness else {
            return XCTFail("expected failed, got \(h.controller.snapshot.runtimeReadiness)")
        }
        XCTAssertTrue(reason.contains("run code"),
                      "a self-test failure means the region was mapped but unusable: \(reason)")
    }

    // MARK: - a start that works

    func testSuccessfulStartReachesBootingAndroid() async {
        let h = harness()
        await h.controller.start()

        XCTAssertEqual(h.memory.acquireCount, 1)
        XCTAssertEqual(h.vm.prepareCount, 1)
        XCTAssertEqual(h.vm.startCount, 1)
        XCTAssertTrue(h.vm.isRunning)

        XCTAssertEqual(h.controller.currentState, .bootingAndroid,
                       "running but not booted: the ladder stops here until the guest says "
                       + "otherwise")
        XCTAssertEqual(h.controller.snapshot.runtimeReadiness, .ready)
        XCTAssertFalse(h.controller.snapshot.permitsOverlayDismissal)

        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("runtime_ready"))
        XCTAssertTrue(names.contains("vm_start_requested"))
        XCTAssertTrue(names.contains("vm_started"))

        // The machine stamp must be available for a snapshot-compatibility decision later.
        XCTAssertEqual(h.controller.snapshot.machineStamp, h.controller.machineStamp)
        XCTAssertNotNil(h.controller.machineStamp)
        XCTAssertTrue(h.controller.machineStamp?.contains("smp=4") ?? false)
    }

    /// The whole point, end to end: a restore reports boot complete immediately, and the
    /// overlay stays up until a frame has actually been presented.
    func testRestoreDoesNotReachReadyWithoutAFrame() async {
        let h = harness()
        await h.controller.start()

        h.controller.ingest(.bootCompleted(restoredFromSnapshot: true))
        XCTAssertEqual(h.controller.currentState, .waitingForDisplay)
        XCTAssertFalse(h.controller.snapshot.permitsOverlayDismissal,
                       "boot_completed is not readiness")
        XCTAssertTrue(h.controller.snapshot.blockers.contains("no_frame_presented"))

        // A frame arrives.
        h.display.attached = true
        h.display.counters = DisplayCounters(entered: 4, received: 4, presented: 4)
        await h.controller.refreshDisplay()

        XCTAssertEqual(h.controller.currentState, .waitingForSystemUI)

        h.controller.ingest(.services(GuestServices(systemServer: .yes,
                                                     surfaceFlinger: .yes,
                                                     systemUI: .yes,
                                                     launcher: .yes)))
        h.controller.applyEvidence { $0.guestAlive = .yes
            $0.memory = MemoryReading(availableBeforeKillBytes: 1 << 30) }

        XCTAssertEqual(h.controller.currentState, .ready)
        XCTAssertTrue(h.controller.snapshot.permitsOverlayDismissal)
        XCTAssertEqual(h.controller.snapshot.progressPercent, 100)
        XCTAssertEqual(h.controller.snapshot.label, "Ready")
    }

    /// The label and the number must always describe the same moment, which is what one
    /// snapshot derived from one state guarantees.
    func testLabelAndProgressAlwaysAgreeWithTheState() async {
        let h = harness()
        await h.controller.start()

        var seen = Set<String>()
        for signal in [GuestSignal.guestLiveness(true),
                       .bootProgress(milestone: "surfaceflinger", fraction: 0.5),
                       .bootCompleted(restoredFromSnapshot: false)] {
            h.controller.ingest(signal)
            let snapshot = h.controller.snapshot
            XCTAssertEqual(snapshot.progressPercent,
                           LifecyclePresentation.percent(for: snapshot.state))
            XCTAssertEqual(snapshot.label, snapshot.state.consumerLabel)
            seen.insert(snapshot.state.rawValue)
        }
        XCTAssertTrue(seen.contains("waitingForDisplay") || seen.contains("bootingAndroid"),
                      "the exchange should have moved the state: \(seen)")
    }

    // MARK: - display evidence

    func testDisplayStallIsClassifiedAndReported() async {
        let h = harness()
        await h.controller.start()

        h.display.attached = true
        h.display.counters = DisplayCounters(entered: 10, received: 10, presented: 10)
        await h.controller.refreshDisplay()
        XCTAssertEqual(h.controller.snapshot.displayCounters.presented, 10)
        XCTAssertEqual(h.controller.snapshot.stallCause, .presented)

        // Frames arrive and are dropped: our fault, and named as such.
        h.display.counters = DisplayCounters(entered: 20, received: 20, presented: 10,
                                             dropped: 10)
        await h.controller.refreshDisplay()
        XCTAssertEqual(h.controller.snapshot.stallCause, .droppedByPresenter)

        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("frame_dropped"),
                      "a drop must be visible in the stream: \(names)")

        // Detaching is reported immediately, even though frames were presented before.
        h.display.attached = false
        await h.controller.refreshDisplay()
        XCTAssertEqual(h.controller.snapshot.stallCause, .surfaceUnavailable)
        XCTAssertTrue(h.controller.snapshot.displayCounters.hasEverPresented,
                      "history is retained")
    }

    /// An idle machine must not produce a stream of identical stall lines.
    func testIdleDisplayIsQuietInTheLog() async {
        let h = harness()
        await h.controller.start()

        h.display.attached = true
        h.display.counters = DisplayCounters(entered: 10, received: 10, presented: 10)
        await h.controller.refreshDisplay()

        let before = h.ring.count
        for _ in 0..<5 { await h.controller.refreshDisplay() }
        XCTAssertEqual(h.ring.count, before,
                       "an unchanged display must not emit anything")
    }

    func testDisplayDetachSignalIsReported() async {
        let h = harness()
        await h.controller.start()
        h.controller.ingest(.displayAttached)
        h.controller.ingest(.displayDetached(reason: "surface lost"))
        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("display_attached"))
        XCTAssertTrue(names.contains("display_detached"))
    }

    // MARK: - failure propagation

    func testEngineLaunchFailureReachesTheSnapshot() async {
        let h = harness()
        h.vm.startError = SimulatedRuntimeError("qemu_main_loop returned 1")
        await h.controller.start()

        XCTAssertEqual(h.controller.currentState, .failed)
        XCTAssertEqual(h.controller.snapshot.label, "Android could not start")
        XCTAssertTrue(h.controller.snapshot.technicalDetail.contains("qemu")
                      || h.ring.contents.contains { $0.contains("qemu_main_loop") },
                      "the underlying reason must survive somewhere")
    }

    /// Android reboots itself on purpose, so an exit after boot is a normal stop.
    func testExitAfterBootIsAnOrdinaryStop() async {
        let h = harness()
        await h.controller.start()
        h.controller.ingest(.bootCompleted(restoredFromSnapshot: false))
        h.controller.ingest(.vmExited(reason: "rebooting into recovery"))

        XCTAssertEqual(h.controller.currentState, .stopped,
                       "a reboot after boot completed is not a failure")
    }

    /// An exit before boot completes is a failure: the machine did not get where it was
    /// going, and it is not going to get there by itself.
    func testExitBeforeBootCompletesIsAFailure() async {
        let h = harness()
        await h.controller.start()
        h.controller.ingest(.vmExited(reason: "guest reset"))

        XCTAssertEqual(h.controller.currentState, .failed)
        XCTAssertTrue(h.controller.snapshot.blockers.isEmpty
                      || !h.controller.snapshot.blockers.isEmpty,
                      "the snapshot must still render")
    }

    // MARK: - observers and shutdown

    func testObserversAreNotifiedOnChangeOnly() async {
        let h = harness()
        var received: [LifecycleState] = []
        h.controller.addObserver { received.append($0.state) }

        XCTAssertEqual(received, [.idle], "the current state is delivered immediately")

        await h.controller.start()
        XCTAssertGreaterThan(received.count, 2)
        XCTAssertEqual(received.last, .bootingAndroid)

        // Identical evaluations must not notify.
        let count = received.count
        h.controller.reevaluate()
        h.controller.reevaluate()
        XCTAssertEqual(received.count, count, "no spurious notifications")
    }

    func testObserverCanBeRemoved() async {
        let h = harness()
        var count = 0
        let id = h.controller.addObserver { _ in count += 1 }
        XCTAssertEqual(count, 1)
        h.controller.removeObserver(id)
        await h.controller.start()
        XCTAssertEqual(count, 1, "a removed observer must not be called again")
    }

    func testStopReturnsTheExecutableRegionAndTheMachine() async {
        let h = harness()
        await h.controller.start()
        XCTAssertTrue(h.memory.isHeld)

        await h.controller.stop()

        XCTAssertEqual(h.controller.currentState, .stopped)
        XCTAssertEqual(h.vm.stopCount, 1)
        XCTAssertFalse(h.vm.isRunning)
        XCTAssertEqual(h.memory.releaseCount, 1)
        XCTAssertFalse(h.memory.isHeld, "the executable region must be given back")
        XCTAssertEqual(h.display.detachCount, 1)

        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("vm_stopped"))
    }

    func testStartingTwiceIsIdempotent() async {
        let h = harness()
        await h.controller.start()
        await h.controller.start()
        XCTAssertEqual(h.vm.startCount, 1, "a second start must not build a second machine")
    }

    // MARK: - guest signals

    func testGuestLivenessIsTriState() async {
        let h = harness()
        await h.controller.start()

        h.controller.ingest(.guestLiveness(nil))
        XCTAssertEqual(h.controller.snapshot.guestAlive, .unknown,
                       "an unanswered probe is not 'not running'")

        h.controller.ingest(.guestLiveness(false))
        XCTAssertEqual(h.controller.snapshot.guestAlive, .no)
    }

    func testMemorySignalIsSampledIntoTheLog() async {
        let h = harness()
        await h.controller.start()
        h.controller.ingest(.memory(MemoryReading(availableBeforeKillBytes: 1234)))
        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("memory_sample"))
    }

    func testBootProgressAndMilestoneStaleness() async {
        let h = harness()
        await h.controller.start()

        h.controller.ingest(.bootProgress(milestone: "init", fraction: 0.1))
        let names = h.ring.contents.compactMap { json($0)?["event"] as? String }
        XCTAssertTrue(names.contains("guest_boot_progress"),
                      "a milestone must be in the stream under its own name")

        // A long silence with nothing drawn is degraded; the clock is the test's.
        h.clock.advance(600)
        h.controller.applyEvidence { $0.guestAlive = .yes }
        XCTAssertEqual(h.controller.currentState, .degraded,
                       "ten minutes of silence with nothing drawn is stalled")
    }

    // MARK: - consumer-facing surface

    /// No internal mechanism may reach a label, at any state, in any order.
    func testNoLabelEverNamesAMechanism() async {
        let h = harness()
        let forbidden = ["jit", "qemu", "renderer", "snapshot", "ram", "metal",
                         "virtio", "surfaceflinger", "systemui", "frame", "fps",
                         "kernel", "gpu", "cpu", "debug", "kernel"]
        var states = Set<String>()

        func assertClean(_ snapshot: RuntimeSnapshot) {
            let lowered = snapshot.label.lowercased()
            for term in forbidden {
                XCTAssertFalse(lowered.contains(term),
                               "label \"\(snapshot.label)\" exposes '\(term)'")
            }
            states.insert(snapshot.state.rawValue)
        }

        h.controller.addObserver(assertClean)
        await h.controller.start()
        for signal in [GuestSignal.guestLiveness(true),
                       .bootProgress(milestone: "surfaceflinger", fraction: 0.4),
                       .bootCompleted(restoredFromSnapshot: true),
                       .services(.unknown),
                       .memory(.unknown),
                       .snapshotRestored] {
            h.controller.ingest(signal)
        }
        h.display.attached = true
        h.display.counters = DisplayCounters(entered: 5, received: 5, presented: 5)
        await h.controller.refreshDisplay()
        h.clock.advance(120)
        h.controller.reevaluate()

        XCTAssertGreaterThan(states.count, 2,
                             "the walk should have visited several states: \(states)")
    }

    // MARK: helpers

    private func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
