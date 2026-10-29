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
DEVICE_TEST_INTERRUPTS : u64 : 10
DEVICE_TEST_TICKS : u64 : 200

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

// After each of the test device's interrupts.
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

// At the boot CPU's last tick while test_ioapic runs: how many came, if not all of them.
device_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    if !kernel.options.test_ioapic || tick != kernel.stop_after_ticks || kernel.test_device_count >= DEVICE_TEST_INTERRUPTS {
        return void
    }
    runtime.log_error("test_ioapic: only % of % interrupts arrived in % ticks", kernel.test_device_count, DEVICE_TEST_INTERRUPTS, tick)
}
