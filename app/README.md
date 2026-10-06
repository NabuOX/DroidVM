# `app/` — the iOS application

Phase 1 creates the Xcode target here. Nothing is implemented yet.

## What goes here

| Group | Contents | Gate |
|---|---|---|
| `DroidVMApp/` | app entry point, SwiftUI shell | 2 |
| `Runtime/` | `RuntimeController` — the single façade the UI talks to | 2 |
| `Boot/` | `BootCoordinator` — the lifecycle state machine's owner | 2 |
| `Display/` | `DisplayManager` — host surfaces and presentation | 2 |
| `Guest/` | `AndroidGuestMonitor`, `GuestControl`, `APKInstaller`, `AppLibrary` | 2 |
| `Diagnostics/` | structured events (gate 1 for the encoder) | 1 + 2 |
| `Settings/` | preferences, including the Advanced section | 2 |
| `GuestProvisioning/` | image download, digest verification, installation | 2 |

The lifecycle vocabulary, the evidence model and the interfaces live in
[`../core`](../core) — a package that builds and tests on **any** platform. Only the
iOS-specific adapters belong here. If something in `app/` can be moved into `core/`, it
should be: every line in this directory costs a macOS CI round trip to verify.

## Rules

1. **Views talk to `RuntimeController` and nothing else.** No view starts an engine, reads
   a frame counter, or decides that boot has finished. The reference implementation's boot
   overlay was dismissible by a signal that meant something different from what the view
   assumed, and a single façade makes that unrepresentable.
2. **No engine vocabulary above the interface line.** No `qemu_*`, no EGL, no virtio, no
   argv. Those belong to the adapters in `../engine`.
3. **No consumer-facing label names a mechanism.** Enforced by
   `LifecycleTests.testConsumerLabelsLeakNoInternalMechanisms`.
4. **No other project's branding.** Enforced by `scripts/check_repo.py`.

## Build identity

Provisional values live in `DroidVMCore.Identity`. `identifiersAreProvisional` flips to
`false` once the final bundle identifier is registered and the first build is signed —
changing it later breaks every existing install and every saved path.
