# DroidVM

An Android virtual machine for iPhone, with a one-button experience.

Open DroidVM, tap **Start Android**, use Android, install APKs. Nothing else is
required of the user.

> **Phase 1 — engine bring-up.** Architecture, interfaces, licensing record and build
> gates are in place, and the engine layer now exists behind them: a lifecycle state
> machine, frame accounting with stall classification, runtime preparation, a portable
> QEMU machine definition, diagnostics, and the guest-asset inventory.
>
> It does **not** boot Android yet. The Apple-only adapters under `engine/` are written
> but have never been compiled, linked or run — they need a macOS runner and a device.
> See the status table below and [docs/roadmap.md](docs/roadmap.md).

## Download test IPA

Current device-test build: **[Download DroidVM IPA (commit `3d2a233`)](https://github.com/NabuOX/DroidVM/actions/runs/37701349873/artifacts/11520325351)**

This is an unsigned test IPA and must be re-signed by your sideloading/installation tool before installation.

## What DroidVM is

A consumer iOS app that runs a real Android system in a virtual machine and presents it
as a normal screen. The user is never asked to understand:

JIT · QEMU · renderers · snapshots · RAM limits · resolution · SurfaceFlinger ·
SystemUI · `boot_completed` · frame counters · logs

Those are implementation concerns. They are visible only in an Advanced section, and
only if someone goes looking.

## Status

| Level | What it means | Status |
|---|---|---|
| **A — host foundation** | domain, interfaces, lifecycle, diagnostics, engine syntax, **engine C ABI** | **PASS** — 143 core tests + 55 interop checks |
| **B — iOS compile** | core module, engine adapters and app type-check against the iOS SDK | **BLOCKED** — needs a GitHub remote and a macOS runner |
| **C — engine link** | QEMU cross-compiles, links, and its exported symbols resolve | **BLOCKED** — same; the stage is prepared but has never run |
| **D — device engine start** | the machine starts on a phone | **NOT RUN** |
| **E — Android ready** | Android boots and the display is usable | **NOT RUN** |

A level is never promoted because a lower one passed. Level A says nothing about B, and B says
nothing about C.

**Level A is stronger than a syntax check, but it is still not B.** The engine's C ABI is
verified from Swift on the host — header visibility, the enum, struct layout, out-parameters,
`char **`, function pointers, `const char *` conversion — and one engine adapter
(`TrapExecutableMemory`) is genuinely compiled and its error mapping exercised. What remains
unverified in the engine is everything Apple: Metal, QuartzCore, `dlopen`, `vm_remap`, the trap
itself, and arm64.

## Layout

```
core/       platform-independent domain types and interfaces (SwiftPM, builds anywhere)
app/        the iOS application                                      (Phase 1)
engine/     the virtual-machine engine, behind DroidVM's interfaces  (Phase 1)
scripts/    host checks and CI helpers
docs/       architecture, roadmap, inventory, licensing, build notes
```

`core/` is a real Swift package with real tests, and it deliberately imports nothing
from SwiftUI, UIKit, Combine or Metal. That means it builds and its tests run on the
development machine, in seconds, with no Mac involved. iOS-only code lives in `app/`
and is checked by CI.

## Build and test

Development happens on Windows. There is no local Mac, and the project is designed so
that none is needed.

```bash
./scripts/check_host.sh      # core tests, repository guards, engine syntax
```

That is gate 1 of the build strategy. Gates 2–4 run in CI on macOS:

| Gate | Meaning |
|---|---|
| 1 | host-independent tests — `check_host.sh` |
| 2 | Swift/iOS compile gate — the app target type-checks against the iOS SDK |
| 3 | full app build — compiles, bridges, links, embeds |
| 4 | IPA artifact |

These are reported separately and never inferred from one another. A green compile gate
is not a link, a link is not a signature, and none of them is a device test.
[docs/build.md](docs/build.md) covers the toolchain, including how to obtain a Swift
compiler without administrator rights.

## Licence and distribution

**DroidVM is GPL-2.0-or-later.** This is not a preference; it is forced by what the app
links. The virtual machine engine is QEMU, which is GPLv2 as a whole, and shipping it
inside an IPA distributes a combined work.

The practical consequences:

* **Sideload only.** AltStore, SideStore or TrollStore. **Not the App Store** — GPLv2
  conflicts with its distribution terms, and the runtime needs a debugger to attach.
* **Full corresponding source must be published**, which is why this repository is the
  whole thing and not a partial drop.
* Every reused component is recorded in [THIRD_PARTY.md](THIRD_PARTY.md), with its
  original project, its licence, and how it was reused.

Reused components are accounted for in THIRD_PARTY.md. They are not part of DroidVM's
product identity: they do not appear as product names, bundle identifiers or
user-facing strings anywhere in the tree, and a repository guard enforces that.

Google Play Services is never bundled. That is a licensing prohibition, not a
complexity argument.

## Architecture

[ARCHITECTURE.md](ARCHITECTURE.md) is the specification. Two rules from it are worth
stating here because they shape everything else:

* **One lifecycle.** Boot state is a single state machine owned by one coordinator. It
  is never a set of booleans that a reader has to reconcile.
* **Evidence before action.** Observability is built before recovery. Nothing attempts
  to repair a machine whose state cannot first be described.

## Development rules

These are enforced where they can be, rather than trusted:

1. No other project's branding in the product tree — `scripts/check_repo.py`.
2. No guest images, APKs or large binaries committed — same.
3. Documentation that defines behaviour is asserted against the code —
   `core/Tests/DroidVMCoreTests/DocumentationTests.swift`.
4. No internal mechanism in a consumer-facing label — `LifecycleTests`.
5. `unknown` is never treated as `no` — `TriStateTests`.
6. A snapshot cannot be saved without health evidence — enforced by the type, not by
   review.
