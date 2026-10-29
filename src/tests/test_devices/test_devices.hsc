/*
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
 * - registering an IOMMU is refused for a kind there's none of, memory that isn't device memory, no requester IDs,
 *   and device memory that's another device, the HPET or the PL011;
 * - what it all charged its budget comes back.
 */
package test_devices

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_device as device_info from "../../test_device"
import test_kit from "../../test_kit"

NAME :: "test_devices"
PAGE : u64 : 4096
INTERRUPTS : u64 : 10
IRQ_KEY : u64 : 11
#if TARGET_ARCH == .x86_64 {
    // QEMU's HPET, where its firmware tables put it; its first register's high half is its vendor.
    DEVICE_MEMORY : u64 : 0xfed00000
    DEVICE_ID_OFFSET : u64 : 0
    DEVICE_ID_SHIFT : u32 : 16
    DEVICE_ID : u64 : 0x8086
    IOMMU : slop_os.IommuKind : .VtD
}
#else_if TARGET_ARCH == .arm64 {
    // QEMU virt's PL011, where its device tree puts it; UARTPeriphID0 is 0x11.
    DEVICE_MEMORY : u64 : 0x09000000
    DEVICE_ID_OFFSET : u64 : 0xfe0
    DEVICE_ID_SHIFT : u32 : 0
    DEVICE_ID : u64 : 0x11
    IOMMU : slop_os.IommuKind : .Smmuv3
}

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    space :: block.space
    hardware :: platform or_return 100
    described :: test_device or_return 100
    // What the firmware tables would say of the device
    info_at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 101
    slop_os.memory_map(described, space, info_at, 0, PAGE, slop_os.PROTECTION_READ) or_return 101
    info :: cast[ptr[device_info.TestDeviceInfo]](info_at)
    kind :: cast[slop_os.ControllerKind](info.kind)
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 102
    results : u64[25]
    // The controller, and one in RAM
    registered :: slop_os.controller_register(hardware, kind, info.registers)
    results[0] = test_kit.tag_of(registered)
    controller :: registered or_else slop_os.ControllerInfo.{}
    results[1] = if controller.lines > info.line { cast[u64](1) } else { cast[u64](0) }
    results[2] = test_kit.tag_of(slop_os.controller_register(hardware, kind, info.kernel_ram))
    // Its IRQ, a second for the same line, and one without the platform capability
    made :: slop_os.irq_create(hardware, budget, controller.number, info.line, info.flags)
    results[3] = test_kit.tag_of(made)
    irq :: made or_else test_kit.handle_at[slop_os.Irq](0)
    results[4] = test_kit.tag_of(slop_os.irq_create(hardware, budget, controller.number, info.line, info.flags))
    not_platform :: test_kit.handle_at[slop_os.Platform](cast[u64](cast[u32](budget)))
    results[5] = test_kit.tag_of(slop_os.irq_create(not_platform, budget, controller.number, info.line, info.flags))
    port :: slop_os.port_create(budget) or_return 103
    results[6] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent))
    // The device's interrupts, which run while the IRQ exists
    taken := cast[u64](0)
    keys_right := cast[u64](1)
    started :: test_kit.clock_now()
    loop {
        packets : slop_os.Packet[1]
        waited :: slop_os.port_wait(port, packets, started + 2_000_000_000)
        if test_kit.tag_of(waited) != 0 || (waited or_else 0) == 0 {
            break
        }
        if packets[0].key != IRQ_KEY || packets[0].kind != .Irq {
            keys_right = 0
        }
        taken += packets[0].data[0]
        _ = slop_os.irq_ack(irq)
    }
    while taken < INTERRUPTS
    results[7] = if taken >= INTERRUPTS { cast[u64](1) } else { cast[u64](0) }
    results[8] = keys_right
    results[9] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](irq)))
    // Device memory: not over the kernel's RAM; the device's registers, read
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    results[10] = test_kit.tag_of(slop_os.memory_create_physical(hardware, budget, info.kernel_ram, PAGE, .Device))
    device :: slop_os.memory_create_physical(hardware, budget, DEVICE_MEMORY, PAGE, .Device)
    results[11] = test_kit.tag_of(device)
    device_at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 104
    results[12] = test_kit.tag_of(slop_os.memory_map(device or_else test_kit.handle_at[slop_os.Memory](0), space, device_at, 0, PAGE, read))
    results[13] = cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](device_at + DEVICE_ID_OFFSET)) >> DEVICE_ID_SHIFT)
    // A window, through a read-only handle
    windowed_at :: runtime.reserve_addresses(cast[usize](4 * PAGE)) or_return 104
    window_at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 104
    memory :: slop_os.memory_create(budget, 4 * PAGE) or_return 105
    _ = slop_os.memory_map(memory, space, windowed_at, 0, 4 * PAGE, read_write)
    for i in 0..<4 {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](windowed_at + cast[u64](i) * PAGE), 1000 + cast[u64](i))
    }
    read_only :: slop_os.handle_duplicate(cast[slop_os.Handle](memory), slop_os.RIGHT_MEMORY_READ) or_else slop_os.NO_HANDLE
    window_made :: slop_os.memory_create_window(cast[slop_os.Memory](read_only), budget, 2 * PAGE, PAGE)
    results[14] = test_kit.tag_of(window_made)
    window :: window_made or_else test_kit.handle_at[slop_os.Memory](0)
    results[15] = test_kit.tag_of(slop_os.memory_map(window, space, window_at, 0, PAGE, read_write))
    results[16] = test_kit.tag_of(slop_os.memory_map(window, space, window_at, 0, PAGE, read))
    results[17] = intrinsics.volatile_load_u64(cast[ptr[u64]](window_at))
    // IOMMUs: a kind there's none of, memory that isn't device memory, no requester IDs, and another device's registers
    registers :: device or_else test_kit.handle_at[slop_os.Memory](0)
    results[21] = test_kit.tag_of(slop_os.iommu_register(hardware, cast[slop_os.IommuKind](99), registers, 0, 1, 0))
    results[22] = test_kit.tag_of(slop_os.iommu_register(hardware, IOMMU, memory, 0, 1, 0))
    results[23] = test_kit.tag_of(slop_os.iommu_register(hardware, IOMMU, registers, 0, 0, 0))
    results[24] = test_kit.tag_of(slop_os.iommu_register(hardware, IOMMU, registers, 0, 1, 0))
    // Closing the memory destroys the window, and takes down its mapping
    results[18] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](memory)))
    results[19] = test_kit.tag_of(slop_os.handle_info(cast[slop_os.Handle](window)))
    results[20] = test_kit.tag_of(slop_os.memory_unmap(space, window_at))
    expected :: u64.[
        0, 1, test_kit.tag(slop_os.DeviceError.BadAddress),
        0, test_kit.tag(slop_os.DeviceError.LineInUse), test_kit.tag(slop_os.DeviceError.WrongKind), 0,
        1, 1, 0,
        test_kit.tag(slop_os.DeviceError.BadAddress), 0, 0, DEVICE_ID,
        0, test_kit.tag(slop_os.MemoryError.MissingRight), 0, 1002,
        0, test_kit.tag(slop_os.HandleError.ObjectGone), test_kit.tag(slop_os.MemoryError.NotMapped),
        test_kit.tag(slop_os.DeviceError.NoIommu), test_kit.tag(slop_os.DeviceError.BadAddress),
        test_kit.tag(slop_os.DeviceError.InvalidSize), test_kit.tag(slop_os.DeviceError.NoIommu),
    ]
    failed := test_kit.check(log, NAME, results, expected)
    if failed != 0 {
        return failed
    }
    _ = slop_os.memory_unmap(space, device_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](device or_else test_kit.handle_at[slop_os.Memory](0)))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    if !test_kit.wait_for_budget(budget, 0, 1_000_000_000) {
        log_line.write(log, "%: its budget still has % bytes charged", NAME, test_kit.used(budget))
        return 30
    }
    log_line.write(log, "%: a driver registered a controller, took an IRQ's interrupts through its port, read device memory, and lost a window with its memory; IOMMUs that aren't were refused", NAME)
    return 0
}
