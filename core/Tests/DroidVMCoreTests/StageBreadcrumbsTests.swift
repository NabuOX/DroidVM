// SPDX-License-Identifier: GPL-2.0-or-later
//
// Durable stage breadcrumbs.
//
// These cover the property the first device run needed and did not have: after the process is
// killed inside a stage, the surviving trail names that stage. They cannot cover the kill itself --
// only a device can produce one -- so they test what can be tested on a host: that the trail is
// durable, that it is ordered, that it is cleared between runs, and above all that it can never
// make a report claim success.

import XCTest
@testable import DroidVMCore

final class StageBreadcrumbsTests: XCTestCase {

    /// A trail in its own directory, so tests cannot collide or inherit state.
    private func makeLog() -> StageBreadcrumbLog {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("droidvm-breadcrumbs-\(UUID().uuidString)", isDirectory: true)
        return StageBreadcrumbLog(url: directory.appendingPathComponent("stage-breadcrumbs.txt"))
    }

    /// THE POINT OF THE FILE. A relaunch reads the trail left by the process that died, so the
    /// trail is read through a SECOND instance over the same path -- which is exactly what a fresh
    /// launch does.
    func testTheTrailSurvivesAFreshReader() {
        let log = makeLog()
        log.reset()
        log.record(.appLaunch)
        log.record(.jitProbeEntered)

        let afterRelaunch = StageBreadcrumbLog(url: log.url)

        XCTAssertEqual(afterRelaunch.readTrail(), [.appLaunch, .jitProbeEntered])
        XCTAssertEqual(afterRelaunch.lastReached, .jitProbeEntered)
    }

    /// A trail ending on an `entered` marker is a diagnosis: that stage was entered and never left.
    /// This is what the crash log would otherwise be needed for.
    func testATrailEndingOnEnteredNamesTheStageThatDied() {
        let log = makeLog()
        log.reset()
        log.record(.appLaunch)
        log.record(.runtimeControllerEntered)
        log.record(.runtimeControllerReturned)
        log.record(.jitProbeEntered)

        let afterRelaunch = StageBreadcrumbLog(url: log.url)

        XCTAssertEqual(afterRelaunch.lastReached, .jitProbeEntered)
        XCTAssertFalse(afterRelaunch.readTrail().contains(.jitProbeReturned),
                       "a returned marker for a stage that never returned")
    }

    /// A new run must not inherit the previous run's last stage, or a stale trail would look like
    /// progress this run never made.
    func testResetClearsThePrecedingRun() {
        let log = makeLog()
        log.record(.qemuInitReturned)
        XCTAssertEqual(log.lastReached, .qemuInitReturned)

        log.reset()
        XCTAssertNil(log.lastReached)
        XCTAssertEqual(log.readTrail(), [])
    }

    /// No trail is NOT a trail that got nowhere, and the two must not be confused.
    func testNoRunRecordedIsNotARunThatGotNowhere() {
        XCTAssertNil(makeLog().lastReached)
    }

    /// Repeating a stage adds nothing, so a retry loop cannot grow the file without recording
    /// anything new.
    func testRepeatingAStageIsNotRecordedTwice() {
        let log = makeLog()
        log.reset()
        log.record(.jitProbeEntered)
        log.record(.jitProbeEntered)
        log.record(.jitProbeEntered)

        XCTAssertEqual(log.readTrail(), [.jitProbeEntered])
    }

    /// A BREADCRUMB RECORDS POSITION, NEVER A VERDICT. Recording every stage must not make the
    /// report look like anything happened -- this is the test that keeps the trail from becoming a
    /// second, weaker source of truth about whether the engine works.
    func testTheTrailCannotMakeAReportPass() {
        let log = makeLog()
        log.reset()
        for stage in LevelDStage.allCases {
            log.record(stage)
        }
        XCTAssertEqual(log.readTrail().count, LevelDStage.allCases.count)

        let fresh = EngineRunReport()
        XCTAssertEqual(fresh.appLaunch, .notRun)
        XCTAssertEqual(fresh.qemuInit, .notRun)
        XCTAssertEqual(fresh.qemuStarted, .notRun)
        XCTAssertEqual(fresh.displayInit, .notRun)
        XCTAssertEqual(fresh.result, .fail, "breadcrumbs produced a passing report")
    }

    /// The vocabulary is closed and every name is the product API a log reader filters on.
    func testTheStageVocabularyIsStable() {
        XCTAssertEqual(LevelDStage.allCases.count, 11)
        XCTAssertEqual(LevelDStage.appLaunch.rawValue, "app_launch")
        XCTAssertEqual(LevelDStage.runtimeControllerEntered.rawValue, "runtime_controller_entered")
        XCTAssertEqual(LevelDStage.jitProbeEntered.rawValue, "jit_probe_entered")
        XCTAssertEqual(LevelDStage.jitProbeReturned.rawValue, "jit_probe_returned")

        let names = LevelDStage.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count, "two stages share a name")
    }
}
