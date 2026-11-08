/**
 * ACPI's static tables as the platform service and the ACPI service read them (decisions/0182, P3): the FADT's fixed
 * hardware, its PM1 and GPE blocks, the SCI and the reset register; and the definition blocks, the DSDT and the SSDTs,
 * found in the firmware tables' copy (slop_os.FirmwareTables). Only I/O port blocks are taken: a machine whose PM1 or
 * GPE blocks are memory-mapped, as a hardware-reduced one's are, has none here.
 */
//SPEC: ACPI 6.5, §5.2.9 (FADT), §5.2.3.2 (Generic Address Structure), §4.8.1 (PM1 and GPE blocks)
package acpi_tables

import slop_os from "std/os"

/** What the FADT says of the fixed hardware; a port of 0 is a block that isn't there. */
Fadt :: struct {
    /** The SCI's interrupt: an ISA IRQ, which the MADT may override to another GSI, or a GSI past 15. */
    sci : u16,
    /** The SMI command port that ACPI_ENABLE is written to, to enter ACPI mode; 0 for a machine always in it. */
    smi_command : u16,
    /** What's written to smi_command to enter ACPI mode. */
    acpi_enable : u8,
    /** PM1a's event block: its status register, then its enable register, each pm1_event_length / 2 bytes. */
    pm1a_event : u16,
    /** PM1b's event block, as PM1a's; 0 for none. */
    pm1b_event : u16,
    /** PM1a's control register's port, 2 bytes. */
    pm1a_control : u16,
    /** PM1b's control register's port; 0 for none. */
    pm1b_control : u16,
    /** The bytes of each PM1 event block: its status and enable registers, half each. */
    pm1_event_length : u8,
    /** GPE0's block: its status registers, then its enable registers, gpe0_length / 2 bytes each. */
    gpe0 : u16,
    /** GPE0's block's bytes. */
    gpe0_length : u8,
    /** GPE1's block, as GPE0's; 0 for none. */
    gpe1 : u16,
    /** GPE1's block's bytes. */
    gpe1_length : u8,
    /** The number of GPE1's first event. */
    gpe1_base : u8,
    /** The FADT's flags. */
    flags : u32,
    /** The reset register's port, when RESET_REG_SUP says it's there and it's an I/O port; 0 otherwise. */
    reset_port : u16,
    /** The byte written to reset_port to reset. */
    reset_value : u8,
}

/** The FADT's flag that the power button is a control method device, PNP0C0C, rather than a fixed event. */
POWER_BUTTON_IS_DEVICE : u32 : 1 << 4
/** The FADT's flag that the reset register is there. */
RESET_SUPPORTED : u32 : 1 << 10
/** The FADT's flag that it's hardware-reduced: no PM1 or GPE blocks, no SCI as these are. */
HARDWARE_REDUCED : u32 : 1 << 20
/** A Generic Address Structure's address space ID for system I/O. */
SPACE_SYSTEM_IO : u8 : 1

/**
 * Read the FADT's fixed hardware.
 *
 * Each block is its 32-bit field, or, where that's 0 and the FADT is long enough, its 64-bit Generic Address
 * Structure's, if that's in system I/O and below 65536.
 *
 * @param table The FADT, header and all.
 * @return What it says; null for one shorter than ACPI 1.0's 116 bytes.
 */
parse_fadt :: fn(table: u8[]) -> Fadt? {
    if table.count < 116 {
        return null
    }
    made := Fadt.{
        sci = cast[u16](little(table, 46, 2)), smi_command = cast[u16](little(table, 48, 4) & 0xffff), acpi_enable = cast[u8](little(table, 52, 1)),
        pm1a_event = block(table, 56, 148), pm1b_event = block(table, 60, 160), pm1a_control = block(table, 64, 172),
        pm1b_control = block(table, 68, 184), pm1_event_length = cast[u8](little(table, 88, 1)),
        gpe0 = block(table, 80, 220), gpe0_length = cast[u8](little(table, 92, 1)), gpe1 = block(table, 84, 232),
        gpe1_length = cast[u8](little(table, 93, 1)), gpe1_base = cast[u8](little(table, 94, 1)),
        flags = cast[u32](little(table, 112, 4)),
    }
    if made.flags & RESET_SUPPORTED != 0 && table.count >= 129 && little(table, 116, 1) == cast[u64](SPACE_SYSTEM_IO) {
        port :: little(table, 120, 8)
        if port != 0 && port <= 0xffff {
            made.reset_port = cast[u16](port)
            made.reset_value = cast[u8](little(table, 128, 1))
        }
    }
    return made
}

/**
 * A block's I/O port: its 32-bit field, or its Generic Address Structure's address if that's 0.
 *
 * @param table The FADT.
 * @param field The 32-bit field's offset.
 * @param extended The Generic Address Structure's offset.
 * @return The port; 0 for none, or one that isn't in system I/O or past 65535.
 */
block :: fn(table: u8[], field: u64, extended: u64) -> u16 {
    value :: little(table, field, 4)
    if value != 0 {
        return if value <= 0xffff { cast[u16](value) } else { 0 }
    }
    if extended + 12 > cast[u64](table.count) || little(table, extended, 1) != cast[u64](SPACE_SYSTEM_IO) {
        return 0
    }
    address :: little(table, extended + 4, 8)
    return if address <= 0xffff { cast[u16](address) } else { 0 }
}

/** The most I/O APICs and interrupt source overrides parse_madt keeps. */
MAX_MADT_ENTRIES :: 16

/** An I/O APIC, as the MADT gives it. */
IoApic :: struct {
    /** Its I/O APIC ID, which a DMAR's device scope names it by. */
    id : u8,
    /** Its registers' physical address. */
    address : u64,
    /** The first GSI its lines are. */
    gsi_base : u32,
}

/** An interrupt source override: an ISA IRQ routed to another GSI, or signaled otherwise than ISA's default. */
Override :: struct {
    /** The ISA IRQ. */
    source : u8,
    /** The GSI it's routed to. */
    gsi : u32,
    /** MPS INTI flags: polarity in bits 0 and 1, trigger mode in 2 and 3; 0 in either conforms to the bus. */
    flags : u16,
}

/** What the MADT says of the I/O APICs and how ISA IRQs reach them (ACPI 6.5 §5.2.12). */
Madt :: struct {
    /** The I/O APICs, the first io_apic_count of them. */
    io_apics : IoApic[MAX_MADT_ENTRIES],
    /** How many there are. */
    io_apic_count : usize,
    /** The overrides, the first override_count of them. */
    overrides : Override[MAX_MADT_ENTRIES],
    /** How many there are. */
    override_count : usize,
}

/**
 * Read the MADT's I/O APICs and interrupt source overrides; its other entries are passed over.
 *
 * @param table The MADT, header and all.
 * @return What it says, up to MAX_MADT_ENTRIES of each; null for one shorter than its header.
 */
parse_madt :: fn(table: u8[]) -> Madt? {
    if table.count < 44 {
        return null
    }
    made := Madt.{}
    at : u64 = 44
    total :: cast[u64](table.count)
    loop {
        if at + 2 > total {
            break
        }
        kind :: little(table, at, 1)
        length :: little(table, at + 1, 1)
        if length < 2 || at + length > total {
            break
        }
        if kind == 1 && length >= 12 && made.io_apic_count < made.io_apics.count {
            made.io_apics[made.io_apic_count] = IoApic.{id = cast[u8](little(table, at + 2, 1)), address = little(table, at + 4, 4),
                gsi_base = cast[u32](little(table, at + 8, 4))}
            made.io_apic_count += 1
        }
        if kind == 2 && length >= 10 && made.override_count < made.overrides.count {
            made.overrides[made.override_count] = Override.{source = cast[u8](little(table, at + 3, 1)),
                gsi = cast[u32](little(table, at + 4, 4)), flags = cast[u16](little(table, at + 8, 2))}
            made.override_count += 1
        }
        at += length
    }
    return made
}

/** How an interrupt signals: whether it's level-triggered, and whether it's active-low. */
Signaling :: struct {
    /** The GSI. */
    gsi : u32,
    /** Whether it's level-triggered; edge-triggered if not. */
    level : bool,
    /** Whether it's active-low; active-high if not. */
    low : bool,
}

/**
 * Where an ISA IRQ goes, and how it signals: an override's GSI and flags, or the same GSI, signaled as the bus's
 * default says where nothing overrides it.
 *
 * @param madt The MADT.
 * @param irq The ISA IRQ, or a GSI past 15.
 * @param level Whether it's level-triggered where nothing says: true for the SCI, false for ISA's.
 * @param low Whether it's active-low where nothing says: true for the SCI, false for ISA's.
 * @return The GSI and how it signals.
 */
route_isa :: fn(madt: ptr[Madt], irq: u32, level: bool, low: bool) -> Signaling {
    for override, i in madt.overrides {
        if i >= madt.override_count {
            break
        }
        if cast[u32](override.source) == irq && irq < 16 {
            polarity :: override.flags & 3
            trigger :: (override.flags >> 2) & 3
            return Signaling.{gsi = override.gsi, level = if trigger == 0 { level } else { trigger == 3 },
                low = if polarity == 0 { low } else { polarity == 3 }}
        }
    }
    return Signaling.{gsi = irq, level = level, low = low}
}

/**
 * Read a little-endian integer from a table.
 *
 * @param table The table.
 * @param offset Its first byte.
 * @param count Its bytes, 1 to 8.
 * @return The integer; bytes past the table read as 0.
 */
little :: fn(table: u8[], offset: u64, count: u64) -> u64 {
    value : u64 = 0
    for i in 0..<count {
        at :: offset + i
        if at < cast[u64](table.count) {
            index :: cast[usize](at)
            if index < table.count {
                value |= cast[u64](table[index]) << (8 * i)
            }
        }
    }
    return value
}

/**
 * Find the firmware tables' copy's entries.
 *
 * @param copy The copy, all of it.
 * @return Its entries; empty if it isn't one.
 */
entries_of :: fn(copy: u8[]) -> slop_os.FirmwareTable[] {
    header :: size_of(slop_os.FirmwareTables)
    none :: view_of(cast[ptr[slop_os.FirmwareTable]](null), 0)
    if copy.count <= header {
        return none
    }
    tables :: cast[ptr[slop_os.FirmwareTables]](&copy[0])
    if tables.magic != slop_os.FIRMWARE_MAGIC {
        return none
    }
    count :: cast[usize](tables.count)
    room :: (copy.count - header) / size_of(slop_os.FirmwareTable)
    return view_of(cast[ptr[slop_os.FirmwareTable]](&copy[header]), if count < room { count } else { room })
}

/**
 * A table in the copy, by its entry.
 *
 * @param copy The copy.
 * @param entry One of its entries.
 * @return The table's bytes, a view into copy; empty if the entry runs past it.
 */
table_of :: fn(copy: u8[], entry: ptr[slop_os.FirmwareTable]) -> u8[] {
    start :: entry.offset
    stop :: entry.offset + cast[u64](entry.size)
    if start > stop || stop > cast[u64](copy.count) {
        return copy[0..<0]
    }
    from :: cast[usize](start)
    to :: cast[usize](stop)
    if from > to || to > copy.count {
        return copy[0..<0]
    }
    return copy[from..<to]
}

/**
 * Tell whether an entry is a table of a signature.
 *
 * @param entry The entry.
 * @param signature Four characters, as "FACP".
 * @return True if they're its signature's.
 */
is_table :: fn(entry: ptr[slop_os.FirmwareTable], signature: string) -> bool {
    bytes :: string_bytes(signature)
    if bytes.count != 4 {
        return false
    }
    for byte, i in entry.signature {
        if i < bytes.count && byte != bytes[i] {
            return false
        }
    }
    return true
}

/**
 * Find the first table of a signature in the copy.
 *
 * @param copy The copy.
 * @param signature Four characters.
 * @return Its bytes, a view into copy; empty if there's none.
 */
first_table :: fn(copy: u8[], signature: string) -> u8[] {
    for &entry in entries_of(copy) {
        if is_table(entry, signature) {
            return table_of(copy, entry)
        }
    }
    return copy[0..<0]
}
