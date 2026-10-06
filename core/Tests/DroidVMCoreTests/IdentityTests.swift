// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// DroidVM is an independent product. These assertions keep the identity it presents
/// to a user from accidentally becoming another project's.
final class IdentityTests: XCTestCase {

    /// The bundle identifier must not be inherited from the reference implementation.
    func testBundleIdentifierIsDroidVMOwn() {
        let id = DroidVMIdentity.bundleIdentifier
        XCTAssertTrue(id.hasPrefix("com.droidvm."),
                      "bundle id '\(id)' is not in DroidVM's namespace")
        for marker in DroidVMIdentity.foreignBrandMarkers {
            XCTAssertFalse(id.lowercased().contains(marker.lowercased()),
                           "bundle id '\(id)' carries foreign branding")
        }
    }

    /// The JIT helper extension's identifier has to sit under the app's, or iOS will
    /// not associate them.
    func testHelperIdentifierNestsUnderTheApp() {
        XCTAssertTrue(DroidVMIdentity.helperBundleIdentifier
                        .hasPrefix(DroidVMIdentity.bundleIdentifier + "."),
                      "the helper extension's identifier must be nested under the app's")
    }

    func testDisplayNameIsNotForeign() {
        XCTAssertFalse(DroidVMIdentity.displayName.isEmpty)
        for marker in DroidVMIdentity.foreignBrandMarkers {
            XCTAssertFalse(DroidVMIdentity.displayName
                            .lowercased().contains(marker.lowercased()),
                           "the product name carries foreign branding")
        }
    }

    /// The identifiers are placeholders right now, and the code should say so rather
    /// than leaving a reader to wonder whether they are load-bearing.
    func testPlaceholderIsDeclaredAsSuch() {
        XCTAssertTrue(DroidVMIdentity.identifiersAreProvisional,
                      "Phase 0 ships provisional identifiers; flip this when they are "
                      + "registered and the build is signed")
    }

    /// The list of files allowed to name another project must be small and explicit.
    /// Provenance is documented; branding is not permitted to spread.
    func testProvenanceWhitelistIsExplicit() {
        XCTAssertFalse(DroidVMIdentity.provenanceFiles.isEmpty)
        for path in DroidVMIdentity.provenanceFiles {
            XCTAssertFalse(path.hasPrefix("/"),
                           "\(path) should be repository-relative")
        }
        XCTAssertTrue(DroidVMIdentity.provenanceFiles.contains("THIRD_PARTY.md"),
                      "THIRD_PARTY.md is where provenance must live")
    }
}
