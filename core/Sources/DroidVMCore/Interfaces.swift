// SPDX-License-Identifier: GPL-2.0-or-later
//
// The DroidVM-owned boundaries between orchestration and engine.
//
// These protocols exist so the UI and the coordinators never touch an engine
// directly. Phase 1 provides the first real conformances; Phase 0 declares the
// contract they must satisfy, because a boundary decided after the code is written
// is a boundary shaped by the code.
//
// DESIGN NOTES THAT ARE NOT NEGOTIABLE
//
//  * Nothing here mentions QEMU, EGL, Metal, virtio, or an argv. Those belong to an
//    adapter behind these protocols, so the engine can be replaced or wrapped without
//    the orchestration layer noticing.
//  * Every call is `async`. A blocking call reachable from SwiftUI is a hung UI, and
//    the reference implementation reached that state more than once.
//  * Anything that can fail is `throws`, and failure carries a reason rather than a
//    bare false. A boolean return that means "it did not work" is how a diagnosis
//    gets lost.

import Foundation

// MARK: - Configuration

/// The size of the guest display, in guest pixels.
public struct DisplaySize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Everything the engine needs to bring up a machine.
///
/// This is DroidVM's vocabulary, not a command line. Translating it into whatever the
/// engine actually wants is the adapter's job.
public struct VMConfiguration: Equatable, Sendable {

    /// Memory to give the guest. Chosen by policy, not by the user.
    public var guestRAMBytes: UInt64

    public var cpuCount: Int
    public var displaySize: DisplaySize
    public var audioEnabled: Bool
    public var networkEnabled: Bool

    /// Whether starting the machine may resume a saved one. Restoring is an
    /// optimisation; it must never be a correctness requirement.
    public var mayRestoreSnapshot: Bool

    public init(guestRAMBytes: UInt64,
                cpuCount: Int,
                displaySize: DisplaySize,
                audioEnabled: Bool = true,
                networkEnabled: Bool = true,
                mayRestoreSnapshot: Bool = true) {
        self.guestRAMBytes = guestRAMBytes
        self.cpuCount = cpuCount
        self.displaySize = displaySize
        self.audioEnabled = audioEnabled
        self.networkEnabled = networkEnabled
        self.mayRestoreSnapshot = mayRestoreSnapshot
    }
}

// MARK: - Engine

/// The virtual machine itself.
///
/// `RuntimeController` is the only caller. The UI never sees this.
public protocol VMEngine: AnyObject, Sendable {

    /// Get ready to start: allocate, verify, and fail early if the machine cannot be
    /// built. Called once per run, before `start()`.
    func prepare(_ configuration: VMConfiguration) async throws

    /// Begin executing the guest. Returns once the machine is running, not once
    /// Android is usable -- readiness is `BootCoordinator`'s business.
    func start() async throws

    /// Ask the machine to stop, and return when it has.
    func stop() async

    var isRunning: Bool { get async }
}

/// Whether DroidVM can execute generated code.
///
/// The contract is deliberately small -- prepare, report status, release -- because the
/// normal UI must eventually care about exactly three outcomes: ready, unavailable,
/// failed. A user is never told about a debugger, a pairing protocol, a helper app or a
/// vendor framework; those are the mechanism, and they live in diagnostics.
///
/// A user sees this as the `checkingRuntime` lifecycle state and, on failure, as the
/// lifecycle's own plain language. See `RuntimeReadiness` and `JITManager`.
public protocol JITProvider: AnyObject, Sendable {

    /// Get ready to execute generated code, or determine that it is not possible.
    ///
    /// Idempotent while ready. Never throws: a failure is a *status*, because "cannot
    /// start Android" is a normal product outcome that must reach the UI, not an error
    /// that gets swallowed at a call site.
    @discardableResult
    func prepareRuntime() async -> RuntimeReadiness

    /// The current product-facing status. Synchronous, because the UI reads it while
    /// rendering.
    var readiness: RuntimeReadiness { get }

    /// Non-destructive availability probe, for diagnostics.
    ///
    /// Returns `.unknown` rather than `.unavailable` when the question could not be
    /// answered -- a probe that did not run is not a negative result.
    func probeAvailability() async -> JITAvailability

    /// Give the region back, if that is possible for this provider.
    func release() async
}

/// The display path: how guest pixels reach the screen, and what happened on the way.
///
/// `counters` is the whole point of this protocol existing rather than the engine
/// exposing a frame count. See `DisplayCounters`.
public protocol DisplayBackend: AnyObject, Sendable {

    /// Bind to a host surface and begin presenting.
    func attach(surface: DisplaySurfaceHandle) async throws

    /// Unbind and stop presenting. The machine may keep running.
    func detach() async

    var attached: Bool { get async }

    /// Monotonic counters, split by stage. Never a frame rate.
    var counters: DisplayCounters { get async }
}

/// An opaque handle to whatever the host needs to give the display.
///
/// Deliberately not a `CAMetalLayer`: that would put Metal in the domain layer, and
/// this package must build on Linux and Windows. The iOS adapter downcasts.
public protocol DisplaySurfaceHandle: AnyObject {}

// MARK: - Guest

/// How DroidVM talks to the running Android system.
///
/// Implementations hide the transport entirely -- whether that is a shell over a
/// forwarded socket, a serial console, or an agent. Nothing above this protocol knows.
public protocol GuestControl: Sendable {

    /// `nil` when the question could not be answered, which is not the same as "no".
    func isAlive() async -> Bool?

    /// Run a command inside the guest. Throws on timeout or transport failure.
    @discardableResult
    func shell(_ command: String, timeout: Duration) async throws -> String

    /// Ask what Android components are up. Every field is three-valued.
    func probeServices() async -> GuestServices
}

/// The monitor that turns raw engine and guest activity into lifecycle evidence.
///
/// This is the stream `BootCoordinator` consumes. It is the only place allowed to
/// decide that a piece of evidence is meaningful.
public protocol AndroidGuestMonitor: Sendable {

    /// A stream of observations. Finishes when the machine stops.
    func signals() -> AsyncStream<GuestSignal>
}

/// One observation about the guest, in DroidVM's terms.
public enum GuestSignal: Equatable, Sendable {
    case vmStarted
    case vmExited(reason: String)
    case guestLiveness(Bool?)
    case bootProgress(milestone: String, fraction: Double?)
    case bootCompleted(restoredFromSnapshot: Bool)
    case services(GuestServices)
    case displayAttached
    case displayDetached(reason: String)
    case frameWindow(presented: UInt64, cause: FrameStallCause)
    case memory(MemoryReading)
    case snapshotRestored
}

// MARK: - Snapshots

/// Evidence that a machine is worth freezing.
///
/// LESSON: a snapshot must never be saved merely because enough time has elapsed.
/// The reference implementation's auto-save fired on elapsed time and a "quiet
/// window" without ever checking that anything had been drawn, so it could freeze a
/// black screen -- and every subsequent launch then restored that black screen,
/// making the failure look permanent and unrelated to its cause.
///
/// `SnapshotStore.save` requires this value, so a caller cannot save without having
/// gathered every piece of evidence. The struct carries the evidence; the pass/fail
/// rule that fills it in is Phase 1's `SnapshotHealthGate`.
public struct SnapshotHealthEvidence: Equatable, Sendable {

    public var guestAlive: TriState
    public var bootCompleted: Bool
    public var displayAttached: Bool
    public var framesPresented: UInt64
    public var services: GuestServices
    public var memory: MemoryReading

    /// The checks a snapshot must pass before it may be written. Kept here as data so
    /// tests can assert the list against documentation, and so no implementation can
    /// quietly drop one.
    public static let requiredChecks: [String] = [
        "guest_alive",
        "boot_completed",
        "display_attached",
        "presented_frame",
        "systemui_not_absent",
        "launcher_not_absent",
        "memory_not_critical",
    ]

    public init(guestAlive: TriState,
                bootCompleted: Bool,
                displayAttached: Bool,
                framesPresented: UInt64,
                services: GuestServices,
                memory: MemoryReading) {
        self.guestAlive = guestAlive
        self.bootCompleted = bootCompleted
        self.displayAttached = displayAttached
        self.framesPresented = framesPresented
        self.services = services
        self.memory = memory
    }
}

/// Where saved machines live.
public protocol SnapshotStore: Sendable {

    /// Metadata for a snapshot compatible with this configuration, or `nil`.
    func loadable(configuration: VMConfiguration) async -> SnapshotMetadata?

    /// Write a snapshot. Callers must supply health evidence; there is no overload
    /// that saves without it.
    func save(evidence: SnapshotHealthEvidence,
              configuration: VMConfiguration) async throws

    /// Forget any saved machine. Used when configuration changes in a way that makes
    /// an existing snapshot invalid.
    func invalidate() async

    /// Whether a snapshot exists at all, compatible or not.
    var hasSnapshot: Bool { get async }
}

/// What is known about a saved machine.
public struct SnapshotMetadata: Equatable, Sendable {
    public var guestRAMBytes: UInt64
    public var displaySize: DisplaySize
    public var createdAt: Date?

    public init(guestRAMBytes: UInt64, displaySize: DisplaySize, createdAt: Date? = nil) {
        self.guestRAMBytes = guestRAMBytes
        self.displaySize = displaySize
        self.createdAt = createdAt
    }
}

// MARK: - APKs

/// One installed Android application, as DroidVM presents it.
public struct InstalledPackage: Equatable, Sendable {
    public var packageName: String
    public var displayName: String
    public var versionName: String?
    public var iconPNGData: Data?

    public init(packageName: String,
                displayName: String,
                versionName: String? = nil,
                iconPNGData: Data? = nil) {
        self.packageName = packageName
        self.displayName = displayName
        self.versionName = versionName
        self.iconPNGData = iconPNGData
    }
}

/// Installing an app into the guest.
///
/// The user taps "Install APK" and is told whether it worked. How the bytes get into
/// Android is not their concern and is not visible above this protocol.
public protocol APKInstalling: Sendable {

    func install(apkAt url: URL) async throws -> InstalledPackage

    func installedPackages() async throws -> [InstalledPackage]

    func uninstall(packageName: String) async throws
}

// MARK: - Memory

/// Memory measurement, so policy is decided on figures rather than impressions.
public protocol MemoryReporting: Sendable {
    func reading() async -> MemoryReading
}

// MARK: - Diagnostics

/// A structured diagnostic value.
///
/// `unknown` is a value, not an absence: "we could not determine this" must not be
/// mistakable for `false`.
public enum DiagnosticValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case unknown
}

/// One structured event.
public struct DiagnosticEvent: Equatable, Sendable {
    public var name: String
    public var fields: [String: DiagnosticValue]

    public init(name: String, fields: [String: DiagnosticValue] = [:]) {
        self.name = name
        self.fields = fields
    }
}

/// Where structured diagnostics go.
///
/// LESSON: observability exists before recovery. Nothing may attempt to repair a
/// machine whose state cannot first be described.
///
/// Deliberately **not** `Sendable`. The production implementation (`DiagnosticsRecorder`)
/// is bound to DroidVM's runtime executor and is called from the frame path, where a lock
/// would be a real per-frame cost paid to guard against a race the single-executor design
/// already prevents. Requiring `Sendable` here would force either a lock or an
/// `@unchecked` lie. The constraint is documented on the implementation instead, and the
/// line-level sinks behind it are the same shape for the same reason.
public protocol DiagnosticsSink: AnyObject {
    func record(_ event: DiagnosticEvent)
    func record(transitionFrom: LifecycleState,
                to: LifecycleState,
                reason: String,
                evidence: [String: DiagnosticValue])
}
