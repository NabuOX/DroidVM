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

# Every embedded library, not one of them. A bundle missing either QEMU or ANGLE launches to a
# dyld error; a check covering only one reports success on a bundle that cannot start.
for lib in libqemu-aarch64-softmmu.dylib libANGLE-shared.dylib; do
    if [ ! -f "$APP/Frameworks/$lib" ]; then
        echo "  MISSING  Frameworks/$lib" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$lib" "$(du -h "$APP/Frameworks/$lib" | cut -f1)"
    fi
done

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
