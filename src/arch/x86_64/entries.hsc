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

/** The NMI's vector, which runs on its own stack and is the only one that returns. */
NMI_VECTOR : u64 : 2
/** The double fault's vector, which runs on its own stack and is fatal. */
DOUBLE_FAULT_VECTOR : u64 : 8
/** The machine check's vector, which runs on its own stack and is fatal. */
MACHINE_CHECK_VECTOR : u64 : 18
/** The first vector that isn't an exception: those below are faults, those from here interrupts. */
FIRST_INTERRUPT_VECTOR : u64 : 32

/**
 * Enter the kernel from any vector, on the IST stack fill_idt gave it, with interrupts disabled.
 *
 * Only an NMI returns, to whatever it interrupted, which may be anywhere, even an entry that hasn't loaded the carrier
 * block yet: the generated code restores the interrupted registers, the carrier register among them, and this
 * restores the carrier block's stack_limit. A double fault or machine check goes to kernel_entry.fatal_critical, and
 * everything else to dispatch, neither of which returns.
 *
 * @param frame The interrupted code's registers, with the vector and error code, as the generated stub saved them on
 *     the entry's stack; valid until the entry returns or leaves for good.
 */
kernel_entry_point #calling_convention(.entry) :: fn(frame: ptr[mut x86_64.RegisterFrame]) {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    vector :: frame.vector
    if vector == NMI_VECTOR {
        saved_limit :: cpu.carrier.stack_limit
        cpu.carrier.stack_limit = cpu.critical_stack_limits[cast[u8](arch_interface.CriticalEvent.Nmi)]
        intrinsics.set_carrier(cpu.carrier)
        push_context entry from cpu.context^ {
            registers :: u64.[frame.rax, frame.rbx, frame.rcx, frame.rdx, frame.rsi, frame.rdi, frame.rbp, frame.rsp, frame.r8, frame.r9,
                frame.r10, frame.r11, frame.r12, frame.r13, frame.r14, frame.r15, frame.rip, frame.rflags]
            kernel_entry.nmi(frame.rip, frame.rbp, registers[0..<registers.count])
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

/**
 * Enter the kernel from SYSCALL, from user mode, on the kernel stack the generated code switched to, with interrupts
 * disabled by IA32_FMASK.
 *
 * @param frame The user's registers as the generated code saved them, passed on as UserRegisters to
 *     kernel_entry.syscall, which never returns.
 */
system_call_entry #calling_convention(.syscall_entry) :: fn(frame: ptr[mut x86_64.RegisterFrame]) #never_returns {
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    cpu.carrier.stack_limit = cpu.kernel_stack_limit
    intrinsics.set_carrier(cpu.carrier)
    push_context entry from cpu.context^ {
        kernel_entry.syscall(cast[ptr[mut UserRegisters]](frame))
    }
}

/**
 * Tell whether the interrupted code ran in user mode, from the privilege level of its code segment.
 *
 * @param frame The interrupted code's registers.
 * @return True if cs's RPL is 3, user mode; false for the kernel, ring 0.
 */
from_user_mode :: fn(frame: ptr[x86_64.RegisterFrame]) -> bool {
    return (frame.cs & 3) == 3
}

/**
 * Decode a fault or an interrupt and hand it to kernel_entry, never returning.
 *
 * A fault from user mode goes to kernel_entry.user_fault, one from the kernel to kernel_entry.kernel_fault. An
 * interrupt from user mode goes to kernel_entry.interrupt with the user's registers; one taken in the kernel is taken
 * to be from idle, the only place the kernel takes interrupts.
 *
 * @param frame The interrupted code's registers, which become the thread's UserRegisters when it came from user mode.
 */
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

/**
 * Decode an exception into the portable fault it is.
 *
 * SPEC: Intel SDM Vol. 3A §7.15 (exception and interrupt reference).
 *
 * @param vector The exception's vector, below 32.
 * @param error_code The error code the CPU pushed, or 0 where it pushes none; only a page fault's is used.
 * @return Arithmetic for divide error and overflow, what decode_debug says for debug, Breakpoint, InvalidInstruction,
 *     FloatingPoint for device-not-available, x87 and SIMD errors, Page with what decode_page_fault says, Alignment,
 *     and Protection for every other vector, the segment and protection faults among them.
 */
decode_fault :: fn(vector: u64, error_code: u64) -> arch_interface.Fault {
    return match vector {
        case 0 => .Arithmetic
        case 1 => decode_debug()
        case 3 => .Breakpoint
        case 4 => .Arithmetic
        case 6 => .InvalidInstruction
        case 7 => .FloatingPoint
        case 14 => .Page(decode_page_fault(error_code))
        case 16 => .FloatingPoint
        case 17 => .Alignment
        case 19 => .FloatingPoint
        // Control protection: a missing endbr64 (3), or the shadow stack's (a return, 1 or 2, and the rest)
        case 21 => .ControlFlow(if error_code & 0x7fff == 3 { .LandingPad } else { .ShadowStack })
        // Bound range, the segment and protection faults, virtualization, and the vectors the CPU doesn't raise
        case _ => .Protection
    }
}

/**
 * Decode a page fault from its error code and CR2.
 *
 * SPEC: Intel SDM Vol. 3A §4.7, Figure 4-12 (page-fault error code): bit 0 present, bit 1 write, bit 4 instruction
 * fetch.
 *
 * @param error_code The page fault's error code.
 * @return The faulting virtual address, from CR2, which has to still be the fault's; the access, Execute for an
 *     instruction fetch, otherwise Write or Read; and whether a mapping was present.
 */
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
        // Bit 6 (SS): the shadow stack's own access
        shadow_stack = (error_code >> 6) & 1 == 1,
    }
}

/**
 * Decode an interrupt's source, acknowledging the local APIC's own.
 *
 * The timer and IPIs are acknowledged here; device interrupts are left for the kernel to acknowledge with
 * end_of_interrupt, and spurious interrupts aren't acknowledged at all (Intel SDM Vol. 3A §11.9).
 *
 * @param vector The interrupt's vector, 32 or above.
 * @return Device with the vector for device_interrupt_range's vectors, Timer, Ipi with its kind, or Spurious for
 *     SPURIOUS_VECTOR and any vector nothing raises.
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

/**
 * Point every vector at its entry point, kernel_entry_point's stub for it, on the IST stack it runs on.
 *
 * The NMI, double fault and machine check get their own stacks; every other vector runs on the kernel stack's slot.
 *
 * @param system The shared state whose 256 IDT entries are written.
 */
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

/**
 * Name a register of those an NMI passes kernel_entry.nmi (arch_interface.nmi_register_name).
 *
 * @param index Its place: rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8 to r15, rip, then rflags.
 * @return Its name, a constant; "?" past them.
 */
nmi_register_name :: fn(index: usize) -> string {
    return match index {
        case 0 => "rax"
        case 1 => "rbx"
        case 2 => "rcx"
        case 3 => "rdx"
        case 4 => "rsi"
        case 5 => "rdi"
        case 6 => "rbp"
        case 7 => "rsp"
        case 8 => "r8"
        case 9 => "r9"
        case 10 => "r10"
        case 11 => "r11"
        case 12 => "r12"
        case 13 => "r13"
        case 14 => "r14"
        case 15 => "r15"
        case 16 => "rip"
        case 17 => "rflags"
        case _ => "?"
    }
}
