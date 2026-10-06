// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// Frame accounting and stall classification.
///
/// This is the suite that has to hold the line on the two rules everything else depends
/// on: display health is never one number, and an idle system is not a broken one.
final class DisplayStatsTests: XCTestCase {

    /// A display that is attached and has a working context, so that tests which are not
    /// about attachment are not accidentally about attachment.
    private let live = DisplayContext(attached: true, hasGraphicsContext: true)

    // MARK: - counters

    /// LESSON: one frame counter cannot tell "the guest is not drawing" apart from
    /// "we are dropping every frame". The type must represent both, distinctly.
    func testReceivedWithoutPresentedIsRepresentable() {
        let droppingEverything = DisplayCounters(entered: 900, received: 900,
                                                 presented: 0, dropped: 900)
        XCTAssertGreaterThan(droppingEverything.received, 0)
        XCTAssertEqual(droppingEverything.presented, 0)
        XCTAssertFalse(droppingEverything.hasEverPresented)

        let guestSilent = DisplayCounters(entered: 900, received: 0, presented: 0)

        XCTAssertNotEqual(droppingEverything, guestSilent,
                          "these must not compare equal: opposite causes, opposite fixes")
        XCTAssertEqual(StallClassifier.classify(window: droppingEverything, context: live),
                       .droppedByPresenter)
        XCTAssertEqual(StallClassifier.classify(window: guestSilent, context: live),
                       .noScanout)
    }

    /// The six stages are independent; nothing OR-s them together.
    func testStagesAreIndependent() {
        let c = DisplayCounters(entered: 1, received: 2, presented: 3,
                                dropped: 4, noScanout: 5, presentFailure: 6)
        XCTAssertEqual(c.entered, 1)
        XCTAssertEqual(c.received, 2)
        XCTAssertEqual(c.presented, 3)
        XCTAssertEqual(c.dropped, 4)
        XCTAssertEqual(c.noScanout, 5)
        XCTAssertEqual(c.presentFailure, 6)
        XCTAssertEqual(DisplayCounters.zero, DisplayCounters())
    }

    func testDeltaClampsAndSubtracts() {
        let before = DisplayCounters(entered: 10, received: 10, presented: 4,
                                     dropped: 1, noScanout: 2, presentFailure: 0)
        let after = DisplayCounters(entered: 25, received: 25, presented: 9,
                                    dropped: 3, noScanout: 2, presentFailure: 1)
        let d = DisplayCounters.delta(from: before, to: after)
        XCTAssertEqual(d.entered, 15)
        XCTAssertEqual(d.received, 15)
        XCTAssertEqual(d.presented, 5)
        XCTAssertEqual(d.dropped, 2)
        XCTAssertEqual(d.noScanout, 0)
        XCTAssertEqual(d.presentFailure, 1)

        // Backwards must clamp to zero, never underflow into an enormous window.
        XCTAssertEqual(DisplayCounters.delta(from: after, to: before), .zero)
    }

    // MARK: - the classifier
    //
    // One test per branch, because each branch is a distinct diagnosis and an accidental
    // reordering would silently merge two of them.

    func testClassifierSeparationOfStages() {
        // Progress settles it, even alongside failures.
        XCTAssertEqual(
            StallClassifier.classify(window: DisplayCounters(entered: 5, received: 5,
                                                             presented: 3, presentFailure: 1),
                                     context: live),
            .presented)

        // Our failure outranks the guest's silence: we were asked to draw and could not.
        XCTAssertEqual(
            StallClassifier.classify(window: DisplayCounters(entered: 5, received: 5,
                                                             presentFailure: 2),
                                     context: live),
            .swapFailed)

        XCTAssertEqual(
            StallClassifier.classify(window: DisplayCounters(entered: 5, received: 5,
                                                             dropped: 5),
                                     context: live),
            .droppedByPresenter)

        XCTAssertEqual(
            StallClassifier.classify(window: DisplayCounters(entered: 5, noScanout: 3),
                                     context: live),
            .noScanout)

        // Asked to draw, guest never produced a frame.
        XCTAssertEqual(
            StallClassifier.classify(window: DisplayCounters(entered: 5), context: live),
            .noScanout)
    }

    /// LESSON: a healthy, idle Android system presents nothing, and that is not a fault.
    ///
    /// Nothing asked us to draw, so the window is empty for the ordinary reason. This must
    /// not be reported as a stall, or every idle phone looks broken.
    func testIdleIsNotStalled() {
        let idle = DisplayCounters.delta(from: DisplayCounters(entered: 900, received: 900,
                                                               presented: 900),
                                         to: DisplayCounters(entered: 900, received: 900,
                                                             presented: 900))
        XCTAssertEqual(idle.presented, 0, "an idle window presents nothing, by definition")
        XCTAssertEqual(idle.entered, 0, "and nothing asked us to draw")

        let cause = StallClassifier.classify(window: idle, context: live)
        XCTAssertEqual(cause, .noUpdates)
        XCTAssertFalse(cause.indicatesStall,
                       "an idle system must not be classified as a stall")

        // And the machine is still one that has drawn a frame.
        XCTAssertTrue(DisplayCounters(entered: 900, presented: 900).hasEverPresented)
    }

    /// A tally that moved with no counter to explain it is reported as a gap, not guessed
    /// at. `unknown` is a real answer.
    func testUnexplainedTrafficIsUnknown() {
        let cause = StallClassifier.classify(
            window: DisplayCounters(entered: 4, received: 4), context: live)
        XCTAssertEqual(cause, .unknown)
        XCTAssertFalse(cause.indicatesStall,
                       "ignorance must not become a fault report")
    }

    /// A missing surface or context explains an empty window completely.
    func testContextOutranksCounters() {
        XCTAssertEqual(
            StallClassifier.classify(window: .zero,
                                     context: DisplayContext(attached: false,
                                                             hasGraphicsContext: false)),
            .surfaceUnavailable)
        XCTAssertEqual(
            StallClassifier.classify(window: .zero,
                                     context: DisplayContext(attached: true,
                                                             hasGraphicsContext: false)),
            .contextUnavailable)
        XCTAssertEqual(DisplayContext.detached,
                       DisplayContext(attached: false, hasGraphicsContext: false))
    }

    func testStallCausesAreCompleteAndClassified() {
        XCTAssertEqual(FrameStallCause.allCases.count, 8)
        for cause in FrameStallCause.allCases {
            XCTAssertFalse(cause.rawValue.isEmpty)
            XCTAssertFalse(cause.technicalDescription.isEmpty,
                           "\(cause) needs a description a log can carry")
        }

        // The three that must NOT report a stall.
        for benign in [FrameStallCause.presented, .noUpdates, .unknown] {
            XCTAssertFalse(benign.indicatesStall, "\(benign) must not indicate a stall")
        }
        for stalled in [FrameStallCause.noScanout, .droppedByPresenter, .swapFailed,
                        .contextUnavailable, .surfaceUnavailable] {
            XCTAssertTrue(stalled.indicatesStall, "\(stalled) must indicate a stall")
        }
    }

    // MARK: - the tracker

    func testTrackerWindowsAndCumulative() {
        let tracker = DisplayStatsTracker()

        let first = tracker.update(counters: DisplayCounters(entered: 10, received: 10,
                                                             presented: 10),
                                   context: live)
        XCTAssertEqual(first.window.presented, 10)
        XCTAssertEqual(first.cause, .presented)
        XCTAssertEqual(tracker.consecutiveEmptyWindows, 0)
        XCTAssertTrue(tracker.hasEverPresented)
        XCTAssertNotNil(tracker.lastPresentedAt)

        // Nothing new: an idle window, and it must be counted as empty but not as a stall.
        let second = tracker.update(counters: DisplayCounters(entered: 10, received: 10,
                                                              presented: 10),
                                    context: live)
        XCTAssertEqual(second.window, .zero)
        XCTAssertEqual(second.cause, .noUpdates)
        XCTAssertEqual(tracker.consecutiveEmptyWindows, 1)
        XCTAssertEqual(tracker.cumulative.presented, 10, "cumulative is the absolute reading")

        let third = tracker.update(counters: DisplayCounters(entered: 10, received: 10,
                                                             presented: 10),
                                   context: live)
        XCTAssertEqual(third.cause, .noUpdates)
        XCTAssertEqual(tracker.consecutiveEmptyWindows, 2)

        // A new frame resets the streak.
        let fourth = tracker.update(counters: DisplayCounters(entered: 20, received: 20,
                                                              presented: 20),
                                    context: live)
        XCTAssertEqual(fourth.window.presented, 10, "the window is the delta, not the total")
        XCTAssertEqual(tracker.consecutiveEmptyWindows, 0)
    }

    /// Counters that go backwards must not produce a nonsense window, and the tracker must
    /// resynchronise rather than stay confused.
    func testTrackerSurvivesCountersGoingBackwards() {
        let tracker = DisplayStatsTracker()
        _ = tracker.update(counters: DisplayCounters(entered: 100, received: 100,
                                                     presented: 100),
                           context: live)
        let after = tracker.update(counters: DisplayCounters(entered: 5, received: 5,
                                                             presented: 5),
                                   context: live)
        XCTAssertEqual(after.window, .zero, "a backwards reading yields an empty window")

        // The next window is measured from the new baseline, so it is meaningful again.
        let next = tracker.update(counters: DisplayCounters(entered: 9, received: 9,
                                                            presented: 9),
                                  context: live)
        XCTAssertEqual(next.window.presented, 4)
    }

    func testTrackerReportsTimeSinceLastPresented() {
        let tracker = DisplayStatsTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = tracker.update(counters: DisplayCounters(entered: 1, received: 1, presented: 1),
                           context: live, now: t0)
        XCTAssertEqual(tracker.timeSinceLastPresented(now: t0) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(tracker.timeSinceLastPresented(now: t0.addingTimeInterval(30)) ?? -1,
                       30, accuracy: 0.001)

        // A tracker that has never presented has no answer, which is not zero.
        XCTAssertNil(DisplayStatsTracker().timeSinceLastPresented())
    }

    func testTrackerReset() {
        let tracker = DisplayStatsTracker()
        _ = tracker.update(counters: DisplayCounters(entered: 5, received: 5, presented: 5),
                           context: live)
        tracker.reset()
        XCTAssertEqual(tracker.cumulative, .zero)
        XCTAssertFalse(tracker.hasEverPresented)
        XCTAssertNil(tracker.lastPresentedAt)
        XCTAssertEqual(tracker.consecutiveEmptyWindows, 0)
        XCTAssertEqual(tracker.currentContext, .detached)
    }

    /// A detached display is reported as such even after frames have been presented: the
    /// cause describes the display *now*, not the history.
    func testDetachIsReportedImmediately() {
        let tracker = DisplayStatsTracker()
        _ = tracker.update(counters: DisplayCounters(entered: 10, received: 10, presented: 10),
                           context: live)
        let window = DisplayCounters(entered: 10, received: 10, presented: 10)
        let detached = tracker.update(counters: window, context: .detached)
        XCTAssertEqual(detached.cause, .surfaceUnavailable)
        XCTAssertTrue(tracker.hasEverPresented,
                      "history is retained: it did present, and it is not presenting now")
    }

    func testSummaryIsReadable() {
        let s = DisplayCounters(entered: 1, received: 2, presented: 3,
                                dropped: 4, noScanout: 5, presentFailure: 6).summary
        for token in ["entered=1", "received=2", "presented=3",
                      "dropped=4", "noScanout=5", "presentFailure=6"] {
            XCTAssertTrue(s.contains(token), "summary is missing \(token): \(s)")
        }
    }
}
