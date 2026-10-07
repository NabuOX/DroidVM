#!/bin/bash
# DroidVM gate 2: iOS compile gate.  **macOS + Xcode only.**
#
#   ./scripts/typecheck_ios.sh
#
# Reports four layers SEPARATELY, because a failure in one is not a failure in another:
#
#   NATIVE COMPILE   engine/native/*.c and the bridge header, for arm64-apple-ios
#   SWIFT COMPILE    DroidVMCore as a module, then engine + app as one module
#   ASSEMBLY         the arm64 trap protocol
#   (link comes later, at gate 3 -- a green compile is not a link)
#
# It mirrors what Xcode does rather than approximating it:
#
#   1. emit `DroidVMCore` as a module for the iOS target -- in the app it is a SwiftPM
#      dependency and therefore a separate module
#   2. type-check the engine adapters AND the app target TOGETHER, because in the real
#      target they are one module
#   3. assemble the trap protocol with the real arm64 toolchain
#   4. compile the native C for arm64-apple-ios
#
# The two-stage Swift shape is not ceremony. Compiling everything as one module would hide
# module-boundary errors -- and that is not hypothetical: the host interop harness found that
# every engine adapter used `DroidVMCore` types without importing the module, which is a hard
# error in the real build and invisible to a single-module shortcut.
#
# FROM PHASE 1.2 THIS GATE REQUIRES THE APP TARGET. It used to print a note and carry on when
# `app/DroidVMApp` did not exist, which meant "iOS compile PASS" meant "everything except the
# application compiles". A gate that skips a stage and calls the result a pass is worse than
# no gate.
#
# Environment overrides: DROIDVM_SDK, DROIDVM_TARGET, DROIDVM_MIN_SDK_MAJOR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun not found. Gate 2 needs macOS with Xcode." >&2
    echo "       Gate 1 (scripts/check_host.sh) runs anywhere." >&2
    exit 2
fi

# ---------------------------------------------------------------- environment
# Dumped unconditionally: a passing run must record which toolchain produced it, and a
# failing one must be attributable rather than guessed at.
echo "================ environment ================"
sw_vers 2>/dev/null || echo "sw_vers: unavailable"
echo "--- xcodebuild ---"
xcodebuild -version 2>&1 | head -3 || echo "xcodebuild: unavailable"
echo "--- xcode-select ---"
xcode-select -p 2>&1 || true
echo "--- sdk ---"
echo "iphoneos version: $(xcrun --sdk iphoneos --show-sdk-version 2>&1 | head -1)"
echo "iphoneos path   : $(xcrun --sdk iphoneos --show-sdk-path 2>&1 | head -1)"
echo "--- swift ---"
swift --version 2>&1 | head -3 || echo "swift: unavailable"
swiftc --version 2>&1 | head -1 || true
echo "--- clang ---"
xcrun --sdk iphoneos clang --version 2>&1 | head -2 || true
echo "============================================"
echo

SDK="${DROIDVM_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
TARGET="${DROIDVM_TARGET:-arm64-apple-ios16.4}"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0)"
SDK_MAJOR="${SDK_VERSION%%.*}"
case "$SDK_MAJOR" in ''|*[!0-9]*) SDK_MAJOR=0 ;; esac

MIN_SDK_MAJOR="${DROIDVM_MIN_SDK_MAJOR:-16}"
if [ "$SDK_MAJOR" -lt "$MIN_SDK_MAJOR" ]; then
    echo "ENVIRONMENT LIMITATION" >&2
    echo "  iOS SDK $SDK_VERSION is below the $MIN_SDK_MAJOR floor DroidVM targets." >&2
    echo "  This is a runner problem, not a source problem. Select a newer Xcode;" >&2
    echo "  do not adapt the application to an older SDK." >&2
    exit 3
fi

BUILD="$ROOT/build/ios-typecheck"
rm -rf "$BUILD"
mkdir -p "$BUILD"

BRIDGE="$ROOT/engine/include/DroidVMBridge.h"
[ -f "$BRIDGE" ] || { echo "error: no bridging header at engine/include/DroidVMBridge.h" >&2; exit 1; }

collect() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -name '*.swift' -not -path '*/.build/*' | sort
}

CORE_SOURCES=();   while IFS= read -r f; do CORE_SOURCES+=("$f"); done   < <(collect core/Sources/DroidVMCore)
ENGINE_SOURCES=(); while IFS= read -r f; do ENGINE_SOURCES+=("$f"); done < <(collect engine)
APP_SOURCES=();    while IFS= read -r f; do APP_SOURCES+=("$f"); done    < <(collect app/DroidVMApp)
NATIVE_SOURCES=(); while IFS= read -r f; do NATIVE_SOURCES+=("$f"); done < <(find engine/native -name '*.c' 2>/dev/null | sort)

echo "droidvm ios compile gate"
echo "  sdk      : $SDK ($SDK_VERSION)"
echo "  target   : $TARGET"
echo "  bridging : ${BRIDGE#$ROOT/}"
echo "  native   : ${#NATIVE_SOURCES[@]} .c"
echo "  core     : ${#CORE_SOURCES[@]} sources -> module DroidVMCore"
echo "  engine   : ${#ENGINE_SOURCES[@]} sources"
echo "  app      : ${#APP_SOURCES[@]} sources"
echo

# Refuse to pass a stage that has nothing in it. This is the change that makes the gate mean
# what it says.
if [ "${#CORE_SOURCES[@]}" -eq 0 ]; then
    echo "error: no core sources found under core/Sources/DroidVMCore" >&2; exit 1
fi
if [ "${#ENGINE_SOURCES[@]}" -eq 0 ]; then
    echo "error: no engine sources found under engine/ -- the app cannot link without them" >&2; exit 1
fi
if [ "${#APP_SOURCES[@]}" -eq 0 ]; then
    echo "error: no app sources found under app/DroidVMApp" >&2
    echo "       This stage used to be skipped with a note, which made 'iOS compile PASS'" >&2
    echo "       mean 'everything except the application compiles'. It fails now." >&2
    exit 1
fi

# ------------------------------------------------- NATIVE COMPILE

echo "--- [1/4] NATIVE COMPILE (arm64-apple-ios) ---"
if [ "${#NATIVE_SOURCES[@]}" -eq 0 ]; then
    echo "error: no native sources found under engine/native" >&2
    exit 1
fi
for src in "${NATIVE_SOURCES[@]}"; do
    printf '  %-46s ' "${src#$ROOT/}"
    xcrun --sdk iphoneos clang \
        -std=c11 -Wall -Wextra -Werror \
        -target "$TARGET" -isysroot "$SDK" \
        -I "$ROOT/engine/include" -I "$ROOT/engine/native" \
        -c "$src" -o "$BUILD/$(basename "$src" .c).o"
    echo "ok"
done
echo "  NATIVE COMPILE: PASS"

# ------------------------------------------------- SWIFT COMPILE: core module

echo
echo "--- [2/4] SWIFT COMPILE: DroidVMCore as a module ---"
xcrun -sdk iphoneos swiftc \
    -emit-module \
    -emit-module-path "$BUILD/DroidVMCore.swiftmodule" \
    -module-name DroidVMCore \
    -target "$TARGET" -sdk "$SDK" -swift-version 5 \
    "${CORE_SOURCES[@]}"
echo "  SWIFT COMPILE (core): PASS (${#CORE_SOURCES[@]} sources)"

# ------------------------------------------------- SWIFT COMPILE: engine + app

echo
echo "--- [3/4] SWIFT COMPILE: engine + app (one module, as in the real target) ---"
xcrun -sdk iphoneos swiftc \
    -typecheck \
    -target "$TARGET" -sdk "$SDK" \
    -import-objc-header "$BRIDGE" \
    -I "$BUILD" \
    -swift-version 5 \
    "${ENGINE_SOURCES[@]}" "${APP_SOURCES[@]}"
echo "  SWIFT COMPILE (engine + app): PASS (${#ENGINE_SOURCES[@]} + ${#APP_SOURCES[@]} sources)"

# ------------------------------------------------- ASSEMBLY

echo
echo "--- [4/4] ASSEMBLY (arm64 trap protocol) ---"
if [ -f engine/jit/droidvm-brk.S ]; then
    xcrun --sdk iphoneos clang -c -target "$TARGET" -isysroot "$SDK" \
        engine/jit/droidvm-brk.S -o "$BUILD/droidvm-brk.o"
    echo "  ASSEMBLY: PASS"
else
    echo "error: engine/jit/droidvm-brk.S is missing; the JIT has no trap protocol" >&2
    exit 1
fi

echo
echo "================================================================"
echo " gate 2 NATIVE COMPILE : PASS (${#NATIVE_SOURCES[@]} sources)"
echo " gate 2 SWIFT COMPILE  : PASS (core module + engine + app)"
echo " gate 2 ASSEMBLY       : PASS"
echo " gate 3 ENGINE LINK    : NOT RUN -- scripts/build_engine_ios.sh"
echo " gate 4 IPA PACKAGE    : NOT RUN"
echo "================================================================"
