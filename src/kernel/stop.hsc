package kernel

import intrinsics from "base"
import runtime from "base"
import robustness from "../robustness"
import boot_info from "../boot_info"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/**
 * Why the kernel stopped.
 *
 * With test_exit on the command line, its value is the code the emulator exits with, so a test that boots the kernel
 * can check it (tools/boot.py --expect). A fault's reason is also sealed in the panic record, for the next boot.
 */
StopReason :: enum #backed_by(u8) {
    /** Booted, handled BOOT_TICKS timer interrupts, and halted: everything worked. */
    Halted = 0,
    /** Kernel code faulted (kernel_entry's kernel_fault): a bug in the kernel, reported with a stack trace. */
    KernelFault = 1,
    /** The boot CPU lacks part of the baseline the kernel needs (decisions/0003). */
    CpuUnsupported = 2,
    /** An assertion failed in kernel code (kernel_assertion_handler). */
    AssertionFailed = 3,
    /** A machine check or double fault (kernel_entry's fatal_critical). */
    CriticalEvent = 4,
    /** The boot adapter couldn't build BootInfo. */
    BootFailed = 5,
    /** Too little memory to boot, or none for something the kernel can't go on without (out_of_memory). */
    OutOfMemory = 6,
    /**
     * The root task ended, which a working system's never does (decisions/0012); the kernel stops a few ticks later,
     * once it has logged the objects left.
     */
    RootTaskEnded = 7,
    /**
     * A CPU made no progress for LOCKUP_SECONDS, not being idle, as one spinning with interrupts off would
     * (lockups.hsc, decisions/0183).
     */
    Lockup = 8,
}

/**
 * Stop the kernel for good: every other CPU, then the calling one.
 *
 * Callable from any context on any CPU, interrupts on or off. Before this CPU has the kernel's state (its carrier's
 * program_data is null) it just halts the calling CPU. Otherwise it sends a Stop IPI to every other online CPU, logs
 * the fault injection report, and, for any reason but Halted and RootTaskEnded, seals the panic record with the reason
 * (decisions/0134) and, with panic_reset on the command line, resets the machine so the next boot keeps it. For
 * RootTaskEnded it turns the machine off or restarts it, if the root task asked (power_end_with, decisions/0182). Then
 * it stops as stop_with does.
 *
 * @param reason Why the kernel stopped: the code given to the emulator with test_exit, and the reason sealed in the
 *     panic record for a fault.
 */
stop :: fn(reason: StopReason) #never_returns {
    if intrinsics.carrier().program_data == null {
        arch.halt()
    }
    kernel :: per_cpu().kernel
    stop_other_cpus(kernel)
    robustness.report(&kernel.frames.faults)
    // A fault's record sealed for the next boot (decisions/0134), which a reset keeps it for
    fault :: reason != .Halted && reason != .RootTaskEnded
    if fault && kernel.panic_record != 0 {
        boot_info.panic_record_seal(cast[ptr[mut boot_info.PanicRecord]](kernel.panic_record), cast[u64](reason))
        if kernel.options.panic_reset {
            runtime.log_info("resetting, the panic record kept")
            reset_machine(kernel)
        }
    }
    if reason == .RootTaskEnded {
        end_power(kernel)
    }
    stop_with(&kernel.options, reason)
}

/**
 * Log that the kernel is halting, and halt the calling CPU; with test_exit, ask the emulator to exit first.
 *
 * Other CPUs aren't touched: stop stops them first, and the other callers run before any has started.
 *
 * @param options The command line's options, of which only test_exit is read.
 * @param reason The code the emulator exits with, under test_exit.
 */
stop_with :: fn(options: ptr[Options], reason: StopReason) #never_returns {
    runtime.log_info("halting")
    if options.test_exit {
        arch.test_exit(cast[u32](reason))
    }
    arch.halt()
}

/**
 * Report why booting failed, and stop with BootFailed: for the boot adapter, when it can't build BootInfo.
 *
 * It runs before the kernel has any state of its own, on the boot CPU alone, so it parses the command line itself
 * for test_exit.
 *
 * @param command_line The command line the bootloader passed, or empty if it passed none.
 * @param message Why booting failed, logged as a fatal line.
 */
boot_failed :: fn(command_line: string, message: string) #never_returns {
    runtime.log_fatal(message)
    options :: parse_command_line(command_line)
    stop_with(&options, .BootFailed)
}
