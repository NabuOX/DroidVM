/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Host stand-ins for QEMU's three entry points, for the interop harness.
 *
 * WHAT THIS IS, AND WHAT IT IS NOT
 *
 * `DroidVMBridge.h` declares `qemu_init`, `qemu_main_loop` and `qemu_cleanup` because the
 * Swift adapter resolves them from the engine shared library at runtime. In a real build
 * QEMU provides them. On the development host there is no QEMU, so this file provides
 * three small stand-ins that record what they were called with.
 *
 * It exists so that the harness can link the REAL native bridge -- the sources under
 * engine/native -- rather than a double of it. Everything DroidVM actually owns is the real
 * thing in that link; the only fiction is QEMU's side, which is the part that cannot be
 * present on a host by definition.
 *
 * It is NOT a test of QEMU, and it proves nothing about QEMU. It proves that DroidVM's
 * argument vector crosses the boundary intact and that the function-pointer call works.
 */

#include "DroidVMBridge.h"

#include <stdint.h>
#include <string.h>

static int g_init_calls = 0;
static int g_init_argc = -1;
static char g_init_argv0[256];
static char g_init_argv1[256];
static int g_main_loop_calls = 0;
static int g_cleanup_status = -1;

void qemu_init(int argc, char **argv)
{
    g_init_calls++;
    g_init_argc = argc;

    if (argv != NULL && argc > 0 && argv[0] != NULL) {
        strncpy(g_init_argv0, argv[0], sizeof(g_init_argv0) - 1);
        g_init_argv0[sizeof(g_init_argv0) - 1] = '\0';
    }
    if (argv != NULL && argc > 1 && argv[1] != NULL) {
        strncpy(g_init_argv1, argv[1], sizeof(g_init_argv1) - 1);
        g_init_argv1[sizeof(g_init_argv1) - 1] = '\0';
    }
}

int qemu_main_loop(void)
{
    g_main_loop_calls++;
    return 0;
}

void qemu_cleanup(int status)
{
    /* Recorded so the ABI test can prove the argument arrived, which also proves the call did. */
    g_cleanup_status = status;
}

/* ------------------------------------------------------------------ *
 * Inspection, for the harness
 *
 * Accessors rather than exported globals: a global read through
 * @_silgen_name depends on the symbol's type matching, which is
 * fragile, while a function returning the value is checked.
 * ------------------------------------------------------------------ */

int droidvm_shim_qemu_init_calls(void)      { return g_init_calls; }
int droidvm_shim_qemu_init_argc(void)       { return g_init_argc; }
int droidvm_shim_qemu_main_loop_calls(void) { return g_main_loop_calls; }
int droidvm_shim_qemu_cleanup_status(void)  { return g_cleanup_status; }

const char *droidvm_shim_qemu_init_argv0(void) { return g_init_argv0; }
const char *droidvm_shim_qemu_init_argv1(void) { return g_init_argv1; }

void droidvm_shim_qemu_reset(void)
{
    g_init_calls = 0;
    g_init_argc = -1;
    g_main_loop_calls = 0;
    g_init_argv0[0] = '\0';
    g_init_argv1[0] = '\0';
}
