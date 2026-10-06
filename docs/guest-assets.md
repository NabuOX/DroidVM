# Guest assets: what Android needs on disk

This is the human-readable form of `GuestAssetCatalog` in
`core/Sources/DroidVMCore/Assets/GuestAssets.swift`. The catalogue is the authority —
`DocumentationTests` asserts that every filename below appears in it and vice versa — because
a table in a document goes stale silently while a tested type does not.

**Phase 1 hosts nothing.** No asset is mirrored, uploaded, committed or fetched from another
project's release URLs. The only provider implemented is a local directory a developer
populates by hand, and it reports itself as non-production.

## Required for a cold boot attempt

| File | Size (approx) | Purpose | Origin | Licence | May DroidVM redistribute? |
|---|---|---|---|---|---|
| `edk2-aarch64-code.fd` | 64 MiB | UEFI firmware code volume the guest boots through | TianoCore EDK2, packaged for arm64 virt | BSD-2-Clause-Patent | **yes** |
| `efi-vars-seed.fd` | 64 MiB | UEFI variable store, seeded so the firmware has a writable environment on first boot | Generated from EDK2 defaults | BSD-2-Clause-Patent | **yes** |
| `vda.qcow2` | ~1.2 GiB | The Android system disk: kernel, system and vendor partitions | An AOSP-derived Android build for arm64 virt | userspace Apache-2.0; **kernel GPL-2.0** | **no** |
| `vdb-seed.qcow2` | ~600 MiB | Initial `/data`, so a boot starts from a consistent state | Same build as the system disk | userspace Apache-2.0; **kernel GPL-2.0** | **no** |
| `manifest.json` | 4 KiB | Names the image and snapshot files with SHA-256 and size, and records the machine shape | DroidVM-authored | GPL-2.0-or-later | **yes** |
| `pc-bios/` | 4 MiB | QEMU's own firmware data directory, passed as `-L` | Produced by the engine build | GPL-2.0 (QEMU) | **yes** |

## Not required for a cold boot

| File | Size (approx) | Purpose | Origin | Licence | May DroidVM redistribute? |
|---|---|---|---|---|---|
| `vdb-snapshot.qcow2.gz` | ~1.8 GiB | A pre-booted machine state, in numbered parts, so a launch can resume instead of booting cold | Produced by a save path; restorable only into a machine of the same shape | As the guest disks; it embeds guest RAM | **no** |
| `droidvm-jit.js` | 7 KiB | The script a debugger executes to service DroidVM's executable-memory traps | **To be authored by DroidVM**, or taken from StikJIT's own MPL-2.0 bundle | GPL-2.0-or-later, or MPL-2.0 | **yes** |

### The kernel obligation

Shipping `vda.qcow2` or `vdb-seed.qcow2` distributes a **GPLv2 Linux kernel binary**, which
obliges DroidVM to offer that kernel's corresponding source. Until that offer exists and the
kernel tag is pinned, DroidVM must not be the party handing out the guest disks — hence
`droidvmMayRedistribute: false` for both, and `GuestAssetValidator.checkRedistribution`
failing a build that would do so.

This is unresolved and tracked in [roadmap.md](roadmap.md).

### Why `droidvm-jit.js` is delicate

The reference implementation bundles a file called `husk-jit.js` that is **byte-identical** to
a script derived from StikDebug — which is **AGPL-3.0** — with no licence header and no
attribution. DroidVM does not copy it. The full reasoning, and the two clean routes, are in
[THIRD_PARTY.md](../THIRD_PARTY.md).

## Where files come from

`GuestAssetProvider` abstracts this. Phase 1 has exactly one implementation:

```swift
LocalDirectoryAssetProvider(directory: someURL)   // isProductionSource == false
```

A production provider — fetching from DroidVM's own hosting, verifying digests, resuming
multi-part downloads — is Phase 2 work and is **blocked** on the hosting and kernel-source
question below.

## Why verification is by digest

The manifest carries a SHA-256 and an exact size per file, not just a version string. A stamp
saying "v12" only records what the file claims to be; a truncated download and a swapped file
both look identical from the app's side, and both fail later, elsewhere, in a way that looks
like something else. `GuestAssetValidator` checks size first (cheap) and then digest (streamed,
so a 2 GiB image is never resident).

## Open questions

1. **Hosting.** DroidVM must publish its own image and manifest. The assets are roughly a
   gigabyte and two gigabytes, so this is a real cost and a bandwidth question.
2. **The kernel source offer**, as above.
3. **Snapshot compatibility.** A snapshot is only restorable into a machine of the same shape;
   `GuestManifest.isCompatible(with:)` decides that before anything is downloaded, using the
   same `QEMUMachineShape.stamp` the engine records.
4. **Audio.** The plan can enable or disable `virtio-sound-pci`, and doing so changes the
   machine definition. It is part of the stamp for that reason, and the published manifest
   does not yet express it.
