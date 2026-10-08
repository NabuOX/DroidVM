// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host harness for the engine bridge and the native implementation behind it.
//
// WHAT THIS LINKS
//
// The real `engine/native/*.c`, the real `engine/include/DroidVMBridge.h`, the real
// `DroidVMCore` as a separate module, and the real `engine/jit/TrapExecutableMemory.swift`.
// The only stand-in is QEMU's three entry points (tests/cinterop/qemu_shim.c), which cannot
// be present on a host by definition.
//
// So when this passes, DroidVM's own native code has been compiled with -Wall -Wextra
// -Werror and exercised: the six display counters, the process-wide reset, the serial
// saturating counter, the JIT status machine, and the error mapping that turns a C status
// into a product-facing readiness.
//
// WHAT THIS DOES NOT PROVE
//
// Nothing about QEMU, Metal, the JIT trap itself, `vm_remap`, arm64, the iOS SDK or a
// device. On this host the executable-memory mechanism is genuinely absent, and the tests
// assert the *honest* consequence of that rather than faking a success path. The success
// paths for the JIT are covered in the Swift unit tests, where the backend is explicitly a
// simulated double named as such.

import Foundation
import CDroidVMBridge
import CDroidVMNative
import DroidVMCore

// Shim inspection, test-only.
@_silgen_name("droidvm_shim_qemu_init_calls")
func shim_init_calls() -> Int32
@_silgen_name("droidvm_shim_qemu_init_argc")
func shim_init_argc() -> Int32
@_silgen_name("droidvm_shim_qemu_main_loop_calls")
func shim_main_loop_calls() -> Int32
@_silgen_name("droidvm_shim_qemu_cleanup_status")
func shim_cleanup_status() -> Int32

@_silgen_name("droidvm_shim_qemu_init_argv0")
func shim_argv0() -> UnsafePointer<CChar>?
@_silgen_name("droidvm_shim_qemu_init_argv1")
func shim_argv1() -> UnsafePointer<CChar>?
@_silgen_name("droidvm_shim_qemu_reset")
func shim_reset()

var checks = 0
var failures = 0

func check(_ condition: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL: \(what())")
    }
}

// MARK: - 1. ABI: struct layout

func testCounterStructLayout() {
    print("abi: does Swift's view of the counter struct match C's?")

    let swiftSize = MemoryLayout<droidvm_display_counters>.size
    let cSize = Int(droidvm_display_counters_sizeof())
    check(swiftSize == cSize,
          "Swift sees \(swiftSize) bytes, C reports \(cSize)")

    check(MemoryLayout.size(ofValue: droidvm_display_counters().entered) == 8,
          "entered must be 64-bit")
    check(MemoryLayout.size(ofValue: droidvm_display_counters().present_failure) == 8,
          "present_failure must be 64-bit")

    let zero = droidvm_display_counters(entered: 0, received: 0, presented: 0,
                                        dropped: 0, no_scanout: 0, present_failure: 0)
    check(zero.presented == 0, "the memberwise initialiser exists")
}

// MARK: - 2. the six counters, through the real native code

func testSixStagesThroughRealNativeCode() {
    print("counters: drive each of the six stages through the real native API")

    droidvm_native_reset()
    var raw = droidvm_display_counters()
    droidvm_display_read(&raw)
    check(raw.entered == 0 && raw.received == 0 && raw.presented == 0
          && raw.dropped == 0 && raw.no_scanout == 0 && raw.present_failure == 0,
          "a fresh machine starts from all zeroes")

    // Each stage is a separate entry point, so each is driven separately. The counts are
    // all DIFFERENT on purpose: if any two note functions wrote the same counter, the
    // values would collide and the assertions below would catch it. (An earlier version of
    // this test used counts that happened to coincide and then asserted they were distinct,
    // which was a bug in the test rather than in the code.)
    droidvm_display_note_entered()
    droidvm_display_note_entered()
    droidvm_display_note_entered()
    droidvm_display_note_entered()
    droidvm_display_note_entered()
    droidvm_display_note_received()
    droidvm_display_note_presented()
    droidvm_display_note_presented()
    droidvm_display_note_dropped()
    droidvm_display_note_dropped()
    droidvm_display_note_dropped()
    droidvm_display_note_no_scanout()
    droidvm_display_note_no_scanout()
    droidvm_display_note_no_scanout()
    droidvm_display_note_no_scanout()
    droidvm_display_note_present_failure()
    droidvm_display_note_present_failure()
    droidvm_display_note_present_failure()
    droidvm_display_note_present_failure()
    droidvm_display_note_present_failure()
    droidvm_display_note_present_failure()

    droidvm_display_read(&raw)
    check(raw.entered == 5, "entered: \(raw.entered)")
    check(raw.received == 1, "received: \(raw.received)")
    check(raw.presented == 2, "presented: \(raw.presented)")
    check(raw.dropped == 3, "dropped: \(raw.dropped)")
    check(raw.no_scanout == 4, "no_scanout: \(raw.no_scanout)")
    check(raw.present_failure == 6, "present_failure: \(raw.present_failure)")

    // The whole point: no two stages shared a counter. If `dropped` and `no_scanout` had
    // been the same field, both would read 7 here.
    let values = [raw.entered, raw.received, raw.presented,
                  raw.dropped, raw.no_scanout, raw.present_failure]
    check(Set(values).count == 6,
          "all six stages must be separately observable, got \(values)")
    check(values.reduce(0, +) == 21,
          "and every increment landed somewhere: total \(values.reduce(0, +))")

    // And the portable classifier consumes it, so the C side and the Swift rules agree.
    let counters = DisplayCounters(entered: raw.entered, received: raw.received,
                                   presented: raw.presented, dropped: raw.dropped,
                                   noScanout: raw.no_scanout,
                                   presentFailure: raw.present_failure)
    check(counters.hasEverPresented, "the readiness rule reads the real counters")
    let cause = StallClassifier.classify(
        window: counters,
        context: DisplayContext(attached: true, hasGraphicsContext: true))
    check(cause == .presented, "a window that presented classifies as presented")

    // A window of pure guest silence is not a stall.
    droidvm_native_reset()
    droidvm_display_note_entered()
    droidvm_display_note_no_scanout()
    droidvm_display_read(&raw)
    let silent = DisplayCounters(entered: raw.entered, received: raw.received,
                                 presented: raw.presented, dropped: raw.dropped,
                                 noScanout: raw.no_scanout,
                                 presentFailure: raw.present_failure)
    check(StallClassifier.classify(
            window: silent,
            context: DisplayContext(attached: true, hasGraphicsContext: true)) == .noScanout,
          "asked to draw with nothing to draw is noScanout, not a drop")
}

// MARK: - 3. reset is process-wide

func testResetIsComplete() {
    print("reset: a second machine must not inherit the first machine's counters")

    droidvm_display_note_entered()
    droidvm_display_note_presented()
    droidvm_display_set_attached(1)
    droidvm_serial_note_bytes(4096)

    droidvm_native_reset()

    var raw = droidvm_display_counters()
    droidvm_display_read(&raw)
    check(raw.entered == 0 && raw.presented == 0, "display counters cleared")
    check(droidvm_display_is_attached() == 0, "attachment cleared")
    check(droidvm_serial_bytes_written() == 0, "serial counter cleared")
}

// MARK: - 4. attachment and registration

func testAttachmentAndRegistration() {
    print("display: attachment flag, and registration refusing a second listener")

    droidvm_native_reset()
    check(droidvm_display_is_attached() == 0, "detached to begin with")

    droidvm_display_set_attached(1)
    check(droidvm_display_is_attached() == 1, "attach is visible to C")

    // On this host the build has no QEMU, so registration must report *that* -- not
    // "already registered", which would be a different and misleading diagnosis.
    let code = droidvm_display_register()
    check(code == 2, "a build without the engine reports code 2, got \(code)")

    if let reason = droidvm_display_last_reason() {
        let text = String(cString: reason)
        check(text.contains("DROIDVM_WITH_QEMU"),
              "and the reason names how to fix it: '\(text)'")
    } else {
        check(false, "droidvm_display_last_reason returned nil")
    }

    droidvm_display_set_attached(0)
    check(droidvm_display_is_attached() == 0, "detach is visible to C")
    if let reason = droidvm_display_last_reason() {
        check(String(cString: reason).contains("detached"),
              "losing the surface records a reason")
    }
}

// MARK: - 5. serial saturates rather than wrapping

func testSerialSaturates() {
    print("serial: saturating counter, because wrapping would read as silence")

    droidvm_serial_reset()
    droidvm_serial_note_bytes(1000)
    check(droidvm_serial_bytes_written() == 1000, "counts normally")

    droidvm_serial_note_bytes(500)
    check(droidvm_serial_bytes_written() == 1500, "and accumulates")

    // A large value added to a zeroed counter is stored exactly. (Starting from a non-zero
    // total here would itself overflow, which is what an earlier version of this test got
    // wrong -- the test was broken, not the counter.)
    droidvm_serial_reset()
    droidvm_serial_note_bytes(UInt64.max - 10)
    check(droidvm_serial_bytes_written() == UInt64.max - 10,
          "a large non-overflowing value is stored exactly")

    droidvm_serial_note_bytes(1000)
    check(droidvm_serial_bytes_written() == UInt64.max,
          "and overflow saturates at the maximum rather than wrapping to zero, which "
          + "would make a chatty guest look silent")

    droidvm_serial_reset()
    check(droidvm_serial_bytes_written() == 0, "reset works")
}

// MARK: - 6. C enum interop and the JIT status machine

func testCEnumAndJITStatus() {
    print("jit: C enum interop, and the honest answer on a host with no mechanism")

    let ok: droidvm_jit_status = DROIDVM_JIT_OK
    check(ok == DROIDVM_JIT_OK, "equality against a same-named constant")
    check(ok != DROIDVM_JIT_UNSUPPORTED, "and inequality against a different one")

    func describe(_ s: droidvm_jit_status) -> String {
        switch s {
        case DROIDVM_JIT_OK: return "ok"
        case DROIDVM_JIT_NOT_PERMITTED: return "not permitted"
        case DROIDVM_JIT_ALLOCATION_FAILED: return "allocation failed"
        case DROIDVM_JIT_SELF_TEST_FAILED: return "self test failed"
        case DROIDVM_JIT_ALREADY_HELD: return "already held"
        case DROIDVM_JIT_UNSUPPORTED: return "unsupported"
        case DROIDVM_JIT_DIAGNOSTIC_STOP: return "diagnostic stop"
        default: return "other"
        }
    }
    check(describe(DROIDVM_JIT_UNSUPPORTED) == "unsupported",
          "switch dispatches on a C enum")

    // STATUS 6 CROSSES THE ABI, and a wrong mapping would compile and pass every other host test --
    // then report a deliberate diagnostic stop as an allocation or execution failure on a device.
    let diagnostic = TrapExecutableMemory.error(for: DROIDVM_JIT_DIAGNOSTIC_STOP)
    if case .diagnosticStop = diagnostic {
        check(true, "status 6 maps to a diagnostic stop")
    } else {
        check(false, "status 6 did not map to a diagnostic stop: \(diagnostic)")
    }
    if case .selfTestFailed = diagnostic {
        check(false, "status 6 must not claim an execution was attempted")
    } else {
        check(true, "status 6 does not claim an execution was attempted")
    }

    // This host genuinely has no executable-memory mechanism, so the platform test must say
    // so rather than claiming availability it cannot honour.
    check(droidvm_jit_platform_supported() == 0,
          "the development host is not a supported platform, and says so")
    let probe = droidvm_jit_probe()
    check(probe == DROIDVM_JIT_UNSUPPORTED,
          "probe reports unsupported rather than pretending, got \(describe(probe))")

    // Capture must refuse for the same reason, not fail with an allocation error -- those
    // map to different DroidVM errors and therefore to different user-facing outcomes.
    var region = droidvm_jit_region(executable: nil, writable: nil, size: 0)
    let captured = droidvm_jit_capture(4096, &region)
    check(captured == DROIDVM_JIT_UNSUPPORTED,
          "capture reports unsupported, got \(describe(captured))")
    check(region.size == 0, "and writes nothing into the out-parameter on failure")

    // A null out-parameter is a caller bug and is refused, not dereferenced.
    let nullOut = droidvm_jit_capture(4096, nil)
    check(nullOut == DROIDVM_JIT_ALLOCATION_FAILED,
          "a null out-parameter is refused rather than crashing")

    // Zero bytes is refused too: a zero-length region cannot be self-tested.
    var zeroRegion = droidvm_jit_region(executable: nil, writable: nil, size: 0)
    check(droidvm_jit_capture(0, &zeroRegion) == DROIDVM_JIT_ALLOCATION_FAILED,
          "zero bytes is refused")

    // Release with nothing held is not an error.
    check(droidvm_jit_release() == DROIDVM_JIT_OK, "releasing nothing succeeds")

    if let reason = droidvm_jit_last_reason() {
        check(!String(cString: reason).isEmpty, "a reason is always available")
    }
}

// MARK: - 7. the real Swift adapter, over the real native code

func testRealAdapterOverRealNativeCode() async {
    print("adapter: TrapExecutableMemory + JITManager over the real C, on a host")

    let backend = TrapExecutableMemory()

    // The adapter must translate "unsupported platform" into an environment limitation,
    // which is the distinction that decides whether the app sends someone hunting a bug.
    do {
        _ = try backend.acquire(bytes: 4096)
        check(false, "acquire should have thrown on a host with no mechanism")
    } catch let error as ExecutableMemoryError {
        if case .unsupportedPlatform(let reason) = error {
            check(error.isEnvironmentLimitation,
                  "an unsupported platform is an environment limitation, not a fault")
            check(!reason.isEmpty, "and carries the C-side reason: '\(reason)'")
        } else {
            check(false, "expected unsupportedPlatform, got \(error)")
        }
    } catch {
        check(false, "wrong error type: \(error)")
    }

    check(backend.probe() == .unavailable(reason: "no executable-memory mechanism on this "
                                          + "platform (build targets arm64-apple-ios)")
          || !backend.probe().isAvailable,
          "probe does not claim availability")

    // And the manager above it: the product-facing outcome is `unavailable`, with a plain
    // reason -- not `failed`. Nothing is broken; the platform simply cannot do it.
    let recorder = DiagnosticsRecorder()
    let ring = RingBufferSink()
    recorder.add(ring)
    let manager = JITManager(backend: backend, requestedBytes: 1 << 20, recorder: recorder)

    let readiness = await manager.prepareRuntime()
    if case .unavailable(let why) = readiness {
        check(readiness.isActionableByUser, "unavailable is actionable by the user")
        check(!why.contains("vm_remap") && !why.contains("errno"),
              "the product-facing reason must be plain language, got '\(why)'")
    } else {
        check(false, "expected .unavailable on a host, got \(readiness)")
    }

    // The technical detail is retained separately, for diagnostics only.
    check(manager.technicalDetail.contains("unsupported")
          || manager.technicalDetail.contains("attempts="),
          "technical detail is kept out of the product state: '\(manager.technicalDetail)'")

    // The failure is in the stream, with a machine-readable reason.
    let names = ring.contents.compactMap { line -> String? in
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return o["event"] as? String
    }
    check(names.contains("runtime_prepare_started"), "the attempt is recorded: \(names)")
    check(names.contains("runtime_failed"), "and so is the outcome")
}

// MARK: - 8. strings and the argument vector

func testStringsAndArgumentVector() {
    print("strings and argv: across the boundary in both directions")

    // const char * -> String.
    droidvm_native_reset()
    if let reason = droidvm_display_last_reason() {
        check(String(cString: reason) == "display state reset",
              "the known reason round-trips: '\(String(cString: reason))'")
    } else {
        check(false, "droidvm_display_last_reason returned nil")
    }

    // char ** in, read back out of C. The typealias matches QEMURuntime's.
    shim_reset()
    // Matches QEMURuntime's typealias and QEMU's own declarations.
    typealias InitFn = @convention(c) (Int32,
                                       UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
        -> Void
    typealias LoopFn = @convention(c) () -> Int32
    typealias CleanupFn = @convention(c) (Int32) -> Void

    let arguments = ["droidvm-engine", "-M", "virt", "-smp", "4"]
    var argv = arguments.map { strdup($0) }
    argv.append(nil)

    let initFn = unsafeBitCast(qemu_init as InitFn, to: InitFn.self)
    let loopFn = unsafeBitCast(qemu_main_loop as LoopFn, to: LoopFn.self)
    let cleanupFn = unsafeBitCast(qemu_cleanup as CleanupFn, to: CleanupFn.self)

    // No result to assert: qemu_init returns void, so the call and the argc/argv are the evidence.
    initFn(Int32(argv.count - 1), &argv)
    check(shim_init_calls() == 1, "qemu_init was called once through a pointer")
    check(shim_init_argc() == Int32(arguments.count),
          "argc arrived intact: \(shim_init_argc())")

    if let p = shim_argv0() { check(String(cString: p) == "droidvm-engine", "argv[0]")
    } else { check(false, "argv[0] nil") }
    if let p = shim_argv1() { check(String(cString: p) == "-M", "argv[1]")
    } else { check(false, "argv[1] nil") }

    check(loopFn() == 0, "qemu_main_loop through a pointer")
    check(shim_main_loop_calls() == 1, "counted")
    cleanupFn(7)
    check(shim_cleanup_status() == 7,
          "qemu_cleanup's status argument arrived: \(shim_cleanup_status())")

    for p in argv where p != nil { free(p) }
}

@main
struct BridgeInterop {
    static func main() async {
        print("DroidVM engine bridge + native harness")
        print("(real native C and the real Swift adapters; QEMU's entry points are shims)")
        print("")

        testCounterStructLayout()
        testSixStagesThroughRealNativeCode()
        testResetIsComplete()
        testAttachmentAndRegistration()
        testSerialSaturates()
        testCEnumAndJITStatus()
        await testRealAdapterOverRealNativeCode()
        testStringsAndArgumentVector()

        print("")
        print("\(checks) checks, \(failures) failure(s)")
        print(failures == 0 ? "PASS" : "FAIL")
        exit(failures == 0 ? 0 : 1)
    }
}
