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
    import iommu_vtd as iommu_unit from "../iommu/vtd"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
    import iommu_smmuv3 as iommu_unit from "../iommu/smmuv3"
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
 * A DmaDomain is where its devices' DMA reaches. DMA memory, pinned and in one block of frames, is made in a domain.
 * Attaching a device to a domain records it, and the IOMMU it's behind (iommus.hsc), which the domain is bound to by
 * its first device, or by its first DMA memory to none: a domain's devices are all behind that IOMMU, or all behind
 * none. Where the IOMMU translates, the domain's memory is mapped at device addresses of its own, and its devices
 * reach nothing else (translation.hsc); without one, that's all of memory, and a device address is a physical address.
 *
 * Lock order: a device's lock, then the kernel's devices_lock, then interrupts_lock; a device's lock, then iommus_lock.
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
    // The IOMMU it's behind, as attaching it found, and its stream there; whether its DMA goes through its domain's tables.
    iommu : IommuPath,
    translated : bool,
    // Bindings watching for its DMA to be blocked (SIGNAL_DMA_FAULT), under watch_lock.
    watch_lock : concurrency.SpinLock,
    watchers : EndBinding[2],
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
    // Whether it may have DMA memory where no IOMMU translates it, for a trusted driver (decisions/0084).
    trusted : bool,
    // Under the kernel's iommus_lock: whether a device was attached or memory made, binding it to that device's IOMMU,
    // the IOMMU's number plus one, or 0 for none.
    bound : bool,
    iommu : u32,
    // Under its IOMMU's lock: whether it translates there, and was, once it's destroyed, with its tables to go; its
    // tables, ID and root; the I/O virtual addresses it gives out, below address_limit, past next_address or freed.
    translating : bool,
    stopped : bool,
    unit : iommu_unit.Domain,
    id : u32,
    root : u64,
    next_address : u64,
    address_limit : u64,
    // Where the high range starts, which is handed out from its free range, 0 for none (translation.hsc, HIGH_DEVICE_BYTES)
    high_start : u64,
    // The MSI doorbell's page, mapped at its own address, 0 for none.
    reserved : u64,
    free_ranges : AddressRange[MAX_FREE_RANGES],
    free_count : u32,
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
    lock_at(&kernel.devices_lock, .Devices)
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
    unlock_at(&kernel.devices_lock, .Devices)
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

// The device's DMA in domain, from now on, if it's behind the IOMMU domain's other devices are.
attach_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device], domain: ptr[mut DmaDomain]) -> Result[void, slop_os.DeviceError] {
    path :: iommu_path(kernel, device.address)
    lock_at(&device.lock, .Device)
    lock_at(&kernel.iommus_lock, .Iommus)
    fits :: !domain.bound || domain.iommu == path.iommu
    if fits {
        domain.bound = true
        domain.iommu = path.iommu
    }
    unlock_at(&kernel.iommus_lock, .Iommus)
    if !fits {
        unlock_at(&device.lock, .Device)
        return .Error(.WrongIommu)
    }
    // Away from the domain it was in, if it was
    untranslate_device(kernel, device)
    device.domain = cast[u64](domain)
    device.domain_generation = domain.header.generation
    device.iommu = path
    match translate_device(kernel, device, domain, path) {
        case Ok => {}
        case Error(error) => {
            device.domain = 0
            unlock_at(&device.lock, .Device)
            return .Error(error)
        }
    }
    unlock_at(&device.lock, .Device)
    return .Ok
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
    // And blocked by its IOMMU, which won't reach its domain's tables once they go
    lock_at(&device.lock, .Device)
    untranslate_device(kernel, device)
    device.domain = 0
    unlock_at(&device.lock, .Device)
    loop {
        lock_at(&device.lock, .Device)
        first :: device.first_irq
        if first != 0 {
            unlink_irq(device, cast[ptr[mut Irq]](first))
        }
        unlock_at(&device.lock, .Device)
        if first == 0 {
            break
        }
        destroy_later(kernel, first, cast[ptr[ObjectHeader]](first).generation)
    }
    lock_at(&kernel.devices_lock, .Devices)
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
    unlock_at(&kernel.devices_lock, .Devices)
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
 * turn that owner's CPU budget has, its message what the device's driver programs into it.
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
    lock_at(&device.lock, .Device)
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
    unlock_at(&device.lock, .Device)
    if gone || event == slop_os.MAX_DEVICE_MSIS {
        release_object(kernel, object)
        return .Error(if gone { slop_os.DeviceError.ObjectGone } else { slop_os.DeviceError.TooManyVectors })
    }
    cpus :: if owner != 0 { cpus_of(kernel, cast[ptr[Process]](owner)) } else { ~cast[u64](0) }
    cpu :: next_cpu_of(kernel, &kernel.next_irq_cpu, cpus)
    first, count :: arch.device_interrupt_range()
    match route_message(kernel, cpu, event, object) {
        case Ok(id) => {
            irq.cpu = cpu
            irq.slot = cast[u32](id) - cast[u32](first)
            cpus :: kernel.cpus
            hardware_id :: if cast[usize](cpu) < cpus.count { cpus[cast[usize](cpu)].hardware_id } else { cast[u64](0) }
            match remap_msi(kernel, irq, device, hardware_id, id) {
                case Some(message) => irq.message = message
                case None => {
                    unroute(kernel, irq.cpu, irq.slot)
                    lock_at(&device.lock, .Device)
                    unlink_irq(device, irq)
                    unlock_at(&device.lock, .Device)
                    release_object(kernel, object)
                    return .Error(.NoFreeInterrupt)
                }
            }
        }
        case Error(error) => {
            // Its event, free again: nothing else has it yet
            lock_at(&device.lock, .Device)
            unlink_irq(device, irq)
            unlock_at(&device.lock, .Device)
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
 * A message-signaled IRQ routed to the CPU with index cpu_index instead (decisions/0099): a route there first, then its
 * IOMMU's entry for it pointed there, or its event moved (the ITS's MOVI), or a new message for its driver to program,
 * and its old route forgotten. Where the message changes (x86-64 without interrupt remapping), what the device raises
 * before its driver programs the new one is lost.
 */
move_msi_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq], cpu_index: u32) -> Result[void, slop_os.DeviceError] {
    cpus :: kernel.cpus
    if cast[usize](cpu_index) >= cpus.count {
        return .Error(.InvalidArgument)
    }
    device :: cast[ptr[mut Device]](irq.device)
    lock_at(&device.lock, .Device)
    defer unlock_at(&device.lock, .Device)
    if !irq.in_device || cast[usize](irq.slot) >= MAX_DEVICE_INTERRUPTS {
        return .Error(.ObjectGone)
    }
    if cpu_index == irq.cpu {
        return .Ok
    }
    first, count :: arch.device_interrupt_range()
    id := first
    match route_message(kernel, cpu_index, irq.line, cast[u64](irq)) {
        case Ok(routed) => id = routed
        case Error(error) => return .Error(.NoFreeInterrupt)
    }
    hardware_id :: cpus[cast[usize](cpu_index)].hardware_id
    if irq.remap_iommu != 0 {
        repoint_msi(kernel, irq, device, hardware_id, id)
    }
    else {
        irq.message = arch.move_msi(irq.msi_source, irq.line, hardware_id, id)
    }
    old_cpu :: irq.cpu
    old_slot :: irq.slot
    irq.cpu = cpu_index
    irq.slot = cast[u32](id) - cast[u32](first)
    unroute(kernel, old_cpu, old_slot)
    return .Ok
}

/*
 * Destroying a message-signaled IRQ: its event no longer delivered, and free on its device, unless the device is
 * being destroyed, which forgets every event at once; then its route.
 */
destroy_msi_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    device :: cast[ptr[mut Device]](irq.device)
    lock_at(&device.lock, .Device)
    if irq.in_device {
        arch.unroute_msi(irq.msi_source, irq.line)
        unlink_irq(device, irq)
    }
    unlock_at(&device.lock, .Device)
    unremap_msi(kernel, irq)
    if cast[usize](irq.slot) < MAX_DEVICE_INTERRUPTS {
        unroute(kernel, irq.cpu, irq.slot)
    }
}

// A domain, trusted with DMA memory no IOMMU confines if trusted.
create_dma_domain :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, trusted: bool) -> Result[ptr[mut DmaDomain], slop_os.DeviceError] {
    object := cast[u64](0)
    match new_object(kernel, .DmaDomain, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    cast[ptr[mut DmaDomain]](object).trusted = trusted
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(cast[ptr[mut DmaDomain]](object))
}

// Its devices detached, and its translation stopped; its tables go once no CPU can be using them.
destroy_dma_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    stop_domain(kernel, domain)
}

release_dma_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    release_domain_tables(kernel, domain)
}

/*
 * DMA memory in domain, size bytes, its device addresses ending at or below limit (0 for none), owned by owner and
 * charged to budget: in one block of frames, pinned for as long as it lives. A domain that translates maps it, and
 * its frames may be anywhere; otherwise they're below limit, and only a trusted domain has any (decisions/0084). A
 * domain no device is attached to yet is bound to none.
 */
create_dma_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, domain: ptr[mut DmaDomain], size: u64, limit: u64)
    -> Result[ptr[mut Memory], slop_os.DeviceError] {
    lock_at(&kernel.iommus_lock, .Iommus)
    if !domain.bound {
        domain.bound = true
        domain.iommu = 0
    }
    unlock_at(&kernel.iommus_lock, .Iommus)
    translates :: translating_iommu(kernel, domain.iommu) is_some
    if !translates && !domain.trusted {
        return .Error(.Untrusted)
    }
    if translates && limit != 0 && limit < size {
        return .Error(.InvalidSize)
    }
    memory :: create_contiguous_memory(kernel, owner, budget, size, if translates { cast[u64](0) } else { limit }, 3)?
    memory.domain = cast[u64](domain)
    memory.domain_generation = domain.header.generation
    match map_dma_memory(kernel, domain, memory, limit) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, cast[u64](memory))
            return .Error(error)
        }
    }
    return .Ok(memory)
}

// Where DMA memory is to its domain's devices: the address its domain mapped it at, or without an IOMMU, its physical address.
device_address_of :: fn(memory: ptr[Memory]) -> Result[u64, slop_os.DeviceError] {
    if memory.domain == 0 || !is_live(memory.domain, memory.domain_generation) {
        return .Error(.NotDmaMemory)
    }
    return .Ok(if memory.device_address != 0 { memory.device_address } else { memory.physical })
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
