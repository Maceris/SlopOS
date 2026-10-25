package iommu_smmuv3

import intrinsics from "base"
import aarch64 from "base/intrinsics"
import iommu_interface from "../../iommu_interface"

/*
 * Arm SMMUv3 (iommu_interface, roadmap D): one SMMU, which the platform service finds through the device tree's
 * iommu-map and registers (decisions/0039, 0079, 0083). Its domains use stage 2 only: each domain's stage-2 tables,
 * 4 KiB pages, 3 or 4 levels for its width, its output address size at most 48 bits, and its domain ID as its VMID.
 * A two-level stream table, each second-level table one page of 64 stream table entries, made as streams are
 * attached; every other stream aborts. Commands go through the command queue, each batch ended with a CMD_SYNC whose
 * completion is the queue's consumer passing it; faults are records in the event queue, which L2 reads, as QEMU's
 * SMMU signals them only through wired interrupts. It remaps no interrupts: the GICv3's ITS already takes a device's
 * MSIs only as the events its device ID was given, and its doorbell is mapped into each domain (L2, msi_doorbell).
 *
 * Its table walks and queue accesses must be coherent (SMMU_IDR0.COHACC), so the tables and queues are normal
 * write-back memory, and a dsb makes what's written visible to it before it's told. L2 serializes calls on one SMMU.
 */
//SPEC: Arm System Memory Management Unit Architecture Specification, SMMU architecture version 3 (IHI 0070), §3.3
//SPEC: (stream tables), §3.5 (queues), §4 (commands), §5.2 (stream table entries), §6.3 (registers), §7.3 (events);
//SPEC: Arm Architecture Reference Manual for A-profile, D8.3 (stage 2 descriptors)

IDR0 : u64 : 0x00
IDR1 : u64 : 0x04
IDR5 : u64 : 0x14
AIDR : u64 : 0x1c
CR0 : u64 : 0x20
CR0_ACK : u64 : 0x24
CR1 : u64 : 0x28
CR2 : u64 : 0x2c
STREAM_TABLE_BASE : u64 : 0x80
STREAM_TABLE_CONFIG : u64 : 0x88
COMMAND_QUEUE_BASE : u64 : 0x90
COMMAND_PRODUCER : u64 : 0x98
COMMAND_CONSUMER : u64 : 0x9c
EVENT_QUEUE_BASE : u64 : 0xa0
// In page 1
EVENT_PRODUCER : u64 : 0x100a8
EVENT_CONSUMER : u64 : 0x100ac
// Page 0's registers and page 1's, 64 KiB each, which every SMMUv3 has
REGISTER_BYTES : u64 : 0x20000

IDR0_S2P : u32 : 1 << 0
// TTF: the translation tables it walks, 2 for AArch64's, 3 for both AArch32's and AArch64's
IDR0_TTF_AARCH64 : u32 : 2 << 2
IDR0_COHERENT : u32 : 1 << 4
IDR0_VMID16 : u32 : 1 << 18
// ST_LEVEL: 1 for two-level stream tables
IDR0_TWO_LEVEL : u32 : 1 << 27
IDR5_GRAN4K : u32 : 1 << 4

CR0_SMMU : u32 : 1 << 0
CR0_EVENT_QUEUE : u32 : 1 << 2
CR0_COMMAND_QUEUE : u32 : 1 << 3
// Tables and queues inner shareable, inner and outer write-back
CR1_ATTRIBUTES : u32 : 0xd75
// A queue base's read- or write-allocate hint
ALLOCATE : u64 : 1 << 62
// A two-level stream table, each second-level table 2^6 entries
STREAM_TABLE_TWO_LEVEL : u64 : 1 << 16
SPLIT : u64 : 6
STREAMS_PER_TABLE : u64 : 64
// At most 16 stream ID bits: 1024 first-level descriptors of 8 bytes
MAX_STREAM_BITS : u64 : 16
// A first-level descriptor's second-level table, 64-byte aligned
LEVEL_2_MASK : u64 : 0x000fffffffffffc0
QUEUE_LOG : u64 : 8
COMMAND_BYTES : u64 : 16
EVENT_BYTES : u64 : 32
CONSUMER_ERROR : u32 : 0x7f << 24

// Commands
CFGI_STE : u64 : 0x03
CFGI_ALL : u64 : 0x04
TLBI_S12_VMALL : u64 : 0x28
TLBI_NSNH_ALL : u64 : 0x30
SYNC : u64 : 0x46

// A stream table entry's first word: valid, and its configuration, abort (0) or stage 2 only
STE_VALID : u64 : 1 << 0
STE_STAGE_2 : u64 : 6 << 1
// Its third: stage 2's walks inner and outer write-back, inner shareable, 4 KiB granule, AArch64, faults recorded
STE_S2_WALKS : u64 : 1 << 40 | 1 << 42 | 3 << 44
STE_S2_AARCH64 : u64 : 1 << 51
STE_S2_RECORD : u64 : 1 << 58

// Stage 2 descriptors: valid and a table or a page; a page's memory type, access, shareability and access flag
DESCRIPTOR : u64 : 3
NORMAL_WRITE_BACK : u64 : 0xf << 2
DEVICE_NGNRE : u64 : 1 << 2
READABLE : u64 : 1 << 6
WRITABLE : u64 : 1 << 7
INNER_SHAREABLE : u64 : 3 << 8
ACCESSED : u64 : 1 << 10
ADDRESS_MASK : u64 : 0x0000fffffffff000
ENTRIES : u64 : 512
PAGE : u64 : 4096
// How long a command may take, in spins
SPINS : u64 : 1_000_000

// One SMMU (iommu_interface.Iommu).
Iommu :: struct {
    // Its registers, mapped by L2 as device memory.
    registers : u64,
    // Its domains' width, at most 48 bits, and their tables' levels, 3 or 4; its output address size's encoding; its
    // stream IDs' bits.
    address_bits : u32,
    levels : u32,
    output_size : u64,
    stream_bits : u64,
    // From enable: the direct map; its first-level stream table, and its queues and where each is.
    direct_map_offset : u64,
    streams : u64,
    commands : u64,
    command_producer : u32,
    events : u64,
    event_consumer : u32,
}

// One domain on an SMMU (iommu_interface.Domain).
Domain :: struct {
    root : u64,
    id : u32,
}

// OAS, the output address sizes, by its value
OUTPUT_BITS :: u32.[32, 36, 40, 42, 44, 48, 52]

/*
 * An SMMUv3 at registers: its AIDR says it's version 3, it has both pages of registers, and it does stage 2, with
 * AArch64's tables and 4 KiB pages, two-level stream tables and coherent access.
 */
identify :: fn(iommu: ptr[mut Iommu], kind: iommu_interface.IommuKind, registers: iommu_interface.VirtualAddress, size: u64)
    -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    if kind != .Smmuv3 {
        return .Error(.UnsupportedKind)
    }
    if size < REGISTER_BYTES {
        return .Error(.NotFound)
    }
    base :: cast[u64](registers)
    features :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + IDR0))
    queues :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + IDR1))
    sizes :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + IDR5))
    version :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + AIDR))
    // ArchMajorRev 0 is SMMUv3; the bits above AIDR's eight are reserved
    if features == 0xffffffff || (version >> 4) & 0xf != 0 || version >> 8 != 0 {
        return .Error(.NotFound)
    }
    output :: cast[usize](sizes & 7)
    if features & IDR0_S2P == 0 || features & IDR0_TTF_AARCH64 == 0 || sizes & IDR5_GRAN4K == 0 || output >= OUTPUT_BITS.count
        || OUTPUT_BITS[output] < 39 || features & IDR0_TWO_LEVEL == 0 || features & IDR0_COHERENT == 0
        || cast[u64]((queues >> 21) & 0x1f) < QUEUE_LOG || cast[u64]((queues >> 16) & 0x1f) < QUEUE_LOG {
        return .Error(.Unsupported)
    }
    iommu.registers = base
    iommu.address_bits = if OUTPUT_BITS[output] < 48 { OUTPUT_BITS[output] } else { 48 }
    iommu.levels = if iommu.address_bits > 39 { 4 } else { 3 }
    iommu.output_size = cast[u64](output)
    stream_bits :: cast[u64](queues & 0x3f)
    iommu.stream_bits = if stream_bits < SPLIT { SPLIT } else if stream_bits > MAX_STREAM_BITS { MAX_STREAM_BITS } else { stream_bits }
    // Its first-level stream table, its command queue and its event queue, each in whole pages
    memory :: first_level_bytes(iommu) + (cast[u64](1) << QUEUE_LOG) * COMMAND_BYTES + (cast[u64](1) << QUEUE_LOG) * EVENT_BYTES
    return .Ok(iommu_interface.IommuInfo.{address_bits = iommu.address_bits, major = 3, minor = version & 0xf, memory = memory,
        domain_ids = if features & IDR0_VMID16 != 0 { 0xffff } else { 0xff }, interrupts = 0, fault_messages = false})
}

// The first-level stream table's bytes, whole pages: 8 for each table of 64 streams.
first_level_bytes :: fn(iommu: ptr[Iommu]) -> u64 {
    bytes :: (cast[u64](1) << (iommu.stream_bits - SPLIT)) * 8
    return (bytes + PAGE - 1) & ~(PAGE - 1)
}

/*
 * memory: the first-level stream table, the command queue, then the event queue. The SMMU off first, if firmware
 * left it on; then the tables and queues, the command queue on, every cached configuration and TLB entry invalidated,
 * the event queue on, and the SMMU, every stream aborting until it's attached.
 */
enable :: fn(iommu: ptr[mut Iommu], memory: iommu_interface.PhysicalAddress, direct_map_offset: u64) -> Result[void, iommu_interface.IommuError] {
    iommu.direct_map_offset = direct_map_offset
    iommu.streams = cast[u64](memory)
    iommu.commands = iommu.streams + first_level_bytes(iommu)
    iommu.events = iommu.commands + (cast[u64](1) << QUEUE_LOG) * COMMAND_BYTES
    if !set_enables(iommu, 0) {
        return .Error(.Timeout)
    }
    write_u32(iommu, CR1, CR1_ATTRIBUTES)
    write_u32(iommu, CR2, 0)
    write_u64(iommu, STREAM_TABLE_BASE, iommu.streams | ALLOCATE)
    write_u32(iommu, STREAM_TABLE_CONFIG, cast[u32](STREAM_TABLE_TWO_LEVEL | SPLIT << 6 | iommu.stream_bits))
    write_u64(iommu, COMMAND_QUEUE_BASE, iommu.commands | ALLOCATE | QUEUE_LOG)
    write_u32(iommu, COMMAND_PRODUCER, 0)
    write_u32(iommu, COMMAND_CONSUMER, 0)
    iommu.command_producer = 0
    write_u64(iommu, EVENT_QUEUE_BASE, iommu.events | ALLOCATE | QUEUE_LOG)
    write_u32(iommu, EVENT_PRODUCER, 0)
    write_u32(iommu, EVENT_CONSUMER, 0)
    iommu.event_consumer = 0
    aarch64.dsb(.SY)
    if !set_enables(iommu, CR0_COMMAND_QUEUE) {
        return .Error(.Timeout)
    }
    submit(iommu, CFGI_ALL, 31)
    submit(iommu, TLBI_NSNH_ALL, 0)
    if !sync(iommu) || !set_enables(iommu, CR0_COMMAND_QUEUE | CR0_EVENT_QUEUE)
        || !set_enables(iommu, CR0_COMMAND_QUEUE | CR0_EVENT_QUEUE | CR0_SMMU) {
        return .Error(.Timeout)
    }
    return .Ok
}

// Its faults go to its event queue, which L2 reads (info.fault_messages is false), so there's nothing to route.
route_faults :: fn(iommu: ptr[mut Iommu], message: iommu_interface.MsiMessage) {
}

init_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: iommu_interface.PhysicalAddress) {
    domain.root = cast[u64](root)
    domain.id = id
}

/*
 * stream's entry: its second-level table made where it has none, the entry made to abort and invalidated first if it
 * was in use, then written with its first word last, and invalidated again.
 */
attach :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32, frames: ptr[mut iommu_interface.TableFrames])
    -> Result[void, iommu_interface.MapError] {
    if cast[u64](stream) >> iommu.stream_bits != 0 {
        return .Error(.InvalidAddress)
    }
    entry :: stream_entry(iommu, stream, frames) or_return .Error(.NeedFrames)
    if load(iommu, entry) & STE_VALID != 0 {
        store(iommu, entry, STE_VALID)
        invalidate_stream(iommu, stream, cast[u32](load(iommu, entry + 16) & 0xffff))
    }
    t0sz :: 64 - cast[u64](iommu.address_bits)
    // SL0: 2 starts at level 0, for 4 levels; 1 at level 1, for 3
    start :: if iommu.levels == 4 { cast[u64](2) } else { cast[u64](1) }
    store(iommu, entry + 8, 0)
    store(iommu, entry + 16, cast[u64](domain.id & 0xffff) | t0sz << 32 | start << 38 | STE_S2_WALKS | iommu.output_size << 48
        | STE_S2_AARCH64 | STE_S2_RECORD)
    store(iommu, entry + 24, domain.root & ADDRESS_MASK)
    for word in 4..<8 {
        store(iommu, entry + cast[u64](word) * 8, 0)
    }
    aarch64.dsb(.SY)
    store(iommu, entry, STE_VALID | STE_STAGE_2)
    invalidate_stream(iommu, stream, domain.id)
    return .Ok
}

// stream's entry made to abort, and invalidated with the domain's TLB entries.
detach :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32) {
    if cast[u64](stream) >> iommu.stream_bits != 0 {
        return void
    }
    descriptor :: load(iommu, iommu.streams + (cast[u64](stream) >> SPLIT) * 8)
    if descriptor & LEVEL_2_MASK == 0 {
        return void
    }
    entry :: (descriptor & LEVEL_2_MASK) + (cast[u64](stream) & (STREAMS_PER_TABLE - 1)) * 64
    store(iommu, entry, STE_VALID)
    invalidate_stream(iommu, stream, domain.id)
}

// Where stream's entry is: its second-level table, from frames where there's none yet, or null if frames has none.
stream_entry :: fn(iommu: ptr[mut Iommu], stream: u32, frames: ptr[mut iommu_interface.TableFrames]) -> u64? {
    at :: iommu.streams + (cast[u64](stream) >> SPLIT) * 8
    if load(iommu, at) & LEVEL_2_MASK == 0 {
        table :: take_frame(frames) or_return null
        aarch64.dsb(.SY)
        // SPAN: SPLIT plus one, 64 entries
        store(iommu, at, table | (SPLIT + 1))
        submit(iommu, CFGI_ALL, 31)
        _ = sync(iommu)
    }
    return (load(iommu, at) & LEVEL_2_MASK) + (cast[u64](stream) & (STREAMS_PER_TABLE - 1)) * 64
}

map :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64, physical: iommu_interface.PhysicalAddress, writable: bool, device: bool,
    frames: ptr[mut iommu_interface.TableFrames]) -> Result[void, iommu_interface.MapError] {
    if address & (PAGE - 1) != 0 || address >> cast[u64](iommu.address_bits) != 0 || cast[u64](physical) & (PAGE - 1) != 0 {
        return .Error(.InvalidAddress)
    }
    // The tables it needs, counted first, so nothing changes when there aren't frames enough
    missing := cast[u32](0)
    table := domain.root
    for level in 0..<iommu.levels - 1 {
        entry :: load(iommu, table + index_of(address, iommu.levels - level) * 8)
        if entry & DESCRIPTOR != DESCRIPTOR {
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
        if load(iommu, at) & DESCRIPTOR != DESCRIPTOR {
            made :: take_frame(frames) or_return .Error(.NeedFrames)
            aarch64.dsb(.SY)
            store(iommu, at, made | DESCRIPTOR)
        }
        table = load(iommu, at) & ADDRESS_MASK
    }
    leaf :: table + index_of(address, 1) * 8
    if load(iommu, leaf) & DESCRIPTOR == DESCRIPTOR {
        return .Error(.AlreadyMapped)
    }
    kind :: if device { DEVICE_NGNRE } else { NORMAL_WRITE_BACK | INNER_SHAREABLE }
    store(iommu, leaf, cast[u64](physical) | DESCRIPTOR | kind | READABLE | (if writable { WRITABLE } else { cast[u64](0) }) | ACCESSED)
    return .Ok
}

unmap :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64) {
    table := domain.root
    for level in 0..<iommu.levels - 1 {
        entry :: load(iommu, table + index_of(address, iommu.levels - level) * 8)
        if entry & DESCRIPTOR != DESCRIPTOR {
            return void
        }
        table = entry & ADDRESS_MASK
    }
    store(iommu, table + index_of(address, 1) * 8, 0)
}

// The domain's TLB entries, by its VMID, after unmapping; nothing is cached of what isn't mapped, so mapping needs none.
invalidate :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) {
    aarch64.dsb(.SY)
    if mapped {
        return void
    }
    submit(iommu, TLBI_S12_VMALL | cast[u64](domain.id & 0xffff) << 32, 0)
    _ = sync(iommu)
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

// As VT-d's: one table below table, at level, let go of, the first whose entries are pages or that has none left.
free_one :: fn(iommu: ptr[Iommu], table: u64, level: u32, freed: ptr[mut iommu_interface.FreedFrames]) -> bool {
    if level <= 1 {
        return false
    }
    for index in 0..<ENTRIES {
        at :: table + index * 8
        entry :: load(iommu, at)
        if entry & DESCRIPTOR != DESCRIPTOR {
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

/*
 * The next record in the event queue, taken from it: a translation, address size, access flag or permission fault
 * with the address the device used, or any other event with none.
 */
next_fault :: fn(iommu: ptr[mut Iommu]) -> iommu_interface.DmaFault? {
    mask :: (cast[u32](1) << cast[u32](QUEUE_LOG + 1)) - 1
    producer :: read_u32(iommu, EVENT_PRODUCER)
    if producer & mask == iommu.event_consumer & mask {
        return null
    }
    record :: iommu.events + cast[u64](iommu.event_consumer & ((cast[u32](1) << cast[u32](QUEUE_LOG)) - 1)) * EVENT_BYTES
    first :: load(iommu, record)
    second :: load(iommu, record + 8)
    third :: load(iommu, record + 16)
    iommu.event_consumer = (iommu.event_consumer + 1) & mask
    write_u32(iommu, EVENT_CONSUMER, iommu.event_consumer)
    reason :: cast[u32](first & 0xff)
    // F_TRANSLATION to F_PERMISSION, whose third word is the input address, and whose RnW bit is set for a read
    translation :: reason >= 0x10 && reason <= 0x13
    return iommu_interface.DmaFault.{stream = cast[u32](first >> 32), address = if translation { third & ~(PAGE - 1) } else { cast[u64](0) },
        write = translation && (second >> 35) & 1 == 0, interrupt = false, reason = reason}
}

// It remaps none (info.interrupts is 0), so L2 never asks.
remap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32) -> iommu_interface.MsiMessage {
    return iommu_interface.MsiMessage.{}
}

unmap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
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

// A stream's configuration and its domain's TLB entries invalidated, waited for.
invalidate_stream :: fn(iommu: ptr[mut Iommu], stream: u32, vmid: u32) {
    submit(iommu, CFGI_STE | cast[u64](stream) << 32, 1)
    submit(iommu, TLBI_S12_VMALL | cast[u64](vmid & 0xffff) << 32, 0)
    _ = sync(iommu)
}

// A command at the queue's producer, which then moves past it, waiting while the queue is full.
submit :: fn(iommu: ptr[mut Iommu], first: u64, second: u64) {
    size :: cast[u32](1) << cast[u32](QUEUE_LOG)
    for spin in 0..<SPINS {
        consumer :: read_u32(iommu, COMMAND_CONSUMER)
        // Full: the same index, the other wrap
        if (iommu.command_producer ~ consumer) & ((size << 1) - 1) != size {
            break
        }
        intrinsics.spin_hint()
    }
    at :: iommu.commands + cast[u64](iommu.command_producer & (size - 1)) * COMMAND_BYTES
    store(iommu, at, first)
    store(iommu, at + 8, second)
    aarch64.dsb(.SY)
    iommu.command_producer = (iommu.command_producer + 1) & ((size << 1) - 1)
    write_u32(iommu, COMMAND_PRODUCER, iommu.command_producer)
}

// Everything submitted done: a CMD_SYNC, then the consumer at the producer, unless it stopped at an error.
sync :: fn(iommu: ptr[mut Iommu]) -> bool {
    submit(iommu, SYNC, 0)
    mask :: (cast[u32](1) << cast[u32](QUEUE_LOG + 1)) - 1
    for spin in 0..<SPINS {
        consumer :: read_u32(iommu, COMMAND_CONSUMER)
        if consumer & CONSUMER_ERROR != 0 {
            return false
        }
        if consumer & mask == iommu.command_producer {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

// CR0's enables set to these, until CR0ACK says so.
set_enables :: fn(iommu: ptr[mut Iommu], enables: u32) -> bool {
    write_u32(iommu, CR0, enables)
    for spin in 0..<SPINS {
        if read_u32(iommu, CR0_ACK) == enables {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

// A table entry or queue entry, by its physical address, through the direct map.
load :: fn(iommu: ptr[Iommu], at: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](at + iommu.direct_map_offset))
}

store :: fn(iommu: ptr[Iommu], at: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), value)
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
