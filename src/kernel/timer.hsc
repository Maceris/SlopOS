package kernel

import intrinsics from "base"
import runtime from "base"
import robustness from "../robustness"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
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
    poll_dma_faults(kernel)
    device_test_tick(kernel, cpu.timer_ticks)
    root_task_ended(kernel, cpu.timer_ticks)
    if cpu.timer_ticks >= kernel.stop_after_ticks {
        // A root task that didn't start left nothing behind, as one that ended doesn't (decisions/0104)
        #if robustness.ON {
            if kernel.root_task == 0 && kernel.modules.count > 0 {
                log_objects_left(kernel)
            }
        }
        stop(.Halted)
    }
    return true
}

// Ticks between the root task's end and the kernel's: the grace period for what it owned to be freed.
ROOT_END_TICKS : u64 : 20

/*
 * At each of the boot CPU's ticks: once the root task has ended, and ROOT_END_TICKS have passed, the objects
 * left, which should be only the kernel's own, then the stop (decisions/0069).
 */
root_task_ended :: fn(kernel: ptr[mut Kernel], tick: u64) {
    state :: intrinsics.atomic_load_u32_acquire(&kernel.root_ended)
    if state == 1 {
        kernel.root_stop_tick = tick + ROOT_END_TICKS
        intrinsics.atomic_store_u32_release(&kernel.root_ended, 2)
        return void
    }
    if state != 2 || tick < kernel.root_stop_tick {
        return void
    }
    log_objects_left(kernel)
    stop(.RootTaskEnded)
}
