package arch_x86_64

import intrinsics from "base"
import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import kernel_entry from "../../kernel/entry"

/*
 * Entry to the kernel through the IDT, one interrupt function per vector, each decoding its cause
 * into the portable arguments of a kernel_entry function (docs/specs/arch_interface.md, Entry Stubs).
 *
 * Each one finds its CPU through the gs base, loads the CPU's carrier block with stack_limit set for
 * the stack it runs on, and pushes the CPU's context. Every vector but the critical events runs on
 * the kernel stack (IST_KERNEL), starting at its top.
 *
 * The local APIC's timer and IPIs are acknowledged here, before the kernel handles them; device
 * interrupts are acknowledged by the kernel, with end_of_interrupt.
 */
//HEMERA(gap): these are interrupt functions, which only work for entries from kernel mode. Entries
//from user mode need entry functions (#calling_convention(.entry), x86_64.entry_points), which the
//compiler can't generate yet; with them, one function covers every vector.
//HEMERA(friction): an interrupt function has no context, so it can't call a helper to find its
//CPU and push the context: those lines are repeated in every one of them
//TODO(claude): device vectors (48 to 239) once entry functions give the vector number (M3)

// Whether the interrupted code ran in user mode, from the privilege level of its code segment.
from_user_mode :: fn(frame: ptr[x86_64.InterruptFrame]) -> bool {
    return (frame.cs & 3) == 3
}

// Entries from user mode need entry functions, which aren't available yet.
unsupported_user_entry :: fn() #never_returns {
    runtime.log_fatal("an interrupt or fault arrived from user mode, which needs entry functions")
    halt()
}

// A fault, which is a bug in the kernel: it can't arrive from user mode yet.
report_fault :: fn(frame: ptr[x86_64.InterruptFrame], fault: arch_interface.Fault) #never_returns {
    if from_user_mode(frame) {
        unsupported_user_entry()
    }
    kernel_entry.kernel_fault(fault, cast[arch_interface.VirtualAddress](frame.rip))
}

// An interrupt, which the kernel only enables while idle.
interrupt_from :: fn(frame: ptr[x86_64.InterruptFrame], source: kernel_entry.InterruptSource) #never_returns {
    if from_user_mode(frame) {
        unsupported_user_entry()
    }
    kernel_entry.interrupt(.Idle, source)
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

// Faults
//SPEC: Intel SDM Vol. 3A §7.15 (exception and interrupt reference)


// Vector 0
divide_error #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Arithmetic)
    }
}

// Vector 1
debug #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .SingleStep)
    }
}

// Vector 3
breakpoint #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Breakpoint)
    }
}

// Vector 4
overflow #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Arithmetic)
    }
}

// Vector 5
bound_range #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vector 6
invalid_opcode #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .InvalidInstruction)
    }
}

// Vector 7
device_not_available #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .FloatingPoint)
    }
}

// Vector 10
invalid_tss #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vector 11
segment_not_present #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vector 12
stack_segment_fault #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vector 13
general_protection #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vector 14
page_fault #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Page(decode_page_fault(error_code)))
    }
}

// Vector 16
x87_floating_point #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .FloatingPoint)
    }
}

// Vector 17
alignment_check #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Alignment)
    }
}

// Vector 19
simd_floating_point #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .FloatingPoint)
    }
}

// Vector 20
virtualization #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vector 21
control_protection #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Vectors 9, 15 and 22 to 31, which the CPU doesn't raise
reserved_vector #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        report_fault(frame, .Protection)
    }
}

// Local APIC interrupts

timer #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        end_of_interrupt(cast[arch_interface.InterruptId](0))
        interrupt_from(frame, .Timer)
    }
}

reschedule_ipi #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        end_of_interrupt(cast[arch_interface.InterruptId](0))
        interrupt_from(frame, .Ipi(.Reschedule))
    }
}

tlb_flush_ipi #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        end_of_interrupt(cast[arch_interface.InterruptId](0))
        interrupt_from(frame, .Ipi(.TlbFlush))
    }
}

stop_ipi #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        end_of_interrupt(cast[arch_interface.InterruptId](0))
        interrupt_from(frame, .Ipi(.Stop))
    }
}

// Spurious interrupts aren't acknowledged (Intel SDM Vol. 3A §11.9)
spurious #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        interrupt_from(frame, .Spurious)
    }
}

// Critical events, on stacks of their own, since they can arrive at any time

/*
 * An NMI can arrive anywhere, even in an entry before it loaded the carrier, so this one sets
 * stack_limit for its stack and restores both the limit and the interrupted code's carrier register.
 */
nmi #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    interrupted := intrinsics.carrier()
    saved_limit := cpu.carrier.stack_limit
    cpu.carrier.stack_limit = cpu.critical_stack_limits[cast[u8](arch_interface.CriticalEvent.Nmi)]
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        kernel_entry.nmi()
    }
    cpu.carrier.stack_limit = saved_limit
    intrinsics.set_carrier(interrupted)
}

double_fault #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame], error_code: u64) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.critical_stack_limits[cast[u8](arch_interface.CriticalEvent.DoubleFault)]
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        kernel_entry.fatal_critical(.DoubleFault)
    }
}

machine_check #calling_convention(.interrupt) :: fn(frame: ptr[x86_64.InterruptFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.critical_stack_limits[cast[u8](arch_interface.CriticalEvent.MachineCheck)]
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        kernel_entry.fatal_critical(.MachineCheck)
    }
}


// Point every vector the kernel handles at its interrupt function. The rest stay not present.
fill_idt :: fn(system: ptr[mut ArchSystem]) {
    system.idt[0] = gate(cast[u64](divide_error), IST_KERNEL)
    system.idt[1] = gate(cast[u64](debug), IST_KERNEL)
    system.idt[3] = gate(cast[u64](breakpoint), IST_KERNEL)
    system.idt[4] = gate(cast[u64](overflow), IST_KERNEL)
    system.idt[5] = gate(cast[u64](bound_range), IST_KERNEL)
    system.idt[6] = gate(cast[u64](invalid_opcode), IST_KERNEL)
    system.idt[7] = gate(cast[u64](device_not_available), IST_KERNEL)
    system.idt[10] = gate(cast[u64](invalid_tss), IST_KERNEL)
    system.idt[11] = gate(cast[u64](segment_not_present), IST_KERNEL)
    system.idt[12] = gate(cast[u64](stack_segment_fault), IST_KERNEL)
    system.idt[13] = gate(cast[u64](general_protection), IST_KERNEL)
    system.idt[14] = gate(cast[u64](page_fault), IST_KERNEL)
    system.idt[16] = gate(cast[u64](x87_floating_point), IST_KERNEL)
    system.idt[17] = gate(cast[u64](alignment_check), IST_KERNEL)
    system.idt[19] = gate(cast[u64](simd_floating_point), IST_KERNEL)
    system.idt[20] = gate(cast[u64](virtualization), IST_KERNEL)
    system.idt[21] = gate(cast[u64](control_protection), IST_KERNEL)
    system.idt[2] = gate(cast[u64](nmi), IST_NMI)
    system.idt[8] = gate(cast[u64](double_fault), IST_DOUBLE_FAULT)
    system.idt[18] = gate(cast[u64](machine_check), IST_MACHINE_CHECK)
    for vector in RESERVED_VECTORS {
        system.idt[vector] = gate(cast[u64](reserved_vector), IST_KERNEL)
    }
    system.idt[TIMER_VECTOR] = gate(cast[u64](timer), IST_KERNEL)
    system.idt[RESCHEDULE_VECTOR] = gate(cast[u64](reschedule_ipi), IST_KERNEL)
    system.idt[TLB_FLUSH_VECTOR] = gate(cast[u64](tlb_flush_ipi), IST_KERNEL)
    system.idt[STOP_VECTOR] = gate(cast[u64](stop_ipi), IST_KERNEL)
    system.idt[SPURIOUS_VECTOR] = gate(cast[u64](spurious), IST_KERNEL)
}

RESERVED_VECTORS :: u8.[9, 15, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]
