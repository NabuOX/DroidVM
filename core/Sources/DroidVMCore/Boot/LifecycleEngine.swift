// SPDX-License-Identifier: GPL-2.0-or-later
//
// The boot state machine: evidence in, lifecycle state out.
//
// DROIDVM'S MODEL IS THE SOURCE OF TRUTH.
//
// The reference implementation solved a closely related problem in C, and that work
// informed the rules below -- but it is not what runs here, and its header is not included
// by anything in DroidVM. There is exactly one lifecycle state machine in this product,
// stated in DroidVM's vocabulary, tested from the host.
//
// THE RULES (see ARCHITECTURE.md section 3)
//
//   1. Forward along the boot sequence; skips allowed; backward only out of `degraded`
//      (evidence cleared) or a terminal state (a fresh start).
//   2. `ready` is terminal apart from the machine stopping or failing. A booted system
//      does not become unbooted, and an idle phone produces no frames without being broken.
//   3. Every transition carries a reason and its evidence.
//   4. `unknown` evidence never causes a transition to a negative outcome.
//   5. Progress is presentation only, derived from the state -- never the reverse, and
//      never from the position of a line in a log.
//   6. Nothing moves for want of a clock. Elapsed time is evidence; a timer is not a
//      transition.

import Foundation

// MARK: - Thresholds

public enum LifecycleThresholds {

    /// How long a booted, display-attached machine may go without ever presenting a frame
    /// before that is treated as degraded rather than merely slow.
    public static let graphicsStallSeconds: TimeInterval = 20.0

    /// How long an incomplete boot may go without any milestone at all before it is
    /// treated as stalled.
    ///
    /// Generous on purpose: an Android first boot spends minutes compiling applications,
    /// during which the console is legitimately quiet.
    public static let bootStallSeconds: TimeInterval = 90.0

    /// Memory availability below which the machine is considered at risk. A kill is a
    /// SIGKILL with no handler and no crash log, so this is the only place it can be seen
    /// coming.
    public static let memoryFloorBytes: Int = 350 << 20
}

// MARK: - Evidence

/// Everything the lifecycle is allowed to reason about, in one value.
///
/// A value rather than a stream of ad-hoc callbacks: a state decision that depends on six
/// independent flags is exactly how the reference implementation ended up unable to answer
/// "is Android booted but not drawing" without reconstructing it from all of them.
public struct BootEvidence: Equatable, Sendable {

    public var startRequested: Bool
    public var stopRequested: Bool

    public var runtimeReadiness: RuntimeReadiness
    public var vmStatus: VMStatus

    /// Three-valued: `unknown` is not "not running".
    public var guestAlive: TriState

    /// Whether Android reported that it finished booting.
    public var bootCompleted: Bool

    /// How long ago boot completed was observed, if it was.
    public var bootCompletedAge: TimeInterval?

    /// How long since any boot milestone at all. `nil` means no milestone has been seen.
    public var bootMilestoneAge: TimeInterval?

    public var restoredFromSnapshot: Bool

    public var services: GuestServices
    public var displayAttached: Bool
    public var counters: DisplayCounters
    public var memory: MemoryReading

    public init(startRequested: Bool = false,
                stopRequested: Bool = false,
                runtimeReadiness: RuntimeReadiness = .unknown,
                vmStatus: VMStatus = .idle,
                guestAlive: TriState = .unknown,
                bootCompleted: Bool = false,
                bootCompletedAge: TimeInterval? = nil,
                bootMilestoneAge: TimeInterval? = nil,
                restoredFromSnapshot: Bool = false,
                services: GuestServices = .unknown,
                displayAttached: Bool = false,
                counters: DisplayCounters = .zero,
                memory: MemoryReading = .unknown) {
        self.startRequested = startRequested
        self.stopRequested = stopRequested
        self.runtimeReadiness = runtimeReadiness
        self.vmStatus = vmStatus
        self.guestAlive = guestAlive
        self.bootCompleted = bootCompleted
        self.bootCompletedAge = bootCompletedAge
        self.bootMilestoneAge = bootMilestoneAge
        self.restoredFromSnapshot = restoredFromSnapshot
        self.services = services
        self.displayAttached = displayAttached
        self.counters = counters
        self.memory = memory
    }

    public static let idle = BootEvidence()
}

// MARK: - Ready gate

/// Whether Android is actually usable.
///
/// THE RULE THAT MATTERS: **absence blocks, ignorance does not.**
///
/// A probe that says a component is missing blocks readiness. A probe that could not answer
/// does not, and is reported as unverified instead. The trade-off is deliberate: requiring
/// a confirmed `yes` would leave the boot overlay up forever on a device where a probe
/// cannot run, which is a worse failure than readiness that is merely unconfirmed.
/// Unconfirmed is never silent -- it comes back in `advisories`.
///
/// `boot_completed` is deliberately NOT sufficient. It is true the instant a restored
/// machine restores, while nothing has been drawn.
public enum ReadyGate {

    public struct Result: Equatable, Sendable {
        public var isSatisfied: Bool
        /// Hard reasons readiness was refused. Each is a `SnapshotHealthEvidence` check name
        /// where one applies, so the same vocabulary covers both gates.
        public var blockers: [String]
        /// Things we could not verify. Never reasons for refusal.
        public var advisories: [String]

        public init(isSatisfied: Bool, blockers: [String], advisories: [String]) {
            self.isSatisfied = isSatisfied
            self.blockers = blockers
            self.advisories = advisories
        }
    }

    public static func evaluate(_ e: BootEvidence,
                                memoryFloorBytes: Int = LifecycleThresholds.memoryFloorBytes)
        -> Result {

        var blockers: [String] = []
        var advisories: [String] = []

        // Guest liveness. `no` is a fact; `unknown` is our ignorance.
        switch e.guestAlive {
        case .no: blockers.append("guest_not_alive")
        case .unknown: advisories.append("guest_liveness_unverified")
        case .yes: break
        }

        if !e.bootCompleted { blockers.append("boot_not_completed") }
        if !e.displayAttached { blockers.append("display_not_attached") }
        if !e.counters.hasEverPresented { blockers.append("no_frame_presented") }

        // The two service probes, where absence blocks and ignorance advises.
        switch e.services.systemUI {
        case .no: blockers.append("systemui_absent")
        case .unknown: advisories.append("systemui_unverified")
        case .yes: break
        }
        switch e.services.launcher {
        case .no: blockers.append("launcher_absent")
        case .unknown: advisories.append("launcher_unverified")
        case .yes: break
        }

        if e.memory.isUnderPressure(floorBytes: memoryFloorBytes) {
            blockers.append("memory_critical")
        } else if e.memory.availableBeforeKillBytes == nil {
            advisories.append("memory_unmeasured")
        }

        return Result(isSatisfied: blockers.isEmpty,
                      blockers: blockers,
                      advisories: advisories)
    }
}

// MARK: - Decision

public struct LifecycleDecision: Equatable, Sendable {
    public var previous: LifecycleState
    public var state: LifecycleState
    public var changed: Bool
    public var reason: String
    public var blockers: [String]
    public var advisories: [String]

    /// Presentation only. Derived from `state`, never the reverse.
    public var progressPercent: Int { LifecyclePresentation.percent(for: state) }
}

/// The only place a percentage is produced.
public enum LifecyclePresentation {

    /// Coarse and honest. These are milestones, not a smooth bar: a smooth bar over a boot
    /// whose intermediate steps are unknown is a bar that lies, and the reference
    /// implementation's version reached 95% having made no progress at all.
    public static func percent(for state: LifecycleState) -> Int {
        switch state {
        case .idle: return 0
        case .preparing: return 5
        case .checkingRuntime: return 10
        case .startingVM: return 20
        case .bootingAndroid: return 35
        case .startingServices: return 50
        case .waitingForDisplay: return 65
        case .waitingForSystemUI: return 75
        case .waitingForLauncher: return 85
        case .ready: return 100
        case .degraded: return 100
        case .recovering: return 90
        case .failed: return 100
        case .stopping: return 100
        case .stopped: return 0
        }
    }
}

// MARK: - The engine

/// Owns the lifecycle. One state, one reason, one owner.
public final class LifecycleEngine {

    public private(set) var state: LifecycleState = .idle
    public private(set) var lastReason: String = "initial"
    public private(set) var lastBlockers: [String] = []
    public private(set) var lastAdvisories: [String] = []

    /// The last decision, whether or not it changed anything.
    public private(set) var lastDecision: LifecycleDecision

    private let memoryFloorBytes: Int
    private let graphicsStallSeconds: TimeInterval
    private let bootStallSeconds: TimeInterval

    public init(memoryFloorBytes: Int = LifecycleThresholds.memoryFloorBytes,
                graphicsStallSeconds: TimeInterval = LifecycleThresholds.graphicsStallSeconds,
                bootStallSeconds: TimeInterval = LifecycleThresholds.bootStallSeconds) {
        self.memoryFloorBytes = memoryFloorBytes
        self.graphicsStallSeconds = graphicsStallSeconds
        self.bootStallSeconds = bootStallSeconds
        self.lastDecision = LifecycleDecision(previous: .idle, state: .idle,
                                              changed: false, reason: "initial",
                                              blockers: [], advisories: [])
    }

    /// Fold in new evidence and produce the resulting state.
    @discardableResult
    public func evaluate(_ evidence: BootEvidence) -> LifecycleDecision {

        let gate = ReadyGate.evaluate(evidence, memoryFloorBytes: memoryFloorBytes)
        let (candidate, reason) = select(evidence: evidence, gate: gate)
        let resolved = resolve(candidate: candidate, evidence: evidence)

        let previous = state
        let reasonText = resolved == candidate
            ? reason
            : "\(reason) (held at \(resolved.rawValue))"

        lastBlockers = gate.blockers
        lastAdvisories = gate.advisories
        lastReason = reasonText

        let decision = LifecycleDecision(previous: previous,
                                         state: resolved,
                                         changed: resolved != previous,
                                         reason: reasonText,
                                         blockers: gate.blockers,
                                         advisories: gate.advisories)
        state = resolved
        lastDecision = decision
        return decision
    }

    // MARK: selection
    //
    // Pure: evidence and the gate in, a candidate state out. Kept free of the engine's
    // own history so that the ladder can be read and tested on its own.

    func select(evidence e: BootEvidence, gate: ReadyGate.Result)
        -> (LifecycleState, String) {

        // --- the machine going away, and death, outrank everything ---

        if e.stopRequested {
            // The discriminator is the *machine's* status, not the lifecycle's. Asking
            // whether the lifecycle `isRunning` is circular: `stopping` is itself a running
            // state, so a machine that had already gone would report `stopping` forever.
            switch e.vmStatus {
            case .running, .starting, .prepared, .preparing, .stopping:
                return (.stopping, "stop requested")
            case .idle, .stopped, .failed:
                return (.stopped, "stopped")
            }
        }

        if case .failed(let failure) = e.vmStatus {
            return (.failed, "engine failed at \(failure.stage.rawValue): \(failure.reason)")
        }

        // A runtime that cannot be prepared is a failed start, not a broken machine. The
        // reason is already in plain language.
        switch e.runtimeReadiness {
        case .unavailable(let why):
            return (.failed, "runtime unavailable: \(why)")
        case .failed(let why):
            return (.failed, "runtime preparation failed: \(why)")
        default:
            break
        }

        // --- before a start is wanted ---

        if !e.startRequested { return (.idle, "no start requested") }

        // --- runtime preparation ---
        //
        // The order matches the lifecycle's own vocabulary, and the boot sequence's own
        // ordering: `preparing` is DroidVM getting its house in order, `checkingRuntime` is
        // actively obtaining executable memory, `startingVM` is building the machine. These
        // three are distinct because they fail differently and a user is told different
        // things about each.
        switch e.runtimeReadiness {
        case .unknown:
            return (.preparing, "getting ready; nothing checked yet")
        case .preparing:
            return (.checkingRuntime, "obtaining executable memory")
        case .ready:
            break
        case .unavailable, .failed:
            break  // handled above
        }

        // --- the machine ---

        switch e.vmStatus {
        case .idle, .preparing, .prepared:
            return (.startingVM, "building the machine")
        case .starting:
            return (.startingVM, "starting the machine")
        case .stopping:
            return (.stopping, "stopping")
        case .stopped:
            // A machine that has stopped and a machine that has not started yet are
            // different situations, and only the lifecycle's own position can tell them
            // apart. Getting this wrong left the overlay saying "Loading display…" over a
            // machine that was not running at all.
            switch state {
            case .idle, .preparing, .checkingRuntime, .startingVM:
                return (.startingVM, "machine not running; ready to start")
            default:
                return (.stopped, "machine stopped")
            }
        case .failed:
            break  // handled above
        case .running:
            break
        }

        // --- the machine is running: walk the boot ladder ---

        // Degradation is checked before the ladder, because it is a conclusion drawn *from*
        // the ladder's inputs rather than a rung on it.
        if let why = degradation(evidence: e) {
            return (.degraded, why)
        }

        if !e.bootCompleted {
            // Services coming up is real progress before boot completes: init is running and
            // starting things. Either signal is enough.
            if e.services.systemServer.isConfirmedPresent || e.counters.hasEverPresented {
                return (.startingServices, "boot not complete; services starting")
            }
            return (.bootingAndroid, "boot not complete")
        }

        // Boot completed from here. That alone is NOT readiness: a restored machine
        // reports it the instant it restores, with nothing drawn.
        if !e.counters.hasEverPresented {
            return (.waitingForDisplay,
                    e.restoredFromSnapshot
                        ? "restored with boot complete but nothing drawn yet"
                        : "boot complete, waiting for the first frame")
        }

        if !e.services.systemUI.isConfirmedPresent {
            return (.waitingForSystemUI, "no frame path to SystemUI yet")
        }

        if !e.services.launcher.isConfirmedPresent {
            return (.waitingForLauncher, "SystemUI up, launcher not yet up")
        }

        if gate.isSatisfied {
            return (.ready, "ready gate satisfied")
        }

        // Everything is present but the gate refuses: report the gate's own reason rather
        // than inventing one.
        return (.waitingForLauncher,
                "gate not satisfied: \(gate.blockers.joined(separator: ","))")
    }

    /// Why the machine is degraded, or `nil` if it is not.
    ///
    /// `nil` means "not degraded", which is distinct from "degraded for an unknown reason":
    /// every branch here names a specific condition, so an unanswered probe can never
    /// produce a fault report.
    func degradation(evidence e: BootEvidence) -> String? {

        // The guest answered, and said it is not running.
        if e.guestAlive.isConfirmedAbsent {
            return "guest is not alive"
        }

        // Confirmed absence of a component Android needs, after boot.
        if e.bootCompleted && e.services.systemUI.isConfirmedAbsent {
            return "SystemUI confirmed absent after boot completed"
        }
        if e.services.systemUI.isConfirmedPresent && e.services.launcher.isConfirmedAbsent {
            return "launcher confirmed absent while SystemUI is up"
        }

        // Booted and attached, but nothing has ever reached the screen.
        if e.bootCompleted, e.displayAttached, !e.counters.hasEverPresented,
           let age = e.bootCompletedAge, age >= graphicsStallSeconds {
            return "boot completed \(Int(age))s ago; display attached; "
                 + "no frame has ever been presented"
        }

        // Boot incomplete and quiet -- but ONLY if nothing has ever been drawn. A long
        // application-compilation phase is quiet on the console for minutes while the boot
        // animation is drawing, and calling that stalled would be wrong.
        if !e.bootCompleted, e.guestAlive.isConfirmedPresent, !e.counters.hasEverPresented,
           let age = e.bootMilestoneAge, age >= bootStallSeconds {
            return "no boot milestone for \(Int(age))s and nothing ever drawn"
        }

        return nil
    }

    // MARK: transition legality

    /// Apply rules 1 and 2 to the candidate.
    ///
    /// Rule 2 is the important one: once `ready`, nothing on the ladder may pull the
    /// machine back. Android being quiet, a probe timing out, or a service probe suddenly
    /// answering `unknown` are all normal on a healthy booted phone, and a lifecycle that
    /// reacted to them would flicker.
    func resolve(candidate: LifecycleState, evidence: BootEvidence) -> LifecycleState {

        // Leaving a terminal state requires a fresh start.
        if state.isTerminal, candidate != state {
            if evidence.startRequested, !evidence.stopRequested,
               candidate == .checkingRuntime || candidate == .preparing {
                return candidate
            }
            return state
        }

        // `ready` is terminal apart from stopping or failing.
        if state == .ready {
            switch candidate {
            case .ready, .stopping, .stopped, .failed:
                return candidate
            default:
                return .ready
            }
        }

        // Backward movement is legal only out of `degraded`.
        if state == .degraded { return candidate }

        if candidate == state { return state }

        let order = LifecycleState.bootSequence
        guard let from = order.firstIndex(of: state),
              let to = order.firstIndex(of: candidate) else {
            // Off the boot axis (recovering, for instance) -- allowed to move anywhere the
            // ladder says.
            return candidate
        }

        // A skip forward is fine. A step backward is not, except into a terminal state or
        // a failure, both of which are handled above.
        return to >= from ? candidate : state
    }
}
