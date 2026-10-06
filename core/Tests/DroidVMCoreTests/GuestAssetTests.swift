// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The guest asset inventory, the manifest, and validation.
///
/// The catalogue is the project's record of what Android needs on disk and what DroidVM is
/// allowed to do with each piece. These tests are what stop it going stale or quietly
/// acquiring an asset nobody cleared.
final class GuestAssetTests: XCTestCase {

    // MARK: - catalogue completeness

    func testEveryEntryDocumentsItself() {
        for asset in GuestAssetCatalog.all {
            XCTAssertFalse(asset.filename.isEmpty, "\(asset.role) has no filename")
            XCTAssertFalse(asset.purpose.isEmpty,
                           "\(asset.role) has no stated purpose")
            XCTAssertFalse(asset.origin.isEmpty,
                           "\(asset.role) does not say where it comes from")
            XCTAssertFalse(asset.license.isEmpty,
                           "\(asset.role) does not state a licence")
            XCTAssertGreaterThan(asset.approximateBytes, 0,
                                 "\(asset.role) has no size estimate")
        }
    }

    func testRolesAreUnique() {
        let roles = GuestAssetCatalog.all.map(\.role)
        XCTAssertEqual(roles.count, Set(roles).count, "duplicate catalogue entry")
        XCTAssertEqual(Set(roles), Set(GuestAssetRole.allCases),
                       "every role must have exactly one entry")
    }

    /// A boot attempt cannot proceed without these, and the list is what Phase 1 has to
    /// obtain before it can try.
    func testBootEssentialsAreMarked() {
        let required = Set(GuestAssetCatalog.requiredForBootAttempt.map(\.role))
        for role in [GuestAssetRole.firmwareCode, .firmwareVars,
                     .systemDisk, .userdataSeed] {
            XCTAssertTrue(required.contains(role), "\(role) must be required for boot")
        }
        // The snapshot is an optimisation, not a prerequisite.
        XCTAssertFalse(required.contains(.snapshotPart),
                       "a pre-booted snapshot must never be required to boot")
        XCTAssertGreaterThan(GuestAssetCatalog.totalRequiredBytes, 0)
    }

    /// Redistribution is the licensing decision, so it is asserted rather than assumed.
    func testRedistributionIsExplicitAndConservative() {
        // DroidVM may not hand out the guest disks until the kernel source offer exists.
        XCTAssertFalse(GuestAssetValidator.mayRedistribute(.systemDisk))
        XCTAssertFalse(GuestAssetValidator.mayRedistribute(.userdataSeed))
        XCTAssertFalse(GuestAssetValidator.mayRedistribute(.snapshotPart))

        // Firmware it may.
        XCTAssertTrue(GuestAssetValidator.mayRedistribute(.firmwareCode))
        XCTAssertTrue(GuestAssetValidator.mayRedistribute(.firmwareVars))

        // Anything withheld must say what the obligation is.
        for asset in GuestAssetCatalog.notRedistributable {
            XCTAssertFalse(asset.sourceObligation.isEmpty,
                           "\(asset.role) is not redistributable but states no obligation")
        }
    }

    /// The kernel inside a guest image is GPLv2, which is the obligation that makes the
    /// guest disks non-redistributable. If this ever reads otherwise, the licensing record
    /// has drifted.
    func testGuestDiskLicenceRecordsTheKernelObligation() {
        let disk = try? XCTUnwrap(GuestAssetCatalog.descriptor(for: .systemDisk))
        XCTAssertTrue(disk?.license.contains("GPL-2.0") ?? false,
                      "the system disk's licence must name the GPLv2 kernel")
        XCTAssertTrue(disk?.sourceObligation.contains("source") ?? false,
                      "and must state the source obligation")
    }

    /// The debugger script is the one asset whose provenance caused a real finding: the
    /// file the reference implementation ships is byte-identical to a copy of StikDebug's
    /// AGPL-3.0 script, with no attribution header. The catalogue entry must keep recording
    /// that, so nobody re-imports it by accident.
    func testDebuggerScriptRecordsTheProvenanceFinding() throws {
        let script = try XCTUnwrap(GuestAssetCatalog.descriptor(for: .debuggerScript))
        let combined = script.license + " " + script.origin + " " + script.sourceObligation
        XCTAssertTrue(combined.contains("AGPL"),
                      "the debugger script entry must record the AGPL-3.0 risk")
        XCTAssertTrue(combined.contains("MPL") || combined.contains("GPL"),
                      "and must name a licence DroidVM can actually use")
        for marker in DroidVMIdentity.foreignBrandMarkers {
            XCTAssertFalse(script.filename.lowercased().contains(marker.lowercased()),
                           "and must not carry the other project's name into "
                           + "DroidVM's tree")
        }
        XCTAssertFalse(script.requiredForBoot,
                       "an external debugger brings its own script, so boot must not "
                       + "depend on ours")
    }

    // MARK: - manifest

    func testManifestRoundTripsAndDescribesAShape() throws {
        let manifest = GuestManifest(
            generation: "2026-10-07T00:00:00Z",
            image: .init(file: "vda.qcow2", sha256: String(repeating: "a", count: 64),
                         size: 1234),
            snapshot: .init(parts: ["vdb-snapshot.qcow2.gz.0", "vdb-snapshot.qcow2.gz.1"],
                            sha256: String(repeating: "b", count: 64), size: 5678),
            guestMiB: 4096, xres: 360, yres: 640, smp: 4, cpu: "cortex-a72")

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(GuestManifest.self, from: encoded)
        XCTAssertEqual(decoded, manifest)

        let shape = manifest.machineShape
        XCTAssertEqual(shape.guestRAMBytes, 4096 << 20)
        XCTAssertEqual(shape.displaySize, DisplaySize(width: 360, height: 640))
        XCTAssertEqual(shape.cpuCount, 4)
    }

    /// Restoring a snapshot into a differently-shaped machine is refused by the engine, so
    /// the check belongs here -- before a two-gigabyte download, not after.
    func testManifestCompatibilityIsCheckedBeforeDownloading() {
        let manifest = GuestManifest(
            generation: "g", image: .init(file: "vda.qcow2", sha256: "a", size: 1),
            snapshot: nil, guestMiB: 4096, xres: 360, yres: 640,
            smp: 4, cpu: "cortex-a72")

        XCTAssertTrue(manifest.isCompatible(with: manifest.machineShape))

        var moreRAM = manifest.machineShape
        moreRAM.guestRAMBytes = 8 << 30
        XCTAssertFalse(manifest.isCompatible(with: moreRAM), "RAM size is part of identity")

        var moreCPUs = manifest.machineShape
        moreCPUs.cpuCount = 6
        XCTAssertFalse(manifest.isCompatible(with: moreCPUs), "vCPU count too")

        var otherSize = manifest.machineShape
        otherSize.displaySize = DisplaySize(width: 720, height: 1280)
        XCTAssertFalse(manifest.isCompatible(with: otherSize), "display size too")

        var otherCPU = manifest.machineShape
        otherCPU.cpuModel = "max"
        XCTAssertFalse(manifest.isCompatible(with: otherCPU), "CPU model too")
    }

    // MARK: - machine shape stamps

    func testMachineShapeStampRoundTrips() throws {
        let shape = QEMUMachineShape(cpuModel: "cortex-a72", cpuCount: 4,
                                     guestRAMBytes: 4 << 30,
                                     displayMode: .software,
                                     displaySize: DisplaySize(width: 360, height: 640),
                                     audioEnabled: true, networkEnabled: true)
        let restored = try XCTUnwrap(QEMUMachineShape(stamp: shape.stamp))
        XCTAssertEqual(restored, shape)

        // A stamp is stored beside a snapshot, so an unreadable one must not silently
        // become a default that happens to match.
        XCTAssertNil(QEMUMachineShape(stamp: ""))
        XCTAssertNil(QEMUMachineShape(stamp: "cpu=cortex-a72;smp=four"))
        XCTAssertNil(QEMUMachineShape(stamp: "garbage"))

        // And it must actually distinguish the things the engine refuses across.
        var other = shape
        other.displayMode = .gpu
        XCTAssertNotEqual(other.stamp, shape.stamp)
    }

    // MARK: - validation

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidvm-asset-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    func testValidationAcceptsAMatchingFile() throws {
        let data = Data("droidvm".utf8)
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = GuestManifest.Entry(file: "x", sha256: SHA256.hexDigest(data),
                                        size: Int64(data.count))
        XCTAssertNoThrow(try GuestAssetValidator.validate(role: .firmwareCode,
                                                          at: url, expected: entry))
    }

    /// Size first: it is cheap, and it catches a truncated download without reading it all.
    func testValidationRejectsWrongSize() throws {
        let url = try temporaryFile(Data("short".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = GuestManifest.Entry(file: "x", sha256: SHA256.hexDigest(Data("short".utf8)),
                                        size: 9_999)

        XCTAssertThrowsError(try GuestAssetValidator.validate(role: .systemDisk,
                                                              at: url, expected: entry)) { error in
            guard case GuestAssetValidationError.sizeMismatch(let role, let expected, let actual)
                = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(role, .systemDisk)
            XCTAssertEqual(expected, 9_999)
            XCTAssertEqual(actual, 5)
        }
    }

    func testValidationRejectsWrongDigest() throws {
        let url = try temporaryFile(Data("droidvm".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = GuestManifest.Entry(file: "x", sha256: String(repeating: "0", count: 64),
                                        size: 7)

        XCTAssertThrowsError(try GuestAssetValidator.validate(role: .systemDisk,
                                                              at: url, expected: entry)) { error in
            guard case GuestAssetValidationError.digestMismatch = error else {
                return XCTFail("a same-sized file with the wrong contents must be refused, "
                               + "got \(error)")
            }
        }
    }

    // MARK: - the development provider

    func testLocalProviderIsMarkedNonProduction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidvm-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = LocalDirectoryAssetProvider(directory: directory)
        XCTAssertFalse(provider.isProductionSource,
                       "a local directory must never present itself as production")
        XCTAssertTrue(provider.sourceDescription.contains(directory.path))

        // Nothing there yet.
        XCTAssertThrowsError(try provider.localURL(for: .firmwareCode)) { error in
            guard case GuestAssetValidationError.missing(let role, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(role, .firmwareCode)
        }
        XCTAssertThrowsError(try provider.ensureAvailable([.firmwareCode, .systemDisk]))

        // Populate one and it resolves.
        let filename = try XCTUnwrap(GuestAssetCatalog.descriptor(for: .firmwareCode)).filename
        try Data("fw".utf8).write(to: directory.appendingPathComponent(filename))
        XCTAssertNoThrow(try provider.localURL(for: .firmwareCode))
        XCTAssertThrowsError(try provider.ensureAvailable([.firmwareCode, .systemDisk]),
                            "one missing asset must still fail the whole check")
    }
}
