// SPDX-License-Identifier: GPL-2.0-or-later
//
// Level D: the Swift -> C bridge probe.
//
// WHAT "native_bridge: PASS" IS ALLOWED TO MEAN
//
// The acceptance criterion says the bridge must be *exercised* on device and return a real
// status. Calling any C function and reporting "it did not crash" would satisfy neither word.
//
// So the probe checks something that can actually be wrong: **the counter struct's layout, as
// C sees it, against the layout Swift has compiled against.** `droidvm_display_counters_sizeof()`
// is answered by the C implementation; `MemoryLayout<droidvm_display_counters>.size` is answered
// by clang from the header. If the two disagree, every counter DroidVM reads is being read out
// of the wrong offsets -- and the failure mode is not a crash, it is plausible wrong numbers,
// which is worse because they get believed.
//
// That makes this a real cross-language check with a real failure mode, and it is why a
// mismatch is reported as `native_bridge: FAIL` rather than logged and ignored.
//
// The JIT status is read too, because it is the one other C entry point that answers a question
// rather than performing an action, and reading it proves the enum's values survive the
// crossing.

import Foundation
import DroidVMCore

#if canImport(CDroidVMBridge)
// Host builds arrive as a Clang module; on iOS the same declarations come through the target's
// SWIFT_OBJC_BRIDGING_HEADER and this import is skipped. Same shape as TrapExecutableMemory.
import CDroidVMBridge
#endif

/// DroidVM's `NativeBridgeProbing`, over the real C bridge.
///
/// `@unchecked Sendable`, with the reason stated: this type has no stored properties at all,
/// so there is no state to race on. The attribute is needed only because `Sendable` on a class
/// is never inferred, even for one that is empty.
public final class DroidVMNativeBridgeProbe: NativeBridgeProbing, @unchecked Sendable {

    public init() {}

    public func probe() async -> NativeBridgeStatus {

        // 1. The struct layout, from both sides of the boundary.
        let cSize = Int(droidvm_display_counters_sizeof())
        let swiftSize = MemoryLayout<droidvm_display_counters>.size

        guard cSize == swiftSize else {
            return NativeBridgeStatus(
                ok: false,
                detail: "counter layout mismatch: C reports \(cSize) bytes, Swift compiled "
                      + "against \(swiftSize). Reading counters would return wrong values.")
        }

        // A size of zero would also "match" and would mean the symbol did not resolve to the
        // real object. Refused explicitly rather than treated as agreement.
        guard cSize > 0 else {
            return NativeBridgeStatus(
                ok: false,
                detail: "droidvm_display_counters_sizeof() returned 0; the bridge symbol did "
                      + "not resolve to the engine's object")
        }

        // 2. An enum across the boundary. `droidvm_jit_probe()` is non-destructive by contract,
        // and its status is the same vocabulary the JIT path uses, so a wrong value here would
        // mean the enum mapping is broken before any real work is attempted.
        let jitStatus = droidvm_jit_probe()
        let known: [droidvm_jit_status] = [
            DROIDVM_JIT_OK, DROIDVM_JIT_NOT_PERMITTED, DROIDVM_JIT_ALLOCATION_FAILED,
            DROIDVM_JIT_SELF_TEST_FAILED, DROIDVM_JIT_ALREADY_HELD, DROIDVM_JIT_UNSUPPORTED,
        ]
        guard known.contains(jitStatus) else {
            return NativeBridgeStatus(
                ok: false,
                detail: "droidvm_jit_probe() returned an unknown status (\(jitStatus.rawValue)); "
                      + "the enum mapping across the bridge is wrong")
        }

        let reason = Self.reason()

        return NativeBridgeStatus(
            ok: true,
            detail: "counters \(cSize) bytes agree; jit status \(jitStatus.rawValue)\(reason)")
    }

    /// The engine's own reason string, if it has one.
    ///
    /// A null pointer is not a failure -- most of the time there is no reason to give -- so it
    /// is reported as an absence rather than turned into an error.
    private static func reason() -> String {
        guard let cString = droidvm_jit_last_reason() else { return "" }
        let text = String(cString: cString)
        return text.isEmpty ? "" : " (\(text))"
    }
}

// MARK: - Runtime confirmation

/// DroidVM's `RuntimeConfirming`, over what the bridge can honestly say today.
///
/// IT CANNOT CONFIRM, AND IT SAYS SO.
///
/// The question is "has QEMU's execution path entered its running state?" No symbol in the
/// current bridge answers it. `droidvm_display_is_attached()` reports whether a surface is
/// attached; the `droidvm_jit_*` calls report executable memory. Neither reports that
/// `qemu_main_loop` is executing.
///
/// Answering it needs a marker published from *inside* the engine -- a QEMU-side hook that
/// records main-loop entry, and a bridge symbol that reads it back. That hook does not exist.
/// Returning `.running` here without it would make every Level D result meaningless, so this
/// returns `.unavailable`, and the coordinator turns that into a failure at the
/// `runtime_confirmation_unavailable` stage.
///
/// The display-attachment read is real C and is included so the failure carries an actual
/// observation rather than a bare assertion.
public final class DroidVMRuntimeConfirmation: RuntimeConfirming, @unchecked Sendable {

    /// The engine image to ask. The SAME instance the adapter runs on, so the state read here is
    /// the state the loop writes -- one owner, one copy.
    private let provider: RuntimeStateProviding

    public init(provider: RuntimeStateProviding) {
        self.provider = provider
    }

    /// Ask the engine, polling until it answers or the deadline passes.
    ///
    /// The mapping is `DroidVMRuntimeState`'s, in DroidVMCore, where it is tested without a
    /// device. This type only supplies the engine and the clock.
    public func confirmRunning(timeout: TimeInterval) async -> RuntimeConfirmation {
        await confirmRuntime(using: provider, timeout: timeout)
    }
}
