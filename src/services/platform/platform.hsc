/*
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
import service_kit from "../../service_kit"

MAX_FUNCTIONS :: 64
NO_PARENT : u32 : 0xffffffff
PAGE : u64 : 4096
VIRTIO_VENDOR : u16 : 0x1af4
HEADER_BRIDGE : u8 : 1
// The class register's top 24 bits for a host bridge, which no driver takes
CLASS_HOST_BRIDGE : u32 : 0x060000

Bar :: struct {
    // Where it is to its device, and how big; 0 for none, or a 64-bit one's upper half
    pci : u64,
    size : u64,
    wide : bool,
    prefetchable : bool,
    // Where it is, and overlaps nothing, as found or as placed
    valid : bool,
}

Function :: struct {
    bus : u8,
    device : u8,
    function : u8,
    vendor : u16,
    device_id : u16,
    class : u32,
    bridge : bool,
    // The bridge it's behind, by its index, or NO_PARENT on the host's own bus
    parent : u32,
    config : u64,
    bars : Bar[6],
    claimed : bool,
    // The client that claimed it, by its index, and whether its driver is trusted with DMA no IOMMU confines
    claimer : usize,
    trusted : bool,
}

Platform :: struct {
    host : pci.Host,
    ecam : u64,
    ram : slop_os.PhysicalRange[],
    functions : Function[MAX_FUNCTIONS],
    count : usize,
    // The highest bus number in use, for giving a bridge the next
    highest_bus : u8,
    reassign : bool,
    placed : u32,
    unplaced : u32,
    // The real-time clock, if there is one, and the client that claimed it
    clock : Clock?,
    clock_claimed : bool,
    clock_claimer : usize,
}

main :: fn(log: slop_os.DebugLog?, platform: slop_os.Platform, firmware: slop_os.Memory, clients: os.Listener[protocol.Platform],
    command_line: slop_os.Memory?) -> int {
    block :: slop_os.startup_block()
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    space :: block.space
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    state := runtime.new(Platform)

    // The firmware tables, and the host bridge they describe
    tables_size :: slop_os.memory_size(firmware) or_return 2
    tables :: runtime.reserve_addresses(cast[usize](tables_size)) or_return 2
    slop_os.memory_map(firmware, space, tables, 0, tables_size, read) or_return 2
    state.clock = find_clock(tables, tables_size)
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

// Every function on bus, and behind its bridges, depth first; a bridge without bus numbers is given the next free ones.
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

/*
 * A function's memory BARs: each one's size, by writing all ones with memory decoding off and reading back, and
 * where it is now. A bridge's two are left as they are.
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

/*
 * A function's BARs where they are, if that's inside a window they can be in and overlaps nothing valid already;
 * the others placed, and written; memory decoding on once all of them are somewhere.
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

// Whether the function at index is behind the bridge at bridge, at any depth.
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

// Whether a BAR at address is inside a window it may be in: its bridge's, or the host's.
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

/*
 * The non-prefetchable memory window of the bridge at index, as its first address and its last (the first above the
 * last for none).
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

/*
 * Whether size bytes at address, for the function at index, overlap no valid BAR, no RAM, not the host's ECAM, and no
 * window of a bridge the function isn't behind, which forwards that range to its own bus.
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

overlaps :: fn(a: u64, a_size: u64, b: u64, b_size: u64) -> bool {
    return a < b + b_size && b < a + a_size
}

/*
 * The first address aligned to the BAR's size, in a window it may be in, where it overlaps nothing: its bridge's
 * window, or the host's, a 64-bit one in a wide window first.
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

// The RAM the kernel owns, from the firmware tables' "RAM " table.
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

// Whether the kernel's command line, if there's one, has word on it.
has_word :: fn(command_line: slop_os.Memory?, word: string) -> bool {
    memory :: command_line or_return false
    text :: service_kit.text_of(slop_os.startup_block(), memory) or_return false
    return service_kit.has_word(text, word)
}

// ---- Claims

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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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
        }
    }
}

/*
 * A claimed device, by its address, given again to the client that claimed it, made anew; NoDevice for one it didn't
 * claim. Its last Device and the rest died with the driver that held them.
 */
reissue :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], client: usize, address: u32) -> protocol.Response {
    for &function, i in state.functions {
        if i >= state.count {
            break
        }
        if !function.claimed || function.claimer != client
            || slop_os.device_address(state.host.segment, function.bus, function.device, function.function) != address {
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

// The next unclaimed function wanted matches, with what its driver holds of it; or NoDevice.
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

matches :: fn(function: ptr[Function], wanted: protocol.DeviceMatch) -> bool {
    return (wanted.vendor == protocol.ANY_ID || wanted.vendor == function.vendor)
        && (wanted.device == protocol.ANY_ID || wanted.device == function.device_id)
        && (wanted.class == protocol.ANY_CLASS || wanted.class == function.class)
}

/*
 * A function's driver's share of it, owned by the platform service until it's sent: its Device, its configuration
 * space, each placed BAR as device memory (at its CPU address), and a DMA domain it's attached to. Null, with what was
 * made closed, if any of it can't be made.
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

// Where an address in the host's windows is to the CPU.
cpu_address :: fn(host: ptr[pci.Host], address: u64) -> u64 {
    for window, i in host.windows {
        if cast[u32](i) < host.window_count && address >= window.pci && address - window.pci < window.size {
            return address - window.pci + window.cpu
        }
    }
    return address
}

close_bundle :: fn(device: ptr[mut protocol.PciDevice]) {
    for handle in slop_os.Handle.[cast[slop_os.Handle](device.device), cast[slop_os.Handle](device.config), cast[slop_os.Handle](device.domain)] {
        if handle != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(handle)
        }
    }
}
