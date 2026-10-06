# Guest image distribution: recommendation

Phase 1.1 asked for a concrete recommendation, comparing three options. This is it.

**Recommendation: build the image in DroidVM's own CI (option A), distribute it as a first-run
download from DroidVM-controlled release assets (option C), and reject externally hosted
prebuilt images (option B). Defer the pre-booted snapshot.** A and C are not alternatives — one
produces the artefact, the other delivers it. The real decision is whether DroidVM builds the
image itself, and the answer is yes.

---

## The options

**A. A reproducible Android image built by DroidVM's own CI.**
DroidVM pins an AOSP-derived source tree and a kernel tag, builds the guest in Actions, and
publishes the result with the source it came from.

**B. An externally hosted prebuilt image, with a source offer.**
DroidVM points at somebody else's build and republishes or links its source.

**C. A first-run download from DroidVM-controlled release assets.**
The delivery mechanism: the app fetches the image and a manifest on first launch, verifies
digests, and installs it. Nothing is committed and nothing ships inside the IPA.

## Comparison

| Criterion | A — CI-built | B — external prebuilt | C — own release feed |
|---|---|---|---|
| Kernel source obligation | **Satisfiable**: DroidVM has the exact tree it built from | **Fragile**: DroidVM must archive a tree it did not build, and the upstream can vanish | n/a (delivery only) |
| Reproducibility | **High**: pinned tags, scripted build, digest published | **None**: a binary with no build DroidVM can repeat | n/a |
| Snapshot compatibility | **Guaranteed**: the machine shape is an output of the build | **Unknown**: shape comes from whoever built it | n/a |
| Update strategy | Scripted: rebuild, bump `generation`, everyone re-downloads on digest mismatch | Wait for the upstream | **Good**: manifest `generation` + digest verification already implemented |
| ~GB size | ~1.2 GiB image | same | same — delivered, not committed |
| Bandwidth cost | Build-time egress only | none | **the real cost**: ~1.2 GiB per new install, on GitHub Releases |
| Effort | **High** — this is the expensive option | Low | Low |

## Why B is rejected

Not because of effort — because of the licence. DroidVM is a GPLv2 combined work and
distributes a kernel binary inside the image. GPLv2 obliges DroidVM to offer *that binary's*
corresponding source. With an externally built image, DroidVM is offering source for something
it cannot prove it built, from a tree it does not control. That is the obligation's letter
without its substance, and it breaks the moment the upstream rebases.

There is a second, independent reason: snapshot compatibility. A restored machine must match
the shape it was saved with, and `QEMUMachineShape.stamp` records that shape. If DroidVM does
not build the image, it cannot guarantee the shape, and the compatibility check has nothing
authoritative to compare against.

## Why A + C together

A gives DroidVM the artefact *and* the corresponding source as one output of one pipeline. C
is how it reaches a user without putting gigabytes in the repository or the IPA.

Practical shape:

1. **A separate images repository** (`NabuOX/DroidVM-images`) holds the build workflow and
   publishes releases. Keeping it out of the main repository keeps a ~1.2 GiB release feed away
   from the source release feed, which matters the first time someone tries to clone.
2. **Pinned inputs:** the Android source tag, the kernel tag, the build tools, and the machine
   shape (`cpu`, `smp`, `guestMiB`, `xres`, `yres`). All of these end up in the manifest.
3. **Published per release:** the image, `manifest.json` (SHA-256 + size per file, plus the
   machine shape), and a **kernel source offer** — either the source tarball as a release asset
   or a `KERNEL-SOURCE.md` naming the exact tag and commit with a durable mirror. The offer must
   survive the upstream disappearing, so a copy under DroidVM's control is the safe form.
4. **Verification is already built.** `GuestAssetValidator` checks size then digest, streamed, so
   a 1.2 GiB image is never resident. `GuestManifest.isCompatible(with:)` refuses a snapshot of
   the wrong shape *before* anything is downloaded.

## Why the pre-booted snapshot is deferred

The reference implementation also distributes a pre-booted snapshot, roughly 1.8 GiB, so a
first launch can resume rather than boot cold. DroidVM should not, yet:

* It **doubles** what a new user downloads, for a one-off saving.
* It **embeds guest RAM**, so it carries the same kernel source obligation in a second,
  less inspectable form.
* It is **shape-locked**, so every change to the machine definition invalidates every published
  snapshot. During bring-up the machine definition changes constantly.
* `docs/roadmap.md` places snapshots in Phase 4 anyway, behind a health gate that does not exist
  yet. Publishing pre-made snapshots before DroidVM can take a *healthy* one itself would be
  shipping the thing the snapshot gate exists to prevent.

Until then the userdata seed (Phase 1's `vdb-seed.qcow2`) is enough: a first boot that starts
from a consistent `/data` rather than a factory reset.

## What this costs

| Item | Estimate |
|---|---|
| Image download per new install | ~1.2 GiB |
| Snapshot download, if ever added | +~1.8 GiB |
| GitHub Releases storage | trivial; bandwidth is the cost, not storage |
| CI time for a guest build | hours, and it needs a build host with enough disk |

Bandwidth is the only figure that grows with users. For a sideloaded app that is acceptable on
GitHub Releases, and it is the reason not to add the snapshot until it earns its 1.8 GiB.

## Not doing yet

Per the Phase 1.1 brief: **no asset is uploaded or mirrored**. This document is a decision, and
the machinery to act on it — a guest-build workflow and DroidVM's own release feed — is Phase 2
work. `GuestAssetCatalog` already marks the guest disks `droidvmMayRedistribute: false`, and
`GuestAssetValidator.checkRedistribution` refuses a build that would hand them out, so the
decision cannot be violated by accident in the meantime.
