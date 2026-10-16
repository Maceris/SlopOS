package kernel

import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

// How often the timer interrupts while the kernel has nothing scheduled.
TICKS_PER_SECOND :: 100
// For now the kernel halts after this many timer interrupts (roadmap M1).
BOOT_TICKS :: 3

start_timer :: fn(kernel: ptr[mut Kernel], hint: u64?) {
    kernel.counter_frequency = arch.init_timer(hint)
    runtime.log_info("timer: counter at % kHz", kernel.counter_frequency / 1000)
    set_next_tick(kernel)
}

set_next_tick :: fn(kernel: ptr[Kernel]) {
    arch.set_deadline(arch.counter() + kernel.counter_frequency / TICKS_PER_SECOND)
}

// A timer interrupt, which arrives while the CPU is idle.
handle_timer :: fn() #never_returns {
    cpu :: per_cpu()
    cpu.timer_ticks += 1
    runtime.log_info("timer interrupt %", cpu.timer_ticks)
    if cpu.timer_ticks >= BOOT_TICKS {
        stop(.Halted)
    }
    set_next_tick(cpu.kernel)
    arch.idle()
}
