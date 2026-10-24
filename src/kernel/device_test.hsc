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
 * DEVICE_TEST_INTERRUPTS of its interrupts have arrived, it's stopped and its line masked again.
 */
DEVICE_TEST_INTERRUPTS : u64 : 10

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
    arch.test_device_interrupts(true)
}

// After each of the test device's interrupts.
test_device_interrupt :: fn(kernel: ptr[mut Kernel], route: ptr[DeviceRoute]) {
    if route.count != DEVICE_TEST_INTERRUPTS {
        return void
    }
    arch.test_device_interrupts(false)
    mask_line(kernel, route.controller, route.line)
    runtime.log_info("test_ioapic: % interrupts arrived from the test device", DEVICE_TEST_INTERRUPTS)
}
