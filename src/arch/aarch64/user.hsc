package arch_aarch64

import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * User-mode registers (arch_interface, User State): a thread's RegisterFrame, as the entry function saves it
 * and return_to_user restores it. System calls follow the system ABI (knowledge/design/system-abi.md,
 * decisions/0066): svc #0 with the number in x8, arguments in x0 to x5, and results in x0, x1 and x2.
 */

/** SPSR_EL1 for user mode: EL0 (EL0t), with no interrupt masked. */
USER_SPSR : u64 : 0

/**
 * Set a new thread's registers (arch_interface.init_user_registers): every one zero but its instruction and stack
 * pointers and its argument in x0, at EL0 with interrupts unmasked, so no kernel value leaks.
 *
 * @param registers The thread's registers, overwritten whole.
 * @param start Where it starts: its first instruction (ELR_EL1), its stack pointer (SP_EL0), and x0's argument.
 */
init_user_registers :: fn(registers: ptr[mut UserRegisters], start: ptr[arch_interface.UserStart]) {
    registers.frame = aarch64.RegisterFrame.{}
    registers.frame.elr = cast[u64](start.instruction_pointer)
    registers.frame.sp_el0 = cast[u64](start.stack_pointer)
    registers.frame.x[0] = start.argument
    registers.frame.spsr = USER_SPSR
}

/**
 * Read a system call's number (arch_interface.syscall_number).
 *
 * @param registers The calling thread's registers, saved at its svc.
 * @return x8, as user mode set it; any value, unchecked.
 */
syscall_number :: fn(registers: ptr[UserRegisters]) -> u64 {
    return registers.frame.x[8]
}

/**
 * Read one of a system call's arguments (arch_interface.syscall_argument).
 *
 * @param registers The calling thread's registers, saved at its svc.
 * @param index Which argument, 0 to 5, in x0 to x5.
 * @return The argument register's value, as user mode set it; 0 for an index past the sixth.
 */
syscall_argument :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    if index >= 6 {
        return 0
    }
    return registers.frame.x[cast[usize](index)]
}

/**
 * Put a system call's result in the thread's result registers (arch_interface.set_syscall_result).
 *
 * @param registers The calling thread's registers, which it returns to.
 * @param result The result: its tag goes in x0, its two values in x1 and x2.
 */
set_syscall_result :: fn(registers: ptr[mut UserRegisters], result: ptr[arch_interface.SyscallResult]) {
    registers.frame.x[0] = result.tag
    registers.frame.x[1] = result.values[0]
    registers.frame.x[2] = result.values[1]
}

/**
 * Read where the thread runs next (arch_interface.instruction_pointer).
 *
 * @param registers The thread's registers.
 * @return ELR_EL1 as saved: after an svc, the instruction after it; after a fault, the faulting instruction.
 */
instruction_pointer :: fn(registers: ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](registers.frame.elr)
}

/**
 * Move the thread back to its svc, so returning to user mode makes the call again (arch_interface.restart_syscall).
 *
 * @param registers The thread's registers, saved at an svc: ELR_EL1 is just past it, which is 4 bytes, as every
 *     instruction is, so it goes back 4.
 */
restart_syscall :: fn(registers: ptr[mut UserRegisters]) {
    registers.frame.elr -= 4
}

/**
 * The PSTATE bits user mode may set: its condition flags, NZCV (bits 28 to 31).
 *
 * SPEC: Arm ARM (DDI 0487) C5.2.18 (SPSR_EL1).
 */
USER_CHANGEABLE_FLAGS : u64 : 0xf0000000

// x0 to x30, sp, pc, pstate (slop_os.THREAD_REGISTERS).
/** How many registers a debugger sees: x0 to x30, sp, pc and pstate (slop_os.THREAD_REGISTERS). */
USER_REGISTER_COUNT :: 34
/** The debugger's index of sp, SP_EL0. */
SP_INDEX : u32 : 31
/** The debugger's index of pc, ELR_EL1. */
PC_INDEX : u32 : 32
/** The debugger's index of pstate, SPSR_EL1. */
PSTATE_INDEX : u32 : 33

/**
 * Give how many registers a debugger sees (arch_interface.user_register_count).
 *
 * @return USER_REGISTER_COUNT, 34.
 */
user_register_count :: fn() -> u32 {
    return USER_REGISTER_COUNT
}

/**
 * Read one of a thread's registers as a debugger sees them (arch_interface.get_user_register).
 *
 * @param registers The thread's registers.
 * @param index 0 to 30 for x0 to x30, then SP_INDEX, PC_INDEX and PSTATE_INDEX.
 * @return The register's value; 0 for an index past PSTATE_INDEX.
 */
get_user_register :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    frame :: &registers.frame
    if index < 31 {
        return frame.x[cast[usize](index)]
    }
    return match index {
        case SP_INDEX => frame.sp_el0
        case PC_INDEX => frame.elr
        case PSTATE_INDEX => frame.spsr
        case _ => cast[u64](0)
    }
}

/**
 * Set one of a thread's registers as a debugger sees them (arch_interface.set_user_register).
 *
 * @param registers The thread's registers.
 * @param index 0 to 30 for x0 to x30, then SP_INDEX, PC_INDEX and PSTATE_INDEX.
 * @param value The new value. For pstate, only the bits in USER_CHANGEABLE_FLAGS are taken; the rest are kept.
 * @return False, with nothing changed, for an index past PSTATE_INDEX, or an sp or pc outside user addresses
 *     (user_address_range), which would fault as soon as the thread ran; true otherwise.
 */
set_user_register :: fn(registers: ptr[mut UserRegisters], index: u32, value: u64) -> bool {
    frame :: &registers.frame
    low, high :: user_address_range()
    // An instruction or stack pointer outside user addresses would fault as soon as the thread ran
    if (index == SP_INDEX || index == PC_INDEX) && (value < cast[u64](low) || value >= cast[u64](high)) {
        return false
    }
    if index < 31 {
        frame.x[cast[usize](index)] = value
        return true
    }
    if index == SP_INDEX {
        frame.sp_el0 = value
    }
    else if index == PC_INDEX {
        frame.elr = value
    }
    else if index == PSTATE_INDEX {
        frame.spsr = (frame.spsr & ~USER_CHANGEABLE_FLAGS) | (value & USER_CHANGEABLE_FLAGS)
    }
    else {
        return false
    }
    return true
}

/**
 * Return to user mode with registers, by eret, on the calling CPU's active page table (arch_interface.return_to_user).
 *
 * SP_EL1 is set to the kernel stack's top, so the next entry from user mode starts there.
 *
 * @param registers The thread's registers, restored whole.
 */
return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    aarch64.return_to_user(&registers.frame, cast[rawptr](current_cpu().kernel_stack_top))
}
