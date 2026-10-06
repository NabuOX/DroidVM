// SPDX-License-Identifier: GPL-2.0-or-later
//
// Frame accounting and stall classification.
//
// THE CENTRAL RULE: display health is never one number.
//
// A single "frames" counter -- the obvious design, and the one the reference
// implementation used -- cannot distinguish these two situations:
//
//   * the guest produced no frame at all          (the guest's problem)
//   * the guest produced frames and we dropped
//     every one                                    (our problem)
//
// Both read as `0.0 fps`, and they have opposite fixes. So each stage is counted
// separately and the stages are never OR-ed together for health.
//
// THE SECOND RULE: a healthy, idle Android system legitimately presents nothing. A phone
// sitting on its home screen with no animation running produces no new frames for
// minutes. Readiness therefore depends on whether anything has EVER reached the screen,
// not on a frame rate, and "no frames this window" is only a fault when something else
// says it should have been drawing.

import Foundation

// MARK: - Counters

/// Frame accounting, split by stage, in the order a frame travels.
public struct DisplayCounters: Equatable, Sendable {

    /// Times the engine entered its display-update path. This is the denominator: if it
    /// is zero, nothing asked us to draw and the other counters mean nothing.
    public var entered: UInt64

    /// Frames handed to DroidVM by the engine. Evidence about the guest.
    public var received: UInt64

    /// Frames that actually reached the screen. Evidence about us.
    public var presented: UInt64

    /// Frames we took and did not draw -- a missing drawable, a skipped pipeline.
    public var dropped: UInt64

    /// Times we were asked to draw and the guest had no scanout to draw. Evidence about
    /// the guest: it has nothing on screen to give us.
    public var noScanout: UInt64

    /// Present/swap calls that failed. Evidence about us.
    public var presentFailure: UInt64

    public init(entered: UInt64 = 0,
                received: UInt64 = 0,
                presented: UInt64 = 0,
                dropped: UInt64 = 0,
                noScanout: UInt64 = 0,
                presentFailure: UInt64 = 0) {
        self.entered = entered
        self.received = received
        self.presented = presented
        self.dropped = dropped
        self.noScanout = noScanout
        self.presentFailure = presentFailure
    }

    public static let zero = DisplayCounters()

    /// Whether anything has ever reached the screen.
    ///
    /// This -- not a frame rate -- is what the ready gate consults.
    public var hasEverPresented: Bool { presented > 0 }

    /// Difference between two readings, clamped at zero.
    ///
    /// A counter that appears to go backwards yields an empty window rather than a
    /// nonsense one.
    public static func delta(from before: DisplayCounters,
                             to after: DisplayCounters) -> DisplayCounters {
        DisplayCounters(
            entered: sub(after.entered, before.entered),
            received: sub(after.received, before.received),
            presented: sub(after.presented, before.presented),
            dropped: sub(after.dropped, before.dropped),
            noScanout: sub(after.noScanout, before.noScanout),
            presentFailure: sub(after.presentFailure, before.presentFailure))
    }

    private static func sub(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }

    /// Human-readable one-line summary for the Advanced view.
    public var summary: String {
        "entered=\(entered) received=\(received) presented=\(presented) "
        + "dropped=\(dropped) noScanout=\(noScanout) presentFailure=\(presentFailure)"
    }
}

// MARK: - Why a window produced nothing
//
// Exactly one cause is chosen, so a log line reporting a zero always carries a reason.
// Printing the zero alone is what made the original black-screen failure take as long as
// it did to explain.

public enum FrameStallCause: String, Equatable, CaseIterable, Sendable {

    /// Frames reached the screen. Nothing is stalled.
    case presented

    /// Nothing asked us to draw. Normal for an idle system, and NOT a fault.
    case noUpdates

    /// Asked to draw; the guest had no scanout. Evidence about the guest.
    case noScanout

    /// A frame reached us and we did not draw it. Evidence about us.
    case droppedByPresenter

    /// The present call failed. Evidence about us.
    case swapFailed

    /// No graphics context is available.
    case contextUnavailable

    /// No display surface is attached.
    case surfaceUnavailable

    /// Frames moved and no counter accounts for it. Preferred over a guess, and a signal
    /// that the counters themselves need attention.
    case unknown

    /// Whether this cause means the guest's screen is not updating.
    ///
    /// `noUpdates` is deliberately false: an idle system is not a stalled one. `unknown`
    /// is also false, because ignorance must not become a fault report.
    public var indicatesStall: Bool {
        switch self {
        case .presented, .noUpdates, .unknown: return false
        case .noScanout, .droppedByPresenter, .swapFailed,
             .contextUnavailable, .surfaceUnavailable: return true
        }
    }

    /// What a technical log says about it. Never shown to a user; the user sees the
    /// lifecycle's own label.
    public var technicalDescription: String {
        switch self {
        case .presented: return "frames are reaching the screen"
        case .noUpdates: return "nothing asked for a frame; consistent with an idle system"
        case .noScanout: return "the guest has no scanout to draw"
        case .droppedByPresenter: return "frames arrived and were dropped by the presenter"
        case .swapFailed: return "the present call failed"
        case .contextUnavailable: return "no graphics context"
        case .surfaceUnavailable: return "no display surface attached"
        case .unknown: return "frames moved but no counter accounts for it"
        }
    }
}

// MARK: - Context

/// What the display path knows about itself, independent of the counters.
///
/// Kept separate from the counters because these are states, not tallies, and a stall can
/// be explained by either.
public struct DisplayContext: Equatable, Sendable {

    public var attached: Bool
    public var hasGraphicsContext: Bool

    public init(attached: Bool = false, hasGraphicsContext: Bool = false) {
        self.attached = attached
        self.hasGraphicsContext = hasGraphicsContext
    }

    public static let detached = DisplayContext()
}

// MARK: - Classification

public enum StallClassifier {

    /// Name the reason a window looks the way it does.
    ///
    /// Priority is by specificity: a state that explains everything outranks a tally, and
    /// a tally that proves progress outranks one that proves nothing.
    public static func classify(window: DisplayCounters,
                                context: DisplayContext) -> FrameStallCause {

        // A missing surface or context explains an empty window completely, and nothing
        // else can be concluded while it is true.
        if !context.attached { return .surfaceUnavailable }
        if !context.hasGraphicsContext { return .contextUnavailable }

        // Progress settles it.
        if window.presented > 0 { return .presented }

        // Our own failures, most specific first.
        if window.presentFailure > 0 { return .swapFailed }
        if window.dropped > 0 { return .droppedByPresenter }

        // The guest says it has nothing to give us.
        if window.noScanout > 0 { return .noScanout }

        // Nothing asked us to draw at all. This is the idle case and it is not a fault.
        if window.entered == 0 { return .noUpdates }

        // We were asked to draw but never received a frame from the guest.
        if window.received == 0 { return .noScanout }

        // Frames arrived and no counter accounts for where they went. Report the gap
        // rather than inventing a cause: this is instrumentation debt, and a guess here
        // would hide it.
        return .unknown
    }
}

// MARK: - Tracker

/// Accumulates counters and describes the window since it was last asked.
///
/// This is the portable heart of the graphics health monitor. It holds no platform state:
/// an adapter polls the engine, hands the absolute counters in, and this decides what they
/// mean.
public final class DisplayStatsTracker {

    /// Cumulative counters, as last reported by the engine.
    public private(set) var cumulative: DisplayCounters = .zero

    /// Counters at the end of the previous window.
    private var windowStart: DisplayCounters = .zero

    private var context: DisplayContext = .detached

    /// Windows that presented nothing, consecutively. Reset by any presented frame.
    public private(set) var consecutiveEmptyWindows: UInt64 = 0

    /// The cause of the most recent window.
    public private(set) var lastCause: FrameStallCause = .noUpdates

    /// When a frame was last presented, on the caller's clock. `nil` until one is.
    public private(set) var lastPresentedAt: Date?

    public init() {}

    /// Update the absolute counters and the context, then describe the window.
    ///
    /// Returns the window and its cause. Callers poll on their own schedule; this does
    /// not run a timer, because a timer here would be a policy decision and policy belongs
    /// above.
    @discardableResult
    public func update(counters: DisplayCounters,
                       context: DisplayContext,
                       now: Date = Date()) -> (window: DisplayCounters, cause: FrameStallCause) {

        // Captured before `cumulative` is overwritten, so a newly presented frame is
        // distinguishable from a reading that merely re-reports the same total.
        let previous = cumulative
        let window = DisplayCounters.delta(from: windowStart, to: counters)

        windowStart = counters
        self.context = context
        cumulative = counters

        if counters.presented > previous.presented {
            lastPresentedAt = now
        }

        let cause = StallClassifier.classify(window: window, context: context)
        lastCause = cause

        if window.presented > 0 {
            consecutiveEmptyWindows = 0
        } else {
            consecutiveEmptyWindows += 1
        }

        return (window, cause)
    }

    /// Whether anything has ever reached the screen.
    public var hasEverPresented: Bool { cumulative.hasEverPresented }

    /// How long since a frame was presented, if one ever was.
    public func timeSinceLastPresented(now: Date = Date()) -> TimeInterval? {
        guard let last = lastPresentedAt else { return nil }
        return now.timeIntervalSince(last)
    }

    public var currentContext: DisplayContext { context }

    public func reset() {
        cumulative = .zero
        windowStart = .zero
        context = .detached
        consecutiveEmptyWindows = 0
        lastCause = .noUpdates
        lastPresentedAt = nil
    }
}
