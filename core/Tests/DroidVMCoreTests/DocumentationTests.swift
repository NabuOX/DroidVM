// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// Documentation that cannot drift from the code.
///
/// ARCHITECTURE.md is the specification this package implements. A specification that
/// silently disagrees with the code is worse than no specification, because people
/// trust it. So the parts that matter are asserted.
final class DocumentationTests: XCTestCase {

    // MARK: - locating the repository

    /// Walk up from this source file to the repository root.
    ///
    /// Tests run from an unpredictable working directory, so the path is derived from
    /// `#filePath` instead: <root>/core/Tests/DroidVMCoreTests/DocumentationTests.swift
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DroidVMCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // core
            .deletingLastPathComponent()   // <root>
    }

    private struct MissingDocument: Error, CustomStringConvertible {
        let path: String
        var description: String { "required document is missing: \(path)" }
    }

    private func read(_ relativePath: String) throws -> String {
        let url = Self.repositoryRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A missing required document is a failure, not a skip: it is exactly the
            // drift this test exists to catch.
            XCTFail("expected \(relativePath) in the repository root; not found at \(url.path)")
            throw MissingDocument(path: relativePath)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - the lifecycle specification

    /// Every lifecycle state must be named in ARCHITECTURE.md.
    ///
    /// Adding a state without documenting it fails here, which is the point: the
    /// lifecycle is the product's vocabulary, not an implementation detail.
    func testArchitectureDocumentsEveryLifecycleState() throws {
        let architecture = try read("ARCHITECTURE.md")
        for state in LifecycleState.allCases {
            XCTAssertTrue(architecture.contains(state.rawValue),
                          "ARCHITECTURE.md does not mention lifecycle state "
                          + "'\(state.rawValue)'; the specification and the code "
                          + "must agree")
        }
    }

    /// The snapshot gate's checks are asserted against the document, so dropping one
    /// from either side fails.
    func testArchitectureDocumentsEverySnapshotCheck() throws {
        let architecture = try read("ARCHITECTURE.md")
        for check in SnapshotHealthEvidence.requiredChecks {
            XCTAssertTrue(architecture.contains(check),
                          "ARCHITECTURE.md does not list the snapshot gate check "
                          + "'\(check)'")
        }
    }

    // MARK: - required documents

    func testProjectDocumentsExist() throws {
        for doc in ["README.md", "ARCHITECTURE.md", "THIRD_PARTY.md",
                    "docs/roadmap.md", "docs/component-inventory.md",
                    "docs/licensing.md", "docs/guest-assets.md", "docs/build.md"] {
            let text = try read(doc)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(doc) is empty")
        }
    }

    /// The guest asset catalogue is the authority; `docs/guest-assets.md` is its
    /// human-readable form. Asserted in both directions, because a table in a document goes
    /// stale silently while a tested type does not.
    func testGuestAssetDocumentMatchesTheCatalogue() throws {
        let doc = try read("docs/guest-assets.md")

        for asset in GuestAssetCatalog.all {
            // The directory-flavoured entry is written as `pc-bios/` in the document.
            let stem = String(asset.filename.split(separator: ".").first ?? "")
            XCTAssertTrue(doc.contains(asset.filename) || doc.contains(stem),
                          "docs/guest-assets.md does not mention \(asset.filename)")
        }

        // Everything withheld must have its filename and its reason stated.
        for asset in GuestAssetCatalog.notRedistributable {
            XCTAssertTrue(doc.contains(asset.filename),
                          "withheld asset \(asset.filename) must appear in the document")
        }
        XCTAssertTrue(doc.contains("GPL-2.0"),
                      "the kernel source obligation must be stated")
        XCTAssertTrue(doc.contains("AGPL"),
                      "the debugger-script provenance finding must be stated")
    }

    /// Provenance has to be recorded, not hidden. THIRD_PARTY.md is where reused code
    /// is accounted for, and it is only useful if it records the things that matter.
    func testThirdPartyRecordKeepsItsColumns() throws {
        let thirdParty = try read("THIRD_PARTY.md")
        for column in ["Source", "License", "Reuse", "Destination"] {
            XCTAssertTrue(thirdParty.contains(column),
                          "THIRD_PARTY.md lost its '\(column)' column")
        }
        // The two obligations that decide how DroidVM may be distributed at all.
        XCTAssertTrue(thirdParty.contains("GPL"),
                      "THIRD_PARTY.md must record the GPL obligations")
    }

    /// The README must state the distribution consequence plainly, because it is not
    /// something a reader would guess from the source alone.
    func testReadmeStatesTheDistributionConstraint() throws {
        let readme = try read("README.md")
        let lowered = readme.lowercased()
        XCTAssertTrue(lowered.contains("gpl"),
                      "README must state the licence")
        XCTAssertTrue(lowered.contains("app store") || lowered.contains("sideload"),
                      "README must state how this can be distributed")
    }
}
