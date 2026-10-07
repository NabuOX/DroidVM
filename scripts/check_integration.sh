#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Regression tests for DroidVM's QEMU build integration.
#
# These are the checks that were previously made by hand, once. They do NOT download or build
# QEMU: a fixture tree holding the three things integrate_engine.sh touches stands in for the
# real one, so the suite is fast enough to run on every host check. The real engine build remains
# gate 3's job.
#
# WHAT IS NOT COVERED HERE, DELIBERATELY
#
# Whether the patch applies to the REAL system/runstate.c. That needs the 136 MB engine source,
# which the host gate must not fetch. It was verified by hand against the exact tree, and gate 3
# re-runs it on every build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE="$WORK/repo"
QEMU="$WORK/qemu"

pass=0
fail=0
check() {
    if [ "$1" = "0" ]; then
        printf '  ok   %s\n' "$2"; pass=$((pass + 1))
    else
        printf '  FAIL %s\n' "$2" >&2; fail=$((fail + 1))
    fi
}

# A stand-in repository: integrate_engine.sh derives its root from its own location, so a copy
# of scripts/ and engine/ is a working repository for these purposes, and nothing here can touch
# the real tree.
mkdir -p "$FAKE"
cp -R "$ROOT/scripts" "$FAKE/scripts"
cp -R "$ROOT/engine"  "$FAKE/engine"
chmod +x "$FAKE/scripts/integrate_engine.sh"

# A stand-in QEMU tree: exactly the three files the integration reads or writes.
mkfixture() {
    rm -rf "$QEMU"; mkdir -p "$QEMU/system"
    cat > "$QEMU/meson.build" <<'EOF'
project('qemu', 'c')
system_ss = ss.source_set()
subdir('system')
EOF
    cat > "$QEMU/system/qemu.symbols" <<'EOF'
{
  qemu_init;
  qemu_main_loop;
  qemu_cleanup;
};
EOF
    # Already carries the markers, so the integration takes its "already patched" branch and the
    # meson and export steps are reached without needing the real 136 MB source.
    cat > "$QEMU/system/runstate.c" <<'EOF'
#include "qemu/osdep.h"
#include "droidvm_qemu_runtime.h"

int qemu_main_loop(void)
{
    int status = EXIT_SUCCESS;

    while (!main_loop_should_exit(&status)) {
        droidvm_runtime_note_loop_iteration();
        main_loop_wait(false);
    }
    droidvm_runtime_note_loop_exited();

    return status;
}
EOF
}

echo "--- build integration (D.1a) ---"

# 0. baseline: the intact integration succeeds.
mkfixture
if bash "$FAKE/scripts/integrate_engine.sh" "$QEMU" >/dev/null 2>&1; then
    check 0 "intact integration succeeds"
else
    check 1 "intact integration succeeds"
fi

# 4. the runtime module reaches Meson, and the subdir is actually added.
if grep -q "droidvm_qemu_runtime.c" "$QEMU/droidvm/meson.build" 2>/dev/null; then
    check 0 "copied meson.build references the runtime module"
else
    check 1 "copied meson.build references the runtime module"
fi
if grep -qE "^subdir\('droidvm'\)" "$QEMU/meson.build"; then
    check 0 "top-level meson.build includes subdir('droidvm')"
else
    check 1 "top-level meson.build includes subdir('droidvm')"
fi
for f in droidvm_qemu_runtime.c droidvm_qemu_runtime.h DroidVMBridge.h meson.build; do
    if [ -f "$QEMU/droidvm/$f" ]; then
        check 0 "copied into the engine tree: $f"
    else
        check 1 "copied into the engine tree: $f"
    fi
done

# 5. idempotency: a second run must succeed and must not double-apply anything.
if bash "$FAKE/scripts/integrate_engine.sh" "$QEMU" >/dev/null 2>&1; then
    check 0 "second run succeeds (idempotent)"
else
    check 1 "second run succeeds (idempotent)"
fi
n="$(grep -cE "^subdir\('droidvm'\)" "$QEMU/meson.build")"
[ "$n" = "1" ] && check 0 "subdir('droidvm') added exactly once" \
               || check 1 "subdir('droidvm') added exactly once (found $n)"
n="$(grep -c "droidvm_runtime_state_get;" "$QEMU/system/qemu.symbols")"
[ "$n" = "1" ] && check 0 "export symbol added exactly once" \
               || check 1 "export symbol added exactly once (found $n)"

# 1, 2, 3. A missing required source must FAIL, not be skipped with a note.
for missing in "qemu-native/droidvm_qemu_runtime.c" \
               "qemu-native/droidvm_qemu_runtime.h" \
               "patches/droidvm-qemu-main-loop.patch"; do
    saved="$WORK/saved"
    mv "$FAKE/engine/$missing" "$saved"
    mkfixture
    if bash "$FAKE/scripts/integrate_engine.sh" "$QEMU" >/dev/null 2>&1; then
        check 1 "missing engine/$missing fails integration"
    else
        check 0 "missing engine/$missing fails integration"
    fi
    mv "$saved" "$FAKE/engine/$missing"
done

# 6. build_engine_ios.sh must consume the engine-symbol manifest.
if grep -q "required-engine-symbols.txt" "$ROOT/scripts/build_engine_ios.sh"; then
    check 0 "build_engine_ios.sh consumes required-engine-symbols.txt"
else
    check 1 "build_engine_ios.sh consumes required-engine-symbols.txt"
fi
if grep -q "check_engine_symbols.sh" "$ROOT/scripts/build_engine_ios.sh"; then
    check 0 "build_engine_ios.sh delegates to the engine-symbol checker"
else
    check 1 "build_engine_ios.sh delegates to the engine-symbol checker"
fi

# 7 and 8. The engine-symbol verification refuses a symbol absent from the FINISHED dylib.
MANIFEST="$ROOT/engine/symbols/required-engine-symbols.txt"
GOOD="$WORK/exports.good"
BAD="$WORK/exports.bad"
printf '%s\n' droidvm_runtime_state_get droidvm_runtime_is_running \
              droidvm_runtime_last_reason droidvm_runtime_note_initialized > "$GOOD"
# Everything except one: exactly the shape of "declared in a header, never compiled in".
grep -v "^droidvm_runtime_is_running$" "$GOOD" > "$BAD"

if bash "$ROOT/scripts/check_engine_symbols.sh" "$MANIFEST" "$GOOD" >/dev/null 2>&1; then
    check 0 "engine-symbol check passes when every symbol is exported"
else
    check 1 "engine-symbol check passes when every symbol is exported"
fi
if bash "$ROOT/scripts/check_engine_symbols.sh" "$MANIFEST" "$BAD" >/dev/null 2>&1; then
    check 1 "engine-symbol check FAILS when a symbol is absent from the dylib"
else
    check 0 "engine-symbol check FAILS when a symbol is absent from the dylib"
fi

# 8, specifically: the checker must read the built artifact, not a declaration. `$GOOD` is a
# bare list of export names, so a checker that consulted the header would pass `$BAD` too.
if grep -q "droidvm_runtime_is_running" "$ROOT/engine/include/DroidVMBridge.h"; then
    check 0 "the omitted symbol IS declared in the header (so the check cannot be reading it)"
else
    check 1 "the omitted symbol IS declared in the header"
fi
# And the object check: a manifest symbol can be exported while the object is absent only if the
# source was linked from somewhere else, which is the failure this catches.
if bash "$ROOT/scripts/check_engine_symbols.sh" "$MANIFEST" "$GOOD" "$WORK/nonexistent-build" \
        >/dev/null 2>&1; then
    check 1 "engine-symbol check FAILS when the runtime object was never compiled"
else
    check 0 "engine-symbol check FAILS when the runtime object was never compiled"
fi
mkdir -p "$WORK/build/obj"; : > "$WORK/build/obj/droidvm_qemu_runtime.c.o"
if bash "$ROOT/scripts/check_engine_symbols.sh" "$MANIFEST" "$GOOD" "$WORK/build" >/dev/null 2>&1; then
    check 0 "engine-symbol check passes when the runtime object is present"
else
    check 1 "engine-symbol check passes when the runtime object is present"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "  integration regression: PASS ($pass checks)"
    exit 0
fi
echo "  integration regression: FAIL ($fail of $((pass + fail)) checks)" >&2
exit 1
