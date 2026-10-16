package kernel

import intrinsics from "base"
import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Why the kernel stopped. With test_exit on the command line, this is the code the emulator exits
 * with, so a test that boots the kernel can check it (tools/boot.py --expect).
 */
StopReason :: enum #backed_by(u8) {
    // Booted, handled BOOT_TICKS timer interrupts, and halted: everything worked.
    Halted = 0,
    KernelFault = 1,
    CpuUnsupported = 2,
    AssertionFailed = 3,
    CriticalEvent = 4,
    // The boot adapter couldn't build BootInfo.
    BootFailed = 5,
    // Too little memory to boot.
    OutOfMemory = 6,
}

// Stop the kernel for good: every other CPU, then the calling one.
stop :: fn(reason: StopReason) #never_returns {
    if intrinsics.carrier().program_data == null {
        arch.halt()
    }
    kernel :: per_cpu().kernel
    stop_other_cpus(kernel)
    stop_with(&kernel.options, reason)
}

stop_with :: fn(options: ptr[Options], reason: StopReason) #never_returns {
    runtime.log_info("halting")
    if options.test_exit {
        arch.test_exit(cast[u32](reason))
    }
    arch.halt()
}

/*
 * For the boot adapter, when it can't build BootInfo: report why, and stop. It has the command line,
 * if the bootloader passed one, but nothing else of the kernel's yet.
 */
boot_failed :: fn(command_line: string, message: string) #never_returns {
    runtime.log_fatal(message)
    options :: parse_command_line(command_line)
    stop_with(&options, .BootFailed)
}
