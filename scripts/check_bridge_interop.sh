#!/bin/bash
# DroidVM engine bridge + native gate.  Runs anywhere with a Swift toolchain and clang.
#
#   ./scripts/check_bridge_interop.sh
#
# Links the REAL native engine sources, the REAL bridge header, the REAL DroidVMCore (as a
# separate module, because that is what it is in the app) and the REAL JIT adapter into one
# executable, then runs it. The only stand-in is QEMU's three entry points, which cannot be
# present on a host by definition.
#
# It answers the questions about the engine that do not need Apple:
#
#   * does the C bridge header become visible to Swift alongside a separate core module?
#   * does a plain C `typedef enum` import such that `==` and `switch` work on it?
#   * does a C struct get a memberwise initialiser, and does its layout match Swift's view?
#   * does an out-parameter work with `&`, and is a null one refused rather than dereferenced?
#   * does a `char **` survive in both directions?
#   * can a function pointer be called through a `@convention(c)` typealias?
#   * do the SIX display counters stay distinct through the real native code?
#   * does the process-wide reset actually clear everything?
#   * does the serial counter saturate rather than wrap -- wrapping would read as silence?
#   * does the JIT status machine map onto DroidVM's error type the way the adapter assumes?
#   * is the product-facing readiness `unavailable` rather than `failed` on a host -- the
#     distinction that decides whether the app sends someone hunting a bug?
#
# WHAT IT DOES NOT ANSWER
#
# Anything about QEMU, Metal, the JIT trap itself, `vm_remap`, arm64, the iOS SDK or a
# device. On this host the executable-memory mechanism is genuinely absent and the tests
# assert the honest consequence of that; they do not fake a success path.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build/bridge-interop"
rm -rf "$BUILD"
mkdir -p "$BUILD"

fails=0

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
echo " DroidVM engine bridge + native gate"
echo "   swiftc : $SWIFTC"
echo "   cc     : $CC_BIN"
echo "   $(uname -srm)"
echo "================================================================"

CFLAGS="-std=c11 -Wall -Wextra -Werror -O1 -I engine/include -I engine/native"

# ------------------------------------------------- real native engine sources

echo
echo "--- compiling the real native engine (engine/native) ---"
NATIVE_OBJECTS=()
NATIVE_SOURCES=()
while IFS= read -r f; do NATIVE_SOURCES+=("$f"); done \
    < <(find engine/native -name '*.c' | sort)

if [ "${#NATIVE_SOURCES[@]}" -eq 0 ]; then
    echo "  FAIL: no native sources found under engine/native" >&2
    exit 1
fi

for src in "${NATIVE_SOURCES[@]}"; do
    obj="$BUILD/$(basename "$src" .c).o"
    printf '  %-44s ' "$src"
    if "$CC_BIN" $CFLAGS -c "$src" -o "$obj" 2>"$BUILD/$(basename "$src").log"; then
        echo "ok"
        NATIVE_OBJECTS+=("$obj")
    else
        echo "FAIL"
        sed 's/^/      /' "$BUILD/$(basename "$src").log" | head -20
        fails=$((fails + 1))
    fi
done

# ------------------------------------------------------------- QEMU stand-in

echo
printf '  %-44s ' "tests/cinterop/qemu_shim.c"
if "$CC_BIN" $CFLAGS -c tests/cinterop/qemu_shim.c -o "$BUILD/qemu_shim.o" \
        2>"$BUILD/qemu_shim.log"; then
    echo "ok"
    NATIVE_OBJECTS+=("$BUILD/qemu_shim.o")
else
    echo "FAIL"
    sed 's/^/      /' "$BUILD/qemu_shim.log" | head -20
    fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] || { echo; echo "NATIVE COMPILE: FAIL"; exit 1; }
echo
echo "NATIVE COMPILE: PASS (${#NATIVE_SOURCES[@]} engine sources, -Wall -Wextra -Werror)"

# ----------------------------------------------------- symbol manifest

echo
echo "--- SYMBOL MANIFEST (engine/symbols/required-symbols.txt) ---"
MANIFEST="engine/symbols/required-symbols.txt"
# The engine-only manifest: symbols the QEMU dylib exports and the app does not
# define. Checked here only to keep the bridge header from declaring something that
# is gated nowhere; gate 3 checks it against the built engine.
ENGINE_MANIFEST="engine/symbols/required-engine-symbols.txt"
if [ ! -f "$MANIFEST" ]; then
    echo "  FAIL: the symbol manifest is missing" >&2
    exit 1
fi

# Every DROIDVM symbol in the manifest must actually be DEFINED in the objects DroidVM builds.
# The qemu_* entries are QEMU's and are not expected here -- that is the point of grouping them.
symbol_fails=0
droidvm_required=0
qemu_required=0
while IFS= read -r raw; do
    symbol="$(echo "$raw" | sed 's/#.*//' | tr -d '[:space:]')"
    [ -z "$symbol" ] && continue

    case "$symbol" in
        qemu_*)
            qemu_required=$((qemu_required + 1))
            continue ;;
        droidvm_*)
            droidvm_required=$((droidvm_required + 1)) ;;
        *)
            printf '  %-46s UNEXPECTED PREFIX\n' "$symbol"
            symbol_fails=$((symbol_fails + 1))
            continue ;;
    esac

    # Defined (T/t) anywhere in DroidVM's own objects?
    if nm -g --defined-only "${NATIVE_OBJECTS[@]}" 2>/dev/null \
            | awk '{print $3}' | grep -qx "$symbol"; then
        printf '  %-46s defined\n' "$symbol"
    else
        printf '  %-46s MISSING\n' "$symbol"
        symbol_fails=$((symbol_fails + 1))
    fi
done < "$MANIFEST"

# The invariant is not "every droidvm_* symbol is declared" -- the engine has internal seams
# (the six counter entry points, the reset) that are deliberately NOT part of the exported
# surface. It is "the manifest and the public bridge header say the same thing": the header is
# what Swift may call, the manifest is what gate 3 must export, and the two must not drift.
undeclared=0
declared="$(grep -oE '\b(droidvm_[a-z_]+|qemu_[a-z_]+)\(' engine/include/DroidVMBridge.h \
            | tr -d '(' | sort -u)"
while IFS= read -r symbol; do
    [ -z "$symbol" ] && continue
    # Either manifest satisfies it. A symbol the bridge declares must be gated SOMEWHERE, but
    # which manifest depends on which image defines it: the app's objects, or the engine dylib.
    if ! grep -qE "^[[:space:]]*${symbol}[[:space:]]*$" "$MANIFEST" \
       && ! grep -qE "^[[:space:]]*${symbol}[[:space:]]*$" "$ENGINE_MANIFEST"; then
        printf '  %-46s DECLARED IN BRIDGE, IN NEITHER MANIFEST\n' "$symbol"
        undeclared=$((undeclared + 1))
    fi
done <<< "$declared"

# And the other direction: a manifest entry the bridge does not declare is either a typo or a
# symbol nothing calls.
for symbol in $(sed 's/#.*//' "$MANIFEST" | tr -d '[:space:]' | grep -E '^droidvm_'); do
    if ! echo "$declared" | grep -qx "$symbol"; then
        printf '  %-46s IN MANIFEST, NOT DECLARED BY THE BRIDGE\n' "$symbol"
        undeclared=$((undeclared + 1))
    fi
done

if [ "$symbol_fails" -ne 0 ] || [ "$undeclared" -ne 0 ]; then
    echo
    echo "  SYMBOL VERIFICATION: FAIL ($symbol_fails missing, $undeclared inconsistent)" >&2
    echo "  The public bridge header and the manifest must agree: the header is what Swift" >&2
    echo "  may call, the manifest is what gate 3 must export, and a symbol in one but not" >&2
    echo "  the other fails at dlopen rather than at link." >&2
    exit 1
fi
echo
echo "  SYMBOL VERIFICATION: PASS"
echo "    $droidvm_required DroidVM symbols defined and matching the bridge header"
echo "    $qemu_required QEMU symbols required from the engine"

# ------------------------------------------------------------- core module
#
# A separate module, because that is what it is in the app target: DroidVMCore is a SwiftPM
# dependency, so a missing import is a compile error -- which is how the harness found that
# every engine adapter was missing one.

echo
echo "--- building DroidVMCore as a module ---"
CORE_SOURCES=()
while IFS= read -r f; do CORE_SOURCES+=("$f"); done \
    < <(find core/Sources/DroidVMCore -name '*.swift' | sort)

if ! "$SWIFTC" -swift-version 5 -O \
        -emit-library -emit-module -module-name DroidVMCore \
        -emit-module-path "$BUILD/DroidVMCore.swiftmodule" \
        -o "$BUILD/libDroidVMCore.so" \
        "${CORE_SOURCES[@]}" 2>"$BUILD/core.log"; then
    echo "  FAIL: DroidVMCore did not build" >&2
    sed 's/^/      /' "$BUILD/core.log" >&2
    exit 1
fi
echo "  SWIFT COMPILE (core): PASS (${#CORE_SOURCES[@]} sources)"

# ------------------------------------------------------- engine adapter + harness

echo
echo "--- compiling the engine adapters and the harness ---"
if ! "$SWIFTC" -swift-version 5 -O \
        -I "$BUILD" -L "$BUILD" -lDroidVMCore \
        -I tests/cinterop \
        -Xcc -fmodule-map-file="$MODULEMAP" \
        -Xcc -I"$ROOT/engine/include" \
        -Xcc -I"$ROOT/engine/native" \
        -o "$BUILD/bridge_interop" \
        engine/jit/TrapExecutableMemory.swift \
        tests/cinterop/BridgeInterop.swift \
        "${NATIVE_OBJECTS[@]}" 2>"$BUILD/swift.log"; then
    echo "  FAIL: the engine adapter or the harness did not compile" >&2
    sed 's/^/      /' "$BUILD/swift.log" >&2
    exit 1
fi
echo "  SWIFT COMPILE (engine + harness): PASS"

# ------------------------------------------------------------- run

echo
echo "--- running the harness ---"
if "$BUILD/bridge_interop"; then
    echo
    echo "================================================================"
    echo " BRIDGE + NATIVE: PASS"
    echo "   verified : the engine's C ABI from Swift, the six display"
    echo "              counters, the process-wide reset, the saturating"
    echo "              serial counter, and the JIT status/error mapping"
    echo "   NOT verified: QEMU, Metal, the trap, vm_remap, arm64, iOS,"
    echo "              or any device"
    echo "================================================================"
    exit 0
else
    echo
    echo "BRIDGE + NATIVE: FAIL" >&2
    exit 1
fi
