package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import iommu_interface from "../iommu_interface"
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
 * DMA through the IOMMUs (roadmap Db and Dd, decisions/0079, 0081, 0083). An IOMMU (VT-d, SMMUv3) turns translation
 * on once it's registered, every device blocked until it's attached, with its faults signalled to CPU 0 where it can
 * signal them by a message (VT-d), or read at CPU 0's ticks where it can't (SMMUv3, whose interrupts are wired), and
 * logged. Where MSIs are writes an IOMMU translates (AArch64's to the ITS), the doorbell is mapped into each domain at
 * its own address, which the domain's other addresses keep clear of. A domain's first device behind it gives the domain an ID there and a
 * root table, charged to the domain's budget, as the tables mapping its memory are. DMA memory made in a domain that
 * translates is in frames anywhere, mapped at the lowest free I/O virtual addresses of the domain's own below its
 * limit; destroying it unmaps it, and the IOMMU reaches none of it once that returns. Destroying a domain detaches its
 * devices first, and its tables go once nothing can reach them.
 *
 * Interrupt remapping (roadmap Dc): an IOMMU that remaps interrupts (VT-d's) turns it on with translation, and every
 * message-signaled IRQ of a device behind it then has an entry of its own there, its message the entry's handle, which
 * the IOMMU takes only from that device; the compatibility-format messages devices could forge are blocked. Wired
 * lines' are too, as the I/O APIC's entries aren't remapped yet, so no IRQ is made for one once an IOMMU remaps.
 *
 * Everything an IOMMU does is under its lock. Lock order: a device's lock, then an IOMMU's lock.
 */

// Domain IDs the kernel gives out on each IOMMU, at most
MAX_DOMAIN_IDS :: 256
// Where a domain's I/O virtual addresses start: never 0, so a device given nothing reaches nothing
FIRST_DEVICE_ADDRESS : u64 : 1 << 20
// Ranges of a domain's I/O virtual addresses freed and kept for reuse
MAX_FREE_RANGES :: 16
// Faults taken in one interrupt, at most
MAX_FAULTS_TAKEN :: 16
// A route's controller for an IOMMU's faults, whose line is the IOMMU's number (interrupts.hsc)
IOMMU_CONTROLLER : u32 : 0xfffffffe
// Remapped interrupts the kernel gives out on each IOMMU, at most
MAX_REMAPPED_INTERRUPTS :: 256

// A free range of a domain's I/O virtual addresses.
AddressRange :: struct {
    start : u64,
    size : u64,
}

/*
 * Translation on, with the memory its implementation asks for, and its faults routed to CPU 0. One that can't is left
 * as it was, its domains' device addresses physical addresses.
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
    concurrency.lock(&registered.lock)
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
    concurrency.unlock(&registered.lock)
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
            concurrency.lock(&registered.lock)
            iommu_unit.route_faults(&registered.unit, iommu_interface.MsiMessage.{address = message.address, data = message.data})
            concurrency.unlock(&registered.lock)
            runtime.log_info("IOMMU %: translating, % interrupts remapped, its faults to CPU 0's interrupt %", index,
                registered.interrupt_limit, cast[u32](id))
        }
        case Error(error) => runtime.log_warn("IOMMU %: translating, but its faults aren't signalled", index)
    }
}

// At CPU 0's ticks: the faults of each IOMMU that doesn't signal them.
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

/*
 * An IOMMU's faults, at its interrupt or its tick: each logged, with the device's address and what it was refused,
 * and raised on the Device the stream is (SIGNAL_DMA_FAULT), for whoever watches its driver (decisions/0084).
 */
handle_dma_faults :: fn(kernel: ptr[mut Kernel], index: u32) {
    if index >= intrinsics.atomic_load_u32_acquire(&kernel.iommu_count) || cast[usize](index) >= MAX_IOMMUS {
        return void
    }
    registered :: &kernel.iommus[cast[usize](index)]
    for taken in 0..<MAX_FAULTS_TAKEN {
        concurrency.lock(&registered.lock)
        found :: iommu_unit.next_fault(&registered.unit)
        if found is_some {
            registered.faults += 1
        }
        concurrency.unlock(&registered.lock)
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

// SIGNAL_DMA_FAULT on the Device translated through the IOMMU as the fault's stream, if there's one.
signal_dma_fault :: fn(kernel: ptr[mut Kernel], index: u32, fault: iommu_interface.DmaFault) {
    concurrency.lock(&kernel.devices_lock)
    defer concurrency.unlock(&kernel.devices_lock)
    with {
        other := kernel.first_device
    }
    loop {
        if other == 0 {
            break
        }
        device :: cast[ptr[mut Device]](other)
        if device.translated && device.iommu.iommu == index + 1 && device.iommu.stream == fault.stream {
            raise_watchers(kernel, &device.watchers, &device.watch_lock, cast[u32](slop_os.SIGNAL_DMA_FAULT), fault.address)
            return void
        }
        other = device.next
    }
}

// The IOMMU a path names (its number plus one), if it translates.
translating_iommu :: fn(kernel: ptr[mut Kernel], iommu: u32) -> ptr[mut RegisteredIommu]? {
    if iommu == 0 || iommu > intrinsics.atomic_load_u32_acquire(&kernel.iommu_count) || cast[usize](iommu) > MAX_IOMMUS {
        return null
    }
    registered :: &kernel.iommus[cast[usize](iommu - 1)]
    return if registered.translating { registered } else { null }
}

/*
 * A device's DMA through domain on its IOMMU, if that translates: the domain made on it first, if it's the first
 * device there, with an ID and a root table charged to its budget. Takes the device's lock as held.
 */
translate_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device], domain: ptr[mut DmaDomain], path: IommuPath)
    -> Result[void, slop_os.DeviceError] {
    registered :: translating_iommu(kernel, path.iommu) or_return .Ok
    concurrency.lock(&registered.lock)
    defer concurrency.unlock(&registered.lock)
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

/*
 * The MSI doorbell mapped into a new domain at its own address, writable device memory, its tables charged to the
 * domain, where MSIs are writes the IOMMU translates; its page is kept out of the domain's other addresses. Takes the
 * IOMMU's lock as held.
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

// A device's DMA blocked again, if it was translated through its domain. Takes the device's lock as held.
untranslate_device :: fn(kernel: ptr[mut Kernel], device: ptr[mut Device]) {
    if !device.translated {
        return void
    }
    device.translated = false
    registered :: translating_iommu(kernel, device.iommu.iommu) or_return void
    domain :: cast[ptr[mut DmaDomain]](device.domain)
    concurrency.lock(&registered.lock)
    iommu_unit.detach(&registered.unit, &domain.unit, device.iommu.stream)
    concurrency.unlock(&registered.lock)
}

/*
 * DMA memory mapped into its domain, if that translates: at the lowest free I/O virtual addresses below limit (0 for
 * none), each page writable, tables charged to the domain. Nothing is left mapped if it can't all be.
 */
map_dma_memory :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain], memory: ptr[mut Memory], limit: u64)
    -> Result[void, slop_os.DeviceError] {
    registered :: translating_iommu(kernel, domain.iommu) or_return .Ok
    concurrency.lock(&registered.lock)
    defer concurrency.unlock(&registered.lock)
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

/*
 * DMA memory unmapped from its domain, if it was mapped and the domain still translates: the IOMMU reaches none of it
 * once this returns.
 */
unmap_dma_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    address :: memory.device_address
    if address == 0 || memory.domain == 0 {
        return void
    }
    memory.device_address = 0
    domain :: cast[ptr[mut DmaDomain]](memory.domain)
    registered :: translating_iommu(kernel, domain.iommu) or_return void
    concurrency.lock(&registered.lock)
    if domain.translating && intrinsics.atomic_load_u32_acquire(&domain.header.generation) == memory.domain_generation {
        for page in 0..<memory.size / frames.FRAME_SIZE {
            iommu_unit.unmap(&registered.unit, &domain.unit, address + page * frames.FRAME_SIZE)
        }
        iommu_unit.invalidate(&registered.unit, &domain.unit, false)
        give_device_addresses(domain, address, memory.size)
    }
    concurrency.unlock(&registered.lock)
}

/*
 * A domain being destroyed: every device attached to it detached, and its translation stopped, so DMA memory of it
 * destroyed later has nothing to unmap.
 */
stop_domain :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    loop {
        found := cast[u64](0)
        concurrency.lock(&kernel.devices_lock)
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
        concurrency.unlock(&kernel.devices_lock)
        if found == 0 {
            break
        }
        device :: cast[ptr[mut Device]](found)
        concurrency.lock(&device.lock)
        if device.domain == cast[u64](domain) {
            untranslate_device(kernel, device)
            device.domain = 0
        }
        concurrency.unlock(&device.lock)
    }
    registered :: translating_iommu(kernel, domain.iommu) or_return void
    concurrency.lock(&registered.lock)
    domain.stopped = domain.translating
    domain.translating = false
    concurrency.unlock(&registered.lock)
}

// Once nothing can reach them: a stopped domain's tables, its root and its ID.
release_domain_tables :: fn(kernel: ptr[mut Kernel], domain: ptr[mut DmaDomain]) {
    if !domain.stopped {
        return void
    }
    domain.stopped = false
    registered :: translating_iommu(kernel, domain.iommu) or_return void
    concurrency.lock(&registered.lock)
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
    concurrency.unlock(&registered.lock)
}

/*
 * A message-signaled IRQ of device's, routed to id on the CPU with this hardware ID, remapped by the IOMMU it's
 * behind, if that remaps interrupts: its message, which only device can raise it with. Null if every remapped
 * interrupt there is taken; the arch's own message where its IOMMU doesn't remap.
 */
remap_msi :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq], device: ptr[Device], hardware_id: u64, id: arch_interface.InterruptId)
    -> arch_interface.MsiMessage? {
    message :: arch.route_msi(device.msi_source, irq.line, hardware_id, id)
    path :: iommu_path(kernel, device.address)
    registered :: translating_iommu(kernel, path.iommu) or_return message
    if !registered.remapping {
        return message
    }
    concurrency.lock(&registered.lock)
    defer concurrency.unlock(&registered.lock)
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

// A remapped IRQ's entry pointed at id on the CPU with this hardware ID instead; its message stays as it was.
repoint_msi :: fn(kernel: ptr[mut Kernel], irq: ptr[Irq], device: ptr[Device], hardware_id: u64, id: arch_interface.InterruptId) {
    registered :: translating_iommu(kernel, irq.remap_iommu) or_return void
    path :: iommu_path(kernel, device.address)
    concurrency.lock(&registered.lock)
    _ = iommu_unit.remap_interrupt(&registered.unit, irq.remap_index, path.stream, hardware_id, cast[u32](id))
    concurrency.unlock(&registered.lock)
}

// A remapped IRQ's entry raising nothing again, and free.
unremap_msi :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    if irq.remap_iommu == 0 {
        return void
    }
    registered :: translating_iommu(kernel, irq.remap_iommu) or_return void
    irq.remap_iommu = 0
    concurrency.lock(&registered.lock)
    iommu_unit.unmap_interrupt(&registered.unit, irq.remap_index)
    registered.interrupts[cast[usize](irq.remap_index / 64) % registered.interrupts.count] &= ~(cast[u64](1) << cast[u64](irq.remap_index % 64))
    concurrency.unlock(&registered.lock)
}

// The lowest free range of size bytes below top: from the ranges freed, or past every one taken.
take_device_addresses :: fn(domain: ptr[mut DmaDomain], size: u64, top: u64) -> u64? {
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
    if domain.next_address > top || size > top - domain.next_address {
        return null
    }
    start :: domain.next_address
    domain.next_address += size
    return start
}

// A range back, for reuse; where there's no room to keep it, its addresses aren't used again.
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

give_domain_id :: fn(registered: ptr[mut RegisteredIommu], id: u32) {
    registered.ids[cast[usize](id / 64) % registered.ids.count] &= ~(cast[u64](1) << cast[u64](id % 64))
}

// Zeroed frames for an IOMMU's tables, each charged to what owner is charged to, unless it's 0: false if none came.
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

// The table frames nothing took, back, with their charge to owner's budget, unless it's 0.
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
