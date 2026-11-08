package kernel

import intrinsics from "base"
import runtime from "base"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Turning the machine off and restarting it (decisions/0182). The platform capability's holders tell the kernel what
 * the firmware knows (power_set_off, power_set_reset) and what to do once the root task ends (power_end_with); the
 * kernel does it in its stop, after every other CPU has stopped and the objects left are logged. Each setting is one
 * atomic word, so a call on any CPU replaces it whole, and the stop, on one CPU alone, reads it whole.
 */

/** In PowerSettings.off: set once power_set_off has given the registers. */
OFF_SET : u64 : 1 << 63
/** In PowerSettings.reset: set once power_set_reset has given the register. */
RESET_SET : u64 : 1 << 63
/** PM1's control register's SLP_TYP field, bits 10 to 12. */
SLEEP_TYPE_MASK : u32 : 0x1c00
/** PM1's control register's SLP_EN bit, which starts the sleep SLP_TYP names. */
SLEEP_ENABLE : u32 : 0x2000

/** How the machine turns off and resets, as the firmware says, and what the root task's end does. */
PowerSettings :: struct {
    /**
     * x86-64's S5, OFF_SET once given, 0 before: PM1a's control port in bits 0 to 15, PM1b's in 16 to 31 (0 for none),
     * PM1a's sleep type in 32 to 34 and PM1b's in 35 to 37. Written and read atomically.
     */
    off : u64,
    /** The reset register, RESET_SET once given, 0 before: its port in bits 0 to 15, its value in 16 to 23. Atomic. */
    reset : u64,
    /** What the root task's end does: a slop_os.PowerAction's value, 0 while none's been asked (as Halt). Atomic. */
    end_with : u32,
}

/**
 * Tell whether the kernel can turn the machine off now.
 *
 * @param kernel The kernel, whose reset_method and power.off are read.
 * @return True if the architecture turns it off by itself (PSCI) or power_set_off has said how.
 */
can_turn_off :: fn(kernel: ptr[Kernel]) -> bool {
    return arch.can_power_off(kernel.reset_method) || intrinsics.atomic_load_u64_acquire(&kernel.power.off) & OFF_SET != 0
}

/**
 * Keep how the machine turns off, replacing what was kept.
 *
 * @param kernel The kernel, whose power.off is written.
 * @param control_a PM1a's control port, 1 to 65535.
 * @param control_b PM1b's control port, 1 to 65535, or 0 for none.
 * @param sleep_a PM1a's sleep type for S5, 0 to 7.
 * @param sleep_b PM1b's sleep type for S5, 0 to 7.
 * @error InvalidArgument A value out of its range, or an architecture without I/O ports or that turns off by itself.
 */
set_power_off :: fn(kernel: ptr[mut Kernel], control_a: u32, control_b: u32, sleep_a: u32, sleep_b: u32) -> Result[void, slop_os.DeviceError] {
    if !arch.has_io_ports() || arch.can_power_off(kernel.reset_method) {
        return .Error(.InvalidArgument)
    }
    if control_a == 0 || control_a > 0xffff || control_b > 0xffff || sleep_a > 7 || sleep_b > 7 {
        return .Error(.InvalidArgument)
    }
    word :: OFF_SET | cast[u64](control_a) | (cast[u64](control_b) << 16) | (cast[u64](sleep_a) << 32) | (cast[u64](sleep_b) << 35)
    intrinsics.atomic_store_u64_release(&kernel.power.off, word)
    return .Ok
}

/**
 * Keep how the machine resets, replacing what was kept.
 *
 * @param kernel The kernel, whose power.reset is written.
 * @param port The reset register's I/O port, 1 to 65535.
 * @param value The byte that resets, 0 to 255.
 * @error InvalidArgument A value out of its range, or an architecture without I/O ports.
 */
set_power_reset :: fn(kernel: ptr[mut Kernel], port: u32, value: u32) -> Result[void, slop_os.DeviceError] {
    if !arch.has_io_ports() || port == 0 || port > 0xffff || value > 0xff {
        return .Error(.InvalidArgument)
    }
    intrinsics.atomic_store_u64_release(&kernel.power.reset, RESET_SET | cast[u64](port) | (cast[u64](value) << 16))
    return .Ok
}

/**
 * Keep what the root task's end does, replacing what was asked.
 *
 * @param kernel The kernel, whose power.end_with is written.
 * @param action A slop_os.PowerAction's value, 1 to 3.
 * @error InvalidArgument A value that isn't one of PowerAction's.
 * @error NoPowerOff Off, when can_turn_off says the kernel can't.
 */
set_power_end :: fn(kernel: ptr[mut Kernel], action: u32) -> Result[void, slop_os.DeviceError] {
    if action < cast[u32](slop_os.PowerAction.Halt) || action > cast[u32](slop_os.PowerAction.Restart) {
        return .Error(.InvalidArgument)
    }
    if action == cast[u32](slop_os.PowerAction.Off) && !can_turn_off(kernel) {
        return .Error(.NoPowerOff)
    }
    intrinsics.atomic_store_u32_release(&kernel.power.end_with, action)
    return .Ok
}

/**
 * Reset the machine: through the reset register power_set_reset gave, if any, then the architecture's own way.
 *
 * Called by stop alone, on one CPU, the others stopped. Returns only if the machine didn't reset.
 *
 * @param kernel The kernel, whose power.reset and reset_method are read.
 */
reset_machine :: fn(kernel: ptr[Kernel]) {
    reset :: intrinsics.atomic_load_u64_acquire(&kernel.power.reset)
    if reset & RESET_SET != 0 {
        _ = arch.port_write(cast[u16](reset & 0xffff), 1, cast[u32]((reset >> 16) & 0xff))
    }
    arch.reset(kernel.reset_method)
}

/**
 * Turn the machine off: by S5 through the PM1 control registers power_set_off gave, if any, else the architecture's
 * own way. Each register is read, its SLP_TYP replaced and SLP_EN set, keeping its other bits (SCI_EN among them).
 *
 * Called by stop alone, on one CPU, the others stopped. Returns only if the machine didn't turn off.
 *
 * @param kernel The kernel, whose power.off and reset_method are read.
 */
turn_off :: fn(kernel: ptr[Kernel]) {
    off :: intrinsics.atomic_load_u64_acquire(&kernel.power.off)
    if off & OFF_SET == 0 {
        arch.power_off(kernel.reset_method)
        return void
    }
    control_a :: cast[u16](off & 0xffff)
    control_b :: cast[u16]((off >> 16) & 0xffff)
    sleep_a :: cast[u32]((off >> 32) & 7)
    sleep_b :: cast[u32]((off >> 35) & 7)
    // PM1b first, where there is one, so PM1a's write, which QEMU and most chipsets act on, comes last
    if control_b != 0 {
        value_b :: arch.port_read(control_b, 2) or_else 0
        _ = arch.port_write(control_b, 2, (value_b & ~(SLEEP_TYPE_MASK | SLEEP_ENABLE)) | (sleep_b << 10) | SLEEP_ENABLE)
    }
    value_a :: arch.port_read(control_a, 2) or_else 0
    _ = arch.port_write(control_a, 2, (value_a & ~(SLEEP_TYPE_MASK | SLEEP_ENABLE)) | (sleep_a << 10) | SLEEP_ENABLE)
}

/**
 * Do what power_end_with asked for the root task's end: turn the machine off or reset it. Nothing for Halt, or when
 * nothing was asked; nothing under test_exit without test_power, so the emulator's asked to exit with the reason.
 *
 * Called by stop for RootTaskEnded, on one CPU, the others stopped. Returns if nothing was to be done, or if the
 * machine didn't turn off or reset, which it logs.
 *
 * @param kernel The kernel, whose power settings and options are read.
 */
end_power :: fn(kernel: ptr[Kernel]) {
    action :: intrinsics.atomic_load_u32_acquire(&kernel.power.end_with)
    if action == 0 || action == cast[u32](slop_os.PowerAction.Halt) {
        return void
    }
    if kernel.options.test_exit && !kernel.options.test_power {
        return void
    }
    if action == cast[u32](slop_os.PowerAction.Off) {
        runtime.log_info("turning the machine off")
        turn_off(kernel)
        runtime.log_error("the machine didn't turn off")
        return void
    }
    runtime.log_info("restarting the machine")
    reset_machine(kernel)
    runtime.log_error("the machine didn't restart")
}
