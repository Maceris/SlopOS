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

// Back to user mode with registers, by sysretq where it can, iretq otherwise.
return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    x86_64.return_to_user(&registers.frame)
}
