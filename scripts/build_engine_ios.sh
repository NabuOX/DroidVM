#!/bin/bash
# DroidVM gate 3: build the engine for iOS.  **macOS + Xcode only.**
#
#   ./scripts/build_engine_ios.sh
#
# STATUS: PREPARED, NEVER RUN. This is the Level C stage. It has not been executed because
# DroidVM has no GitHub remote yet, so there is no macOS runner to execute it on, and it has
# never been executed locally because there is no local Mac. Treat every line as unverified.
#
# WHAT LEVEL C REQUIRES
#
# DroidVM links QEMU as a shared library rather than spawning it, because an iOS app cannot
# create processes. That means:
#
#   1. cross-compile the dependency set for arm64-apple-ios
#   2. cross-compile QEMU itself with --enable-shared-lib, producing
#      libqemu-aarch64-softmmu.dylib
#   3. give QEMU the display listener and the executable-memory allocator, and make sure the
#      entry points DroidVM calls are EXPORTED
#   4. embed the dylib in the app bundle
#
# Step 3 is where Level C usually fails, and it fails in a way that looks like something else.
# QEMU's shared-library build exports only the symbols named in `system/qemu.symbols`. A symbol
# missing from that list links perfectly and fails at `dlopen`, or later at first use inside a
# vCPU thread. The export list is therefore maintained explicitly below.
#
# DEPENDENCY PINS
#
# The versions are recorded in THIRD_PARTY.md with their licences. They match the versions the
# reference implementation used, because those exact versions are known to cross-compile for
# arm64-apple-ios -- which is a real constraint, not a preference.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VENDOR="$ROOT/engine/vendor"
BUILD="$ROOT/build/ios-arm64"
STAGE="$ROOT/build/ios-arm64/lib"
mkdir -p "$VENDOR" "$BUILD" "$STAGE"

# ------------------------------------------------------------------ pins
# Kept in step with THIRD_PARTY.md. Changing one here without changing it there is a
# provenance bug.
QEMU_TARBALL="qemu-10.0.12-utm.tar.xz"
QEMU_URL="https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/$QEMU_TARBALL"
FFI_VERSION="3.5.0"
GLIB_VERSION="2.83.0"
PIXMAN_VERSION="0.38.0"
LIBICONV_VERSION="1.16"
GETTEXT_VERSION="0.22.5"
LIBUCONTEXT_COMMIT="9b1d8f01a6e99166f9808c79966abe10786de8b6"
LIBSLIRP_VERSION="4.9.1"

echo "================================================================"
echo " DroidVM engine build for iOS (PREPARED, UNVERIFIED)"
echo "   qemu     : $QEMU_TARBALL"
echo "   deps     : glib $GLIB_VERSION, pixman $PIXMAN_VERSION, libffi $FFI_VERSION"
echo "================================================================"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: this stage needs macOS with Xcode." >&2
    exit 2
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios16.4"
echo "  sdk    : $SDK"
echo "  target : $TARGET"
echo

# ------------------------------------------------------------------ fetch

if [ ! -d "$VENDOR/qemu" ]; then
    echo "==> fetching QEMU"
    curl -fL --retry 3 -o "$VENDOR/$QEMU_TARBALL" "$QEMU_URL"
    # Verified against the recorded digest; an unverified tarball that builds is worse than a
    # failed fetch, because the result is trusted.
    if [ -n "${QEMU_SHA256:-}" ]; then
        echo "$QEMU_SHA256  $VENDOR/$QEMU_TARBALL" | shasum -a 256 -c -
    else
        echo "  WARNING: QEMU_SHA256 is not set, so the tarball was NOT verified" >&2
    fi
    mkdir -p "$VENDOR/qemu"
    tar -xf "$VENDOR/$QEMU_TARBALL" -C "$VENDOR/qemu" --strip-components=1
else
    echo "==> QEMU already fetched"
fi

# ------------------------------------------------------------------ deps
#
# glib and pixman are the two QEMU will not build without. Both are cross-compiled with a
# meson cross-file; the shape of that file is the fiddly part, which is why it is written out
# rather than assembled inline.
echo
echo "==> meson cross-file"
CROSS="$VENDOR/ios-arm64.cross"
cat > "$CROSS" <<CROSSEOF
[binaries]
c = '$(xcrun --sdk iphoneos --find clang)'
cpp = '$(xcrun --sdk iphoneos --find clang++)'
ar = '$(xcrun --sdk iphoneos --find ar)'
strip = '$(xcrun --sdk iphoneos --find strip)'
pkgconfig = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
c_args = ['-target', '$TARGET', '-isysroot', '$SDK', '-fPIC']
c_link_args = ['-target', '$TARGET', '-isysroot', '$SDK']
CROSSEOF
echo "  wrote $CROSS"

echo
echo "==> dependencies"
echo "  glib $GLIB_VERSION, pixman $PIXMAN_VERSION, libffi $FFI_VERSION,"
echo "  libiconv $LIBICONV_VERSION, gettext $GETTEXT_VERSION,"
echo "  libucontext $LIBUCONTEXT_COMMIT, libslirp $LIBSLIRP_VERSION"
echo "  (fetched and cross-compiled into $BUILD; see THIRD_PARTY.md for licences)"
#
# The per-dependency build steps are deliberately NOT written out here. Each needs its own
# configure/meson invocation whose flags are discovered by running it, and a script written
# without ever being run would be a plausible-looking fiction. The reference implementation's
# working sequence is in its scripts/build_ios.sh, which is recorded in THIRD_PARTY.md as
# reference material; that is what this stage should be derived from, run, and corrected.

# --------------------------------------------------------- integrate engine
#
# Copy DroidVM's engine sources into QEMU's tree, wire the meson targets, and maintain the
# export list. Adapted from the reference implementation's integration script, whose export-list
# maintenance is the part that matters (see the header comment).
echo
echo "==> integrating the engine into QEMU's tree"
if [ -x "$ROOT/scripts/integrate_engine.sh" ]; then
    "$ROOT/scripts/integrate_engine.sh" "$VENDOR/qemu"
else
    echo "  ERROR: scripts/integrate_engine.sh is missing; the engine cannot be wired in" >&2
    exit 1
fi

# ------------------------------------------------------------------ build

echo
echo "==> configuring and building QEMU (this takes hours on a cold cache)"
echo "  --enable-shared-lib  : required; an iOS app cannot spawn a process"
echo "  --target-list=aarch64-softmmu --disable-* (no spice, gstreamer, usb, tpm)"
echo
echo "  NOT IMPLEMENTED: see the note above. Expected output:"
echo "    $STAGE/libqemu-aarch64-softmmu.dylib"

if [ ! -f "$STAGE/libqemu-aarch64-softmmu.dylib" ]; then
    echo
    echo "================================================================"
    echo " ENGINE LINK: NOT REACHED"
    echo "   libqemu-aarch64-softmmu.dylib was not produced."
    echo "   This stage is prepared but has never been run. See the report."
    echo "================================================================"
    exit 1
fi

echo
echo "==> verifying the exported symbols DroidVM calls"
SYMBOLS="$(xcrun nm -gU "$STAGE/libqemu-aarch64-softmmu.dylib" 2>/dev/null || true)"
missing=0
for symbol in _qemu_init _qemu_main_loop _qemu_cleanup \
              _droidvm_jit_probe _droidvm_jit_capture _droidvm_jit_release \
              _droidvm_display_register _droidvm_display_read \
              _droidvm_display_counters_sizeof; do
    if echo "$SYMBOLS" | grep -q " $symbol$"; then
        printf '  ok       %s\n' "$symbol"
    else
        printf '  MISSING  %s   <-- links fine, fails at dlopen\n' "$symbol" >&2
        missing=1
    fi
done
[ $missing -eq 0 ] || { echo "==> export list is incomplete" >&2; exit 1; }

echo
echo "================================================================"
echo " ENGINE LINK: PASS"
echo "   $STAGE/libqemu-aarch64-softmmu.dylib"
echo "   every symbol DroidVM calls is exported"
echo "================================================================"
