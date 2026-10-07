#!/bin/bash
# DroidVM: wire the engine into QEMU's source tree, and maintain the export list.
#
#   ./scripts/integrate_engine.sh <path-to-qemu-source-tree>
#
# STATUS: PREPARED, NEVER RUN. Called by scripts/build_engine_ios.sh during gate 3. There is no
# macOS runner yet, so this has never executed. Treat it as a specification of the steps.
#
# WHY THIS EXISTS AS A SEPARATE STEP
#
# QEMU cannot be vendored into this repository: it is fetched and cross-compiled. DroidVM's own
# engine sources therefore have to be copied into QEMU's tree and wired into its build, which
# means three things have to keep agreeing -- the copies, the meson targets, and the export
# list. Doing that by hand once is fine; doing it on every build is how a stale copy ships.
#
# THE EXPORT LIST IS THE PART THAT MATTERS
#
# QEMU's shared-library build exports only the symbols named in `system/qemu.symbols`. A symbol
# missing from that list **links successfully and fails at `dlopen`**, and a symbol left in it
# after the code is gone fails differently. Both are confusing, and neither is caught by a
# compile. So this stage prunes names that no longer exist and adds names that do, rather than
# appending.
#
# Adapted from the reference implementation's integration script; see THIRD_PARTY.md. The
# reasoning above is that script's, and it is the reason this one exists as its own step.
#
# NOT CALLED YET, AND THAT IS DELIBERATE
#
# scripts/build_engine_ios.sh does not invoke this, because at this stage DroidVM's bridge
# compiles into the APP target and nothing needs to live inside QEMU's tree.
#
# It will be needed, and the reason is worth naming rather than rediscovering. The display
# listener is a QEMU `DisplayChangeListener`, registered with QEMU's display system, and the
# six counters are written from QEMU's callbacks -- so the listener and the counters must be in
# the same image. That means moving the bridge into the dylib and having the Swift adapters
# resolve `droidvm_*` through `dlsym` exactly as they resolve `qemu_*`.
#
# Copying the bridge into QEMU's tree first would put two sets of counters in one process, and
# the app would read the wrong one. So the order is: prove the link (Level C), then move the
# bridge, then make the machine run.
set -euo pipefail

QEMU_TREE="${1:-}"
if [ -z "$QEMU_TREE" ] || [ ! -d "$QEMU_TREE" ]; then
    echo "usage: $0 <path-to-qemu-source-tree>" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"

echo "==> integrating $ENGINE into $QEMU_TREE"

# ---------------------------------------------------------------- sources
#
# The C and assembly that must live inside QEMU's tree, because they include QEMU's own
# headers and are compiled by its build. The Swift adapters are NOT copied: they compile in the
# app target and reach this code only through the bridge header.
WIRED_SOURCES=(
    "jit/droidvm_jit.c"
    "jit/droidvm-brk.S"
    "display/droidvm-display.c"
    "display/droidvm-display-gl.c"
    "include/DroidVMBridge.h"
)

copied=0
for rel in "${WIRED_SOURCES[@]}"; do
    src="$ENGINE/$rel"
    if [ ! -f "$src" ]; then
        echo "  absent, skipped: engine/$rel"
        continue
    fi
    # The include directory is flattened: QEMU's build expects headers where it is told to look.
    case "$rel" in
        include/*) dest="$QEMU_TREE/droidvm/$(basename "$rel")" ;;
        *)         dest="$QEMU_TREE/droidvm/$rel" ;;
    esac
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest"
    echo "  copied engine/$rel -> ${dest#$QEMU_TREE/}"
    copied=$((copied + 1))
done
echo "  $copied file(s) wired in"

if [ "$copied" -eq 0 ]; then
    echo
    echo "NOTE: no C sources exist under engine/ yet. The Swift adapters are in place and their"
    echo "      ABI is verified on the host (scripts/check_bridge_interop.sh), but the C side of"
    echo "      the bridge -- the trap, vm_remap, the DisplayChangeListener -- is a Phase 2"
    echo "      deliverable. Until it exists, gate 3 cannot produce a dylib and says so."
fi

# ---------------------------------------------------------------- export list

SYMBOLS_FILE="$QEMU_TREE/system/qemu.symbols"
echo
echo "==> export list: ${SYMBOLS_FILE#$QEMU_TREE/}"

# The symbols DroidVM calls, and only those. Everything else QEMU exports is its own business.
WANTED=(
    qemu_init
    qemu_main_loop
    qemu_cleanup
    droidvm_jit_probe
    droidvm_jit_capture
    droidvm_jit_release
    droidvm_jit_last_reason
    droidvm_display_register
    droidvm_display_read
    droidvm_display_is_attached
    droidvm_display_set_attached
    droidvm_display_counters_sizeof
    droidvm_serial_bytes_written
)

if [ ! -f "$SYMBOLS_FILE" ]; then
    echo "  ERROR: no export list at system/qemu.symbols" >&2
    exit 1
fi

# Which of the wanted symbols actually exist in the tree? A name in the list that nothing
# defines is a name that must not be exported, and a name that is defined but absent from the
# list is a name that will fail at dlopen.
present=(); absent=()
for symbol in "${WANTED[@]}"; do
    if grep -rqE "^[a-zA-Z_].*\b${symbol}\s*\(" "$QEMU_TREE" --include='*.c' --include='*.h' \
            2>/dev/null; then
        present+=("$symbol")
    else
        absent+=("$symbol")
    fi
done

echo "  defined in the tree : ${#present[@]}"
for symbol in "${present[@]}"; do
    if grep -qx "$symbol" "$SYMBOLS_FILE" 2>/dev/null; then
        printf '    ok       %s\n' "$symbol"
    else
        printf '    ADDING   %s\n' "$symbol"
        echo "$symbol" >> "$SYMBOLS_FILE"
    fi
done

echo "  not yet defined     : ${#absent[@]}"
for symbol in "${absent[@]}"; do
    printf '    absent   %s\n' "$symbol"
    if grep -qx "$symbol" "$SYMBOLS_FILE" 2>/dev/null; then
        printf '    PRUNING  %s (listed but nothing defines it)\n' "$symbol"
        grep -vx "$symbol" "$SYMBOLS_FILE" > "$SYMBOLS_FILE.tmp"
        mv "$SYMBOLS_FILE.tmp" "$SYMBOLS_FILE"
    fi
done

echo
echo "==> integration complete"
echo "  Next: build QEMU with --enable-shared-lib, then check the dylib's exports."
echo "  A symbol missing from the list links fine and fails at dlopen; build_engine_ios.sh"
echo "  verifies the built dylib rather than trusting this step."
