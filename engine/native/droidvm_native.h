/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * DroidVM's native engine internals.
 *
 * NOT part of the Swift-visible bridge. `DroidVMBridge.h` is the narrow door the
 * application reaches through; this header is the wiring behind it, used by the engine's
 * own translation units and by the host tests.
 *
 * The split matters. Everything in DroidVMBridge.h is a promise to Swift. Everything here
 * is an implementation detail of the C side, and most of it is deliberately portable so it
 * can be compiled and exercised on the development machine rather than only on a device.
 *
 * WHAT IS PORTABLE, AND WHY THAT IS THE POINT
 *
 * The six display counters and the JIT status machine contain the *rules* -- the parts that
 * can be wrong in ways that matter. They are plain C with no platform dependency, so the
 * host gate compiles them for real and asserts their transitions. Only the mechanism
 * underneath (the trap, `vm_remap`, QEMU's listener) needs Apple and QEMU.
 */

#ifndef DROIDVM_NATIVE_H
#define DROIDVM_NATIVE_H

#include "DroidVMBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 * Display stage counters
 *
 * One function per stage, and no generic `bump(kind)` accessor. The
 * point of six counters is that the call sites are forced to say
 * *which* stage they are in; a single increment function would make
 * "we dropped a frame" and "the guest had nothing to draw"
 * indistinguishable at the call site, which is the confusion the six
 * counters exist to prevent.
 *
 * These are called from the QEMU-side display listener. They are not
 * exported to Swift: the Swift adapters read the totals, they do not
 * increment them.
 * ------------------------------------------------------------------ */

void droidvm_display_note_entered(void);
void droidvm_display_note_received(void);
void droidvm_display_note_presented(void);
void droidvm_display_note_dropped(void);
void droidvm_display_note_no_scanout(void);
void droidvm_display_note_present_failure(void);

/* Zero every counter, the attachment flag and the registration flag. */
void droidvm_display_reset(void);

/* Zero every counter and the attachment flag. For a fresh machine. */
void droidvm_native_reset(void);

/* ------------------------------------------------------------------ *
 * Serial
 *
 * The launch plan routes serial to a file with -chardev file, so QEMU
 * writes it directly. This counter exists so the adapter can tell
 * whether the guest is saying anything without stat()ing the file on
 * every poll, and so a stalled boot can be distinguished from a silent
 * one.
 * ------------------------------------------------------------------ */

void droidvm_serial_note_bytes(uint64_t bytes);

/* Zero the serial counter. */
void droidvm_serial_reset(void);

/* ------------------------------------------------------------------ *
 * JIT internal seams
 *
 * The reason string is owned by the JIT translation unit and returned
 * as a static pointer, because the Swift side reads it immediately and
 * must not have to free it.
 * ------------------------------------------------------------------ */

void droidvm_jit_set_reason(const char *fmt, ...);

/* Whether the executable-memory mechanism is available at all on this
 * platform. Separate from `droidvm_jit_probe` so that the platform test
 * is one function rather than a preprocessor condition repeated in
 * three places. */
int droidvm_jit_platform_supported(void);

#ifdef __cplusplus
}
#endif

#endif /* DROIDVM_NATIVE_H */
