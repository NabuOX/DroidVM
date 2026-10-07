#!/bin/bash
# DroidVM gates 4: package an unsigned IPA.  **macOS + Xcode only.**
#
#   ./scripts/package_ipa.sh [output.ipa]      default: build/DroidVM.ipa
#
# DroidVM's own pipeline. Nothing here carries another project's identity: the target, the
# bundle identifier, the display name, the artifact name and the validation are all DroidVM's.
#
# UNSIGNED IS DELIBERATE. SideStore / AltStore / TrollStore re-sign at install, so no signing
# team is needed and one artifact works for everyone. Signing is reported separately and is
# never inferred from this succeeding.
#
# THE VALIDATION IS THE POINT
#
# A bundle missing CFBundleIdentifier or CFBundleExecutable builds and zips perfectly happily
# and then fails to install with no useful message. Xcode does not inject those keys when a
# custom INFOPLIST_FILE is supplied without GENERATE_INFOPLIST_FILE, which is exactly how this
# project is configured. So the bundle is checked before it is zipped, and the check covers
# every embedded library -- a check that covers one of two required libraries reports success
# on a bundle that cannot launch.
#
# The validation approach is adapted from the reference implementation's packaging script,
# whose comments record the two failures that motivated it. Recorded in THIRD_PARTY.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DD="${DD:-$ROOT/build/ipa}"
OUT="${1:-$ROOT/build/DroidVM.ipa}"
mkdir -p "$DD" "$(dirname "$OUT")"

BUNDLE_ID="com.droidvm.app"
APP_NAME="DroidVM"
SCHEME="DroidVM"
PROJECT="$ROOT/app/DroidVM.xcodeproj"

echo "================================================================"
echo " DroidVM IPA packaging"
echo "   bundle id : $BUNDLE_ID"
echo "   artifact  : $OUT"
echo "================================================================"

# ---------------------------------------------------------------- project
#
# project.yml is the source of truth and the .pbxproj is a build artefact of it. Without this
# step a newly added source file is silently absent from the target, and the only symptom is
# "cannot find X in scope" for a type that is plainly on disk.
if command -v xcodegen >/dev/null 2>&1; then
    echo "==> regenerating the project from project.yml"
    (cd "$ROOT/app" && xcodegen generate --quiet)
else
    echo "==> xcodegen not installed; using the checked-in project as-is" >&2
fi

[ -d "$PROJECT" ] || { echo "error: no project at $PROJECT" >&2; exit 1; }

# ---------------------------------------------------------------- build

echo "==> building"
set +e
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -sdk iphoneos -configuration Release -derivedDataPath "$DD" \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > "$DD/build.log" 2>&1
BUILD_STATUS=$?
set -e
grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" "$DD/build.log" | tail -30 || true

# A failed build must not sail past this. The previous .app is still in derived data, so
# validation and packaging would both succeed and produce an IPA of the LAST build -- which
# looks exactly like a fix that did not work.
if [ "$BUILD_STATUS" -ne 0 ] || ! grep -q "BUILD SUCCEEDED" "$DD/build.log"; then
    echo >&2
    echo "COMPILE/LINK: FAIL" >&2
    grep -E "error:" "$DD/build.log" | head -20 >&2
    echo "refusing to package a stale app" >&2
    exit 1
fi
echo "==> COMPILE PASS"
echo "==> LINK PASS"

# ---------------------------------------------------------------- embed the engine
#
# Packaging owns this because the dylib is a runtime dependency the app loads dynamically through
# dlopen, not a link-time one. There is deliberately no Xcode build phase and no linkage between the
# app target and QEMU -- the app target must never compile QEMU-internal sources.
echo "==> embedding the engine"
[ -f "$ENGINE_LIB" ] || {
    echo "error: no engine library at $ENGINE_LIB" >&2
    echo "       build it first: ./scripts/build_engine_ios.sh deps qemu" >&2
    exit 1
}
mkdir -p "$APP/Frameworks"
cp -f "$ENGINE_LIB" "$APP/Frameworks/libqemu-aarch64-softmmu.dylib"

# The engine library, from the verified engine build. One canonical path, and the runtime looks
# in exactly one place that matches it: DroidVM.app/Frameworks.
ENGINE_LIB="${DROIDVM_ENGINE_LIB:-$ROOT/build/ios-arm64/lib/libqemu-aarch64-softmmu.dylib}"

APP="$DD/Build/Products/Release-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: no app bundle at $APP" >&2; exit 1; }

# ---------------------------------------------------------------- stamp
#
# The build's identity goes into the bundle so its logs can name themselves. A log from a
# stale install is otherwise indistinguishable from a log proving a fix did not work.
PLIST="$APP/Info.plist"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$ROOT" diff --quiet 2>/dev/null || COMMIT="$COMMIT-dirty"
/usr/libexec/PlistBuddy -c "Add :DroidVMBuildCommit string $COMMIT" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :DroidVMBuildCommit $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :DroidVMBuildDate string $(date -u '+%Y-%m-%d %H:%M UTC')" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :DroidVMBuildDate $(date -u '+%Y-%m-%d %H:%M UTC')" "$PLIST"
echo "==> stamped build $COMMIT"

# ---------------------------------------------------------------- validate

echo "==> validating bundle"
rc=0

for key in CFBundleIdentifier CFBundleExecutable CFBundleName \
           CFBundlePackageType CFBundleVersion CFBundleShortVersionString \
           MinimumOSVersion UIDeviceFamily; do
    val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    if [ -z "$val" ]; then
        echo "  MISSING  $key   <-- the app will not install" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$key" "$(echo "$val" | head -1)"
    fi
done

# The identity must be DroidVM's. Asserted here as well as in Identity.swift, because this is
# the artefact a user installs.
actual_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" 2>/dev/null || true)"
if [ "$actual_id" != "$BUNDLE_ID" ]; then
    echo "  WRONG    CFBundleIdentifier is '$actual_id', expected '$BUNDLE_ID'" >&2
    rc=1
fi
case "$actual_id" in
    *[Hh]usk*) echo "  WRONG    the bundle identifier carries foreign branding" >&2; rc=1 ;;
esac

EXE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)"
if [ -n "$EXE" ] && [ ! -f "$APP/$EXE" ]; then
    echo "  MISSING  executable '$EXE' named by CFBundleExecutable" >&2
    rc=1
elif [ -n "$EXE" ]; then
    printf "  ok       %-28s %s\n" "executable present" "$EXE"
fi

# The engine is the one embedded library THIS ARCHITECTURE NEEDS. QEMU is built with
# --disable-opengl --disable-virglrenderer and the display path is software (pixman through
# DisplayChangeListenerOps), so there is no libANGLE-shared.dylib to embed. ANGLE stays in
# THIRD_PARTY.md as planned acceleration work and becomes a requirement only when that backend
# lands -- at which point this check must gain it back rather than silently shipping without it.
QEMU_LIB="$APP/Frameworks/libqemu-aarch64-softmmu.dylib"
if [ ! -f "$QEMU_LIB" ]; then
    echo "  MISSING  Frameworks/libqemu-aarch64-softmmu.dylib" >&2
    rc=1
else
    printf "  ok       %-28s %s\n" "engine embedded" "$(du -h "$QEMU_LIB" | cut -f1)"

    # A wrong-arch or empty library installs fine and fails at dlopen, on the device, with no
    # useful message. `lipo` reports neither as arm64, so one check covers both.
    ARCHS="$(lipo -archs "$QEMU_LIB" 2>/dev/null || echo unknown)"
    case "$ARCHS" in
        *arm64*) printf "  ok       %-28s %s\n" "engine architecture" "$ARCHS" ;;
        *) echo "  WRONG    engine architecture is '$ARCHS', expected arm64" >&2; rc=1 ;;
    esac

    # The symbols the app resolves by name, checked by the SAME script gate 3 runs, so the packaged
    # bundle cannot disagree with what SYMBOL VERIFY proved inside QEMU.
    MANIFEST="$ROOT/engine/symbols/required-engine-symbols.txt"
    EXPORTS="$DD/bundle-exports.txt"
    nm -gU "$QEMU_LIB" 2>/dev/null | awk '{print $NF}' | sed 's/^_//' | sort -u > "$EXPORTS"
    if bash "$ROOT/scripts/check_engine_symbols.sh" "$MANIFEST" "$EXPORTS" > /dev/null; then
        printf "  ok       %-28s %s\n" "engine exports" "all present"
    else
        rc=1
    fi

    # Every non-system dependency must travel inside the bundle, or the app dies at launch on the
    # device with a dyld error that names a library nobody shipped.
    echo "  -- dependencies --"
    # Process substitution, NOT a pipe: a pipeline would run this loop in a subshell and discard the
    # failure flag, leaving a check that can never fail packaging.
    while read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/Library/*) printf "  ok       %-28s %s\n" "system" "$dep" ;;
            *)
                base="$(basename "$dep")"
                if [ -f "$APP/Frameworks/$base" ]; then
                    printf "  ok       %-28s %s\n" "in bundle" "$base"
                else
                    echo "  MISSING  dependency '$dep' is not a system library and is not in the bundle" >&2
                    rc=1
                fi ;;
        esac
    done < <(otool -L "$QEMU_LIB" | tail -n +2 | awk '{print $1}')
fi

[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

# ---------------------------------------------------------------- package

echo "==> packaging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
TMP_IPA="$STAGE/$APP_NAME.ipa"
(cd "$STAGE" && zip -qry "$TMP_IPA" Payload)
mv -f "$TMP_IPA" "$OUT"

echo
echo "================================================================"
echo " COMPILE       PASS"
echo " LINK          PASS"
echo " SIGNING       NOT REQUIRED (unsigned; the installer re-signs)"
echo " DEVICE TEST   NOT RUN"
echo " artifact      $OUT ($(du -h "$OUT" | cut -f1))"
echo "================================================================"
