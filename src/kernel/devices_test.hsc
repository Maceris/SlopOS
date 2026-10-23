package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import slop_os from "std/os"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * test_devices: a driver in user mode, given the platform capability as the root task would give the
 * platform service, keeping what each call gave in its page:
 * - it registers the test device's interrupt controller (arch.test_device), from what the firmware tables
 *   would say, which the kernel puts in its page; registers in RAM the kernel owns are refused;
 * - it makes an IRQ for the device's line (a second for the same line is refused, and so is making one
 *   without the platform capability), binds it to a port, and once the kernel starts the device, takes
 *   DEVICES_TEST_INTERRUPTS interrupts through Irq packets, acknowledging each;
 * - device memory over RAM the kernel owns is refused; over the emulator's HPET it maps, and reads the
 *   HPET's vendor;
 * - a window onto memory through a read-only handle can't be mapped writable, maps read-only and shows
 *   what was written through the memory; closing the memory destroys the window and its mapping.
 * Then the kernel destroys the process, and every IRQ, memory object and mapping has to be gone.
 */

DEVICES_TEST_TICKS : u64 : 300
DEVICES_TEST_DESTROY_TICK : u64 : 290
DEVICES_TEST_INTERRUPTS : u64 : 10
DEVICE_SLOT_SPACE :: 0
DEVICE_SLOT_PLATFORM :: 1
DEVICE_SLOT_KIND :: 2
DEVICE_SLOT_REGISTERS :: 3
DEVICE_SLOT_LINE :: 4
DEVICE_SLOT_FLAGS :: 5
// A page of RAM the kernel owns: the driver's own page.
DEVICE_SLOT_RAM :: 6
DEVICE_SLOT_READY :: 40
DEVICE_SLOT_STOP :: 41
DEVICE_SLOT_DONE :: 42
DEVICE_PACKETS_OFFSET : u64 : 256
IRQ_KEY : u64 : 11
// QEMU's HPET, where its firmware tables put it; its first register's high half is its vendor.
QEMU_HPET : u64 : 0xfed00000
HPET_VENDOR : u64 : 0x8086
DEVICE_AT : u64 : 0x3000000
WINDOWED_AT : u64 : 0x4000000
WINDOW_AT : u64 : 0x5000000

DevicesTest :: struct {
    process : u64,
    page : u64,
    started : bool,
    stopped : bool,
}

user_driver #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    packets :: cast[ptr[u64[16]]](base + DEVICE_PACKETS_OFFSET)
    space :: page^[DEVICE_SLOT_SPACE]
    platform :: page^[DEVICE_SLOT_PLATFORM]
    budget :: page^[TEST_SLOT_BUDGET]
    // The controller, and one in RAM
    controller :: call(.ControllerRegister, platform, page^[DEVICE_SLOT_KIND], page^[DEVICE_SLOT_REGISTERS])
    page^[8] = controller.rax
    page^[9] = if controller.r8 > page^[DEVICE_SLOT_LINE] { cast[u64](1) } else { cast[u64](0) }
    page^[10] = call(.ControllerRegister, platform, page^[DEVICE_SLOT_KIND], page^[DEVICE_SLOT_RAM]).rax
    // Its IRQ, a second for the same line, and one without the platform capability
    irq :: call(.IrqCreate, platform, budget, controller.rdx, page^[DEVICE_SLOT_LINE], page^[DEVICE_SLOT_FLAGS])
    page^[11] = irq.rax
    page^[12] = call(.IrqCreate, platform, budget, controller.rdx, page^[DEVICE_SLOT_LINE], page^[DEVICE_SLOT_FLAGS]).rax
    page^[13] = call(.IrqCreate, budget, budget, controller.rdx, page^[DEVICE_SLOT_LINE], page^[DEVICE_SLOT_FLAGS]).rax
    port :: call(.PortCreate, budget).rdx
    page^[14] = call(.PortBind, port, irq.rdx, 0, IRQ_KEY, cast[u64](cast[u32](slop_os.BindMode.Persistent))).rax
    // The device's interrupts, once the kernel starts it
    intrinsics.volatile_store_u64(&page^[DEVICE_SLOT_READY], 1)
    taken := cast[u64](0)
    keys_right := cast[u64](1)
    loop {
        waited :: call(.PortWait, port, base + DEVICE_PACKETS_OFFSET, 1, slop_os.NO_DEADLINE)
        if waited.rax != 0 {
            break
        }
        if packets^[0] != IRQ_KEY || packets^[1] & 0xffffffff != cast[u64](cast[u32](slop_os.PacketKind.Irq)) {
            keys_right = 0
        }
        taken += packets^[2]
        _ = call(.IrqAck, irq.rdx)
    }
    while taken < DEVICES_TEST_INTERRUPTS
    intrinsics.volatile_store_u64(&page^[DEVICE_SLOT_STOP], 1)
    page^[15] = if taken >= DEVICES_TEST_INTERRUPTS { cast[u64](1) } else { cast[u64](0) }
    page^[16] = keys_right
    page^[17] = call(.HandleClose, irq.rdx).rax
    // Device memory: not over the kernel's RAM; the HPET's registers, read
    device :: cast[u64](cast[u32](slop_os.CacheMode.Device))
    read :: cast[u64](cast[u32](slop_os.PROTECTION_READ))
    read_write :: cast[u64](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    page^[18] = call(.MemoryCreatePhysical, platform, budget, page^[DEVICE_SLOT_RAM], frames.FRAME_SIZE, device).rax
    hpet :: call(.MemoryCreatePhysical, platform, budget, QEMU_HPET, frames.FRAME_SIZE, device)
    page^[19] = hpet.rax
    page^[20] = call(.MemoryMap, hpet.rdx, space, DEVICE_AT, 0, frames.FRAME_SIZE, read).rax
    page^[21] = cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](DEVICE_AT)) >> 16)
    // A window, through a read-only handle
    memory :: call(.MemoryCreate, budget, 4 * frames.FRAME_SIZE).rdx
    _ = call(.MemoryMap, memory, space, WINDOWED_AT, 0, 4 * frames.FRAME_SIZE, read_write)
    for i in 0..<4 {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](WINDOWED_AT + cast[u64](i) * frames.FRAME_SIZE), 1000 + cast[u64](i))
    }
    read_only :: call(.HandleDuplicate, memory, cast[u64](cast[u32](slop_os.RIGHT_MEMORY_READ))).rdx
    window :: call(.MemoryCreateWindow, read_only, budget, 2 * frames.FRAME_SIZE, frames.FRAME_SIZE)
    page^[22] = window.rax
    page^[23] = call(.MemoryMap, window.rdx, space, WINDOW_AT, 0, frames.FRAME_SIZE, read_write).rax
    page^[24] = call(.MemoryMap, window.rdx, space, WINDOW_AT, 0, frames.FRAME_SIZE, read).rax
    page^[25] = intrinsics.volatile_load_u64(cast[ptr[u64]](WINDOW_AT))
    // Closing the memory destroys the window, and takes down its mapping
    page^[26] = call(.HandleClose, memory).rax
    page^[27] = call(.HandleInfo, window.rdx).rax
    page^[28] = call(.MemoryUnmap, space, WINDOW_AT).rax
    intrinsics.volatile_store_u64(&page^[DEVICE_SLOT_DONE], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

test_devices :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[DevicesTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_devices: no memory")
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("test_devices: no process: %", error)
            return void
        }
    }
    test.process = cast[u64](process)
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), 0) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("test_devices: no address space: %", error)
            return void
        }
    }
    // The function, call, and the code between them
    first :: min_u64(cast[u64](user_driver), cast[u64](call)) & ~(frames.FRAME_SIZE - 1)
    last :: frames.round_up(max_u64(cast[u64](user_driver), cast[u64](call)) + 4 * frames.FRAME_SIZE, frames.FRAME_SIZE)
    if !mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (first - kernel.image_base), last - first, USER_CODE) {
        return void
    }
    page :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_devices: no memory")
    stacks :: frames.allocate_zeroed(&kernel.frames, 1) or_else out_of_memory(&kernel.options, "test_devices: no memory")
    if !mapped_for_test(kernel, space, TEST_COUNTERS, cast[u64](page), frames.FRAME_SIZE, USER_DATA)
        || !mapped_for_test(kernel, space, TEST_STACKS, cast[u64](stacks), 2 * frames.FRAME_SIZE, USER_DATA) {
        return void
    }
    test.page = frames.virtual_of(&kernel.frames, page)
    slots :: cast[ptr[mut u64[64]]](test.page)
    match install(kernel, &process.table, cast[u64](space), space.header.generation, .AddressSpace, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[DEVICE_SLOT_SPACE] = cast[u64](cast[u32](handle))
        case Error(error) => {
            runtime.log_error("test_devices: no handle: %", error)
            return void
        }
    }
    // The platform capability, as the root task would hand it on
    platform :: cast[ptr[ObjectHeader]](kernel.platform)
    match install(kernel, &process.table, kernel.platform, platform.generation, .Platform, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[DEVICE_SLOT_PLATFORM] = cast[u64](cast[u32](handle))
        case Error(error) => {
            runtime.log_error("test_devices: no platform handle: %", error)
            return void
        }
    }
    if !give_test_budget(kernel, process, test.page) {
        return void
    }
    // What the firmware tables would say of the test device
    device :: arch.test_device()
    slots^[DEVICE_SLOT_KIND] = cast[u64](cast[u32](slop_os.ControllerKind.IoApic))
    slots^[DEVICE_SLOT_REGISTERS] = cast[u64](device.registers)
    slots^[DEVICE_SLOT_LINE] = cast[u64](device.line)
    slots^[DEVICE_SLOT_FLAGS] = (if device.trigger == .Level { cast[u64](slop_os.IRQ_LEVEL) } else { cast[u64](0) })
        | (if device.polarity == .ActiveLow { cast[u64](slop_os.IRQ_ACTIVE_LOW) } else { cast[u64](0) })
    slots^[DEVICE_SLOT_RAM] = cast[u64](page)
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (cast[u64](user_driver) - first)),
        stack_pointer = cast[arch_interface.VirtualAddress](TEST_STACKS + frames.FRAME_SIZE - 8),
        argument = TEST_COUNTERS,
    }
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0, 0) {
        case Ok(thread) => start_thread(kernel, thread)
        case Error(error) => {
            runtime.log_error("test_devices: no thread: %", error)
            return void
        }
    }
    kernel.stop_after_ticks = DEVICES_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.devices_test, cast[u64](test))
}

devices_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.devices_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut DevicesTest]](address)
    slots :: cast[ptr[u64[64]]](test.page)
    // The device runs while the driver takes its interrupts
    if !test.started && intrinsics.volatile_load_u64(&slots^[DEVICE_SLOT_READY]) == 1 {
        test.started = true
        arch.test_device_interrupts(true)
    }
    if test.started && !test.stopped && intrinsics.volatile_load_u64(&slots^[DEVICE_SLOT_STOP]) == 1 {
        test.stopped = true
        arch.test_device_interrupts(false)
    }
    if tick == DEVICES_TEST_DESTROY_TICK {
        check_device_results(test)
        _ = destroy_object(kernel, test.process)
        return void
    }
    if tick != DEVICES_TEST_TICKS {
        return void
    }
    pools :: &kernel.pools
    if pools.irqs.allocated != 0 || pools.memories.allocated != 0 || pools.mappings.allocated != 0 {
        runtime.log_error("test_devices: left after the process was destroyed: % IRQs, % memory objects, % mappings",
            pools.irqs.allocated, pools.memories.allocated, pools.mappings.allocated)
        return void
    }
    runtime.log_info("test_devices: destroying the process freed its IRQs, its device memory and its windows")
}

check_device_results :: fn(test: ptr[DevicesTest]) {
    slots :: cast[ptr[u64[64]]](test.page)
    if slots^[DEVICE_SLOT_DONE] != 1 {
        runtime.log_error("test_devices: the driver didn't finish")
        return void
    }
    expected :: u64.[
        0, 1, device_tag(.BadAddress),
        0, device_tag(.LineInUse), device_tag(.WrongKind), 0,
        1, 1, 0,
        device_tag(.BadAddress), 0, 0, HPET_VENDOR,
        0, tag(.MissingRight), 0, 1002,
        0, cast[u64](cast[u32](slop_os.HandleError.ObjectGone)), tag(.NotMapped),
    ]
    for value, i in expected {
        if slots^[8 + i] != value {
            runtime.log_error("test_devices: result % is %, not %", i, slots^[8 + i], value)
            return void
        }
    }
    runtime.log_info("test_devices: a driver registered a controller, took an IRQ's interrupts through its port, read device memory, and lost a window with its memory")
}

// A device error's tag, as a call gives it.
device_tag :: fn(error: slop_os.DeviceError) -> u64 {
    return cast[u64](cast[u32](error))
}
