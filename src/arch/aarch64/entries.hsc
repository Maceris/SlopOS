package arch_aarch64

import intrinsics from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import kernel_entry from "../../kernel/entry"

/*
 * Entry to the kernel (docs/specs/arch_interface.md, Entry Stubs): one entry function for the whole vector
 * table, through aarch64.vector_table, whose generated code saves the interrupted code's registers in a
 * RegisterFrame on SP_EL1. This finds the CPU through TPIDR_EL1, loads its carrier block, pushes its
 * context, and decodes the cause into kernel_entry's portable arguments.
 *
 * Exceptions run on SP_EL1, the kernel stack: from user mode and idle, from its top, where return_to_user
 * left it; from the kernel's boot code on SP_EL0, wherever it is; and from an entry, below it. So every
 * entry gets the kernel stack's limit.
 */

// ESR_EL1's exception classes this decodes, besides those aarch64 names (bits 26 to 31).
//SPEC: Arm ARM (DDI 0487) D19.2.40 ESR_EL1 (exception classes)
/** ESR_EL1.EC 0x00: an unknown reason, as an undefined instruction gives; decoded as InvalidInstruction. */
ESR_CLASS_UNKNOWN : u64 : 0x00
/** ESR_EL1.EC 0x3c: a BRK instruction; decoded as Breakpoint. */
ESR_CLASS_BREAKPOINT : u64 : 0x3c
/** ESR_EL1.EC 0x07: a trapped floating-point or SIMD access; decoded as FloatingPoint. */
ESR_CLASS_FP_ACCESS : u64 : 0x07
/** ESR_EL1.EC 0x0e: an illegal execution state; decoded as Protection. */
ESR_CLASS_ILLEGAL_STATE : u64 : 0x0e
/** ESR_EL1.EC 0x22: a misaligned PC; decoded as Alignment. */
ESR_CLASS_PC_ALIGNMENT : u64 : 0x22
/** ESR_EL1.EC 0x26: a misaligned SP; decoded as Alignment. */
ESR_CLASS_SP_ALIGNMENT : u64 : 0x26
/** ESR_EL1.EC 0x2c: a trapped floating-point exception from AArch64; decoded as FloatingPoint. */
ESR_CLASS_FP_EXCEPTION : u64 : 0x2c
/** ESR_EL1.EC 0x32: a software step from a lower exception level; decoded as SingleStep. */
ESR_CLASS_SOFTWARE_STEP_LOWER : u64 : 0x32
/** ESR_EL1.EC 0x33: a software step at the same exception level; decoded as SingleStep. */
ESR_CLASS_SOFTWARE_STEP : u64 : 0x33
/** ESR_EL1.EC 0x30: a hardware breakpoint from a lower exception level; decoded as Breakpoint. */
ESR_CLASS_HARDWARE_BREAKPOINT_LOWER : u64 : 0x30
/** ESR_EL1.EC 0x0d: a branch to no landing pad on a guarded page (FEAT_BTI); decoded as ControlFlow(LandingPad). */
ESR_CLASS_BRANCH_TARGET : u64 : 0x0d
/** ESR_EL1.EC 0x1c: a pointer that failed authentication (FEAT_FPAC); decoded as ControlFlow(Authentication). */
ESR_CLASS_AUTHENTICATION : u64 : 0x1c
/** ESR_EL1.EC 0x2d: a Guarded Control Stack fault (FEAT_GCS); decoded as ControlFlow(ShadowStack). */
ESR_CLASS_CONTROL_STACK : u64 : 0x2d
/** ESR_EL1.EC 0x34: a watchpoint from a lower exception level; decoded as Watchpoint at FAR_EL1. */
ESR_CLASS_WATCHPOINT_LOWER : u64 : 0x34
// An abort's fault status code (ISS bits 0 to 5): permission faults at levels 0 to 3, and alignment
/** An abort's fault status code for a permission fault, its low two bits the level (0 to 3) masked off. */
FAULT_STATUS_PERMISSION : u64 : 0b001100
/** An abort's fault status code for an alignment fault. */
FAULT_STATUS_ALIGNMENT : u64 : 0b100001
/** In a data abort's ISS, WnR (bit 6): the access was a write, not a read. */
DATA_ABORT_WRITE : u64 : 1 << 6

/**
 * Take every exception: the one entry function the vector table's generated code calls.
 *
 * Only a pseudo-NMI returns, to whatever it interrupted, kernel code included (decisions/0185, 12h), and so does any
 * other IRQ that reaches kernel code, without being taken: faults in the kernel stop it, and the rest come from user
 * mode or idle, which L2 never goes back to directly. An IRQ's ID is
 * taken first; then the kernel's priority mask is set and IRQs unmasked in PSTATE, so only SGI_NMI reaches the kernel
 * from here on. Interrupts are acknowledged as interrupt_source says (gic.hsc). Runs at EL1 on SP_EL1, with the CPU's
 * carrier block and context set up here from its ArchCpu, and its stack limit set to the kernel stack's.
 *
 * @param frame The interrupted code's registers, saved on SP_EL1 by the generated code, with the vector's offset,
 *     ESR_EL1 and FAR_EL1; for an entry from user mode, the thread's UserRegisters, which kernel_entry may change.
 */
exception_entry #calling_convention(.entry) :: fn(frame: ptr[mut aarch64.RegisterFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](aarch64.read_system_register(.TPIDR_EL1))
    kind :: frame.vector & 3
    interrupted_mask :: aarch64.read_system_register(.ICC_PMR_EL1)
    interrupt := NO_INTERRUPT
    if kind == cast[u64](aarch64.ExceptionKind.Irq) || kind == cast[u64](aarch64.ExceptionKind.Fiq) {
        /*
         * Kernel code, under the kernel's mask, is meant to be interrupted only by the NMI. Anything else that comes
         * anyway, as a signal raised just before the mask was, or withdrawn before it's taken, isn't taken: it stays
         * pending until the kernel lets it through, and the kernel goes on where it was, rather than as if from idle.
         */
        if interrupted_mask == KERNEL_PRIORITY_MASK && pending_interrupt() != SGI_NMI {
            return void
        }
        interrupt = take_interrupt()
    }
    mask_for_kernel()
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        if interrupt == SGI_NMI {
            take_nmi(frame)
        }
        else {
            dispatch(frame, interrupt)
        }
    }
    // Back to what the NMI interrupted, with its mask: IRQs masked in PSTATE first, so none comes before the eret
    aarch64.daif_set(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ)
    aarch64.write_system_register(.ICC_PMR_EL1, interrupted_mask)
    aarch64.isb()
}

/** An IRQ's ID for an exception that isn't one. */
NO_INTERRUPT : u32 : 0xffffffff

/**
 * Let only SGI_NMI reach the calling CPU, in the kernel: the priority mask at KERNEL_PRIORITY_MASK, then IRQs unmasked
 * in PSTATE. A write to ICC_PMR_EL1 masks what it masks once it's executed (IHI 0069, §12.1.6), so nothing else
 * comes between.
 */
mask_for_kernel #no_context :: fn() {
    aarch64.write_system_register(.ICC_PMR_EL1, KERNEL_PRIORITY_MASK)
    aarch64.isb()
    aarch64.daif_clear(aarch64.DAIF_IRQ)
}

/**
 * Let every interrupt reach the calling CPU again once it erets to user mode or idle: IRQs masked in PSTATE until the
 * eret, which restores PSTATE from SPSR_EL1, then the priority mask at PRIORITY_MASK.
 */
unmask_for_return :: fn() {
    aarch64.daif_set(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ)
    aarch64.write_system_register(.ICC_PMR_EL1, PRIORITY_MASK)
    aarch64.isb()
}

/**
 * Handle a pseudo-NMI: kernel_entry.nmi with the interrupted registers and frame pointer, then acknowledge it.
 *
 * @param frame The interrupted code's registers: x0 to x30, then its stack pointer (SP_EL0 from user mode, else where
 *     SP_EL1 was before the frame), the program counter and PSTATE, as nmi_register_name names them.
 */
take_nmi :: fn(frame: ptr[mut aarch64.RegisterFrame]) {
    registers : u64[34]
    for value, i in frame.x {
        if i < registers.count {
            registers[i] = value
        }
    }
    registers[31] = if from_user_mode(frame) { frame.sp_el0 } else { cast[u64](frame) + cast[u64](size_of(aarch64.RegisterFrame)) }
    registers[32] = frame.elr
    registers[33] = frame.spsr
    kernel_entry.nmi(frame.elr, frame.x[29], registers[0..<registers.count])
    acknowledge(SGI_NMI)
}

/**
 * Name a register of those take_nmi passes kernel_entry.nmi (arch_interface.nmi_register_name).
 *
 * @param index Its place: x0 to x30, sp, pc, then pstate.
 * @return Its name, a constant; "?" past them.
 */
nmi_register_name :: fn(index: usize) -> string {
    names :: string.["x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16",
        "x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "sp", "pc", "pstate"]
    if index >= names.count {
        return "?"
    }
    return names[index]
}

/**
 * Tell whether an exception came from EL0 in AArch64 state, through the vector table's lower-EL entries.
 *
 * @param frame The saved registers, whose vector says which of the table's entries was taken.
 * @return True for the lower-EL AArch64 entries; false for the current-EL ones and the lower-EL AArch32 ones.
 */
from_user_mode :: fn(frame: ptr[aarch64.RegisterFrame]) -> bool {
    return frame.vector & ~cast[u64](3) == aarch64.VECTOR_LOWER_AARCH64
}

/**
 * Decode a fault or an interrupt and hand it to kernel_entry, which never returns.
 *
 * Anything from 32-bit code, which never runs, is a kernel Protection fault; an SError is a fatal MachineCheck;
 * IRQs and FIQs go to kernel_entry.interrupt, from User or, for anything else, Idle; an SVC from user mode is a
 * system call; and every other synchronous exception is a fault, the thread's from user mode and the kernel's
 * otherwise.
 *
 * @param frame The saved registers, as exception_entry has them.
 * @param interrupt An IRQ's or FIQ's ID, as exception_entry took it; NO_INTERRUPT for other exceptions.
 */
dispatch :: fn(frame: ptr[mut aarch64.RegisterFrame], interrupt: u32) #never_returns {
    kind :: frame.vector & 3
    source :: frame.vector & ~cast[u64](3)
    instruction :: cast[arch_interface.VirtualAddress](frame.elr)
    // From 32-bit code, which never runs
    if source == aarch64.VECTOR_LOWER_AARCH32 {
        kernel_entry.kernel_fault(.Protection, instruction)
    }
    if kind == cast[u64](aarch64.ExceptionKind.SError) {
        // An asynchronous external abort, like a machine check
        kernel_entry.fatal_critical(.MachineCheck)
    }
    if kind != cast[u64](aarch64.ExceptionKind.Synchronous) {
        // IRQs and FIQs, through the GIC. The kernel only lets them through in user mode and idle, but the NMI
        source :: interrupt_source(interrupt)
        if from_user_mode(frame) {
            kernel_entry.interrupt(.User(cast[ptr[mut UserRegisters]](frame)), source)
        }
        kernel_entry.interrupt(.Idle, source)
    }
    class :: (frame.esr >> 26) & 0x3f
    if class == aarch64.ESR_CLASS_SVC && from_user_mode(frame) {
        kernel_entry.syscall(cast[ptr[mut UserRegisters]](frame))
    }
    fault :: decode_fault(class, frame.esr, frame.far)
    if from_user_mode(frame) {
        kernel_entry.user_fault(cast[ptr[mut UserRegisters]](frame), fault)
    }
    kernel_entry.kernel_fault(fault, instruction)
}

/**
 * Decode a synchronous exception into the portable fault it is.
 *
 * SPEC: Arm ARM (DDI 0487) D19.2.40 ESR_EL1 (exception classes, and the ISS of instruction and data aborts).
 *
 * @param class ESR_EL1.EC, the exception class (bits 26 to 31), 0 to 0x3f.
 * @param syndrome ESR_EL1 whole, whose ISS an abort's status code and WnR are read from.
 * @param address FAR_EL1, the faulting virtual address, which only an abort's result uses.
 * @return For an instruction or data abort, Alignment for an alignment fault, or else a Page fault at address,
 *     Execute, Write or Read, present only for a permission fault (translation and access flag faults aren't).
 *     For other classes: InvalidInstruction, Breakpoint, SingleStep, Watchpoint at address, Alignment or
 *     FloatingPoint as the class says,
 *     and Protection for every other class, like an illegal execution state or a trapped system instruction.
 */
decode_fault :: fn(class: u64, syndrome: u64, address: u64) -> arch_interface.Fault {
    status :: syndrome & 0x3f
    if class == aarch64.ESR_CLASS_INSTRUCTION_ABORT || class == aarch64.ESR_CLASS_INSTRUCTION_ABORT_LOWER
        || class == aarch64.ESR_CLASS_DATA_ABORT || class == aarch64.ESR_CLASS_DATA_ABORT_LOWER {
        if status == FAULT_STATUS_ALIGNMENT {
            return .Alignment
        }
        instruction_fetch :: class == aarch64.ESR_CLASS_INSTRUCTION_ABORT || class == aarch64.ESR_CLASS_INSTRUCTION_ABORT_LOWER
        access : arch_interface.Access = if instruction_fetch { .Execute } else if syndrome & DATA_ABORT_WRITE != 0 { .Write } else { .Read }
        return .Page(arch_interface.PageFault.{
            address = cast[arch_interface.VirtualAddress](address),
            access = access,
            present = status & ~cast[u64](3) == FAULT_STATUS_PERMISSION,
        })
    }
    return match class {
        case ESR_CLASS_UNKNOWN => .InvalidInstruction
        case ESR_CLASS_BREAKPOINT => .Breakpoint
        case ESR_CLASS_HARDWARE_BREAKPOINT_LOWER => .Breakpoint
        case ESR_CLASS_WATCHPOINT_LOWER => .Watchpoint(address)
        case ESR_CLASS_SOFTWARE_STEP => .SingleStep
        case ESR_CLASS_SOFTWARE_STEP_LOWER => .SingleStep
        case ESR_CLASS_PC_ALIGNMENT => .Alignment
        case ESR_CLASS_SP_ALIGNMENT => .Alignment
        case ESR_CLASS_FP_ACCESS => .FloatingPoint
        case ESR_CLASS_FP_EXCEPTION => .FloatingPoint
        case ESR_CLASS_BRANCH_TARGET => .ControlFlow(.LandingPad)
        case ESR_CLASS_AUTHENTICATION => .ControlFlow(.Authentication)
        case ESR_CLASS_CONTROL_STACK => .ControlFlow(.ShadowStack)
        // Illegal execution state, trapped system instructions, and the classes nothing here raises
        case _ => .Protection
    }
}
