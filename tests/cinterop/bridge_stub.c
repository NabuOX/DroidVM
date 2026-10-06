/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * A host implementation of the engine bridge, for the interop harness.
 *
 * WHAT THIS IS FOR
 *
 * `DroidVMBridge.h` declares an ABI. Whether Swift can actually *use* that ABI -- how a C
 * enum imports, whether a struct gets a memberwise initialiser, whether an out-parameter
 * works, whether `size_t` is `Int`, whether a `char **` survives the boundary -- are
 * questions only a compiler answers. They do not need Apple frameworks, and they are
 * precisely the parts that would otherwise be discovered after a macOS CI round trip.
 *
 * So this file implements the declarations well enough to link and run on the host, and
 * `BridgeInterop.swift` drives them from Swift. What it proves is the ABI and the bridging.
 * What it does NOT prove is anything about QEMU, Metal, the JIT, or a device -- the bodies
 * here are stand-ins, and they return synthetic values. A test that could be mistaken for
 * device verification would be worse than no test.
 */

#include "DroidVMBridge.h"

#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- JIT */

static char g_reason[256] = "no failure recorded";
static int g_held = 0;
static size_t g_held_bytes = 0;

/* Synthetic region addresses. Distinct, page-aligned-looking, and obviously not real. */
static void *const kFakeExecutable = (void *)(uintptr_t)0x100000000ULL;
static void *const kFakeWritable   = (void *)(uintptr_t)0x200000000ULL;

/* The harness sets this to drive each branch of the status machine. */
int g_probe_result = DROIDVM_JIT_OK;
int g_capture_result = DROIDVM_JIT_OK;
size_t g_capture_granted = 0;

droidvm_jit_status droidvm_jit_probe(void)
{
    return (droidvm_jit_status)g_probe_result;
}

droidvm_jit_status droidvm_jit_capture(size_t bytes, droidvm_jit_region *out)
{
    if (g_capture_result != DROIDVM_JIT_OK) {
        return (droidvm_jit_status)g_capture_result;
    }
    if (g_held) {
        return DROIDVM_JIT_ALREADY_HELD;
    }
    g_held = 1;
    g_held_bytes = bytes;
    g_capture_granted = bytes;

    if (out) {
        out->executable = kFakeExecutable;
        out->writable = kFakeWritable;
        out->size = bytes;
    }
    return DROIDVM_JIT_OK;
}

droidvm_jit_status droidvm_jit_release(void)
{
    g_held = 0;
    g_held_bytes = 0;
    return DROIDVM_JIT_OK;
}

const char *droidvm_jit_last_reason(void)
{
    return g_reason;
}

/* Test seams, deliberately not in the production header. */
void droidvm_test_set_reason(const char *reason);
void droidvm_test_set_reason(const char *reason)
{
    if (!reason) {
        g_reason[0] = '\0';
        return;
    }
    strncpy(g_reason, reason, sizeof(g_reason) - 1);
    g_reason[sizeof(g_reason) - 1] = '\0';
}

/* ---------------------------------------------------------------- display */

static droidvm_display_counters g_counters;
static int g_display_registered = 0;
static int g_display_attached = 0;

size_t droidvm_display_counters_sizeof(void)
{
    return sizeof(droidvm_display_counters);
}

void droidvm_display_read(droidvm_display_counters *out)
{
    if (out) {
        *out = g_counters;
    }
}

int droidvm_display_register(void)
{
    if (g_display_registered) {
        return 1;
    }
    g_display_registered = 1;
    return 0;
}

int droidvm_display_is_attached(void)
{
    return g_display_attached;
}

void droidvm_display_set_attached(int attached)
{
    g_display_attached = attached ? 1 : 0;
}

/* Test seam: advance the counters so the reading path has something to carry. */
void droidvm_test_bump_counters(uint64_t entered, uint64_t received, uint64_t presented,
                                uint64_t dropped, uint64_t no_scanout,
                                uint64_t present_failure);
void droidvm_test_bump_counters(uint64_t entered, uint64_t received, uint64_t presented,
                                uint64_t dropped, uint64_t no_scanout,
                                uint64_t present_failure)
{
    g_counters.entered += entered;
    g_counters.received += received;
    g_counters.presented += presented;
    g_counters.dropped += dropped;
    g_counters.no_scanout += no_scanout;
    g_counters.present_failure += present_failure;
}

/* ---------------------------------------------------------------- serial */

static uint64_t g_serial_bytes = 0;

uint64_t droidvm_serial_bytes_written(void)
{
    return g_serial_bytes;
}

void droidvm_test_set_serial_bytes(uint64_t bytes);
void droidvm_test_set_serial_bytes(uint64_t bytes)
{
    g_serial_bytes = bytes;
}

/* ---------------------------------------------------------------- engine */

/* Recorded so the harness can check that argc and argv arrived intact -- the point being
 * that Swift built a `char **` and C read it back. */
int g_qemu_init_calls = 0;
int g_qemu_init_argc = -1;
char g_qemu_init_argv0[256] = { 0 };
char g_qemu_init_argv1[256] = { 0 };
int g_qemu_main_loop_calls = 0;
int g_qemu_cleanup_calls = 0;

int qemu_init(int argc, char **argv)
{
    g_qemu_init_calls++;
    g_qemu_init_argc = argc;
    if (argv && argc > 0 && argv[0]) {
        strncpy(g_qemu_init_argv0, argv[0], sizeof(g_qemu_init_argv0) - 1);
    }
    if (argv && argc > 1 && argv[1]) {
        strncpy(g_qemu_init_argv1, argv[1], sizeof(g_qemu_init_argv1) - 1);
    }
    return 0;
}

int qemu_main_loop(void)
{
    g_qemu_main_loop_calls++;
    return 0;
}

void qemu_cleanup(void)
{
    g_qemu_cleanup_calls++;
}
