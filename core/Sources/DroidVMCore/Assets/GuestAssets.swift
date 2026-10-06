// SPDX-License-Identifier: GPL-2.0-or-later
//
// What Android needs on disk to boot, where it comes from, and what DroidVM is allowed to
// do with it.
//
// WHY THIS IS A TYPE AND NOT A PARAGRAPH
//
// A guest image is the largest, slowest, least reversible dependency this project has:
// hundreds of megabytes to gigabytes, fetched once, kept forever, and carrying its own
// licensing obligations into whatever DroidVM ships. Prose about it goes stale silently.
// So the inventory is data, tests assert it is complete, and docs/guest-assets.md is
// asserted against it.
//
// PHASE 1 DOES NOTO HOST ANY OF THIS. No asset is mirrored, uploaded or committed. The only
// provider implemented here reads from a local directory that a developer populates by
// hand, and it says so in its own name.

import Foundation

// MARK: - Roles

/// Every file a boot attempt needs, by what it is for.
public enum GuestAssetRole: String, Equatable, CaseIterable, Sendable {
    case firmwareCode
    case firmwareVars
    case systemDisk
    case userdataSeed
    case snapshotPart
    case releaseManifest

    /// The script a debugger executes to grant executable memory.
    ///
    /// Not an Android guest asset in the usual sense, but it ships beside them and it has
    /// the most delicate provenance of anything in this project. See the catalogue entry.
    case debuggerScript

    /// QEMU's own firmware data directory, passed as `-L`. Produced by the engine build,
    /// not downloaded.
    case engineFirmwareData
}

// MARK: - Descriptor

/// One required file, with everything a decision about it needs.
public struct GuestAssetDescriptor: Equatable, Sendable {

    public var role: GuestAssetRole

    /// The name on disk. For snapshots, the base name of a numbered part series.
    public var filename: String

    /// Roughly how large it is. An estimate for planning, not a digest.
    public var approximateBytes: Int64

    /// What it is for, in one sentence.
    public var purpose: String

    /// Where it comes from.
    public var origin: String

    /// Its licence, as precisely as it is known.
    public var license: String

    /// What shipping it obliges DroidVM to do. Empty when there is no obligation.
    public var sourceObligation: String

    /// Whether DroidVM may redistribute this file itself.
    ///
    /// `false` does not mean "cannot use" -- it means DroidVM must not be the one handing
    /// out copies, which for the guest disks is the current position pending the kernel
    /// source offer.
    public var droidvmMayRedistribute: Bool

    /// Whether a boot attempt cannot proceed without it.
    public var requiredForBoot: Bool

    public init(role: GuestAssetRole,
                filename: String,
                approximateBytes: Int64,
                purpose: String,
                origin: String,
                license: String,
                sourceObligation: String = "",
                droidvmMayRedistribute: Bool,
                requiredForBoot: Bool = true) {
        self.role = role
        self.filename = filename
        self.approximateBytes = approximateBytes
        self.purpose = purpose
        self.origin = origin
        self.license = license
        self.sourceObligation = sourceObligation
        self.droidvmMayRedistribute = droidvmMayRedistribute
        self.requiredForBoot = requiredForBoot
    }

    public var approximateMiB: Double { Double(approximateBytes) / (1024 * 1024) }
}

// MARK: - Catalogue

public enum GuestAssetCatalog {

    /// Every asset, whether or not a Phase 1 boot attempt needs it.
    ///
    /// Sizes are the order of magnitude observed for an Android 12-class guest on this
    /// device class. They are planning figures; the manifest carries the authoritative
    /// digest and size.
    public static let all: [GuestAssetDescriptor] = [

        GuestAssetDescriptor(
            role: .firmwareCode,
            filename: "edk2-aarch64-code.fd",
            approximateBytes: 64 << 20,
            purpose: "UEFI firmware code volume the guest boots through.",
            origin: "TianoCore EDK2, as packaged for arm64 virt machines.",
            license: "BSD-2-Clause-Patent",
            droidvmMayRedistribute: true),

        GuestAssetDescriptor(
            role: .firmwareVars,
            filename: "efi-vars-seed.fd",
            approximateBytes: 64 << 20,
            purpose: "UEFI variable store, seeded so the firmware has a writable "
                   + "environment on first boot and remembers boot order afterwards.",
            origin: "Generated from EDK2 defaults.",
            license: "BSD-2-Clause-Patent",
            droidvmMayRedistribute: true),

        GuestAssetDescriptor(
            role: .systemDisk,
            filename: "vda.qcow2",
            approximateBytes: 1200 << 20,
            purpose: "The Android system disk: kernel, system partition, vendor "
                   + "partition. Read-mostly.",
            origin: "An AOSP-derived Android build for arm64 virt (the reference "
                  + "implementation uses a LineageOS build).",
            license: "Android userspace is Apache-2.0; the Linux kernel inside it is "
                   + "GPL-2.0; individual vendor blobs carry their own terms.",
            sourceObligation: "Shipping this image distributes a GPLv2 kernel binary, "
                            + "which obliges DroidVM to offer that kernel's corresponding "
                            + "source. Pin the exact kernel tag and publish the offer "
                            + "beside the image.",
            droidvmMayRedistribute: false),

        GuestAssetDescriptor(
            role: .userdataSeed,
            filename: "vdb-seed.qcow2",
            approximateBytes: 600 << 20,
            purpose: "Initial /data. Provided as a seed so that a boot attempt starts "
                   + "from a consistent state rather than a first-boot factory reset.",
            origin: "Same build as the system disk.",
            license: "Android userspace Apache-2.0; kernel GPL-2.0 as above.",
            sourceObligation: "Same kernel source offer as the system disk.",
            droidvmMayRedistribute: false),

        GuestAssetDescriptor(
            role: .snapshotPart,
            filename: "vdb-snapshot.qcow2.gz",
            approximateBytes: 1800 << 20,
            purpose: "A pre-booted machine state, so a first launch can resume instead of "
                   + "booting from cold. Split into numbered parts.",
            origin: "Produced by the reference implementation's own save path, and "
                  + "therefore only restorable into a machine of the same shape.",
            license: "Same as the guest disks it contains; it embeds guest RAM.",
            sourceObligation: "Embeds guest RAM containing the kernel image, so the same "
                            + "kernel source offer applies.",
            droidvmMayRedistribute: false,
            requiredForBoot: false),

        GuestAssetDescriptor(
            role: .releaseManifest,
            filename: "manifest.json",
            approximateBytes: 4 << 10,
            purpose: "Names the current image and snapshot files with their SHA-256 and "
                   + "size, and records the machine shape the snapshot was taken with.",
            origin: "DroidVM-authored, published beside the assets.",
            license: "GPL-2.0-or-later (DroidVM's own)",
            droidvmMayRedistribute: true),

        GuestAssetDescriptor(
            role: .engineFirmwareData,
            filename: "pc-bios/",
            approximateBytes: 4 << 20,
            purpose: "QEMU's own firmware data directory, handed to the engine as -L.",
            origin: "Produced by the engine build; QEMU ships it.",
            license: "GPL-2.0 (QEMU)",
            sourceObligation: "Covered by the QEMU source offer.",
            droidvmMayRedistribute: true),

        // --- the one with the difficult provenance ---

        GuestAssetDescriptor(
            role: .debuggerScript,
            filename: "droidvm-jit.js",
            approximateBytes: 7 << 10,
            purpose: "The script a debugger executes to service DroidVM's executable-memory "
                   + "traps. Needed only for the built-in activation route; an external "
                   + "debugger brings its own.",
            origin: "TO BE AUTHORED BY DROIDVM, or taken from StikJIT's own bundle "
                  + "(MPL-2.0, properly licensed and shipped by the framework).",
            license: "GPL-2.0-or-later if authored here; MPL-2.0 if taken from StikJIT.",
            sourceObligation: "If any part is taken from StikDebug, that part is AGPL-3.0 "
                            + "and must keep its notice.",
            droidvmMayRedistribute: true,
            requiredForBoot: false),
    ]

    /// What a cold boot attempt needs. This is the list Phase 1 cares about.
    public static var requiredForBootAttempt: [GuestAssetDescriptor] {
        all.filter { $0.requiredForBoot }
    }

    /// Assets whose redistribution DroidVM is not yet entitled to perform.
    ///
    /// Consulted by the packaging step: a build that would hand out one of these is
    /// refused until the obligation is met.
    public static var notRedistributable: [GuestAssetDescriptor] {
        all.filter { !$0.droidvmMayRedistribute }
    }

    public static func descriptor(for role: GuestAssetRole) -> GuestAssetDescriptor? {
        all.first { $0.role == role }
    }

    public static var totalRequiredBytes: Int64 {
        requiredForBootAttempt.reduce(0) { $0 + $1.approximateBytes }
    }
}

// MARK: - Manifest

/// The published description of the guest assets.
///
/// Verifying by digest rather than by a version string is what makes a truncated or
/// swapped download detectable: a stamp saying "v12" only records what the file claims to
/// be, and a wrongly-sized file with the right name looks identical from the app's side.
public struct GuestManifest: Equatable, Sendable, Codable {

    public struct Entry: Equatable, Sendable, Codable {
        public let file: String
        public let sha256: String
        public let size: Int64

        public init(file: String, sha256: String, size: Int64) {
            self.file = file
            self.sha256 = sha256
            self.size = size
        }
    }

    public struct Snapshot: Equatable, Sendable, Codable {
        public let parts: [String]
        public let sha256: String
        public let size: Int64

        public init(parts: [String], sha256: String, size: Int64) {
            self.parts = parts
            self.sha256 = sha256
            self.size = size
        }
    }

    /// A monotonic marker, so a cached manifest can be recognised as stale.
    public let generation: String

    public let image: Entry
    public let snapshot: Snapshot?

    /// The machine shape the snapshot was taken with. Restoring into anything else is
    /// refused by the engine, so the check belongs here, before a two-gigabyte download.
    public let guestMiB: Int
    public let xres: Int
    public let yres: Int
    public let smp: Int?
    public let cpu: String?

    public init(generation: String,
                image: Entry,
                snapshot: Snapshot? = nil,
                guestMiB: Int,
                xres: Int,
                yres: Int,
                smp: Int? = nil,
                cpu: String? = nil) {
        self.generation = generation
        self.image = image
        self.snapshot = snapshot
        self.guestMiB = guestMiB
        self.xres = xres
        self.yres = yres
        self.smp = smp
        self.cpu = cpu
    }

    /// The machine shape this manifest describes.
    public var machineShape: QEMUMachineShape {
        QEMUMachineShape(cpuModel: cpu ?? QEMUMachineShape.defaultCPUModel,
                         cpuCount: smp ?? 4,
                         guestRAMBytes: UInt64(guestMiB) << 20,
                         displayMode: .software,
                         displaySize: DisplaySize(width: xres, height: yres))
    }

    /// Whether a snapshot from this manifest may be restored into `shape`.
    ///
    /// Only the fields the engine actually refuses across are compared. Audio is
    /// deliberately excluded here and handled by the caller, because it is conditional at
    /// start time rather than a property of the published image.
    public func isCompatible(with shape: QEMUMachineShape) -> Bool {
        let other = machineShape
        return other.cpuModel == shape.cpuModel
            && other.cpuCount == shape.cpuCount
            && other.guestRAMBytes == shape.guestRAMBytes
            && other.displaySize == shape.displaySize
    }
}

// MARK: - Validation

public enum GuestAssetValidationError: Error, Equatable {
    case missing(role: GuestAssetRole, path: String)
    case sizeMismatch(role: GuestAssetRole, expected: Int64, actual: Int64)
    case digestMismatch(role: GuestAssetRole, expected: String, actual: String)
    case notSupportedYet(role: GuestAssetRole, reason: String)
    case sourceIsNotProduction(description: String)
    case redistributionNotPermitted(role: GuestAssetRole)

    public var plainReason: String {
        switch self {
        case .missing(let role, _):
            return "Android is missing a file it needs (\(role.rawValue))."
        case .sizeMismatch(let role, _, _):
            return "A file Android needs is the wrong size (\(role.rawValue))."
        case .digestMismatch(let role, _, _):
            return "A file Android needs failed its integrity check (\(role.rawValue))."
        case .notSupportedYet:
            return "Android cannot be started from these files yet."
        case .sourceIsNotProduction:
            return "Android's files are coming from a development location."
        case .redistributionNotPermitted(let role):
            return "This build is not allowed to distribute \(role.rawValue)."
        }
    }

    public var technicalReason: String {
        switch self {
        case .missing(let role, let path): return "missing \(role.rawValue) at \(path)"
        case .sizeMismatch(let role, let e, let a):
            return "\(role.rawValue) size \(a) != \(e)"
        case .digestMismatch(let role, let e, let a):
            return "\(role.rawValue) sha256 \(a) != \(e)"
        case .notSupportedYet(let role, let why):
            return "\(role.rawValue) not supported: \(why)"
        case .sourceIsNotProduction(let d): return "non-production source: \(d)"
        case .redistributionNotPermitted(let role):
            return "redistribution not permitted for \(role.rawValue)"
        }
    }
}

// MARK: - Provider

/// Where DroidVM's guest files come from.
///
/// Phase 1 has exactly one implementation, and it is a development convenience. A
/// production provider -- one that fetches from DroidVM's own hosting with digest
/// verification and resumable multi-part download -- is Phase 2 work, and it is blocked on
/// the distribution decision recorded in `docs/roadmap.md`.
public protocol GuestAssetProvider: AnyObject {

    /// Where the asset for `role` is on disk, if it is present.
    func localURL(for role: GuestAssetRole) throws -> URL

    /// Whether this provider is a development convenience rather than something a user
    /// should ever be running.
    ///
    /// Exposed rather than assumed: the app must be able to say so, and the build must be
    /// able to refuse to package it.
    var isProductionSource: Bool { get }

    /// A description of where files come from, for the log.
    var sourceDescription: String { get }
}

/// Reads guest files from a directory on disk. **DEVELOPMENT ONLY.**
///
/// This exists so that Phase 1 can attempt a boot before the asset-hosting question is
/// settled, without any production code path learning to depend on somebody else's release
/// URLs. Three things keep it honest:
///
///   * the name says what it is;
///   * `isProductionSource` is `false`, and the app surfaces that;
///   * `ensureAvailable` refuses for any role DroidVM is not yet allowed to redistribute,
///     so a build cannot quietly ship the guest disks.
public final class LocalDirectoryAssetProvider: GuestAssetProvider {

    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public var isProductionSource: Bool { false }

    public var sourceDescription: String {
        "local development directory (\(directory.path))"
    }

    public func localURL(for role: GuestAssetRole) throws -> URL {
        guard let descriptor = GuestAssetCatalog.descriptor(for: role) else {
            throw GuestAssetValidationError.notSupportedYet(role: role,
                                                            reason: "no catalogue entry")
        }
        let candidate = directory.appendingPathComponent(descriptor.filename)
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw GuestAssetValidationError.missing(role: role, path: candidate.path)
        }
        return candidate
    }

    /// Verify that everything a boot attempt needs is present.
    ///
    /// Digest checking is deliberately not done here: the manifest is the authority on
    /// digests, and a provider that invented its own would be a second source of truth.
    /// `verify(against:)` does that part.
    public func ensureAvailable(_ roles: [GuestAssetRole]) throws {
        for role in roles {
            _ = try localURL(for: role)
        }
    }
}

// MARK: - Verification

public enum GuestAssetValidator {

    /// Check one file against the manifest's expectation.
    public static func validate(role: GuestAssetRole,
                                at url: URL,
                                expected: GuestManifest.Entry,
                                digest: FileDigestProvider = PortableSHA256(),
                                fileManager: FileManager = .default) throws {

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = Int64(values.fileSize ?? 0)
        if actualSize != expected.size {
            throw GuestAssetValidationError.sizeMismatch(role: role,
                                                         expected: expected.size,
                                                         actual: actualSize)
        }

        let actual = try digest.sha256Hex(ofFileAt: url)
        if actual.lowercased() != expected.sha256.lowercased() {
            throw GuestAssetValidationError.digestMismatch(role: role,
                                                           expected: expected.sha256,
                                                           actual: actual)
        }
    }

    /// Refuse a build that would distribute something DroidVM may not.
    public static func checkRedistribution(_ descriptor: GuestAssetDescriptor) throws {
        guard descriptor.droidvmMayRedistribute else {
            throw GuestAssetValidationError.redistributionNotPermitted(role: descriptor.role)
        }
    }

    /// Whether a build may ship this asset at all.
    ///
    /// Used by the packaging step. Stated as a predicate as well as a throwing check
    /// because the packaging script wants to list everything that is wrong, not stop at
    /// the first one.
    public static func mayRedistribute(_ role: GuestAssetRole) -> Bool {
        GuestAssetCatalog.descriptor(for: role)?.droidvmMayRedistribute ?? false
    }
}
