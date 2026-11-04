package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import maps from "std"
import slop_os from "std/os"
import frames from "frames"
import slab from "slab"
import robustness from "../robustness"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Channels (roadmap M5, knowledge/design/ipc.md §2, decisions/0035): two ends, each an object, sharing
 * a core with the rings, one per direction, in memory both ends' holders can map (ChannelMap), so
 * messages need no system call. The kernel takes part for what shared memory can't do:
 * - doorbells: ChannelNotify raises Readable or Writable on the other end, for the ports bound to it;
 * - handle transfer: handles go into one of the other end's batches, out of the sender's table, and the
 *   receiver takes them into its own;
 * - closing: closing an end raises PeerClosed on the other, which stays raised.
 * Ends without RIGHT_CHANNEL_MAP reach the same rings through ChannelRead and ChannelWrite, which copy
 * through the kernel (decisions/0024): every byte the peer wrote is untrusted, checked against the ring.
 *
 * The core holds the ring memory until both ends are released and every mapping of it is gone: a
 * mapping is on its address space's list of rings, and is let go when it's unmapped or the space is
 * released (spaces.hsc). Closing an end unmaps its rings.
 *
 * Lock order: a core's lock, then a port's, then a run queue's. A space's lock is never taken with a
 * core's.
 */
//TODO(claude): the rings as a memory object (knowledge/design/ipc.md §2)

/** The ports an end can be bound to at once. */
MAX_END_BINDINGS :: 4

/** Where an end's rings are in being mapped, under the core's lock. */
MappingState :: enum #backed_by(u8) {
    /** Not mapped: channel_map may map them, and the end may be sent. */
    None,
    /** ChannelMap is mapping it; if the end is destroyed meanwhile, it's doomed, and unmapped once mapped. */
    Mapping,
    /** Mapped in a space, at its address; channel_unmap or the end's destruction unmaps it. */
    Mapped,
    /** Being unmapped. */
    Unmapping,
}

/**
 * Where an end's rings are mapped. Its state is under the core's lock; whether it's linked into its
 * space's list of rings, and the links, under the space's.
 */
RingMapping :: struct {
    /** How far mapping or unmapping has got, under the core's lock. */
    state : MappingState,
    /** Set when the end is destroyed while it's Mapping: channel_map unmaps it again once it's mapped. */
    doomed : bool,
    /** Whether it's on its space's list of rings, which holds a reference to the core; under the space's lock. */
    linked : bool,
    /** The AddressSpace it's mapped in, by address, while it's not None. */
    space : u64,
    /** Where in space it starts: a page-aligned user virtual address. */
    address : u64,
    /** The ChannelCore it maps, by address; set when the channel is made, and never changed. */
    core : u64,
    /** The next RingMapping on its space's list, or 0; under the space's lock. */
    next : u64,
    /** The previous RingMapping on its space's list, or 0 for the first; under the space's lock. */
    previous : u64,
}

/** A signal binding of an end's: the binding, and its generation, which changes once the port drops it. */
EndBinding :: struct {
    /** The Binding's address, or 0 for a free slot. */
    binding : u64,
    /** The binding's generation when it was made; one that differs means the port dropped it, and the slot is free. */
    generation : u32,
}

/** What a channel's core keeps for each end, under the core's lock. */
CoreSide :: struct {
    /** The end's Channel object, by address; kept after it's destroyed, though it may be released. */
    end : u64,
    /** Set once its end is destroyed: the other end sees PeerClosed from then on. */
    closed : bool,
    /** Where this end's holder mapped the rings (both directions), if it has. */
    mapping : RingMapping,
    /** The ports bound to this end's signals, at most MAX_END_BINDINGS at once. */
    bindings : EndBinding[MAX_END_BINDINGS],
    /**
     * Batches of handles sent to it: a HandleBatch's address, RESERVED while the sender fills it in, 0
     * for none.
     */
    batches : u64[16],
}

/** What a channel's ends share, freed once both are released and no mapping is left. */
ChannelCore :: struct #align(16) {
    /** The slab allocator's, while the slot is free. */
    free_link : u64,
    /** Guards the sides; ranks as LockRank.ChannelCore, taken before a port's and never with a space's. */
    lock : concurrency.SpinLock,
    /** The ends not yet released, and the mappings of its memory. */
    references : u32,
    /** The ring memory's physical address: 2^order contiguous frames, zeroed when the channel was made. */
    memory : u64,
    /** The ring memory's size, as a frame allocator order. */
    order : u64,
    /** Each ring's size in bytes: a power of two from slop_os.CHANNEL_MIN_RING to slop_os.CHANNEL_MAX_RING. */
    ring_bytes : u32,
    /** The protocol both ends speak, as whoever made it says: never interpreted here (decisions/0040, 0071). */
    tag : u64,
    /** What it keeps for each end: end A's at 0, end B's at 1. */
    sides : CoreSide[2],
}

/** A batch slot's value while its sender fills the batch in: no HandleBatch is at that address. */
RESERVED : u64 : 1

/** A channel end. */
Channel :: struct #align(16) {
    /** The object header every kernel object starts with. */
    header : ObjectHeader,
    /** Its ChannelCore, by address, shared with the other end; 0 once it's released. */
    core : u64,
    /** Which end it is: 0 for A, which writes the first ring, or 1 for B, which writes the second. */
    side : u32,
    /** Batches in flight with it in, under its core's lock: it can't be mapped meanwhile. */
    sending : u32,
}

/** Handles in flight, from the kernel heap, charged to the end that sent them while it lives. */
HandleBatch :: struct {
    /** How many entries are filled in, up to slop_os.MAX_HANDLES_PER_BATCH. */
    count : u32,
    /** The sender's generation when it sent them, so its charge goes back only to that end. */
    sender_generation : u32,
    /** The sending end, by address, which the batch's size is charged to. */
    sender : u64,
    /**
     * The handles, as they were in the sender's table; an entry whose object is 0 was closed before it could be taken
     * out, and goes as nothing.
     */
    entries : Resolved[64],
}

/**
 * Free a batch, its charge back to its sender if that's still the same end.
 *
 * Doesn't touch its entries: the caller has taken them, or let go of them (drop_batch).
 *
 * @param kernel The kernel, whose heap the batch goes back to.
 * @param address The HandleBatch's address, from allocate_block.
 */
free_batch :: fn(kernel: ptr[mut Kernel], address: u64) {
    batch :: cast[ptr[mut HandleBatch]](address)
    if batch.sender != 0 {
        uncharge(batch.sender, batch.sender_generation, cast[u64](size_of(HandleBatch)))
    }
    free_block(kernel, address, cast[u64](size_of(HandleBatch)))
}

/** A new channel's two ends, as create_channel makes them. */
ChannelPair :: struct {
    /** End A, which writes the first ring and reads the second. */
    a : ptr[mut Channel],
    /** End B, which writes the second ring and reads the first. */
    b : ptr[mut Channel],
}

/**
 * Make a channel: two ends sharing a core, with a ring each way in zeroed memory, both rings' indices set to
 * RING_INDEX_START.
 *
 * @param kernel The kernel, whose channel and core pools, and frames, it comes from.
 * @param owner The Process both ends belong to, by address, or 0 for the kernel.
 * @param budget The MemoryBudget that pays, by address, or 0 for the kernel's own: end A is charged its slot, the core
 *     and the ring memory, end B its slot.
 * @param ring_bytes Each ring's size in bytes: a power of two from slop_os.CHANNEL_MIN_RING to
 *     slop_os.CHANNEL_MAX_RING, or 0 for slop_os.CHANNEL_DEFAULT_RING.
 * @param tag The protocol the channel speaks, kept for channel_tag and never interpreted; 0 for none.
 * @return Both ends, live and owned by owner, without handles; the caller makes them.
 * @error InvalidSize ring_bytes isn't 0 or a power of two in range.
 * @error BudgetExceeded The budget couldn't pay for an end.
 * @error OutOfMemory The pools or the frame allocator had nothing to give; whatever was made is destroyed again.
 * @error ObjectGone The owner is being destroyed; both ends are destroyed again.
 */
create_channel :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, ring_bytes: u32, tag: u64) -> Result[ChannelPair, slop_os.ChannelError] {
    ring :: if ring_bytes == 0 { slop_os.CHANNEL_DEFAULT_RING } else { ring_bytes }
    if ring < slop_os.CHANNEL_MIN_RING || ring > slop_os.CHANNEL_MAX_RING || ring & (ring - 1) != 0 {
        return .Error(.InvalidSize)
    }
    a := cast[u64](0)
    b := cast[u64](0)
    order :: frames.order_for(slop_os.channel_memory_size(ring))
    held :: kernel.pools.channel_cores.object_size + (frames.FRAME_SIZE << order)
    match new_object(kernel, .Channel, budget, held) {
        case Ok(made) => a = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.ChannelError.BudgetExceeded } else { slop_os.ChannelError.OutOfMemory })
    }
    match new_object(kernel, .Channel, budget, 0) {
        case Ok(made) => b = made
        case Error(error) => {
            _ = destroy_object(kernel, a)
            return .Error(if error == .BudgetExceeded { slop_os.ChannelError.BudgetExceeded } else { slop_os.ChannelError.OutOfMemory })
        }
    }
    core_address :: slab.allocate(&kernel.pools.channel_cores, &kernel.frames) or_else 0
    memory := cast[u64](0)
    if core_address != 0 {
        match frames.allocate_zeroed(&kernel.frames, order) {
            case Ok(physical) => memory = cast[u64](physical)
            case Error(error) => slab.free(&kernel.pools.channel_cores, &kernel.frames, core_address)
        }
    }
    if memory == 0 {
        _ = destroy_object(kernel, a)
        _ = destroy_object(kernel, b)
        return .Error(.OutOfMemory)
    }
    core :: cast[ptr[mut ChannelCore]](core_address)
    core^ = ChannelCore.{}
    core.sides[0].end = a
    core.sides[1].end = b
    core.references = 2
    core.memory = memory
    core.order = order
    core.ring_bytes = ring
    core.tag = tag
    for side in 0..<2 {
        core.sides[side].mapping.core = core_address
        // Each ring's indices from where they start, which only the kernel reads and writes
        indices :: indices_of(kernel, core, cast[u32](side))
        indices.head = RING_INDEX_START
        indices.tail = RING_INDEX_START
    }
    end_a :: cast[ptr[mut Channel]](a)
    end_b :: cast[ptr[mut Channel]](b)
    end_a.core = core_address
    end_b.core = core_address
    end_b.side = 1
    // Each end's ownership: once both are the owner's, destroying the owner reaches them
    if !adopted(owner, a) || !adopted(owner, b) {
        _ = destroy_object(kernel, a)
        _ = destroy_object(kernel, b)
        return .Error(.ObjectGone)
    }
    return .Ok(ChannelPair.{a = end_a, b = end_b})
}

/**
 * Give an object to an owner, as adopt does, telling only whether it worked.
 *
 * @param owner The Process to own it, by address, or 0 for the kernel, which always works.
 * @param object The object, by address.
 * @return True if it's owner's now; false if owner is being destroyed, when nothing changed.
 */
adopted :: fn(owner: u64, object: u64) -> bool {
    match adopt(owner, object) {
        case Ok => return true
        case Error(error) => return false
    }
}

/**
 * Find what the core keeps for one end.
 *
 * @param core The channel's core.
 * @param side The end: 0 for A, 1 for B; others are taken modulo 2.
 * @return The side, inside the core; its fields are under the core's lock.
 */
side_of :: fn(core: ptr[mut ChannelCore], side: u32) -> ptr[mut CoreSide] {
    return &core.sides[cast[usize](side) % 2]
}

/**
 * Find an end's core.
 *
 * @param end The end, not yet released.
 * @return The core it shares with the other end, which lives at least until the end is released.
 */
core_of :: fn(end: ptr[Channel]) -> ptr[mut ChannelCore] {
    return cast[ptr[mut ChannelCore]](end.core)
}

/**
 * Find the ring memory in the direct map.
 *
 * @param kernel The kernel, whose direct map it's in.
 * @param core The channel's core.
 * @return The kernel virtual address of the memory's start: both directions' RingIndices, then the rings.
 */
memory_of :: fn(kernel: ptr[Kernel], core: ptr[ChannelCore]) -> u64 {
    return frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](core.memory))
}

/*
 * Where a ring's indices start: 0, or with robustness=on 256 bytes before u32 wraps (decisions/0096, 0105), so every
 * ring's indices wrap within its first few messages. They're free-running, masked to the ring.
 */
#if robustness.ON {
    /** Where a new ring's head and tail start, in bytes: 256 before u32 wraps, so wrapping is tested early. */
    RING_INDEX_START : u32 : 0xffffff00
}
#else {
    /** Where a new ring's head and tail start, in bytes. */
    RING_INDEX_START : u32 : 0
}

/**
 * Find the indices of the ring an end writes.
 *
 * Both ends' holders can write them through a mapping, so what's read from them is untrusted.
 *
 * @param kernel The kernel, whose direct map the memory is in.
 * @param core The channel's core.
 * @param side The writing end: 0 for A, 1 for B.
 * @return The indices' kernel virtual address.
 */
indices_of :: fn(kernel: ptr[Kernel], core: ptr[ChannelCore], side: u32) -> ptr[mut slop_os.RingIndices] {
    return cast[ptr[mut slop_os.RingIndices]](memory_of(kernel, core) + cast[u64](side) * cast[u64](size_of(slop_os.RingIndices)))
}

/**
 * Find the ring an end writes.
 *
 * @param kernel The kernel, whose direct map the memory is in.
 * @param core The channel's core.
 * @param side The writing end: 0 for A, 1 for B.
 * @return The ring's kernel virtual address; it's core.ring_bytes long.
 */
ring_of :: fn(kernel: ptr[Kernel], core: ptr[ChannelCore], side: u32) -> u64 {
    return memory_of(kernel, core) + cast[u64](slop_os.CHANNEL_RINGS_OFFSET) + cast[u64](side) * cast[u64](core.ring_bytes)
}

/**
 * Destroy an end: its bindings go, the batches sent to it are dropped, its rings are unmapped, and
 * the other end sees PeerClosed.
 *
 * Called once, from destroy_object, with the end already dying. Takes the core's lock, and with it the bound ports';
 * unmaps after letting go of it. A mapping still being made is left doomed, for channel_map to unmap. A batch still
 * being filled in is left to its sender, who finds this side closed. The owning handles in dropped batches have their
 * objects destroyed once this destroy is done (destroy_later). The core is kept until the end is released.
 *
 * @param kernel The kernel: bindings go back to its binding pool, the rings are unmapped with a TLB shootdown and their
 *     page tables freed to its frames, and dropped batches go back to its heap.
 * @param end The end being destroyed; one that never got its core (create_channel failing) is left alone.
 */
destroy_channel :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel]) {
    if end.core == 0 {
        return void
    }
    core :: core_of(end)
    side :: end.side
    dropped : u64[16]
    unmap := false
    kept :: side_of(core, side)
    lock_at(&core.lock, .ChannelCore)
    kept.closed = true
    for i in 0..<MAX_END_BINDINGS {
        drop_end_binding(kernel, &kept.bindings[i])
    }
    for slot, batch in kept.batches {
        // One still being filled in is dropped by its sender, who finds this side closed
        dropped[batch] = if slot > RESERVED { slot } else { 0 }
        if slot > RESERVED {
            kept.batches[batch] = 0
        }
    }
    mapping :: &kept.mapping
    if mapping.state == .Mapped {
        mapping.state = .Unmapping
        unmap = true
    }
    else if mapping.state == .Mapping {
        mapping.doomed = true
    }
    raise_signals(kernel, core, 1 - side, cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    unlock_at(&core.lock, .ChannelCore)
    if unmap {
        unmap_ring(kernel, core, side)
    }
    for batch in dropped {
        if batch != 0 {
            drop_batch(kernel, cast[ptr[mut HandleBatch]](batch))
        }
    }
}

/**
 * Release an end once no CPU can use it: the core's let go of, and freed with the second end, unless still mapped.
 *
 * @param kernel The kernel, whose frames and core pool the core goes back to with its last reference.
 * @param end The end, destroyed, about to go back to its pool; its core is set to 0.
 */
release_channel :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel]) {
    if end.core == 0 {
        return void
    }
    drop_core(kernel, end.core)
    end.core = 0
}

/**
 * Let go of one reference to a core: with the last, its ring memory and the core are freed.
 *
 * Takes no lock; the count is atomic.
 *
 * @param kernel The kernel, whose frames and core pool they go back to.
 * @param address The ChannelCore's address, which the caller holds a reference to (an end not yet released, or a
 *     mapping on a space's list) and mustn't use after.
 */
drop_core :: fn(kernel: ptr[mut Kernel], address: u64) {
    core :: cast[ptr[mut ChannelCore]](address)
    // It gives the count from before
    if intrinsics.interlocked_decrement_u32(&core.references) != 1 {
        return void
    }
    frames.free(&kernel.frames, cast[boot_info.PhysicalAddress](core.memory), core.order)
    slab.free(&kernel.pools.channel_cores, &kernel.frames, address)
}

/**
 * Map a channel's memory for an end's holder: both directions' indices and both rings, read/write, since both sides
 * write indices in both rings (ipc.md §2).
 *
 * The mapping is on the space's list of rings, holding a reference to the core, before anything is mapped, so
 * releasing the space lets go of it. Takes the core's lock, then the space's, never both at once. The page tables'
 * frames are charged to the space's budget.
 *
 * @param kernel The kernel, whose frames the page tables come from, and whose core pool the core goes back to if this
 *     held its last reference.
 * @param end The end, from a handle with RIGHT_CHANNEL_MAP; one end is mapped once at a time.
 * @param space The address space to map it in, from a handle with RIGHT_SPACE_MAP.
 * @param address Where: a page-aligned user virtual address, with slop_os.channel_memory_size(ring_bytes) bytes free
 *     from it in space, within the user address range.
 * @return Null once it's mapped; otherwise, with nothing mapped: BadAddress if address isn't page-aligned, in range or
 *     free, or the page tables couldn't map it; ObjectGone if the end or the space is being destroyed, the end even
 *     after it was mapped, when it's unmapped again; Mapped if the end is mapped already or being mapped or unmapped;
 *     InFlight if the end is in a handle batch on its way; OutOfMemory or BudgetExceeded if page tables couldn't be
 *     had.
 */
channel_map :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel], space: ptr[mut AddressSpace], address: u64) -> slop_os.ChannelError? {
    core :: core_of(end)
    side :: end.side
    size :: slop_os.channel_memory_size(core.ring_bytes)
    low, high :: arch.user_address_range()
    if address & (frames.FRAME_SIZE - 1) != 0 || address < cast[u64](low) || address >= cast[u64](high) || size > cast[u64](high) - address {
        return slop_os.ChannelError.BadAddress
    }
    mapping :: &side_of(core, side).mapping
    lock_at(&core.lock, .ChannelCore)
    if is_dying(cast[u64](end)) {
        unlock_at(&core.lock, .ChannelCore)
        return slop_os.ChannelError.ObjectGone
    }
    if mapping.state != .None {
        unlock_at(&core.lock, .ChannelCore)
        return slop_os.ChannelError.Mapped
    }
    if end.sending != 0 {
        unlock_at(&core.lock, .ChannelCore)
        return slop_os.ChannelError.InFlight
    }
    mapping.state = .Mapping
    mapping.doomed = false
    mapping.space = cast[u64](space)
    mapping.address = address
    unlock_at(&core.lock, .ChannelCore)
    // On the space's list first, so releasing the space lets go of what it maps
    lock_at(&space.lock, .Space)
    if is_dying(cast[u64](space)) {
        unlock_at(&space.lock, .Space)
        set_mapping_state(core, mapping, .None)
        return slop_os.ChannelError.ObjectGone
    }
    // A memory mapping there may have nothing in its page tables yet
    if !range_free(kernel, space, address, size) {
        unlock_at(&space.lock, .Space)
        set_mapping_state(core, mapping, .None)
        return slop_os.ChannelError.BadAddress
    }
    link_ring(space, mapping)
    _ = intrinsics.interlocked_increment_u32(&core.references)
    unlock_at(&space.lock, .Space)
    match map_user(kernel, space, address, core.memory, size, RING_MAPPING) {
        case Ok => {}
        case Error(error) => {
            lock_at(&space.lock, .Space)
            unlink_ring(space, mapping)
            unlock_at(&space.lock, .Space)
            drop_core(kernel, cast[u64](core))
            set_mapping_state(core, mapping, .None)
            return if error == .OutOfMemory { slop_os.ChannelError.OutOfMemory }
                else if error == .BudgetExceeded { slop_os.ChannelError.BudgetExceeded } else { slop_os.ChannelError.BadAddress }
        }
    }
    lock_at(&core.lock, .ChannelCore)
    if mapping.doomed {
        // The end was destroyed meanwhile, and left this for the mapper
        mapping.state = .Unmapping
        unlock_at(&core.lock, .ChannelCore)
        unmap_ring(kernel, core, side)
        return slop_os.ChannelError.ObjectGone
    }
    mapping.state = .Mapped
    unlock_at(&core.lock, .ChannelCore)
    return null
}

/** How a channel's memory is mapped for user mode: read/write, never executable, write-back, per address space. */
RING_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = true, global = false}

/**
 * Unmap what channel_map mapped for an end.
 *
 * Takes the core's lock, then unmaps with the space's (unmap_ring), and shoots down the TLB entries.
 *
 * @param kernel The kernel: the unmapping is shot down on its CPUs, freed page tables go back to its frames, and the
 *     core to its pool with its last reference.
 * @param end The end; no right is needed.
 * @return Null once it's unmapped; BadAddress if it isn't mapped, or is being mapped or unmapped.
 */
channel_unmap :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel]) -> slop_os.ChannelError? {
    core :: core_of(end)
    mapping :: &side_of(core, end.side).mapping
    lock_at(&core.lock, .ChannelCore)
    if mapping.state != .Mapped {
        unlock_at(&core.lock, .ChannelCore)
        return slop_os.ChannelError.BadAddress
    }
    mapping.state = .Unmapping
    unlock_at(&core.lock, .ChannelCore)
    unmap_ring(kernel, core, end.side)
    return null
}

/**
 * Set a mapping's state under its core's lock.
 *
 * @param core The core, whose lock is taken; the caller doesn't hold it.
 * @param mapping One of the core's sides' mappings.
 * @param state Its new state.
 */
set_mapping_state :: fn(core: ptr[mut ChannelCore], mapping: ptr[mut RingMapping], state: MappingState) {
    lock_at(&core.lock, .ChannelCore)
    mapping.state = state
    unlock_at(&core.lock, .ChannelCore)
}

/**
 * Unmap a side's rings, in Unmapping: unless its space was released first, which let go of it. Page by
 * page, with the space's lock, checking each time it's still on the space's list, so the space's tables
 * are never freed under it; off the list once it's all unmapped. A space being destroyed has its tables
 * released whole, without its lock, once a grace period has passed, which this CPU may already have passed
 * through, so its tables aren't touched: the ring is only taken off its list, here or by the release,
 * whichever comes first, and that one lets go of the core (decisions/0145).
 *
 * Takes the space's lock for each step, and the core's at the end to set the state back to None; the caller holds
 * neither.
 *
 * @param kernel The kernel, whose page-table frames freed go back, after their TLB entries are shot down.
 * @param core The channel's core, which the mapping holds a reference to until it's off its space's list.
 * @param side The end whose mapping it is, 0 or 1; its state is Unmapping.
 */
unmap_ring :: fn(kernel: ptr[mut Kernel], core: ptr[mut ChannelCore], side: u32) {
    mapping :: &side_of(core, side).mapping
    space :: cast[ptr[mut AddressSpace]](mapping.space)
    pages :: slop_os.channel_memory_size(core.ring_bytes) / frames.FRAME_SIZE
    flush : arch_interface.TlbBatch
    freed : arch_interface.FreedTables
    page : u64 = 0
    dropped := false
    loop {
        lock_at(&space.lock, .Space)
        if !mapping.linked {
            unlock_at(&space.lock, .Space)
            break
        }
        if is_dying(cast[u64](space)) {
            unlink_ring(space, mapping)
            dropped = true
            unlock_at(&space.lock, .Space)
            break
        }
        page = unmap_some(&space.table, mapping.address, page, pages, &freed, &flush)
        if page >= pages {
            unlink_ring(space, mapping)
            dropped = true
        }
        unlock_at(&space.lock, .Space)
        shootdown(kernel, &flush)
        flush = arch_interface.TlbBatch.{}
        free_tables(kernel, &freed)
        if dropped {
            break
        }
    }
    set_mapping_state(core, mapping, .None)
    if dropped {
        drop_core(kernel, cast[u64](core))
    }
}

/**
 * Put a ring mapping first on its space's list of rings.
 *
 * Takes the space's lock as held. The list holds a reference to the mapping's core, which the caller takes.
 *
 * @param space The space it's mapped in.
 * @param mapping The mapping, not on any list.
 */
link_ring :: fn(space: ptr[mut AddressSpace], mapping: ptr[mut RingMapping]) {
    mapping.previous = 0
    mapping.next = space.first_ring
    if space.first_ring != 0 {
        cast[ptr[mut RingMapping]](space.first_ring).previous = cast[u64](mapping)
    }
    space.first_ring = cast[u64](mapping)
    mapping.linked = true
}

/**
 * Take a ring mapping off its space's list of rings, if it's on it.
 *
 * Takes the space's lock as held. The caller lets go of the core reference the list held.
 *
 * @param space The space it's mapped in.
 * @param mapping The mapping, on the list or not.
 */
unlink_ring :: fn(space: ptr[mut AddressSpace], mapping: ptr[mut RingMapping]) {
    if !mapping.linked {
        return void
    }
    if mapping.previous != 0 {
        cast[ptr[mut RingMapping]](mapping.previous).next = mapping.next
    }
    else {
        space.first_ring = mapping.next
    }
    if mapping.next != 0 {
        cast[ptr[mut RingMapping]](mapping.next).previous = mapping.previous
    }
    mapping.linked = false
}

/**
 * Take the first ring mapping off a space's list, as a space being released lets go of them.
 *
 * Takes the space's lock as held.
 *
 * @param space The space being released, whose lock the caller holds.
 * @return The RingMapping's address, its core reference now the caller's to let go of; 0 if the list is empty.
 */
take_ring :: fn(space: ptr[mut AddressSpace]) -> u64 {
    first :: space.first_ring
    if first != 0 {
        unlink_ring(space, cast[ptr[mut RingMapping]](first))
    }
    return first
}

/**
 * Raise Readable or Writable on the other end: the doorbell of the rings' wake protocol, after writing or reading a
 * ring directly.
 *
 * Takes the core's lock, then each bound port's.
 *
 * @param kernel The kernel, whose timer heaps and run queues waking a port's waiter goes through.
 * @param end The caller's end; no right is needed.
 * @param signals Which to raise: slop_os.SIGNAL_READABLE, slop_os.SIGNAL_WRITABLE, or both; other bits are ignored,
 *     and none raises nothing.
 * @return Null once they're raised; PeerClosed if the other end is closed.
 */
channel_notify :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel], signals: slop_os.Signals) -> slop_os.ChannelError? {
    core :: core_of(end)
    lock_at(&core.lock, .ChannelCore)
    defer unlock_at(&core.lock, .ChannelCore)
    if side_of(core, 1 - end.side).closed {
        return slop_os.ChannelError.PeerClosed
    }
    raised :: cast[u32](signals) & cast[u32](slop_os.SIGNAL_READABLE | slop_os.SIGNAL_WRITABLE)
    raise_signals(kernel, core, 1 - end.side, raised)
    return null
}

/**
 * Raise signals on one end: each binding that sees any of them, and is armed, takes them into its packet.
 *
 * Takes the core's lock as held, and each bound port's in turn. A binding its port dropped is skipped.
 *
 * @param kernel The kernel, whose timer heaps and run queues waking a port's waiter goes through.
 * @param core The channel's core.
 * @param side The end the signals are raised on, 0 or 1.
 * @param signals The slop_os.SIGNAL_ bits raised; 0 raises nothing.
 */
raise_signals :: fn(kernel: ptr[mut Kernel], core: ptr[mut ChannelCore], side: u32, signals: u32) {
    if signals == 0 {
        return void
    }
    kept :: side_of(core, side)
    for i in 0..<MAX_END_BINDINGS {
        slot :: &kept.bindings[i]
        if slot.binding != 0 {
            binding :: cast[ptr[mut Binding]](slot.binding)
            // A binding the port dropped is no longer this one, whatever its slot holds now
            match lock_bound_port(binding, slot.generation) {
                case Some(port) => {
                    signal_binding(kernel, port, binding, signals)
                    unlock_at(&port.lock, .Port)
                }
                case None => {}
            }
        }
    }
}

/**
 * Raise signals on a signal binding: if it's armed and sees any of them, they're ORed into its data and its packet is
 * queued, disarming it if it's Once.
 *
 * Takes the port's lock as held.
 *
 * @param kernel The kernel, whose timer heaps and run queues waking a port's waiter goes through.
 * @param port The binding's port.
 * @param binding A signal binding on port; its signals, armed and once fields say what it does.
 * @param signals The slop_os.SIGNAL_ bits raised; only those it sees count.
 */
signal_binding :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], binding: ptr[mut Binding], signals: u32) {
    seen :: signals & binding.signals
    if !binding.armed || seen == 0 {
        return void
    }
    binding.data |= cast[u64](seen)
    if binding.once {
        binding.armed = false
    }
    queue_binding(kernel, port, binding)
}

/**
 * Drop a side's binding slot: the binding, off its port, unless the port dropped it first.
 *
 * Takes the core's lock as held, and the port's. The slot is free afterwards.
 *
 * @param kernel The kernel, whose binding pool the binding goes back to.
 * @param slot The slot, used or free.
 */
drop_end_binding :: fn(kernel: ptr[mut Kernel], slot: ptr[mut EndBinding]) {
    if slot.binding == 0 {
        return void
    }
    binding :: cast[ptr[mut Binding]](slot.binding)
    match lock_bound_port(binding, slot.generation) {
        case Some(port) => {
            _ = maps.map_remove(&port.bindings, binding.key)
            free_binding(kernel, port, binding)
            unlock_at(&port.lock, .Port)
        }
        case None => {}
    }
    slot.binding = 0
}

/**
 * Bind key on a port to a channel end's signals, queuing a Signal packet when the end raises any of them.
 *
 * Binding key again to the same end arms it again, with the new signals and mode. PeerClosed stays raised, so binding
 * to an end whose peer is closed queues a packet at once; and so does binding for Readable to an end with messages
 * waiting, which no read has found empty, so nothing else would raise it (decisions/0099). Binding for Readable to an
 * empty end says its reader waits, as a read finding it empty does, so the next message raises Readable: a new end
 * bound and not yet read, as a service's client in a place it has already read past this pass, is woken by its first
 * message (decisions/0144).
 *
 * Takes the core's lock, then the port's. A new binding is charged to the port's budget.
 *
 * @param kernel The kernel, whose binding pool a new binding comes from.
 * @param port The port, from a handle with RIGHT_PORT_BIND.
 * @param end The channel end to watch.
 * @param signals The slop_os.SIGNAL_ bits to queue a packet for; the end raises Readable, Writable and PeerClosed.
 * @param key The key: one not yet bound on the port, or one already bound to this same end.
 * @param mode Once, disarmed after each packet until it's bound again, or Persistent, armed until it's unbound.
 * @return Null once it's bound and armed; otherwise ObjectGone if the end or the port is being destroyed, KeyInUse if
 *     key is bound to anything else, TooManyBindings if the end has MAX_END_BINDINGS bindings already, or
 *     BudgetExceeded or OutOfMemory if a new binding couldn't be made (binding_failure).
 */
port_bind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], end: ptr[mut Channel], signals: slop_os.Signals, key: u64,
    mode: slop_os.BindMode) -> slop_os.PortError? {
    core :: core_of(end)
    side :: end.side
    lock_at(&core.lock, .ChannelCore)
    defer unlock_at(&core.lock, .ChannelCore)
    if is_dying(cast[u64](end)) {
        return slop_os.PortError.ObjectGone
    }
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    binding := cast[ptr[mut Binding]](0)
    match maps.map_get(&port.bindings, key) {
        case Some(address) => {
            existing :: cast[ptr[mut Binding]](address)
            if existing.kind != .Signal || existing.object != cast[u64](end) || existing.object_generation != end.header.generation {
                return slop_os.PortError.KeyInUse
            }
            binding = existing
        }
        case None => {
            free_slot := cast[ptr[mut EndBinding]](0)
            kept :: side_of(core, side)
            for i in 0..<MAX_END_BINDINGS {
                slot :: &kept.bindings[i]
                if cast[u64](free_slot) == 0 && (slot.binding == 0 || cast[ptr[Binding]](slot.binding).generation != slot.generation) {
                    free_slot = slot
                }
            }
            if cast[u64](free_slot) == 0 {
                return slop_os.PortError.TooManyBindings
            }
            binding = new_binding(kernel, port, key, .Signal) or_return binding_failure(port)
            binding.object = cast[u64](end)
            binding.object_generation = end.header.generation
            free_slot.binding = cast[u64](binding)
            free_slot.generation = binding.generation
        }
    }
    binding.signals = cast[u32](signals)
    binding.once = mode == .Once
    binding.armed = true
    if side_of(core, 1 - side).closed {
        signal_binding(kernel, port, binding, cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    }
    incoming :: indices_of(kernel, core, 1 - side)
    if cast[u32](signals) & cast[u32](slop_os.SIGNAL_READABLE) != 0 {
        intrinsics.atomic_store_u32(&incoming.consumer_waiting, 1)
        intrinsics.fence_sequentially_consistent()
    }
    if intrinsics.atomic_load_u32_acquire(&incoming.tail) != intrinsics.atomic_load_u32(&incoming.head) {
        signal_binding(kernel, port, binding, cast[u32](slop_os.SIGNAL_READABLE))
    }
    return null
}

/**
 * Write one message into the ring an end writes, through the kernel, as a producer mapping the ring would write it.
 *
 * Without room, it says it waits for room (producer_waiting), then looks again, and fails with Full: the reader raises
 * Writable once it makes some. If the reader waits for a message, Readable is raised on its end. The ring's indices
 * are untrusted, since the other end may have mapped them. Takes the core's lock, and the bound ports' when it raises
 * Readable.
 *
 * @param kernel The kernel, for the direct map the ring and the payload are reached through, and the run queues a woken
 *     reader goes on.
 * @param thread The calling thread, from whose address space the payload is copied.
 * @param end The caller's end; no right is needed.
 * @param payload The payload's start: a user virtual address in the thread's space, any alignment.
 * @param size The payload's size in bytes, at most slop_os.channel_max_payload of the ring's size; 0 writes a message
 *     with only its header.
 * @param batch The handle batch, numbered below slop_os.HANDLE_BATCHES, whose handles the message carries, or
 *     slop_os.NO_BATCH for none. It isn't checked to hold anything; the reader takes it with channel_take_handles.
 * @return Null once the message is written and its tail published; otherwise, with nothing written: TooBig if size is
 *     over the largest payload; NoSuchBatch for a batch out of range; PeerClosed if the other end is closed; Corrupt if
 *     the ring's indices are impossible; Full if the ring hasn't room for the message now; or BadBuffer if the payload
 *     isn't readable user memory.
 */
channel_write :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], end: ptr[mut Channel], payload: u64, size: u32,
    batch: u32) -> slop_os.ChannelError? {
    core :: core_of(end)
    side :: end.side
    ring_bytes :: core.ring_bytes
    if size > slop_os.channel_max_payload(ring_bytes) {
        return slop_os.ChannelError.TooBig
    }
    if batch != slop_os.NO_BATCH && batch >= slop_os.HANDLE_BATCHES {
        return slop_os.ChannelError.NoSuchBatch
    }
    lock_at(&core.lock, .ChannelCore)
    defer unlock_at(&core.lock, .ChannelCore)
    if side_of(core, 1 - side).closed {
        return slop_os.ChannelError.PeerClosed
    }
    indices :: indices_of(kernel, core, side)
    record :: cast[u32](size_of(slop_os.MessageHeader)) + ((size + 7) & ~cast[u32](7))
    intrinsics.atomic_store_u32(&indices.producer_waiting, 0)
    tail :: intrinsics.atomic_load_u32(&indices.tail)
    head := intrinsics.atomic_load_u32_acquire(&indices.head)
    if tail - head > ring_bytes {
        return slop_os.ChannelError.Corrupt
    }
    if ring_bytes - (tail - head) < record {
        intrinsics.atomic_store_u32(&indices.producer_waiting, 1)
        intrinsics.fence_sequentially_consistent()
        head = intrinsics.atomic_load_u32_acquire(&indices.head)
        if tail - head > ring_bytes {
            return slop_os.ChannelError.Corrupt
        }
        if ring_bytes - (tail - head) < record {
            return slop_os.ChannelError.Full
        }
        intrinsics.atomic_store_u32(&indices.producer_waiting, 0)
    }
    ring :: ring_of(kernel, core, side)
    mask :: ring_bytes - 1
    header :: slop_os.MessageHeader.{
        size = size,
        flags = if batch == slop_os.NO_BATCH { cast[u16](0) } else { slop_os.MESSAGE_HAS_HANDLES },
        handle_batch = if batch == slop_os.NO_BATCH { cast[u16](0) } else { cast[u16](batch) },
    }
    // Headers are 8-byte aligned in a ring a power of two in size, so one never wraps
    intrinsics.mem_copy(cast[mut rawptr](ring + cast[u64](tail & mask)), cast[rawptr](&header), size_of(slop_os.MessageHeader))
    start :: (tail + 8) & mask
    first :: if size < ring_bytes - start { size } else { ring_bytes - start }
    if !copy_from_user(kernel, thread.space, payload, ring + cast[u64](start), cast[u64](first))
        || !copy_from_user(kernel, thread.space, payload + cast[u64](first), ring, cast[u64](size - first)) {
        return slop_os.ChannelError.BadBuffer
    }
    intrinsics.atomic_store_u32_release(&indices.tail, tail + record)
    intrinsics.fence_sequentially_consistent()
    if intrinsics.atomic_load_u32(&indices.consumer_waiting) != 0 {
        raise_signals(kernel, core, 1 - side, cast[u32](slop_os.SIGNAL_READABLE))
    }
    return null
}

/**
 * What reading a message comes to: its size, and its flags and its batch's in the high 16 bits; or the
 * error, and for BufferTooSmall, the message's size.
 */
ReadOutcome :: union {
    /** A message was read: its payload's size in bytes, and its header's flags with its batch's number at bit 16. */
    Read(u32, u32),
    /** No message was read: the error, and for BufferTooSmall the message's payload size in bytes, otherwise 0. */
    Failed(slop_os.ChannelError, u32),
}

/**
 * Read the next message from the other end's ring, through the kernel, as a consumer mapping the ring would read it:
 * the header is read once, and checked against what the ring holds.
 *
 * With nothing to read, it says it waits for a message (consumer_waiting), then looks again, and fails with Empty, or
 * PeerClosed once nothing more can come. If the writer waits for room, Writable is raised on its end. Takes the core's
 * lock, and the bound ports' when it raises Writable.
 *
 * @param kernel The kernel, for the direct map the ring and the buffer are reached through, and the run queues a woken
 *     writer goes on.
 * @param thread The calling thread, into whose address space the payload is copied.
 * @param end The caller's end; no right is needed.
 * @param buffer Where the payload goes: a user virtual address in the thread's space, any alignment.
 * @param capacity How many bytes fit at buffer; a message bigger than that stays in the ring.
 * @return Read with the message's size and flags once it's copied and consumed; or Failed with: Empty if there's no
 *     message and the other end is open, PeerClosed if there's none and it's closed, Corrupt if the indices or the
 *     header are impossible, BufferTooSmall with the size needed, or BadBuffer if buffer isn't writable user memory,
 *     when the message stays in the ring.
 */
channel_read :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], end: ptr[mut Channel], buffer: u64, capacity: u32) -> ReadOutcome {
    core :: core_of(end)
    peer :: 1 - end.side
    ring_bytes :: core.ring_bytes
    lock_at(&core.lock, .ChannelCore)
    defer unlock_at(&core.lock, .ChannelCore)
    indices :: indices_of(kernel, core, peer)
    intrinsics.atomic_store_u32(&indices.consumer_waiting, 0)
    head :: intrinsics.atomic_load_u32(&indices.head)
    tail := intrinsics.atomic_load_u32_acquire(&indices.tail)
    if tail == head {
        intrinsics.atomic_store_u32(&indices.consumer_waiting, 1)
        intrinsics.fence_sequentially_consistent()
        tail = intrinsics.atomic_load_u32_acquire(&indices.tail)
        if tail == head {
            return .Failed(if side_of(core, peer).closed { slop_os.ChannelError.PeerClosed } else { slop_os.ChannelError.Empty }, 0)
        }
        intrinsics.atomic_store_u32(&indices.consumer_waiting, 0)
    }
    used :: tail - head
    mask :: ring_bytes - 1
    header : slop_os.MessageHeader
    if used > ring_bytes || used < 8 || head & 7 != 0 {
        return .Failed(.Corrupt, 0)
    }
    ring :: ring_of(kernel, core, peer)
    intrinsics.mem_copy(cast[mut rawptr](&header), cast[rawptr](ring + cast[u64](head & mask)), size_of(slop_os.MessageHeader))
    size :: header.size
    if size > slop_os.channel_max_payload(ring_bytes) {
        return .Failed(.Corrupt, 0)
    }
    record :: cast[u32](size_of(slop_os.MessageHeader)) + ((size + 7) & ~cast[u32](7))
    if record > used {
        return .Failed(.Corrupt, 0)
    }
    if size > capacity {
        return .Failed(.BufferTooSmall, size)
    }
    start :: (head + 8) & mask
    first :: if size < ring_bytes - start { size } else { ring_bytes - start }
    if !copy_to_user(kernel, thread.space, buffer, ring + cast[u64](start), cast[u64](first))
        || !copy_to_user(kernel, thread.space, buffer + cast[u64](first), ring, cast[u64](size - first)) {
        return .Failed(.BadBuffer, 0)
    }
    intrinsics.atomic_store_u32_release(&indices.head, head + record)
    intrinsics.fence_sequentially_consistent()
    if intrinsics.atomic_load_u32(&indices.producer_waiting) != 0 {
        raise_signals(kernel, core, peer, cast[u32](slop_os.SIGNAL_WRITABLE))
    }
    return .Read(size, cast[u32](header.flags) | (cast[u32](header.handle_batch) << 16))
}

/**
 * Move handles out of the caller's table into a batch on the other end, for a message to name.
 *
 * Each handle needs RIGHT_TRANSFER, and none can be this channel's own ends, nor an end whose rings are mapped; ends
 * sent are held unmapped until the batch is taken or dropped. Objects whose owning handles go keep their owner until
 * the batch is taken; if it never is, they're destroyed with it. A handle closed between the checks and the move goes
 * as nothing. The batch is charged to this end's budget until it's taken. Takes the core's lock in short spells, and
 * the handle table's.
 *
 * @param kernel The kernel, whose heap the batch comes from.
 * @param thread The calling thread, whose process's handles are moved.
 * @param end The caller's end; no right is needed.
 * @param handles The handles' start: a user virtual address in the thread's space of count slop_os.Handle values.
 * @param count How many handles, at most slop_os.MAX_HANDLES_PER_BATCH; 0 sends an empty batch.
 * @param batch The batch number on the other end, below slop_os.HANDLE_BATCHES, which has to be free.
 * @return Null once the handles are in the batch, out of the caller's table; otherwise the error. TooBig, NoSuchBatch,
 *     BadBuffer, InvalidHandle, ObjectGone, MissingRight, NotTransferable, BudgetExceeded, OutOfMemory, PeerClosed and
 *     BatchInUse leave every handle where it was; so does Mapped, if an end among them is mapped. PeerClosed found
 *     after the move drops the batch: the handles are gone, and owning ones' objects destroyed.
 */
channel_send_handles :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], end: ptr[mut Channel], handles: u64, count: u32,
    batch: u32) -> slop_os.ChannelError? {
    if count > slop_os.MAX_HANDLES_PER_BATCH {
        return slop_os.ChannelError.TooBig
    }
    if batch >= slop_os.HANDLE_BATCHES {
        return slop_os.ChannelError.NoSuchBatch
    }
    given : slop_os.Handle[64]
    if !copy_from_user(kernel, thread.space, handles, cast[u64](&given[0]), cast[u64](count) * 4) {
        return slop_os.ChannelError.BadBuffer
    }
    process :: process_of(thread)
    core :: core_of(end)
    for i in 0..<cast[usize](count) {
        match lookup(&process.table, given[i]) {
            case Ok(found) => {
                if cast[u32](found.rights) & cast[u32](slop_os.RIGHT_TRANSFER) == 0 {
                    return slop_os.ChannelError.MissingRight
                }
                if found.kind == .Channel && cast[ptr[Channel]](found.object).core == end.core {
                    return slop_os.ChannelError.NotTransferable
                }
            }
            case Error(error) => return if error == .ObjectGone { slop_os.ChannelError.ObjectGone } else { slop_os.ChannelError.InvalidHandle }
        }
    }
    if !charge_more(cast[u64](end), cast[u64](size_of(HandleBatch))) {
        return slop_os.ChannelError.BudgetExceeded
    }
    block :: allocate_block(kernel, cast[u64](size_of(HandleBatch))) or_else 0
    if block == 0 {
        uncharge(cast[u64](end), end.header.generation, cast[u64](size_of(HandleBatch)))
        return slop_os.ChannelError.OutOfMemory
    }
    filled :: cast[ptr[mut HandleBatch]](block)
    filled.count = 0
    filled.sender = cast[u64](end)
    filled.sender_generation = end.header.generation
    peer :: 1 - end.side
    slot :: &side_of(core, peer).batches[cast[usize](batch) % 16]
    lock_at(&core.lock, .ChannelCore)
    failure := cast[u32](0)
    if side_of(core, peer).closed {
        failure = cast[u32](slop_os.ChannelError.PeerClosed)
    }
    else if slot^ != 0 {
        failure = cast[u32](slop_os.ChannelError.BatchInUse)
    }
    else {
        slot^ = RESERVED
    }
    unlock_at(&core.lock, .ChannelCore)
    if failure != 0 {
        free_batch(kernel, block)
        return cast[slop_os.ChannelError](failure)
    }
    // Ends being sent are held unmapped until the batch is taken or dropped
    for i in 0..<cast[usize](count) {
        match lookup(&process.table, given[i]) {
            case Ok(found) => {
                if found.kind == .Channel && !hold_for_sending(cast[ptr[mut Channel]](found.object)) {
                    let_go_of_ends(filled, cast[u32](i), &process.table, &given)
                    set_batch(core, slot, 0)
                    free_batch(kernel, block)
                    return slop_os.ChannelError.Mapped
                }
            }
            case Error(error) => {}
        }
    }
    // Out of the table; one closed meanwhile goes as nothing
    for i in 0..<cast[usize](count) {
        filled.entries[i] = Resolved.{}
        match remove(&process.table, given[i]) {
            case Ok(removed) => filled.entries[i] = removed
            case Error(error) => {}
        }
    }
    filled.count = count
    lock_at(&core.lock, .ChannelCore)
    closed :: side_of(core, peer).closed
    slot^ = if closed { cast[u64](0) } else { block }
    unlock_at(&core.lock, .ChannelCore)
    if closed {
        drop_batch(kernel, filled)
        return slop_os.ChannelError.PeerClosed
    }
    return null
}

/**
 * Set a batch slot under its core's lock.
 *
 * @param core The core, whose lock is taken; the caller doesn't hold it.
 * @param slot One of the core's sides' batch slots.
 * @param value A HandleBatch's address, RESERVED, or 0 to free it.
 */
set_batch :: fn(core: ptr[mut ChannelCore], slot: ptr[mut u64], value: u64) {
    lock_at(&core.lock, .ChannelCore)
    slot^ = value
    unlock_at(&core.lock, .ChannelCore)
}

/**
 * Hold an end that's about to be sent unmapped: unless its rings are mapped, it can't be mapped until it arrives.
 *
 * Takes the end's core's lock. Each hold is let go of by let_go_of_end.
 *
 * @param end The end being sent, any channel's.
 * @return True if it's held, its sending count one more; false if its rings are mapped, or being mapped or unmapped,
 *     when it isn't.
 */
hold_for_sending :: fn(end: ptr[mut Channel]) -> bool {
    core :: core_of(end)
    lock_at(&core.lock, .ChannelCore)
    defer unlock_at(&core.lock, .ChannelCore)
    if side_of(core, end.side).mapping.state != .None {
        return false
    }
    end.sending += 1
    return true
}

/**
 * An end held by hold_for_sending let go of, if it's still the end with generation. One destroyed since may have been
 * released, its core with it, before this call (a copy of it in a batch keeps nothing alive): its generation says so.
 * One that's still its own can't be released until this CPU passes a quiescent point (objects.hsc), so its core stays.
 *
 * Takes the end's core's lock.
 *
 * @param end The end, as a batch kept it; its slot may have been released and reused since.
 * @param generation The end's generation when it was held.
 */
let_go_of_end :: fn(end: ptr[mut Channel], generation: u32) {
    if intrinsics.atomic_load_u32_acquire(&end.header.generation) != generation {
        return void
    }
    core :: core_of(end)
    lock_at(&core.lock, .ChannelCore)
    if end.header.generation == generation && end.sending != 0 {
        end.sending -= 1
    }
    unlock_at(&core.lock, .ChannelCore)
}

/**
 * Let go again of the ends among the first handles of a send that failed part way, held by hold_for_sending.
 *
 * @param filled The batch being filled; unused, its entries aren't filled in yet.
 * @param count How many of the handles were held, from the first.
 * @param table The sender's handle table, where the handles still are; one closed meanwhile is skipped.
 * @param given The handles, as the sender gave them.
 */
let_go_of_ends :: fn(filled: ptr[HandleBatch], count: u32, table: ptr[HandleTable], given: ptr[slop_os.Handle[64]]) {
    for handle, i in given^ {
        if i >= cast[usize](count) {
            break
        }
        match lookup(table, handle) {
            case Ok(found) => {
                if found.kind == .Channel {
                    let_go_of_end(cast[ptr[mut Channel]](found.object), found.generation)
                }
            }
            case Error(error) => {}
        }
    }
}

/**
 * Drop a batch that won't be taken: ends in it are let go of, and owning handles' objects are destroyed, as closing
 * them would, once the destroy running on this CPU is done (destroy_later). The batch is freed.
 *
 * @param kernel The kernel: owning handles' objects are destroyed through it, and the batch goes back to its heap.
 * @param batch The batch, filled in and in no slot; it's freed, so the caller mustn't use it after.
 */
drop_batch :: fn(kernel: ptr[mut Kernel], batch: ptr[mut HandleBatch]) {
    for entry, i in batch.entries {
        if i >= cast[usize](batch.count) {
            break
        }
        if entry.object != 0 {
            if entry.kind == .Channel {
                let_go_of_end(cast[ptr[mut Channel]](entry.object), entry.generation)
            }
            if entry.owning {
                destroy_later(kernel, entry.object, entry.generation)
            }
        }
    }
    free_batch(kernel, cast[u64](batch))
}

/** How many handles were taken; or the error, and for BufferTooSmall, how many there are. */
TakeOutcome :: union {
    /** The handles were taken: how many there were, each written, NO_HANDLE for one that couldn't be had. */
    Taken(u32),
    /** None were taken: the error, and for BufferTooSmall how many handles the batch holds, otherwise 0. */
    Failed(slop_os.ChannelError, u32),
}

/**
 * Take a batch's handles into the caller's table, in order, writing them to its memory.
 *
 * One whose object was destroyed meanwhile, or that doesn't fit in the table, comes out as NO_HANDLE. An object whose
 * owning handle comes is the caller's process's from then on, its charge moved to that process's budget: all of them,
 * or the batch stays (decisions/0011). Takes the core's lock, then the handle table's after letting go of it.
 *
 * @param kernel The kernel: charges move under its budgets_lock, the handle table's new pages come from its frames, the
 *     handles are written through its direct map, and the batch goes back to its heap.
 * @param thread The calling thread, whose process takes the handles.
 * @param end The caller's end, which the batch was sent to; no right is needed.
 * @param batch The batch number, below slop_os.HANDLE_BATCHES.
 * @param handles Where the handles go: a user virtual address in the thread's space, room for capacity
 *     slop_os.Handle values.
 * @param capacity How many handles fit at handles.
 * @return Taken with the batch's count once they're taken and the batch freed; or Failed with: NoSuchBatch if the
 *     number is out of range or the batch is empty or still being filled; BufferTooSmall with the count, BadBuffer, or
 *     BudgetExceeded if the caller's budget can't take the objects' charges, all leaving the batch as it was; or
 *     BadBuffer if writing the handles failed after they were taken, when they're in the table but the caller can't
 *     know their values.
 */
channel_take_handles :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], end: ptr[mut Channel], batch: u32, handles: u64,
    capacity: u32) -> TakeOutcome {
    if batch >= slop_os.HANDLE_BATCHES {
        return .Failed(.NoSuchBatch, 0)
    }
    core :: core_of(end)
    slot :: &side_of(core, end.side).batches[cast[usize](batch) % 16]
    lock_at(&core.lock, .ChannelCore)
    address :: slot^
    if address <= RESERVED {
        unlock_at(&core.lock, .ChannelCore)
        return .Failed(.NoSuchBatch, 0)
    }
    taken :: cast[ptr[mut HandleBatch]](address)
    count :: taken.count
    if count > capacity {
        unlock_at(&core.lock, .ChannelCore)
        return .Failed(.BufferTooSmall, count)
    }
    if !is_user_writable(thread.space, handles, cast[u64](count) * 4) {
        unlock_at(&core.lock, .ChannelCore)
        return .Failed(.BadBuffer, 0)
    }
    process :: process_of(thread)
    // What the owning handles own is charged to the taker's budget from now on, or the batch stays (decisions/0011)
    owned : u64[64]
    owned_count := cast[u32](0)
    for entry, i in taken.entries {
        if i >= cast[usize](count) {
            break
        }
        if entry.object != 0 && entry.owning && is_live(entry.object, entry.generation) {
            owned[cast[usize](owned_count) % 64] = entry.object
            owned_count += 1
        }
    }
    if !move_charges(kernel, &owned, owned_count, process.header.budget) {
        unlock_at(&core.lock, .ChannelCore)
        return .Failed(.BudgetExceeded, 0)
    }
    slot^ = 0
    unlock_at(&core.lock, .ChannelCore)
    installed : slop_os.Handle[64]
    for entry, i in taken.entries {
        if i >= cast[usize](count) {
            break
        }
        if entry.object != 0 {
            if entry.kind == .Channel {
                let_go_of_end(cast[ptr[mut Channel]](entry.object), entry.generation)
            }
            if is_live(entry.object, entry.generation) {
                installed[i] = take_one(kernel, process, entry)
            }
        }
    }
    free_batch(kernel, address)
    if !copy_to_user(kernel, thread.space, handles, cast[u64](&installed[0]), cast[u64](count) * 4) {
        return .Failed(.BadBuffer, 0)
    }
    return .Taken(count)
}

/**
 * Install one handle from a batch in a process's table; an object whose owning handle it is, adopted first, or
 * destroyed if that fails.
 *
 * Takes the owner lists' locks, then the handle table's.
 *
 * @param kernel The kernel: the table's new pages come from its frames, and an object that can't be taken is destroyed
 *     through it.
 * @param process The process taking it.
 * @param entry The handle, as the batch kept it: its object live, its rights and whether it owns kept as they were.
 * @return The handle in process's table; slop_os.NO_HANDLE if process is being destroyed or its table is full or
 *     closed, when an owning handle's object is destroyed (destroy_later).
 */
take_one :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], entry: Resolved) -> slop_os.Handle {
    if entry.owning {
        disown(entry.object)
        if !adopted(cast[u64](process), entry.object) {
            destroy_later(kernel, entry.object, entry.generation)
            return slop_os.NO_HANDLE
        }
    }
    match install(kernel, &process.table, entry.object, entry.generation, entry.kind, entry.rights, entry.owning) {
        case Ok(handle) => return handle
        case Error(error) => {
            if entry.owning {
                destroy_later(kernel, entry.object, entry.generation)
            }
            return slop_os.NO_HANDLE
        }
    }
}
