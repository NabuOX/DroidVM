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
 * bookkeeping around it: the status machine, the reason strings, the two-view mapping, and
 * -- most importantly -- the self-test that decides whether the region is actually usable.
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
 * A region can be returned that is mapped and still cannot execute. A flag saying "we have
 * executable memory" that is set before something has run in it converts that into a
 * mystery several layers away. So the self-test happens here, before any status other than
 * SELF_TEST_FAILED is possible.
 */

#include "droidvm_native.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
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
/* Returns the provider's prepared region in x0, according to droidvm-brk.S: the handler's answer
 * is the function's return value. DECLARED SO IT CAN BE RECORDED, not so it can be used: nothing
 * in this file dereferences it, and the allocation flow ignores it. */
extern uintptr_t droidvm_jit_break_get_mapping(void);
extern void droidvm_jit_break_release_mapping(void);
extern void droidvm_jit_break_mark_executable(void);
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

/* ------------------------------------------------------------------ *
 * The self-test
 *
 * THE POINT OF THIS FILE. A region that is mapped but cannot execute is the failure that
 * looks like success: everything reports fine until something jumps into it, and by then
 * the explanation is several layers away.
 *
 * The test writes a single `ret` and calls it. If the mapping is not executable the call
 * faults; if the write did not reach the executable view, the call returns to the wrong
 * place. Neither is survivable in-process, so on Darwin this runs with the two views
 * established and any failure is caught by the caller's own signal handling -- which is why
 * the ordering below matters and why the flag is set only after everything else.
 * ------------------------------------------------------------------ */

#if defined(__APPLE__) && defined(__arm64__)
/* The trap's raw return register, recorded by make_views and reported by capture.
 *
 * EVIDENCE ONLY. Nothing in this file dereferences it, and the mapping flow ignores it. It lives at
 * file scope because the function that asks the trap and the function that reports the answer are
 * different functions -- a local could not be seen by the one that needs it. */
static uintptr_t g_provider_return_raw;

/* ARM64: `ret`. One instruction, no operands, no state. */
static const uint32_t kReturnInstruction = 0xd65f03c0u;

static droidvm_jit_status make_views(size_t bytes,
                                     void **exec_out,
                                     void **write_out)
{
    /* The executable view is created by the debugger, which maps it on our behalf once the
     * trap has been serviced. What we get back is a region; the writable alias of those
     * same pages is made here with vm_remap, which is the only supported way to get a
     * second view of a mapping we do not own. */
    /* EVIDENCE ONLY. The value is recorded and reported. It is never dereferenced, never used as
     * exec_out or write_out, never passed to memcpy, and never assumed to be an address. The
     * mapping below is DroidVM's own allocation, exactly as before. */
    g_provider_return_raw = droidvm_jit_break_get_mapping();

    vm_address_t base = 0;
    vm_size_t size = 0;

    /* Ask the kernel for our own executable region. A debugger that has been asked for a
     * mapping exposes it through the trap's side effects; when it has not, this is where
     * the attempt fails, and it fails here rather than later. */
    vm_address_t requested = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &requested, (vm_size_t)bytes,
                                   VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        droidvm_jit_set_reason("vm_allocate failed (kern_return %d)", (int)kr);
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }
    base = requested;
    size = (vm_size_t)bytes;

    /* The executable view: the same pages, mapped RX. Removing write permission is what
     * makes the mapping executable rather than writable, and the split is the whole point. */
    kr = vm_protect(mach_task_self(), base, size, FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), base, size);
        droidvm_jit_set_reason("vm_protect to RX failed (kern_return %d)", (int)kr);
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    /* The writable alias. VM_PROT_READ|VM_PROT_WRITE here, and the two views are distinct
     * mappings of the same physical pages.
     *
     * `vm_remap`, not `mach_vm_remap`. Both exist and on arm64 they are the same width, but
     * they are different families with different headers:
     *
     *   vm_*        <mach/vm_map.h>     vm_allocate, vm_protect, vm_deallocate, vm_remap
     *   mach_vm_*   <mach/mach_vm.h>    mach_vm_allocate, mach_vm_remap, ...
     *
     * Every other call in this function is the natural-width `vm_*` family, so mixing in one
     * `mach_vm_*` call was an inconsistency rather than a deliberate choice -- and it did not
     * compile, because <mach/mach_vm.h> is not included. Using `vm_remap` keeps the function
     * in one family and needs no additional header. */
    vm_address_t writable = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kr = vm_remap(mach_task_self(), &writable, (vm_size_t)size, 0,
                  VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR,
                  mach_task_self(), base, FALSE,
                  &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), base, size);
        droidvm_jit_set_reason("vm_remap for the writable alias failed "
                               "(kern_return %d)", (int)kr);
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }
    kr = vm_protect(mach_task_self(), writable, size, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), writable, size);
        vm_deallocate(mach_task_self(), base, size);
        droidvm_jit_set_reason("vm_protect to RW failed (kern_return %d)", (int)kr);
        return DROIDVM_JIT_ALLOCATION_FAILED;
    }

    *exec_out = (void *)base;
    *write_out = (void *)writable;
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
 * Nothing here dereferences `provider_return_raw`. It is described by the kernel like any other
 * address, which is how a wrong assumption about it is discovered instead of taken on faith.
 * ------------------------------------------------------------------ */

#define DROIDVM_DIAG_REGION_LEN 200

/* The three states a region probe can report. UNMAPPED and NO_ACCESS are NOT the same: one means
 * the kernel has no entry, the other means it has one that grants nothing. Collapsing them would
 * make "we cannot read this" indistinguishable from "this does not exist". */
#define DROIDVM_REGION_UNMAPPED  (-1)

/* Returns the current protection bits for `address`, or DROIDVM_REGION_UNMAPPED.
 *
 * The distinction that matters: a region mapped with VM_PROT_NONE returns 0, which is a real
 * answer, while an address with no region at all returns -1. Callers must not treat 0 as absent.
 *
 * ASKS THE KERNEL, never the memory: `mach_vm_region` answers from the task's map, so a bogus or
 * unreadable address is reported rather than faulted on. */
static int region_probe(const char *label, uintptr_t address, char *out, size_t out_size)
{
    if (address == 0) {
        snprintf(out, out_size, "%s=0 (no value returned by the trap)", label);
        return DROIDVM_REGION_UNMAPPED;
    }

    mach_vm_address_t region = (mach_vm_address_t)address;
    mach_vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    memset(&info, 0, sizeof(info));

    kern_return_t kr = mach_vm_region(mach_task_self(), &region, &region_size,
                                      VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) {
        snprintf(out, out_size, "%s=%p UNMAPPED (kr=%d)", label, (void *)address, (int)kr);
        return DROIDVM_REGION_UNMAPPED;
    }

    /* `mach_vm_region` answers with the NEXT region when the address falls in a gap, so a
     * successful return does NOT mean the address is mapped. Requiring it to lie inside the
     * returned range is what makes this a description of `address` rather than of its neighbour --
     * and reporting a gap as mapped would be false evidence from the diagnostic itself. */
    if ((mach_vm_address_t)address < region ||
        (mach_vm_address_t)address >= region + region_size) {
        snprintf(out, out_size,
                 "%s=%p UNMAPPED (in a gap; mach_vm_region returned the next region at %p)",
                 label, (void *)address, (void *)region);
        if (object != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), object);
        }
        return DROIDVM_REGION_UNMAPPED;
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
    return (int)info.protection;
}

static droidvm_jit_status diagnose_views(void *executable, void *writable, size_t bytes,
                                         uintptr_t provider_return_raw)
{
    /* An arm64 `ret` followed by zeros. Written and read back; NEVER EXECUTED.
     *
     * Built from kReturnInstruction rather than repeating its bytes: the instruction is defined
     * once, so the pattern cannot drift from what execution would eventually run. */
    uint8_t pattern[16];
    memset(pattern, 0, sizeof(pattern));
    memcpy(pattern, &kReturnInstruction, sizeof(kReturnInstruction));

    uint8_t readback[16];
    char exec_info[DROIDVM_DIAG_REGION_LEN];
    char write_info[DROIDVM_DIAG_REGION_LEN];
    char provider_info[DROIDVM_DIAG_REGION_LEN];

    memset(readback, 0, sizeof(readback));

    int exec_prot = region_probe("exec", (uintptr_t)executable, exec_info, sizeof(exec_info));
    int write_prot = region_probe("write", (uintptr_t)writable, write_info, sizeof(write_info));

    /* uintptr_t arithmetic, then a signed result: subtracting two pointers that do not point into
     * one array is undefined behaviour, even when the difference is what we want to report. */
    int64_t alias_delta = (int64_t)((uintptr_t)writable - (uintptr_t)executable);

    /* Described only. Not dereferenced, not used as a pointer, not assumed to be an address. */
    region_probe("provider_raw", provider_return_raw, provider_info, sizeof(provider_info));

    /* The read through the executable alias happens ONLY when the kernel says that address is
     * readable. A mapping described by the log is not the same as one that is mapped, and this is
     * the check that turns "we assumed" into "we asked". */
    int match = -1; /* -1 means the comparison was not attempted. */
    int attempted = 0;

    if ((exec_prot & VM_PROT_READ) != 0 && (write_prot & VM_PROT_WRITE) != 0) {
        attempted = 1;
        memcpy(writable, pattern, sizeof(pattern));
        sys_icache_invalidate(executable, sizeof(pattern));
        memcpy(readback, executable, sizeof(pattern));
        match = (memcmp(readback, pattern, sizeof(pattern)) == 0) ? 1 : 0;
    }

    droidvm_jit_set_reason("diagnostic stop before execution: provider_raw=%p "
                           "exec=%p write=%p delta=%lld size=%zu readback_attempted=%d match=%d "
                           "wrote=%02x%02x%02x%02x read=%02x%02x%02x%02x || %s || %s || %s",
                           (void *)provider_return_raw,
                           executable, writable,
                           (long long)alias_delta,
                           bytes, attempted, match,
                           pattern[0], pattern[1], pattern[2], pattern[3],
                           readback[0], readback[1], readback[2], readback[3],
                           exec_info, write_info, provider_info);

    /* A controlled stop, never a crash, and NOT an execution failure: execution was deliberately
     * not attempted. Saying "self-test failed" here would be a lie the Swift layer repeats. */
    return DROIDVM_JIT_DIAGNOSTIC_STOP;
}

#endif /* __APPLE__ && __arm64__ */

/* ------------------------------------------------------------------ *
 * Capture
 * ------------------------------------------------------------------ */

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

    void *executable = NULL;
    void *writable = NULL;
    droidvm_jit_status status = make_views(bytes, &executable, &writable);
    if (status != DROIDVM_JIT_OK) {
        /* make_views executes the get-mapping trap BEFORE it allocates, so provider state may exist
         * even though the local mapping failed. Releasing only on the success path would let a
         * retry inherit the previous attempt's mapping and fail for a reason this run caused. */
        droidvm_jit_break_release_mapping();
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
    status = diagnose_views(executable, writable, bytes, g_provider_return_raw);
    vm_deallocate(mach_task_self(), (vm_address_t)executable, (vm_size_t)bytes);
    vm_deallocate(mach_task_self(), (vm_address_t)writable, (vm_size_t)bytes);

    /* Give the provider's mapping back before returning. We asked for it and never used it, and a
     * diagnostic that runs on every device test must not accumulate provider state: the next
     * attempt would then fail for a reason the previous one caused.
     *
     * Safe here because this is behind the attached-debugger gate, so the trap has a responder --
     * and it is a command, not an execution. */
    droidvm_jit_break_release_mapping();

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
    /* Ask the debugger to release its side first, then drop our own two views. */
    droidvm_jit_break_release_mapping();
    vm_deallocate(mach_task_self(), (vm_address_t)g_region.writable, (vm_size_t)g_region.size);
    vm_deallocate(mach_task_self(), (vm_address_t)g_region.executable, (vm_size_t)g_region.size);
#endif

    g_region.executable = NULL;
    g_region.writable = NULL;
    g_region.size = 0;
    g_held = 0;
    droidvm_jit_set_reason("region released");
    return DROIDVM_JIT_OK;
}
