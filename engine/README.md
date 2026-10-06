# `engine/` — the virtual machine, behind DroidVM's interfaces

Phase 1 populates this directory. Nothing is implemented yet.

## Shape

```
engine/
├── jit/           executable memory: the trap protocol, the RW alias, TCG diversion
├── display/       the display backend: software and GPU paths, frame counters
├── snapshot/      save and load, behind the health gate
├── memory/        balloon control; measurement lives above this
├── audio/         audio backend                                       (Phase 2)
├── lifecycle/     the lifecycle rules as C, mirrored by core/          (class A)
├── diagnostics/   the boot classifier as C                             (class A)
├── compat/        platform shims the SDK withholds
├── pairing/       on-device pairing transport
└── vendor/        fetched, never committed: QEMU, patches, sysroot
```

## Rules

1. **These are the only files allowed to know about QEMU, EGL, Metal or virtio.** Everything
   above them talks to the protocols in `DroidVMCore`.
2. **Nothing here decides product behaviour.** A backend reports what happened; a
   coordinator decides what it means. The reference implementation's display code, its
   runner and its UI each held a piece of boot truth, which is why no single place could
   answer "is Android booted but not drawing".
3. **Every failure is counted or reported, never dropped silently.** The specific silent
   paths to avoid are known and named in [`../docs/component-inventory.md`](../docs/component-inventory.md):
   a display update that returns before incrementing anything, a presenter that discards a
   frame with no log, and an availability flag that can read true for a region that was
   just released.
4. **Reused code keeps its provenance.** Every file taken or adapted from elsewhere carries
   its original SPDX header and has a row in [`../THIRD_PARTY.md`](../THIRD_PARTY.md).

## Build integration

QEMU cannot be vendored into the repository: it is fetched, patched and cross-compiled, and
the resulting archive is linked into the app. Two consequences worth knowing before touching
the build:

* The engine's C files are copied into QEMU's own source tree and wired into its
  `meson.build` files, so anything added to `engine/` must also be added to the integration
  script.
* QEMU's shared-library build exports only the symbols named in `system/qemu.symbols`. A
  symbol missing from that list **links successfully and fails at `dlopen`**, which is a
  confusing way to lose an afternoon. The integration script maintains that list, pruning
  names that no longer exist and adding new ones.

`engine/vendor/` is gitignored. `docs/build.md` covers obtaining and building the
dependencies.
