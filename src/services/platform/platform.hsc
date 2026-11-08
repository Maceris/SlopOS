/**
 * The platform service (decisions/0039, 0070, 0074): given the platform capability and the firmware tables' copy by
 * the root task, it finds the PCIe host bridge (src/pci), enumerates every function on every bus behind it, and gives
 * each, once, to the supervisor, which starts its driver with what it holds of it (platform.PciDevice). Before it gives
 * any out, it registers the IOMMUs the firmware tables describe with the kernel (iommus.hsc).
 *
 * Firmware's work is kept where it holds (decisions/0074): bus numbers bridges were given, and BARs inside a window,
 * or their bridge's, that overlap nothing. A bridge without bus numbers is given the next free ones, and a memory BAR
 * that's unplaced, outside its windows or overlapping something is placed, aligned to its size, first-fit, in the
 * host's windows, or behind a bridge, in that bridge's, never in a window of a bridge it isn't behind. I/O BARs aren't
 * placed. With test_reassign on the kernel's command line, every virtio device's BARs and every bridge's bus numbers
 * are taken as unset, so assigning them is tested on emulators whose firmware assigns everything.
 *
 * It finds the real-time clock too (clock.hsc), which one client, the supervisor for the clock service, claims.
 */
package platform

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import log_line from "../../log_line"
import pci from "../../pci"
import platform as protocol from "../../protocols/platform"
import service_kit from "../../libraries/service_kit"

/** The most PCI functions enumerated and given out; ones past it are skipped, and bridges among them not scanned. */
MAX_FUNCTIONS :: 64
/** A function's parent when it's on the host bridge's own bus, behind no bridge. */
NO_PARENT : u32 : 0xffffffff
/** A page's size in bytes, what device memory is made in multiples of. */
PAGE : u64 : 4096
/** Virtio's PCI vendor ID, whose devices' BARs test_reassign takes as unset. */
VIRTIO_VENDOR : u16 : 0x1af4
/** The header type, without its multi-function bit, of a PCI-to-PCI bridge. */
HEADER_BRIDGE : u8 : 1
/** The class register's top 24 bits for a host bridge, which no driver takes. */
CLASS_HOST_BRIDGE : u32 : 0x060000

/** A function's memory BAR, as found and as placed. */
Bar :: struct {
    /**
     * Where it is to its device, a PCI address: 0 for none, not yet placed, or taken as unset by test_reassign. For a
     * 64-bit BAR's upper half, which isn't a BAR of its own, the whole entry stays 0.
     */
    pci : u64,
    /** Its size in bytes, a power of two; 0 for no BAR, an I/O BAR, or a 64-bit BAR's upper half. */
    size : u64,
    /** Whether it's a 64-bit BAR, taking this entry and the next, so it can be placed above 4 GiB. */
    wide : bool,
    /** Whether its memory is prefetchable, as its BAR says. */
    prefetchable : bool,
    /** Whether it's where pci says and overlaps nothing, as found or as placed; only a valid BAR is given out. */
    valid : bool,
}

/** A PCI function found on a bus, and what's been done with it. */
Function :: struct {
    /** Its bus number. */
    bus : u8,
    /** Its device number on bus, 0 to 31. */
    device : u8,
    /** Its function number on device, 0 to 7. */
    function : u8,
    /** Its vendor ID. */
    vendor : u16,
    /** Its device ID, the vendor's. */
    device_id : u16,
    /** Its class code, subclass and programming interface: the class register's top 24 bits. */
    class : u32,
    /** Whether it's a PCI-to-PCI bridge; bridges are scanned behind, never given out, and their BARs not sized. */
    bridge : bool,
    /** The bridge it's behind, by its index in the functions, or NO_PARENT on the host's own bus. */
    parent : u32,
    /** Where its configuration space is mapped, in the platform service's mapping of the host's ECAM. */
    config : u64,
    /** Its six BARs, by their number; a 64-bit BAR's upper half is an empty entry. */
    bars : Bar[6],
    /** Whether a client has claimed it, so it isn't given to another. */
    claimed : bool,
    /** The client that claimed it, by its index in the platform service's clients; meaningful only once claimed. */
    claimer : usize,
    /** Whether its driver is trusted with DMA no IOMMU confines, as the claim asked; its DMA domain is made so. */
    trusted : bool,
}

/** The platform service's state, one for its life, from the heap. */
Platform :: struct {
    /** The PCIe host bridge the firmware tables describe; all zeros if there's none. */
    host : pci.Host,
    /** Where the host's ECAM, every bus of it, is mapped, readable and writable. */
    ecam : u64,
    /** The RAM the kernel owns, a view into the firmware tables' copy, which BARs are never placed over. */
    ram : slop_os.PhysicalRange[],
    /** The functions found, in the order they were, the first count of them used. */
    functions : Function[MAX_FUNCTIONS],
    /** How many of functions are used, at most MAX_FUNCTIONS. */
    count : usize,
    /** The highest bus number in use, for giving a bridge without bus numbers the next. */
    highest_bus : u8,
    /** Whether test_reassign is on the kernel's command line: virtio BARs and bridges' bus numbers are reassigned. */
    reassign : bool,
    /** How many BARs were placed, rather than kept where firmware put them, for the log. */
    placed : u32,
    /** How many BARs found no room, so their functions' memory decoding stays off, for the log. */
    unplaced : u32,
    /** The real-time clock, or null if there's none. */
    clock : Clock?,
    /** Whether a client has claimed the clock, so only it is given it again. */
    clock_claimed : bool,
    /** The client that claimed the clock, by its index; meaningful only once claimed. */
    clock_claimer : usize,
    /** The first framebuffer, or null if there's none. */
    framebuffer : Framebuffer?,
    /** Whether a client has claimed the framebuffer, so only it is given it again. */
    framebuffer_claimed : bool,
    /** The client that claimed the framebuffer, by its index; meaningful only once claimed. */
    framebuffer_claimer : usize,
    /** The firmware tables' copy, as the root task gave it, which ACPI's claimer is given a read-only copy of. */
    firmware : slop_os.Memory,
    /** Where the firmware tables' copy is mapped, readable, for the service's life. */
    tables : u64,
    /** The copy's bytes. */
    tables_size : u64,
    /** Whether a client has claimed ACPI (decisions/0182, P3). */
    acpi_claimed : bool,
    /** The client that claimed ACPI last, by its index, whose requests for ports, memory and the like are answered. */
    acpi_claimer : usize,
}

/**
 * Enumerate the PCIe devices and the real-time clock and framebuffer the firmware tables describe, and give each, once,
 * to the client that claims it.
 *
 * It's started by the root task. It maps the firmware tables, numbers the buses, places BARs, registers the IOMMUs, and
 * then serves its clients for good; without a host bridge it serves only the clock and the framebuffer.
 *
 * @param log Where it logs what it found, placed and gave out; without one it logs nothing.
 * @param platform The platform capability, which device memory, devices, DMA domains, I/O ports and IOMMU
 *     registrations are made with.
 * @param firmware The firmware tables' copy, mapped read-only for the service's life.
 * @param clients The listener its first client, the supervisor, connects on; further clients come as Connect
 *     requests.
 * @param command_line The kernel's command line; with test_reassign on it, virtio BARs and bridges' bus numbers are
 *     reassigned. Without one, firmware's are kept where they hold.
 * @return Only on failing to start: 99 without memory for its state, 2 if the firmware tables can't be mapped, 3 if the
 *     configuration space can't be, 4 without a port, and 5 if its first client can't be added. Serving, it doesn't
 *     return.
 */
main :: fn(log: slop_os.DebugLog?, platform: slop_os.Platform, firmware: slop_os.Memory, clients: os.Listener[protocol.Platform],
    command_line: slop_os.Memory?) -> int {
    block :: slop_os.startup_block()
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    space :: block.space
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    state_made, state_error :: runtime.new_aligned(Platform, align_of(Platform))
    if state_error != null {
        return 99
    }
    state :: state_made

    // The firmware tables, and the host bridge they describe
    tables_size :: slop_os.memory_size(firmware) or_return 2
    tables :: runtime.reserve_addresses(cast[usize](tables_size)) or_return 2
    slop_os.memory_map(firmware, space, tables, 0, tables_size, read) or_return 2
    state.firmware = firmware
    state.tables = tables
    state.tables_size = tables_size
    state.clock = find_clock(tables, tables_size)
    state.framebuffer = find_framebuffer(tables, tables_size)
    give_reset(to, platform, tables, tables_size)
    match pci.find_host(tables, tables_size) {
        case Some(found) => state.host = found
        case None => {
            log_line.write(to, "platform: the firmware tables describe no PCIe host bridge")
            return serve(to, platform, state, clients)
        }
    }
    state.ram = ram_of(tables, tables_size)
    state.reassign = has_word(command_line, "test_reassign")
    host :: &state.host

    // Its configuration space, every bus of it
    size :: pci.ecam_size(host)
    ecam_memory :: slop_os.memory_create_physical(platform, block.budget, host.ecam, size, .Device) or_return 3
    state.ecam = runtime.reserve_addresses(cast[usize](size)) or_return 3
    slop_os.memory_map(ecam_memory, space, state.ecam, 0, size, read_write) or_return 3
    state.highest_bus = host.first_bus
    scan_bus(state, host.first_bus, NO_PARENT)
    for i in 0..<state.count {
        size_bars(state, i)
    }
    for i in 0..<state.count {
        place_bars(to, state, i)
    }
    ranges :: register_iommus(to, platform, state, tables, tables_size)
    if ranges == 0 {
        log_line.write(to, "platform: the firmware tables describe no IOMMU, so devices' DMA reaches all of memory")
    }
    else {
        log_line.write(to, "platform: % ranges of requester IDs registered with their IOMMUs", ranges)
    }
    log_line.write(to, "platform: % functions on buses % to %, % BARs placed, % left unplaced", state.count, host.first_bus,
        state.highest_bus, state.placed, state.unplaced)
    return serve(to, platform, state, clients)
}

/**
 * Record every function on a bus, and behind its bridges, depth first.
 *
 * A bridge without bus numbers, or with a secondary bus not above its own (every bridge, with test_reassign), is given
 * the next free bus as its secondary, and as its subordinate the highest bus found behind it. A device without function
 * 0 has none, and a single-function device is read only at function 0, since it answers for every function. Functions
 * past MAX_FUNCTIONS aren't recorded, and bridges among them aren't scanned behind.
 *
 * @param state The platform service's state, its configuration space mapped: functions are added to it, count and
 *     highest_bus raised, and bridges' bus number registers written.
 * @param bus The bus to scan; a bus past the host's last is skipped.
 * @param parent The bridge the bus is behind, by its index in the functions, or NO_PARENT for the host's own bus.
 */
scan_bus :: fn(state: ptr[mut Platform], bus: u8, parent: u32) {
    if bus > state.host.last_bus {
        return void
    }
    state.highest_bus = if bus > state.highest_bus { bus } else { state.highest_bus }
    for device in 0..<32 {
        for function in 0..<8 {
            config :: state.ecam + pci.function_offset(&state.host, bus, cast[u8](device), cast[u8](function))
            vendor :: pci.read_u16(config, pci.VENDOR_ID)
            if vendor == pci.NO_VENDOR {
                // A device without function 0 has none
                if function == 0 {
                    break
                }
                continue
            }
            header :: pci.read_u8(config, pci.HEADER_TYPE)
            index :: state.count
            if index < state.functions.count {
                state.functions[index] = Function.{bus = bus, device = cast[u8](device), function = cast[u8](function),
                    vendor = vendor, device_id = pci.read_u16(config, pci.DEVICE_ID), class = pci.read_u32(config, pci.CLASS_REVISION) >> 8,
                    bridge = header & 0x7f == HEADER_BRIDGE, parent = parent, config = config}
                state.count += 1
            }
            if header & 0x7f == HEADER_BRIDGE && index < state.functions.count {
                secondary := if state.reassign { cast[u8](0) } else { pci.read_u8(config, pci.SECONDARY_BUS) }
                if secondary == 0 || secondary <= bus {
                    secondary = state.highest_bus + 1
                    pci.write_u8(config, pci.PRIMARY_BUS, bus)
                    pci.write_u8(config, pci.SECONDARY_BUS, secondary)
                    pci.write_u8(config, pci.SUBORDINATE_BUS, state.host.last_bus)
                    scan_bus(state, secondary, cast[u32](index))
                    pci.write_u8(config, pci.SUBORDINATE_BUS, state.highest_bus)
                }
                else {
                    scan_bus(state, secondary, cast[u32](index))
                }
            }
            // A single-function device answers for every function
            if function == 0 && header & 0x80 == 0 {
                break
            }
        }
    }
}

/**
 * Find a function's memory BARs: each one's size, by writing all ones with memory decoding off and reading back, and
 * where it is now.
 *
 * Each BAR is written back as it was, and the command register restored. I/O BARs are skipped, left empty, and so is
 * a bridge's every BAR. With test_reassign, a virtio function's BARs are recorded as unplaced.
 *
 * @param state The platform service's state: the function's bars are set.
 * @param index The function, by its index in the functions; one past their count does nothing.
 */
size_bars :: fn(state: ptr[mut Platform], index: usize) {
    if index >= state.functions.count {
        return void
    }
    function :: &state.functions[index]
    if function.bridge {
        return void
    }
    config :: function.config
    command :: pci.read_u16(config, pci.COMMAND)
    pci.write_u16(config, pci.COMMAND, command & ~pci.COMMAND_MEMORY)
    with {
        bar : usize = 0
    }
    loop {
        offset :: pci.BAR0 + cast[u64](bar) * 4
        original :: pci.read_u32(config, offset)
        if original & 1 != 0 {
            // I/O ports, which aren't placed
            bar += 1
            continue
        }
        wide :: (original >> 1) & 3 == 2 && bar + 1 < 6
        upper :: if wide { pci.read_u32(config, offset + 4) } else { cast[u32](0) }
        pci.write_u32(config, offset, 0xffffffff)
        mask := cast[u64](pci.read_u32(config, offset) & 0xfffffff0)
        if wide {
            pci.write_u32(config, offset + 4, 0xffffffff)
            mask |= cast[u64](pci.read_u32(config, offset + 4)) << 32
            pci.write_u32(config, offset + 4, upper)
        }
        else if mask != 0 {
            mask |= 0xffffffff00000000
        }
        pci.write_u32(config, offset, original)
        size :: if mask == 0 { cast[u64](0) } else { ~mask + 1 }
        address :: (cast[u64](original) & 0xfffffff0) | (cast[u64](upper) << 32)
        if bar < function.bars.count {
            function.bars[bar] = Bar.{pci = if state.reassign && function.vendor == VIRTIO_VENDOR { cast[u64](0) } else { address },
                size = size, wide = wide, prefetchable = original & 8 != 0}
        }
        bar += if wide { 2 } else { 1 }
    }
    while bar < 6
    pci.write_u16(config, pci.COMMAND, command)
}

/**
 * Keep a function's BARs where they are, if that's inside a window they can be in and overlaps nothing valid already,
 * and place the others, writing them to the function.
 *
 * Memory decoding is turned on once every BAR it has is somewhere; a BAR with no room leaves it off, so the function
 * decodes none of its BARs. A function without BARs is left as it is.
 *
 * @param to The debug log, NO_HANDLE for none; each BAR placed, and each with no room, is logged.
 * @param state The platform service's state: the function's bars are made valid as they're kept or placed, and placed
 *     or unplaced counted.
 * @param index The function, by its index in the functions; one past their count does nothing.
 */
place_bars :: fn(to: slop_os.DebugLog, state: ptr[mut Platform], index: usize) {
    if index >= state.functions.count {
        return void
    }
    function :: &state.functions[index]
    every := true
    any := false
    for bar in 0..<6 {
        if function.bars[bar].size == 0 {
            continue
        }
        any = true
        current :: function.bars[bar]
        if current.pci != 0 && fits_window(state, function, current, current.pci) && free_at(state, index, current.pci, current.size) {
            function.bars[bar].valid = true
            continue
        }
        match find_place(state, index, function, current) {
            case Some(address) => {
                function.bars[bar].pci = address
                function.bars[bar].valid = true
                offset :: pci.BAR0 + cast[u64](bar) * 4
                low :: pci.read_u32(function.config, offset) & 0xf
                pci.write_u32(function.config, offset, cast[u32](address & 0xfffffff0) | low)
                if current.wide {
                    pci.write_u32(function.config, offset + 4, cast[u32](address >> 32))
                }
                state.placed += 1
                log_line.write(to, "platform: BAR % of %:%.% placed at %{#018x}, % bytes", bar, function.bus, function.device, function.function,
                    address, current.size)
            }
            case None => {
                every = false
                state.unplaced += 1
                log_line.write(to, "platform: no room for BAR % of %:%.%, % bytes", bar, function.bus, function.device, function.function,
                    current.size)
            }
        }
    }
    if any && every {
        pci.write_u16(function.config, pci.COMMAND, pci.read_u16(function.config, pci.COMMAND) | pci.COMMAND_MEMORY)
    }
}

/**
 * Tell whether a function is behind a bridge, at any depth.
 *
 * @param state The platform service's state.
 * @param index The function, by its index in the functions; one past their count is behind nothing.
 * @param bridge The bridge, by its index in the functions.
 * @return True if bridge is the function's parent, or its parent's, and so on up to the host's bus.
 */
is_behind :: fn(state: ptr[Platform], index: usize, bridge: u32) -> bool {
    at := if index < state.functions.count { state.functions[index].parent } else { NO_PARENT }
    for depth in 0..<MAX_FUNCTIONS {
        if at == NO_PARENT || cast[usize](at) >= state.functions.count {
            return false
        }
        if at == bridge {
            return true
        }
        at = state.functions[at].parent
    }
    return false
}

/**
 * Tell whether a BAR at an address would be inside a window it may be in: its bridge's non-prefetchable memory window,
 * or, on the host's own bus, one of the host's windows, a 64-bit window only for a 64-bit BAR.
 *
 * @param state The platform service's state, for the bridges' windows and the host's.
 * @param function The BAR's function, whose parent decides which windows it may be in.
 * @param bar The BAR, for its size and whether it's 64-bit.
 * @param address Where it would be, a PCI address.
 * @return True if all of its bytes from address are in such a window.
 */
fits_window :: fn(state: ptr[Platform], function: ptr[Function], bar: Bar, address: u64) -> bool {
    if function.parent != NO_PARENT {
        low, high :: bridge_window(state, function.parent)
        return low <= high && address >= low && address + bar.size - 1 <= high
    }
    for window, i in state.host.windows {
        if cast[u32](i) < state.host.window_count && (bar.wide || !window.wide) && address >= window.pci
            && address + bar.size <= window.pci + window.size {
            return true
        }
    }
    return false
}

/**
 * Read a bridge's non-prefetchable memory window, as its first address and its last.
 *
 * @param state The platform service's state, for the bridge's configuration space.
 * @param index The bridge, by its index in the functions; one past their count has no window.
 * @return low The window's first PCI address, 1 MiB aligned; above high when there's no window.
 * @return high The window's last PCI address, the last byte of a 1 MiB block.
 */
bridge_window :: fn(state: ptr[Platform], index: u32) -> (low: u64, high: u64) {
    if cast[usize](index) >= state.functions.count {
        return 1, 0
    }
    config :: state.functions[index].config
    base :: cast[u64](pci.read_u16(config, pci.MEMORY_BASE) & 0xfff0) << 16
    limit :: (cast[u64](pci.read_u16(config, pci.MEMORY_LIMIT) & 0xfff0) << 16) | 0xfffff
    return base, limit
}

/**
 * Tell whether a range of PCI addresses is free for one of a function's BARs.
 *
 * It's free if it overlaps no valid BAR, no RAM, not the host's ECAM, and no window of a bridge the function isn't
 * behind, which would forward that range to its own bus.
 *
 * @param state The platform service's state.
 * @param index The function the range is for, by its index in the functions.
 * @param address The range's first PCI address.
 * @param size The range's size in bytes.
 * @return True if nothing overlaps it.
 */
free_at :: fn(state: ptr[Platform], index: usize, address: u64, size: u64) -> bool {
    if overlaps(address, size, state.host.ecam, pci.ecam_size(&state.host)) {
        return false
    }
    for other, i in state.functions {
        if i >= state.count {
            break
        }
        if other.bridge && !is_behind(state, index, cast[u32](i)) {
            low, high :: bridge_window(state, cast[u32](i))
            if low <= high && overlaps(address, size, low, high - low + 1) {
                return false
            }
        }
    }
    for range in state.ram {
        if overlaps(address, size, range.base, range.size) {
            return false
        }
    }
    for function, i in state.functions {
        if i >= state.count {
            break
        }
        for bar in function.bars {
            if bar.valid && bar.size != 0 && overlaps(address, size, bar.pci, bar.size) {
                return false
            }
        }
    }
    return true
}

/**
 * Tell whether two ranges of addresses overlap.
 *
 * @param a The first range's first address.
 * @param a_size The first range's size in bytes.
 * @param b The second range's first address.
 * @param b_size The second range's size in bytes.
 * @return True if some address is in both; a range wrapping past the top of the address space isn't handled.
 */
overlaps :: fn(a: u64, a_size: u64, b: u64, b_size: u64) -> bool {
    return a < b + b_size && b < a + a_size
}

/**
 * Find where to place a BAR: the first address aligned to its size, in a window it may be in, where it overlaps
 * nothing.
 *
 * Behind a bridge, that's the bridge's non-prefetchable window. On the host's own bus it's the host's windows, a 64-bit
 * BAR in a 64-bit window first, so 32-bit space is left for BARs that need it.
 *
 * @param state The platform service's state.
 * @param index The BAR's function, by its index in the functions.
 * @param function The function at index in the functions, only read: its parent picks the windows looked in, its
 *     bridge's if it has one, or the host's.
 * @param bar The BAR, for its size and whether it's 64-bit; its size is a power of two, not 0.
 * @return The PCI address to place it at, or null if there's no room in any window it may be in.
 */
find_place :: fn(state: ptr[Platform], index: usize, function: ptr[Function], bar: Bar) -> u64? {
    if function.parent != NO_PARENT {
        low, high :: bridge_window(state, function.parent)
        if low > high {
            return null
        }
        return first_fit(state, index, bar, low, high - low + 1)
    }
    for pass in 0..<2 {
        for window, i in state.host.windows {
            if cast[u32](i) >= state.host.window_count || window.wide != (pass == 0) || (window.wide && !bar.wide) {
                continue
            }
            match first_fit(state, index, bar, window.pci, window.size) {
                case Some(address) => return address
                case None => {}
            }
        }
    }
    return null
}

/**
 * Find the first free address for a BAR in a range, aligned to the BAR's size.
 *
 * @param state The platform service's state.
 * @param index The BAR's function, by its index in the functions.
 * @param bar The BAR, its size a power of two, not 0.
 * @param start The range's first PCI address.
 * @param size The range's size in bytes.
 * @return The first aligned address from start where the BAR overlaps nothing, or null if there's none before the
 *     range's end. The first aligned address is tried before the end is checked, so it can be returned even when the
 *     BAR doesn't fit in the range.
 */
first_fit :: fn(state: ptr[Platform], index: usize, bar: Bar, start: u64, size: u64) -> u64? {
    at := pci.round_up(start, bar.size)
    loop {
        if free_at(state, index, at, bar.size) {
            return at
        }
        at += bar.size
    }
    while at + bar.size <= start + size
    return null
}

/**
 * Find the RAM the kernel owns, from the firmware tables' "RAM " table.
 *
 * @param tables Where the firmware tables' copy is mapped, its header already checked.
 * @param size The firmware tables' copy's size in bytes; a table running past it isn't taken.
 * @return The RAM's ranges, a view into the firmware tables' copy, good while it's mapped; empty without a "RAM "
 *     table.
 */
ram_of :: fn(tables: u64, size: u64) -> slop_os.PhysicalRange[] {
    header :: cast[ptr[slop_os.FirmwareTables]](tables)
    entries :: view_of(cast[ptr[slop_os.FirmwareTable]](tables + cast[u64](size_of(slop_os.FirmwareTables))), cast[usize](header.count))
    for &entry in entries {
        if pci.signature_of(entry) == "RAM " && entry.offset + cast[u64](entry.size) <= size {
            return view_of(cast[ptr[slop_os.PhysicalRange]](tables + entry.offset), cast[usize](entry.size) / size_of(slop_os.PhysicalRange))
        }
    }
    return view_of(cast[ptr[slop_os.PhysicalRange]](tables), 0)
}

/**
 * Tell whether the kernel's command line has a word on it.
 *
 * @param command_line The command line's memory, mapped and read for the call; null for none.
 * @param word The word, matched whole.
 * @return True if the command line has it; false without a command line, or if it can't be read.
 */
has_word :: fn(command_line: slop_os.Memory?, word: string) -> bool {
    memory :: command_line or_return false
    text :: service_kit.text_of(slop_os.startup_block(), memory) or_return false
    return service_kit.has_word(text, word)
}

// ---- Claims

/**
 * Serve the platform service's clients for good: claims, reissues, and new clients' connections.
 *
 * @param to The debug log, NO_HANDLE for none.
 * @param platform The platform capability, which what's given out is made with.
 * @param state The platform service's state, its claims kept in it.
 * @param clients The listener for its first client, the supervisor; others connect through Connect.
 * @return Only on failing to start serving: 4 without a port, 5 if the first client can't be added.
 */
serve :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], clients: os.Listener[protocol.Platform]) -> int {
    block :: slop_os.startup_block()
    port :: slop_os.port_create(block.budget) or_return 4
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, port, clients.end) {
        return 5
    }
    log_line.write(to, "platform: serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve_client(to, platform, state, &connected, i, port, &into)
            i += 1
        }
        while i < connected.count
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request a client has waiting, until it has none.
 *
 * Claim, Reissue, ClaimClock and ClaimFramebuffer are each answered with a Response; Connect adds the client whose end
 * it brings, closing that end if there's no room for it; an unknown request is answered Unsupported, and one that's
 * invalid or of another protocol is skipped. A client whose channel fails is dropped.
 *
 * @param to The debug log, NO_HANDLE for none.
 * @param platform The platform capability, which what's given out is made with.
 * @param state The platform service's state, its claims kept in it.
 * @param connected The clients; a new one is added, a failed one dropped.
 * @param index The client to serve, by its index in connected; one past them, or a dropped one, does nothing.
 * @param port The port every client's end is bound to.
 * @param into Where each request is received; overwritten by each.
 */
serve_client :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], connected: ptr[mut service_kit.Clients],
    index: usize, port: slop_os.Port, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match protocol.receive_request(end, port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = protocol.answer_unsupported(end, port)
                continue
            }
            case _ => {
                service_kit.drop_client(connected, index)
                return void
            }
        }
        match os.message_of[protocol.Request](into)^ {
            case Claim(wanted) => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = claim(to, platform, state, index, wanted)
                _ = protocol.send_response(end, port, &out)
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            case Reissue(address) => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = reissue(to, platform, state, index, address)
                _ = protocol.send_response(end, port, &out)
            }
            case ClaimClock => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = claim_clock(to, platform, state, index)
                _ = protocol.send_response(end, port, &out)
            }
            case ClaimFramebuffer => {
                out := os.Outgoing.{}
                response :: os.begin[protocol.Response](&out)
                response^ = claim_framebuffer(to, platform, state, index)
                _ = protocol.send_response(end, port, &out)
            }
            case ClaimAcpi => answer(end, port, claim_acpi(to, state, index, state.tables, state.tables_size))
            case Ports(range) => answer(end, port, give_ports(platform, state, index, range))
            case PhysicalMemory(range) => answer(end, port, give_memory(platform, state, index, range))
            case ConfigRead(access) => answer(end, port, config_read(state, index, access))
            case ConfigWrite(access) => answer(end, port, config_write(state, index, access))
            case GiveSleepTypes(types) => answer(end, port, give_sleep_types(to, platform, state, index, types, state.tables, state.tables_size))
        }
    }
}

/**
 * Send a client a response.
 *
 * @param end The client's end.
 * @param port The port it's bound to.
 * @param response The response; what it holds moves to the client.
 */
answer :: fn(end: slop_os.Channel, port: slop_os.Port, response #escaping : protocol.Response) {
    out := os.Outgoing.{}
    made :: os.begin[protocol.Response](&out)
    made^ = response
    _ = protocol.send_response(end, port, &out)
}

/**
 * Give a claimed device again, made anew, to the client that claimed it; its last Device and the rest died with the
 * driver that held them.
 *
 * A device unclaimed here was claimed from the platform service before this one, which the root task started again
 * (decisions/0140), so the client asking for it is taken to be its claimer, and claims it.
 *
 * @param to The debug log, NO_HANDLE for none; a reissue is logged.
 * @param platform The platform capability, which the device's bundle is made with.
 * @param state The platform service's state.
 * @param client The asking client, by its index in the platform service's clients.
 * @param address The device's segment and requester ID (slop_os.device_address).
 * @return Claimed with the device's bundle, which moves to the client with the response; or NoDevice if no function
 *     has that address, another client claimed it, or its bundle can't be made.
 */
reissue :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], client: usize, address: u32) -> protocol.Response {
    for &function, i in state.functions {
        if i >= state.count {
            break
        }
        if slop_os.device_address(state.host.segment, function.bus, function.device, function.function) != address {
            continue
        }
        // Unclaimed here, it was claimed from the platform service before this one, which the root task started again
        // (decisions/0140): the client asking for it again is its claimer
        if !function.claimed {
            function.claimed = true
            function.claimer = client
        }
        if function.claimer != client {
            continue
        }
        match bundle_of(platform, state, function) {
            case Some(device) => {
                log_line.write(to, "platform: %:%.% reissued", function.bus, function.device, function.function)
                return .Claimed(device)
            }
            case None => return .NoDevice
        }
    }
    return .NoDevice
}

/**
 * Give a client the next unclaimed function that matches what it wants, with what its driver holds of it.
 *
 * Bridges and host bridges are never given out. A function whose bundle can't be made is logged and passed over,
 * left unclaimed.
 *
 * @param to The debug log, NO_HANDLE for none; each claim, and each function that can't be given out, is logged.
 * @param platform The platform capability, which the bundle is made with.
 * @param state The platform service's state: the function given is marked claimed by client.
 * @param client The asking client, by its index in the platform service's clients.
 * @param wanted Which devices it wants, and whether its driver is trusted with DMA no IOMMU confines.
 * @return Claimed with the device's bundle, which moves to the client with the response; or NoDevice if nothing
 *     unclaimed matches.
 */
claim :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], client: usize, wanted: protocol.Wanted)
    -> protocol.Response {
    for &function, i in state.functions {
        if i >= state.count {
            break
        }
        if function.claimed || function.bridge || function.class == CLASS_HOST_BRIDGE || !matches(function, wanted.devices) {
            continue
        }
        function.trusted = wanted.trusted
        match bundle_of(platform, state, function) {
            case Some(device) => {
                function.claimed = true
                function.claimer = client
                log_line.write(to, "platform: %:%.% (% %) claimed", function.bus, function.device, function.function,
                    function.vendor, function.device_id)
                return .Claimed(device)
            }
            case None => log_line.write(to, "platform: %:%.% can't be given out", function.bus, function.device, function.function)
        }
    }
    return .NoDevice
}

/**
 * Tell whether a function is one a client wants.
 *
 * @param function A scanned function, whose vendor ID, device ID and class are compared; only read.
 * @param wanted What's wanted: a vendor, a device and a class, each ANY_ID or ANY_CLASS for any.
 * @return True if each of the three is any or the function's.
 */
matches :: fn(function: ptr[Function], wanted: protocol.DeviceMatch) -> bool {
    return (wanted.vendor == protocol.ANY_ID || wanted.vendor == function.vendor)
        && (wanted.device == protocol.ANY_ID || wanted.device == function.device_id)
        && (wanted.class == protocol.ANY_CLASS || wanted.class == function.class)
}

/**
 * Make a function's driver's share of it: its Device, its configuration space, each valid BAR as device memory (at its
 * CPU address, whole pages), and a DMA domain it's attached to.
 *
 * @param platform The platform capability, which every handle is made with.
 * @param state The platform service's state, for the host bridge.
 * @param function The function; its trusted decides whether its DMA domain is trusted with DMA no IOMMU confines.
 * @return The bundle, its handles owned by the platform service until it's sent, NO_HANDLE for a BAR it hasn't or whose
 *     memory couldn't be made; or null, with what was made closed, if its Device, configuration space or domain can't
 *     be made, or the Device can't be attached.
 */
bundle_of :: fn(platform: slop_os.Platform, state: ptr[mut Platform], function: ptr[Function]) -> protocol.PciDevice? {
    block :: slop_os.startup_block()
    host :: &state.host
    address :: slop_os.device_address(host.segment, function.bus, function.device, function.function)
    result := protocol.PciDevice.{address = address, vendor = function.vendor, device_id = function.device_id, class = function.class}
    config_physical :: host.ecam + pci.function_offset(host, function.bus, function.device, function.function)
    result.device = slop_os.device_create(platform, block.budget, address, pci.msi_source(host, address), config_physical) or_return null
    result.config = slop_os.memory_create_physical(platform, block.budget, config_physical, pci.FUNCTION_BYTES, .Device)
        or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    trust :: if function.trusted { slop_os.DMA_DOMAIN_TRUSTED } else { cast[u32](0) }
    result.domain = slop_os.dma_domain_create(platform, block.budget, trust) or_else cast[slop_os.DmaDomain](slop_os.NO_HANDLE)
    attached := cast[slop_os.Handle](result.config) != slop_os.NO_HANDLE && cast[slop_os.Handle](result.domain) != slop_os.NO_HANDLE
    if attached {
        if slop_os.device_attach(platform, result.device, result.domain) is_error {
            attached = false
        }
    }
    if !attached {
        close_bundle(&result)
        return null
    }
    bars : slop_os.Memory[6]
    for bar, i in function.bars {
        if bar.valid && bar.size != 0 && i < bars.count {
            cpu :: cpu_address(host, bar.pci)
            bars[i] = slop_os.memory_create_physical(platform, block.budget, cpu & ~(PAGE - 1), pci.round_up(bar.size + (cpu & (PAGE - 1)), PAGE), .Device)
                or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
        }
    }
    result.bar0 = bars[0]
    result.bar1 = bars[1]
    result.bar2 = bars[2]
    result.bar3 = bars[3]
    result.bar4 = bars[4]
    result.bar5 = bars[5]
    return result
}

/**
 * Translate a PCI address in the host's windows to where the CPU sees it.
 *
 * @param host The host bridge, for its windows.
 * @param address An address on the PCI bus, as a BAR is programmed with; any value.
 * @return The CPU's address for it; address itself if it's in no window.
 */
cpu_address :: fn(host: ptr[pci.Host], address: u64) -> u64 {
    for window, i in host.windows {
        if cast[u32](i) < host.window_count && address >= window.pci && address - window.pci < window.size {
            return address - window.pci + window.cpu
        }
    }
    return address
}

/**
 * Close a bundle's Device, configuration space and DMA domain, those that were made, after it couldn't be finished.
 *
 * @param device The bundle; its BARs, which aren't made yet when it's closed, are left alone, and its handles aren't
 *     cleared.
 */
close_bundle :: fn(device: ptr[mut protocol.PciDevice]) {
    for handle in slop_os.Handle.[cast[slop_os.Handle](device.device), cast[slop_os.Handle](device.config), cast[slop_os.Handle](device.domain)] {
        if handle != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(handle)
        }
    }
}
