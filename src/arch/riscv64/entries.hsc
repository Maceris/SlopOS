package arch_riscv64

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import arch_interface from "../../arch_interface"
import kernel_entry from "../../kernel/entry"

/*
 * Entry to the kernel (docs/specs/arch_interface.md, Entry Stubs): one entry function, which stvec points at, whose
 * generated code saves the interrupted code's registers in a RegisterFrame: from user mode on the kernel stack, through
 * the TrapScratch sscratch held, with tp pointing at it, the hart's ArchCpu; from the kernel on the stack it was on,
 * with tp as it was, the ArchCpu too.
 *
 * A trap from user mode loads the hart's carrier block, pushes its context and decodes the cause into kernel_entry's
 * portable arguments. An exception in the kernel is always fatal, and may be the stack check's ebreak on a stack with
 * no room left, so it isn't handled where it was taken: the entry returns, with sret, to kernel_trap on the hart's trap
 * stack, which reports it.
 */

/** scause's code for a hardware error the hart detected (the privileged architecture's §12.1.1, code 19). */
CAUSE_HARDWARE_ERROR : u64 : 19
/** stval's value for a software-check exception that's a missing landing pad (Zicfilp). */
SOFTWARE_CHECK_LANDING_PAD : u64 : 2
/** stval's value for a software-check exception that's a shadow stack mismatch (Zicfiss). */
SOFTWARE_CHECK_SHADOW_STACK : u64 : 3

/**
 * Take every trap: the entry function stvec points at, in direct mode.
 *
 * From user mode it runs on the kernel stack's top, never returning: a system call, a fault or an interrupt for
 * kernel_entry. From the kernel it changes only the frame, and returns: the generated code then restores the
 * interrupted registers but the stack pointer, the program counter and a0 to a2, and its sret goes on in supervisor
 * mode with interrupts off. An exception goes to kernel_trap, on the trap stack, with the cause, stval and where it was
 * taken; the interrupted s0 and ra stay, so the stack trace goes on through the code that faulted. An interrupt, which
 * the kernel takes only while idle (or with interrupts unmasked, which is taken as idle, as on x86-64), goes to
 * idle_interrupt on the kernel stack's top, as an entry from idle starts there.
 *
 * @param frame The interrupted code's registers, saved by the generated code; for an entry from user mode, the
 *     thread's UserRegisters, which kernel_entry may change.
 */
trap_entry #calling_convention(.entry) :: fn(frame : ptr[mut riscv64.RegisterFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](riscv64.read_tp())
    if frame.sstatus & riscv64.SSTATUS_SPP == 0 {
        cpu.carrier.stack_limit = cpu.kernel_stack_limit
        intrinsics.set_carrier(cpu.carrier)
        push_context entry from cpu.context^ {
            from_user(frame)
        }
    }
    // A page fault on a mapping this hart hadn't seen made yet: fenced, and the access made again
    if stale_fault(cpu, frame.scause, frame.stval) {
        riscv64.sfence_vma_address(cast[rawptr](frame.stval))
        return void
    }
    frame.x[10] = frame.scause
    frame.x[11] = frame.stval
    frame.x[12] = frame.sepc
    if frame.scause & riscv64.CAUSE_INTERRUPT != 0 {
        frame.x[2] = cpu.kernel_stack_top
        frame.sepc = cast[u64](idle_interrupt)
    }
    else {
        frame.x[2] = cpu.trap_stack_top
        frame.sepc = cast[u64](kernel_trap)
    }
    // Interrupts stay off after the sret, which sets SIE from SPIE
    frame.sstatus = frame.sstatus & ~riscv64.SSTATUS_SPIE
}

/**
 * Tell whether a page fault in the kernel is only stale: the active tables, satp's, map the address with a leaf that
 * allows the access, so the hart faulted on an entry it walked before another hart made it valid, which a hart may
 * keep until Svvptc's bounded time has passed. The kernel never touches user pages, so a leaf with U set doesn't count.
 *
 * Runs in the trap entry, before there's a context, on whatever stack the kernel was on, so it calls nothing that
 * needs one.
 *
 * @param cpu The calling hart's state, for the direct map's offset.
 * @param cause scause at the trap.
 * @param address stval at the trap, the faulting address for a page fault.
 * @return True for a load, store or instruction page fault whose access the tables now allow; false for anything else.
 */
stale_fault #no_context :: fn(cpu : ptr[ArchCpu], cause : u64, address : u64) -> bool {
    needed := cast[u64](0)
    if cause == riscv64.CAUSE_LOAD_PAGE_FAULT {
        needed = ENTRY_READ
    }
    else if cause == riscv64.CAUSE_STORE_PAGE_FAULT {
        needed = ENTRY_WRITE
    }
    else if cause == riscv64.CAUSE_INSTRUCTION_PAGE_FAULT {
        needed = ENTRY_EXECUTE
    }
    else {
        return false
    }
    offset :: cast[ptr[ArchSystem]](cpu.system).direct_map_offset
    table := ((riscv64.csrr(.SATP) & SATP_PPN_MASK) << 12)
    level := TOP_LEVEL
    loop {
        entry :: cast[ptr[u64]](offset + table + ((address >> (12 + 9 * level)) & 511) * 8)^
        if entry & ENTRY_VALID == 0 {
            return false
        }
        if entry & ENTRY_LEAF != 0 {
            return entry & ENTRY_USER == 0 && entry & needed != 0
        }
        if level == 0 {
            return false
        }
        table = ((entry >> PPN_SHIFT) & PPN_MASK) << 12
        level -= 1
    }
}

/**
 * Take an interrupt that came in supervisor mode, on the kernel stack's top, where trap_entry's sret sent it: as one
 * from idle, for kernel_entry.interrupt, which never returns.
 *
 * @param cause scause at the trap: CAUSE_INTERRUPT and the interrupt's number.
 */
idle_interrupt #calling_convention(.c) #no_context :: fn(cause : u64) #never_returns {
    cpu :: cast[ptr[ArchCpu]](riscv64.read_tp())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        kernel_entry.interrupt(.Idle, interrupt_source(cause))
    }
}

/**
 * Report an exception in the kernel, on the hart's trap stack, where trap_entry's sret sent it: a hardware error as a
 * fatal MachineCheck, anything else as the fault it is, with kernel_entry.kernel_fault, which never returns.
 *
 * @param cause scause at the trap: an exception's code.
 * @param value stval at the trap, like the faulting address.
 * @param pc sepc at the trap, the instruction that faulted.
 */
kernel_trap #calling_convention(.c) #no_context :: fn(cause : u64, value : u64, pc : u64) #never_returns {
    cpu :: cast[ptr[ArchCpu]](riscv64.read_tp())
    cpu.carrier.stack_limit = cpu.trap_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        instruction :: cast[arch_interface.VirtualAddress](pc)
        if cause == CAUSE_HARDWARE_ERROR {
            kernel_entry.fatal_critical(.MachineCheck)
        }
        kernel_entry.kernel_fault(decode_fault(cause, value), instruction)
    }
}

/**
 * Hand a trap from user mode to kernel_entry, which never returns: an interrupt is decoded (interrupt_source), an ecall
 * is a system call, a hardware error a fatal MachineCheck, any other exception the thread's fault.
 *
 * @param frame The thread's registers, as the generated code saved them on the kernel stack.
 */
from_user :: fn(frame : ptr[mut riscv64.RegisterFrame]) #never_returns {
    registers :: cast[ptr[mut UserRegisters]](frame)
    if frame.scause & riscv64.CAUSE_INTERRUPT != 0 {
        kernel_entry.interrupt(.User(registers), interrupt_source(frame.scause))
    }
    if frame.scause == riscv64.CAUSE_USER_ECALL {
        kernel_entry.syscall(registers)
    }
    if frame.scause == CAUSE_HARDWARE_ERROR {
        kernel_entry.fatal_critical(.MachineCheck)
    }
    kernel_entry.user_fault(registers, decode_fault(frame.scause, frame.stval))
}

/**
 * Decode an exception into the portable fault it is.
 *
 * SPEC: The RISC-V Instruction Set Manual, Volume II: Privileged Architecture, §12.1.1 (scause's exception codes),
 * §12.1.2 (stval); the Zicfilp and Zicfiss chapters (software-check exceptions).
 *
 * @param cause scause, an exception's code (CAUSE_INTERRUPT clear).
 * @param value stval: for a page fault, the faulting address; for a software check, which one.
 * @return A Page fault for a page fault, at value, Execute, Read or Write, present if the active tables map value with
 *     a valid leaf (so the access broke its protection); Alignment for a misaligned access; InvalidInstruction for an
 *     illegal instruction; Breakpoint for ebreak; ControlFlow for a landing pad's or a shadow stack's software check;
 *     Protection for the rest, like an access fault the PMP or the bus raised.
 */
decode_fault :: fn(cause : u64, value : u64) -> arch_interface.Fault {
    access : arch_interface.Access = .Read
    if cause == riscv64.CAUSE_INSTRUCTION_PAGE_FAULT {
        access = .Execute
    }
    else if cause == riscv64.CAUSE_STORE_PAGE_FAULT {
        access = .Write
    }
    else if cause != riscv64.CAUSE_LOAD_PAGE_FAULT {
        misaligned :: cause == riscv64.CAUSE_INSTRUCTION_MISALIGNED
            || cause == riscv64.CAUSE_LOAD_MISALIGNED
            || cause == riscv64.CAUSE_STORE_MISALIGNED
        if misaligned {
            return .Alignment
        }
        if cause == riscv64.CAUSE_ILLEGAL_INSTRUCTION {
            return .InvalidInstruction
        }
        if cause == riscv64.CAUSE_BREAKPOINT {
            return .Breakpoint
        }
        if cause == riscv64.CAUSE_SOFTWARE_CHECK && value == SOFTWARE_CHECK_LANDING_PAD {
            return .ControlFlow(.LandingPad)
        }
        if cause == riscv64.CAUSE_SOFTWARE_CHECK && value == SOFTWARE_CHECK_SHADOW_STACK {
            return .ControlFlow(.ShadowStack)
        }
        return .Protection
    }
    return .Page(
        arch_interface.PageFault.{
            address = cast[arch_interface.VirtualAddress](value),
            access = access,
            present = mapped_now(value),
        }
    )
}

/**
 * Tell whether the active page tables, satp's, map an address with a valid leaf.
 *
 * @param address Any virtual address.
 * @return True if the walk from satp's root, through the direct map, ends at a valid leaf; false if an entry on the
 *     way is invalid.
 */
mapped_now :: fn(address : u64) -> bool {
    table :: PageTable.{
        root = cast[arch_interface.PhysicalAddress]((riscv64.csrr(.SATP) & SATP_PPN_MASK) << 12),
        direct_map_offset = current_system().direct_map_offset,
    }
    return translate(&table, cast[arch_interface.VirtualAddress](address)) is_some
}
