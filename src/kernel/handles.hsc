package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import slop_os from "std/os"
import boot_info from "../boot_info"
import frames from "frames"

/*
 * Handle tables (roadmap M5, decisions/0008, 0010): one per process. A handle is an entry's index in
 * the low 16 bits and the entry's generation in the high 16, so a closed handle fails rather than
 * reaching whatever the entry holds next; an entry whose generation would wrap is never used again.
 *
 * An entry names its object by address and generation, with the handle's rights and whether it's the
 * owning one. Lookups read it without the lock, checking its tag didn't change while they read;
 * changes take the table's lock. Entries are in pages of ENTRIES_PER_PAGE, made as the table grows,
 * found through a directory frame.
 */

ENTRIES_PER_PAGE :: 128
TABLE_PAGES :: 512
MAX_HANDLES :: ENTRIES_PER_PAGE * TABLE_PAGES

// An entry's tag: its rights in the low 32 bits, then its kind, and these, then its generation in the top 16.
TAG_VALID : u64 : 1 << 40
TAG_OWNING : u64 : 1 << 41
TAG_GENERATION_SHIFT : u64 : 48

HandleEntry :: struct #align(32) {
    tag : u64,
    object : u64,
    generation : u32,
    // The next free entry's index, while it's free.
    next_free : u32,
    reserved : u64,
}

#assert size_of(HandleEntry) == 32

HandleTable :: struct {
    lock : concurrency.SpinLock,
    // A frame of TABLE_PAGES page addresses, 0 until the first handle.
    directory : u64,
    // Free entries, by index, 0 for none; and the first index never used. Index 0 is never a handle.
    first_free : u32,
    next_unused : u32,
    count : u32,
    // Set when its process is destroyed: no more handles go in.
    closed : bool,
    // The object its pages are charged to, its process, and whether the last page couldn't be paid for.
    account : u64,
    short_of_budget : bool,
}

// What a handle refers to, as a lookup found it.
Resolved :: struct {
    object : u64,
    generation : u32,
    kind : slop_os.ObjectKind,
    rights : slop_os.Rights,
    owning : bool,
}

/*
 * A handle to object, a live object of kind with generation, with rights, owning or not: unless the
 * table is full or closed.
 */
install :: fn(kernel: ptr[mut Kernel], table: ptr[mut HandleTable], object: u64, generation: u32, kind: slop_os.ObjectKind,
    rights: slop_os.Rights, owning: bool) -> Result[slop_os.Handle, slop_os.HandleError] {
    concurrency.lock(&table.lock)
    defer concurrency.unlock(&table.lock)
    if table.closed {
        return .Error(.ObjectGone)
    }
    index := table.first_free
    entry : ptr[mut HandleEntry]
    if index != 0 {
        entry = entry_at(table, index) or_return .Error(.InvalidHandle)
        table.first_free = entry.next_free
    }
    else {
        if table.next_unused == 0 {
            table.next_unused = 1
        }
        index = table.next_unused
        if cast[usize](index) >= MAX_HANDLES {
            return .Error(.TableFull)
        }
        entry = make_entry(kernel, table, index) or_return .Error(if table.short_of_budget { slop_os.HandleError.BudgetExceeded } else { slop_os.HandleError.OutOfMemory })
        table.next_unused = index + 1
    }
    entry_generation :: intrinsics.atomic_load_u64(&entry.tag) >> TAG_GENERATION_SHIFT
    entry.object = object
    entry.generation = generation
    tag := (entry_generation << TAG_GENERATION_SHIFT) | TAG_VALID | (cast[u64](cast[u8](kind)) << 32) | cast[u64](cast[u32](rights))
    if owning {
        tag |= TAG_OWNING
    }
    intrinsics.atomic_store_u64_release(&entry.tag, tag)
    table.count += 1
    return .Ok(cast[slop_os.Handle](cast[u32](index) | cast[u32](entry_generation << 16)))
}

/*
 * What handle refers to: InvalidHandle if it isn't one of the table's, ObjectGone if its object was
 * destroyed. Without the lock.
 */
lookup :: fn(table: ptr[HandleTable], handle: slop_os.Handle) -> Result[Resolved, slop_os.HandleError] {
    index :: cast[u32](handle) & 0xffff
    wanted :: cast[u64](cast[u32](handle) >> 16)
    if index == 0 {
        return .Error(.InvalidHandle)
    }
    entry :: entry_at(table, index) or_return .Error(.InvalidHandle)
    loop {
        tag :: intrinsics.atomic_load_u64_acquire(&entry.tag)
        if tag & TAG_VALID == 0 || tag >> TAG_GENERATION_SHIFT != wanted {
            return .Error(.InvalidHandle)
        }
        resolved :: Resolved.{
            object = entry.object,
            generation = entry.generation,
            kind = cast[slop_os.ObjectKind](cast[u8](tag >> 32)),
            rights = cast[slop_os.Rights](cast[u32](tag)),
            owning = tag & TAG_OWNING != 0,
        }
        intrinsics.fence_acquire()
        // Unchanged while it was read, so what was read belongs together
        if intrinsics.atomic_load_u64(&entry.tag) == tag {
            if !is_live(resolved.object, resolved.generation) {
                return .Error(.ObjectGone)
            }
            return .Ok(resolved)
        }
    }
}

/*
 * Close handle: what it referred to, for the caller to destroy if it was the owning one. Whether the object
 * is still live doesn't matter.
 */
remove :: fn(table: ptr[mut HandleTable], handle: slop_os.Handle) -> Result[Resolved, slop_os.HandleError] {
    index :: cast[u32](handle) & 0xffff
    wanted :: cast[u64](cast[u32](handle) >> 16)
    concurrency.lock(&table.lock)
    defer concurrency.unlock(&table.lock)
    if index == 0 {
        return .Error(.InvalidHandle)
    }
    entry :: entry_at(table, index) or_return .Error(.InvalidHandle)
    tag :: entry.tag
    if tag & TAG_VALID == 0 || tag >> TAG_GENERATION_SHIFT != wanted {
        return .Error(.InvalidHandle)
    }
    removed :: Resolved.{
        object = entry.object,
        generation = entry.generation,
        kind = cast[slop_os.ObjectKind](cast[u8](tag >> 32)),
        rights = cast[slop_os.Rights](cast[u32](tag)),
        owning = tag & TAG_OWNING != 0,
    }
    next_generation :: (wanted + 1) & 0xffff
    intrinsics.atomic_store_u64_release(&entry.tag, next_generation << TAG_GENERATION_SHIFT)
    table.count -= 1
    // Back on the free list, unless its generation wrapped
    if next_generation != 0 {
        entry.next_free = table.first_free
        table.first_free = index
    }
    return .Ok(removed)
}

// The entry at index, if its page is there.
entry_at :: fn(table: ptr[HandleTable], index: u32) -> ptr[mut HandleEntry]? {
    directory :: intrinsics.atomic_load_u64_acquire(&table.directory)
    page_index :: cast[usize](index) / ENTRIES_PER_PAGE % TABLE_PAGES
    if directory == 0 {
        return null
    }
    page :: intrinsics.atomic_load_u64_acquire(cast[ptr[u64]](directory + cast[u64](page_index) * 8))
    if page == 0 {
        return null
    }
    return cast[ptr[mut HandleEntry]](page + cast[u64](cast[usize](index) % ENTRIES_PER_PAGE) * cast[u64](size_of(HandleEntry)))
}

/*
 * The entry at index, a new one at the end, making its page, and the directory, if they aren't there
 * yet, each charged to the table's process: null if there's no memory, or the budget is short.
 */
make_entry :: fn(kernel: ptr[mut Kernel], table: ptr[mut HandleTable], index: u32) -> ptr[mut HandleEntry]? {
    table.short_of_budget = false
    if table.directory == 0 {
        directory :: charged_frame(kernel, table) or_return null
        intrinsics.atomic_store_u64_release(&table.directory, directory)
    }
    page_index :: cast[usize](index) / ENTRIES_PER_PAGE % TABLE_PAGES
    slot :: cast[ptr[mut u64]](table.directory + cast[u64](page_index) * 8)
    if slot^ == 0 {
        page :: charged_frame(kernel, table) or_return null
        intrinsics.atomic_store_u64_release(slot, page)
    }
    return entry_at(table, index)
}

// A zeroed frame for table, charged to its process; its whole charge comes back once the process is released.
charged_frame :: fn(kernel: ptr[mut Kernel], table: ptr[mut HandleTable]) -> u64? {
    if table.account != 0 && !charge_more(table.account, frames.FRAME_SIZE) {
        table.short_of_budget = true
        return null
    }
    frame :: zeroed_frame(kernel) or_else 0
    if frame == 0 && table.account != 0 {
        uncharge(table.account, cast[ptr[ObjectHeader]](table.account).generation, frames.FRAME_SIZE)
    }
    return if frame != 0 { frame } else { null }
}

// A zeroed frame from this CPU's cache, as an address in the direct map.
zeroed_frame :: fn(kernel: ptr[mut Kernel]) -> u64? {
    frame :: frames.take_frame(&per_cpu().frame_cache, &kernel.frames) or_return null
    address :: frames.virtual_of(&kernel.frames, frame)
    intrinsics.mem_zero(cast[rawptr](address), cast[usize](frames.FRAME_SIZE))
    return address
}

// No more handles go in; the entries stay readable until the table is freed.
close_table :: fn(table: ptr[mut HandleTable]) {
    concurrency.lock(&table.lock)
    table.closed = true
    concurrency.unlock(&table.lock)
}

// Free a closed table's pages and directory, once no CPU can be reading them.
free_table :: fn(kernel: ptr[mut Kernel], table: ptr[mut HandleTable]) {
    if table.directory == 0 {
        return void
    }
    for page_index in 0..<TABLE_PAGES {
        page :: cast[ptr[u64]](table.directory + cast[u64](page_index) * 8)^
        if page != 0 {
            give_frame_at(kernel, page)
        }
    }
    give_frame_at(kernel, table.directory)
    table.directory = 0
}

// Give back a frame by its address in the direct map.
give_frame_at :: fn(kernel: ptr[mut Kernel], address: u64) {
    frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](address - kernel.frames.direct_map_offset))
}
