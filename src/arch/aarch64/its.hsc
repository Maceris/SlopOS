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
GITS_CTLR : u64 : 0x0000
GITS_TYPER : u64 : 0x0008
GITS_CBASER : u64 : 0x0080
GITS_CWRITER : u64 : 0x0088
GITS_CREADR : u64 : 0x0090
GITS_BASER : u64 : 0x0100
GITS_TRANSLATER : u64 : 0x10040
ITS_SIZE : u64 : 0x20000
CTLR_ENABLED : u32 : 1
CTLR_QUIESCENT : u32 : 1 << 31

// Redistributor registers for LPIs, in its RD frame
GICR_CTLR : u64 : 0x0000
GICR_PROPBASER : u64 : 0x0070
GICR_PENDBASER : u64 : 0x0078
GICR_CTLR_ENABLE_LPIS : u32 : 1
TYPER_PHYSICAL_LPIS : u64 : 1

// Tables' memory: normal, inner write-back read- and write-allocate, inner shareable
TABLE_INNER_CACHE : u64 : 7
TABLE_SHAREABLE : u64 : 1
BASER_VALID : u64 : 1 << 63
BASER_TYPE_DEVICES : u64 : 1
BASER_TYPE_COLLECTIONS : u64 : 4
PENDING_ZEROED : u64 : 1 << 62

// LPIs from 8192, with 14 bits of interrupt ID: 8192 of them
FIRST_LPI : u32 : 8192
LPI_ID_BITS : u64 : 14
LPI_COUNT :: 8192
// Each LPI's byte in the property table: its priority, and whether it's enabled
LPI_ENABLED : u8 : 1

// The memory init_msi is given, in this order, each part aligned to 64 KiB as the pending tables must be
COMMAND_QUEUE_SIZE : u64 : 0x10000
PROPERTY_TABLE_SIZE : u64 : 0x10000
COLLECTION_TABLE_SIZE : u64 : 0x10000
PENDING_TABLE_SIZE : u64 : 0x10000
// Device IDs up to 16 bits: a flat device table of up to 2^16 entries
MAX_DEVICE_BITS : u64 : 16
COMMAND_SIZE : u64 : 32

// ITS commands
COMMAND_MOVI : u64 : 0x01
COMMAND_SYNC : u64 : 0x05
COMMAND_MAPD : u64 : 0x08
COMMAND_MAPC : u64 : 0x09
COMMAND_MAPTI : u64 : 0x0a
COMMAND_INV : u64 : 0x0c
COMMAND_DISCARD : u64 : 0x0f

MAX_COLLECTIONS :: 128
MAX_MSI_ROUTES :: 256
// The ITS waits this many polls for a command at most before the kernel gives up on it.
COMMAND_POLLS : u64 : 10000000

// A CPU's redistributor as a collection: whose affinity it has, and how the ITS names it (MAPC's RDbase).
Collection :: struct {
    affinity : u64,
    target : u64,
}

// An event routed: which LPI it raises.
MsiRoute :: struct {
    used : bool,
    source : u32,
    event : u32,
    lpi : u32,
}

// What the ITS needs, in ArchSystem.
ItsState :: struct {
    // Its registers through the direct map, and where they are; 0 without one.
    registers : u64,
    physical : u64,
    // Set up (init_msi), so MSIs can be had.
    ready : bool,
    lock : concurrency.SpinLock,
    // From GITS_TYPER: bytes an event takes in a translation table, device ID bits, and whether MAPC names a
    // redistributor by its address (or by its processor number)
    itt_entry_size : u64,
    device_bits : u64,
    targets_by_address : bool,
    // The command queue and the property table, through the direct map, and where the next command goes.
    commands : u64,
    command_offset : u64,
    properties : u64,
    collections : Collection[MAX_COLLECTIONS],
    collection_count : u32,
    lpis_used : u64[LPI_COUNT / 64],
    routes : MsiRoute[MAX_MSI_ROUTES],
}

// The ITS's registers, mapped through the direct map, from the device tree's node for it.
map_its :: fn(system: ptr[mut ArchSystem], physical: u64) {
    if physical == 0 || !map_device_range(system, physical, ITS_SIZE) {
        return void
    }
    system.its.physical = physical
    system.its.registers = system.direct_map_offset + physical
}

// Bytes of memory for the device table this ITS needs, which init_msi's memory has after its first three parts.
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

device_bits_of :: fn(typer: u64) -> u64 {
    bits :: ((typer >> 13) & 0x1f) + 1
    return if bits > MAX_DEVICE_BITS { MAX_DEVICE_BITS } else { bits }
}

round_up_64k :: fn(value: u64) -> u64 {
    return (value + 0xffff) & ~cast[u64](0xffff)
}

// How many redistributors the region has, each a CPU's.
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

/*
 * The ITS set up with memory, msi_controller_memory's bytes: its tables and command queue, every redistributor's
 * LPIs on, and each one a collection. Once every CPU has started, so every redistributor is awake.
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

// Bytes of a device's interrupt translation table, for MAX_DEVICE_MSIS events; null without an ITS.
// The page of GITS_TRANSLATER, which a device's MSI is a write to.
msi_doorbell :: fn() -> arch_interface.PhysicalAddress? {
    its :: &current_system().its
    if !its.ready {
        return null
    }
    return cast[arch_interface.PhysicalAddress]((its.physical + GITS_TRANSLATER) & ~cast[u64](0xfff))
}

msi_device_memory :: fn() -> u64? {
    its :: &current_system().its
    if !its.ready {
        return null
    }
    return its.itt_entry_size * 32
}

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

// The device unmapped, which drops every event of its; their LPIs free again.
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

/*
 * Source's event as an LPI of its own, on the collection of the CPU with this hardware ID, enabled; the LPI routed
 * to id there. The message: the event's number, to GITS_TRANSLATER.
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

// Source's event's LPI moved to the collection of the CPU with this hardware ID (MOVI), and routed to id there.
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

// An LPI disabled, forgotten by routes, and free. Takes its_lock as held.
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

give_lpi :: fn(its: ptr[mut ItsState], lpi: u32) {
    index :: cast[usize]((lpi - FIRST_LPI) / 64)
    if index < its.lpis_used.count {
        its.lpis_used[index] &= ~(cast[u64](1) << cast[u64]((lpi - FIRST_LPI) % 64))
    }
}

/*
 * One command, its four doublewords: the first (with its number), the second and the third, the fourth zero. Waits
 * until the ITS has read it. Takes its_lock as held.
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
