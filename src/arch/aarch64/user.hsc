package arch_aarch64

import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * User-mode registers (arch_interface, User State): a thread's RegisterFrame, as the entry function saves it
 * and return_to_user restores it. System calls follow the system ABI (knowledge/design/system-abi.md,
 * decisions/0066): svc #0 with the number in x8, arguments in x0 to x5, and results in x0, x1 and x2.
 */

// SPSR_EL1 for user mode: EL0 (EL0t), with no interrupt masked.
USER_SPSR : u64 : 0

/*
 * A new thread's registers: every one zero but its instruction and stack pointers and its argument in x0, at
 * EL0 with interrupts unmasked.
 */
init_user_registers :: fn(registers: ptr[mut UserRegisters], start: ptr[arch_interface.UserStart]) {
    registers.frame = aarch64.RegisterFrame.{}
    registers.frame.elr = cast[u64](start.instruction_pointer)
    registers.frame.sp_el0 = cast[u64](start.stack_pointer)
    registers.frame.x[0] = start.argument
    registers.frame.spsr = USER_SPSR
}

syscall_number :: fn(registers: ptr[UserRegisters]) -> u64 {
    return registers.frame.x[8]
}

// One of the six argument registers, x0 to x5, by index; 0 past the sixth.
syscall_argument :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    if index >= 6 {
        return 0
    }
    return registers.frame.x[cast[usize](index)]
}

set_syscall_result :: fn(registers: ptr[mut UserRegisters], result: ptr[arch_interface.SyscallResult]) {
    registers.frame.x[0] = result.tag
    registers.frame.x[1] = result.values[0]
    registers.frame.x[2] = result.values[1]
}

instruction_pointer :: fn(registers: ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](registers.frame.elr)
}

// ELR_EL1 is just past the svc, which is 4 bytes, as every instruction is.
restart_syscall :: fn(registers: ptr[mut UserRegisters]) {
    registers.frame.elr -= 4
}

// The PSTATE bits user mode may set: its condition flags, NZCV.
//SPEC: Arm ARM (DDI 0487) C5.2.18 (SPSR_EL1)
USER_CHANGEABLE_FLAGS : u64 : 0xf0000000

// x0 to x30, sp, pc, pstate (slop_os.THREAD_REGISTERS).
USER_REGISTER_COUNT :: 34
SP_INDEX : u32 : 31
PC_INDEX : u32 : 32
PSTATE_INDEX : u32 : 33

user_register_count :: fn() -> u32 {
    return USER_REGISTER_COUNT
}

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

/*
 * Back to user mode with registers, by eret, with SP_EL1 at the kernel stack's top, so the next entry from
 * user mode starts there.
 */
return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    aarch64.return_to_user(&registers.frame, cast[rawptr](current_cpu().kernel_stack_top))
}
