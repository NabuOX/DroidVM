// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The VM engine adapter, against a simulated runtime backend.
///
/// These tests exercise DroidVM's own status machine, failure classification and
/// diagnostics. They say nothing about a real device: a simulated backend that never runs
/// QEMU cannot demonstrate that QEMU works. Device behaviour is recorded as NOT TESTED.
final class VMEngineAdapterTests: XCTestCase {

    func testPrepareBuildsAPlanAndReportsPrepared() async throws {
        let backend = SimulatedVMRuntimeBackend()
        let adapter = TestFixtures.adapter(backend: backend)

        XCTAssertEqual(adapter.status, .idle)

        try await adapter.prepare(TestFixtures.configuration())

        XCTAssertEqual(adapter.status, .prepared)
        XCTAssertEqual(backend.prepareCount, 1)
        XCTAssertFalse(backend.isRunning, "prepare must not begin executing the guest")

        let plan = try XCTUnwrap(adapter.plan)
        XCTAssertTrue(plan.argumentLine().contains("-M virt"))
        XCTAssertEqual(backend.lastPlan, plan, "the backend got exactly the plan we built")

        let shape = try XCTUnwrap(adapter.shape)
        XCTAssertEqual(shape.guestRAMBytes, 4 << 30)
        XCTAssertEqual(shape.cpuCount, 4)
        XCTAssertTrue(adapter.machineStampIsSet)
    }

    /// A preparation failure must arrive as a *status* as well as a throw, because a caller
    /// that ignores the throw must still not be able to miss it.
    func testPreparationFailurePropagatesReasonAndStage() async {
        let backend = SimulatedVMRuntimeBackend()
        backend.prepareError = SimulatedRuntimeError("dylib not found")
        let adapter = TestFixtures.adapter(backend: backend)

        do {
            try await adapter.prepare(TestFixtures.configuration())
            XCTFail("expected a throw")
        } catch let error as VMFailureError {
            XCTAssertEqual(error.failure.stage, .preparation)
            XCTAssertFalse(error.failure.reason.isEmpty)
            XCTAssertTrue(error.failure.technical.contains("dylib not found"),
                          "the underlying reason must survive: \(error.failure.technical)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }

        guard case .failed(let failure) = adapter.status else {
            return XCTFail("status must record the failure, got \(adapter.status)")
        }
        XCTAssertEqual(failure.stage, .preparation)
        XCTAssertFalse(adapter.status.canStart)
    }

    func testStartFailureIsReportedAtTheLaunchStage() async throws {
        let backend = SimulatedVMRuntimeBackend()
        backend.startError = SimulatedRuntimeError("qemu_main_loop returned")
        let adapter = TestFixtures.adapter(backend: backend)
        try await adapter.prepare(TestFixtures.configuration())

        do {
            try await adapter.start()
            XCTFail("expected a throw")
        } catch let error as VMFailureError {
            XCTAssertEqual(error.failure.stage, .launch,
                           "a launch failure is not a preparation failure: the diagnosis "
                           + "and the fix are different")
        }

        guard case .failed(let failure) = adapter.status else {
            return XCTFail("expected failed, got \(adapter.status)")
        }
        XCTAssertEqual(failure.stage, .launch)
    }

    /// Starting without preparing is a programming error, and must be loud rather than
    /// silently doing nothing.
    func testStartWithoutPrepareFails() async {
        let adapter = TestFixtures.adapter(backend: SimulatedVMRuntimeBackend())
        do {
            try await adapter.start()
            XCTFail("expected a throw")
        } catch let error as VMFailureError {
            XCTAssertEqual(error.failure.stage, .launch)
            XCTAssertTrue(error.failure.technical.contains("idle"),
                          "the status it was actually in should be recorded")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Preparing a running machine would build a second definition and discard the first.
    func testPrepareWhileRunningIsRefused() async throws {
        let backend = SimulatedVMRuntimeBackend()
        let adapter = TestFixtures.adapter(backend: backend)
        try await adapter.prepare(TestFixtures.configuration())
        try await adapter.start()
        XCTAssertEqual(adapter.status, .running)

        do {
            try await adapter.prepare(TestFixtures.configuration())
            XCTFail("expected a throw")
        } catch let error as VMFailureError {
            XCTAssertEqual(error.failure.stage, .preparation)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(backend.prepareCount, 1, "the running machine must be left alone")
    }

    func testSuccessfulStartStopsAndReportsEachStep() async throws {
        let backend = SimulatedVMRuntimeBackend()
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink()
        recorder.add(ring)
        let adapter = TestFixtures.adapter(backend: backend, recorder: recorder)

        try await adapter.prepare(TestFixtures.configuration())
        try await adapter.start()
        XCTAssertEqual(adapter.status, .running)
        XCTAssertTrue(adapter.isRunning, "liveness comes from the backend, not from status")

        await adapter.stop()
        XCTAssertEqual(adapter.status, .stopped)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertFalse(backend.isRunning)

        let names = ring.contents.compactMap { eventName(in: $0) }
        XCTAssertEqual(names.first, "vm_start_requested")
        XCTAssertTrue(names.contains("vm_started"))
        XCTAssertTrue(names.contains("vm_stopped"))

        // The machine definition travels with the start, so a log can explain its own
        // machine without a second source.
        XCTAssertTrue(ring.contents.contains { $0.contains("arguments") })
    }

    /// An exit we did not ask for is a `run`-stage failure, which is a different diagnosis
    /// from a launch failure.
    func testUnexpectedExitIsARunStageFailure() async throws {
        let backend = SimulatedVMRuntimeBackend()
        let adapter = TestFixtures.adapter(backend: backend)
        try await adapter.prepare(TestFixtures.configuration())
        try await adapter.start()

        adapter.noteUnexpectedExit(technical: "guest reset")
        guard case .failed(let failure) = adapter.status else {
            return XCTFail("expected failed, got \(adapter.status)")
        }
        XCTAssertEqual(failure.stage, .run)
        XCTAssertTrue(failure.technical.contains("guest reset"))
    }

    /// An exit after boot completed is Android rebooting itself, which is normal.
    func testUnexpectedExitBeforeStartIsIgnored() async throws {
        let adapter = TestFixtures.adapter(backend: SimulatedVMRuntimeBackend())
        adapter.noteUnexpectedExit(technical: "stray")
        XCTAssertEqual(adapter.status, .idle,
                       "an exit report for a machine that never ran is not a failure")
    }

    func testRestoreOnlyWhenConfigurationAllowsIt() async throws {
        let backend = SimulatedVMRuntimeBackend()
        let restoring = VMEngineAdapter(backend: backend,
                                        paths: TestFixtures.paths(),
                                        restoresSnapshot: true)
        try await restoring.prepare(TestFixtures.configuration(restore: false))
        XCTAssertFalse(restoring.plan?.notes.contains { $0.contains("restore requested") } ?? true,
                       "the adapter may not restore when the configuration forbids it")

        let backend2 = SimulatedVMRuntimeBackend()
        let restoring2 = VMEngineAdapter(backend: backend2,
                                        paths: TestFixtures.paths(),
                                        restoresSnapshot: true)
        try await restoring2.prepare(TestFixtures.configuration(restore: true))
        XCTAssertTrue(restoring2.plan?.notes.contains { $0.contains("restore requested") } ?? false)
    }

    func testStatusTransitionsAreMonotonicThroughTheHappyPath() async throws {
        let backend = SimulatedVMRuntimeBackend()
        let adapter = TestFixtures.adapter(backend: backend)
        var seen: [VMStatus] = [adapter.status]

        try await adapter.prepare(TestFixtures.configuration())
        seen.append(adapter.status)
        try await adapter.start()
        seen.append(adapter.status)
        await adapter.stop()
        seen.append(adapter.status)

        XCTAssertEqual(seen, [.idle, .prepared, .running, .stopped])
        XCTAssertTrue(VMStatus.prepared.canStart)
        XCTAssertTrue(VMStatus.stopped.canStart)
        XCTAssertFalse(VMStatus.running.canStart, "a running machine is not startable")
        XCTAssertFalse(VMStatus.failed(.init(stage: .launch, reason: "x", technical: "y")).canStart)
    }

    func testFailureStagesAreAllDistinguishable() {
        let stages = VMFailure.Stage.allCases
        XCTAssertEqual(stages.count, 4)
        XCTAssertEqual(Set(stages.map(\.rawValue)).count, 4)
        for stage in stages { XCTAssertFalse(stage.rawValue.isEmpty) }
    }

    // MARK: helpers

    private func eventName(in line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["event"] as? String
    }
}

/// A stand-in for an error the platform backend would raise.
struct SimulatedRuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension VMEngineAdapter {
    /// Whether a machine stamp was produced. Test-only convenience.
    var machineStampIsSet: Bool { shape?.stamp.isEmpty == false }
}
