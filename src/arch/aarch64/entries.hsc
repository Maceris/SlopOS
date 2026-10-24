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
ESR_CLASS_UNKNOWN : u64 : 0x00
ESR_CLASS_BREAKPOINT : u64 : 0x3c
ESR_CLASS_FP_ACCESS : u64 : 0x07
ESR_CLASS_ILLEGAL_STATE : u64 : 0x0e
ESR_CLASS_PC_ALIGNMENT : u64 : 0x22
ESR_CLASS_SP_ALIGNMENT : u64 : 0x26
ESR_CLASS_FP_EXCEPTION : u64 : 0x2c
ESR_CLASS_SOFTWARE_STEP_LOWER : u64 : 0x32
ESR_CLASS_SOFTWARE_STEP : u64 : 0x33
// An abort's fault status code (ISS bits 0 to 5): permission faults at levels 0 to 3, and alignment
FAULT_STATUS_PERMISSION : u64 : 0b001100
FAULT_STATUS_ALIGNMENT : u64 : 0b100001
// In a data abort's ISS: the access was a write
DATA_ABORT_WRITE : u64 : 1 << 6

/*
 * Every exception. None returns: faults in the kernel stop it, and the rest come from user mode or idle,
 * which L2 never goes back to directly. Interrupts are acknowledged as interrupt_source says (gic.hsc).
 */
exception_entry #calling_convention(.entry) :: fn(frame: ptr[mut aarch64.RegisterFrame]) #never_returns {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](aarch64.read_system_register(.TPIDR_EL1))
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        dispatch(frame)
    }
}

// Whether the exception came from EL0, through the vector table's lower-EL entries.
from_user_mode :: fn(frame: ptr[aarch64.RegisterFrame]) -> bool {
    return frame.vector & ~cast[u64](3) == aarch64.VECTOR_LOWER_AARCH64
}

// A fault or an interrupt, decoded for kernel_entry.
dispatch :: fn(frame: ptr[mut aarch64.RegisterFrame]) #never_returns {
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
        // IRQs and FIQs, through the GIC. The kernel only unmasks them in user mode and idle
        source :: interrupt_source()
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

//SPEC: Arm ARM (DDI 0487) D19.2.40 ESR_EL1 (exception classes, and the ISS of instruction and data aborts)
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
        case ESR_CLASS_SOFTWARE_STEP => .SingleStep
        case ESR_CLASS_SOFTWARE_STEP_LOWER => .SingleStep
        case ESR_CLASS_PC_ALIGNMENT => .Alignment
        case ESR_CLASS_SP_ALIGNMENT => .Alignment
        case ESR_CLASS_FP_ACCESS => .FloatingPoint
        case ESR_CLASS_FP_EXCEPTION => .FloatingPoint
        // Illegal execution state, trapped system instructions, and the classes nothing here raises
        case _ => .Protection
    }
}
