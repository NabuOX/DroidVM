/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * DroidVM's bridge to its engine.
 *
 * This is the ONLY header the Swift side includes to reach the engine. Everything the
 * application layer is forbidden to know about -- QEMU's internals, its symbol table, the
 * executable-memory mechanism, the display listener registration -- is behind these
 * declarations and the adapters that use them.
 *
 * STATUS: written in Phase 1, NOT COMPILED. It needs the iOS SDK and the built engine
 * dylib. scripts/check_engine.sh syntax-checks the parts that have no Apple dependency;
 * everything else is verified by the macOS CI gate, and nothing here is verified by the
 * host gate.
 *
 * The declarations are deliberately narrow. A wide bridge is a wide surface for the
 * application to reach through, which is the coupling the ownership model exists to
 * prevent.
 */

#ifndef DROIDVM_BRIDGE_H
#define DROIDVM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ *
 * Engine lifecycle
 *
 * The engine is QEMU built as a shared library rather than an
 * executable, because an iOS app cannot spawn processes: the machine
 * has to live inside this one. These three are QEMU's own entry
 * points, exported by the dylib.
 *
 * They are NOT renamed. The Phase 1 brief asks for DroidVM-owned
 * symbols but also warns against mechanical renaming that would make
 * comparison with upstream impossible -- and these are upstream's
 * public API, called by name from the adapter. The DroidVM-owned
 * boundary is the Swift protocol above them, not a prefix here.
 * ------------------------------------------------------------------ */

/* Build the machine. Returns 0 on success. argv follows QEMU's own
 * conventions; DroidVM constructs it in QEMULaunchPlanBuilder so that
 * the machine definition stays a testable value. */
int qemu_init(int argc, char **argv);

/* Run until the machine stops. Blocking; called on its own thread. */
int qemu_main_loop(void);

/* Tear down after main_loop returns. */
void qemu_cleanup(void);

/* ------------------------------------------------------------------ *
 * Executable memory
 *
 * iOS will not hand out a mapping that is both writable and executable,
 * so translated code and the translator that produces it need two views
 * of the same pages: one executable, one writable. An attached debugger
 * is what makes the executable view possible, and it is asked for it
 * through a trap.
 *
 * See droidvm-brk.S for the protocol, and droidvm_jit.c for the
 * implementation. The asymmetry is the point: the region is captured
 * once, before anything else can consume the helper's attention.
 * ------------------------------------------------------------------ */

typedef struct droidvm_jit_region {
    void   *executable;   /* RX view: where translated code runs        */
    void   *writable;     /* RW view of the same pages                  */
    size_t  size;         /* bytes, both views                          */
} droidvm_jit_region;

typedef enum droidvm_jit_status {
    DROIDVM_JIT_OK               = 0,
    DROIDVM_JIT_NOT_PERMITTED    = 1,  /* environment does not allow it   */
    DROIDVM_JIT_ALLOCATION_FAILED= 2,
    DROIDVM_JIT_SELF_TEST_FAILED = 3,  /* mapped but cannot execute       */
    DROIDVM_JIT_ALREADY_HELD     = 4,
    DROIDVM_JIT_UNSUPPORTED      = 5
} droidvm_jit_status;

/* Non-destructive availability check. Never traps, never allocates. */
droidvm_jit_status droidvm_jit_probe(void);

/* Capture a region of at least `bytes`. Returns DROIDVM_JIT_OK and
 * fills `out` on success. Performs an execute self-test before
 * reporting success -- a region that is mapped but cannot execute is
 * the failure mode that is otherwise indistinguishable from working. */
droidvm_jit_status droidvm_jit_capture(size_t bytes, droidvm_jit_region *out);

/* Release the region, if the platform permits it. */
droidvm_jit_status droidvm_jit_release(void);

/* A human-readable reason for the last failure. Static storage; valid
 * until the next call. Not for display to a user -- the adapter maps
 * the status onto DroidVM's own plain language. */
const char *droidvm_jit_last_reason(void);

/* ------------------------------------------------------------------ *
 * Display
 *
 * DroidVM registers its own DisplayChangeListener, so QEMU needs no
 * display backend of its own (the plan passes -display none). The
 * listener counts each stage of the frame path; those counters are the
 * evidence the graphics health monitor reasons about.
 *
 * Six counters, never one. See DisplayCounters in DroidVMCore.
 * ------------------------------------------------------------------ */

typedef struct droidvm_display_counters {
    uint64_t entered;         /* display-update path entered            */
    uint64_t received;        /* a frame was handed to us               */
    uint64_t presented;       /* a frame reached the screen             */
    uint64_t dropped;         /* a frame was taken and not drawn        */
    uint64_t no_scanout;      /* asked to draw, guest had nothing       */
    uint64_t present_failure; /* the present call failed                */
} droidvm_display_counters;

/* Size of the counters struct, so the Swift side can assert that its
 * mirror agrees rather than assuming. A silent layout mismatch here
 * would produce plausible, wrong numbers. */
size_t droidvm_display_counters_sizeof(void);

/* Read the counters. Monotonic; never resets while the machine lives. */
void droidvm_display_read(droidvm_display_counters *out);

/* Register the listener. Returns 0 on success, non-zero on failure:
 *
 *   1  a listener is already registered, and a second would orphan
 *      the first surface -- which shows up as a frame counter
 *      climbing against a black screen
 *   2  this build has no engine to register with
 *
 * The codes are distinguished rather than collapsed, because only one
 * of them is a bug in the caller. `droidvm_display_last_reason()`
 * carries the detail. */
int droidvm_display_register(void);

/* A human-readable reason for the last display-side refusal or
 * transition. Static storage; valid until the next call. Not for
 * display to a user -- the Swift adapter maps it onto DroidVM's own
 * plain language. */
const char *droidvm_display_last_reason(void);

/* Whether a display surface is currently bound. */
int droidvm_display_is_attached(void);

/* Called by the platform adapter when a surface becomes available or is
 * lost. The engine cannot discover a CAMetalLayer by itself. */
void droidvm_display_set_attached(int attached);

/* ------------------------------------------------------------------ *
 * Serial
 *
 * The plan routes serial to a file with -chardev file. The adapter
 * reads that file; nothing here is needed for that. This declaration
 * exists only for the case where the adapter wants to be told when the
 * file has grown, without polling.
 * ------------------------------------------------------------------ */

uint64_t droidvm_serial_bytes_written(void);

/* ------------------------------------------------------------------ *
 * Runtime confirmation
 *
 * THE QUESTION LEVEL D EXISTS TO ANSWER: has QEMU's main execution loop
 * actually started running?
 *
 * Not "was the machine constructed" and not "did qemu_init return 0".
 * QEMURuntime's own isRunning is set as soon as qemu_init returns, one
 * statement BEFORE qemu_main_loop() is called, so it is true in the
 * window before the loop is entered and stays true if the loop returns
 * immediately. It answers a different question.
 *
 * This state advances ONLY from inside qemu_main_loop()'s loop body, so
 * MAIN_LOOP_ENTERED is unreachable unless a real iteration began.
 *
 * OWNERSHIP: one copy, inside the QEMU dylib. These symbols are NOT
 * compiled into the app -- the app resolves them from the loaded engine
 * the same way it resolves qemu_init. Two copies of this state would
 * mean the app reading a value nothing ever writes.
 *
 * Thread-safe: written by the engine thread from inside the loop, read
 * by the app's runtime executor. C11 atomics.
 * ------------------------------------------------------------------ */

typedef enum droidvm_runtime_state {
    DROIDVM_RUNTIME_NOT_STARTED       = 0,
    DROIDVM_RUNTIME_INITIALIZED       = 1,  /* qemu_init returned 0      */
    DROIDVM_RUNTIME_MAIN_LOOP_ENTERED = 2,  /* a real iteration began    */
    DROIDVM_RUNTIME_MAIN_LOOP_EXITED  = 3,  /* the loop returned         */
    DROIDVM_RUNTIME_FAILED            = 4
} droidvm_runtime_state;

/* The current state. */
droidvm_runtime_state droidvm_runtime_state_get(void);

/* True ONLY for MAIN_LOOP_ENTERED: "a loop iteration has begun and the
 * loop has not yet exited". INITIALIZED is deliberately NOT running. */
int droidvm_runtime_is_running(void);

/* A human-readable reason for the last transition. Static storage; valid
 * until the next transition. Never empty. */
const char *droidvm_runtime_last_reason(void);

/* THE ONE CONTROL SYMBOL THE APP CALLS.
 *
 * QEMURuntime calls this immediately after qemu_init returns 0, which is the only place that
 * fact is known: the engine cannot report it itself without a patch to qemu_init, and that
 * would be an invasive change to code this integration has no other reason to touch. So it is
 * the single control function that must be dynamically visible.
 *
 * It is exported and queried through dlsym from the SAME loaded engine image. Nothing in the
 * app defines it. INITIALIZED is explicitly NOT "running" -- see droidvm_runtime_is_running().
 *
 * The loop markers are NOT here. system/runstate.c includes droidvm_qemu_runtime.h instead,
 * because separate translation units in one dylib link without joining the export list. */
void droidvm_runtime_note_initialized(void);

#ifdef __cplusplus
}
#endif

#endif /* DROIDVM_BRIDGE_H */
