# Building and the four gates

DroidVM is developed on **Windows**, with **no local Mac**. That is a design constraint,
not a temporary inconvenience: everything that can be checked without Xcode must be, on the
development machine, in seconds, before anything reaches a macOS runner.

## The gates

| Gate | Where it runs | What it proves | Command |
|---|---|---|---|
| **1** host | Windows, Linux, macOS | core tests, repository guards, engine **syntax** | `./scripts/check_host.sh` |
| **2** compile | macOS runner | the app target type-checks against the iOS SDK | `./scripts/typecheck_ios.sh` |
| **3** link | macOS runner | compiles, bridges, links, embeds the engine | `./scripts/build_ipa.sh` |
| **4** package | macOS runner | an IPA exists and its bundle is installable | same |

These are reported **separately and never inferred from one another**:

```
COMPILE       PASS / FAIL
LINK          PASS / FAIL / NOT REACHED
SIGNING       PASS / BLOCKED / NOT REQUIRED   (unsigned IPAs are the target)
DEVICE TEST   PASS / FAIL / NOT RUN
```

A green compile gate is not a link. A link is not a signature. None of them is a device
test. Saying otherwise is how a project ends up believing something works.

## Gate 1 — the host check

```bash
./scripts/check_host.sh
```

Three stages:

1. **`core/` builds and its tests pass.** A real Swift package containing the lifecycle state
   machine, the frame accounting and stall classifier, runtime preparation, the VM engine
   adapter, the machine definition, diagnostics and the asset inventory. It imports nothing
   from SwiftUI, UIKit, Combine or Metal, so it builds on Linux and Windows too.
2. **Repository guards** (`scripts/check_repo.py`): required documents exist and are
   non-empty; no foreign branding outside the provenance files; no guest images, APKs or
   large binaries committed; the third-party record keeps its columns and its required
   entries; the bundle identifier is in DroidVM's namespace.
3. **Engine syntax** (`scripts/check_engine.sh`): the Apple-only adapters under `engine/`
   *parse*, the C bridge header genuinely compiles under `-Wall -Wextra -Werror`, and the
   trap protocol is intact. This check is self-tested — it verifies that it does reject
   broken input — and it reports `PARSE PASS`, never `COMPILE PASS`, because it cannot
   resolve types, symbols or imports.

Exit codes: `0` pass, `1` failure, `2` no toolchain (a skip, not a pass).

## Obtaining a Swift toolchain without administrator rights

On a machine where `sudo` needs a password, the Ubuntu packages can be downloaded and
unpacked into a user directory. This is how the Windows development machine is set up
(via WSL) and it is why gate 1 needs no Mac.

```bash
mkdir -p ~/swiftroot
apt-get download swiftlang libswiftlang   # both: swiftlang alone has no libswiftCore.so
dpkg-deb -x swiftlang_*.deb   ~/swiftroot
dpkg-deb -x libswiftlang_*.deb ~/swiftroot
```

Two details that cost time to discover:

* `swiftlang` on its own has **no runtime libraries**; `libswiftlang` is a separate
  package.
* The `.deb` layout puts the runtime under `libexec/swift/lib/swift/linux`, and the real
  `swift` driver under `libexec/swift/bin` — `usr/bin` holds only `swiftc`, `swift-build`,
  `swift-run`, `swift-lldb` and `sourcekit-lsp`, and **no `swift` at all**.

`scripts/check_host.sh` finds a toolchain from `DROIDVM_SWIFT`, then `swift` on `PATH`,
then `~/swiftroot`. It sets the library path for that layout itself and exits `2` with a
`SKIP` message when nothing is found, so it is safe to call unconditionally in CI.

## Gate 2 — the iOS compile gate

```bash
./scripts/typecheck_ios.sh      # macOS only
```

Type-checks the app target's Swift against the iOS SDK with the real bridging header. It
needs no QEMU, no ANGLE, no guest image and no signing, and it runs in about a minute.

What it catches that nothing else does: actor isolation, C enum and integer bridging,
`inout` arguments passed to C, undeclared bridging symbols, and Swift's complete absence of
implicit numeric conversion. That last one is not hypothetical — it is the error class that
made a whole batch of code in the reference implementation uncompilable while reading
perfectly plausibly.

It prints its toolchain unconditionally, so a passing run still records which Xcode produced
it. An SDK below the deployment target is reported as an **environment limitation** and the
script exits `3`; it is never a reason to edit the app to fit an older SDK.

## Gates 3 and 4 — the real build

```bash
./scripts/build_ipa.sh          # macOS only; long
```

Fetch and cross-compile QEMU, ANGLE, virglrenderer and the rest; integrate the engine into
QEMU's tree; generate the Xcode project; build; validate the bundle; zip an unsigned IPA.

The first run takes hours because the dependency set is built from source. Subsequent runs
are incremental.

The bundle validation is not optional ceremony: a bundle missing `CFBundleIdentifier` or an
embedded dylib builds and zips perfectly happily and then fails to install with no useful
message. The check exists because that happened.

## CI

`.github/workflows/ci.yml`:

* `host` — gate 1 on Ubuntu, on every push and pull request.
* `ios-typecheck` — gate 2 on a macOS runner.
* `ipa` — gates 3 and 4, manual (`workflow_dispatch`), because it needs hours and the right
  Xcode.

The `ipa` job checks the runner's iOS SDK against the floor the engine requires and stops
with a clear `::error` if it is too old, rather than producing a build that would fail on
the device for reasons nothing in the log would explain.

## Windows notes

* Use WSL for gate 1. Git's `core.autocrlf=true` is commonly set system-wide on Windows,
  so the working tree is CRLF while the repository stores LF. A shell script with CRLF
  endings fails to parse on Linux and macOS — with a confusing error about a stray token on
  the line after a backslash continuation — so **never validate a shell script by running
  the working-tree copy**; validate the normalised form:

  ```bash
  git show HEAD:scripts/check_host.sh | bash -n
  ```

* `.gitignore` excludes `swiftroot/`, `build/`, `.build/`, Xcode derived data, and every
  guest-image and APK extension. Guest images are downloaded at runtime and never
  committed.
