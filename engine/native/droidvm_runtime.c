/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * DroidVM's native runtime support.
 *
 * WHAT THIS FILE IS NOT
 *
 * It does not implement `qemu_init`, `qemu_main_loop` or `qemu_cleanup`. Those are QEMU's
 * own entry points, declared in DroidVMBridge.h so the Swift side can resolve them from the
 * shared library, and provided by QEMU when the engine is linked. Defining them here would
 * collide with the engine and, worse, would mean DroidVM shipping a second, fake QEMU.
 *
 * WHAT IT IS
 *
 * The small amount of state that belongs to DroidVM rather than to QEMU, and that would
 * otherwise be a global somewhere in a Swift adapter:
 *
 *   * serial byte accounting, so a stalled boot can be told from a silent one
 *   * the process-wide reset, so a second machine starts from a clean slate instead of
 *     inheriting counters from the first
 *
 * The serial figure exists because the launch plan routes serial to a file with
 * `-chardev file`. QEMU writes it directly; this counts what has been written, so the
 * adapter can see whether the guest is talking without stat()ing the file on every poll.
 */

#include "droidvm_native.h"

/* ------------------------------------------------------------------ *
 * Serial
 * ------------------------------------------------------------------ */

static uint64_t g_serial_bytes = 0;

void droidvm_serial_note_bytes(uint64_t bytes)
{
    /* Saturating rather than wrapping. A counter that wraps to zero would read as "nothing
     * has been written", which is the opposite of the truth and would make a chatty guest
     * look silent -- exactly the confusion this figure exists to resolve. */
    if (UINT64_MAX - g_serial_bytes < bytes) {
        g_serial_bytes = UINT64_MAX;
        return;
    }
    g_serial_bytes += bytes;
}

uint64_t droidvm_serial_bytes_written(void)
{
    return g_serial_bytes;
}

void droidvm_serial_reset(void)
{
    g_serial_bytes = 0;
}

/* ------------------------------------------------------------------ *
 * Process-wide reset
 *
 * One machine per process is DroidVM's model. Restarting means resetting;
 * leaving counters from a previous run in place would make the second
 * machine's first window look like it had already presented frames.
 * ------------------------------------------------------------------ */

void droidvm_native_reset(void)
{
    droidvm_display_reset();
    droidvm_serial_reset();
}
