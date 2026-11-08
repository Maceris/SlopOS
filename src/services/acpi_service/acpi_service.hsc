/**
 * The ACPI service (decisions/0039, 0182 P3): it runs the firmware's AML, in a process of its own, restartable and
 * less trusted than the platform service. Started by the supervisor with a connection to the platform service, it
 * claims ACPI, which gives it the firmware tables; it loads the DSDT and every SSDT into the AML interpreter
 * (src/aml), enters ACPI mode, runs every present device's _INI, and gives S5's sleep types back to the platform
 * service, which gives them to the kernel, so the machine can be turned off.
 *
 * What its AML reaches goes through the platform service: I/O ports and device memory for its regions, asked for as
 * they're first used and kept, and PCI configuration space, each access asked for. Nothing else is held.
 */
package acpi_service

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import aml from "../../aml"
import acpi_tables from "../../acpi_tables"
import platform from "../../protocols/platform"

/** The most ranges of I/O ports kept, each as the platform service gave it. */
MAX_PORT_GRANTS :: 64
/** The most ranges of device memory kept, mapped. */
MAX_MEMORY_GRANTS :: 16
/** A page's bytes. */
PAGE : u64 : 4096
/** PM1's control register's SCI_EN bit: the machine's in ACPI mode. */
SCI_ENABLE : u32 : 1
/** How long entering ACPI mode is waited for, in nanoseconds. */
ACPI_MODE_WAIT : u64 : 1_000_000_000
/** EisaId ("PNP0A08"), a PCI Express host bridge. */
PCIE_HOST_BRIDGE : u64 : 0x080ad041
/** EisaId ("PNP0A03"), a PCI host bridge. */
PCI_HOST_BRIDGE : u64 : 0x030ad041

/** I/O ports the platform service gave. */
PortGrant :: struct {
    /** The first port. */
    first : u32,
    /** How many. */
    count : u32,
    /** The ports. */
    ports : slop_os.IoPortRange,
}

/** Device memory the platform service gave, mapped. */
MemoryGrant :: struct {
    /** Its first byte's physical address, page-aligned. */
    base : u64,
    /** Its bytes, whole pages. */
    size : u64,
    /** Where it's mapped, readable and writable. */
    mapped : u64,
}

/** The service's state, for its life; the AML interpreter's host reaches it by its address. */
Acpi :: struct {
    /** The connection to the platform service. */
    platform : slop_os.Channel,
    /** A port bound to it alone, waited on for its answers. */
    platform_port : slop_os.Port,
    /** A port nothing's bound to, for sleeping until a deadline. */
    sleeper : slop_os.Port,
    /** The ports kept, the first port_count of them. */
    ports : PortGrant[MAX_PORT_GRANTS],
    /** How many ports are kept. */
    port_count : usize,
    /** The memory kept, the first memory_count of it. */
    memories : MemoryGrant[MAX_MEMORY_GRANTS],
    /** How much memory is kept. */
    memory_count : usize,
    /** The interpreter. */
    interpreter : ptr[mut aml.Interpreter],
    /** What the FADT says. */
    fadt : acpi_tables.Fadt,
    /** Devices whose _STA says they're present, counted at the start. */
    present : u32,
    /** _INIs run, and those that failed. */
    initialized : u32,
    /** _INIs that failed. */
    failed : u32,
}

/**
 * Run the firmware's AML, then wait, for the supervisor to stop.
 *
 * @param platform_service A connection to the platform service of its own, on which ACPI is claimed.
 * @return 0 where there's no ACPI, so it isn't started again; on failing to start, 1 without a port, 2 if ACPI can't be
 *     claimed, 3 if the tables can't be read, 4 without a FADT, 5 without memory for the interpreter, 6 if the DSDT
 *     doesn't load.
 */
main :: fn(platform_service: os.Channel[platform.Platform]) -> int {
    block :: slop_os.startup_block()
    made, error :: runtime.new_aligned(Acpi, align_of(Acpi))
    if error != null {
        return 5
    }
    service :: made
    service.platform = platform_service.end
    service.platform_port = os.port_for(block.budget, platform_service.end) or_return 1
    service.sleeper = slop_os.port_create(block.budget) or_return 1
    hardware := platform.AcpiHardware.{}
    match ask(service, .ClaimAcpi) {
        case Some(response) => match response {
            case ClaimedAcpi(given) => hardware = given
            case _ => {
                runtime.log_info("there's no ACPI here")
                return 0
            }
        }
        case None => return 2
    }
    // The tables, copied into the heap rather than mapped, as memory another process owns is (decisions/0098)
    size :: slop_os.memory_size(hardware.tables) or_return 3
    tables, tables_error :: runtime.new_array(u8, cast[usize](size))
    if tables_error != null {
        return 3
    }
    if slop_os.memory_read(hardware.tables, 0, tables) is_error {
        return 3
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](hardware.tables))
    service.fadt = acpi_tables.parse_fadt(acpi_tables.first_table(tables, "FACP")) or_return 4

    host :: aml.Host.{state = cast[u64](service), read = host_read, write = host_write, sleep = host_sleep, stall = host_stall,
        timer = host_timer, notify = host_notify, debug = host_debug}
    service.interpreter = aml.make(host, aml.Limits.{}, view_of(cast[ptr[string]](null), 0)) or_return 5
    interpreter :: service.interpreter
    // The DSDT, then every SSDT
    match aml.load_table(interpreter, acpi_tables.first_table(tables, "DSDT")) {
        case Some(failure) => {
            runtime.log_error("the DSDT didn't load: % at % (missing %)", failure, interpreter.failed_at, interpreter.missing)
            return 6
        }
        case None => {}
    }
    ssdts : u32 = 0
    for &entry in acpi_tables.entries_of(tables) {
        if !acpi_tables.is_table(entry, "SSDT") {
            continue
        }
        match aml.load_table(interpreter, acpi_tables.table_of(tables, entry)) {
            case Some(failure) => runtime.log_error("an SSDT didn't load: %", failure)
            case None => ssdts += 1
        }
    }
    runtime.log_info("loaded the DSDT and % SSDTs", ssdts)

    enter_acpi_mode(service)
    // \_SB._INI first, then each device's, parents before what's in them
    match aml.find(interpreter, "\\_SB._INI") {
        case Some(node) => _ = aml.evaluate_node(interpreter, node, view_of(cast[ptr[aml.Value]](null), 0))
        case None => {}
    }
    initialize(service, interpreter.root)
    runtime.log_info("% devices present, % _INI run, % of them failed", service.present, service.initialized, service.failed)
    give_sleep_types(service)
    count_routes(service)
    runtime.log_info("serving")
    loop {
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(service.sleeper, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Ask the platform service something and wait for its answer.
 *
 * @param service The service, whose platform connection it's asked on; nothing else is handled while it waits.
 * @param request The request.
 * @return The answer, what it holds the caller's; null if the connection failed.
 */
ask :: fn(service: ptr[mut Acpi], request #escaping : platform.Request) -> platform.Response? {
    out := os.Outgoing.{}
    made :: os.begin[platform.Request](&out)
    made^ = request
    if platform.send_request(service.platform, service.platform_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match platform.receive_response(service.platform, service.platform_port, &into, true) {
            case Received => break
            case _ => return null
        }
    }
    return os.message_of[platform.Response](&into)^
}

// ---- What the AML reaches

/**
 * Find, or ask for and keep, I/O ports covering a run.
 *
 * @param service The service, whose ports may grow by the ones given.
 * @param first The run's first port.
 * @param count Its ports.
 * @return The ports and the offset of first in them; null if the platform service refused them.
 */
ports_for :: fn(service: ptr[mut Acpi], first: u64, count: u64) -> PortGrant? {
    for grant, i in service.ports {
        if i >= service.port_count {
            break
        }
        if first >= cast[u64](grant.first) && first + count <= cast[u64](grant.first) + cast[u64](grant.count) {
            return grant
        }
    }
    if first > 0xffff || count > 0x10000 - first {
        return null
    }
    match ask(service, .Ports(platform.PortRange.{first = cast[u32](first), count = cast[u32](count)})) {
        case Some(response) => match response {
            case GivenPorts(ports) => {
                grant :: PortGrant.{first = cast[u32](first), count = cast[u32](count), ports = ports}
                at :: service.port_count
                if at < service.ports.count {
                    service.ports[at] = grant
                    service.port_count = at + 1
                }
                return grant
            }
            case _ => return null
        }
        case None => return null
    }
    return null
}

/**
 * Find, or ask for, keep and map, device memory covering a run.
 *
 * @param service The service, whose memories may grow by the one given.
 * @param address The run's first byte's physical address.
 * @param count Its bytes.
 * @return Where address is mapped; null if the platform service refused it, or it can't be mapped.
 */
memory_for :: fn(service: ptr[mut Acpi], address: u64, count: u64) -> u64? {
    for grant, i in service.memories {
        if i >= service.memory_count {
            break
        }
        if address >= grant.base && address + count <= grant.base + grant.size {
            return grant.mapped + (address - grant.base)
        }
    }
    if service.memory_count >= service.memories.count {
        return null
    }
    response :: ask(service, .PhysicalMemory(platform.MemoryRange.{address = address, size = count})) or_return null
    memory : slop_os.Memory = cast[slop_os.Memory](slop_os.NO_HANDLE)
    match response {
        case GivenMemory(given) => memory = given
        case _ => return null
    }
    size :: slop_os.memory_size(memory) or_return null
    mapped :: runtime.reserve_addresses(cast[usize](size)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, slop_os.startup_block().space, mapped, 0, size, read_write) or_return null
    base :: address & ~(PAGE - 1)
    at :: service.memory_count
    if at < service.memories.count {
        service.memories[at] = MemoryGrant.{base = base, size = size, mapped = mapped}
        service.memory_count = at + 1
    }
    return mapped + (address - base)
}

/**
 * Read an operation region for the AML interpreter: SystemMemory, SystemIO and PCI_Config, through the platform
 * service; a 64-bit access to ports or configuration space is two 32-bit ones.
 *
 * @param state The Acpi's address.
 * @param space The region's space.
 * @param address Where.
 * @param width The bits: 8, 16, 32 or 64.
 * @return The value; null for another space, or an access the platform service refused.
 */
host_read :: fn(state: u64, space: u8, address: u64, width: u32) -> u64? {
    service :: cast[ptr[mut Acpi]](state)
    if width == 64 && space != cast[u8](aml.RegionSpace.SystemMemory) {
        low :: host_read(state, space, address, 32) or_return null
        high :: host_read(state, space, address + 4, 32) or_return null
        return low | (high << 32)
    }
    bytes :: cast[u64](width / 8)
    if space == cast[u8](aml.RegionSpace.SystemIo) {
        grant :: ports_for(service, address, bytes) or_return null
        value :: slop_os.io_port_read(grant.ports, cast[u32](address - cast[u64](grant.first)), cast[u32](bytes)) or_return null
        return cast[u64](value)
    }
    if space == cast[u8](aml.RegionSpace.SystemMemory) {
        at :: memory_for(service, address, bytes) or_return null
        if width == 8 {
            return cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](at)))
        }
        if width == 16 {
            return cast[u64](intrinsics.volatile_load_u16(cast[ptr[u16]](at)))
        }
        if width == 32 {
            return cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](at)))
        }
        return intrinsics.volatile_load_u64(cast[ptr[u64]](at))
    }
    if space == cast[u8](aml.RegionSpace.PciConfig) {
        response :: ask(service, .ConfigRead(platform.ConfigAccess.{address = address, width = width})) or_return null
        match response {
            case ConfigValue(value) => return value
            case _ => return null
        }
    }
    return null
}

/**
 * Write an operation region for the AML interpreter, as host_read reads one.
 *
 * @param state The Acpi's address.
 * @param space The region's space.
 * @param address Where.
 * @param width The bits.
 * @param value What's written.
 * @return False for another space, or an access the platform service refused.
 */
host_write :: fn(state: u64, space: u8, address: u64, width: u32, value: u64) -> bool {
    service :: cast[ptr[mut Acpi]](state)
    if width == 64 && space != cast[u8](aml.RegionSpace.SystemMemory) {
        return host_write(state, space, address, 32, value & 0xffffffff) && host_write(state, space, address + 4, 32, value >> 32)
    }
    bytes :: cast[u64](width / 8)
    if space == cast[u8](aml.RegionSpace.SystemIo) {
        grant :: ports_for(service, address, bytes) or_return false
        return slop_os.io_port_write(grant.ports, cast[u32](address - cast[u64](grant.first)), cast[u32](bytes), cast[u32](value & 0xffffffff)) is_ok
    }
    if space == cast[u8](aml.RegionSpace.SystemMemory) {
        at :: memory_for(service, address, bytes) or_return false
        if width == 8 {
            intrinsics.volatile_store_u8(cast[ptr[mut u8]](at), cast[u8](value & 0xff))
        }
        else if width == 16 {
            intrinsics.volatile_store_u16(cast[ptr[mut u16]](at), cast[u16](value & 0xffff))
        }
        else if width == 32 {
            intrinsics.volatile_store_u32(cast[ptr[mut u32]](at), cast[u32](value & 0xffffffff))
        }
        else {
            intrinsics.volatile_store_u64(cast[ptr[mut u64]](at), value)
        }
        return true
    }
    if space == cast[u8](aml.RegionSpace.PciConfig) {
        response :: ask(service, .ConfigWrite(platform.ConfigAccess.{address = address, width = width, value = value})) or_return false
        match response {
            case Done => return true
            case _ => return false
        }
    }
    return false
}

/** Sleep, for the AML interpreter: the service waits on a port nothing's bound to until the time's passed. */
host_sleep :: fn(state: u64, milliseconds: u64) {
    service :: cast[ptr[mut Acpi]](state)
    now :: slop_os.clock_monotonic() or_else 0
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(service.sleeper, packets, now + milliseconds * 1_000_000)
}

/** Stall, for the AML interpreter: spin until the time's passed. */
host_stall :: fn(state: u64, microseconds: u64) {
    until :: (slop_os.clock_monotonic() or_else 0) + microseconds * 1000
    loop {
        intrinsics.spin_hint()
    }
    while (slop_os.clock_monotonic() or_else until) < until
}

/** The timer, for the AML interpreter: the monotonic clock in 100-nanosecond units. */
host_timer :: fn(state: u64) -> u64 {
    return (slop_os.clock_monotonic() or_else 0) / 100
}

/** A notification, for the AML interpreter: logged, until the power button's handled (P3c). */
host_notify :: fn(state: u64, node: ptr[aml.Node], value: u64) {
    storage : u8[64]
    path := text_buffer.make(storage)
    aml.write_path(&path, node)
    runtime.log_info("% notified with %", text_buffer.as_string(&path), value)
}

/** What AML stores to the debug object, for the AML interpreter: logged. */
host_debug :: fn(state: u64, text: string) {
    runtime.log_info("AML says: %", text)
}

// ---- Starting

/**
 * Enter ACPI mode, unless the machine's in it already: ACPI_ENABLE written to the SMI command port, then SCI_EN in
 * PM1a's control register waited for.
 *
 * @param service The service, whose FADT says how.
 */
enter_acpi_mode :: fn(service: ptr[mut Acpi]) {
    fadt :: service.fadt
    control :: cast[u64](fadt.pm1a_control)
    if control == 0 {
        return void
    }
    if (host_read(cast[u64](service), cast[u8](aml.RegionSpace.SystemIo), control, 16) or_else 0) & cast[u64](SCI_ENABLE) != 0 {
        runtime.log_info("the machine's in ACPI mode")
        return void
    }
    if fadt.smi_command == 0 || fadt.acpi_enable == 0 {
        runtime.log_error("the machine isn't in ACPI mode, and has no way into it")
        return void
    }
    _ = host_write(cast[u64](service), cast[u8](aml.RegionSpace.SystemIo), cast[u64](fadt.smi_command), 8, cast[u64](fadt.acpi_enable))
    until :: (slop_os.clock_monotonic() or_else 0) + ACPI_MODE_WAIT
    loop {
        if (host_read(cast[u64](service), cast[u8](aml.RegionSpace.SystemIo), control, 16) or_else 0) & cast[u64](SCI_ENABLE) != 0 {
            runtime.log_info("entered ACPI mode")
            return void
        }
        host_sleep(cast[u64](service), 10)
    }
    while (slop_os.clock_monotonic() or_else until) < until
    runtime.log_error("the machine didn't enter ACPI mode")
}

/**
 * Run the _INI of every device beneath a node whose _STA says it's present, parents before what's in them; beneath a
 * device neither present nor functional, nothing's run (ACPI 6.5 §6.5.1).
 *
 * @param service The service, whose counts grow.
 * @param node Where to start; its own _INI isn't run here.
 */
initialize :: fn(service: ptr[mut Acpi], node: ptr[mut aml.Node]) {
    interpreter :: service.interpreter
    none :: view_of(cast[ptr[aml.Value]](null), 0)
    child := node.first_child
    loop {
        inner :: child or_break
        child = inner.next
        // A scope, as \_SB is, holds devices but has no _STA of its own
        if inner.kind == .Scope {
            initialize(service, inner)
            continue
        }
        if inner.kind != .Device && inner.kind != .Processor && inner.kind != .ThermalZone {
            continue
        }
        status : u64 = 0x0f
        match aml.child_of(inner, aml.segment_of("_STA")) {
            case Some(found) => {
                match aml.evaluate_node(interpreter, found, none) {
                    case Ok(value) => match value {
                        case Integer(number) => status = number
                        case _ => {}
                    }
                    case Error(_) => {}
                }
            }
            case None => {}
        }
        if status & 1 != 0 {
            service.present += 1
            match aml.child_of(inner, aml.segment_of("_INI")) {
                case Some(found) => {
                    service.initialized += 1
                    if aml.evaluate_node(interpreter, found, none) is_error {
                        service.failed += 1
                    }
                }
                case None => {}
            }
        }
        // Beneath a device that's neither present nor functional, nothing's there to start
        if status & 1 != 0 || status & 8 != 0 {
            initialize(service, inner)
        }
    }
}

/**
 * Give the platform service S5's sleep types, `\_S5`'s first two elements, for the kernel.
 *
 * @param service The service.
 */
give_sleep_types :: fn(service: ptr[mut Acpi]) {
    value :: aml.evaluate(service.interpreter, "\\_S5", view_of(cast[ptr[aml.Value]](null), 0)) or_else aml.Value.Uninitialized
    types := platform.SleepTypes.{}
    match value {
        case Package(package) => {
            elements :: package.elements
            if elements.count < 2 {
                runtime.log_error("\\_S5 has fewer than its two sleep types")
                return void
            }
            types.a = cast[u8](small_integer(elements[0]) & 7)
            types.b = cast[u8](small_integer(elements[1]) & 7)
        }
        case _ => {
            runtime.log_error("there's no \\_S5, so the machine can't be turned off")
            return void
        }
    }
    match ask(service, .GiveSleepTypes(types)) {
        case Some(response) => match response {
            case Done => runtime.log_info("S5's sleep types, % and %, given for turning the machine off", types.a, types.b)
            case _ => runtime.log_error("S5's sleep types were refused")
        }
        case None => runtime.log_error("S5's sleep types couldn't be given")
    }
}

/**
 * An integer element's value.
 *
 * @param value The element.
 * @return Its value; 0 for anything but an integer.
 */
small_integer :: fn(value: aml.Value) -> u64 {
    match value {
        case Integer(number) => return number
        case _ => return 0
    }
}

/**
 * Find the host bridge, the first device beneath \_SB whose _HID is PNP0A08 or PNP0A03, and log how many interrupt
 * routes its _PRT has.
 *
 * @param service The service.
 */
count_routes :: fn(service: ptr[mut Acpi]) {
    interpreter :: service.interpreter
    bus :: aml.find(interpreter, "\\_SB") or_return void
    none :: view_of(cast[ptr[aml.Value]](null), 0)
    child := bus.first_child
    loop {
        inner :: child or_break
        child = inner.next
        number : u64 = 0
        match aml.child_of(inner, aml.segment_of("_HID")) {
            case Some(hid) => number = small_integer(aml.evaluate_node(interpreter, hid, none) or_else aml.Value.Uninitialized)
            case None => {}
        }
        if number != PCIE_HOST_BRIDGE && number != PCI_HOST_BRIDGE {
            continue
        }
        routes :: aml.child_of(inner, aml.segment_of("_PRT")) or_return void
        match aml.evaluate_node(interpreter, routes, none) {
            case Ok(value) => match value {
                case Package(package) => runtime.log_info("the host bridge's _PRT routes % interrupts", package.elements.count)
                case _ => runtime.log_error("the host bridge's _PRT isn't a package")
            }
            case Error(failure) => runtime.log_error("the host bridge's _PRT failed: %", failure)
        }
        return void
    }
}
