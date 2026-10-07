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
# The IncludeDirs defect: QEMU's SourceSet.add rejects IncludeDirs and accepts Dependency, which
# failed Meson setup on CI with "argument 2 was of type IncludeDirs". The include path must reach
# Meson as a Dependency.
if grep -q "declare_dependency" "$QEMU/droidvm/meson.build"; then
    check 0 "meson.build passes the include path as a Dependency"
else
    check 1 "meson.build passes the include path as a Dependency"
fi
# ...and never as a bare IncludeDirs object, which is the form that failed.
# The exact broken SHAPE: a source set given a bare include-path variable as a second
# argument. Matching "add(...include_directories(" is wrong -- it also matches the correct
# declare_dependency(include_directories: ...) form, because [^)]* crosses an opening paren.
if grep -qE "^[[:space:]]*[a-z_]+_ss\.add\(files\([^)]*\),[[:space:]]*[a-z_]+_inc\)" "$QEMU/droidvm/meson.build"; then
    check 1 "no IncludeDirs object is passed to a source set"
else
    check 0 "no IncludeDirs object is passed to a source set"
fi
# system/runstate.c includes the internal header, so the dependency has to be on the set that also
# contains runstate.c -- not on a private set that is merely merged in.
if grep -q "system_ss.add(declare_dependency" "$QEMU/droidvm/meson.build"; then
    check 0 "the include dependency is on system_ss (the set holding runstate.c)"
else
    check 1 "the include dependency is on system_ss (the set holding runstate.c)"
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
# Derived from the manifest, not hardcoded: a fixed list silently becomes wrong the moment
# a symbol is added, and the failure then looks like a checker bug rather than a stale test.
grep -v '^#' "$MANIFEST" | sed '/^[[:space:]]*$/d' | tr -d ' ' > "$GOOD"
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

# ---------------------------------------------------------------- manifest union (the four false alarms)
#
# Gate 3 failed with "DECLARED IN BRIDGE, ABSENT FROM MANIFEST" for the four runtime symbols,
# because declaration coverage consulted only the app manifest. The fix is the union of both.
UNION_BODY="$WORK/union.body"
sed -n '/^declaration_is_covered() {/,/^}/p' "$ROOT/scripts/build_engine_ios.sh" > "$UNION_BODY"
if [ ! -s "$UNION_BODY" ]; then
    check 1 "declaration_is_covered is extractable"
else
    check 0 "declaration_is_covered is extractable"
    covered() {
        { cat "$UNION_BODY"; printf 'declaration_is_covered "%s" "%s"\n' "$ROOT" "$1"; } | bash
    }

    # App-owned: in required-symbols.txt only.
    covered droidvm_jit_probe \
        && check 0 "app-manifest symbol is covered" \
        || check 1 "app-manifest symbol is covered"

    # Engine-owned: the four that failed in CI.
    for s in droidvm_runtime_state_get droidvm_runtime_is_running \
             droidvm_runtime_last_reason droidvm_runtime_note_initialized; do
        covered "$s" \
            && check 0 "engine-manifest symbol is covered: $s" \
            || check 1 "engine-manifest symbol is covered: $s"
    done

    # A declaration in NEITHER manifest must still fail coverage, or the union would have turned a
    # real gate into a rubber stamp.
    covered droidvm_runtime_not_a_real_symbol \
        && check 1 "a symbol in neither manifest is NOT covered" \
        || check 0 "a symbol in neither manifest is NOT covered"

    # The union must not have leaked engine symbols into the app manifest.
    if grep -q "^droidvm_runtime_is_running$" "$ROOT/engine/symbols/required-symbols.txt"; then
        check 1 "engine-owned symbols were NOT copied into the app manifest"
    else
        check 0 "engine-owned symbols were NOT copied into the app manifest"
    fi
fi

# ---------------------------------------------------------------- QEMU cache invalidation
#
# Gate 3 skipped QEMU on a stamp restored from CI's cache, so an engine built BEFORE D.1a survived
# into SYMBOL VERIFY and the gate reported on an engine that did not contain the integration.
FP_BODY="$WORK/fingerprint.body"
sed -n '/^qemu_integration_fingerprint() {/,/^}/p' "$ROOT/scripts/build_engine_ios.sh" > "$FP_BODY"
if [ ! -s "$FP_BODY" ]; then
    check 1 "qemu_integration_fingerprint is extractable"
else
    check 0 "qemu_integration_fingerprint is extractable"

    FP="$WORK/fprepo"
    mkdir -p "$FP"
    cp -R "$ROOT/scripts" "$FP/scripts"
    cp -R "$ROOT/engine"  "$FP/engine"

    fp() {
        { cat "$FP_BODY"; printf 'qemu_integration_fingerprint "%s"\n' "$FP"; } | bash
    }

    base="$(fp)"
    [ -n "$base" ] || check 1 "the fingerprint is non-empty"
    # 1. identical inputs reuse the stamp.
    if [ "$base" = "$(fp)" ]; then
        check 0 "identical inputs produce an identical fingerprint (stamp reusable)"
    else
        check 1 "identical inputs produce an identical fingerprint (stamp reusable)"
    fi

    # 2-6. every integration input invalidates it.
    for rel in "engine/qemu-native/droidvm_qemu_runtime.c" \
               "engine/qemu-native/droidvm_qemu_runtime.h" \
               "engine/qemu-native/droidvm_qemu_display.c" \
               "engine/patches/droidvm-qemu-main-loop.patch" \
               "engine/qemu-native/meson.build" \
               "scripts/integrate_engine.sh"; do
        saved="$WORK/fp.saved"
        cp "$FP/$rel" "$saved"
        printf '\n/* regression probe */\n' >> "$FP/$rel"
        changed="$(fp)"
        if [ "$changed" != "$base" ]; then
            check 0 "changing $rel invalidates the QEMU stamp"
        else
            check 1 "changing $rel invalidates the QEMU stamp"
        fi
        cp "$saved" "$FP/$rel"
    done

    # The engine symbol manifest is an input too: adding a required export changes the build.
    saved="$WORK/fp.saved"
    cp "$FP/engine/symbols/required-engine-symbols.txt" "$saved"
    printf '\ndroidvm_probe_symbol\n' >> "$FP/engine/symbols/required-engine-symbols.txt"
    if [ "$(fp)" != "$base" ]; then
        check 0 "changing required-engine-symbols.txt invalidates the QEMU stamp"
    else
        check 1 "changing required-engine-symbols.txt invalidates the QEMU stamp"
    fi
    cp "$saved" "$FP/engine/symbols/required-engine-symbols.txt"

    # QEMU source identity is part of it: a different engine is a different build.
    other="$({ cat "$FP_BODY"; printf 'qemu_integration_fingerprint "%s" "qemu-different"\n' "$FP"; } | bash)"
    if [ "$other" != "$base" ]; then
        check 0 "a different QEMU source identity invalidates the QEMU stamp"
    else
        check 1 "a different QEMU source identity invalidates the QEMU stamp"
    fi

    # And a changed file must RESTORE to the same fingerprint, or the check would be one-way.
    if [ "$(fp)" = "$base" ]; then
        check 0 "restoring the inputs restores the fingerprint"
    else
        check 1 "restoring the inputs restores the fingerprint"
    fi
fi

# The integration must be invoked BEFORE the stamp decision, or a cached stamp skips it entirely.
if grep -q 'integrate_engine.sh" "\$SRC/\$QEMU_SRC_NAME"' "$ROOT/scripts/build_engine_ios.sh"; then
    check 0 "integrate_engine.sh is invoked by the engine build"
else
    check 1 "integrate_engine.sh is invoked by the engine build"
fi
if grep -q 'STAMPS/qemu.fingerprint' "$ROOT/scripts/build_engine_ios.sh"; then
    check 0 "the QEMU stamp is guarded by a stored fingerprint"
else
    check 1 "the QEMU stamp is guarded by a stored fingerprint"
fi

# HOST CHECK must syntax-check the build script. It cannot be RUN on the host, so without
# `bash -n` nothing on the host executes or parses it -- which is how an unterminated string in it
# reached CI and failed gate 3.
if grep -q 'bash -n' "$ROOT/scripts/check_host.sh"; then
    check 0 "HOST CHECK syntax-checks the shell scripts"
else
    check 1 "HOST CHECK syntax-checks the shell scripts"
fi
# And this script must actually parse, which the assertion above does not prove by itself.
if bash -n "$ROOT/scripts/build_engine_ios.sh" 2>/dev/null; then
    check 0 "build_engine_ios.sh parses"
else
    check 1 "build_engine_ios.sh parses"
fi

# ---------------------------------------------------------------- stage independence
#
# run_symbols referenced `dir`, which is local to run_qemu. CI invokes the stages as separate
# script runs, so SYMBOL VERIFY died with "dir: unbound variable" -- after QEMU had built
# correctly. Every run_* stage must be independently executable, and this is the test for that
# class rather than for the one instance.

# Extract run_symbols' body structurally: it ends at the first line that does not start with
# whitespace. A textual end anchor was tried first and matched nothing, which quietly turned the
# assertions below into tests of an empty string.
symbols_body() {
    awk '/^run_symbols\(\) \{/ { inside = 1; print; next }
         inside && /^[^ \t]/ { inside = 0 }
         inside { print }' "$ROOT/scripts/build_engine_ios.sh"
}

# The extractor must yield something, or the two assertions that use it pass vacuously.
if [ -n "$(symbols_body)" ]; then
    check 0 "run_symbols body is extractable"
else
    check 1 "run_symbols body is extractable"
fi

STAGE_BODY="$WORK/stages.txt"
# One line per stage function, so a leak is attributed to the function that has it.
awk '/^run_[a-z]+\(\) \{/{fn=$0; next} /^}/{fn=""} fn != "" && fn !~ /run_qemu/ && $0 ~ /\$dir([^a-zA-Z_]|$)/ {print fn": "$0}' \
    "$ROOT/scripts/build_engine_ios.sh" > "$STAGE_BODY"
if [ -s "$STAGE_BODY" ]; then
    echo "  FAIL a stage references the run_qemu-local \$dir:" >&2
    sed 's/^/       /' "$STAGE_BODY" >&2
    fail=$((fail + 1))
else
    check 0 "no stage references the run_qemu-local \$dir"
fi

# SYMBOL VERIFY must derive the QEMU build directory itself rather than inherit one.
if [ "$(symbols_body | grep -c 'local qemu_build_dir=')" -gt 0 ]; then
    check 0 "SYMBOL VERIFY derives the QEMU build directory itself"
else
    check 1 "SYMBOL VERIFY derives the QEMU build directory itself"
fi

# ...and it must actually be handed to the engine-symbol checker, or the object check is skipped.
if [ "$(symbols_body | grep -c '"\$qemu_build_dir"')" -gt 0 ]; then
    check 0 "the engine-symbol checker still receives the QEMU build directory"
else
    check 1 "the engine-symbol checker still receives the QEMU build directory"
fi

# The object check must glob, because Meson prefixes the object with its source directory:
# libcommon.a.p/droidvm_droidvm_qemu_runtime.c.o
if grep -q "name '\*droidvm_qemu_runtime.c.o'" "$ROOT/scripts/check_engine_symbols.sh"; then
    check 0 "the runtime object is matched by suffix glob, not a bare filename"
else
    check 1 "the runtime object is matched by suffix glob, not a bare filename"
fi
# Prove the glob is right by exercising it against the name CI actually produced.
OBJDIR="$WORK/objname/libcommon.a.p"
mkdir -p "$OBJDIR"
: > "$OBJDIR/droidvm_droidvm_qemu_runtime.c.o"
if [ -n "$(find "$WORK/objname" -name '*droidvm_qemu_runtime.c.o' 2>/dev/null)" ]; then
    check 0 "the glob finds Meson's directory-prefixed object name"
else
    check 1 "the glob finds Meson's directory-prefixed object name"
fi

# ---------------------------------------------------------------- CI cache placement
#
# `actions/cache` saves in a post-job step that GitHub SKIPS when the job fails, so a successful
# QEMU build was discarded whenever a later stage failed. The workflow looked correct; only the
# PLACEMENT was wrong, which is the kind of defect that returns silently.
WORKFLOW="$ROOT/.github/workflows/engine-link.yml"
save_line="$(grep -n "save engine cache after a successful QEMU build" "$WORKFLOW" | head -1 | cut -d: -f1)"
symbol_line="$(grep -n "4. SYMBOL VERIFY" "$WORKFLOW" | head -1 | cut -d: -f1)"
if grep -q "actions/cache/restore@v4" "$WORKFLOW" \
   && grep -q "actions/cache/save@v4" "$WORKFLOW" \
   && [ -n "$save_line" ] && [ -n "$symbol_line" ] && [ "$save_line" -lt "$symbol_line" ]; then
    check 0 "engine cache: explicit restore, and save before SYMBOL VERIFY (line $save_line)"
else
    check 1 "engine cache: explicit restore, and save before SYMBOL VERIFY (save=${save_line:-none} symbol=${symbol_line:-none})"
fi

# The display listener is QEMU-private source: it must be COMPILED by QEMU's build, not merely
# copied into the tree, and copied rather than assumed present.
if grep -q "droidvm_qemu_display.c" "$QEMU/droidvm/meson.build"; then
    check 0 "meson.build compiles the display listener"
else
    check 1 "meson.build compiles the display listener"
fi
if [ -f "$QEMU/droidvm/droidvm_qemu_display.c" ]; then
    check 0 "the integration copies the display listener into the engine tree"
else
    check 1 "the integration copies the display listener into the engine tree"
fi
# And it must stay OUT of the app target, or APP LINK fails on QEMU's headers again.
if grep -q '"qemu-native/\*\*"' "$ROOT/app/project.yml"; then
    check 0 "the display listener stays out of the Xcode app target"
else
    check 1 "the display listener stays out of the Xcode app target"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "  integration regression: PASS ($pass checks)"
    exit 0
fi
echo "  integration regression: FAIL ($fail of $((pass + fail)) checks)" >&2
exit 1
