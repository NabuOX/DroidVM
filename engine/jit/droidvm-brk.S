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
// These are three instruction pairs. Executing a `brk` is how a process asks whatever
// debugger is attached to do something on its behalf, and the command number travels in
// x16. The debugger's handler returns a prepared region; the mapping is then re-mapped
// executable by the debugger, and DroidVM makes a writable alias of the same pages so the
// translator can write what the emulated CPU will execute.
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
//   0x69    marks an existing mapping as executable without going through 0xf00d.
//
// Both immediates appear in the debugger's own script, which is why following them is
// following a protocol rather than copying an implementation.

#if defined(__arm64__) || defined(__aarch64__)

.text
.align 2

// droidvm_jit_break_get_mapping()
//   Ask the debugger to prepare a mapping for the JIT region.
//   x16 = 1 is the "get" command.
.globl _droidvm_jit_break_get_mapping
_droidvm_jit_break_get_mapping:
    mov x16, #0x1
    brk #0xf00d
    ret

// droidvm_jit_break_release_mapping()
//   Release it. x16 = 0 is the "detach / release" command.
.globl _droidvm_jit_break_release_mapping
_droidvm_jit_break_release_mapping:
    mov x16, #0x0
    brk #0xf00d
    ret

// droidvm_jit_break_mark_executable()
//   Mark an existing mapping executable, without the 0xf00d round trip. Used when a region
//   was obtained by other means and only needs its permissions changed.
.globl _droidvm_jit_break_mark_executable
_droidvm_jit_break_mark_executable:
    brk #0x69
    ret

#endif
