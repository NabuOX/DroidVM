// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVM's application target.
//
// WHAT THIS SCREEN IS
//
// Level D's surface, and nothing more. One button, one status line, and a diagnostics section
// that can be read out loud. Tapping "Start Android" runs the REAL runtime stack -- the same
// `JITManager`, `VMEngineAdapter` over the engine, `MetalDisplaySurface` and native bridge the
// product uses -- and stops at "the engine confirmed it is running".
//
// IT DOES NOT BOOT ANDROID, AND IT DOES NOT PRETEND TO
//
// There is no Android screen, no progress percentage, no fake home screen. After a successful
// run the status says "Engine started", which is exactly what happened: the machine is
// executing and no guest operating system has come up. Anything more on this screen would be
// the most misleading thing in the repository.
//
// The status text comes from `EngineRunState.consumerLabel`, so the view never decides what to
// say. Mechanism -- JIT, QEMU, the bridge -- appears only in the Diagnostics section, which is
// opt-in.

import SwiftUI
import DroidVMCore

@main
struct DroidVMApplication: App {
    @StateObject private var model = EngineModel()

    var body: some Scene {
        WindowGroup {
            EngineStatusView(model: model)
        }
    }
}

/// Holds the runtime stack and republishes the Level D state for SwiftUI.
///
/// `@MainActor` because every runtime call is bound to the main executor; the core documents
/// that contract rather than enforcing it, so this is where it is honoured.
@MainActor
final class EngineModel: ObservableObject {

    @Published private(set) var state: EngineRunState = .idle
    @Published private(set) var report = EngineRunReport()

    /// The lifecycle façade, kept wired for the level that needs it. It shares the same engine,
    /// runtime provider and display as the Level D coordinator -- one runtime stack, two
    /// façades -- because a second `VMEngineAdapter` would mean a second machine.
    private let controller: RuntimeController
    private let coordinator: EngineRunCoordinator

    private var observer: UUID?

    init() {
        let recorder = DiagnosticsRecorder()
        recorder.add(RingBufferSink(capacity: 400))

        // The real adapters. No mock, no substitute branch, and nothing here is reachable in a
        // build that does not have the engine linked.
        let jit = JITManager(backend: TrapExecutableMemory(), recorder: recorder)

        // ONE runtime instance, shared. It is the adapter's backend AND the runtime-state
        // provider the confirmer asks, so the state read is the state the engine writes.
        // Creating a second QEMURuntime here would load the dylib twice and ask a second copy.
        let runtime = QEMURuntime()
        let engine = VMEngineAdapter(backend: runtime,
                                     paths: EngineModel.machinePaths(),
                                     recorder: recorder)

        // A display that could not be created is not fatal here: the surface is recorded as
        // absent and the engine start is still attempted and still reported.
        let display = MetalDisplaySurface()
        let surface = display.map { MetalSurfaceHandle(layer: $0.layer) }

        self.controller = RuntimeController(engine: engine,
                                           jit: jit,
                                           display: display,
                                           recorder: recorder)
        self.coordinator = EngineRunCoordinator(engine: engine,
                                                jit: jit,
                                                bridge: DroidVMNativeBridgeProbe(),
                                                // The engine is asked whether its execution
                                                // path is running. It cannot answer yet, so
                                                // this reports `unavailable` and the level
                                                // fails rather than claiming a start it has no
                                                // evidence for. See docs/level-d-device-test.md.
                                                confirmer: DroidVMRuntimeConfirmation(provider: runtime),
                                                display: display,
                                                surface: surface,
                                                // The engine is the only source of QEMU
                                                // display facts, so the report reads them
                                                // from it, not from app-side bookkeeping.
                                                displayTelemetry: { runtime.displayObservation() },
                                                // The coordinator's own display result, so the
                                                // engine's state follows the ONE place attachment
                                                // is decided.
                                                noteHostAttachment: { runtime.noteHostDisplayAttachment($0) },
                                                recorder: recorder)

        // Registered after every stored property is initialised, so capturing self weakly is
        // safe.
        self.observer = coordinator.addObserver { [weak self] state, report in
            Task { @MainActor in
                self?.state = state
                self?.report = report
            }
        }
    }

    func start() {
        Task { await coordinator.run() }
    }

    func stop() {
        Task { await coordinator.stop() }
    }

    /// Where the machine's files live.
    ///
    /// Level D does not need a guest image and the brief forbids downloading one to prove it.
    /// These are *locations*, not assertions that anything is there.
    private static func machinePaths() -> QEMULaunchPaths {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let root = support.appendingPathComponent("DroidVM", isDirectory: true)
        let bundle = Bundle.main.bundlePath

        return QEMULaunchPaths(
            firmwareCode: bundle + "/edk2-aarch64-code.fd",
            firmwareVars: root.appendingPathComponent("efi-vars.fd").path,
            systemDisk: root.appendingPathComponent("vda.qcow2").path,
            userdataDisk: root.appendingPathComponent("vdb.qcow2").path,
            pcBiosDirectory: bundle + "/pc-bios",
            serialLog: root.appendingPathComponent("serial.log").path)
    }
}

/// Level D's whole product surface.
struct EngineStatusView: View {

    @ObservedObject var model: EngineModel
    @State private var showsDiagnostics = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("DroidVM")
                    .font(.largeTitle.weight(.semibold))

                Text(model.state.consumerLabel)
                    .font(.title3)
                    .foregroundStyle(model.state.isFailure ? .red : .secondary)
                    .accessibilityIdentifier("levelD.status")

                // The user-safe reason, when there is one. Never a mechanism string.
                if let reason = model.report.failureReason {
                    Text(reason)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                if model.state.isInProgress {
                    ProgressView()
                }

                HStack(spacing: 12) {
                    Button("Start Android") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.state.isInProgress)

                    Button("Stop") { model.stop() }
                        .buttonStyle(.bordered)
                        .disabled(!model.state.engineIsRunning)
                }

                Spacer()
            }
            .padding(32)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(showsDiagnostics ? "Hide diagnostics" : "Diagnostics") {
                        showsDiagnostics.toggle()
                    }
                }
            }
            .sheet(isPresented: $showsDiagnostics) {
                DiagnosticsView(state: model.state, report: model.report)
            }
        }
    }
}

/// The device report, and the developer-facing state name.
///
/// Everything the normal screen is not allowed to say lives here, behind a tap. This is what
/// makes a device run checkable without a screenshot of a status line: the report is text, in a
/// fixed order, and can be read, copied or photographed as a whole.
struct DiagnosticsView: View {

    let state: EngineRunState
    let report: EngineRunReport

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report.rendered)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Level D report")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
