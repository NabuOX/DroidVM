#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Wire DroidVM's QEMU integration into the engine's source tree.
#
#   ./scripts/integrate_engine.sh <path-to-qemu-source-tree>
#
# Called by scripts/build_engine_ios.sh before QEMU is configured.
#
# WHAT THIS FIXES
#
# The previous version listed source paths that did not exist (`display/droidvm-display.c`,
# `display/droidvm-display-gl.c`), reported them as "absent, skipped", and never wired anything
# into Meson. Three separate ways for the build to succeed while integrating nothing: the files
# were never copied, never compiled, and the only symptom was a symbol missing at dlopen.
#
# This version copies only files that exist, FAILS LOUDLY if a required one is absent, applies
# the main-loop patch, and adds the Meson subdir that actually compiles the module.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It does not copy engine/native/*.c into QEMU, and it does not touch the display listener.
# The runtime state has exactly ONE owner -- the QEMU dylib -- because a second copy in the app
# would mean the app reading a value nothing ever writes. The display listener is a separate
# integration with its own ownership question.
set -euo pipefail

QEMU_TREE="${1:-}"
if [ -z "$QEMU_TREE" ] || [ ! -d "$QEMU_TREE" ]; then
    echo "usage: $0 <path-to-qemu-source-tree>" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"
PATCHES="$ENGINE/patches"
PATCH_NAME="droidvm-qemu-main-loop.patch"

fail() { echo "  FAIL: $*" >&2; exit 1; }

echo "==> integrating DroidVM's QEMU runtime confirmation into $QEMU_TREE"

# ---------------------------------------------------------------- 1. required sources
#
# Required means required. A missing integration source is a broken build, not a note in a log.

REQUIRED_SOURCES=(
    "qemu-native/droidvm_qemu_runtime.c"
    "qemu-native/droidvm_qemu_runtime.h"
    "qemu-native/meson.build"
    "include/DroidVMBridge.h"
)

for rel in "${REQUIRED_SOURCES[@]}"; do
    [ -f "$ENGINE/$rel" ] || fail "required integration source is missing: engine/$rel"
done
echo "  all ${#REQUIRED_SOURCES[@]} required source(s) present"

# ---------------------------------------------------------------- 2. copy

DEST="$QEMU_TREE/droidvm"
rm -rf "$DEST"
mkdir -p "$DEST"

cp -f "$ENGINE/qemu-native/droidvm_qemu_runtime.c" "$DEST/"
cp -f "$ENGINE/qemu-native/droidvm_qemu_runtime.h" "$DEST/"
cp -f "$ENGINE/qemu-native/meson.build"            "$DEST/"
# Flattened: Meson adds this directory to the include path, and the module includes the header
# by name.
cp -f "$ENGINE/include/DroidVMBridge.h"            "$DEST/"
echo "  copied $(ls -1 "$DEST" | wc -l | tr -d ' ') file(s) into ${DEST#$QEMU_TREE/}"

for f in droidvm_qemu_runtime.c droidvm_qemu_runtime.h meson.build DroidVMBridge.h; do
    [ -f "$DEST/$f" ] || fail "copy did not produce $DEST/$f"
done

# ---------------------------------------------------------------- 3. main-loop patch

[ -f "$PATCHES/$PATCH_NAME" ] || fail "required patch is missing: engine/patches/$PATCH_NAME"

RUNSTATE="$QEMU_TREE/system/runstate.c"
[ -f "$RUNSTATE" ] || fail "no system/runstate.c in $QEMU_TREE; the engine tree is not QEMU 10"

if grep -q "droidvm_runtime_note_loop_iteration" "$RUNSTATE"; then
    echo "  runstate.c already carries the loop markers"
else
    echo "  applying $PATCH_NAME"
    ( cd "$QEMU_TREE" && patch -p1 -N < "$PATCHES/$PATCH_NAME" ) \
        || fail "$PATCH_NAME did not apply to system/runstate.c"
fi

# Both markers, verified by name. The entry marker must be INSIDE the loop body: if it moved
# above the `while`, a loop that exits immediately would report as running.
grep -q "droidvm_runtime_note_loop_iteration" "$RUNSTATE" \
    || fail "the entry marker is not in system/runstate.c after patching"
grep -q "droidvm_runtime_note_loop_exited" "$RUNSTATE" \
    || fail "the exit marker is not in system/runstate.c after patching"
echo "  loop markers verified in system/runstate.c"

# ---------------------------------------------------------------- 4. Meson wiring

TOP_MESON="$QEMU_TREE/meson.build"
[ -f "$TOP_MESON" ] || fail "no top-level meson.build in $QEMU_TREE"

if grep -qE "^subdir\('droidvm'\)" "$TOP_MESON"; then
    echo "  meson.build already wired"
else
    # `subdir('system')` is where QEMU adds the softmmu sources to `system_ss`, and `system_ss`
    # is what feeds the shared library. Adding ours after it means `system_ss` exists and the
    # library is defined later. Anywhere else and the source set is empty or the variable is
    # undefined.
    grep -q "system_ss = ss.source_set()" "$TOP_MESON" \
        || fail "cannot find 'system_ss = ss.source_set()' in the QEMU meson.build; this tree's layout is not the one this integration was written for"
    grep -qE "^subdir\('system'\)" "$TOP_MESON" \
        || fail "cannot find subdir('system') in the QEMU meson.build"

    python3 - "$TOP_MESON" <<'PYEOF'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8").read()
anchor = "subdir('system')"
i = t.index(anchor)
end = t.index("\n", i) + 1
t = t[:end] + "\nsubdir('droidvm')\n" + t[end:]
io.open(p, "w", encoding="utf-8", newline="\n").write(t)
PYEOF
    grep -qE "^subdir\('droidvm'\)" "$TOP_MESON" || fail "meson wiring did not take"
    echo "  subdir('droidvm') added after subdir('system')"
fi

# ---------------------------------------------------------------- 5. export list
#
# QEMU's shared build exports ONLY the names in system/qemu.symbols. A symbol missing from it
# links perfectly and fails at dlopen, which is why this is maintained here rather than trusted.
#
# The file is a linker version script: `{ sym; sym; ... };`. Appending after the closing brace
# produces an invalid script, so names go INSIDE the block.

SYMBOLS_FILE="$QEMU_TREE/system/qemu.symbols"
[ -f "$SYMBOLS_FILE" ] || fail "no system/qemu.symbols in $QEMU_TREE"

# Queried by the app, and the one marker the app calls.
WANTED=(
    droidvm_runtime_state_get
    droidvm_runtime_is_running
    droidvm_runtime_last_reason
    droidvm_runtime_note_initialized
)

added=0
for symbol in "${WANTED[@]}"; do
    if grep -qE "^[[:space:]]*${symbol};" "$SYMBOLS_FILE"; then
        continue
    fi
    python3 - "$SYMBOLS_FILE" "$symbol" <<'PYEOF'
import io, sys
path, symbol = sys.argv[1], sys.argv[2]
lines = io.open(path, encoding="utf-8").read().splitlines(True)
# Insert before the LAST line that closes the block.
for i in range(len(lines) - 1, -1, -1):
    if lines[i].strip() in ("};", "}"):
        lines.insert(i, "  %s;\n" % symbol)
        break
else:
    raise SystemExit("could not find the closing brace of the export list")
io.open(path, "w", encoding="utf-8", newline="\n").writelines(lines)
PYEOF
    echo "  ADDED to export list: $symbol"
    added=$((added + 1))
done
[ "$added" -eq 0 ] && echo "  export list already complete"

for symbol in "${WANTED[@]}"; do
    grep -qE "^[[:space:]]*${symbol};" "$SYMBOLS_FILE" \
        || fail "$symbol is not in system/qemu.symbols; it would fail at dlopen"
done
echo "  ${#WANTED[@]} runtime symbol(s) verified present in the export list"

echo
echo "==> integration complete"
echo "  The build now compiles droidvm/droidvm_qemu_runtime.c into the engine and exports the"
echo "  runtime query symbols. scripts/build_engine_ios.sh verifies the BUILT dylib rather than"
echo "  trusting this step -- a symbol listed here and not compiled still fails there."
