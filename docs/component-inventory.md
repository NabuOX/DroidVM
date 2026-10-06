# Component inventory: what to reuse, adapt, reference or reject

Phase 0 task: inspect the reference implementation (`Leviidev/Husk`, GPL-2.0-or-later) and
classify every component so Phase 1 starts from decisions rather than from a codebase.

| Class | Meaning |
|---|---|
| **A** | reusable essentially as-is — self-contained, dependency-free, and tested |
| **B** | reusable after heavy adaptation — the behaviour is needed, the shape is not |
| **C** | reference only — read it, understand it, write DroidVM's own |
| **D** | reject — do not carry forward, for a stated reason |

DroidVM destinations: `core/` (platform-independent Swift package), `app/` (iOS app),
`engine/` (C/ObjC engine and vendored dependencies), `scripts/`, `docs/`.

**No code was copied in Phase 0.** This is a plan, and every row that results in reuse is
recorded in [THIRD_PARTY.md](../THIRD_PARTY.md) when it happens.

---

## A — reusable essentially as-is

These are dependency-free and already carry their own tests. They are the cheapest and
highest-value things to take, and they are exactly the parts that encode the lessons.

| Reference component | What it does | Destination | Notes |
|---|---|---|---|
| `src/ios-jit/husk-display-stats.h` | frame/display counter taxonomy and the rule that turns a window of counters into one named cause | `engine/display/` | No QEMU headers, no libc beyond `stdint`. 54 tests. Directly implements lesson 3. |
| `src/ios-jit/husk-lifecycle.h` + `.c` | lifecycle state machine: states, legal transitions, ready gate, progress mapping | `engine/lifecycle/` | Header-only rules + a tiny exported wrapper. 235 tests. The Swift `LifecycleState` in `core/` mirrors it. |
| `src/ios-jit/husk-boot-diag.h` | diagnostic boot classifier (still-booting / graphics-stalled / SystemUI / launcher / memory / dead) | `engine/diagnostics/` | 131 tests. Overlaps DroidVM's lifecycle; keep as the *diagnostic* view, not the state. |
| `src/app/Husk/HuskEvents.swift` | structured event field conversion and JSON Lines encoding | `app/Diagnostics/` | Foundation-only, 51 tests. Portable and self-contained. |
| `src/app/Husk/fishhook.c` + `.h`, `PipeShim.c` | rebinds `pipe2` for iOS versions whose SDK withholds it | `engine/compat/` | Tiny, single-purpose, no alternative. |
| `src/ios-jit/husk-brk.S` | the three `brk` instruction pairs a debugger services to grant executable memory | `engine/jit/` | Three pairs dictated by an external protocol. Reimplementing takes minutes and makes the provenance unambiguous — recommended, but copying is defensible. |
| `patches/qemu-10.0.12-utm.patch`, `pixman-0.38.0.patch`, `libslirp-v4.9.1.patch` | the upstream patches the engine needs | `engine/vendor/patches/` | From UTM; GPL-2.0 / MIT / BSD-3-Clause per each project. |

---

## B — reusable after heavy adaptation

The behaviour is needed and hard-won; the *shape* is the reference project's product, not
DroidVM's. Each of these becomes something smaller behind a DroidVM interface.

### Engine (C)

| Reference component | What it does | Destination | What changes |
|---|---|---|---|
| `src/ios-jit/husk-ios-jit.c` + `.h` | obtains an RX region from an attached debugger via a `brk` trap, makes an RW alias with `vm_remap`, and diverts TCG's split-W^X allocator to it | `engine/jit/` | Wrap behind `JITProvider`; fix the availability flag that is set before the self-test and never cleared; keep the upstream SPDX header, since this file is itself derived from a GPL-2.0-or-later project |
| `src/ios-jit/husk-display.c` + `.h` | software display path: register a `DisplayChangeListener`, hand the app a pixman surface to pull | `engine/display/` | Split the frame counters out (class A already provides them); expose through `DisplayBackend` |
| `src/ios-jit/husk-display-gl.c` + `.h` | GL/EGL path, and the Metal presenter hook that hands the app a scanout texture | `engine/display/` | Same split; the Metal-vs-GL-rasterisation reasoning in its comments is worth preserving |
| `src/ios-jit/husk-snapshot.c` + `.h` | savevm/vmstate save and load | `engine/snapshot/` | **Add the health gate the original lacked.** Its save path has no health check at all; the gate existed only in Swift, and was time-based |
| `src/ios-jit/husk-balloon.c` + `.h` | virtio balloon control for reclaiming guest memory | `engine/memory/` | Becomes the actuator behind `MemoryPressureManager`; the policy is measurement-first |
| `src/ios-jit/husk-audio.c` + `.h` | AudioUnit backend for QEMU plus the QAPI enum wiring it needs | `engine/audio/` | Phase 2; the two hand-written switches that abort with no message are the whole trick |
| `scripts/integrate_husk.sh` | copies `src/ios-jit/*` into the QEMU tree, rewrites three `meson.build` files, and maintains `system/qemu.symbols` — pruning stale `husk_*` names and adding missing ones | `scripts/integrate_engine.sh` | The export-list maintenance is the critical knowledge: a symbol missing from that list **links fine and fails at `dlopen`**. Also stages the new dependency-free headers |

### Application (Swift/ObjC)

| Reference component | What it does | Destination | What changes |
|---|---|---|---|
| `QemuRunner.swift` | the god object: thread, argv, boot percentage, FPS, memory watch, snapshot trigger, installer hooks | split across `RuntimeController`, `VMEngine` adapter, `BootCoordinator`, `DisplayManager`, `MemoryPressureManager` | Its **argv knowledge and its comments** are the asset (CPU model, `pauth-impdef`, SVE/SME off, file-backed RAM, split-wx). Its *state* is not — the milestone table, progress percentage and auto-save trigger are class D |
| `HuskBridgeFS.swift` | three types in one file: a 9p file bridge, a guest shell over TCP 5599, and a `@MainActor` façade | split into `GuestControl` (the 5599 shell), `APKInstaller`, `AppLibrary`, and a small 9p helper | The 5599 netcat-shell-over-forwarded-TCP trick is the most valuable single idea in the project: it gives `adb shell`-equivalent authority with no ADB, and it is transport, so it belongs behind `GuestControl` |
| `HuskLog.swift` | unified logging: stdout/stderr redirection, ring buffer, `os_log`, synchronous file writes, crash handlers | `app/Diagnostics/` | Structured events become first-class rather than a second sink; DroidVM naming |
| `HuskGLView.swift` | the single `CAMetalLayer` published to the engine, placement diagnostics | `app/Display/` | Keep the single-instance insight: a second view orphans the EGL surface and the frame counter climbs against a black screen |
| `HuskMetalPresenter.swift` | draws the guest's `MTLTexture` straight into the layer, bypassing GL | `app/Display/` | Keep; its drop paths become counted instead of silent |
| `HuskMetalView.swift` | software-path uploader (`MTKView` + texture replace) | `app/Display/` | Keep as the fallback backend |
| `GuestImage.swift`, `GuestManifest.swift`, `BundleUnpacker.swift` | download, verify by digest, unpack and install the guest image and a pre-booted snapshot | `app/GuestProvisioning/` | **Rehost the assets.** Today they are fetched from another project's GitHub release assets; DroidVM must publish its own. Everything else — digest-over-version checking, partial-part snapshot assembly — is worth keeping |
| JIT Swift layer (`JITBootstrap`, `JITSetup`, `JITBuiltIn`, `JITPairing`, `JITCard`, `JITSetupView`) | activation routes: external debugger, TrollStore, built-in StikJIT helper, on-device pairing | `JITManager` + `app/Setup/` | Mechanism kept, UI rewritten. The one-line start-gate bug (`!prewarm(), !isLive` short-circuits) must not be carried over |
| `ApkMetadata.swift` | parses an APK's manifest and `resources.arsc` for its label and icon | `app/Library/` | Genuinely useful and has no cheaper substitute |
| `HuskKeyboard.swift`, `HuskGamepad.swift`, `VirtualPad.swift` | on-screen keyboard, special keys, game controllers | `app/Input/` | Phase 2+ |
| `HuskRPPairing.h`, `src/rppairing-ios` | on-device pairing with a helper, over RemotePairing | `engine/pairing/` | Depends on `idevice` (MIT); the wrapper is GPL like the rest |
| `scripts/build_ios.sh`, `sources.sh`, `package_ipa.sh` | cross-compile the dependency set and QEMU; package and validate an unsigned IPA | `scripts/` | `package_ipa.sh`'s bundle validation is the part worth keeping: a bundle missing `CFBundleIdentifier` or an embedded dylib builds and zips happily, then fails to install with no useful message |
| `Husk.entitlements` | `get-task-allow`, increased memory limit, dynamic-codesigning | — | Re-author for DroidVM's identifiers; the *set* is reference, the file is not |

### Guest asset provenance (recorded here, not in the roadmap)

The reference implementation's guest assets are published as GitHub release assets of its
own repository. The versions pinned in its source:

| Asset | Version | URL pattern |
|---|---|---|
| `vda` Android image | image `v12` | `https://github.com/Leviidev/Husk/releases/download/<deps-tag>/vda-v12.qcow2` |
| `vdb` pre-booted snapshot | image `v12`, 2 parts | `.../vdb-snapshot-v12.qcow2.gz.0` … `.1` |
| userdata seed | `v10` | `.../lineage-vdb-seed.qcow2` |
| release manifest | `generation`-stamped JSON | `https://github.com/Leviidev/Husk/releases/download/<deps-tag>/manifest.json` |

The manifest is the right idea and DroidVM keeps it: it carries a file name, a SHA-256 and a
size for the image and the snapshot separately, plus the guest memory and display dimensions
the snapshot was taken with. Verifying by digest rather than by version string is what makes
a truncated download detectable, and recording the dimensions is what makes an incompatible
restore refusable instead of silently wrong.

DroidVM must publish its own equivalents. The assets are roughly a gigabyte and two
gigabytes, so this is a real cost; `docs/roadmap.md` tracks it as the open question that
blocks Phase 1.

---

## C — reference only

Read for the reasoning; write DroidVM's own, or leave alone.

| Reference component | Why reference only |
|---|---|
| `docs/00-architecture.md` … `docs/06-built-in-jit.md` | The design record. The single most useful thing in the repository, and the reason the D rows below are identifiable at all. |
| `docs/01-licensing.md` | The licence analysis DroidVM's `docs/licensing.md` is derived from. |
| `src/translation-layer/`, `src/translation-layer-next/` | An entire second runtime — a linker, a bionic shim, a JNI implementation, game-engine drivers — for running APKs *without* Android. Large, off DroidVM's product goal (a VM), and its own multi-phase project. May be interesting later. |
| `TranslationLayer.swift`, `TLUnityView.swift`, `TLScreenView.swift` | The UI and driver for the above. |
| `AppSource.swift`, `DiscoverTab.swift`, `catalog/source.json` | A curated app catalogue and F-Droid index parsing. A good idea for Phase 2; the branding in the catalogue is not. |
| `tests/husk_display_probe.c`, `scripts/run_display_probe.sh` | Drives the real patched QEMU on macOS and reports whether the display bridge receives frames. Excellent idea — DroidVM should have its own, because it tests the bridge somewhere it can be observed. |
| `tools/*` (cocos, unity, ga, ue, sdl, dex, tl-cli, …) | Test harnesses for the translation layer. |
| `research/decoded/stikdebug_jit26_universal.js` | The debugger-side script that services the `brk` traps. Needed to understand the protocol; not DroidVM code. |
| `docs/03-phase0-runbook.md`, `docs/05-…-handoff.md` | Project-specific history. |
| `scripts/build_angle_ios.sh`, `build_gpu_ios.sh`, `build_moltenvk_ios.sh`, `build_macos_validation.sh`, `add_ethernet_feature*.sh`, `fetch_*.sh`, `publish_*.sh`, `set_grub_toggles*.sh`, `repro_waydroid_local.sh`, `cloud-init/*` | Build and image-publishing plumbing, tied to the current asset hosting. Mine for specifics; DroidVM's pipeline is its own. |

---

## D — reject

Do not carry these forward. Each has a reason, and most are the accumulated cost the
lessons in the brief came from.

| Rejected | Reason |
|---|---|
| **The entire UI** — `ContentView`, `BootScreen`, `LibraryTab`, `LibraryView`, `SettingsTab`, `OnboardingView`, `FilesTab`, `AppDetailView`, `AppTheme`, `Theme`, `HuskAppIcon` | Not DroidVM's product. Lesson: a view owning boot truth is how the overlay came to be dismissed by a signal that meant something else. `LibraryView` and `RunningAppView` are additionally unreachable dead code. |
| `Assets.xcassets` | Another project's icons. DroidVM needs its own identity. |
| The `bootMilestones` table, `QemuRunner.bootProgress`, and `BootScreen`'s creep and ETA | **Lesson 7.** The percentage was a monotonic clamp over guessed milestone scores while the label came from whichever milestone matched most recently, so a later lower-scoring milestone produced a number belonging to one milestone and words belonging to another — and a stalled boot crept to 95% having made no progress. DroidVM derives both from the lifecycle state. |
| The `quietWindows` / `overdue` auto-save trigger | **Lesson 6.** It fired on elapsed time and a quiet window with no check that anything had ever been drawn, so it could freeze a black screen; every later launch then restored that black screen, which is how one bug came to look permanent. |
| `AndroidHost.waitForReady` as *the* notion of readiness | It is an unbounded `while true` polling one boot property, and that property is true the instant a restored machine restores. Readiness is a lifecycle state with an evidence gate. |
| The `AndroidHost` god object | Three responsibilities in one `@MainActor` type. Split. |
| `boot_classification` as a *driver* of anything | In the reference it is diagnostic only, and DroidVM keeps it that way — the classifier describes, the lifecycle decides. |
| `patches/console-with-checkpoints.c`, `patches/shader-with-checkpoints.c` | Debug-only instrumented copies. |
| `HuskJITHelper` naming and bundle layout | Mechanism is class B; identity is not. |
| `.husk-scan.js`-style scratch files | Not part of any project. |
| Silent failure paths generally | Present paths that return without counting or logging: the display update that bails before incrementing anything, the Metal presenter that drops a frame with no log, the JIT availability flag that can be true for a region that was just released. Every one of them becomes a counter in DroidVM. |

---

## Summary

| Class | Components | Phase 1 action |
|---|---|---|
| A | 7 | Take first. Small, dependency-free, tested, and they encode the lessons. |
| B | ~20 | Adapt one at a time, each behind a DroidVM interface. |
| C | ~10 groups | Read as needed. |
| D | 12 | Do not port. Listed so they are not re-introduced by accident. |

## Recommended Phase 1 order

The dependency graph decides it: the parts with no dependencies land first, and each one
makes the next testable.

1. `engine/display/husk-display-stats` (A) — no dependencies at all.
2. `core/` lifecycle vocabulary already exists (Phase 0); add the transition rules from
   `engine/lifecycle/` (A) with their tests.
3. `app/Diagnostics/` event encoder (A) — gives everything after it somewhere to report.
4. `engine/compat/` `pipe2` shim (A), then `engine/jit/` (B) — executable memory is the
   precondition for any VM at all.
5. `engine/display/` (B) and `app/Display/` (B) — a display path that can be observed.
6. `engine/snapshot/` (B) **with the health gate added**, and `engine/vendor` + build glue.
7. `app/GuestProvisioning/` (B) with DroidVM-hosted assets.

Recovery stays out of Phase 1: observability first.
