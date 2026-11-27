package arch_riscv64

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import runtime from "base:runtime"
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
 * interrupts on), SIE and SUM clear, floating point and vectors on, and the thread's own SPELP.
 *
 * @param saved The thread's sstatus as saved; only its SPELP is kept, whether it was trapped between an indirect
 *     branch and the landing pad it must reach, which it's to reach still. User mode may change none of the rest.
 * @return The value for the frame's sstatus.
 */
user_status :: fn(saved : u64) -> u64 {
    status :: riscv64.csrr(.SSTATUS)
    kept :: status
        & ~(riscv64.SSTATUS_SPP
            | riscv64.SSTATUS_SIE
            | riscv64.SSTATUS_SUM
            | riscv64.SSTATUS_FS
            | riscv64.SSTATUS_VS
            | SSTATUS_SPELP)
    return kept | riscv64.SSTATUS_SPIE | SSTATUS_FS_INITIAL | SSTATUS_VS_INITIAL | (saved & SSTATUS_SPELP)
}

/** sstatus's SPELP (Zicfilp): a trap was taken expecting a landing pad, which sret expects again. */
SSTATUS_SPELP : u64 : 1 << 23

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
 * @param index x0 to x31 by number, then 32 for pc; writing x0 changes nothing. Writing pc also clears SPELP, whether
 *     it was trapped expecting a landing pad: the debugger has taken it somewhere else, which needn't be one.
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
        registers.frame.sstatus &= ~SSTATUS_SPELP
    }
    else if index != 0 {
        registers.frame.x[cast[usize](index) % 32] = value
    }
    return true
}

// ---- Hardware debugging, through the SBI's debug triggers extension (decisions/0201, 20g)

/** The SBI's debug triggers extension, "DBTR", and its functions (SBI 2.0 §19). */
SBI_DBTR : u64 : 0x44425452
DBTR_NUM_TRIGGERS : u64 : 0
DBTR_SET_SHMEM : u64 : 1
DBTR_INSTALL : u64 : 3
DBTR_UNINSTALL : u64 : 5
/** tdata1's type, in bits 63:60: an address match trigger (mcontrol6), an instruction count trigger (icount). */
TRIGGER_MATCH : u64 : 6 << 60
TRIGGER_COUNT : u64 : 3 << 60
/** mcontrol6's bits: U (3), EXECUTE (2), STORE (1), LOAD (0), and its size (18:16), 0 for any. */
MATCH_USER : u64 : 1 << 3
MATCH_EXECUTE : u64 : 1 << 2
MATCH_STORE : u64 : 1 << 1
MATCH_LOAD : u64 : 1
MATCH_SIZE_SHIFT : u64 : 16
/** icount's U (6), and a count of 1 (bits 23:10): it fires once one user instruction has run. */
COUNT_USER : u64 : 1 << 6
COUNT_ONE : u64 : 1 << 10

/**
 * Find how many triggers the SBI's debug triggers extension has, and note Sdtrig among the features if it has address
 * match triggers (find_shadow_stacks' sibling, from init_system).
 *
 * @param system The ArchSystem, whose match_triggers and count_triggers are set, 0 without the extension.
 */
find_debug_triggers :: fn(system : ptr[mut ArchSystem]) {
    counts :: debug_trigger_counts()
    system.match_triggers = counts[0]
    system.count_triggers = counts[1]
    if system.match_triggers > 0 {
        slop_os.add_feature(&system.features, .RiscvSdtrig)
    }
}

/**
 * Ask the SBI's debug triggers extension how many triggers of each kind a hart has.
 *
 * @return Its address match triggers' count, then its instruction count triggers'; both 0 without the extension.
 */
debug_trigger_counts :: fn() -> u64[2] {
    probed :: riscv64.sbi_call(SBI_BASE, SBI_PROBE_EXTENSION, SBI_DBTR)
    if probed.error != 0 || probed.value == 0 {
        return u64.[0, 0]
    }
    matching :: riscv64.sbi_call(SBI_DBTR, DBTR_NUM_TRIGGERS, TRIGGER_MATCH)
    counting :: riscv64.sbi_call(SBI_DBTR, DBTR_NUM_TRIGGERS, TRIGGER_COUNT)
    return u64.[
        if matching.error == 0 { matching.value } else { cast[u64](0) },
        if counting.error == 0 { counting.value } else { cast[u64](0) },
    ]
}

/**
 * Set a thread's debugging state (arch_interface.set_debug): each slot an address match trigger for user mode, an
 * Execute slot's on the instruction, a data slot's on its bytes' loads and stores or stores; a step an instruction
 * count trigger of 1, or where the SBI has none, an execute trigger on each place the instruction at the thread's pc
 * can go next (step_targets): its successor, a jump's target, or a branch's two. They're the SBI's debug triggers
 * extension's to give, installed as the thread returns to user mode (debug_on).
 *
 * @param debug The thread's state, replaced whole when this succeeds.
 * @param registers The thread's saved registers: its pc, and a register jump's register, for a step.
 * @param step Whether it stops after each instruction it runs in user mode.
 * @param slots The breakpoints and watchpoints, slop_os.DEBUG_SLOTS at most.
 * @param instruction The instruction at its pc, for a step without an instruction count trigger.
 * @return True once it's set; false, nothing changed, for a slot whose address isn't a user one, a data slot whose
 *     size isn't 1, 2, 4 or 8 or whose address isn't a multiple of it, more slots and a step than the SBI has triggers
 *     for, or a step without an instruction count trigger whose instruction couldn't be read.
 */
set_debug :: fn(
    debug : ptr[mut DebugRegisters],
    registers : ptr[mut UserRegisters],
    step : bool,
    slots : slop_os.DebugSlot[],
    instruction : u32
) -> bool {
    system :: current_system()
    made := DebugRegisters.{step = step}
    used := cast[u64](0)
    for slot, i in slots {
        if slot.kind == .Off {
            continue
        }
        if i >= made.triggers.count || slot.address < USER_LOW || slot.address >= USER_HIGH {
            return false
        }
        if slot.kind == .Execute {
            made.triggers[i] = TRIGGER_MATCH | MATCH_USER | MATCH_EXECUTE
        }
        else {
            // mcontrol6's size: 1 for a byte, 2 for 2, 3 for 4, 5 for 8
            encoded :: match slot.size {
                case 1 => cast[u64](1)
                case 2 => cast[u64](2)
                case 4 => cast[u64](3)
                case 8 => cast[u64](5)
                case _ => return false
            }
            if slot.address % cast[u64](slot.size) != 0 {
                return false
            }
            access :: if slot.kind == .Write { MATCH_STORE } else { MATCH_STORE | MATCH_LOAD }
            made.triggers[i] = TRIGGER_MATCH | MATCH_USER | access | (encoded << MATCH_SIZE_SHIFT)
        }
        made.addresses[i] = slot.address
        used += 1
    }
    // A step without an instruction count trigger takes an address match trigger for each place it can go
    if step && system.count_triggers == 0 {
        if instruction == 0 {
            return false
        }
        made.step_targets = step_targets(registers, instruction)
        used += if made.step_targets[1] != 0 { cast[u64](2) } else { cast[u64](1) }
    }
    if used > system.match_triggers {
        return false
    }
    debug^ = made
    return true
}

/**
 * Find where an instruction can go next, for a step's execute triggers: a conditional branch's target and its
 * successor; a jump's target, a register's from the registers; anything else's successor. RV64GC's: JAL, JALR and the
 * branches, and C.J, C.JR, C.JALR, C.BEQZ and C.BNEZ.
 *
 * @param registers The thread's registers: its pc, and a register jump's register.
 * @param instruction The instruction at its pc: four bytes, or two for a compressed one, little-endian.
 * @return Where it goes, and where else it can for a branch; 0 for none, and the second 0 too when both are one.
 */
step_targets :: fn(registers : ptr[UserRegisters], instruction : u32) -> u64[2] {
    pc :: registers.frame.sepc
    if instruction & 3 != 3 {
        // Compressed: its quadrant (bits 1:0) and funct3 (15:13)
        quadrant :: instruction & 3
        funct3 :: (instruction >> 13) & 7
        if quadrant == 1 && funct3 == 5 {
            return u64.[pc + cj_offset(instruction), 0]
        }
        if quadrant == 1 && (funct3 == 6 || funct3 == 7) {
            return both(pc + 2, pc + cb_offset(instruction))
        }
        rs1 :: (instruction >> 7) & 0x1f
        rs2 :: (instruction >> 2) & 0x1f
        if quadrant == 2 && funct3 == 4 && rs1 != 0 && rs2 == 0 {
            return u64.[register_of(registers, rs1) & ~cast[u64](1), 0]
        }
        return u64.[pc + 2, 0]
    }
    opcode :: instruction & 0x7f
    if opcode == 0x6f {
        // JAL: imm[20|10:1|11|19:12] in bits 31:12
        offset :: (((instruction >> 31) & 1) << 20)
            | (((instruction >> 21) & 0x3ff) << 1)
            | (((instruction >> 20) & 1) << 11)
            | (((instruction >> 12) & 0xff) << 12)
        return u64.[pc + extended(offset, 21), 0]
    }
    if opcode == 0x67 {
        // JALR: rs1 plus imm[11:0], its low bit cleared
        rs1 :: (instruction >> 15) & 0x1f
        return u64.[(register_of(registers, rs1) + extended(instruction >> 20, 12)) & ~cast[u64](1), 0]
    }
    if opcode == 0x63 {
        // A branch: imm[12|10:5] in bits 31:25, imm[4:1|11] in 11:7
        offset :: (((instruction >> 31) & 1) << 12)
            | (((instruction >> 25) & 0x3f) << 5)
            | (((instruction >> 8) & 0xf) << 1)
            | (((instruction >> 7) & 1) << 11)
        return both(pc + 4, pc + extended(offset, 13))
    }
    return u64.[pc + 4, 0]
}

/**
 * Two places a step can go, as step_targets gives them.
 *
 * @param first One.
 * @param second The other.
 * @return Both, or the first alone when they're one.
 */
both :: fn(first : u64, second : u64) -> u64[2] {
    return if first == second { u64.[first, 0] } else { u64.[first, second] }
}

/**
 * C.J's offset: offset[11|4|9:8|10|6|7|3:1|5] in bits 12:2.
 *
 * @param instruction The instruction.
 * @return The offset, sign-extended.
 */
cj_offset :: fn(instruction : u32) -> u64 {
    offset :: (((instruction >> 12) & 1) << 11)
        | (((instruction >> 11) & 1) << 4)
        | (((instruction >> 9) & 3) << 8)
        | (((instruction >> 8) & 1) << 10)
        | (((instruction >> 7) & 1) << 6)
        | (((instruction >> 6) & 1) << 7)
        | (((instruction >> 3) & 7) << 1)
        | (((instruction >> 2) & 1) << 5)
    return extended(offset, 12)
}

/**
 * C.BEQZ's and C.BNEZ's offset: offset[8|4:3] in bits 12:10, offset[7:6|2:1|5] in bits 6:2.
 *
 * @param instruction The instruction.
 * @return The offset, sign-extended.
 */
cb_offset :: fn(instruction : u32) -> u64 {
    offset :: (((instruction >> 12) & 1) << 8)
        | (((instruction >> 10) & 3) << 3)
        | (((instruction >> 5) & 3) << 6)
        | (((instruction >> 3) & 3) << 1)
        | (((instruction >> 2) & 1) << 5)
    return extended(offset, 9)
}

/**
 * Sign-extend a field.
 *
 * @param value The field, in its low bits.
 * @param bits How many bits it has, its top one its sign.
 * @return It as a 64-bit two's complement value.
 */
extended :: fn(value : u32, bits : u32) -> u64 {
    shift :: cast[u64](64 - bits)
    return bit_cast[u64](bit_cast[i64](cast[u64](value) << shift) >> shift)
}

/**
 * Read a thread's integer register.
 *
 * @param registers The thread's registers.
 * @param number Which, 0 to 31; x0 is 0.
 * @return Its value.
 */
register_of :: fn(registers : ptr[UserRegisters], number : u32) -> u64 {
    return if number == 0 { cast[u64](0) } else { registers.frame.x[cast[usize](number) % 32] }
}

/**
 * Load a thread's debugging state (arch_interface.debug_on): its triggers installed on this hart through the SBI, the
 * hart's trigger memory given it the first time. One with none installs nothing; one the SBI refuses is left off.
 *
 * @param debug The thread's state.
 * @param registers Unused.
 */
debug_on :: fn(debug : ptr[DebugRegisters], registers : ptr[mut UserRegisters]) {
    cpu :: current_cpu()
    count := cast[usize](0)
    for trigger, i in debug.triggers {
        if trigger != 0 && count < cpu.trigger_memory.count {
            cpu.trigger_memory[count] = TriggerEntry.{tdata1 = trigger, tdata2 = debug.addresses[i]}
            count += 1
        }
    }
    if debug.step && count < cpu.trigger_memory.count {
        cpu.trigger_memory[count] = if current_system().count_triggers > 0 {
            TriggerEntry.{tdata1 = TRIGGER_COUNT | COUNT_USER | COUNT_ONE}
        }
        else {
            TriggerEntry.{tdata1 = TRIGGER_MATCH | MATCH_USER | MATCH_EXECUTE, tdata2 = debug.step_targets[0]}
        }
        count += 1
        if current_system().count_triggers == 0 && debug.step_targets[1] != 0 && count < cpu.trigger_memory.count {
            cpu.trigger_memory[count] = TriggerEntry.{tdata1 = TRIGGER_MATCH | MATCH_USER | MATCH_EXECUTE, tdata2 = debug.step_targets[1]}
            count += 1
        }
    }
    if count == 0 {
        return void
    }
    if !cpu.trigger_memory_given {
        // ArchCpu is in the direct map, so its physical address is its address less the map's offset
        physical :: cast[u64](&cpu.trigger_memory[0]) - current_system().direct_map_offset
        if riscv64.sbi_call(SBI_DBTR, DBTR_SET_SHMEM, physical, 0, 0).error != 0 {
            return void
        }
        cpu.trigger_memory_given = true
    }
    if riscv64.sbi_call(SBI_DBTR, DBTR_INSTALL, cast[u64](count)).error != 0 {
        return void
    }
    // Each entry's tstate is its trigger's index now
    for i in 0..<count {
        if i < cpu.installed.count {
            cpu.installed[i] = cpu.trigger_memory[i].tstate
        }
    }
    cpu.installed_count = count
    cpu.loaded = debug^
}

/**
 * Turn the hart's breakpoints, watchpoints and step off (arch_interface.debug_off): each installed trigger uninstalled
 * through the SBI. Nothing's done when there are none.
 */
debug_off :: fn() {
    cpu :: current_cpu()
    for i in 0..<cpu.installed_count {
        if i < cpu.installed.count {
            _ = riscv64.sbi_call(SBI_DBTR, DBTR_UNINSTALL, cpu.installed[i], 1)
        }
    }
    cpu.installed_count = 0
}

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
 * TrapScratch, with the kernel stack's top for the next trap, and its kernel shadow stack's, turned on the first time
 * (hardening.hsc), the thread's senvcfg set, the kernel's writes fenced before user mode's device accesses, then every
 * register loaded, user mode's ssp put back, and sret.
 *
 * @param registers The thread's registers.
 */
return_to_user :: fn(registers : ptr[UserRegisters]) #never_returns {
    cpu :: current_cpu()
    frame := registers.frame
    frame.sstatus = user_status(frame.sstatus)
    cpu.scratch.kernel_stack = cpu.kernel_stack_top
    /*
     * The kernel shadow stack from its top, turned on the first time, here rather than in a function: one returning
     * across it would check, against the new stack, a return pushed before it (hardening.hsc)
     */
    if cpu.kernel_shadow_top != 0 && !cpu.shadow_stacks_on {
        cpu.shadow_stacks_on = riscv64.sbi_call(SBI_FWFT, SBI_FWFT_SET, FWFT_SHADOW_STACK, 1, 0).error == 0
        // check_shadow_stacks found it on every hart, so threads may have shadow stacks; it has to go on here too
        runtime.assert(cpu.shadow_stacks_on || !current_system().shadow_stacks, "FWFT didn't turn shadow stacks on")
    }
    if cpu.shadow_stacks_on {
        riscv64.csrw(.SSP, cpu.kernel_shadow_top)
        cpu.scratch.kernel_shadow_stack = cpu.kernel_shadow_top
    }
    riscv64.csrw(.SENVCFG, cpu.user_envcfg)
    /*
     * What the kernel wrote is ordered before a device access user mode makes next: a driver programming its device's
     * MSI after a call that routed it needs the route seen first, which RVWMO orders only with an output fence
     */
    riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_OUTPUT)
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
