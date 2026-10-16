/*
 * What the arch layer's entry stubs call (docs/specs/arch_interface.md, kernel_entry): the kernel's
 * side of every entry. Each one runs with the CPU's carrier block loaded and its context pushed.
 *
 * Not here yet: syscall and user_fault, which arrive from user mode through entry functions (M4 to M6).
 */
package kernel_entry

import runtime from "base"
import arch_interface from "../../arch_interface"
import text_buffer from "std"
import kernel from ".."

#if TARGET_ARCH == .x86_64 {
    import arch from "../../arch/x86_64"
}

//HEMERA(gap): a union variant can't hold a generic type like ptr[...] or a name from another
//package directly, so they go through aliases
UserRegistersPointer :: alias ptr[mut arch.UserRegisters]
IpiKind :: alias arch_interface.IpiKind
InterruptId :: alias arch_interface.InterruptId

Interrupted :: union {
    User(UserRegistersPointer),
    Idle,
}

InterruptSource :: union {
    Timer,
    Ipi(IpiKind),
    Device(InterruptId),
    Spurious,
}

// An interrupt from user mode or idle.
interrupt #never_returns :: fn(interrupted: Interrupted, source: InterruptSource) {
    match source {
        case Timer => kernel.handle_timer()
        case Spurious => arch.idle()
        case _ => {}
    }
    //TODO(claude): IPIs (M3), device interrupts (M3, M7) and interrupts from user mode (M6)
    runtime.log_error("an interrupt arrived that the kernel doesn't handle yet")
    arch.idle()
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
            what :: if page.present { " breaking the protection at " } else { " of nothing mapped at " }
            text_buffer.append(line, what)
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
