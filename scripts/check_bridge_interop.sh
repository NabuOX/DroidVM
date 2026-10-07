#!/bin/bash
# DroidVM bridge interop gate.  Runs anywhere with a Swift toolchain and clang.
#
#   ./scripts/check_bridge_interop.sh
#
# Builds the REAL DroidVMCore as a module, compiles the REAL `engine/jit/TrapExecutableMemory`
# against the REAL bridge header, links a host stub of the bridge's C side, and runs it.
#
# It answers the questions about the engine ABI that do not need Apple frameworks:
#
#   * does the C bridge header become visible to Swift, alongside a separate core module?
#   * does a plain C `typedef enum` import such that `==` and `switch` work on it?
#   * does a C struct get a memberwise initialiser, and does its layout match Swift's view?
#   * does `size_t` arrive as `Int`, and `uint64_t` as `UInt64`?
#   * does an out-parameter work with `&`?
#   * does a `char **` survive in both directions -- how QEMU gets its argument vector?
#   * can a function pointer be called through a `@convention(c)` typealias -- how the engine
#     reaches `qemu_init` after `dlsym`?
#   * does `const char *` convert to `String` the way the error path assumes?
#   * does the module boundary between the engine and the core actually hold?
#
# WHAT IT DOES NOT ANSWER
#
# Anything about QEMU, Metal, the JIT trap itself, `vm_remap`, arm64, the iOS SDK, or a
# device. The C bodies are stand-ins (tests/cinterop/bridge_stub.c) returning synthetic
# values. This is an ABI harness, not device verification, and it must never be reported as
# the latter.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build/bridge-interop"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# ---------------------------------------------------------------- toolchain

find_swift() {
    if [ -n "${DROIDVM_SWIFT:-}" ] && [ -x "${DROIDVM_SWIFT}" ]; then
        echo "${DROIDVM_SWIFT}"; return 0
    fi
    if command -v swiftc >/dev/null 2>&1; then command -v swiftc; return 0; fi
    for cand in "$HOME/swiftroot/usr/libexec/swift/bin/swiftc" \
                "$HOME/swiftroot/usr/bin/swiftc"; do
        [ -x "$cand" ] && { echo "$cand"; return 0; }
    done
    return 1
}

SWIFTC="$(find_swift || true)"
if [ -z "$SWIFTC" ]; then
    echo "SKIP: no Swift toolchain found." >&2
    exit 2
fi

SWIFT_BIN_DIR="$(cd "$(dirname "$SWIFTC")" && pwd)"
SWIFT_PREFIX="$(cd "$SWIFT_BIN_DIR/.." && pwd)"
for d in "$SWIFT_PREFIX/libexec/swift/lib/swift/linux" "$SWIFT_PREFIX/libexec/swift/lib"; do
    [ -d "$d" ] && LD_LIBRARY_PATH="$d:${LD_LIBRARY_PATH:-}"
done
LD_LIBRARY_PATH="$BUILD:${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH

if [ -x "$SWIFT_BIN_DIR/clang" ]; then CC_BIN="$SWIFT_BIN_DIR/clang"
elif command -v clang >/dev/null 2>&1; then CC_BIN="$(command -v clang)"
else CC_BIN="cc"; fi

MODULEMAP="tests/cinterop/module.modulemap"

echo "================================================================"
echo " DroidVM bridge interop gate"
echo "   swiftc : $SWIFTC"
echo "   cc     : $CC_BIN"
echo "   $(uname -srm)"
echo "================================================================"
echo

# ------------------------------------------------------------- C stub

echo "--- compiling the bridge's C side (host stand-in) ---"
if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O1 \
        -I engine/include -c tests/cinterop/bridge_stub.c \
        -o "$BUILD/bridge_stub.o" 2>"$BUILD/stub.log"; then
    echo "FAIL: the stand-in did not compile against DroidVMBridge.h" >&2
    sed 's/^/  /' "$BUILD/stub.log" >&2
    exit 1
fi
echo "  ok"

# ------------------------------------------------------------- core module
#
# A separate module, because that is what it is in the app target: DroidVMCore is a SwiftPM
# dependency, and the engine adapters must import it. Building it separately is what makes
# a missing import a compile error here rather than a surprise in CI.

echo "--- building DroidVMCore as a module ---"
CORE_SOURCES=()
while IFS= read -r f; do CORE_SOURCES+=("$f"); done \
    < <(find core/Sources/DroidVMCore -name '*.swift' | sort)

if ! "$SWIFTC" -swift-version 5 -O \
        -emit-library -emit-module -module-name DroidVMCore \
        -emit-module-path "$BUILD/DroidVMCore.swiftmodule" \
        -o "$BUILD/libDroidVMCore.so" \
        "${CORE_SOURCES[@]}" 2>"$BUILD/core.log"; then
    echo "FAIL: DroidVMCore did not build" >&2
    sed 's/^/  /' "$BUILD/core.log" >&2
    exit 1
fi
echo "  ok (${#CORE_SOURCES[@]} sources)"

# ------------------------------------------------------------- engine + harness
#
# `TrapExecutableMemory` is the one engine adapter that needs no Apple framework, so it is
# compiled here FOR REAL rather than merely parsed.

echo "--- compiling the engine adapter and the harness ---"
if ! "$SWIFTC" -swift-version 5 -O \
        -I "$BUILD" -L "$BUILD" -lDroidVMCore \
        -I tests/cinterop \
        -Xcc -fmodule-map-file="$MODULEMAP" \
        -o "$BUILD/bridge_interop" \
        engine/jit/TrapExecutableMemory.swift \
        tests/cinterop/BridgeInterop.swift \
        "$BUILD/bridge_stub.o" 2>"$BUILD/swift.log"; then
    echo "FAIL: the engine adapter or the harness did not compile" >&2
    sed 's/^/  /' "$BUILD/swift.log" >&2
    echo >&2
    echo "This is the class of error that would otherwise be found only after a macOS CI" >&2
    echo "round trip. Fix the header, the engine adapter, or the harness -- not the check." >&2
    exit 1
fi
echo "  ok (engine/jit/TrapExecutableMemory.swift compiled for real)"

# ------------------------------------------------------------- run

echo
echo "--- running the interop harness ---"
if "$BUILD/bridge_interop"; then
    echo
    echo "================================================================"
    echo " BRIDGE INTEROP: PASS"
    echo "   verified : the engine's C ABI from Swift, and the real JIT"
    echo "              adapter's status and error mapping"
    echo "   NOT verified: QEMU, Metal, the JIT trap itself, vm_remap,"
    echo "              arm64, the iOS SDK, a device"
    echo "================================================================"
    exit 0
else
    echo
    echo "BRIDGE INTEROP: FAIL" >&2
    exit 1
fi
