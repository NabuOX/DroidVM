// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVM product identity. Provisional until Phase 1 registers the real values.
//
// These are kept in one place and asserted by tests so that no Husk identifier can
// creep into the tree by accident. DroidVM is an independent application: it must
// not present another project's name, bundle identifier, or icons to the user.

public enum DroidVMIdentity {

    /// MARKETING / DISPLAY NAME. Provisional.
    public static let displayName = "DroidVM"

    /// The app's bundle identifier. Provisional: pick the final reverse-DNS value
    /// before the first signed install, because changing it later breaks every
    /// existing install and every saved path.
    public static let bundleIdentifier = "com.droidvm.app"

    /// The JIT helper app extension, if DroidVM keeps a built-in activation route.
    /// It must sit under the app's identifier.
    public static let helperBundleIdentifier = bundleIdentifier + ".JITHelper"

    /// Whether the identifiers above are placeholders. Phase 1 flips this to false
    /// once they are registered and the first build has been signed.
    public static let identifiersAreProvisional = true

    /// Marker used by tests and packaging checks to catch foreign branding.
    ///
    /// "Husk" appears in this file and in THIRD_PARTY.md on purpose -- provenance
    /// must be documented, not hidden. Everywhere ELSE it is a bug.
    public static let foreignBrandMarkers = ["Husk", "husk"]

    /// Files permitted to name a foreign project, because provenance must be
    /// recorded rather than concealed.
    public static let provenanceFiles = [
        "THIRD_PARTY.md",
        "docs/licensing.md",
        "docs/component-inventory.md",
        "docs/guest-assets.md",
        "Sources/DroidVMCore/Identity.swift",
    ]
}
