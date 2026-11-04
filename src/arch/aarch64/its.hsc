package arch_aarch64

import intrinsics from "base"
import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import concurrency from "std"

/*
 * Message-signaled interrupts through the GICv3's ITS (arch_interface, MSIs; decisions/0073). A device writes its
 * event's number to the ITS's GITS_TRANSLATER, and the ITS, through the device's interrupt translation table,
 * turns it into an LPI on the collection, a CPU's redistributor, it was mapped to.
 *
 * The kernel's device interrupt IDs stay its own, as with SPIs: each event routed is given a free LPI, and routes
 * (gic.hsc) translates the LPI back to the ID on its CPU. LPIs are configured in one property table, a byte each,
 * and each redistributor has its own pending table. Each CPU's redistributor is a collection, numbered as it's found.
 * The ITS is told what to do through its command queue, one command at a time under its_lock, each waited for.
 */
//SPEC: Arm GICv3 and GICv4 Architecture Specification (IHI 0069): §5 (LPIs and the ITS), §5.3 (ITS commands), §12.19 (GITS_*), §12.11 (GICR_PROPBASER, GICR_PENDBASER)

// ITS registers: the control frame, then the translation frame 64 KiB on
/** GITS_CTLR's offset: the ITS's control register, Enabled in bit 0 and Quiescent in bit 31. */
GITS_CTLR : u64 : 0x0000
/** GITS_TYPER's offset: what the ITS implements, as init_msi reads it. */
GITS_TYPER : u64 : 0x0008
/** GITS_CBASER's offset: the command queue's address, size and attributes. */
GITS_CBASER : u64 : 0x0080
/** GITS_CWRITER's offset: where software has written commands up to, in bytes from the queue's start. */
GITS_CWRITER : u64 : 0x0088
/** GITS_CREADR's offset: where the ITS has read commands up to, in bytes from the queue's start. */
GITS_CREADR : u64 : 0x0090
/** The first GITS_BASER's offset: eight 8-byte registers describing the ITS's tables, each's type in bits 56 to 58. */
GITS_BASER : u64 : 0x0100
/** GITS_TRANSLATER's offset, in the translation frame: the register devices write their event numbers to. */
GITS_TRANSLATER : u64 : 0x10040
/** The ITS's registers' size in bytes: the control frame and the translation frame, 64 KiB each. */
ITS_SIZE : u64 : 0x20000
/** GITS_CTLR.Enabled (bit 0): the ITS translates. */
CTLR_ENABLED : u32 : 1
/** GITS_CTLR.Quiescent (bit 31): the ITS has finished everything, once disabled. */
CTLR_QUIESCENT : u32 : 1 << 31

// Redistributor registers for LPIs, in its RD frame
/** GICR_CTLR's offset in a redistributor's RD frame. */
GICR_CTLR : u64 : 0x0000
/** GICR_PROPBASER's offset: where the LPI property table is, and how many interrupt ID bits it covers. */
GICR_PROPBASER : u64 : 0x0070
/** GICR_PENDBASER's offset: where the redistributor's LPI pending table is. */
GICR_PENDBASER : u64 : 0x0078
/** GICR_CTLR.EnableLPIs (bit 0). */
GICR_CTLR_ENABLE_LPIS : u32 : 1
/** GICR_TYPER.PLPIS (bit 0): the redistributor supports physical LPIs. */
TYPER_PHYSICAL_LPIS : u64 : 1

// Tables' memory: normal, inner write-back read- and write-allocate, inner shareable
/** The InnerCache field's value for the ITS's tables: normal memory, inner write-back, read- and write-allocate. */
TABLE_INNER_CACHE : u64 : 7
/** The Shareability field's value for the ITS's tables: inner shareable. */
TABLE_SHAREABLE : u64 : 1
/** GITS_BASER.Valid and GITS_CBASER.Valid (bit 63), and a MAPD or MAPC command's V bit. */
BASER_VALID : u64 : 1 << 63
/** GITS_BASER.Type 1: the table is the device table. */
BASER_TYPE_DEVICES : u64 : 1
/** GITS_BASER.Type 4: the table is the collection table. */
BASER_TYPE_COLLECTIONS : u64 : 4
/** GICR_PENDBASER.PTZ (bit 62): the pending table is zeroed, so the redistributor needn't read it. */
PENDING_ZEROED : u64 : 1 << 62

// LPIs from 8192, with 14 bits of interrupt ID: 8192 of them
/** The first LPI's interrupt ID. */
FIRST_LPI : u32 : 8192
/** The interrupt ID bits the property table covers: 14, so IDs up to 16383. */
LPI_ID_BITS : u64 : 14
/** How many LPIs there are, FIRST_LPI to 16383, each a byte of the property table. */
LPI_COUNT :: 8192
/** In an LPI's byte of the property table, whose upper six bits are its priority: Enable (bit 0). */
LPI_ENABLED : u8 : 1

// The memory init_msi is given, in this order, each part aligned to 64 KiB as the pending tables must be
/** The command queue's size in bytes: 64 KiB, 2048 commands. */
COMMAND_QUEUE_SIZE : u64 : 0x10000
/** The property table's size in bytes: 64 KiB, more than LPI_COUNT's bytes. */
PROPERTY_TABLE_SIZE : u64 : 0x10000
/** The collection table's size in bytes: 64 KiB. */
COLLECTION_TABLE_SIZE : u64 : 0x10000
/** Each redistributor's pending table's size in bytes: 64 KiB, a bit for each of 2^14 interrupt IDs and more. */
PENDING_TABLE_SIZE : u64 : 0x10000
// Device IDs up to 16 bits: a flat device table of up to 2^16 entries
/** The most device ID bits used, whatever the ITS supports, so the flat device table has at most 2^16 entries. */
MAX_DEVICE_BITS : u64 : 16
/** One ITS command's size in bytes: four doublewords. */
COMMAND_SIZE : u64 : 32

// ITS commands
/** MOVI: move an event's LPI to another collection. */
COMMAND_MOVI : u64 : 0x01
/** SYNC: wait until a redistributor has taken every earlier command's effects. */
COMMAND_SYNC : u64 : 0x05
/** MAPD: map a device ID to its interrupt translation table, or unmap it. */
COMMAND_MAPD : u64 : 0x08
/** MAPC: map a collection to a redistributor. */
COMMAND_MAPC : u64 : 0x09
/** MAPTI: map a device's event to an LPI on a collection. */
COMMAND_MAPTI : u64 : 0x0a
/** INV: make the redistributor reread an event's LPI's property byte. */
COMMAND_INV : u64 : 0x0c
/** DISCARD: drop an event's mapping, and any pending interrupt for it. */
COMMAND_DISCARD : u64 : 0x0f

/** The most collections, so redistributors, the ITS is told of; redistributors past this many get no LPIs. */
MAX_COLLECTIONS :: 128
/** The most events routed at once, across every device. */
MAX_MSI_ROUTES :: 256
/** How many polls run_command waits for the ITS to read a command, at most, before it logs an error and goes on. */
COMMAND_POLLS : u64 : 10000000

/** A CPU's redistributor as a collection: whose affinity it has, and how the ITS names it (MAPC's RDbase). */
Collection :: struct {
    /**
     * The redistributor's affinity, as GICR_TYPER's bits 32 to 63 give it: Aff3 in bits 24 to 31, Aff2 to Aff0 below.
     */
    affinity : u64,
    /**
     * MAPC's RDbase, already in place in the command's third doubleword: the redistributor's physical address when
     * GITS_TYPER.PTA is set, or else its processor number shifted left 16.
     */
    target : u64,
}

/** An event routed: which LPI it raises. */
MsiRoute :: struct {
    /** Whether this slot holds a route; the other fields mean nothing when it doesn't. */
    used : bool,
    /** The device, as the ITS knows it: its device ID. */
    source : u32,
    /** The event's number, which the device writes to GITS_TRANSLATER. */
    event : u32,
    /** The LPI's interrupt ID, from FIRST_LPI. */
    lpi : u32,
}

/** What the ITS needs, in ArchSystem; every field is 0 or empty without an ITS. */
ItsState :: struct {
    /** The ITS's registers, a virtual address through the direct map; 0 without an ITS. */
    registers : u64,
    /** The ITS's registers' physical address; 0 without an ITS. */
    physical : u64,
    /** Whether init_msi has set the ITS up, with at least one collection, so MSIs can be had. */
    ready : bool,
    /** The lock every command and the routes and LPIs are taken under: its_lock, as other comments call it. */
    lock : concurrency.SpinLock,
    /** From GITS_TYPER.ITT_entry_size: the bytes an event takes in a device's interrupt translation table. */
    itt_entry_size : u64,
    /** From GITS_TYPER.Devbits: how many bits of device ID the ITS takes, at most MAX_DEVICE_BITS. */
    device_bits : u64,
    /**
     * From GITS_TYPER.PTA: whether MAPC names a redistributor by its physical address, or else by its processor number.
     */
    targets_by_address : bool,
    /** The command queue, a virtual address through the direct map. */
    commands : u64,
    /** Where the next command goes, in bytes from the queue's start, a multiple of COMMAND_SIZE. */
    command_offset : u64,
    /** The LPI property table, a virtual address through the direct map, a byte an LPI from FIRST_LPI. */
    properties : u64,
    /** Each redistributor's collection, by collection number; the first collection_count are used. */
    collections : Collection[MAX_COLLECTIONS],
    /** How many of collections are used. */
    collection_count : u32,
    /** Which LPIs are taken, a bit each, from FIRST_LPI. */
    lpis_used : u64[LPI_COUNT / 64],
    /** The events routed, each with its LPI. */
    routes : MsiRoute[MAX_MSI_ROUTES],
}

/**
 * Map the ITS's registers through the direct map and record where they are, from the device tree's node for it.
 *
 * Nothing is recorded if physical is 0 or the registers couldn't be mapped, so there's no ITS.
 *
 * @param system The shared state, whose its.physical and its.registers are set.
 * @param physical The ITS's registers' physical address, ITS_SIZE bytes of them.
 */
map_its :: fn(system: ptr[mut ArchSystem], physical: u64) {
    if physical == 0 || !map_device_range(system, physical, ITS_SIZE) {
        return void
    }
    system.its.physical = physical
    system.its.registers = system.direct_map_offset + physical
}

/**
 * Compute the bytes of memory the ITS's device table needs, which init_msi's memory has after its first three parts.
 *
 * @param system The shared state, whose ITS's registers are mapped.
 * @return The device table's entry size times 2 to the device ID bits (at most MAX_DEVICE_BITS), rounded up to
 *     64 KiB; 0 if no GITS_BASER describes a device table.
 */
device_table_size :: fn(system: ptr[ArchSystem]) -> u64 {
    base :: system.its.registers
    for n in 0..<8 {
        baser :: read_u64(base, GITS_BASER + cast[u64](n) * 8)
        if (baser >> 56) & 7 == BASER_TYPE_DEVICES {
            entry_size :: ((baser >> 48) & 0x1f) + 1
            return round_up_64k(entry_size << device_bits_of(read_u64(base, GITS_TYPER)))
        }
    }
    return 0
}

/**
 * Read how many device ID bits to use from GITS_TYPER.Devbits.
 *
 * @param typer GITS_TYPER's value.
 * @return Devbits + 1, capped at MAX_DEVICE_BITS: 1 to 16.
 */
device_bits_of :: fn(typer: u64) -> u64 {
    bits :: ((typer >> 13) & 0x1f) + 1
    return if bits > MAX_DEVICE_BITS { MAX_DEVICE_BITS } else { bits }
}

/**
 * Round a size up to a multiple of 64 KiB.
 *
 * @param value The size in bytes, below 2^64 - 0xffff.
 * @return The smallest multiple of 0x10000 at least value.
 */
round_up_64k :: fn(value: u64) -> u64 {
    return (value + 0xffff) & ~cast[u64](0xffff)
}

/**
 * Count the redistributors in the region, each a CPU's, walking its frames until GICR_TYPER.Last or the region's end.
 *
 * @param system The shared state, whose redistributor region is mapped (non-zero).
 * @return How many redistributors there are, at least 1.
 */
redistributor_count :: fn(system: ptr[ArchSystem]) -> u64 {
    count : u64 = 0
    with {
        frame := system.redistributors
    }
    loop {
        typer :: read_u64(frame, GICR_TYPER)
        count += 1
        if typer & TYPER_LAST != 0 {
            break
        }
        frame += if typer & TYPER_VIRTUAL_LPIS != 0 { 2 * REDISTRIBUTOR_STRIDE } else { REDISTRIBUTOR_STRIDE }
    }
    while frame != 0 && frame + REDISTRIBUTOR_STRIDE <= system.redistributors + system.redistributors_size
    return count
}

/**
 * Give the bytes of memory the ITS needs for MSIs at all (arch_interface.msi_controller_memory), asked once every
 * CPU has started.
 *
 * @return The command queue, the property table, the collection table, the device table and a pending table for
 *     each redistributor, in that order, each a multiple of 64 KiB; 0 without an ITS, a redistributor region, or a
 *     device table.
 */
msi_controller_memory :: fn() -> u64 {
    system :: current_system()
    if system.its.registers == 0 || system.redistributors == 0 {
        return 0
    }
    tables :: device_table_size(system)
    if tables == 0 {
        return 0
    }
    return COMMAND_QUEUE_SIZE + PROPERTY_TABLE_SIZE + COLLECTION_TABLE_SIZE + tables + redistributor_count(system) * PENDING_TABLE_SIZE
}

/**
 * Set the ITS up (arch_interface.init_msi): its tables and command queue, every redistributor's LPIs on, and each
 * one a collection, mapped with MAPC.
 *
 * Called once every CPU has started, so every redistributor is awake. Waits, without a timeout, for the ITS to be
 * quiescent once disabled. MSIs can be had afterwards (its.ready) if at least one redistributor takes LPIs; nothing
 * happens without an ITS.
 *
 * @param memory msi_controller_memory's bytes, zeroed and contiguous, physical, aligned to at least 64 KiB; the
 *     ITS and the redistributors own it from here on.
 */
init_msi :: fn(memory: arch_interface.PhysicalAddress) {
    system :: current_system()
    its :: &system.its
    base :: its.registers
    if base == 0 {
        return void
    }
    write_u32(base, GITS_CTLR, 0)
    loop {
        intrinsics.spin_hint()
    }
    while read_u32(base, GITS_CTLR) & CTLR_QUIESCENT == 0
    typer :: read_u64(base, GITS_TYPER)
    its.itt_entry_size = ((typer >> 4) & 0xf) + 1
    its.device_bits = device_bits_of(typer)
    its.targets_by_address = typer & (1 << 19) != 0

    physical :: cast[u64](memory)
    commands :: physical
    properties :: commands + COMMAND_QUEUE_SIZE
    collection_table :: properties + PROPERTY_TABLE_SIZE
    device_table :: collection_table + COLLECTION_TABLE_SIZE
    pending :: device_table + device_table_size(system)
    its.commands = system.direct_map_offset + commands
    its.properties = system.direct_map_offset + properties
    its.command_offset = 0

    // The device and collection tables, flat, in 4 KiB pages
    for n in 0..<8 {
        offset :: GITS_BASER + cast[u64](n) * 8
        baser :: read_u64(base, offset)
        kind :: (baser >> 56) & 7
        entry_size :: ((baser >> 48) & 0x1f) + 1
        table := cast[u64](0)
        size := cast[u64](0)
        if kind == BASER_TYPE_DEVICES {
            table = device_table
            size = device_table_size(system)
        }
        else if kind == BASER_TYPE_COLLECTIONS {
            table = collection_table
            size = COLLECTION_TABLE_SIZE
        }
        if table != 0 {
            pages :: size / 4096
            write_u64(base, offset, BASER_VALID | TABLE_INNER_CACHE << 59 | kind << 56 | (entry_size - 1) << 48 | table
                | TABLE_SHAREABLE << 10 | (pages - 1))
        }
    }
    write_u64(base, GITS_CBASER, BASER_VALID | TABLE_INNER_CACHE << 59 | commands | TABLE_SHAREABLE << 10 | (COMMAND_QUEUE_SIZE / 4096 - 1))
    write_u64(base, GITS_CWRITER, 0)
    write_u32(base, GITS_CTLR, CTLR_ENABLED)

    // Every redistributor's LPIs, through the one property table and its own pending table; then its collection
    count := cast[u32](0)
    with {
        frame := system.redistributors
    }
    loop {
        typer :: read_u64(frame, GICR_TYPER)
        if typer & TYPER_PHYSICAL_LPIS != 0 && cast[usize](count) < MAX_COLLECTIONS {
            write_u64(frame, GICR_PROPBASER, properties | TABLE_SHAREABLE << 10 | TABLE_INNER_CACHE << 7 | (LPI_ID_BITS - 1))
            write_u64(frame, GICR_PENDBASER, PENDING_ZEROED | (pending + cast[u64](count) * PENDING_TABLE_SIZE) | TABLE_SHAREABLE << 10
                | TABLE_INNER_CACHE << 7)
            write_u32(frame, GICR_CTLR, read_u32(frame, GICR_CTLR) | GICR_CTLR_ENABLE_LPIS)
            target :: if its.targets_by_address { frame - system.direct_map_offset } else { ((typer >> 8) & 0xffff) << 16 }
            its.collections[count] = Collection.{affinity = typer >> 32, target = target}
            count += 1
        }
        if typer & TYPER_LAST != 0 {
            break
        }
        frame += if typer & TYPER_VIRTUAL_LPIS != 0 { 2 * REDISTRIBUTOR_STRIDE } else { REDISTRIBUTOR_STRIDE }
    }
    while frame + REDISTRIBUTOR_STRIDE <= system.redistributors + system.redistributors_size
    its.collection_count = count
    concurrency.lock(&its.lock)
    for index in 0..<count {
        if cast[usize](index) < MAX_COLLECTIONS {
            collection :: its.collections[index]
            run_command(its, COMMAND_MAPC, 0, BASER_VALID | collection.target | cast[u64](index))
            run_command(its, COMMAND_SYNC, 0, collection.target)
        }
    }
    concurrency.unlock(&its.lock)
    its.ready = count > 0
    runtime.log_info("GIC ITS: MSIs on, % collections, % device ID bits", count, its.device_bits)
}

/**
 * Give the page devices write their MSIs to (arch_interface.msi_doorbell), which an IOMMU translating their DMA
 * must map for the MSIs to arrive.
 *
 * @return The physical address of the 4 KiB page holding GITS_TRANSLATER, which a device's MSI is a write to; null
 *     until init_msi has set an ITS up.
 */
msi_doorbell :: fn() -> arch_interface.PhysicalAddress? {
    its :: &current_system().its
    if !its.ready {
        return null
    }
    return cast[arch_interface.PhysicalAddress]((its.physical + GITS_TRANSLATER) & ~cast[u64](0xfff))
}

/**
 * Give the bytes of memory a device's interrupt translation table takes (arch_interface.msi_device_memory).
 *
 * @return GITS_TYPER's ITT entry size times 32, room for 32 events; null until init_msi has set an ITS up.
 */
msi_device_memory :: fn() -> u64? {
    its :: &current_system().its
    if !its.ready {
        return null
    }
    return its.itt_entry_size * 32
}

/**
 * Map a device to its interrupt translation table, with MAPD, under its_lock (arch_interface.add_msi_device).
 *
 * Nothing happens without an ITS set up, or for a source wider than the ITS's device ID bits.
 *
 * @param source The device's ITS device ID, below 2 to its.device_bits.
 * @param memory The interrupt translation table: msi_device_memory's bytes, zeroed and contiguous, physical,
 *     256-byte aligned as the ITS needs; the ITS owns it until remove_msi_device.
 * @param events How many events the device may raise, numbered from 0; the table is given room for at least 4,
 *     the next power of two at least events, though msi_device_memory's bytes hold only 32.
 */
add_msi_device :: fn(source: u32, memory: arch_interface.PhysicalAddress, events: u32) {
    its :: &current_system().its
    if !its.ready || cast[u64](source) >> its.device_bits != 0 {
        return void
    }
    bits := cast[u64](1)
    loop {
        bits += 1
    }
    while cast[u64](1) << bits < cast[u64](events)
    concurrency.lock(&its.lock)
    run_command(its, COMMAND_MAPD | cast[u64](source) << 32, bits - 1, BASER_VALID | cast[u64](memory))
    concurrency.unlock(&its.lock)
}

/**
 * Unmap a device with MAPD, under its_lock, which drops every event of its; their LPIs are disabled, their routes
 * forgotten, and they're free again (arch_interface.remove_msi_device).
 *
 * @param source The device's ITS device ID, as add_msi_device had it. Nothing happens without an ITS set up.
 */
remove_msi_device :: fn(source: u32) {
    system :: current_system()
    its :: &system.its
    if !its.ready {
        return void
    }
    concurrency.lock(&its.lock)
    run_command(its, COMMAND_MAPD | cast[u64](source) << 32, 0, 0)
    for &route in its.routes {
        if route.used && route.source == source {
            free_lpi(system, route.lpi)
            route.used = false
        }
    }
    concurrency.unlock(&its.lock)
}

/**
 * Give a device's event an LPI of its own, enabled, on the collection of the CPU with this hardware ID, and route the
 * LPI to id there (arch_interface.route_msi), with MAPTI, INV and SYNC, under its_lock.
 *
 * Without an ITS set up, or with no LPI or route slot free (logged as an error), nothing is routed, but the message
 * is still returned. A CPU with no collection gets collection 0's.
 *
 * @param source The device's ITS device ID, added with add_msi_device.
 * @param event The event's number, below the events add_msi_device was given.
 * @param cpu_hardware_id The CPU's MPIDR; only its affinity fields are used.
 * @param id The kernel's device interrupt ID on that CPU, from device_interrupt_range.
 * @return The message the device sends to raise it: event as the data, written to GITS_TRANSLATER's physical address.
 */
route_msi :: fn(source: u32, event: u32, cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    system :: current_system()
    its :: &system.its
    message :: arch_interface.MsiMessage.{address = its.physical + GITS_TRANSLATER, data = event}
    if !its.ready {
        return message
    }
    affinity :: ((cpu_hardware_id >> 32) & 0xff) << 24 | (cpu_hardware_id & 0xffffff)
    collection := cast[u64](0)
    for found, index in its.collections {
        if cast[u32](index) < its.collection_count && found.affinity == affinity {
            collection = cast[u64](index)
        }
    }
    concurrency.lock(&its.lock)
    defer concurrency.unlock(&its.lock)
    lpi := FIRST_LPI
    match take_lpi(its) {
        case Some(taken) => lpi = taken
        case None => {
            runtime.log_error("GIC ITS: no LPI is free for an MSI")
            return message
        }
    }
    slot : usize = MAX_MSI_ROUTES
    for route, index in its.routes {
        if !route.used {
            slot = index
            break
        }
    }
    if slot == MAX_MSI_ROUTES {
        runtime.log_error("GIC ITS: every MSI route is taken")
        give_lpi(its, lpi)
        return message
    }
    its.routes[slot] = MsiRoute.{used = true, source = source, event = event, lpi = lpi}
    record_route(system, cpu_hardware_id & 0xff00ffffff, cast[u32](id), lpi)
    properties :: view_of(cast[ptr[mut u8]](its.properties), LPI_COUNT)
    index :: cast[usize](lpi - FIRST_LPI)
    if index < properties.count {
        properties[index] = (INTERRUPT_PRIORITY & 0xfc) | LPI_ENABLED
    }
    // The property table written before the ITS reads it
    aarch64.dsb(.ISH)
    run_command(its, COMMAND_MAPTI | cast[u64](source) << 32, cast[u64](event) | cast[u64](lpi) << 32, collection)
    run_command(its, COMMAND_INV | cast[u64](source) << 32, cast[u64](event), 0)
    if cast[usize](collection) < MAX_COLLECTIONS {
        run_command(its, COMMAND_SYNC, 0, its.collections[collection].target)
    }
    return message
}

/**
 * Move a routed event's LPI to the collection of the CPU with this hardware ID, with MOVI and SYNC, and route it
 * to id there (arch_interface.move_msi), under its_lock.
 *
 * Nothing moves without an ITS set up, or if the event isn't routed. A CPU with no collection gets collection 0's.
 *
 * @param source The device's ITS device ID.
 * @param event The event's number, routed by route_msi.
 * @param cpu_hardware_id The new CPU's MPIDR; only its affinity fields are used.
 * @param id The kernel's device interrupt ID on that CPU.
 * @return The message the device sends to raise it, the same as route_msi gave, so the device needn't change.
 */
move_msi :: fn(source: u32, event: u32, cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    system :: current_system()
    its :: &system.its
    message :: arch_interface.MsiMessage.{address = its.physical + GITS_TRANSLATER, data = event}
    if !its.ready {
        return message
    }
    affinity :: ((cpu_hardware_id >> 32) & 0xff) << 24 | (cpu_hardware_id & 0xffffff)
    collection := cast[u64](0)
    for found, index in its.collections {
        if cast[u32](index) < its.collection_count && found.affinity == affinity {
            collection = cast[u64](index)
        }
    }
    concurrency.lock(&its.lock)
    defer concurrency.unlock(&its.lock)
    for route in its.routes {
        if route.used && route.source == source && route.event == event {
            record_route(system, cpu_hardware_id & 0xff00ffffff, cast[u32](id), route.lpi)
            run_command(its, COMMAND_MOVI | cast[u64](source) << 32, cast[u64](event), collection)
            if cast[usize](collection) < MAX_COLLECTIONS {
                run_command(its, COMMAND_SYNC, 0, its.collections[collection].target)
            }
        }
    }
    return message
}

/**
 * Stop delivering a device's event (arch_interface.unroute_msi): DISCARD drops its mapping, and its LPI is
 * disabled, its route forgotten, and it's free again, under its_lock.
 *
 * @param source The device's ITS device ID.
 * @param event The event's number. Nothing happens without an ITS set up, or if the event isn't routed.
 */
unroute_msi :: fn(source: u32, event: u32) {
    system :: current_system()
    its :: &system.its
    if !its.ready {
        return void
    }
    concurrency.lock(&its.lock)
    defer concurrency.unlock(&its.lock)
    for &route in its.routes {
        if route.used && route.source == source && route.event == event {
            run_command(its, COMMAND_DISCARD | cast[u64](source) << 32, cast[u64](event), 0)
            free_lpi(system, route.lpi)
            route.used = false
        }
    }
}

/**
 * Free an LPI: disabled in the property table, forgotten by routes, and free to take again.
 *
 * The caller holds its_lock.
 *
 * @param system The shared state, with the ITS and routes.
 * @param lpi The LPI's interrupt ID, FIRST_LPI or above.
 */
free_lpi :: fn(system: ptr[mut ArchSystem], lpi: u32) {
    its :: &system.its
    properties :: view_of(cast[ptr[mut u8]](its.properties), LPI_COUNT)
    index :: cast[usize](lpi - FIRST_LPI)
    if index < properties.count {
        properties[index] = 0
    }
    forget_route(system, lpi)
    give_lpi(its, lpi)
}

/**
 * Take the lowest free LPI. The caller holds its_lock.
 *
 * @param its The ITS's state, whose lpis_used marks it taken.
 * @return The LPI's interrupt ID, FIRST_LPI to FIRST_LPI + LPI_COUNT - 1; null if every one is taken.
 */
take_lpi :: fn(its: ptr[mut ItsState]) -> u32? {
    for &word, index in its.lpis_used {
        if word^ != 0xffffffffffffffff {
            for bit in 0..<64 {
                if word^ & (cast[u64](1) << cast[u64](bit)) == 0 {
                    word^ |= cast[u64](1) << cast[u64](bit)
                    return FIRST_LPI + cast[u32](index) * 64 + cast[u32](bit)
                }
            }
        }
    }
    return null
}

/**
 * Mark an LPI free in lpis_used. The caller holds its_lock.
 *
 * @param its The ITS's state.
 * @param lpi The LPI's interrupt ID, from take_lpi; one out of range is ignored.
 */
give_lpi :: fn(its: ptr[mut ItsState], lpi: u32) {
    index :: cast[usize]((lpi - FIRST_LPI) / 64)
    if index < its.lpis_used.count {
        its.lpis_used[index] &= ~(cast[u64](1) << cast[u64]((lpi - FIRST_LPI) % 64))
    }
}

/**
 * Put one command in the queue and wait until the ITS has read it, up to COMMAND_POLLS polls, then log an error
 * and go on.
 *
 * A command is four doublewords: the three given, then a fourth of zero. The caller holds its_lock.
 *
 * @param its The ITS's state, whose command_offset moves on by COMMAND_SIZE, wrapping at the queue's end.
 * @param first The first doubleword, the command's number in bits 0 to 7, and usually the device ID in bits 32 to 63.
 * @param second The second doubleword, as the command defines it.
 * @param third The third doubleword, as the command defines it.
 */
run_command :: fn(its: ptr[mut ItsState], first: u64, second: u64, third: u64) {
    slot :: its.commands + its.command_offset
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](slot), first)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](slot + 8), second)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](slot + 16), third)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](slot + 24), 0)
    its.command_offset = (its.command_offset + COMMAND_SIZE) % COMMAND_QUEUE_SIZE
    // The command in memory before the ITS is told to read it
    aarch64.dsb(.ISH)
    write_u64(its.registers, GITS_CWRITER, its.command_offset)
    polls := cast[u64](0)
    loop {
        intrinsics.spin_hint()
        polls += 1
    }
    while read_u64(its.registers, GITS_CREADR) & 0xfffe0 != its.command_offset && polls < COMMAND_POLLS
    if polls >= COMMAND_POLLS {
        runtime.log_error("GIC ITS: a command (%) wasn't taken", first & 0xff)
    }
}
