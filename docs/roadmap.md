# Roadmap

Each phase states what it delivers, how it is accepted, and what it deliberately does not
do. Phases are not started before their predecessor is accepted, because the whole point
of the ordering is that observability exists before anything acts on it.

---

## Phase 0 — foundation ✓ **delivered**

Architecture, interfaces, licensing record, component inventory, build gates, identity.

**Delivered**

* `core/` — a platform-independent Swift package: the lifecycle vocabulary, the evidence
  model, the interface declarations, and tests asserting the rules that matter.
* `ARCHITECTURE.md`, `THIRD_PARTY.md`, `docs/component-inventory.md`, `docs/licensing.md`,
  `docs/build.md`, this file.
* `scripts/check_host.sh` — gate 1, runnable on Windows, Linux or macOS.
* `.github/workflows/ci.yml` — gates 2–4 on macOS runners.
* `scripts/check_repo.py` — identity, provenance and artifact guards.

**Accepted when** `./scripts/check_host.sh` passes: the core package builds and its tests
pass on the development machine, and the repository guards pass.

**Not in this phase:** no Android boot, no engine code, no copying from the reference
implementation.

---

## Phase 1 — engine bring-up, observable from the first commit ← **current**

**Status: Level A reached; Levels B–E not run.** Everything platform-independent is
implemented and tested on the host: the lifecycle state machine, frame accounting with stall
classification, runtime preparation, the VM engine adapter, the portable QEMU machine
definition, structured diagnostics, and the guest-asset inventory. The Apple-only adapters
exist under `engine/` and have never been compiled, linked or run, because that needs a macOS
runner and a device.


Get a real Android system to boot and appear on screen **with the lifecycle and the frame
telemetry in place from the start**, so that every later phase has evidence to act on.

**Deliver**

1. Engine skeleton: `engine/` builds behind the DroidVM interfaces; `VMEngine`,
   `DisplayBackend`, `JITProvider`, `GuestControl` have first real conformances.
2. `JITManager` — executable memory, with a correct availability signal (present only
   after a successful execute self-test).
3. `DisplayManager` + `GraphicsHealthMonitor` — the six frame counters, live, with a named
   stall cause for every empty window.
4. `BootCoordinator` — the state machine's transition rules, one owner, every transition
   logged with its reason and evidence.
5. `RuntimeController` — the single façade. The UI talks to this and nothing else.
6. `AndroidGuestMonitor` — service probes in three states each.
7. A consumer UI: product name, **Start Android**, **Install APK**, and a boot overlay that
   dismisses only on `ready`.
8. `APKInstaller` + `AppLibrary` — install an APK over the guest shell and launch it.
9. Guest provisioning with **DroidVM-hosted assets** (see the open questions below).
10. CI gates 2–4 green, and an unsigned IPA as an artifact.

**Accepted when** — *none of these can be evaluated yet; the engine has never run*

* On a real device, tapping **Start Android** reaches `ready` and Android is usable.
* A machine that reports boot complete with nothing drawn stays in `waitingForDisplay`
  with the overlay visible — the restore race, closed.
* With the display deliberately stalled, the log names a specific stall cause rather than
  a bare `0.0 fps`.
* No consumer-facing label names an internal mechanism (the test already enforces this).
* A restart from a saved machine is never required for correctness.

**Not in this phase:** no recovery, no automatic renderer switching, no timeout-triggered
restarts, no snapshot auto-save, no Advanced mode.

---

## Phase 2 — graphics health and honest degradation

**Deliver:** the stall detector with its full evidence set; `degraded` reachable only on
evidence; per-stage drop counting surfaced; memory telemetry with the available-before-kill
series.

**Accepted when** the known black-screen failure, if reproduced, produces a specific
`degraded` reason and a named blocker set — and no recovery is attempted.

**Not in this phase:** still no recovery. Phase 2 exists to prove the diagnosis.

---

## Phase 3 — evidence-driven, bounded recovery

**Deliver:** `RecoveryManager` with a finite, ordered ladder. Each stage runs only when its
precondition is observable, and each attempt records its reason and outcome. The ladder
stops; it does not loop.

Stages, in order of increasing invasiveness: refresh the surface; rebind presentation; ask
the guest to redraw; restart the compositor when the guest is otherwise healthy; switch
renderer; restore the last known-good saved machine; restart the machine cleanly.

**Accepted when** a stalled machine recovers without user involvement in at least one
observed case, and a machine that cannot recover reports a specific reason rather than
retrying forever.

**Not in this phase:** no snapshot auto-save yet — recovery makes the machine usable, it
does not freeze it.

---

## Phase 4 — snapshots, gated on health

**Deliver:** `SnapshotManager` with the seven-check health gate enforced by the type;
compatibility stamps for guest memory and display shape; invalidation on configuration
change; a documented restore path.

**Accepted when** a second launch is materially faster; a snapshot of a machine that never
drew a frame is impossible to take; and a snapshot taken in the wrong display or memory
shape is refused rather than restored into a broken machine.

**Not in this phase:** no snapshot sharing or pre-booted image distribution.

---

## Phase 5 — consumer polish

Advanced mode (diagnostics, logs, boot stage, memory, recovery history, snapshot controls),
onboarding, first-run asset download, and the plain-language explanation shown when the
runtime cannot be prepared.

**Accepted when** a non-technical person can install DroidVM, start Android, install an APK
and use it without reading anything about the runtime.

---

## Phase 6 — hardening

The matrix: repeated cold starts; repeated snapshot starts; renderer failures; display
shape changes; low memory; failed APK install; guest crash; background/foreground;
interruption; runtime unavailable; runtime lost mid-session.

**Accepted when** each row either passes on a real device or has a documented, explained
failure.

---

## Open questions and risks

### 1. Guest asset hosting — **decided**

**Recommendation: build the image in DroidVM's own CI and distribute it as a first-run download
from DroidVM-controlled release assets. Reject externally hosted prebuilt images. Defer the
pre-booted snapshot.** The reasoning, the comparison of all three options and the cost estimate
are in [guest-distribution.md](guest-distribution.md).

What remains is the work: a guest-build workflow in a separate images repository, and the
kernel source offer published beside each release. Neither is done, and no asset has been
uploaded. `GuestAssetCatalog` marks the guest disks `droidvmMayRedistribute: false` in the
meantime, so the decision cannot be violated by accident.

### 2. The kernel source offer — **licensing obligation**

A guest image contains a GPLv2 Linux kernel. Distributing the image obliges DroidVM to
offer that kernel's corresponding source. Pin the precise kernel tag and publish the offer
next to the image. See `THIRD_PARTY.md`.

### 3. Device access for testing

Gates 1–3 run in CI. Gate 4 and every "accepted when" above that says *on a real device*
need a physical iPhone, a runtime-activation path, and a human. No automated substitute
exists, and none should be faked.

### 4. Signing

Unsigned IPAs are the target: SideStore, AltStore or TrollStore re-sign at install, so no
signing team is required and one artifact works for everyone. If that changes, the CI
pipeline needs a signing identity and a provisioning profile, which is a separate problem
with a separate secret-management story.

### 5. Renderer default

The reference implementation ended up defaulting to software rasterisation for Android,
because the GPU path made the guest's own Mesa/virgl driver do more emulated work than the
rasterisation it saved. DroidVM should measure this on the target device rather than
inherit the conclusion.

### 6. No local Mac

Every iOS-specific change costs a CI round trip. This is why `core/` exists and why the
rule is that anything which *can* be platform-independent *is*.
