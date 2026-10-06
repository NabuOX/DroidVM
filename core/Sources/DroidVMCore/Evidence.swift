// SPDX-License-Identifier: GPL-2.0-or-later
//
// The evidence model: what DroidVM is allowed to believe, and how it is shaped so
// that the mistakes the reference implementation made are not representable.
//
// Every type in this file exists to encode a specific lesson. The comments say
// which, because a future reader who does not know the history will otherwise
// "simplify" them back into the bug.

// MARK: - Guest services

/// Whether Android's own components are up.
///
/// LESSON: three states each. `unknown` never means "not running"; see `TriState`.
public struct GuestServices: Equatable, Sendable {

    public var systemServer: TriState
    public var surfaceFlinger: TriState
    public var systemUI: TriState
    public var launcher: TriState

    public init(systemServer: TriState = .unknown,
                surfaceFlinger: TriState = .unknown,
                systemUI: TriState = .unknown,
                launcher: TriState = .unknown) {
        self.systemServer = systemServer
        self.surfaceFlinger = surfaceFlinger
        self.systemUI = systemUI
        self.launcher = launcher
    }

    public static let unknown = GuestServices()

    /// Everything we know nothing about -- used to decide whether a diagnosis has
    /// enough evidence to be worth stating at all.
    public var allUnknown: Bool {
        systemServer.isUnknown && surfaceFlinger.isUnknown
            && systemUI.isUnknown && launcher.isUnknown
    }
}

// MARK: - Executable memory

/// Whether DroidVM can obtain executable memory.
///
/// This is an implementation concern that must never reach a consumer screen: the
/// user is shown "Checkingâ€¦" and, if it cannot be obtained, a plain explanation.
public enum JITAvailability: Equatable, Sendable {

    /// A region of the given size is held and has passed an execute self-test.
    case available(regionBytes: Int)

    /// Definitively not obtainable, with a reason suitable for a log.
    case unavailable(reason: String)

    /// Not yet determined. Distinct from `.unavailable`: a probe that has not run is
    /// not a negative result.
    case unknown

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - Memory

/// A memory reading. Every field is optional because a figure the platform will not
/// give up is unknown, not zero.
public struct MemoryReading: Equatable, Sendable {

    /// How much more this process may allocate before the platform kills it. This is
    /// the figure that matters: a kill is a SIGKILL with no handler and no crash log,
    /// so watching this fall is the only way to see it coming.
    public var availableBeforeKillBytes: Int?

    /// The number the platform actually judges the process on.
    public var physicalFootprintBytes: Int?

    public var residentBytes: Int?

    public init(availableBeforeKillBytes: Int? = nil,
                physicalFootprintBytes: Int? = nil,
                residentBytes: Int? = nil) {
        self.availableBeforeKillBytes = availableBeforeKillBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
    }

    public static let unknown = MemoryReading()

    /// Whether memory is tight enough to be worth reporting. `nil` is not "tight":
    /// an unmeasurable figure must not raise a pressure signal.
    public func isUnderPressure(floorBytes: Int) -> Bool {
        guard let available = availableBeforeKillBytes else { return false }
        return available < floorBytes
    }
}
