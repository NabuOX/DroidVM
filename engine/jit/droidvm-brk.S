// SPDX-License-Identifier: GPL-2.0-or-later
//
// The trap protocol by which DroidVM asks an attached debugger for executable memory.
//
// STATUS: written in Phase 1, NOT ASSEMBLED and NOT RUN. It needs an arm64 iOS toolchain and
// a device. scripts/check_engine.sh verifies only that the three instruction pairs are
// present and that nothing has been added to them; it cannot assemble for arm64-ios here.
//
// WHAT THIS IS, AND WHAT IT IS NOT
//
// These are TWO instruction pairs. Executing a `brk` is how a process asks whatever
// debugger is attached to do something on its behalf.
//
// x16 carries the command. ARGUMENTS ARRIVE IN x0/x1, and the result is written back into x0
// before the debugger resumes us -- so the trailing `ret` returns it.
//
//   x0 = NULL asks for a FRESH region for the provider to allocate. That is the only branch
//   that gets a region whose pages the provider prepares; handing in an address DroidVM
//   allocated itself does not, which is why DroidVM now asks for the region rather than
//   allocating one.
//
// This reproduces an *interface* -- the trap immediates and the register command numbers,
// all of which are documented in the debugger's own published script -- not anybody's
// creative expression. The reference implementation took the same position when it declined
// to depend on an unlicensed binary that contained exactly these three pairs, and the
// reasoning is recorded in THIRD_PARTY.md.
//
// A NOTE ON THE COMMAND NUMBERS
//
//   0xf00d  the customary "map this for me / unmap it" trap. x16 = 1 asks for a mapping,
//           x16 = 0 releases it.
//
// Both immediates appear in the debugger's own script, which is why following them is
// following a protocol rather than copying an implementation.

#if defined(__arm64__) || defined(__aarch64__)

.text
.align 2

// void *droidvm_jit_break_get_jit_mapping(void *addr, size_t len)
//   Ask the provider for an execute-capable region.
//
//   x0 = addr: NULL requests a FRESH region, which is the only request the provider prepares.
//   x1 = len:  the size requested.
//   x16 = 1 selects "prepare region".
//
//   Returns the region address in x0, or 0 on failure. The argument registers are already
//   where the protocol expects them, so this body only sets the command.
.globl _droidvm_jit_break_get_jit_mapping
_droidvm_jit_break_get_jit_mapping:
    mov x16, #0x1
    brk #0xf00d
    ret

// void droidvm_jit_break_detach(void)
//   Let the provider go. x16 = 0 is the detach command.
//
//   The protocol has exactly two commands. A preparation that is never followed by a detach leaves
//   the debugger's script attached and waiting, so this is called on every exit from the trap path.
.globl _droidvm_jit_break_detach
_droidvm_jit_break_detach:
    mov x16, #0x0
    brk #0xf00d
    ret

#endif
