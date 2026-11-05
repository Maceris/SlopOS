/**
 * test_devices (decisions/0069, from the kernel's test of 0055): a driver, given the platform capability as
 * the root task would give the platform service, and what the firmware tables say of the emulator's test
 * device (test_device.TestDeviceInfo), which the kernel runs while its line has an IRQ:
 * - it registers the device's interrupt controller; registers in RAM the kernel owns are refused;
 * - it makes an IRQ for the device's line (a second for the same line is refused, and so is making one
 *   without the platform capability), binds it to a port, and takes INTERRUPTS interrupts through Irq
 *   packets, acknowledging each;
 * - device memory over RAM the kernel owns is refused; over a device the emulator always has, it maps, and
 *   reads an ID the device gives: the HPET's vendor on x86-64, the PL011's first peripheral ID on AArch64;
 * - a window onto memory through a read-only handle can't be mapped writable, maps read-only and shows
 *   what was written through the memory; closing the memory destroys the window and its mapping;
 * - registering an IOMMU is refused for a kind there's none of, memory that isn't device memory, no requester
 *   IDs, and device memory that's another device, the HPET or the PL011;
 * - what it all charged its budget comes back.
 */
package test_devices

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_device as device_info from "../../test_device"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_devices"
/** A page, in bytes: what the device's info, its registers and the window are mapped in. */
PAGE : u64 : 4096
/** How many of the test device's interrupts the driver takes, at least, within two seconds. */
INTERRUPTS : u64 : 10
/** The key the IRQ's binding queues its packets under. */
IRQ_KEY : u64 : 11
#if TARGET_ARCH == .x86_64 {
    /** The physical address of QEMU's HPET, where its firmware tables put it. */
    DEVICE_MEMORY : u64 : 0xfed00000
    /** The offset of the register the ID is in: the HPET's first, its capabilities and ID. */
    DEVICE_ID_OFFSET : u64 : 0
    /** How far the ID is shifted up in its 32-bit register: the vendor is the first register's high half. */
    DEVICE_ID_SHIFT : u32 : 16
    /** The ID the device gives: the HPET's vendor, Intel. */
    DEVICE_ID : u64 : 0x8086
    /** The kind of IOMMU registering is tried for: the architecture's own, VT-d. */
    IOMMU : slop_os.IommuKind : .VtD
}
#else_if TARGET_ARCH == .arm64 {
    /** The physical address of QEMU virt's PL011, where its device tree puts it. */
    DEVICE_MEMORY : u64 : 0x09000000
    /** The offset of the register the ID is in: UARTPeriphID0. */
    DEVICE_ID_OFFSET : u64 : 0xfe0
    /** How far the ID is shifted up in its 32-bit register: not at all. */
    DEVICE_ID_SHIFT : u32 : 0
    /** The ID the device gives: UARTPeriphID0 is 0x11. */
    DEVICE_ID : u64 : 0x11
    /** The kind of IOMMU registering is tried for: the architecture's own, an SMMUv3. */
    IOMMU : slop_os.IommuKind : .Smmuv3
}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
    /** The platform capability, which registers controllers and IOMMUs, makes IRQs and device memory; none if main wasn't given it. */
    platform : slop_os.Platform?,
    /**
     * The page the kernel writes the test device's TestDeviceInfo in, from the test_device grant; none if main wasn't
     * given it, as when the kernel's command line hasn't test_device.
     */
    test_device : slop_os.Memory?,
}

/**
 * Map what the firmware tables would say of the test device, read-only.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param given What main was given: its test_device page is mapped.
 * @return The device's info, mapped at addresses reserved for it, which stay mapped; Error(Failed), recorded, if main
 *     wasn't given the page, or it couldn't be mapped.
 */
info_of :: fn(t: ptr[mut testing.T], given: ptr[Given]) -> Result[ptr[device_info.TestDeviceInfo], testing.Stopped] {
    block :: slop_os.startup_block()
    described :: testing.require_some(t, given.test_device, "the root task grants the test device's info, with test_device on the command line")?
    info_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGE)), "addresses to map the device's info at")?
    testing.require_ok(t, slop_os.memory_map(described, block.space, info_at, 0, PAGE, slop_os.PROTECTION_READ), "the device's info is mapped to read")?
    return .Ok(cast[ptr[device_info.TestDeviceInfo]](info_at))
}

/**
 * Check that a driver registers the device's interrupt controller, but not one in RAM the kernel owns; makes an IRQ for
 * the device's line, but not a second for it, nor one without the platform capability; and takes INTERRUPTS
 * interrupts through Irq packets on a port, acknowledging each. Then that what it charged its budget comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the platform capability or the device's info, or the budget,
 *     the IRQ or the port couldn't be made.
 */
a_driver_takes_its_device_interrupts_through_an_irq #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    hardware :: testing.require_some(t, given.platform, "the root task grants the platform capability")?
    info :: info_of(t, given)?
    kind :: cast[slop_os.ControllerKind](info.kind)
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the IRQ and its port")?
    // The controller, and one in RAM
    registered :: slop_os.controller_register(hardware, kind, info.registers)
    testing.expect_ok(t, registered, "the device's interrupt controller registers where the firmware tables say it is")
    controller :: registered or_else slop_os.ControllerInfo.{}
    testing.expect(t, controller.lines > info.line, "the controller registered has the device's line")
    in_ram :: slop_os.controller_register(hardware, kind, info.kernel_ram)
    testing.expect_error(t, in_ram, slop_os.DeviceError.BadAddress, "a controller's registers can't be in RAM the kernel owns")
    // Its IRQ, a second for the same line, and one without the platform capability
    irq :: testing.require_ok(t, slop_os.irq_create(hardware, budget, controller.number, info.line, info.flags), "an IRQ is made for the device's line")?
    second :: slop_os.irq_create(hardware, budget, controller.number, info.line, info.flags)
    testing.expect_error(t, second, slop_os.DeviceError.LineInUse, "a line has one IRQ at a time")
    not_platform :: test_kit.handle_at[slop_os.Platform](cast[u64](cast[u32](budget)))
    without :: slop_os.irq_create(not_platform, budget, controller.number, info.line, info.flags)
    testing.expect_error(t, without, slop_os.DeviceError.WrongKind, "only the platform capability makes IRQs")
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port for the IRQ's packets")?
    bound :: slop_os.port_bind(port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent)
    testing.expect_ok(t, bound, "an IRQ binds to a port, to queue a packet for each interrupt")
    // The device's interrupts, which run while the IRQ exists
    taken := cast[u64](0)
    keys_right := true
    started :: test_kit.clock_now()
    loop {
        packets : slop_os.Packet[1]
        waited :: slop_os.port_wait(port, packets, started + 2_000_000_000)
        if (waited is_error) || (waited or_else 0) == 0 {
            break
        }
        if packets[0].key != IRQ_KEY || packets[0].kind != .Irq {
            keys_right = false
        }
        taken += packets[0].data[0]
        _ = slop_os.irq_ack(irq)
    }
    while taken < INTERRUPTS
    testing.expect(t, taken >= INTERRUPTS, "the device's interrupts come as packets, each acknowledged, at least INTERRUPTS in two seconds")
    testing.expect(t, keys_right, "every packet is an Irq packet under the IRQ's key")
    closed :: slop_os.handle_close(cast[slop_os.Handle](irq))
    testing.expect_ok(t, closed, "the IRQ closes, freeing its line")
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "the budget is back to nothing once the IRQ and its port are closed")
    return .Ok
}

/**
 * Check that device memory isn't made over RAM the kernel owns, but is over a device the emulator always has, which
 * maps, and gives the ID it should; and that registering an IOMMU is refused for a kind there's none of, memory that
 * isn't device memory, no requester IDs, and device memory that's another device's. Then that what it charged its
 * budget comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the platform capability or the device's info, or the budget,
 *     the device memory, its addresses or the plain memory couldn't be made.
 */
device_memory_reads_its_device_and_false_iommus_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    space :: block.space
    hardware :: testing.require_some(t, given.platform, "the root task grants the platform capability")?
    info :: info_of(t, given)?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the memory")?
    // Device memory: not over the kernel's RAM; the device's registers, read
    over_ram :: slop_os.memory_create_physical(hardware, budget, info.kernel_ram, PAGE, .Device)
    testing.expect_error(t, over_ram, slop_os.DeviceError.BadAddress, "device memory can't be made over RAM the kernel owns")
    registers :: testing.require_ok(t, slop_os.memory_create_physical(hardware, budget, DEVICE_MEMORY, PAGE, .Device), "device memory is made over a device the emulator always has")?
    device_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGE)), "addresses to map the device at")?
    mapped :: slop_os.memory_map(registers, space, device_at, 0, PAGE, slop_os.PROTECTION_READ)
    testing.expect_ok(t, mapped, "device memory maps")
    if mapped is_ok {
        found :: cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](device_at + DEVICE_ID_OFFSET)) >> DEVICE_ID_SHIFT)
        testing.expect_eq(t, found, DEVICE_ID, "reading the device's registers gives the ID it has: the HPET's vendor, or the PL011's first peripheral ID")
    }
    // IOMMUs: a kind there's none of, memory that isn't device memory, no requester IDs, and another device's registers
    plain :: testing.require_ok(t, slop_os.memory_create(budget, PAGE), "memory that isn't device memory")?
    no_kind :: slop_os.iommu_register(hardware, cast[slop_os.IommuKind](99), registers, 0, 1, 0)
    testing.expect_error(t, no_kind, slop_os.DeviceError.NoIommu, "there's no IOMMU of a kind that doesn't exist")
    not_device :: slop_os.iommu_register(hardware, IOMMU, plain, 0, 1, 0)
    testing.expect_error(t, not_device, slop_os.DeviceError.BadAddress, "an IOMMU's registers have to be device memory")
    no_ids :: slop_os.iommu_register(hardware, IOMMU, registers, 0, 0, 0)
    testing.expect_error(t, no_ids, slop_os.DeviceError.InvalidSize, "an IOMMU has to cover at least one requester ID")
    other_device :: slop_os.iommu_register(hardware, IOMMU, registers, 0, 1, 0)
    testing.expect_error(t, other_device, slop_os.DeviceError.NoIommu, "another device's registers, the HPET's or the PL011's, aren't an IOMMU's")
    _ = slop_os.memory_unmap(space, device_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](registers))
    _ = slop_os.handle_close(cast[slop_os.Handle](plain))
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "the budget is back to nothing once the memory is closed")
    return .Ok
}

/**
 * Check that a window onto memory, made through a read-only handle, can't be mapped writable, maps read-only, and
 * shows what was written through the memory; and that closing the memory destroys the window and takes down its
 * mapping. Then that what it charged its budget comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the budget, the memory or its addresses couldn't be made.
 */
a_window_shows_its_memory_and_goes_with_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    space :: block.space
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the memory and its window")?
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    windowed_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](4 * PAGE)), "addresses to map the memory at")?
    window_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGE)), "addresses to map the window at")?
    memory :: testing.require_ok(t, slop_os.memory_create(budget, 4 * PAGE), "memory of 4 pages")?
    testing.require_ok(t, slop_os.memory_map(memory, space, windowed_at, 0, 4 * PAGE, read_write), "the memory is mapped to write")?
    for i in 0..<4 {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](windowed_at + cast[u64](i) * PAGE), 1000 + cast[u64](i))
    }
    read_only :: slop_os.handle_duplicate(cast[slop_os.Handle](memory), slop_os.RIGHT_MEMORY_READ) or_else slop_os.NO_HANDLE
    window :: testing.require_ok(t, slop_os.memory_create_window(cast[slop_os.Memory](read_only), budget, 2 * PAGE, PAGE), "a window onto the memory's third page is made through a read-only handle")?
    writable :: slop_os.memory_map(window, space, window_at, 0, PAGE, read_write)
    testing.expect_error(t, writable, slop_os.MemoryError.MissingRight, "a window made through a read-only handle can't be mapped writable")
    readable :: slop_os.memory_map(window, space, window_at, 0, PAGE, read)
    testing.expect_ok(t, readable, "a window made through a read-only handle maps read-only")
    if readable is_ok {
        testing.expect_eq(t, intrinsics.volatile_load_u64(cast[ptr[u64]](window_at)), 1002, "a window shows what was written through its memory, at its offset")
    }
    // Closing the memory destroys the window, and takes down its mapping
    closed :: slop_os.handle_close(cast[slop_os.Handle](memory))
    testing.expect_ok(t, closed, "the memory closes")
    gone :: slop_os.handle_info(cast[slop_os.Handle](window))
    testing.expect_error(t, gone, slop_os.HandleError.ObjectGone, "closing memory destroys its windows")
    unmapped :: slop_os.memory_unmap(space, window_at)
    testing.expect_error(t, unmapped, slop_os.MemoryError.NotMapped, "a destroyed window's mapping is taken down with it")
    _ = slop_os.handle_close(cast[slop_os.Handle](window))
    _ = slop_os.handle_close(read_only)
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "the budget is back to nothing once the memory and its window are gone")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform The platform capability, which registers controllers and IOMMUs, makes IRQs and device memory;
 *     without it the tests that need it fail.
 * @param test_device The page the kernel writes the test device's TestDeviceInfo in, from the test_device grant;
 *     without it, as when the kernel's command line hasn't test_device, the tests that need it fail.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log, platform = platform, test_device = test_device}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
