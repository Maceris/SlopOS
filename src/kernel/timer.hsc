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

/** How many ticks every CPU has a second, unless it idles without ticking: the scheduler's round-robin period. */
TICKS_PER_SECOND :: 100
/**
 * How many of the boot CPU's ticks the kernel runs before it halts, when no root task starts and no test sets its own
 * number (Kernel.stop_after_ticks); the first this many ticks are also logged.
 */
BOOT_TICKS : u64 : 3

/**
 * Start the boot CPU's timer and the kernel's clock, and arm the first tick.
 *
 * Called once, on the boot CPU, before the other CPUs start; each of those sets its own timer up (cpu_started).
 *
 * @param kernel The kernel, whose counter_frequency is set to the counter's, in Hz, and whose clock starts now.
 * @param hint The counter's frequency in Hz as the bootloader measured it, or null if it didn't, when it's found or
 *     measured here (arch.init_timer), which can busy-wait some milliseconds.
 */
start_timer :: fn(kernel: ptr[mut Kernel], hint: u64?) {
    kernel.counter_frequency = arch.init_timer(hint)
    start_clock(kernel)
    runtime.log_info("timer: counter at % kHz", kernel.counter_frequency / 1000)
    set_next_tick(kernel)
}

/**
 * Set the calling CPU's next tick to a tick from now, and program its timer for it or an earlier deadline.
 *
 * @param kernel The kernel, whose counter_frequency must be set.
 */
set_next_tick :: fn(kernel: ptr[Kernel]) {
    cpu :: per_cpu()
    cpu.next_tick = arch.counter() + kernel.counter_frequency / TICKS_PER_SECOND
    program_deadline(cpu)
}

/**
 * Handle a timer interrupt, from idle or user mode, on any CPU: fire the deadlines that came due, and count a tick if
 * one is due.
 *
 * The next tick is a period after the one due, unless that has fallen a whole period behind, when it's a period from
 * now; the CPU's timer is then programmed for it or its earliest deadline. At the boot CPU's ticks, it also polls for
 * DMA faults, runs the tests' tick hooks, checks for the root task's end, and stops the kernel (Halted) once
 * stop_after_ticks ticks have passed. Runs with interrupts off.
 *
 * @return Whether this was a tick, so the scheduler should round-robin; false when only deadlines were due. It doesn't
 *     return if the kernel stops.
 */
handle_timer :: fn() -> bool {
    cpu :: per_cpu()
    kernel :: cpu.kernel
    now :: arch.counter()
    cpu.timer_interrupts += 1
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
    tickless_test_tick(kernel, cpu.timer_ticks)
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

/** The boot CPU's ticks between the root task's end and the kernel's: the grace period for what it owned to go. */
ROOT_END_TICKS : u64 : 20

/**
 * Stop the kernel once the root task has ended and ROOT_END_TICKS have passed, logging the objects left, which should
 * be only the kernel's own (decisions/0069).
 *
 * Called at each of the boot CPU's ticks. kernel.root_ended goes from 1, set when the root task's process is destroyed
 * (processes.hsc), to 2 here, when the stop tick is set; until it's 1, this does nothing.
 *
 * @param kernel The kernel, whose root_ended and root_stop_tick it reads and sets.
 * @param tick The boot CPU's tick count, from 1.
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
