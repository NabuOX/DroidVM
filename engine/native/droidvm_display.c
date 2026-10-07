/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * DroidVM's display bridge, native side.
 *
 * THE SIX COUNTERS ARE THE INTERFACE
 *
 * entered · received · presented · dropped · noScanout · presentFailure
 *
 * One function per stage, deliberately. A generic `bump(kind)` would let a call site say
 * "a frame happened" without saying which stage it was in, and the entire reason there are
 * six counters is that "the guest is not drawing" and "we are dropping every frame" are
 * different faults with opposite fixes. A single increment point would quietly recreate the
 * one-number model this replaces.
 *
 * There is no frame-rate metric anywhere in this file, and none may be added. A rate cannot
 * distinguish those two cases, and an idle Android system legitimately presents nothing.
 *
 * EVERY FAILURE PATH IS NAMED
 *
 * The reference implementation had paths that returned without counting or logging -- a
 * display update that bailed before incrementing anything, a presenter that discarded a
 * frame silently. Each of those is a counter here. Nothing in this file returns quietly:
 * a stage that did not happen is a stage that was not counted, and the reason is set.
 *
 * WHAT IS PORTABLE
 *
 * The counters, the attachment flag and the reason reporting have no platform dependency,
 * so the host gate compiles this file for real and asserts the transitions. The QEMU
 * listener below them does need QEMU, and is compiled only when DROIDVM_WITH_QEMU is
 * defined.
 */

#include "droidvm_native.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * State
 * ------------------------------------------------------------------ */

static droidvm_display_counters g_counters;
static int g_attached = 0;
static int g_registered = 0;

static char g_reason[256] = "no attempt made";

static void set_reason(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_reason, sizeof(g_reason), fmt, args);
    va_end(args);
    g_reason[sizeof(g_reason) - 1] = '\0';
}

const char *droidvm_display_last_reason(void)
{
    return g_reason;
}

/* ------------------------------------------------------------------ *
 * The six stages
 *
 * Each is a separate entry point, and each is the only way its counter
 * can move. There is no combined increment.
 * ------------------------------------------------------------------ */

void droidvm_display_note_entered(void)
{
    g_counters.entered++;
}

void droidvm_display_note_received(void)
{
    g_counters.received++;
}

void droidvm_display_note_presented(void)
{
    g_counters.presented++;
}

void droidvm_display_note_dropped(void)
{
    /* A drop is a frame we took and did not draw. It is counted here rather than folded
     * into `received`, because a window with received > 0 and presented == 0 means our
     * presenter is broken, while received == 0 means the guest never drew. */
    g_counters.dropped++;
}

void droidvm_display_note_no_scanout(void)
{
    /* We were asked to draw and the guest had nothing on screen to give us. This is
     * evidence about the guest, and it is the counter that makes an idle-but-healthy
     * system distinguishable from a stuck one. */
    g_counters.no_scanout++;
}

void droidvm_display_note_present_failure(void)
{
    g_counters.present_failure++;
}

/* ------------------------------------------------------------------ *
 * Reading and resetting
 * ------------------------------------------------------------------ */

size_t droidvm_display_counters_sizeof(void)
{
    return sizeof(droidvm_display_counters);
}

void droidvm_display_read(droidvm_display_counters *out)
{
    if (out == NULL) {
        set_reason("counter read with a null out-parameter");
        return;
    }
    *out = g_counters;
    set_reason("counters read");
}

int droidvm_display_is_attached(void)
{
    return g_attached;
}

void droidvm_display_set_attached(int attached)
{
    g_attached = attached ? 1 : 0;
    if (!g_attached) {
        /* Losing the surface is not losing the machine, and it is not a frame failure
         * either. It is recorded as a reason so the next empty window has an explanation
         * rather than being attributed to the guest. */
        set_reason("display surface detached");
    } else {
        set_reason("display surface attached");
    }
}

void droidvm_display_reset(void)
{
    memset(&g_counters, 0, sizeof(g_counters));
    g_attached = 0;
    g_registered = 0;
    set_reason("display state reset");
}

/* ------------------------------------------------------------------ *
 * Listener registration
 *
 * DroidVM registers its own DisplayChangeListener, which is why the
 * launch plan passes `-display none`: QEMU needs no backend of its
 * own because ours is the backend.
 *
 * Return codes are distinguished rather than collapsed, because the
 * caller is a Swift type that has to decide what to tell the user:
 *
 *   0  registered
 *   1  already registered -- a second listener would orphan the first
 *      surface, which shows up as a frame counter climbing against a
 *      black screen
 *   2  this build has no engine to register with
 * ------------------------------------------------------------------ */

#define DROIDVM_DISPLAY_REGISTER_OK          0
#define DROIDVM_DISPLAY_REGISTER_ALREADY     1
#define DROIDVM_DISPLAY_REGISTER_NO_ENGINE   2

#ifdef DROIDVM_WITH_QEMU

#include "ui/console.h"
#include "qemu/osdep.h"

/* The listener. Six explicit stages, no shared increment, and every early return counted
 * before it returns -- which is the discipline that was missing before. */
static void droidvm_display_update(void *opaque, DisplaySurface *surface)
{
    (void)opaque;

    droidvm_display_note_entered();

    if (surface == NULL || surface->format == NULL) {
        /* Asked to draw with no scanout. Evidence about the guest, and named as such. */
        droidvm_display_note_no_scanout();
        return;
    }

    droidvm_display_note_received();

    if (!g_attached) {
        /* A frame arrived and there is nowhere to put it. This is OUR failure, not the
         * guest's: the machine is producing frames and the host cannot show them. */
        droidvm_display_note_dropped();
        set_reason("frame received with no attached surface");
        return;
    }

    status = droidvm_display_present_scanout(surface);
    if (status != 0) {
        droidvm_display_note_present_failure();
        set_reason("presenting the scanout failed (%d)", status);
        return;
    }

    droidvm_display_note_presented();
}

static DisplayChangeListener g_listener;

int droidvm_display_register(void)
{
    if (g_registered) {
        set_reason("a display listener is already registered; a second would orphan "
                   "the first surface");
        return DROIDVM_DISPLAY_REGISTER_ALREADY;
    }

    memset(&g_listener, 0, sizeof(g_listener));
    g_listener.dpy = NULL;
    g_listener.update = droidvm_display_update;

    register_displaychangelistener(&g_listener);
    g_registered = 1;
    set_reason("display listener registered");
    return DROIDVM_DISPLAY_REGISTER_OK;
}

#else /* !DROIDVM_WITH_QEMU */

int droidvm_display_register(void)
{
    /* Without QEMU there is no display to register against. Reported as its own code
     * rather than as "already registered", because those mean different things to whoever
     * reads the log, and only one of them is a bug in the caller. */
    set_reason("this build has no engine to register a display listener with "
               "(compile with DROIDVM_WITH_QEMU)");
    return DROIDVM_DISPLAY_REGISTER_NO_ENGINE;
}

#endif /* DROIDVM_WITH_QEMU */
