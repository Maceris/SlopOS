package iommu_vtd

import intrinsics from "base"
import x86_64 from "base/intrinsics"
import iommu_interface from "../../iommu_interface"

/*
 * Intel VT-d (iommu_interface, roadmap D): one DMA remapping hardware unit, which the platform service finds in ACPI's
 * DMAR and registers (decisions/0039, 0079, 0081). Legacy mode: a root table of 256 buses, a context table for each
 * bus with a device, and each context entry a device's domain, its ID and the root of its second-level tables, which
 * are 4- or 3-level like x86-64's own, mapping 4 KiB pages only. Invalidation is through the invalidation queue, each
 * batch of it waited for with an invalidation wait descriptor writing a status word. A unit whose table walks don't
 * snoop caches (ECAP_REG.C clear, as QEMU's says) has every table write flushed from the cache.
 *
 * Interrupt remapping (roadmap Dc), where the unit has it: a table of 256 interrupt remapping entries, each a remapped
 * MSI's vector and CPU, and the requester ID it may come from, which the unit checks; compatibility-format interrupts
 * are blocked, so a device raises only the interrupts its entries give it. Entries' destinations are x2APIC IDs where
 * the unit has extended interrupt mode, otherwise xAPIC IDs.
 *
 * L2 serializes calls on one unit.
 */
//SPEC: Intel Virtualization Technology for Directed I/O, Architecture Specification 4.1, §3.4.2-3 (root and context
//SPEC: entries), §3.6 (second-level translation), §6.5.2 (queued invalidation), §7.2.1 (primary fault logging),
//SPEC: §9.1-9.3 (root, context and second-level entries), §11.4 (registers); §5.1 (interrupt remapping), §5.1.2.2
//SPEC: (remappable interrupt requests), §6.5.2.7 (interrupt entry cache invalidation), §9.9 (remapping table entries)

VERSION : u64 : 0x000
CAPABILITY : u64 : 0x008
EXTENDED_CAPABILITY : u64 : 0x010
GLOBAL_COMMAND : u64 : 0x018
GLOBAL_STATUS : u64 : 0x01c
ROOT_TABLE : u64 : 0x020
FAULT_STATUS : u64 : 0x034
FAULT_CONTROL : u64 : 0x038
FAULT_DATA : u64 : 0x03c
FAULT_ADDRESS : u64 : 0x040
FAULT_UPPER_ADDRESS : u64 : 0x044
QUEUE_HEAD : u64 : 0x080
QUEUE_TAIL : u64 : 0x088
QUEUE_ADDRESS : u64 : 0x090
REMAPPING_TABLE : u64 : 0x0b8
// The bytes of registers every unit has, from its version register to its last fixed one
FIXED_REGISTERS : u64 : 0x100

// SAGAW's widths: 3-level tables for 39-bit addresses, 4-level for 48
SAGAW_39 : u64 : 1 << 1
SAGAW_48 : u64 : 1 << 2
CAPABILITY_RWBF : u64 : 1 << 4
CAPABILITY_CACHING_MODE : u64 : 1 << 7
EXTENDED_COHERENT : u64 : 1 << 0
EXTENDED_QUEUED_INVALIDATION : u64 : 1 << 1
EXTENDED_INTERRUPT_REMAPPING : u64 : 1 << 3
EXTENDED_INTERRUPT_MODE : u64 : 1 << 4

// Global command bits, and their status bits at the same places
COMMAND_TRANSLATION : u32 : 1 << 31
COMMAND_ROOT_TABLE : u32 : 1 << 30
COMMAND_WRITE_BUFFER_FLUSH : u32 : 1 << 27
COMMAND_QUEUED_INVALIDATION : u32 : 1 << 26
COMMAND_INTERRUPT_REMAPPING : u32 : 1 << 25
COMMAND_REMAPPING_TABLE : u32 : 1 << 24
// The status bits that are on or off, as the command register's are written back: the one-shot ones left out
STATUS_PERSISTENT : u32 : 0x96ffffff

FAULT_STATUS_OVERFLOW : u32 : 1 << 0
FAULT_STATUS_QUEUE_ERROR : u32 : 1 << 4
FAULT_CONTROL_MASKED : u32 : 1 << 31
// A fault recording register's upper half: its fault bit, and its type bit, set for a read
FAULT_RECORDED : u64 : 1 << 63
FAULT_READ : u64 : 1 << 62

// Entries: present; a second-level entry readable and writable
PRESENT : u64 : 1 << 0
READ : u64 : 1 << 0
WRITE : u64 : 1 << 1
ADDRESS_MASK : u64 : 0x000ffffffffff000
ENTRIES : u64 : 512
PAGE : u64 : 4096
CACHE_LINE : u64 : 64

// Invalidation descriptors' types, and their granularities
DESCRIPTOR_CONTEXT : u64 : 1
DESCRIPTOR_IOTLB : u64 : 2
DESCRIPTOR_INTERRUPT_ENTRY : u64 : 4
// An interrupt entry cache invalidation of one entry, rather than all of them
INTERRUPT_ENTRY_ONE : u64 : 1 << 4
DESCRIPTOR_WAIT : u64 : 5
GLOBAL : u64 : 1 << 4
DOMAIN : u64 : 2 << 4
WAIT_STATUS_WRITE : u64 : 1 << 5
WAIT_FENCE : u64 : 1 << 6
// 256 descriptors of 16 bytes, one page of queue
QUEUE_ENTRIES : u32 : 256
// The remapping table: 256 entries of 16 bytes, one page; its size field is entries' log 2, less 1
INTERRUPT_ENTRIES : u32 : 256
TABLE_SIZE_FIELD : u64 : 7
TABLE_EXTENDED_MODE : u64 : 1 << 11
// An entry's present bit, its vector's place and its destination's; its upper half's source validation, by requester ID
ENTRY_PRESENT : u64 : 1 << 0
ENTRY_VECTOR_SHIFT : u64 : 16
ENTRY_DESTINATION_SHIFT : u64 : 32
ENTRY_VERIFY_SOURCE : u64 : 1 << 18
// A remappable message's address: the interrupt range, the remappable format bit, and the handle's bits 14:0 and 15
MESSAGE_BASE : u64 : 0xfee00000
MESSAGE_REMAPPABLE : u64 : 1 << 4
// How long a command or a wait may take, in spins
SPINS : u64 : 1_000_000

// One VT-d unit (iommu_interface.Iommu).
Iommu :: struct {
    // Its registers, mapped by L2 as device memory.
    registers : u64,
    // Its domains: their width, 39 or 48 bits, and their tables' levels, 3 or 4.
    address_bits : u32,
    levels : u32,
    // Where its IOTLB's registers and its fault recording registers are, from its registers' start, and how many of the latter.
    iotlb : u64,
    faults : u64,
    fault_count : u32,
    // The fault record to look at first.
    next_fault : u32,
    // Table writes are flushed from the cache; mapping is invalidated too (caching mode); writes are flushed (RWBF).
    flushes : bool,
    caching_mode : bool,
    write_buffer : bool,
    // Interrupt remapping, with x2APIC destinations where extended interrupt mode is there.
    remaps : bool,
    extended_mode : bool,
    // From enable: the direct map, its root table, its invalidation queue and its tail, the status word waits write,
    // and its interrupt remapping table.
    remapping : u64,
    direct_map_offset : u64,
    root : u64,
    queue : u64,
    tail : u32,
    status : u64,
    waits : u32,
}

// One domain on a unit (iommu_interface.Domain).
Domain :: struct {
    root : u64,
    id : u32,
}

/*
 * A VT-d unit at registers: its version register is 1.0 or later, and its registers, as far as its capability
 * registers place the IOTLB's and the fault recording registers, fit in size. It has queued invalidation.
 */
identify :: fn(iommu: ptr[mut Iommu], kind: iommu_interface.IommuKind, registers: iommu_interface.VirtualAddress, size: u64)
    -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    if kind != .VtD {
        return .Error(.UnsupportedKind)
    }
    if size < FIXED_REGISTERS {
        return .Error(.NotFound)
    }
    base :: cast[u64](registers)
    version :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + VERSION))
    capability :: intrinsics.volatile_load_u64(cast[ptr[u64]](base + CAPABILITY))
    extended :: intrinsics.volatile_load_u64(cast[ptr[u64]](base + EXTENDED_CAPABILITY))
    major :: (version >> 4) & 0xf
    if version == 0xffffffff || major == 0 {
        return .Error(.NotFound)
    }
    // IRO, FRO and NFR, in 16-byte units: the IOTLB's two registers, and the fault recording registers
    iotlb :: ((extended >> 8) & 0x3ff) * 16
    faults :: ((capability >> 24) & 0x3ff) * 16
    fault_count :: cast[u32]((capability >> 40) & 0xff) + 1
    if iotlb + 16 > size || faults + cast[u64](fault_count) * 16 > size {
        return .Error(.NotFound)
    }
    widths :: (capability >> 8) & 0x1f
    guest_width :: cast[u32]((capability >> 16) & 0x3f) + 1
    widest : u32 = if widths & SAGAW_48 != 0 { 48 } else if widths & SAGAW_39 != 0 { 39 } else { 0 }
    if widest == 0 || guest_width < 39 || extended & EXTENDED_QUEUED_INVALIDATION == 0 {
        return .Error(.Unsupported)
    }
    iommu.registers = base
    iommu.levels = if widest == 48 { 4 } else { 3 }
    iommu.address_bits = if guest_width < widest { guest_width } else { widest }
    iommu.iotlb = iotlb
    iommu.faults = faults
    iommu.fault_count = fault_count
    iommu.flushes = extended & EXTENDED_COHERENT == 0
    iommu.caching_mode = capability & CAPABILITY_CACHING_MODE != 0
    iommu.write_buffer = capability & CAPABILITY_RWBF != 0
    iommu.remaps = extended & EXTENDED_INTERRUPT_REMAPPING != 0
    iommu.extended_mode = extended & EXTENDED_INTERRUPT_MODE != 0
    // ND: 2^(4 + 2 ND) domain IDs, of which 0 is left alone, as caching mode keeps it for itself
    ids :: (cast[u64](1) << (4 + 2 * (capability & 7))) - 1
    return .Ok(iommu_interface.IommuInfo.{address_bits = iommu.address_bits, major = major, minor = version & 0xf,
        memory = 4 * PAGE, domain_ids = if ids > 0xffff { 0xffff } else { cast[u32](ids) },
        interrupts = if iommu.remaps { INTERRUPT_ENTRIES } else { 0 }})
}

/*
 * memory's four pages: the root table, the invalidation queue, the status word invalidation waits write, and the
 * interrupt remapping table. The queue goes on first, then the root table, both caches are invalidated, and
 * translation goes on; then, where the unit remaps interrupts, the remapping table, its cache invalidated, and
 * remapping, compatibility-format interrupts blocked.
 */
enable :: fn(iommu: ptr[mut Iommu], memory: iommu_interface.PhysicalAddress, direct_map_offset: u64) -> Result[void, iommu_interface.IommuError] {
    iommu.direct_map_offset = direct_map_offset
    iommu.root = cast[u64](memory)
    iommu.queue = cast[u64](memory) + PAGE
    iommu.status = cast[u64](memory) + 2 * PAGE
    iommu.remapping = cast[u64](memory) + 3 * PAGE
    flush_range(iommu, iommu.root, 4 * PAGE)
    write_u64(iommu, QUEUE_TAIL, 0)
    iommu.tail = 0
    write_u64(iommu, QUEUE_ADDRESS, iommu.queue)
    if !command(iommu, COMMAND_QUEUED_INVALIDATION, true) {
        return .Error(.Timeout)
    }
    write_u64(iommu, ROOT_TABLE, iommu.root)
    if !one_shot(iommu, COMMAND_ROOT_TABLE) {
        return .Error(.Timeout)
    }
    submit(iommu, DESCRIPTOR_CONTEXT | GLOBAL, 0)
    submit(iommu, DESCRIPTOR_IOTLB | GLOBAL, 0)
    if !wait(iommu) {
        return .Error(.Timeout)
    }
    write_u32(iommu, FAULT_CONTROL, FAULT_CONTROL_MASKED)
    if !command(iommu, COMMAND_TRANSLATION, true) {
        return .Error(.Timeout)
    }
    if !iommu.remaps {
        return .Ok
    }
    write_u64(iommu, REMAPPING_TABLE, iommu.remapping | TABLE_SIZE_FIELD | (if iommu.extended_mode { TABLE_EXTENDED_MODE } else { cast[u64](0) }))
    if !one_shot(iommu, COMMAND_REMAPPING_TABLE) {
        return .Error(.Timeout)
    }
    submit(iommu, DESCRIPTOR_INTERRUPT_ENTRY, 0)
    if !wait(iommu) || !command(iommu, COMMAND_INTERRUPT_REMAPPING, true) {
        return .Error(.Timeout)
    }
    return .Ok
}

/*
 * Entry index: fixed delivery, edge-triggered, physical destination mode, to the CPU's APIC ID, from stream only. Its
 * upper half first and its present bit last, then its cached copy invalidated.
 */
remap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32) -> iommu_interface.MsiMessage {
    entry :: iommu.remapping + cast[u64](index % INTERRUPT_ENTRIES) * 16
    // SVT 1, SQ 0: the requester ID must be stream's
    store(iommu, entry + 8, cast[u64](stream & 0xffff) | ENTRY_VERIFY_SOURCE)
    destination :: if iommu.extended_mode { cpu_hardware_id & 0xffffffff } else { (cpu_hardware_id & 0xff) << 8 }
    store(iommu, entry, destination << ENTRY_DESTINATION_SHIFT | cast[u64](vector & 0xff) << ENTRY_VECTOR_SHIFT | ENTRY_PRESENT)
    invalidate_interrupt(iommu, index)
    handle :: cast[u64](index)
    return iommu_interface.MsiMessage.{address = MESSAGE_BASE | (handle & 0x7fff) << 5 | MESSAGE_REMAPPABLE | ((handle >> 15) & 1) << 2,
        data = 0}
}

unmap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
    entry :: iommu.remapping + cast[u64](index % INTERRUPT_ENTRIES) * 16
    store(iommu, entry, 0)
    store(iommu, entry + 8, 0)
    invalidate_interrupt(iommu, index)
}

// One entry's cached copy, by its index, waited for.
invalidate_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
    submit(iommu, DESCRIPTOR_INTERRUPT_ENTRY | INTERRUPT_ENTRY_ONE | cast[u64](index) << 32, 0)
    _ = wait(iommu)
}

// Faults signalled by message: the fault event registers, then unmasked.
route_faults :: fn(iommu: ptr[mut Iommu], message: iommu_interface.MsiMessage) {
    write_u32(iommu, FAULT_DATA, message.data)
    write_u32(iommu, FAULT_ADDRESS, cast[u32](message.address))
    write_u32(iommu, FAULT_UPPER_ADDRESS, cast[u32](message.address >> 32))
    write_u32(iommu, FAULT_CONTROL, 0)
}

init_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: iommu_interface.PhysicalAddress) {
    domain.root = cast[u64](root)
    domain.id = id
}

/*
 * The context entry for stream, its bus and its device and function: its bus's context table made where it has
 * none, and a present entry made not present and invalidated first, as an entry in use can't be changed in place.
 */
attach :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32, frames: ptr[mut iommu_interface.TableFrames])
    -> Result[void, iommu_interface.MapError] {
    root_entry :: iommu.root + cast[u64]((stream >> 8) & 0xff) * 16
    if load(iommu, root_entry) & PRESENT == 0 {
        table :: take_frame(frames) or_return .Error(.NeedFrames)
        store(iommu, root_entry, table | PRESENT)
    }
    entry :: (load(iommu, root_entry) & ADDRESS_MASK) + cast[u64](stream & 0xff) * 16
    old :: load(iommu, entry + 8)
    if load(iommu, entry) & PRESENT != 0 {
        store(iommu, entry, 0)
        invalidate_context(iommu, cast[u32]((old >> 8) & 0xffff))
    }
    // AW: 1 for 3-level tables, 2 for 4; then the domain's ID
    width :: if iommu.levels == 4 { cast[u64](2) } else { cast[u64](1) }
    store(iommu, entry + 8, width | cast[u64](domain.id) << 8)
    // TT 0: untranslated requests, through the second-level tables
    store(iommu, entry, domain.root | PRESENT)
    invalidate_context(iommu, domain.id)
    return .Ok
}

detach :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32) {
    root_entry :: iommu.root + cast[u64]((stream >> 8) & 0xff) * 16
    if load(iommu, root_entry) & PRESENT == 0 {
        return void
    }
    entry :: (load(iommu, root_entry) & ADDRESS_MASK) + cast[u64](stream & 0xff) * 16
    if load(iommu, entry) & PRESENT != 0 {
        store(iommu, entry, 0)
        invalidate_context(iommu, domain.id)
    }
}

map :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64, physical: iommu_interface.PhysicalAddress, writable: bool,
    frames: ptr[mut iommu_interface.TableFrames]) -> Result[void, iommu_interface.MapError] {
    if address & (PAGE - 1) != 0 || address >> cast[u64](iommu.address_bits) != 0 || cast[u64](physical) & (PAGE - 1) != 0 {
        return .Error(.InvalidAddress)
    }
    // The tables it needs, counted first, so nothing changes when there aren't frames enough
    missing := cast[u32](0)
    table := domain.root
    for level in 0..<iommu.levels - 1 {
        entry :: load(iommu, table + index_of(address, iommu.levels - level) * 8)
        if entry & PRESENT == 0 {
            missing = iommu.levels - 1 - level
            break
        }
        table = entry & ADDRESS_MASK
    }
    if frames.count < missing {
        return .Error(.NeedFrames)
    }
    table = domain.root
    for level in 0..<iommu.levels - 1 {
        at :: table + index_of(address, iommu.levels - level) * 8
        if load(iommu, at) & READ == 0 {
            made :: take_frame(frames) or_return .Error(.NeedFrames)
            store(iommu, at, made | READ | WRITE)
        }
        table = load(iommu, at) & ADDRESS_MASK
    }
    leaf :: table + index_of(address, 1) * 8
    if load(iommu, leaf) & READ != 0 {
        return .Error(.AlreadyMapped)
    }
    store(iommu, leaf, cast[u64](physical) | READ | (if writable { WRITE } else { cast[u64](0) }))
    return .Ok
}

unmap :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64) {
    table := domain.root
    for level in 0..<iommu.levels - 1 {
        entry :: load(iommu, table + index_of(address, iommu.levels - level) * 8)
        if entry & READ == 0 {
            return void
        }
        table = entry & ADDRESS_MASK
    }
    store(iommu, table + index_of(address, 1) * 8, 0)
}

// The domain's IOTLB entries and cached tables, by its ID; after mapping, only in caching mode, or a write buffer flush.
invalidate :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) {
    if mapped && !iommu.caching_mode {
        if iommu.write_buffer {
            _ = one_shot(iommu, COMMAND_WRITE_BUFFER_FLUSH)
        }
        return void
    }
    submit(iommu, DESCRIPTOR_IOTLB | DOMAIN | cast[u64](domain.id) << 16, 0)
    _ = wait(iommu)
}

release_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], freed: ptr[mut iommu_interface.FreedFrames]) -> bool {
    loop {
        if cast[usize](freed.count) >= freed.frames.count {
            return false
        }
        if !free_one(iommu, domain.root, iommu.levels, freed) {
            return true
        }
    }
}

/*
 * One table below table, at level, let go of: the first whose own entries are pages, or that has none left. False if
 * table has no tables below it.
 */
free_one :: fn(iommu: ptr[Iommu], table: u64, level: u32, freed: ptr[mut iommu_interface.FreedFrames]) -> bool {
    if level <= 1 {
        return false
    }
    for index in 0..<ENTRIES {
        at :: table + index * 8
        entry :: load(iommu, at)
        if entry & READ == 0 {
            continue
        }
        child :: entry & ADDRESS_MASK
        if level > 2 && free_one(iommu, child, level - 1, freed) {
            return true
        }
        store(iommu, at, 0)
        index_freed :: cast[usize](freed.count)
        if index_freed < freed.frames.count {
            freed.frames[index_freed] = cast[iommu_interface.PhysicalAddress](child)
            freed.count += 1
        }
        return true
    }
    return false
}

// The next fault record with its fault bit set, from where the last one was, cleared once it's read.
next_fault :: fn(iommu: ptr[mut Iommu]) -> iommu_interface.DmaFault? {
    for i in 0..<iommu.fault_count {
        index :: (iommu.next_fault + i) % iommu.fault_count
        record :: iommu.registers + iommu.faults + cast[u64](index) * 16
        upper :: intrinsics.volatile_load_u64(cast[ptr[u64]](record + 8))
        if upper & FAULT_RECORDED == 0 {
            continue
        }
        lower :: intrinsics.volatile_load_u64(cast[ptr[u64]](record))
        // Writing the fault bit clears it
        intrinsics.volatile_store_u32(cast[ptr[mut u32]](record + 12), 1 << 31)
        iommu.next_fault = (index + 1) % iommu.fault_count
        reason :: cast[u32]((upper >> 32) & 0xff)
        // Reasons 0x20 to 0x2f are interrupt remapping's, whose fault information is the interrupt's index
        interrupt :: reason >= 0x20 && reason < 0x30
        return iommu_interface.DmaFault.{stream = cast[u32](upper & 0xffff), address = if interrupt { lower >> 48 } else { lower & ~(PAGE - 1) },
            write = upper & FAULT_READ == 0, interrupt = interrupt, reason = reason}
    }
    write_u32(iommu, FAULT_STATUS, FAULT_STATUS_OVERFLOW)
    return null
}

// Which entry of a table at level (1 for the tables of pages) address is in.
index_of :: fn(address: u64, level: u32) -> u64 {
    return (address >> (12 + 9 * cast[u64](level - 1))) & (ENTRIES - 1)
}

take_frame :: fn(frames: ptr[mut iommu_interface.TableFrames]) -> u64? {
    if frames.count == 0 || cast[usize](frames.count) > frames.frames.count {
        return null
    }
    frames.count -= 1
    return cast[u64](frames.frames[cast[usize](frames.count)])
}

// A table entry, by its physical address, through the direct map; stored, and flushed where the unit doesn't snoop.
load :: fn(iommu: ptr[Iommu], at: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](at + iommu.direct_map_offset))
}

store :: fn(iommu: ptr[Iommu], at: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), value)
    flush_range(iommu, at, 8)
}

flush_range :: fn(iommu: ptr[Iommu], at: u64, size: u64) {
    if !iommu.flushes {
        return void
    }
    line := at & ~(CACHE_LINE - 1)
    loop {
        if line >= at + size {
            break
        }
        x86_64.clflush(cast[rawptr](line + iommu.direct_map_offset))
        line += CACHE_LINE
    }
    x86_64.mfence()
}

// A context-cache invalidation, everything's, and the domain's IOTLB entries, waited for.
invalidate_context :: fn(iommu: ptr[mut Iommu], id: u32) {
    submit(iommu, DESCRIPTOR_CONTEXT | GLOBAL, 0)
    submit(iommu, DESCRIPTOR_IOTLB | DOMAIN | cast[u64](id) << 16, 0)
    _ = wait(iommu)
}

// A descriptor at the queue's tail, which then moves past it, so the unit takes it.
submit :: fn(iommu: ptr[mut Iommu], lower: u64, upper: u64) {
    at :: iommu.queue + cast[u64](iommu.tail) * 16
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), lower)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + 8 + iommu.direct_map_offset), upper)
    flush_range(iommu, at, 16)
    iommu.tail = (iommu.tail + 1) % QUEUE_ENTRIES
    write_u64(iommu, QUEUE_TAIL, cast[u64](iommu.tail) << 4)
}

// Everything submitted done: a wait descriptor that writes the next status, fenced after what's before it.
wait :: fn(iommu: ptr[mut Iommu]) -> bool {
    iommu.waits += 1
    expected :: iommu.waits
    submit(iommu, DESCRIPTOR_WAIT | WAIT_STATUS_WRITE | WAIT_FENCE | cast[u64](expected) << 32, iommu.status)
    status :: cast[ptr[u32]](iommu.status + iommu.direct_map_offset)
    for spin in 0..<SPINS {
        if intrinsics.volatile_load_u32(status) == expected {
            return true
        }
        if read_u32(iommu, FAULT_STATUS) & FAULT_STATUS_QUEUE_ERROR != 0 {
            return false
        }
        intrinsics.spin_hint()
    }
    return false
}

// A persistent command on or off, with the others as they are, until its status says so.
command :: fn(iommu: ptr[mut Iommu], bit: u32, on: bool) -> bool {
    status :: read_u32(iommu, GLOBAL_STATUS) & STATUS_PERSISTENT
    write_u32(iommu, GLOBAL_COMMAND, if on { status | bit } else { status & ~bit })
    for spin in 0..<SPINS {
        if (read_u32(iommu, GLOBAL_STATUS) & bit != 0) == on {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

// A one-shot command, until its status says it's done: set for a table's pointer, clear for a write buffer flush.
one_shot :: fn(iommu: ptr[mut Iommu], bit: u32) -> bool {
    status :: read_u32(iommu, GLOBAL_STATUS) & STATUS_PERSISTENT
    write_u32(iommu, GLOBAL_COMMAND, status | bit)
    done_when_set :: bit != COMMAND_WRITE_BUFFER_FLUSH
    for spin in 0..<SPINS {
        if (read_u32(iommu, GLOBAL_STATUS) & bit != 0) == done_when_set {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

read_u32 :: fn(iommu: ptr[Iommu], offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](iommu.registers + offset))
}

write_u32 :: fn(iommu: ptr[Iommu], offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](iommu.registers + offset), value)
}

write_u64 :: fn(iommu: ptr[Iommu], offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](iommu.registers + offset), value)
}
