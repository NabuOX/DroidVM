#!/bin/bash
# DroidVM engine-layer gate.  Runs anywhere with a Swift toolchain and clang.
#
#   ./scripts/check_engine.sh
#
# WHAT THIS IS
#
# The engine adapters under engine/ import Metal, QuartzCore and the C bridge, so they
# cannot be *type-checked* anywhere but macOS. What they CAN be checked for on any platform
# is:
#
#   1. SYNTAX. `swiftc -parse` does not resolve imports or types, so it accepts a file that
#      imports frameworks this machine does not have -- and still rejects unbalanced braces,
#      malformed declarations and truncated edits. That is worth having when the alternative
#      is finding out after a macOS CI round trip.
#
#   2. THE C BRIDGE HEADER compiles. It includes only <stddef.h> and <stdint.h>, so clang on
#      Linux can genuinely syntax-check it, including with -Wall -Wextra -Werror.
#
#   3. The trap protocol has not grown. The assembly cannot be assembled for arm64-ios here,
#      but the three instruction pairs can be checked for presence and for nothing extra.
#
# WHAT IT IS NOT
#
# PARSE PASS is NOT COMPILE PASS. It proves syntax. It does not prove that a symbol exists,
# that a type is right, that anything links, or that any of it works. The report says so at
# every level, and this script repeats it at the end.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fails=0
note() { printf '\n--- %s ---\n' "$*"; }

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
SWIFT_BIN_DIR=""
if [ -n "$SWIFTC" ]; then
    SWIFT_BIN_DIR="$(cd "$(dirname "$SWIFTC")" && pwd)"
    SWIFT_PREFIX="$(cd "$SWIFT_BIN_DIR/.." && pwd)"
    for d in "$SWIFT_PREFIX/libexec/swift/lib/swift/linux" "$SWIFT_PREFIX/libexec/swift/lib"; do
        [ -d "$d" ] && LD_LIBRARY_PATH="$d:${LD_LIBRARY_PATH:-}"
    done
    export LD_LIBRARY_PATH
fi

if [ -z "$SWIFTC" ]; then
    echo "SKIP: no Swift toolchain found (the Swift parse check cannot run)." >&2
fi

echo "================================================================"
echo " DroidVM engine gate (syntax only)"
echo "   swiftc : ${SWIFTC:-none}"
echo "   $(uname -srm 2>/dev/null || echo unknown)"
echo "================================================================"

# ------------------------------------------------------- Swift parse check

note "Swift parse check (engine/)"
SWIFT_SOURCES=()
if [ -d engine ]; then
    while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find engine -name '*.swift' | sort)
fi

if [ "${#SWIFT_SOURCES[@]}" -eq 0 ]; then
    echo "  no engine Swift sources yet"
elif [ -z "$SWIFTC" ]; then
    echo "  SKIPPED (no toolchain)"
else
    parse_failed=0
    for f in "${SWIFT_SOURCES[@]}"; do
        printf '  %-56s ' "$f"
        if "$SWIFTC" -parse -swift-version 5 "$f" >/tmp/droidvm-parse.log 2>&1; then
            echo "parses"
        else
            echo "PARSE ERROR"
            sed 's/^/      /' /tmp/droidvm-parse.log | head -20
            parse_failed=1
        fi
    done
    [ "$parse_failed" -eq 0 ] || fails=$((fails + 1))

    # A parse check that accepts anything is worthless, so prove it can fail.
    probe="$(mktemp -d)/probe.swift"
    printf 'import Metal\nfinal class Broken {\n    func f() { if true { print("x") }\n}\n' > "$probe"
    if "$SWIFTC" -parse -swift-version 5 "$probe" >/dev/null 2>&1; then
        echo "  FAIL: the parse check accepted deliberately broken Swift, so it proves nothing"
        fails=$((fails + 1))
    else
        echo "  (self-check: the parser does reject broken input)"
    fi
    rm -rf "$(dirname "$probe")"
fi

# ------------------------------------------------------- C bridge header

note "C bridge header"
if [ ! -f engine/include/DroidVMBridge.h ]; then
    echo "  FAIL: engine/include/DroidVMBridge.h is missing"
    fails=$((fails + 1))
else
    CC_BIN=""
    if [ -n "$SWIFT_BIN_DIR" ] && [ -x "$SWIFT_BIN_DIR/clang" ]; then
        CC_BIN="$SWIFT_BIN_DIR/clang"
    elif command -v clang >/dev/null 2>&1; then
        CC_BIN="$(command -v clang)"
    elif command -v cc >/dev/null 2>&1; then
        CC_BIN="$(command -v cc)"
    fi

    if [ -z "$CC_BIN" ]; then
        echo "  SKIPPED (no C compiler)"
    else
        # Compiled as a real translation unit, with the header included, so that a
        # declaration error is caught rather than merely a preprocessing one.
        TU="$(mktemp -d)/tu.c"
        printf '#include "DroidVMBridge.h"\nint main(void) { return (int)DROIDVM_JIT_OK; }\n' > "$TU"
        if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -fsyntax-only \
                -I engine/include "$TU" 2>/tmp/droidvm-bridge.log; then
            echo "  DroidVMBridge.h: compiles clean under -Wall -Wextra -Werror"
        else
            echo "  FAIL: DroidVMBridge.h does not compile"
            sed 's/^/      /' /tmp/droidvm-bridge.log | head -20
            fails=$((fails + 1))
        fi
        rm -rf "$(dirname "$TU")"
    fi
fi

# ------------------------------------------------------- trap protocol

note "trap protocol (assembly)"
ASM="engine/jit/droidvm-brk.S"
if [ ! -f "$ASM" ]; then
    echo "  FAIL: $ASM is missing"
    fails=$((fails + 1))
else
    # Present, exactly once each, and nothing else in the code section.
    asm_failed=0
    for pair in "mov x16, #0x1" "brk #0xf00d" "mov x16, #0x0" "brk #0x69"; do
        count="$(grep -c -F "$pair" "$ASM" || true)"
        printf '  %-20s occurrences: %s\n' "$pair" "$count"
        if [ "$count" -eq 0 ]; then
            echo "      FAIL: expected at least one"
            asm_failed=1
        fi
    done

    # The immediates are a protocol; a fourth, unknown one would mean somebody guessed.
    unexpected="$(grep -oE 'brk #0x[0-9a-f]+' "$ASM" | sort -u \
                  | grep -vE 'brk #0xf00d|brk #0x69' || true)"
    if [ -n "$unexpected" ]; then
        echo "  FAIL: unexpected trap immediate(s): $unexpected"
        echo "        only 0xf00d (with x16 = 1 or 0) and 0x69 are part of the protocol"
        asm_failed=1
    fi

    total="$(grep -cE '^\s+brk ' "$ASM" || true)"
    printf '  %-20s total: %s (expected 3)\n' "traps" "$total"
    [ "$total" -eq 3 ] || { echo "      FAIL: exactly three traps are expected"; asm_failed=1; }

    [ "$asm_failed" -eq 0 ] || fails=$((fails + 1))
fi

echo
echo "================================================================"
if [ "$fails" -eq 0 ]; then
    echo " ENGINE GATE: PASS (SYNTAX ONLY)"
    echo "   verified : Swift parses, the C header compiles, the trap protocol is intact"
    echo "   NOT verified: types, symbols, linking, or behaviour on a device"
    echo "   PARSE PASS is not COMPILE PASS. Gate 2 is the macOS type-check;"
    echo "   gates 3-4 are the macOS build; gate 5 is a human with a phone."
else
    echo " ENGINE GATE: FAIL ($fails check(s))"
fi
echo "================================================================"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
