package arch_x86_64

import intrinsics from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import kernel_entry from "../../kernel/entry"

/*
 * Entry to the kernel (docs/specs/arch_interface.md, Entry Stubs): one entry function for every
 * vector, through x86_64.entry_points, and one for SYSCALL. Their generated code saves the
 * interrupted code's registers in a RegisterFrame, with swapgs first when it was in user mode.
 * These find the CPU through the gs base, load its carrier block with stack_limit set for the
 * stack they run on, push its context, and decode the cause into kernel_entry's portable
 * arguments.
 *
 * Every vector runs on an IST stack: the kernel stack's own slot for most, so an entry from idle
 * starts again at its top, and stacks of their own for the critical events, which can arrive
 * while the kernel stack is in use.
 *
 * The local APIC's timer and IPIs are acknowledged here, before the kernel handles them; device
 * interrupts are acknowledged by the kernel, with end_of_interrupt.
 */

NMI_VECTOR : u64 : 2
DOUBLE_FAULT_VECTOR : u64 : 8
MACHINE_CHECK_VECTOR : u64 : 18
FIRST_INTERRUPT_VECTOR : u64 : 32

/*
 * Every vector. Only an NMI returns, to whatever it interrupted, which may be anywhere, even an
 * entry that hasn't loaded the carrier block yet: the generated code restores the interrupted
 * registers, the carrier register among them, and this restores the carrier block's stack_limit.
 */
kernel_entry_point #calling_convention(.entry) :: fn(frame: ptr[mut x86_64.RegisterFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    vector :: frame.vector
    if vector == NMI_VECTOR {
        saved_limit :: cpu.carrier.stack_limit
        cpu.carrier.stack_limit = cpu.critical_stack_limits[cast[u8](arch_interface.CriticalEvent.Nmi)]
        intrinsics.set_carrier(cpu.carrier)
        push_context entry from cpu.context^ {
            kernel_entry.nmi()
        }
        cpu.carrier.stack_limit = saved_limit
        return void
    }
    if vector == DOUBLE_FAULT_VECTOR || vector == MACHINE_CHECK_VECTOR {
        event : arch_interface.CriticalEvent = .DoubleFault
        if vector == MACHINE_CHECK_VECTOR {
            event = .MachineCheck
        }
        cpu.carrier.stack_limit = cpu.critical_stack_limits[cast[u8](event)]
        intrinsics.set_carrier(cpu.carrier)
        push_context entry from cpu.context^ {
            kernel_entry.fatal_critical(event)
        }
    }
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        dispatch(frame)
    }
}

// SYSCALL, from user mode, on the kernel stack the generated code switched to.
system_call_entry #calling_convention(.syscall_entry) :: fn(frame: ptr[mut x86_64.RegisterFrame]) #never_returns {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        kernel_entry.syscall(cast[ptr[mut UserRegisters]](frame))
    }
}

// Whether the interrupted code ran in user mode, from the privilege level of its code segment.
from_user_mode :: fn(frame: ptr[x86_64.RegisterFrame]) -> bool {
    return (frame.cs & 3) == 3
}

// A fault or an interrupt, decoded for kernel_entry.
dispatch :: fn(frame: ptr[mut x86_64.RegisterFrame]) #never_returns {
    vector :: frame.vector
    if vector < FIRST_INTERRUPT_VECTOR {
        fault :: decode_fault(vector, frame.error_code)
        if from_user_mode(frame) {
            kernel_entry.user_fault(cast[ptr[mut UserRegisters]](frame), fault)
        }
        kernel_entry.kernel_fault(fault, cast[arch_interface.VirtualAddress](frame.rip))
    }
    source :: interrupt_source(vector)
    if from_user_mode(frame) {
        kernel_entry.interrupt(.User(cast[ptr[mut UserRegisters]](frame)), source)
    }
    kernel_entry.interrupt(.Idle, source)
}

//SPEC: Intel SDM Vol. 3A §7.15 (exception and interrupt reference)
decode_fault :: fn(vector: u64, error_code: u64) -> arch_interface.Fault {
    return match vector {
        case 0 => .Arithmetic
        case 1 => .SingleStep
        case 3 => .Breakpoint
        case 4 => .Arithmetic
        case 6 => .InvalidInstruction
        case 7 => .FloatingPoint
        case 14 => .Page(decode_page_fault(error_code))
        case 16 => .FloatingPoint
        case 17 => .Alignment
        case 19 => .FloatingPoint
        // Bound range, the segment and protection faults, virtualization and control protection,
        // and the vectors the CPU doesn't raise
        case _ => .Protection
    }
}

// A page fault's error code and address: bit 0 present, bit 1 write, bit 4 instruction fetch.
//SPEC: Intel SDM Vol. 3A §4.7, Figure 4-12 (page-fault error code)
decode_page_fault :: fn(error_code: u64) -> arch_interface.PageFault {
    access : arch_interface.Access = .Read
    if (error_code >> 4) & 1 == 1 {
        access = .Execute
    }
    else if (error_code >> 1) & 1 == 1 {
        access = .Write
    }
    return arch_interface.PageFault.{
        address = cast[arch_interface.VirtualAddress](x86_64.read_cr2()),
        access = access,
        present = error_code & 1 == 1,
    }
}

/*
 * An interrupt's source. The timer and IPIs are acknowledged here; spurious interrupts aren't
 * acknowledged at all (Intel SDM Vol. 3A §11.9). Vectors nothing raises count as spurious.
 */
interrupt_source :: fn(vector: u64) -> kernel_entry.InterruptSource {
    if vector >= cast[u64](FIRST_DEVICE_VECTOR) && vector < cast[u64](FIRST_DEVICE_VECTOR + DEVICE_VECTOR_COUNT) {
        return .Device(cast[arch_interface.InterruptId](vector))
    }
    source : kernel_entry.InterruptSource = .Spurious
    if vector == cast[u64](TIMER_VECTOR) {
        source = .Timer
    }
    else if vector == cast[u64](RESCHEDULE_VECTOR) {
        source = .Ipi(.Reschedule)
    }
    else if vector == cast[u64](TLB_FLUSH_VECTOR) {
        source = .Ipi(.TlbFlush)
    }
    else if vector == cast[u64](STOP_VECTOR) {
        source = .Ipi(.Stop)
    }
    else {
        return source
    }
    end_of_interrupt(cast[arch_interface.InterruptId](0))
    return source
}

// Point every vector at its entry point, on the IST stack it runs on.
fill_idt :: fn(system: ptr[mut ArchSystem]) {
    points :: x86_64.entry_points(kernel_entry_point)
    for vector in 0..<256 {
        stack := IST_KERNEL
        if cast[u64](vector) == NMI_VECTOR {
            stack = IST_NMI
        }
        else if cast[u64](vector) == DOUBLE_FAULT_VECTOR {
            stack = IST_DOUBLE_FAULT
        }
        else if cast[u64](vector) == MACHINE_CHECK_VECTOR {
            stack = IST_MACHINE_CHECK
        }
        system.idt[vector] = gate(points.addresses[vector], stack)
    }
}
