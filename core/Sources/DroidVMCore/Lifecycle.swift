// SPDX-License-Identifier: GPL-2.0-or-later
//
// The DroidVM lifecycle vocabulary. Phase 0 defines the states and their
// consumer-facing labels; the *transition rules* are Phase 1's BootCoordinator.
//
// WHY ONE ENUM AND NOT A SET OF BOOLEANS
//
// LESSON (from the reference implementation): boot state accumulated as a handful of
// independent flags -- is the VM running, has boot completed, which display is up,
// is a snapshot restoring -- and nothing could answer "is Android booted but not
// drawing" without a reader reconstructing it from all of them. One enum, owned by
// one coordinator, with explicit transitions, is the fix.
//
// UI CONTRACT
//
// The state is the source of truth. A percentage is presentation only and must be
// derived from the state, never from the position of a line in a log. In particular
// `consumerLabel` and any progress value must come from the SAME state, so a label
// can never describe a different moment than the number beside it.

public enum LifecycleState: String, Equatable, CaseIterable, Sendable {

    // --- before any VM exists ---
    case idle
    case preparing
    case checkingRuntime
    case startingVM

    // --- the VM exists; Android is coming up ---
    case bootingAndroid
    case startingServices
    case waitingForDisplay
    case waitingForSystemUI
    case waitingForLauncher

    // --- outcomes ---
    case ready
    case degraded
    case recovering
    case failed

    // --- going away ---
    case stopping
    case stopped

    /// What a non-technical person is shown.
    ///
    /// These strings are a hard requirement, not decoration: a test asserts none of
    /// them names an internal mechanism. The user is never told about JIT, QEMU, a
    /// renderer, a snapshot, SurfaceFlinger, system_server, frames or RAM.
    public var consumerLabel: String {
        switch self {
        case .idle:               return "Android is not running"
        case .preparing:          return "Preparing Android…"
        case .checkingRuntime:    return "Checking…"
        case .startingVM:         return "Starting Android…"
        case .bootingAndroid:     return "Starting Android…"
        case .startingServices:   return "Starting system…"
        case .waitingForDisplay:  return "Loading display…"
        case .waitingForSystemUI: return "Loading interface…"
        case .waitingForLauncher: return "Loading apps…"
        case .ready:              return "Ready"
        case .degraded:           return "Android is running with a problem"
        case .recovering:         return "Recovering…"
        case .failed:             return "Android could not start"
        case .stopping:           return "Stopping Android…"
        case .stopped:            return "Android stopped"
        }
    }

    /// Whether the boot overlay may be taken down.
    ///
    /// Only `ready`. LESSON: the overlay must not disappear because a boot property
    /// was set -- a restored machine can report "boot complete" the instant it
    /// restores, while nothing has been drawn yet. Requiring `ready` means the
    /// overlay stays up until there is evidence the display is actually usable.
    public var permitsOverlayDismissal: Bool { self == .ready }

    /// Whether the user can expect to interact with Android.
    public var isRunning: Bool {
        switch self {
        case .idle, .preparing, .checkingRuntime, .stopped, .failed: return false
        default: return true
        }
    }

    /// Whether this is a settled end state.
    public var isTerminal: Bool {
        self == .stopped || self == .failed
    }

    /// Whether the boot sequence is still making its way forward.
    public var isBootInProgress: Bool {
        switch self {
        case .preparing, .checkingRuntime, .startingVM,
             .bootingAndroid, .startingServices,
             .waitingForDisplay, .waitingForSystemUI, .waitingForLauncher:
            return true
        default:
            return false
        }
    }

    /// The boot sequence in order, for tests and for documentation checks. Off-axis
    /// states (degraded, recovering, failed, stopping, stopped) are not part of it.
    public static var bootSequence: [LifecycleState] {
        [.idle, .preparing, .checkingRuntime, .startingVM,
         .bootingAndroid, .startingServices,
         .waitingForDisplay, .waitingForSystemUI, .waitingForLauncher, .ready]
    }
}
