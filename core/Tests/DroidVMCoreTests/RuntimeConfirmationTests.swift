// SPDX-License-Identifier: GPL-2.0-or-later
//
// Level D.1a: the native runtime-state mapping.
//
// These prove the MAPPING and the polling rule. They cannot prove that QEMU's loop runs -- that
// is what gate 3's engine-symbol verification and a physical iPhone are for. Nothing here starts
// QEMU, and no result below is device evidence.

import XCTest
@testable import DroidVMCore

/// A provider whose answer the test controls, and which counts how often it was asked.
private final class StubProvider: RuntimeStateProviding, @unchecked Sendable {
    var state: DroidVMRuntimeState?
    /// Answers to give before settling on `state`, so "still starting" can be exercised.
    var transitions: [DroidVMRuntimeState] = []
    private(set) var calls = 0

    func runtimeState() -> DroidVMRuntimeState? {
        calls += 1
        if !transitions.isEmpty { return transitions.removeFirst() }
        return state
    }
}

final class RuntimeConfirmationTests: XCTestCase {

    // MARK: the state model

    /// Only one state means running, and it is the one written from inside the loop body.
    func testOnlyMainLoopEnteredIsRunning() {
        XCTAssertTrue(DroidVMRuntimeState.mainLoopEntered.isRunning)
        XCTAssertFalse(DroidVMRuntimeState.notStarted.isRunning)
        XCTAssertFalse(DroidVMRuntimeState.initialized.isRunning,
                       "qemu_init returning 0 is not a running engine")
        XCTAssertFalse(DroidVMRuntimeState.mainLoopExited.isRunning)
        XCTAssertFalse(DroidVMRuntimeState.failed(reason: "x").isRunning)
    }

    /// Every state has something to say, so a failure is never silent.
    func testEveryStateHasADetail() {
        let states: [DroidVMRuntimeState] = [
            .notStarted, .initialized, .mainLoopEntered, .mainLoopExited,
            .failed(reason: "dylib missing"),
        ]
        for state in states {
            XCTAssertFalse(state.detail.isEmpty, "\(state) has no detail")
        }
        XCTAssertTrue(DroidVMRuntimeState.failed(reason: "dylib missing").detail
                        .contains("dylib missing"),
                      "a failure reason must survive into the detail")
    }

    /// Level D says nothing about Android, and no native-state label may imply it.
    func testNoStateImpliesAndroid() {
        let states: [DroidVMRuntimeState] = [
            .notStarted, .initialized, .mainLoopEntered, .mainLoopExited,
            .failed(reason: "x"),
        ]
        for state in states {
            XCTAssertFalse(state.detail.lowercased().contains("android"))
        }
    }

    // MARK: the mapping

    func testMainLoopEnteredMapsToRunning() async {
        let provider = StubProvider()
        provider.state = .mainLoopEntered
        let result = await confirmRuntime(using: provider, timeout: 1.0, pollInterval: 0.001)
        XCTAssertEqual(result, .running)
        XCTAssertEqual(provider.calls, 1, "a running engine is answered on the first ask")
    }

    func testMainLoopExitedMapsToNotRunning() async {
        let provider = StubProvider()
        provider.state = .mainLoopExited
        let result = await confirmRuntime(using: provider, timeout: 1.0, pollInterval: 0.001)
        XCTAssertEqual(result, .notRunning)
    }

    func testFailedMapsToNotRunning() async {
        let provider = StubProvider()
        provider.state = .failed(reason: "qemu_init returned 1")
        let result = await confirmRuntime(using: provider, timeout: 1.0, pollInterval: 0.001)
        XCTAssertEqual(result, .notRunning)
    }

    /// A symbol that is absent means the question could not be asked -- which is NOT the same as
    /// a negative answer. Conflating them would let a broken export look like a dead machine.
    func testMissingSymbolsMapToUnavailable() async {
        let provider = StubProvider()
        provider.state = nil
        let result = await confirmRuntime(using: provider, timeout: 1.0, pollInterval: 0.001)
        guard case .unavailable(let why) = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertTrue(why.contains("does not export"), "the reason names the cause: \(why)")
    }

    // MARK: polling

    /// The loop is entered some time after `start()` returns, so a single immediate query would
    /// report a healthy engine as failed. Waiting is required; what matters is that waiting can
    /// never invent the answer.
    func testItWaitsForTheLoopToBeEntered() async {
        let provider = StubProvider()
        provider.transitions = [.notStarted, .notStarted, .initialized, .initialized]
        provider.state = .mainLoopEntered
        let result = await confirmRuntime(using: provider, timeout: 2.0, pollInterval: 0.001)
        XCTAssertEqual(result, .running)
        XCTAssertEqual(provider.calls, 5, "it kept asking until the engine answered")
    }

    /// Still starting when the deadline passes is a TIMEOUT, not a promotion.
    func testDeadlineProducesTimeoutAndNeverRunning() async {
        let provider = StubProvider()
        provider.state = .initialized      // never advances
        let result = await confirmRuntime(using: provider, timeout: 0.02, pollInterval: 0.001)
        XCTAssertEqual(result, .timedOut)
        XCTAssertNotEqual(result, .running, "a deadline must never promote to running")
        XCTAssertGreaterThan(provider.calls, 1, "it genuinely polled")
    }

    /// NOT_STARTED alone is not a verdict either: the engine may not have begun.
    func testNotStartedTimesOutRatherThanFailingImmediately() async {
        let provider = StubProvider()
        provider.state = .notStarted
        let result = await confirmRuntime(using: provider, timeout: 0.02, pollInterval: 0.001)
        XCTAssertEqual(result, .timedOut)
    }

    /// A terminal state ends the wait immediately: there is nothing left to wait for.
    func testTerminalStatesDoNotWaitForTheDeadline() async {
        let provider = StubProvider()
        provider.state = .mainLoopExited
        let started = Date()
        _ = await confirmRuntime(using: provider, timeout: 5.0, pollInterval: 0.001)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "an exited loop must be reported at once, not after five seconds")
    }

    // MARK: integration with the coordinator's contract

    /// The confirmer is what the coordinator calls; the mapping must survive the wrapper.
    func testConfirmerUsesTheProviderThroughTheSharedProtocol() async {
        final class Confirmer: RuntimeConfirming, @unchecked Sendable {
            let provider: RuntimeStateProviding
            init(provider: RuntimeStateProviding) { self.provider = provider }
            func confirmRunning(timeout: TimeInterval) async -> RuntimeConfirmation {
                await confirmRuntime(using: provider, timeout: timeout, pollInterval: 0.001)
            }
        }

        let running = StubProvider(); running.state = .mainLoopEntered
        let idle = StubProvider();    idle.state = .initialized

        let a = await Confirmer(provider: running).confirmRunning(timeout: 0.5)
        XCTAssertEqual(a, .running)

        let b = await Confirmer(provider: idle).confirmRunning(timeout: 0.02)
        XCTAssertEqual(b, .timedOut)
    }
}
