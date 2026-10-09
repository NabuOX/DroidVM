// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVM's executable-memory backend: the trap protocol, and two views of one mapping.
//
// STATUS: written in Phase 1, NOT COMPILED and NOT RUN. It needs Apple's `vm_remap` and a
// real device to test. The host gate checks only that the file parses; nothing here is
// verified by it. See the Phase 1 report for the level-by-level status.
//
// WHY A TRAP, AND WHY THIS IS THE HARDEST PART OF THE PROJECT
//
// iOS will not give a third-party app a mapping that is both writable and executable. So
// translated code and the translator that produces it need two views of the same pages: one
// executable, one writable. Only a debugger can create the executable view, and it is asked
// for it by executing a trap instruction with a command number in x16.
//
// Two consequences shape everything here:
//
//   * The region must be captured EARLY, while the helper is still attached and listening.
//     Capturing late, or twice, is a race the debugger does not lose gracefully.
//
//   * Success must be CHECKED, not inferred. A region can come back mapped and still be
//     unusable, and the flag that says "we have executable memory" must not be set before
//     something has actually executed in it. The reference implementation set that flag
//     first and cleared it never, which converts a real failure into a mystery.

import Foundation
import DroidVMCore

#if canImport(CDroidVMBridge)
// Host builds: the engine bridge arrives as a Clang module, which is what lets this file
// be compiled and its ABI exercised without macOS. On iOS the same declarations arrive
// through the target's SWIFT_OBJC_BRIDGING_HEADER, `canImport` is false, and nothing here
// is compiled. The condition exists so that one file can be verified in both worlds; it
// changes nothing about the iOS build.
import CDroidVMBridge
#endif

/// DroidVM's `ExecutableMemoryBackend`.
///
/// Wraps the C implementation. The Swift side owns the state machine, the diagnostics and
/// the product-facing status; this owns the mechanism.
public final class TrapExecutableMemory: ExecutableMemoryBackend {

    private var held: ExecutableRegion?

    public init() {}

    public func probe() -> JITAvailability {
        switch droidvm_jit_probe() {
        case DROIDVM_JIT_OK:
            // "OK" here means the mechanism is present, not that a region exists. The
            // honest answer to "is executable memory available" before capture is
            // `unknown`, because capture is what decides it.
            return .unknown
        case DROIDVM_JIT_NOT_PERMITTED:
            return .unavailable(reason: Self.reason())
        case DROIDVM_JIT_UNSUPPORTED:
            return .unavailable(reason: Self.reason())
        default:
            return .unknown
        }
    }

    public func acquire(bytes: Int) throws -> ExecutableRegion {
        if let held {
            throw ExecutableMemoryError.alreadyHeld(regionBytes: held.size)
        }

        var raw = droidvm_jit_region(executable: nil, writable: nil, size: 0)
        let status = droidvm_jit_capture(bytes, &raw)

        guard status == DROIDVM_JIT_OK else {
            throw Self.error(for: status)
        }

        // The C side performs the execute self-test before returning OK. Reaching here means
        // something ran in the region, so this is the first point at which "we have
        // executable memory" is a fact rather than a hope.
        let region = ExecutableRegion(executableAddress: UInt(bitPattern: raw.executable),
                                      writableAddress: UInt(bitPattern: raw.writable),
                                      size: raw.size)
        held = region
        return region
    }

    /// Reads the bring-up stages the C layer recorded, so the report can name each one.
    public var bringUp: BringUpStages? {
        var raw = droidvm_bringup_report()
        droidvm_jit_bringup_report_get(&raw)

        func stage(_ s: droidvm_bringup_stage) -> BringUpStages.Stage {
            if s.not_run != 0 { return .notRun }
            return s.passed != 0 ? .passed : .failed
        }
        return BringUpStages(providerPrepare: stage(raw.provider_prepare),
                             providerRange: stage(raw.provider_range),
                             rwAlias: stage(raw.rw_alias),
                             readback: stage(raw.readback),
                             jitSelfTest: stage(raw.jit_selftest))
    }

    public func release() {
        guard held != nil else { return }
        _ = droidvm_jit_release()
        held = nil
    }

    // MARK: status mapping
    //
    // The C layer knows *what* happened; this decides whether it is an environment
    // limitation or a fault. That distinction is what decides whether the user is told
    // "this device is not supported" or "something went wrong".

    /// Internal, not private, so the host interop harness can assert the mapping of every status
    /// value that crosses the C ABI. A mapping mistake here compiles and passes every other test.
    static func error(for status: droidvm_jit_status) -> ExecutableMemoryError {
        let reason = Self.reason()
        switch status {
        case DROIDVM_JIT_NOT_PERMITTED:
            return .notPermitted(reason: reason)
        case DROIDVM_JIT_ALLOCATION_FAILED:
            return .allocationFailed(reason: reason)
        case DROIDVM_JIT_SELF_TEST_FAILED:
            return .selfTestFailed(reason: reason)
        case DROIDVM_JIT_ALREADY_HELD:
            return .alreadyHeld(regionBytes: 0)
        case DROIDVM_JIT_UNSUPPORTED:
            return .unsupportedPlatform(reason: reason)
        case DROIDVM_JIT_DIAGNOSTIC_STOP:
            // NOT selfTestFailed: that means "mapped but cannot execute", and claiming an execution
            // failure for a run that deliberately did not execute is a false reason.
            return .diagnosticStop(reason: reason)
        default:
            return .allocationFailed(reason: reason)
        }
    }

    private static func reason() -> String {
        guard let cString = droidvm_jit_last_reason() else { return "no reason reported" }
        return String(cString: cString)
    }
}
