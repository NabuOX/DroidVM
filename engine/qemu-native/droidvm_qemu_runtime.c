/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * DroidVM -- QEMU runtime state.
 *
 * THE ONE QUESTION THIS FILE EXISTS TO ANSWER
 *
 *   Has QEMU's main execution loop actually started running?
 *
 * Not "was the machine constructed", not "did qemu_init return 0", not "did Swift
 * launch a thread". The loop itself, entered and not yet exited.
 *
 * WHY THAT DISTINCTION IS THE WHOLE POINT
 *
 * QEMURuntime.start() marks itself running as soon as qemu_init returns 0, one
 * statement before it calls qemu_main_loop(). That is true in the window before the
 * loop is entered, and it stays true if the loop returns immediately -- so it can
 * report a running machine that never executed anything.
 *
 * A marker placed there would have the same defect, so there isn't one. The state
 * below advances ONLY from inside qemu_main_loop()'s loop body, which means
 * MAIN_LOOP_ENTERED is unreachable unless a real iteration began.
 *
 * THREAD SAFETY
 *
 * Written by the engine thread from inside the loop; read by the app's runtime
 * executor through the bridge. C11 atomics, because the reader must never block and
 * the writer is on the hot path -- a lock here would be taken once per loop
 * iteration for a value that is one word.
 *
 * The reason strings are static literals, so publishing one is a single atomic
 * pointer store and reading one needs no lock either.
 */

#include "qemu/osdep.h"

#include <stdatomic.h>

#include "DroidVMBridge.h"
/* The QEMU-internal markers. Declared here so these definitions satisfy a prototype
 * and cannot drift from what the patched system/runstate.c is told to call. */
#include "droidvm_qemu_runtime.h"

/* The Swift side mirrors these by numeric value (DroidVMRuntimeState). Pinning them here
 * means a change to the enum fails a build rather than silently misreporting on the other side
 * of the bridge -- which would look exactly like a machine that will not start. */
_Static_assert(DROIDVM_RUNTIME_NOT_STARTED == 0, "mirrored in Swift as .notStarted");
_Static_assert(DROIDVM_RUNTIME_INITIALIZED == 1, "mirrored in Swift as .initialized");
_Static_assert(DROIDVM_RUNTIME_MAIN_LOOP_ENTERED == 2, "mirrored in Swift as .mainLoopEntered");
_Static_assert(DROIDVM_RUNTIME_MAIN_LOOP_EXITED == 3, "mirrored in Swift as .mainLoopExited");
_Static_assert(DROIDVM_RUNTIME_FAILED == 4, "mirrored in Swift as .failed");

static _Atomic int g_state = DROIDVM_RUNTIME_NOT_STARTED;
static _Atomic(const char *) g_reason = NULL;

/* ------------------------------------------------------------------ *
 * QEMU side. Called from the patched qemu_main_loop() and from the
 * notifier that runs after machine initialisation.
 * ------------------------------------------------------------------ */

void droidvm_runtime_note_initialized(void)
{
    /* Only from NOT_STARTED: a second qemu_init in one process must not be able to
     * walk the state backwards past a loop that is running. */
    int expected = DROIDVM_RUNTIME_NOT_STARTED;
    atomic_compare_exchange_strong_explicit(&g_state, &expected,
                                            DROIDVM_RUNTIME_INITIALIZED,
                                            memory_order_release,
                                            memory_order_relaxed);
    if (expected == DROIDVM_RUNTIME_NOT_STARTED) {
        atomic_store_explicit(&g_reason, "qemu_init completed", memory_order_relaxed);
    }
}

void droidvm_runtime_note_loop_iteration(void)
{
    /* First iteration promotes INITIALIZED -> MAIN_LOOP_ENTERED.
     *
     * Placed INSIDE the loop body, so it is reached only when the loop is genuinely
     * executing. A marker before the while loop would be reached by a loop that
     * exits immediately, which is the exact lie this file exists to prevent.
     *
     * later iterations are a no-op: compare_exchange fails because the state is
     * already MAIN_LOOP_ENTERED, and the state must not be rewritten every
     * iteration on the hot path. */
    int expected = DROIDVM_RUNTIME_INITIALIZED;
    if (atomic_compare_exchange_strong_explicit(&g_state, &expected,
                                                DROIDVM_RUNTIME_MAIN_LOOP_ENTERED,
                                                memory_order_acq_rel,
                                                memory_order_relaxed)) {
        atomic_store_explicit(&g_reason, "main loop entered", memory_order_relaxed);
    }
}

void droidvm_runtime_note_loop_exited(void)
{
    /* Unconditional: whatever the state was, the loop is not running now, and a
     * reader must never see "running" after this returns. */
    atomic_store_explicit(&g_reason, "main loop exited", memory_order_relaxed);
    atomic_store_explicit(&g_state, DROIDVM_RUNTIME_MAIN_LOOP_EXITED,
                          memory_order_release);
}

void droidvm_runtime_note_failed(const char *reason)
{
    atomic_store_explicit(&g_reason, reason ? reason : "runtime failed",
                          memory_order_relaxed);
    atomic_store_explicit(&g_state, DROIDVM_RUNTIME_FAILED, memory_order_release);
}

/* ------------------------------------------------------------------ *
 * Bridge side. Stable, minimal, and the only things Swift calls.
 * ------------------------------------------------------------------ */

droidvm_runtime_state droidvm_runtime_state_get(void)
{
    return (droidvm_runtime_state)atomic_load_explicit(&g_state, memory_order_acquire);
}

int droidvm_runtime_is_running(void)
{
    /* TRUE only for MAIN_LOOP_ENTERED, and only for as long as it lasts. After
     * droidvm_runtime_note_loop_exited() this is false even though the loop did
     * once run -- "has entered and has not yet exited" is the whole predicate. */
    return droidvm_runtime_state_get() == DROIDVM_RUNTIME_MAIN_LOOP_ENTERED ? 1 : 0;
}

const char *droidvm_runtime_last_reason(void)
{
    const char *reason = atomic_load_explicit(&g_reason, memory_order_acquire);
    return reason ? reason : "";
}
