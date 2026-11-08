/**
 * What the arch layer's entry stubs call (docs/specs/arch_interface.md, kernel_entry): the kernel's
 * side of every entry. Each one runs with the CPU's carrier block loaded and its context pushed.
 *
 * syscall and user_fault come from user mode: a system call (syscalls.hsc), and a fault, which fills in
 * memory a thread maps or stops the thread (memory.hsc).
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
#else_if TARGET_ARCH == .arm64 {
    import arch from "../../arch/aarch64"
}

/** What an interrupt interrupted: the kernel itself never is, as it runs with interrupts disabled. */
Interrupted :: union {
    /**
     * A thread in user mode: its registers, which the entry stub saved on this CPU's kernel stack, good until the
     * entry leaves.
     */
    User(ptr[mut arch.UserRegisters]),
    /** The CPU's idle loop, with no thread. */
    Idle,
}

/** What raised an interrupt, as the entry stub decoded it. */
InterruptSource :: union {
    /** The CPU's timer: a deadline came due. */
    Timer,
    /** An inter-processor interrupt from another CPU, of the kind given. */
    Ipi(arch_interface.IpiKind),
    /** A device interrupt, by its ID, which should be in arch.device_interrupt_range. */
    Device(arch_interface.InterruptId),
    /** An interrupt the controller reported but nothing raised; nothing is done for it. */
    Spurious,
}

/**
 * Handle a system call from user mode, by the CPU's current thread; the scheduler picks what runs next.
 *
 * Runs on the CPU's kernel stack, interrupts disabled. The first entry on a CPU notes it has left its boot stack.
 *
 * @param registers The user registers the entry stub saved on this CPU's kernel stack, the call's number and
 *     arguments among them; copied into the thread.
 */
syscall #never_returns :: fn(registers: ptr[mut arch.UserRegisters]) {
    arch.debug_off()
    kernel.left_boot_stack()
    kernel.handle_syscall(registers)
}

/**
 * Handle a fault in user mode, by the CPU's current thread; the scheduler picks what runs next.
 *
 * A page fault in mapped memory is resolved, filling the page in or waiting for its pager; any other fault stops the
 * thread for its debugger, or destroys it (handle_user_fault). Runs on the CPU's kernel stack, interrupts disabled.
 *
 * @param registers The user registers the entry stub saved on this CPU's kernel stack; copied into the thread.
 * @param fault What faulted: for a page fault, its address and access.
 */
//TODO(claude): faults in user threads (M4 to M6)
user_fault #never_returns :: fn(registers: ptr[mut arch.UserRegisters], fault: arch_interface.Fault) {
    arch.debug_off()
    kernel.left_boot_stack()
    kernel.handle_user_fault(registers, fault)
}

/**
 * Handle an interrupt from user mode or idle; the scheduler then picks what runs next.
 *
 * What it interrupted in user mode is kept in the CPU's current thread; a CPU leaving idle records the epoch first
 * (decisions/0128). Then: a timer interrupt fires the deadlines due, and at a tick the next thread runs round robin;
 * a Stop IPI halts this CPU for good; a TlbFlush IPI flushes for the shootdown waiting on this CPU; a Reschedule IPI
 * only brings the CPU here (and serves test_shootdown, test_binding_reuse and test_ownership_race); a device interrupt
 * is routed
 * (handle_device_interrupt).
 * Otherwise a thread that should run before the current one runs, or the current one goes on. Runs on the CPU's
 * kernel stack, interrupts disabled.
 *
 * @param from What was interrupted: a user thread, with its saved registers, or idle.
 * @param source What raised the interrupt.
 */
interrupt #never_returns :: fn(from: Interrupted, source: InterruptSource) {
    kernel.left_boot_stack()
    match from {
        case User(registers) => {
            arch.debug_off()
            kernel.save_user_registers(registers)
        }
        // One idle without ticking records the epoch first (decisions/0128)
        case Idle => kernel.leave_idle()
    }
    match source {
        case Timer => kernel.schedule(kernel.handle_timer())
        case Ipi(kind) => {
            if kind == .Stop {
                arch.halt()
            }
            if kind == .TlbFlush {
                kernel.flush_for_shootdown(kernel.per_cpu())
            }
            if kind == .Reschedule {
                kernel.read_for_shootdown_test()
                kernel.read_for_binding_reuse_test()
                kernel.move_for_ownership_race_test()
            }
        }
        case Device(id) => kernel.handle_device_interrupt(id)
        case Spurious => {}
    }
    kernel.schedule(false)
}

/**
 * Report a fault in kernel code, which is a bug, and stop every CPU with KernelFault.
 *
 * Logs a fatal line saying what faulted and where, then a stack trace from the arch layer's entry through the
 * interrupted code's callers.
 *
 * @param fault What faulted: for a page fault, the address and access, and whether a mapping was there.
 * @param instruction_pointer The virtual address of the faulting instruction, in the kernel image.
 */
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

/**
 * Describe a fault in a log line, as "page fault, write of nothing mapped at <address>" or "invalid instruction".
 *
 * @param line The line being built; truncated, as a text buffer is, if it's full.
 * @param fault The fault, as the entry stub decoded it: for a page fault, its access, address and whether a mapping
 *     was there, all written; for any other kind, its name alone.
 */
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
        case Watchpoint(address) => {
            text_buffer.append(line, "watchpoint at ")
            text_buffer.append_address(line, address)
        }
        case Protection => text_buffer.append(line, "protection fault")
        case FloatingPoint => text_buffer.append(line, "floating-point error")
    }
}

/**
 * Name a page fault's access, for the log.
 *
 * @param access The kind of access that faulted.
 * @return A constant name: "read", "write" or "execute".
 */
access_name :: fn(access: arch_interface.Access) -> string {
    return match access {
        case .Read => "read"
        case .Write => "write"
        case .Execute => "execute"
    }
}

/**
 * Handle an NMI, which can arrive at any time, kernel code included; returns to the interrupted code.
 *
 * Counts it in the CPU's nmi_count (for test_nmi), and notes where it interrupted if a lockup's report asked
 * (kernel.note_lockup); nothing else: an NMI can interrupt this CPU while it holds any lock, the console's included, so
 * it takes none, and doesn't log.
 *
 * @param pc The interrupted program counter.
 */
nmi :: fn(pc: u64) {
    cpu :: kernel.per_cpu()
    intrinsics.atomic_store_u32_release(&cpu.nmi_count, cpu.nmi_count + 1)
    kernel.note_lockup(cpu.kernel, cpu, pc)
}

/**
 * Report a critical event, which can arrive at any time, and stop every CPU with CriticalEvent.
 *
 * Unlike kernel_fault, no stack trace is logged.
 *
 * @param event The event: a machine check or a double fault; the arch layer sends NMIs to nmi instead.
 */
fatal_critical #never_returns :: fn(event: arch_interface.CriticalEvent) {
    runtime.log_fatal(match event {
        case .Nmi => "NMI"
        case .DoubleFault => "double fault"
        case .MachineCheck => "machine check"
    })
    kernel.stop(.CriticalEvent)
}
