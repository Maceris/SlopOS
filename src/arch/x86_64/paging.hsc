package arch_x86_64

import intrinsics from "base"
import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * 4-level paging (arch_interface, Paging): four levels of 512-entry tables, from the root (level 3,
 * the PML4) down to page tables (level 0). Tables are reached through the direct map, at their
 * physical address plus its offset.
 *
 * Each non-leaf entry also counts the present entries of the table it points to, in bits the CPU
 * ignores, so unmap knows when a table empties without reading all of it. The root's own entries
 * aren't counted, since the root is never freed by unmapping.
 *
 * The kernel half (the upper 256 root entries) has its tables from the start, made by
 * init_kernel_page_table, and every other address space copies those root entries. So the kernel
 * half is shared, and a kernel mapping made after an address space was created shows up in it too.
 */
//SPEC: Intel SDM Vol. 3A §4.5 (4-level paging), Tables 4-14 to 4-20 (entry formats), §4.10 (TLBs, PCIDs), §13.12 (PAT)

/** How many 8-byte entries a table has at every level. */
ENTRIES :: 512
/** The root's level, the PML4's; page tables are level 0. */
TOP_LEVEL : u64 : 3
// The root entries of the kernel half: 256 to 511.
/** The first root entry of the kernel half. */
KERNEL_HALF_FIRST :: 256
/** How many root entries the kernel half has, each with a level 2 table from the start. */
KERNEL_HALF_COUNT :: 256

/** Entry bit 0 (P): the entry is in use; the CPU ignores every other bit when it's clear. */
ENTRY_PRESENT : u64 : 1 << 0
/** Entry bit 5 (A): set by the hardware as the page, or a table, is touched, and cleared only by software. */
ENTRY_ACCESSED : u64 : 1 << 5
/** Entry bit 1 (R/W): writes allowed. */
ENTRY_WRITABLE : u64 : 1 << 1
/** Entry bit 2 (U/S): user mode may access it. */
ENTRY_USER : u64 : 1 << 2
/** Entry bit 3 (PWT): one of the three bits picking the page's PAT entry. */
ENTRY_WRITE_THROUGH : u64 : 1 << 3
/** Entry bit 4 (PCD): one of the three bits picking the page's PAT entry. */
ENTRY_CACHE_DISABLE : u64 : 1 << 4
/** Entry bit 7 (PS), in a level 1 or 2 entry: maps a 2 MiB or 1 GiB page rather than pointing to a table. */
ENTRY_LARGE : u64 : 1 << 7
// The PAT bit is bit 7 in a 4 KiB page's entry, and bit 12 in a large page's.
/** A 4 KiB page's entry's PAT bit, bit 7, the third bit picking its PAT entry. */
ENTRY_PAT_SMALL : u64 : 1 << 7
/** A 2 MiB or 1 GiB page's entry's PAT bit, bit 12, the third bit picking its PAT entry. */
ENTRY_PAT_LARGE : u64 : 1 << 12
/** Entry bit 8 (G), in a leaf: the translation is global, kept across CR3 writes while CR4.PGE is set. */
ENTRY_GLOBAL : u64 : 1 << 8
/** Entry bit 63 (XD): instruction fetches not allowed, with IA32_EFER.NXE set. */
ENTRY_NO_EXECUTE : u64 : 1 << 63
/** Where a table's or a 4 KiB page's address is in an entry. Large pages' addresses are aligned further. */
ENTRY_ADDRESS : u64 : 0x000ffffffffff000
// The count of the next table's present entries, in a non-leaf entry's bits 61:52, which the CPU ignores.
/** The bit where a non-leaf entry's count of its table's present entries starts. */
COUNT_SHIFT : u64 : 52
/** The bits of a non-leaf entry's count of its table's present entries, bits 52-61, 0 to 512 fitting in them. */
COUNT_MASK : u64 : 0x3ff << 52

/** One past the highest physical address an entry can hold: 52 bits of them. */
PHYSICAL_LIMIT : u64 : 1 << 52
/** The kernel half's lowest address, the lowest canonical address with bit 47 set. */
KERNEL_HALF_START : u64 : 0xffff800000000000
/*
 * User mode gets 64 KiB up to the last page below the canonical boundary: nothing at null or near it,
 * and SYSRET never returns to the boundary's non-canonical neighbor (Intel SDM Vol. 2B, SYSRET).
 */
/** The lowest user address, 64 KiB, so nothing is mapped at null or near it. */
USER_LOW : u64 : 0x10000
/** One past the highest user address, the last page below the canonical boundary left out. */
USER_HIGH : u64 : 0x00007ffffffff000

/*
 * The PAT: write-back, write-through, uncached-minus and uncached, as at reset, then write-protected,
 * write-combining, uncached-minus and uncached. An entry's PAT, cache-disable and write-through bits
 * pick one: 0 for WriteBack, 3 for Device, 5 for WriteCombining.
 */
/** The IA32_PAT MSR's number: the 8 memory types an entry's PAT, PCD and PWT bits pick from. */
IA32_PAT : u32 : 0x277
/** The PAT this sets on each CPU, one byte per entry, entry 0 lowest: WB, WT, UC-, UC, WP, WC, UC-, UC. */
PAT_VALUE : u64 : 0x0007010500070406

/** CR3 bit 63, with PCIDs on: write CR3 without flushing the new PCID's entries. */
CR3_NO_FLUSH : u64 : 1 << 63
/** CR3 bits 0-11, with PCIDs on: the current PCID. */
CR3_PCID : u64 : 0xfff
/** How many PCIDs there are, 12 bits' worth. */
PCID_COUNT : u32 : 4096
/** CR4 bit 7 (PGE): global pages enabled. */
CR4_PAGE_GLOBAL : u64 : 1 << 7

/** One page-table level's 512 entries, a 4 KiB frame. */
Table :: struct {
    /** The entries, each mapping a page, pointing at a table a level down, or 0. */
    entries : u64[ENTRIES],
}

#assert size_of(Table) == 4096

/** One address space's page tables (arch_interface.PageTable). */
PageTable :: struct {
    /** The physical address of the root table, the PML4, which CR3 points at while it's active. */
    root : arch_interface.PhysicalAddress,
    /** The address space's PCID, of which the low 12 bits are used, and only where PCIDs are on. */
    tag : arch_interface.AddressSpaceTag,
    /** The kernel's own table, which maps the kernel half and nothing else. */
    kernel : bool,
    /** Whether the CPU maps 1 GiB pages, read once. */
    pages_1g : bool,
    /** Where physical address 0 is in the direct map, through which the tables are reached: a virtual address. */
    direct_map_offset : u64,
}

/**
 * Give the range of addresses user mappings may use.
 *
 * @return low USER_LOW, 64 KiB, the lowest user address.
 * @return high USER_HIGH, one past the highest, a page below the canonical boundary.
 */
user_address_range :: fn() -> (low, high: arch_interface.VirtualAddress) {
    return cast[arch_interface.VirtualAddress](USER_LOW), cast[arch_interface.VirtualAddress](USER_HIGH)
}

/**
 * Count the address-space tags, PCIDs, the calling CPU has turned on.
 *
 * @return PCID_COUNT, 4096, where the CPU has PCIDs and init_cpu turned them on; otherwise 1, tags not supported.
 */
address_space_tag_count :: fn() -> u32 {
    return if (x86_64.read_cr4() & CR4_PCID) != 0 { PCID_COUNT } else { 1 }
}

/**
 * Tell whether the CPU maps pages of a size.
 *
 * @param size Any of the three sizes; only 1 GiB asks the CPU, through CPUID on the calling CPU.
 * @return True for 4 KiB and 2 MiB pages, which every x86-64 CPU maps; for 1 GiB pages, whether CPUID says so.
 */
supports_page_size :: fn(size: arch_interface.PageSize) -> bool {
    if size != .Size1G {
        return true
    }
    features :: detect_features()
    return has(&features, .X86Pages1G)
}

/**
 * Count the zeroed frames the kernel's own table needs besides its root.
 *
 * @return KERNEL_HALF_COUNT, 256: one level 2 table for each root entry of the kernel half.
 */
kernel_half_frames :: fn() -> u32 {
    return KERNEL_HALF_COUNT
}

/**
 * Make table the kernel's own address space, which maps the kernel half and nothing else.
 *
 * The root's kernel-half entries point at the 256 tables from half on, present and writable, so every address space
 * that copies them shares the kernel half as it grows.
 *
 * @param table The table to set up.
 * @param root The physical address of a zeroed 4 KiB frame for the root.
 * @param half The physical address of the first of kernel_half_frames() contiguous zeroed 4 KiB frames.
 * @param tag The kernel's address-space tag.
 * @param direct_map_offset Where physical address 0 is in the direct map, through which every table is reached.
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
    table.pages_1g = supports_page_size(.Size1G)
    table.direct_map_offset = direct_map_offset
    top :: table_at(table, cast[u64](root))
    for i in 0..<KERNEL_HALF_COUNT {
        next :: cast[u64](half) + cast[u64](i) * 4096
        store_entry(&top.entries[KERNEL_HALF_FIRST + i], next | ENTRY_PRESENT | ENTRY_WRITABLE)
    }
}

/**
 * Make table a user address space, sharing the kernel's kernel half.
 *
 * The kernel's root entries for the kernel half are copied, without their counts, so a kernel mapping made later
 * shows up here too. Mapping user addresses is all it's for.
 *
 * @param table The table to set up.
 * @param root The physical address of a zeroed 4 KiB frame for the root.
 * @param tag The address space's tag, flushed with flush_tlb_tag before it's reused.
 * @param kernel The kernel's own table, from init_kernel_page_table, whose direct map and page sizes this takes too.
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
    table.pages_1g = kernel.pages_1g
    table.direct_map_offset = kernel.direct_map_offset
    top :: table_at(table, cast[u64](root))
    kernel_top :: table_at(kernel, cast[u64](kernel.root))
    for i in 0..<KERNEL_HALF_COUNT {
        // Without the count, which only the kernel's table keeps
        store_entry(&top.entries[KERNEL_HALF_FIRST + i], kernel_top.entries[KERNEL_HALF_FIRST + i] & ~COUNT_MASK)
    }
}

/**
 * Map one page.
 *
 * Everything is checked before anything is written, so a call that fails changes nothing. Tables the walk lacks are
 * taken from the end of tables, and are permissive (writable, and user for a user mapping): the leaf decides what's
 * allowed. No TLB flush is needed, since nothing was mapped there.
 *
 * @param table The address space: a user mapping needs a user address space, a kernel one the kernel's own.
 * @param virtual_address Where to map it, aligned to size: in USER_LOW to USER_HIGH for a user mapping, at
 *     KERNEL_HALF_START or above for a kernel one.
 * @param physical_address The page's physical address, aligned to size, below PHYSICAL_LIMIT.
 * @param size The page's size; 1 GiB only where the CPU maps them.
 * @param mapping Its protection, cache mode, user access, and for a kernel mapping whether it's global.
 * @param tables Zeroed frames for new tables, of which up to 3 are taken from the end, count lowered by each.
 * @error NeedTableFrames tables has fewer frames than the walk needs; refill it and call again.
 * @error AlreadyMapped A page is mapped there already, or a larger page covers it, or a table is where a large page
 *     would go.
 * @error InvalidAddress An address isn't aligned, the physical one is too high, or the virtual one is outside the
 *     range for this kind of mapping and address space.
 * @error UnsupportedPageSize A 1 GiB page, which the CPU doesn't map.
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
    if size == .Size1G && !table.pages_1g {
        return .Error(.UnsupportedPageSize)
    }
    if address % bytes != 0 || physical % bytes != 0 || physical >= PHYSICAL_LIMIT || !may_map(table, address, bytes, mapping.user) {
        return .Error(.InvalidAddress)
    }

    // Check first, so a call that fails changes nothing: the tables the walk lacks, or what's in the way
    missing : u64 = 0
    current := table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        entry :: slot_at(current, address, level)^
        if entry & ENTRY_PRESENT == 0 {
            missing = level - leaf
            break
        }
        if level == leaf || entry & ENTRY_LARGE != 0 {
            return .Error(.AlreadyMapped)
        }
        current = table_at(table, entry & ENTRY_ADDRESS)
    }
    if missing > cast[u64](tables.count) {
        return .Error(.NeedTableFrames)
    }

    // The address of the entry pointing at current, counting its present entries; 0 for the root
    counted : u64 = 0
    current = table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        if level == leaf {
            store_entry(slot, leaf_entry(physical, mapping, leaf > 0))
            add_to_count(counted, 1)
            break
        }
        if slot^ & ENTRY_PRESENT == 0 {
            // Tables below a leaf are permissive: the leaf decides what's allowed
            access :: if mapping.user { ENTRY_WRITABLE | ENTRY_USER } else { ENTRY_WRITABLE }
            store_entry(slot, take_table(tables) | ENTRY_PRESENT | access)
            add_to_count(counted, 1)
        }
        counted = cast[u64](slot)
        current = table_at(table, slot^ & ENTRY_ADDRESS)
    }
    return .Ok
}

/**
 * Unmap one page.
 *
 * Tables the page leaves empty are unlinked and go in freed, from the leaf's up, until one keeps an entry; the root,
 * and the kernel's own level 2 tables, stay. The freed tables' frames and the page's TLB entry may still be in use by
 * other CPUs until flush is carried out on them.
 *
 * @param table The address space; only kernel addresses in the kernel's own table, and user ones in a user one.
 * @param virtual_address The page's address, aligned to size.
 * @param size The page's size, which has to be the size it was mapped with.
 * @param freed Where emptied tables' frames go, at most 3, after those already in it.
 * @param flush The TLB batch the page is added to, with table's tag.
 * @return The physical address the page mapped.
 * @error NotMapped Nothing of that size is mapped there; nothing was changed.
 * @error PartOfLargerPage The address is in a larger page, which can't be split; nothing was changed.
 * @error NeedFreedSpace freed hasn't room for the tables that would empty; empty it and call again. Nothing was
 *     changed.
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

    // Each table that empties, from the leaf's up, until one keeps an entry. The root, and the
    // kernel half's tables below it, stay.
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
    add_flush(flush, table.tag, address)
    return .Ok(cast[arch_interface.PhysicalAddress](physical))
}

/**
 * Change a mapped page's protection and cache mode, keeping its physical address.
 *
 * @param table The address space, of the kind mapping.user needs, as for map.
 * @param virtual_address The page's address, aligned to size.
 * @param size The page's size, which has to be the size it was mapped with.
 * @param mapping Its new protection, cache mode, user access and global bit, which replace the old ones whole.
 * @param flush The TLB batch the page is added to, with table's tag; the old mapping may be used until it's flushed.
 * @error NotMapped Nothing of that size is mapped there, or the address is outside the range for mapping's kind;
 *     nothing was changed.
 * @error PartOfLargerPage The address is in a larger page; nothing was changed.
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
    slot :: path.leaf_slot
    store_entry(cast[ptr[mut u64]](slot), leaf_entry(page_address(load_entry(slot), leaf), mapping, leaf > 0))
    add_flush(flush, table.tag, address)
    return .Ok
}

/**
 * Find where an address is mapped.
 *
 * @param table The address space, whose kernel half is the kernel's.
 * @param virtual_address Any address, not necessarily aligned.
 * @return The physical address it maps to, its offset in its page included, and the mapping, or null if nothing is
 *     mapped there.
 */
translate :: fn(table: ptr[PageTable], virtual_address: arch_interface.VirtualAddress) -> arch_interface.Translation? {
    address :: cast[u64](virtual_address)
    current := table_at(table, cast[u64](table.root))
    for level in 0..=TOP_LEVEL #reverse {
        entry :: slot_at(current, address, level)^
        if entry & ENTRY_PRESENT == 0 {
            return null
        }
        if level == 0 || entry & ENTRY_LARGE != 0 {
            offset :: address & ((cast[u64](1) << (12 + 9 * level)) - 1)
            return arch_interface.Translation.{
                physical_address = cast[arch_interface.PhysicalAddress](page_address(entry, level) + offset),
                mapping = mapping_of(entry, level > 0),
            }
        }
        current = table_at(table, entry & ENTRY_ADDRESS)
    }
    return null
}

/**
 * Free a user address space's tables before its root is freed, as many as freed has room for.
 *
 * What they mapped isn't touched. Each step frees a table with none below it, so a call can stop anywhere and the
 * next go on. The kernel half's tables, shared, aren't freed.
 *
 * @param table A user address space, not the kernel's own (asserted), no longer active on any CPU.
 * @param freed Where the tables' frames go. At least one has to be free: the first table is freed before it's
 *     checked.
 * @return True once only the root is left; false when freed filled first, so it has to be emptied and this called
 *     again.
 */
release_user_tables :: fn(table: ptr[mut PageTable], freed: ptr[mut arch_interface.FreedTables]) -> bool {
    runtime.assert(!table.kernel, "the kernel's own tables stay")
    top :: table_at(table, cast[u64](table.root))
    loop {
        slot := cast[u64](0)
        for i in 0..<KERNEL_HALF_FIRST {
            entry :: top.entries[i]
            if entry & ENTRY_PRESENT != 0 {
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
 * Find a table with no tables under it, below current, so it can be freed first.
 *
 * @param table The address space, for its direct map.
 * @param current A table at level, through the direct map.
 * @param level current's level, 0 to 2; a level 0 table points at no tables.
 * @return The virtual address of the entry that points at such a table, the first one found, or 0 if current points
 *     at no tables.
 */
lowest_table_slot :: fn(table: ptr[PageTable], current: ptr[mut Table], level: u64) -> u64 {
    if level == 0 {
        return 0
    }
    for i in 0..<ENTRIES {
        entry :: current.entries[i]
        if entry & ENTRY_PRESENT != 0 && entry & ENTRY_LARGE == 0 {
            below :: lowest_table_slot(table, table_at(table, entry & ENTRY_ADDRESS), level - 1)
            return if below != 0 { below } else { cast[u64](&current.entries[i]) }
        }
    }
    return 0
}

/**
 * Switch the calling CPU to an address space.
 *
 * With PCIDs, its tag's entries stay in the TLB unless something since marked them stale; without them every switch
 * flushes the non-global entries. The first switch from the bootloader's tables flushes everything.
 *
 * @param table The address space, which has to stay until the CPU switches away from it and its tag is flushed.
 */
activate :: fn(table: ptr[PageTable]) {
    cpu :: current_cpu()
    value := cast[u64](table.root)
    if cpu.pcid {
        tag :: cast[u64](table.tag) & CR3_PCID
        value |= tag
        if !take_stale(cpu, tag) {
            value |= CR3_NO_FLUSH
        }
    }
    x86_64.write_cr3(value)
    if cpu.bootloader_tables {
        cpu.bootloader_tables = false
        flush_everything()
    }
}

/**
 * Flush a batch from the calling CPU's TLB.
 *
 * INVLPG flushes an address for the current PCID and its global entries; another PCID's entries are flushed whole,
 * when it's next activated. A batch with all set flushes everything, global entries and every PCID's.
 *
 * @param batch The addresses, at most 16 (asserted), and their tag.
 */
flush_tlb :: fn(batch: ptr[arch_interface.TlbBatch]) {
    if batch.all {
        flush_everything()
        return void
    }
    count :: cast[usize](batch.count)
    runtime.assert(count <= 16, "a TlbBatch holds 16 addresses")
    for i in 0..<count {
        x86_64.invlpg(cast[rawptr](batch.addresses[i]))
    }
    cpu :: current_cpu()
    tag :: cast[u64](batch.tag) & CR3_PCID
    if cpu.pcid && tag != x86_64.read_cr3() & CR3_PCID {
        mark_stale(cpu, tag)
    }
}

/**
 * Flush every non-global entry for a tag, before the tag is reused.
 *
 * The current PCID's are flushed now, by writing CR3 again; another's when it's next activated. Without PCIDs this
 * does nothing, since every switch flushes.
 *
 * @param tag The tag, of which the low 12 bits are used.
 */
flush_tlb_tag :: fn(tag: arch_interface.AddressSpaceTag) {
    cpu :: current_cpu()
    if !cpu.pcid {
        // Without PCIDs every switch flushes, so nothing of another address space is left
        return void
    }
    pcid :: cast[u64](tag) & CR3_PCID
    current :: x86_64.read_cr3()
    if pcid == current & CR3_PCID {
        x86_64.write_cr3(current & ~CR3_NO_FLUSH)
    }
    else {
        mark_stale(cpu, pcid)
    }
}

/**
 * Flush every TLB entry on the calling CPU, global ones and every PCID's: turning global pages off and on again
 * flushes them all.
 */
flush_everything :: fn() {
    cr4 :: x86_64.read_cr4()
    x86_64.write_cr4(cr4 & ~CR4_PAGE_GLOBAL)
    x86_64.write_cr4(cr4)
}

/**
 * Mark a tag's TLB entries stale on a CPU, so they're flushed when it's next activated there.
 *
 * @param cpu The CPU, the calling one.
 * @param tag The PCID, below 4096.
 */
mark_stale :: fn(cpu: ptr[mut ArchCpu], tag: u64) {
    word :: (tag >> 6) % 64
    cpu.stale_tags[word] |= cast[u64](1) << (tag % 64)
}

/**
 * Take a tag's stale mark on a CPU.
 *
 * @param cpu The CPU, the calling one.
 * @param tag The PCID, below 4096.
 * @return Whether the tag was marked stale; the mark is cleared either way.
 */
take_stale :: fn(cpu: ptr[mut ArchCpu], tag: u64) -> bool {
    word :: (tag >> 6) % 64
    bit :: cast[u64](1) << (tag % 64)
    stale :: cpu.stale_tags[word] & bit != 0
    cpu.stale_tags[word] &= ~bit
    return stale
}

/**
 * Set up the calling CPU's paging, as init_cpu does after enable_cpu_features: the PAT, global pages, whether PCIDs
 * are on, and every tag stale until first activated.
 *
 * @param cpu The calling CPU's state.
 */
init_paging :: fn(cpu: ptr[mut ArchCpu]) {
    x86_64.wrmsr(IA32_PAT, PAT_VALUE)
    x86_64.write_cr4(x86_64.read_cr4() | CR4_PAGE_GLOBAL)
    cpu.pcid = (x86_64.read_cr4() & CR4_PCID) != 0
    cpu.bootloader_tables = true
    for i in 0..<64 {
        cpu.stale_tags[i] = 0xffffffffffffffff
    }
}

/**
 * Take a 4 KiB page's accessed bit: whether it was touched since the bit was last cleared, clearing it.
 *
 * It's cleared atomically, since the hardware sets it, and without a TLB flush, so a CPU with the translation cached
 * may touch the page again without setting it.
 *
 * @param table The address space whose leaf entry loses the bit, a user one where the kernel calls it; any table
 *     works, and nothing else in it changes.
 * @param virtual_address Any address in the page, aligned or not; it isn't checked against table's half, and one where
 *     no 4 KiB page is mapped gives false.
 * @return Whether the bit was set; false where no 4 KiB page is mapped there, a larger page included.
 */
take_accessed :: fn(table: ptr[mut PageTable], virtual_address: arch_interface.VirtualAddress) -> bool {
    path :: match walk(table, cast[u64](virtual_address), 0) {
        case Ok(found) => found
        case Error(error) => return false
    }
    old :: intrinsics.interlocked_and_u64(cast[ptr[mut u64]](path.leaf_slot), ~ENTRY_ACCESSED)
    return old & ENTRY_ACCESSED != 0
}

/** Which entries walk passed through, by level, as addresses in the direct map. */
Path :: struct {
    /** Each level's entry, from the leaf's level up to TOP_LEVEL; those below the leaf's level are 0. */
    slots : u64[4],
    /** slots[leaf], the leaf's entry. */
    leaf_slot : u64,
}

/**
 * Walk from the root down to a page of the leaf level's size mapped at address.
 *
 * @param table A user address space or the kernel's own table; only read, its tables through the direct map.
 * @param address The virtual address, anywhere in the page.
 * @param leaf The level whose entries map pages of the size wanted, 0 to 2.
 * @return The entries passed through.
 * @error NotMapped An entry on the way isn't present, or there's a table where a large page should be.
 * @error PartOfLargerPage A larger page maps the address.
 */
walk :: fn(table: ptr[PageTable], address: u64, leaf: u64) -> Result[Path, arch_interface.UnmapError] {
    path : Path
    current := table_at(table, cast[u64](table.root))
    for level in leaf..=TOP_LEVEL #reverse {
        slot :: slot_at(current, address, level)
        path.slots[level] = cast[u64](slot)
        entry :: slot^
        if entry & ENTRY_PRESENT == 0 {
            return .Error(.NotMapped)
        }
        large :: level > 0 && entry & ENTRY_LARGE != 0
        if level == leaf {
            // A table where a large page should be: nothing of that size is mapped there
            if leaf > 0 && !large {
                return .Error(.NotMapped)
            }
            path.leaf_slot = cast[u64](slot)
            break
        }
        if large {
            return .Error(.PartOfLargerPage)
        }
        current = table_at(table, entry & ENTRY_ADDRESS)
    }
    return .Ok(path)
}

/**
 * Tell whether table may map bytes at address: user addresses in a user address space, kernel ones in the kernel's.
 *
 * @param table A user address space or the kernel's own table; only its kernel flag is read.
 * @param address The mapping's first virtual address, aligned to bytes by the callers.
 * @param bytes How many bytes, the page's size.
 * @param user Whether it's a user mapping.
 * @return For a user mapping, whether table is a user one and the bytes are within USER_LOW to USER_HIGH; for a
 *     kernel one, whether table is the kernel's own and address is at KERNEL_HALF_START or above.
 */
may_map :: fn(table: ptr[PageTable], address: u64, bytes: u64, user: bool) -> bool {
    if user {
        return !table.kernel && address >= USER_LOW && address < USER_HIGH && bytes <= USER_HIGH - address
    }
    return table.kernel && address >= KERNEL_HALF_START
}

/**
 * Make an entry that maps a page.
 *
 * @param physical The page's physical address, aligned to its size.
 * @param mapping What it allows: user pages are never global; global is only set for kernel ones.
 * @param large Whether it's a 2 MiB or 1 GiB page, which sets PS and moves the PAT bit.
 * @return The entry, present.
 */
leaf_entry :: fn(physical: u64, mapping: arch_interface.Mapping, large: bool) -> u64 {
    entry := physical | ENTRY_PRESENT | protection_bits(mapping.protection) | cache_bits(mapping.cache, large)
    if mapping.user {
        entry |= ENTRY_USER
    }
    else if mapping.global {
        entry |= ENTRY_GLOBAL
    }
    if large {
        entry |= ENTRY_LARGE
    }
    return entry
}

/**
 * Give the entry bits for a protection.
 *
 * @param protection The protection, never both writable and executable.
 * @return R/W and XD as it needs: Read is XD, ReadWrite R/W and XD, ReadExecute neither.
 */
protection_bits :: fn(protection: arch_interface.Protection) -> u64 {
    return match protection {
        case .Read => ENTRY_NO_EXECUTE
        case .ReadWrite => ENTRY_WRITABLE | ENTRY_NO_EXECUTE
        case .ReadExecute => cast[u64](0)
    }
}

/**
 * Give the PAT, cache-disable and write-through bits that pick cache's PAT entry, in PAT_VALUE.
 *
 * @param cache The cache mode: WriteBack picks entry 0, WriteCombining entry 5, Device entry 3, uncached.
 * @param large Whether it's for a large page's entry, whose PAT bit is bit 12.
 * @return The bits to OR into the entry: none for WriteBack, PAT and PWT for WriteCombining, PCD and PWT for
 *     Device.
 */
cache_bits :: fn(cache: arch_interface.CacheMode, large: bool) -> u64 {
    pat :: if large { ENTRY_PAT_LARGE } else { ENTRY_PAT_SMALL }
    return match cache {
        case .WriteBack => cast[u64](0)
        case .WriteCombining => pat | ENTRY_WRITE_THROUGH
        case .Device => ENTRY_CACHE_DISABLE | ENTRY_WRITE_THROUGH
    }
}

/**
 * Read back the mapping a leaf entry makes, as leaf_entry would have made it.
 *
 * @param entry The leaf entry, present.
 * @param large Whether it maps a 2 MiB or 1 GiB page, which moves the PAT bit.
 * @return Its protection, cache mode (Device for any combination leaf_entry doesn't make, other than WriteBack's and
 *     WriteCombining's), user access and global bit.
 */
mapping_of :: fn(entry: u64, large: bool) -> arch_interface.Mapping {
    mapping : arch_interface.Mapping
    mapping.protection = if entry & ENTRY_WRITABLE != 0 { .ReadWrite } else if entry & ENTRY_NO_EXECUTE != 0 { .Read } else { .ReadExecute }
    pat :: if large { ENTRY_PAT_LARGE } else { ENTRY_PAT_SMALL }
    mapping.cache = if entry & (pat | ENTRY_CACHE_DISABLE | ENTRY_WRITE_THROUGH) == 0 {
        .WriteBack
    }
    else if entry & (pat | ENTRY_CACHE_DISABLE | ENTRY_WRITE_THROUGH) == pat | ENTRY_WRITE_THROUGH {
        .WriteCombining
    }
    else {
        .Device
    }
    mapping.user = entry & ENTRY_USER != 0
    mapping.global = entry & ENTRY_GLOBAL != 0
    return mapping
}

/**
 * Give the physical address a leaf entry maps.
 *
 * @param entry A present leaf entry at level; its flag, count and PAT bits are masked off, so a large page's PAT bit
 *     (bit 12) doesn't show in the address.
 * @param level Its level, 0 to 2, which says how far the address is aligned and so which low bits aren't part of it.
 * @return The page's physical address, aligned to its size.
 */
page_address :: fn(entry: u64, level: u64) -> u64 {
    return entry & ENTRY_ADDRESS & ~((cast[u64](1) << (12 + 9 * level)) - 1)
}

/**
 * Give a page size in bytes.
 *
 * @param size Any of the three sizes, supported by the CPU or not.
 * @return 4096, 2 MiB or 1 GiB.
 */
page_bytes :: fn(size: arch_interface.PageSize) -> u64 {
    return cast[u64](1) << (12 + 9 * leaf_level(size))
}

/**
 * Give the level whose entries map pages of a size.
 *
 * @param size Any of the three sizes, supported by the CPU or not.
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
 * @param current The table, through the direct map.
 * @param address Any virtual address; only its 9 bits for level are used, so it needn't be aligned or canonical.
 * @param level current's level, which picks the 9 bits of address that index it.
 * @return The entry, in current.
 */
slot_at :: fn(current: ptr[mut Table], address: u64, level: u64) -> ptr[mut u64] {
    return &current.entries[(address >> (12 + 9 * level)) % ENTRIES]
}

/**
 * Reach a table through the direct map.
 *
 * @param table The address space, for its direct map offset.
 * @param physical The table's physical address.
 * @return The table's virtual address in the direct map.
 */
table_at :: fn(table: ptr[PageTable], physical: u64) -> ptr[mut Table] {
    return cast[ptr[mut Table]](table.direct_map_offset + physical)
}

/**
 * Read a non-leaf entry's count of its table's present entries.
 *
 * @param entry A non-leaf entry, whose bits 52 to 61 (COUNT_MASK) hold the count; for a leaf entry those bits are
 *     its own and the result means nothing.
 * @return The count, 0 to 512; 0 for a root entry copied into a user address space, which keeps none.
 */
count_of :: fn(entry: u64) -> u64 {
    return (entry & COUNT_MASK) >> COUNT_SHIFT
}

/**
 * Change the count in a non-leaf entry, unless it's 0, the root's place, which has no entry.
 *
 * @param slot The entry's virtual address, or 0 for none.
 * @param change What to add, wrapping: 1 to count up, 0 - 1 to count down.
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
 * @param slot The entry's virtual address, in the direct map, 8-byte aligned.
 * @return The entry as it is now, with a plain load: 0 if it was never set or was cleared, otherwise its address,
 *     flags and, for a non-leaf entry, count bits.
 */
load_entry :: fn(slot: u64) -> u64 {
    return cast[ptr[u64]](slot)^
}

/**
 * Write an entry whole, with release ordering.
 *
 * Entries are written whole and in order, so another CPU walking the tables (the kernel half is shared) sees a new
 * table only after its zeroed contents.
 *
 * @param slot The entry, in the direct map.
 * @param entry Its new value.
 */
store_entry :: fn(slot: ptr[mut u64], entry: u64) {
    intrinsics.atomic_store_u64_release(slot, entry)
}

/**
 * Take the last of tables' frames off it.
 *
 * @param tables The frames, at least one of them (asserted).
 * @return The frame's physical address, zeroed, as the caller provided it.
 */
take_table :: fn(tables: ptr[mut arch_interface.TableFrames]) -> u64 {
    count :: cast[usize](tables.count)
    runtime.assert(count >= 1 && count <= 4, "map takes a frame only when one is left")
    tables.count = cast[u32](count - 1)
    return cast[u64](tables.frames[count - 1])
}

/**
 * Add a frame to freed.
 *
 * @param freed The frames, with room for one more (asserted).
 * @param frame The table's physical address.
 */
add_freed :: fn(freed: ptr[mut arch_interface.FreedTables], frame: u64) {
    count :: cast[usize](freed.count)
    runtime.assert(count < 4, "unmap checks there's room before freeing a table")
    freed.frames[count] = cast[arch_interface.PhysicalAddress](frame)
    freed.count = cast[u32](count + 1)
}

/**
 * Add an address to a TLB batch, which once full covers the whole tag instead.
 *
 * @param flush The batch, whose tag is set to tag.
 * @param tag The address space's tag.
 * @param address The page's virtual address.
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
