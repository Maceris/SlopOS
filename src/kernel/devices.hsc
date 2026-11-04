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

/** A device, a kernel object: one PCIe function, its message-signaled IRQs, and the DMA domain it's attached to. */
Device :: struct #align(16) {
    /** The object's header; first, as for every kernel object. */
    header : ObjectHeader,
    /** Held (rank Device, before devices_lock, interrupts_lock and an IOMMU's) for its IRQs, events and domain. */
    lock : concurrency.SpinLock,
    /** Its address (slop_os.device_address): its segment in the upper 16 bits, its requester ID in the lower. */
    address : u32,
    /** The source the interrupt controller knows its MSIs by (the ITS's device ID on AArch64; unused on x86-64). */
    msi_source : u32,
    /** Its configuration space, mapped in the kernel's window, for turning its DMA off when it's destroyed. */
    config : u64,
    /** Its events in use, a bit each, below slop_os.MAX_DEVICE_MSIS. */
    events : u32,
    /** Its first message-signaled IRQ, as its address, 0 for none; the list is under lock. */
    first_irq : u64,
    /** The DmaDomain it's attached to, as its address, 0 for none. */
    domain : u64,
    /** The domain's generation when it was attached, so a destroyed domain isn't taken for it. */
    domain_generation : u32,
    /** The IOMMU it's behind, as attaching it found, and its stream there. */
    iommu : IommuPath,
    /** Whether its DMA goes through its domain's tables on its IOMMU. */
    translated : bool,
    /** Held (rank Watchers) for watchers. */
    watch_lock : concurrency.SpinLock,
    /** Bindings watching for its DMA to be blocked (SIGNAL_DMA_FAULT), under watch_lock. */
    watchers : EndBinding[2],
    /** The physical address of what the interrupt controller keeps for its MSIs, 0 for none. */
    msi_memory : u64,
    /** The order of msi_memory's block of frames plus one, 0 for none. */
    msi_memory_order : u64,
    /** Its next neighbor among the kernel's devices, under devices_lock, 0 for none. */
    next : u64,
    /** Its previous neighbor among the kernel's devices, under devices_lock, 0 for none. */
    previous : u64,
    /** Whether it's on the kernel's list of devices, under devices_lock. */
    listed : bool,
}

/** A DMA domain, a kernel object: what its devices' DMA reaches, the DMA memory made in it. */
DmaDomain :: struct #align(16) {
    /** The object's header; first, as for every kernel object. */
    header : ObjectHeader,
    /** Whether it may have DMA memory where no IOMMU translates it, for a trusted driver (decisions/0084). */
    trusted : bool,
    /**
     * Whether it's bound to an IOMMU, or to none, by its first device attached or its first DMA memory; under the
     * kernel's iommus_lock.
     */
    bound : bool,
    /** The number plus one of the IOMMU it's bound to, 0 for none; under the kernel's iommus_lock. */
    iommu : u32,
    /** Whether it translates on its IOMMU, under that IOMMU's lock. */
    translating : bool,
    /** Whether its translation was stopped as it was destroyed, with its tables still to go; under the IOMMU's lock. */
    stopped : bool,
    /** Its IOMMU implementation's state for it. */
    unit : iommu_unit.Domain,
    /** Its domain ID on its IOMMU. */
    id : u32,
    /** The physical address of its root table, a frame charged to it. */
    root : u64,
    /** The lowest I/O virtual address never given out yet, from FIRST_DEVICE_ADDRESS. */
    next_address : u64,
    /** The I/O virtual addresses it gives out are below this: 2 to the IOMMU's address bits. */
    address_limit : u64,
    /**
     * Where the high range starts, which is handed out from its free range, 0 for none (translation.hsc,
     * HIGH_DEVICE_BYTES).
     */
    high_start : u64,
    /** The MSI doorbell's page, mapped at its own address, 0 for none. */
    reserved : u64,
    /** Ranges of its I/O virtual addresses freed, kept for reuse; the first free_count are used. */
    free_ranges : AddressRange[MAX_FREE_RANGES],
    /** How many of free_ranges are used. */
    free_count : u32,
}

/**
 * Make a device, for one PCIe function, with what the interrupt controller keeps for its MSIs.
 *
 * No other device may have its address, nor, where the controller uses sources, its source. The device's charge
 * includes the block of frames the controller keeps for it.
 *
 * @param kernel The kernel: the object comes from its Device pool, config is mapped into its window, the MSI
 *     block comes from its frames, and the device joins its list of devices under devices_lock.
 * @param owner The Process to own it, as its address, or 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, as its address, or 0 for the kernel's own.
 * @param address Its address (slop_os.device_address): its segment in the upper 16 bits, its requester ID in the
 *     lower.
 * @param msi_source The source its MSIs come from as the interrupt controller sees them; unused where it uses none.
 * @param config The physical address of its configuration space, CONFIG_BYTES of it: page aligned, not 0, and not
 *     RAM the kernel owns. It's mapped, so its DMA can be turned off when it's destroyed.
 * @return The device, owned by owner, attached to no domain; the caller makes a handle to it.
 * @error BadAddress config was 0, unaligned, too high, or RAM the kernel owns.
 * @error OutOfMemory No memory for the object or what the controller keeps, or room to map config.
 * @error BudgetExceeded budget hadn't room for the object and what the controller keeps, or is closed.
 * @error DeviceExists Another device has the address, or, where the controller uses sources, the source.
 * @error ObjectGone owner is being destroyed; the device is destroyed again.
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
    // Each device listed, none for the first one made
    loop {
        if other == 0 {
            break
        }
        listed :: cast[ptr[Device]](other)
        if listed.address == address || (order != 0 && listed.msi_source == msi_source) {
            taken = true
            break
        }
        other = listed.next
    }
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
/** The bytes of a PCIe function's configuration space the kernel maps: its first page. */
CONFIG_BYTES : u64 : 4096
/** The command register's offset in configuration space, in bytes; it's 16 bits. */
PCI_COMMAND : u64 : 0x04
/** The command register's Bus Master Enable bit, which lets the function start DMA. */
PCI_COMMAND_BUS_MASTER : u16 : 1 << 2

/**
 * Attach a device to a DMA domain, so its DMA reaches the domain's memory from now on, and nothing else where its
 * IOMMU translates.
 *
 * The domain is bound to the device's IOMMU by its first device, or by its first DMA memory to none; a device behind
 * another isn't attached. A device attached elsewhere is detached first. Where the IOMMU translates and the domain
 * isn't on it yet, the domain gets an ID and a root table there, charged to its budget. Takes the device's lock, then
 * iommus_lock, then the IOMMU's.
 *
 * @param kernel The kernel, whose iommus_lock is taken to bind the domain, and whose IOMMU's lock is taken to
 *     detach and attach the device's stream.
 * @param device The device, not dying; its lock is taken, so the caller holds none of rank Device or above.
 * @param domain The domain, whose devices are all behind one IOMMU, or all behind none.
 * @error WrongIommu The device is behind another IOMMU than the domain's, or none where it's bound to one, or the
 *     other way; nothing changes.
 * @error OutOfMemory No domain ID, root table or IOMMU table could be had; the device is detached from its old
 *     domain and attached to none.
 * @error BudgetExceeded The domain's budget couldn't pay for its root table; the device is attached to none.
 */
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

/**
 * Destroy a device, as destroy_object does each kind: its DMA turned off and blocked, its IRQs destroyed, and it
 * forgotten by the interrupt controller and the kernel's devices.
 *
 * Bus Master Enable is cleared first, then the device is detached from its domain. Each IRQ is taken off its list,
 * then destroyed once the destroy running on this CPU is done (destroy_later). Takes the device's lock, then
 * devices_lock, one after the other.
 *
 * @param kernel The kernel, whose devices_lock is taken to take the device off its list, and whose IOMMU's lock
 *     to detach it; called from destroy_object, on any CPU, with interrupts off.
 * @param device The device being destroyed, already dying.
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

/**
 * Release a destroyed device, as release_object does each kind once no CPU can use it: its configuration space
 * unmapped, and the frames the interrupt controller kept for its MSIs freed.
 *
 * @param kernel The kernel, whose window config is unmapped from and whose frames the MSI block goes back to;
 *     called from release_object once every CPU has passed a quiescent point since the destroy.
 * @param device The destroyed device, or one create_device gave up on, with what it got so far.
 */
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

/**
 * Take a message-signaled IRQ off its device's list, if it's on it, its event free again.
 *
 * @param device The IRQ's device, whose lock the caller holds.
 * @param irq The IRQ; one not on the list is left alone.
 */
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

/**
 * Make a message-signaled IRQ for the lowest free event of a device's, routed to the next CPU in turn that the
 * owner's CPU budget has, and remapped by its IOMMU where that remaps interrupts.
 *
 * The IRQ's message is what the device's driver programs into the device's MSI or MSI-X table. Takes the device's
 * lock, then interrupts_lock and the IOMMU's, one after the other.
 *
 * @param kernel The kernel: the object comes from its Irq pool, its CPUs' routes are changed under
 *     interrupts_lock, and next_irq_cpu advances.
 * @param owner The Process to own it, as its address, or 0 for the kernel, which routes it to any online CPU.
 * @param budget The MemoryBudget the object is charged to, as its address, or 0 for the kernel's own.
 * @param device The device whose event it is.
 * @return The IRQ, edge-triggered, owned by owner, with no binding yet; the caller makes a handle to it.
 * @error NoMsi The interrupt controller takes no MSIs.
 * @error OutOfMemory No memory could be had for the object.
 * @error BudgetExceeded budget hadn't room for the object, or is closed.
 * @error ObjectGone The device, or owner, is being destroyed.
 * @error TooManyVectors Every one of the device's slop_os.MAX_DEVICE_MSIS events has an IRQ.
 * @error NoFreeInterrupt The CPU picked has no device interrupt ID free, or its IOMMU no remapped interrupt; the
 *     event is free again.
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

/**
 * Route a message-signaled IRQ to another CPU (decisions/0099).
 *
 * A route there is made first, then its IOMMU's entry for it is pointed there, or its event moved (the ITS's MOVI),
 * or a new message made for its driver to program; then its old route is forgotten. Where the message changes
 * (x86-64 without interrupt remapping), what the device raises before its driver programs the new one is lost; the
 * caller reads the IRQ's message after. Takes the device's lock, holding it throughout.
 *
 * @param kernel The kernel, whose CPUs' routes are changed under interrupts_lock, and whose IOMMU's lock is taken
 *     when the IRQ is remapped.
 * @param irq The IRQ, which has to be message-signaled.
 * @param cpu_index The index of the CPU to route it to; the one it's on already changes nothing.
 * @error InvalidArgument No CPU has that index.
 * @error ObjectGone The IRQ is off its device's list, as its device is being destroyed, or isn't routed.
 * @error NoFreeInterrupt That CPU has no device interrupt ID free, or hasn't started; the IRQ stays where it was.
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

/**
 * Destroy a message-signaled IRQ, for destroy_irq: its event no longer delivered, and free on its device, unless the
 * device is being destroyed, which forgets every event at once; then its IOMMU's entry freed and its route forgotten.
 *
 * @param kernel The kernel, whose CPU's route is forgotten under interrupts_lock, and whose IOMMU's lock is taken
 *     to free the remapping entry; called from destroy_irq, with interrupts off.
 * @param irq The message-signaled IRQ being destroyed.
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

/**
 * Make a DMA domain, bound to no IOMMU until its first device or DMA memory.
 *
 * @param kernel The kernel, whose DmaDomain pool the object comes from.
 * @param owner The Process to own it, as its address, or 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, as its address, or 0 for the kernel's own; its tables on an
 *     IOMMU are charged to it as well.
 * @param trusted Whether it may have DMA memory no IOMMU confines, for a trusted driver (decisions/0084).
 * @return The domain, owned by owner; the caller makes a handle to it.
 * @error OutOfMemory No memory could be had for the object.
 * @error BudgetExceeded budget hadn't room for the object, or is closed.
 * @error ObjectGone owner is being destroyed; the domain is destroyed again.
 */
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

/**
 * Destroy a DMA domain, as destroy_object does each kind: its devices detached, and its translation stopped; its
 * tables go once no CPU can be using them (release_dma_domain).
 *
 * @param kernel The kernel, whose IOMMU's lock is taken to stop the domain's translation; called from
 *     destroy_object, on any CPU, with interrupts off.
 * @param domain The domain being destroyed, already dying.
 */
destroy_dma_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    stop_domain(kernel, domain)
}

/**
 * Release a destroyed DMA domain, as release_object does each kind once no CPU can use it: its tables, root and
 * domain ID given back.
 *
 * @param kernel The kernel, whose frames the domain's tables and root go back to, and whose IOMMU gets its domain
 *     ID back; called from release_object once no CPU can still be using them.
 * @param domain The destroyed domain, stopped by destroy_dma_domain; its memory is freed by release_object after.
 */
release_dma_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    release_domain_tables(kernel, domain)
}

/**
 * Make DMA memory in a domain: one block of frames, zeroed and pinned for as long as it lives.
 *
 * A domain that translates maps it at the lowest free I/O virtual addresses below limit, and its frames may be
 * anywhere; otherwise its device addresses are its physical addresses, its frames are below limit, and only a
 * trusted domain has any (decisions/0084). A domain no device is attached to yet is bound to no IOMMU by this.
 *
 * @param kernel The kernel: iommus_lock is taken to bind the domain, the block comes from its frames, and the
 *     IOMMU's lock is taken to map it.
 * @param owner The Process to own it, as its address, or 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, the whole block, as its address, or 0 for the kernel's own.
 * @param domain The domain its devices reach it through.
 * @param size Its size in bytes: a whole number of pages, not 0, at most slop_os.MAX_MEMORY_SIZE.
 * @param limit The address its device addresses end at or below, for a device that can't reach every address; 0
 *     for none. At least size.
 * @return The memory, owned by owner, which can be mapped readable and writable; device_address_of gives where its
 *     devices reach it.
 * @error Untrusted The domain isn't on a translating IOMMU, and wasn't made trusted.
 * @error InvalidSize size was 0, not a whole number of pages or too big, or limit was below it.
 * @error OutOfMemory No memory for the object, no block of frames below limit, or no I/O virtual addresses or
 *     tables to map it.
 * @error BudgetExceeded budget hadn't room for the block, or is closed, or the domain's budget for its tables.
 * @error ObjectGone owner is being destroyed; the memory is destroyed again.
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

/**
 * Find where DMA memory is to its domain's devices.
 *
 * @param memory The memory, which isn't changed.
 * @return The I/O virtual address its domain mapped it at, or without a translating IOMMU, its physical address.
 * @error NotDmaMemory It isn't DMA memory, or its domain was destroyed.
 */
device_address_of :: fn(memory: ptr[Memory]) -> Result[u64, slop_os.DeviceError] {
    if memory.domain == 0 || !is_live(memory.domain, memory.domain_generation) {
        return .Error(.NotDmaMemory)
    }
    return .Ok(if memory.device_address != 0 { memory.device_address } else { memory.physical })
}

/**
 * Set up the interrupt controller's MSIs, once every CPU has started, with the memory it asks for, which it keeps for
 * good. Without that memory, MSIs aren't set up, and that's logged.
 *
 * @param kernel The kernel, whose frames the memory comes from.
 */
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
