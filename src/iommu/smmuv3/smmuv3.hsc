package iommu_smmuv3

import intrinsics from "base"
import runtime from "base"
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
/*
 * SPEC: Arm System Memory Management Unit Architecture Specification, SMMU architecture version 3 (IHI 0070), §3.3
 * (stream tables), §3.5 (queues), §4 (commands), §5.2 (stream table entries), §6.3 (registers), §7.3 (events);
 * Arm Architecture Reference Manual for A-profile, D8.3 (stage 2 descriptors)
 */

// ---- Registers: byte offsets from the SMMU's register base (IHI 0070 §6.3)

/** SMMU_IDR0: the features it has, like stage 2, its table formats, coherency and stream table levels. */
IDR0 : u64 : 0x00
/** SMMU_IDR1: its queues' and stream IDs' sizes: SIDSIZE in bits 5:0, EVENTQS in 20:16, CMDQS in 25:21. */
IDR1 : u64 : 0x04
/** SMMU_IDR5: its translation granules, and OAS, its output address size, in bits 2:0. */
IDR5 : u64 : 0x14
/** SMMU_AIDR: its architecture version, ArchMajorRev in bits 7:4 (0 for SMMUv3) and ArchMinorRev in 3:0. */
AIDR : u64 : 0x1c
/** SMMU_CR0: its enables, the SMMU's, the event queue's and the command queue's. */
CR0 : u64 : 0x20
/** SMMU_CR0ACK: the enables CR0 last had that have taken effect. */
CR0_ACK : u64 : 0x24
/** SMMU_CR1: the cacheability and shareability of its accesses to tables and queues. */
CR1 : u64 : 0x28
/** SMMU_CR2: further controls, left 0. */
CR2 : u64 : 0x2c
/** SMMU_STRTAB_BASE: the stream table's physical address, and its read-allocate hint. */
STREAM_TABLE_BASE : u64 : 0x80
/** SMMU_STRTAB_BASE_CFG: the stream table's format, split and size. */
STREAM_TABLE_CONFIG : u64 : 0x88
/** SMMU_CMDQ_BASE: the command queue's physical address and log2 size. */
COMMAND_QUEUE_BASE : u64 : 0x90
/** SMMU_CMDQ_PROD: the command queue's producer index, with its wrap bit above the index. */
COMMAND_PRODUCER : u64 : 0x98
/** SMMU_CMDQ_CONS: the command queue's consumer index, with its wrap bit and, in bits 30:24, an error. */
COMMAND_CONSUMER : u64 : 0x9c
/** SMMU_EVENTQ_BASE: the event queue's physical address and log2 size. */
EVENT_QUEUE_BASE : u64 : 0xa0
/** SMMU_EVENTQ_PROD, in register page 1: the event queue's producer index, with its wrap bit. */
EVENT_PRODUCER : u64 : 0x100a8
/** SMMU_EVENTQ_CONS, in register page 1: the event queue's consumer index, with its wrap bit. */
EVENT_CONSUMER : u64 : 0x100ac
/** The bytes of registers: page 0's and page 1's, 64 KiB each, which every SMMUv3 has. */
REGISTER_BYTES : u64 : 0x20000

/** IDR0.S2P: stage 2 translation is supported. */
IDR0_S2P : u32 : 1 << 0
/** IDR0.TTF, bits 3:2: the translation tables it walks, 2 for AArch64's, 3 for both AArch32's and AArch64's. */
IDR0_TTF_AARCH64 : u32 : 2 << 2
/** IDR0.COHACC: its table walks and queue accesses are coherent with the CPUs'. */
IDR0_COHERENT : u32 : 1 << 4
/** IDR0.VMID16: VMIDs are 16 bits, not 8. */
IDR0_VMID16 : u32 : 1 << 18
/** IDR0.ST_LEVEL, bits 28:27: 1 for two-level stream tables. */
IDR0_TWO_LEVEL : u32 : 1 << 27
/** IDR5.GRAN4K: the 4 KiB translation granule is supported. */
IDR5_GRAN4K : u32 : 1 << 4

/** CR0.SMMUEN: translation is on, streams following their stream table entries. */
CR0_SMMU : u32 : 1 << 0
/** CR0.EVENTQEN: the event queue is on. */
CR0_EVENT_QUEUE : u32 : 1 << 2
/** CR0.CMDQEN: the command queue is on. */
CR0_COMMAND_QUEUE : u32 : 1 << 3
/** CR1's value: tables and queues inner shareable, inner and outer write-back. */
CR1_ATTRIBUTES : u32 : 0xd75
/** A table or queue base register's read-allocate (RA) or write-allocate (WA) hint, bit 62. */
ALLOCATE : u64 : 1 << 62
/** STRTAB_BASE_CFG.FMT, bits 17:16: 1 for a two-level stream table. */
STREAM_TABLE_TWO_LEVEL : u64 : 1 << 16
/** STRTAB_BASE_CFG.SPLIT: the stream ID bits a second-level table covers, 6, for 64 entries each. */
SPLIT : u64 : 6
/** The stream table entries in one second-level table, 2 to the SPLIT; each takes 64 bytes, so one table is 4 KiB. */
STREAMS_PER_TABLE : u64 : 64
/** The most stream ID bits it covers: 16, so 1024 first-level descriptors of 8 bytes. */
MAX_STREAM_BITS : u64 : 16
/** A first-level descriptor's L2Ptr, bits 51:6: its second-level table's physical address, 64-byte aligned. */
LEVEL_2_MASK : u64 : 0x000fffffffffffc0
/** Each queue's log2 size in entries: 256 entries. */
QUEUE_LOG : u64 : 8
/** The bytes of one command queue entry. */
COMMAND_BYTES : u64 : 16
/** The bytes of one event queue record. */
EVENT_BYTES : u64 : 32
/** CMDQ_CONS.ERR, bits 30:24: nonzero when the command queue stopped at an erroneous command. */
CONSUMER_ERROR : u32 : 0x7f << 24

// ---- Commands: each one's opcode, its first word's bits 7:0 (IHI 0070 §4)

/** CMD_CFGI_STE: invalidate the configuration cached of one stream, its StreamID in bits 63:32. */
CFGI_STE : u64 : 0x03
/** CMD_CFGI_ALL: invalidate every stream's cached configuration, its range 31 in the second word. */
CFGI_ALL : u64 : 0x04
/** CMD_TLBI_S12_VMALL: invalidate every TLB entry for one VMID, in bits 47:32. */
TLBI_S12_VMALL : u64 : 0x28
/** CMD_TLBI_NSNH_ALL: invalidate every non-secure, non-hypervisor TLB entry. */
TLBI_NSNH_ALL : u64 : 0x30
/** CMD_SYNC: complete once every command before it has. */
SYNC : u64 : 0x46

// ---- Stream table entries (IHI 0070 §5.2)

/** An STE's first word's V bit: the entry is valid. With Config 0, a valid entry aborts its stream's traffic. */
STE_VALID : u64 : 1 << 0
/** An STE's first word's Config, bits 3:1: 0b110, stage 2 translation only, stage 1 bypassed. */
STE_STAGE_2 : u64 : 6 << 1
/**
 * An STE's third word's stage 2 walk attributes: S2IR0 and S2OR0 write-back, S2SH0 inner shareable; S2TG 0 leaves
 * the 4 KiB granule.
 */
STE_S2_WALKS : u64 : 1 << 40 | 1 << 42 | 3 << 44
/** An STE's third word's S2AA64: stage 2 uses AArch64's tables. */
STE_S2_AARCH64 : u64 : 1 << 51
/** An STE's third word's S2R: stage 2 faults are recorded in the event queue. */
STE_S2_RECORD : u64 : 1 << 58

// ---- Stage 2 descriptors (Arm ARM D8.3)

/** A descriptor's low two bits for a valid table, or a valid page at the last level. */
DESCRIPTOR : u64 : 3
/** A page's MemAttr, bits 5:2: 0b1111, normal memory, inner and outer write-back. */
NORMAL_WRITE_BACK : u64 : 0xf << 2
/** A page's MemAttr, bits 5:2: 0b0001, Device-nGnRE memory. */
DEVICE_NGNRE : u64 : 1 << 2
/** A page's S2AP bit 6: the device may read it. */
READABLE : u64 : 1 << 6
/** A page's S2AP bit 7: the device may write it. */
WRITABLE : u64 : 1 << 7
/** A page's SH, bits 9:8: inner shareable. */
INNER_SHAREABLE : u64 : 3 << 8
/** A page's access flag, set so the first access doesn't fault. */
ACCESSED : u64 : 1 << 10
/** A descriptor's output address, bits 47:12: the physical address of the table or page it points at. */
ADDRESS_MASK : u64 : 0x0000fffffffff000
/** The descriptors in one table, 4 KiB of 8 bytes each. */
ENTRIES : u64 : 512
/** The bytes of a page and of a table, the 4 KiB granule. */
PAGE : u64 : 4096
/** How long a command, or an enable, may take, in spins of spin_hint, before it's taken as timed out. */
SPINS : u64 : 1_000_000

/** One SMMU (iommu_interface.Iommu). */
Iommu :: struct {
    /** The virtual address of its registers, both pages, mapped by L2 as device memory. */
    registers : u64,
    /** Its domains' I/O virtual address width in bits, from 39 to 48: its output address size, at most 48. */
    address_bits : u32,
    /** Its domains' stage 2 tables' levels: 4 when address_bits is over 39, otherwise 3. */
    levels : u32,
    /** Its output address size as IDR5.OAS encodes it, 0 to 6 (OUTPUT_BITS), for an STE's S2PS. */
    output_size : u64,
    /** The stream ID bits its stream table covers, from SPLIT to MAX_STREAM_BITS. */
    stream_bits : u64,
    /** From enable: the virtual address of physical 0 in the direct map, through which tables and queues are read. */
    direct_map_offset : u64,
    /** From enable: the first-level stream table's physical address. */
    streams : u64,
    /** From enable: the command queue's physical address. */
    commands : u64,
    /** The command queue's producer index, with its wrap bit, as last written to CMDQ_PROD. */
    command_producer : u32,
    /** From enable: the event queue's physical address. */
    events : u64,
    /** The event queue's consumer index, with its wrap bit, as last written to EVENTQ_CONS. */
    event_consumer : u32,
}

/** One domain on an SMMU (iommu_interface.Domain). */
Domain :: struct {
    /** The physical address of its stage 2 top-level table, a 4 KiB frame. */
    root : u64,
    /** Its domain ID, used as its VMID; only the low 16 bits are used. */
    id : u32,
}

/** The output address sizes in bits, by IDR5.OAS's value. */
OUTPUT_BITS :: u32.[32, 36, 40, 42, 44, 48, 52]

/**
 * Identify an SMMUv3, changing nothing on it: DMA through it goes on as before.
 *
 * It has to say it's version 3 in its AIDR and do stage 2, with AArch64's tables and 4 KiB pages, two-level stream
 * tables, coherent access, an output address size of at least 39 bits, and queues of at least 256 entries.
 *
 * @param iommu Where what's needed of it is kept: its registers, address width, levels and stream ID bits. Written
 *     only when it's found and supported.
 * @param kind The kind the platform service says it is.
 * @param registers The virtual address L2 mapped its registers at, uncached.
 * @param size The bytes mapped there, at least REGISTER_BYTES.
 * @return What it is: version 3.minor, its address width, the bytes enable takes (the first-level stream table, the
 *     command queue and the event queue), 255 or 65535 domain IDs as its VMIDs are 8 or 16 bits, no interrupts
 *     remapped, and faults that L2 asks for.
 * @error UnsupportedKind kind isn't Smmuv3.
 * @error NotFound Fewer than REGISTER_BYTES are mapped, or the registers don't read as an SMMUv3's.
 * @error Unsupported It lacks one of the things above.
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

/**
 * Size the first-level stream table.
 *
 * @param iommu The SMMU, identified.
 * @return Its bytes, 8 for each second-level table of 64 streams, rounded up to whole 4 KiB pages.
 */
first_level_bytes :: fn(iommu: ptr[Iommu]) -> u64 {
    bytes :: (cast[u64](1) << (iommu.stream_bits - SPLIT)) * 8
    return (bytes + PAGE - 1) & ~(PAGE - 1)
}

/**
 * Turn translation on, every stream aborting until it's attached.
 *
 * The SMMU is turned off first, if firmware left it on; then the tables and queues are set, the command queue turned
 * on, every cached configuration and TLB entry invalidated, then the event queue and the SMMU turned on.
 *
 * @param iommu The SMMU, identified.
 * @param memory The physical address of identify's memory bytes, zeroed and contiguous: the first-level stream
 *     table, the command queue, then the event queue. The SMMU keeps it for good.
 * @param direct_map_offset The virtual address of physical 0 in the direct map, through which it reaches its tables
 *     and queues, and domains' tables.
 * @error Timeout CR0ACK didn't follow CR0 within SPINS spins, or the first CMD_SYNC didn't complete or met an error;
 *     the SMMU may be left partly set up.
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

/**
 * Do nothing: its faults go to its event queue, which L2 reads (info.fault_messages is false), so there's nothing to
 * route.
 *
 * @param iommu The SMMU, unused.
 * @param message The message, unused.
 */
route_faults :: fn(iommu: ptr[mut Iommu], message: iommu_interface.MsiMessage) {
}

/**
 * Make an empty domain on the SMMU. Nothing is written to the SMMU or the table.
 *
 * @param iommu The SMMU, unused.
 * @param domain The domain to set up.
 * @param id Its domain ID, used as its VMID: from 1 to identify's domain_ids.
 * @param root The physical address of a zeroed 4 KiB frame for its top-level table.
 */
init_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: iommu_interface.PhysicalAddress) {
    domain.root = cast[u64](root)
    domain.id = id
}

/**
 * Translate a stream's DMA through a domain from now on, instead of what it was before.
 *
 * Its second-level stream table is made where it has none; if its entry was in use, it's made to abort and
 * invalidated first, with its old VMID's TLB entries; then it's written, its first word last, and invalidated again.
 *
 * @param iommu The SMMU, enabled.
 * @param domain The domain to translate through, made by init_domain; its root and VMID go into the stream's entry,
 *     so it must stay alive and keep its root until the stream is detached.
 * @param stream The stream ID, below 2 to the SMMU's stream_bits.
 * @param frames Zeroed frames, of which one is taken for the stream's second-level table if it has none.
 * @error InvalidAddress The stream ID is outside the stream table.
 * @error NeedFrames Its second-level table had to be made and frames was empty; nothing was changed.
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

/**
 * Abort a stream's DMA again, with nothing cached of it left when this returns.
 *
 * The entry is made to abort and invalidated, with the domain's TLB entries. A stream outside the table, or with no
 * second-level table, is left alone.
 *
 * @param iommu The SMMU, enabled.
 * @param domain The domain it was attached to, whose VMID's TLB entries are invalidated.
 * @param stream The stream ID; one at or above 2 to the SMMU's stream_bits, or whose second-level table was never
 *     made, is left alone.
 */
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

/**
 * Find a stream's stream table entry, making its second-level table if there's none yet.
 *
 * A new second-level table is installed in the first-level descriptor, and every cached configuration invalidated.
 *
 * @param iommu The SMMU, enabled.
 * @param stream The stream ID, within the stream table.
 * @param frames Where a zeroed frame for a new second-level table is taken from.
 * @return The entry's physical address, or null if a table had to be made and frames had none.
 */
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

/**
 * Map one 4 KiB page in a domain, readable, and writable if asked.
 *
 * Until invalidate, the SMMU may not see it. Nothing is changed when frames are short.
 *
 * @param iommu The SMMU, identified and enabled (its direct_map_offset set); only read: its address_bits and levels
 *     shape the walk, and its direct map reaches the tables.
 * @param domain The domain whose stage 2 tables are walked from its root, and added to where the walk lacks a table.
 * @param address The I/O virtual address, 4 KiB aligned and below 2 to the SMMU's address_bits.
 * @param physical The physical address it maps, 4 KiB aligned.
 * @param writable Whether the device may write it, as well as read it.
 * @param device Whether it's device memory, like the MSI doorbell, mapped Device-nGnRE; otherwise normal write-back
 *     RAM.
 * @param frames Zeroed frames for the tables the walk lacks, taken from its end.
 * @error InvalidAddress address or physical isn't 4 KiB aligned, or address is outside the domain's width.
 * @error NeedFrames frames has fewer than the tables the walk lacks.
 * @error AlreadyMapped A page is mapped there already.
 */
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

/**
 * Unmap one 4 KiB page in a domain, if it's mapped. Until invalidate, the SMMU may still reach it.
 *
 * Tables the page leaves empty stay, until release_domain.
 *
 * @param iommu The SMMU, enabled (its direct_map_offset set); only read, for its levels and direct map.
 * @param domain The domain whose tables are walked; its page's last-level descriptor is cleared.
 * @param address The page's I/O virtual address; its bits below 12 are ignored, and an address with no page mapped
 *     changes nothing.
 */
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

/**
 * Make the SMMU see a domain's tables as they are, waiting for it.
 *
 * A dsb makes the tables' writes visible to it. After unmapping, the domain's TLB entries are invalidated by its
 * VMID; nothing is cached of what isn't mapped, so mapping needs nothing more.
 *
 * @param iommu The SMMU, enabled; a TLB invalidation goes on its command queue and is waited for, a failed or timed
 *     out sync ignored.
 * @param domain The domain whose tables changed; only its ID, as the VMID whose TLB entries go, is read.
 * @param mapped True after mapping, false after unmapping.
 */
invalidate :: fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) {
    aarch64.dsb(.SY)
    if mapped {
        return void
    }
    submit(iommu, TLBI_S12_VMALL | cast[u64](domain.id & 0xffff) << 32, 0)
    _ = sync(iommu)
}

/**
 * Let go of a domain's tables, all but its root, as many as freed has room for each call.
 *
 * Nothing may be attached to it any more. What its pages mapped isn't touched.
 *
 * @param iommu The SMMU, enabled (its direct_map_offset set); only read, for its levels and direct map.
 * @param domain The domain, detached from every stream; its tables below the root are unlinked and their frames
 *     handed out, its root kept for the caller to free.
 * @param freed Where the tables' frames go; L2 frees them once the SMMU can no longer reach them.
 * @return True once only the root is left; false when freed is full, so L2 empties it and calls again.
 */
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

/**
 * Let go of one table below a table, as VT-d's does: the first, depth first, whose entries are pages or that has none
 * left.
 *
 * @param iommu The SMMU, its direct_map_offset set; only read, to reach the tables.
 * @param table The physical address of the table to look below.
 * @param level The table's level, 1 for a table of pages, which has no tables below it.
 * @param freed Where the table's frame goes, if there's room; the caller makes sure there is.
 * @return Whether a table was let go of; false when there's none below table.
 */
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

/**
 * Take the next record from the event queue.
 *
 * @param iommu The SMMU, enabled.
 * @return The fault: its stream ID, its event type as reason, and, for a translation, address size, access flag or
 *     permission fault (types 0x10 to 0x13), the page the device addressed and whether it was a write; any other
 *     event has address 0 and isn't a write. Null when the queue is empty.
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

/**
 * Remap nothing: it remaps no interrupts (info.interrupts is 0), so L2 never asks.
 *
 * @param iommu The SMMU, unused.
 * @param index The remapped interrupt's index, unused.
 * @param stream The stream, unused.
 * @param cpu_hardware_id The CPU's hardware ID, unused.
 * @param vector The interrupt ID, unused.
 *  * @param level Unused.
 @return An empty message.
 */
remap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32, level: bool)
    -> iommu_interface.MsiMessage {
    return iommu_interface.MsiMessage.{}
}

/**
 * Do nothing: it remaps no interrupts.
 *
 * @param iommu The SMMU, unused.
 * @param index The remapped interrupt's index, unused.
 */
unmap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
}

/**
 * Find which entry of a table an address is in.
 *
 * @param address The I/O virtual address.
 * @param level The table's level, 1 for the tables of pages, up to 4 for a top-level table.
 * @return The entry's index, 0 to 511.
 */
index_of :: fn(address: u64, level: u32) -> u64 {
    return (address >> (12 + 9 * cast[u64](level - 1))) & (ENTRIES - 1)
}

/**
 * Take a zeroed frame from the end of the frames L2 gave.
 *
 * @param frames The frames; its count drops by one when one is taken.
 * @return The frame's physical address, or null when there's none, or count is out of range.
 */
take_frame :: fn(frames: ptr[mut iommu_interface.TableFrames]) -> u64? {
    if frames.count == 0 || cast[usize](frames.count) > frames.frames.count {
        return null
    }
    frames.count -= 1
    return cast[u64](frames.frames[cast[usize](frames.count)])
}

/**
 * Invalidate a stream's cached configuration and a VMID's TLB entries, and wait for it.
 *
 * A sync that fails or times out is ignored.
 *
 * @param iommu The SMMU, its command queue on.
 * @param stream The stream ID whose cached stream table entry goes, within the stream table.
 * @param vmid The VMID whose TLB entries go; only the low 16 bits are used.
 */
invalidate_stream :: fn(iommu: ptr[mut Iommu], stream: u32, vmid: u32) {
    submit(iommu, CFGI_STE | cast[u64](stream) << 32, 1)
    submit(iommu, TLBI_S12_VMALL | cast[u64](vmid & 0xffff) << 32, 0)
    _ = sync(iommu)
}

/**
 * Put a command on the command queue, and tell the SMMU.
 *
 * It waits while the queue is full, for as long as the SMMU is reading it: a command written over one it hasn't read
 * would be lost, and a lost invalidation leaves stale translations in use. If the SMMU has stopped at an erroneous
 * command, it never reads on, so the kernel stops (an assertion) rather than wait for good or overwrite a command.
 *
 * @param iommu The SMMU, its command queue on; its command_producer moves past the command.
 * @param first The command's first word: its opcode and fields.
 * @param second The command's second word.
 */
submit :: fn(iommu: ptr[mut Iommu], first: u64, second: u64) {
    size :: cast[u32](1) << cast[u32](QUEUE_LOG)
    loop {
        consumer :: read_u32(iommu, COMMAND_CONSUMER)
        // Full: the same index, the other wrap
        if (iommu.command_producer ~ consumer) & ((size << 1) - 1) != size {
            break
        }
        runtime.assert(consumer & CONSUMER_ERROR == 0, "the SMMU's command queue stopped at an erroneous command")
        intrinsics.spin_hint()
    }
    at :: iommu.commands + cast[u64](iommu.command_producer & (size - 1)) * COMMAND_BYTES
    store(iommu, at, first)
    store(iommu, at + 8, second)
    aarch64.dsb(.SY)
    iommu.command_producer = (iommu.command_producer + 1) & ((size << 1) - 1)
    write_u32(iommu, COMMAND_PRODUCER, iommu.command_producer)
}

/**
 * Wait for every command submitted to complete: a CMD_SYNC, then the consumer at the producer.
 *
 * @param iommu The SMMU, its command queue on.
 * @return True once they have; false if the queue stopped at an erroneous command, or SPINS spins passed first.
 */
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

/**
 * Set CR0's enables, and wait for CR0ACK to say they've taken effect.
 *
 * @param iommu The SMMU, identified; only its registers are used.
 * @param enables The whole of CR0: CR0_SMMU, CR0_EVENT_QUEUE and CR0_COMMAND_QUEUE, or none.
 * @return True once CR0ACK equals enables; false if SPINS spins passed first.
 */
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

/**
 * Read a table entry or a queue entry's word through the direct map.
 *
 * @param iommu The SMMU, whose direct_map_offset is set.
 * @param at The word's physical address, 8-byte aligned.
 * @return The word's 64 bits as memory holds them now, read with a volatile load.
 */
load :: fn(iommu: ptr[Iommu], at: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](at + iommu.direct_map_offset))
}

/**
 * Write a table entry or a queue entry's word through the direct map. The SMMU sees it only after a dsb.
 *
 * @param iommu The SMMU, whose direct_map_offset is set.
 * @param at The word's physical address, 8-byte aligned.
 * @param value The 64 bits to write, in full: a descriptor, a stream table entry word or a command word.
 */
store :: fn(iommu: ptr[Iommu], at: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), value)
}

/**
 * Read a 32-bit register.
 *
 * @param iommu The SMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 4-byte aligned and below REGISTER_BYTES.
 * @return The register's 32 bits, read with a volatile load; all ones if nothing answers there.
 */
read_u32 :: fn(iommu: ptr[Iommu], offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](iommu.registers + offset))
}

/**
 * Write a 32-bit register.
 *
 * @param iommu The SMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 4-byte aligned and below REGISTER_BYTES.
 * @param value The register's new 32 bits, written whole with a volatile store.
 */
write_u32 :: fn(iommu: ptr[Iommu], offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](iommu.registers + offset), value)
}

/**
 * Write a 64-bit register.
 *
 * @param iommu The SMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 8-byte aligned.
 * @param value The register's new 64 bits, written whole with one volatile store.
 */
write_u64 :: fn(iommu: ptr[Iommu], offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](iommu.registers + offset), value)
}
