// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// The diagnostic event vocabulary and its wire format.
///
/// The event names are DroidVM's product API. A script or a support runbook written against
/// the stream breaks the moment one is renamed, so the set is asserted rather than trusted.
final class DiagnosticsTests: XCTestCase {

    // MARK: - the vocabulary

    /// Every event the Phase 1 brief requires, by name.
    func testEventVocabularyMatchesTheBrief() {
        let required: Set<String> = [
            "runtime_prepare_started", "runtime_ready", "runtime_failed",
            "vm_start_requested", "vm_started", "vm_start_failed", "vm_stopped",
            "display_attached", "display_detached",
            "frame_received", "frame_presented", "frame_dropped",
            "display_no_scanout", "display_present_failed",
            "guest_alive_changed", "lifecycle_changed", "memory_sample",
        ]
        let actual = Set(DiagnosticEventName.allCases.map(\.rawValue))
        XCTAssertTrue(required.isSubset(of: actual),
                      "missing events: \(required.subtracting(actual).sorted())")

        // No event name may be a foreign project's. DroidVM owns this namespace.
        //
        // The markers come from Identity rather than being written out here, so the
        // string itself lives in exactly one file -- which the repository branding
        // guard enforces, and which caught an earlier version of this test.
        for name in actual {
            for marker in DroidVMIdentity.foreignBrandMarkers {
                XCTAssertFalse(name.lowercased().contains(marker.lowercased()),
                               "event '\(name)' carries foreign naming")
            }
        }
    }

    func testEveryEventNameIsSnakeCaseAndUnique() {
        let names = DiagnosticEventName.allCases.map(\.rawValue)
        XCTAssertEqual(names.count, Set(names).count, "duplicate event name")
        for name in names {
            XCTAssertEqual(name, name.lowercased(), "\(name) is not lower case")
            XCTAssertFalse(name.contains(" "), "\(name) contains a space")
            XCTAssertFalse(name.hasPrefix("_"), "\(name) starts with an underscore")
        }
    }

    // MARK: - encoding

    func testEncodingShape() {
        let event = DiagnosticEvent(name: DiagnosticEventName.lifecycleChanged.rawValue,
                                    fields: ["state": .string("ready"),
                                             "count": .int(3),
                                             "ok": .bool(true)])
        let line = DiagnosticsEncoder.line(event, milliseconds: 1500, sequence: 7)

        XCTAssertTrue(line.hasSuffix("\n"), "each record is a line")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "exactly one newline")

        // Keys sorted, so two runs of one scenario produce identical bytes.
        let keys = ["\"count\"", "\"event\"", "\"ms\"", "\"ok\"", "\"seq\"", "\"state\""]
        var lastIndex = line.startIndex
        for key in keys {
            guard let range = line.range(of: key) else {
                return XCTFail("missing key \(key) in \(line)")
            }
            XCTAssertGreaterThan(range.lowerBound, lastIndex, "keys are not sorted: \(line)")
            lastIndex = range.lowerBound
        }
    }

    func testEncodingIsValidJSON() throws {
        let event = DiagnosticEvent(
            name: DiagnosticEventName.framePresented.rawValue,
            fields: ["a": .unknown, "b": .bool(false), "c": .int(-5),
                     "d": .double(2.5), "e": .string("quote:\" newline:\n tab:\t")])
        let line = DiagnosticsEncoder.line(event, milliseconds: 1234.5, sequence: 1)
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let object = try XCTUnwrap(parsed)

        XCTAssertTrue(object["a"] is NSNull, "unknown must encode as null")
        XCTAssertEqual(object["b"] as? Bool, false, "false must not become null")
        XCTAssertEqual(object["c"] as? Int, -5)
        XCTAssertEqual(object["d"] as? Double, 2.5)
        XCTAssertEqual(object["e"] as? String, "quote:\" newline:\n tab:\t")
        XCTAssertEqual(object["ms"] as? Double, 1234.5)
        XCTAssertEqual(object["seq"] as? Int, 1)
    }

    /// `unknown` and `false` must be distinguishable, everywhere.
    func testUnknownIsNotNullishForFalse() throws {
        let line = DiagnosticsEncoder.line(
            DiagnosticEvent(name: "e", fields: ["u": .unknown, "f": .bool(false)]),
            milliseconds: 0, sequence: 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertTrue(object["u"] is NSNull)
        XCTAssertEqual(object["f"] as? Bool, false)
        XCTAssertNotNil(object["f"])
    }

    /// One unparseable line breaks every tool reading the stream, and a non-finite counter
    /// is exactly when someone reaches for a tool.
    func testNonFiniteNumbersBecomeNull() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            let line = DiagnosticsEncoder.line(
                DiagnosticEvent(name: "e", fields: ["v": .double(bad)]),
                milliseconds: 0, sequence: 0)
            XCTAssertTrue(line.contains("\"v\":null"), "expected null for \(bad): \(line)")
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testEscapingCoversControlCharacters() throws {
        let nasty = "nul:\u{00} bell:\u{07} esc:\u{1b} bs:\\ quote:\" cr:\r nl:\n"
        let line = DiagnosticsEncoder.line(
            DiagnosticEvent(name: "e", fields: ["s": .string(nasty)]),
            milliseconds: 0, sequence: 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["s"] as? String, nasty, "the string must round-trip exactly")
    }

    // MARK: - the recorder

    func testRecorderSequencesAndFansOut() {
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink(capacity: 10)
        let other = RingBufferSink(capacity: 10)
        recorder.add(ring)
        recorder.add(other)

        XCTAssertNotNil(recorder.emit(DiagnosticEventName.vmStartRequested))
        XCTAssertNotNil(recorder.emit(DiagnosticEventName.vmStarted))

        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(other.count, 2, "every sink receives every line")
        XCTAssertTrue(ring.contents[0].contains("\"seq\":1"))
        XCTAssertTrue(ring.contents[1].contains("\"seq\":2"))
    }

    func testRingBufferKeepsTheMostRecentLinesInOrder() {
        let ring = RingBufferSink(capacity: 3)
        for i in 1...5 { ring.write("line\(i)\n") }
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.contents, ["line3\n", "line4\n", "line5\n"],
                       "contents must be oldest-first")
        ring.clear()
        XCTAssertEqual(ring.count, 0)
        XCTAssertTrue(ring.contents.isEmpty)
    }

    func testDisabledRecorderCountsWhatItDropped() {
        let recorder = DiagnosticsRecorder()
        recorder.isEnabled = false
        XCTAssertNil(recorder.emit(DiagnosticEventName.vmStarted))
        XCTAssertNil(recorder.emit(DiagnosticEventName.vmStopped))
        XCTAssertEqual(recorder.droppedEvents, 2,
                       "a disabled recorder must be accountable for what it did not write")
    }

    func testFilterSuppressesWithoutLosingCount() {
        let recorder = DiagnosticsRecorder()
        recorder.filter = { $0 != .memorySample }
        XCTAssertNotNil(recorder.emit(DiagnosticEventName.vmStarted))
        XCTAssertNil(recorder.emit(DiagnosticEventName.memorySample))
        XCTAssertEqual(recorder.droppedEvents, 1)
    }

    /// The typed conveniences exist so call sites cannot invent or forget a field. These
    /// assert the fields a log reader depends on.
    func testLifecycleChangedCarriesBothStatesAndAReason() throws {
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink()
        recorder.add(ring)

        recorder.lifecycleChanged(from: .waitingForDisplay, to: .ready,
                                  reason: "gate satisfied", evidence: [:])

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ring.contents[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "lifecycle_changed")
        XCTAssertEqual(object["previous_state"] as? String, "waitingForDisplay")
        XCTAssertEqual(object["state"] as? String, "ready")
        XCTAssertEqual(object["reason"] as? String, "gate satisfied")
    }

    func testFrameWindowEmitsOnlyRelevantStages() throws {
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink()
        recorder.add(ring)

        // A window that dropped everything: the drop must be reported, and specifically.
        recorder.frameWindow(DisplayCounters(entered: 5, received: 5, dropped: 5),
                             cause: .droppedByPresenter)
        let lines = ring.contents.map {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        let names = lines.compactMap { $0?["event"] as? String }
        XCTAssertTrue(names.contains("frame_presented"),
                      "a window summary is still a frame event: \(names)")
        XCTAssertTrue(names.contains("frame_dropped"),
                      "a drop must be reported as a drop, not folded into a summary")

        // A stall with no frame must NOT emit a frame event; the lifecycle carries it.
        ring.clear()
        recorder.frameWindow(.zero, cause: .noUpdates)
        XCTAssertTrue(ring.contents.isEmpty,
                      "an idle window must not emit a frame event")
    }

    func testWindowFieldsCountsAreClampedNotTrapped() throws {
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink(); recorder.add(ring)
        recorder.frameWindow(DisplayCounters(entered: UInt64.max, presented: 1),
                             cause: .presented)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ring.contents[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["entered"] as? Int, Int.max,
                       "a counter too large for Int clamps rather than trapping")
    }

    func testMemorySampleOmitsUnmeasuredFields() throws {
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink(); recorder.add(ring)
        recorder.memorySample(MemoryReading(availableBeforeKillBytes: 1234))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ring.contents[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["available_before_kill_bytes"] as? Int, 1234)
        XCTAssertNil(object["physical_footprint_bytes"],
                     "an unmeasured field must be absent, not zero")
    }
}
