/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * DroidVM -- the QEMU display listener.
 *
 * Registered from `qemu_add_machine_init_done_notifier`, which fires after `virtio-gpu-pci` is
 * realized (so the console exists) and before `qemu_main_loop` (so no frame is missed). That means
 * the notifier is armed BEFORE `qemu_init`, via `droidvm_display_qemu_start()`.
 *
 * This file owns every D.1b display fact. It does not call engine/native/droidvm_display.c, which
 * is compiled into the app: doing so would give the process two of every counter, with Swift
 * reading the one nothing writes.
 *
 * QEMU owns every DisplaySurface it passes us; we read the geometry and never retain the pointer.
 * Nothing here reports readiness.
 */
#include "qemu/osdep.h"

#include "qemu/notify.h"
#include "system/system.h"
#include "ui/console.h"
#include "ui/surface.h"

#include <stdatomic.h>

#include "DroidVMBridge.h"

/* ------------------------------------------------------------------ *
 * State. Scalars are atomic: written by QEMU's thread, read by the
 * app's executor. The reason is a buffer copy, so it takes a lock.
 * ------------------------------------------------------------------ */

/* The Swift side mirrors these by numeric value (DroidVMDisplayState). Pinning them here means
 * a change to the enum fails a build rather than silently misreporting across the bridge -- which
 * would look exactly like a display that never registers. */
_Static_assert(DROIDVM_DISPLAY_NOT_ATTEMPTED == 0, "mirrored in Swift as .notAttempted");
_Static_assert(DROIDVM_DISPLAY_LISTENER_REGISTERED == 1, "mirrored in Swift as .listenerRegistered");
_Static_assert(DROIDVM_DISPLAY_ATTACHED == 2, "mirrored in Swift as .attached");
_Static_assert(DROIDVM_DISPLAY_DETACHED == 3, "mirrored in Swift as .detached");
_Static_assert(DROIDVM_DISPLAY_FAILED == 4, "mirrored in Swift as .failed");

static _Atomic int g_state = DROIDVM_DISPLAY_NOT_ATTEMPTED;
static _Atomic int g_width;
static _Atomic int g_height;
static _Atomic int g_stride;
static _Atomic unsigned long long g_updates;
static _Atomic unsigned long long g_switches;

/* Whether a HOST surface is bound. Separate from g_state by design: "QEMU has a graphic console"
 * and "DroidVM has somewhere to put its frames" are different facts. */
static _Atomic int g_host_attached;

/* Static literals, so the callbacks take no lock and format nothing. The reason is what happened,
 * not a snapshot of the geometry -- that is the snapshot's job, and duplicating it here cost a mutex
 * on the QEMU main loop. Same pattern as droidvm_qemu_runtime.c. */
static _Atomic(const char *) g_reason = "display integration has not been attempted";

static void set_reason(const char *reason)
{
    atomic_store_explicit(&g_reason, reason, memory_order_release);
}

static void set_state(int state, const char *reason)
{
    set_reason(reason);
    atomic_store_explicit(&g_state, state, memory_order_release);
}

static void note_surface(DisplaySurface *surface)
{
    atomic_store_explicit(&g_width, surface_width(surface), memory_order_relaxed);
    atomic_store_explicit(&g_height, surface_height(surface), memory_order_relaxed);
    atomic_store_explicit(&g_stride, surface_stride(surface), memory_order_relaxed);
}

/* ------------------------------------------------------------------ *
 * The callbacks.
 *
 * Deliberately minimal: no allocation, no UI work, no blocking. The
 * QEMU main loop must not wait on us.
 * ------------------------------------------------------------------ */

static void droidvm_display_gfx_switch(DisplayChangeListener *dcl,
                                       struct DisplaySurface *new_surface)
{
    (void)dcl;

    if (new_surface == NULL) {
        set_reason("surface switch with no surface");
        return;
    }

    /* A switch means the surface was REPLACED -- the guest changed mode or resolution. Counting it
     * separately is what makes a stale-size bug visible, and the snapshot carries the new size. */
    atomic_fetch_add_explicit(&g_switches, 1, memory_order_relaxed);
    note_surface(new_surface);
    set_reason("surface replaced");
}

static void droidvm_display_gfx_update(DisplayChangeListener *dcl,
                                       int x, int y, int w, int h)
{
    DisplaySurface *surface = qemu_console_surface(dcl->con);

    (void)x;
    (void)y;
    (void)w;
    (void)h;

    if (surface == NULL) {
        /* Asked to draw and the console has nothing: evidence about the guest, not our failure. */
        set_reason("update received with no console surface");
        return;
    }

    note_surface(surface);
    atomic_fetch_add_explicit(&g_updates, 1, memory_order_relaxed);

    if (!atomic_load_explicit(&g_host_attached, memory_order_relaxed)) {
        /* A real update arrived and there is nowhere to put it. That is OUR failure, not the
         * guest's, and it is named as such rather than reported as presented. */
        set_reason("update received with no attached host surface");
        return;
    }

    set_reason("update received");
}

static const DisplayChangeListenerOps droidvm_display_ops = {
    .dpy_name = "droidvm",
    .dpy_gfx_update = droidvm_display_gfx_update,
    .dpy_gfx_switch = droidvm_display_gfx_switch,
    /* No dpy_refresh. Driving a refresh from here would be this integration inventing frames:
     * QEMU decides when there is something to show. */
};

/* ------------------------------------------------------------------ *
 * Registration
 * ------------------------------------------------------------------ */

static DisplayChangeListener g_listener;
static Notifier g_init_done;

static void droidvm_display_machine_init_done(Notifier *notifier, void *data)
{
    (void)notifier;
    (void)data;

    QemuConsole *con = qemu_console_lookup_by_index(0);
    if (con == NULL) {
        /* Not a fault in itself -- a machine with no graphic device legitimately has none -- but
         * reported precisely so a device log can tell it apart from a rejected console. */
        set_state(DROIDVM_DISPLAY_FAILED,
                  "no QemuConsole at index 0; the machine has no graphic device");
        return;
    }

    if (!qemu_console_is_graphic(con)) {
        set_state(DROIDVM_DISPLAY_FAILED,
                  "console 0 exists but is not a graphic console");
        return;
    }

    g_listener.ops = &droidvm_display_ops;
    g_listener.con = con;

    register_displaychangelistener(&g_listener);

    /* Registration has no return value -- QEMU asserts rather than failing softly -- so the
     * evidence is that the listener is bound and its surface is readable. */
    DisplaySurface *surface = qemu_console_surface(con);
    if (surface != NULL) {
        note_surface(surface);
    }

    set_state(DROIDVM_DISPLAY_LISTENER_REGISTERED,
              "display listener registered against console 0");
}

void droidvm_display_qemu_start(void)
{
    g_init_done.notify = droidvm_display_machine_init_done;
    qemu_add_machine_init_done_notifier(&g_init_done);
}

/* ------------------------------------------------------------------ *
 * The app-facing surface. Minimal on purpose.
 * ------------------------------------------------------------------ */

void droidvm_display_snapshot_get(droidvm_display_snapshot *out)
{
    if (out == NULL) {
        return;
    }

    /* Acquire on the state so that a reader which sees LISTENER_REGISTERED also sees the geometry
     * written before it. The counters are relaxed: they are monotonic and a reader does not need
     * them to agree with the geometry to the nanosecond. */
    out->state = atomic_load_explicit(&g_state, memory_order_acquire);
    out->width = atomic_load_explicit(&g_width, memory_order_relaxed);
    out->height = atomic_load_explicit(&g_height, memory_order_relaxed);
    out->stride = atomic_load_explicit(&g_stride, memory_order_relaxed);
    out->updates = atomic_load_explicit(&g_updates, memory_order_relaxed);
    out->surface_replacements = atomic_load_explicit(&g_switches, memory_order_relaxed);
}

const char *droidvm_display_qemu_last_reason(void)
{
    return atomic_load_explicit(&g_reason, memory_order_acquire);
}

/* Whether a HOST surface is bound. Deliberately separate from the state machine above: "QEMU has
 * a graphic console" and "DroidVM has somewhere to put its frames" are different facts, and
 * collapsing them is how "console exists" would start meaning "display ready". */
void droidvm_display_qemu_note_host_attachment(int attached)
{
    atomic_store_explicit(&g_host_attached, attached ? 1 : 0, memory_order_relaxed);

    if (attached) {
        if (atomic_load_explicit(&g_state, memory_order_acquire) ==
            DROIDVM_DISPLAY_LISTENER_REGISTERED) {
            set_state(DROIDVM_DISPLAY_ATTACHED, "host surface attached");
        }
    } else if (atomic_load_explicit(&g_state, memory_order_acquire) ==
               DROIDVM_DISPLAY_ATTACHED) {
        set_state(DROIDVM_DISPLAY_DETACHED, "host surface detached");
    }
}
