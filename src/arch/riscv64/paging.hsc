package arch_riscv64

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import runtime from "base:runtime"
import arch_interface from "../../arch_interface"

/*
 * Sv48 paging (arch_interface, Paging): four levels of 512-entry tables, from the root (level 3) down to page tables
 * (level 0), numbered as x86-64's are. Tables are reached through the direct map, at their physical address plus its
 * offset. Each page's memory type is Svpbmt's, in its entry: the physical memory attributes for RAM, non-cacheable for
 * write-combining, I/O for device registers.
 *
 * One root holds both halves, as on x86-64: the kernel half (the upper 256 root entries) has its tables from the start,
 * made by init_kernel_page_table, and every other address space copies those root entries, so a kernel mapping made
 * later shows up in all of them. Kernel mappings are global, and user ones carry their address space's ASID.
 *
 * A non-leaf entry has no bits to spare (bits 54 to 63 must be 0 there, and only bits 8 and 9 are the software's), so
 * unmap looks through a table for a second valid entry to know whether it empties, rather than keeping a count.
 *
 * Every leaf has its accessed and dirty bits set, as Svade, which RVA23S64 has, faults on a clear one rather than
 * setting it.
 */
/*
 * SPEC: The RISC-V Instruction Set Manual, Volume II: Privileged Architecture, §12.3 (Sv39: the PTE format and the
 * walk), §12.4 (Sv48), §10.1.11 (satp), §11.2.1 (sfence.vma), chapter 15 (Svpbmt)
 */

/** How many 8-byte entries a table has at every level. */
ENTRIES :: 512
/** The root's level; page tables are level 0. */
TOP_LEVEL : u64 : 3
/** The first root entry of the kernel half, the first with bit 47 set. */
KERNEL_HALF_FIRST :: 256
/** How many root entries the kernel half has, each with a level 2 table from the start. */
KERNEL_HALF_COUNT :: 256

/** Entry bit 0 (V): the entry is valid; every other bit is ignored when it's clear. */
ENTRY_VALID : u64 : 1 << 0
/** Entry bit 1 (R): reads allowed. A valid entry with R, W and X clear points at the next table instead. */
ENTRY_READ : u64 : 1 << 1
/** Entry bit 2 (W): writes allowed; with R clear and X clear, a shadow stack's page (Zicfiss). */
ENTRY_WRITE : u64 : 1 << 2
/** Entry bit 3 (X): instruction fetches allowed. */
ENTRY_EXECUTE : u64 : 1 << 3
/** Entry bit 4 (U): user mode may access it, and supervisor mode only with sstatus.SUM, never to execute. */
ENTRY_USER : u64 : 1 << 4
/** Entry bit 5 (G): the mapping is in every address space, whatever the ASID. */
ENTRY_GLOBAL : u64 : 1 << 5
/** Entry bit 6 (A): accessed, set on every leaf, as Svade faults on a clear one. */
ENTRY_ACCESSED : u64 : 1 << 6
/** Entry bit 7 (D): dirty, set on every leaf, as Svade faults on a write to a clean one. */
ENTRY_DIRTY : u64 : 1 << 7
/** The bits that make a valid entry a leaf, any of R, W and X. */
ENTRY_LEAF : u64 : ENTRY_READ | ENTRY_WRITE | ENTRY_EXECUTE
/** Where an entry's physical page number is: bits 10 to 53. */
PPN_SHIFT : u64 : 10
/** An entry's physical page number's bits, before shifting: 44 of them. */
PPN_MASK : u64 : (cast[u64](1) << 44) - 1
/** Svpbmt's memory type field, bits 61 and 62. */
ENTRY_PBMT : u64 : 3 << 61
/** Svpbmt's NC: non-cacheable, idempotent, weakly ordered main memory, for write-combining. */
PBMT_NON_CACHEABLE : u64 : 1 << 61
/** Svpbmt's IO: non-cacheable, non-idempotent, strongly ordered I/O, for device registers. */
PBMT_IO : u64 : 2 << 61

/** satp's MODE for Sv48, in bits 60 to 63. */
SATP_SV48 : u64 : 9 << 60
/** Where satp's ASID is: bits 44 to 59. */
SATP_ASID_SHIFT : u64 : 44
/** satp's ASID field's bits, before shifting: 16 of them, of which the CPU may have fewer. */
SATP_ASID_MASK : u64 : 0xffff
/** satp's physical page number of the root: bits 0 to 43. */
SATP_PPN_MASK : u64 : (cast[u64](1) << 44) - 1

/** One past the highest physical address an entry can hold: 56 bits of them. */
PHYSICAL_LIMIT : u64 : 1 << 56
/** The kernel half's lowest address, the lowest Sv48 address with bit 47 set, so its bits 48 to 63 are set too. */
KERNEL_HALF_START : u64 : 0xffff800000000000
// As on x86-64: 64 KiB up to the last page below the lower half's end.
/** The lowest user address: 64 KiB, so a null pointer and small offsets from it fault. */
USER_LOW : u64 : 0x10000
/** One past the highest user address: 2^47 less a page, as on x86-64. */
USER_HIGH : u64 : 0x00007ffffffff000

/** A 2 MiB page's size in bytes, a level 1 leaf's. */
BLOCK_2M : u64 : 1 << 21

/** One page-table level's 512 entries, a 4 KiB frame. */
Table :: struct {
    /** The entries, each mapping a page, pointing at a table a level down, or 0. */
    entries : u64[ENTRIES],
}

#assert size_of(Table) == 4096

/** One address space's page tables (arch_interface.PageTable). */
PageTable :: struct {
    /** The root table's physical address, a 4 KiB frame, whose page number goes in satp while it's active. */
    root : arch_interface.PhysicalAddress,
    /** The address space's ASID, of which the CPU's ASID bits are used (address_space_tag_count). */
    tag : arch_interface.AddressSpaceTag,
    /** The kernel's own table, which maps the kernel half and nothing else. */
    kernel : bool,
    /** Where physical address 0 is in the direct map, through which the tables are reached: a virtual address. */
    direct_map_offset : u64,
}

/**
 * Give the range of addresses user mappings may use (arch_interface.user_address_range).
 *
 * @return low USER_LOW, 64 KiB, the lowest user address.
 * @return high USER_HIGH, one past the highest: 2^47 less a page.
 */
user_address_range :: fn() -> (low, high : arch_interface.VirtualAddress) {
    return cast[arch_interface.VirtualAddress](USER_LOW), cast[arch_interface.VirtualAddress](USER_HIGH)
}

/**
 * Count the ASIDs the CPU has (arch_interface.address_space_tag_count), as init_system found them.
 *
 * @return 2 to the power of the ASID bits satp keeps, up to 65536; 1, tags not supported, where it keeps none.
 */
address_space_tag_count :: fn() -> u32 {
    return cast[u32](1) << current_system().asid_bits
}

/**
 * Tell whether the CPU maps pages of a size (arch_interface.supports_page_size).
 *
 * @param size Any of the three sizes.
 * @return True: Sv48 maps 4 KiB pages, 2 MiB megapages and 1 GiB gigapages on every CPU that has it.
 */
supports_page_size :: fn(size : arch_interface.PageSize) -> bool {
    return true
}

/**
 * Count the zeroed frames the kernel's own table needs besides its root (arch_interface.kernel_half_frames).
 *
 * @return KERNEL_HALF_COUNT, 256, one level 2 table for each root entry of the kernel half, then one level 1 table for
 *     each device block init_system kept for L1's own registers.
 */
kernel_half_frames :: fn() -> u32 {
    return KERNEL_HALF_COUNT + current_system().device_block_count
}

/**
 * Make table the kernel's own address space (arch_interface.init_kernel_page_table), which maps the kernel half and
 * nothing else: the root's kernel-half entries pointing at the 256 tables from half on, so every address space that
 * copies them shares the kernel half as it grows, and the device registers L1 uses (the console's), as the
 * bootloader's tables had them, at the direct map's address for them, as 2 MiB I/O pages.
 *
 * @param table The table to set up.
 * @param root The physical address of a zeroed 4 KiB frame for the root.
 * @param half The physical address of the first of kernel_half_frames() contiguous zeroed 4 KiB frames: 256 for the
 *     kernel half's level 2 tables, then one for each device block; a block another one's level 1 table already
 *     covers leaves its frame unused, still zeroed.
 * @param tag The kernel's address-space tag, kept but unused, since kernel mappings are global.
 * @param direct_map_offset Where physical address 0 is in the direct map, through which every table is reached.
 */
init_kernel_page_table :: fn(
    table : ptr[mut PageTable],
    root : arch_interface.PhysicalAddress,
    half : arch_interface.PhysicalAddress,
    tag : arch_interface.AddressSpaceTag,
    direct_map_offset : u64
) {
    table.root = root
    table.tag = tag
    table.kernel = true
    table.direct_map_offset = direct_map_offset
    top :: table_at(table, cast[u64](root))
    for i in 0..<KERNEL_HALF_COUNT {
        next :: cast[u64](half) + cast[u64](i) * 4096
        store_entry(&top.entries[KERNEL_HALF_FIRST + i], table_entry(next))
    }
    system :: current_system()
    next := cast[u64](half) + cast[u64](KERNEL_HALF_COUNT) * 4096
    for block, i in system.device_blocks {
        if i >= cast[usize](system.device_block_count) {
            break
        }
        tables := arch_interface.TableFrames.{count = 1}
        tables.frames[0] = cast[arch_interface.PhysicalAddress](next)
        next += 4096
        // A block another one's level 1 table already covers leaves its own frame unused, zeroed
        _ = map(
            table,
            cast[arch_interface.VirtualAddress](direct_map_offset + block),
            cast[arch_interface.PhysicalAddress](block),
            .Size2M,
            DEVICE_MAPPING,
            &tables
        )
    }
}

/** How the kernel maps device registers: readable and writable, I/O memory, global. */
DEVICE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = true}

/**
 * Make table a user address space (arch_interface.init_page_table), sharing the kernel's kernel half.
 *
 * The kernel's root entries for the kernel half are copied, so a kernel mapping made later shows up here too. Mapping
 * user addresses is all it's for.
 *
 * @param table The table to set up.
 * @param root The physical address of a zeroed 4 KiB frame for the root.
 * @param tag The address space's ASID, below address_space_tag_count(), flushed with flush_tlb_tag before it's reused.
 * @param kernel The kernel's own table, from init_kernel_page_table, whose direct map this takes too.
 */
init_page_table :: fn(
    table : ptr[mut PageTable],
    root : arch_interface.PhysicalAddress,
    tag : arch_interface.AddressSpaceTag,
    kernel : ptr[PageTable]
) {
    table.root = root
    table.tag = tag
    table.kernel = false
    table.direct_map_offset = kernel.direct_map_offset
    top :: table_at(table, cast[u64](root))
    kernel_top :: table_at(kernel, cast[u64](kernel.root))
    for i in 0..<KERNEL_HALF_COUNT {
        store_entry(&top.entries[KERNEL_HALF_FIRST + i], kernel_top.entries[KERNEL_HALF_FIRST + i])
    }
}

/**
 * Map one page (arch_interface.map), checking first, so a call that fails changes nothing.
 *
 * Tables the walk lacks are taken from the end of tables. The new entry is then fenced into this hart's translation
 * (sfence.vma for its address), as a hart may keep an invalid entry it walked; other harts see it once Svvptc's bounded
 * time has passed.
 *
 * @param table The address space: a user mapping needs a user address space, a kernel one the kernel's own.
 * @param virtual_address Where to map it, aligned to size: in USER_LOW to USER_HIGH for a user mapping, at
 *     KERNEL_HALF_START or above for a kernel one.
 * @param physical_address The page's physical address, aligned to size, below PHYSICAL_LIMIT.
 * @param size The page's size.
 * @param mapping Its protection, cache mode and user access; global follows user (kernel mappings are global, user
 *     ones aren't), whatever mapping.global says.
 * @param tables Zeroed frames for new tables, of which up to 3 are taken from the end, count lowered by each.
 * @error NeedTableFrames tables has fewer frames than the walk needs; refill it and call again.
 * @error AlreadyMapped A page is mapped there already, or a larger page covers it, or a table is where a large page
 *     would go.
 * @error InvalidAddress An address isn't aligned, the physical one is too high, or the virtual one is outside the
 *     range for this kind of mapping and address space.
 */
map :: fn(
    table : ptr[mut PageTable],
    virtual_address : arch_interface.VirtualAddress,
    physical_address : arch_interface.PhysicalAddress,
    size : arch_interface.PageSize,
    mapping : arch_interface.Mapping,
    tables : ptr[mut arch_interface.TableFrames]
) -> Result[void, arch_interface.MapError] {
    address :: cast[u64](virtual_address)
    physical :: cast[u64](physical_address)
    bytes :: page_bytes(size)
    leaf :: leaf_level(size)
    if address % bytes != 0
        || physical % bytes != 0
        || physical >= PHYSICAL_LIMIT
        || !may_map(table, address, bytes, mapping.user) {
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
        if level == leaf || is_leaf(entry) {
            return .Error(.AlreadyMapped)
        }
        current = table_at(table, entry_address(entry))
    }
    if missing > cast[u64](tables.count) {
        return .Error(.NeedTableFrames)
    }

    current = table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        if level == leaf {
            store_entry(slot, leaf_entry(physical, mapping))
            break
        }
        if slot^ & ENTRY_VALID == 0 {
            store_entry(slot, table_entry(take_table(tables)))
        }
        current = table_at(table, entry_address(slot^))
    }
    fence_new_entry(table, address)
    return .Ok
}

/**
 * Make this hart's translation see an entry just made valid, which it may have walked while it was invalid: sfence.vma
 * for the address, in every address space for a kernel page, which is global, or in the table's own.
 *
 * @param table The table the entry is in.
 * @param address The page's virtual address.
 */
fence_new_entry :: fn(table : ptr[PageTable], address : u64) {
    if table.kernel {
        riscv64.sfence_vma_address(cast[rawptr](address))
    }
    else {
        riscv64.sfence_vma(cast[rawptr](address), cast[u64](table.tag))
    }
}

/**
 * Unmap one page (arch_interface.unmap), checking first, so a call that fails changes nothing.
 *
 * Tables the page leaves empty are unlinked and go in freed, from the leaf's up, until one keeps an entry; the root,
 * and the kernel half's level 2 tables, stay. The freed tables' frames and the page's TLB entry may still be in use by
 * other harts until flush is carried out on them.
 *
 * @param table The address space; only kernel addresses in the kernel's own table, and user ones in a user one.
 * @param virtual_address The page's address, aligned to size.
 * @param size The page's size, which has to be the size it was mapped with.
 * @param freed Where emptied tables' frames go, at most 3, after those already in it.
 * @param flush The TLB batch the page is added to, with table's tag.
 * @return The physical address the page mapped.
 * @error NotMapped Nothing of that size is mapped there, or the address isn't aligned to size or is outside the
 *     table's own half (a user table never unmaps the kernel's shared pages); nothing was changed.
 * @error PartOfLargerPage The address is in a larger page, which can't be split; nothing was changed.
 * @error NeedFreedSpace freed hasn't room for the tables that would empty; empty it and call again. Nothing was
 *     changed.
 */
unmap :: fn(
    table : ptr[mut PageTable],
    virtual_address : arch_interface.VirtualAddress,
    size : arch_interface.PageSize,
    freed : ptr[mut arch_interface.FreedTables],
    flush : ptr[mut arch_interface.TlbBatch]
) -> Result[arch_interface.PhysicalAddress, arch_interface.UnmapError] {
    address :: cast[u64](virtual_address)
    // Only the table's own half, as map allows: a user table can't reach the kernel's shared tables through it
    if address % page_bytes(size) != 0 || !may_map(table, address, page_bytes(size), !table.kernel) {
        return .Error(.NotMapped)
    }
    leaf :: leaf_level(size)
    path :: walk(table, address, leaf)?
    physical :: page_address(load_entry(path.leaf_slot), leaf)

    /*
     * Each table that empties, from the leaf's up, until one keeps an entry besides the one going. The root, and the
     * kernel half's tables below it, stay.
     */
    emptied : u64 = 0
    for level in leaf..<TOP_LEVEL {
        if level + 1 == TOP_LEVEL && table.kernel {
            break
        }
        if !only_entry(table_at(table, entry_address(load_entry(path.slots[level + 1])))) {
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
        if level - leaf > emptied {
            break
        }
        // The table this entry points at emptied
        parent :: path.slots[level]
        add_freed(freed, entry_address(load_entry(parent)))
        store_entry(cast[ptr[mut u64]](parent), 0)
    }
    add_flush(flush, table.tag, address)
    /*
     * A table freed: sfence.vma by address need only drop leaf entries, so a hart could go on walking the table's frame
     * once it's reused. The batch flushes the whole ASID instead, which drops the tables cached for it too
     */
    if emptied > 0 {
        flush.all = true
    }
    return .Ok(cast[arch_interface.PhysicalAddress](physical))
}

/**
 * Tell whether a table has exactly one valid entry, so taking it out empties the table.
 *
 * @param current The table, through the direct map; it has at least the one valid entry being taken out.
 * @return True if no second valid entry is there; it stops looking at the second it finds.
 */
only_entry :: fn(current : ptr[Table]) -> bool {
    found := 0
    for entry in current.entries {
        if entry & ENTRY_VALID != 0 {
            found += 1
            if found > 1 {
                return false
            }
        }
    }
    return true
}

/**
 * Change a mapped page's protection and cache mode, keeping its physical address (arch_interface.protect).
 *
 * Its memory type (PBMT) can't change here, which stops the kernel (an assertion): other harts could go on using the
 * old type until flush is shot down, the page seen with two types at once. A caller changing it unmaps the page,
 * shoots the flush down, and maps it again.
 *
 * @param table The address space, of the kind mapping.user needs, as for map.
 * @param virtual_address The page's address, aligned to size.
 * @param size The page's size, which has to be the size it was mapped with.
 * @param mapping Its new protection, cache mode and user access, which replace the old ones whole.
 * @param flush The TLB batch the page is added to, with table's tag; the old mapping may be used until it's flushed.
 * @error NotMapped Nothing of that size is mapped there, or the address is outside the range for mapping's kind;
 *     nothing was changed.
 * @error PartOfLargerPage The address is in a larger page; nothing was changed.
 */
protect :: fn(
    table : ptr[mut PageTable],
    virtual_address : arch_interface.VirtualAddress,
    size : arch_interface.PageSize,
    mapping : arch_interface.Mapping,
    flush : ptr[mut arch_interface.TlbBatch]
) -> Result[void, arch_interface.UnmapError] {
    address :: cast[u64](virtual_address)
    leaf :: leaf_level(size)
    if !may_map(table, address, page_bytes(size), mapping.user) {
        return .Error(.NotMapped)
    }
    path :: walk(table, address, leaf)?
    slot :: cast[ptr[mut u64]](path.leaf_slot)
    old :: load_entry(path.leaf_slot)
    new :: leaf_entry(page_address(old, leaf), mapping)
    runtime.assert(old & ENTRY_PBMT == new & ENTRY_PBMT, "protect doesn't change a page's memory type")
    store_entry(slot, new)
    fence_new_entry(table, address)
    add_flush(flush, table.tag, address)
    return .Ok
}

/**
 * Find where an address is mapped (arch_interface.translate).
 *
 * @param table The address space, whose kernel half is the kernel's.
 * @param virtual_address Any address, not necessarily aligned.
 * @return The physical address it maps to, its offset in its page included, and the mapping, or null if nothing is
 *     mapped there.
 */
translate :: fn(
    table : ptr[PageTable],
    virtual_address : arch_interface.VirtualAddress
) -> arch_interface.Translation? {
    address :: cast[u64](virtual_address)
    current := table_at(table, cast[u64](table.root))
    for level in 0..=TOP_LEVEL #reverse {
        entry :: slot_at(current, address, level)^
        if entry & ENTRY_VALID == 0 {
            return null
        }
        if is_leaf(entry) {
            offset :: address & ((cast[u64](1) << (12 + 9 * level)) - 1)
            return arch_interface.Translation.{
                physical_address = cast[arch_interface.PhysicalAddress](page_address(entry, level) + offset),
                mapping = mapping_of(entry),
            }
        }
        if level == 0 {
            // A level 0 entry that isn't a leaf is reserved, and the walk faults on it
            return null
        }
        current = table_at(table, entry_address(entry))
    }
    return null
}

/**
 * Free a user address space's tables before its root is freed (arch_interface.release_user_tables), as many as freed
 * has room for.
 *
 * What they mapped isn't touched. Each step frees a table with none below it, so a call can stop anywhere and the next
 * go on. The kernel half's tables, shared, aren't freed.
 *
 * @param table A user address space, not the kernel's own (asserted), no longer active on any hart.
 * @param freed Where the tables' frames go. At least one has to be free: the first table is freed before it's checked.
 * @return True once only the root is left; false when freed filled first, so it has to be emptied and this called
 *     again.
 */
release_user_tables :: fn(table : ptr[mut PageTable], freed : ptr[mut arch_interface.FreedTables]) -> bool {
    runtime.assert(!table.kernel, "the kernel's own tables stay")
    top :: table_at(table, cast[u64](table.root))
    loop {
        slot := cast[u64](0)
        for i in 0..<KERNEL_HALF_FIRST {
            entry :: top.entries[i]
            if entry & ENTRY_VALID != 0 && !is_leaf(entry) {
                below :: lowest_table_slot(table, table_at(table, entry_address(entry)), TOP_LEVEL - 1)
                slot = if below != 0 { below } else { cast[u64](&top.entries[i]) }
                break
            }
        }
        if slot == 0 {
            return true
        }
        add_freed(freed, entry_address(load_entry(slot)))
        store_entry(cast[ptr[mut u64]](slot), 0)
    }
    while cast[usize](freed.count) < 4
    return false
}

/**
 * Find a table with no tables under it, below current, so it can be freed first.
 *
 * @param table The address space, for its direct map.
 * @param current A table at level, through the direct map.
 * @param level current's level, 0 to 2; a level 0 table points at no tables.
 * @return The virtual address of the entry that points at such a table, the first one found, or 0 if current points
 *     at no tables.
 */
lowest_table_slot :: fn(table : ptr[PageTable], current : ptr[mut Table], level : u64) -> u64 {
    if level == 0 {
        return 0
    }
    for i in 0..<ENTRIES {
        entry :: current.entries[i]
        if entry & ENTRY_VALID != 0 && !is_leaf(entry) {
            below :: lowest_table_slot(table, table_at(table, entry_address(entry)), level - 1)
            return if below != 0 { below } else { cast[u64](&current.entries[i]) }
        }
    }
    return 0
}

/**
 * Switch the calling hart to an address space (arch_interface.activate): satp with Sv48, the table's ASID and its root.
 *
 * ASIDs keep each address space's entries apart, so nothing is flushed; the first switch from the bootloader's tables
 * flushes the hart's whole TLB, and so does every switch where the hart has no ASIDs, every space's tag 0 then.
 *
 * @param table The address space, which has to stay until the hart switches away from it and its tag is flushed.
 */
activate :: fn(table : ptr[PageTable]) {
    cpu :: current_cpu()
    asid :: cast[u64](table.tag) & SATP_ASID_MASK
    riscv64.csrw(.SATP, SATP_SV48 | (asid << SATP_ASID_SHIFT) | ((cast[u64](table.root) >> 12) & SATP_PPN_MASK))
    if cpu.bootloader_tables || current_system().asid_bits == 0 {
        cpu.bootloader_tables = false
        riscv64.sfence_vma_all()
    }
}

/**
 * Flush a batch from the calling hart's TLB only (arch_interface.flush_tlb): sfence.vma by address and ASID.
 *
 * The kernel's entries are global, so they're flushed for every ASID. A batch marked all flushes its ASID if its first
 * address is a user one, and every entry otherwise, since it may be the kernel's.
 *
 * @param batch The pages to flush, at most 16, with their address space's tag.
 */
flush_tlb :: fn(batch : ptr[arch_interface.TlbBatch]) {
    tag :: cast[u64](batch.tag) & SATP_ASID_MASK
    user :: batch.count > 0 && cast[u64](batch.addresses[0]) < KERNEL_HALF_START
    if batch.all {
        if user {
            riscv64.sfence_vma_asid(tag)
        }
        else {
            riscv64.sfence_vma_all()
        }
        return void
    }
    count :: cast[usize](batch.count)
    runtime.assert(count <= 16, "a TlbBatch holds 16 addresses")
    for i in 0..<count {
        address :: cast[u64](batch.addresses[i])
        if address >= KERNEL_HALF_START {
            riscv64.sfence_vma_address(cast[rawptr](address))
        }
        else {
            riscv64.sfence_vma(cast[rawptr](address), tag)
        }
    }
}

/**
 * Flush every non-global entry for an ASID from the calling hart's TLB, before the ASID is reused
 * (arch_interface.flush_tlb_tag).
 *
 * @param tag The ASID; global entries, the kernel's, stay.
 */
flush_tlb_tag :: fn(tag : arch_interface.AddressSpaceTag) {
    riscv64.sfence_vma_asid(cast[u64](tag) & SATP_ASID_MASK)
}

/**
 * Find how many ASID bits the calling hart's satp keeps: all ones are written to its ASID field, with its mode and root
 * as they are, and what's read back is counted, then satp is put back and the TLB flushed.
 *
 * Runs on the bootloader's tables, whose mappings are the same whatever the ASID, so nothing moves meanwhile.
 *
 * @return From 0 to 16, the ASIDLEN of the privileged architecture's §10.1.11.
 */
probe_asid_bits :: fn() -> u32 {
    saved :: riscv64.csrr(.SATP)
    riscv64.csrw(.SATP, saved | (SATP_ASID_MASK << SATP_ASID_SHIFT))
    kept :: (riscv64.csrr(.SATP) >> SATP_ASID_SHIFT) & SATP_ASID_MASK
    riscv64.csrw(.SATP, saved)
    riscv64.sfence_vma_all()
    bits := cast[u32](0)
    loop {
        if bits >= 16 || (kept >> cast[u64](bits)) & 1 == 0 {
            break
        }
        bits += 1
    }
    return bits
}

/**
 * Map device registers in the bootloader's tables, at direct_map_offset plus physical, as an I/O page in the first gap
 * the walk down to it finds: 1 GiB, 2 MiB or a 4 KiB page.
 *
 * Runs before the kernel's own tables exist, on the boot hart, on the tables satp holds, reached through the direct
 * map.
 *
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map, through which its tables are
 *     reached.
 * @param physical The registers' physical address; the page holding it is mapped.
 * @return True if they're mapped now, or were mapped so already, as an I/O page over the same address; false if they
 *     can't be: the root's entry for them is empty, the direct map isn't aligned to the gap's size, or something else
 *     is mapped there.
 */
map_early_device :: fn(direct_map_offset : u64, physical : u64) -> bool {
    address :: direct_map_offset + physical
    current := cast[ptr[mut Table]](direct_map_offset + ((riscv64.csrr(.SATP) & SATP_PPN_MASK) << 12))
    for level in 0..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        entry :: slot^
        if entry & ENTRY_VALID == 0 {
            if level == TOP_LEVEL {
                return false
            }
            bytes :: cast[u64](1) << (12 + 9 * level)
            // The direct map at a boundary of the page's size, so the page maps what's at its address there
            if direct_map_offset % bytes != 0 {
                return false
            }
            store_entry(slot, leaf_entry(physical & ~(bytes - 1), DEVICE_MAPPING))
            riscv64.sfence_vma_address(cast[rawptr](address))
            return true
        }
        if is_leaf(entry) {
            // Mapped already, which is fine if it's as I/O over the same registers
            device :: entry & ENTRY_PBMT == PBMT_IO
            return device && page_address(entry, level) == physical & ~((cast[u64](1) << (12 + 9 * level)) - 1)
        }
        if level == 0 {
            return false
        }
        current = cast[ptr[mut Table]](direct_map_offset + entry_address(entry))
    }
    return false
}

/** Which entries walk passed through, by level, as addresses in the direct map. */
Path :: struct {
    /** Each level's entry for the address, from the leaf's level up; levels below the leaf's are 0. */
    slots : u64[4],
    /** slots[leaf], the leaf's entry. */
    leaf_slot : u64,
}

/**
 * Walk the tables from the root down to a page of the leaf level's size mapped at an address.
 *
 * @param table The address space, or the kernel's own table.
 * @param address Any virtual address in the page; it needn't be aligned. Only bits 12 to 47 index the tables, so it
 *     isn't checked against the half table maps.
 * @param leaf The leaf's level: 0 for a 4 KiB page, 1 for 2 MiB, 2 for 1 GiB.
 * @return The entries it passed through, down to the leaf's.
 * @error NotMapped An entry on the way is invalid, or a table is where a page of the leaf's size would be.
 * @error PartOfLargerPage A page above the leaf's level covers the address.
 */
walk :: fn(table : ptr[PageTable], address : u64, leaf : u64) -> Result[Path, arch_interface.UnmapError] {
    path : Path
    current := table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        path.slots[level] = cast[u64](slot)
        entry :: slot^
        if entry & ENTRY_VALID == 0 {
            return .Error(.NotMapped)
        }
        if level == leaf {
            // A table where a page should be: nothing of that size is mapped there
            if !is_leaf(entry) {
                return .Error(.NotMapped)
            }
            path.leaf_slot = cast[u64](slot)
            break
        }
        if is_leaf(entry) {
            return .Error(.PartOfLargerPage)
        }
        current = table_at(table, entry_address(entry))
    }
    return .Ok(path)
}

/**
 * Tell whether the 4 KiB user page at an address was touched since this last asked, and clear the mark
 * (arch_interface.take_accessed), atomically, without a TLB flush.
 *
 * The mark is kept by software: under Svade, which RVA23S64 has, an access through a leaf whose accessed bit is clear
 * faults, and the trap entry sets the bit and makes the access again (entries.hsc, stale_fault). A hart holding the
 * page's translation from before may go on using it without faulting, so a touch may be missed until that's flushed,
 * as on x86-64 without a flush. Kernel leaves keep the bit set, so they never fault for it.
 *
 * @param table The address space holding the page.
 * @param virtual_address Any address in the page.
 * @return True if the bit was set; false if it wasn't, or nothing's mapped there as a 4 KiB user page.
 */
take_accessed :: fn(table : ptr[mut PageTable], virtual_address : arch_interface.VirtualAddress) -> bool {
    path :: match walk(table, cast[u64](virtual_address), 0) {
        case Ok(found) => found
        case Error(error) => return false
    }
    if load_entry(path.leaf_slot) & ENTRY_USER == 0 {
        return false
    }
    old :: intrinsics.interlocked_and_u64(cast[ptr[mut u64]](path.leaf_slot), ~ENTRY_ACCESSED)
    return old & ENTRY_ACCESSED != 0
}

/**
 * Tell whether a valid entry is a leaf, mapping a page, rather than pointing at a table.
 *
 * @param entry The entry, valid.
 * @return True if any of R, W and X is set.
 */
is_leaf :: fn(entry : u64) -> bool {
    return entry & ENTRY_LEAF != 0
}

/**
 * Tell whether a table may map bytes at an address: user addresses in an address space, kernel ones in the kernel's.
 *
 * @param table The table, an address space or the kernel's own.
 * @param address The mapping's first virtual address, aligned to bytes by the callers.
 * @param bytes How many bytes from it, the page's size.
 * @param user Whether the mapping is user-reachable.
 * @return For a user mapping, true if table is an address space and every byte is from USER_LOW to below USER_HIGH;
 *     for a kernel one, true if table is the kernel's and address is in the kernel half.
 */
may_map :: fn(table : ptr[PageTable], address : u64, bytes : u64, user : bool) -> bool {
    if user {
        return !table.kernel && address >= USER_LOW && address < USER_HIGH && bytes <= USER_HIGH - address
    }
    return table.kernel && address >= KERNEL_HALF_START
}

/**
 * Make an entry that points at a table a level down: valid, R, W and X clear, and nothing else, as the privileged
 * architecture has a non-leaf's U, A, D and memory type bits reserved.
 *
 * @param physical The table's physical address, 4096-aligned.
 * @return The entry, only built, not stored.
 */
table_entry :: fn(physical : u64) -> u64 {
    return ((physical >> 12) << PPN_SHIFT) | ENTRY_VALID
}

/**
 * Make a leaf entry, with its accessed and dirty bits set: user ones only reachable from user mode and not global,
 * kernel ones global.
 *
 * @param physical The physical address, aligned to the level's size.
 * @param mapping The protection and cache mode; user decides globalness, and global and guarded are ignored, landing
 *     pads not being a page's on RISC-V. Read is R; ReadWrite R and W; ReadExecute R and X. A shadow stack's page is W
 *     alone, Zicfiss's encoding.
 * @return The entry, valid, with physical's page number in it; it's only built, not stored.
 */
leaf_entry :: fn(physical : u64, mapping : arch_interface.Mapping) -> u64 {
    entry := ((physical >> 12) << PPN_SHIFT)
        | ENTRY_VALID
        | ENTRY_ACCESSED
        | ENTRY_DIRTY
        | memory_type_of(mapping.cache)
    entry |= if mapping.shadow_stack {
        ENTRY_WRITE
    }
    else {
        match mapping.protection {
            case .Read => ENTRY_READ
            case .ReadWrite => ENTRY_READ | ENTRY_WRITE
            case .ReadExecute => ENTRY_READ | ENTRY_EXECUTE
        }
    }
    entry |= if mapping.user { ENTRY_USER } else { ENTRY_GLOBAL }
    return entry
}

/**
 * Give a cache mode's Svpbmt memory type, in an entry's bits 61 and 62.
 *
 * @param cache Any cache mode; each has its own type.
 * @return 0, the physical memory attributes, for WriteBack (RAM's own); PBMT_NON_CACHEABLE for WriteCombining; PBMT_IO
 *     for Device.
 */
memory_type_of :: fn(cache : arch_interface.CacheMode) -> u64 {
    return match cache {
        case .WriteBack => cast[u64](0)
        case .WriteCombining => PBMT_NON_CACHEABLE
        case .Device => PBMT_IO
    }
}

/**
 * Read the mapping a leaf entry gives, as leaf_entry made it.
 *
 * @param entry The leaf, valid.
 * @return Its user flag; protection (ReadWrite if writable, ReadExecute if executable, else Read); a shadow stack's
 *     page, as Read, for W alone; cache mode (memory type 1 WriteCombining, 2 and the reserved 3 Device, else
 *     WriteBack); and global if G is set.
 */
mapping_of :: fn(entry : u64) -> arch_interface.Mapping {
    mapping : arch_interface.Mapping
    mapping.user = entry & ENTRY_USER != 0
    mapping.global = entry & ENTRY_GLOBAL != 0
    rights :: entry & ENTRY_LEAF
    if rights == ENTRY_WRITE {
        mapping.shadow_stack = true
        mapping.protection = .Read
    }
    else if rights & ENTRY_WRITE != 0 {
        mapping.protection = .ReadWrite
    }
    else if rights & ENTRY_EXECUTE != 0 {
        mapping.protection = .ReadExecute
    }
    else {
        mapping.protection = .Read
    }
    type :: entry & ENTRY_PBMT
    mapping.cache = if type == 0 { .WriteBack } else if type == PBMT_NON_CACHEABLE { .WriteCombining } else { .Device }
    return mapping
}

/**
 * Read the physical address an entry points at, a table's or a page's.
 *
 * @param entry The entry, valid.
 * @return Its page number shifted back into an address, 4096-aligned.
 */
entry_address :: fn(entry : u64) -> u64 {
    return ((entry >> PPN_SHIFT) & PPN_MASK) << 12
}

/**
 * Read the physical address a leaf maps.
 *
 * @param entry The leaf.
 * @param level Its level, 0 to 2.
 * @return The address, aligned to the level's size: 4 KiB, 2 MiB or 1 GiB.
 */
page_address :: fn(entry : u64, level : u64) -> u64 {
    return entry_address(entry) & ~((cast[u64](1) << (12 + 9 * level)) - 1)
}

/**
 * Give a page size in bytes.
 *
 * @param size Any of the three sizes; each has a level, so none is refused.
 * @return 4096, 2 MiB or 1 GiB.
 */
page_bytes :: fn(size : arch_interface.PageSize) -> u64 {
    return cast[u64](1) << (12 + 9 * leaf_level(size))
}

/**
 * Give the level whose leaves map pages of a size.
 *
 * @param size Any of the three sizes; each maps at its own level.
 * @return 0 for 4 KiB, 1 for 2 MiB, 2 for 1 GiB.
 */
leaf_level :: fn(size : arch_interface.PageSize) -> u64 {
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
slot_at :: fn(current : ptr[mut Table], address : u64, level : u64) -> ptr[mut u64] {
    return &current.entries[(address >> (12 + 9 * level)) % ENTRIES]
}

/**
 * Reach a table through the direct map.
 *
 * @param table The page table whose direct map offset is used.
 * @param physical The table's physical address.
 * @return The table, valid while the direct map is.
 */
table_at :: fn(table : ptr[PageTable], physical : u64) -> ptr[mut Table] {
    return cast[ptr[mut Table]](table.direct_map_offset + physical)
}

/**
 * Read an entry.
 *
 * @param slot The entry's address, through the direct map, 8-byte aligned.
 * @return The entry as it is now, with a plain load: 0 for an invalid entry.
 */
load_entry :: fn(slot : u64) -> u64 {
    return cast[ptr[u64]](slot)^
}

/**
 * Write an entry whole, with release ordering.
 *
 * Entries are written whole and in order, so another hart walking the tables sees a new table only after its zeroed
 * contents.
 *
 * @param slot The entry, in a table reached through the direct map; what was there is replaced.
 * @param entry The whole new entry: 0 to make it invalid. Making it valid fences nothing; the callers do.
 */
store_entry :: fn(slot : ptr[mut u64], entry : u64) {
    intrinsics.atomic_store_u64_release(slot, entry)
}

/**
 * Take the last of tables' frames off it. Asserts there's one, and no more than 4.
 *
 * @param tables The frames left for new tables.
 * @return The frame's physical address, zeroed as L2 gives them.
 */
take_table :: fn(tables : ptr[mut arch_interface.TableFrames]) -> u64 {
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
add_freed :: fn(freed : ptr[mut arch_interface.FreedTables], frame : u64) {
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
add_flush :: fn(flush : ptr[mut arch_interface.TlbBatch], tag : arch_interface.AddressSpaceTag, address : u64) {
    flush.tag = tag
    count :: cast[usize](flush.count)
    if flush.all || count >= 16 {
        flush.all = true
        return void
    }
    flush.addresses[count] = cast[arch_interface.VirtualAddress](address)
    flush.count = cast[u32](count + 1)
}
