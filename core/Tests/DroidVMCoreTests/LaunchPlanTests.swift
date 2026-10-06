// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The machine definition.
///
/// This is the portable half of the engine adapter, and the reason it is portable is so
/// that the machine definition -- the part with all the hard-won, easily-regressed
/// reasoning in it -- can be asserted on any platform.
final class LaunchPlanTests: XCTestCase {

    private func request(displayMode: QEMUDisplayMode = .software,
                         audio: Bool = true,
                         network: Bool = true,
                         ramFile: String? = nil,
                         restore: Bool = false) -> QEMULaunchRequest {
        var shape = QEMUMachineShape()
        shape.displayMode = displayMode
        shape.audioEnabled = audio
        shape.networkEnabled = network
        return QEMULaunchRequest(shape: shape,
                                 paths: TestFixtures.paths(ramFile: ramFile),
                                 restoresSnapshot: restore)
    }

    private func args(_ r: QEMULaunchRequest) -> [String] {
        QEMULaunchPlanBuilder.make(r).arguments
    }

    /// `value(of:)` for the `-flag value` pairs QEMU uses.
    private func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - the essentials

    func testContainsTheRequiredMachineArguments() {
        let a = args(request())
        XCTAssertEqual(value(of: "-M", in: a), "virt")
        XCTAssertNotNil(value(of: "-cpu", in: a))
        XCTAssertEqual(value(of: "-smp", in: a), "4")
        XCTAssertEqual(value(of: "-m", in: a), "4096")
    }

    /// `split-wx=on` is load-bearing rather than an optimisation: iOS withholds a mapping
    /// that is both writable and executable, so without it TCG never asks for the split
    /// allocator and the executable region goes unused.
    func testAcceleratorRequiresSplitWriteExecute() {
        let accel = value(of: "-accel", in: args(request()))
        XCTAssertEqual(accel, QEMUMachineShape.accelerator)
        XCTAssertTrue(accel?.contains("split-wx=on") ?? false,
                      "split-wx must be on: it is a correctness requirement, not tuning")
        XCTAssertTrue(accel?.contains("tcg") ?? false)
    }

    /// The CPU model must not be `max`: advertising SVE and SME makes bionic take slow
    /// paths for every string and memory operation in Android.
    func testDefaultCPUModelAvoidsSVEAndSME() {
        XCTAssertNotEqual(QEMUMachineShape.defaultCPUModel, "max")
        XCTAssertEqual(QEMUMachineShape.defaultCPUModel, "cortex-a72")
    }

    /// `node-name` on the userdata drive is not decoration: `save_snapshot` picks its target
    /// by node name, and unnamed it takes the first snapshot-capable drive in graph order --
    /// which is the UEFI variable store, which is how a 64 MiB vars image became 2.6 GB of
    /// guest RAM blobs.
    func testSnapshotNodeNameIsOnTheUserdataDrive() {
        let a = args(request())
        let userdata = a.first { $0.hasPrefix("file=") && $0.contains("vdb.qcow2") }
        XCTAssertNotNil(userdata)
        XCTAssertTrue(userdata?.contains("node-name=droidvmvmstate") ?? false,
                      "the VM state node must be named, and named on vdb: \(userdata ?? "nil")")

        // And nowhere else, or the engine would have two candidates.
        XCTAssertEqual(a.filter { $0.contains("node-name=") }.count, 1)
    }

    /// Android reboots itself on purpose to repair an inconsistent /data. Forbidding that
    /// turns self-repair into a dead machine.
    func testNoRebootIsDeliberatelyAbsent() {
        let a = args(request())
        XCTAssertFalse(a.contains("-no-reboot"),
                       "-no-reboot would break Android's own recovery path")
        XCTAssertTrue(QEMULaunchPlanBuilder.make(request())
                        .notes.contains { $0.contains("no-reboot") },
                      "and the reason must travel with the plan, so nobody adds it back")
    }

    /// SELinux denials are a continuous stream; formatting and logging each one is real work
    /// on the thread that also runs the machine.
    func testDebugLoggingIsAbsent() {
        XCTAssertFalse(args(request()).contains("-d"))
    }

    func testRunsHeadlessWithSerialToAFile() {
        let a = args(request())
        XCTAssertEqual(value(of: "-display", in: a), "none",
                       "DroidVM's own display listener is the display")
        XCTAssertEqual(value(of: "-monitor", in: a), "none")
        XCTAssertNotNil(value(of: "-serial", in: a))
        XCTAssertTrue(a.contains { $0.hasPrefix("file,id=ser0,path=") })
    }

    // MARK: - display mode

    func testDisplayDeviceFollowsTheMode() {
        let sw = args(request(displayMode: .software))
        XCTAssertTrue(sw.contains("virtio-gpu-pci,xres=360,yres=640"))
        XCTAssertFalse(sw.contains { $0.hasPrefix("virtio-gpu-gl-pci") })

        let gpu = args(request(displayMode: .gpu))
        XCTAssertTrue(gpu.contains("virtio-gpu-gl-pci,xres=360,yres=640"))
    }

    /// Choosing the GL device is not reversible inside a session, so the plan must warn.
    func testGPUModeCarriesTheIrreversibilityWarning() {
        let sw = QEMULaunchPlanBuilder.make(request(displayMode: .software))
        XCTAssertFalse(sw.notes.contains { $0.contains("reversible") })

        let gpu = QEMULaunchPlanBuilder.make(request(displayMode: .gpu))
        XCTAssertTrue(gpu.notes.contains { $0.contains("reversible") },
                      "the GPU plan must record that the console cannot fall back")
    }

    func testDisplaySizeComesFromTheShape() {
        var shape = QEMUMachineShape()
        shape.displaySize = DisplaySize(width: 720, height: 1280)
        let a = QEMULaunchPlanBuilder.make(
            QEMULaunchRequest(shape: shape, paths: TestFixtures.paths())).arguments
        XCTAssertTrue(a.contains("virtio-gpu-pci,xres=720,yres=1280"))
    }

    // MARK: - conditionals

    func testFileBackedRAMIsOptionalAndShareIsOnWhenPresent() {
        XCTAssertFalse(args(request()).contains { $0.contains("memory-backend-file") })

        let withFile = args(request(ramFile: "/data/ram.bin"))
        let backend = withFile.first { $0.hasPrefix("memory-backend-file,") }
        XCTAssertNotNil(backend)
        XCTAssertTrue(backend?.contains("share=on") ?? false,
                      "without share=on the mapping is private and every dirtied page "
                      + "becomes anonymous again -- the problem it exists to solve")
        XCTAssertTrue(backend?.contains("prealloc=off") ?? false,
                      "prealloc would make every page resident immediately")
        XCTAssertTrue(backend?.contains("mem-path=/data/ram.bin") ?? false)
    }

    func testAudioIsConditionalAndPartOfTheMachineShape() {
        XCTAssertTrue(args(request(audio: true)).contains { $0.hasPrefix("virtio-sound-pci") })
        XCTAssertFalse(args(request(audio: false)).contains { $0.hasPrefix("virtio-sound-pci") })

        var on = QEMUMachineShape(); on.audioEnabled = true
        var off = QEMUMachineShape(); off.audioEnabled = false
        XCTAssertNotEqual(on.stamp, off.stamp,
                          "audio changes the machine, so it belongs in the stamp: a "
                          + "snapshot taken without it cannot be restored into it")
    }

    func testNetworkIsConditionalAndForwardsOnlyOnLoopback() {
        XCTAssertFalse(args(request(network: false)).contains { $0.contains("netdev=net0") })

        let a = args(request(network: true))
        let netdev = a.first { $0.hasPrefix("user,id=net0,") }
        XCTAssertNotNil(netdev)
        XCTAssertTrue(netdev?.contains("hostfwd=tcp:127.0.0.1:5555-:5555") ?? false)
        XCTAssertTrue(netdev?.contains("hostfwd=tcp:127.0.0.1:5599-:5599") ?? false)
        XCTAssertFalse(netdev?.contains("0.0.0.0") ?? true,
                       "nothing outside this app may reach the guest")
    }

    // MARK: - determinism and provenance

    /// The same request must produce the same arguments, so a log can be diffed.
    func testPlanIsDeterministic() {
        XCTAssertEqual(args(request()), args(request()))
        XCTAssertEqual(QEMULaunchPlanBuilder.make(request()).argumentLine(),
                       QEMULaunchPlanBuilder.make(request()).argumentLine())
    }

    func testQEMUInternalIdentifiersAreDroidVMOwned() {
        let line = QEMULaunchPlanBuilder.make(request(ramFile: "/r")).argumentLine()
        for identifier in ["droidvmvmstate", "droidvmram", "droidvmballoon", "droidvmaudio"] {
            XCTAssertTrue(line.contains(identifier), "expected \(identifier) in the plan")
        }
        for marker in DroidVMIdentity.foreignBrandMarkers {
            XCTAssertFalse(line.lowercased().contains(marker.lowercased()),
                           "no other project's identifiers may appear in "
                           + "DroidVM's machine")
        }
    }

    func testNotesExplainTheTraps() {
        let notes = QEMULaunchPlanBuilder.make(request()).notes.joined(separator: " | ")
        for topic in ["split-wx", "node-name", "serial", "no-reboot", "loopback"] {
            XCTAssertTrue(notes.lowercased().contains(topic.lowercased()),
                          "the plan's notes must cover \(topic)")
        }
    }

    func testRestoreRequestIsNoted() {
        let restoring = QEMULaunchPlanBuilder.make(request(restore: true))
        XCTAssertTrue(restoring.notes.contains { $0.contains("stamp") })
    }
}
