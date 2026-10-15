package kernel

import runtime from "base"
import text_buffer from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

// How often the timer interrupts while the kernel has nothing scheduled.
TICKS_PER_SECOND :: 100
// For now the kernel halts after this many timer interrupts (roadmap M1).
BOOT_TICKS :: 3

start_timer :: fn(kernel: ptr[mut Kernel], hint: u64?) {
    kernel.counter_frequency = arch.init_timer(hint)
    storage : u8[96]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "timer: counter at ")
    text_buffer.append_unsigned(&line, kernel.counter_frequency / 1000)
    text_buffer.append(&line, " kHz")
    runtime.log_info(text_buffer.as_string(&line))
    set_next_tick(kernel)
}

set_next_tick :: fn(kernel: ptr[Kernel]) {
    arch.set_deadline(arch.counter() + kernel.counter_frequency / TICKS_PER_SECOND)
}

// A timer interrupt, which arrives while the CPU is idle.
handle_timer :: fn() #never_returns {
    cpu :: per_cpu()
    cpu.timer_ticks += 1
    storage : u8[64]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "timer interrupt ")
    text_buffer.append_unsigned(&line, cpu.timer_ticks)
    runtime.log_info(text_buffer.as_string(&line))
    if cpu.timer_ticks >= BOOT_TICKS {
        stop(.Halted)
    }
    set_next_tick(cpu.kernel)
    arch.idle()
}
