// SPDX-License-Identifier: GPL-2.0-or-later
//
// Level D.1b: the native display state enum.
//
// This proves the MIRROR and nothing else. It cannot prove QEMU registered a listener -- that is
// gate 3's compile/link proof and, ultimately, a physical iPhone. Nothing here runs QEMU.

import XCTest
@testable import DroidVMCore

final class DisplayIntegrationTests: XCTestCase {

    /// The raw values mirror the C enum, and `droidvm_qemu_display.c` pins them with
    /// `_Static_assert`. If either side moves without the other, a build fails rather than the two
    /// silently disagreeing about what "registered" means.
    func testRawValuesMatchTheNativeEnum() {
        XCTAssertEqual(DroidVMDisplayState.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
    }
}
