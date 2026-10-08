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

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

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

static droidvm_jit_status make_views(size_t bytes,
                                     void **exec_out,
                                     void **write_out)
{
    /* ASK THE PROVIDER FOR THE REGION.
     *
     * x0 = NULL requests a FRESH region, which is the only request whose pages the provider
     * prepares. DroidVM used to vm_allocate its own region and never ask -- and a region we allocate
     * ourselves is exactly the one that does not get prepared, so it ends up with protection bits
     * and no authorization to execute. */
    void *rx = droidvm_jit_break_get_jit_mapping(NULL, bytes);
    if (rx == NULL) {
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

    /* THE RETURNED LENGTH IS CHECKED BEFORE IT IS USED. Handing a shorter region to vm_remap with a
     * longer length remaps past the end of the provider's allocation, and the failure then arrives
     * without the size evidence that explains it.
     *
     * Deliberately NOT clamped: this build measures, and a silent clamp hides the very mismatch it
     * exists to expose. */
    if (rx_info.size < (unsigned long long)bytes) {
        droidvm_jit_set_reason("provider region smaller than requested request: "
                               "requested_bytes=%zu provider_rx_region_size=%llu",
                               bytes, rx_info.size);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    /* The writable alias: locally remapped from the PROVIDER'S region, so it is the same physical
     * pages, and no debugger is involved in creating it -- which is why it would remain valid after
     * a detach. */
    vm_address_t rw = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, /*mask=*/0,
                                VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx,
                                /*copy=*/FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        droidvm_jit_set_reason("vm_remap of the provider's region %p failed (kern_return %d)",
                               rx, (int)kr);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), rw, (vm_size_t)bytes);
        droidvm_jit_set_reason("vm_protect(READ|WRITE) on the alias failed (kern_return %d)",
                               (int)kr);
        droidvm_jit_break_detach();
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

/* NO vm_protect ON THE RX REGION. Its protection is whatever the provider delivered, and the
     * authority to execute it comes from the provider having prepared its pages -- not from bits we
     * could set ourselves. Setting them ourselves is precisely what produced a mapping that read as
     * READ|EXEC and faulted on its first instruction. */

    *exec_out = rx;
    *write_out = (void *)rw;
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
    droidvm_jit_status status = make_views(bytes, &executable, &writable);
    if (status != DROIDVM_JIT_OK) {
        g_prepare_status = status;
        snprintf(g_prepare_reason, sizeof(g_prepare_reason), "%s", g_reason);
        /* make_views runs the prepare trap BEFORE it can fail, so provider state may exist even
         * though we obtained nothing usable -- and make_views detaches and deallocates on each of
         * its own failure paths. Nothing is left for this branch to release. */
        return status;
    }

    /* DIAGNOSTIC BUILD -- THIS PATH NEVER EXECUTES THE REGION, so it never reports one as ready.
     *
     * `g_held` is deliberately not set and the out-parameter is deliberately not written: nothing
     * has been shown to be executable, and claiming otherwise is the failure this project exists
     * not to make.
     *
     * The success path (set `g_held`, fill `*out`, return OK) returns when the alias contract is
     * proven from the device evidence this function produces -- as a decision backed by data, not
     * as a line left lying around. */
    status = diagnose_views(executable, writable, bytes);
    g_prepare_status = status;
    snprintf(g_prepare_reason, sizeof(g_prepare_reason), "%s", g_reason);

    /* GET OUT CLEANLY, FREEING ONLY WHAT IS OURS.
     *
     * The writable alias was created here by vm_remap, so it is DroidVM's to release and it is
     * released.
     *
     * The provider's region is NOT released. It was created by the external JIT provider and there
     * is no proven ownership contract that says DroidVM may unmap it -- while `region_probe` reports
     * the size of the whole VM region CONTAINING the address, so freeing that many bytes could unmap
     * memory that is not part of the allocation at all. Its lifetime is therefore left to process
     * termination in this diagnostic build, which is the safe choice while the contract is unproven.
     *
     * The detach is unconditional: the debugger's script must not be left waiting. */
    vm_deallocate(mach_task_self(), (vm_address_t)writable, (vm_size_t)bytes);
    droidvm_jit_break_detach();

    return status;

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

    g_region.executable = NULL;
    g_region.writable = NULL;
    g_region.size = 0;
    g_held = 0;
    droidvm_jit_set_reason("region released");
    return DROIDVM_JIT_OK;
}
