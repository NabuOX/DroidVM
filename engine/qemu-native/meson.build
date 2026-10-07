# SPDX-License-Identifier: GPL-2.0-or-later
#
# DroidVM's QEMU integration unit.
#
# Copied into the QEMU source tree as `droidvm/` by scripts/integrate_engine.sh, which also
# adds `subdir('droidvm')` to QEMU's top-level meson.build.
#
# WHY THIS FILE EXISTS AT ALL
#
# The previous integration copied DroidVM's sources into QEMU's tree and stopped there. Copying
# is not compiling: the files landed on disk and no Meson target referenced them, so nothing was
# ever built into the dylib -- and the only symptom was a symbol missing at dlopen, long after
# the build reported success. The integration is only real when Meson compiles the source and
# the symbol turns up in the produced library, which is what scripts/build_engine_ios.sh now
# verifies.
#
# `system_ss` is QEMU's softmmu source set, and it is what feeds the shared library that
# `--enable-shared-lib` produces. Adding to it here is the whole mechanism.

droidvm_inc = include_directories('.')

# The runtime-state module, and nothing else yet.
#
# It is deliberately alone: it is the only DroidVM source that must live inside the engine at
# this stage, because only the engine can observe its own main loop. The display listener is a
# separate, later integration.
droidvm_runtime_ss = ss.source_set()
droidvm_runtime_ss.add(files('droidvm_qemu_runtime.c'), droidvm_inc)

system_ss.add_all(droidvm_runtime_ss)
