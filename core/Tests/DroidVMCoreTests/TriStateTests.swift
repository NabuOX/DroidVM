// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// `TriState` is where the "UNKNOWN is not NO" rule lives, so it is tested first and
/// hardest.
final class TriStateTests: XCTestCase {

    /// The rule, stated once: a probe that could not answer is not evidence that the
    /// thing is absent.
    func testUnknownIsNotAbsent() {
        XCTAssertFalse(TriState.unknown.isConfirmedAbsent,
                       "an unanswered probe must never read as 'it is not running'")
        XCTAssertTrue(TriState.no.isConfirmedAbsent)
        XCTAssertFalse(TriState.yes.isConfirmedAbsent)

        XCTAssertFalse(TriState.unknown.isConfirmedPresent)
        XCTAssertTrue(TriState.yes.isConfirmedPresent)
    }

    func testUnknownIsNotNo() {
        XCTAssertNotEqual(TriState.unknown, TriState.no)
        XCTAssertNotEqual(TriState.unknown, TriState.yes)
        XCTAssertTrue(TriState.unknown.isUnknown)
    }

    /// `nil` from a probe means "no answer", which is `unknown`. The mapping is the
    /// single place that decision is made.
    func testOptionalMapping() {
        XCTAssertEqual(TriState(nil), .unknown)
        XCTAssertEqual(TriState(true), .yes)
        XCTAssertEqual(TriState(false), .no)

        let unanswered: Bool? = nil
        XCTAssertEqual(TriState(unanswered), .unknown)
    }

    /// Exhaustive, so adding a fourth case cannot silently skip these rules.
    func testAllCasesCovered() {
        XCTAssertEqual(TriState.allCases.count, 3)
        for state in TriState.allCases {
            XCTAssertFalse(state.rawValue.isEmpty)
            // Exactly one of the three predicates may hold.
            let flags = [state.isConfirmedPresent, state.isConfirmedAbsent, state.isUnknown]
            XCTAssertEqual(flags.filter { $0 }.count, 1,
                           "\(state) must be exactly one of present/absent/unknown")
        }
    }
}
