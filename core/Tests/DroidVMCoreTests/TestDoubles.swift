// SPDX-License-Identifier: GPL-2.0-or-later
//
// Test doubles for the two platform backends.
//
// WHAT THESE ARE, AND WHAT THEY ARE NOT
//
// They are *simulated platform behaviour*, used to exercise DroidVM's own orchestration:
// status machines, failure classification, diagnostics and lifecycle transitions. They
// deliberately do not claim anything about the platform. A test that passes here says
// "the adapter handles this outcome correctly", never "the device does this".
//
// The names say `Simulated` for that reason, and the Phase 1 report records device
// behaviour as NOT TESTED. A double that could be mistaken for a passing device test would
// be worse than no test at all.

import Foundation
@testable import DroidVMCore

/// A controllable executable-memory backend.
final class SimulatedExecutableMemoryBackend: ExecutableMemoryBackend {

    enum Behaviour {
        /// Probe says it cannot be obtained, before anything is attempted.
        case probeSaysUnavailable(reason: String)
        /// Probe is honest but acquire fails.
        case acquireFails(ExecutableMemoryError)
        /// Probe cannot answer, and acquire succeeds anyway.
        case probeUnknownThenSucceeds(bytes: Int)
        /// The ordinary success path.
        case succeeds(bytes: Int)
    }

    var behaviour: Behaviour
    private(set) var probeCount = 0
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var isHeld = false

    /// Set to make the next acquire succeed without changing the configured behaviour.
    var nextAcquireSucceeds = false

    init(_ behaviour: Behaviour = .succeeds(bytes: 1 << 20)) {
        self.behaviour = behaviour
    }

    func probe() -> JITAvailability {
        probeCount += 1
        switch behaviour {
        case .probeSaysUnavailable(let reason):
            return .unavailable(reason: reason)
        case .acquireFails, .succeeds, .probeUnknownThenSucceeds:
            return .unknown
        }
    }

    func acquire(bytes: Int) throws -> ExecutableRegion {
        acquireCount += 1
        if nextAcquireSucceeds {
            isHeld = true
            return ExecutableRegion(executableAddress: 0x1000_0000,
                                    writableAddress: 0x2000_0000,
                                    size: bytes)
        }
        switch behaviour {
        case .acquireFails(let error):
            throw error
        case .succeeds(let granted), .probeUnknownThenSucceeds(let granted):
            isHeld = true
            return ExecutableRegion(executableAddress: 0x1000_0000,
                                    writableAddress: 0x2000_0000,
                                    size: granted)
        case .probeSaysUnavailable(let reason):
            throw ExecutableMemoryError.notPermitted(reason: reason)
        }
    }

    func release() {
        releaseCount += 1
        isHeld = false
    }
}

/// A controllable VM runtime backend.
final class SimulatedVMRuntimeBackend: VMRuntimeBackend {

    /// What `prepare` does.
    var prepareError: Error?
    /// What `start` does.
    var startError: Error?

    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastPlan: QEMULaunchPlan?

    /// Whether the backend believes the machine is running.
    ///
    /// Setting this externally simulates the guest exiting on its own.
    var isRunning: Bool = false

    init() {}

    func prepare(plan: QEMULaunchPlan) throws {
        prepareCount += 1
        lastPlan = plan
        if let prepareError { throw prepareError }
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

/// A display backend that reports whatever it is told to.
///
/// Allows the frame path to be driven deterministically: set counters, call
/// `refreshDisplay()`, assert the classified window.
final class SimulatedDisplayBackend: DisplayBackend, @unchecked Sendable {

    /// A class, because `DisplaySurfaceHandle` is a class protocol: on the device this is a
    /// `CAMetalLayer` or an EGL surface, and a value type could be copied and outlive what
    /// it names.
    final class Surface: DisplaySurfaceHandle {}

    private(set) var attachCount = 0
    private(set) var detachCount = 0

    var attached: Bool = false
    var counters: DisplayCounters = .zero

    func attach(surface: DisplaySurfaceHandle) async throws {
        attachCount += 1
        attached = true
    }

    func detach() async {
        detachCount += 1
        attached = false
    }
}

/// A launch plan and paths, for tests that need a valid machine definition.
enum TestFixtures {

    static func paths(ramFile: String? = nil) -> QEMULaunchPaths {
        QEMULaunchPaths(firmwareCode: "/app/edk2-aarch64-code.fd",
                        firmwareVars: "/data/efi-vars.fd",
                        systemDisk: "/data/vda.qcow2",
                        userdataDisk: "/data/vdb.qcow2",
                        pcBiosDirectory: "/app/pc-bios",
                        serialLog: "/data/serial.log",
                        ramFile: ramFile)
    }

    static func adapter(backend: SimulatedVMRuntimeBackend,
                        displayMode: QEMUDisplayMode = .software,
                        recorder: DiagnosticsSink? = nil) -> VMEngineAdapter {
        VMEngineAdapter(backend: backend,
                        paths: paths(),
                        displayMode: displayMode,
                        recorder: recorder)
    }

    static func configuration(restore: Bool = false) -> VMConfiguration {
        VMConfiguration(guestRAMBytes: 4 << 30,
                        cpuCount: 4,
                        displaySize: DisplaySize(width: 360, height: 640),
                        mayRestoreSnapshot: restore)
    }

    /// Evidence for a healthy, booted, drawing machine.
    static func readyEvidence() -> BootEvidence {
        var e = BootEvidence()
        e.startRequested = true
        e.runtimeReadiness = .ready
        e.vmStatus = .running
        e.guestAlive = .yes
        e.bootCompleted = true
        e.bootCompletedAge = 5
        e.services = GuestServices(systemServer: .yes, surfaceFlinger: .yes,
                                   systemUI: .yes, launcher: .yes)
        e.displayAttached = true
        e.counters = DisplayCounters(entered: 900, received: 900, presented: 900)
        e.memory = MemoryReading(availableBeforeKillBytes: 1 << 30)
        return e
    }
}
