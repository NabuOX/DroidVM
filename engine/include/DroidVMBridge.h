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

/* THESE MUST MATCH QEMU'S OWN DECLARATIONS, character for character, because this header is
 * included from engine-side sources that have already included QEMU's. A mismatch is a compile
 * error inside QEMU, and the authority is include/system/system.h.
 *
 * Build the machine. Returns NOTHING: QEMU exits the process itself on a fatal configuration
 * error, so returning at all is the success signal. It was declared `int` here until gate 3
 * caught the conflict -- and the Swift side was comparing that non-existent return value
 * against zero. argv follows QEMU's conventions; DroidVM builds it in QEMULaunchPlanBuilder so
 * the machine definition stays a testable value. */
void qemu_init(int argc, char **argv);

/* Run until the machine stops. Blocking; called on its own thread. */
int qemu_main_loop(void);

/* Tear down after main_loop returns. Takes QEMU's exit status; calling it with no argument
 * passed whatever the register held. */
void qemu_cleanup(int status);

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
    DROIDVM_JIT_UNSUPPORTED      = 5,

    /* Diagnostics ran and execution was DELIBERATELY not attempted.
     *
     * A distinct value on purpose. SELF_TEST_FAILED means "mapped but cannot execute", so returning
     * it here would report an execution failure that never happened -- a false reason, which is the
     * one thing a device diagnostic must not produce. */
    DROIDVM_JIT_DIAGNOSTIC_STOP  = 6
} droidvm_jit_status;

/* Non-destructive availability check. Never traps, never allocates. */
droidvm_jit_status droidvm_jit_probe(void);

/* The bring-up pipeline, in one call.
 *
 * It asks the provider for the executable region (x0 = NULL, x1 = `bytes`), MEASURES the returned
 * range rather than presuming it from one vm_region_64 answer, aliases the proven range READ|WRITE,
 * writes a known instruction sequence through the alias and verifies it back through the executable
 * view, and -- only if all of that passed -- executes one stub from the region and requires the
 * expected constant back.
 *
 * Returns DROIDVM_JIT_OK and fills `out` only when every stage passed, which is what `jit: READY`
 * means. Any earlier failure returns that stage's status with the stage named in the reason.
 *
 * The provider's region is deliberately NOT released: no ownership contract for it is proven, so its
 * lifetime is left to process termination rather than risk unmapping memory DroidVM does not own. The
 * local writable alias, which DroidVM does create, is released on every failure path and held on
 * success.
 *
 * The prepare runs at most once per process. */
droidvm_jit_status droidvm_jit_capture(size_t bytes, droidvm_jit_region *out);

/* Where the bring-up pipeline got to, stage by stage.
 *
 * A single status cannot say which stage passed and which stopped: `FAILED` after a rejected range
 * and `FAILED` after a stub that faulted are different problems, and the whole point of one
 * consolidated device test is to tell them apart from one report. */
typedef struct droidvm_bringup_stage {
    int not_run;        /* 0 = the stage ran, 1 = it was never reached */
    int passed;         /* meaningful only when not_run is 0 */
} droidvm_bringup_stage;

typedef struct droidvm_bringup_report {
    droidvm_bringup_stage provider_prepare;
    droidvm_bringup_stage provider_range;
    droidvm_bringup_stage rw_alias;
    droidvm_bringup_stage readback;
    droidvm_bringup_stage jit_selftest;

    unsigned long long requested_bytes;
    unsigned long long contiguous_rx_bytes;   /* proven by the walk, before the request is judged */
    unsigned long long usable_bytes;
    unsigned long long first_region_size;
    unsigned int regions_walked;
    int range_complete;
    int first_gap_offset;
    int gap_reason;
    int rx_cur_prot;
    int rx_max_prot;
} droidvm_bringup_report;

/* The stages recorded so far. Safe to call at any time; untouched stages read as not_run. */
void droidvm_jit_bringup_report_get(droidvm_bringup_report *out);

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

/* ------------------------------------------------------------------ *
 * Display integration (D.1b)
 *
 * The lifecycle of DroidVM's QEMU DisplayChangeListener. Every value here
 * is written by QEMU's main loop thread and read by the app, so they are
 * atomics on the engine side.
 *
 * SEPARATE FROM THE FRAME COUNTERS ABOVE, ON PURPOSE. "QEMU has a graphic
 * console" and "frames are reaching the screen" are different facts, and
 * collapsing them is how a console would start meaning a working display.
 * Nothing here reports readiness.
 *
 * Arming MUST happen before qemu_init: the machine-init-done notifier that
 * performs the registration fires during it.
 * ------------------------------------------------------------------ */

typedef enum droidvm_display_state {
    DROIDVM_DISPLAY_NOT_ATTEMPTED       = 0,
    DROIDVM_DISPLAY_LISTENER_REGISTERED = 1,  /* console validated and bound */
    DROIDVM_DISPLAY_ATTACHED            = 2,  /* a host surface is bound too */
    DROIDVM_DISPLAY_DETACHED            = 3,
    DROIDVM_DISPLAY_FAILED              = 4
} droidvm_display_state;

/* Arm the notifier that registers the listener. Call before qemu_init. */
void droidvm_display_qemu_start(void);

/* One consistent read of every display fact.
 *
 * A snapshot rather than a getter per field, for two reasons. Reading width and
 * height separately can observe geometry from two DIFFERENT surfaces, which is
 * exactly the stale-size bug this integration exists to avoid. And one export is
 * one thing to keep in step with the app.
 *
 * width/height/stride are ZERO until a surface has been observed. Zero is not a
 * measurement, which is why the app reports absent rather than 0x0. */
typedef struct droidvm_display_snapshot {
    int state;                              /* droidvm_display_state */
    int width;
    int height;
    int stride;
    unsigned long long updates;             /* real QEMU gfx update callbacks */
    unsigned long long surface_replacements;
} droidvm_display_snapshot;

void droidvm_display_snapshot_get(droidvm_display_snapshot *out);

/* Why the state is what it is. Static storage; never empty. */
const char *droidvm_display_qemu_last_reason(void);

/* Called by the app when it binds or loses a host surface. Not the same fact
 * as the engine having a console, which is why it is a separate call. */
void droidvm_display_qemu_note_host_attachment(int attached);

#ifdef __cplusplus
}
#endif

#endif /* DROIDVM_BRIDGE_H */
