package arch_riscv64

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"

/*
 * User mode (decisions/0199, R5): threads run in U-mode, enter the kernel through the trap entry, by ecall for a system
 * call, and leave it through riscv64.return_to_user, which loads every register and srets, sscratch set to the hart's
 * TrapScratch for the next trap. The system ABI's registers (../../../knowledge/design/system-abi.md): the number in
 * a7, arguments in a0 to a5, results in a0, a1 and a2.
 */

/** sstatus.FS with floating point's state Initial: user mode may use it, the kernel saving it at every switch. */
SSTATUS_FS_INITIAL : u64 : 1 << 13
/** sstatus.VS with the vector state Initial, as SSTATUS_FS_INITIAL is. */
SSTATUS_VS_INITIAL : u64 : 1 << 9
/** How many bytes an ecall takes, which a system call's sepc is moved past and restart_syscall moves back over. */
ECALL_BYTES : u64 : 4
/** Where the system call's number is among the x registers: a7. */
SYSCALL_NUMBER_REGISTER :: 17
/** Where a system call's first argument is: a0, the others following up to a5. */
FIRST_ARGUMENT_REGISTER :: 10
/** How many registers a debugger sees: x0 to x31 by number, then pc. */
USER_REGISTERS : u32 : 33

/**
 * Set up a new thread's registers (arch_interface.init_user_registers): every one zero but sepc (the entry), sp and a0
 * (the argument); sstatus to return to user mode with interrupts on.
 *
 * @param registers The thread's registers, all overwritten.
 * @param start Where it starts, and its argument.
 */
init_user_registers :: fn(registers : ptr[mut UserRegisters], start : ptr[arch_interface.UserStart]) {
    registers^ = UserRegisters.{}
    registers.frame.sepc = cast[u64](start.instruction_pointer)
    registers.frame.x[2] = cast[u64](start.stack_pointer)
    registers.frame.x[FIRST_ARGUMENT_REGISTER] = start.argument
    registers.frame.sstatus = user_status(0)
}

/**
 * Make the sstatus a thread returns to user mode with: the hart's own, but for SPP clear (user mode), SPIE set (its
 * interrupts on), SIE and SUM clear, and floating point and vectors on.
 *
 * @param saved The thread's sstatus as saved, unused but for its record; what user mode may change of sstatus is none
 *     of
 *     these bits.
 * @return The value for the frame's sstatus.
 */
user_status :: fn(saved : u64) -> u64 {
    status :: riscv64.csrr(.SSTATUS)
    kept :: status
        & ~(riscv64.SSTATUS_SPP | riscv64.SSTATUS_SIE | riscv64.SSTATUS_SUM | riscv64.SSTATUS_FS | riscv64.SSTATUS_VS)
    return kept | riscv64.SSTATUS_SPIE | SSTATUS_FS_INITIAL | SSTATUS_VS_INITIAL
}

/**
 * Read which system call a thread made (arch_interface.syscall_number).
 *
 * @param registers The thread's registers, saved at the system call's entry.
 * @return a7.
 */
syscall_number :: fn(registers : ptr[UserRegisters]) -> u64 {
    return registers.frame.x[SYSCALL_NUMBER_REGISTER]
}

/**
 * Read one of a system call's arguments (arch_interface.syscall_argument).
 *
 * @param registers The thread's registers, saved at the system call's entry.
 * @param index Which argument, from 0: a0 to a5.
 * @return The argument's register; 0 past the sixth.
 */
syscall_argument :: fn(registers : ptr[UserRegisters], index : u32) -> u64 {
    if index >= 6 {
        return 0
    }
    return registers.frame.x[FIRST_ARGUMENT_REGISTER + cast[usize](index)]
}

/**
 * Set a system call's result (arch_interface.set_syscall_result): a0 the tag, a1 and a2 the values.
 *
 * @param registers The calling thread's registers; only a0, a1 and a2 change.
 * @param result The result.
 */
set_syscall_result :: fn(registers : ptr[mut UserRegisters], result : ptr[arch_interface.SyscallResult]) {
    registers.frame.x[10] = result.tag
    registers.frame.x[11] = result.values[0]
    registers.frame.x[12] = result.values[1]
}

/**
 * Read where a thread is in user mode (arch_interface.instruction_pointer).
 *
 * @param registers The thread's registers, as its last entry saved them.
 * @return sepc: past the ecall for a system call, which the entry moved it past, else the instruction that trapped.
 */
instruction_pointer :: fn(registers : ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    return cast[arch_interface.VirtualAddress](registers.frame.sepc)
}

/**
 * Go back to the ecall (arch_interface.restart_syscall), which the entry moved sepc past.
 *
 * @param registers The registers of a thread that entered by a system call.
 */
restart_syscall :: fn(registers : ptr[mut UserRegisters]) {
    registers.frame.sepc -= ECALL_BYTES
}

/**
 * Count the registers a debugger sees (arch_interface.user_register_count).
 *
 * @return USER_REGISTERS, 33: x0 to x31, then pc.
 */
user_register_count :: fn() -> u32 {
    return USER_REGISTERS
}

/**
 * Read a register as a debugger sees it (arch_interface.get_user_register).
 *
 * @param registers The thread's registers, as its last entry saved them.
 * @param index x0 to x31 by number, then 32 for pc.
 * @return Its value: x0 is 0; 0 past pc.
 */
get_user_register :: fn(registers : ptr[UserRegisters], index : u32) -> u64 {
    if index == 0 || index >= USER_REGISTERS {
        return 0
    }
    if index == 32 {
        return registers.frame.sepc
    }
    return registers.frame.x[cast[usize](index) % 32]
}

/**
 * Set a register as a debugger sets it (arch_interface.set_user_register).
 *
 * @param registers The thread's saved registers.
 * @param index x0 to x31 by number, then 32 for pc; writing x0 changes nothing.
 * @param value The value; the stack pointer (x2) and pc have to be user addresses.
 * @return False, nothing changed, for an index past pc or a stack pointer or pc outside user addresses; true otherwise.
 */
set_user_register :: fn(registers : ptr[mut UserRegisters], index : u32, value : u64) -> bool {
    if index >= USER_REGISTERS {
        return false
    }
    if (index == 2 || index == 32) && (value < USER_LOW || value >= USER_HIGH) {
        return false
    }
    if index == 32 {
        registers.frame.sepc = value
    }
    else if index != 0 {
        registers.frame.x[cast[usize](index) % 32] = value
    }
    return true
}

/**
 * Set a thread's debugging state (arch_interface.set_debug): only none yet. RISC-V's triggers are the SBI's debug
 * triggers extension's to give, which isn't used, and it has no single step for supervisor mode to ask for.
 *
 * @param debug The thread's state, cleared when this succeeds.
 * @param registers Unused.
 * @param step Whether it should step; it can't.
 * @param slots The breakpoints and watchpoints; every one has to be Off.
 * @return True, the state cleared, if nothing is asked; false, nothing changed, for a step or any slot that isn't Off.
 */
set_debug :: fn(
    debug : ptr[mut DebugRegisters],
    registers : ptr[mut UserRegisters],
    step : bool,
    slots : slop_os.DebugSlot[]
) -> bool {
    if step {
        return false
    }
    for slot in slots {
        if slot.kind != .Off {
            return false
        }
    }
    debug^ = DebugRegisters.{}
    return true
}

/**
 * Load a thread's debugging state (arch_interface.debug_on): nothing, as set_debug only ever sets none.
 *
 * @param debug Unused.
 * @param registers Unused.
 */
debug_on :: fn(debug : ptr[DebugRegisters], registers : ptr[mut UserRegisters]) {}

/** Turn the hart's breakpoints and watchpoints off (arch_interface.debug_off): there are none loaded. */
debug_off :: fn() {}

/** scounteren's TM (bit 1): user mode reads the time CSR. */
COUNTEREN_TIME : u64 : 1 << 1

/**
 * Trap user mode's reads of the time CSR, or let them run (arch_interface.set_counter_trap): scounteren's TM.
 *
 * @param trapped Whether they trap, as illegal instructions, which emulate_counter_read then runs.
 */
set_counter_trap :: fn(trapped : bool) {
    riscv64.csrw(.SCOUNTEREN, if trapped { cast[u64](0) } else { COUNTEREN_TIME })
}

/** rdtime rd, csrrs rd, time, x0, with rd's bits clear. */
RDTIME : u32 : 0xc0102073
/** The bits of an instruction rdtime fixes: all but rd's (bits 7 to 11). */
RDTIME_MASK : u32 : 0xfffff07f

/**
 * Run a trapped read of the time CSR (arch_interface.emulate_counter_read): rdtime, whose value goes in its rd, the
 * thread moved past it.
 *
 * @param registers The thread's saved registers, at the instruction.
 * @param instruction The instruction's first four bytes; a compressed instruction isn't rdtime.
 * @return The time read; null if the instruction isn't rdtime, the registers left as they were.
 */
emulate_counter_read :: fn(registers : ptr[mut UserRegisters], instruction : u32) -> u64? {
    if instruction & RDTIME_MASK != RDTIME {
        return null
    }
    value :: riscv64.csrr(.TIME)
    target :: cast[usize]((instruction >> 7) & 31)
    if target != 0 {
        registers.frame.x[target % 32] = value
    }
    registers.frame.sepc += 4
    return value
}

/**
 * Return to user mode (arch_interface.return_to_user): sstatus made a user one (user_status), sscratch the hart's
 * TrapScratch, with the kernel stack's top for the next trap, then every register loaded and sret.
 *
 * @param registers The thread's registers.
 */
return_to_user :: fn(registers : ptr[UserRegisters]) #never_returns {
    cpu :: current_cpu()
    frame := registers.frame
    frame.sstatus = user_status(frame.sstatus)
    cpu.scratch.kernel_stack = cpu.kernel_stack_top
    riscv64.return_to_user(&frame, &cpu.scratch)
}

/** The bytes a VectorState's floating-point part takes, f0 to f31 and fcsr, rounded to 16. */
FLOATING_BYTES : usize : 272

/**
 * Give the bytes a thread's vector state takes (arch_interface.vector_state_size): its floating-point registers, then
 * its vector registers and their four CSRs.
 *
 * @param config Unused: RISC-V has one size of vector state.
 * @return FLOATING_BYTES, then 32 vlenb-byte registers and 32 bytes.
 */
vector_state_size :: fn(config : arch_interface.VectorConfig) -> usize {
    return FLOATING_BYTES + 32 * cast[usize](current_system().vlenb) + 32
}

/**
 * Give the alignment a VectorState needs (arch_interface.vector_state_alignment).
 *
 * @return 16.
 */
vector_state_alignment :: fn() -> usize {
    return 16
}

/** vtype's vill (bit 63): no vector configuration, as at reset. */
VTYPE_ILL : u64 : 1 << 63

/**
 * Set up a thread's vector state as it is at reset (arch_interface.init_vector_state): every register 0, fcsr 0, vl 0
 * and vtype with vill set.
 *
 * @param state The state, vector_state_size bytes.
 * @param config Unused.
 */
init_vector_state :: fn(state : ptr[mut VectorState], config : arch_interface.VectorConfig) {
    size :: vector_state_size(config)
    intrinsics.mem_zero(cast[mut rawptr](state), size)
    vtype :: cast[u64](cast[rawptr](state)) + cast[u64](size) - 32 + 8
    cast[ptr[mut u64]](cast[rawptr](vtype))^ = VTYPE_ILL
}

/**
 * Save the hart's floating-point and vector registers into a thread's state (arch_interface.save_vector_state), with
 * sstatus.FS and VS on while it does, and off again after.
 *
 * @param state The state.
 */
save_vector_state :: fn(state : ptr[mut VectorState]) {
    _ = riscv64.csrrs(.SSTATUS, SSTATUS_FS_INITIAL | SSTATUS_VS_INITIAL)
    riscv64.save_floating(cast[rawptr](state))
    riscv64.save_vector(cast[rawptr](cast[u64](cast[rawptr](state)) + cast[u64](FLOATING_BYTES)))
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_FS | riscv64.SSTATUS_VS)
}

/**
 * Load a thread's state into the hart's floating-point and vector registers (arch_interface.restore_vector_state), with
 * sstatus.FS and VS on while it does, and off again after; return_to_user turns them on for user mode.
 *
 * @param state The state, set up by init_vector_state or saved.
 */
restore_vector_state :: fn(state : ptr[VectorState]) {
    _ = riscv64.csrrs(.SSTATUS, SSTATUS_FS_INITIAL | SSTATUS_VS_INITIAL)
    riscv64.restore_floating(cast[rawptr](state))
    riscv64.restore_vector(cast[rawptr](cast[u64](cast[rawptr](state)) + cast[u64](FLOATING_BYTES)))
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_FS | riscv64.SSTATUS_VS)
}
