#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""DroidVM repository guards.

Runs anywhere with Python 3 -- including plain Windows, with no WSL and no Swift,
which matters because DroidVM is developed on Windows. Invoked by
scripts/check_host.sh and by CI.

These are cheap checks for expensive mistakes:

  * a required document went missing, or an empty placeholder got committed
  * another project's branding leaked into DroidVM's identity
  * a guest image, APK or other large binary got committed by accident
  * THIRD_PARTY.md lost the columns that make it useful

Exit status 0 when everything passes, 1 otherwise.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures = []
notes = []


def fail(message):
    failures.append(message)


def ok(message):
    notes.append(message)


# --------------------------------------------------------------------- files

REQUIRED_FILES = [
    "README.md",
    "ARCHITECTURE.md",
    "THIRD_PARTY.md",
    "LICENSE",
    "docs/roadmap.md",
    "docs/component-inventory.md",
    "docs/licensing.md",
    "docs/guest-assets.md",
    "docs/guest-distribution.md",
    "app/project.yml",
    "app/DroidVMApp/DroidVMApp.swift",
    "app/DroidVMApp/Info.plist",
    "app/DroidVMApp/DroidVM.entitlements",
    "engine/include/DroidVMBridge.h",
    "engine/native/droidvm_native.h",
    "engine/native/droidvm_jit.c",
    "engine/native/droidvm_display.c",
    "engine/native/droidvm_runtime.c",
    "engine/jit/droidvm-brk.S",
    "engine/symbols/required-symbols.txt",
    "engine/patches/README.md",
    "engine/patches/pixman-0.38.0.patch",
    "engine/patches/libslirp-v4.9.1.patch",
    ".github/workflows/engine-link.yml",
    "core/Package.swift",
]


def check_required_files():
    for rel in REQUIRED_FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            fail("missing required file: %s" % rel)
            continue
        if os.path.getsize(path) == 0:
            fail("required file is empty: %s" % rel)
    ok("required files: %d checked" % len(REQUIRED_FILES))


# ---------------------------------------------------------------- provenance

# Files permitted to name another project, because provenance must be recorded rather
# than concealed. Everything else in the tree must be DroidVM's own.
PROVENANCE_WHITELIST = {
    "THIRD_PARTY.md",
    "docs/licensing.md",
    "docs/component-inventory.md",
    # guest-assets.md records distribution obligations, including the file whose provenance
    # caused a licensing finding. Warning against copying it requires naming it.
    "docs/guest-assets.md",
    "core/Sources/DroidVMCore/Identity.swift",
    "scripts/check_repo.py",          # this file names the marker to look for
    "core/Tests/DroidVMCoreTests/IdentityTests.swift",
    # Engine sources carry SPDX headers and, where a design was studied or a recipe adapted,
    # a comment naming the upstream file. That is provenance, not branding: the guard exists
    # to keep another project's name out of the product identity and out of user-facing text,
    # and the brief is explicit that provenance must not be obscured to satisfy it.
    "engine/native/droidvm_jit.c",
    "engine/native/droidvm_display.c",
    "engine/native/droidvm_runtime.c",
    "engine/native/droidvm_native.h",
    "engine/include/DroidVMBridge.h",
    "engine/jit/droidvm-brk.S",
    # engine/patches/README.md documents the upstream patches that are deliberately NOT
    # vendored, which requires naming them. That is provenance, not branding.
    "engine/patches/README.md",
}

# Words that must not appear outside the whitelist. Kept deliberately short: this is a
# branding guard, not a general-purpose word filter.
FOREIGN_MARKERS = ["husk"]

# Text files only. Binary formats would produce noise, and git already ignores them.
TEXT_SUFFIXES = {
    ".swift", ".c", ".h", ".m", ".mm", ".md", ".txt", ".sh", ".py", ".yml", ".yaml",
    ".json", ".plist", ".entitlements", ".pbxproj", ".xcconfig", ".modulemap",
}

SKIP_DIRS = {".git", "build", ".build", "DerivedData", "node_modules", "__pycache__"}


def iter_text_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            ext = os.path.splitext(name)[1].lower()
            if ext in TEXT_SUFFIXES:
                yield os.path.relpath(os.path.join(dirpath, name), ROOT).replace(os.sep, "/")


def check_no_foreign_branding():
    """Fail if another project's name appears outside the documented places.

    DroidVM is an independent product. Reused code is accounted for in THIRD_PARTY.md
    and described in the inventory; it must not appear as a product name, a bundle
    identifier or a UI string anywhere else.
    """
    offenders = []
    for rel in iter_text_files():
        if rel in PROVENANCE_WHITELIST:
            continue
        try:
            with open(os.path.join(ROOT, rel), "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read().lower()
        except OSError as exc:
            fail("could not read %s: %s" % (rel, exc))
            continue
        for marker in FOREIGN_MARKERS:
            if marker in text:
                # Report the first offending line so the fix is obvious.
                with open(os.path.join(ROOT, rel), "r", encoding="utf-8",
                          errors="replace") as fh:
                    for lineno, line in enumerate(fh, 1):
                        if marker in line.lower():
                            offenders.append("%s:%d: %s" % (rel, lineno, line.strip()[:100]))
                            break
                break

    if offenders:
        fail(
            "foreign branding found outside the provenance whitelist "
            "(%d file(s)). Reused code must be recorded in THIRD_PARTY.md and "
            "described in docs/component-inventory.md; it must not appear as a product "
            "name, bundle id or user-facing string." % len(offenders)
        )
        for entry in offenders[:15]:
            failures.append("    " + entry)
    else:
        ok("branding: clean outside %d whitelisted provenance file(s)"
           % len(PROVENANCE_WHITELIST))


# ------------------------------------------------------------------- assets

# Guest images, firmware and APKs are downloaded at runtime, never committed: they are
# hundreds of megabytes, they are other projects' distributions, and the kernel inside
# a guest image carries its own source-offer obligation.
FORBIDDEN_SUFFIXES = {
    ".qcow2", ".img", ".apk", ".ipa", ".dylib", ".a", ".o", ".fd",
    ".vmdk", ".raw", ".iso", ".gz", ".xz", ".zst", ".zip",
}

MAX_BYTES = 2 * 1024 * 1024   # 2 MiB: DroidVM's own sources and docs are far smaller.


def check_no_committed_assets():
    offenders = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            ext = os.path.splitext(name)[1].lower()
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            if ext in FORBIDDEN_SUFFIXES:
                offenders.append("%s (%s) -- forbidden artifact type" % (rel, ext))
            elif size > MAX_BYTES:
                offenders.append("%s (%.1f MiB) -- over the %d MiB limit"
                                 % (rel, size / 1048576.0, MAX_BYTES // 1048576))

    if offenders:
        fail("large or redistributable artifacts in the tree:")
        for entry in offenders[:15]:
            failures.append("    " + entry)
    else:
        ok("assets: no guest images, APKs or large binaries committed")


# ------------------------------------------------------------------ third party

THIRD_PARTY_COLUMNS = ["Source", "License", "Reuse", "Destination"]

# The obligations that decide how DroidVM may be distributed at all. If one of these
# disappears from the record, the record has stopped being useful.
THIRD_PARTY_MUST_MENTION = [
    "QEMU",
    "GPL",
    "ANGLE",
    "MoltenVK",
    "StikJIT",
    "StikDebug",
    "idevice",
]


def check_third_party_record():
    path = os.path.join(ROOT, "THIRD_PARTY.md")
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    for column in THIRD_PARTY_COLUMNS:
        if column not in text:
            fail("THIRD_PARTY.md lost its '%s' column" % column)

    lowered = text.lower()
    for term in THIRD_PARTY_MUST_MENTION:
        if term.lower() not in lowered:
            fail("THIRD_PARTY.md does not mention %s" % term)

    ok("third-party record: %d columns, %d required entries present"
       % (len(THIRD_PARTY_COLUMNS), len(THIRD_PARTY_MUST_MENTION)))


# ----------------------------------------------------------------- identity

SYMBOL_MANIFEST = "engine/symbols/required-symbols.txt"

# The only prefixes permitted in the manifest. `qemu_` comes from the engine; `droidvm_` is
# DroidVM's own. Anything else is a typo or a symbol that belongs to nobody.
ALLOWED_SYMBOL_PREFIXES = ("qemu_", "droidvm_")


def check_symbol_manifest():
    """The manifest must be well-formed, because two other gates trust it.

    The host gate verifies every `droidvm_` entry is defined in the built objects; gate 3
    verifies every entry is exported by the built dylib. Both read this file, so a duplicate
    or a typo here would be believed by both.
    """
    path = os.path.join(ROOT, SYMBOL_MANIFEST.replace("/", os.sep))
    if not os.path.isfile(path):
        fail("missing symbol manifest: %s" % SYMBOL_MANIFEST)
        return

    symbols = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            entry = line.split("#", 1)[0].strip()
            if not entry:
                continue
            if not entry.startswith(ALLOWED_SYMBOL_PREFIXES):
                fail("%s:%d: %r does not start with qemu_ or droidvm_"
                     % (SYMBOL_MANIFEST, lineno, entry))
                continue
            symbols.append(entry)

    if not symbols:
        fail("the symbol manifest lists nothing")
        return

    duplicates = sorted({s for s in symbols if symbols.count(s) > 1})
    if duplicates:
        fail("duplicate entries in the symbol manifest: %s" % ", ".join(duplicates))

    droidvm_count = len([s for s in symbols if s.startswith("droidvm_")])
    qemu_count = len([s for s in symbols if s.startswith("qemu_")])
    if droidvm_count == 0:
        fail("the symbol manifest declares no droidvm_ symbols")
    if qemu_count == 0:
        fail("the symbol manifest declares no qemu_ symbols; the engine's entry points "
             "are the reason the manifest exists")

    ok("symbol manifest: %d symbols (%d droidvm_, %d qemu_), no duplicates"
       % (len(symbols), droidvm_count, qemu_count))


def check_identity_values():
    """The bundle identifiers in the core package must be DroidVM's own."""
    path = os.path.join(ROOT, "core/Sources/DroidVMCore/Identity.swift")
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    match = re.search(r'bundleIdentifier\s*=\s*"([^"]+)"', text)
    if not match:
        fail("could not read bundleIdentifier from Identity.swift")
        return
    ident = match.group(1)
    if not ident.startswith("com.droidvm."):
        fail("bundle identifier %r is not in DroidVM's namespace" % ident)
    else:
        ok("identity: bundle identifier %s" % ident)


# Project formats DroidVM's CI baseline (Xcode 15.4) can open. Listed rather than derived,
# because "is this format too new" is exactly the judgement the default got wrong.
XCODE_15_PROJECT_FORMATS = ("xcode15_3", "xcode15_0")


def check_project_format():
    """app/project.yml must pin a project format our Xcode can actually open.

    XcodeGen defaults `projectFormat` to `xcode16_0`, which writes objectVersion 77. Relying on
    that default failed gate 3's APP LINK layer with "the project cannot be opened because it
    is in a future Xcode project file format (77)" -- after all five earlier layers had passed,
    so a green build looked like an app-link bug.

    Pinning it makes the generated project a function of this file rather than of whichever
    XcodeGen version the runner installs.
    """
    path = os.path.join(ROOT, "app/project.yml")
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    match = re.search(r"^\s*projectFormat:\s*[\"']?([A-Za-z0-9_]+)", text, re.MULTILINE)
    if not match:
        fail("app/project.yml does not pin projectFormat, so XcodeGen's default (xcode16_0, "
             "objectVersion 77) is used and Xcode 15.4 cannot open the project")
        return

    fmt = match.group(1)
    if fmt not in XCODE_15_PROJECT_FORMATS:
        fail("app/project.yml pins projectFormat %r, which is newer than the CI baseline "
             "(Xcode 15.4). Allowed: %s"
             % (fmt, ", ".join(XCODE_15_PROJECT_FORMATS)))
        return

    if not re.search(r"^\s*xcodeVersion:\s*[\"']?\d", text, re.MULTILINE):
        fail("app/project.yml sets projectFormat but not xcodeVersion")
        return

    ok("project format: %s, for Xcode 15.4" % fmt)


# ------------------------------------------------------------------- main

# ------------------------------------------------------------------- modes

def check_script_modes():
    """Every tracked script must be executable in Git.

    This exists because of a real failure. The scripts were created on Windows, where
    `core.fileMode` is false and Git does not track the executable bit, so all of them were
    committed as 100644. CI runs them directly:

        ./scripts/check_host.sh: Permission denied     (exit 126)

    Two consecutive runs failed on that and nothing else, because every other check in this
    file looks at content and none looked at the mode.

    The mode is read from the Git index, not the filesystem: the development machine's
    filesystem cannot express it, which is what caused the bug.
    """
    import subprocess
    try:
        result = subprocess.run(["git", "ls-files", "-s", "scripts/"],
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        ok("script modes: skipped (git unavailable: %s)" % exc)
        return

    if result.returncode != 0:
        fail("could not read file modes from the Git index: %s" % result.stderr.strip())
        return

    offenders = []
    checked = 0
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        mode, path = parts[0], parts[3]
        checked += 1
        if mode != "100755":
            offenders.append("%s has mode %s, expected 100755" % (path, mode))

    if checked == 0:
        fail("no tracked files under scripts/ -- the guard cannot be checking anything")
        return

    if offenders:
        fail("scripts are not executable in Git. CI invokes them directly, so every job "
             "will fail with 'Permission denied' (exit 126) before reaching a compiler:")
        for entry in offenders:
            failures.append("    " + entry)
        failures.append("    fix with: git update-index --chmod=+x <path>")
    else:
        ok("script modes: all %d tracked scripts are 100755" % checked)


def main():
    print("DroidVM repository guards")
    print("  root: %s" % ROOT)
    print("")

    check_required_files()
    check_no_foreign_branding()
    check_no_committed_assets()
    check_third_party_record()
    check_identity_values()
    check_script_modes()
    check_symbol_manifest()
    check_project_format()

    for note in notes:
        print("  ok   %s" % note)
    for problem in failures:
        print(("  FAIL %s" % problem) if not problem.startswith("    ") else problem)

    print("")
    if failures:
        print("guards: FAIL (%d problem(s))" % len(failures))
        return 1
    print("guards: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
