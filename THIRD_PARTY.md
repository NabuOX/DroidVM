# Third-party components and code provenance

DroidVM reuses work that other people wrote. This file records every component, where it
came from, what its licence is, how DroidVM uses it, and where it ends up. Nothing here is
concealed, and nothing may be added without a row.

Read this before copying anything into the tree. The `Reuse` column uses exactly four
values:

| Value | Meaning |
|---|---|
| **copied** | taken verbatim |
| **modified** | taken and changed; changes are DroidVM's |
| **reimplemented** | behaviour reproduced from scratch, no code taken |
| **not reused** | examined and rejected, recorded so nobody re-introduces it |

## Status: Phase 0

**Phase 0 copies no engine code.** The only file taken from elsewhere is the GPL-2.0
licence text itself, which exists to be copied verbatim. Every row below marked *planned*
is a Phase 1 decision that has been recorded rather than made.

---

## Status: Phase 1

**Phase 1 copies no code and no file.** Everything reused from the reference implementation
in Phase 1 was read, understood and *reimplemented* in DroidVM's own vocabulary, in Swift, in
`core/` — where it can be tested on the host. The `Reuse` value for every Phase 1 row is
therefore **reimplemented**, and each row names the exact file the design came from so a
reader can compare the two.

That is a deliberate choice, not a technicality:

* The reference equivalents live in C headers and a 2000-line Swift runner that compile only
  with QEMU and Xcode present. Reimplementing the *rules* in the portable package is what
  makes them testable on the development machine, which is the entire point of the build
  strategy.
* One implementation, one source of truth. Carrying a C rule engine *and* a Swift one would
  give DroidVM two lifecycles that could disagree — the failure the brief warns about.

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| Frame/display counter taxonomy and stall classification | `src/ios-jit/husk-display-stats.h` | GPL-2.0-or-later | **reimplemented** | `core/Sources/DroidVMCore/Display/DisplayStats.swift` |
| Lifecycle state machine, ready gate, degradation rules | `src/ios-jit/husk-lifecycle.h`, `husk-lifecycle.c` | GPL-2.0-or-later | **reimplemented** | `core/Sources/DroidVMCore/Boot/LifecycleEngine.swift` |
| Diagnostic boot classifier (diagnostic view only) | `src/ios-jit/husk-boot-diag.h` | GPL-2.0-or-later | **reimplemented** as `LifecycleEngine.degradation` | `core/Sources/DroidVMCore/Boot/LifecycleEngine.swift` |
| Structured event encoding: JSON Lines, sorted keys, null-for-unknown, escaping, non-finite handling | `src/app/Husk/HuskEvents.swift` | GPL-2.0-or-later | **reimplemented** | `core/Sources/DroidVMCore/Diagnostics/Diagnostics.swift` |
| QEMU machine definition: CPU model, accelerator flags, device set, drive options, node naming, port forwards | `src/app/Husk/QemuRunner.swift` — the argv block and its comments | GPL-2.0-or-later | **reimplemented as data** | `core/Sources/DroidVMCore/VM/QEMULaunchPlan.swift` |
| Guest manifest: digest-over-version verification, snapshot parts, machine dimensions | `src/app/Husk/GuestManifest.swift`, `GuestImage.swift` | GPL-2.0-or-later | **reimplemented** | `core/Sources/DroidVMCore/Assets/GuestAssets.swift` |
| The three `brk` instruction pairs and the trap protocol | StikDebug's published script; also in the reference tree as `husk-brk.S` | the protocol is not copyrightable subject matter | **reimplemented** | `engine/jit/droidvm-brk.S` |
| Machine stamp as a snapshot-compatibility identity | `src/app/Husk/QemuRunner.swift`, `machineStamp` | GPL-2.0-or-later | **reimplemented** | `QEMUMachineShape.stamp` |
| SHA-256 for asset verification | none — published algorithm, FIPS 180-4 test vectors | public domain algorithm | **authored here** | `core/Sources/DroidVMCore/Assets/SHA256.swift` |
| Bundle validation before packaging: the required Info.plist keys, the executable named by `CFBundleExecutable` actually existing, and every embedded dylib present | `scripts/package_ipa.sh` | GPL-2.0-or-later | **adapted** | `scripts/package_ipa.sh` |
| The export-list maintenance insight: QEMU's shared-library build exports only `system/qemu.symbols`, so a missing symbol links and fails at `dlopen` | `scripts/integrate_husk.sh` | GPL-2.0-or-later | **adapted** | `scripts/integrate_engine.sh` |
| Cross-compilation target triple and meson cross-file shape | `scripts/build_ios.sh`, `scripts/sources.sh` | GPL-2.0-or-later | **adapted** | `scripts/build_engine_ios.sh` |
| The dependency version pins (QEMU 10.0.12-utm, glib 2.83, pixman 0.38, libffi 3.5, libiconv 1.16, gettext 0.22.5, libucontext, libslirp 4.9.1) | `scripts/sources.sh` | GPL-2.0-or-later (the pins) | **adapted** | `scripts/build_engine_ios.sh` |

### The `husk-jit.js` finding — do not carry this forward

The reference implementation ships `src/app/Husk/Resources/husk-jit.js` inside its app
bundle. It is **byte-identical** (SHA-256 `4515336a0c3a62920f8b16e8b230c581…`) to
`research/decoded/stikdebug_jit26_universal.js`, a file derived from StikDebug, which is
**AGPL-3.0** — and it carries **no licence header, no copyright notice and no attribution of
any kind**.

DroidVM must not copy that file. Three separate problems:

1. **Relicensing.** Taking AGPL code and shipping it under a GPL-2.0-or-later notice is a
   licence violation.
2. **Attribution.** The notice is absent, so even a permitted use would be undocumented.
3. **Compatibility, subtler than it first looks.** AGPLv3 *is* compatible with GPLv3
   (AGPLv3 §13), and DroidVM's "or-later" wording permits the combination to be taken under
   GPLv3 — but **not** under GPLv2-only, which is what QEMU forces for the rest of the
   combined work. Bundling it would put the project's licence position in tension with
   itself.

**What DroidVM does instead**, in order of preference:

* **Use StikJIT's own script.** The StikJIT XCFramework DroidVM already embeds ships
  `universal.js` and `legacy.js` under MPL-2.0, properly licensed, as part of a framework
  whose source is published at a pinned tag. That is the intended path for a built-in
  activation route and it needs nothing from StikDebug.
* **Or author DroidVM's own** from the documented protocol. The catalogue entry exists
  (`GuestAssetRole.debuggerScript`) with `requiredForBoot: false`, because an external
  debugger brings its own script and boot must not depend on ours.

`GuestAssetTests.testDebuggerScriptRecordsTheProvenanceFinding` asserts that this record
keeps naming the AGPL risk, so the finding cannot quietly disappear.

---

## Runtime engine

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| QEMU 10.0.12-utm | `utmapp/qemu` release `v10.0.12-utm` | GPL-2.0 | planned: modified (build integration) | `engine/vendor/qemu` (fetched, not committed) |
| `--enable-shared-lib` support in that fork | same tarball | GPL-2.0 | planned: as-is | build glue |
| UTM's QEMU patches (`qemu-10.0.12-utm.patch`, pixman, libslirp) | `utmapp/UTM` `patches/` | GPL-2.0 / MIT / BSD-3-Clause as per each patch's own project | planned: as-is | `engine/vendor/patches` |
| UTM's `build_dependencies.sh` toolchain setup | `utmapp/UTM` `scripts/` | ISC (Angelo Haller, 2014) | planned: modified | `scripts/` |
| **UTM's application code, CocoaSpice, its UI** | `utmapp/UTM` `Sources/` | **Apache-2.0** | **not reused** | — |
| AetherPS4-iOS / shadPS4 `ios_jit_allocator.cpp` | shadPS4 Emulator Project | GPL-2.0-or-later | planned: modified (exec-memory allocator) | `engine/jit/` |
| `BreakpointJIT.framework` | binary only, **no licence anywhere in its distribution** | **none** | **not reused** — see below | — |

### Why UTM's application code is not reused

Apache-2.0 is **not compatible with GPLv2**. QEMU as a whole is GPLv2, and DroidVM links
it, so the combined work is GPLv2 and Apache-2.0 application code cannot be taken into it.
(Apache-2.0 is GPLv3-compatible, which does not help: QEMU is GPLv2, not "v2 or later".)

The distinction is easy to get wrong, so:

* UTM's **QEMU fork** — GPL-2.0, because it *is* QEMU. Usable.
* UTM's **build script** — ISC, permissive. Usable.
* UTM's **app code** — Apache-2.0. Not usable. DroidVM must write its own.

### Why `BreakpointJIT` is not reused

It ships as a bare Mach-O with no licence file. An unlicensed binary is not something a
GPL project can take a dependency on. It turned out not to matter: the framework is three
instruction pairs (`mov x16, #1 ; brk #0xf00d`, the same with `#0`, and `brk #0x69`),
which are the *protocol* by which a debugger is asked for executable memory. DroidVM will
issue those traps in its own assembly (see `engine/jit/`), reproducing an interface rather
than anyone's expression. That is recorded here precisely because it is the kind of
judgement that should not be made silently.

## Cross-compiled dependencies of the engine

Versions and provenance verified against the reference project's dependency pins.

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| glib 2.83 | GNOME | LGPL-2.1-or-later | planned: as-is | engine sysroot |
| pixman 0.38.0 | cairographics | MIT | planned: as-is | engine sysroot |
| libffi 3.5.0 | libffi project | MIT | planned: as-is | engine sysroot |
| libiconv 1.16 | GNU | LGPL-2.1 (library) | planned: as-is | engine sysroot |
| gettext 0.22.5 | GNU | LGPL-2.1+ (libintl) | planned: as-is | engine sysroot |
| libucontext | `utmapp/libucontext` `9b1d8f0` | ISC | planned: as-is | engine sysroot |
| libslirp 4.9.1 | `utmapp/libslirp` release | BSD-3-Clause | planned: as-is | engine sysroot |

The LGPL components are linked into a GPL work, which LGPL permits; they are consumed as
libraries, unchanged, and their sources are published upstream.

## Graphics

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| ANGLE | Google / `google/angle` | BSD-3-Clause | planned: as-is, embedded | `DroidVM.app/Frameworks/libANGLE-shared.dylib` |
| MoltenVK | Khronos | Apache-2.0 | planned: as-is, embedded | `DroidVM.app/Frameworks/MoltenVK.framework` |
| virglrenderer | freedesktop | MIT | planned: as-is | engine sysroot |
| libepoxy | freedesktop | MIT | planned: as-is | engine sysroot |

ANGLE and MoltenVK are permissively licensed and are **embedded**, not linked. Both must
be present or the app aborts at launch with a dyld error; the packaging step checks for
both.

## Executable memory and debugging

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| StikJIT 1.9.0 XCFramework | `StikDebug/StikJIT` tag `1.9.0` | MPL-2.0 | planned: as-is, unmodified, embedded | `DroidVM.app/Frameworks/` + JIT helper extension |
| StikDebug | StikDebug project | **AGPL-3.0** | **not bundled** — separate app, attached as a debugger | none |
| idevice 0.1.68 | `jkcoxson/idevice` | MIT | planned: as-is, linked | JIT helper / pairing |
| idevice Rust dependency tree | pinned by `Cargo.lock` | MIT / Apache-2.0 / BSD-3-Clause / ISC | planned: as-is | statically linked |

### StikDebug is AGPL and that is fine

DroidVM does not link it. It is a **separate application** that attaches as a debugger over
a wire protocol. No linking, no shared address space, no derived work; the only thing
crossing the boundary is a protocol, which is not copyrightable subject matter. Users
install it themselves. DroidVM documents the dependency and links to it.

### StikJIT is MPL-2.0 and is bundled

MPL-2.0 is file-level copyleft and is compatible with the GPL (MPL-2.0 §3.3). The
framework is embedded unmodified, and its source is public at the tag above, which
satisfies the corresponding-source requirement for the binary. Its licence text ships
inside the app bundle.

## Guest operating system

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| LineageOS / AOSP userspace image | LineageOS builds of AOSP | Apache-2.0 | planned: redistributed as a runtime download | downloaded at first run, not committed |
| Linux kernel inside that image | upstream kernel + device patches | **GPL-2.0** | redistributed inside the guest image | see obligation below |
| EDK2 aarch64 firmware | TianoCore EDK2 | BSD-2-Clause-Patent | planned: redistributed | app bundle |
| F-Droid app index | F-Droid | — (data, not code) | planned: an app *source* option | runtime fetch |
| Google Play Services | — | — | **never bundled** | — |

**The kernel obligation.** Distributing a guest image distributes a GPLv2 kernel binary,
which obliges DroidVM to offer that kernel's corresponding source. The exact kernel tag
must be pinned, and the source offer published next to the image. This is unresolved and
tracked in `docs/roadmap.md`.

**Play Services is never bundled.** That is a licensing prohibition, not a complexity
argument.

## Licence texts

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| GPL-2.0 licence text | Free Software Foundation, via the reference repository's `LICENSE` | the text itself is distributed for verbatim copying | **copied** | `LICENSE` |

## Reference material

| Component | Source | License | Reuse | Destination |
|---|---|---|---|---|
| Husk source tree | `Leviidev/Husk` | GPL-2.0-or-later | **reference only in Phase 0** — no code copied | `docs/component-inventory.md` classifies every component A/B/C/D |

Husk is DroidVM's main reference. It is a GPL-2.0-or-later project, it links the same QEMU
fork, and it solved several problems DroidVM faces. It is recorded here because the
inventory in `docs/component-inventory.md` names its files and describes what each does, and
because any Phase 1 reuse will be listed in this table with the specific files taken.

Its product identity is not reused: not its name, bundle identifier, icons, UI, boot flow
or user-facing concepts. `scripts/check_repo.py` enforces that, allowing the name only in
this file, `docs/licensing.md`, `docs/component-inventory.md` and the identity whitelist.

## Distribution obligations

DroidVM is a combined GPLv2 work. Shipping an IPA therefore requires:

1. **Complete corresponding source**, public and buildable. This repository is it.
2. **Licence texts** for everything embedded, inside the bundle.
3. **A source offer for the guest kernel**, wherever a guest image is distributed.
4. **No App Store distribution.** GPLv2 conflicts with its terms, and the runtime requires
   `get-task-allow` with a debugger attaching, which App Review does not permit.
5. Sideloading via AltStore / SideStore / TrollStore, as unsigned IPAs that the installer
   re-signs.

## Adding a component

Every new reused component needs a row in the tables above, with its source, its licence,
whether it was copied, modified or reimplemented, and where it landed. If the licence is
unknown, the answer is no.
