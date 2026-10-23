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

ENTRIES :: 512
TOP_LEVEL : u64 : 3
// The root entries of the kernel half: 256 to 511.
KERNEL_HALF_FIRST :: 256
KERNEL_HALF_COUNT :: 256

ENTRY_PRESENT : u64 : 1 << 0
ENTRY_WRITABLE : u64 : 1 << 1
ENTRY_USER : u64 : 1 << 2
ENTRY_WRITE_THROUGH : u64 : 1 << 3
ENTRY_CACHE_DISABLE : u64 : 1 << 4
// In a level 1 or 2 entry: maps a 2 MiB or 1 GiB page rather than pointing to a table.
ENTRY_LARGE : u64 : 1 << 7
// The PAT bit is bit 7 in a 4 KiB page's entry, and bit 12 in a large page's.
ENTRY_PAT_SMALL : u64 : 1 << 7
ENTRY_PAT_LARGE : u64 : 1 << 12
ENTRY_GLOBAL : u64 : 1 << 8
ENTRY_NO_EXECUTE : u64 : 1 << 63
// Where a table's or a 4 KiB page's address is in an entry. Large pages' addresses are aligned further.
ENTRY_ADDRESS : u64 : 0x000ffffffffff000
// The count of the next table's present entries, in a non-leaf entry's bits 61:52, which the CPU ignores.
COUNT_SHIFT : u64 : 52
COUNT_MASK : u64 : 0x3ff << 52

// Physical addresses go up to 52 bits.
PHYSICAL_LIMIT : u64 : 1 << 52
// The kernel half starts at the lowest canonical address with bit 47 set.
KERNEL_HALF_START : u64 : 0xffff800000000000
/*
 * User mode gets 64 KiB up to the last page below the canonical boundary: nothing at null or near it,
 * and SYSRET never returns to the boundary's non-canonical neighbor (Intel SDM Vol. 2B, SYSRET).
 */
USER_LOW : u64 : 0x10000
USER_HIGH : u64 : 0x00007ffffffff000

/*
 * The PAT: write-back, write-through, uncached-minus and uncached, as at reset, then write-protected,
 * write-combining, uncached-minus and uncached. An entry's PAT, cache-disable and write-through bits
 * pick one: 0 for WriteBack, 3 for Device, 5 for WriteCombining.
 */
IA32_PAT : u32 : 0x277
PAT_VALUE : u64 : 0x0007010500070406

// Write CR3 without flushing the new PCID's entries.
CR3_NO_FLUSH : u64 : 1 << 63
CR3_PCID : u64 : 0xfff
PCID_COUNT : u32 : 4096
CR4_PAGE_GLOBAL : u64 : 1 << 7

// One page-table level's 512 entries.
Table :: struct {
    entries : u64[ENTRIES],
}

#assert size_of(Table) == 4096

// One address space's page tables (arch_interface.PageTable).
PageTable :: struct {
    root : arch_interface.PhysicalAddress,
    tag : arch_interface.AddressSpaceTag,
    // The kernel's own table, which maps the kernel half and nothing else.
    kernel : bool,
    // Whether the CPU maps 1 GiB pages, read once.
    pages_1g : bool,
    // Where physical address 0 is in the direct map, through which the tables are reached.
    direct_map_offset : u64,
}

user_address_range :: fn() -> (low, high: arch_interface.VirtualAddress) {
    return cast[arch_interface.VirtualAddress](USER_LOW), cast[arch_interface.VirtualAddress](USER_HIGH)
}

// PCIDs, where the CPU has them and init_cpu turned them on.
address_space_tag_count :: fn() -> u32 {
    return if (x86_64.read_cr4() & CR4_PCID) != 0 { PCID_COUNT } else { 1 }
}

supports_page_size :: fn(size: arch_interface.PageSize) -> bool {
    if size != .Size1G {
        return true
    }
    features :: detect_features()
    return has(&features, .X86Pages1G)
}

// One table for each root entry of the kernel half.
kernel_half_frames :: fn() -> u32 {
    return KERNEL_HALF_COUNT
}

/*
 * The kernel's own table: root, a zeroed frame, whose kernel half points at the kernel_half_frames()
 * zeroed frames from half on.
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

// An address space whose root is a zeroed frame, sharing kernel's kernel half.
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

/*
 * An address space's tables, freed into freed, as many as it has room for: true once none are left
 * but the root. What they mapped isn't touched. Each call frees tables with none below them, so it can
 * stop anywhere and go on.
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
        if entry & ENTRY_PRESENT != 0 && entry & ENTRY_LARGE == 0 {
            below :: lowest_table_slot(table, table_at(table, entry & ENTRY_ADDRESS), level - 1)
            return if below != 0 { below } else { cast[u64](&current.entries[i]) }
        }
    }
    return 0
}

/*
 * Switch the calling CPU to table. With PCIDs, its tag's entries stay in the TLB unless something
 * since marked them stale; the first switch from the bootloader's tables flushes everything.
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

/*
 * Flush batch from the calling CPU's TLB. INVLPG flushes an address for the current PCID and its
 * global entries; another PCID's entries are flushed whole, when it's next activated.
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

// Flush every non-global entry for tag, before the tag is reused.
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

// Every TLB entry, global ones and every PCID's: turning global pages off and on again flushes them all.
flush_everything :: fn() {
    cr4 :: x86_64.read_cr4()
    x86_64.write_cr4(cr4 & ~CR4_PAGE_GLOBAL)
    x86_64.write_cr4(cr4)
}

mark_stale :: fn(cpu: ptr[mut ArchCpu], tag: u64) {
    word :: (tag >> 6) % 64
    cpu.stale_tags[word] |= cast[u64](1) << (tag % 64)
}

// Whether tag was stale, which it no longer is.
take_stale :: fn(cpu: ptr[mut ArchCpu], tag: u64) -> bool {
    word :: (tag >> 6) % 64
    bit :: cast[u64](1) << (tag % 64)
    stale :: cpu.stale_tags[word] & bit != 0
    cpu.stale_tags[word] &= ~bit
    return stale
}

// The paging state init_cpu sets: the PAT, global pages, and every tag stale until first activated.
init_paging :: fn(cpu: ptr[mut ArchCpu]) {
    x86_64.wrmsr(IA32_PAT, PAT_VALUE)
    x86_64.write_cr4(x86_64.read_cr4() | CR4_PAGE_GLOBAL)
    cpu.pcid = (x86_64.read_cr4() & CR4_PCID) != 0
    cpu.bootloader_tables = true
    for i in 0..<64 {
        cpu.stale_tags[i] = 0xffffffffffffffff
    }
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

// Whether table may map bytes at address: user addresses in an address space, kernel ones in the kernel's.
may_map :: fn(table: ptr[PageTable], address: u64, bytes: u64, user: bool) -> bool {
    if user {
        return !table.kernel && address >= USER_LOW && address < USER_HIGH && bytes <= USER_HIGH - address
    }
    return table.kernel && address >= KERNEL_HALF_START
}

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

protection_bits :: fn(protection: arch_interface.Protection) -> u64 {
    return match protection {
        case .Read => ENTRY_NO_EXECUTE
        case .ReadWrite => ENTRY_WRITABLE | ENTRY_NO_EXECUTE
        case .ReadExecute => cast[u64](0)
    }
}

// The PAT, cache-disable and write-through bits that pick cache's PAT entry.
cache_bits :: fn(cache: arch_interface.CacheMode, large: bool) -> u64 {
    pat :: if large { ENTRY_PAT_LARGE } else { ENTRY_PAT_SMALL }
    return match cache {
        case .WriteBack => cast[u64](0)
        case .WriteCombining => pat | ENTRY_WRITE_THROUGH
        case .Device => ENTRY_CACHE_DISABLE | ENTRY_WRITE_THROUGH
    }
}

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
 * Entries are written whole and in order, so another CPU walking the tables (the kernel half is
 * shared) sees a new table only after its zeroed contents.
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
