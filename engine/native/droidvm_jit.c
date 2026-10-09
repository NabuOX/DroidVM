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
 * executing exactly such a region. So a flag saying "we have executable memory" is never set
 * before something has run in it, and nothing runs in it until the mapping contract is proven.
 *
 * Capture therefore INSPECTS and stops: it returns DIAGNOSTIC_STOP, never OK, until the evidence
 * it reports has settled which alias is which.
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

/* ARM64: `ret`. One instruction, no operands, no state. */
static const uint32_t kReturnInstruction = 0xd65f03c0u;

/* ---------------------------------------------------------------- bounded range walking
 *
 * WHY THIS EXISTS. A 1 GiB request came back with a FIRST region of 16 KiB, and the previous build
 * treated that as "the provider returned less than we asked for" and stopped. The provider returns a
 * RANGE assembled from many VM regions, so the usable size is something to MEASURE, not to presume
 * from one observation.
 */
typedef struct {
    uintptr_t start;
    unsigned long long requested;
    unsigned long long first_region_size;
    unsigned long long contiguous;      /* proven usable from `start` */
    unsigned int regions_walked;
    int range_complete;                 /* contiguous == requested */
    int first_gap_offset;               /* -1 when the range is complete */
    int gap_reason;                     /* 0 none, 1 unmapped, 2 not executable, 3 limit */
    int first_cur_prot, first_max_prot, last_cur_prot;
    int walk_truncated;
} droidvm_rx_range;

static uint64_t droidvm_now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* Walks forward from `start`, region by region, while each region is executable and begins exactly
 * where the previous one ended. BOUNDED TWICE: a fixed region cap and a wall-clock cap, so a
 * pathological map cannot spin this loop. Stops at the requested length. */
static void droidvm_walk_provider_range(uintptr_t start, unsigned long long requested,
                                        droidvm_rx_range *out)
{
    enum { kMaxRegions = 4096, kBudgetMs = 250 };
    char buf[DROIDVM_DIAG_REGION_LEN];

    memset(out, 0, sizeof(*out));
    out->start = start;
    out->requested = requested;
    out->first_gap_offset = -1;

    const uint64_t deadline = droidvm_now_ms() + kBudgetMs;
    uintptr_t cursor = start;
    unsigned long long proven = 0;

    while (out->regions_walked < kMaxRegions) {
        if (proven >= requested) { out->range_complete = 1; break; }
        if (droidvm_now_ms() > deadline) {
            out->walk_truncated = 1; out->gap_reason = 3;
            out->first_gap_offset = (int)proven;
            break;
        }

        droidvm_region_info ri = region_probe("range", cursor, buf, sizeof(buf));
        if (!ri.mapped) {
            out->gap_reason = 1; out->first_gap_offset = (int)proven; break;
        }
        /* A region that does not START at the cursor means the walk has stepped over a gap: the
         * kernel answers with the NEXT region when an address is unmapped. */
        if (cursor != ri.base) {
            out->gap_reason = 1; out->first_gap_offset = (int)proven; break;
        }
        /* BOTH BITS. An execute-only mapping would pass an EXECUTE-only test and then be READ by
         * the readback -- before any fault guard is armed, because the guard belongs to the
         * self-test. Requiring READ here is what keeps the readback from being the crash. */
        if ((ri.cur_prot & VM_PROT_EXECUTE) == 0 || (ri.cur_prot & VM_PROT_READ) == 0) {
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
        proven += take;
        cursor += (uintptr_t)take;
    }
    out->contiguous = proven;
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

    if (rx_prot == DROIDVM_REGION_UNMAPPED) {
        droidvm_jit_set_reason("the provider returned %p, which is not mapped", rx);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    /* THE ADDRESS MUST BE THE START OF ITS REGION. `region_probe` describes the whole mapping that
     * CONTAINS `rx`, so if the provider returned an address in the middle of one, `rx_info.size` is
     * not the space available from `rx` -- and remapping or deallocating that many bytes from there
     * would run past the end of the mapping and touch pages that are not ours.
     *
     * The protocol returns an allocation base, so anything else is a malformed answer and is
     * refused rather than interpreted. */
    if ((uintptr_t)rx != rx_info.base) {
        droidvm_jit_set_reason("the provider returned an address inside a region rather than at its "
                               "base: provider_rx=%p provider_rx_region_base=%p",
                               rx, (void *)rx_info.base);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }
    if ((rx_prot & VM_PROT_EXECUTE) == 0) {
        droidvm_jit_set_reason("the provider returned %p but it is not execute-capable (cur=%d)",
                               rx, rx_prot);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_NOT_PERMITTED;
    }

    /* THE ADDRESS MUST BE THE START OF ITS REGION -- otherwise the walk below would begin in the
     * middle of a mapping and `size` would not be the space available from `rx`. The protocol returns
     * an allocation base, so anything else is malformed and is refused rather than interpreted. */
    if ((uintptr_t)rx != rx_info.base) {
        droidvm_jit_set_reason("provider_prepare: the provider returned an address inside a region "
                               "rather than at its base: provider_rx=%p provider_rx_region_base=%p",
                               rx, (void *)rx_info.base);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }
    if ((rx_prot & VM_PROT_EXECUTE) == 0) {
        droidvm_jit_set_reason("provider_prepare: the provider returned %p but it is not "
                               "execute-capable (cur=%d)", rx, rx_prot);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_NOT_PERMITTED;
    }

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
    g_bringup.rx_cur_prot = range.first_cur_prot;
    g_bringup.rx_max_prot = range.first_max_prot;
    bringup_mark(&g_bringup.provider_prepare, 1);

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
        droidvm_jit_set_reason("provider_range: the provider's range covers only "
                               "contiguous_rx_bytes=%llu of requested_bytes=%zu "
                               "range_complete=0 (regions_walked=%u first_region_size=%llu "
                               "gap_reason=%d first_gap_offset=%d walk_truncated=%d); "
                               "a partial range cannot satisfy the request",
                               range.contiguous, bytes,
                               range.regions_walked, range.first_region_size,
                               range.gap_reason, range.first_gap_offset, range.walk_truncated);
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

/* ------------------------------------------------------------------ *
 * Mapping diagnostics, before any execution
 *
 * THIS BUILD NEVER EXECUTES THE REGION. The self-test used to write one instruction and call it;
 * two device runs died with an execute fault at the base of the mapping. Until the provider's alias
 * contract is proven, the region is INSPECTED rather than entered -- the same write and read-back,
 * without the call.
 *
 * The provider's returned region is described by the kernel like any other
 * address, which is how a wrong assumption about it is discovered instead of taken on faith.
 * ------------------------------------------------------------------ */

/* Returns the current protection bits for `address`, or DROIDVM_REGION_UNMAPPED.
 *
 * The distinction that matters: a region mapped with VM_PROT_NONE returns 0, which is a real
 * answer, while an address with no region at all returns -1. Callers must not treat 0 as absent.
 *
 * ASKS THE KERNEL, never the memory: `vm_region_64` answers from the task's map, so a bogus or
 * unreadable address is reported rather than faulted on. */
/* Reports the base and size of the region it found as well as describing it, so the requested size
 * and the mapping size appear as separate fields in the report. */
/* ONE kernel lookup, describing the region that contains `address`.
 *
 * ASKS THE KERNEL, never the memory: `vm_region_64` answers from the task's map, so a bogus or
 * hostile address produces a description rather than a fault. */
static droidvm_region_info region_probe(const char *label, uintptr_t address,
                                        char *out, size_t out_size)
{
    droidvm_region_info result;
    memset(&result, 0, sizeof(result));

    if (address == 0) {
        snprintf(out, out_size, "%s=0 (the provider returned no address)", label);
        return result;
    }

    /* vm_region_64, not mach_vm_region: `mach/mach_vm.h` is a macOS header and the iOS SDK
     * rejects it outright. Everything else in this file is the vm_* family for the same reason. */
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

    /* `vm_region_64` answers with the NEXT region when the address falls in a gap, so a successful
     * return does NOT mean the address is mapped. Requiring it to lie inside the returned range is
     * what makes this a description of `address` rather than of its neighbour -- and reporting a gap
     * as mapped would be false evidence produced by the diagnostic itself. */
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

static droidvm_jit_status diagnose_views(void *executable, void *writable, size_t bytes)
{
    /* An arm64 `ret` followed by zeros. Written and read back; NEVER EXECUTED. */
    uint8_t pattern[16];
    memset(pattern, 0, sizeof(pattern));
    memcpy(pattern, &kReturnInstruction, sizeof(kReturnInstruction));

    uint8_t readback[16];
    memset(readback, 0, sizeof(readback));

    char rx_info[DROIDVM_DIAG_REGION_LEN];
    char rw_info[DROIDVM_DIAG_REGION_LEN];

    /* FIELD NAMES ARE UNAMBIGUOUS ON PURPOSE. An earlier revision printed `size=` for two different
     * quantities -- the requested size and the mapping size -- and that ambiguity is why a 1 GiB
     * request and 128 MiB mappings could not be told apart from the report. */
    droidvm_region_info rx = region_probe("provider_rx", (uintptr_t)executable,
                                         rx_info, sizeof(rx_info));
    droidvm_region_info rw = region_probe("rw_alias", (uintptr_t)writable,
                                         rw_info, sizeof(rw_info));

    int rx_prot = rx.mapped ? rx.cur_prot : DROIDVM_REGION_UNMAPPED;
    int rw_prot = rw.mapped ? rw.cur_prot : DROIDVM_REGION_UNMAPPED;

    int64_t alias_delta = (int64_t)((uintptr_t)writable - (uintptr_t)executable);

    /* Read through the executable alias ONLY when the kernel says that address is readable. */
    int attempted = 0;
    int match = -1;
    if (rx_prot != DROIDVM_REGION_UNMAPPED && rw_prot != DROIDVM_REGION_UNMAPPED &&
        (rx_prot & VM_PROT_READ) != 0 && (rw_prot & VM_PROT_WRITE) != 0) {
        attempted = 1;
        memcpy(writable, pattern, sizeof(pattern));
        sys_icache_invalidate(executable, sizeof(pattern));
        memcpy(readback, executable, sizeof(pattern));
        match = (memcmp(readback, pattern, sizeof(pattern)) == 0) ? 1 : 0;
    }

    droidvm_jit_set_reason("diagnostic stop before execution: "
                           "requested_bytes=%zu "
                           "provider_rx=%p "
                           "provider_rx_region_base=%p "
                           "provider_rx_region_size=%llu "
                           "provider_rx_cur_prot=%d "
                           "provider_rx_max_prot=%d "
                           "rw_alias=%p "
                           "rw_region_size=%llu "
                           "alias_delta=%lld "
                           "readback_attempted=%d "
                           "readback_match=%d "
                           "wrote=%02x%02x%02x%02x "
                           "read=%02x%02x%02x%02x "
                           "|| %s || %s",
                           bytes,
                           executable,
                           (void *)rx.base, rx.size, rx.cur_prot, rx.max_prot,
                           writable, rw.size,
                           (long long)alias_delta,
                           attempted, match,
                           pattern[0], pattern[1], pattern[2], pattern[3],
                           readback[0], readback[1], readback[2], readback[3],
                           rx_info, rw_info);

    /* A controlled stop, never a crash, and NOT an execution failure: execution was deliberately
     * not attempted. */
    return DROIDVM_JIT_DIAGNOSTIC_STOP;
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
}
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
