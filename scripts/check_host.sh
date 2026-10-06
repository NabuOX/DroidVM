#!/bin/bash
# DroidVM host check. Runs on the development machine -- Windows via WSL, Linux, or
# macOS -- with nothing but a Swift toolchain and Python 3.
#
#   ./scripts/check_host.sh
#
# This is build-strategy gate 1: host-independent tests. DroidVM is developed on
# Windows with no local Mac, so everything that CAN be checked without Xcode must be,
# here, quickly, before anything reaches a macOS runner.
#
# What it does:
#   1. builds and tests the platform-independent core package (`swift test`)
#   2. runs the repository guards (identity/provenance, required files)
#
# What it does NOT do: compile the iOS app target. That needs the iOS SDK; see
# scripts/typecheck_ios.sh and .github/workflows/ci.yml.
#
# Toolchain discovery: $DROIDVM_SWIFT (a swift path) wins, then `swift` on PATH, then
# an extracted toolchain at $HOME/swiftroot (see docs/build.md for how that is
# produced without root).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fails=0
stage_fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# ---------------------------------------------------------------- toolchain

find_swift() {
    if [ -n "${DROIDVM_SWIFT:-}" ] && [ -x "${DROIDVM_SWIFT}" ]; then
        echo "${DROIDVM_SWIFT}"; return 0
    fi
    if command -v swift >/dev/null 2>&1; then
        command -v swift; return 0
    fi
    # A toolchain extracted from the Ubuntu packages keeps the real driver under
    # libexec; usr/bin holds only a few wrappers and no `swift` at all.
    for cand in "$HOME/swiftroot/usr/libexec/swift/bin/swift" \
                "$HOME/swiftroot/usr/bin/swift"; do
        if [ -x "$cand" ]; then echo "$cand"; return 0; fi
    done
    return 1
}

SWIFT="$(find_swift || true)"
if [ -z "$SWIFT" ]; then
    echo "SKIP: no Swift toolchain found." >&2
    echo "      Put swift on PATH, or set DROIDVM_SWIFT=/path/to/swift." >&2
    echo "      docs/build.md describes the root-free way to obtain one." >&2
    exit 2
fi

# The driver's siblings (swift-build, swift-package, swift-test) must be reachable.
SWIFT_BIN_DIR="$(cd "$(dirname "$SWIFT")" && pwd)"
PATH="$SWIFT_BIN_DIR:$PATH"
export PATH

# The Ubuntu .deb layout keeps the runtime libraries under libexec, which is not where
# the compiler looks for itself. Harmless on a normal install.
SWIFT_PREFIX="$(cd "$SWIFT_BIN_DIR/.." && pwd)"
for d in "$SWIFT_PREFIX/libexec/swift/lib/swift/linux" \
         "$SWIFT_PREFIX/libexec/swift/lib" \
         "$SWIFT_PREFIX/lib/swift/linux"; do
    [ -d "$d" ] && LD_LIBRARY_PATH="$d:${LD_LIBRARY_PATH:-}"
done
export LD_LIBRARY_PATH

echo "================================================================"
echo " DroidVM host check"
echo "   swift : $SWIFT"
echo "   $( ("$SWIFT" --version 2>&1 | head -1) )"
echo "   $(uname -srm 2>/dev/null || echo unknown)"
echo "================================================================"
echo

# ------------------------------------------------------- core package tests

echo "--- core package (platform-independent domain + interfaces) ---"
if (cd "$ROOT/core" && "$SWIFT" test --parallel 2>&1); then
    echo "core: PASS"
else
    echo "core: FAIL" >&2
    stage_fail "swift test (core)"
fi
echo

# --------------------------------------------------------- repository guards

echo "--- repository guards ---"
GUARD="$ROOT/scripts/check_repo.py"
if [ -f "$GUARD" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else PY=""; fi

    if [ -z "$PY" ]; then
        echo "SKIP: no python3/python found for the repository guards" >&2
    elif "$PY" "$GUARD"; then
        echo "guards: PASS"
    else
        echo "guards: FAIL" >&2
        stage_fail "check_repo.py"
    fi
else
    stage_fail "scripts/check_repo.py is missing"
fi
echo

# ------------------------------------------------------------- engine layer
#
# Syntax only. The engine adapters import Metal and QuartzCore, so they cannot be
# type-checked anywhere but macOS -- but they can be checked for syntax, the C bridge header
# can be genuinely compiled, and the trap protocol can be verified intact. PARSE PASS is not
# COMPILE PASS, and that script says so in its own output.

echo "--- engine layer (syntax only) ---"
ENGINE_GATE="$ROOT/scripts/check_engine.sh"
if [ -f "$ENGINE_GATE" ]; then
    if bash "$ENGINE_GATE" >/tmp/droidvm-engine-gate.log 2>&1; then
        echo "engine: PARSE PASS (not a compile)"
    else
        echo "engine: FAIL" >&2
        sed 's/^/  /' /tmp/droidvm-engine-gate.log | tail -n 25 >&2
        stage_fail "check_engine.sh"
    fi
else
    stage_fail "scripts/check_engine.sh is missing"
fi
echo

# ---------------------------------------------------------- bridge interop
#
# The strongest check available without macOS: it builds DroidVMCore as a real module, compiles
# the one engine adapter that needs no Apple framework, and exercises the engine's whole C ABI
# from Swift. It is an ABI harness, not device verification.

echo "--- engine bridge interop (C ABI from Swift) ---"
INTEROP="$ROOT/scripts/check_bridge_interop.sh"
if [ -f "$INTEROP" ]; then
    if bash "$INTEROP" >/tmp/droidvm-interop.log 2>&1; then
        grep -E '^[0-9]+ checks' /tmp/droidvm-interop.log | sed 's/^/  /'
        echo "interop: PASS (ABI and the JIT adapter's mapping; not a device)"
    else
        echo "interop: FAIL" >&2
        sed 's/^/  /' /tmp/droidvm-interop.log | tail -n 30 >&2
        stage_fail "check_bridge_interop.sh"
    fi
else
    stage_fail "scripts/check_bridge_interop.sh is missing"
fi
echo

echo "================================================================"
if [ "$fails" -eq 0 ]; then
    echo " HOST CHECK: PASS"
    echo " gates covered : host-independent tests, repository guards,"
    echo "                 engine syntax, engine C ABI from Swift"
    echo " not covered   : iOS SDK compile, linking, signing, device"
else
    echo " HOST CHECK: FAIL ($fails stage(s))"
fi
echo "================================================================"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
