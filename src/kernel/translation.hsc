package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import iommu_interface from "../iommu_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import slop_os from "std/os"
import frames from "frames"
import robustness from "../robustness"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
    import iommu_vtd as iommu_unit from "../iommu/vtd"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
    import iommu_smmuv3 as iommu_unit from "../iommu/smmuv3"
}

/*
 * DMA through the IOMMUs (roadmap Db and Dd, decisions/0079, 0081, 0083). An IOMMU (VT-d, SMMUv3) turns translation
 * on once it's registered, every device blocked until it's attached, with its faults signalled to CPU 0 where it can
 * signal them by a message (VT-d), or read at CPU 0's ticks where it can't (SMMUv3, whose interrupts are wired), and
 * logged. Where MSIs are writes an IOMMU translates (AArch64's to the ITS), the doorbell is mapped into each domain at
 * its own address, which the domain's other addresses keep clear of. A domain's first device behind it gives the
 * domain an ID there and a root table, charged to the domain's budget, as the tables mapping its memory are. DMA
 * memory made in a domain that translates is in frames anywhere, mapped at the lowest free I/O virtual addresses of
 * the domain's own below its limit; destroying it unmaps it, and the IOMMU reaches none of it once that returns.
 * Destroying a domain detaches its devices first, and its tables go once nothing can reach them.
 *
 * Interrupt remapping (roadmap Dc): an IOMMU that remaps interrupts (VT-d's) turns it on with translation, and every
 * message-signaled IRQ of a device behind it then has an entry of its own there, its message the entry's handle, which
 * the IOMMU takes only from that device; the compatibility-format messages devices could forge are blocked. Wired
 * lines' are too, as the I/O APIC's entries aren't remapped yet, so no IRQ is made for one once an IOMMU remaps.
 *
 * Everything an IOMMU does is under its lock. Lock order: a device's lock, then an IOMMU's lock.
 */

/** The most domain IDs the kernel keeps track of on each IOMMU; IDs from 1 up are given out, 0 never. */
MAX_DOMAIN_IDS :: 256
/** Where a domain's I/O virtual addresses start, 1 MiB: never 0, so a device given nothing reaches nothing. */
FIRST_DEVICE_ADDRESS : u64 : 1 << 20
/** How many ranges of a domain's I/O virtual addresses freed are kept for reuse; more are never used again. */
MAX_FREE_RANGES :: 16
/** The most faults taken from an IOMMU in one interrupt or tick; the rest wait for the next. */
MAX_FAULTS_TAKEN :: 16
/** A route's controller for an IOMMU's faults, whose line is the IOMMU's number (interrupts.hsc). */
IOMMU_CONTROLLER : u32 : 0xfffffffe
/** The most remapped interrupts the kernel gives out on each IOMMU. */
MAX_REMAPPED_INTERRUPTS :: 256

/** A free range of a domain's I/O virtual addresses. */
AddressRange :: struct {
    /** Its first I/O virtual address, page aligned. */
    start : u64,
    /** Its size in bytes, a whole number of pages. */
    size : u64,
}

/**
 * Turn an IOMMU's translation on, with the memory its implementation asks for, and route its faults to CPU 0.
 *
 * One whose implementation can't translate yet, or that has no memory or fails to start, is left as it was, its
 * domains' device addresses physical addresses; it logs why. One that remaps interrupts blocks wired lines from then
 * on. Faults are signalled by a message to CPU 0 where the IOMMU can, or read at CPU 0's ticks where it can't. Takes
 * the IOMMU's lock. The memory given to the IOMMU is its own for good.
 *
 * @param kernel The kernel: its frame allocator gives the IOMMU's memory, an interrupt on CPU 0 is routed for the
 *     faults, and its wired_lines_blocked and iommus_polled flags may be set.
 * @param index The IOMMU's index in kernel.iommus, registered already.
 */
start_translation :: fn(kernel: ptr[mut Kernel], index: u32) {
    registered :: &kernel.iommus[cast[usize](index) % MAX_IOMMUS]
    if registered.info.memory == 0 {
        runtime.log_info("IOMMU %: not translating, which its implementation can't yet", index)
        return void
    }
    memory := cast[u64](0)
    match frames.allocate_zeroed(&kernel.frames, frames.order_for(registered.info.memory)) {
        case Ok(block) => memory = cast[u64](block)
        case Error(error) => {
            runtime.log_error("IOMMU %: no memory for its tables, so not translating", index)
            return void
        }
    }
    lock_at(&registered.lock, .Iommu)
    enabled :: iommu_unit.enable(&registered.unit, cast[iommu_interface.PhysicalAddress](memory), kernel.frames.direct_map_offset)
    failed := false
    match enabled {
        case Ok => {
            registered.translating = true
            registered.id_limit = if registered.info.domain_ids < MAX_DOMAIN_IDS { registered.info.domain_ids } else { MAX_DOMAIN_IDS - 1 }
            registered.remapping = registered.info.interrupts != 0
            registered.interrupt_limit = if registered.info.interrupts < MAX_REMAPPED_INTERRUPTS { registered.info.interrupts }
                else { MAX_REMAPPED_INTERRUPTS }
        }
        case Error(error) => failed = true
    }
    unlock_at(&registered.lock, .Iommu)
    if failed {
        // What it may have taken of the memory stays its own
        runtime.log_error("IOMMU %: translation didn't go on", index)
        return void
    }
    if registered.remapping {
        intrinsics.atomic_store_u32_release(&kernel.wired_lines_blocked, 1)
    }
    if !registered.info.fault_messages {
        intrinsics.atomic_store_u32_release(&kernel.iommus_polled, 1)
        runtime.log_info("IOMMU %: translating, % interrupts remapped, its faults read at CPU 0's ticks", index, registered.interrupt_limit)
        return void
    }
    match route_message(kernel, 0, index, 0, IOMMU_CONTROLLER) {
        case Ok(id) => {
            cpus :: kernel.cpus
            hardware_id :: if cpus.count > 0 { cpus[0].hardware_id } else { cast[u64](0) }
            message :: arch.route_msi(0, index, hardware_id, id)
            lock_at(&registered.lock, .Iommu)
            iommu_unit.route_faults(&registered.unit, iommu_interface.MsiMessage.{address = message.address, data = message.data})
            unlock_at(&registered.lock, .Iommu)
            runtime.log_info("IOMMU %: translating, % interrupts remapped, its faults to CPU 0's interrupt %", index,
                registered.interrupt_limit, cast[u32](id))
        }
        case Error(error) => runtime.log_warn("IOMMU %: translating, but its faults aren't signalled", index)
    }
}

/**
 * Take the faults of each translating IOMMU that doesn't signal them: called at CPU 0's ticks.
 *
 * Does nothing unless such an IOMMU has been started.
 *
 * @param kernel The kernel, whose iommus_polled flag and registered IOMMUs are read; runs in CPU 0's tick.
 */
poll_dma_faults :: fn(kernel: ptr[mut Kernel]) {
    if intrinsics.atomic_load_u32_acquire(&kernel.iommus_polled) == 0 {
        return void
    }
    for index in 0..<intrinsics.atomic_load_u32_acquire(&kernel.iommu_count) {
        if cast[usize](index) < MAX_IOMMUS && kernel.iommus[cast[usize](index)].translating && !kernel.iommus[cast[usize](index)].info.fault_messages {
            handle_dma_faults(kernel, index)
        }
    }
}

/**
 * Take an IOMMU's faults, at its interrupt or its tick, up to MAX_FAULTS_TAKEN.
 *
 * Each is logged, with the device's address and what it was refused, and raised on the Device the stream is
 * (SIGNAL_DMA_FAULT), for whoever watches its driver (decisions/0084). Takes the IOMMU's lock for each fault, and the
 * devices' lock to signal it.
 *
 * @param kernel The kernel, whose registered IOMMU is read; runs in the IOMMU's interrupt or CPU 0's tick.
 * @param index The IOMMU's index in kernel.iommus; one that isn't registered does nothing.
 */
handle_dma_faults :: fn(kernel: ptr[mut Kernel], index: u32) {
    if index >= intrinsics.atomic_load_u32_acquire(&kernel.iommu_count) || cast[usize](index) >= MAX_IOMMUS {
        return void
    }
    registered :: &kernel.iommus[cast[usize](index)]
    for taken in 0..<MAX_FAULTS_TAKEN {
        lock_at(&registered.lock, .Iommu)
        found :: iommu_unit.next_fault(&registered.unit)
        if found is_some {
            registered.faults += 1
        }
        unlock_at(&registered.lock, .Iommu)
        fault :: found or_return void
        signal_dma_fault(kernel, index, fault)
        bus, slot, function :: (fault.stream >> 8) & 0xff, (fault.stream >> 3) & 0x1f, fault.stream & 7
        if fault.interrupt {
            runtime.log_warn("IOMMU %: blocked an interrupt through remapped interrupt % from %:%.%, reason %", index, fault.address,
                bus, slot, function, fault.reason)
        }
        else {
            runtime.log_warn("IOMMU %: blocked a DMA % at %{#018x} from %:%.%, reason %", index, if fault.write { "write" } else { "read" },
                fault.address, bus, slot, function, fault.reason)
        }
    }
}

/**
 * Raise SIGNAL_DMA_FAULT on the Device translated through an IOMMU as a fault's stream, if there's one.
 *
 * Takes the kernel's devices lock, then the device's watch lock.
 *
 * @param kernel The kernel, whose devices list is searched under devices_lock.
 * @param index The IOMMU's index in kernel.iommus.
 * @param fault The fault; its stream says which device, and its address is the signal's value.
 */
signal_dma_fault :: fn(kernel: ptr[mut Kernel], index: u32, fault: iommu_interface.DmaFault) {
    lock_at(&kernel.devices_lock, .Devices)
    defer unlock_at(&kernel.devices_lock, .Devices)
    with {
        other := kernel.first_device
    }
    loop {
        if other == 0 {
            break
        }
        device :: cast[ptr[mut Device]](other)
        if device.translated && device.iommu.iommu == index + 1 && device.iommu.stream == fault.stream {
            raise_watchers(kernel, &device.watchers, &device.watch_lock, .Watchers, cast[u32](slop_os.SIGNAL_DMA_FAULT), fault.address)
            return void
        }
        other = device.next
    }
}

/**
 * Find the IOMMU a path names, if it translates.
 *
 * @param kernel The kernel, whose iommu_count and registered IOMMUs are read, without a lock: entries are never
 *     removed.
 * @param iommu The IOMMU's number plus one, as a path or a domain names it; 0 for none.
 * @return The registered IOMMU, kept for as long as the kernel runs; null for 0, a number not registered, or an IOMMU
 *     that doesn't translate.
 */
translating_iommu :: fn(kernel: ptr[mut Kernel], iommu: u32) -> ptr[mut RegisteredIommu]? {
    if iommu == 0 || iommu > intrinsics.atomic_load_u32_acquire(&kernel.iommu_count) || cast[usize](iommu) > MAX_IOMMUS {
        return null
    }
    registered :: &kernel.iommus[cast[usize](iommu - 1)]
    return if registered.translating { registered } else { null }
}

/**
 * Attach a device to a domain on its IOMMU, if that translates, so its DMA goes through the domain's tables.
 *
 * The domain is made on the IOMMU first if it's the first device there: an ID, a root table charged to the domain's
 * budget, and the MSI doorbell mapped where MSIs are writes the IOMMU translates. The IOMMU's own context tables are
 * charged to nothing. Takes the IOMMU's lock.
 *
 * @param kernel The kernel: its frame allocator gives the root table and this CPU's frame cache the IOMMU's tables.
 * @param device The device, whose lock the caller holds; it's marked translated once attached.
 * @param domain The DMA domain it joins.
 * @param path Where the device is: its IOMMU's number plus one, 0 for none, and its stream there.
 * @return Nothing; a device behind no translating IOMMU succeeds with nothing done.
 * @error OutOfMemory No domain ID is free, or no frame for the root table or the IOMMU's tables; a domain made on the
 *     IOMMU in the call stays made.
 * @error BudgetExceeded The domain's budget can't pay for its root table; nothing is made.
 */
translate_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device], domain: ptr[mut DmaDomain], path: IommuPath)
    -> Result[void, slop_os.DeviceError] {
    registered :: translating_iommu(kernel, path.iommu) or_return .Ok
    lock_at(&registered.lock, .Iommu)
    defer unlock_at(&registered.lock, .Iommu)
    if !domain.translating {
        id :: take_domain_id(registered) or_return .Error(.OutOfMemory)
        if !charge_more(cast[u64](domain), frames.FRAME_SIZE) {
            give_domain_id(registered, id)
            return .Error(.BudgetExceeded)
        }
        root := cast[u64](0)
        match frames.allocate_zeroed(&kernel.frames, 0) {
            case Ok(frame) => root = cast[u64](frame)
            case Error(error) => {
                uncharge(cast[u64](domain), domain.header.generation, frames.FRAME_SIZE)
                give_domain_id(registered, id)
                return .Error(.OutOfMemory)
            }
        }
        iommu_unit.init_domain(&registered.unit, &domain.unit, id, cast[iommu_interface.PhysicalAddress](root))
        domain.translating = true
        domain.id = id
        domain.root = root
        domain.next_address = FIRST_DEVICE_ADDRESS
        domain.address_limit = cast[u64](1) << cast[u64](registered.info.address_bits)
        // With robustness=on, the domain's last addresses are a free range from the start, so what can reach them gets them
        if HIGH_DEVICE_BYTES != 0 && domain.address_limit > FIRST_DEVICE_ADDRESS + 2 * HIGH_DEVICE_BYTES {
            domain.high_start = domain.address_limit - HIGH_DEVICE_BYTES
            domain.free_ranges[0] = AddressRange.{start = domain.high_start, size = HIGH_DEVICE_BYTES}
            domain.free_count = 1
        }
        match map_doorbell(kernel, registered, domain) {
            case Some(error) => {
                runtime.log_warn("a domain on IOMMU % has no MSI doorbell, so its devices' MSIs won't arrive", path.iommu - 1)
            }
            case None => {}
        }
    }
    // Context tables and the like are the IOMMU's own, kept for as long as it is, so they're charged to nothing
    tables : iommu_interface.TableFrames
    defer give_back_iommu_tables(kernel, &tables, 0)
    loop {
        match iommu_unit.attach(&registered.unit, &domain.unit, path.stream, &tables) {
            case Ok => break
            case Error(error) => {
                if error != .NeedFrames || !refill_iommu_tables(kernel, &tables, 0) {
                    return .Error(.OutOfMemory)
                }
            }
        }
    }
    device.translated = true
    return .Ok
}

/**
 * Map the MSI doorbell into a new domain at its own address, where MSIs are writes the IOMMU translates.
 *
 * It's mapped writable device memory, its tables charged to the domain, and its page is kept out of the domain's other
 * addresses.
 *
 * @param kernel The kernel, whose frame cache gives the tables, charged to the domain.
 * @param registered The IOMMU, whose lock the caller holds.
 * @param domain The domain, made on the IOMMU just now; its reserved is set to the doorbell's page.
 * @return Null once it's mapped, or when the architecture has no doorbell to map; InvalidAddress if the doorbell is
 *     past the domain's addresses; the IOMMU's error, NeedFrames among them when no frame or budget was left.
 */
map_doorbell :: fn(kernel: ptr[mut Kernel], registered: ptr[mut RegisteredIommu], domain: ptr[mut DmaDomain]) -> iommu_interface.MapError? {
    doorbell :: cast[u64](arch.msi_doorbell() or_return null)
    if doorbell >= domain.address_limit {
        return iommu_interface.MapError.InvalidAddress
    }
    domain.reserved = doorbell
    tables : iommu_interface.TableFrames
    defer give_back_iommu_tables(kernel, &tables, cast[u64](domain))
    loop {
        match iommu_unit.map(&registered.unit, &domain.unit, doorbell, cast[iommu_interface.PhysicalAddress](doorbell), true, true, &tables) {
            case Ok => break
            case Error(error) => {
                if error != .NeedFrames || !refill_iommu_tables(kernel, &tables, cast[u64](domain)) {
                    return error
                }
            }
        }
    }
    iommu_unit.invalidate(&registered.unit, &domain.unit, true)
    return null
}

/**
 * Block a device's DMA again by detaching it from its domain, if it was translated through it.
 *
 * Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose registered IOMMU the device is behind.
 * @param device The device, whose lock the caller holds; it isn't marked translated after.
 */
untranslate_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device]) {
    if !device.translated {
        return void
    }
    device.translated = false
    registered :: translating_iommu(kernel, device.iommu.iommu) or_return void
    domain :: cast[ptr[mut DmaDomain]](device.domain)
    lock_at(&registered.lock, .Iommu)
    iommu_unit.detach(&registered.unit, &domain.unit, device.iommu.stream)
    unlock_at(&registered.lock, .Iommu)
}

/**
 * Map DMA memory into its domain, if that translates, setting the memory's device address.
 *
 * It goes at the lowest free I/O virtual addresses below limit, each page writable, tables charged to the domain.
 * Nothing is left mapped if it can't all be. Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose frame cache gives the tables, charged to the domain.
 * @param domain The memory's domain.
 * @param memory Contiguous DMA memory; its device_address is set once it's mapped.
 * @param limit The I/O virtual address the memory has to end at or below, for devices that reach only so far; 0, or
 *     one past the domain's addresses, for the domain's limit.
 * @return Nothing; memory in a domain that doesn't translate succeeds unmapped, and its device address stays 0.
 * @error OutOfMemory No free range of addresses that big below limit, or no frame or budget for the tables.
 */
map_dma_memory :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain], memory: ptr[mut Memory], limit: u64)
    -> Result[void, slop_os.DeviceError] {
    registered :: translating_iommu(kernel, domain.iommu) or_return .Ok
    lock_at(&registered.lock, .Iommu)
    defer unlock_at(&registered.lock, .Iommu)
    if !domain.translating {
        return .Ok
    }
    top :: if limit == 0 || limit > domain.address_limit { domain.address_limit } else { limit }
    address :: take_device_addresses(domain, memory.size, top) or_return .Error(.OutOfMemory)
    tables : iommu_interface.TableFrames
    defer give_back_iommu_tables(kernel, &tables, cast[u64](domain))
    pages :: memory.size / frames.FRAME_SIZE
    for page in 0..<pages {
        offset :: page * frames.FRAME_SIZE
        mapped := false
        loop {
            match iommu_unit.map(&registered.unit, &domain.unit, address + offset,
                cast[iommu_interface.PhysicalAddress](memory.physical + offset), true, false, &tables) {
                case Ok => mapped = true
                case Error(error) => {
                    if error == .NeedFrames && refill_iommu_tables(kernel, &tables, cast[u64](domain)) {
                        continue
                    }
                }
            }
            break
        }
        if !mapped {
            for undone in 0..<page {
                iommu_unit.unmap(&registered.unit, &domain.unit, address + undone * frames.FRAME_SIZE)
            }
            iommu_unit.invalidate(&registered.unit, &domain.unit, false)
            give_device_addresses(domain, address, memory.size)
            return .Error(.OutOfMemory)
        }
    }
    iommu_unit.invalidate(&registered.unit, &domain.unit, true)
    memory.device_address = address
    return .Ok
}

/**
 * Unmap DMA memory from its domain, if it was mapped and the domain still translates.
 *
 * The IOMMU reaches none of it once this returns. Its addresses go back to the domain. Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose registered IOMMU the domain is on.
 * @param memory The memory, of any kind; memory that isn't mapped in a domain is left alone. Its device address is 0
 *     after.
 */
unmap_dma_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    address :: memory.device_address
    if address == 0 || memory.domain == 0 {
        return void
    }
    memory.device_address = 0
    domain :: cast[ptr[mut DmaDomain]](memory.domain)
    registered :: translating_iommu(kernel, domain.iommu) or_return void
    lock_at(&registered.lock, .Iommu)
    if domain.translating && intrinsics.atomic_load_u32_acquire(&domain.header.generation) == memory.domain_generation {
        for page in 0..<memory.size / frames.FRAME_SIZE {
            iommu_unit.unmap(&registered.unit, &domain.unit, address + page * frames.FRAME_SIZE)
        }
        iommu_unit.invalidate(&registered.unit, &domain.unit, false)
        give_device_addresses(domain, address, memory.size)
    }
    unlock_at(&registered.lock, .Iommu)
}

/**
 * Stop a domain being destroyed: detach every device attached to it, and stop its translation, so DMA memory of it
 * destroyed later has nothing to unmap.
 *
 * Its tables stay until release_domain_tables. Takes the devices lock, each device's lock, and the IOMMU's lock, in
 * turn.
 *
 * @param kernel The kernel, whose devices list is searched under devices_lock, again after each device it detaches.
 * @param domain The domain being destroyed.
 */
stop_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    loop {
        found := cast[u64](0)
        lock_at(&kernel.devices_lock, .Devices)
        with {
            other := kernel.first_device
        }
        loop {
            if other == 0 {
                break
            }
            if cast[ptr[Device]](other).domain == cast[u64](domain) {
                found = other
                break
            }
            other = cast[ptr[Device]](other).next
        }
        unlock_at(&kernel.devices_lock, .Devices)
        if found == 0 {
            break
        }
        device :: cast[ptr[mut Device]](found)
        lock_at(&device.lock, .Device)
        if device.domain == cast[u64](domain) {
            untranslate_device(kernel, device)
            device.domain = 0
        }
        unlock_at(&device.lock, .Device)
    }
    registered :: translating_iommu(kernel, domain.iommu) or_return void
    lock_at(&registered.lock, .Iommu)
    domain.stopped = domain.translating
    domain.translating = false
    unlock_at(&registered.lock, .Iommu)
}

/**
 * Free a stopped domain's tables, its root and its ID, once nothing can reach them.
 *
 * Does nothing for a domain that wasn't stopped while translating, and nothing a second time. Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose frame allocator the tables go back to.
 * @param domain The domain, destroyed.
 */
release_domain_tables :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    if !domain.stopped {
        return void
    }
    domain.stopped = false
    registered :: translating_iommu(kernel, domain.iommu) or_return void
    lock_at(&registered.lock, .Iommu)
    loop {
        freed : iommu_interface.FreedFrames
        done :: iommu_unit.release_domain(&registered.unit, &domain.unit, &freed)
        for i in 0..<cast[usize](freed.count) {
            if i < freed.frames.count {
                frames.free(&kernel.frames, cast[boot_info.PhysicalAddress](freed.frames[i]), 0)
            }
        }
        if done {
            break
        }
    }
    frames.free(&kernel.frames, cast[boot_info.PhysicalAddress](domain.root), 0)
    give_domain_id(registered, domain.id)
    unlock_at(&registered.lock, .Iommu)
}

/**
 * Make the message for a message-signaled IRQ of a device's, remapped by the IOMMU it's behind if that remaps
 * interrupts.
 *
 * A remapped IRQ takes an entry of the IOMMU's, which only the device can raise. Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose IOMMU the device is behind (found from its address); that IOMMU's lock is taken.
 * @param irq The IRQ; its remap_iommu and remap_index are set when it's remapped.
 * @param device The device the IRQ is of.
 * @param hardware_id The hardware ID of the CPU it goes to.
 * @param id The interrupt ID on that CPU.
 * @return The message the device writes: the remapped entry's handle, or where its IOMMU doesn't remap, the
 *     architecture's own message. Null if every remapped interrupt on the IOMMU is taken.
 */
remap_msi :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq], device: ptr[Device], hardware_id: u64, id: arch_interface.InterruptId)
    -> arch_interface.MsiMessage? {
    message :: arch.route_msi(device.msi_source, irq.line, hardware_id, id)
    path :: iommu_path(kernel, device.address)
    registered :: translating_iommu(kernel, path.iommu) or_return message
    if !registered.remapping {
        return message
    }
    lock_at(&registered.lock, .Iommu)
    defer unlock_at(&registered.lock, .Iommu)
    index := registered.interrupt_limit
    for i in 0..<registered.interrupt_limit {
        word :: cast[usize](i / 64) % registered.interrupts.count
        bit :: cast[u64](1) << cast[u64](i % 64)
        if registered.interrupts[word] & bit == 0 {
            registered.interrupts[word] |= bit
            index = i
            break
        }
    }
    if index == registered.interrupt_limit {
        return null
    }
    remapped :: iommu_unit.remap_interrupt(&registered.unit, index, path.stream, hardware_id, cast[u32](id))
    irq.remap_iommu = path.iommu
    irq.remap_index = index
    return arch_interface.MsiMessage.{address = remapped.address, data = remapped.data}
}

/**
 * Point a remapped IRQ's entry at another interrupt or CPU; its message stays as it was.
 *
 * Does nothing for an IRQ that isn't remapped. Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose IOMMU the IRQ was remapped on; that IOMMU's lock is taken.
 * @param irq The IRQ, remapped by remap_msi.
 * @param device The device the IRQ is of.
 * @param hardware_id The hardware ID of the CPU it goes to now.
 * @param id The interrupt ID on that CPU.
 */
repoint_msi :: fn(kernel: ptr[mut Kernel], irq: ptr[Irq], device: ptr[Device], hardware_id: u64, id: arch_interface.InterruptId) {
    registered :: translating_iommu(kernel, irq.remap_iommu) or_return void
    path :: iommu_path(kernel, device.address)
    lock_at(&registered.lock, .Iommu)
    _ = iommu_unit.remap_interrupt(&registered.unit, irq.remap_index, path.stream, hardware_id, cast[u32](id))
    unlock_at(&registered.lock, .Iommu)
}

/**
 * Free a remapped IRQ's entry, which raises nothing from then on.
 *
 * Does nothing for an IRQ that isn't remapped. Takes the IOMMU's lock.
 *
 * @param kernel The kernel, whose IOMMU the IRQ was remapped on; that IOMMU's lock is taken.
 * @param irq The IRQ; its remap_iommu is 0 after.
 */
unremap_msi :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    if irq.remap_iommu == 0 {
        return void
    }
    registered :: translating_iommu(kernel, irq.remap_iommu) or_return void
    irq.remap_iommu = 0
    lock_at(&registered.lock, .Iommu)
    iommu_unit.unmap_interrupt(&registered.unit, irq.remap_index)
    registered.interrupts[cast[usize](irq.remap_index / 64) % registered.interrupts.count] &= ~(cast[u64](1) << cast[u64](irq.remap_index % 64))
    unlock_at(&registered.lock, .Iommu)
}

#if robustness.ON {
    /**
     * How much at the top of each DMA domain's addresses is free from the start, in bytes: with robustness=on 64 MiB,
     * so devices that can reach the top of the domain use addresses just below it (decisions/0096, 0105).
     */
    HIGH_DEVICE_BYTES : u64 : 64 << 20
}
#else {
    /** How much at the top of each DMA domain's addresses is free from the start, in bytes: none without robustness. */
    HIGH_DEVICE_BYTES : u64 : 0
}

/**
 * Take a range of a domain's I/O virtual addresses below a limit: from the ranges freed, or past every one taken.
 *
 * The first freed range that fits is used, then the lowest addresses never given out, kept clear of the doorbell's
 * page and below the high range. Can fail by fault injection (Iova). The caller holds the IOMMU's lock.
 *
 * @param domain The domain, translating, whose IOMMU's lock the caller holds; its free ranges and next_address change.
 * @param size The range's size in bytes, a whole number of pages.
 * @param top The address the range has to end at or below.
 * @return The range's first I/O virtual address; null if no range that big is free below top.
 */
take_device_addresses :: fn(domain: ptr[mut DmaDomain], size: u64, top: u64) -> u64? {
    if fails(.Iova) {
        return null
    }
    for i in 0..<cast[usize](domain.free_count) {
        if i >= MAX_FREE_RANGES {
            break
        }
        range :: domain.free_ranges[i]
        if range.size >= size && range.start + size <= top {
            if range.size == size {
                domain.free_count -= 1
                domain.free_ranges[i] = domain.free_ranges[cast[usize](domain.free_count) % MAX_FREE_RANGES]
            }
            else {
                domain.free_ranges[i] = AddressRange.{start = range.start + size, size = range.size - size}
            }
            return range.start
        }
    }
    // Past the doorbell's page, if it's in the way
    if domain.reserved != 0 && domain.next_address < domain.reserved + frames.FRAME_SIZE && domain.next_address + size > domain.reserved {
        domain.next_address = domain.reserved + frames.FRAME_SIZE
    }
    // Below the high range, if there is one: it's handed out from its free range
    ceiling :: if domain.high_start != 0 && domain.high_start < top { domain.high_start } else { top }
    if domain.next_address > ceiling || size > ceiling - domain.next_address {
        return null
    }
    start :: domain.next_address
    domain.next_address += size
    return start
}

/**
 * Give a range of a domain's I/O virtual addresses back, for reuse.
 *
 * A range just below the addresses never given out joins them; another is kept among the freed ranges, and where
 * there's no room to keep it, its addresses aren't used again. The caller holds the IOMMU's lock.
 *
 * @param domain The domain, whose IOMMU's lock the caller holds; its free ranges or next_address change.
 * @param start The range's first address, as take_device_addresses gave it.
 * @param size Its size in bytes, as take_device_addresses was given.
 */
give_device_addresses :: fn(domain: ptr[mut DmaDomain], start: u64, size: u64) {
    if start + size == domain.next_address {
        domain.next_address = start
        return void
    }
    slot :: cast[usize](domain.free_count)
    if slot < MAX_FREE_RANGES {
        domain.free_ranges[slot] = AddressRange.{start = start, size = size}
        domain.free_count += 1
    }
}

/**
 * Take a free domain ID on an IOMMU, the lowest.
 *
 * @param registered The IOMMU, whose lock the caller holds.
 * @return An ID from 1 up, below its id_limit; null if every one is taken.
 */
take_domain_id :: fn(registered: ptr[mut RegisteredIommu]) -> u32? {
    for id in 1..<registered.id_limit {
        word :: cast[usize](id / 64) % registered.ids.count
        bit :: cast[u64](1) << cast[u64](id % 64)
        if registered.ids[word] & bit == 0 {
            registered.ids[word] |= bit
            return id
        }
    }
    return null
}

/**
 * Give a domain ID back to an IOMMU, for reuse.
 *
 * @param registered The IOMMU, whose lock the caller holds.
 * @param id The ID, as take_domain_id gave it.
 */
give_domain_id :: fn(registered: ptr[mut RegisteredIommu], id: u32) {
    registered.ids[cast[usize](id / 64) % registered.ids.count] &= ~(cast[u64](1) << cast[u64](id % 64))
}

/**
 * Fill a set of IOMMU table frames with zeroed frames, from this CPU's frame cache.
 *
 * Each frame is charged to what owner is charged to, unless it's 0; filling stops at the first that can't be charged
 * or had.
 *
 * @param kernel The kernel, whose frames come from this CPU's frame cache.
 * @param tables The table frames, filled as far as possible.
 * @param owner The object whose budget pays for the frames, as an address; 0 for none.
 * @return True if the set is full, or has any frames at all after stopping early; false only if it's empty.
 */
refill_iommu_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[mut iommu_interface.TableFrames], owner: u64) -> bool {
    cache :: &per_cpu().frame_cache
    for i in cast[usize](tables.count)..<tables.frames.count {
        if owner != 0 && !charge_more(owner, frames.FRAME_SIZE) {
            return tables.count != 0
        }
        match frames.take_frame(cache, &kernel.frames) {
            case Ok(frame) => {
                intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, frame)), cast[usize](frames.FRAME_SIZE))
                tables.frames[i] = cast[iommu_interface.PhysicalAddress](frame)
                tables.count += 1
            }
            case Error(error) => {
                if owner != 0 {
                    uncharge(owner, cast[ptr[ObjectHeader]](owner).generation, frames.FRAME_SIZE)
                }
                return tables.count != 0
            }
        }
    }
    return true
}

/**
 * Give back the table frames nothing took, to this CPU's frame cache, with their charge to owner's budget.
 *
 * @param kernel The kernel, whose frames go back to this CPU's frame cache.
 * @param tables The table frames; its count is 0 after.
 * @param owner The object their charge goes back to, as an address; 0 for frames charged to nothing.
 */
give_back_iommu_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[mut iommu_interface.TableFrames], owner: u64) {
    count :: cast[usize](tables.count)
    for i in 0..<count {
        if i < tables.frames.count {
            frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](tables.frames[i]))
        }
    }
    if owner != 0 {
        uncharge(owner, cast[ptr[ObjectHeader]](owner).generation, cast[u64](count) * frames.FRAME_SIZE)
    }
    tables.count = 0
}
