package kernel

import runtime from "base"
import testing from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_ioapic: the emulator's test device (arch.test_device: QEMU's PIT on line 2 of its I/O APIC)
 * registered the way the platform service would, its line routed to the boot CPU and unmasked, a test run at boot.
 * Once DEVICE_TEST_INTERRUPTS of its interrupts have arrived, it's stopped, its line masked again, and the kernel stops,
 * a second test run then saying they came. It waits for them up to DEVICE_TEST_TICKS of the boot CPU's ticks rather
 * than the boot's few, so an emulator slowed by its host still gets them in; if they don't all come, the second test is
 * run at the last of those ticks, and fails saying how many did.
 */
/** How many of the test device's interrupts test_ioapic waits for before it stops the kernel. */
DEVICE_TEST_INTERRUPTS : u64 : 10
/** How many of the boot CPU's ticks test_ioapic waits for its interrupts, at most. */
DEVICE_TEST_TICKS : u64 : 200

/**
 * Start test_ioapic, running its first test, which routes the test device's line to the boot CPU and starts its
 * interrupts, reporting it to the kernel's log.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu. Called on the boot CPU at boot.
 */
test_io_apic :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_ioapic", testing.Test.[.{name = "the_test_device_is_routed_to_the_boot_cpu", run = the_test_device_is_routed_to_the_boot_cpu}])
}

/**
 * Register the test device's controller, route its line to the boot CPU for the kernel itself, unmask it, and start
 * the device's interrupts, the kernel to stop after DEVICE_TEST_TICKS ticks.
 *
 * @param t The test's state.
 * @return Ok once the device's interrupts are started, kernel.test_controller and stop_after_ticks set; Error if its
 *     controller couldn't be registered or its line routed, when nothing is started.
 */
the_test_device_is_routed_to_the_boot_cpu #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    device :: arch.test_device()
    registered :: register_controller(kernel, device.kind, device.registers)
    index :: testing.require_ok(t, registered, "the test device's controller is free, so it registers as the platform service's would")?
    routed :: route_line(kernel, index, device.line, 0, device.trigger, device.polarity)
    testing.require_ok(t, routed, "the test device's line is the controller's and unrouted, so it routes to the boot CPU")?
    kernel.test_controller = index
    runtime.log_info("test_ioapic: a controller with % lines, line % routed to CPU 0", kernel.controllers[0].lines, device.line)
    unmask_line(kernel, index, device.line)
    kernel.stop_after_ticks = DEVICE_TEST_TICKS
    arch.test_device_interrupts(true)
    return .Ok
}

/**
 * Count one of the test device's interrupts, from handle_device_interrupt with test_ioapic on; at the
 * DEVICE_TEST_INTERRUPTS-th, stop the device, mask its line again, run test_ioapic's second test, which passes, and
 * stop the kernel, halted.
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
    run_arrival_test()
    stop(.Halted)
}

/**
 * Run test_ioapic's second test at the boot CPU's last tick while test_ioapic runs, if not all of the device's
 * interrupts came, so it fails saying how many did. Other ticks, and runs without test_ioapic, do nothing.
 *
 * @param kernel The kernel, whose options, stop_after_ticks and test_device_count are read; called from the timer
 *     interrupt on the boot CPU.
 * @param tick The boot CPU's tick count, from 1.
 */
device_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    if !kernel.options.test_ioapic || tick != kernel.stop_after_ticks || kernel.test_device_count >= DEVICE_TEST_INTERRUPTS {
        return void
    }
    run_arrival_test()
}

/** Run test_ioapic's second test, reporting it to the kernel's log; from an interrupt, as it allocates nothing. */
run_arrival_test :: fn() {
    _ = run_tests("test_ioapic", testing.Test.[.{name = "the_test_devices_interrupts_arrive", run = the_test_devices_interrupts_arrive}])
}

/**
 * Check that DEVICE_TEST_INTERRUPTS of the test device's interrupts arrived through its route, within
 * DEVICE_TEST_TICKS of the boot CPU's ticks; run when the last arrives, or at the last tick if they didn't all.
 *
 * @param t The test's state.
 * @return Ok once it's run.
 */
the_test_devices_interrupts_arrive #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    testing.expect_eq(t, kernel.test_device_count, DEVICE_TEST_INTERRUPTS,
        "the routed, unmasked line delivers each of the device's interrupts to the boot CPU, well within the ticks waited")
    return .Ok
}
