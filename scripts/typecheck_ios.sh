#!/bin/bash
# DroidVM gate 2: iOS compile gate.  **macOS + Xcode only.**
#
#   ./scripts/typecheck_ios.sh
#
# WHAT THIS DOES, AND WHY IT IS IN TWO STAGES
#
# It mirrors what Xcode does, rather than approximating it:
#
#   1. Emit `DroidVMCore` as a module for the iOS target. In the app it is a SwiftPM
#      dependency and therefore a separate module.
#   2. Type-check the app and engine sources against that module and the real bridging
#      header, for `arm64-apple-ios16.4`.
#
# The two-stage shape is not ceremony. Compiling everything as one module instead would hide
# the module-boundary errors -- and that is not hypothetical: the bridge interop harness found
# that every engine adapter used `DroidVMCore` types without importing the module, which is a
# hard error in the real build and invisible to a single-module shortcut.
#
# WHAT IT CATCHES THAT NOTHING ELSE DOES
#
#   * actor isolation: @MainActor, nonisolated, Task { @MainActor in }
#   * C enum and integer bridging, and `size_t`/`uint64_t` widths
#   * inout arguments passed as &x to a C function
#   * bridging-header visibility, and undeclared symbols
#   * Metal, QuartzCore and UIKit availability and their API shapes
#   * Swift's complete absence of implicit numeric conversion
#
# It is NOT gates 3-4. Passing this does not mean the app builds: type-checking cannot prove
# a symbol exists in the engine dylib, that the export list is complete, or that anything
# links.
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
# Dumped unconditionally: a passing run must still record which toolchain produced it, and a
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
echo "============================================"
echo

SDK="${DROIDVM_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
TARGET="${DROIDVM_TARGET:-arm64-apple-ios16.4}"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0)"
SDK_MAJOR="${SDK_VERSION%%.*}"
case "$SDK_MAJOR" in ''|*[!0-9]*) SDK_MAJOR=0 ;; esac

# The app targets iOS 16.4, so any SDK from 16 up can type-check it. An older SDK is an
# environment limitation to report, never a reason to edit the app to fit it.
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

CORE_SOURCES=(); while IFS= read -r f; do CORE_SOURCES+=("$f"); done < <(collect core/Sources/DroidVMCore)
ENGINE_SOURCES=(); while IFS= read -r f; do ENGINE_SOURCES+=("$f"); done < <(collect engine)
APP_SOURCES=(); while IFS= read -r f; do APP_SOURCES+=("$f"); done < <(collect app/DroidVMApp)

echo "droidvm ios compile gate"
echo "  sdk      : $SDK ($SDK_VERSION)"
echo "  target   : $TARGET"
echo "  bridging : ${BRIDGE#$ROOT/}"
echo "  core     : ${#CORE_SOURCES[@]} sources -> module DroidVMCore"
echo "  engine   : ${#ENGINE_SOURCES[@]} sources"
echo "  app      : ${#APP_SOURCES[@]} sources"
echo
echo "note: type-check only. This does NOT prove the app builds or links."

if [ "${#CORE_SOURCES[@]}" -eq 0 ]; then
    echo "error: no core sources found" >&2
    exit 1
fi

# ------------------------------------------------- stage 1: the core module

echo
echo "--- [1/3] emitting DroidVMCore for the iOS target ---"
xcrun -sdk iphoneos swiftc \
    -emit-module \
    -emit-module-path "$BUILD/DroidVMCore.swiftmodule" \
    -module-name DroidVMCore \
    -target "$TARGET" \
    -sdk "$SDK" \
    -swift-version 5 \
    "${CORE_SOURCES[@]}"
echo "  ok"

# ------------------------------------------------- stage 2: engine sources

if [ "${#ENGINE_SOURCES[@]}" -gt 0 ]; then
    echo
    echo "--- [2/3] type-checking the engine adapters ---"
    xcrun -sdk iphoneos swiftc \
        -typecheck \
        -target "$TARGET" \
        -sdk "$SDK" \
        -import-objc-header "$BRIDGE" \
        -I "$BUILD" \
        -swift-version 5 \
        "${ENGINE_SOURCES[@]}"
    echo "  ok (${#ENGINE_SOURCES[@]} sources: Metal, QuartzCore, the bridge, the core module)"
else
    echo
    echo "--- [2/3] no engine sources yet ---"
fi

# ------------------------------------------------- stage 3: app sources

if [ "${#APP_SOURCES[@]}" -gt 0 ]; then
    echo
    echo "--- [3/3] type-checking the app target ---"
    xcrun -sdk iphoneos swiftc \
        -typecheck \
        -target "$TARGET" \
        -sdk "$SDK" \
        -import-objc-header "$BRIDGE" \
        -I "$BUILD" \
        -swift-version 5 \
        "${APP_SOURCES[@]}"
    echo "  ok (${#APP_SOURCES[@]} sources)"
else
    echo
    echo "--- [3/3] the app target does not exist yet (app/DroidVMApp) ---"
    echo "      Phase 2 creates it. This is NOT a passing app compile: it is a stage with"
    echo "      nothing to check, which is a different thing."
fi

# ------------------------------------------------- assembly
#
# The trap protocol is assembled separately, because `-typecheck` cannot check assembly and
# silently skipping it would leave an arm64 build failure for gate 3.
if [ -f engine/jit/droidvm-brk.S ]; then
    echo
    echo "--- assembling the trap protocol for arm64 ---"
    xcrun -sdk iphoneos clang -c -target "$TARGET" -isysroot "$SDK" \
        engine/jit/droidvm-brk.S -o "$BUILD/droidvm-brk.o"
    echo "  ok (arm64 assembly accepted by the real toolchain)"
fi

echo
echo "gate 2 (COMPILE) : PASS (${#ENGINE_SOURCES[@]} engine + ${#APP_SOURCES[@]} app sources)"
echo "gate 3 (LINK)    : NOT RUN -- scripts/build_engine_ios.sh, then scripts/package_ipa.sh"
echo "gate 4 (PACKAGE) : NOT RUN"
