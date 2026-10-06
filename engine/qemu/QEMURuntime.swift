// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVM's VM runtime backend: the only part that needs a device.
//
// STATUS: written in Phase 1, NOT COMPILED and NOT LINKED. It needs the built engine
// dylib, the iOS SDK and a device. The host gate checks only that it parses.
//
// WHAT IT DOES, AND ALL IT DOES
//
//   1. loads the engine dylib
//   2. resolves QEMU's three entry points from the export list
//   3. runs `qemu_init` / `qemu_main_loop` / `qemu_cleanup` on a dedicated thread
//   4. reports honestly whether that worked
//
// Everything else -- what the machine is, whether Android booted, whether the display is
// drawing -- is above this file, in code that can be tested on a laptop. That split is the
// whole point of Phase 1: the untestable surface is kept small enough to read in one
// sitting.

import Foundation
import DroidVMCore
import Darwin

/// A `VMRuntimeBackend` over the engine shared library.
public final class QEMURuntime: VMRuntimeBackend {

    /// The library inside the app bundle.
    public static let libraryName = "libqemu-aarch64-softmmu"

    private var handle: UnsafeMutableRawPointer?
    private var thread: Thread?
    private var plan: QEMULaunchPlan?

    /// Guards the small amount of state the QEMU thread and the caller share.
    private let lock = NSLock()
    private var running = false
    private var started = false

    /// How the engine last exited, once it has. `nil` until then.
    ///
    /// Retained rather than discarded: an exit status is the first thing anyone asks for
    /// when a machine stops on its own, and reconstructing it later is impossible.
    public private(set) var lastExitStatus: Int32?

    /// Called when the machine stops without being asked to. The adapter turns this into a
    /// `run`-stage failure, or not, depending on whether boot had completed.
    public var onUnexpectedExit: ((String) -> Void)?

    public init() {}

    // MARK: VMRuntimeBackend

    public func prepare(plan: QEMULaunchPlan) throws {
        guard handle == nil else {
            throw VMFailureError(VMFailure(
                stage: .preparation,
                reason: "Android could not be prepared.",
                technical: "prepare() called twice on the same runtime"))
        }

        guard let path = Bundle.main.path(forResource: Self.libraryName,
                                          ofType: "dylib") else {
            throw VMFailureError(VMFailure(
                stage: .preparation,
                reason: "Android could not be prepared.",
                technical: "\(Self.libraryName).dylib is not in the app bundle; the "
                         + "packaging step must embed it"))
        }

        // RTLD_NOW, so a missing or renamed symbol fails here with a name in the message
        // rather than at first use inside a vCPU thread.
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            // `dlerror()` returns an implicitly-unwrapped pointer and may legitimately be
            // nil, so it is checked rather than force-unwrapped.
            let cMessage = dlerror()
            let reason = cMessage != nil ? String(cString: cMessage!) : "no reason reported"
            throw VMFailureError(VMFailure(
                stage: .preparation,
                reason: "Android could not be prepared.",
                technical: "dlopen failed: \(reason)"))
        }

        // Resolving the three entry points explicitly is what makes the export list
        // (`system/qemu.symbols`) a checked thing rather than a belief. A symbol missing
        // from that list links perfectly and fails here.
        for symbol in ["qemu_init", "qemu_main_loop", "qemu_cleanup"] {
            if dlsym(handle, symbol) == nil {
                dlclose(handle)
                throw VMFailureError(VMFailure(
                    stage: .preparation,
                    reason: "Android could not be prepared.",
                    technical: "\(symbol) is not exported by \(Self.libraryName).dylib; "
                             + "the engine's export list is incomplete"))
            }
        }

        self.handle = handle
        self.plan = plan
    }

    public func start() throws {
        guard let handle, let plan else {
            throw VMFailureError(VMFailure(
                stage: .launch,
                reason: "Android could not be started.",
                technical: "start() before a successful prepare()"))
        }

        // The argv must stay alive for the whole life of the machine: QEMU keeps the
        // pointers. Copying it into a local array that goes out of scope is a
        // use-after-free that only shows up under load.
        let arguments = [Self.programName] + plan.arguments
        var argv = arguments.map { strdup($0) }
        argv.append(nil)

        guard let qemuInit = Self.resolve(handle, "qemu_init"),
              let qemuMainLoop = Self.resolve(handle, "qemu_main_loop"),
              let qemuCleanup = Self.resolve(handle, "qemu_cleanup") else {
            throw VMFailureError(VMFailure(
                stage: .launch,
                reason: "Android could not be started.",
                technical: "engine entry points vanished between prepare and start"))
        }

        typealias InitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias LoopFn = @convention(c) () -> Int32
        typealias CleanupFn = @convention(c) () -> Void

        let initFn = unsafeBitCast(qemuInit, to: InitFn.self)
        let loopFn = unsafeBitCast(qemuMainLoop, to: LoopFn.self)
        let cleanupFn = unsafeBitCast(qemuCleanup, to: CleanupFn.self)

        let thread = Thread { [weak self] in
            guard let self else {
                for pointer in argv where pointer != nil { free(pointer) }
                return
            }

            let initResult = initFn(Int32(argv.count - 1), &argv)

            var loopResult: Int32 = -1
            if initResult == 0 {
                self.markRunning(true)
                loopResult = loopFn()
                cleanupFn()
            }
            self.markRunning(false)

            for pointer in argv where pointer != nil { free(pointer) }

            // A machine that stopped without being asked is worth reporting; whether it is
            // a failure is decided above, because Android reboots itself on purpose.
            self.reportExit(status: initResult != 0 ? initResult : loopResult,
                            initFailed: initResult != 0)
        }

        thread.name = "droidvm.engine"
        // Darwin propagates QoS to threads a thread creates, and every vCPU is created from
        // this one. Left at the default they read as background work -- CPU-saturated for
        // the guest's whole life -- and get parked on efficiency cores, which on a phone are
        // several times slower than the performance cores. The guest's speed is the app's
        // speed, so this is user-interactive by definition.
        thread.qualityOfService = .userInteractive
        // QEMU's main loop is not shy with stack.
        thread.stackSize = 16 * 1024 * 1024

        lock.lock()
        self.thread = thread
        started = true
        lock.unlock()

        thread.start()
    }

    public func stop() {
        // QEMU exposes no asynchronous stop. The supported route is to ask the guest to
        // shut down and let `qemu_main_loop` return on its own; a hard stop is `exit()`,
        // which is why Phase 1 does not offer one. What this does is refuse to pretend:
        // it records that a stop was requested without claiming the machine has stopped.
        lock.lock()
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { return }

        // A monitor command over the QMP socket, or a guest-side poweroff, arrives in
        // Phase 2. Until then, stopping is the caller's problem and this reports the truth.
        onUnexpectedExit?("stop() requested; the engine has no asynchronous stop in Phase 1")
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: internals

    private static let programName = "droidvm-engine"

    private func markRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }

    private func reportExit(status: Int32, initFailed: Bool) {
        lock.lock()
        lastExitStatus = status
        let wasStarted = started
        started = false
        lock.unlock()

        guard wasStarted else { return }
        onUnexpectedExit?(initFailed
            ? "qemu_init returned \(status)"
            : "qemu_main_loop returned \(status)")
    }

    private static func resolve(_ handle: UnsafeMutableRawPointer,
                                _ name: String) -> UnsafeMutableRawPointer? {
        dlsym(handle, name)
    }

    deinit {
        if let handle { dlclose(handle) }
    }
}
