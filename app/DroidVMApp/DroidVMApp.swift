// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVM's application target.
//
// WHAT THIS IS, AND WHAT IT IS DELIBERATELY IS NOT
//
// This is the smallest real app that proves the engine links: it constructs a
// `RuntimeController` wired to the actual engine adapters, and shows the lifecycle's own
// label. That is the whole screen.
//
// It is not the product UX. There is no Android screen, no APK library, no settings, no
// onboarding, and nothing that looks like Android before it can possibly work. A placeholder
// that pretended to be the product would be the most misleading thing in the repository.
//
// WHY IT EXISTS AT ALL
//
// Until now `typecheck_ios.sh` skipped the app stage because `app/DroidVMApp` did not exist,
// so "iOS compile PASS" meant "everything except the application compiles". From this phase
// the app is compiled too, and the gate fails if it is missing rather than silently passing
// a stage with nothing in it.
//
// The view talks to `RuntimeController` and to nothing else. It does not construct a command
// line, touch executable memory, or decide that boot has finished -- which is the rule the
// reference implementation broke by letting views read boot state directly.

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

/// Holds the one façade and republishes its snapshot for SwiftUI.
///
/// `@MainActor` because every `RuntimeController` call is bound to the main executor; the
/// controller documents that contract rather than enforcing it, so this is where it is
/// honoured.
@MainActor
final class EngineModel: ObservableObject {

    @Published private(set) var snapshot: RuntimeSnapshot = .initial

    private let controller: RuntimeController
    private var observer: UUID?

    init() {
        let recorder = DiagnosticsRecorder()
        let ring = RingBufferSink(capacity: 400)
        recorder.add(ring)

        let jit = JITManager(backend: TrapExecutableMemory(), recorder: recorder)
        let engine = VMEngineAdapter(backend: QEMURuntime(),
                                     paths: EngineModel.machinePaths(),
                                     recorder: recorder)

        let controller = RuntimeController(engine: engine,
                                           jit: jit,
                                           display: MetalDisplaySurface(),
                                           recorder: recorder)
        self.controller = controller

        // Registered after every stored property is initialised, so capturing self weakly
        // here is safe.
        self.observer = controller.addObserver { [weak self] snapshot in
            Task { @MainActor in self?.snapshot = snapshot }
        }
    }

    deinit {
        if let observer {
            // `removeObserver` is documented as main-executor-only; deinit of a
            // main-actor-bound object is the one place that is awkward, so the observer id
            // is simply dropped here and the controller's list dies with the model. Written
            // explicitly so the intent is visible rather than implied.
            _ = observer
        }
    }

    func prepareAndStart() {
        Task { await controller.start() }
    }

    func stop() {
        Task { await controller.stop() }
    }

    /// Where the machine's files live.
    ///
    /// Level C is a link gate: it proves the engine links and the app target compiles. It
    /// does not need a guest image, and the brief forbids downloading one for this purpose.
    /// These paths are therefore *locations*, not assertions that anything is there --
    /// nothing in this target reads them.
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

/// The whole product surface for this phase.
struct EngineStatusView: View {

    @ObservedObject var model: EngineModel

    var body: some View {
        VStack(spacing: 16) {
            Text("DroidVM")
                .font(.largeTitle.weight(.semibold))

            Text("Engine build ready")
                .font(.headline)

            // The lifecycle's own label. The view does not decide what to say; it renders
            // what the state machine concluded, which is why a label can never describe a
            // different moment than the number beside it.
            Text(model.snapshot.label)
                .font(.body)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(model.snapshot.progressPercent), total: 100)

            HStack(spacing: 12) {
                Button("Check engine") { model.prepareAndStart() }
                    .buttonStyle(.borderedProminent)
                Button("Stop") { model.stop() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }
}
