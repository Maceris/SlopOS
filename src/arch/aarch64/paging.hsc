package arch_aarch64

import intrinsics from "base"
import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * Paging with 4 KiB pages and 48-bit addresses (arch_interface, Paging): four levels of 512-entry tables,
 * from the root (level 3 here, Arm's level 0) down to page tables (level 0 here, Arm's level 3), numbered
 * as x86-64's are so the walks read the same. Tables are reached through the direct map.
 *
 * The kernel's own table is TTBR1's, for the upper half, and every address space's is TTBR0's, for the
 * lower half, so address spaces share the kernel half without copying anything. Kernel mappings are
 * global and user ones carry their address space's ASID.
 *
 * Each table entry also counts the valid entries of the table it points to, in bits 2 to 11, which the
 * walk ignores in a table entry, so unmap knows when a table empties without reading all of it.
 */
//SPEC: Arm ARM (DDI 0487) D8.3 (translation table descriptor formats), D8.4 (attributes: AP, PXN, UXN, nG, AttrIndx, SH, AF), D8.16 (break-before-make), D19.2: TCR_EL1, MAIR_EL1, TTBR0_EL1, TTBR1_EL1; TLBI (C5.5)

ENTRIES :: 512
TOP_LEVEL : u64 : 3

ENTRY_VALID : u64 : 1 << 0
// At levels 1 to 3, a table rather than a block; at level 0, a page, as every valid entry there is.
ENTRY_TABLE : u64 : 1 << 1
ATTRIBUTE_SHIFT : u64 : 2
// AP[2:1]: EL0 can reach it (bit 6), and it's read-only (bit 7)
ENTRY_USER : u64 : 1 << 6
ENTRY_READ_ONLY : u64 : 1 << 7
ENTRY_INNER_SHAREABLE : u64 : 3 << 8
ENTRY_ACCESSED : u64 : 1 << 10
ENTRY_NOT_GLOBAL : u64 : 1 << 11
ENTRY_PRIVILEGED_EXECUTE_NEVER : u64 : 1 << 53
ENTRY_USER_EXECUTE_NEVER : u64 : 1 << 54
ENTRY_ATTRIBUTE : u64 : 7 << 2
// Where a table's or a page's address is in an entry. Blocks' addresses are aligned further.
ENTRY_ADDRESS : u64 : 0x0000fffffffff000
// The count of the next table's valid entries, in a table entry's bits 11:2.
COUNT_SHIFT : u64 : 2
COUNT_MASK : u64 : 0x3ff << 2

/*
 * MAIR_EL1's attributes, by index: write-back, as the bootloader's index 0 is; normal non-cacheable, for
 * write-combining; and Device-nGnRnE, for device registers.
 */
ATTRIBUTE_WRITE_BACK : u64 : 0
ATTRIBUTE_NON_CACHEABLE : u64 : 1
ATTRIBUTE_DEVICE : u64 : 2
MAIR_VALUE : u64 : 0x00_44_ff

// TCR_EL1: 16-bit ASIDs (AS), TTBR0's walks off (EPD0), and the ASID from TTBR0 (A1 clear).
TCR_ASID_16 : u64 : 1 << 36
TCR_TTBR0_WALKS_OFF : u64 : 1 << 7
TCR_ASID_FROM_TTBR1 : u64 : 1 << 22
// TCR_EL1.HA: the hardware sets a page's access flag as it's touched, rather than faulting (FEAT_HAFDBS)
TCR_HARDWARE_ACCESS : u64 : 1 << 39
TTBR_ASID_SHIFT : u64 : 48

// Physical addresses go up to 48 bits.
PHYSICAL_LIMIT : u64 : 1 << 48
// The kernel half: every address TTBR1 translates, with 48-bit addresses.
KERNEL_HALF_START : u64 : 0xffff000000000000
// As on x86-64: 64 KiB up to the last page below the lower half's end.
USER_LOW : u64 : 0x10000
USER_HIGH : u64 : 0x00007ffffffff000

// The kernel table's table frames for each device block L1 maps: at most one at level 2 and one at level 1.
TABLES_PER_DEVICE_BLOCK : u32 : 2
BLOCK_2M : u64 : 1 << 21
BLOCK_1G : u64 : 1 << 30

// One page-table level's 512 entries.
Table :: struct {
    entries : u64[ENTRIES],
}

#assert size_of(Table) == 4096

// One address space's page tables (arch_interface.PageTable).
PageTable :: struct {
    root : arch_interface.PhysicalAddress,
    tag : arch_interface.AddressSpaceTag,
    // The kernel's own table, TTBR1's, which maps the kernel half and nothing else.
    kernel : bool,
    // Where physical address 0 is in the direct map, through which the tables are reached.
    direct_map_offset : u64,
}

user_address_range :: fn() -> (low, high: arch_interface.VirtualAddress) {
    return cast[arch_interface.VirtualAddress](USER_LOW), cast[arch_interface.VirtualAddress](USER_HIGH)
}

// ASIDs: 16 bits where the CPU has them, which init_cpu turns on, otherwise 8.
address_space_tag_count :: fn() -> u32 {
    return if aarch64.read_system_register(.TCR_EL1) & TCR_ASID_16 != 0 { 65536 } else { 256 }
}

// 4 KiB pages, and 2 MiB and 1 GiB blocks, which every CPU with 4 KiB pages has.
supports_page_size :: fn(size: arch_interface.PageSize) -> bool {
    return true
}

// The kernel half has TTBR1's root to itself; these are for the device blocks L1 maps for itself.
kernel_half_frames :: fn() -> u32 {
    return TABLES_PER_DEVICE_BLOCK * current_system().device_block_count
}

/*
 * The kernel's own table: root, a zeroed frame, mapping the device registers L1 uses (the console's and the
 * GIC's) where the bootloader's tables had them, at the direct map's address for them, with tables from the
 * kernel_half_frames() zeroed frames at half.
 */
init_kernel_page_table :: fn(
    table: ptr[mut PageTable],
    root: arch_interface.PhysicalAddress,
    half: arch_interface.PhysicalAddress,
    tag: arch_interface.AddressSpaceTag,
    direct_map_offset: u64,
) {
    table.root = root
    table.tag = tag
    table.kernel = true
    table.direct_map_offset = direct_map_offset
    system :: current_system()
    next := cast[u64](half)
    for block, i in system.device_blocks {
        if i >= cast[usize](system.device_block_count) {
            break
        }
        tables := arch_interface.TableFrames.{count = TABLES_PER_DEVICE_BLOCK}
        tables.frames[0] = cast[arch_interface.PhysicalAddress](next)
        tables.frames[1] = cast[arch_interface.PhysicalAddress](next + 4096)
        next += cast[u64](TABLES_PER_DEVICE_BLOCK) * 4096
        // A block another one's tables already cover leaves its own frames unused, zeroed
        _ = map(table, cast[arch_interface.VirtualAddress](direct_map_offset + block), cast[arch_interface.PhysicalAddress](block),
            .Size2M, DEVICE_MAPPING, &tables)
    }
}

// Kernel device registers: readable and writable, uncached, global.
DEVICE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = true}

// Keep a 2 MiB block of device registers, by physical address, for the kernel's own table.
add_device_block :: fn(system: ptr[mut ArchSystem], physical: u64) {
    block :: physical & ~(BLOCK_2M - 1)
    count :: cast[usize](system.device_block_count)
    for kept, i in system.device_blocks {
        if i < count && kept == block {
            return void
        }
    }
    runtime.assert(count < MAX_DEVICE_BLOCKS, "room for L1's device blocks")
    if count < MAX_DEVICE_BLOCKS {
        system.device_blocks[count] = block
        system.device_block_count += 1
    }
}

/*
 * Map device registers from physical, size bytes of them, through the direct map: in the bootloader's tables
 * now, and in the kernel's own once it's made. False if some block of them couldn't be.
 */
map_device_range :: fn(system: ptr[mut ArchSystem], physical: u64, size: u64) -> bool {
    block := physical & ~(BLOCK_2M - 1)
    loop {
        if !map_early_device(system.direct_map_offset, block) {
            return false
        }
        add_device_block(system, block)
        block += BLOCK_2M
    }
    while block < physical + size
    return true
}

// An address space whose root is a zeroed frame. The kernel half is TTBR1's, so there's nothing to share.
init_page_table :: fn(
    table: ptr[mut PageTable],
    root: arch_interface.PhysicalAddress,
    tag: arch_interface.AddressSpaceTag,
    kernel: ptr[PageTable],
) {
    table.root = root
    table.tag = tag
    table.kernel = false
    table.direct_map_offset = kernel.direct_map_offset
}

map :: fn(
    table: ptr[mut PageTable],
    virtual_address: arch_interface.VirtualAddress,
    physical_address: arch_interface.PhysicalAddress,
    size: arch_interface.PageSize,
    mapping: arch_interface.Mapping,
    tables: ptr[mut arch_interface.TableFrames],
) -> Result[void, arch_interface.MapError] {
    address :: cast[u64](virtual_address)
    physical :: cast[u64](physical_address)
    bytes :: page_bytes(size)
    leaf :: leaf_level(size)
    if address % bytes != 0 || physical % bytes != 0 || physical >= PHYSICAL_LIMIT || !may_map(table, address, bytes, mapping.user) {
        return .Error(.InvalidAddress)
    }

    // Check first, so a call that fails changes nothing: the tables the walk lacks, or what's in the way
    missing : u64 = 0
    current := table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        entry :: slot_at(current, address, level)^
        if entry & ENTRY_VALID == 0 {
            missing = level - leaf
            break
        }
        if level == leaf || is_block(entry, level) {
            return .Error(.AlreadyMapped)
        }
        current = table_at(table, entry & ENTRY_ADDRESS)
    }
    if missing > cast[u64](tables.count) {
        return .Error(.NeedTableFrames)
    }

    // The address of the entry pointing at current, counting its valid entries; 0 for the root
    counted : u64 = 0
    current = table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        if level == leaf {
            store_entry(slot, leaf_entry(physical, mapping, leaf))
            add_to_count(counted, 1)
            break
        }
        if slot^ & ENTRY_VALID == 0 {
            store_entry(slot, take_table(tables) | ENTRY_VALID | ENTRY_TABLE)
            add_to_count(counted, 1)
        }
        counted = cast[u64](slot)
        current = table_at(table, slot^ & ENTRY_ADDRESS)
    }
    // An invalid entry is never cached, so the new one only has to be visible to the walk
    aarch64.dsb(.ISHST)
    aarch64.isb()
    return .Ok
}

// Unmap one page, returning its physical address. Tables it empties go in freed.
unmap :: fn(
    table: ptr[mut PageTable],
    virtual_address: arch_interface.VirtualAddress,
    size: arch_interface.PageSize,
    freed: ptr[mut arch_interface.FreedTables],
    flush: ptr[mut arch_interface.TlbBatch],
) -> Result[arch_interface.PhysicalAddress, arch_interface.UnmapError] {
    address :: cast[u64](virtual_address)
    leaf :: leaf_level(size)
    path :: walk(table, address, leaf)?
    physical :: page_address(load_entry(path.leaf_slot), leaf)

    // Each table that empties, from the leaf's up, until one keeps an entry. The root, and the kernel's
    // tables right below its root, stay.
    emptied : u64 = 0
    for level in leaf..<TOP_LEVEL {
        if level + 1 == TOP_LEVEL && table.kernel {
            break
        }
        if count_of(load_entry(path.slots[level + 1])) != 1 {
            break
        }
        emptied += 1
    }
    room :: cast[u64](freed.count)
    runtime.assert(room <= 4, "FreedTables holds 4 frames")
    if emptied > 4 - room {
        return .Error(.NeedFreedSpace)
    }

    store_entry(cast[ptr[mut u64]](path.leaf_slot), 0)
    for level in leaf + 1..=TOP_LEVEL {
        parent :: path.slots[level]
        if level - leaf <= emptied {
            // The table this entry points at emptied
            add_freed(freed, load_entry(parent) & ENTRY_ADDRESS)
            store_entry(cast[ptr[mut u64]](parent), 0)
        }
        else {
            add_to_count(cast[u64](parent), cast[u64](0) - 1)
            break
        }
    }
    aarch64.dsb(.ISHST)
    add_flush(flush, table.tag, address)
    return .Ok(cast[arch_interface.PhysicalAddress](physical))
}

/*
 * A new protection for a page. Permissions change in place; a different memory type needs break-before-make:
 * the entry cleared and flushed everywhere before the new one is written.
 */
protect :: fn(
    table: ptr[mut PageTable],
    virtual_address: arch_interface.VirtualAddress,
    size: arch_interface.PageSize,
    mapping: arch_interface.Mapping,
    flush: ptr[mut arch_interface.TlbBatch],
) -> Result[void, arch_interface.UnmapError] {
    address :: cast[u64](virtual_address)
    leaf :: leaf_level(size)
    if !may_map(table, address, page_bytes(size), mapping.user) {
        return .Error(.NotMapped)
    }
    path :: walk(table, address, leaf)?
    slot :: cast[ptr[mut u64]](path.leaf_slot)
    old :: load_entry(path.leaf_slot)
    new :: leaf_entry(page_address(old, leaf), mapping, leaf)
    if old & ENTRY_ATTRIBUTE != new & ENTRY_ATTRIBUTE {
        store_entry(slot, 0)
        aarch64.dsb(.ISHST)
        invalidate_everywhere(table, address)
    }
    store_entry(slot, new)
    aarch64.dsb(.ISHST)
    add_flush(flush, table.tag, address)
    return .Ok
}

translate :: fn(table: ptr[PageTable], virtual_address: arch_interface.VirtualAddress) -> arch_interface.Translation? {
    address :: cast[u64](virtual_address)
    current := table_at(table, cast[u64](table.root))
    for level in 0..=TOP_LEVEL #reverse {
        entry :: slot_at(current, address, level)^
        if entry & ENTRY_VALID == 0 {
            return null
        }
        if level == 0 || is_block(entry, level) {
            offset :: address & ((cast[u64](1) << (12 + 9 * level)) - 1)
            return arch_interface.Translation.{
                physical_address = cast[arch_interface.PhysicalAddress](page_address(entry, level) + offset),
                mapping = mapping_of(entry),
            }
        }
        current = table_at(table, entry & ENTRY_ADDRESS)
    }
    return null
}

/*
 * An address space's tables, freed into freed, as many as it has room for: true once none are left but
 * the root. What they mapped isn't touched. Each call frees tables with none below them, so it can stop
 * anywhere and go on.
 */
release_user_tables :: fn(table: ptr[mut PageTable], freed: ptr[mut arch_interface.FreedTables]) -> bool {
    runtime.assert(!table.kernel, "the kernel's own tables stay")
    top :: table_at(table, cast[u64](table.root))
    loop {
        slot := cast[u64](0)
        for i in 0..<ENTRIES {
            entry :: top.entries[i]
            if entry & ENTRY_VALID != 0 {
                below :: lowest_table_slot(table, table_at(table, entry & ENTRY_ADDRESS), TOP_LEVEL - 1)
                slot = if below != 0 { below } else { cast[u64](&top.entries[i]) }
                break
            }
        }
        if slot == 0 {
            return true
        }
        add_freed(freed, load_entry(slot) & ENTRY_ADDRESS)
        store_entry(cast[ptr[mut u64]](slot), 0)
    }
    while cast[usize](freed.count) < 4
    return false
}

/*
 * In current, a table at level, the entry of a table under it with no tables under it in turn, or 0 if
 * current points at no tables.
 */
lowest_table_slot :: fn(table: ptr[PageTable], current: ptr[mut Table], level: u64) -> u64 {
    if level == 0 {
        return 0
    }
    for i in 0..<ENTRIES {
        entry :: current.entries[i]
        if entry & ENTRY_VALID != 0 && !is_block(entry, level) {
            below :: lowest_table_slot(table, table_at(table, entry & ENTRY_ADDRESS), level - 1)
            return if below != 0 { below } else { cast[u64](&current.entries[i]) }
        }
    }
    return 0
}

/*
 * Switch the calling CPU to table: the kernel's goes in TTBR1, with TTBR0's walks off, and an address
 * space's in TTBR0 with its ASID. ASIDs keep each address space's entries apart, so nothing is flushed; the
 * first switch from the bootloader's tables flushes everything.
 */
activate :: fn(table: ptr[PageTable]) {
    cpu :: current_cpu()
    control :: aarch64.read_system_register(.TCR_EL1)
    if table.kernel {
        aarch64.write_system_register(.TTBR1_EL1, cast[u64](table.root))
        aarch64.write_system_register(.TCR_EL1, control | TCR_TTBR0_WALKS_OFF)
    }
    else {
        aarch64.write_system_register(.TTBR0_EL1, cast[u64](table.root) | (cast[u64](table.tag) << TTBR_ASID_SHIFT))
        aarch64.write_system_register(.TCR_EL1, control & ~TCR_TTBR0_WALKS_OFF)
    }
    aarch64.isb()
    if cpu.bootloader_tables {
        cpu.bootloader_tables = false
        flush_everything()
    }
}

/*
 * Flush batch from the calling CPU's TLB, by address and ASID, whichever address space is active. The
 * kernel's entries are global, so they're flushed for every ASID.
 */
flush_tlb :: fn(batch: ptr[arch_interface.TlbBatch]) {
    tag :: cast[u64](batch.tag) << TTBR_ASID_SHIFT
    user :: batch.count > 0 && cast[u64](batch.addresses[0]) < KERNEL_HALF_START
    aarch64.dsb(.ISHST)
    if batch.all {
        // An address space's ASID, or everything when it may be the kernel's, whose entries are global
        if user {
            aarch64.tlbi_aside1(tag)
        }
        else {
            aarch64.tlbi_vmalle1()
        }
    }
    else {
        count :: cast[usize](batch.count)
        runtime.assert(count <= 16, "a TlbBatch holds 16 addresses")
        for i in 0..<count {
            page :: (cast[u64](batch.addresses[i]) >> 12) & 0x0000_0fff_ffff_ffff
            if cast[u64](batch.addresses[i]) >= KERNEL_HALF_START {
                aarch64.tlbi_vaae1(page)
            }
            else {
                aarch64.tlbi_vae1(page | tag)
            }
        }
    }
    aarch64.dsb(.NSH)
    aarch64.isb()
}

// Flush every entry for tag, before the tag is reused.
flush_tlb_tag :: fn(tag: arch_interface.AddressSpaceTag) {
    aarch64.dsb(.ISHST)
    aarch64.tlbi_aside1(cast[u64](tag) << TTBR_ASID_SHIFT)
    aarch64.dsb(.NSH)
    aarch64.isb()
}

// Every TLB entry of the calling CPU's.
flush_everything :: fn() {
    aarch64.dsb(.ISHST)
    aarch64.tlbi_vmalle1()
    aarch64.dsb(.NSH)
    aarch64.isb()
}

// One page's entries on every CPU, for break-before-make, before its new entry is written.
invalidate_everywhere :: fn(table: ptr[PageTable], address: u64) {
    page :: (address >> 12) & 0x0000_0fff_ffff_ffff
    if table.kernel {
        aarch64.tlbi_vaae1is(page)
    }
    else {
        aarch64.tlbi_vae1is(page | (cast[u64](table.tag) << TTBR_ASID_SHIFT))
    }
    aarch64.dsb(.ISH)
    aarch64.isb()
}

/*
 * The paging state init_cpu sets: the memory attributes, 16-bit ASIDs where the CPU has them, taken from TTBR0, and
 * the access flag kept by the hardware where it can, with TTBR0's walks off until an address space is activated. The
 * bootloader's TCR_EL1 is kept otherwise: 48-bit halves, 4 KiB granules, walks cached and inner shareable, and the
 * CPU's physical address size.
 */
init_paging :: fn(system: ptr[ArchSystem]) {
    aarch64.write_system_register(.MAIR_EL1, MAIR_VALUE)
    control := aarch64.read_system_register(.TCR_EL1) & ~TCR_ASID_FROM_TTBR1
    control |= TCR_TTBR0_WALKS_OFF
    if system.asid16 {
        control |= TCR_ASID_16
    }
    if system.hardware_access_flag {
        control |= TCR_HARDWARE_ACCESS
    }
    aarch64.write_system_register(.TCR_EL1, control)
    aarch64.isb()
    flush_everything()
}

/*
 * Map device registers in the bootloader's tables, at direct_map_offset plus physical, as a Device block in
 * the first gap the walk down to it finds: 1 GiB, 2 MiB or a page. True if they're mapped so already; false if
 * it can't, with no table where one is needed, or something else mapped there.
 */
map_early_device :: fn(direct_map_offset: u64, physical: u64) -> bool {
    // Index 2 of MAIR_EL1, which the bootloader leaves unused, as Device-nGnRnE until init_cpu sets all of it
    aarch64.write_system_register(.MAIR_EL1, aarch64.read_system_register(.MAIR_EL1) & ~(cast[u64](0xff) << 16))
    address :: direct_map_offset + physical
    current := cast[ptr[mut Table]](direct_map_offset + (aarch64.read_system_register(.TTBR1_EL1) & ENTRY_ADDRESS))
    for level in 0..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        entry :: slot^
        if entry & ENTRY_VALID == 0 {
            if level == TOP_LEVEL {
                return false
            }
            bytes :: cast[u64](1) << (12 + 9 * level)
            // The direct map at a boundary of the block's size, so the block maps what's at its address there
            if direct_map_offset % bytes != 0 {
                return false
            }
            kind :: if level == 0 { ENTRY_TABLE } else { cast[u64](0) }
            store_entry(slot, device_block(physical & ~(bytes - 1)) | kind)
            aarch64.dsb(.ISHST)
            aarch64.isb()
            return true
        }
        if level == 0 || is_block(entry, level) {
            // Mapped already, which is fine if it's as a device block over the same registers
            device :: (entry & ENTRY_ATTRIBUTE) >> ATTRIBUTE_SHIFT == ATTRIBUTE_DEVICE
            return device && page_address(entry, level) == physical & ~((cast[u64](1) << (12 + 9 * level)) - 1)
        }
        current = cast[ptr[mut Table]](direct_map_offset + (entry & ENTRY_ADDRESS))
    }
    return false
}

// A Device block or page for the kernel, global, never executed.
device_block :: fn(physical: u64) -> u64 {
    return physical | ENTRY_VALID | (ATTRIBUTE_DEVICE << ATTRIBUTE_SHIFT) | ENTRY_ACCESSED
        | ENTRY_PRIVILEGED_EXECUTE_NEVER | ENTRY_USER_EXECUTE_NEVER
}

// Which entries walk passed through, by level, as addresses in the direct map.
Path :: struct {
    slots : u64[4],
    // slots[leaf], the leaf's entry.
    leaf_slot : u64,
}

// The entries from the root down to a page of the leaf level's size mapped at address.
walk :: fn(table: ptr[PageTable], address: u64, leaf: u64) -> Result[Path, arch_interface.UnmapError] {
    path : Path
    current := table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        path.slots[level] = cast[u64](slot)
        entry :: slot^
        if entry & ENTRY_VALID == 0 {
            return .Error(.NotMapped)
        }
        block :: is_block(entry, level)
        if level == leaf {
            // A table where a block should be: nothing of that size is mapped there
            if leaf > 0 && !block {
                return .Error(.NotMapped)
            }
            path.leaf_slot = cast[u64](slot)
            break
        }
        if block {
            return .Error(.PartOfLargerPage)
        }
        current = table_at(table, entry & ENTRY_ADDRESS)
    }
    return .Ok(path)
}

/*
 * Whether the 4 KiB page at virtual_address was touched since its access flag was last cleared, the flag cleared: where
 * the hardware sets it (TCR_EL1.HA), and false everywhere else, since every page is mapped with the flag set, which
 * clearing would turn into faults.
 */
take_accessed :: fn(table: ptr[mut PageTable], virtual_address: arch_interface.VirtualAddress) -> bool {
    if aarch64.read_system_register(.TCR_EL1) & TCR_HARDWARE_ACCESS == 0 {
        return false
    }
    path :: match walk(table, cast[u64](virtual_address), 0) {
        case Ok(found) => found
        case Error(error) => return false
    }
    old :: intrinsics.interlocked_and_u64(cast[ptr[mut u64]](path.leaf_slot), ~ENTRY_ACCESSED)
    return old & ENTRY_ACCESSED != 0
}

// Whether a valid entry at level maps a block rather than pointing at a table. Level 0's are pages.
is_block :: fn(entry: u64, level: u64) -> bool {
    return level > 0 && entry & ENTRY_TABLE == 0
}

// Whether table may map bytes at address: user addresses in an address space, kernel ones in the kernel's.
may_map :: fn(table: ptr[PageTable], address: u64, bytes: u64, user: bool) -> bool {
    if user {
        return !table.kernel && address >= USER_LOW && address < USER_HIGH && bytes <= USER_HIGH - address
    }
    return table.kernel && address >= KERNEL_HALF_START
}

/*
 * A page or block: user ones only reachable from EL0 and never executed by the kernel, kernel ones never
 * executed by user mode, and only kernel ones global.
 */
leaf_entry :: fn(physical: u64, mapping: arch_interface.Mapping, level: u64) -> u64 {
    entry := physical | ENTRY_VALID | ENTRY_ACCESSED | (attribute_of(mapping.cache) << ATTRIBUTE_SHIFT)
    if mapping.cache != .Device {
        entry |= ENTRY_INNER_SHAREABLE
    }
    if level == 0 {
        entry |= ENTRY_TABLE
    }
    if mapping.protection == .Read {
        entry |= ENTRY_READ_ONLY
    }
    executable :: mapping.protection == .ReadExecute
    if executable {
        entry |= ENTRY_READ_ONLY
    }
    if mapping.user {
        entry |= ENTRY_USER | ENTRY_NOT_GLOBAL | ENTRY_PRIVILEGED_EXECUTE_NEVER
        if !executable {
            entry |= ENTRY_USER_EXECUTE_NEVER
        }
    }
    else {
        entry |= ENTRY_USER_EXECUTE_NEVER
        if !executable {
            entry |= ENTRY_PRIVILEGED_EXECUTE_NEVER
        }
    }
    return entry
}

attribute_of :: fn(cache: arch_interface.CacheMode) -> u64 {
    return match cache {
        case .WriteBack => ATTRIBUTE_WRITE_BACK
        case .WriteCombining => ATTRIBUTE_NON_CACHEABLE
        case .Device => ATTRIBUTE_DEVICE
    }
}

mapping_of :: fn(entry: u64) -> arch_interface.Mapping {
    mapping : arch_interface.Mapping
    mapping.user = entry & ENTRY_USER != 0
    never :: if mapping.user { ENTRY_USER_EXECUTE_NEVER } else { ENTRY_PRIVILEGED_EXECUTE_NEVER }
    mapping.protection = if entry & ENTRY_READ_ONLY == 0 { .ReadWrite } else if entry & never != 0 { .Read } else { .ReadExecute }
    attribute :: (entry & ENTRY_ATTRIBUTE) >> ATTRIBUTE_SHIFT
    mapping.cache = if attribute == ATTRIBUTE_WRITE_BACK { .WriteBack } else if attribute == ATTRIBUTE_NON_CACHEABLE { .WriteCombining } else { .Device }
    mapping.global = entry & ENTRY_NOT_GLOBAL == 0
    return mapping
}

// The physical address a leaf entry at level maps.
page_address :: fn(entry: u64, level: u64) -> u64 {
    return entry & ENTRY_ADDRESS & ~((cast[u64](1) << (12 + 9 * level)) - 1)
}

page_bytes :: fn(size: arch_interface.PageSize) -> u64 {
    return cast[u64](1) << (12 + 9 * leaf_level(size))
}

// The level whose entries map pages of size.
leaf_level :: fn(size: arch_interface.PageSize) -> u64 {
    return match size {
        case .Size4K => cast[u64](0)
        case .Size2M => cast[u64](1)
        case .Size1G => cast[u64](2)
    }
}

// The entry for address in current, a table at level.
slot_at :: fn(current: ptr[mut Table], address: u64, level: u64) -> ptr[mut u64] {
    return &current.entries[(address >> (12 + 9 * level)) % ENTRIES]
}

table_at :: fn(table: ptr[PageTable], physical: u64) -> ptr[mut Table] {
    return cast[ptr[mut Table]](table.direct_map_offset + physical)
}

count_of :: fn(entry: u64) -> u64 {
    return (entry & COUNT_MASK) >> COUNT_SHIFT
}

// Change the count in the entry at slot by change, unless slot is 0, the root's place.
add_to_count :: fn(slot: u64, change: u64) {
    if slot == 0 {
        return void
    }
    entry :: load_entry(slot)
    count :: (count_of(entry) + change) & (COUNT_MASK >> COUNT_SHIFT)
    store_entry(cast[ptr[mut u64]](slot), (entry & ~COUNT_MASK) | (count << COUNT_SHIFT))
}

load_entry :: fn(slot: u64) -> u64 {
    return cast[ptr[u64]](slot)^
}

/*
 * Entries are written whole and in order, so another CPU walking the tables sees a new table only after
 * its zeroed contents.
 */
store_entry :: fn(slot: ptr[mut u64], entry: u64) {
    intrinsics.atomic_store_u64_release(slot, entry)
}

// The last of tables' frames, taken off it.
take_table :: fn(tables: ptr[mut arch_interface.TableFrames]) -> u64 {
    count :: cast[usize](tables.count)
    runtime.assert(count >= 1 && count <= 4, "map takes a frame only when one is left")
    tables.count = cast[u32](count - 1)
    return cast[u64](tables.frames[count - 1])
}

add_freed :: fn(freed: ptr[mut arch_interface.FreedTables], frame: u64) {
    count :: cast[usize](freed.count)
    runtime.assert(count < 4, "unmap checks there's room before freeing a table")
    freed.frames[count] = cast[arch_interface.PhysicalAddress](frame)
    freed.count = cast[u32](count + 1)
}

add_flush :: fn(flush: ptr[mut arch_interface.TlbBatch], tag: arch_interface.AddressSpaceTag, address: u64) {
    flush.tag = tag
    count :: cast[usize](flush.count)
    if flush.all || count >= 16 {
        flush.all = true
        return void
    }
    flush.addresses[count] = cast[arch_interface.VirtualAddress](address)
    flush.count = cast[u32](count + 1)
}
