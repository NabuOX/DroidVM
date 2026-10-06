# DroidVM architecture

This is the specification. `core/` implements the vocabulary and the interfaces below,
and tests assert that this document and the code agree — so if you change one, the other
fails to build until it is updated too.

> Phase 1 status: the lifecycle state machine and its rules, the evidence model, the
> frame accounting and stall classifier, runtime preparation, the VM engine adapter and its
> portable machine definition, structured diagnostics, and the guest-asset inventory all
> exist and are tested on the host. The Apple-only adapters under `engine/` are written but
> have never been compiled, linked or run. Nothing here has booted Android.

## 1. The product constraint that shapes everything

A normal person opens the app, taps one button, and uses Android. They do not choose a
renderer, set a RAM limit, pick a resolution, manage snapshots, read logs, or learn what
JIT is.

Every technical decision below is subordinate to that. Where a mechanism would otherwise
leak upward, it is hidden behind an interface and named in plain language at the surface.

## 2. Module map

```
DroidVMApp
│
├── RuntimeController      the one façade the UI is allowed to talk to
│
├── BootCoordinator        owns the lifecycle state machine; single source of boot truth
├── JITManager             exec-memory acquisition, behind JITProvider
├── VMEngine               the virtual machine, behind VMEngine
├── AndroidGuestMonitor    turns engine/guest activity into lifecycle evidence
├── DisplayManager         host surfaces, behind DisplayBackend
├── GraphicsHealthMonitor  frame-stage telemetry and stall classification
├── SnapshotManager        saved machines, gated on health evidence
├── RecoveryManager        evidence-driven repair (Phase 3; declared, not implemented)
├── MemoryPressureManager  measurement first, policy second
├── APKInstaller           install an APK into the guest
├── AppLibrary             what is installed, and launching it
├── Diagnostics            structured events
└── Settings               user preferences, including the Advanced section
```

### The single-façade rule

**SwiftUI views talk to `RuntimeController` and nothing else.** No view imports a QEMU
symbol, starts an engine, reads a frame counter, or decides that boot has finished.

This is not stylistic. The reference implementation let views read boot state directly —
a percentage owned by one type, a readiness flag owned by another, a display kind owned by
a third — and the result was a boot overlay that could be dismissed by a signal that meant
something different from what the view assumed it meant. A façade with one state on it
makes that class of bug unrepresentable.

## 3. Lifecycle

One enum, one owner, explicit transitions. `LifecycleState`:

```
idle
preparing
checkingRuntime
startingVM
bootingAndroid
startingServices
waitingForDisplay
waitingForSystemUI
waitingForLauncher
ready
degraded
recovering
failed
stopping
stopped
```

The **boot sequence** is the ordered subset from `idle` to `ready`. `degraded`,
`recovering`, `failed`, `stopping` and `stopped` are off that axis.

### Rules

1. **Forward only, along the boot sequence.** Skips are allowed: a restored machine
   legitimately arrives part-way through, and a fast device can cross two states between
   samples. Backward movement is legal only out of `degraded` (the evidence cleared) or a
   terminal state (a fresh start).
2. **`ready` is terminal** apart from the machine stopping or failing. A booted system
   does not become unbooted, and a phone sitting on its home screen produces no frames
   without being broken.
3. **Every transition is logged with its reason and its evidence.** A state change with no
   recorded cause is a bug.
4. **`unknown` evidence never causes a transition to a negative outcome.** Not enough
   evidence means `unknown` inputs, and `unknown` is not a fault.
5. **Progress percentage is presentation only.** It is derived from the state — never the
   reverse, and never from the position of a line in a log. `LifecycleState.consumerLabel`
   and any percentage come from the same state in the same read, so a label can never
   describe a different moment than the number beside it.
6. **Nothing moves for want of a clock.** A classifier may use elapsed time as *evidence*;
   no transition is triggered by a timer alone.

### Consumer labels

| State | What the user sees |
|---|---|
| idle | Android is not running |
| preparing | Preparing Android… |
| checkingRuntime | Checking… |
| startingVM | Starting Android… |
| bootingAndroid | Starting Android… |
| startingServices | Starting system… |
| waitingForDisplay | Loading display… |
| waitingForSystemUI | Loading interface… |
| waitingForLauncher | Loading apps… |
| ready | Ready |
| degraded | Android is running with a problem |
| recovering | Recovering… |
| failed | Android could not start |
| stopping | Stopping Android… |
| stopped | Android stopped |

A test asserts that none of these strings names an internal mechanism. A label is exactly
the kind of thing that gets "clarified" into jargon by a later change, so it is enforced
rather than reviewed.

## 4. Evidence model

### Three-valued probes

Every observation about the guest is `yes`, `no` or `unknown`.

* "SystemUI is not running" is a fact about the guest.
* "we could not ask" is a fact about our probe.

Collapsing those into `false` turns a timed-out probe into a reported fault. `TriState`
exists so the mistake is not expressible, and `isConfirmedAbsent` is what a caller uses
when the question is "is it missing".

### Frame accounting

Display health is **never** one number. Six stages, counted separately:

| Counter | Whose evidence |
|---|---|
| `guestFramesGenerated` | the guest's — it is not drawing |
| `hostFramesReceived` | ours — we were handed a frame |
| `framesPresented` | ours — a frame reached the screen |
| `framesDropped` | ours — we took a frame and did not draw it |
| `swapFailures` | ours — presentation failed |
| `noScanoutEvents` | the guest's — we were asked to draw with nothing to draw |

A single "frames" counter cannot distinguish *the guest produced nothing* from *we dropped
everything*. Those have opposite causes and opposite fixes, and both read as `0.0 fps`.

When a window presents nothing, exactly one `FrameStallCause` is chosen — `presented`,
`noUpdates`, `noScanout`, `droppedByPresenter`, `swapFailed`, `contextUnavailable`,
`surfaceUnavailable`, or `unknown`. A zero in a log is always accompanied by a reason.

**An idle Android system legitimately presents no frames.** Readiness depends on whether
anything has *ever* reached the screen, not on a frame rate. `unknown` is preferred over a
guess.

### Memory

Measurement before policy. The figure that matters is available-before-kill: a kill is a
SIGKILL with no handler and no crash log, so watching that figure fall is the only way to
see it coming. An unmeasurable figure does not raise a pressure signal — `nil` is not
"tight".

## 5. Boot coordination and the ready gate

`BootCoordinator` consumes evidence from `AndroidGuestMonitor`:

`vmStarted` · `vmExited` · guest liveness · boot milestones · boot completion ·
service probes · display attached/detached · frame windows · memory · snapshot restored

It owns the state. It answers, in evidence terms and with no percentage arithmetic in
sight: is the machine starting, is Android still booting, is Android booted but waiting for
a display, is the display up but SystemUI absent, is SystemUI up but the launcher absent,
is the system actually ready, is it degraded but alive, did it die.

### Readiness requires all of

| Check | Meaning |
|---|---|
| `guest_alive` | the guest is answering |
| `boot_completed` | Android reported it finished booting |
| `display_attached` | a display surface is bound |
| `presented_frame` | at least one frame has reached the screen |
| `systemui_not_absent` | SystemUI is not *confirmed* missing |
| `launcher_not_absent` | the launcher is not *confirmed* missing |
| `memory_not_critical` | memory is not critically low |

**Absence blocks; ignorance does not.** `systemui_not_absent` and `launcher_not_absent`
are satisfied by `unknown`, and the fact that they were unverified is reported alongside.
The trade-off is deliberate: requiring a confirmed `yes` would leave the boot overlay up
forever on a device where a probe cannot answer, which is worse than readiness that is
merely unconfirmed. Unconfirmed is never silent.

`SnapshotHealthEvidence.requiredChecks` holds this list as data, and a test asserts it
against this document.

## 6. Overlay dismissal

The boot overlay comes down when, and only when, the lifecycle is `ready`. Anything else —
including a machine that reports boot complete with nothing drawn — keeps it visible, with
the state's own label.

The user can always dismiss it themselves; that is a user decision, recorded as such, and
distinct from the app deciding Android is usable.

## 7. Degradation, and recovery

`degraded` means alive but not right. It is reachable only before `ready`, from evidence:

* boot complete, display attached, nothing ever presented, and boot completed longer ago
  than the stall window;
* boot incomplete, guest alive, no milestone for the stall window, and nothing ever
  presented — *both* halves are required, because a long application-compilation phase is
  quiet on the console for minutes while the boot animation is drawing;
* SystemUI confirmed absent after boot completion;
* launcher confirmed absent while SystemUI is up;
* the machine exited without ever completing boot.

`recovering` exists in the vocabulary from the start so that recovery is a state rather
than a side effect, but **Phase 0 implements no recovery.** The rule that governs it:

> Recovery is evidence-driven and bounded. A stage runs only when its precondition is
> observable, every attempt is recorded with its reason and outcome, and the ladder is
> finite. Nothing loops.

## 8. Interfaces

DroidVM-owned protocols; `core/Sources/DroidVMCore/Interfaces.swift`.

| Protocol | Boundary | Notes |
|---|---|---|
| `VMEngine` | the virtual machine | no QEMU vocabulary above this line |
| `JITProvider` | executable memory | failure carries a reason; `.unknown` ≠ `.unavailable` |
| `DisplayBackend` | host surfaces and presentation | exposes counters, never a frame rate |
| `DisplaySurfaceHandle` | opaque host surface | deliberately not `CAMetalLayer` |
| `GuestControl` | talking to Android | transport is an implementation detail |
| `AndroidGuestMonitor` | lifecycle evidence | the stream `BootCoordinator` consumes |
| `SnapshotStore` | saved machines | `save` requires `SnapshotHealthEvidence` |
| `APKInstalling` | installing apps | the user is told whether it worked |
| `MemoryReporting` | memory measurement | figures, not impressions |
| `DiagnosticsSink` | structured events | observability before recovery |

Two deliberate choices:

* **Everything is `async`.** A blocking call reachable from SwiftUI is a hung UI.
* **`SnapshotStore.save` takes `SnapshotHealthEvidence` as a parameter.** There is no
  overload that saves without it, so "save because time passed" — the reference
  implementation's rule, which could freeze a black screen permanently — cannot be written.

## 9. Build and CI strategy

Windows-first. No local Mac is a project requirement.

| Gate | Where | What it proves |
|---|---|---|
| 1 | anywhere — `scripts/check_host.sh` | domain types, interfaces, repository guards |
| 2 | macOS runner | the app target type-checks against the iOS SDK |
| 3 | macOS runner | compiles, bridges, links, embeds |
| 4 | macOS runner | an IPA exists |

Reported separately, never inferred: **COMPILE**, **LINK**, **SIGNING**, **DEVICE TEST**.
A green gate 2 is not a link; a link is not a signature; none is a device test.

## 10. What DroidVM deliberately does not carry forward

Named so that nobody re-introduces them by accident:

* **A percentage derived from log-line order.** A milestone table with guessed ordering
  produced a bar that reached a number belonging to one milestone and a label belonging to
  a different one, and sat there forever.
* **A snapshot rule based on elapsed time and a quiet window.** It had no check that
  anything had ever been drawn, so it could freeze a black screen — and every later launch
  restored that black screen, making one bug look like a permanent one.
* **Readiness inferred from one boot property.** It is true the instant a restored machine
  restores, while nothing is drawing.
* **A single frame counter.** See §4.
* **A view owning boot truth.**
* **A boolean where three states are needed.**
* **Silent failure paths.** Every drop, refusal and skip is counted and rate-limited-logged
  rather than returning quietly.
