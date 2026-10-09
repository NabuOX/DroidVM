/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * DroidVM's executable-memory backend.
 *
 * WHAT THIS IS
 *
 * iOS will not hand a third-party app a mapping that is both writable and executable, so
 * translated code and the translator that produces it need two views of the same pages:
 * one executable, one writable. Only an attached debugger can create the executable view,
 * and it is asked for it by executing a trap instruction with a command number in x16.
 *
 * The trap itself lives in droidvm-brk.S, which is DroidVM's own assembly. This file is the
 * bookkeeping around it: the status machine, the reason strings, the two-view mapping, and the
 * mapping diagnostics that report what the kernel says about every address involved.
 *
 * WHAT IS DELIBERATELY PORTABLE
 *
 * The status machine and the reason reporting have no platform dependency, so they compile
 * and are tested on the development machine. Only `droidvm_jit_capture`'s body differs by
 * platform. That split is why the error mapping can be verified without a device.
 *
 * PROVENANCE
 *
 * Reimplemented. The mechanism was studied in the reference implementation's
 * `src/ios-jit/husk-ios-jit.c`, which is itself derived from AetherPS4-iOS's
 * `ios_jit_allocator.cpp` (GPL-2.0-or-later). No code was copied; the design and the
 * failure modes are recorded in THIRD_PARTY.md.
 *
 * THE FAILURE MODE THIS EXISTS TO PREVENT
 *
 * A region can be returned that is mapped and still cannot execute -- and two device runs died
 * executing exactly such a region. So "we have executable memory" is never claimed on the strength of
 * protection bits alone: the range is measured, aliased, verified in both directions, and only then is
 * a single stub executed. `DROIDVM_JIT_OK` is returned only when that stub returned the expected
 * constant.
 *
 * The build is a health-gated bring-up pipeline, stage by stage: provider_prepare, provider_range,
 * rw_alias, readback, jit_selftest. Each stage is recorded as it is decided, so a failure report names
 * the stage that stopped it rather than reporting a single undifferentiated failure.
 */

#include "droidvm_native.h"

#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
#endif

/* ------------------------------------------------------------------ *
 * The trap protocol
 *
 * Implemented in droidvm-brk.S. Declared rather than insourced so that
 * the assembly and this file can be reviewed separately.
 * ------------------------------------------------------------------ */

#if defined(__APPLE__) && defined(__arm64__)
/* THE ARGUMENT CONTRACT, from the protocol.
 *
 * x0 = addr: NULL requests a FRESH region for the provider to allocate. Handing in an address we
 * allocated ourselves is the branch that does NOT get its pages prepared.
 * x1 = len: the size requested.
 * The result (the region address, or 0) is written back into x0 before the provider resumes us. */
extern void *droidvm_jit_break_get_jit_mapping(void *addr, size_t len);

/* The protocol's other command. Every preparation must be followed by one of these. */
extern void droidvm_jit_break_detach(void);
#endif

/* ------------------------------------------------------------------ *
 * State
 * ------------------------------------------------------------------ */

/* One machine per process is DroidVM's model, so one region is correct rather than a
 * limitation. A second capture is refused rather than silently leaking the first. */
static droidvm_jit_region g_region;
static int g_held = 0;

/* Set when the held region is given back. `droidvm_jit_release` lives outside the Apple-only block
 * and reads it, so it is declared here rather than beside the bring-up state. */
static int g_region_released;

/* The bring-up stages, zero-initialised: on a platform that never runs the pipeline, every stage
 * reads as not_run, which is exactly true. Declared outside the Apple-only block because the host
 * gate links this file and the manifest requires the symbol. */
static droidvm_bringup_report g_bringup = {
    /* not_run = 1 for every stage: in this ABI "untouched" and "attempted and failed" are different
     * facts, and a zero-initialised struct would report all five as FAILED before anything ran. */
    .provider_prepare = { 1, 0 }, .provider_range = { 1, 0 }, .rw_alias = { 1, 0 },
    .readback = { 1, 0 }, .jit_selftest = { 1, 0 }
};

void droidvm_jit_bringup_report_get(droidvm_bringup_report *out)
{
    if (out == NULL) { return; }
    *out = g_bringup;
}

/* The walk's region cap for a request of `requested` bytes.
 *
 * PORTABLE, and deliberately so: this arithmetic IS the bug. A fixed cap of 4096 is smaller than a
 * 1 GiB request needs at arm64's 16 KiB granularity -- a gigabyte is 65536 regions -- so the walk
 * stopped at its own ceiling and the range was reported as a 64 MiB provider allocation. Deriving the
 * bound from the request is what makes that impossible, and being portable is what lets the host
 * regression test check the number rather than trust it. */
#define DROIDVM_MIN_PAGE_SIZE  16384ull
#define DROIDVM_WALK_MARGIN    1024ull

unsigned long long droidvm_walk_region_bound(unsigned long long requested)
{
    return requested / DROIDVM_MIN_PAGE_SIZE + DROIDVM_WALK_MARGIN;
}


/* Large enough for the mapping diagnostic, which is the entire point of the diagnostic build.
 * At 256 the region descriptions were cut off mid-address, which is worse than useless. */
static char g_reason[1024] = "no attempt made";

void droidvm_jit_set_reason(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_reason, sizeof(g_reason), fmt, args);
    va_end(args);
    g_reason[sizeof(g_reason) - 1] = '\0';
}

const char *droidvm_jit_last_reason(void)
{
    return g_reason;
}

int droidvm_jit_platform_supported(void)
{
#if defined(__APPLE__) && defined(__arm64__)
    /* Apple silicon, where the trap protocol is the documented route. A device without a
     * debugger attached will still fail at capture, which is a different answer from
     * "this platform cannot do it", and the Swift side distinguishes the two. */
    return 1;
#else
    /* Everywhere else -- the development host included -- there is no debugger to service
     * the trap, so the honest answer is that the mechanism is absent rather than that an
     * attempt failed. */
    return 0;
#endif
}

/* Is anything attached that could service the trap?
 *
 * THE CHECK THAT MAKES THE PROBE SAFE. `brk` IS the mechanism, so availability cannot be
 * discovered by attempting it: with nothing attached, the attempt is not a failed call, it is a
 * dead process -- EXC_BREAKPOINT, which is what the first device run produced.
 *
 * P_TRACED is set by the kernel while a debugger traces this process, which is exactly when the
 * trap has a responder. Reading it costs a sysctl: no trap, no allocation, nothing to survive.
 */
static int debugger_is_attached(void)
{
#if defined(__APPLE__)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);

    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        /* Unreadable is reported as "not attached": the conservative answer is the one that
         * cannot crash. */
        return 0;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
#else
    /* No debugger services a trap on the development host either. */
    return 0;
#endif
}

/* ------------------------------------------------------------------ *
 * Probe
 *
 * Non-destructive by contract: it must never trap and never allocate, because the Swift
 * side calls it while deciding what to tell the user.
 * ------------------------------------------------------------------ */

droidvm_jit_status droidvm_jit_probe(void)
{
    if (!droidvm_jit_platform_supported()) {
        droidvm_jit_set_reason("executable memory is not available on this platform");
        return DROIDVM_JIT_UNSUPPORTED;
    }
    if (g_held) {
        /* Already held is not a failure, and the caller is told so rather than being given
         * a reason string that sounds like one. */
        droidvm_jit_set_reason("a region is already held");
        return DROIDVM_JIT_ALREADY_HELD;
    }
    /* THE SAFETY GATE. Nothing below this line may execute a trap, and nothing above it has
     * been tried. On a normal sideloaded launch no debugger is attached, the trap would not be
     * serviced, and iOS would terminate the process -- so this answers UNAVAILABLE without
     * executing anything. That is a real answer about a real limitation, not a fabricated
     * failure: the environment genuinely cannot provide executable memory. */
    if (!debugger_is_attached()) {
        droidvm_jit_set_reason("no JIT-enabling environment is attached: the process is not "
                               "being debugged, so the trap that provides executable memory "
                               "would not be serviced and would terminate the app");
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    /* A debugger IS attached, so the trap has a responder. Whether a region can actually be
     * obtained is still decided by capture, not by a probe -- which is why the Swift mapping
     * turns this into `unknown` rather than `available`. */
    droidvm_jit_set_reason("mechanism available and a debugger is attached; no region held");
    return DROIDVM_JIT_OK;
}

#if defined(__APPLE__) && defined(__arm64__)
/* THE REGION DESCRIPTION BUFFER, the sentinel, and the probe that fills them, are declared here
 * because make_views uses them and is defined above their definitions. C11 has no implicit
 * declarations, so an Apple build fails without this -- and only an Apple build sees it, which is
 * why the host gate stays green while gate 2 fails. */
#define DROIDVM_DIAG_REGION_LEN 200

/* The three states a region probe can report. UNMAPPED and NO_ACCESS are NOT the same: one means the
 * kernel has no entry, the other means it has one that grants nothing. Collapsing them would make
 * "we cannot read this" indistinguishable from "this does not exist". */
#define DROIDVM_REGION_UNMAPPED  (-1)

typedef struct {
    int mapped;                 /* 0 when the address is not mapped */
    int cur_prot;               /* what the region allows NOW */
    int max_prot;               /* the most it could ever allow -- not the same thing */
    uintptr_t base;
    unsigned long long size;
} droidvm_region_info;

static droidvm_region_info region_probe(const char *label, uintptr_t address,
                                        char *out, size_t out_size);

/* ONE-SHOT STATE, NOT PERSISTED. FILE SCOPE, beside the other Apple-only declarations -- outside
 * every function, so both make_views and droidvm_jit_capture can see it. (An earlier revision put
 * these inside make_views, where `static` made them block-scope: legal C, invisible to capture, and
 * an undeclared-identifier error that only an Apple build would report.)
 *
 * The prepare experiment runs at most once per process. The first attempt consumes it; a later Start
 * reports the evidence already collected rather than asking for another region that would never be
 * given back. Being process-local, a relaunch begins a fresh process and allows one fresh attempt.
 *
 * The consumed flag is set BEFORE the trap is issued, so every outcome -- a valid region, a NULL
 * return, a validation failure, a remap failure, a readback failure or the diagnostic stop -- leaves
 * it consumed. There is no path that could ask twice. */
static int g_prepare_consumed;
static droidvm_jit_status g_prepare_status = DROIDVM_JIT_OK;

/* THE FIRST ATTEMPT'S OWN REASON, and nothing else may write it afterwards.
 *
 * `g_reason` cannot serve here: it is mutable, and the ordinary probe calls droidvm_jit_set_reason
 * (which writes it) on every Start before capture runs. Reading `g_reason` on a repeat therefore
 * reported the probe's message as though it were the collected evidence. */
static char g_prepare_reason[1024];

/* ---------------------------------------------------------------- bounded range walking
 *
 * WHY THIS EXISTS. A 1 GiB request came back with a FIRST region of 16 KiB, and the previous build
 * treated that as "the provider returned less than we asked for" and stopped. The provider returns a
 * RANGE assembled from many VM regions, so the usable size is something to MEASURE, not to presume
 * from one observation.
 */
/* WHY THE WALK STOPPED. Six distinct facts, and conflating them is what produced the bug: the walk
 * hit a fixed 4096-region ceiling and the caller read that as "the provider returned 64 MiB". A cap
 * is something WE did; a gap is something the PROVIDER did. They must never look alike. */
typedef enum {
    DROIDVM_WALK_COMPLETE = 0,
    DROIDVM_WALK_GAP,               /* the next region does not start where this one ended */
    DROIDVM_WALK_PROTECTION,        /* mapped, but not READ|EXECUTE */
    DROIDVM_WALK_REGION_LIMIT,      /* our own cap, NOT a provider limit */
    DROIDVM_WALK_TIME_LIMIT,        /* our own deadline, NOT a provider limit */
    DROIDVM_WALK_OVERFLOW           /* the cursor would wrap the address space */
} droidvm_walk_outcome;

/* 16 KiB is the arm64 iOS page size, so a request of N bytes can legitimately be N/16384 regions:
 * a gigabyte is 65536. A FIXED cap smaller than that stops the walk early and reports a short range
 * that the provider never returned.
 *
 * Portable, because `droidvm_walk_region_bound` is portable and the host tests its arithmetic. */

typedef struct {
    uintptr_t start;
    unsigned long long requested;
    unsigned long long first_region_size;
    unsigned long long contiguous;      /* proven usable from `start` */
    unsigned int regions_walked;
    unsigned long long region_bound;    /* the cap actually applied */
    int range_complete;                 /* contiguous == requested */
    int first_gap_offset;               /* -1 when the range is complete */
    int gap_reason;                     /* 0 none, 1 unmapped, 2 not executable, 3 limit */
    int first_cur_prot, first_max_prot, last_cur_prot;
    int walk_truncated;                 /* nonzero when WE stopped it, not the map */
    droidvm_walk_outcome outcome;
    unsigned long long elapsed_ms;
} droidvm_rx_range;

/* PORTABLE ON PURPOSE: the bound depends only on the request, so the host can test the arithmetic
 * this bug was about. 4096 must not come back for a 1 GiB request.
 *
 * Defined in the portable section above, beside the other host-visible symbols. */

static uint64_t droidvm_now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* Walks forward from `start`, region by region, while each region is READ|EXECUTE and begins exactly
 * where the previous one ended. The walk IS the proof that there is no gap: coalescing cannot be
 * assumed from endpoint samples, so every region on the way is asked about.
 *
 * BOUNDED TWICE, and the two bounds are independent: a region count DERIVED FROM THE REQUEST, and a
 * wall-clock deadline. Reaching either one is recorded as truncation with its own reason, so a
 * self-imposed stop is never reported as a property of the provider's mapping. */
static void droidvm_walk_provider_range(uintptr_t start, unsigned long long requested,
                                        droidvm_rx_range *out)
{
    enum { kBudgetMs = 2000 };          /* independent of the region bound */
    char buf[DROIDVM_DIAG_REGION_LEN];

    memset(out, 0, sizeof(*out));
    out->start = start;
    out->requested = requested;
    out->first_gap_offset = -1;
    out->region_bound = droidvm_walk_region_bound(requested);

    const uint64_t started_at = droidvm_now_ms();
    const uint64_t deadline = started_at + kBudgetMs;
    uintptr_t cursor = start;
    unsigned long long proven = 0;

    for (;;) {
        if (proven >= requested) {
            out->range_complete = 1;
            out->outcome = DROIDVM_WALK_COMPLETE;
            break;
        }
        if ((unsigned long long)out->regions_walked >= out->region_bound) {
            /* OUR CAP, NOT A PROVIDER LIMIT. Said plainly, because reading it as a short allocation
             * is exactly the mistake this replaces. */
            out->walk_truncated = 1;
            out->outcome = DROIDVM_WALK_REGION_LIMIT;
            out->gap_reason = 3;
            out->first_gap_offset = (int)proven;
            break;
        }
        if (droidvm_now_ms() > deadline) {
            out->walk_truncated = 1;
            out->outcome = DROIDVM_WALK_TIME_LIMIT;
            out->gap_reason = 3;
            out->first_gap_offset = (int)proven;
            break;
        }

        droidvm_region_info ri = region_probe("range", cursor, buf, sizeof(buf));
        if (!ri.mapped) {
            out->outcome = DROIDVM_WALK_GAP;
            out->gap_reason = 1; out->first_gap_offset = (int)proven; break;
        }
        /* A region that does not START at the cursor means the walk has stepped over a gap: the
         * kernel answers with the NEXT region when an address is unmapped. */
        if (cursor != ri.base) {
            out->outcome = DROIDVM_WALK_GAP;
            out->gap_reason = 1; out->first_gap_offset = (int)proven; break;
        }
        /* BOTH BITS. An execute-only mapping would pass an EXECUTE-only test and then be READ by
         * the readback -- before any fault guard is armed, because the guard belongs to the
         * self-test. Requiring READ here is what keeps the readback from being the crash. */
        if ((ri.cur_prot & VM_PROT_EXECUTE) == 0 || (ri.cur_prot & VM_PROT_READ) == 0) {
            out->outcome = DROIDVM_WALK_PROTECTION;
            out->gap_reason = 2; out->first_gap_offset = (int)proven; break;
        }

        if (out->regions_walked == 0) {
            out->first_region_size = ri.size;
            out->first_cur_prot = ri.cur_prot;
            out->first_max_prot = ri.max_prot;
        }
        out->last_cur_prot = ri.cur_prot;
        out->regions_walked++;

        unsigned long long take = ri.size;
        if (take > requested - proven) { take = requested - proven; }
        /* The cursor must not wrap, or the walk would loop over the address space. */
        if (take > (unsigned long long)(UINTPTR_MAX - cursor)) {
            out->walk_truncated = 1;
            out->outcome = DROIDVM_WALK_OVERFLOW;
            out->gap_reason = 3;
            out->first_gap_offset = (int)proven;
            break;
        }
        proven += take;
        cursor += (uintptr_t)take;
    }
    out->contiguous = proven;
    out->elapsed_ms = droidvm_now_ms() - started_at;
}

/* ---------------------------------------------------------------- the execution self-test
 *
 * THE ONLY PLACE THIS BUILD EXECUTES JIT MEMORY. It runs one four-instruction stub that returns the
 * constant 42 -- written through the RW alias, read back through RX, verified byte for byte, and
 * only then called.
 *
 * The signal guard exists so a fault is REPORTED rather than fatal, and it is deliberately narrow:
 * armed only around this call, and it restores the default disposition and re-raises for any signal
 * that arrives outside that window, so a genuine crash stays a crash.
 */
static sigjmp_buf g_selftest_jmp;
static volatile sig_atomic_t g_selftest_armed;
static uintptr_t g_selftest_thread;

/* THE GUARD BELONGS TO ONE THREAD. These handlers are process-wide, so a fault on any other thread
 * would otherwise longjmp into THIS thread's saved context -- undefined control flow in place of the
 * crash that actually happened. Only the thread that armed the guard is recovered; everything else
 * has its default disposition restored and is re-raised. */
static void droidvm_selftest_signal(int sig)
{
    if (g_selftest_armed && (uintptr_t)pthread_self() == g_selftest_thread) {
        g_selftest_armed = 0;
        siglongjmp(g_selftest_jmp, sig);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

typedef int (*droidvm_selftest_fn)(void);

/* mov w0, #42 ; ret ; nop ; nop -- the smallest thing that can prove a range executes and that we
 * can read a result back out of it. */
static const uint32_t kStub[4] = { 0x52800540u, 0xd65f03c0u, 0xd503201fu, 0xd503201fu };

/* PHASE 4 -- write a known instruction sequence through the alias, read it back through the
 * executable view, and require an exact match. Nothing is executed here. */
static droidvm_jit_status verify_readback(void *rx, void *rw, size_t usable)
{
    const size_t stub_bytes = sizeof(kStub);

    if (usable < stub_bytes) {
        droidvm_jit_set_reason("readback: usable range is %zu bytes, too small for the stub",
                               usable);
        return DROIDVM_JIT_SELF_TEST_FAILED;
    }

    memcpy(rw, kStub, stub_bytes);
    sys_icache_invalidate(rx, stub_bytes);

    if (memcmp(rx, kStub, stub_bytes) != 0) {
        droidvm_jit_set_reason("readback: the %zu bytes written through rw_alias did not read back "
                               "through provider_rx", stub_bytes);
        return DROIDVM_JIT_SELF_TEST_FAILED;
    }
    return DROIDVM_JIT_OK;
}

/* PHASE 5 -- THE ONLY EXECUTION IN THIS BUILD.
 *
 * The bytes were already written and verified through both views by verify_readback, so this does
 * NOT repeat that work: a second readback path would be a second thing to keep correct, and the
 * reviewer was right that it had become one. The guard is armed BEFORE the call and only for the
 * calling thread. */
static droidvm_jit_status run_self_test(void *rx)
{
    struct sigaction sa, old_segv, old_bus, old_ill;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = 0;                       /* sa_handler, not SA_SIGINFO: the form must match */
    sa.sa_handler = droidvm_selftest_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGILL, &sa, &old_ill);

    g_selftest_thread = (uintptr_t)pthread_self();
    int fault = sigsetjmp(g_selftest_jmp, 1);
    droidvm_jit_status result;

    if (fault == 0) {
        g_selftest_armed = 1;
        droidvm_selftest_fn fn = (droidvm_selftest_fn)rx;   /* THE ONE PERMITTED CALL */
        int returned = fn();
        g_selftest_armed = 0;

        if (returned == 42) {
            result = DROIDVM_JIT_OK;
        } else {
            droidvm_jit_set_reason("jit_selftest: the stub returned %d, expected 42", returned);
            result = DROIDVM_JIT_SELF_TEST_FAILED;
        }
    } else {
        g_selftest_armed = 0;
        droidvm_jit_set_reason("jit_selftest: executing the stub raised signal %d "
                               "(the range is mapped READ|EXECUTE but did not execute)", fault);
        result = DROIDVM_JIT_SELF_TEST_FAILED;
    }

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
    sigaction(SIGILL, &old_ill, NULL);
    return result;
}

/* The measured range, kept for the report whether the run succeeds or fails. */
static droidvm_rx_range g_range;
static size_t g_usable;

/* Stage recorder. Each stage is marked the moment it is decided, so a later failure cannot erase the
 * evidence that an earlier one passed. The RECORDER lives here because only this block calls it; the
 * storage and the getter are portable (see below). */
static void bringup_mark(droidvm_bringup_stage *stage, int passed)
{
    stage->not_run = 0;
    stage->passed = passed;
}

static droidvm_jit_status make_views(size_t bytes,
                                     void **exec_out,
                                     void **write_out,
                                     size_t *usable_out)
{
    /* ASK THE PROVIDER FOR THE REGION.
     *
     * x0 = NULL requests a FRESH region, which is the only request whose pages the provider
     * prepares. DroidVM used to vm_allocate its own region and never ask -- and a region we allocate
     * ourselves is exactly the one that does not get prepared, so it ends up with protection bits
     * and no authorization to execute. */
    g_bringup.requested_bytes = (unsigned long long)bytes;

    void *rx = droidvm_jit_break_get_jit_mapping(NULL, bytes);
    if (rx == NULL) {
        bringup_mark(&g_bringup.provider_prepare, 0);
        /* A clean failure: the provider declined, or nothing is attached to service the request.
         * Nothing is executed and nothing is assumed.
         *
         * DETACH EVEN HERE. The request was made, so the provider may be holding state for us, and
         * a script left waiting would make a later attempt behave differently for a reason this run
         * caused. */
        droidvm_jit_set_reason("the provider returned no region for a fresh request "
                               "(x0=NULL, x1=%zu)", bytes);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    /* The provider's answer is an address CLAIM, not proof. Ask the kernel before using it. */
    char rx_buf[DROIDVM_DIAG_REGION_LEN];
    droidvm_region_info rx_info = region_probe("provider_rx", (uintptr_t)rx, rx_buf, sizeof(rx_buf));
    int rx_prot = rx_info.mapped ? rx_info.cur_prot : DROIDVM_REGION_UNMAPPED;

    /* ONE CONSOLIDATED VALIDATION OF THE PROVIDER'S ANSWER.
     *
     * It was two partially-overlapping copies, and neither marked the stage -- so an unmapped,
     * non-base or non-executable answer left `provider_prepare` reading NOT RUN in the device report,
     * which is false evidence about which stage actually failed. Every rejection below marks it
     * FAILED, and it is marked PASSED only after the whole answer has been accepted. */
    if (rx_prot == DROIDVM_REGION_UNMAPPED) {
        bringup_mark(&g_bringup.provider_prepare, 0);
        droidvm_jit_set_reason("provider_prepare: the provider returned %p, which is not mapped", rx);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    /* The address must be the START of its region: `region_probe` describes the mapping that
     * CONTAINS `rx`, so an address in the middle would make `size` something other than the space
     * available from there. The protocol returns an allocation base. */
    if ((uintptr_t)rx != rx_info.base) {
        bringup_mark(&g_bringup.provider_prepare, 0);
        droidvm_jit_set_reason("provider_prepare: the provider returned an address inside a region "
                               "rather than at its base: provider_rx=%p provider_rx_region_base=%p",
                               rx, (void *)rx_info.base);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    /* BOTH BITS. The range is read by the readback before any fault guard exists, so an
     * execute-only mapping would be read unprotected; and a mapping that cannot execute is not what
     * was asked for. */
    if ((rx_prot & VM_PROT_EXECUTE) == 0 || (rx_prot & VM_PROT_READ) == 0) {
        bringup_mark(&g_bringup.provider_prepare, 0);
        droidvm_jit_set_reason("provider_prepare: the provider returned %p but it is not "
                               "READ|EXECUTE (cur=%d)", rx, rx_prot);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    /* Accepted. Marked here, and only here: everything above is a rejection. */
    bringup_mark(&g_bringup.provider_prepare, 1);

    /* MEASURE THE RANGE INSTEAD OF PRESUMING IT.
     *
     * One vm_region_64 answer describes ONE region. The first one being 16 KiB does not mean the
     * allocation is 16 KiB; it means the provider assembles the range from many regions. Walking
     * forward is what turns that into a number we can actually use -- and the walk is bounded, so a
     * pathological map cannot spin here. */
    droidvm_rx_range range;
    droidvm_walk_provider_range((uintptr_t)rx, (unsigned long long)bytes, &range);

    unsigned long long usable = range.contiguous;

    /* Record the measurement FIRST, so it is in the report whichever way this goes. */
    g_range = range;
    g_bringup.contiguous_rx_bytes = range.contiguous;
    g_bringup.first_region_size = range.first_region_size;
    g_bringup.regions_walked = range.regions_walked;
    g_bringup.range_complete = range.range_complete;
    g_bringup.first_gap_offset = range.first_gap_offset;
    g_bringup.gap_reason = range.gap_reason;
    g_bringup.region_bound = range.region_bound;
    g_bringup.elapsed_walk_ms = range.elapsed_ms;
    g_bringup.walk_truncated = range.walk_truncated;
    /* The reason is a NAME, so a report cannot read a self-imposed cap as a provider limit. */
    switch (range.outcome) {
    case DROIDVM_WALK_REGION_LIMIT: g_bringup.truncation_reason = 1; break;
    case DROIDVM_WALK_TIME_LIMIT:   g_bringup.truncation_reason = 2; break;
    case DROIDVM_WALK_OVERFLOW:     g_bringup.truncation_reason = 3; break;
    default:                        g_bringup.truncation_reason = 0; break;
    }
    g_bringup.rx_cur_prot = range.first_cur_prot;
    g_bringup.rx_max_prot = range.first_max_prot;

    if (usable == 0) {
        bringup_mark(&g_bringup.provider_range, 0);
        droidvm_jit_set_reason("provider_range: no executable range begins at provider_rx=%p "
                               "(gap_reason=%d regions_walked=%u)",
                               rx, range.gap_reason, range.regions_walked);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    /* A PARTIAL RANGE IS NOT A SMALLER SUCCESS.
     *
     * `acquire(bytes:)` promises at least `bytes`. A prefix that merely executes -- 16 KiB of a 1 GiB
     * request -- would run the stub happily and report READY for a region the engine could never use,
     * so `usable > 0` is NOT sufficient: the measurement has to cover the request.
     *
     * Checked BEFORE the alias exists, and therefore before rw_alias, readback, jit_selftest and
     * READY. A truncated walk lands here too: stopping early is a reason to refuse, not a reason to
     * settle for less. */
    if (!range.range_complete) {
        bringup_mark(&g_bringup.provider_range, 0);
        /* THE REASON IS STATED IN WORDS, not left for the reader to infer from a number. A walk that
         * we truncated is a fact about our limits; a gap is a fact about the provider's mapping. The
         * previous report said neither, and the region cap was read as a 64 MiB allocation. */
        const char *why =
            (range.outcome == DROIDVM_WALK_REGION_LIMIT) ? "walk_truncated=1 truncation_reason=region_limit"
          : (range.outcome == DROIDVM_WALK_TIME_LIMIT)   ? "walk_truncated=1 truncation_reason=time_limit"
          : (range.outcome == DROIDVM_WALK_OVERFLOW)     ? "walk_truncated=1 truncation_reason=overflow"
          : (range.outcome == DROIDVM_WALK_PROTECTION)   ? "walk_truncated=0 truncation_reason=none gap=protection"
          : (range.outcome == DROIDVM_WALK_GAP)          ? "walk_truncated=0 truncation_reason=none gap=unmapped"
                                                         : "walk_truncated=0 truncation_reason=none";

        droidvm_jit_set_reason("provider_range: only contiguous_rx_bytes=%llu of requested_bytes=%zu "
                               "was proven; %s "
                               "(regions_walked=%u region_bound=%llu first_region_size=%llu "
                               "gap_reason=%d first_gap_offset=%d elapsed_walk_ms=%llu); "
                               "a partial range cannot satisfy the request",
                               range.contiguous, bytes, why,
                               range.regions_walked, range.region_bound, range.first_region_size,
                               range.gap_reason, range.first_gap_offset, range.elapsed_ms);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }
    bringup_mark(&g_bringup.provider_range, 1);

    g_bringup.usable_bytes = usable;

    /* THE ALIAS COVERS ONLY THE PROVEN RANGE. Aliasing `bytes` when only `usable` was proven would
     * remap past the end of the provider's allocation. */
    vm_address_t rw = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, (vm_size_t)usable, /*mask=*/0,
                                VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx,
                                /*copy=*/FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        bringup_mark(&g_bringup.rw_alias, 0);
        droidvm_jit_set_reason("rw_alias: vm_remap of the proven range %p (%llu bytes) failed "
                               "(kern_return %d)", rx, usable, (int)kr);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)usable, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), rw, (vm_size_t)usable);
        bringup_mark(&g_bringup.rw_alias, 0);
        droidvm_jit_set_reason("rw_alias: vm_protect(READ|WRITE) failed (kern_return %d)", (int)kr);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    /* NO vm_protect ON THE RX REGION. Its protection is whatever the provider delivered, and the
     * authority to execute it comes from the provider having prepared its pages -- not from bits we
     * could set ourselves. Setting them ourselves is what produced a mapping that read as
     * READ|EXECUTE and faulted on its first instruction. W^X holds: RX stays READ|EXECUTE as
     * delivered, the alias is READ|WRITE, and EXECUTE is never added to the alias. */

    bringup_mark(&g_bringup.rw_alias, 1);

    *exec_out = rx;
    *write_out = (void *)rw;
    if (usable_out != NULL) { *usable_out = (size_t)usable; }
    return DROIDVM_JIT_OK;
}

/* ONE kernel lookup, describing the region that contains `address`.
 *
 * ASKS THE KERNEL, never the memory: `vm_region_64` answers from the task's map, so a bogus or hostile
 * address produces a description rather than a fault. That is what makes it safe to ask about an
 * address the provider merely claimed. */
static droidvm_region_info region_probe(const char *label, uintptr_t address,
                                        char *out, size_t out_size)
{
    droidvm_region_info result;
    memset(&result, 0, sizeof(result));

    if (address == 0) {
        snprintf(out, out_size, "%s=0 (the provider returned no address)", label);
        return result;
    }

    /* vm_region_64, not mach_vm_region: `mach/mach_vm.h` is a macOS header and the iOS SDK rejects it
     * outright. Everything else in this file is the vm_* family for the same reason. */
    vm_address_t region = (vm_address_t)address;
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    memset(&info, 0, sizeof(info));

    kern_return_t kr = vm_region_64(mach_task_self(), &region, &region_size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) {
        snprintf(out, out_size, "%s=%p UNMAPPED (kr=%d)", label, (void *)address, (int)kr);
        return result;
    }

    /* CONTAINMENT IS THE PROOF. `vm_region_64` answers with the NEXT region when the address falls in
     * a gap, so a successful return does NOT mean the address is mapped. Requiring it to lie inside
     * the returned range is what makes this a description of `address` rather than of its neighbour --
     * and reporting a gap as mapped would be false evidence produced by the diagnostic itself. */
    if ((vm_address_t)address < region ||
        (vm_address_t)address >= region + region_size) {
        snprintf(out, out_size,
                 "%s=%p UNMAPPED (in a gap; vm_region_64 returned the next region at %p)",
                 label, (void *)address, (void *)region);
        if (object != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), object);
        }
        return result;
    }

    snprintf(out, out_size,
             "%s=%p MAPPED[base=%p size=%llu cur=%d max=%d shared=%d%s]",
             label, (void *)address, (void *)region,
             (unsigned long long)region_size,
             (int)info.protection, (int)info.max_protection, (int)info.shared,
             (info.protection == VM_PROT_NONE) ? " NO-ACCESS" : "");

    /* A port RIGHT from the region query, not memory: releasing it is bookkeeping, and it was always
     * done here. No mapping is deallocated in this function. */
    if (object != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), object);
    }

    /* maximum protection is NOT the current one: a region can allow RWX while currently permitting
     * only RX. Reporting the current value in both fields would be a lie in the device evidence. */
    result.mapped = 1;
    result.cur_prot = (int)info.protection;
    result.max_prot = (int)info.max_protection;
    result.base = (uintptr_t)region;
    result.size = (unsigned long long)region_size;
    return result;
}

#endif /* __APPLE__ && __arm64__ */

droidvm_jit_status droidvm_jit_capture(size_t bytes, droidvm_jit_region *out)
{
    if (out == NULL) {
        droidvm_jit_set_reason("capture called with a null out-parameter");
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }
    if (g_held) {
        droidvm_jit_set_reason("a region of %zu bytes is already held", g_region.size);
        return DROIDVM_JIT_ALREADY_HELD;
    }
    if (bytes == 0) {
        droidvm_jit_set_reason("capture called for zero bytes");
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

#if defined(__APPLE__) && defined(__arm64__)
    if (!droidvm_jit_platform_supported()) {
        droidvm_jit_set_reason("executable memory is not available on this platform");
        return DROIDVM_JIT_UNSUPPORTED;
    }

    /* The probe refuses in this situation too. Checking again is not redundant: capture is
     * reachable directly, and this is the last point before the instruction that cannot be
     * survived. A caller that skips the probe must not be able to kill the process. */
    if (!debugger_is_attached()) {
        droidvm_jit_set_reason("refusing to execute the capture trap: no debugger is attached, "
                               "so the trap would terminate the process rather than fail");
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    /* THE ONE-SHOT CHECK COMES BEFORE THE TRAP, and so does the flag that consumes it. Anything
     * that ran the prepare already reported its evidence; asking again would claim another region
     * that is never released. */
    /* A REGION THAT WAS RELEASED IS NOT STILL HELD. The one-shot replays its cached status on a
     * repeat, and after a release that status is a stale OK whose out-parameter is never filled --
     * so Swift would read two null pointers as a valid ready region. */
    if (g_prepare_consumed && g_region_released) {
        droidvm_jit_set_reason("the one-shot diagnostic ran and its region was then released; "
                               "nothing is held. Relaunch to attempt once more.");
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    if (g_prepare_consumed) {
        /* g_prepare_reason, NOT g_reason. The probe has almost certainly overwritten g_reason by
         * now, and reporting that as the first attempt's evidence would hide exactly what the
         * device run was for. */
        droidvm_jit_set_reason("the one-shot diagnostic already ran in this process; reporting the "
                               "evidence it collected rather than asking the provider for another "
                               "region: %s", g_prepare_reason);
        return g_prepare_status;
    }
    g_prepare_consumed = 1;

    void *executable = NULL;
    void *writable = NULL;
    size_t usable = 0;
    droidvm_jit_status status = make_views(bytes, &executable, &writable, &usable);
    if (status != DROIDVM_JIT_OK) {
        g_prepare_status = status;
        snprintf(g_prepare_reason, sizeof(g_prepare_reason), "%s", g_reason);
        /* make_views detaches and releases its own alias on every failure path. */
        return status;
    }
    g_usable = usable;

    /* PHASE 4 -- read/write verification over the PROVEN range. */
    status = verify_readback(executable, writable, usable);
    bringup_mark(&g_bringup.readback, status == DROIDVM_JIT_OK);
    if (status != DROIDVM_JIT_OK) {
        g_prepare_status = status;
        snprintf(g_prepare_reason, sizeof(g_prepare_reason), "%s", g_reason);
        vm_deallocate(mach_task_self(), (vm_address_t)writable, (vm_size_t)usable);
        droidvm_jit_break_detach();
        return status;
    }

    /* DETACH BEFORE EXECUTING. The provider's work is done: the region is a task mapping that
     * outlives the debugger, and leaving the script waiting while we execute would be both pointless
     * and untidy. Detaching here also means a fault in the self-test cannot leave it half-serviced. */
    droidvm_jit_break_detach();

    /* PHASE 5 -- the only execution. */
    status = run_self_test(executable);
    bringup_mark(&g_bringup.jit_selftest, status == DROIDVM_JIT_OK);
    if (status != DROIDVM_JIT_OK) {
        g_prepare_status = status;
        snprintf(g_prepare_reason, sizeof(g_prepare_reason), "%s", g_reason);
        /* The alias is ours, so it goes back. The provider's region is NOT released: it was never
         * ours to allocate, and no ownership contract for it is proven. */
        vm_deallocate(mach_task_self(), (vm_address_t)writable, (vm_size_t)usable);
        return status;
    }

    /* ---------------------------------------------------------------- ALL GREEN: jit = READY
     *
     * This is the only exit that reports a region as usable, and it is reached only after the range
     * was MEASURED, the alias bounded by that measurement, the bytes verified in both directions, and
     * a stub actually executed and returned the right value. */
    g_region.executable = executable;
    g_region.writable = writable;
    g_region.size = usable;
    g_held = 1;

    g_prepare_status = DROIDVM_JIT_OK;
    g_region_released = 0;
    droidvm_jit_set_reason("jit=READY "
                           "requested_bytes=%zu usable_bytes=%zu "
                           "provider_rx=%p first_region_size=%llu regions_walked=%u "
                           "range_complete=%d first_gap_offset=%d gap_reason=%d "
                           "rx_cur_prot=%d rx_max_prot=%d rw_alias=%p "
                           "readback_match=1 jit_selftest=42",
                           bytes, usable,
                           executable,
                           g_range.first_region_size, g_range.regions_walked,
                           g_range.range_complete, g_range.first_gap_offset, g_range.gap_reason,
                           g_range.first_cur_prot, g_range.first_max_prot, writable);

    snprintf(g_prepare_reason, sizeof(g_prepare_reason), "%s", g_reason);
    if (out != NULL) { *out = g_region; }
    return DROIDVM_JIT_OK;

#else
    /* The development host. There is no debugger to service the trap and no iOS to
     * restrict the mapping, so the honest answer is that the mechanism is unsupported --
     * not that an attempt was made and failed. `TrapExecutableMemory` maps this to
     * `.unsupportedPlatform`, which is an environment limitation, which is what the
     * lifecycle shows the user. */
    droidvm_jit_set_reason("no executable-memory mechanism on this platform "
                           "(build targets arm64-apple-ios)");
    return DROIDVM_JIT_UNSUPPORTED;
#endif
}

droidvm_jit_status droidvm_jit_release(void)
{
    if (!g_held) {
        droidvm_jit_set_reason("no region is held");
        return DROIDVM_JIT_OK;
    }

#if defined(__APPLE__) && defined(__arm64__)
    /* RELEASE TOUCHES ONLY WHAT DROIDVM OWNS, AND ISSUES NO TRAP.
     *
     * There is deliberately no detach here. Detaching belongs to a serviced prepare attempt, and it
     * happens on every exit from that attempt. By the time a region is held, the provider has
     * already been told to let go -- so a detach at this point would be a `brk` with no script
     * attached to service it, which does not fail politely: it terminates the process.
     *
     * `g_region.executable` is the PROVIDER's region and is not freed either: its ownership contract
     * is unproven, and the reported size is the whole containing VM region. Only the writable alias,
     * which DroidVM created with vm_remap, is released. */
    vm_deallocate(mach_task_self(), (vm_address_t)g_region.writable, (vm_size_t)g_region.size);
#endif

    g_region_released = 1;
    g_region.executable = NULL;
    g_region.writable = NULL;
    g_region.size = 0;
    g_held = 0;
    droidvm_jit_set_reason("region released");
    return DROIDVM_JIT_OK;
}
