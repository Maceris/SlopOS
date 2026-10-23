/*
 * What the arch layer's entry stubs call (docs/specs/arch_interface.md, kernel_entry): the kernel's
 * side of every entry. Each one runs with the CPU's carrier block loaded and its context pushed.
 *
 * There's no user mode yet (M4 to M6), so syscall and user_fault, which only come from it, stop the
 * kernel.
 */
package kernel_entry

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../../arch_interface"
import text_buffer from "std"
import kernel from ".."

#if TARGET_ARCH == .x86_64 {
    import arch from "../../arch/x86_64"
}

Interrupted :: union {
    User(ptr[mut arch.UserRegisters]),
    Idle,
}

InterruptSource :: union {
    Timer,
    Ipi(arch_interface.IpiKind),
    Device(arch_interface.InterruptId),
    Spurious,
}

// A system call from user mode.
//TODO(claude): system calls (M5)
syscall #never_returns :: fn(registers: ptr[mut arch.UserRegisters]) {
    runtime.log_fatal("a system call arrived, and the kernel doesn't take system calls yet")
    kernel.stop(.KernelFault)
}

// A fault in user mode.
//TODO(claude): faults in user threads (M4 to M6)
user_fault #never_returns :: fn(registers: ptr[mut arch.UserRegisters], fault: arch_interface.Fault) {
    runtime.log_fatal("a fault arrived from user mode, which the kernel doesn't run yet")
    kernel.stop(.KernelFault)
}

/*
 * An interrupt from user mode or idle. What it interrupted in user mode is kept in the CPU's current
 * thread; then the scheduler picks what runs next: at a tick, the next thread round robin, otherwise a
 * thread that should run before the current one, or the current one again.
 */
interrupt #never_returns :: fn(from: Interrupted, source: InterruptSource) {
    kernel.left_boot_stack()
    match from {
        case User(registers) => kernel.save_user_registers(registers)
        case Idle => {}
    }
    match source {
        case Timer => {
            kernel.handle_timer()
            kernel.schedule(true)
        }
        case Ipi(kind) => {
            if kind == .Stop {
                arch.halt()
            }
            if kind == .TlbFlush {
                kernel.flush_for_shootdown(kernel.per_cpu())
            }
            if kind == .Reschedule {
                kernel.read_for_shootdown_test()
            }
        }
        case Device(id) => kernel.handle_device_interrupt(id)
        case Spurious => {}
    }
    kernel.schedule(false)
}

// A fault in kernel code, which is a bug. The kernel stops, with a stack trace.
kernel_fault #never_returns :: fn(fault: arch_interface.Fault, instruction_pointer: arch_interface.VirtualAddress) {
    storage : u8[160]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "kernel fault: ")
    append_fault(&line, fault)
    text_buffer.append(&line, " at ")
    text_buffer.append_address(&line, cast[u64](instruction_pointer))
    runtime.log_fatal(text_buffer.as_string(&line))
    // From the arch layer's entry, through the interrupted code's callers
    kernel.log_stack_trace()
    kernel.stop(.KernelFault)
}

append_fault :: fn(line: ptr[mut text_buffer.TextBuffer], fault: arch_interface.Fault) {
    match fault {
        case Page(page) => {
            text_buffer.append(line, "page fault, ")
            text_buffer.append(line, access_name(page.access))
            text_buffer.append(line, if page.present { " breaking the protection at " } else { " of nothing mapped at " })
            text_buffer.append_address(line, cast[u64](page.address))
        }
        case InvalidInstruction => text_buffer.append(line, "invalid instruction")
        case Breakpoint => text_buffer.append(line, "breakpoint")
        case SingleStep => text_buffer.append(line, "single step")
        case Arithmetic => text_buffer.append(line, "arithmetic error")
        case Alignment => text_buffer.append(line, "misaligned access")
        case Protection => text_buffer.append(line, "protection fault")
        case FloatingPoint => text_buffer.append(line, "floating-point error")
    }
}

access_name :: fn(access: arch_interface.Access) -> string {
    return match access {
        case .Read => "read"
        case .Write => "write"
        case .Execute => "execute"
    }
}

// An NMI, at any time. Returns to the interrupted code.
nmi :: fn() {
    cpu :: kernel.per_cpu()
    intrinsics.atomic_store_u32_release(&cpu.nmi_count, cpu.nmi_count + 1)
    runtime.log_warn("NMI")
}

// A machine check or double fault, at any time. The kernel stops.
fatal_critical #never_returns :: fn(event: arch_interface.CriticalEvent) {
    runtime.log_fatal(match event {
        case .Nmi => "NMI"
        case .DoubleFault => "double fault"
        case .MachineCheck => "machine check"
    })
    kernel.stop(.CriticalEvent)
}
