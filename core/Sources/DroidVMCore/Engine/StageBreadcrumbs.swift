// SPDX-License-Identifier: GPL-2.0-or-later
//
// Durable stage breadcrumbs.
//
// A CRASH CANNOT REPORT ITSELF. When the process dies inside a stage, the report describing that
// stage dies with it. The first physical-device run demonstrated exactly that: the app was killed
// by EXC_BREAKPOINT inside JIT capture, and the relaunched app could only show a default report --
// app_launch NOT RUN and every other field NOT RUN. There was no way to tell how far execution had
// reached, or even that it had started.
//
// So each risky boundary writes WHERE IT REACHED to a file, flushed, BEFORE crossing it. What
// survives a kill is then the last breadcrumb, which names the stage that was entered and never
// left.
//
// A BREADCRUMB RECORDS POSITION, NEVER A VERDICT. This is the rule that keeps the crash-recovery
// trail from becoming a second, weaker source of truth about whether anything worked. Reaching
// `jit_probe_entered` does not mean the probe ran, let alone succeeded; `appLaunch` stays NOT RUN
// until the stage genuinely completes and says so in the report. Nothing here writes to a report.

import Foundation

/// Every point in a Level D run that is worth surviving a crash.
///
/// The `entered`/`returned` pairs are the point: a trail ending at `jit_probe_entered` says the
/// process died *inside* the probe, which is a different diagnosis from one ending at
/// `jit_probe_returned`.
public enum LevelDStage: String, CaseIterable, Equatable, Sendable {
    case appLaunch = "app_launch"
    case runtimeControllerEntered = "runtime_controller_entered"
    case runtimeControllerReturned = "runtime_controller_returned"
    case jitProbeEntered = "jit_probe_entered"
    case jitProbeReturned = "jit_probe_returned"
    case nativeBridgeEntered = "native_bridge_entered"
    case nativeBridgeReturned = "native_bridge_returned"
    case engineLoadEntered = "engine_load_entered"
    case engineLoadReturned = "engine_load_returned"
    case qemuInitEntered = "qemu_init_entered"
    case qemuInitReturned = "qemu_init_returned"

    public var label: String { rawValue }
}

/// Where a run records how far it got.
public protocol StageBreadcrumbRecording: Sendable {
    /// Begin a run. Called before the first breadcrumb so a trail from a previous run cannot be
    /// mistaken for this one's.
    func reset()
    func record(_ stage: LevelDStage)
}

/// A file-backed trail.
///
/// Written with `.atomic`, which stages to a temporary file and renames. That is enough for the
/// failure this exists to survive: a process being killed loses nothing already written, because
/// the rename completed before the kill. It is deliberately not `fsync` on every step -- the cost
/// would be paid on ten writes per run to defend against power loss, which is not the failure
/// mode here, and a breadcrumb that is slower than the boundary it precedes is a worse trade.
public struct StageBreadcrumbLog: StageBreadcrumbRecording, Sendable {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The trail as written, oldest first. Empty when no run has recorded anything.
    public func readTrail() -> [LevelDStage] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { LevelDStage(rawValue: String($0)) }
    }

    /// The last point the process reached.
    ///
    /// After a crash this is the whole answer: the stage named here was entered and never left.
    /// `nil` means no run has recorded anything, which is NOT the same as a run that got nowhere.
    public var lastReached: LevelDStage? { readTrail().last }

    public func reset() {
        try? FileManager.default.removeItem(at: url)
    }

    public func record(_ stage: LevelDStage) {
        var trail = readTrail()
        // Re-recording the same stage is not information, and a retry loop would otherwise grow
        // the file without adding any.
        guard trail.last != stage else { return }
        trail.append(stage)

        var text = trail.map(\.rawValue).joined(separator: "\n")
        text += "\n"
        guard let data = text.data(using: .utf8) else { return }

        // The directory is created on first write: the caller supplies a location, not a guarantee
        // that it exists, and a breadcrumb that fails silently because of a missing directory is
        // worse than no breadcrumb at all.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
