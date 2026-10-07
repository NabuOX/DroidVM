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

# ---------------------------------------------------------------- integration regression
#
# The build integration was previously verified by hand, once. These run it against a fixture
# QEMU tree, so a regression in integrate_engine.sh fails the host gate rather than gate 3.

echo "--- integration regression (D.1a) ---"
if "$ROOT/scripts/check_integration.sh"; then
    :
else
    stage_fail "integration regression"
fi
echo

# ---------------------------------------------------------------- guard tests
#
# Guards that cannot fail are not guards. Two of them live in shell scripts that cannot run on
# this host -- build_engine_ios.sh exits 2 without Xcode -- so their logic is extracted and
# exercised here instead. This is how the dependency false-pass and the NDEBUG regression were
# caught, and it is how they stay caught.

echo "--- guard self-tests ---"

# require_no_ndebug: must accept a clean release flag set and refuse one containing NDEBUG.
# QEMU hard-errors on it (include/qemu/osdep.h:294) and that cost a multi-hour CI run.
GUARD_BODY="$(mktemp)"
sed -n '/^require_no_ndebug() {/,/^}/p' "$ROOT/scripts/build_engine_ios.sh" > "$GUARD_BODY"
if [ ! -s "$GUARD_BODY" ]; then
    echo "  FAIL: could not extract require_no_ndebug from build_engine_ios.sh" >&2
    stage_fail "require_no_ndebug extraction"
else
    run_guard() {
        { echo 'die() { exit 1; }'; cat "$GUARD_BODY"; printf 'require_no_ndebug %s\n' "$1"; } \
            | bash >/dev/null 2>&1
    }
    if run_guard '"-O2 -fPIC"'; then
        echo "  ok   require_no_ndebug accepts a clean -O2 flag set"
    else
        echo "  FAIL require_no_ndebug refused a clean -O2 flag set" >&2
        stage_fail "require_no_ndebug false positive"
    fi
    if run_guard '"-O2" "-O2 -std=c++17" "-O2 -DNDEBUG"'; then
        echo "  FAIL require_no_ndebug accepted NDEBUG (QEMU refuses to build with it)" >&2
        stage_fail "require_no_ndebug did not fire"
    else
        echo "  ok   require_no_ndebug refuses NDEBUG, in any argument"
    fi
fi
rm -f "$GUARD_BODY"

# extract_bridge_declarations: must read DECLARATIONS, not names mentioned in comments, and
# must refuse to pass on an input it cannot extract anything from. The malformed-regex failure
# this replaces reached CI because nothing tested the extraction on its own.
EXTRACT_BODY="$(mktemp)"
sed -n '/^extract_bridge_declarations() {/,/^}/p' "$ROOT/scripts/build_engine_ios.sh" \
    > "$EXTRACT_BODY"
if [ ! -s "$EXTRACT_BODY" ]; then
    echo "  FAIL: could not extract extract_bridge_declarations" >&2
    stage_fail "extract_bridge_declarations extraction"
else
    FIXTURE="$(mktemp)"
    cat > "$FIXTURE" <<'FIXTURE_EOF'
/* A block comment mentioning droidvm_comment_only( which is NOT a declaration. */
int droidvm_declared_one(int argc, char **argv);
void qemu_declared_two(void);
// A line comment mentioning droidvm_also_comment_only(
int droidvm_declared_three(void);
/* trailing */
FIXTURE_EOF

    # The extracted body only DEFINES the function. It has to be called, and the call has to
    # be appended -- an earlier version extracted the definition and ran it, which printed
    # nothing and exited 0, so every assertion below "failed" against empty output.
    run_extract() {
        { echo 'die() { exit 1; }'
          cat "$EXTRACT_BODY"
          printf 'extract_bridge_declarations "$1"\n'
        } > "$EXTRACT_BODY.run"
        bash "$EXTRACT_BODY.run" "$1"
    }

    got="$(run_extract "$FIXTURE" 2>/dev/null || true)"
    for expected in droidvm_declared_one qemu_declared_two droidvm_declared_three; do
        if printf '%s\n' "$got" | grep -qx "$expected"; then
            echo "  ok   extracts the declaration $expected"
        else
            echo "  FAIL did not extract the declaration $expected" >&2
            stage_fail "extract_bridge_declarations missed $expected"
        fi
    done
    for forbidden in droidvm_comment_only droidvm_also_comment_only; do
        if printf '%s\n' "$got" | grep -qx "$forbidden"; then
            echo "  FAIL accepted '$forbidden', which appears only in a comment" >&2
            stage_fail "extract_bridge_declarations accepted a comment mention"
        else
            echo "  ok   rejects the comment-only mention $forbidden"
        fi
    done

    # An input with no declarations must be REFUSED, not silently produce an empty set.
    EMPTY_FIXTURE="$(mktemp)"
    printf '/* only a comment, droidvm_nothing( */\n' > "$EMPTY_FIXTURE"
    if run_extract "$EMPTY_FIXTURE" >/dev/null 2>&1; then
        echo "  FAIL accepted an input with no declarations (the check would pass vacuously)" >&2
        stage_fail "extract_bridge_declarations accepted an empty extraction"
    else
        echo "  ok   refuses an input it cannot extract from"
    fi

    # The real header, through the same extracted function. It must find every symbol the
    # manifest expects, or the cross-check downstream is comparing against a short list.
    real_decls="$(run_extract "$ROOT/engine/include/DroidVMBridge.h" 2>/dev/null || true)"
    real_count="$(printf '%s\n' "$real_decls" | grep -c . || true)"
    echo "  ok   the real header extracts $real_count declaration(s)"
    for must_have in qemu_init qemu_main_loop qemu_cleanup droidvm_jit_capture \
                     droidvm_display_register droidvm_serial_bytes_written; do
        if printf '%s\n' "$real_decls" | grep -qx "$must_have"; then
            :
        else
            echo "  FAIL the real header extraction missed $must_have" >&2
            stage_fail "extract_bridge_declarations missed $must_have in the real header"
        fi
    done
    if [ "$real_count" -lt 14 ]; then
        echo "  FAIL the real header should yield at least 14 declarations, got $real_count" >&2
        stage_fail "extract_bridge_declarations returned too few from the real header"
    else
        echo "  ok   it finds all 14 declared symbols in the real bridge header"
    fi
    rm -f "$FIXTURE" "$EMPTY_FIXTURE" "$EXTRACT_BODY" "$EXTRACT_BODY.run"
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
