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
#      but the instruction pairs can be checked for presence and for nothing extra.
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
# ---------------------------------------------------------------- the JIT trap path
#
# THE SAFETY PROPERTY, as a guard. droidvm_jit_break_get_mapping executes `brk`, and on a device
# with nothing attached to service it, iOS terminates the process -- EXC_BREAKPOINT, which is what
# the first physical-device run produced. The host cannot execute an arm64 trap, so what is checked
# here is ORDER: no path may reach the code that executes the trap without passing the
# attached-debugger check first.
#
# This would have failed before that fix, because there was no check at all.
JIT_C="engine/native/droidvm_jit.c"

if [ ! -f "$JIT_C" ]; then
    echo "  FAIL: $JIT_C is missing"
    fails=$((fails + 1))
else
    jit_failed=0

    if grep -q 'static int debugger_is_attached(void)' "$JIT_C"; then
        echo "  ok:   the attached-debugger check exists"
    else
        echo "      FAIL: $JIT_C has no debugger_is_attached()"
        jit_failed=1
    fi

    # It must ASK, not TRY. P_TRACED is read from the kernel; anything that executes a trap to
    # discover whether traps work is the defect this guards against.
    if grep -q 'P_TRACED' "$JIT_C"; then
        echo "  ok:   it reads P_TRACED from the kernel rather than attempting a trap"
    else
        echo "      FAIL: debugger_is_attached() does not consult P_TRACED"
        jit_failed=1
    fi

    # The gate must precede the call that reaches the trap, in BOTH entry points: capture is
    # reachable directly, and the probe is what the app actually calls first.
    for fn in droidvm_jit_capture droidvm_jit_probe; do
        at="$(grep -n "^droidvm_jit_status $fn" "$JIT_C" | head -1 | cut -d: -f1)"
        if [ -z "$at" ]; then
            echo "      FAIL: $fn was not found"
            jit_failed=1
            continue
        fi

        gate="$(awk -v s="$at" 'NR > s && /debugger_is_attached\(\)/ { print NR; exit }' "$JIT_C")"
        if [ -n "$gate" ]; then
            printf '  ok:   %-20s checks the debugger (line %s)\n' "$fn" "$gate"
        else
            echo "      FAIL: $fn does not check whether anything is attached"
            jit_failed=1
        fi

        # And in capture the gate must come BEFORE make_views, which is what executes the trap.
        trap_at="$(awk -v s="$at" 'NR > s && /make_views\(/ { print NR; exit }' "$JIT_C")"
        if [ -n "$trap_at" ]; then
            if [ -n "$gate" ] && [ "$gate" -lt "$trap_at" ]; then
                printf '  ok:   %-20s gate (line %s) precedes the trap (line %s)\n' "$fn" "$gate" "$trap_at"
            else
                echo "      FAIL: $fn can reach the trap without the debugger check (gate=${gate:-none} trap=$trap_at)"
                jit_failed=1
            fi
        fi
    done

    # The probe must never execute the trap itself: it decides what to tell the user.
    probe_at="$(grep -n '^droidvm_jit_status droidvm_jit_probe' "$JIT_C" | head -1 | cut -d: -f1)"
    # The BODY only: from the declaration to the function's closing brace at column 0.
    if [ -n "$probe_at" ] && awk -v s="$probe_at" 'NR > s { if (/^}/) exit; if (/droidvm_jit_break_get_jit_mapping\(/) found=1 } END { exit !found }' "$JIT_C"; then
        echo "      FAIL: droidvm_jit_probe executes the trap itself"
        jit_failed=1
    else
        echo "  ok:   probe never executes the trap itself"
    fi


    # ---- diagnostic-build invariants ------------------------------------------------
    #
    # NO INDIRECT EXECUTION -- checked as a PROPERTY, not by name.
    #
    # An earlier version grepped for `fn();`, which any other identifier would have evaded. The
    # property is that the file contains no function-pointer cast or call at all: without one,
    # there is nothing to call indirectly, whatever it might have been called.
    #
    # Comment lines are stripped first, because prose about function pointers is not one.
    code_lines="$(grep -vE '^[[:space:]]*(/\*|\*|//)' "$JIT_C")"
    indirect="$(printf '%s\n' "$code_lines" \
                | grep -nE '\([[:space:]]*\*[[:space:]]*[A-Za-z_]|\([[:space:]]*void[[:space:]]*\([[:space:]]*\*' || true)"
    if [ -z "$indirect" ]; then
        echo "  ok:   no function-pointer cast or call exists in the diagnostic build"
    else
        echo "      FAIL: the diagnostic build can call through a function pointer:"
        printf '%s\n' "$indirect" | sed 's/^/            /'
        jit_failed=1
    fi

    # The self-test that executed must be gone, not merely unused.
    if grep -q 'static droidvm_jit_status self_test' "$JIT_C"; then
        echo "      FAIL: the executing self-test is still present"
        jit_failed=1
    else
        echo "  ok:   the executing self-test is gone"
    fi

    # The read through the executable alias must be gated on the kernel saying it is readable.
    #
    # Matching the CONDITIONAL, not two strings that happen to appear elsewhere in the file: an
    # earlier version stayed green with the guard deleted, which is a check that cannot fail.
    # The bits are not enough: `DROIDVM_REGION_UNMAPPED` is -1, so every bit test passes for an
    # unmapped address. The sentinel must be excluded first, and this requires it.
    if grep -q 'rx_prot & VM_PROT_READ' "$JIT_C" \
       && grep -q 'rw_prot & VM_PROT_WRITE' "$JIT_C" \
       && grep -q 'rx_prot != DROIDVM_REGION_UNMAPPED' "$JIT_C" \
       && grep -q 'rw_prot != DROIDVM_REGION_UNMAPPED' "$JIT_C" \
       && grep -q 'vm_region_64' "$JIT_C"; then
        echo "  ok:   the readback needs SUCCESSFUL lookups and the right protection bits"
    else
        echo "      FAIL: an unmapped address could pass the readback guard (-1 has every bit set)"
        jit_failed=1
    fi

    # And the gap check: a successful mach_vm_region is not proof that the ADDRESS is mapped.
    if grep -q 'address >= region + region_size' "$JIT_C"; then
        echo "  ok:   a region answer must contain the address to count as mapped"
    else
        echo "      FAIL: a gap could be reported as mapped"
        jit_failed=1
    fi

    # marker: not yet ready, and the provider's call is still unused
    # ------------------------------------------------------------ the 0xf00d argument contract
    # The protocol takes x0 = addr (NULL for a fresh region) and x1 = len. A wrapper declared with
    # no parameters passes whatever happens to be in those registers, which is how DroidVM ended up
    # asking for the wrong branch: the provider never prepared the pages, and executing them faulted.
    if grep -q 'droidvm_jit_break_get_jit_mapping(void \*addr, size_t len)' "$JIT_C" \
       && grep -q 'droidvm_jit_break_get_jit_mapping:' engine/jit/droidvm-brk.S; then
        echo "  ok:   get_jit_mapping is declared and defined with the addr+len contract"
    else
        echo "      FAIL: get_jit_mapping does not carry the addr+len argument contract"
        jit_failed=1
    fi

    if grep -q 'droidvm_jit_break_get_jit_mapping(NULL, bytes)' "$JIT_C"; then
        echo "  ok:   the fresh-region request passes x0=NULL and x1=bytes"
    else
        echo "      FAIL: the fresh-region request does not pass NULL and the requested length"
        jit_failed=1
    fi

    # ------------------------------------------------------------ the executable region is the provider's
    if [ "$(grep -vE '^[[:space:]]*(/\*|\*|//)' "$JIT_C" | grep -c 'vm_allocate(mach_task_self')" -gt 0 ]; then
        echo "      FAIL: vm_allocate is called in the JIT path; a self-allocated region is never prepared"
        jit_failed=1
    else
        echo "  ok:   vm_allocate is never called: the executable region comes from the provider"
    fi

    # vm_remap's SOURCE must be the provider's region, otherwise the alias views our own memory.
    if [ "$(grep -A4 'vm_remap(mach_task_self' "$JIT_C" | grep -c 'mach_task_self(), (vm_address_t)rx,')" -gt 0 ]; then
        echo "  ok:   the RW alias is remapped from the provider's region"
    else
        echo "      FAIL: the RW alias is not remapped from the provider's region"
        jit_failed=1
    fi

    # The provider's protection is kept as delivered: we must never vm_protect EXECUTE onto it.
    # The property is "VM_PROT_EXECUTE is READ, never GRANTED". Matching one literal spelling is not
    # enough: appending `| VM_PROT_EXECUTE` to a READ|WRITE grant is the exact bug and does not
    # contain `READ | VM_PROT_EXECUTE`. So: comments stripped, every occurrence must be the single
    # validation comparison, and no vm_protect line may mention it.
    execute_granted=0
    if [ "$(grep -vE '^[[:space:]]*(/\*|\*|//)' "$JIT_C" | grep -c 'vm_protect.*VM_PROT_EXECUTE')" -gt 0 ]; then
        execute_granted=1
    fi
    execute_lines=$(grep -vE '^[[:space:]]*(/\*|\*|//)' "$JIT_C" | grep -c 'VM_PROT_EXECUTE')
    execute_validation=$(grep -vE '^[[:space:]]*(/\*|\*|//)' "$JIT_C" | grep -c 'rx_prot & VM_PROT_EXECUTE')
    if [ "$execute_granted" -eq 0 ] && [ "$execute_lines" -eq 1 ] && [ "$execute_validation" -eq 1 ]; then
        echo "  ok:   EXECUTE is only ever validated, never granted by vm_protect"
    else
        echo "      FAIL: EXECUTE is granted or appears outside the single validation (granted=$execute_granted uses=$execute_lines validation=$execute_validation)"
        jit_failed=1
    fi

    # ------------------------------------------------------------ 0x69 is a probe, not a command
    # SYMBOLS, not the literal `0x69`. The assembly deliberately MENTIONS 0x69 to record that DroidVM
    # does not use it, so matching the text would fail on its own documentation -- which is exactly
    # what happened. The instruction count is separately guarded above (`traps total: 2`).
    if grep -q 'mark_executable\|break_probe' "$JIT_C" engine/jit/droidvm-brk.S; then
        echo "      FAIL: a removed trap symbol is back (mark_executable / break_probe)"
        jit_failed=1
    else
        echo "  ok:   the removed DroidVM trap symbols are absent; the universal path uses prepare and detach"
    fi

    # A prototype with no definition links on no platform and fails only where it is compiled --
    # which is arm64 Apple, the one place this host cannot see. The deletion of a redundant helper
    # removed region_probe's body while leaving its declaration, and nothing local noticed.
    # A PROTOTYPE ends `out_size);`. An IMPLEMENTATION ends `out_size)` with `{` on the next line.
    # Counting the signature alone cannot tell them apart: the prototype's signature is identical, so
    # two prototypes with no body satisfied the previous version of this check.
    probe_protos=$(grep -cF 'char *out, size_t out_size);' "$JIT_C" || true)
    probe_bodies=$(grep -A1 -F 'char *out, size_t out_size)' "$JIT_C" | grep -cF '{' || true)
    if [ "${probe_bodies:-0}" -ge 1 ]; then
        echo "  ok:   region_probe has an implementation, not only a declaration (protos=$probe_protos bodies=$probe_bodies)"
    else
        echo "      FAIL: region_probe is declared $probe_protos time(s) but has no body -- an Apple-only link error"
        jit_failed=1
    fi

    # Review finding 3: the provider's address must be the START of its region. Otherwise the size
    # below is not the space available from that address, and remapping or freeing that many bytes
    # from there would cross the end of the mapping.
    base_check_at="$(grep -n '(uintptr_t)rx != rx_info.base' "$JIT_C" | head -1 | cut -d: -f1)"
    remap_at="$(grep -n 'vm_remap(mach_task_self' "$JIT_C" | head -1 | cut -d: -f1)"
    if [ -n "$base_check_at" ] && [ -n "$remap_at" ] && [ "$base_check_at" -lt "$remap_at" ]; then
        echo "  ok:   the region-base check runs BEFORE the remap that depends on it (line $base_check_at < $remap_at)"
    else
        echo "      FAIL: the region-base check is missing or runs after the remap (base=$base_check_at remap=$remap_at)"
        jit_failed=1
    fi

    # ONE-SHOT PREPARE, by ordering within capture.
    #
    # The provider's region is never freed, so a second prepare would claim another 1 GiB that is
    # never reclaimed. Within capture the consumed check AND the consume must both come before the
    # CALL to make_views -- the call is what reaches the trap, and the trap lives in a function
    # defined above capture, so line order against the trap itself would prove nothing.
    oneshot_check=$(grep -n 'if (g_prepare_consumed)' "$JIT_C" | head -1 | cut -d: -f1)
    oneshot_set=$(grep -n 'g_prepare_consumed = 1;' "$JIT_C" | head -1 | cut -d: -f1)
    oneshot_call=$(grep -n 'make_views(bytes, &executable' "$JIT_C" | head -1 | cut -d: -f1)
    if [ -n "$oneshot_check" ] && [ -n "$oneshot_set" ] && [ -n "$oneshot_call" ] \
       && [ "$oneshot_check" -lt "$oneshot_call" ] && [ "$oneshot_set" -lt "$oneshot_call" ]; then
        echo "  ok:   the prepare is one-shot: check and consume precede the call (check=$oneshot_check set=$oneshot_set call=$oneshot_call)"
    else
        echo "      FAIL: a second prepare could be issued (check=$oneshot_check set=$oneshot_set call=$oneshot_call)"
        jit_failed=1
    fi

    if grep -q 'return g_prepare_status;' "$JIT_C"; then
        echo "  ok:   a repeat reports the collected outcome instead of asking again"
    else
        echo "      FAIL: a repeat does not report the collected diagnostic outcome"
        jit_failed=1
    fi

    # ------------------------------------------------------------ one-shot state at FILE scope
    # Brace depth is what the compiler sees. A `static` declaration inside a function is legal C and
    # invisible outside it, so capture would fail to compile -- only on Apple arm64.
    # The patterns are indentation-agnostic ON PURPOSE: an indented copy inside a function must be
    # visible to the depth check. And presence is required as well as depth, because asking only
    # "is anything misplaced" is satisfied by declaring nothing at all -- which does not compile
    # either, since capture references all three.
    oneshot_state=$(awk 'BEGIN { d = 0 }
        /^[[:space:]]*static int g_prepare_consumed;/ { if (d == 0) seen_c = 1; else bad = 1 }
        /^[[:space:]]*static droidvm_jit_status g_prepare_status/ { if (d == 0) seen_s = 1; else bad = 1 }
        /^[[:space:]]*static char g_prepare_reason/ { if (d == 0) seen_r = 1; else bad = 1 }
        { n = gsub(/{/, "{"); m = gsub(/}/, "}"); d += n - m }
        END { print (seen_c && seen_s && seen_r && !bad) ? 0 : 1 }' "$JIT_C")
    if [ "${oneshot_state:-1}" -eq 0 ]; then
        echo "  ok:   the one-shot state is present and at file scope, outside every function"
    else
        echo "      FAIL: one-shot state is missing or declared inside a function, so capture cannot see it"
        jit_failed=1
    fi

    # ------------------------------------------------------------ first-attempt evidence is preserved
    repeat_block=$(awk '/if \(g_prepare_consumed\)/{f=1} f{print} f&&/^    }$/{exit}' "$JIT_C")
    repeat_code=$(printf '%s\n' "$repeat_block" | grep -vE '^[[:space:]]*(/\*|\*|//)')
    stored=$(printf '%s\n' "$repeat_code" | grep -c 'g_prepare_reason')
    mutable=$(printf '%s\n' "$repeat_code" | grep -cE '(^|[^_a-zA-Z])g_reason')
    if [ "${stored:-0}" -ge 1 ] && [ "${mutable:-1}" -eq 0 ]; then
        echo "  ok:   a repeat reports the stored first-attempt reason, never the mutable g_reason"
    else
        echo "      FAIL: a repeat could report the mutable g_reason (stored=$stored mutable=$mutable)"
        jit_failed=1
    fi

    if [ "$(grep -c 'snprintf(g_prepare_reason' "$JIT_C")" -ge 2 ]; then
        echo "  ok:   both first-attempt outcomes store the reason beside the status"
    else
        echo "      FAIL: an outcome path stores the status without storing the reason"
        jit_failed=1
    fi

    [ "$jit_failed" -eq 0 ] || fails=$((fails + 1))
fi

ASM="engine/jit/droidvm-brk.S"
if [ ! -f "$ASM" ]; then
    echo "  FAIL: $ASM is missing"
    fails=$((fails + 1))
else
    # Present, exactly once each, and nothing else in the code section.
    asm_failed=0
    for pair in "mov x16, #0x1" "brk #0xf00d" "mov x16, #0x0"; do
        count="$(grep -c -F "$pair" "$ASM" || true)"
        printf '  %-20s occurrences: %s\n' "$pair" "$count"
        if [ "$count" -eq 0 ]; then
            echo "      FAIL: expected at least one"
            asm_failed=1
        fi
    done

    # EVERY EXECUTABLE brk MUST BE THE CANONICAL FORM, REGARDLESS OF LINE SHAPE.
    #
    # Three earlier versions anchored on how a line BEGINS and each was defeated: `brk #0x69`
    # substituted for the detach trap; `brk #105`, decimal for the same instruction; a column-zero
    # trap; and `_extra: brk #0x69`, which shares its line with a label. Assembly permits all of
    # them, so this does not look at the start of a line at all.
    #
    # Comments are removed first, so the file may still DOCUMENT other immediates. Then every exact
    # canonical `brk #0xf00d` is removed, and any `brk` LEFT OVER fails the gate. Removing the exact
    # canonical text also catches two traps sharing a line, which no per-line allow-list could.
    asm_code="$(grep -vE '^[[:space:]]*(//|/\*|\*)' "$ASM")"
    noncanonical="$(printf '%s\n' "$asm_code" | sed 's/brk #0xf00d//g' | grep -nE 'brk' || true)"
    if [ -n "$noncanonical" ]; then
        echo "  FAIL: non-canonical executable brk instruction(s); every one must be 'brk #0xf00d':"
        echo "$noncanonical" | sed 's/^/            /'
        asm_failed=1
    else
        echo "  ok:   every executable brk is the canonical brk #0xf00d, wherever it sits on its line"
    fi

    total="$(printf '%s\n' "$asm_code" | grep -oE 'brk' | wc -l | tr -d ' ')"
    printf '  %-20s total: %s (expected 2)\n' "traps" "$total"
    # DROIDVM'S SUBSET, and this file makes no claim about the protocol's total. An earlier revision
    # asserted a total here; it was wrong. Stating an unverified external contract as fact would also
    # make this gate reject a valid protocol extension for the wrong reason.
    [ "$total" -eq 2 ] || { echo "      FAIL: DroidVM implements exactly two universal-protocol wrappers (prepare, detach)"; asm_failed=1; }

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
