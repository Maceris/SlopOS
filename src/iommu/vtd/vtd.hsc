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
/*
 * SPEC: Intel Virtualization Technology for Directed I/O, Architecture Specification 4.1, §3.4.2-3 (root and context
 * entries), §3.6 (second-level translation), §6.5.2 (queued invalidation), §7.2.1 (primary fault logging),
 * §9.1-9.3 (root, context and second-level entries), §11.4 (registers); §5.1 (interrupt remapping), §5.1.2.2
 * (remappable interrupt requests), §6.5.2.7 (interrupt entry cache invalidation), §9.9 (remapping table entries)
 */

// ---- Registers: byte offsets from the unit's register base (VT-d §11.4)

/** VER_REG: the architecture version, major in bits 7:4 and minor in 3:0. */
VERSION : u64 : 0x000
/** CAP_REG: the capabilities, like SAGAW, MGAW, ND, caching mode, RWBF, and where the fault recording registers are. */
CAPABILITY : u64 : 0x008
/** ECAP_REG: the extended capabilities, like coherency, queued invalidation, interrupt remapping, and IRO. */
EXTENDED_CAPABILITY : u64 : 0x010
/** GCMD_REG: the global command register, which turns things on and off and sets table pointers. */
GLOBAL_COMMAND : u64 : 0x018
/** GSTS_REG: the global status register, each bit GCMD_REG's at the same place, saying it's taken effect. */
GLOBAL_STATUS : u64 : 0x01c
/** RTADDR_REG: the root table's physical address. */
ROOT_TABLE : u64 : 0x020
/** FSTS_REG: the fault status register, like primary fault overflow and invalidation queue error. */
FAULT_STATUS : u64 : 0x034
/** FECTL_REG: the fault event control register, whose bit 31 masks the fault event interrupt. */
FAULT_CONTROL : u64 : 0x038
/** FEDATA_REG: the fault event interrupt message's data. */
FAULT_DATA : u64 : 0x03c
/** FEADDR_REG: the fault event interrupt message's address, low 32 bits. */
FAULT_ADDRESS : u64 : 0x040
/** FEUADDR_REG: the fault event interrupt message's address, high 32 bits. */
FAULT_UPPER_ADDRESS : u64 : 0x044
/** IQH_REG: the invalidation queue's head, the next descriptor the unit reads. */
QUEUE_HEAD : u64 : 0x080
/** IQT_REG: the invalidation queue's tail, in bits 18:4, the descriptor after the last one written. */
QUEUE_TAIL : u64 : 0x088
/** IQA_REG: the invalidation queue's physical address and size; size 0 is one page of 256 descriptors. */
QUEUE_ADDRESS : u64 : 0x090
/** IRTA_REG: the interrupt remapping table's physical address, size and extended interrupt mode. */
REMAPPING_TABLE : u64 : 0x0b8
/** The bytes of registers every unit has, from its version register to its last fixed one. */
FIXED_REGISTERS : u64 : 0x100

/** CAP_REG.SAGAW, after shifting its bits 12:8 down: 3-level tables, for 39-bit addresses. */
SAGAW_39 : u64 : 1 << 1
/** CAP_REG.SAGAW, after shifting its bits 12:8 down: 4-level tables, for 48-bit addresses. */
SAGAW_48 : u64 : 1 << 2
/** CAP_REG.RWBF: table writes have to be flushed from the unit's write buffer with a write buffer flush. */
CAPABILITY_RWBF : u64 : 1 << 4
/** CAP_REG.CM, caching mode: the unit may cache entries that aren't present, so mapping needs invalidating too. */
CAPABILITY_CACHING_MODE : u64 : 1 << 7
/** ECAP_REG.C: the unit's table walks snoop the CPUs' caches. */
EXTENDED_COHERENT : u64 : 1 << 0
/** ECAP_REG.QI: queued invalidation is supported. */
EXTENDED_QUEUED_INVALIDATION : u64 : 1 << 1
/** ECAP_REG.IR: interrupt remapping is supported. */
EXTENDED_INTERRUPT_REMAPPING : u64 : 1 << 3
/** ECAP_REG.EIM: extended interrupt mode, with x2APIC destinations, is supported. */
EXTENDED_INTERRUPT_MODE : u64 : 1 << 4

// ---- Global command bits, and their status bits at the same places

/** GCMD_REG.TE: translation enable, persistent. */
COMMAND_TRANSLATION : u32 : 1 << 31
/** GCMD_REG.SRTP: set the root table pointer from RTADDR_REG, one-shot; its status bit is set when done. */
COMMAND_ROOT_TABLE : u32 : 1 << 30
/** GCMD_REG.WBF: write buffer flush, one-shot; its status bit is clear when done. */
COMMAND_WRITE_BUFFER_FLUSH : u32 : 1 << 27
/** GCMD_REG.QIE: queued invalidation enable, persistent. */
COMMAND_QUEUED_INVALIDATION : u32 : 1 << 26
/** GCMD_REG.IRE: interrupt remapping enable, persistent. */
COMMAND_INTERRUPT_REMAPPING : u32 : 1 << 25
/** GCMD_REG.SIRTP: set the interrupt remapping table pointer from IRTA_REG, one-shot; its status is set when done. */
COMMAND_REMAPPING_TABLE : u32 : 1 << 24
/** The status bits that are on or off, as the command register's are written back: the one-shot ones left out. */
STATUS_PERSISTENT : u32 : 0x96ffffff

/** FSTS_REG.PFO: a primary fault overflowed the fault recording registers; written 1 to clear. */
FAULT_STATUS_OVERFLOW : u32 : 1 << 0
/** FSTS_REG.IQE: an invalidation queue error stopped the queue. */
FAULT_STATUS_QUEUE_ERROR : u32 : 1 << 4
/** FECTL_REG.IM: the fault event interrupt is masked. */
FAULT_CONTROL_MASKED : u32 : 1 << 31
/** A fault recording register's upper half's F bit: a fault is recorded; written 1 to clear. */
FAULT_RECORDED : u64 : 1 << 63
/** A fault recording register's upper half's T bit: set for a read, clear for a write. */
FAULT_READ : u64 : 1 << 62

// ---- Table entries (VT-d §9.1-9.3)

/** A root or context entry's present bit. */
PRESENT : u64 : 1 << 0
/** A second-level entry's read bit; an entry with neither read nor write is not present. */
READ : u64 : 1 << 0
/** A second-level entry's write bit. */
WRITE : u64 : 1 << 1
/** An entry's address bits, 51:12: the physical address of the table or page it points at. */
ADDRESS_MASK : u64 : 0x000ffffffffff000
/** The entries in a second-level table, 4 KiB of 8 bytes each. */
ENTRIES : u64 : 512
/** The bytes of a page and of a table. */
PAGE : u64 : 4096
/** The bytes clflush flushes at once, a cache line. */
CACHE_LINE : u64 : 64

// ---- Invalidation descriptors (VT-d §6.5.2): types in bits 3:0, granularities in bits 5:4

/** A context-cache invalidate descriptor's type. */
DESCRIPTOR_CONTEXT : u64 : 1
/** An IOTLB invalidate descriptor's type. */
DESCRIPTOR_IOTLB : u64 : 2
/** An interrupt entry cache invalidate descriptor's type; alone, it invalidates every entry. */
DESCRIPTOR_INTERRUPT_ENTRY : u64 : 4
/** An interrupt entry cache invalidation's granularity bit: one entry, its index in bits 47:32, not all of them. */
INTERRUPT_ENTRY_ONE : u64 : 1 << 4
/** An invalidation wait descriptor's type. */
DESCRIPTOR_WAIT : u64 : 5
/** A context-cache or IOTLB invalidation's granularity: global, everything. */
GLOBAL : u64 : 1 << 4
/** A context-cache or IOTLB invalidation's granularity: one domain, its ID in bits 31:16. */
DOMAIN : u64 : 2 << 4
/** A wait descriptor's SW bit: write its status data, bits 63:32, to the address in its upper half. */
WAIT_STATUS_WRITE : u64 : 1 << 5
/** A wait descriptor's FN bit: descriptors after it wait until it's done. */
WAIT_FENCE : u64 : 1 << 6
/** The invalidation queue's descriptors: 256 of 16 bytes, one page. */
QUEUE_ENTRIES : u32 : 256

// ---- Interrupt remapping (VT-d §5.1, §9.9)

/** The interrupt remapping table's entries: 256 of 16 bytes, one page. */
INTERRUPT_ENTRIES : u32 : 256
/** IRTA_REG's size field: the entries' log 2, less 1. */
TABLE_SIZE_FIELD : u64 : 7
/** IRTA_REG.EIME: extended interrupt mode, entries' destinations x2APIC IDs. */
TABLE_EXTENDED_MODE : u64 : 1 << 11
/** An interrupt remapping entry's present bit. */
ENTRY_PRESENT : u64 : 1 << 0
/** Where an interrupt remapping entry's vector is, bits 23:16. */
ENTRY_VECTOR_SHIFT : u64 : 16
/** Where an interrupt remapping entry's destination is, bits 63:32. */
ENTRY_DESTINATION_SHIFT : u64 : 32
/** An entry's upper half's SVT, 1: the request's requester ID has to be the entry's SID, every bit compared. */
ENTRY_VERIFY_SOURCE : u64 : 1 << 18
/** A remappable message's address's base: the interrupt range. */
MESSAGE_BASE : u64 : 0xfee00000
/** A message address's interrupt format bit, set for a remappable one, whose handle's bits 14:0 are in bits 19:5. */
MESSAGE_REMAPPABLE : u64 : 1 << 4
/** How long a command or a wait may take, in spins of spin_hint, before it's taken as timed out. */
SPINS : u64 : 1_000_000

/** One VT-d unit (iommu_interface.Iommu). */
Iommu :: struct {
    /** The virtual address of its registers, mapped by L2 as device memory. */
    registers : u64,
    /** Its domains' I/O virtual address width in bits: 39 to 48, the least of its MGAW and its widest table's. */
    address_bits : u32,
    /** Its domains' second-level tables' levels: 4 where SAGAW has 48-bit tables, otherwise 3. */
    levels : u32,
    /** The byte offset of its IOTLB's registers from its registers' start (ECAP_REG.IRO). */
    iotlb : u64,
    /** The byte offset of its fault recording registers from its registers' start (CAP_REG.FRO). */
    faults : u64,
    /** How many fault recording registers it has, 1 to 256 (CAP_REG.NFR plus 1). */
    fault_count : u32,
    /** The fault recording register to look at first, below fault_count. */
    next_fault : u32,
    /** Whether table writes are flushed from the CPU's cache, where its walks don't snoop (ECAP_REG.C clear). */
    flushes : bool,
    /** Whether mapping is invalidated too (CAP_REG.CM). */
    caching_mode : bool,
    /** Whether table writes need a write buffer flush (CAP_REG.RWBF). */
    write_buffer : bool,
    /** Whether it remaps interrupts (ECAP_REG.IR). */
    remaps : bool,
    /** Whether its remapping entries' destinations are x2APIC IDs (ECAP_REG.EIM); otherwise xAPIC IDs. */
    extended_mode : bool,
    /** From enable: its interrupt remapping table's physical address, one page. */
    remapping : u64,
    /** From enable: the virtual address of physical 0 in the direct map, through which tables and queue are used. */
    direct_map_offset : u64,
    /** From enable: its root table's physical address, one page of 256 root entries. */
    root : u64,
    /** From enable: its invalidation queue's physical address, one page. */
    queue : u64,
    /** The invalidation queue's tail, the next descriptor's index, below QUEUE_ENTRIES. */
    tail : u32,
    /** From enable: the physical address of the status word invalidation waits write. */
    status : u64,
    /** How many waits it has submitted, the value the last one writes to the status word. */
    waits : u32,
}

/** One domain on a unit (iommu_interface.Domain). */
Domain :: struct {
    /** The physical address of its top-level second-level table, a 4 KiB frame. */
    root : u64,
    /** Its domain ID, from 1 up; 0 is never one, as caching mode keeps it for itself. */
    id : u32,
}

/**
 * Identify a VT-d unit, changing nothing on it: DMA through it goes on as before.
 *
 * Its version register has to be 1.0 or later, and its registers, as far as its capability registers place the
 * IOTLB's and the fault recording registers, have to fit in size. It has to have queued invalidation, and 3- or
 * 4-level second-level tables with at least 39-bit addresses.
 *
 * @param iommu Where what's needed of it is kept. Written only when it's found and supported.
 * @param kind The kind the platform service says it is.
 * @param registers The virtual address L2 mapped its registers at, uncached.
 * @param size The bytes mapped there, at least FIXED_REGISTERS.
 * @return What it is: its version, address width, the four pages enable takes, its domain IDs (1 up to 2 to the
 *     4 + 2 ND, less 1, at most 65535), 256 interrupts remapped where it remaps them and none where it doesn't, and
 *     faults signalled by message.
 * @error UnsupportedKind kind isn't VtD.
 * @error NotFound Fewer than FIXED_REGISTERS are mapped, the registers don't read as a unit's, or its IOTLB's or
 *     fault recording registers are past size.
 * @error Unsupported It lacks one of the things above.
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
        interrupts = if iommu.remaps { INTERRUPT_ENTRIES } else { 0 }, fault_messages = true})
}

/**
 * Turn translation on, every stream blocked until it's attached, and interrupt remapping where the unit has it.
 *
 * The queue goes on first, then the root table, both caches are invalidated, the fault event interrupt is masked,
 * and translation goes on; then, where the unit remaps interrupts, the remapping table, its cache invalidated, and
 * remapping, compatibility-format interrupts blocked.
 *
 * @param iommu The unit, identified.
 * @param memory The physical address of four zeroed, contiguous pages: the root table, the invalidation queue, the
 *     status word invalidation waits write, and the interrupt remapping table. The unit keeps them for good.
 * @param direct_map_offset The virtual address of physical 0 in the direct map, through which tables and the queue
 *     are reached.
 * @error Timeout A command's status didn't follow within SPINS spins, or a wait didn't complete or met a queue
 *     error; the unit may be left partly set up.
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

/**
 * Make a remapped interrupt deliver a vector to a CPU, from one stream only; the unit uses it once this returns.
 *
 * The entry is fixed delivery, edge-triggered, physical destination mode, to the CPU's APIC ID. Its upper half is
 * written first and its present bit last, then its cached copy invalidated.
 *
 * @param iommu The unit, enabled with interrupt remapping.
 * @param index The remapped interrupt's index, below INTERRUPT_ENTRIES.
 * @param stream The requester ID (bus, device and function) the interrupt has to come from.
 * @param cpu_hardware_id The CPU's APIC ID: its x2APIC ID in extended interrupt mode, otherwise its xAPIC ID, of
 *     which the low 8 bits are used.
 * @param vector The vector, an InterruptId; the low 8 bits are used.
 * @return The message stream's device writes to raise it: a remappable-format address carrying index as its handle,
 *     and data 0.
 */
remap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32) -> iommu_interface.MsiMessage {
    // One index for the entry, its invalidation and its handle, so they never disagree
    slot :: index % INTERRUPT_ENTRIES
    entry :: iommu.remapping + cast[u64](slot) * 16
    // SVT 1, SQ 0: the requester ID must be stream's
    store(iommu, entry + 8, cast[u64](stream & 0xffff) | ENTRY_VERIFY_SOURCE)
    destination :: if iommu.extended_mode { cpu_hardware_id & 0xffffffff } else { (cpu_hardware_id & 0xff) << 8 }
    store(iommu, entry, destination << ENTRY_DESTINATION_SHIFT | cast[u64](vector & 0xff) << ENTRY_VECTOR_SHIFT | ENTRY_PRESENT)
    invalidate_interrupt(iommu, slot)
    handle :: cast[u64](slot)
    return iommu_interface.MsiMessage.{address = MESSAGE_BASE | (handle & 0x7fff) << 5 | MESSAGE_REMAPPABLE | ((handle >> 15) & 1) << 2,
        data = 0}
}

/**
 * Make a remapped interrupt raise nothing, with nothing the unit cached of it left when this returns.
 *
 * @param iommu The unit, enabled with interrupt remapping.
 * @param index The remapped interrupt's index, below INTERRUPT_ENTRIES.
 */
unmap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
    slot :: index % INTERRUPT_ENTRIES
    entry :: iommu.remapping + cast[u64](slot) * 16
    store(iommu, entry, 0)
    store(iommu, entry + 8, 0)
    invalidate_interrupt(iommu, slot)
}

/**
 * Invalidate one interrupt remapping entry's cached copy, and wait for it. A wait that fails is ignored.
 *
 * @param iommu The unit, its invalidation queue on; the descriptor and a wait are put on it.
 * @param index The entry's index, below INTERRUPT_ENTRIES, as remap_interrupt and unmap_interrupt pass it.
 */
invalidate_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
    submit(iommu, DESCRIPTOR_INTERRUPT_ENTRY | INTERRUPT_ENTRY_ONE | cast[u64](index) << 32, 0)
    _ = wait(iommu)
}

/**
 * Signal faults by a message: the fault event registers are set, then the interrupt unmasked.
 *
 * @param iommu The unit, enabled.
 * @param message What the unit writes, and where, to raise the fault interrupt.
 */
route_faults :: fn(iommu: ptr[mut Iommu], message: iommu_interface.MsiMessage) {
    write_u32(iommu, FAULT_DATA, message.data)
    write_u32(iommu, FAULT_ADDRESS, cast[u32](message.address))
    write_u32(iommu, FAULT_UPPER_ADDRESS, cast[u32](message.address >> 32))
    write_u32(iommu, FAULT_CONTROL, 0)
}

/**
 * Make an empty domain on the unit. Nothing is written to the unit or the table.
 *
 * @param iommu The unit, unused.
 * @param domain The domain to set up.
 * @param id Its domain ID, from 1 to identify's domain_ids.
 * @param root The physical address of a zeroed 4 KiB frame for its top-level table.
 */
init_domain :: fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: iommu_interface.PhysicalAddress) {
    domain.root = cast[u64](root)
    domain.id = id
}

/**
 * Translate a stream's DMA through a domain from now on, instead of what it was before.
 *
 * The stream's context entry, by its bus and its device and function, is written: its bus's context table is made
 * where it has none, and a present entry is made not present and invalidated first, as an entry in use can't be
 * changed in place.
 *
 * @param iommu The unit, enabled.
 * @param domain The domain to translate through, made by init_domain; its root and ID go into the context entry, so
 *     it must stay alive and keep its root until the stream is detached.
 * @param stream The requester ID: bus in bits 15:8, device and function in 7:0; higher bits are ignored.
 * @param frames Zeroed frames, of which one is taken for the bus's context table if it has none.
 * @error NeedFrames The bus's context table had to be made and frames was empty; nothing was changed.
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

/**
 * Block a stream's DMA again, with nothing cached of it left when this returns.
 *
 * Its context entry is made not present and invalidated, with the domain's IOTLB entries. A stream without one is
 * left alone.
 *
 * @param iommu The unit, enabled.
 * @param domain The domain it was attached to, whose IOTLB entries are invalidated by its ID.
 * @param stream The requester ID: bus in bits 15:8, device and function in 7:0; higher bits are ignored. One with no
 *     present context entry is left alone.
 */
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

/**
 * Map one 4 KiB page in a domain, readable, and writable if asked.
 *
 * Until invalidate, the unit may not see it. Nothing is changed when frames are short.
 *
 * @param iommu The unit, enabled (its direct_map_offset set); only read: its address_bits and levels shape the walk,
 *     and table writes are flushed from the cache where it doesn't snoop.
 * @param domain The domain whose second-level tables are walked from its root, and added to where the walk lacks a
 *     table.
 * @param address The I/O virtual address, 4 KiB aligned and below 2 to the unit's address_bits.
 * @param physical The physical address it maps, 4 KiB aligned.
 * @param writable Whether the device may write it, as well as read it.
 * @param device Whether it's device memory; unused, as second-level entries have no memory type of their own here,
 *     so device memory is mapped as RAM is.
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

/**
 * Unmap one 4 KiB page in a domain, if it's mapped. Until invalidate, the unit may still reach it.
 *
 * Tables the page leaves empty stay, until release_domain.
 *
 * @param iommu The unit, enabled (its direct_map_offset set); only read, for its levels and direct map.
 * @param domain The domain whose tables are walked; its page's last-level entry is cleared.
 * @param address The page's I/O virtual address; its bits below 12 are ignored, and an address with no page mapped
 *     changes nothing.
 */
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

/**
 * Make the unit see a domain's tables as they are, waiting for it.
 *
 * The domain's IOTLB entries and cached tables are invalidated by its ID; after mapping, only in caching mode, and
 * otherwise the write buffer is flushed where the unit needs it. A wait or flush that fails is ignored.
 *
 * @param iommu The unit, enabled, its invalidation queue on.
 * @param domain The domain whose tables changed; only its ID, whose IOTLB entries go, is read.
 * @param mapped True after mapping, false after unmapping.
 */
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

/**
 * Let go of a domain's tables, all but its root, as many as freed has room for each call.
 *
 * Nothing may be attached to it any more. What its pages mapped isn't touched.
 *
 * @param iommu The unit, enabled (its direct_map_offset set); only read, for its levels and direct map.
 * @param domain The domain, detached from every stream; its tables below the root are unlinked and their frames
 *     handed out, its root kept for the caller to free.
 * @param freed Where the tables' frames go; L2 frees them once the unit can no longer reach them.
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
 * Let go of one table below a table: the first, depth first, whose own entries are pages, or that has none left.
 *
 * @param iommu The unit, its direct_map_offset set; only read, to reach the tables and flush what's cleared.
 * @param table The physical address of the table to look below.
 * @param level The table's level, 1 for a table of pages, which has no tables below it.
 * @param freed Where the table's frame goes, if there's room; the caller makes sure there is.
 * @return Whether a table was let go of; false if table has no tables below it.
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

/**
 * Take the next recorded fault, from the fault recording register after the last one taken, clearing it.
 *
 * When none is recorded, the primary fault overflow is cleared, so the unit records faults again.
 *
 * @param iommu The unit, enabled.
 * @return The fault: its requester ID, its reason, whether it was a write, and either the page the device addressed
 *     or, for interrupt remapping's reasons (0x20 to 0x2f), the interrupt's index. Null when none is recorded.
 */
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
 * Read a table entry's word through the direct map.
 *
 * @param iommu The unit, whose direct_map_offset is set.
 * @param at The word's physical address, 8-byte aligned.
 * @return The word's 64 bits as memory holds them now, read with a volatile load.
 */
load :: fn(iommu: ptr[Iommu], at: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](at + iommu.direct_map_offset))
}

/**
 * Write a table entry's word through the direct map, flushed from the cache where the unit doesn't snoop.
 *
 * @param iommu The unit, whose direct_map_offset is set.
 * @param at The word's physical address, 8-byte aligned.
 * @param value The 64 bits to write, in full: a root, context or second-level table entry's word.
 */
store :: fn(iommu: ptr[Iommu], at: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), value)
    flush_range(iommu, at, 8)
}

/**
 * Flush memory from the CPU's cache, where the unit's walks don't snoop, then fence; otherwise do nothing.
 *
 * @param iommu The unit, its direct_map_offset set; when its flushes is false, nothing is done.
 * @param at The physical address of the first byte.
 * @param size The bytes to flush; every cache line they touch is flushed.
 */
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

/**
 * Invalidate the whole context cache and one domain's IOTLB entries, and wait for it. A wait that fails is ignored.
 *
 * @param iommu The unit, enabled.
 * @param id The ID of the domain whose IOTLB entries go, from 1 to identify's domain_ids.
 */
invalidate_context :: fn(iommu: ptr[mut Iommu], id: u32) {
    submit(iommu, DESCRIPTOR_CONTEXT | GLOBAL, 0)
    submit(iommu, DESCRIPTOR_IOTLB | DOMAIN | cast[u64](id) << 16, 0)
    _ = wait(iommu)
}

/**
 * Put a descriptor on the invalidation queue, and tell the unit by moving the tail past it.
 *
 * It doesn't check for room: every batch is waited for, so the queue never holds many.
 *
 * @param iommu The unit, its queue on.
 * @param lower The descriptor's low 64 bits: its type, granularity and fields.
 * @param upper The descriptor's high 64 bits.
 */
submit :: fn(iommu: ptr[mut Iommu], lower: u64, upper: u64) {
    at :: iommu.queue + cast[u64](iommu.tail) * 16
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), lower)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + 8 + iommu.direct_map_offset), upper)
    flush_range(iommu, at, 16)
    iommu.tail = (iommu.tail + 1) % QUEUE_ENTRIES
    write_u64(iommu, QUEUE_TAIL, cast[u64](iommu.tail) << 4)
}

/**
 * Wait for everything submitted to be done: a wait descriptor that writes the next status, fenced after what's
 * before it.
 *
 * @param iommu The unit, its queue on; its waits count goes up by one.
 * @return True once the status word has the new count; false at an invalidation queue error, or after SPINS spins.
 */
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

/**
 * Turn a persistent command on or off, with the others as they are, and wait until its status says so.
 *
 * @param iommu The unit, identified; only its registers are used.
 * @param bit The command's bit, one of the persistent ones (COMMAND_TRANSLATION, COMMAND_QUEUED_INVALIDATION,
 *     COMMAND_INTERRUPT_REMAPPING).
 * @param on Whether to turn it on.
 * @return True once its status bit matches on; false after SPINS spins.
 */
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

/**
 * Issue a one-shot command, with the persistent ones as they are, and wait until its status says it's done.
 *
 * @param iommu The unit, identified; only its registers are used.
 * @param bit The command's bit: COMMAND_ROOT_TABLE or COMMAND_REMAPPING_TABLE, done when their status is set, or
 *     COMMAND_WRITE_BUFFER_FLUSH, done when its status is clear.
 * @return True once it's done; false after SPINS spins.
 */
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

/**
 * Read a 32-bit register.
 *
 * @param iommu The unit, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 4-byte aligned and within what L2 mapped.
 * @return The register's 32 bits, read with a volatile load.
 */
read_u32 :: fn(iommu: ptr[Iommu], offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](iommu.registers + offset))
}

/**
 * Write a 32-bit register.
 *
 * @param iommu The unit, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 4-byte aligned and within what L2 mapped.
 * @param value The register's new 32 bits, written whole with a volatile store.
 */
write_u32 :: fn(iommu: ptr[Iommu], offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](iommu.registers + offset), value)
}

/**
 * Write a 64-bit register.
 *
 * @param iommu The unit, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 8-byte aligned.
 * @param value The register's new 64 bits, written whole with one volatile store.
 */
write_u64 :: fn(iommu: ptr[Iommu], offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](iommu.registers + offset), value)
}
