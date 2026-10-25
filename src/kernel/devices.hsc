package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import slop_os from "std/os"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Devices and DMA domains (roadmap M7, decisions/0070, 0073).
 *
 * A Device is one PCIe function, made with the platform capability by whoever read the firmware tables and found
 * it: its address (segment and requester ID), and the source its message-signaled interrupts come from as the
 * interrupt controller sees them (the ITS's device ID on AArch64). It has up to slop_os.MAX_DEVICE_MSIS
 * message-signaled IRQs, each one of its events, routed to a CPU's device interrupt ID as a wired line's is
 * (interrupts.hsc). Destroying the device destroys its IRQs, as destroying memory destroys its windows.
 *
 * A DmaDomain is where its devices' DMA reaches. Without an IOMMU that's all of memory, and a device address is a
 * physical address: DMA memory, pinned and in one block of frames, is made in a domain, and its device address is
 * its block's. Attaching a device to a domain records it, for when an IOMMU confines it there.
 *
 * Lock order: a device's lock, then the kernel's devices_lock, then interrupts_lock.
 */

Device :: struct #align(16) {
    header : ObjectHeader,
    // Held for its IRQs and its events.
    lock : concurrency.SpinLock,
    address : u32,
    msi_source : u32,
    // Its configuration space, mapped in the kernel's window, for turning its DMA off when it's destroyed
    config : u64,
    // Its events in use, a bit each.
    events : u32,
    // Its IRQs, under lock.
    first_irq : u64,
    // The domain it's attached to, and that domain's generation then; 0 for none.
    domain : u64,
    domain_generation : u32,
    // What the interrupt controller keeps for its MSIs, a block of frames of this order plus one, 0 for none.
    msi_memory : u64,
    msi_memory_order : u64,
    // Its neighbors among the kernel's devices, under devices_lock, and whether it's there.
    next : u64,
    previous : u64,
    listed : bool,
}

DmaDomain :: struct #align(16) {
    header : ObjectHeader,
}

/*
 * A device at address, its MSIs from msi_source, owned by owner and charged to budget, for its slot and what the
 * interrupt controller keeps for it. No other device may have its address, nor, where the controller uses sources,
 * its source.
 */
create_device :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, address: u32, msi_source: u32, config: u64)
    -> Result[ptr[mut Device], slop_os.DeviceError] {
    if config == 0 || config & (frames.FRAME_SIZE - 1) != 0 || config > ~CONFIG_BYTES || overlaps_kernel_ram(kernel, config, CONFIG_BYTES) {
        return .Error(.BadAddress)
    }
    table_size :: arch.msi_device_memory() or_else 0
    order :: if table_size == 0 { cast[u64](0) } else { frames.order_for(table_size) + 1 }
    extra :: if order == 0 { cast[u64](0) } else { frames.FRAME_SIZE << (order - 1) }
    object := cast[u64](0)
    match new_object(kernel, .Device, budget, extra) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    device :: cast[ptr[mut Device]](object)
    device.address = address
    device.msi_source = msi_source
    match map_device(kernel, cast[boot_info.PhysicalAddress](config), CONFIG_BYTES) {
        case Ok(mapped) => device.config = mapped
        case Error(error) => {
            release_object(kernel, object)
            return .Error(.OutOfMemory)
        }
    }
    if order != 0 {
        match frames.allocate_zeroed(&kernel.frames, order - 1) {
            case Ok(block) => {
                device.msi_memory = cast[u64](block)
                device.msi_memory_order = order
            }
            case Error(error) => {
                release_object(kernel, object)
                return .Error(.OutOfMemory)
            }
        }
    }
    concurrency.lock(&kernel.devices_lock)
    taken := false
    with {
        other := kernel.first_device
    }
    loop {
        listed :: cast[ptr[Device]](other)
        if listed.address == address || (order != 0 && listed.msi_source == msi_source) {
            taken = true
            break
        }
        other = listed.next
    }
    while other != 0
    if !taken {
        device.next = kernel.first_device
        if kernel.first_device != 0 {
            cast[ptr[mut Device]](kernel.first_device).previous = object
        }
        kernel.first_device = object
        device.listed = true
    }
    concurrency.unlock(&kernel.devices_lock)
    if taken {
        release_object(kernel, object)
        return .Error(.DeviceExists)
    }
    if device.msi_memory != 0 {
        arch.add_msi_device(msi_source, cast[arch_interface.PhysicalAddress](device.msi_memory), slop_os.MAX_DEVICE_MSIS)
    }
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(device)
}

// A PCIe function's configuration space, and its command register's Bus Master Enable, which lets it start DMA.
//SPEC: PCI Express Base Specification 5.0, §7.5.1.1.3 (Command Register)
CONFIG_BYTES : u64 : 4096
PCI_COMMAND : u64 : 0x04
PCI_COMMAND_BUS_MASTER : u16 : 1 << 2

// The device's DMA in domain, from now on.
attach_device :: fn(device: ptr[mut Device], domain: ptr[DmaDomain]) {
    concurrency.lock(&device.lock)
    device.domain = cast[u64](domain)
    device.domain_generation = domain.header.generation
    concurrency.unlock(&device.lock)
}

/*
 * Destroying a device destroys its IRQs, each once the destroy running on this CPU is done, off its list first;
 * then the interrupt controller forgets it, and it leaves the kernel's devices.
 */
destroy_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device]) {
    /*
     * Its DMA off first, Bus Master Enable cleared: what its driver gave it to read and write, like its queues, goes with
     * the driver, and no grace period ends while this destroy runs, so before any of that memory is used again
     */
    if device.config != 0 {
        command :: cast[ptr[mut u16]](device.config + PCI_COMMAND)
        intrinsics.volatile_store_u16(command, intrinsics.volatile_load_u16(command) & ~PCI_COMMAND_BUS_MASTER)
    }
    loop {
        concurrency.lock(&device.lock)
        first :: device.first_irq
        if first != 0 {
            unlink_irq(device, cast[ptr[mut Irq]](first))
        }
        concurrency.unlock(&device.lock)
        if first == 0 {
            break
        }
        destroy_later(kernel, first, cast[ptr[ObjectHeader]](first).generation)
    }
    concurrency.lock(&kernel.devices_lock)
    if device.listed {
        if device.previous != 0 {
            cast[ptr[mut Device]](device.previous).next = device.next
        }
        else {
            kernel.first_device = device.next
        }
        if device.next != 0 {
            cast[ptr[mut Device]](device.next).previous = device.previous
        }
        device.listed = false
        if device.msi_memory != 0 {
            arch.remove_msi_device(device.msi_source)
        }
    }
    concurrency.unlock(&kernel.devices_lock)
}

// Once no CPU can use it: what the interrupt controller kept for it.
release_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device]) {
    if device.config != 0 {
        unmap_device(kernel, device.config, CONFIG_BYTES)
        device.config = 0
    }
    if device.msi_memory_order != 0 {
        frames.free(&kernel.frames, cast[boot_info.PhysicalAddress](device.msi_memory), device.msi_memory_order - 1)
        device.msi_memory = 0
        device.msi_memory_order = 0
    }
}

// Take irq off device's list, if it's on it, its event free again. Takes the device's lock as held.
unlink_irq :: fn(device: ptr[mut Device], irq: ptr[mut Irq]) {
    if !irq.in_device {
        return void
    }
    if irq.device_previous != 0 {
        cast[ptr[mut Irq]](irq.device_previous).device_next = irq.device_next
    }
    else {
        device.first_irq = irq.device_next
    }
    if irq.device_next != 0 {
        cast[ptr[mut Irq]](irq.device_next).device_previous = irq.device_previous
    }
    irq.in_device = false
    device.events &= ~(cast[u32](1) << irq.line)
}

/*
 * A message-signaled IRQ for one of device's events, owned by owner and charged to budget: routed to the next CPU in
 * turn, its message what the device's driver programs into it.
 */
create_msi_irq :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, device: ptr[mut Device]) -> Result[ptr[mut Irq], slop_os.DeviceError] {
    _ = arch.msi_device_memory() or_return .Error(.NoMsi)
    object := cast[u64](0)
    match new_object(kernel, .Irq, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    irq :: cast[ptr[mut Irq]](object)
    irq.msi = true
    irq.trigger = .Edge
    irq.controller = MSI_CONTROLLER
    irq.slot = cast[u32](MAX_DEVICE_INTERRUPTS)
    irq.device = cast[u64](device)
    irq.msi_source = device.msi_source
    concurrency.lock(&device.lock)
    event : u32 = slop_os.MAX_DEVICE_MSIS
    if !is_dying(cast[u64](device)) {
        for bit in 0..<slop_os.MAX_DEVICE_MSIS {
            if device.events & (cast[u32](1) << bit) == 0 {
                event = bit
                break
            }
        }
    }
    gone :: is_dying(cast[u64](device))
    if event < slop_os.MAX_DEVICE_MSIS {
        device.events |= cast[u32](1) << event
        irq.line = event
        irq.device_previous = 0
        irq.device_next = device.first_irq
        if device.first_irq != 0 {
            cast[ptr[mut Irq]](device.first_irq).device_previous = object
        }
        device.first_irq = object
        irq.in_device = true
    }
    concurrency.unlock(&device.lock)
    if gone || event == slop_os.MAX_DEVICE_MSIS {
        release_object(kernel, object)
        return .Error(if gone { slop_os.DeviceError.ObjectGone } else { slop_os.DeviceError.TooManyVectors })
    }
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    cpu :: intrinsics.interlocked_increment_u32(&kernel.next_irq_cpu) % online
    first, count :: arch.device_interrupt_range()
    match route_message(kernel, cpu, event, object) {
        case Ok(id) => {
            irq.cpu = cpu
            irq.slot = cast[u32](id) - cast[u32](first)
            cpus :: kernel.cpus
            hardware_id :: if cast[usize](cpu) < cpus.count { cpus[cast[usize](cpu)].hardware_id } else { cast[u64](0) }
            irq.message = arch.route_msi(device.msi_source, event, hardware_id, id)
        }
        case Error(error) => {
            // Its event, free again: nothing else has it yet
            concurrency.lock(&device.lock)
            unlink_irq(device, irq)
            concurrency.unlock(&device.lock)
            release_object(kernel, object)
            return .Error(.NoFreeInterrupt)
        }
    }
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(irq)
}

/*
 * Destroying a message-signaled IRQ: its event no longer delivered, and free on its device, unless the device is
 * being destroyed, which forgets every event at once; then its route.
 */
destroy_msi_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    device :: cast[ptr[mut Device]](irq.device)
    concurrency.lock(&device.lock)
    if irq.in_device {
        arch.unroute_msi(irq.msi_source, irq.line)
        unlink_irq(device, irq)
    }
    concurrency.unlock(&device.lock)
    if cast[usize](irq.slot) < MAX_DEVICE_INTERRUPTS {
        unroute(kernel, irq.cpu, irq.slot)
    }
}

create_dma_domain :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64) -> Result[ptr[mut DmaDomain], slop_os.DeviceError] {
    object := cast[u64](0)
    match new_object(kernel, .DmaDomain, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(cast[ptr[mut DmaDomain]](object))
}

// A domain holds nothing yet: what an IOMMU's will hold is its page tables.
destroy_dma_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
}

release_dma_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
}

/*
 * DMA memory in domain, size bytes, ending at or below limit (0 for none), owned by owner and charged to budget: in
 * one block of frames, pinned for as long as it lives.
 */
create_dma_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, domain: ptr[DmaDomain], size: u64, limit: u64)
    -> Result[ptr[mut Memory], slop_os.DeviceError] {
    memory :: create_contiguous_memory(kernel, owner, budget, size, limit, 3)?
    memory.domain = cast[u64](domain)
    memory.domain_generation = domain.header.generation
    return .Ok(memory)
}

// Where DMA memory is to its domain's devices: without an IOMMU, its physical address.
device_address_of :: fn(memory: ptr[Memory]) -> Result[u64, slop_os.DeviceError] {
    if memory.domain == 0 || !is_live(memory.domain, memory.domain_generation) {
        return .Error(.NotDmaMemory)
    }
    return .Ok(memory.physical)
}

// The interrupt controller's MSIs, set up once every CPU has started, with the memory it asks for, which it keeps.
start_msis :: fn(kernel: ptr[mut Kernel]) {
    size :: arch.msi_controller_memory()
    if size == 0 {
        return void
    }
    match frames.allocate_zeroed(&kernel.frames, frames.order_for(size)) {
        case Ok(memory) => arch.init_msi(memory)
        case Error(error) => runtime.log_error("no memory for the interrupt controller's MSIs: % bytes", size)
    }
}
