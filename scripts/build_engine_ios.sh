#!/bin/bash
# DroidVM gate 3: build the engine for iOS, and link the app against it.  **macOS only.**
#
#   ./scripts/build_engine_ios.sh            build everything
#   ./scripts/build_engine_ios.sh deps       dependencies only
#   ./scripts/build_engine_ios.sh qemu       QEMU only
#
# SIX LAYERS, REPORTED SEPARATELY. A failure in one is not a failure in another, and
# collapsing them loses the diagnosis -- "the engine did not build" is not actionable, whereas
# "glib configured but pixman's make failed" is.
#
#   DEPENDENCIES   the third-party libraries QEMU cannot be built without
#   NATIVE ENGINE  DroidVM's own bridge, compiled for arm64-apple-ios
#   QEMU           QEMU configured and built as a shared library
#   SYMBOL VERIFY  every symbol in the manifest is exported, and the arch is right
#   SWIFT ENGINE   the engine adapters compiled, not merely type-checked
#   APP LINK       DroidVMApp linked by a real linker invocation
#
# WHAT LEVEL C IS NOT
#
# It is not a device test and it does not boot Android. No guest image is downloaded: the app
# dlopens the engine at runtime rather than linking against it, so proving the link needs no
# guest bytes at all.
#
# THE RECIPE IS ADAPTED, NOT INVENTED
#
# The dependency sequence below is transcribed from a build that is known to produce an
# arm64-ios QEMU -- the reference implementation's scripts/build_ios.sh, recorded in
# THIRD_PARTY.md as an adapted (class B) source. The configure flags are what cross-compiles,
# not anyone's expression.
#
# DROIDVM'S DEPENDENCY SET IS SMALLER, DELIBERATELY
#
# The reference builds QEMU with `--enable-opengl --enable-virglrenderer`, which requires
# virglrenderer, libepoxy and MoltenVK. DroidVM's default display is the software path
# (`virtio-gpu-pci`), so Level C disables the GPU path and three large dependencies with it.
# Enabling `QEMUDisplayMode.gpu` later brings them back, and the patch in engine/patches that
# goes with them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAGES_ALL=(deps native qemu symbols swift app)
STAGES=("$@")
[ "${#STAGES[@]}" -eq 0 ] && STAGES=("${STAGES_ALL[@]}")

VENDOR="$ROOT/engine/vendor"
SRC="$VENDOR/src"
BUILD="$ROOT/build/ios-arm64"
PREFIX="$BUILD/sysroot"
LOGS="$BUILD/logs"
STAMPS="$BUILD/stamps"
STAGED_LIB="$BUILD/lib"
PATCHES="$ROOT/engine/patches"
MANIFEST="$ROOT/engine/symbols/required-symbols.txt"
DIGESTS="$ROOT/engine/deps-digests.txt"
QEMU_SRC_NAME="qemu-10.0.12-utm"

mkdir -p "$SRC" "$BUILD" "$PREFIX" "$LOGS" "$STAMPS" "$STAGED_LIB"

# ---------------------------------------------------------------- toolchain

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: gate 3 needs macOS with Xcode." >&2
    exit 2
fi

die() {
    echo "  FAIL: $*" >&2
    # A GitHub Actions annotation, because without one the diagnosis is unreachable: job logs
    # require a token, and the annotations API is the only surface an unauthenticated reader
    # can see. Three gate-3 runs were spent on "Process completed with exit code 1".
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error title=engine build::%s\n' \
            "$(printf '%s' "$*" | sed 's/%/%25/g' | tr '\n' ' ' | tr -d '\r')"
    fi
    exit 1
}

banner() { printf '\n=== %s ===\n' "$*"; }

# QEMU refuses to compile when NDEBUG is defined, and the message is unambiguous:
#
#   include/qemu/osdep.h:294: #error building with NDEBUG is not supported
#
# NDEBUG is not an optimisation flag -- it disables `assert()`, and QEMU relies on its
# assertions for correctness. So removing it keeps `-O2` intact and makes the engine stricter
# rather than weaker.
#
# Declared as a function rather than inline for one reason: a guard that cannot be run
# anywhere is a guard nobody has tested. This script exits 2 on any host without Xcode, so the
# guard is unreachable there -- but as a function it can be extracted and called, and
# scripts/check_host.sh does exactly that, proving it accepts a clean -O2 flag set and refuses
# one containing NDEBUG.
require_no_ndebug() {
    local droidvm_flags
    for droidvm_flags in "$@"; do
        case "$droidvm_flags" in
            *-DNDEBUG*)
                die "DroidVM's compile flags define NDEBUG, which QEMU refuses to build with (include/qemu/osdep.h:294). Remove it from CFLAGS; -O2 is the optimisation."
                ;;
        esac
    done
}

# Fail with the log surfaced. The FIRST decisive line is what matters -- it is the actual
# compiler or configure error, and hiding it behind a path is what made the last failure take
# a run to identify.
die_log() {
    local stage="$1" log="$2" msg="$3" decisive=""
    if [ -f "$log" ]; then
        decisive="$(grep -m1 -E '#error|error:|Error:|ERROR:|configure: error' "$log" \
                    || tail -n 1 "$log")"
        echo "----- $stage log tail ($log) -----" >&2
        tail -n 40 "$log" >&2
        echo "---------------------------------" >&2
    else
        decisive="$msg (no log at $log)"
    fi
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error title=%s::%s\n' "$stage" \
            "$(printf '%s' "$decisive" | sed 's/%/%25/g' | tr '\n' ' ' | tr -d '\r')"
    fi
    die "$msg"
}

# Fail hard on a missing tool rather than half-way through a dependency's configure.
for tool in curl make patch pkg-config git; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' is not on PATH"
done
command -v meson >/dev/null 2>&1 || die "meson is not on PATH (brew install meson)"
command -v ninja >/dev/null 2>&1 || die "ninja is not on PATH (brew install ninja)"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDKVERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
TARGET="arm64-apple-ios16.4"
NCPU="$(sysctl -n hw.ncpu)"

CC="$(xcrun --sdk iphoneos --find clang)"
CXX="$(xcrun --sdk iphoneos --find clang++)"
OBJCC="$CC"
AR="$(xcrun --sdk iphoneos --find ar)"
NM="$(xcrun --sdk iphoneos --find nm)"
RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
STRIP="$(xcrun --sdk iphoneos --find strip)"
PKG_CONFIG="$(command -v pkg-config)"

# -O2 stays. -DNDEBUG does not, and the reason is worth recording because it cost a
# multi-hour CI run to find.
#
# QEMU REFUSES TO BUILD WITH NDEBUG:
#
#   include/qemu/osdep.h:294: #error building with NDEBUG is not supported
#
# And NDEBUG is not an optimisation flag to begin with -- it disables `assert()`. QEMU relies
# on its assertions for correctness, so defining it there is a correctness change that QEMU
# forbids outright. Dropping it keeps `-O2`, and if anything it makes the engine stricter
# rather than weaker. The guard below is not ceremony: the flag used to be here, and nothing
# in the script said why it could not be.
CFLAGS="-target $TARGET -isysroot $SDK -O2 -fPIC"
CXXFLAGS="$CFLAGS -std=c++17"
OBJCFLAGS="$CFLAGS"
LDFLAGS="-target $TARGET -isysroot $SDK"
export CFLAGS CXXFLAGS OBJCFLAGS LDFLAGS CC CXX AR NM RANLIB STRIP

require_no_ndebug "$CFLAGS" "$CXXFLAGS" "$OBJCFLAGS"

# pkg-config must look ONLY inside the sysroot. Left to itself it finds Homebrew's macOS
# libraries, and the link then fails with "building for iOS, but linking in dylib built for
# macOS" -- one of the least helpful errors the toolchain produces.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH=""
export PKG_CONFIG_SYSROOT_DIR=""

echo "================================================================"
echo " DroidVM engine build for iOS"
echo "   sdk      : $SDK ($SDKVERSION)"
echo "   target   : $TARGET"
echo "   prefix   : $PREFIX"
echo "   jobs     : $NCPU"
echo "   stages   : ${STAGES[*]}"
echo "================================================================"

# ---------------------------------------------------------------- helpers

done_stage() { [ -f "$STAMPS/$1" ]; }
mark_stage() { touch "$STAMPS/$1"; }

# Deterministic downloads: versions pinned by URL, digests recorded on first fetch and
# verified from then on. That makes the build byte-reproducible without anyone having to guess
# a hash in advance, and it does not block the first run on a digest nobody has yet.
verify_digest() {
    local name="$1" file="$2" actual expected
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"

    if [ ! -f "$DIGESTS" ]; then
        {
            echo "# DroidVM dependency digests."
            echo "# Recorded automatically on first fetch; commit this file to pin them."
            echo "$actual  $name"
        } > "$DIGESTS"
        echo "  digest RECORDED: $actual  $name"
        return 0
    fi

    expected="$(awk -v n="$name" '$2 == n {print $1}' "$DIGESTS" | head -1)"
    if [ -z "$expected" ]; then
        echo "$actual  $name" >> "$DIGESTS"
        echo "  digest RECORDED (new): $actual  $name"
        return 0
    fi
    [ "$expected" = "$actual" ] \
        || die "$name digest mismatch: pinned $expected, got $actual"
    echo "  digest ok ($name)"
}

fetch() {
    local name="$1" url="$2" out="$3"
    if [ -f "$out" ]; then
        echo "  cached $name"
    else
        echo "  fetching $name"
        curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url" \
            || die "could not fetch $name from $url"
        mv "$out.part" "$out"
    fi
    verify_digest "$name" "$out"
}

extract() {
    local archive="$1" dirname="$2"
    if [ -d "$SRC/$dirname" ]; then echo "  unpacked already"; return 0; fi
    mkdir -p "$SRC/$dirname"
    case "$archive" in
        *.tar.xz) tar -xf  "$archive" -C "$SRC/$dirname" --strip-components=1 ;;
        *.tar.gz) tar -xzf "$archive" -C "$SRC/$dirname" --strip-components=1 ;;
        *) die "unknown archive type: $archive" ;;
    esac
}

apply_patch() {
    local dir="$1" patch="$2" stamp="$SRC/$1/.droidvm-patched"
    [ -f "$stamp" ] && { echo "  already patched"; return 0; }
    [ -f "$PATCHES/$patch" ] || die "patch $patch is not in engine/patches"
    echo "  applying $patch"
    ( cd "$SRC/$dir" && patch -p1 -N < "$PATCHES/$patch" ) \
        || die "patch $patch did not apply to $dir -- see engine/patches/README.md"
    touch "$stamp"
}

# The meson cross-file. `needs_exe_wrapper` is true because iOS binaries cannot run on the
# build host, so meson must not try to execute what it builds.
gen_cross() {
    local cross="$1" system="$2"
    local c_args cxx_args objc_args ld_args
    c_args="$(echo "$CFLAGS"    | sed "s/ /','/g")"
    cxx_args="$(echo "$CXXFLAGS" | sed "s/ /','/g")"
    objc_args="$(echo "$OBJCFLAGS" | sed "s/ /','/g")"
    ld_args="$(echo "$LDFLAGS"  | sed "s/ /','/g")"
    cat > "$cross" <<CROSSEOF
# Generated by DroidVM's build_engine_ios.sh. Do not edit.
[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['$c_args']
c_link_args = ['$ld_args']
cpp_args = ['$cxx_args']
cpp_link_args = ['$ld_args']
objc_args = ['$objc_args']
objc_link_args = ['$ld_args']

[binaries]
c = '$CC'
cpp = '$CXX'
objc = '$OBJCC'
ar = '$AR'
nm = '$NM'
ranlib = '$RANLIB'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'

[host_machine]
system = '$system'
kernel = 'xnu'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSSEOF
}

CROSS_IOS="$BUILD/cross-ios.meson"
CROSS_DARWIN="$BUILD/cross-darwin.meson"
gen_cross "$CROSS_IOS" ios
gen_cross "$CROSS_DARWIN" darwin

build_autotools() {
    local name="$1"; shift
    local log="$LOGS/$name.log"
    done_stage "$name" && { echo "  [skip] $name"; return 0; }
    echo "  building $name (autotools)"
    ( cd "$SRC/$name" \
      && ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
                     --enable-static --disable-shared "$@" \
      && make -j"$NCPU" \
      && make install ) > "$log" 2>&1 || die_log "$name" "$log" "$name failed to build"
    mark_stage "$name"
}

build_meson() {
    local name="$1" cross="$2"; shift 2
    local log="$LOGS/$name.log"
    done_stage "$name" && { echo "  [skip] $name"; return 0; }
    echo "  building $name (meson)"
    rm -rf "$SRC/$name/_droidvm_build"
    ( cd "$SRC/$name" \
      && meson setup _droidvm_build --cross-file "$cross" --prefix="$PREFIX" \
                --buildtype=release --default-library=static "$@" \
      && meson compile -C _droidvm_build -j "$NCPU" \
      && meson install -C _droidvm_build ) > "$log" 2>&1 \
        || die_log "$name" "$log" "$name failed to build"
    mark_stage "$name"
}

# ---------------------------------------------------------------- DEPENDENCIES
#
# Five libraries, each unavoidable. THIRD_PARTY.md carries the source, revision, licence and
# why; engine/patches/README.md explains why the two patched ones need patching.

run_deps() {
    banner "DEPENDENCIES"

    # libffi -- the FFI plumbing QEMU will not configure without.
    fetch "libffi-3.5.0.tar.gz" \
          "https://github.com/libffi/libffi/releases/download/v3.5.0/libffi-3.5.0.tar.gz" \
          "$VENDOR/libffi-3.5.0.tar.gz"
    extract "$VENDOR/libffi-3.5.0.tar.gz" "libffi-3.5.0"
    build_autotools libffi-3.5.0

    # glib -- QEMU's core data structures and main loop; the largest dependency. Everything
    # optional is off: none of it is reachable from QEMU and each one is another way for a
    # cross-compile to fail.
    fetch "glib-2.83.0.tar.xz" \
          "https://download.gnome.org/sources/glib/2.83/glib-2.83.0.tar.xz" \
          "$VENDOR/glib-2.83.0.tar.xz"
    extract "$VENDOR/glib-2.83.0.tar.xz" "glib-2.83.0"
    build_meson glib-2.83.0 "$CROSS_IOS" \
        -Dtests=false -Dnls=disabled -Dintrospection=disabled \
        -Dselinux=disabled -Dlibmount=disabled -Ddtrace=disabled \
        -Dman-pages=disabled -Dglib_debug=disabled -Dxattr=false

    # pixman -- QEMU's software rasteriser, and the reason the software display path works.
    fetch "pixman-0.38.0.tar.gz" \
          "https://www.cairographics.org/releases/pixman-0.38.0.tar.gz" \
          "$VENDOR/pixman-0.38.0.tar.gz"
    extract "$VENDOR/pixman-0.38.0.tar.gz" "pixman-0.38.0"
    apply_patch pixman-0.38.0 pixman-0.38.0.patch
    build_autotools pixman-0.38.0 --disable-gtk --disable-libpng --disable-arm-iwmmxt

    # libucontext -- the iOS SDK withholds makecontext/swapcontext, which QEMU's coroutines
    # need. Pinned by commit as well as repository: the Darwin/arm64 assembly fixes are what
    # make it work here.
    if [ ! -d "$SRC/libucontext" ]; then
        echo "  cloning libucontext at 9b1d8f0"
        git clone --quiet https://github.com/utmapp/libucontext.git "$SRC/libucontext" \
            || die "could not clone libucontext"
        ( cd "$SRC/libucontext" \
          && git checkout --quiet 9b1d8f01a6e99166f9808c79966abe10786de8b6 ) \
            || die "could not check out the pinned libucontext commit"
    fi
    build_meson libucontext "$CROSS_IOS" -Dfreestanding=true

    # libslirp -- QEMU's user-mode networking, which is what `-netdev user` means. The launch
    # plan always configures one, so this is not optional.
    fetch "libslirp-v4.9.1.tar.gz" \
          "https://github.com/utmapp/libslirp/releases/download/v4.9.1-release-mirror/libslirp-v4.9.1.tar.gz" \
          "$VENDOR/libslirp-v4.9.1.tar.gz"
    extract "$VENDOR/libslirp-v4.9.1.tar.gz" "libslirp-v4.9.1"
    apply_patch libslirp-v4.9.1 libslirp-v4.9.1.patch
    build_meson libslirp-v4.9.1 "$CROSS_DARWIN"

    # THE GUARD THAT COULD NOT FAIL.
    #
    # This used to be:
    #
    #     ls -1 "$PREFIX/lib"/*.a 2>/dev/null | sed 's/^/    /' || die "no static libraries..."
    #
    # `|| die` binds to the PIPELINE's status, which is sed's -- and sed succeeds even when ls
    # finds nothing. So the stage would have reported PASS with an empty sysroot. It is written
    # out here so that nobody restores the one-liner.
    local installed
    installed="$(ls -1 "$PREFIX/lib"/*.a 2>/dev/null || true)"
    if [ -z "$installed" ]; then
        die "no static libraries were installed into $PREFIX/lib"
    fi

    # And each required library by name, because a non-empty directory is not the same claim as
    # "the five dependencies produced what QEMU will look for".
    local required missing=0
    for required in libglib-2.0.a libgobject-2.0.a libgio-2.0.a \
                    libffi.a libpixman-1.a libslirp.a libucontext.a; do
        if [ -f "$PREFIX/lib/$required" ]; then
            printf '  %-32s present\n' "$required"
        else
            printf '  %-32s MISSING\n' "$required" >&2
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -eq 0 ] || die "$missing required library/libraries are missing from $PREFIX/lib"

    echo "  DEPENDENCIES: PASS ($(echo "$installed" | wc -l | tr -d ' ') static libraries)"
}

# ---------------------------------------------------------------- NATIVE ENGINE

run_native() {
    banner "NATIVE ENGINE (DroidVM's bridge, $TARGET)"
    mkdir -p "$BUILD/native"
    local count=0
    for src in engine/native/*.c; do
        printf '  %-44s ' "$src"
        "$CC" -std=c11 -Wall -Wextra -Werror -O2 -fPIC \
              -target "$TARGET" -isysroot "$SDK" \
              -I engine/include -I engine/native \
              -c "$src" -o "$BUILD/native/$(basename "$src" .c).o" \
            || die "$src did not compile for $TARGET"
        echo "ok"
        count=$((count + 1))
    done
    printf '  %-44s ' "engine/jit/droidvm-brk.S"
    "$CC" -c -target "$TARGET" -isysroot "$SDK" \
          engine/jit/droidvm-brk.S -o "$BUILD/native/droidvm-brk.o" \
        || die "the trap protocol did not assemble for $TARGET"
    echo "ok"
    echo "  NATIVE ENGINE: PASS ($count sources + the trap protocol)"
}

# ---------------------------------------------------------------- QEMU
#
# QEMU as a SHARED LIBRARY rather than an executable: an iOS app cannot spawn a process, so
# the machine has to live inside this one. That is what `--enable-shared-lib` is for, and it
# is why the export list matters -- QEMU exports only what `system/qemu.symbols` names.

run_qemu() {
    banner "QEMU ($QEMU_SRC_NAME)"
    fetch "qemu-10.0.12-utm.tar.xz" \
          "https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz" \
          "$VENDOR/qemu-10.0.12-utm.tar.xz"
    extract "$VENDOR/qemu-10.0.12-utm.tar.xz" "$QEMU_SRC_NAME"

    # NOTE on placement, because it is the one thing about this stage that is deliberately
    # incomplete.
    #
    # DroidVM's bridge currently compiles into the APP target (stage `native`), and the dylib
    # provides QEMU's entry points. That is coherent for a link gate: the app dlopens the
    # dylib and resolves qemu_* from it.
    #
    # It is NOT yet coherent at runtime, and the gap is worth naming. The display listener has
    # to live INSIDE QEMU -- it is QEMU's DisplayChangeListener, registered with QEMU's display
    # system, and QEMU's callbacks call the six counters. Those counters therefore have to be
    # in the same image as the listener. Moving the bridge into the dylib means the Swift
    # adapters resolve droidvm_* through dlsym exactly as they resolve qemu_*, which is a real
    # change to TrapExecutableMemory and MetalDisplaySurface and belongs to the phase that
    # makes the machine run.
    #
    # Copying the bridge into QEMU's tree now would give the process TWO sets of counters --
    # one in the app, one in the dylib -- and the app would read the wrong one. So
    # integrate_engine.sh is not called here, and scripts/integrate_engine.sh says why.
    local dir="$SRC/$QEMU_SRC_NAME"
    local log="$LOGS/qemu.log"
    if done_stage qemu; then
        echo "  [skip] configure and make (stamped)"
    else
        echo "  configuring (this is the long one)"
        rm -rf "$dir/_droidvm_build"; mkdir -p "$dir/_droidvm_build"
        ( cd "$dir/_droidvm_build" \
          && ../configure \
                --prefix="$PREFIX" \
                --cross-prefix="" \
                --target-list=aarch64-softmmu \
                --enable-shared-lib \
                --with-coroutine=libucontext \
                --enable-slirp \
                --disable-cocoa --disable-sdl --disable-gtk --disable-coreaudio \
                --disable-vnc --disable-spice \
                --disable-opengl --disable-virglrenderer \
                --disable-curses --disable-curl --disable-libusb --disable-usb-redir \
                --disable-tpm --disable-docs --disable-guest-agent --disable-tools \
                --disable-hvf --disable-vde --disable-brlapi --disable-libssh \
                --disable-bzip2 --disable-snappy --disable-lzo --disable-gnutls \
                --disable-png --disable-vte --disable-zstd \
                --disable-nettle --disable-gcrypt --disable-auth-pam \
                --disable-install-blobs --disable-sparse --disable-debug-info \
                --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
          && make -j"$NCPU" ) > "$log" 2>&1 \
            || die_log "QEMU" "$log" "QEMU configure or build failed"
        mark_stage qemu
    fi

    local built="$dir/_droidvm_build/libqemu-aarch64-softmmu.dylib"
    [ -f "$built" ] || die "QEMU produced no dylib at $built"
    cp -f "$built" "$STAGED_LIB/"
    echo "  QEMU: PASS ($(du -h "$STAGED_LIB/libqemu-aarch64-softmmu.dylib" | cut -f1))"
}

# ---------------------------------------------------------------- SYMBOL VERIFY

# Extract the function names DroidVMBridge.h DECLARES.
#
# NOT a regex over the raw file, and the reason is not style.
#
# The previous version was:
#
#     grep -oE '\\b(droidvm_[a-z_]+|qemu_[a-z_]+)\\(' engine/include/DroidVMBridge.h
#
# which is a malformed ERE: the doubled backslashes turn `\(` into a literal backslash
# followed by a group-opening `(`, so the pattern has two `(` and one `)` and grep refuses with
# "parentheses not balanced". It cost a gate-3 run.
#
# Fixing the escaping would still have been wrong. A name mentioned in a COMMENT is not a
# declaration, and a regex over raw text cannot tell them apart -- it would demand that a
# symbol nobody declares appear in the manifest, which is the same class of error pointing the
# other way. So comments are removed first, by a small state machine, and the identifier before
# each '(' is taken from what remains. No pattern spans a parenthesis.
#
# It is a function rather than an inline pipeline so it can be tested off-macOS: this script
# exits 2 without Xcode. scripts/check_host.sh extracts it and proves a declaration is matched,
# a comment-only mention is rejected, and an input yielding nothing is refused rather than
# accepted.
extract_bridge_declarations() {
    local header="$1"
    [ -f "$header" ] || die "no bridge header at $header"

    local stripped names
    stripped="$(awk '
        {
            line = $0; out = ""; i = 1
            while (i <= length(line)) {
                two = substr(line, i, 2)
                if (incomment) {
                    if (two == "*/") { incomment = 0; i += 2 } else { i += 1 }
                } else if (two == "/*") {
                    incomment = 1; i += 2
                } else if (two == "//") {
                    break
                } else {
                    out = out substr(line, i, 1); i += 1
                }
            }
            print out
        }' "$header")"

    [ -n "$stripped" ] || die "comment stripping produced nothing from $header"

    # Split on '(' and take the trailing identifier of each preceding fragment. No regex here
    # spans a parenthesis, so there is nothing to unbalance.
    names="$(printf '%s\n' "$stripped" | awk '
        {
            n = split($0, parts, "(")
            for (i = 1; i < n; i++) {
                if (match(parts[i], /[A-Za-z_][A-Za-z0-9_]*$/)) {
                    print substr(parts[i], RSTART, RLENGTH)
                }
            }
        }' | grep -E '^(droidvm_|qemu_)' | sort -u)"

    # A check that extracts nothing passes vacuously -- it would report "no undeclared
    # symbols" about an empty set. That is the false-pass class this project keeps finding, so
    # it is refused here rather than trusted.
    [ -n "$names" ] || die "no droidvm_/qemu_ declarations were extracted from $header; \
the manifest cross-check would pass vacuously"

    printf '%s\n' "$names"
}

run_symbols() {
    banner "SYMBOL VERIFY"
    local dylib="$STAGED_LIB/libqemu-aarch64-softmmu.dylib"
    [ -f "$dylib" ] || die "no dylib to verify"

    # Wrong architecture is a failure, not a warning: a macOS dylib would link and then fail
    # to load on the device in a way that looks like something else entirely.
    local archs
    archs="$(lipo -archs "$dylib" 2>/dev/null || echo unknown)"
    echo "  archs: $archs"
    [ "$archs" = "arm64" ] || die "expected an arm64 dylib, got '$archs'"

    local exports
    exports="$(xcrun nm -gU "$dylib" 2>/dev/null | awk '{print $3}' | sed 's/^_//' | sort -u)"

    # TWO TIERS, because the two kinds of symbol come from two different images.
    #
    #   qemu_*     provided by the dylib. The app dlopens the dylib and resolves these, so a
    #              missing one links fine and fails at dlopen.
    #   droidvm_*  provided by DroidVM's own sources, which compile into the APP. Verified
    #              against the objects this build just produced, and against the public bridge
    #              header, so the manifest and the header cannot drift.
    local missing=0 declared=0 from_dylib=0 from_app=0 symbol
    while IFS= read -r raw; do
        symbol="$(echo "$raw" | sed 's/#.*//' | tr -d '[:space:]')"
        [ -z "$symbol" ] && continue
        declared=$((declared + 1))

        case "$symbol" in
            qemu_*)
                if echo "$exports" | grep -qx "$symbol"; then
                    printf '  %-46s exported by the engine\n' "$symbol"
                    from_dylib=$((from_dylib + 1))
                else
                    printf '  %-46s MISSING FROM ENGINE   <-- links fine, fails at dlopen\n' \
                        "$symbol" >&2
                    missing=$((missing + 1))
                fi
                ;;
            droidvm_*)
                if xcrun nm -g --defined-only "$BUILD/native"/*.o 2>/dev/null \
                        | awk '{print $3}' | sed 's/^_//' | grep -qx "$symbol"; then
                    printf '  %-46s defined in the app\n' "$symbol"
                    from_app=$((from_app + 1))
                else
                    printf '  %-46s MISSING FROM APP\n' "$symbol" >&2
                    missing=$((missing + 1))
                fi
                ;;
        esac
    done < "$MANIFEST"
    [ "$missing" -eq 0 ] || die "$missing required symbol(s) do not resolve"

    # Every symbol the public bridge header declares must be in the manifest, or a Swift call
    # would reach a symbol nothing validated.
    local header_symbols undeclared=0
    header_symbols="$(extract_bridge_declarations engine/include/DroidVMBridge.h)"
    echo "  bridge header declares $(printf '%s\n' "$header_symbols" | wc -l | tr -d ' ') symbol(s)"
    for exported in $header_symbols; do
        if ! grep -qE "^[[:space:]]*${exported}[[:space:]]*$" "$MANIFEST"; then
            printf '  %-46s DECLARED IN BRIDGE, ABSENT FROM MANIFEST\n' "$exported" >&2
            undeclared=$((undeclared + 1))
        fi
    done
    [ "$undeclared" -eq 0 ] || die "$undeclared bridge declaration(s) are not in the manifest"

    echo "  SYMBOL VERIFY: PASS ($declared declared: $from_dylib from the engine, "
         "$from_app from the app; engine is arm64)"
}

# ---------------------------------------------------------------- SWIFT ENGINE
#
# Compiled, not merely type-checked. Gate 2 type-checks; this produces objects, which is a
# different claim.

run_swift() {
    banner "SWIFT ENGINE (compiled to objects)"
    mkdir -p "$BUILD/swift"
    xcrun -sdk iphoneos swiftc \
        -emit-module -emit-module-path "$BUILD/swift/DroidVMCore.swiftmodule" \
        -module-name DroidVMCore -target "$TARGET" -sdk "$SDK" -swift-version 5 \
        $(find core/Sources/DroidVMCore -name '*.swift' | sort) \
        || die "DroidVMCore did not compile"

    local n=0 src
    for src in $(find engine -name '*.swift' | sort); do
        printf '  %-48s ' "$src"
        xcrun -sdk iphoneos swiftc -c -parse-as-library \
            -target "$TARGET" -sdk "$SDK" -swift-version 5 \
            -import-objc-header engine/include/DroidVMBridge.h \
            -I "$BUILD/swift" \
            "$src" -o "$BUILD/swift/$(basename "$src" .swift).o" \
            || die "$src did not compile"
        echo "ok"
        n=$((n + 1))
    done
    echo "  SWIFT ENGINE: PASS ($n adapters compiled)"
}

# ---------------------------------------------------------------- APP LINK
#
# A REAL LINKER INVOCATION, via xcodebuild -- the same path the IPA uses. Compilation passing
# is not linking, and Level C is not PASS on compilation alone.
#
# The app does not link against the engine dylib: it dlopens it at runtime, which is why no
# guest asset and no dylib is needed to prove the app itself links. The dylib is verified
# separately above and embedded at packaging time.

run_app() {
    banner "APP LINK (xcodebuild)"
    command -v xcodegen >/dev/null 2>&1 || die "xcodegen is not on PATH (brew install xcodegen)"
    ( cd app && xcodegen generate --quiet ) || die "xcodegen could not generate the project"

    local log="$LOGS/app-link.log" rc=0
    set +e
    xcodebuild -project app/DroidVM.xcodeproj -scheme DroidVM \
        -sdk iphoneos -configuration Release -derivedDataPath "$BUILD/derived" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        build > "$log" 2>&1
    rc=$?
    set -e
    grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$log" | tail -20 || true
    [ "$rc" -eq 0 ] || die_log "APP LINK" "$log" "the app did not link"

    local app="$BUILD/derived/Build/Products/Release-iphoneos/DroidVM.app"
    [ -d "$app" ] || die "no app bundle at $app"
    echo "  APP LINK: PASS ($(du -sh "$app" | cut -f1))"
}

# ---------------------------------------------------------------- run

for stage in "${STAGES[@]}"; do
    case "$stage" in
        deps)    run_deps ;;
        native)  run_native ;;
        qemu)    run_qemu ;;
        symbols) run_symbols ;;
        swift)   run_swift ;;
        app)     run_app ;;
        *)       die "unknown stage '$stage' (expected: ${STAGES_ALL[*]})" ;;
    esac
done

banner "summary"
echo " NATIVE ENGINE : engine/native for $TARGET"
echo " QEMU          : $STAGED_LIB/libqemu-aarch64-softmmu.dylib"
echo " SYMBOL VERIFY : manifest $MANIFEST"
echo " SWIFT ENGINE  : $BUILD/swift"
echo " APP LINK      : $BUILD/derived/Build/Products/Release-iphoneos/DroidVM.app"
echo
echo " LEVEL D (device start) : NOT RUN -- and not inferable from a successful link."
