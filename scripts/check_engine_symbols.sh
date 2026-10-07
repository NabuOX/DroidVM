#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Verify that the BUILT engine exports DroidVM's required runtime symbols.
#
#   ./scripts/check_engine_symbols.sh <manifest> <export-list> [<qemu-build-dir>]
#
# WHY THIS IS ITS OWN SCRIPT
#
# It is the only check in this repository that must inspect the FINISHED dylib. A symbol declared
# in a header, or present in an object that never reached the library, satisfies every other gate
# here and still fails at dlopen.
#
# Splitting it out is what makes that rule TESTABLE. While the logic lived inline in
# build_engine_ios.sh -- a script that needs macOS tooling -- the host gate could not exercise it
# at all, so "the gate proves the symbol is in the engine" was an assertion nobody had run. Now
# the host gate hands it a synthetic export list and proves it refuses a missing symbol.
set -euo pipefail

MANIFEST="${1:-}"
EXPORTS="${2:-}"
BUILD_DIR="${3:-}"

if [ -z "$MANIFEST" ] || [ -z "$EXPORTS" ]; then
    echo "usage: $0 <manifest> <export-list> [<qemu-build-dir>]" >&2
    exit 2
fi
[ -f "$MANIFEST" ] || { echo "FAIL: no manifest at $MANIFEST" >&2; exit 1; }
[ -f "$EXPORTS" ]  || { echo "FAIL: no export list at $EXPORTS" >&2; exit 1; }

missing=0
checked=0
while IFS= read -r raw; do
    symbol="$(echo "$raw" | sed 's/#.*//' | tr -d '[:space:]')"
    [ -z "$symbol" ] && continue
    checked=$((checked + 1))
    if grep -qx -- "$symbol" "$EXPORTS"; then
        printf '  %-46s exported by the engine\n' "$symbol"
    else
        printf '  %-46s MISSING FROM ENGINE   <-- declared, never compiled in\n' "$symbol" >&2
        missing=$((missing + 1))
    fi
done < "$MANIFEST"

# A manifest that lists nothing would "pass" while checking nothing.
[ "$checked" -gt 0 ] || {
    echo "FAIL: $MANIFEST lists no symbols; the check would pass vacuously" >&2
    exit 1
}

# And the object must exist. A symbol can only come from a compiled source, so this is what
# separates "wired into Meson" from "copied into the tree and forgotten".
if [ -n "$BUILD_DIR" ]; then
    # GLOB on the suffix, because Meson prefixes the object with its source directory:
    # libcommon.a.p/droidvm_droidvm_qemu_runtime.c.o
    # Matching the bare filename would never find it and the check would fail on a build that
    # compiled the module correctly.
    found="$(find "$BUILD_DIR" -name '*droidvm_qemu_runtime.c.o' 2>/dev/null | head -1)"
    [ -n "$found" ] || {
        echo "FAIL: droidvm_qemu_runtime.c.o was never produced; the Meson integration did not compile it" >&2
        exit 1
    }
    echo "  runtime object compiled into the engine"
fi

[ "$missing" -eq 0 ] || {
    echo "FAIL: $missing engine symbol(s) are not exported by the built dylib" >&2
    exit 1
}
echo "  ENGINE SYMBOLS: PASS ($checked checked)"
