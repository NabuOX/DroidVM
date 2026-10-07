/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * DroidVM -- QEMU-internal runtime markers.
 *
 * NOT the app-facing bridge. The patched system/runstate.c includes THIS header, not
 * DroidVMBridge.h, so QEMU's main loop reports its own state without depending on the
 * app-facing contract to do it.
 *
 * WHY THESE ARE NOT IN system/qemu.symbols
 *
 * Separate translation units inside one dylib link against each other without appearing in the
 * dynamic export list. system/runstate.c and droidvm_qemu_runtime.c are both compiled into
 * libqemu-aarch64-softmmu.dylib, so these are ordinary external symbols, resolved at link time
 * within the image. Putting them in the export list would widen the dynamic ABI for no reason
 * and would make the export gate assert something nobody needs.
 *
 * They are also deliberately absent from DroidVMBridge.h: nothing in the app calls them, and a
 * declaration there would put them into the app-facing surface -- and into the manifest the
 * gate checks -- by accident.
 */
#ifndef DROIDVM_QEMU_RUNTIME_H
#define DROIDVM_QEMU_RUNTIME_H

#ifdef __cplusplus
extern "C" {
#endif

/* Called from INSIDE qemu_main_loop()'s loop body. Reaching it means an iteration genuinely
 * began; anywhere else and a loop that exits immediately would report as running. */
void droidvm_runtime_note_loop_iteration(void);

/* Called after qemu_main_loop() returns. Unconditional: no reader may see "running" after it. */
void droidvm_runtime_note_loop_exited(void);

/* Records an engine-side failure against a stable reason string. */
void droidvm_runtime_note_failed(const char *reason);

#ifdef __cplusplus
}
#endif

#endif /* DROIDVM_QEMU_RUNTIME_H */
