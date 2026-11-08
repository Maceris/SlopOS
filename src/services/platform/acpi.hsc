package platform

import slop_os from "std/os"
import acpi_tables from "../../acpi_tables"
import log_line from "../../log_line"
import pci from "../../pci"
import platform as protocol from "../../protocols/platform"

/*
 * What the ACPI service is given (decisions/0182, P3): the firmware tables and the SCI when it claims ACPI, and, as
 * its AML asks, I/O ports, device memory and PCI configuration space, each checked against what only the platform
 * service may touch. S5's sleep types it gives back, which go to the kernel with the FADT's PM1 control registers.
 */

/** The PCI configuration mechanism's ports, 0xcf8 to 0xcff, which no client is given. */
PCI_PORTS : u32 : 0xcf8
/** How many there are. */
PCI_PORT_COUNT : u32 : 8
/** The most device memory one PhysicalMemory request is given. */
MOST_ACPI_MEMORY : u64 : 16 * 1024 * 1024

/**
 * Give the client asking the firmware tables, as ACPI's claimer from now on.
 *
 * @param to The debug log; the claim is logged.
 * @param state The platform service's state, whose acpi_claimer is set.
 * @param client The client asking, by its index.
 * @param tables Where the firmware tables' copy is mapped.
 * @param size Its bytes.
 * @return ClaimedAcpi with a read-only copy of the tables; NoDevice without a FADT and a DSDT, or if it can't be copied.
 */
claim_acpi :: fn(to: slop_os.DebugLog, state: ptr[mut Platform], client: usize, tables: u64, size: u64) -> protocol.Response {
    if (pci.firmware_table(tables, size, "FACP") is_none) || (pci.firmware_table(tables, size, "DSDT") is_none) {
        return .NoDevice
    }
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy :: slop_os.handle_duplicate(cast[slop_os.Handle](state.firmware), rights) or_return .NoDevice
    state.acpi_claimed = true
    state.acpi_claimer = client
    log_line.write(to, "platform: ACPI claimed")
    return .ClaimedAcpi(protocol.AcpiHardware.{tables = cast[slop_os.Memory](copy), sci = cast[slop_os.Irq](slop_os.NO_HANDLE)})
}

/**
 * Tell whether a client is ACPI's claimer.
 *
 * @param state The platform service's state.
 * @param client The client, by its index.
 * @return True if it claimed ACPI last.
 */
is_acpi :: fn(state: ptr[Platform], client: usize) -> bool {
    return state.acpi_claimed && state.acpi_claimer == client
}

/**
 * Give ACPI's claimer I/O ports.
 *
 * @param platform The platform capability, which they're made with.
 * @param state The platform service's state.
 * @param client The client asking.
 * @param range The ports.
 * @return GivenPorts; Refused for another client, ports past 65535, or among PCI_PORTS'.
 */
give_ports :: fn(platform: slop_os.Platform, state: ptr[Platform], client: usize, range: protocol.PortRange) -> protocol.Response {
    if !is_acpi(state, client) || range.count == 0 || range.first > 0xffff || range.count > 0x10000 - range.first {
        return .Refused
    }
    if range.first < PCI_PORTS + PCI_PORT_COUNT && PCI_PORTS < range.first + range.count {
        return .Refused
    }
    ports :: slop_os.io_ports_create(platform, slop_os.startup_block().budget, range.first, range.count) or_return .Refused
    return .GivenPorts(ports)
}

/**
 * Give ACPI's claimer device memory, the whole pages a range is in.
 *
 * @param platform The platform capability, which it's made with.
 * @param state The platform service's state, whose RAM and host bridge are kept out.
 * @param client The client asking.
 * @param range The memory.
 * @return GivenMemory; Refused for another client, a range over MOST_ACPI_MEMORY, or one overlapping RAM the kernel
 *     owns or the host bridge's ECAM.
 */
give_memory :: fn(platform: slop_os.Platform, state: ptr[Platform], client: usize, range: protocol.MemoryRange) -> protocol.Response {
    if !is_acpi(state, client) || range.size == 0 || range.size > MOST_ACPI_MEMORY || range.address > 0xffffffffffffffff - range.size {
        return .Refused
    }
    base :: range.address & ~(PAGE - 1)
    size :: ((range.address + range.size + PAGE - 1) & ~(PAGE - 1)) - base
    for ram in state.ram {
        if overlaps(base, size, ram.base, ram.size) {
            return .Refused
        }
    }
    if state.host.ecam != 0 && overlaps(base, size, state.host.ecam, pci.ecam_size(&state.host)) {
        return .Refused
    }
    memory :: slop_os.memory_create_physical(platform, slop_os.startup_block().budget, base, size, .Device) or_return .Refused
    return .GivenMemory(memory)
}

/**
 * Where an access to a PCI function's configuration space is, in the ECAM's mapping.
 *
 * @param state The platform service's state, its ECAM mapped.
 * @param access The access.
 * @return The register's address in the mapping; null for a function the host bridge doesn't reach, a width that
 *     isn't 8, 16 or 32, or an access past the function's 4 KiB or not aligned to its width.
 */
config_register :: fn(state: ptr[Platform], access: protocol.ConfigAccess) -> u64? {
    host :: &state.host
    if state.ecam == 0 {
        return null
    }
    segment :: (access.address >> 32) & 0xffff
    bus :: (access.address >> 24) & 0xff
    device :: (access.address >> 19) & 0x1f
    function :: (access.address >> 16) & 7
    offset :: access.address & 0xffff
    bytes :: cast[u64](access.width / 8)
    if segment != cast[u64](host.segment) || bus < cast[u64](host.first_bus) || bus > cast[u64](host.last_bus) {
        return null
    }
    if (bytes != 1 && bytes != 2 && bytes != 4) || offset % bytes != 0 || offset + bytes > 4096 {
        return null
    }
    return state.ecam + pci.function_offset(host, cast[u8](bus), cast[u8](device), cast[u8](function)) + offset
}

/**
 * Read a PCI function's configuration space for ACPI's claimer.
 *
 * @param state The platform service's state.
 * @param client The client asking.
 * @param access The access.
 * @return ConfigValue; Refused for another client, or an access config_register refuses.
 */
config_read :: fn(state: ptr[Platform], client: usize, access: protocol.ConfigAccess) -> protocol.Response {
    if !is_acpi(state, client) {
        return .Refused
    }
    register :: config_register(state, access) or_return .Refused
    function :: register & ~cast[u64](4095)
    offset :: register & 4095
    if access.width == 8 {
        return .ConfigValue(cast[u64](pci.read_u8(function, offset)))
    }
    if access.width == 16 {
        return .ConfigValue(cast[u64](pci.read_u16(function, offset)))
    }
    return .ConfigValue(cast[u64](pci.read_u32(function, offset)))
}

/**
 * Write a PCI function's configuration space for ACPI's claimer, but a type 0 header's command register, BARs and
 * expansion ROM, which only the platform service sets.
 *
 * @param state The platform service's state.
 * @param client The client asking.
 * @param access The access.
 * @return Done; Refused for another client, an access config_register refuses, or one reaching those registers.
 */
config_write :: fn(state: ptr[Platform], client: usize, access: protocol.ConfigAccess) -> protocol.Response {
    if !is_acpi(state, client) {
        return .Refused
    }
    register :: config_register(state, access) or_return .Refused
    function :: register & ~cast[u64](4095)
    offset :: register & 4095
    bytes :: cast[u64](access.width / 8)
    header :: pci.read_u8(function, 0x0e) & 0x7f
    if header == 0 && (overlaps(offset, bytes, 0x04, 2) || overlaps(offset, bytes, 0x10, 0x18) || overlaps(offset, bytes, 0x30, 4)) {
        return .Refused
    }
    if access.width == 8 {
        pci.write_u8(function, offset, cast[u8](access.value & 0xff))
    }
    else if access.width == 16 {
        pci.write_u16(function, offset, cast[u16](access.value & 0xffff))
    }
    else {
        pci.write_u32(function, offset, cast[u32](access.value & 0xffffffff))
    }
    return .Done
}

/**
 * Give the kernel S5's sleep types from ACPI's claimer, with the FADT's PM1 control registers, so it can turn the
 * machine off.
 *
 * @param to The debug log; what's given is logged.
 * @param platform The platform capability, the call's authority.
 * @param state The platform service's state.
 * @param client The client asking.
 * @param types The sleep types.
 * @param tables Where the firmware tables' copy is mapped.
 * @param size Its bytes.
 * @return Done; Refused for another client, a FADT without PM1a's control block, or the kernel refusing them.
 */
give_sleep_types :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[Platform], client: usize, types: protocol.SleepTypes,
    tables: u64, size: u64) -> protocol.Response {
    if !is_acpi(state, client) {
        return .Refused
    }
    region :: pci.firmware_table(tables, size, "FACP") or_return .Refused
    fadt :: acpi_tables.parse_fadt(view_of(cast[ptr[u8]](region.address), cast[usize](region.size))) or_return .Refused
    if fadt.pm1a_control == 0 {
        return .Refused
    }
    match slop_os.power_set_off(platform, cast[u32](fadt.pm1a_control), cast[u32](fadt.pm1b_control), cast[u32](types.a), cast[u32](types.b)) {
        case Ok => {
            log_line.write(to, "platform: the machine turns off with S5's sleep types % and %, by PM1 control port %", types.a, types.b,
                fadt.pm1a_control)
            return .Done
        }
        case Error(error) => {
            log_line.write(to, "platform: the kernel refused S5's sleep types: %", error)
            return .Refused
        }
    }
}
