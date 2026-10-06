// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The evidence model, minus frames.
///
/// Frame accounting and stall classification moved to `DisplayStatsTests` in Phase 1,
/// when those types moved to `Display/` and grew the six-stage vocabulary the architecture
/// commits to.
final class EvidenceTests: XCTestCase {

    // MARK: - services

    func testUnknownServicesAreNotAbsent() {
        let probed = GuestServices(systemServer: .yes, surfaceFlinger: .yes,
                                   systemUI: .unknown, launcher: .no)
        XCTAssertFalse(probed.systemUI.isConfirmedAbsent,
                       "a probe we could not run is not a missing component")
        XCTAssertTrue(probed.launcher.isConfirmedAbsent)
        XCTAssertFalse(probed.allUnknown)

        XCTAssertTrue(GuestServices.unknown.allUnknown)
    }

    /// Each component is tracked separately: the launcher being absent says nothing about
    /// whether SystemUI is up, and both are separately actionable.
    func testServiceComponentsAreIndependent() {
        let s = GuestServices(systemServer: .yes, surfaceFlinger: .yes,
                              systemUI: .yes, launcher: .no)
        XCTAssertTrue(s.systemUI.isConfirmedPresent)
        XCTAssertTrue(s.launcher.isConfirmedAbsent)
        XCTAssertFalse(s.allUnknown)
    }

    // MARK: - memory

    /// An unmeasurable figure must not raise a pressure signal.
    func testUnknownMemoryIsNotPressure() {
        let unmeasured = MemoryReading()
        XCTAssertFalse(unmeasured.isUnderPressure(floorBytes: 512 * 1024 * 1024))

        let tight = MemoryReading(availableBeforeKillBytes: 64 * 1024 * 1024)
        XCTAssertTrue(tight.isUnderPressure(floorBytes: 512 * 1024 * 1024))

        let comfortable = MemoryReading(availableBeforeKillBytes: 2 * 1024 * 1024 * 1024)
        XCTAssertFalse(comfortable.isUnderPressure(floorBytes: 512 * 1024 * 1024))
    }

    func testMemoryFieldsAreIndependentlyOptional() {
        let partial = MemoryReading(physicalFootprintBytes: 1234)
        XCTAssertNil(partial.availableBeforeKillBytes)
        XCTAssertEqual(partial.physicalFootprintBytes, 1234)
        XCTAssertNil(partial.residentBytes)
        // Unknown before-kill must not read as pressure, even with other fields present.
        XCTAssertFalse(partial.isUnderPressure(floorBytes: 1 << 40))
    }

    // MARK: - runtime availability

    func testUnknownAvailabilityIsNotUnavailable() {
        let notYetProbed = JITAvailability.unknown
        let refused = JITAvailability.unavailable(reason: "no debugger attached")
        XCTAssertNotEqual(notYetProbed, refused)
        XCTAssertFalse(notYetProbed.isAvailable)
        XCTAssertFalse(refused.isAvailable)
        XCTAssertTrue(JITAvailability.available(regionBytes: 1).isAvailable)
    }

    // MARK: - snapshots

    /// LESSON: a snapshot must not be saved merely because time passed.
    ///
    /// The evidence type must require every check, so a caller cannot save without having
    /// gathered them.
    func testSnapshotEvidenceRequiresEveryCheck() {
        let required = Set(SnapshotHealthEvidence.requiredChecks)
        for check in ["guest_alive", "boot_completed", "display_attached",
                      "presented_frame", "systemui_not_absent",
                      "launcher_not_absent", "memory_not_critical"] {
            XCTAssertTrue(required.contains(check),
                          "the snapshot gate must include '\(check)'")
        }
        XCTAssertEqual(SnapshotHealthEvidence.requiredChecks.count, required.count,
                       "no duplicate checks")

        let evidence = SnapshotHealthEvidence(
            guestAlive: .yes,
            bootCompleted: true,
            displayAttached: true,
            framesPresented: 42,
            services: GuestServices(systemServer: .yes, surfaceFlinger: .yes,
                                    systemUI: .yes, launcher: .yes),
            memory: MemoryReading(availableBeforeKillBytes: 1024 * 1024 * 1024))
        XCTAssertTrue(evidence.framesPresented > 0)
        XCTAssertTrue(evidence.services.systemUI.isConfirmedPresent)
    }
}
