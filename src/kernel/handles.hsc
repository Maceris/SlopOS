package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import slop_os from "std/os"
import boot_info from "../boot_info"
import frames from "frames"
import robustness from "../robustness"

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

/** How many entries a page of a table holds: 128 of 32 bytes, one 4 KiB frame. */
ENTRIES_PER_PAGE :: 128
/** How many pages a table's directory holds: 512 addresses of 8 bytes, one 4 KiB frame. */
TABLE_PAGES :: 512
/** The most entries a table has, 65536, so an index fits a handle's low 16 bits; index 0 is never a handle. */
MAX_HANDLES :: ENTRIES_PER_PAGE * TABLE_PAGES

// An entry's tag: its rights in the low 32 bits, then its kind, and these, then its generation in the top 16.
/** The tag's bit for an entry that holds a handle. */
TAG_VALID : u64 : 1 << 40
/** The tag's bit for an owning handle, whose closing destroys its object. */
TAG_OWNING : u64 : 1 << 41
/** Where the entry's 16-bit generation starts in its tag. */
TAG_GENERATION_SHIFT : u64 : 48
/*
 * A fresh entry's generation: 0, or with robustness=on a few uses before 0xffff, where an entry is retired
 * (decisions/0096, 0105), so retiring runs in every test.
 */
#if robustness.ON {
    /** A fresh entry's generation: 0xfffc, four closes short of retiring. */
    HANDLE_GENERATION_START : u64 : 0xfffc
}
#else {
    /** A fresh entry's generation: 0. */
    HANDLE_GENERATION_START : u64 : 0
}

/** One entry of a handle table, 32 bytes: a handle, or a free slot. */
HandleEntry :: struct #align(32) {
    /**
     * The rights in the low 32 bits, the object's kind in bits 32 to 39, TAG_VALID and TAG_OWNING, and the entry's
     * generation in the top 16. Written with a release store under the table's lock, and read without it.
     */
    tag : u64,
    /** The object's address, while TAG_VALID is set. */
    object : u64,
    /** The object's generation when the handle was made, while TAG_VALID is set. */
    generation : u32,
    /** The next free entry's index, while it's free; 0 at the free list's end. */
    next_free : u32,
    /** Unused, so an entry is 32 bytes. */
    reserved : u64,
}

#assert size_of(HandleEntry) == 32

/** A process's handle table: entries in pages of ENTRIES_PER_PAGE, found through a directory frame. */
HandleTable :: struct {
    /** Held, at rank HandleTable, while an entry or the table's bookkeeping changes; lookups don't take it. */
    lock : concurrency.SpinLock,
    /** A frame of TABLE_PAGES page addresses, in the direct map, 0 until the first handle. */
    directory : u64,
    /** The first free entry, by index, 0 for none; its next_free links the rest. */
    first_free : u32,
    /** The first index never used, 0 before the first handle, then from 1 up to MAX_HANDLES. */
    next_unused : u32,
    /** How many handles the table holds. */
    count : u32,
    /** Set when its process is destroyed: no more handles go in. */
    closed : bool,
    /** The object its pages are charged to, its Process, as an address; 0 to charge nothing. */
    account : u64,
    /** Whether the last page wanted couldn't be paid for, so install says BudgetExceeded rather than OutOfMemory. */
    short_of_budget : bool,
}

/** What a handle refers to, as a lookup found it. */
Resolved :: struct {
    /** The object's address. */
    object : u64,
    /** The object's generation when the handle was made, which is_live checks it against. */
    generation : u32,
    /** The object's kind, as the handle records it. */
    kind : slop_os.ObjectKind,
    /** The handle's rights. */
    rights : slop_os.Rights,
    /** Whether it's the owning handle, whose closing destroys the object. */
    owning : bool,
}

/**
 * Make a handle to an object in a table.
 *
 * Takes the table's lock, at rank HandleTable. A new entry may take a frame for its page, and one for the
 * directory, each charged to the table's account.
 *
 * @param kernel The kernel, for frames.
 * @param table The table it goes in.
 * @param object The object, as an address: a live one, which the caller keeps from going away meanwhile.
 * @param generation The object's generation, which the handle checks it against from now on.
 * @param kind The object's kind, which has to be what object is: it's stored in the entry's tag, not checked.
 * @param rights What the handle allows.
 * @param owning Whether it's the owning handle, whose closing destroys the object; the caller sees there's one.
 * @return The handle: the entry's index in the low 16 bits, never 0, and the entry's generation in the high 16.
 * @error ObjectGone The table is closed, as its process is being destroyed.
 * @error TableFull All MAX_HANDLES entries are in use.
 * @error OutOfMemory No frame for the entry's page or the directory.
 * @error BudgetExceeded The table's process's budget can't pay for a page.
 * @error InvalidHandle A free entry's page is missing, which the table's own bookkeeping never allows.
 */
install :: fn(kernel: ptr[mut Kernel], table: ptr[mut HandleTable], object: u64, generation: u32, kind: slop_os.ObjectKind,
    rights: slop_os.Rights, owning: bool) -> Result[slop_os.Handle, slop_os.HandleError] {
    lock_at(&table.lock, .HandleTable)
    defer unlock_at(&table.lock, .HandleTable)
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
        entry.tag = HANDLE_GENERATION_START << TAG_GENERATION_SHIFT
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

/**
 * Find what a handle refers to, without the table's lock.
 *
 * The entry is read until its tag is the same before and after, so what's read belongs together. The object may be
 * destroyed the moment after; its memory stays an object of its kind until this CPU's next quiescent point.
 *
 * @param table The table, which may be closed: its entries stay readable until it's freed.
 * @param handle The handle, as the process gave it.
 * @return What it refers to, its object live when it was checked.
 * @error InvalidHandle It isn't one of the table's: index 0, a page not there, a free entry, or one whose
 *     generation has changed since, as it was closed.
 * @error ObjectGone Its object was destroyed, or is being destroyed.
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

/**
 * Close a handle.
 *
 * Takes the table's lock, at rank HandleTable. The entry's generation advances, so the handle fails from now on; an
 * entry whose generation wraps to 0 isn't freed, and never used again.
 *
 * @param table The table, closed or not.
 * @param handle The handle, as the process gave it.
 * @return What it referred to, for the caller to destroy if it was the owning one. Whether the object is still live
 *     isn't checked.
 * @error InvalidHandle It isn't one of the table's: index 0, a page not there, a free entry, or one already closed.
 */
remove :: fn(table: ptr[mut HandleTable], handle: slop_os.Handle) -> Result[Resolved, slop_os.HandleError] {
    index :: cast[u32](handle) & 0xffff
    wanted :: cast[u64](cast[u32](handle) >> 16)
    lock_at(&table.lock, .HandleTable)
    defer unlock_at(&table.lock, .HandleTable)
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

/**
 * Find the entry at an index, without the table's lock.
 *
 * @param table The table, read with acquire loads, so it may be another CPU's to change meanwhile.
 * @param index The entry's index, below MAX_HANDLES; a larger one is taken modulo the table's size.
 * @return The entry, in its page in the direct map, good until the table is freed; null if the directory or the
 *     entry's page isn't there yet. The entry may be free.
 */
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

/**
 * Find the entry at an index, a new one at the end, making its page, and the directory, if they aren't there
 * yet, each charged to the table's process.
 *
 * Called with the table's lock held. Sets short_of_budget to say why it failed. A directory made before a page
 * failed is kept.
 *
 * @param kernel The kernel, for frames.
 * @param table The table, whose lock the caller holds; its directory and page slots are published with release
 *     stores, for lookups without the lock.
 * @param index The entry's index, next_unused, below MAX_HANDLES.
 * @return The entry, zeroed if its page is new; null if there's no memory, or the budget is short.
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

/**
 * Take a zeroed frame for a table, charged to its process; its whole charge comes back once the process is released.
 *
 * @param kernel The kernel, for frames, taken from this CPU's frame cache.
 * @param table The table, whose account is charged a frame's 4 KiB; short_of_budget is set if it can't pay.
 * @return The frame's address in the direct map; null if fault injection failed this pass, the budget can't pay, or
 *     there's no frame, when the charge is given back.
 */
charged_frame :: fn(kernel: ptr[mut Kernel], table: ptr[mut HandleTable]) -> u64? {
    if fails(.Handles) {
        return null
    }
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

/**
 * Take a zeroed frame from this CPU's frame cache, charged to nobody.
 *
 * @param kernel The kernel, for frames.
 * @return The frame's address in the direct map, the caller's to give back with give_frame_at; null if there are no
 *     frames.
 */
zeroed_frame :: fn(kernel: ptr[mut Kernel]) -> u64? {
    frame :: frames.take_frame(&per_cpu().frame_cache, &kernel.frames) or_return null
    address :: frames.virtual_of(&kernel.frames, frame)
    intrinsics.mem_zero(cast[mut rawptr](address), cast[usize](frames.FRAME_SIZE))
    return address
}

/**
 * Close a table: no more handles go in; the entries stay readable until the table is freed.
 *
 * Takes the table's lock, at rank HandleTable.
 *
 * @param table The table, whose process is being destroyed.
 */
close_table :: fn(table: ptr[mut HandleTable]) {
    lock_at(&table.lock, .HandleTable)
    table.closed = true
    unlock_at(&table.lock, .HandleTable)
}

/**
 * Free a closed table's pages and directory, once no CPU can be reading them, as at its process's release.
 *
 * Their charge isn't given back here: it's part of the process's, which its release returns whole.
 *
 * @param kernel The kernel, whose frames they go back to through this CPU's frame cache.
 * @param table The table, closed, whose directory is 0 afterwards; one that never had a handle has nothing to free.
 */
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

/**
 * Give back a single frame by its address in the direct map, to this CPU's frame cache.
 *
 * @param kernel The kernel, for frames.
 * @param address The frame's address in the direct map: one frames.take_frame gave, which the caller no longer uses.
 */
give_frame_at :: fn(kernel: ptr[mut Kernel], address: u64) {
    frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](address - kernel.frames.direct_map_offset))
}
