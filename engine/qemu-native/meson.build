# SPDX-License-Identifier: GPL-2.0-or-later
#
# DroidVM's QEMU integration unit.
#
# Copied into the QEMU source tree as `droidvm/` by scripts/integrate_engine.sh, which also adds
# `subdir('droidvm')` to QEMU's top-level meson.build.
#
# WHY THIS FILE EXISTS AT ALL
#
# The original integration copied DroidVM's sources into QEMU's tree and stopped there. Copying is
# not compiling: the files landed on disk and no Meson target referenced them, so nothing was ever
# built into the dylib -- and the only symptom was a symbol missing at dlopen, long after the build
# reported success.
#
# TWO STATEMENTS, NOT ONE, AND THE SECOND IS THE IMPORTANT ONE
#
# QEMU's `SourceSet.add` accepts `str`, `File`, `GeneratedList`, `CustomTarget`,
# `CustomTargetIndex` and `Dependency` -- and NOT `IncludeDirs`. Passing the `include_directories`
# object straight in failed at Meson setup with:
#
#   ../droidvm/meson.build:28:19: ERROR: sourceset.add argument 2 was of type "IncludeDirs"
#   but should have been one of: "str", "File", "GeneratedList", "CustomTarget",
#   "CustomTargetIndex", "Dependency"
#
# A dependency is the accepted form, so the include path becomes one:
#
#   declare_dependency(include_directories: ...)
#
# WHY IT IS ADDED TO `system_ss` AND NOT TO A SEPARATE SET
#
# `system/runstate.c` includes `droidvm_qemu_runtime.h`, so the include path has to be visible when
# THAT file compiles -- not only when `droidvm_qemu_runtime.c` does. Putting the dependency in a
# private source set and merging it with `add_all` would leave the propagation question open.
#
# Adding it to `system_ss` itself closes it, and it is QEMU's own pattern for exactly this reason:
# `ui/meson.build` does `system_ss.add(pixman)`, `system_ss.add(png)` and `system_ss.add(opengl)`
# so that every source in the set compiles against those include paths. A dependency added to a
# source set applies to the whole set.

system_ss.add(files('droidvm_qemu_runtime.c'))
# The display listener. Compiles against QEMU's own ui/console.h, which is why it can
# only live here -- the app target excludes qemu-native/** entirely.
system_ss.add(files('droidvm_qemu_display.c'))

# The include path that makes `droidvm_qemu_runtime.h` discoverable from the patched
# system/runstate.c in the same source set.
system_ss.add(declare_dependency(include_directories: include_directories('.')))
