package platform

import slop_os from "std/os"
import log_line from "../../log_line"
import pci from "../../pci"

/*
 * How the machine resets, as ACPI's FADT says (decisions/0182): its reset register, when it's an I/O port, given to
 * the kernel, which otherwise resets x86-64 through 0xcf9. Turning it off needs `\_S5`, which is AML, so the ACPI
 * service gives that (P3). A devicetree machine says nothing here: the kernel finds PSCI itself.
 */
//SPEC: ACPI 6.5, §5.2.9 (FADT: Flags' RESET_REG_SUP, RESET_REG, RESET_VALUE), §5.2.3.2 (Generic Address Structure)

/** The byte offset of the FADT's Flags, a u32. */
FADT_FLAGS : u64 : 112
/** Flags' RESET_REG_SUP: the reset register's there and resets the machine. */
FLAGS_RESET_SUPPORTED : u32 : 1 << 10
/** The byte offset of the FADT's RESET_REG, a Generic Address Structure of 12 bytes. */
FADT_RESET_REGISTER : u64 : 116
/** The byte offset of the FADT's RESET_VALUE, a u8. */
FADT_RESET_VALUE : u64 : 128
/** The FADT's bytes up to and with RESET_VALUE: a shorter one, from ACPI before 2.0, has no reset register. */
FADT_WITH_RESET : u64 : 129
/** A Generic Address Structure's address space ID for system I/O. */
SPACE_SYSTEM_IO : u8 : 1

/**
 * Give the kernel the FADT's reset register, if it's there, supported, and an I/O port, logging what it gave.
 *
 * @param to Where the line saying so is written.
 * @param platform The platform capability, the call's authority.
 * @param tables Where the firmware tables' copy is mapped, readable.
 * @param size How many bytes of it there are.
 */
give_reset :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, tables: u64, size: u64) {
    fadt :: pci.firmware_table(tables, size, "FACP") or_return void
    if fadt.size < FADT_WITH_RESET {
        return void
    }
    if pci.read_u32(fadt.address, FADT_FLAGS) & FLAGS_RESET_SUPPORTED == 0 {
        return void
    }
    space :: cast[ptr[u8]](fadt.address + FADT_RESET_REGISTER)^
    port :: pci.read_u64(fadt.address + FADT_RESET_REGISTER + 4)
    value :: cast[ptr[u8]](fadt.address + FADT_RESET_VALUE)^
    if space != SPACE_SYSTEM_IO || port == 0 || port > 0xffff {
        return void
    }
    match slop_os.power_set_reset(platform, cast[u32](port), cast[u32](value)) {
        case Ok => log_line.write(to, "platform: the machine resets by writing % to port %", value, port)
        case Error(error) => log_line.write(to, "platform: the kernel refused the FADT's reset register: %", error)
    }
}
