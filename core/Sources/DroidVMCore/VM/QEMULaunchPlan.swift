// SPDX-License-Identifier: GPL-2.0-or-later
//
// The machine definition, as data.
//
// WHY THIS IS PORTABLE AND TESTED RATHER THAN BURIED IN THE ENGINE ADAPTER
//
// The single most valuable thing in the reference implementation is not its code, it is
// the reasoning attached to its command line: which CPU model, which accelerators, which
// devices, and what went wrong with each alternative. That reasoning was expressed as a
// literal array inside a 2000-line runner, which meant it could only be read, never
// checked, and only on a machine that could build the app.
//
// Here the machine is a value. Building it is pure, so the whole definition -- including
// the traps below -- is exercised by host tests on any platform. The engine adapter is
// left with only the part that genuinely needs an Apple device: handing the arguments to
// a shared library and running its main loop.
//
// Fields named `droidvm*` are QEMU-internal identifiers. They are DroidVM's own; the
// mapping to the reference's equivalents is recorded in THIRD_PARTY.md so the two can
// still be compared.

import Foundation

// MARK: - Display mode

/// Which virtio-gpu device the machine is built around.
///
/// This is part of the machine's *identity*, not a runtime toggle: a machine built with
/// `virtio-gpu-pci` cannot be restored into one built with `virtio-gpu-gl-pci`, and
/// choosing wrongly is not reversible within a session. The reference implementation
/// learned this the hard way -- a console created for virtio-gpu-gl demands a GL listener,
/// so when GL then failed to initialise, the software display could not register and QEMU
/// aborted with "The console requires a GL context". Falling back has to mean not asking
/// for the GL device in the first place.
public enum QEMUDisplayMode: String, Equatable, CaseIterable, Sendable {
    case software = "sw"
    case gpu = "gpu"

    var deviceName: String {
        switch self {
        case .software: return "virtio-gpu-pci"
        case .gpu: return "virtio-gpu-gl-pci"
        }
    }
}

// MARK: - Machine shape

/// Everything QEMU refuses to restore across.
///
/// A snapshot carries the machine's shape implicitly. Restoring it into a machine with a
/// different CPU model, vCPU count, RAM size or display device is not a degraded restore,
/// it is a refused one -- so the shape is a value with a comparable stamp, and snapshot
/// compatibility is a question this type can answer.
public struct QEMUMachineShape: Equatable, Sendable {

    public var cpuModel: String
    public var cpuCount: Int
    public var guestRAMBytes: UInt64
    public var displayMode: QEMUDisplayMode
    public var displaySize: DisplaySize
    public var audioEnabled: Bool
    public var networkEnabled: Bool

    public init(cpuModel: String = QEMUMachineShape.defaultCPUModel,
                cpuCount: Int = 4,
                guestRAMBytes: UInt64 = 4 << 30,
                displayMode: QEMUDisplayMode = .software,
                displaySize: DisplaySize = DisplaySize(width: 360, height: 640),
                audioEnabled: Bool = true,
                networkEnabled: Bool = true) {
        self.cpuModel = cpuModel
        self.cpuCount = cpuCount
        self.guestRAMBytes = guestRAMBytes
        self.displayMode = displayMode
        self.displaySize = displaySize
        self.audioEnabled = audioEnabled
        self.networkEnabled = networkEnabled
    }

    /// The CPU model DroidVM asks for by default.
    ///
    /// NOT `max`, which advertises FEAT_SVE and FEAT_SME. TCG has no host SVE to map those
    /// onto, so every SVE instruction becomes a helper call -- while bionic selects its
    /// SVE memcpy/memset/strlen/strcmp through ifunc the moment HWCAP_SVE is set. The
    /// result is that every string and memory operation in the whole of Android takes the
    /// slow path. With SVE absent, bionic falls back to its ASIMD routines, which TCG
    /// translates onto the host's own NEON.
    ///
    /// Pointer authentication is kept, with a cheap algorithm instead of QARMA. Turning it
    /// off is not neutral: this kernel's dynamic shadow-call-stack patcher rewrites
    /// pointer-auth instructions, and it runs *only* when the CPU lacks PAC. Removing the
    /// feature switches a whole code path ON rather than switching one off, and it
    /// panicked the kernel at 9.3s inside `load_module` with PACIASP/AUTIASP encodings in
    /// the registers. `impdef` keeps PAC present while picking a cheap algorithm.
    public static let defaultCPUModel = "cortex-a72"

    /// What the accel string must contain, and why each part is there.
    ///
    /// `split-wx=on` is load-bearing rather than an optimisation: iOS will not give a
    /// writable mapping that is also executable, so TCG must be told to keep the two
    /// apart. Without it, TCG never asks for the split allocator and the JIT region goes
    /// unused.
    public static let accelerator = "tcg,tb-size=256,thread=multi,split-wx=on"

    public var guestRAMMiB: UInt64 { guestRAMBytes >> 20 }

    /// A short, stable identity for this shape.
    ///
    /// Stored beside a snapshot so that a machine of the wrong shape is refused rather
    /// than restored into something subtly wrong. Deliberately human-readable: it ends up
    /// in log lines and in a stamp file on disk, and a stamp nobody can read is a stamp
    /// nobody checks.
    public var stamp: String {
        "cpu=\(cpuModel);smp=\(cpuCount);ram=\(guestRAMMiB);"
        + "disp=\(displayMode.rawValue);res=\(displaySize.width)x\(displaySize.height);"
        + "audio=\(audioEnabled ? 1 : 0);net=\(networkEnabled ? 1 : 0)"
    }

    public init?(stamp: String) {
        var fields: [String: String] = [:]
        for part in stamp.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            fields[String(kv[0])] = String(kv[1])
        }
        guard let cpu = fields["cpu"], let smp = fields["smp"].flatMap(Int.init),
              let ram = fields["ram"].flatMap(UInt64.init),
              let disp = fields["disp"].flatMap(QEMUDisplayMode.init(rawValue:)),
              let res = fields["res"] else { return nil }
        let wh = res.split(separator: "x").compactMap { Int($0) }
        guard wh.count == 2 else { return nil }

        self.cpuModel = cpu
        self.cpuCount = smp
        self.guestRAMBytes = ram << 20
        self.displayMode = disp
        self.displaySize = DisplaySize(width: wh[0], height: wh[1])
        self.audioEnabled = fields["audio"] == "1"
        self.networkEnabled = fields["net"] == "1"
    }
}

// MARK: - Paths

/// Where the machine's files are. Absolute paths, already resolved.
public struct QEMULaunchPaths: Equatable, Sendable {

    public var firmwareCode: String
    public var firmwareVars: String
    public var systemDisk: String
    public var userdataDisk: String
    public var pcBiosDirectory: String
    public var serialLog: String

    /// When set, guest RAM is a MAP_SHARED file rather than anonymous memory.
    ///
    /// The kernel can then write it back and evict it instead of counting all of it
    /// against our jetsam footprint. `share=on` is what makes the mapping shared and
    /// therefore external; without it the file maps private and every dirtied page becomes
    /// anonymous again, which is the thing being avoided. `prealloc` is deliberately off,
    /// because touching the whole block up front would make every page resident
    /// immediately and hand back exactly the problem this solves.
    public var ramFile: String?

    public init(firmwareCode: String,
                firmwareVars: String,
                systemDisk: String,
                userdataDisk: String,
                pcBiosDirectory: String,
                serialLog: String,
                ramFile: String? = nil) {
        self.firmwareCode = firmwareCode
        self.firmwareVars = firmwareVars
        self.systemDisk = systemDisk
        self.userdataDisk = userdataDisk
        self.pcBiosDirectory = pcBiosDirectory
        self.serialLog = serialLog
        self.ramFile = ramFile
    }
}

// MARK: - Request

public struct QEMULaunchRequest: Equatable, Sendable {

    public var shape: QEMUMachineShape
    public var paths: QEMULaunchPaths

    /// The qcow2 node the VM state is saved into.
    ///
    /// The name matters and is not decoration: `save_snapshot` picks its target by node
    /// name, and with nothing named it takes the FIRST snapshot-capable drive in graph
    /// order -- which is the pflash variable store. That is how a 64 MiB UEFI vars image
    /// grew to 2.6 GB of guest RAM blobs.
    public var snapshotNodeName: String

    /// Port on the guest that DroidVM's shell listener is bound to.
    ///
    /// The guest image defines this, not DroidVM. It is a plain `nc` listener started at
    /// boot as the shell user, which hands whatever is written to it to `/system/bin/sh`
    /// -- the same authority `adb shell` has, obtained without `adbd`'s cooperation. That
    /// matters because an unprovisioned Android runs `adbd` in trade-in mode and refuses
    /// every shell.
    public var guestShellPort: Int

    /// Host loopback port forwarded to the guest's adbd, when it is willing to talk.
    public var adbPort: Int

    /// Whether to ask QEMU to resume a saved machine.
    public var restoresSnapshot: Bool

    public init(shape: QEMUMachineShape,
                paths: QEMULaunchPaths,
                snapshotNodeName: String = "droidvmvmstate",
                guestShellPort: Int = 5599,
                adbPort: Int = 5555,
                restoresSnapshot: Bool = false) {
        self.shape = shape
        self.paths = paths
        self.snapshotNodeName = snapshotNodeName
        self.guestShellPort = guestShellPort
        self.adbPort = adbPort
        self.restoresSnapshot = restoresSnapshot
    }
}

// MARK: - Plan

public struct QEMULaunchPlan: Equatable, Sendable {

    /// Arguments *after* argv[0]. The adapter prepends the program name QEMU expects.
    public var arguments: [String]

    /// Extra environment for the process hosting the engine.
    public var environment: [String: String]

    /// Why the non-obvious choices are what they are. Emitted to diagnostics once per
    /// start, so a log from a device explains its own machine definition.
    public var notes: [String]

    public func argumentLine() -> String { arguments.joined(separator: " ") }
}

// MARK: - Builder

public enum QEMULaunchPlanBuilder {

    public static func make(_ request: QEMULaunchRequest) -> QEMULaunchPlan {
        let shape = request.shape
        let paths = request.paths
        var args: [String] = []
        var notes: [String] = []

        // --- machine ---
        args += ["-M", "virt"]
        notes.append("-M virt adds a default virtio-net-pci unless told otherwise")

        args += ["-cpu", shape.cpuModel]
        args += ["-smp", String(shape.cpuCount)]
        args += ["-m", String(shape.guestRAMMiB)]
        args += ["-accel", QEMUMachineShape.accelerator]
        notes.append("accel=\(QEMUMachineShape.accelerator): split-wx is required, not an "
                     + "optimisation -- iOS withholds a writable+executable mapping")

        // --- memory backend ---
        if let ramFile = paths.ramFile {
            args += ["-object", "memory-backend-file,id=droidvmram,"
                     + "size=\(shape.guestRAMMiB)M,mem-path=\(ramFile),"
                     + "share=on,prealloc=off"]
            notes.append("file-backed guest RAM so the kernel can evict it instead of "
                         + "counting it against jetsam; prealloc off on purpose")
        }

        // --- balloon ---
        // Present so the guest can be told to hand pages back when the host gets tight.
        args += ["-device", "virtio-balloon-pci,id=droidvmballoon"]

        // --- firmware ---
        args += ["-drive", "if=pflash,unit=0,format=raw,readonly=on,"
                 + "file=\(paths.firmwareCode)"]
        args += ["-drive", "if=pflash,unit=1,format=qcow2,file=\(paths.firmwareVars)"]

        // --- disks ---
        // vda is the system disk, vdb is userdata. bootindex matters: the firmware must
        // try the system disk first.
        args += ["-device", "virtio-blk-pci,drive=vda,bootindex=0"]
        args += ["-device", "virtio-blk-pci,drive=vdb,bootindex=1"]
        // detect-zeroes deliberately absent: it made QEMU scan the contents of every guest
        // write looking for runs of zeroes to punch out, which is host CPU spent to save
        // disk space on a device with tens of gigabytes free. Host CPU is the one resource
        // this system is short of.
        args += ["-drive", "file=\(paths.systemDisk),if=none,id=vda,"
                 + "format=qcow2,discard=unmap"]
        args += ["-drive", "file=\(paths.userdataDisk),if=none,id=vdb,"
                 + "node-name=\(request.snapshotNodeName),format=qcow2,discard=unmap"]
        notes.append("node-name=\(request.snapshotNodeName) on vdb: save_snapshot picks "
                     + "its target by node name, and unnamed it takes the first "
                     + "snapshot-capable drive, which is the UEFI variable store")

        // --- network ---
        if shape.networkEnabled {
            args += ["-device", "virtio-net-pci,netdev=net0"]
            args += ["-netdev", "user,id=net0,"
                     + "hostfwd=tcp:127.0.0.1:\(request.adbPort)-:\(request.adbPort),"
                     + "hostfwd=tcp:127.0.0.1:\(request.guestShellPort)"
                     + "-:\(request.guestShellPort)"]
            notes.append("both forwards on loopback, so nothing outside this app can "
                         + "reach the guest")
        }

        // --- firmware data directory ---
        args += ["-L", paths.pcBiosDirectory]

        // --- display device ---
        // Pixel count is the dominant cost of the software path: there is no GPU, so every
        // pixel is rasterised in software by a CPU that is itself emulated, and the cost is
        // paid twice. A quarter of the pixels is a quarter of the multiplication.
        args += ["-device", "\(shape.displayMode.deviceName),"
                 + "xres=\(shape.displaySize.width),yres=\(shape.displaySize.height)"]
        if shape.displayMode == .gpu {
            notes.append("virtio-gpu-gl-pci demands a GL listener: if GL then fails, the "
                         + "software display cannot register and QEMU aborts. The choice "
                         + "is not reversible within a session")
        }

        // --- input ---
        // USB HID rather than virtio-input: every Android kernel has usbhid, virtio-input
        // is not guaranteed, and losing input would look exactly like a hung guest.
        args += ["-device", "qemu-xhci,id=usb-bus"]
        args += ["-device", "usb-tablet,bus=usb-bus.0"]
        args += ["-device", "usb-kbd,bus=usb-bus.0"]

        // --- entropy ---
        // Without it the guest stalls waiting for crng init.
        args += ["-device", "virtio-rng-pci"]

        // --- audio ---
        // virtio-snd rather than intel-hda: a paravirtual device with no codec to emulate,
        // so the cost is a queue rather than a chip. Conditional, because adding it changes
        // the machine definition and no snapshot taken without it can be restored into it.
        if shape.audioEnabled {
            args += ["-audiodev", "droidvmaudio,id=droidvmaudio"]
            args += ["-device", "virtio-sound-pci,audiodev=droidvmaudio"]
            notes.append("audio changes the machine definition, so it is part of the "
                         + "machine stamp")
        }

        // --- serial and headless operation ---
        args += ["-chardev", "file,id=ser0,path=\(paths.serialLog)"]
        args += ["-serial", "chardev:ser0"]
        // The serial log is the only view into the guest before the display works, and it is
        // what makes "booted but nothing on screen" distinguishable from "still booting".
        // It goes to a file rather than a pipe on purpose: a pipe needs a reader on a
        // thread, and that thread competes with the machine for the CPU it is emulating.
        notes.append("serial goes to a file, not a pipe: a reader thread would compete "
                     + "with the machine for the CPU it is emulating")
        // DroidVM's own DisplayChangeListener is the display; QEMU needs no backend.
        args += ["-display", "none"]
        args += ["-monitor", "none"]

        // NOT -no-reboot. Android reboots itself on purpose, and the most important case is
        // repair: when /data is inconsistent it reboots into recovery, fixes it, and
        // reboots again. With -no-reboot that self-repair becomes a dead VM. A guest that
        // loops shows up in the log; a guest that cannot reboot cannot recover.
        //
        // -d deliberately absent: Android generates a continuous stream of SELinux denials
        // and unimplemented-device accesses, and each one would be formatted by QEMU,
        // written to a pipe, read back and logged -- real work on the thread that also runs
        // the machine.
        notes.append("-no-reboot deliberately absent: Android's own recovery path is a "
                     + "reboot, and forbidding it turns self-repair into a dead VM")

        if request.restoresSnapshot {
            notes.append("restore requested; the machine stamp must match or QEMU refuses")
        }

        return QEMULaunchPlan(arguments: args, environment: [:], notes: notes)
    }
}
