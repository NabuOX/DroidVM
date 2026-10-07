# Patches

Every patch in this directory is applied by `scripts/build_engine_ios.sh`. Each one records
what it changes, which upstream file it touches, and why DroidVM cannot build iOS without it.

**Reuse decision: C — direct reuse.** A patch is a diff against somebody else's released
source. Rewriting one would mean re-deriving the same fix against the same upstream file, with
no architectural benefit and a real risk of getting it subtly wrong. They are vendored
verbatim, byte-for-byte, so the build is reproducible without cloning another project.

---

## `pixman-0.38.0.patch`

* **Purpose:** makes pixman's autotools build cross-compile for iOS.
* **Upstream file:** `Makefile.am`, `Makefile.in` at the top of the pixman source tree.
* **What it does:** trims `SUBDIRS` to `pixman` alone — dropping `demos` and `test`, which are
  host tools that cannot be built for iOS and are not needed to link — and repairs the
  automake `runstatedir`/`depcomp` mismatch that a newer `automake` on the build host produces
  against this older release.
* **Why DroidVM needs it:** without it pixman's `configure`/`make` tries to build the demo and
  test programs for iOS and fails before producing `libpixman-1.a`. Pixman is a hard
  requirement of QEMU's display code; there is no substitute.
* **Licence:** pixman is MIT. A patch against MIT source carries MIT.
* **Derived from:** UTM's `patches/pixman-0.38.0.patch`, vendored verbatim.
  SHA-256 `3737a80522b9e9cb…`

## `libslirp-v4.9.1.patch`

* **Purpose:** teaches libslirp's meson build that `ios` behaves like `darwin`.
* **Upstream file:** `meson.build`, one conditional.
* **What it does:** changes `elif host_system == 'darwin'` to also accept `host_system == 'ios'`,
  so the `resolv` library is linked as it is on macOS.
* **Why DroidVM needs it:** the meson cross-file reports `system = 'ios'`, which the released
  `meson.build` does not know about, so the `resolv` dependency is silently skipped and the
  link fails later with undefined resolver symbols. Without this one line there is no
  `libslirp.a`.
* **Why DroidVM needs libslirp at all:** the launch plan always configures
  `-netdev user,...` when networking is enabled, and QEMU's user-mode networking *is* libslirp.
  Building QEMU with `--enable-slirp` and then failing to provide it is not an option.
* **Licence:** libslirp is BSD-3-Clause. A patch against BSD-3-Clause source carries
  BSD-3-Clause.
* **Derived from:** UTM's `patches/libslirp-v4.9.1.patch`, vendored verbatim.
  SHA-256 `f170e9505990a3c5…`

---

## Deliberately NOT vendored

| Patch | Why not |
|---|---|
| `qemu-10.0.12-utm.patch` (110 KB) | It is a patch **against** QEMU, and the tarball DroidVM fetches **is** UTM's already-patched QEMU fork (`v10.0.12-utm`). Applying it to its own output is a no-op at best and a half-applied tree at worst. Fetching the fork is the deterministic way to get those changes. |
| `husk-qemu-ios-jit.patch` | It diverts `tcg/region.c`'s split-W^X allocator to a function that sources executable memory from a debugger. That is a **runtime** integration between QEMU and the JIT bridge, and Level C is a build-and-link gate. It also calls a symbol named for another project, so adopting it means adapting it, not copying it. Deferred to the phase that makes the machine actually run. |
| `husk-epoxy-ios-egl-path.patch` | Applies to libepoxy, which is only reachable through QEMU's GL path. Level C builds the **software** display (`virtio-gpu-pci`, DroidVM's default), so libepoxy, virglrenderer and MoltenVK are not in the dependency set at all. Enabling the GPU path later brings them back, and this patch with them. |

## Adding a patch

A new patch needs a section here, with its purpose, the upstream file it touches, and why
DroidVM cannot build without it. A patch with no stated reason is a patch nobody can remove.
