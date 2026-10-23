package arch_x86_64

import x86_64 from "base/intrinsics"
import runtime from "base"
import arch_interface from "../../arch_interface"

/*
 * User-mode registers (arch_interface, User State): a thread's RegisterFrame, as entries save it and
 * return_to_user restores it. System calls follow the system ABI (knowledge/design/system-abi.md): the
 * number in rax, arguments in rdi, rsi, rdx, r10, r8 and r9 (SYSCALL takes rcx and r11), and results in
 * rax, rdx and r8.
 */

// Interrupts enabled, and bit 1, which is always set.
USER_RFLAGS : u64 : 0x202

/*
 * A new thread's registers: every one zero but its instruction and stack pointers, its argument in rdi,
 * user-mode segments, and interrupts enabled.
 */
init_user_registers :: fn(registers: ptr[mut UserRegisters], start: ptr[arch_interface.UserStart]) {
    registers.frame = x86_64.RegisterFrame.{}
    registers.frame.rip = cast[u64](start.instruction_pointer)
    registers.frame.rsp = cast[u64](start.stack_pointer)
    registers.frame.rdi = start.argument
    registers.frame.cs = cast[u64](USER_CODE_SELECTOR)
    registers.frame.ss = cast[u64](USER_DATA_SELECTOR)
    registers.frame.rflags = USER_RFLAGS
}

syscall_number :: fn(registers: ptr[UserRegisters]) -> u64 {
    return registers.frame.rax
}

// One of the six argument registers, by index; 0 past the sixth.
syscall_argument :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    frame :: &registers.frame
    return match index {
        case 0 => frame.rdi
        case 1 => frame.rsi
        case 2 => frame.rdx
        case 3 => frame.r10
        case 4 => frame.r8
        case 5 => frame.r9
        case _ => cast[u64](0)
    }
}

set_syscall_result :: fn(registers: ptr[mut UserRegisters], result: ptr[arch_interface.SyscallResult]) {
    registers.frame.rax = result.tag
    registers.frame.rdx = result.values[0]
    registers.frame.r8 = result.values[1]
}

instruction_pointer :: fn(registers: ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](registers.frame.rip)
}

// SYSCALL is two bytes, 0f 05.
//SPEC: Intel SDM Vol. 2B, SYSCALL
SYSCALL_LENGTH : u64 : 2

restart_syscall :: fn(registers: ptr[mut UserRegisters]) {
    registers.frame.rip -= SYSCALL_LENGTH
}

// The flags user mode may set: CF, PF, AF, ZF, SF, DF and OF.
//SPEC: Intel SDM Vol. 1 §3.4.3 (EFLAGS)
USER_CHANGEABLE_FLAGS : u64 : 0xcd5

// rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8 to r15, rip, rflags (slop_os.THREAD_REGISTERS).
USER_REGISTER_COUNT :: 18

user_register_count :: fn() -> u32 {
    return USER_REGISTER_COUNT
}

get_user_register :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    frame :: &registers.frame
    return match index {
        case 0 => frame.rax
        case 1 => frame.rbx
        case 2 => frame.rcx
        case 3 => frame.rdx
        case 4 => frame.rsi
        case 5 => frame.rdi
        case 6 => frame.rbp
        case 7 => frame.rsp
        case 8 => frame.r8
        case 9 => frame.r9
        case 10 => frame.r10
        case 11 => frame.r11
        case 12 => frame.r12
        case 13 => frame.r13
        case 14 => frame.r14
        case 15 => frame.r15
        case 16 => frame.rip
        case 17 => frame.rflags
        case _ => 0
    }
}

set_user_register :: fn(registers: ptr[mut UserRegisters], index: u32, value: u64) -> bool {
    frame :: &registers.frame
    low, high :: user_address_range()
    // Returning to a non-canonical or kernel address would fault in the kernel, by sysretq
    if (index == 7 || index == 16) && (value < cast[u64](low) || value >= cast[u64](high)) {
        return false
    }
    match index {
        case 0 => frame.rax = value
        case 1 => frame.rbx = value
        case 2 => frame.rcx = value
        case 3 => frame.rdx = value
        case 4 => frame.rsi = value
        case 5 => frame.rdi = value
        case 6 => frame.rbp = value
        case 7 => frame.rsp = value
        case 8 => frame.r8 = value
        case 9 => frame.r9 = value
        case 10 => frame.r10 = value
        case 11 => frame.r11 = value
        case 12 => frame.r12 = value
        case 13 => frame.r13 = value
        case 14 => frame.r14 = value
        case 15 => frame.r15 = value
        case 16 => frame.rip = value
        case 17 => frame.rflags = (frame.rflags & ~USER_CHANGEABLE_FLAGS) | (value & USER_CHANGEABLE_FLAGS)
        case _ => return false
    }
    return true
}

// Back to user mode with registers, by sysretq where it can, iretq otherwise.
return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    x86_64.return_to_user(&registers.frame)
}
