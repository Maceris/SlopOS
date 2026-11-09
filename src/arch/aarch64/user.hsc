package arch_aarch64

import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import slop_os from "std/os"

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
 * @param registers The thread's registers, as its last entry to the kernel saved them; only read.
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
 * @param registers The thread's registers, as its last entry to the kernel saved them; only read.
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
 * @param registers The thread's saved registers, which it returns to user mode with; only the indexed one changes, and
 *     only when this returns true.
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
 * SP_EL1 is set to the kernel stack's top, so the next entry from user mode starts there; every interrupt's priority is
 * let through again (unmask_for_return); and the thread's process's pointer authentication key is loaded, here, where
 * no frame below returns (set_user_pointer_key, decisions/0186).
 *
 * @param registers The thread's registers, restored whole.
 */
return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    key :: current_cpu().user_key
    if has_pointer_authentication() {
        // APIAKeyLo_EL1 and APIAKeyHi_EL1 (S3_0_C2_C1_0 and S3_0_C2_C1_1), then SCTLR_EL1.EnIA, here, where no frame below returns
        aarch64.write_system_register_encoded(3, 0, 2, 1, 0, key[0])
        aarch64.write_system_register_encoded(3, 0, 2, 1, 1, key[1])
        aarch64.write_system_register(.SCTLR_EL1, aarch64.read_system_register(.SCTLR_EL1) | SCTLR_ENABLE_IA)
        aarch64.isb()
    }
    cpu :: current_cpu()
    // The kernel's Guarded Control Stack from its top, as SP_EL1 is, and on (decisions/0186, Hd): GCSPR_EL1 (S3_0_C2_C5_1), GCSCR_EL1 (S3_0_C2_C5_0)
    if cpu.kernel_shadow_top != 0 {
        aarch64.write_system_register_encoded(3, 0, 2, 5, 1, cpu.kernel_shadow_top)
        aarch64.write_system_register_encoded(3, 0, 2, 5, 0, GCSCR_ON)
        aarch64.isb()
    }
    unmask_for_return()
    aarch64.return_to_user(&registers.frame, cast[rawptr](cpu.kernel_stack_top))
}

// The self-hosted debug registers (decisions/0183, 12b), by their encodings, which take n in CRm
//SPEC: Arm ARM (DDI 0487) D2 (AArch64 self-hosted debug), D19.3 (debug registers)
/** MDSCR_EL1.SS (bit 0): software step on. */
MDSCR_SS : u64 : 1 << 0
/** MDSCR_EL1.MDE (bit 15): breakpoints and watchpoints on. */
MDSCR_MDE : u64 : 1 << 15
/** SPSR_EL1.SS (bit 21): step the one instruction an eret returns to. */
SPSR_SS : u64 : 1 << 21
/** A DBGBCR's or DBGWCR's enable (bit 0), and its privilege, EL0 only (bits 1 and 2: 0b10). */
DEBUG_ENABLE_EL0 : u64 : 1 | (2 << 1)
/** A DBGBCR's byte address select (bits 5 to 8), every byte of the instruction. */
BREAKPOINT_BYTES : u64 : 0xf << 5

/** Unlock the OS lock and turn breakpoints and watchpoints on, all of them still disabled, at a CPU's start. */
init_debug :: fn() {
    // OSLAR_EL1: 0 unlocks
    aarch64.write_system_register_encoded(2, 0, 1, 0, 4, 0)
    aarch64.write_system_register_encoded(2, 0, 0, 2, 2, MDSCR_MDE)
}

/**
 * A thread's debugging state (arch_interface.DebugRegisters): its breakpoints' and watchpoints' value and control
 * registers, slot n the breakpoint or watchpoint register n, and whether it steps.
 */
DebugRegisters :: struct {
    /** DBGBVR0 to 3: the breakpoints' addresses. */
    breakpoints : u64[4],
    /** DBGBCR0 to 3; 0 for one that's off. */
    breakpoint_controls : u64[4],
    /** DBGWVR0 to 3: the watchpoints' doublewords. */
    watchpoints : u64[4],
    /** DBGWCR0 to 3; 0 for one that's off. */
    watchpoint_controls : u64[4],
    /** Whether it steps. */
    step : bool,
    /** Whether any of it is set, so debug_on has something to load. */
    used : bool,
}

/**
 * Set a thread's debugging state (arch_interface.set_debug): an Execute slot n is breakpoint n, a data slot n
 * watchpoint n, for EL0 alone, a watchpoint's bytes selected within its doubleword.
 *
 * @param debug The thread's state, replaced whole.
 * @param registers Not changed here: debug_on marks them to step as it returns.
 * @param step Whether it single-steps.
 * @param slots At most four.
 * @return False, changing nothing, for a slot past the CPU's breakpoints or watchpoints, an address outside user
 *     memory, or a data slot whose size isn't 1, 2, 4 or 8 or whose address isn't a multiple of it.
 */
set_debug :: fn(debug: ptr[mut DebugRegisters], registers: ptr[mut UserRegisters], step: bool, slots: slop_os.DebugSlot[]) -> bool {
    made := DebugRegisters.{step = step, used = step}
    features :: aarch64.read_system_register_encoded(3, 0, 0, 5, 0)
    breakpoint_count :: ((features >> 12) & 0xf) + 1
    watchpoint_count :: ((features >> 20) & 0xf) + 1
    low, high :: user_address_range()
    for slot, i in slots {
        if slot.kind == .Off {
            continue
        }
        if i >= made.breakpoints.count || slot.address < cast[u64](low) || slot.address >= cast[u64](high) {
            return false
        }
        if slot.kind == .Execute {
            if cast[u64](i) >= breakpoint_count || slot.address & 3 != 0 {
                return false
            }
            made.breakpoints[i] = slot.address
            made.breakpoint_controls[i] = DEBUG_ENABLE_EL0 | BREAKPOINT_BYTES
        }
        else {
            size :: cast[u64](slot.size)
            if cast[u64](i) >= watchpoint_count || (size != 1 && size != 2 && size != 4 && size != 8) || slot.address % size != 0 {
                return false
            }
            accesses : u64 = if slot.kind == .Write { 2 } else { 3 }
            bytes :: ((cast[u64](1) << size) - 1) << (slot.address & 7)
            made.watchpoints[i] = slot.address & ~cast[u64](7)
            made.watchpoint_controls[i] = DEBUG_ENABLE_EL0 | (accesses << 3) | (bytes << 5)
        }
        made.used = true
    }
    debug^ = made
    return true
}

/**
 * Load a thread's breakpoints, watchpoints and stepping as it returns to user mode (arch_interface.debug_on).
 *
 * @param debug The thread's state; with nothing set, nothing's loaded.
 * @param registers Its registers, whose SPSR.SS is set so the eret steps one instruction, when it steps.
 */
debug_on :: fn(debug: ptr[DebugRegisters], registers: ptr[mut UserRegisters]) {
    if !debug.used {
        return void
    }
    for i in cast[usize](0)..<4 {
        if i < debug.breakpoints.count {
            write_breakpoint(i, debug.breakpoints[i], debug.breakpoint_controls[i])
            write_watchpoint(i, debug.watchpoints[i], debug.watchpoint_controls[i])
        }
    }
    if debug.step {
        aarch64.write_system_register_encoded(2, 0, 0, 2, 2, MDSCR_MDE | MDSCR_SS)
        registers.frame.spsr |= SPSR_SS
    }
    aarch64.isb()
    current_cpu().debug_loaded = true
}

/** Turn a thread's breakpoints, watchpoints and stepping off at an entry from user mode (arch_interface.debug_off). */
debug_off :: fn() {
    cpu :: current_cpu()
    if !cpu.debug_loaded {
        return void
    }
    for i in cast[usize](0)..<4 {
        write_breakpoint(i, 0, 0)
        write_watchpoint(i, 0, 0)
    }
    aarch64.write_system_register_encoded(2, 0, 0, 2, 2, MDSCR_MDE)
    aarch64.isb()
    cpu.debug_loaded = false
}

/**
 * Write breakpoint n's value and control registers, DBGBVRn_EL1 and DBGBCRn_EL1.
 *
 * @param n Which, 0 to 3.
 * @param value Its address.
 * @param control Its control; 0 turns it off.
 */
write_breakpoint :: fn(n: usize, value: u64, control: u64) {
    match n {
        case 0 => {
            aarch64.write_system_register_encoded(2, 0, 0, 0, 4, value)
            aarch64.write_system_register_encoded(2, 0, 0, 0, 5, control)
        }
        case 1 => {
            aarch64.write_system_register_encoded(2, 0, 0, 1, 4, value)
            aarch64.write_system_register_encoded(2, 0, 0, 1, 5, control)
        }
        case 2 => {
            aarch64.write_system_register_encoded(2, 0, 0, 2, 4, value)
            aarch64.write_system_register_encoded(2, 0, 0, 2, 5, control)
        }
        case _ => {
            aarch64.write_system_register_encoded(2, 0, 0, 3, 4, value)
            aarch64.write_system_register_encoded(2, 0, 0, 3, 5, control)
        }
    }
}

/**
 * Write watchpoint n's value and control registers, DBGWVRn_EL1 and DBGWCRn_EL1.
 *
 * @param n Which, 0 to 3.
 * @param value Its doubleword's address.
 * @param control Its control; 0 turns it off.
 */
write_watchpoint :: fn(n: usize, value: u64, control: u64) {
    match n {
        case 0 => {
            aarch64.write_system_register_encoded(2, 0, 0, 0, 6, value)
            aarch64.write_system_register_encoded(2, 0, 0, 0, 7, control)
        }
        case 1 => {
            aarch64.write_system_register_encoded(2, 0, 0, 1, 6, value)
            aarch64.write_system_register_encoded(2, 0, 0, 1, 7, control)
        }
        case 2 => {
            aarch64.write_system_register_encoded(2, 0, 0, 2, 6, value)
            aarch64.write_system_register_encoded(2, 0, 0, 2, 7, control)
        }
        case _ => {
            aarch64.write_system_register_encoded(2, 0, 0, 3, 6, value)
            aarch64.write_system_register_encoded(2, 0, 0, 3, 7, control)
        }
    }
}

/** CNTKCTL_EL1's EL0PCTEN (bit 0) and EL0VCTEN (bit 1): EL0 reads CNTPCT_EL0 and CNTVCT_EL0. */
CNTKCTL_EL0_COUNTERS : u64 : 3
/** MRS Xt, CNTVCT_EL0, Xt in the low five bits. */
MRS_CNTVCT : u32 : 0xd53be040
/** MRS Xt, CNTPCT_EL0, Xt in the low five bits. */
MRS_CNTPCT : u32 : 0xd53be020

/**
 * Trap EL0's counter reads, or let them run (arch_interface.set_counter_trap), by CNTKCTL_EL1.
 *
 * @param trapped Whether they trap.
 */
set_counter_trap :: fn(trapped: bool) {
    cpu :: current_cpu()
    if cpu.counter_trapped == trapped {
        return void
    }
    aarch64.write_system_register(.CNTKCTL_EL1, if trapped { cast[u64](0) } else { CNTKCTL_EL0_COUNTERS })
    aarch64.isb()
    cpu.counter_trapped = trapped
}

/**
 * Run a trapped MRS of CNTVCT_EL0 or CNTPCT_EL0 for a thread (arch_interface.emulate_counter_read): its register the
 * counter, unless it's xzr, the thread past it.
 *
 * @param registers The thread's saved registers, at the instruction.
 * @param instruction The instruction.
 * @return The counter; null for any other instruction.
 */
emulate_counter_read :: fn(registers: ptr[mut UserRegisters], instruction: u32) -> u64? {
    encoding :: instruction & ~cast[u32](0x1f)
    value : u64 = 0
    if encoding == MRS_CNTVCT {
        value = aarch64.read_system_register(.CNTVCT_EL0)
    }
    else if encoding == MRS_CNTPCT {
        value = aarch64.read_system_register(.CNTPCT_EL0)
    }
    else {
        return null
    }
    target :: cast[usize](instruction & 0x1f)
    if target < registers.frame.x.count {
        registers.frame.x[target] = value
    }
    registers.frame.elr += 4
    return value
}
