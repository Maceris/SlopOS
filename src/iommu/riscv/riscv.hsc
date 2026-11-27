package iommu_riscv

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import runtime from "base:runtime"
import iommu_interface from "../../iommu_interface"

/*
 * The RISC-V IOMMU (iommu_interface, decisions/0199's R6): one IOMMU, which the platform service finds through the
 * device tree's iommu-map, as an SMMUv3 (decisions/0039, 0079, 0083). Its domains use the first stage only, Sv48, the
 * second stage Bare: each domain's tables are a hart's own kind, 4 levels, its I/O virtual addresses below 2^47, as
 * Sv48's upper half isn't reachable from a device's zero-extended ones, and its domain ID is its PSCID. A two-level
 * device directory, each leaf one page of device contexts, made as devices are attached; every other device's DMA
 * faults. Commands go through the command queue, each batch ended with an IOFENCE.C whose completion is the queue's
 * head reaching its tail; faults are records in the fault queue, which L2 reads.
 *
 * MSIs are remapped where it has MSI_FLAT and MSI_MRIF: each device's context has its own MSI page table (msiptp
 * Flat), a page made as it's first attached, whose entries are the remapped interrupts L2 gave the device. A remapped
 * interrupt's message writes its index to a page of MSI_WINDOW, the page's number picking the entry; L2 maps the window
 * into each domain at its own addresses. Each entry is MRIF mode: the write sets a bit in the device's memory-resident
 * interrupt file, in the same page, and where that bit is enabled, one of the device's own indices, the IOMMU sends the
 * entry's notice, which is the interrupt itself: the CPU's interrupt ID, written to its hart's supervisor interrupt
 * file. A device reaches only its own table, so it raises only its own interrupts, never another device's nor an IPI.
 * Without both, it remaps none, and MSIs are translated as other writes (msiptp Off), to the harts' interrupt files,
 * which L2 maps into each domain (arch_interface.msi_doorbell).
 *
 * Its table walks and queue accesses are taken to be coherent, as QEMU's are and the platform's device tree says of
 * the PCI host (dma-coherent), so what's written is ordered before telling it by a fence. L2 serializes calls on one
 * IOMMU.
 *
 * Two things for QEMU's (11.1): its walk checks U on every entry, a table's as well as a page's, as a request without a
 * process ID is user mode's, so the tables' entries have U set too, which the privileged spec reserves and later
 * QEMUs ignore; and it takes a page's PPN with its PBMT bits, so a page has none, its memory type left to the PMAs,
 * which make the harts' interrupt files device memory whatever a page says.
 *
 * SPEC: The RISC-V IOMMU Architecture Specification, version 1.0: §2 (the device directory and device contexts, and
 * §2.3.3, MSI page tables and MRIFs), §3 (queues and commands), §4 (fault records), §5 (registers); The RISC-V
 * Advanced Interrupt Architecture, version 1.0 (interrupt files); The RISC-V Instruction Set Manual, Volume II: Sv48.
 */

// ---- Registers: byte offsets from the IOMMU's register base (§5)

/** capabilities: its version in bits 7:0 and what it supports, like Sv48, Svpbmt and MSI_FLAT. */
CAPABILITIES : u64 : 0x00
/** fctl: its features' controls: BE, little-endian if 0; WSI, wired interrupts; left 0. */
FEATURES_CONTROL : u64 : 0x08
/** ddtp: the device directory's mode, in bits 3:0, busy in bit 4, its root's PPN in bits 53:10. */
DDTP : u64 : 0x10
/** cqb: the command queue's PPN in bits 53:10, and its log2 size less one in bits 4:0. */
COMMAND_QUEUE_BASE : u64 : 0x18
/** cqh: the command queue's head, the index of the next command the IOMMU takes; it writes it. */
COMMAND_HEAD : u64 : 0x20
/** cqt: the command queue's tail, the index past the last command software put there. */
COMMAND_TAIL : u64 : 0x24
/** fqb: the fault queue's PPN, and its log2 size less one. */
FAULT_QUEUE_BASE : u64 : 0x28
/** fqh: the fault queue's head, the index of the next record software takes. */
FAULT_HEAD : u64 : 0x30
/** fqt: the fault queue's tail, past the last record the IOMMU wrote; it writes it. */
FAULT_TAIL : u64 : 0x34
/** cqcsr: the command queue's enable, and its errors and state. */
COMMAND_CONTROL : u64 : 0x48
/** fqcsr: the fault queue's enable, and its errors and state. */
FAULT_CONTROL : u64 : 0x4c
/** The bytes of registers it has. */
REGISTER_BYTES : u64 : 0x1000

/** capabilities' Sv48: first-stage Sv48 tables are supported. */
CAPABILITY_SV48 : u64 : 1 << 10
/** capabilities' MSI_FLAT: device contexts are the extended format's, 64 bytes, rather than the base format's 32. */
CAPABILITY_MSI_FLAT : u64 : 1 << 22
/** capabilities' MSI_MRIF: MSI page table entries may be MRIF mode. */
CAPABILITY_MSI_MRIF : u64 : 1 << 23

// ---- Remapped MSIs (§2.3.3)

/** The interrupts it remaps where it has MSI_MRIF: as many as a device's MSI page table has entries. */
REMAPPED_INTERRUPTS : u32 : 128
/**
 * Where remapped interrupts' messages write, an I/O address and the physical address it's mapped to in every domain:
 * a page for each remapped interrupt, whose number below the window picks its MSI page table entry. Nothing is
 * there; the IOMMU takes the writes as MSIs before they'd reach memory. Below 2^47, past any RAM a board has, and
 * aligned to the window's size.
 */
MSI_WINDOW : u64 : 1 << 46
/** msi_addr_mask: the page number bits under the window that pick an entry, REMAPPED_INTERRUPTS of them. */
MSI_ADDRESS_MASK : u64 : 0x7f
/** msiptp's MODE Flat, bits 63:60: MSIs go through the MSI page table its PPN, bits 43:0, says. */
MSIPTP_FLAT : u64 : 1 << 60
/** msiptp's PPN. */
MSIPTP_PPN : u64 : (1 << 44) - 1
/** An MSI page table entry's V. */
MSI_ENTRY_VALID : u64 : 1
/** An MSI page table entry's M, bits 2:1: 1 for MRIF mode. */
MSI_ENTRY_MRIF : u64 : 1 << 1
/** The bytes of an MSI page table entry: two doublewords. */
MSI_ENTRY_BYTES : u64 : 16
/** Where a device's MRIF is in its MSI page table's page: past its entries, 512-byte aligned. */
MRIF_OFFSET : u64 : 2048
/** IOTINVAL.GVMA, func3 1, no GV: every cached MSI page table entry goes, with what the second stage cached. */
IOTINVAL_GVMA : u64 : 1 | (1 << 7)

/** ddtp's iommu_mode Off: every device's DMA is refused. */
MODE_OFF : u64 : 0
/** ddtp's iommu_mode 2LVL: a two-level device directory. */
MODE_TWO_LEVEL : u64 : 3
/** ddtp's busy: a write to ddtp hasn't taken effect yet. */
DDTP_BUSY : u64 : 1 << 4

/** cqcsr's and fqcsr's enable, bit 0. */
QUEUE_ENABLE : u32 : 1 << 0
/**
 * cqcsr's cqmf, cmd_to and cmd_ill, bits 8 to 10: the command queue stopped, at a memory fault, a timeout, a bad
 * command.
 */
COMMAND_ERRORS : u32 : 7 << 8
/**
 * fqcsr's fqmf and fqof, bits 8 and 9: the fault queue stopped taking records, at a memory fault writing one or with
 * no room for one, until each is cleared by writing it back.
 */
FAULT_ERRORS : u32 : 3 << 8
/** cqcsr's and fqcsr's on, bit 16: the queue is running. */
QUEUE_ON : u32 : 1 << 16
/** cqcsr's and fqcsr's busy, bit 17: a change of enable hasn't taken effect yet. */
QUEUE_BUSY : u32 : 1 << 17

/** The command queue's log2 size in entries: 256 of 16 bytes, one page. */
COMMAND_LOG : u64 : 8
/** The fault queue's log2 size in records: 128 of 32 bytes, one page, so each queue is a page-aligned page. */
FAULT_LOG : u64 : 7
/** The bytes of one command. */
COMMAND_BYTES : u64 : 16
/** The bytes of one fault record. */
FAULT_BYTES : u64 : 32

// ---- Commands (§3.1): opcode in bits 6:0, func3 in 9:7 of the first word

/** IOTINVAL.VMA, with PSCV (bit 32) and the PSCID in bits 31:12: invalidate a PSCID's first-stage translations. */
IOTINVAL_VMA : u64 : 1
/** IOTINVAL's PSCV: only the PSCID's are invalidated. */
PSCID_VALID : u64 : 1 << 32
/** IOFENCE.C: complete once every command before it has. */
IOFENCE_C : u64 : 2
/** IODIR.INVAL_DDT, with DV (bit 33) and the device ID in bits 63:40: invalidate a device's cached context. */
IODIR_INVAL_DDT : u64 : 3
/** IODIR's DV: only the device ID's context is invalidated. */
DEVICE_VALID : u64 : 1 << 33

// ---- The device directory (§2)

/** A non-leaf device directory entry's V: valid, its PPN in bits 53:10. */
DIRECTORY_VALID : u64 : 1
/** A device context's tc's V: valid; with nothing else set, translation through fsc, faults recorded. */
CONTEXT_VALID : u64 : 1
/** A device context's fsc as iosatp: MODE 9, Sv48, in bits 63:60, the root's PPN in bits 43:0. */
FSC_SV48 : u64 : 9 << 60
/** The device directory's non-leaf entries in a page: device ID bits above the leaf's, 9 of them. */
DIRECTORY_ENTRIES : u64 : 512

// ---- First-stage page table entries (Sv48)

/** A page table entry's V. */
VALID : u64 : 1 << 0
/** A leaf's R: the device may read it. */
READABLE : u64 : 1 << 1
/** A leaf's W: the device may write it. */
WRITABLE : u64 : 1 << 2
/** An entry's U: a device's requests, with no process ID, are user mode's; set on a table's entries too, for QEMU. */
USER : u64 : 1 << 4
/** A leaf's A, set so no access faults for it. */
ACCESSED : u64 : 1 << 6
/** A leaf's D, set so no write faults for it. */
DIRTY : u64 : 1 << 7
/** An entry's PPN, bits 53:10. */
PPN_MASK : u64 : 0x003ffffffffffc00
/** The entries in one table, 4 KiB of 8 bytes each. */
ENTRIES : u64 : 512
/** The bytes of a page and of a table. */
PAGE : u64 : 4096
/** The levels of a domain's tables: Sv48's 4. */
LEVELS : u32 : 4
/** A domain's I/O virtual address bits: Sv48's lower half, as a device's addresses aren't sign-extended. */
ADDRESS_BITS : u32 : 47
/** How long a command, or an enable, may take, in spins of spin_hint, before it's taken as timed out. */
SPINS : u64 : 1_000_000

/** One RISC-V IOMMU (iommu_interface.Iommu). */
Iommu :: struct {
    /** The virtual address of its registers, mapped by L2 as device memory. */
    registers : u64,
    /** A device context's bytes: 64 with MSI_FLAT, the extended format; 32 without, the base format. */
    context_bytes : u64,
    /** The device ID bits a leaf of the device directory covers: 6 for the extended format, 7 for the base. */
    leaf_bits : u64,
    /** From enable: the virtual address of physical 0 in the direct map, through which tables and queues are read. */
    direct_map_offset : u64,
    /** From enable: the device directory's root's physical address. */
    directory : u64,
    /** From enable: the command queue's physical address. */
    commands : u64,
    /** The command queue's tail, as last written to cqt. */
    command_tail : u32,
    /** From enable: the fault queue's physical address. */
    faults : u64,
    /** The fault queue's head, as last written to fqh. */
    fault_head : u32,
    /** Whether it remaps MSIs through MRIFs: it has MSI_FLAT and MSI_MRIF. */
    remaps : bool,
    /** Each remapped interrupt L2 gave out, by index: its device's MSI page table has its entry once it's attached. */
    remapped : RemappedInterrupt[REMAPPED_INTERRUPTS],
}

/** A remapped interrupt: whose it is, and where its notice goes. */
RemappedInterrupt :: struct {
    /** Whether L2 gave it out; the rest means nothing when it isn't. */
    used : bool,
    /** The device ID whose MSI page table has it. */
    stream : u32,
    /** The physical address of the hart's supervisor interrupt file its notice is written to, a page's start. */
    file : u64,
    /** The interrupt ID its notice writes there, below 2048. */
    id : u32,
}

/** One domain on an IOMMU (iommu_interface.Domain). */
Domain :: struct {
    /** The physical address of its Sv48 top-level table, a 4 KiB frame. */
    root : u64,
    /** Its domain ID, used as its PSCID. */
    id : u32,
}

/**
 * Identify a RISC-V IOMMU, changing nothing on it: DMA through it goes on as before.
 *
 * It has to be version 1 and do first-stage Sv48.
 *
 * @param iommu Where what's needed of it is kept: its registers and its device contexts'
 *     format. Written only when it's found and supported.
 * @param kind The kind the platform service says it is.
 * @param registers The virtual address L2 mapped its registers at, uncached.
 * @param size The bytes mapped there, at least REGISTER_BYTES.
 * @return What it is: its version, 47 address bits, the bytes enable takes (the device directory's root, the command
 *     queue and the fault queue, a page each), 65535 domain IDs as PSCIDs, and faults that L2 asks for; with MSI_FLAT
 *     and MSI_MRIF, REMAPPED_INTERRUPTS interrupts remapped and MSI_WINDOW to map, and otherwise none. Wired lines
 *     aren't remapped: the APLIC writes its MSIs to the interrupt files itself.
 * @error UnsupportedKind kind isn't RiscV.
 * @error NotFound Fewer than REGISTER_BYTES are mapped, or the registers don't read as a version 1 IOMMU's.
 * @error Unsupported It lacks first-stage Sv48.
 */
identify :: fn(
    iommu : ptr[mut Iommu],
    kind : iommu_interface.IommuKind,
    registers : iommu_interface.VirtualAddress,
    size : u64
) -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    if kind != .RiscV {
        return .Error(.UnsupportedKind)
    }
    if size < REGISTER_BYTES {
        return .Error(.NotFound)
    }
    base :: cast[u64](registers)
    capabilities :: intrinsics.volatile_load_u64(cast[ptr[u64]](base + CAPABILITIES))
    version :: cast[u32](capabilities & 0xff)
    if capabilities == ~cast[u64](0) || version >> 4 != 1 {
        return .Error(.NotFound)
    }
    if capabilities & CAPABILITY_SV48 == 0 {
        return .Error(.Unsupported)
    }
    iommu.registers = base
    extended :: capabilities & CAPABILITY_MSI_FLAT != 0
    iommu.context_bytes = if extended { cast[u64](64) } else { 32 }
    iommu.leaf_bits = if extended { cast[u64](6) } else { 7 }
    iommu.remaps = extended && capabilities & CAPABILITY_MSI_MRIF != 0
    for i in 0..<iommu.remapped.count {
        iommu.remapped[i] = RemappedInterrupt.{}
    }
    return .Ok(
        iommu_interface.IommuInfo.{
            address_bits = ADDRESS_BITS,
            major = version >> 4,
            minor = version & 0xf,
            memory = 3 * PAGE,
            domain_ids = 0xffff,
            interrupts = if iommu.remaps { REMAPPED_INTERRUPTS } else { 0 },
            fault_messages = false,
            wired_lines_remapped = false,
            msi_window = if iommu.remaps { MSI_WINDOW } else { 0 },
            msi_window_pages = if iommu.remaps { REMAPPED_INTERRUPTS } else { 0 },
        }
    )
}

/**
 * Turn translation on, every device's DMA faulting until it's attached.
 *
 * The device directory is turned off first, refusing every device's DMA, and the queues, which firmware or a kernel
 * before may have left on, with their errors cleared; then the queues are set, their bases read back, and turned on;
 * every cached context and translation is invalidated, while the directory is still off; and the empty device
 * directory's root set, and read back.
 *
 * @param iommu The IOMMU, identified.
 * @param memory The physical address of identify's memory bytes, zeroed and contiguous: the device directory's root,
 *     the command queue, then the fault queue, a page each. The IOMMU keeps it for good.
 * @param direct_map_offset The virtual address of physical 0 in the direct map, through which it reaches its tables
 *     and queues, and domains' tables.
 * @error Timeout ddtp stayed busy, a queue didn't turn off or on, or the first IOFENCE.C didn't complete or met an
 *     error, within SPINS spins; Unsupported a queue's base or ddtp didn't keep what was written, as a WARL field may
 *     not, like a smaller queue than asked for. The IOMMU may be left partly set up.
 */
enable :: fn(
    iommu : ptr[mut Iommu],
    memory : iommu_interface.PhysicalAddress,
    direct_map_offset : u64
) -> Result[void, iommu_interface.IommuError] {
    iommu.direct_map_offset = direct_map_offset
    iommu.directory = cast[u64](memory)
    iommu.commands = iommu.directory + PAGE
    iommu.faults = iommu.commands + PAGE
    if !set_directory(iommu, MODE_OFF) {
        return .Error(.Timeout)
    }
    if !turn_off(iommu, COMMAND_CONTROL, COMMAND_ERRORS) || !turn_off(iommu, FAULT_CONTROL, FAULT_ERRORS) {
        return .Error(.Timeout)
    }
    write_u32(iommu, FEATURES_CONTROL, 0)
    commands :: ppn(iommu.commands) | (COMMAND_LOG - 1)
    write_u64(iommu, COMMAND_QUEUE_BASE, commands)
    write_u32(iommu, COMMAND_TAIL, 0)
    iommu.command_tail = 0
    faults :: ppn(iommu.faults) | (FAULT_LOG - 1)
    write_u64(iommu, FAULT_QUEUE_BASE, faults)
    write_u32(iommu, FAULT_HEAD, 0)
    iommu.fault_head = 0
    if read_u64(iommu, COMMAND_QUEUE_BASE) != commands || read_u64(iommu, FAULT_QUEUE_BASE) != faults {
        return .Error(.Unsupported)
    }
    riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_OUTPUT)
    if !turn_on(iommu, COMMAND_CONTROL) || !turn_on(iommu, FAULT_CONTROL) {
        return .Error(.Timeout)
    }
    // What the IOMMU cached of any directory before is gone before this one is used
    submit(iommu, IODIR_INVAL_DDT)
    submit(iommu, IOTINVAL_VMA)
    if !sync(iommu) {
        return .Error(.Timeout)
    }
    directory :: ppn(iommu.directory) | MODE_TWO_LEVEL
    if !set_directory(iommu, directory) {
        return .Error(.Timeout)
    }
    if read_u64(iommu, DDTP) & ~DDTP_BUSY != directory {
        return .Error(.Unsupported)
    }
    return .Ok
}

/**
 * Do nothing: its faults go to its fault queue, which L2 reads (info.fault_messages is false), so there's nothing to
 * route.
 *
 * @param iommu The IOMMU, unused.
 * @param message The message, unused.
 */
route_faults :: fn(iommu : ptr[mut Iommu], message : iommu_interface.MsiMessage) {}

/**
 * Make an empty domain on the IOMMU. Nothing is written to the IOMMU or the table.
 *
 * @param iommu The IOMMU, unused.
 * @param domain The domain to set up.
 * @param id Its domain ID, used as its PSCID: from 1 to identify's domain_ids.
 * @param root The physical address of a zeroed 4 KiB frame for its top-level table.
 */
init_domain :: fn(iommu : ptr[Iommu], domain : ptr[mut Domain], id : u32, root : iommu_interface.PhysicalAddress) {
    domain.root = cast[u64](root)
    domain.id = id
}

/**
 * Translate a device's DMA through a domain from now on, instead of what it was before.
 *
 * Its leaf of the device directory is made where there's none; if its context was valid, it's made invalid and
 * invalidated first, with its old PSCID's translations; then it's written, tc last, and invalidated again. Where it
 * remaps MSIs, the device's MSI page table is made the first time, and kept after: its context's msiptp points at it,
 * and it's given the entries of the device's remapped interrupts that L2 gave out before.
 *
 * @param iommu The IOMMU, enabled.
 * @param domain The domain to translate through, made by init_domain; its root and PSCID go into the device's
 *     context, so it must stay alive and keep its root until the device is detached.
 * @param stream The device ID, below 2 to the leaf's bits plus 9.
 * @param frames Zeroed frames, of which one is taken for the device's leaf if it has none, and one for its MSI page
 *     table if it has none.
 * @error InvalidAddress The device ID is outside the two-level device directory.
 * @error NeedFrames Its leaf or MSI page table had to be made and frames was empty; a leaf made stays, and the device's
 *     context is as it was.
 */
attach :: fn(
    iommu : ptr[mut Iommu],
    domain : ptr[Domain],
    stream : u32,
    frames : ptr[mut iommu_interface.TableFrames]
) -> Result[void, iommu_interface.MapError] {
    if cast[u64](stream) >> (iommu.leaf_bits + 9) != 0 {
        return .Error(.InvalidAddress)
    }
    context :: device_context(iommu, stream, frames) or_return .Error(.NeedFrames)
    // Its MSI page table, once made, stays its own; a context invalid keeps its msiptp
    table := cast[u64](0)
    if iommu.remaps {
        kept :: load(iommu, context + 32)
        if kept & ~MSIPTP_PPN == MSIPTP_FLAT {
            table = (kept & MSIPTP_PPN) << 12
        }
        else {
            table = take_frame(frames) or_return .Error(.NeedFrames)
        }
    }
    if load(iommu, context) & CONTEXT_VALID != 0 {
        store(iommu, context, 0)
        invalidate_device(iommu, stream, cast[u32]((load(iommu, context + 16) >> 12) & 0xfffff))
    }
    // iohgatp Bare; ta's PSCID; fsc as iosatp, Sv48 from the domain's root; with the extended format, msiptp Off
    store(iommu, context + 8, 0)
    store(iommu, context + 16, cast[u64](domain.id & 0xfffff) << 12)
    store(iommu, context + 24, FSC_SV48 | (domain.root >> 12))
    for word in 4..<iommu.context_bytes / 8 {
        store(iommu, context + word * 8, 0)
    }
    if iommu.remaps {
        for index in 0..<iommu.remapped.count {
            if iommu.remapped[index].used && iommu.remapped[index].stream == stream {
                write_entry(iommu, table, cast[u32](index))
            }
        }
        // msiptp, msi_addr_mask and msi_addr_pattern: the window's pages are MSIs, through the table
        store(iommu, context + 32, MSIPTP_FLAT | (table >> 12))
        store(iommu, context + 40, MSI_ADDRESS_MASK)
        store(iommu, context + 48, MSI_WINDOW >> 12)
    }
    riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_READ | riscv64.FENCE_WRITE)
    store(iommu, context, CONTEXT_VALID)
    invalidate_device(iommu, stream, domain.id)
    return .Ok
}

/**
 * Fault a device's DMA again, with nothing cached of it left when this returns.
 *
 * Its context is made invalid and invalidated, with the domain's translations. A device outside the directory, or
 * with no leaf, is left alone.
 *
 * @param iommu The IOMMU, enabled.
 * @param domain The domain it was attached to, whose PSCID's translations are invalidated.
 * @param stream The device ID; one outside the directory, or whose leaf was never made, is left alone.
 */
detach :: fn(iommu : ptr[mut Iommu], domain : ptr[Domain], stream : u32) {
    if cast[u64](stream) >> (iommu.leaf_bits + 9) != 0 {
        return void
    }
    entry :: load(iommu, iommu.directory + (cast[u64](stream) >> iommu.leaf_bits) * 8)
    if entry & DIRECTORY_VALID == 0 {
        return void
    }
    store(iommu, context_in(iommu, entry, stream), 0)
    invalidate_device(iommu, stream, domain.id)
}

/**
 * Find a device's context, making its leaf of the device directory if there's none yet.
 *
 * @param iommu The IOMMU, enabled.
 * @param stream The device ID, within the directory.
 * @param frames Where a zeroed frame for a new leaf is taken from.
 * @return The context's physical address, or null if a leaf had to be made and frames had none.
 */
device_context :: fn(iommu : ptr[mut Iommu], stream : u32, frames : ptr[mut iommu_interface.TableFrames]) -> u64? {
    at :: iommu.directory + (cast[u64](stream) >> iommu.leaf_bits) * 8
    if load(iommu, at) & DIRECTORY_VALID == 0 {
        leaf :: take_frame(frames) or_return null
        riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_READ | riscv64.FENCE_WRITE)
        store(iommu, at, ppn(leaf) | DIRECTORY_VALID)
    }
    return context_in(iommu, load(iommu, at), stream)
}

/**
 * Find a device's context in its leaf.
 *
 * @param iommu The IOMMU, for its contexts' size.
 * @param entry The device's non-leaf directory entry, valid.
 * @param stream The device ID.
 * @return The context's physical address.
 */
context_in :: fn(iommu : ptr[Iommu], entry : u64, stream : u32) -> u64 {
    index :: cast[u64](stream) & ((cast[u64](1) << iommu.leaf_bits) - 1)
    return ((entry & PPN_MASK) << 2) + index * iommu.context_bytes
}

/**
 * Map one 4 KiB page in a domain, readable, and writable if asked.
 *
 * Until invalidate, the IOMMU may not see it. Nothing is changed when frames are short.
 *
 * @param iommu The IOMMU, identified and enabled (its direct_map_offset set); only read: its direct map reaches the
 *     tables.
 * @param domain The domain whose tables are walked from its root, and added to where the walk lacks a table.
 * @param address The I/O virtual address, 4 KiB aligned and below 2^47.
 * @param physical The physical address it maps, 4 KiB aligned.
 * @param writable Whether the device may write it, as well as read it.
 * @param device Unused: device memory, like the harts' interrupt files, is mapped as RAM is, with no PBMT, its PMA
 *     making it device memory.
 * @param frames Zeroed frames for the tables the walk lacks, taken from its end.
 * @error InvalidAddress address or physical isn't 4 KiB aligned, or address is 2^47 or more.
 * @error NeedFrames frames has fewer than the tables the walk lacks.
 * @error AlreadyMapped A page is mapped there already.
 */
map :: fn(
    iommu : ptr[Iommu],
    domain : ptr[mut Domain],
    address : u64,
    physical : iommu_interface.PhysicalAddress,
    writable : bool,
    device : bool,
    frames : ptr[mut iommu_interface.TableFrames]
) -> Result[void, iommu_interface.MapError] {
    if address & (PAGE - 1) != 0 || address >> cast[u64](ADDRESS_BITS) != 0 || cast[u64](physical) & (PAGE - 1) != 0 {
        return .Error(.InvalidAddress)
    }
    // The tables it needs, counted first, so nothing changes when there aren't frames enough
    missing := cast[u32](0)
    table := domain.root
    for level in 0..<LEVELS - 1 {
        entry :: load(iommu, table + index_of(address, LEVELS - level) * 8)
        if entry & VALID == 0 {
            missing = LEVELS - 1 - level
            break
        }
        table = (entry & PPN_MASK) << 2
    }
    if frames.count < missing {
        return .Error(.NeedFrames)
    }
    table = domain.root
    for level in 0..<LEVELS - 1 {
        at :: table + index_of(address, LEVELS - level) * 8
        if load(iommu, at) & VALID == 0 {
            made :: take_frame(frames) or_return .Error(.NeedFrames)
            riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_READ | riscv64.FENCE_WRITE)
            store(iommu, at, ppn(made) | VALID | USER)
        }
        table = (load(iommu, at) & PPN_MASK) << 2
    }
    leaf :: table + index_of(address, 1) * 8
    if load(iommu, leaf) & VALID != 0 {
        return .Error(.AlreadyMapped)
    }
    access :: if writable { READABLE | WRITABLE | DIRTY } else { READABLE }
    store(iommu, leaf, ppn(cast[u64](physical)) | VALID | access | USER | ACCESSED)
    return .Ok
}

/**
 * Unmap one 4 KiB page in a domain, if it's mapped. Until invalidate, the IOMMU may still reach it.
 *
 * Tables the page leaves empty stay, until release_domain.
 *
 * @param iommu The IOMMU, enabled (its direct_map_offset set); only read, for its direct map.
 * @param domain The domain whose tables are walked; its page's leaf is cleared.
 * @param address The page's I/O virtual address; its bits below 12 are ignored, and an address with no page mapped
 *     changes nothing.
 */
unmap :: fn(iommu : ptr[Iommu], domain : ptr[mut Domain], address : u64) {
    table := domain.root
    for level in 0..<LEVELS - 1 {
        entry :: load(iommu, table + index_of(address, LEVELS - level) * 8)
        if entry & VALID == 0 {
            return void
        }
        table = (entry & PPN_MASK) << 2
    }
    store(iommu, table + index_of(address, 1) * 8, 0)
}

/**
 * Make the IOMMU see a domain's tables as they are, waiting for it: its PSCID's translations invalidated, after
 * mapping as after unmapping, as an IOMMU may keep what it walked of an invalid entry.
 *
 * @param iommu The IOMMU, enabled; an IOTINVAL.VMA goes on its command queue and is waited for. If it fails or times
 *     out, the kernel stops (an assertion): the domain's old translations may still be in use, and its pages reused.
 * @param domain The domain whose tables changed; only its ID, as the PSCID whose translations go, is read.
 * @param mapped Unused: mapping and unmapping are invalidated alike.
 */
invalidate :: fn(iommu : ptr[mut Iommu], domain : ptr[Domain], mapped : bool) {
    submit(iommu, IOTINVAL_VMA | PSCID_VALID | cast[u64](domain.id & 0xfffff) << 12)
    runtime.assert(sync(iommu), "the RISC-V IOMMU didn't finish an invalidation, stopped or slow")
}

/**
 * Let go of a domain's tables, all but its root, as many as freed has room for each call.
 *
 * Nothing may be attached to it any more. What its pages mapped isn't touched.
 *
 * @param iommu The IOMMU, enabled (its direct_map_offset set); only read, for its direct map.
 * @param domain The domain, detached from every device; its tables below the root are unlinked and their frames
 *     handed out, its root kept for the caller to free.
 * @param freed Where the tables' frames go; L2 frees them once the IOMMU can no longer reach them.
 * @return True once only the root is left; false when freed is full, so L2 empties it and calls again.
 */
release_domain :: fn(
    iommu : ptr[Iommu],
    domain : ptr[mut Domain],
    freed : ptr[mut iommu_interface.FreedFrames]
) -> bool {
    loop {
        if cast[usize](freed.count) >= freed.frames.count {
            return false
        }
        if !free_one(iommu, domain.root, LEVELS, freed) {
            return true
        }
    }
}

/**
 * Let go of one table below a table, as SMMUv3's does: the first, depth first, whose entries are pages or that has
 * none left.
 *
 * @param iommu The IOMMU, its direct_map_offset set; only read, to reach the tables.
 * @param table The physical address of the table to look below.
 * @param level The table's level, 1 for a table of pages, which has no tables below it.
 * @param freed Where the table's frame goes, if there's room; the caller makes sure there is.
 * @return Whether a table was let go of; false when there's none below table.
 */
free_one :: fn(iommu : ptr[Iommu], table : u64, level : u32, freed : ptr[mut iommu_interface.FreedFrames]) -> bool {
    if level <= 1 {
        return false
    }
    for index in 0..<ENTRIES {
        at :: table + index * 8
        entry :: load(iommu, at)
        if entry & VALID == 0 {
            continue
        }
        child :: (entry & PPN_MASK) << 2
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
 * Take the next record from the fault queue.
 *
 * Where the queue had stopped taking records, full or at a memory fault, that's logged and it's started again: the
 * faults it dropped are lost, but later ones are kept.
 *
 * @param iommu The IOMMU, enabled.
 * @return The fault: its device ID, its cause as reason, the address the device used (iotval) by its page, and
 *     whether it was a write, for an untranslated or translated write (TTYP 3 or 7). Null when the queue is empty, or
 *     its tail is out of range, as a PCI IOMMU that stopped decoding reads all ones.
 */
next_fault :: fn(iommu : ptr[mut Iommu]) -> iommu_interface.DmaFault? {
    size :: cast[u32](1) << cast[u32](FAULT_LOG)
    errors :: read_u32(iommu, FAULT_CONTROL) & FAULT_ERRORS
    if errors != 0 {
        runtime.log_warn("the RISC-V IOMMU's fault queue dropped records (fqcsr errors %); taking them again", errors)
        write_u32(iommu, FAULT_CONTROL, read_u32(iommu, FAULT_CONTROL) | errors)
    }
    tail :: read_u32(iommu, FAULT_TAIL)
    if tail >= size || tail == iommu.fault_head {
        return null
    }
    riscv64.fence(riscv64.FENCE_INPUT, riscv64.FENCE_READ)
    record :: iommu.faults + cast[u64](iommu.fault_head) * FAULT_BYTES
    first :: load(iommu, record)
    value :: load(iommu, record + 16)
    // The record read before the IOMMU is told it may write the slot again
    riscv64.fence(riscv64.FENCE_READ, riscv64.FENCE_OUTPUT)
    iommu.fault_head = (iommu.fault_head + 1) & (size - 1)
    write_u32(iommu, FAULT_HEAD, iommu.fault_head)
    kind :: (first >> 34) & 0x3f
    return iommu_interface.DmaFault.{
        stream = cast[u32](first >> 40),
        address = value & ~(PAGE - 1),
        write = kind == 3 || kind == 7,
        interrupt = false,
        reason = cast[u32](first & 0xfff),
    }
}

/**
 * Make a remapped interrupt deliver an interrupt ID to a hart, raised by one device only (iommu_interface's
 * remap_interrupt): its entry in the device's MSI page table, once the device is attached, sends direct's message as
 * its notice; until then it's kept, and attach writes it. A cached entry is invalidated, so the IOMMU uses it once this
 * returns.
 *
 * @param iommu The IOMMU, enabled and remapping MSIs (info.interrupts above 0).
 * @param index The remapped interrupt, below REMAPPED_INTERRUPTS: its message's page in MSI_WINDOW, and its MRIF bit.
 * @param stream The device ID whose MSI page table has it, the only device that can raise it.
 * @param cpu_hardware_id The hart's ID; direct says its interrupt file.
 * @param vector The interrupt ID; direct says it too.
 * @param level Unused: what the IOMMU remaps is messages, edge-triggered.
 * @param direct The message that raises vector on the hart without remapping (arch_interface.route_msi's): its page
 *     the hart's supervisor interrupt file, its data the identity below 2048. The notice writes it.
 * @return The message the device writes: index, to its page of MSI_WINDOW.
 */
remap_interrupt :: fn(
    iommu : ptr[mut Iommu],
    index : u32,
    stream : u32,
    cpu_hardware_id : u64,
    vector : u32,
    level : bool,
    direct : iommu_interface.MsiMessage
) -> iommu_interface.MsiMessage {
    at :: cast[usize](index) % iommu.remapped.count
    iommu.remapped[at] = RemappedInterrupt.{
        used = true,
        stream = stream,
        file = direct.address & ~(PAGE - 1),
        id = direct.data & 0x7ff,
    }
    match msi_table(iommu, stream) {
        case Some(table) => {
            write_entry(iommu, table, cast[u32](at))
            invalidate_msi(iommu)
        }
        case None => {}
    }
    return iommu_interface.MsiMessage.{address = MSI_WINDOW + cast[u64](at) * PAGE, data = cast[u32](at)}
}

/**
 * Make a remapped interrupt raise nothing (iommu_interface's unmap_interrupt): its entry and its MRIF bit cleared,
 * the cached entry invalidated, by the time this returns.
 *
 * @param iommu The IOMMU, enabled.
 * @param index The remapped interrupt, below REMAPPED_INTERRUPTS; one not given out is left alone.
 */
unmap_interrupt :: fn(iommu : ptr[mut Iommu], index : u32) {
    at :: cast[usize](index) % iommu.remapped.count
    if !iommu.remapped[at].used {
        return void
    }
    match msi_table(iommu, iommu.remapped[at].stream) {
        case Some(table) => {
            store(iommu, table + cast[u64](at) * MSI_ENTRY_BYTES, 0)
            enable :: table + MRIF_OFFSET + cast[u64](at / 64) * 16 + 8
            store(iommu, enable, load(iommu, enable) & ~(cast[u64](1) << cast[u64](at % 64)))
            invalidate_msi(iommu)
        }
        case None => {}
    }
    iommu.remapped[at] = RemappedInterrupt.{}
}

/**
 * Find a device's MSI page table, made at its first attach, without making anything.
 *
 * @param iommu The IOMMU, enabled.
 * @param stream The device ID.
 * @return The table's physical address, a page; null if it isn't remapping, the device is outside the directory, or
 *     it was never attached.
 */
msi_table :: fn(iommu : ptr[Iommu], stream : u32) -> u64? {
    if !iommu.remaps || cast[u64](stream) >> (iommu.leaf_bits + 9) != 0 {
        return null
    }
    entry :: load(iommu, iommu.directory + (cast[u64](stream) >> iommu.leaf_bits) * 8)
    if entry & DIRECTORY_VALID == 0 {
        return null
    }
    kept :: load(iommu, context_in(iommu, entry, stream) + 32)
    if kept & ~MSIPTP_PPN != MSIPTP_FLAT {
        return null
    }
    return (kept & MSIPTP_PPN) << 12
}

/**
 * Write a remapped interrupt's entry in its device's MSI page table, MRIF mode: the device's MRIF, in the table's page,
 * with the interrupt's bit enabled, and the notice to the interrupt's hart; the notice first, then the entry's first
 * doubleword with V, so a valid entry is never half written. The caller invalidates.
 *
 * @param iommu The IOMMU, remapping; remapped[index] is used.
 * @param table The device's MSI page table's physical address.
 * @param index The remapped interrupt, below REMAPPED_INTERRUPTS.
 */
write_entry :: fn(iommu : ptr[mut Iommu], table : u64, index : u32) {
    remapped :: &iommu.remapped[cast[usize](index) % iommu.remapped.count]
    mrif :: table + MRIF_OFFSET
    // The MRIF's 64 identities in a pair of doublewords, the pending bits then the enable bits
    enable :: mrif + cast[u64](index / 64) * 16 + 8
    store(iommu, enable, load(iommu, enable) | cast[u64](1) << cast[u64](index % 64))
    entry :: table + cast[u64](index) * MSI_ENTRY_BYTES
    // NID's low 10 bits in 9:0 and its 11th in bit 60; NPPN, the file's page, in 53:10
    id :: cast[u64](remapped.id)
    store(iommu, entry + 8, (id & 0x3ff) | (remapped.file >> 12) << 10 | ((id >> 10) & 1) << 60)
    riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_READ | riscv64.FENCE_WRITE)
    // The MRIF's address, 512-byte aligned, in bits 53:7
    store(iommu, entry, MSI_ENTRY_VALID | MSI_ENTRY_MRIF | (mrif >> 9) << 7)
}

/**
 * Invalidate every cached MSI page table entry, and wait for it: IOTINVAL.GVMA, as entries are cached with second-stage
 * translations. One that fails or times out stops the kernel (an assertion), as the old entry may still be in use.
 *
 * @param iommu The IOMMU, its command queue on.
 */
invalidate_msi :: fn(iommu : ptr[mut Iommu]) {
    riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_OUTPUT)
    submit(iommu, IOTINVAL_GVMA)
    runtime.assert(sync(iommu), "the RISC-V IOMMU didn't finish an invalidation, stopped or slow")
}

/**
 * Find which entry of a table an address is in.
 *
 * @param address The I/O virtual address.
 * @param level The table's level, 1 for the tables of pages, up to 4 for the top-level table.
 * @return The entry's index, 0 to 511.
 */
index_of :: fn(address : u64, level : u32) -> u64 {
    return (address >> (12 + 9 * cast[u64](level - 1))) & (ENTRIES - 1)
}

/**
 * Give a physical address's PPN where an entry or a register has it, in bits 53:10.
 *
 * @param physical The physical address, 4 KiB aligned.
 * @return physical >> 12, shifted to bit 10.
 */
ppn :: fn(physical : u64) -> u64 {
    return (physical >> 12) << 10
}

/**
 * Take a zeroed frame from the end of the frames L2 gave.
 *
 * @param frames The frames; its count drops by one when one is taken.
 * @return The frame's physical address, or null when there's none, or count is out of range.
 */
take_frame :: fn(frames : ptr[mut iommu_interface.TableFrames]) -> u64? {
    if frames.count == 0 || cast[usize](frames.count) > frames.frames.count {
        return null
    }
    frames.count -= 1
    return cast[u64](frames.frames[cast[usize](frames.count)])
}

/**
 * Invalidate a device's cached context and a PSCID's translations, and wait for it.
 *
 * A fence that fails or times out stops the kernel (an assertion), as the old context may still be in use.
 *
 * @param iommu The IOMMU, its command queue on.
 * @param stream The device ID whose cached context goes.
 * @param pscid The PSCID whose translations go; only the low 20 bits are used.
 */
invalidate_device :: fn(iommu : ptr[mut Iommu], stream : u32, pscid : u32) {
    submit(iommu, IODIR_INVAL_DDT | DEVICE_VALID | cast[u64](stream & 0xffffff) << 40)
    submit(iommu, IOTINVAL_VMA | PSCID_VALID | cast[u64](pscid & 0xfffff) << 12)
    runtime.assert(sync(iommu), "the RISC-V IOMMU didn't finish an invalidation, stopped or slow")
}

/**
 * Put a command on the command queue, its second word 0, and tell the IOMMU.
 *
 * It waits while the queue is full, for as long as the IOMMU is reading it: a command written over one it hasn't read
 * would be lost, and a lost invalidation leaves stale translations in use. If the queue has stopped at an error, or
 * stays full for SPINS spins with none, it's not being read on, so the kernel stops (an assertion) rather than wait
 * for good, holding the IOMMU's lock, or overwrite a command.
 *
 * @param iommu The IOMMU, its command queue on; its command_tail moves past the command.
 * @param first The command's first word: its opcode, func3 and fields.
 */
submit :: fn(iommu : ptr[mut Iommu], first : u64) {
    size :: cast[u32](1) << cast[u32](COMMAND_LOG)
    spins := cast[u64](0)
    loop {
        // Full: the tail one short of the head
        if (iommu.command_tail + 1) & (size - 1) != read_u32(iommu, COMMAND_HEAD) & (size - 1) {
            break
        }
        runtime.assert(
            read_u32(iommu, COMMAND_CONTROL) & COMMAND_ERRORS == 0,
            "the RISC-V IOMMU's command queue stopped at an error"
        )
        spins += 1
        runtime.assert(spins < SPINS, "the RISC-V IOMMU's command queue stayed full")
        intrinsics.spin_hint()
    }
    at :: iommu.commands + cast[u64](iommu.command_tail) * COMMAND_BYTES
    store(iommu, at, first)
    store(iommu, at + 8, 0)
    riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_OUTPUT)
    iommu.command_tail = (iommu.command_tail + 1) & (size - 1)
    write_u32(iommu, COMMAND_TAIL, iommu.command_tail)
}

/**
 * Wait for every command submitted to complete: an IOFENCE.C, then the head at the tail.
 *
 * @param iommu The IOMMU, its command queue on.
 * @return True once they have; false if the queue stopped at an error, or SPINS spins passed first.
 */
sync :: fn(iommu : ptr[mut Iommu]) -> bool {
    submit(iommu, IOFENCE_C)
    size :: cast[u32](1) << cast[u32](COMMAND_LOG)
    for spin in 0..<SPINS {
        if read_u32(iommu, COMMAND_CONTROL) & COMMAND_ERRORS != 0 {
            return false
        }
        if read_u32(iommu, COMMAND_HEAD) & (size - 1) == iommu.command_tail {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

/**
 * Turn a queue on, and wait for it to say it is.
 *
 * @param iommu The IOMMU, identified, the queue's base and tail or head written.
 * @param control The queue's control register: COMMAND_CONTROL or FAULT_CONTROL.
 * @return True once it's on and not busy; false if SPINS spins passed first.
 */
turn_on :: fn(iommu : ptr[mut Iommu], control : u64) -> bool {
    write_u32(iommu, control, QUEUE_ENABLE)
    for spin in 0..<SPINS {
        state :: read_u32(iommu, control)
        if state & QUEUE_ON != 0 && state & QUEUE_BUSY == 0 {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

/**
 * Turn a queue off, clearing its errors, and wait for it to say it is: its base can be set only while it's off.
 *
 * @param iommu The IOMMU, identified; only its registers are used.
 * @param control The queue's control register: COMMAND_CONTROL or FAULT_CONTROL.
 * @param errors The control register's error bits, which writing 1 clears: COMMAND_ERRORS or FAULT_ERRORS.
 * @return True once it's neither on nor busy; false if SPINS spins passed first.
 */
turn_off :: fn(iommu : ptr[mut Iommu], control : u64, errors : u32) -> bool {
    write_u32(iommu, control, errors)
    for spin in 0..<SPINS {
        if read_u32(iommu, control) & (QUEUE_ON | QUEUE_BUSY) == 0 {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

/**
 * Set ddtp, and wait for it to take effect.
 *
 * @param iommu The IOMMU, identified; only its registers are used.
 * @param value ddtp's new value: a mode, and with a level mode the root's PPN.
 * @return True once it's no longer busy; false if SPINS spins passed first, before or after the write.
 */
set_directory :: fn(iommu : ptr[mut Iommu], value : u64) -> bool {
    if !directory_idle(iommu) {
        return false
    }
    write_u64(iommu, DDTP, value)
    return directory_idle(iommu)
}

/**
 * Wait for ddtp's busy to clear.
 *
 * @param iommu The IOMMU, identified.
 * @return True once it's clear; false if SPINS spins passed first.
 */
directory_idle :: fn(iommu : ptr[Iommu]) -> bool {
    for spin in 0..<SPINS {
        if intrinsics.volatile_load_u64(cast[ptr[u64]](iommu.registers + DDTP)) & DDTP_BUSY == 0 {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

/**
 * Read a table entry, a device context's or a queue entry's word through the direct map.
 *
 * @param iommu The IOMMU, whose direct_map_offset is set.
 * @param at The word's physical address, 8-byte aligned.
 * @return The word's 64 bits as memory holds them now, read with a volatile load.
 */
load :: fn(iommu : ptr[Iommu], at : u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](at + iommu.direct_map_offset))
}

/**
 * Write a table entry, a device context's or a command's word through the direct map. The IOMMU is told of it only
 * after a fence.
 *
 * @param iommu The IOMMU, whose direct_map_offset is set.
 * @param at The word's physical address, 8-byte aligned.
 * @param value The 64 bits to write, in full.
 */
store :: fn(iommu : ptr[Iommu], at : u64, value : u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + iommu.direct_map_offset), value)
}

/**
 * Read a 32-bit register.
 *
 * @param iommu The IOMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 4-byte aligned and below REGISTER_BYTES.
 * @return The register's 32 bits, read with a volatile load; all ones if nothing answers there.
 */
read_u32 :: fn(iommu : ptr[Iommu], offset : u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](iommu.registers + offset))
}

/**
 * Read a 64-bit register.
 *
 * @param iommu The IOMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 8-byte aligned and below REGISTER_BYTES.
 * @return The register's 64 bits, read with one volatile load; all ones if nothing answers there.
 */
read_u64 :: fn(iommu : ptr[Iommu], offset : u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](iommu.registers + offset))
}

/**
 * Write a 32-bit register.
 *
 * @param iommu The IOMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 4-byte aligned and below REGISTER_BYTES.
 * @param value The register's new 32 bits, written whole with a volatile store.
 */
write_u32 :: fn(iommu : ptr[Iommu], offset : u64, value : u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](iommu.registers + offset), value)
}

/**
 * Write a 64-bit register.
 *
 * @param iommu The IOMMU, whose registers are mapped, as identify records them.
 * @param offset The register's byte offset from the register base, 8-byte aligned.
 * @param value The register's new 64 bits, written whole with one volatile store.
 */
write_u64 :: fn(iommu : ptr[Iommu], offset : u64, value : u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](iommu.registers + offset), value)
}
