package kernel

import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

// How often every CPU's timer interrupts: the scheduler's tick.
TICKS_PER_SECOND :: 100
// For now the kernel halts after this many of the boot CPU's ticks, or a test's own number (Kernel.stop_after_ticks).
BOOT_TICKS : u64 : 3

start_timer :: fn(kernel: ptr[mut Kernel], hint: u64?) {
    kernel.counter_frequency = arch.init_timer(hint)
    start_clock(kernel)
    runtime.log_info("timer: counter at % kHz", kernel.counter_frequency / 1000)
    set_next_tick(kernel)
}

// The calling CPU's next tick, a tick from now.
set_next_tick :: fn(kernel: ptr[Kernel]) {
    cpu :: per_cpu()
    cpu.next_tick = arch.counter() + kernel.counter_frequency / TICKS_PER_SECOND
    program_deadline(cpu)
}

/*
 * A timer interrupt, from idle or user mode, on any CPU: the deadlines that came due fire, and if it's
 * time for one, a tick, which is whether the scheduler should round-robin. The boot CPU counts ticks for
 * when the kernel stops.
 */
handle_timer :: fn() -> bool {
    cpu :: per_cpu()
    kernel :: cpu.kernel
    now :: arch.counter()
    fire_timers(kernel, now)
    period :: kernel.counter_frequency / TICKS_PER_SECOND
    tick :: now >= cpu.next_tick
    if tick {
        cpu.timer_ticks += 1
        // From when it was due, unless that's fallen a whole tick behind
        cpu.next_tick = if cpu.next_tick + period > now { cpu.next_tick + period } else { now + period }
    }
    program_deadline(cpu)
    if !tick || cpu.index != 0 {
        return tick
    }
    if cpu.timer_ticks <= BOOT_TICKS {
        runtime.log_info("timer interrupt %", cpu.timer_ticks)
    }
    threads_test_tick(kernel, cpu.timer_ticks)
    syscalls_test_tick(kernel, cpu.timer_ticks)
    ports_test_tick(kernel, cpu.timer_ticks)
    channels_test_tick(kernel, cpu.timer_ticks)
    memory_test_tick(kernel, cpu.timer_ticks)
    if cpu.timer_ticks >= kernel.stop_after_ticks {
        stop(.Halted)
    }
    return true
}
