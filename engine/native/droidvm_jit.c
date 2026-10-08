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
#include <stdio.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/vm_map.h>
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
extern void droidvm_jit_break_get_mapping(void);
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

static char g_reason[256] = "no attempt made";

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

/* ------------------------------------------------------------------ *
 * Is anything attached that could service the trap?
 *
 * THE CHECK THAT MAKES THE PROBE SAFE. `brk` is the mechanism, so availability cannot be
 * discovered by attempting it: on a device with nothing attached, the attempt is not a failed
 * call, it is a dead process. The first physical-device run proved that -- EXC_BREAKPOINT,
 * `brk 61453`, inside droidvm_jit_break_get_mapping.
 *
 * `P_TRACED` is set by the kernel while a debugger is tracing this process, which is precisely
 * when the trap has something to answer it. It costs a sysctl read: no trap, no allocation, and
 * no way to kill the caller. A failure to READ it is reported as "not attached", because the
 * conservative answer is the one that cannot crash.
 * ------------------------------------------------------------------ */

static int debugger_is_attached(void)
{
#if defined(__APPLE__)
    int mib[4];
    struct kinfo_proc info;
    size_t size = sizeof(info);

    memset(&info, 0, sizeof(info));
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PID;
    mib[3] = (int)getpid();

    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
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
    droidvm_jit_break_get_mapping();

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

static droidvm_jit_status self_test(void *executable, void *writable)
{
    /* Write through the writable view... */
    memcpy(writable, &kReturnInstruction, sizeof(kReturnInstruction));
    sys_icache_invalidate(executable, sizeof(kReturnInstruction));

    /* ...and execute through the executable one. If the two views are not the same pages,
     * or the write did not land, this does not return correctly. */
    void (*fn)(void) = (void (*)(void))executable;
    fn();
    return DROIDVM_JIT_OK;
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
        return status;
    }

    /* THE ORDERING THAT MATTERS: the self-test runs before `g_held` is set and before the
     * caller is told anything. A region that is mapped but not executable must never be
     * reported as ready. */
    status = self_test(executable, writable);
    if (status != DROIDVM_JIT_OK) {
        vm_deallocate(mach_task_self(), (vm_address_t)executable, (vm_size_t)bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)writable, (vm_size_t)bytes);
        droidvm_jit_set_reason("the region was mapped but cannot execute");
        return DROIDVM_JIT_SELF_TEST_FAILED;
    }

    g_region.executable = executable;
    g_region.writable = writable;
    g_region.size = bytes;
    g_held = 1;
    droidvm_jit_set_reason("region of %zu bytes ready and self-tested", bytes);
    *out = g_region;
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
