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

/** How many entries a table has: 512, of 8 bytes each, so a table is one 4 KiB frame. */
ENTRIES :: 512
/** The root's level, in this file's numbering (Arm's level 0). */
TOP_LEVEL : u64 : 3

/** A descriptor's valid bit (bit 0). */
ENTRY_VALID : u64 : 1 << 0
// At levels 1 to 3, a table rather than a block; at level 0, a page, as every valid entry there is.
/** A descriptor's bit 1: at levels 1 to 3, a table rather than a block; at level 0, a page, as every valid one is. */
ENTRY_TABLE : u64 : 1 << 1
/** Where AttrIndx, the MAIR_EL1 index, starts in a page or block descriptor (bits 2 to 4). */
ATTRIBUTE_SHIFT : u64 : 2
// AP[2:1]: EL0 can reach it (bit 6), and it's read-only (bit 7)
/** AP[1] (bit 6): EL0 can reach the page. */
ENTRY_USER : u64 : 1 << 6
/** AP[2] (bit 7): the page is read-only, at every level of privilege that can reach it. */
ENTRY_READ_ONLY : u64 : 1 << 7
/** SH (bits 8 and 9) set to 0b11: inner shareable. */
ENTRY_INNER_SHAREABLE : u64 : 3 << 8
/** AF (bit 10): the access flag, set so the first access doesn't fault. */
ENTRY_ACCESSED : u64 : 1 << 10
/** nG (bit 11): not global, so the TLB tags the entry with the ASID. */
ENTRY_NOT_GLOBAL : u64 : 1 << 11
/** PXN (bit 53): EL1 never executes the page. */
ENTRY_PRIVILEGED_EXECUTE_NEVER : u64 : 1 << 53
/** UXN (bit 54): EL0 never executes the page. */
ENTRY_USER_EXECUTE_NEVER : u64 : 1 << 54
/** AttrIndx (bits 2 to 4) in a page or block descriptor: which of MAIR_EL1's attributes the memory has. */
ENTRY_ATTRIBUTE : u64 : 7 << 2
/** Where a table's or a page's physical address is in an entry, bits 12 to 47; blocks' are aligned further. */
ENTRY_ADDRESS : u64 : 0x0000fffffffff000
// The count of the next table's valid entries, in a table entry's bits 11:2.
/** Where the count of the next table's valid entries starts in a table entry. */
COUNT_SHIFT : u64 : 2
/** The count's bits in a table entry, 2 to 11, which the walk ignores there; counts reach 512 at most. */
COUNT_MASK : u64 : 0x3ff << 2

/*
 * MAIR_EL1's attributes, by index: write-back, as the bootloader's index 0 is; normal non-cacheable, for
 * write-combining; and Device-nGnRnE, for device registers.
 */
/** MAIR_EL1 index 0: normal memory, write-back, read- and write-allocate (0xff), as the bootloader's index 0 is. */
ATTRIBUTE_WRITE_BACK : u64 : 0
/** MAIR_EL1 index 1: normal memory, non-cacheable (0x44), for write-combining. */
ATTRIBUTE_NON_CACHEABLE : u64 : 1
/** MAIR_EL1 index 2: Device-nGnRnE (0x00), for device registers. */
ATTRIBUTE_DEVICE : u64 : 2
/** MAIR_EL1's value: attribute 0 is 0xff, 1 is 0x44, 2 is 0x00, and the rest 0x00. */
MAIR_VALUE : u64 : 0x00_44_ff

// TCR_EL1: 16-bit ASIDs (AS), TTBR0's walks off (EPD0), and the ASID from TTBR0 (A1 clear).
/** TCR_EL1.AS (bit 36): 16-bit ASIDs. */
TCR_ASID_16 : u64 : 1 << 36
/** TCR_EL1.EPD0 (bit 7): no walks through TTBR0, so a lower-half miss faults. */
TCR_TTBR0_WALKS_OFF : u64 : 1 << 7
/** TCR_EL1.A1 (bit 22): the ASID comes from TTBR1; kept clear, so it comes from TTBR0. */
TCR_ASID_FROM_TTBR1 : u64 : 1 << 22
// TCR_EL1.HA: the hardware sets a page's access flag as it's touched, rather than faulting (FEAT_HAFDBS)
/** TCR_EL1.HA (bit 39): the hardware sets a page's access flag as it's touched, rather than faulting (FEAT_HAFDBS). */
TCR_HARDWARE_ACCESS : u64 : 1 << 39
/** Where the ASID is in TTBR0_EL1, and in a TLBI operand: bits 48 to 63. */
TTBR_ASID_SHIFT : u64 : 48

/** One past the highest physical address map takes: physical addresses go up to 48 bits. */
PHYSICAL_LIMIT : u64 : 1 << 48
/** The kernel half's lowest address: every address from it up is TTBR1's, with 48-bit addresses. */
KERNEL_HALF_START : u64 : 0xffff000000000000
// As on x86-64: 64 KiB up to the last page below the lower half's end.
/** The lowest user address: 64 KiB, as on x86-64, so a null pointer and small offsets from it fault. */
USER_LOW : u64 : 0x10000
/** One past the highest user address: 2^47 less a page, as on x86-64, though TTBR0's half goes up to 2^48. */
USER_HIGH : u64 : 0x00007ffffffff000

// The kernel table's table frames for each device block L1 maps: at most one at level 2 and one at level 1.
/** The kernel table's table frames for each device block L1 maps: at most one at level 2 and one at level 1. */
TABLES_PER_DEVICE_BLOCK : u32 : 2
/** A 2 MiB block's size in bytes, a level 1 entry's. */
BLOCK_2M : u64 : 1 << 21
/** A 1 GiB block's size in bytes, a level 2 entry's. */
BLOCK_1G : u64 : 1 << 30

/** One page-table level's 512 entries, one 4 KiB frame. */
Table :: struct {
    /** The descriptors, indexed by the address's 9 bits for this level. */
    entries : u64[ENTRIES],
}

#assert size_of(Table) == 4096

/** One address space's page tables (arch_interface.PageTable). */
PageTable :: struct {
    /** The root table's physical address, a 4 KiB frame, which goes in TTBR0_EL1 or TTBR1_EL1. */
    root : arch_interface.PhysicalAddress,
    /** The address space's ASID; unused for the kernel's own, whose mappings are global. */
    tag : arch_interface.AddressSpaceTag,
    /** Whether this is the kernel's own table, TTBR1's, which maps the kernel half and nothing else. */
    kernel : bool,
    /** Where physical address 0 is in the direct map, through which the tables are reached. */
    direct_map_offset : u64,
}

/**
 * Give the user-mode address range (arch_interface.user_address_range).
 *
 * @return low USER_LOW, 64 KiB, the lowest user address.
 * @return high USER_HIGH, one past the highest: 2^47 less a page, as on x86-64.
 */
user_address_range :: fn() -> (low, high: arch_interface.VirtualAddress) {
    return cast[arch_interface.VirtualAddress](USER_LOW), cast[arch_interface.VirtualAddress](USER_HIGH)
}

/**
 * Give how many ASIDs the calling CPU has (arch_interface.address_space_tag_count), as TCR_EL1 is set.
 *
 * @return 65536 with 16-bit ASIDs, which init_cpu turns on where the CPU has them; otherwise 256.
 */
address_space_tag_count :: fn() -> u32 {
    return if aarch64.read_system_register(.TCR_EL1) & TCR_ASID_16 != 0 { 65536 } else { 256 }
}

/**
 * Tell whether the CPU supports a page size (arch_interface.supports_page_size).
 *
 * @param size The page size asked about.
 * @return True for each: 4 KiB pages, and 2 MiB and 1 GiB blocks, which every CPU with 4 KiB pages has.
 */
supports_page_size :: fn(size: arch_interface.PageSize) -> bool {
    return true
}

/**
 * Give how many zeroed frames init_kernel_page_table needs besides its root (arch_interface.kernel_half_frames).
 *
 * The kernel half has TTBR1's root to itself, so none are needed to share it; these are for the device blocks L1
 * maps for itself.
 *
 * @return TABLES_PER_DEVICE_BLOCK for each device block init_system kept.
 */
kernel_half_frames :: fn() -> u32 {
    return TABLES_PER_DEVICE_BLOCK * current_system().device_block_count
}

/**
 * Make the kernel's own table (arch_interface.init_kernel_page_table), mapping the device registers L1 uses (the
 * console's and the GIC's) as the bootloader's tables had them, at the direct map's address for them, as 2 MiB
 * Device blocks.
 *
 * @param table The table to fill; it maps the kernel half and nothing else.
 * @param root A zeroed 4 KiB frame, the root.
 * @param half The first of kernel_half_frames() contiguous zeroed frames, used two to each device block; a block
 *     another one's tables already cover leaves its frames unused, still zeroed.
 * @param tag The kernel's address-space tag, kept but unused, since kernel mappings are global.
 * @param direct_map_offset Where physical address 0 is in the direct map, through which tables are reached.
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

/** How the kernel maps device registers: readable and writable, uncached and strongly ordered, global. */
DEVICE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = true}

/**
 * Keep the 2 MiB block holding some device registers, for the kernel's own table, unless it's kept already.
 *
 * Asserts there's room for it, MAX_DEVICE_BLOCKS in all.
 *
 * @param system The shared state, whose device_blocks grows.
 * @param physical A physical address in the block; it's rounded down to 2 MiB.
 */
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

/**
 * Map device registers through the direct map: in the bootloader's tables now (map_early_device), and in the
 * kernel's own once it's made, each 2 MiB block of them kept for init_kernel_page_table.
 *
 * Stops at the first block that can't be mapped, with the blocks before it mapped and kept.
 *
 * @param system The shared state, with the direct map's offset, whose device_blocks grows.
 * @param physical The registers' physical address.
 * @param size Their size in bytes; at least the block holding physical is mapped, even for 0.
 * @return True if every block was mapped; false if one couldn't be.
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

/**
 * Make an address space (arch_interface.init_page_table) whose root is a zeroed frame, mapping user addresses
 * only. The kernel half is TTBR1's, so there's nothing to share.
 *
 * @param table The table to fill.
 * @param root A zeroed 4 KiB frame, the root, which goes in TTBR0_EL1.
 * @param tag The address space's ASID, below address_space_tag_count().
 * @param kernel The kernel's own table, whose direct map offset this takes.
 */
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

/**
 * Map a page or block (arch_interface.map), checking first, so a call that fails changes nothing.
 *
 * Tables the walk lacks are made from tables' frames, each counted in its parent entry. No TLB flush is needed:
 * an invalid entry is never cached, so the new one only has to be visible to the walk.
 *
 * @param table The address space, or the kernel's own table.
 * @param virtual_address Where to map it, aligned to size: a user address (USER_LOW to USER_HIGH) for a user
 *     mapping in an address space, or a kernel-half address for a kernel mapping in the kernel's table.
 * @param physical_address What to map, aligned to size, below PHYSICAL_LIMIT.
 * @param size The page or block size.
 * @param mapping Its protection, cache mode and whether it's user-reachable; global follows user (kernel mappings
 *     are global, user ones aren't), whatever mapping.global says.
 * @param tables Zeroed frames for new tables, taken from the end; untouched on an error.
 * @error InvalidAddress An address isn't aligned to size, the physical one is past 48 bits, or the virtual one is
 *     outside the range for user or kernel mappings, or in the wrong kind of table.
 * @error AlreadyMapped A page or block is already mapped where this would go, or over it.
 * @error NeedTableFrames tables has fewer frames than the walk lacks tables; refill it and call again.
 */
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

/**
 * Unmap one page or block (arch_interface.unmap), checking first, so a call that fails changes nothing.
 *
 * Tables it empties go in freed, from the leaf's up, until one keeps an entry; the root, and the kernel's tables
 * right below its root, stay. The TLB isn't flushed here: the page goes in flush, for the caller to flush on every
 * CPU that may hold it.
 *
 * @param table The address space, or the kernel's own table.
 * @param virtual_address The page's address, aligned to size.
 * @param size The size it was mapped with.
 * @param freed Where emptied tables' frames go, for L2 to free once no CPU can still use them.
 * @param flush The batch the page's address is added to, with table's tag.
 * @return The physical address the page or block mapped.
 * @error NotMapped Nothing is mapped there, or a table is where a block of size would be.
 * @error PartOfLargerPage A larger block covers the address.
 * @error NeedFreedSpace freed hasn't room for the tables this would empty; empty it and call again.
 */
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

/**
 * Give a mapped page or block a new protection (arch_interface.protect).
 *
 * Permissions change in place; a different memory type needs break-before-make: the entry cleared and flushed
 * everywhere before the new one is written. Either way the page goes in flush for the caller to flush.
 *
 * @param table The address space, or the kernel's own table.
 * @param virtual_address The page's address, aligned to size.
 * @param size The size it was mapped with.
 * @param mapping The new protection, cache mode and user flag; the physical address is kept.
 * @param flush The batch the page's address is added to, with table's tag.
 * @error NotMapped Nothing of size is mapped there, or the address is outside the range mapping's user flag allows
 *     in this kind of table.
 * @error PartOfLargerPage A larger block covers the address.
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

/**
 * Find where an address is mapped (arch_interface.translate), by walking the tables.
 *
 * @param table The address space, or the kernel's own table.
 * @param virtual_address Any address, aligned or not.
 * @return The physical address it maps to, its offset in the page or block kept, and the mapping as the entry has
 *     it; null if nothing is mapped there.
 */
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

/**
 * Free an address space's tables before its root is freed (arch_interface.release_user_tables), as many as freed
 * has room for.
 *
 * What they mapped isn't touched, and no TLB is flushed. Each call frees tables with none below them, so it can
 * stop anywhere and go on. Asserts table isn't the kernel's own.
 *
 * @param table The address space, no longer active on any CPU.
 * @param freed Where the tables' frames go, for L2 to free once no CPU can still use them; while tables are left,
 *     it must have room for at least one, or add_freed's assertion fails.
 * @return True once none are left but the root; false if freed filled first, so call again once it's emptied.
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

/**
 * Find, under a table, the entry of a table with no tables under it in turn.
 *
 * @param table The address space, for the direct map's offset.
 * @param current A table at level.
 * @param level current's level, 0 to 2; a page table, level 0, has no tables under it.
 * @return The address, through the direct map, of the entry pointing at the first such table, depth first; 0 if
 *     current points at no tables.
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

/**
 * Switch the calling CPU to table (arch_interface.activate): the kernel's goes in TTBR1, with TTBR0's walks off,
 * and an address space's in TTBR0 with its ASID, with TTBR0's walks on.
 *
 * ASIDs keep each address space's entries apart, so nothing is flushed; the first switch from the bootloader's
 * tables flushes the CPU's whole TLB.
 *
 * @param table The table, which must stay valid while the CPU uses it.
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

/**
 * Flush a batch from the calling CPU's TLB only (arch_interface.flush_tlb), by address and ASID, whichever address
 * space is active.
 *
 * The kernel's entries are global, so they're flushed for every ASID. A batch marked all flushes its ASID if its
 * first address is a user one, and the whole TLB otherwise, since it may be the kernel's.
 *
 * @param batch The pages to flush, at most 16, with their address space's tag.
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

/**
 * Flush every entry for an ASID from the calling CPU's TLB, before the ASID is reused (arch_interface.flush_tlb_tag).
 *
 * @param tag The ASID; global entries, the kernel's, stay.
 */
flush_tlb_tag :: fn(tag: arch_interface.AddressSpaceTag) {
    aarch64.dsb(.ISHST)
    aarch64.tlbi_aside1(cast[u64](tag) << TTBR_ASID_SHIFT)
    aarch64.dsb(.NSH)
    aarch64.isb()
}

/** Flush every TLB entry of the calling CPU's, every ASID's and the global ones. */
flush_everything :: fn() {
    aarch64.dsb(.ISHST)
    aarch64.tlbi_vmalle1()
    aarch64.dsb(.NSH)
    aarch64.isb()
}

/**
 * Flush one page's entries on every CPU in the inner shareable domain, for break-before-make, before its new entry
 * is written, and wait for it to finish.
 *
 * @param table The table the page is in: the kernel's, whose entries are flushed for every ASID, or an address
 *     space's, whose ASID is flushed.
 * @param address The page's virtual address.
 */
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

/**
 * Set the calling CPU's paging state, for init_cpu: the memory attributes, 16-bit ASIDs where the CPU has them,
 * taken from TTBR0, and the access flag kept by the hardware where it can, with TTBR0's walks off until an address
 * space is activated; then flush its whole TLB.
 *
 * The bootloader's TCR_EL1 is kept otherwise: 48-bit halves, 4 KiB granules, walks cached and inner shareable, and
 * the CPU's physical address size.
 *
 * @param system The shared state, which says whether the CPU has 16-bit ASIDs and the hardware access flag.
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

/**
 * Map device registers in the bootloader's tables (TTBR1's), at direct_map_offset plus physical, as a Device block
 * in the first gap the walk down to it finds: 1 GiB, 2 MiB or a 4 KiB page.
 *
 * Also sets MAIR_EL1's attribute 2, which the bootloader leaves unused, to Device-nGnRnE, until init_cpu sets all
 * of it. Runs before the kernel's own tables exist, on the boot CPU.
 *
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map, through which its tables
 *     are reached.
 * @param physical The registers' physical address; the block or page holding it is mapped.
 * @return True if they're mapped now, or were mapped so already, as a Device block or page over the same address;
 *     false if they can't be: the root's entry for them is empty, the direct map isn't aligned to the gap's size, or
 *     something else is mapped there.
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

/**
 * Make a Device block descriptor for the kernel: global, never executed, with the access flag set.
 *
 * @param physical The block's physical address, aligned to its size.
 * @return The descriptor, as a block; a page at level 0 also needs ENTRY_TABLE.
 */
device_block :: fn(physical: u64) -> u64 {
    return physical | ENTRY_VALID | (ATTRIBUTE_DEVICE << ATTRIBUTE_SHIFT) | ENTRY_ACCESSED
        | ENTRY_PRIVILEGED_EXECUTE_NEVER | ENTRY_USER_EXECUTE_NEVER
}

/** Which entries walk passed through, by level, as addresses in the direct map. */
Path :: struct {
    /** Each level's entry for the address, from the leaf's level up; levels below the leaf's are 0. */
    slots : u64[4],
    /** slots[leaf], the leaf's entry. */
    leaf_slot : u64,
}

/**
 * Walk the tables from the root down to a page or block of the leaf level's size mapped at an address.
 *
 * @param table The address space, or the kernel's own table.
 * @param address Any virtual address in the page or block; it needn't be aligned. Only bits 12 to 47 index the
 *     tables, so it isn't checked against the half table maps.
 * @param leaf The leaf's level: 0 for a 4 KiB page, 1 for a 2 MiB block, 2 for a 1 GiB block.
 * @return The entries it passed through, down to the leaf's.
 * @error NotMapped An entry on the way is invalid, or a table is where a block of the leaf's size would be.
 * @error PartOfLargerPage A block above the leaf's level covers the address.
 */
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

/**
 * Tell whether the 4 KiB page at an address was touched since its access flag was last cleared, and clear it
 * (arch_interface.take_accessed), atomically, without a TLB flush.
 *
 * Only where the hardware sets the flag (TCR_EL1.HA): everywhere else every page is mapped with the flag set,
 * which clearing would turn into faults.
 *
 * @param table The address space, or the kernel's own table.
 * @param virtual_address Any address in the page, aligned or not; only bits 12 to 47 index the tables, so it isn't
 *     checked against the half table maps.
 * @return True if the flag was set; false if it wasn't, if the hardware doesn't keep it, or if no 4 KiB page is
 *     mapped there (a block counts as none).
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

/**
 * Tell whether a valid entry maps a block rather than pointing at a table.
 *
 * @param entry The descriptor, valid.
 * @param level Its level, 0 to 3.
 * @return True for a block at levels 1 to 3 (bit 1 clear); false for a table, and at level 0, whose entries are
 *     pages.
 */
is_block :: fn(entry: u64, level: u64) -> bool {
    return level > 0 && entry & ENTRY_TABLE == 0
}

/**
 * Tell whether a table may map bytes at an address: user addresses in an address space, kernel ones in the
 * kernel's.
 *
 * @param table The table, an address space or the kernel's own.
 * @param address The mapping's first virtual address, aligned to bytes by the callers.
 * @param bytes How many bytes from it, the page's size.
 * @param user Whether the mapping is user-reachable.
 * @return For a user mapping, true if table is an address space and every byte is from USER_LOW to below
 *     USER_HIGH; for a kernel one, true if table is the kernel's and address is in the kernel half.
 */
may_map :: fn(table: ptr[PageTable], address: u64, bytes: u64, user: bool) -> bool {
    if user {
        return !table.kernel && address >= USER_LOW && address < USER_HIGH && bytes <= USER_HIGH - address
    }
    return table.kernel && address >= KERNEL_HALF_START
}

/**
 * Make a page or block descriptor, with the access flag set: user ones only reachable from EL0, never executed by
 * the kernel and not global; kernel ones never executed by user mode, and global.
 *
 * @param physical The physical address, aligned to the level's size.
 * @param mapping The protection and cache mode; user decides globalness, and global is ignored. Read and
 *     ReadExecute are read-only; only ReadExecute is executable. Memory that isn't Device is inner shareable.
 * @param level The level, 0 for a page (which also gets ENTRY_TABLE, as a page descriptor has) to 2.
 * @return The descriptor, valid, with physical in its address bits; it's only built, not stored.
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

/**
 * Give a cache mode's MAIR_EL1 index.
 *
 * @param cache Any cache mode; each has its own index.
 * @return ATTRIBUTE_WRITE_BACK, ATTRIBUTE_NON_CACHEABLE for WriteCombining, or ATTRIBUTE_DEVICE.
 */
attribute_of :: fn(cache: arch_interface.CacheMode) -> u64 {
    return match cache {
        case .WriteBack => ATTRIBUTE_WRITE_BACK
        case .WriteCombining => ATTRIBUTE_NON_CACHEABLE
        case .Device => ATTRIBUTE_DEVICE
    }
}

/**
 * Read the mapping a page or block descriptor gives, as leaf_entry made it.
 *
 * @param entry The descriptor, valid.
 * @return Its user flag, protection (ReadWrite if writable, else Read or ReadExecute as the execute-never bit for
 *     its privilege says), cache mode (any index other than 0 and 1 is Device), and global if nG is clear.
 */
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

/**
 * Read the physical address a leaf entry maps.
 *
 * @param entry The page or block descriptor.
 * @param level Its level, 0 to 2.
 * @return The address, aligned to the level's size: 4 KiB, 2 MiB or 1 GiB.
 */
page_address :: fn(entry: u64, level: u64) -> u64 {
    return entry & ENTRY_ADDRESS & ~((cast[u64](1) << (12 + 9 * level)) - 1)
}

/**
 * Give a page size in bytes.
 *
 * @param size Any of the three sizes; each has a level, so none is refused.
 * @return 4096, 2 MiB or 1 GiB.
 */
page_bytes :: fn(size: arch_interface.PageSize) -> u64 {
    return cast[u64](1) << (12 + 9 * leaf_level(size))
}

/**
 * Give the level whose entries map pages of a size.
 *
 * @param size Any of the three sizes; each maps at its own level.
 * @return 0 for 4 KiB, 1 for 2 MiB, 2 for 1 GiB.
 */
leaf_level :: fn(size: arch_interface.PageSize) -> u64 {
    return match size {
        case .Size4K => cast[u64](0)
        case .Size2M => cast[u64](1)
        case .Size1G => cast[u64](2)
    }
}

/**
 * Find the entry for an address in a table.
 *
 * @param current The table, at level.
 * @param address The virtual address; only its 9 bits for the level are used.
 * @param level The table's level, 0 to 3.
 * @return The entry, in current.
 */
slot_at :: fn(current: ptr[mut Table], address: u64, level: u64) -> ptr[mut u64] {
    return &current.entries[(address >> (12 + 9 * level)) % ENTRIES]
}

/**
 * Reach a table through the direct map.
 *
 * @param table The page table whose direct map offset is used.
 * @param physical The table's physical address.
 * @return The table, valid while the direct map is.
 */
table_at :: fn(table: ptr[PageTable], physical: u64) -> ptr[mut Table] {
    return cast[ptr[mut Table]](table.direct_map_offset + physical)
}

/**
 * Read the count of valid entries a table entry keeps for the table it points at.
 *
 * @param entry A valid table descriptor at levels 1 to 3, whose bits 2 to 11 (COUNT_MASK) hold the count;
 *     what any other entry gives there means nothing.
 * @return The count, 0 to 512.
 */
count_of :: fn(entry: u64) -> u64 {
    return (entry & COUNT_MASK) >> COUNT_SHIFT
}

/**
 * Change the count in a table entry.
 *
 * @param slot The entry's address through the direct map; 0, the root's place, which has no entry, does nothing.
 * @param change What to add, modulo the count's 10 bits: 1, or 0 - 1 to subtract one.
 */
add_to_count :: fn(slot: u64, change: u64) {
    if slot == 0 {
        return void
    }
    entry :: load_entry(slot)
    count :: (count_of(entry) + change) & (COUNT_MASK >> COUNT_SHIFT)
    store_entry(cast[ptr[mut u64]](slot), (entry & ~COUNT_MASK) | (count << COUNT_SHIFT))
}

/**
 * Read an entry.
 *
 * @param slot The entry's address, through the direct map, 8-byte aligned.
 * @return The descriptor as it is now, with a plain load: 0 for an invalid entry, else a table, block or page
 *     descriptor, its count bits included.
 */
load_entry :: fn(slot: u64) -> u64 {
    return cast[ptr[u64]](slot)^
}

/**
 * Write an entry whole, with release ordering.
 *
 * Entries are written whole and in order, so another CPU walking the tables sees a new table only after its zeroed
 * contents.
 *
 * @param slot The entry, in a table reached through the direct map; what was there is replaced.
 * @param entry The whole new descriptor: 0 to make it invalid. Making it valid doesn't flush any TLB; a valid entry
 *     replaced needs the caller's flush.
 */
store_entry :: fn(slot: ptr[mut u64], entry: u64) {
    intrinsics.atomic_store_u64_release(slot, entry)
}

/**
 * Take the last of tables' frames off it. Asserts there's one, and no more than 4.
 *
 * @param tables The frames left for new tables.
 * @return The frame's physical address, zeroed as L2 gives them.
 */
take_table :: fn(tables: ptr[mut arch_interface.TableFrames]) -> u64 {
    count :: cast[usize](tables.count)
    runtime.assert(count >= 1 && count <= 4, "map takes a frame only when one is left")
    tables.count = cast[u32](count - 1)
    return cast[u64](tables.frames[count - 1])
}

/**
 * Add a table's frame to freed. Asserts there's room.
 *
 * @param freed The frames for L2 to free.
 * @param frame The table's physical address.
 */
add_freed :: fn(freed: ptr[mut arch_interface.FreedTables], frame: u64) {
    count :: cast[usize](freed.count)
    runtime.assert(count < 4, "unmap checks there's room before freeing a table")
    freed.frames[count] = cast[arch_interface.PhysicalAddress](frame)
    freed.count = cast[u32](count + 1)
}

/**
 * Add a page to a TLB batch, which covers the whole tag once full.
 *
 * @param flush The batch, whose tag is set to tag.
 * @param tag The page's address space's ASID.
 * @param address The page's virtual address. Once the batch holds 16, or is marked all, it's marked all instead.
 */
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
