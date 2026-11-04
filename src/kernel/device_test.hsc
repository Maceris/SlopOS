package kernel

import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_ioapic: the emulator's test device (arch.test_device: QEMU's PIT on line 2 of its I/O APIC)
 * registered the way the platform service would, its line routed to the boot CPU and unmasked. Once
 * DEVICE_TEST_INTERRUPTS of its interrupts have arrived, it's stopped, its line masked again, and the kernel stops.
 * It waits for them up to DEVICE_TEST_TICKS of the boot CPU's ticks rather than the boot's few, so an emulator slowed
 * by its host still gets them in, and says how many came if they don't.
 */
/** How many of the test device's interrupts test_ioapic waits for before it stops the kernel. */
DEVICE_TEST_INTERRUPTS : u64 : 10
/** How many of the boot CPU's ticks test_ioapic waits for its interrupts, at most. */
DEVICE_TEST_TICKS : u64 : 200

/**
 * Start test_ioapic: register the test device's controller, route its line to the boot CPU for the kernel itself,
 * unmask it, and start the device's interrupts, the kernel to stop after DEVICE_TEST_TICKS ticks.
 *
 * A controller or route that can't be had is logged, and the test goes no further.
 *
 * @param kernel The kernel, whose test_controller and stop_after_ticks it sets; called on the boot CPU at boot.
 */
test_io_apic :: fn(kernel: ptr[mut Kernel]) {
    device :: arch.test_device()
    index := cast[u32](0)
    match register_controller(kernel, device.kind, device.registers) {
        case Ok(registered) => index = registered
        case Error(error) => {
            runtime.log_error("test_ioapic: the test device's controller couldn't be registered: %", error)
            return void
        }
    }
    match route_line(kernel, index, device.line, 0, device.trigger, device.polarity) {
        case Ok(id) => {}
        case Error(error) => {
            runtime.log_error("test_ioapic: the test device's line couldn't be routed: %", error)
            return void
        }
    }
    kernel.test_controller = index
    runtime.log_info("test_ioapic: a controller with % lines, line % routed to CPU 0", kernel.controllers[0].lines, device.line)
    unmask_line(kernel, index, device.line)
    kernel.stop_after_ticks = DEVICE_TEST_TICKS
    arch.test_device_interrupts(true)
}

/**
 * Count one of the test device's interrupts, from handle_device_interrupt with test_ioapic on; at the
 * DEVICE_TEST_INTERRUPTS-th, stop the device, mask its line again, and stop the kernel, halted.
 *
 * @param kernel The kernel, whose test_device_count it sets.
 * @param route The route the interrupt came through, its count already raised.
 */
test_device_interrupt :: fn(kernel: ptr[mut Kernel], route: ptr[DeviceRoute]) {
    kernel.test_device_count = route.count
    if route.count != DEVICE_TEST_INTERRUPTS {
        return void
    }
    arch.test_device_interrupts(false)
    mask_line(kernel, route.controller, route.line)
    runtime.log_info("test_ioapic: % interrupts arrived from the test device", DEVICE_TEST_INTERRUPTS)
    stop(.Halted)
}

/**
 * Log, at the boot CPU's last tick while test_ioapic runs, how many interrupts came, if not all of them did. Other
 * ticks, and runs without test_ioapic, do nothing.
 *
 * @param kernel The kernel, whose options, stop_after_ticks and test_device_count are read; called from the timer
 *     interrupt on the boot CPU.
 * @param tick The boot CPU's tick count, from 1.
 */
device_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    if !kernel.options.test_ioapic || tick != kernel.stop_after_ticks || kernel.test_device_count >= DEVICE_TEST_INTERRUPTS {
        return void
    }
    runtime.log_error("test_ioapic: only % of % interrupts arrived in % ticks", kernel.test_device_count, DEVICE_TEST_INTERRUPTS, tick)
}
