// SPDX-License-Identifier: GPL-2.0-or-later
//
// Structured diagnostics: the event vocabulary, the wire format, and the sink plumbing.
//
// OBSERVABILITY COMES FIRST. Nothing in DroidVM may attempt to repair a machine whose
// state cannot first be described, so the event vocabulary is defined before there is
// anything to repair.
//
// The event names below are DroidVM's product API. They are a closed set, asserted by
// test, because an event name that changes silently breaks every log reader and every
// script built on the stream.

import Foundation

// MARK: - The vocabulary

/// Every diagnostic event DroidVM emits.
///
/// Closed and tested. Adding a case is a deliberate act; renaming one is a breaking
/// change to the log format.
public enum DiagnosticEventName: String, Equatable, CaseIterable, Sendable {

    // --- runtime preparation: obtaining executable memory ---

    case runtimePrepareStarted = "runtime_prepare_started"
    case runtimeReady = "runtime_ready"
    case runtimeFailed = "runtime_failed"

    // --- the virtual machine ---

    case vmStartRequested = "vm_start_requested"
    case vmStarted = "vm_started"
    case vmStartFailed = "vm_start_failed"
    case vmStopped = "vm_stopped"

    // --- the display path ---

    case displayAttached = "display_attached"
    case displayDetached = "display_detached"

    // --- frames, counted by stage ---

    case frameReceived = "frame_received"
    case framePresented = "frame_presented"
    case frameDropped = "frame_dropped"
    case displayNoScanout = "display_no_scanout"
    case displayPresentFailed = "display_present_failed"

    // --- the guest ---

    case guestAliveChanged = "guest_alive_changed"

    /// A boot milestone was observed. The milestone's own name is a field rather than part
    /// of the event name, so adding a milestone does not change the log format.
    case guestBootProgress = "guest_boot_progress"

    // --- lifecycle ---

    case lifecycleChanged = "lifecycle_changed"

    // --- Level D: the engine-run report ---

    /// The Level D device report, rendered as one line.
    ///
    /// Emitted once per engine-run, on success and on failure alike, so the evidence for a
    /// device run exists in the log and does not depend on a screenshot. The line carries the
    /// verdict and the whole report with newlines folded to separators.
    case levelDReport = "level_d_report"

    // --- resource sampling ---

    case memorySample = "memory_sample"
}

// MARK: - Field keys
//
// String keys rather than an enum, because the JSON is the interface and a reader in
// another language should not have to mirror a Swift enum. These constants exist so the
// writers agree with each other; the test suite checks the ones that matter.

public enum DiagnosticField {
    public static let state = "state"
    public static let previousState = "previous_state"
    public static let reason = "reason"
    public static let stage = "stage"
    public static let message = "message"
    public static let kind = "kind"
    public static let cause = "cause"
    public static let count = "count"
    public static let total = "total"
    public static let entered = "entered"
    public static let received = "received"
    public static let presented = "presented"
    public static let dropped = "dropped"
    public static let noScanout = "no_scanout"
    public static let presentFailure = "present_failure"
    public static let alive = "alive"
    public static let regionBytes = "region_bytes"
    public static let availableBeforeKillBytes = "available_before_kill_bytes"
    public static let physicalFootprintBytes = "physical_footprint_bytes"
    public static let asset = "asset"
    public static let bytes = "bytes"
    public static let detail = "detail"

    /// A verdict, as it appears in a report line. See `EngineRunReport.Verdict`.
    public static let result = "result"
}

// MARK: - Encoding

/// Encodes events as JSON Lines: one JSON object per line, keys sorted.
///
/// Sorting is not cosmetic. Two runs of the same scenario must produce byte-identical
/// lines so that a diff of two logs shows only behaviour that actually differs.
public enum DiagnosticsEncoder {

    /// One complete JSONL line, including its newline.
    public static func line(_ event: DiagnosticEvent,
                            milliseconds: Double,
                            sequence: UInt64) -> String {
        var pairs: [(String, String)] = []
        pairs.append(("event", quoted(event.name)))
        pairs.append(("ms", number(milliseconds)))
        pairs.append(("seq", String(sequence)))
        for (key, value) in event.fields {
            pairs.append((key, encode(value)))
        }
        pairs.sort { $0.0 < $1.0 }

        let body = pairs.map { "\(quoted($0.0)):\($0.1)" }.joined(separator: ",")
        return "{\(body)}\n"
    }

    /// One value. `unknown` encodes as JSON `null`, and is never confused with `false`.
    public static func encode(_ value: DiagnosticValue) -> String {
        switch value {
        case .string(let s): return quoted(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .double(let d): return number(d)
        case .unknown: return "null"
        }
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Numbers must always be valid JSON.
    ///
    /// A non-finite value becomes `null`: one unparseable line breaks every tool reading
    /// the stream, and a non-finite counter is exactly the moment someone reaches for a
    /// tool.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 {
            return String(Int64(d))
        }
        return String(format: "%.3f", d)
    }
}

// MARK: - Where events go

/// A destination for **encoded** lines.
///
/// Deliberately a different protocol from `DiagnosticsSink` in Interfaces.swift, which
/// takes structured events. The layering is: callers hand structured events to
/// `DiagnosticsRecorder`, which formats each one exactly once and fans the resulting line
/// out to line sinks. Two levels, one formatting step, so two sinks cannot disagree about
/// a field.
///
/// Not `Sendable`: everything here runs on DroidVM's runtime executor, and taking a lock
/// on the frame path is a cost this project refuses to pay. See the recorder's note.
public protocol DiagnosticsLineSink: AnyObject {
    func write(_ line: String)
    func flush()
}

/// Keeps the stream in memory. Used for the Advanced view, and by tests.
public final class RingBufferSink: DiagnosticsLineSink {

    private let capacity: Int
    private var lines: [String] = []
    private var next = 0
    private var filled = false

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
        lines.reserveCapacity(self.capacity)
    }

    public func write(_ line: String) {
        if lines.count < capacity {
            lines.append(line)
        } else {
            lines[next] = line
            filled = true
        }
        next = (next + 1) % capacity
    }

    public func flush() {}

    /// Oldest first.
    public var contents: [String] {
        guard filled else { return lines }
        return Array(lines[next...]) + Array(lines[..<next])
    }

    public var count: Int { lines.count }

    public func clear() {
        lines.removeAll(keepingCapacity: true)
        next = 0
        filled = false
    }
}

// MARK: - The recorder

/// The single place events are turned into lines and handed to sinks.
///
/// Thread-safety contract: all calls happen on DroidVM's runtime executor (the main
/// thread in the app). This is stated rather than enforced with a lock, because the
/// recorder is called from the frame path and a lock taken per frame is a real cost paid
/// on the hot path to guard against a race that the single-executor design already
/// prevents.
public final class DiagnosticsRecorder: DiagnosticsSink {

    private var sinks: [DiagnosticsLineSink] = []
    private var sequence: UInt64 = 0
    private let startedAt: Date
    private let clock: () -> Date

    /// Events dropped because recording was disabled. Reported rather than silently lost.
    public private(set) var droppedEvents: UInt64 = 0

    public var isEnabled: Bool = true

    /// Optional per-event-name gate, for the Advanced view.
    public var filter: ((DiagnosticEventName) -> Bool)?

    public init(startedAt: Date = Date(), clock: @escaping () -> Date = { Date() }) {
        self.startedAt = startedAt
        self.clock = clock
    }

    public func add(_ sink: DiagnosticsLineSink) {
        sinks.append(sink)
    }

    public func flush() {
        for sink in sinks { sink.flush() }
    }

    /// Milliseconds since the recorder was created.
    public var elapsedMilliseconds: Double {
        clock().timeIntervalSince(startedAt) * 1000.0
    }

    /// The workhorse. Returns the encoded line so tests can assert exactly what was
    /// written, and so a caller can forward it if it needs to.
    @discardableResult
    public func emit(_ event: DiagnosticEvent) -> String? {
        guard isEnabled else { droppedEvents += 1; return nil }
        if let name = DiagnosticEventName(rawValue: event.name), let filter, !filter(name) {
            droppedEvents += 1
            return nil
        }
        sequence += 1
        let text = DiagnosticsEncoder.line(event,
                                           milliseconds: elapsedMilliseconds,
                                           sequence: sequence)
        for sink in sinks { sink.write(text) }
        return text
    }

    @discardableResult
    public func emit(_ name: DiagnosticEventName,
                     _ fields: [String: DiagnosticValue] = [:]) -> String? {
        emit(DiagnosticEvent(name: name.rawValue, fields: fields))
    }

    /// `DiagnosticsSink` conformance. The protocol is Void-returning because a sink has
    /// no business knowing the wire format; `emit` is the version that hands it back.
    public func record(_ event: DiagnosticEvent) {
        _ = emit(event)
    }

    // MARK: typed conveniences
    //
    // These exist so that call sites cannot invent a field name or forget one. They are
    // the only way the runtime emits the corresponding events.

    public func lifecycleChanged(from previous: LifecycleState,
                                to current: LifecycleState,
                                reason: String,
                                evidence: [String: DiagnosticValue] = [:]) {
        var fields = evidence
        fields[DiagnosticField.previousState] = .string(previous.rawValue)
        fields[DiagnosticField.state] = .string(current.rawValue)
        fields[DiagnosticField.reason] = .string(reason)
        emit(.lifecycleChanged, fields)
    }

    /// `DiagnosticsSink` conformance: the structured entry point from the rest of the
    /// runtime. `record(_:)` above and this are the only two ways in.
    public func record(transitionFrom previous: LifecycleState,
                       to current: LifecycleState,
                       reason: String,
                       evidence: [String: DiagnosticValue]) {
        lifecycleChanged(from: previous, to: current, reason: reason, evidence: evidence)
    }

    public func frameWindow(_ window: DisplayCounters, cause: FrameStallCause) {
        var fields: [String: DiagnosticValue] = [
            DiagnosticField.cause: .string(cause.rawValue),
        ]
        // Only non-zero stages are recorded: a frame event carrying six zeroes tells a
        // reader less than a short line does, and the window is already summarised.
        if window.entered > 0 { fields[DiagnosticField.entered] = .int(clamp(window.entered)) }
        if window.received > 0 { fields[DiagnosticField.received] = .int(clamp(window.received)) }
        if window.presented > 0 { fields[DiagnosticField.presented] = .int(clamp(window.presented)) }
        if window.dropped > 0 { fields[DiagnosticField.dropped] = .int(clamp(window.dropped)) }
        if window.noScanout > 0 { fields[DiagnosticField.noScanout] = .int(clamp(window.noScanout)) }
        if window.presentFailure > 0 {
            fields[DiagnosticField.presentFailure] = .int(clamp(window.presentFailure))
        }

        switch cause {
        case .presented:
            emit(.framePresented, fields)
        case .droppedByPresenter:
            // Both the summary and the specific event, because a reader filtering for
            // drops should not have to understand the classifier.
            emit(.framePresented, fields)
            emit(.frameDropped, fields)
        case .noScanout:
            emit(.displayNoScanout, fields)
        case .swapFailed:
            emit(.displayPresentFailed, fields)
        case .noUpdates, .contextUnavailable, .surfaceUnavailable, .unknown:
            // Nothing arrived, so there is no frame event to emit. The lifecycle
            // evidence carries this instead.
            break
        }
    }

    public func memorySample(_ reading: MemoryReading) {
        var fields: [String: DiagnosticValue] = [:]
        if let v = reading.availableBeforeKillBytes {
            fields[DiagnosticField.availableBeforeKillBytes] = .int(v)
        }
        if let v = reading.physicalFootprintBytes {
            fields[DiagnosticField.physicalFootprintBytes] = .int(v)
        }
        emit(.memorySample, fields)
    }

    /// UInt64 counters clamped into Int. A counter large enough to overflow never
    /// happens in practice, and clamping is preferable to trapping while reporting.
    private func clamp(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }
}
