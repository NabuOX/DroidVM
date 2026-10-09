# Level D — real device engine start

**LEVEL D IS A MANUAL DEVICE GATE.** No GitHub Actions job can prove it. A runner has no
iPhone, so continuous integration can verify that the engine builds, links and that the state
machine behaves — it cannot verify that a machine started on a phone. This document is the
procedure and the acceptance record.

## What Level D claims, and what it does not

Level D PASS means: **the DroidVM engine starts on a real iPhone.**

It does **not** mean Android booted, that the Android UI appeared, that the launcher or any
system service is ready, that an APK runs, or that graphics perform acceptably. Those belong to
Level E and later. The device report has no field for them, and a host test asserts that its
key set is closed, so a future change cannot quietly add one.

## Why the host tests cannot do this

`core/Tests/DroidVMCoreTests/EngineRunTests.swift` proves the *logic*: that the state machine
visits its stages in order, that every failure reaches a terminal state, and — most importantly
— that no run can report success without the engine confirming it is running. Those tests use
stub collaborators. They never start QEMU and they are not evidence about a device.

## Prerequisites

* A physical arm64 iPhone on iOS 16.4 or later, with a JIT-enabling launch path available for
  this build. Without one the JIT probe returns `UNAVAILABLE` and the run stops at the
  `checkingJIT` stage — which is a **recorded outcome, not a crash and not a bug**.
* Xcode 15.4, `xcodegen`, `meson`, `ninja` and `pkg-config`.
* Level C already green: the engine builds and the app links.

## Procedure

**1. Build the engine and the app.**

```sh
./scripts/build_engine_ios.sh          # all six layers; APP LINK last
```

Gate 3 does this on a runner. Locally it is the same script.

**2. Package.**

```sh
./scripts/package_ipa.sh
```

**3. Install on the iPhone** using whatever signing route the device requires. DroidVM is
sideload-only; it is never submitted to the App Store.

**4. Launch the app.** The status line reads **Ready**. The app must not crash and must not sit
on a spinner. A crash or a hang at this point is a Level D failure and the rest of the
procedure is skipped.

**5. Tap "Start Android".** The status line moves through Preparing… → Checking… → Starting
engine…, and settles on **Engine started** or **Failed**.

**6. Open Diagnostics** (the button in the bottom bar) and copy the whole report. It is text in
a fixed order, so it can be pasted into an issue or a commit message as-is.

**7. Read the report against the criteria below.**

## Acceptance criteria

| # | Criterion | Where it appears |
|---|---|---|
| 1 | App launches, no immediate crash | `app_launch: PASS`, screen reaches **Ready** |
| 2 | The real runtime stack runs, no mock engine | `runtime_controller: PASS` and the engine is the linked one |
| 3 | Swift → C bridge exercised, real status returned | `native_bridge: PASS` (counter layout agreed across the boundary) |
| 4 | Engine initialisation actually invoked, engine reaches a started state | `qemu_init: PASS`, `qemu_started: PASS` |
| 5 | JIT probe is the real on-device probe | `jit:` and `jit_reason:` |
| 6 | Display initialisation recorded | `display_init:` |
| 7 | A compact structured report exists | the Diagnostics sheet |
| 8 | Failures reach a real failed state; the UI never hangs | status settles on **Failed** with a plain reason |

`result: PASS` requires **every** criterion above and no crash:

```
app_launch == PASS   runtime_controller == PASS   jit == READY
native_bridge == PASS   qemu_init == PASS   qemu_started == PASS
display_init == PASS   crash == NO
```

It is **computed, not stored**, so no code path can set it, and an earlier revision that allowed
`display_init: FAIL` to coexist with `result: PASS` has been removed. A green Level D may not
mean "the engine started and something else was broken".

`jit: UNAVAILABLE` remains a valid diagnostic outcome, and cannot produce a pass: without
executable memory the engine's execution path never ran, so there is nothing to confirm.

## The bring-up flow

One press of **Start Android**, one report:

1. install the IPA
2. prepare JIT with StikDebug
3. return to DroidVM
4. press **Start Android** once
5. send the single consolidated report

The pipeline is health-gated: each stage runs only if the one before it passed, and a failure names
the stage that stopped it. The stages are reported as their own fields:

| field | what it means |
|---|---|
| `provider_prepare` | the provider answered the fresh-region request (`x0 = NULL`, `x1 = requested_bytes`) with a `READ\|EXECUTE` mapping at its own base |
| `provider_range` | the range was **walked** and covers all `requested_bytes`. One `vm_region_64` answer describes one region, so a first region of 16 KiB is not a 16 KiB allocation |
| `rw_alias` | a writable alias of the proven range exists, `READ\|WRITE`, with `EXECUTE` never added |
| `readback` | a known instruction sequence written through the alias read back byte-for-byte through the executable view, after `sys_icache_invalidate` |
| `jit_selftest` | one stub executed from the region and returned the expected constant |
| `jit` | `READY` only when every stage above passed, and only then do the later stages run |
| `native_bridge`, `qemu_init`, `qemu_started`, `display_init` | as before, each gated on the previous |
| `android_guest` | **`NOT RUN`** unless a guest monitor actually observed readiness. It is never inferred, and `boot_completed` alone is not readiness |

A stage that was never reached reads **`NOT RUN`**, which is different from **`FAIL`**. `FAIL` means
the stage ran and did not pass; `NOT RUN` means the pipeline stopped before it.

### Reading the failure detail

`detail:` carries the numbers behind the verdict, including `requested_bytes`,
`contiguous_rx_bytes` (what the walk proved), `provider_rx`, `first_region_size`, `regions_walked`,
`range_complete`, `gap_reason`, and the protections observed. A partial range is a **failure**, not a
smaller success: `acquire(bytes:)` promises at least `bytes`, so a range that covers less than the
request is refused and reported with both numbers.

### Execution, and its confinement

This build executes JIT memory in exactly one place: a four-instruction stub (`mov w0, #42 ; ret`)
that returns the constant 42, written through the alias and verified through the executable view
first. The engine gate proves that confinement structurally -- it extracts the `run_self_test` body
and requires that no indirect execution exists anywhere else in the file. Nothing else in the build
executes provider memory.

The self-test arms a fault guard for its own thread only; a fault on any other thread keeps its
default disposition and is re-raised, so an unrelated crash is still a crash.

### What is still not proven

`READY` means the region was measured, aliased, verified and executed. It does **not** mean Android
starts. Level D passes only when the engine is confirmed running, and Level E only when the guest is
usable. Android guest readiness is reported as `NOT RUN` until a guest monitor exists to answer for
it.

## LEVEL D IS CURRENTLY BLOCKED ON TWO ENGINE INTEGRATIONS

`display_init: PASS` and `qemu_started: PASS` cannot both be achieved by this build, and the
report says so rather than working around it.

### 1. The display listener is not inside the engine

`MetalDisplaySurface.attach(surface:)` calls `droidvm_display_set_attached(1)` and then
`droidvm_display_register()`. Registration is answered by the QEMU-side `DisplayChangeListener`,
which only exists inside the engine library -- but:

* `scripts/integrate_engine.sh` still lists `display/droidvm-display.c` and
  `display/droidvm-display-gl.c`, **neither of which exists** (the real file is
  `engine/native/droidvm_display.c`), so it silently copies almost nothing;
* it copies files but never wires them into QEMU's meson build, so nothing would be compiled
  into the dylib even if the files were there;
* nothing inside QEMU calls `droidvm_display_register()`, so the listener is never created.

Until that lands, the display backend can be constructed but cannot register, and
`display_init` is `FAIL`.

### 2. The engine cannot confirm its execution path is running

This is the more serious of the two, because it is the question Level D exists to answer.

`QEMURuntime.start()` runs the engine on its own thread and marks itself running here:

```swift
let initResult = initFn(...)      // qemu_init
if initResult == 0 {
    self.markRunning(true)        // <- isRunning becomes true HERE
    loopResult = loopFn()         // <- qemu_main_loop is entered afterwards
    cleanupFn()
}
```

So `VMEngineAdapter.isRunning` is set **after `qemu_init` returns 0 and before
`qemu_main_loop` is entered**. It is not set by `start()` returning -- it is genuine
asynchronous engine-thread state -- but it means "the machine was constructed", not "the machine
is executing". It is true in the window before the loop is entered, and it stays true if the
loop returns immediately.

Answering the real question needs a marker published from **inside** the engine: a QEMU-side
hook that records main-loop entry, and a bridge symbol that reads it back. Neither exists.
`DroidVMRuntimeConfirmation` therefore returns `unavailable`, and the run fails at the
`runtime_confirmation_unavailable` stage with that reason in `detail:`.

**It does not return `running`.** Doing so would make every Level D result meaningless.

## Timeouts

Neither wait is unbounded. Both have a deadline, and a deadline can only ever produce a
**failure** -- it never advances a state:

| Wait | Deadline | Failure stage |
|---|---|---|
| Engine confirmation | 5 s | `engine_confirm_timeout` |
| Display attachment | 5 s | `display_attach_timeout` |

If a confirmation or an attachment does not answer in time, the state becomes `failed` and the
UI leaves "Starting engine…". A hang is not representable.

## Recording the result

Paste the report verbatim. A screenshot is not the evidence; the report is, because it can be
diffed between two runs.

```
LEVEL D DEVICE REPORT
app_launch: PASS
runtime_controller: PASS
jit: READY
jit_reason: -
native_bridge: PASS
qemu_init: PASS
qemu_started: PASS
display_init: PASS
crash: NO
failure_reason: -
result: PASS
```

**`crash: NO` means this process was still executing when the report was written.** It is the
most a process can honestly say about itself, since it cannot observe its own death.

## What would make this automatic

A hosted device farm with real hardware, a signing identity and a JIT-enabling launch path. Until
that exists, CI proves everything up to and including the link, and a human with a phone proves
the start. The distinction is kept explicit rather than blurred.

## Failure reporting

If the run stops before `engineStarted`, record **exactly where**:

* the state it settled in (`diagnosticLabel`),
* the `failure_reason`,
* the corresponding `stage` from `EngineRunFailure.Stage` — `jit`, `native_bridge`,
  `engine_prepare`, `engine_start`, `engine_confirm` or `display`.

An engine that accepted the start request and did not confirm it is reported at
`engine_confirm`, never as a success. That distinction is the whole point of the level.
