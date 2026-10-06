// SPDX-License-Identifier: GPL-2.0-or-later
//
// Three-valued logic, and why the third value exists.
//
// LESSON (from the reference implementation): every signal about the guest needs
// three states, not two.
//
//   * "SystemUI is not running"   -> a fact about the guest
//   * "we could not ask"          -> a fact about our probe
//
// Collapsing those into `false` is how a probe that timed out becomes a reported
// fault, and how a diagnostic layer starts lying. `TriState.unknown` is never
// treated as `.no` anywhere in DroidVM.

public enum TriState: String, Equatable, CaseIterable, Sendable {
    case yes
    case no
    case unknown

    /// Build from an optional probe result.
    ///
    /// `nil` means the probe did not produce an answer -- it threw, timed out, or was
    /// never run -- and that is `unknown`, never `.no`.
    public init(_ confirmed: Bool?) {
        switch confirmed {
        case .some(true): self = .yes
        case .some(false): self = .no
        case .none: self = .unknown
        }
    }

    public var isConfirmedPresent: Bool { self == .yes }

    /// Whether the evidence actually says the thing is absent.
    ///
    /// Deliberately false for `.unknown`. Use this rather than `!= .yes` when the
    /// question is "is it missing", so that ignorance cannot become a fault report.
    public var isConfirmedAbsent: Bool { self == .no }

    public var isUnknown: Bool { self == .unknown }
}
