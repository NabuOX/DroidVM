// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The lifecycle vocabulary, and the two rules attached to it that prevent known
/// failure modes: overlay dismissal, and leaking internal mechanisms into user text.
final class LifecycleTests: XCTestCase {

    /// LESSON: the boot overlay must not come down because a boot property was set.
    ///
    /// A restored machine can report "boot complete" the instant it restores, while
    /// nothing has been drawn yet. Only `ready` means there is evidence the display is
    /// actually usable.
    func testOnlyReadyDismissesTheOverlay() {
        for state in LifecycleState.allCases {
            if state == .ready {
                XCTAssertTrue(state.permitsOverlayDismissal,
                              "ready must permit dismissal")
            } else {
                XCTAssertFalse(state.permitsOverlayDismissal,
                               "\(state) must NOT dismiss the boot overlay")
            }
        }
    }

    /// The whole point of the consumer-facing vocabulary: a normal user is never told
    /// about JIT, QEMU, renderers, snapshots, SurfaceFlinger, frames or RAM.
    ///
    /// This is enforced mechanically rather than by review, because a label is exactly
    /// the kind of thing that gets "clarified" into jargon later.
    func testConsumerLabelsLeakNoInternalMechanisms() {

        // Compound terms that are unambiguous as substrings.
        let forbiddenSubstrings = [
            "surfaceflinger", "system_server", "systemserver", "boot_completed",
            "systemui", "system ui", "virtio", "snapshot", "renderer",
            "resolution", "telemetry", "diagnostic", "daemon", "jitter",
        ]

        // Single words, matched on word boundaries so that e.g. "RAM" does not fire
        // on an unrelated longer word.
        let forbiddenWords: Set<String> = [
            "jit", "qemu", "metal", "vulkan", "egl", "opengl", "gles", "angle",
            "ram", "cpu", "gpu", "fps", "frame", "frames", "kernel", "service",
            "services", "probe", "log", "logs", "debug",
        ]

        for state in LifecycleState.allCases {
            let label = state.consumerLabel
            XCTAssertFalse(label.isEmpty, "\(state) has no consumer label")

            let lowered = label.lowercased()
            for term in forbiddenSubstrings {
                XCTAssertFalse(lowered.contains(term),
                               "label \"\(label)\" for \(state) exposes '\(term)'")
            }

            let words = lowered
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            for word in words {
                XCTAssertFalse(forbiddenWords.contains(word),
                               "label \"\(label)\" for \(state) exposes '\(word)'")
            }
        }
    }

    /// The boot sequence is ordered, starts and ends where the architecture says, and
    /// contains no off-axis state.
    func testBootSequenceShape() {
        let sequence = LifecycleState.bootSequence

        XCTAssertEqual(sequence.first, .idle)
        XCTAssertEqual(sequence.last, .ready)
        XCTAssertEqual(sequence.count, Set(sequence).count,
                       "the boot sequence must not repeat a state")

        // Strictly ordered, and every entry is a real state.
        for state in sequence {
            XCTAssertTrue(LifecycleState.allCases.contains(state))
        }

        // The off-axis states are deliberately absent from the sequence.
        for offAxis in [LifecycleState.degraded, .recovering, .failed, .stopping, .stopped] {
            XCTAssertFalse(sequence.contains(offAxis),
                           "\(offAxis) is off-axis and must not appear in the boot sequence")
        }
    }

    func testRunningAndTerminalFlags() {
        XCTAssertFalse(LifecycleState.idle.isRunning)
        XCTAssertFalse(LifecycleState.preparing.isRunning)
        XCTAssertFalse(LifecycleState.checkingRuntime.isRunning)
        XCTAssertFalse(LifecycleState.stopped.isRunning)
        XCTAssertFalse(LifecycleState.failed.isRunning)
        XCTAssertTrue(LifecycleState.ready.isRunning)
        XCTAssertTrue(LifecycleState.degraded.isRunning,
                      "degraded is still a running system, not a dead one")

        XCTAssertTrue(LifecycleState.stopped.isTerminal)
        XCTAssertTrue(LifecycleState.failed.isTerminal)
        XCTAssertFalse(LifecycleState.ready.isTerminal)

        // Boot-in-progress and isRunning must not overlap on the settled states.
        XCTAssertTrue(LifecycleState.startingServices.isBootInProgress)
        XCTAssertFalse(LifecycleState.ready.isBootInProgress)
        XCTAssertFalse(LifecycleState.degraded.isBootInProgress)
        XCTAssertFalse(LifecycleState.idle.isBootInProgress)
    }

    func testStateVocabularyIsComplete() {
        // The fifteen states the architecture commits to. A state silently dropped
        // from the enum would otherwise only show up as a compile error somewhere far
        // away, if at all.
        let expected: Set<String> = [
            "idle", "preparing", "checkingRuntime", "startingVM",
            "bootingAndroid", "startingServices", "waitingForDisplay",
            "waitingForSystemUI", "waitingForLauncher", "ready", "degraded",
            "recovering", "failed", "stopping", "stopped",
        ]
        XCTAssertEqual(Set(LifecycleState.allCases.map(\.rawValue)), expected)
    }
}
