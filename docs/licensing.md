# Licensing

**DroidVM is GPL-2.0-or-later.** The source is public, distribution is a sideloaded IPA
with the full corresponding source, and it cannot go on the App Store.

This document explains why, and what may and may not be taken into the tree. Every claim
was checked against a licence file in an actual source tree rather than recalled.

## Why GPL-2.0, and why there was never a choice

QEMU's own `LICENSE`, verbatim:

> 1) The QEMU emulator as a whole is released under the GNU General Public License,
>    version 2.

DroidVM's engine is that QEMU, built as `libqemu-aarch64-softmmu.dylib` and shipped inside
the IPA. That is distribution of a combined work, so the combined work is GPLv2.

`GPL-2.0-or-later` for DroidVM's own files is the right shade: compatible with QEMU's
GPLv2 (the combination is GPLv2 in practice) while leaving the door open to GPLv3 for
anything that later needs it.

A second, independent reason: the executable-memory allocator is derived from
AetherPS4-iOS's `ios_jit_allocator.cpp`, whose header reads
`SPDX-License-Identifier: GPL-2.0-or-later`. That file was going to be GPL-2.0-or-later
regardless of QEMU.

## The trap worth naming: UTM's application code is Apache-2.0

**Apache-2.0 is not compatible with GPLv2.** It is compatible with GPLv3, which does not
help, because QEMU as a whole is GPLv2 and not "v2 or later".

| Thing | Licence | Usable in DroidVM? |
|---|---|---|
| `utmapp/qemu` fork (the tarball) | GPL-2.0 — it *is* QEMU | **Yes** |
| UTM's `scripts/build_dependencies.sh` | ISC (Angelo Haller, 2014) | **Yes** — permissive |
| UTM's Swift/ObjC application code, CocoaSpice, their UI | Apache-2.0 | **No — do not copy** |

So DroidVM may take the QEMU tarball and *ideas* from the build script. It must write its
own application code. When the display bridge is adapted, it is adapted from a GPLv2
source, never from CocoaSpice.

## StikDebug is AGPL-3.0, and that is fine

AGPL-3.0 would be a serious problem if DroidVM linked it. DroidVM does not. StikDebug is a
**separate application** that attaches as a debugger over the gdb-remote protocol. No
linking, no shared address space, no derived work; the only thing crossing the boundary is
a wire protocol, which is not copyrightable subject matter.

Users install it themselves from its own distribution. DroidVM documents the dependency and
links to it — it never bundles it.

## Bundled JIT components

| Thing | Licence | Where |
|---|---|---|
| StikJIT XCFramework, unmodified | MPL-2.0 | embedded, used by the JIT helper extension |
| `idevice` | MIT | linked |
| `idevice`'s Rust dependency tree | MIT, Apache-2.0, BSD-3-Clause, ISC | statically linked |
| DroidVM's pairing wrapper | GPL-2.0-or-later | static in the app |

MPL-2.0 is file-level copyleft and is compatible with the GPL (MPL-2.0 §3.3). The framework
is embedded unmodified and its source is public at a pinned tag, which is the corresponding
source for the binary. Its licence texts ship inside the app bundle.

## The `brk` instruction pairs

`BreakpointJIT.framework` ships as a bare Mach-O with **no licence file anywhere in its
distribution**, so it cannot be taken as a dependency. It turns out not to matter: the
framework is a small set of instruction pairs, reproduced here because they are the protocol by
which a debugger is asked for executable memory:

```
_BreakGetJITMapping:  mov x16, #0x1 ; brk #0xf00d ; ret
_BreakJITDetach:      mov x16, #0x0 ; brk #0xf00d ; ret
_BreakMarkJITMapping: brk #0x69     ; ret
```

**DroidVM implements two universal-protocol wrappers: prepare and detach.** The prepare form uses
`x16 = 1`, with the region address or NULL in `x0` and the length in `x1`; the detach form uses
`x16 = 0`.

This record states DroidVM's own implementation and **deliberately makes no claim about how many
commands or forms the external protocol defines in total.** That is an external contract, this
project has not verified it, and an earlier revision of this file asserted a total that was wrong.

`brk #0x69` is not used by DroidVM's current universal path. **No behaviour is attributed to it**:
it has not been independently verified here, and this record will not repeat another project's
description of it as though it were established. If a later revision needs it, that verification is
where the work starts.

What is being reproduced is an *interface* — the trap immediates and the register command
numbers, all documented in StikDebug's own published JavaScript — not anyone's creative
expression. Instruction pairs dictated by an external protocol are not a meaningful authorship
contribution. DroidVM writes them in its own assembly.

This is also better engineering: no `dlopen` indirection, and no embedded framework
carrying entitlements, which AMFI rejects on sideloaded builds at launch.

## Guest images

| Part | Licence | Obligation |
|---|---|---|
| AOSP / LineageOS userspace | Apache-2.0 | notices |
| Linux kernel in the image | **GPL-2.0** | **offer the corresponding source** |
| EDK2 aarch64 firmware | BSD-2-Clause-Patent | notices |
| Google Play Services | — | **never bundled** |

Shipping a kernel binary obliges DroidVM to offer that kernel's source. Pin the exact
kernel tag and publish the offer beside the image. This is unresolved and tracked in
`docs/roadmap.md`.

Play Services must not be bundled. That is a licensing prohibition, not a complexity
argument.

## Dependencies of the engine

The cross-compiled set, with licences. All are consumed as unmodified libraries.

| Component | Licence |
|---|---|
| glib | LGPL-2.1-or-later |
| pixman | MIT |
| libffi | MIT |
| libiconv | LGPL-2.1 |
| gettext (libintl) | LGPL-2.1-or-later |
| libucontext | ISC |
| libslirp | BSD-3-Clause |
| ANGLE | BSD-3-Clause |
| MoltenVK | Apache-2.0 |
| virglrenderer | MIT |
| libepoxy | MIT |

The LGPL components are linked into a GPL work, which LGPL permits; they are used
unchanged as libraries, and their sources are published upstream. The Apache-2.0
components (MoltenVK, and ANGLE's own dependencies) are compatible because the combined
work is GPLv2-only in effect and Apache-2.0 code is taken as an unmodified separate
library — the same position the reference implementation relies on, and one worth
re-checking if any of them is ever *modified*.

## Reference material

The main reference is a GPL-2.0-or-later project that links the same QEMU fork. Because it
is GPL and so is DroidVM, code *may* be taken from it — with its provenance recorded in
[THIRD_PARTY.md](../THIRD_PARTY.md) and its files classified in
[component-inventory.md](component-inventory.md). What is not taken is its product identity: not its
name, bundle identifier, icons, UI, boot flow or user-facing concepts.

That is enforced mechanically, not by good intentions. `scripts/check_repo.py` fails the
build if the reference project's name appears anywhere outside the four files whose job is
to record provenance.

## Distribution

* **Public source repository**, complete and buildable. This satisfies GPLv2 §3 when an IPA
  is handed to someone.
* **Unsigned IPA releases**, sideloaded via SideStore / AltStore / TrollStore.
* **Not the App Store.** Two independent blockers, either sufficient: GPLv2's terms
  conflict with the App Store's distribution restrictions, and DroidVM requires
  `get-task-allow` with an external debugger attaching at runtime, which App Review does
  not permit.
