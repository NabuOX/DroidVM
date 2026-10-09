// SPDX-License-Identifier: GPL-2.0-or-later
//
// Level D: the engine-run state model, and the device report that proves it.
//
// WHY THIS IS NOT `LifecycleState`
//
// `LifecycleState` answers "is Android usable?", and its rungs above `startingVM` --
// `bootingAndroid`, `waitingForSystemUI`, `waitingForLauncher` -- are questions about a guest
// that is already executing. Level D asks a strictly smaller question: **did the engine
// start?** Android has not booted, no frame has been drawn, and no service is up.
//
// Folding Level D into the lifecycle would mean `startingVM` had to stand for "engine running,
// Android absent", and the first thing that buys is a lie: `bootingAndroid` would be reached
// by a machine that has not executed a single guest instruction. So Level D has its own state
// and its own terminal value, and `EngineRunState` never reaches anything resembling "Android
// is ready". That absence is enforced by test.
//
// NO STATE ADVANCES ON A CLOCK. Every transition here is caused by a value that came back
// from the engine, the runtime provider, the native bridge or the display. There is no timer
// in this file and none anywhere it is driven from.

import Foundation

// MARK: - Failure

/// Why the engine did not start. Typed, because the stage is the diagnosis.
public struct EngineRunFailure: Equatable, Sendable {

    /// Where the start path stopped. Ordered as the path runs.
    public enum Stage: String, Equatable, Sendable, CaseIterable {
        /// Executable memory could not be obtained.
        case jit
        /// The Swift -> C bridge did not answer correctly on this device.
        case nativeBridge = "native_bridge"
        /// The machine definition could not be built or staged.
        case enginePrepare = "engine_prepare"
        /// The engine was asked to start and refused.
        case engineStart = "engine_start"
        /// The engine accepted the request but did not confirm it is running.
        case engineConfirm = "engine_confirm"
        /// The engine did not confirm within the bounded wait.
        ///
        /// Separate from `engineConfirm`, because "it said no" and "it never said anything"
        /// are different diagnoses and the second one is what a hang looks like from here.
        case engineConfirmTimeout = "engine_confirm_timeout"
        /// The display did not attach within the bounded wait.
        case displayAttachTimeout = "display_attach_timeout"
        /// There is no mechanism to ask the engine whether it is executing.
        ///
        /// This is NOT a pass. A build in which the question cannot be asked cannot answer it,
        /// and Level D requires the answer.
        case runtimeConfirmationUnavailable = "runtime_confirmation_unavailable"
        /// The display path could not be brought up.
        case display
    }

    public var stage: Stage

    /// For the user. Plain language, and the same rule as the lifecycle: no mechanism.
    public var reason: String

    /// For the log and for the device report. May name the mechanism.
    public var technical: String

    public init(stage: Stage, reason: String, technical: String) {
        self.stage = stage
        self.reason = reason
        self.technical = technical
    }
}

// MARK: - State

/// Where the Level D start path is.
///
/// Terminal values are `engineStarted`, `displayReady` and `failed`. `engineStarted` is
/// reachable ONLY from a confirmation the engine itself returned -- see
/// `EngineRunCoordinator.confirmRunning()`.
public enum EngineRunState: Equatable, Sendable {

    case idle
    case preparing
    case checkingJIT
    case startingEngine

    /// The engine confirmed it is running. THIS is Level D's success value: it says the
    /// machine is executing, and it says nothing whatever about Android.
    case engineStarted

    /// The engine is running and the display path reported itself attached.
    case displayReady

    case failed(EngineRunFailure)

    /// What a non-technical person is shown.
    ///
    /// Deliberately free of mechanism, and a test enforces that: the user is never told about
    /// JIT, QEMU, Metal, a renderer or a bridge. `checkingJIT` is the developer-facing name of
    /// the state; the person holding the phone is told "Checking…", exactly as
    /// `LifecycleState.checkingRuntime` already does.
    public var consumerLabel: String {
        switch self {
        case .idle:           return "Ready"
        case .preparing:      return "Preparing…"
        case .checkingJIT:    return "Checking…"
        case .startingEngine: return "Starting engine…"
        case .engineStarted:  return "Engine started"
        case .displayReady:   return "Engine started"
        case .failed:         return "Failed"
        }
    }

    /// The exact state name, for the Diagnostics section only.
    ///
    /// Kept apart from `consumerLabel` on purpose. The brief's mock UI says "Checking JIT…",
    /// and the project's standing rule says a user is never shown that word. Both are served
    /// by having two labels rather than by weakening one of them.
    public var diagnosticLabel: String {
        switch self {
        case .idle:           return "idle"
        case .preparing:      return "preparing"
        case .checkingJIT:    return "checkingJIT"
        case .startingEngine: return "startingEngine"
        case .engineStarted:  return "engineStarted"
        case .displayReady:   return "displayReady"
        case .failed(let f):  return "failed(\(f.stage.rawValue))"
        }
    }

    /// Whether the engine has been confirmed running. The only thing Level D claims.
    public var engineIsRunning: Bool {
        self == .engineStarted || self == .displayReady
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var failure: EngineRunFailure? {
        if case .failed(let f) = self { return f }
        return nil
    }

    /// A settled end state. A failed run is settled; so is a successful one.
    public var isTerminal: Bool {
        switch self {
        case .engineStarted, .displayReady, .failed: return true
        case .idle, .preparing, .checkingJIT, .startingEngine: return false
        }
    }

    /// Whether the state is one the path is still moving through.
    ///
    /// The UI uses this to decide whether to keep showing a spinner. Because it is derived
    /// from the state and not from a timer, a path that stops moving also stops spinning --
    /// there is no arrangement of this code in which a spinner outlives the run.
    public var isInProgress: Bool {
        switch self {
        case .preparing, .checkingJIT, .startingEngine: return true
        case .idle, .engineStarted, .displayReady, .failed: return false
        }
    }
}

// MARK: - Device report

/// The deterministic, human-readable device report.
///
/// One value, one `rendered` text, fixed field order. It exists so that "it seemed to work on
/// my phone" is never the evidence: the report can be read, pasted into a commit message or
/// diffed between two runs.
///
/// WHAT `result` MEANS, EXACTLY
///
/// `result` is **computed, not stored**, so no caller can set it. It is PASS when the app
/// launched, the runtime path ran, the native bridge answered, the engine definition was
/// accepted and the engine confirmed it was running -- with no crash. That is the whole claim.
///
/// It is deliberately NOT gated on `displayInit`. The brief requires the display result to be
/// *recorded*, and recording is what happens: a display that did not attach appears as
/// `display_init: FAIL` beside a `result` that describes the engine. Conflating the two would
/// mean either overclaiming the display or refusing to report an engine that genuinely
/// started.
///
/// There is no field here for Android, and a test asserts that. `result: PASS` says the engine
/// started on a real device. It does not say a guest booted, that anything was drawn, or that
/// a single instruction of Android ran.
public struct EngineRunReport: Equatable, Sendable {

    public enum Verdict: String, Equatable, Sendable {
        case pass = "PASS"
        case fail = "FAIL"
        case notRun = "NOT RUN"
    }

    /// The three outcomes the brief asks for, plus "we did not get that far".
    ///
    /// `unavailable` and `failed` are NOT the same and must never be collapsed. `unavailable`
    /// is the environment declining -- typically no debugger is attached -- and is not a DroidVM
    /// fault. `failed` is an attempt that did not work. `notProbed` is neither, and is not a
    /// negative result.
    public enum JITState: String, Equatable, Sendable {
        case notProbed = "NOT RUN"
        case ready = "READY"
        case unavailable = "UNAVAILABLE"
        case failed = "FAILED"
    }

    public var appLaunch: Verdict = .notRun
    public var runtimeController: Verdict = .notRun
    /// The bring-up stages, in the order they run.
    ///
    /// One `jit:` verdict could not distinguish a rejected range from a failed readback from a stub
    /// that faulted, and telling those apart is the entire point of a single consolidated device
    /// test. `notRun` means the pipeline never reached the stage, which is different from reaching it
    /// and failing.
    public var providerPrepare: Verdict = .notRun
    public var providerRange: Verdict = .notRun
    public var rwAlias: Verdict = .notRun
    public var readback: Verdict = .notRun
    public var jitSelfTest: Verdict = .notRun

    /// Android guest readiness. `notRun` until the engine and display are alive AND the guest
    /// monitor has been asked -- a guest that was never observed is not an unready guest.
    public var androidGuest: Verdict = .notRun

    public var jit: JITState = .notProbed
    public var jitReason: String?
    public var nativeBridge: Verdict = .notRun
    public var qemuInit: Verdict = .notRun
    public var qemuStarted: Verdict = .notRun
    public var displayInit: Verdict = .notRun

    /// `crash: NO` means this process was still executing when the report was written.
    ///
    /// That is the most a process can honestly say about itself: it cannot observe its own
    /// death. Stated here rather than implied, because "crash: NO" reads stronger than it is.
    public var crashed: Bool = false

    /// The user-safe reason, when there is one.
    public var failureReason: String?

    /// Which stage stopped the run, in the report's own vocabulary.
    public var failureStage: String?

    /// Where the stop happened, and any detail worth keeping. Not shown to a user.
    public var technicalDetail: String?

    /// What the ENGINE's display listener observed, gathered from the QEMU dylib rather than from
    /// Swift bookkeeping.
    ///
    /// GEOMETRY IS OPTIONAL BECAUSE "NO SURFACE YET" IS NOT "A 0x0 SURFACE". A zero reads as a real
    /// measurement and cannot be told apart from an engine whose guest is drawing nothing, so `nil`
    /// -- rendered as `-`, encoded as JSON null -- is the honest value until a surface exists.
    ///
    /// `state` is the engine's own lifecycle, which keeps `listenerRegistered` and `attached`
    /// distinguishable: the first says QEMU has a graphic console with our listener on it, the
    /// second says DroidVM also has somewhere to put a frame. Neither says Android is ready, and
    /// neither is what makes `displayInit` pass.
    public struct DisplayObservation: Equatable, Sendable {
        public var state: DroidVMDisplayState = .notAttempted
        public var width: Int?
        public var height: Int?
        public var stride: Int?
        public var updates: UInt64 = 0
        public var surfaceReplacements: UInt64 = 0
        public var reason: String?

        public init() {}

        /// The report lines, in the report's own `key: value` style.
        public var renderedLines: [String] {
            [
                "display_state: \(state.reportName)",
                "display_width: \(width.map(String.init) ?? "-")",
                "display_height: \(height.map(String.init) ?? "-")",
                "display_stride: \(stride.map(String.init) ?? "-")",
                "display_updates: \(updates)",
                "display_surface_replacements: \(surfaceReplacements)",
                "display_last_reason: \(reason ?? "-")",
            ]
        }
    }

    /// The engine's display telemetry. Populated before the report is rendered and emitted.
    public var display = DisplayObservation()

    public init() {}

    /// The whole of Level D's claim, and the only place it is decided.
    ///
    /// EVERY criterion in the acceptance gate is required, and none of them may be relaxed to
    /// accommodate a part of the engine that is not wired yet. An earlier revision let
    /// `display_init: FAIL` coexist with `result: PASS`, on the reasoning that the display
    /// listener was not implemented. That was wrong: it would have made a green Level D mean
    /// "the engine started and something else was broken", which is exactly the kind of
    /// overclaim this repository exists to avoid.
    ///
    /// `jit == READY` is required rather than merely recorded for the same reason. Without
    /// executable memory the QEMU execution path cannot run, so `UNAVAILABLE` is a valid
    /// *diagnostic outcome* and cannot be a Level D pass.
    public var result: Verdict {
        guard appLaunch == .pass,
              runtimeController == .pass,
              jit == .ready,
              nativeBridge == .pass,
              qemuInit == .pass,
              qemuStarted == .pass,
              displayInit == .pass,
              !crashed else { return .fail }
        return .pass
    }

    /// The report, exactly as a human reads it. Deterministic: same value, same bytes.
    public var rendered: String {
        var lines: [String] = []
        lines.append("LEVEL D DEVICE REPORT")
        lines.append("app_launch: \(appLaunch.rawValue)")
        lines.append("runtime_controller: \(runtimeController.rawValue)")
        lines.append("provider_prepare: \(providerPrepare.rawValue)")
        lines.append("provider_range: \(providerRange.rawValue)")
        lines.append("rw_alias: \(rwAlias.rawValue)")
        lines.append("readback: \(readback.rawValue)")
        lines.append("jit_selftest: \(jitSelfTest.rawValue)")
        lines.append("jit: \(jit.rawValue)")
        lines.append("jit_reason: \(jitReason ?? "-")")
        lines.append("native_bridge: \(nativeBridge.rawValue)")
        lines.append("qemu_init: \(qemuInit.rawValue)")
        lines.append("qemu_started: \(qemuStarted.rawValue)")
        lines.append("display_init: \(displayInit.rawValue)")
        lines.append(contentsOf: display.renderedLines)
        lines.append("android_guest: \(androidGuest.rawValue)")
        lines.append("crash: \(crashed ? "YES" : "NO")")
        lines.append("failure_stage: \(failureStage ?? "-")")
        lines.append("failure_reason: \(failureReason ?? "-")")
        lines.append("result: \(result.rawValue)")
        if let technicalDetail, !technicalDetail.isEmpty {
            lines.append("detail: \(technicalDetail)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Runtime confirmation

/// Whether the engine's execution path is actually running.
///
/// THIS IS THE QUESTION LEVEL D EXISTS TO ANSWER, and it is one that Swift bookkeeping cannot
/// answer. `QEMURuntime`'s `isRunning` is set on the engine thread after `qemu_init` returns 0
/// and **before `qemu_main_loop` is called**:
///
///     let initResult = initFn(...)        // qemu_init
///     if initResult == 0 {
///         self.markRunning(true)          // <- isRunning becomes true HERE
///         loopResult = loopFn()           // <- qemu_main_loop, entered afterwards
///     }
///
/// So it is genuine in one respect -- it is not set by `start()`, which returns as soon as the
/// thread is launched -- but it is set one step too early. It is true in the window before the
/// loop is entered, and it is true if the loop returns immediately. "The machine was
/// constructed" is not "the machine is executing".
///
/// Answering honestly needs a marker published from *inside* the engine. That does not exist
/// yet, so `unavailable` exists as a first-class answer and is a FAILURE -- a build in which the
/// question cannot be asked cannot answer it, and Level D requires the answer.
public enum RuntimeConfirmation: Equatable, Sendable {
    /// The engine reported that its execution path has entered its running state.
    case running
    /// The engine reported that it is not executing.
    case notRunning
    /// The engine was asked and did not answer within the deadline.
    case timedOut
    /// There is no mechanism to ask. NOT a pass, and not a negative answer either.
    case unavailable(reason: String)
}

/// Asks the engine whether it is executing.
///
/// Behind a protocol because the honest implementation has to reach into the engine and
/// DroidVMCore must build and be tested where the engine does not exist. The engine layer
/// provides the real conformance; the host tests provide a stub that can say each of the four
/// answers.
public protocol RuntimeConfirming: AnyObject, Sendable {

    /// Ask, with a deadline.
    ///
    /// Implementations MUST bound their own wait and must return `.timedOut` rather than
    /// blocking. A confirmation that can hang is a UI that can hang, and the two are the same
    /// defect from the user's chair.
    func confirmRunning(timeout: TimeInterval) async -> RuntimeConfirmation
}

// MARK: - Native runtime state

/// The engine's own view of its execution state, as the QEMU dylib reports it.
///
/// A Swift mirror of the `droidvm_runtime_state` C enum. The values are mirrored by *name*, and
/// `droidvm_qemu_runtime.c` carries `_Static_assert`s pinning the numeric values, so a change on
/// one side fails a build rather than silently misreporting on the other.
///
/// This is the ONLY thing Level D accepts as evidence that the engine is running.
/// `VMEngineAdapter.isRunning` is adapter-side bookkeeping set after `qemu_init` returns and
/// before `qemu_main_loop` is entered, so it answers a different question.
public enum DroidVMRuntimeState: Equatable, Sendable {
    /// Nothing has run yet.
    case notStarted
    /// `qemu_init` returned 0. The loop has NOT been entered -- explicitly not running.
    case initialized
    /// A real `qemu_main_loop` iteration has begun and the loop has not exited. The one state
    /// that means running.
    case mainLoopEntered
    /// The loop returned. It ran, and it is not running now.
    case mainLoopExited
    /// The engine recorded a failure.
    case failed(reason: String)

    /// Whether the engine's execution path is running, by the only definition Level D accepts.
    public var isRunning: Bool { self == .mainLoopEntered }

    /// A human-readable description for diagnostics. Never shown to a user verbatim.
    public var detail: String {
        switch self {
        case .notStarted: return "engine has not started"
        case .initialized: return "engine initialised; main loop not yet entered"
        case .mainLoopEntered: return "main loop entered"
        case .mainLoopExited: return "main loop exited"
        case .failed(let reason): return "engine failed: \(reason)"
        }
    }
}

/// Something that can report the engine's native runtime state.
///
/// `nil` means the engine could not be asked -- it does not export the query symbol. That is
/// `unavailable`, never `notRunning`: a question that could not be asked has not been answered,
/// and conflating the two would let a broken symbol export look like a machine that will not
/// start.
public protocol RuntimeStateProviding: AnyObject {
    func runtimeState() -> DroidVMRuntimeState?
}

/// Poll the engine until it reports running, reaches a terminal state, or the deadline passes.
///
/// POLLING, NOT A TIMER. The state is written on the engine thread while `qemu_init` is still
/// running, so a single query immediately after `start()` would usually find NOT_STARTED and
/// report a healthy machine as failed. Waiting is unavoidable; what matters is that waiting can
/// never *produce* running -- only the engine's own state can. Every exit from this function is
/// either the engine's answer or the deadline.
///
/// `pollInterval` is injectable so tests do not spend five seconds proving the deadline works.
public func confirmRuntime(
    using provider: RuntimeStateProviding,
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05
) async -> RuntimeConfirmation {

    let started = Date()

    while true {
        guard let state = provider.runtimeState() else {
            return .unavailable(
                reason: "the loaded engine does not export the DroidVM runtime-state symbols; "
                      + "it cannot be asked whether its main loop is running")
        }

        switch state {
        case .mainLoopEntered:
            return .running
        case .mainLoopExited:
            // It ran and stopped. Not running, and never will be again without a fresh start.
            return .notRunning
        case .failed:
            return .notRunning
        case .notStarted, .initialized:
            break   // still on its way; wait, do not promote
        }

        if Date().timeIntervalSince(started) >= timeout { return .timedOut }
        try? await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
    }
}

// MARK: - Native display state (D.1b)

/// The engine's display-listener lifecycle, as the QEMU dylib reports it.
///
/// A Swift mirror of the `droidvm_display_state` C enum. The raw values are pinned on the C side by
/// `_Static_assert`s, so a divergence fails a build rather than silently misreporting.
///
/// DELIBERATELY NOT THE FRAME COUNTERS. "QEMU has a graphic console" and "frames are reaching the
/// screen" are different facts; collapsing them is how a console would start meaning a working
/// display. Nothing here is "ready".
public enum DroidVMDisplayState: Int32, Equatable, Sendable, CaseIterable {
    case notAttempted = 0
    case listenerRegistered = 1
    case attached = 2
    case detached = 3
    case failed = 4

    /// The stable name used in the device report and the JSON event.
    ///
    /// The raw values stay numeric so that mirroring the C enum is a value comparison; this is the
    /// reader-facing spelling, and readers filter on it, so it is part of the format.
    public var reportName: String {
        switch self {
        case .notAttempted: return "NOT ATTEMPTED"
        case .listenerRegistered: return "LISTENER REGISTERED"
        case .attached: return "ATTACHED"
        case .detached: return "DETACHED"
        case .failed: return "FAILED"
        }
    }
}

// MARK: - Deadlines

/// Deadline used for asking the engine whether it is executing.
///
/// Long enough that a slow device is not accused of hanging, short enough that a person does
/// not conclude the app has frozen.
public let engineConfirmationTimeout: TimeInterval = 5.0

/// Deadline used for attaching the display.
public let displayAttachmentTimeout: TimeInterval = 5.0

/// Run an operation with a deadline. `nil` means the deadline passed first.
///
/// A deadline can only ever produce a FAILURE here. It never promotes a state, and a successful
/// value always comes from the operation itself -- which is the difference between a timeout and
/// a timer. A timer that advanced the state after N seconds would be a lie; a deadline that
/// reports "no answer within N seconds" is a fact.
public func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
