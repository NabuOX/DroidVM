// SPDX-License-Identifier: GPL-2.0-or-later
//
// C interop harness for the engine bridge.
//
// WHAT THIS PROVES
//
// `DroidVMBridge.h` declares an ABI and `engine/` uses it from Swift. Whether Swift can
// actually consume that ABI is a question only a compiler answers, and it does not need
// Apple frameworks to answer it:
//
//   * whether a plain C `typedef enum` imports as something `==` and `switch` work on
//   * whether a C struct gets a usable memberwise initialiser
//   * whether `size_t` arrives as `Int`, and `uint64_t` as `UInt64`
//   * whether an out-parameter (`droidvm_jit_region *out`) is drivable with `&`
//   * whether the C struct's layout matches the Swift view of it -- the check
//     `MetalDisplaySurface.checkBridgeLayout()` performs at startup, executed for real here
//   * whether `char **` survives the boundary in both directions -- the mechanism
//     `QEMURuntime` uses to hand QEMU its argument vector
//   * whether a function pointer resolved from a library can be called through a
//     `@convention(c)` typealias -- the mechanism `QEMURuntime` uses to reach `qemu_init`
//   * whether `const char *` converts to a `String` the way the error path assumes
//
// It also compiles against the REAL `DroidVMCore`, so constructing a `DisplayCounters` from
// the C struct is exercised exactly as `MetalDisplaySurface` does it.
//
// WHAT IT DOES NOT PROVE
//
// Nothing about QEMU, Metal, the JIT, arm64, the iOS SDK or a device. The C bodies are
// stand-ins returning synthetic values (see bridge_stub.c). This is an ABI harness. It is
// not device verification and must never be reported as such.

import Foundation
import CDroidVMBridge
import DroidVMCore

// Stub-side test seams.
@_silgen_name("droidvm_test_set_reason")
func droidvm_test_set_reason(_ reason: UnsafePointer<CChar>?)

@_silgen_name("droidvm_test_bump_counters")
func droidvm_test_bump_counters(_ entered: UInt64, _ received: UInt64, _ presented: UInt64,
                                _ dropped: UInt64, _ no_scanout: UInt64,
                                _ present_failure: UInt64)

@_silgen_name("droidvm_test_set_serial_bytes")
func droidvm_test_set_serial_bytes(_ bytes: UInt64)

// Stub-side inspection of the argv that crossed the boundary.
@_silgen_name("droidvm_stub_qemu_init_argc")
func droidvm_stub_qemu_init_argc() -> Int32

var checks = 0
var failures = 0

func check(_ condition: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL: \(what())")
    }
}

// The stub exposes its recording globals as C symbols; Swift sees them as mutable globals.
@_silgen_name("g_qemu_init_argc")
var g_qemu_init_argc: Int32

@_silgen_name("g_qemu_init_calls")
var g_qemu_init_calls: Int32

@_silgen_name("g_qemu_main_loop_calls")
var g_qemu_main_loop_calls: Int32

@_silgen_name("g_qemu_cleanup_calls")
var g_qemu_cleanup_calls: Int32

@_silgen_name("g_probe_result")
var g_probe_result: Int32

@_silgen_name("g_capture_result")
var g_capture_result: Int32

@_silgen_name("g_qemu_init_argv0")
var g_qemu_init_argv0: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                        CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                        CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                        CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)

// MARK: - 1. struct layout

func testCounterStructLayout() {
    print("counter struct: does Swift's view match C's?")

    // This is the check the engine performs once at startup and refuses to run without.
    // A mismatch here would produce plausible, wrong numbers rather than a crash, which is
    // worse: they would be believed.
    let swiftSize = MemoryLayout<droidvm_display_counters>.size
    let cSize = Int(droidvm_display_counters_sizeof())
    check(swiftSize == cSize,
          "droidvm_display_counters: Swift sees \(swiftSize) bytes, C reports \(cSize)")

    // Field widths, asserted individually so a partial mismatch is named.
    check(MemoryLayout.size(ofValue: droidvm_display_counters().entered) == 8,
          "entered must be 64-bit")
    check(MemoryLayout.size(ofValue: droidvm_display_counters().presented) == 8,
          "presented must be 64-bit")

    // The memberwise initialiser the engine relies on exists.
    let zero = droidvm_display_counters(entered: 0, received: 0, presented: 0,
                                        dropped: 0, no_scanout: 0, present_failure: 0)
    check(zero.presented == 0, "memberwise init works")
}

// MARK: - 2. counters read path

func testCounterReadPath() {
    print("counters: read the C struct and build a real DisplayCounters")

    droidvm_test_bump_counters(10, 9, 8, 1, 2, 3)

    var raw = droidvm_display_counters()
    droidvm_display_read(&raw)

    check(raw.entered == 10, "entered arrived: \(raw.entered)")
    check(raw.received == 9, "received arrived: \(raw.received)")
    check(raw.presented == 8, "presented arrived: \(raw.presented)")
    check(raw.dropped == 1, "dropped arrived: \(raw.dropped)")
    check(raw.no_scanout == 2, "no_scanout arrived: \(raw.no_scanout)")
    check(raw.present_failure == 3, "present_failure arrived: \(raw.present_failure)")

    // Exactly the mapping MetalDisplaySurface performs.
    let counters = DisplayCounters(entered: raw.entered,
                                   received: raw.received,
                                   presented: raw.presented,
                                   dropped: raw.dropped,
                                   noScanout: raw.no_scanout,
                                   presentFailure: raw.present_failure)

    check(counters.presented == 8, "DisplayCounters carried the value")
    check(counters.hasEverPresented, "and the readiness rule reads correctly")

    // And the classifier consumes it, so the whole path is exercised.
    let cause = StallClassifier.classify(window: counters,
                                         context: DisplayContext(attached: true,
                                                                 hasGraphicsContext: true))
    check(cause == .presented, "a window with frames presented classifies as presented")

    // The six stages stayed distinct across the boundary: this is the rule that a single
    // frame counter cannot express, so it is worth asserting end to end.
    check(counters.entered != counters.received
          && counters.received != counters.presented
          && counters.presented != counters.dropped,
          "the six stages must not be conflated by the bridge")
}

// MARK: - 3. display attachment

func testDisplayAttachment() {
    print("display: attachment flag and one-listener rule")

    check(droidvm_display_is_attached() == 0, "detached to begin with")
    droidvm_display_set_attached(1)
    check(droidvm_display_is_attached() == 1, "attach is visible to C")
    droidvm_display_set_attached(0)
    check(droidvm_display_is_attached() == 0, "detach is visible to C")

    // A second registration must be refused; a second listener would orphan the first
    // surface, which shows up as a frame counter climbing against a black screen.
    let first = droidvm_display_register()
    check(first == 0, "the first registration succeeds")
    let second = droidvm_display_register()
    check(second != 0, "a second registration is refused")
}

// MARK: - 4. C enum import

func testCEnumInterop() {
    print("C enum: comparison and switch over an imported typedef enum")

    // Plain C enums do not arrive as Swift enums; how they behave is exactly the kind of
    // thing that must be checked rather than assumed.
    let ok: droidvm_jit_status = DROIDVM_JIT_OK
    check(ok == DROIDVM_JIT_OK, "equality against a same-named constant")
    check(ok != DROIDVM_JIT_NOT_PERMITTED, "and inequality against a different one")

    // Switch with static-member patterns, which is how the engine dispatches on status.
    func describe(_ status: droidvm_jit_status) -> String {
        switch status {
        case DROIDVM_JIT_OK: return "ok"
        case DROIDVM_JIT_NOT_PERMITTED: return "not permitted"
        case DROIDVM_JIT_ALLOCATION_FAILED: return "allocation failed"
        case DROIDVM_JIT_SELF_TEST_FAILED: return "self test failed"
        case DROIDVM_JIT_ALREADY_HELD: return "already held"
        case DROIDVM_JIT_UNSUPPORTED: return "unsupported"
        default: return "other"
        }
    }

    check(describe(DROIDVM_JIT_OK) == "ok", "switch dispatches on a C enum")
    check(describe(DROIDVM_JIT_SELF_TEST_FAILED) == "self test failed",
          "and reaches a later case")

    // Mapping onto DroidVM's own error type, which is what TrapExecutableMemory does.
    func mapped(_ status: droidvm_jit_status) -> ExecutableMemoryError {
        switch status {
        case DROIDVM_JIT_NOT_PERMITTED: return .notPermitted(reason: "x")
        case DROIDVM_JIT_ALLOCATION_FAILED: return .allocationFailed(reason: "x")
        case DROIDVM_JIT_SELF_TEST_FAILED: return .selfTestFailed(reason: "x")
        case DROIDVM_JIT_UNSUPPORTED: return .unsupportedPlatform(reason: "x")
        default: return .alreadyHeld(regionBytes: 0)
        }
    }
    check(mapped(DROIDVM_JIT_NOT_PERMITTED).isEnvironmentLimitation,
          "a permission refusal maps to an environment limitation")
    check(!mapped(DROIDVM_JIT_SELF_TEST_FAILED).isEnvironmentLimitation,
          "a self-test failure maps to a fault, not an environment limitation")
}

// MARK: - 5. out-parameters and pointer round-trip

func testJITOutParameter() {
    print("jit: out-parameter, pointer round-trip, and the acquire/release lifecycle")

    _ = droidvm_jit_release()
    g_capture_result = 0     // DROIDVM_JIT_OK
    g_probe_result = 0

    var raw = droidvm_jit_region(executable: nil, writable: nil, size: 0)
    let status = droidvm_jit_capture(4096, &raw)

    check(status == DROIDVM_JIT_OK, "capture reported success")
    check(raw.size == 4096, "the out-parameter carried the size back: \(raw.size)")
    check(raw.executable != nil, "the executable view was filled in")
    check(raw.writable != nil, "the writable view was filled in")
    check(raw.executable != raw.writable,
          "the two views must be distinct: the split is the whole technique")

    // The conversion ExecutableRegion performs.
    let region = ExecutableRegion(executableAddress: UInt(bitPattern: raw.executable),
                                  writableAddress: UInt(bitPattern: raw.writable),
                                  size: raw.size)
    check(region.size == 4096, "ExecutableRegion built from the C struct")
    check(region.executableAddress != 0, "and the address survived the round trip")

    // A second capture must be refused rather than leaking the first region.
    var second = droidvm_jit_region(executable: nil, writable: nil, size: 0)
    let refused = droidvm_jit_capture(4096, &second)
    check(refused == DROIDVM_JIT_ALREADY_HELD,
          "a second capture is refused while one is held, got \(refused)")

    _ = droidvm_jit_release()

    // Failure branches, each mapping to a different DroidVM error.
    g_capture_result = 3     // DROIDVM_JIT_SELF_TEST_FAILED
    var third = droidvm_jit_region(executable: nil, writable: nil, size: 0)
    check(droidvm_jit_capture(4096, &third) == DROIDVM_JIT_SELF_TEST_FAILED,
          "the self-test failure branch is reachable")
    g_capture_result = 0
}

// MARK: - 6. const char * to String

func testStringReturn() {
    print("strings: const char * into String, the way the error path reads a reason")

    let reason = "no debugger attached"
    reason.withCString { droidvm_test_set_reason($0) }

    guard let raw = droidvm_jit_last_reason() else {
        return check(false, "droidvm_jit_last_reason returned nil")
    }
    let text = String(cString: raw)
    check(text == reason, "the reason round-tripped: '\(text)'")

    // The empty-string edge, which a naive implementation traps on.
    "".withCString { droidvm_test_set_reason($0) }
    if let empty = droidvm_jit_last_reason() {
        check(String(cString: empty).isEmpty, "an empty reason reads as empty, not a crash")
    }
}

// MARK: - 7. char ** across the boundary, and a function pointer call

func testArgumentVectorAndFunctionPointer() {
    print("argv: build a char ** in Swift, read it back in C, then call through a pointer")

    let arguments = ["droidvm-engine", "-M", "virt", "-smp", "4"]
    var argv = arguments.map { strdup($0) }
    argv.append(nil)

    check(argv.count == arguments.count + 1, "argv is nil-terminated")

    // The exact typealias QEMURuntime uses for a symbol resolved from the library.
    typealias InitFn = @convention(c) (Int32,
                                       UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
        -> Int32
    typealias LoopFn = @convention(c) () -> Int32
    typealias CleanupFn = @convention(c) () -> Void

    // In the engine these come from dlsym; here they are taken directly, which exercises
    // the same typealias and the same call convention.
    let initPtr = unsafeBitCast(qemu_init as InitFn, to: UnsafeMutableRawPointer.self)
    let initFn = unsafeBitCast(initPtr, to: InitFn.self)
    let loopFn = unsafeBitCast(qemu_main_loop as LoopFn, to: LoopFn.self)
    let cleanupFn = unsafeBitCast(qemu_cleanup as CleanupFn, to: CleanupFn.self)

    let initResult = initFn(Int32(argv.count - 1), &argv)
    check(initResult == 0, "qemu_init reported success through the pointer")
    check(g_qemu_init_calls == 1, "and was called once")
    check(g_qemu_init_argc == Int32(arguments.count),
          "argc arrived intact: \(g_qemu_init_argc) vs \(arguments.count)")

    // argv[0] read back out of the C side, which is what makes this a real round trip
    // rather than a call that merely did not crash.
    let argv0 = withUnsafePointer(to: &g_qemu_init_argv0) {
        $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
    }
    check(argv0 == "droidvm-engine", "argv[0] round-tripped: '\(argv0)'")

    let loopResult = loopFn()
    check(loopResult == 0, "qemu_main_loop was called through the pointer")
    cleanupFn()
    check(g_qemu_cleanup_calls == 1, "qemu_cleanup was called through the pointer")

    for pointer in argv where pointer != nil { free(pointer) }
}

// MARK: - 8. serial

func testSerialCounter() {
    print("serial: uint64_t return value")
    droidvm_test_set_serial_bytes(123_456)
    check(droidvm_serial_bytes_written() == 123_456, "a 64-bit return value arrives intact")
}

// MARK: - 9. the real engine adapter

/// `TrapExecutableMemory` is compiled into this harness for real -- it needs only Foundation,
/// DroidVMCore and the bridge header, so the host can compile and exercise it. That makes it
/// the one engine adapter whose *behaviour* is verified outside macOS, against a stand-in C
/// side. What is still unverified for it is the trap itself and `vm_remap`.
func testRealEngineJITAdapter() {
    print("engine: TrapExecutableMemory, the real adapter, against the stand-in C side")

    _ = droidvm_jit_release()
    g_capture_result = 0
    g_probe_result = 0

    let backend = TrapExecutableMemory()

    // The honesty rule: before a capture, "is executable memory available?" has no answer.
    // `OK` from the probe means the mechanism is present, not that a region exists, and
    // reporting `.available` here would be a claim the adapter cannot support.
    let probe = backend.probe()
    check(probe == .unknown,
          "probe before capture must be unknown, got \(probe)")
    check(!probe.isAvailable, "and must not claim availability")

    do {
        let region = try backend.acquire(bytes: 8192)
        check(region.size == 8192, "acquire returned the region")
        check(region.executableAddress != 0 && region.writableAddress != 0,
              "both views have addresses")
        check(region.executableAddress != region.writableAddress,
              "and they are distinct: the split is the technique, not an optimisation")
    } catch {
        check(false, "acquire threw unexpectedly: \(error)")
    }

    // Holding twice must be refused rather than leaking the first region.
    do {
        _ = try backend.acquire(bytes: 8192)
        check(false, "a second acquire should have been refused")
    } catch let error as ExecutableMemoryError {
        if case .alreadyHeld = error {
            check(true, "")
        } else {
            check(false, "expected alreadyHeld, got \(error)")
        }
    } catch {
        check(false, "wrong error type: \(error)")
    }

    backend.release()
    _ = droidvm_jit_release()

    // A self-test failure is a fault, not an environment limitation, and the adapter must
    // classify it correctly -- the distinction decides whether the app sends someone
    // looking for a bug.
    g_capture_result = 3     // DROIDVM_JIT_SELF_TEST_FAILED
    do {
        _ = try TrapExecutableMemory().acquire(bytes: 4096)
        check(false, "acquire should have thrown")
    } catch let error as ExecutableMemoryError {
        if case .selfTestFailed = error {
            check(!error.isEnvironmentLimitation,
                  "a self-test failure must not read as an environment limitation")
            check(!error.plainReason.isEmpty, "and must carry a plain reason")
        } else {
            check(false, "expected selfTestFailed, got \(error)")
        }
    } catch {
        check(false, "wrong error type: \(error)")
    }

    // A permission refusal is an environment limitation.
    g_capture_result = 1     // DROIDVM_JIT_NOT_PERMITTED
    "no debugger attached".withCString { droidvm_test_set_reason($0) }
    do {
        _ = try TrapExecutableMemory().acquire(bytes: 4096)
        check(false, "acquire should have thrown")
    } catch let error as ExecutableMemoryError {
        if case .notPermitted(let reason) = error {
            check(error.isEnvironmentLimitation,
                  "a permission refusal IS an environment limitation")
            check(reason == "no debugger attached",
                  "and the C-side reason must survive into Swift: '\(reason)'")
        } else {
            check(false, "expected notPermitted, got \(error)")
        }
    } catch {
        check(false, "wrong error type: \(error)")
    }

    // A probe that refuses is an environment limitation before anything is attempted.
    g_capture_result = 0
    g_probe_result = 1       // DROIDVM_JIT_NOT_PERMITTED
    if case .unavailable = TrapExecutableMemory().probe() {
        check(true, "")
    } else {
        check(false, "a refusing probe must report unavailable")
    }
    g_probe_result = 0
}

@main
struct BridgeInterop {
    static func main() {
        print("DroidVM engine bridge interop harness")
        print("(ABI and bridging only. No QEMU, no Metal, no device.)")
        print("")

        testCounterStructLayout()
        testCounterReadPath()
        testDisplayAttachment()
        testCEnumInterop()
        testJITOutParameter()
        testStringReturn()
        testArgumentVectorAndFunctionPointer()
        testSerialCounter()
        testRealEngineJITAdapter()

        print("")
        print("\(checks) checks, \(failures) failure(s)")
        print(failures == 0 ? "PASS" : "FAIL")
        exit(failures == 0 ? 0 : 1)
    }
}
