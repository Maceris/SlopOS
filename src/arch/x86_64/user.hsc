package arch_x86_64

import x86_64 from "base/intrinsics"
import runtime from "base"
import arch_interface from "../../arch_interface"
import slop_os from "std/os"

/*
 * User-mode registers (arch_interface, User State): a thread's RegisterFrame, as entries save it and
 * return_to_user restores it. System calls follow the system ABI (knowledge/design/system-abi.md): the
 * number in rax, arguments in rdi, rsi, rdx, r10, r8 and r9 (SYSCALL takes rcx and r11), and results in
 * rax, rdx and r8.
 */

/** A new thread's RFLAGS: interrupts enabled (bit 9), and bit 1, which is always set. */
USER_RFLAGS : u64 : 0x202

/**
 * Set a new thread's registers: every one zero but its instruction and stack pointers, its argument in rdi, user-mode
 * segments, and interrupts enabled, so no kernel value leaks (0026).
 *
 * @param registers The thread's registers, all of them overwritten.
 * @param start Where the thread starts, in user addresses, and the argument it gets; not checked here.
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

/**
 * Read a system call's number.
 *
 * @param registers The registers SYSCALL's entry saved.
 * @return rax, the number, as user mode put it there; not checked.
 */
syscall_number :: fn(registers: ptr[UserRegisters]) -> u64 {
    return registers.frame.rax
}

/**
 * Read one of a system call's arguments.
 *
 * @param registers The registers SYSCALL's entry saved.
 * @param index Which argument, 0 to 5: rdi, rsi, rdx, r10, r8 and r9, r10 in rcx's place since SYSCALL takes rcx.
 * @return The argument register's value, or 0 for an index past 5.
 */
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

/**
 * Put a system call's result in the registers returning to user mode loads.
 *
 * @param registers The registers SYSCALL's entry saved, whose rax, rdx and r8 are set.
 * @param result The result: its tag goes in rax, its values in rdx and r8.
 */
set_syscall_result :: fn(registers: ptr[mut UserRegisters], result: ptr[arch_interface.SyscallResult]) {
    registers.frame.rax = result.tag
    registers.frame.rdx = result.values[0]
    registers.frame.r8 = result.values[1]
}

/**
 * Read where user mode was, or will go on: after SYSCALL, the instruction after it; after a fault, the faulting one.
 *
 * @param registers The registers an entry saved.
 * @return rip, a user address.
 */
instruction_pointer :: fn(registers: ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](registers.frame.rip)
}

/**
 * The bytes of the SYSCALL instruction: two, 0f 05.
 *
 * SPEC: Intel SDM Vol. 2B, SYSCALL.
 */
SYSCALL_LENGTH : u64 : 2

/**
 * Move a thread back to its SYSCALL instruction, so returning to user mode makes the call again.
 *
 * It's how a call a debugger stopped at its entry runs once it's let go (knowledge/design/kernel.md §4).
 *
 * @param registers The registers SYSCALL's entry saved, whose rip is after the SYSCALL; its other registers have to
 *     still hold the call's number and arguments.
 */
restart_syscall :: fn(registers: ptr[mut UserRegisters]) {
    registers.frame.rip -= SYSCALL_LENGTH
}

/**
 * The RFLAGS bits a debugger may set for user mode: CF, PF, AF, ZF, SF, DF and OF.
 *
 * SPEC: Intel SDM Vol. 1 §3.4.3 (EFLAGS).
 */
USER_CHANGEABLE_FLAGS : u64 : 0xcd5

/**
 * How many registers a debugger sees: rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8 to r15, rip and rflags
 * (slop_os.THREAD_REGISTERS).
 */
USER_REGISTER_COUNT :: 18

/**
 * Count the registers a debugger sees, in the order slop_os.THREAD_REGISTERS gives for x86-64.
 *
 * @return USER_REGISTER_COUNT, 18.
 */
user_register_count :: fn() -> u32 {
    return USER_REGISTER_COUNT
}

/**
 * Read one of a thread's registers as a debugger sees them.
 *
 * @param registers The thread's saved registers.
 * @param index Which register, 0 to 17: rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8 to r15, rip, rflags.
 * @return The register's value, or 0 for an index past 17.
 */
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

/**
 * Set one of a thread's registers as a debugger sees them.
 *
 * @param registers The thread's saved registers, changed only when this returns true.
 * @param index Which register, 0 to 17, as get_user_register numbers them.
 * @param value The new value. For rsp (7) and rip (16) it has to be a user address, in user_address_range, since
 *     returning to a non-canonical or kernel address would fault in the kernel. For rflags (17), only the bits in
 *     USER_CHANGEABLE_FLAGS are taken; the others keep what they had.
 * @return True if it was set; false for an index past 17, or rsp or rip outside user addresses, and nothing changed.
 */
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

/**
 * Return to user mode with registers, on the calling CPU's active page table, by sysretq where it can, iretq otherwise.
 *
 * @param registers The registers to load, which have to be user mode's: user segments and user addresses.
 */
return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    x86_64.return_to_user(&registers.frame)
}

/** RFLAGS.TF (bit 8): trap after each instruction, single-stepping. */
TRAP_FLAG : u64 : 1 << 8
/** DR7 with every breakpoint off: bit 10 is always set. */
DR7_OFF : u64 : 0x400
/** DR6 with nothing reported: its reserved bits as they read, the status bits clear. */
DR6_CLEAR : u64 : 0xffff0ff0
/** DR6.BS (bit 14): the debug exception was a single step. */
DR6_SINGLE_STEP : u64 : 1 << 14

/**
 * A thread's debugging state (arch_interface.DebugRegisters): DR0 to DR3 and the DR7 bits that enable them.
 *
 * SPEC: Intel SDM Vol. 3B §18.2 (debug registers).
 */
DebugRegisters :: struct {
    /** DR0 to DR3, each slot's address. */
    addresses : u64[4],
    /** DR7's bits past DR7_OFF: each used slot's local enable (bit 2n), condition (bits 16 + 4n) and length. */
    control : u64,
}

/**
 * Set a thread's debugging state (arch_interface.set_debug): slot n is DRn, an Execute slot's condition 00 and length
 * 1, a Write slot's 01 and a ReadWrite slot's 11, with its size's length; stepping is RFLAGS.TF.
 *
 * @param debug The thread's state, replaced whole.
 * @param registers The thread's saved registers, whose TF is set or cleared.
 * @param step Whether it single-steps.
 * @param slots At most four.
 * @return False, changing nothing, for more than four slots, an address outside user memory, or a data slot whose
 *     size isn't 1, 2, 4 or 8 or whose address isn't a multiple of it.
 */
set_debug :: fn(debug: ptr[mut DebugRegisters], registers: ptr[mut UserRegisters], step: bool, slots: slop_os.DebugSlot[]) -> bool {
    made := DebugRegisters.{}
    low, high :: user_address_range()
    for slot, i in slots {
        if slot.kind == .Off {
            continue
        }
        if i >= made.addresses.count || slot.address < cast[u64](low) || slot.address >= cast[u64](high) {
            return false
        }
        condition : u64 = 0
        length : u64 = 0
        if slot.kind != .Execute {
            condition = if slot.kind == .Write { 1 } else { 3 }
            match slot.size {
                case 1 => length = 0
                case 2 => length = 1
                case 4 => length = 3
                case 8 => length = 2
                case _ => return false
            }
            if slot.address % cast[u64](slot.size) != 0 {
                return false
            }
        }
        made.addresses[i] = slot.address
        shift :: 16 + 4 * cast[u64](i)
        made.control |= (1 << (2 * cast[u64](i))) | (condition << shift) | (length << (shift + 2))
    }
    debug^ = made
    if step {
        registers.frame.rflags |= TRAP_FLAG
    }
    else {
        registers.frame.rflags &= ~TRAP_FLAG
    }
    return true
}

/**
 * Load a thread's breakpoints into DR0 to DR3 and DR7 as it returns to user mode (arch_interface.debug_on); stepping is
 * already in its RFLAGS.
 *
 * @param debug The thread's state; with no slot used, nothing's loaded.
 * @param registers Not used: TF is in the saved flags.
 */
debug_on :: fn(debug: ptr[DebugRegisters], registers: ptr[mut UserRegisters]) {
    if debug.control == 0 {
        return void
    }
    x86_64.write_dr0(debug.addresses[0])
    x86_64.write_dr1(debug.addresses[1])
    x86_64.write_dr2(debug.addresses[2])
    x86_64.write_dr3(debug.addresses[3])
    x86_64.write_dr7(DR7_OFF | debug.control)
    current_cpu().debug_loaded = true
}

/**
 * Turn the breakpoints off at an entry from user mode, if a thread's are loaded (arch_interface.debug_off): DR7's
 * enables apply in the kernel too.
 */
debug_off :: fn() {
    cpu :: current_cpu()
    if cpu.debug_loaded {
        x86_64.write_dr7(DR7_OFF)
        cpu.debug_loaded = false
    }
}

/**
 * Decode a debug exception (vector 1) by DR6, which is cleared: a breakpoint slot that matched, as Breakpoint for an
 * Execute slot and Watchpoint at its address for a data slot, or else SingleStep.
 *
 * SPEC: Intel SDM Vol. 3B §18.2.3 (debug status register), §18.2.4 (debug control register).
 *
 * @return The fault.
 */
decode_debug :: fn() -> arch_interface.Fault {
    status :: x86_64.read_dr6()
    x86_64.write_dr6(DR6_CLEAR)
    control :: x86_64.read_dr7()
    for i in cast[u64](0)..<4 {
        if status & (1 << i) == 0 {
            continue
        }
        if (control >> (16 + 4 * i)) & 3 == 0 {
            return .Breakpoint
        }
        address :: match i {
            case 0 => x86_64.read_dr0()
            case 1 => x86_64.read_dr1()
            case 2 => x86_64.read_dr2()
            case _ => x86_64.read_dr3()
        }
        return .Watchpoint(address)
    }
    return .SingleStep
}

/** CR4.TSD (bit 2): RDTSC and RDTSCP outside ring 0 raise #GP. */
CR4_TIME_STAMP_DISABLE : u64 : 1 << 2
/** IA32_TSC_AUX, which RDTSCP puts in ecx. */
TSC_AUX_MSR : u32 : 0xc0000103

/**
 * Trap user mode's RDTSC and RDTSCP, or let them run (arch_interface.set_counter_trap), by CR4.TSD.
 *
 * @param trapped Whether they trap.
 */
set_counter_trap :: fn(trapped: bool) {
    cpu :: current_cpu()
    if cpu.counter_trapped == trapped {
        return void
    }
    cr4 :: x86_64.read_cr4()
    x86_64.write_cr4(if trapped { cr4 | CR4_TIME_STAMP_DISABLE } else { cr4 & ~CR4_TIME_STAMP_DISABLE })
    cpu.counter_trapped = trapped
}

/**
 * Run a trapped RDTSC (0f 31) or RDTSCP (0f 01 f9) for a thread (arch_interface.emulate_counter_read): edx:eax the
 * counter, and for RDTSCP ecx IA32_TSC_AUX, the thread past it.
 *
 * @param registers The thread's saved registers, at the instruction.
 * @param instruction Its first bytes, little-endian.
 * @return The counter; null for any other instruction.
 */
emulate_counter_read :: fn(registers: ptr[mut UserRegisters], instruction: u32) -> u64? {
    length : u64 = 0
    if instruction & 0xffff == 0x310f {
        length = 2
    }
    else if instruction & 0xffffff == 0xf9010f {
        length = 3
        registers.frame.rcx = x86_64.rdmsr(TSC_AUX_MSR) & 0xffffffff
    }
    else {
        return null
    }
    value :: x86_64.rdtsc()
    registers.frame.rax = value & 0xffffffff
    registers.frame.rdx = value >> 32
    registers.frame.rip += length
    return value
}
