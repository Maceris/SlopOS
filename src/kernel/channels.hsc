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

// The ports an end can be bound to at once.
MAX_END_BINDINGS :: 4

MappingState :: enum #backed_by(u8) {
    None,
    // ChannelMap is mapping it; if the end is destroyed meanwhile, it's doomed, and unmapped once mapped.
    Mapping,
    Mapped,
    // Being unmapped.
    Unmapping,
}

/*
 * Where an end's rings are mapped. Its state is under the core's lock; whether it's linked into its
 * space's list of rings, and the links, under the space's.
 */
RingMapping :: struct {
    state : MappingState,
    doomed : bool,
    linked : bool,
    space : u64,
    address : u64,
    core : u64,
    next : u64,
    previous : u64,
}

// A signal binding of an end's: the binding, and its generation, which changes once the port drops it.
EndBinding :: struct {
    binding : u64,
    generation : u32,
}

// What a channel's core keeps for each end.
CoreSide :: struct {
    end : u64,
    // Once its end is destroyed.
    closed : bool,
    mapping : RingMapping,
    bindings : EndBinding[MAX_END_BINDINGS],
    // Batches of handles sent to it: a HandleBatch's address, RESERVED while the sender fills it in, 0
    // for none.
    batches : u64[16],
}

// What a channel's ends share, freed once both are released and no mapping is left.
ChannelCore :: struct #align(16) {
    // The slab allocator's, while the slot is free.
    free_link : u64,
    lock : concurrency.SpinLock,
    // The ends not yet released, and the mappings of its memory.
    references : u32,
    // The ring memory: 2^order contiguous frames.
    memory : u64,
    order : u64,
    ring_bytes : u32,
    sides : CoreSide[2],
}

RESERVED : u64 : 1

// A channel end.
Channel :: struct #align(16) {
    header : ObjectHeader,
    core : u64,
    side : u32,
    // Batches in flight with it in, under its core's lock: it can't be mapped meanwhile.
    sending : u32,
}

// Handles in flight, from the kernel heap, charged to the end that sent them while it lives.
HandleBatch :: struct {
    count : u32,
    sender_generation : u32,
    sender : u64,
    entries : Resolved[64],
}

// A batch, freed, its charge back to its sender if that's still the same end.
free_batch :: fn(kernel: ptr[mut Kernel], address: u64) {
    batch :: cast[ptr[mut HandleBatch]](address)
    if batch.sender != 0 {
        uncharge(batch.sender, batch.sender_generation, cast[u64](size_of(HandleBatch)))
    }
    free_block(kernel, address, cast[u64](size_of(HandleBatch)))
}

ChannelPair :: struct {
    a : ptr[mut Channel],
    b : ptr[mut Channel],
}

/*
 * A channel with rings of ring_bytes each way (0 for the default), its ends owned by owner (a Process's
 * address, 0 for the kernel), charged to budget: end A with the core and the rings, end B its slot.
 */
create_channel :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, ring_bytes: u32) -> Result[ChannelPair, slop_os.ChannelError] {
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
    for side in 0..<2 {
        core.sides[side].mapping.core = core_address
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

adopted :: fn(owner: u64, object: u64) -> bool {
    match adopt(owner, object) {
        case Ok => return true
        case Error(error) => return false
    }
}

// What the core keeps for side, 0 or 1.
side_of :: fn(core: ptr[mut ChannelCore], side: u32) -> ptr[mut CoreSide] {
    return &core.sides[cast[usize](side) % 2]
}

core_of :: fn(end: ptr[Channel]) -> ptr[mut ChannelCore] {
    return cast[ptr[mut ChannelCore]](end.core)
}

// Where the ring memory is in the direct map.
memory_of :: fn(kernel: ptr[Kernel], core: ptr[ChannelCore]) -> u64 {
    return frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](core.memory))
}

// The indices of the ring side writes.
indices_of :: fn(kernel: ptr[Kernel], core: ptr[ChannelCore], side: u32) -> ptr[mut slop_os.RingIndices] {
    return cast[ptr[mut slop_os.RingIndices]](memory_of(kernel, core) + cast[u64](side) * cast[u64](size_of(slop_os.RingIndices)))
}

// The ring side writes.
ring_of :: fn(kernel: ptr[Kernel], core: ptr[ChannelCore], side: u32) -> u64 {
    return memory_of(kernel, core) + cast[u64](slop_os.CHANNEL_RINGS_OFFSET) + cast[u64](side) * cast[u64](core.ring_bytes)
}

/*
 * Destroying an end: its bindings go, the batches sent to it are dropped, its rings are unmapped, and
 * the other end sees PeerClosed.
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
    concurrency.lock(&core.lock)
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
    concurrency.unlock(&core.lock)
    if unmap {
        unmap_ring(kernel, core, side)
    }
    for batch in dropped {
        if batch != 0 {
            drop_batch(kernel, cast[ptr[mut HandleBatch]](batch))
        }
    }
}

// Once no CPU can use the end: the core's let go of, and freed with the second end, unless still mapped.
release_channel :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel]) {
    if end.core == 0 {
        return void
    }
    drop_core(kernel, end.core)
    end.core = 0
}

// One reference to a core let go of: with the last, its memory and the core are freed.
drop_core :: fn(kernel: ptr[mut Kernel], address: u64) {
    core :: cast[ptr[mut ChannelCore]](address)
    // It gives the count from before
    if intrinsics.interlocked_decrement_u32(&core.references) != 1 {
        return void
    }
    frames.free(&kernel.frames, cast[boot_info.PhysicalAddress](core.memory), core.order)
    slab.free(&kernel.pools.channel_cores, &kernel.frames, address)
}

/*
 * Map end's rings at address in space, read/write: both sides write indices in both rings (ipc.md §2).
 * The mapping is on the space's list of rings, holding the core, before anything is mapped.
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
    concurrency.lock(&core.lock)
    if is_dying(cast[u64](end)) {
        concurrency.unlock(&core.lock)
        return slop_os.ChannelError.ObjectGone
    }
    if mapping.state != .None {
        concurrency.unlock(&core.lock)
        return slop_os.ChannelError.Mapped
    }
    if end.sending != 0 {
        concurrency.unlock(&core.lock)
        return slop_os.ChannelError.InFlight
    }
    mapping.state = .Mapping
    mapping.doomed = false
    mapping.space = cast[u64](space)
    mapping.address = address
    concurrency.unlock(&core.lock)
    // On the space's list first, so releasing the space lets go of what it maps
    concurrency.lock(&space.lock)
    if is_dying(cast[u64](space)) {
        concurrency.unlock(&space.lock)
        set_mapping_state(core, mapping, .None)
        return slop_os.ChannelError.ObjectGone
    }
    // A memory mapping there may have nothing in its page tables yet
    if !range_free(kernel, space, address, size) {
        concurrency.unlock(&space.lock)
        set_mapping_state(core, mapping, .None)
        return slop_os.ChannelError.BadAddress
    }
    link_ring(space, mapping)
    _ = intrinsics.interlocked_increment_u32(&core.references)
    concurrency.unlock(&space.lock)
    match map_user(kernel, space, address, core.memory, size, RING_MAPPING) {
        case Ok => {}
        case Error(error) => {
            concurrency.lock(&space.lock)
            unlink_ring(space, mapping)
            concurrency.unlock(&space.lock)
            drop_core(kernel, cast[u64](core))
            set_mapping_state(core, mapping, .None)
            return if error == .OutOfMemory { slop_os.ChannelError.OutOfMemory }
                else if error == .BudgetExceeded { slop_os.ChannelError.BudgetExceeded } else { slop_os.ChannelError.BadAddress }
        }
    }
    concurrency.lock(&core.lock)
    if mapping.doomed {
        // The end was destroyed meanwhile, and left this for the mapper
        mapping.state = .Unmapping
        concurrency.unlock(&core.lock)
        unmap_ring(kernel, core, side)
        return slop_os.ChannelError.ObjectGone
    }
    mapping.state = .Mapped
    concurrency.unlock(&core.lock)
    return null
}

RING_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = true, global = false}

// Unmap end's rings.
channel_unmap :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel]) -> slop_os.ChannelError? {
    core :: core_of(end)
    mapping :: &side_of(core, end.side).mapping
    concurrency.lock(&core.lock)
    if mapping.state != .Mapped {
        concurrency.unlock(&core.lock)
        return slop_os.ChannelError.BadAddress
    }
    mapping.state = .Unmapping
    concurrency.unlock(&core.lock)
    unmap_ring(kernel, core, end.side)
    return null
}

set_mapping_state :: fn(core: ptr[mut ChannelCore], mapping: ptr[mut RingMapping], state: MappingState) {
    concurrency.lock(&core.lock)
    mapping.state = state
    concurrency.unlock(&core.lock)
}

/*
 * Unmap a side's rings, in Unmapping: unless its space was released first, which let go of it. Page by
 * page, with the space's lock, checking each time it's still on the space's list, so the space's tables
 * are never freed under it; off the list once it's all unmapped.
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
        concurrency.lock(&space.lock)
        if !mapping.linked {
            concurrency.unlock(&space.lock)
            break
        }
        page = unmap_some(&space.table, mapping.address, page, pages, &freed, &flush)
        if page >= pages {
            unlink_ring(space, mapping)
            dropped = true
        }
        concurrency.unlock(&space.lock)
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

// Takes the space's lock as held.
link_ring :: fn(space: ptr[mut AddressSpace], mapping: ptr[mut RingMapping]) {
    mapping.previous = 0
    mapping.next = space.first_ring
    if space.first_ring != 0 {
        cast[ptr[mut RingMapping]](space.first_ring).previous = cast[u64](mapping)
    }
    space.first_ring = cast[u64](mapping)
    mapping.linked = true
}

// Takes the space's lock as held.
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

// The first ring on a space's list, taken off it, or 0. Takes the space's lock as held.
take_ring :: fn(space: ptr[mut AddressSpace]) -> u64 {
    first :: space.first_ring
    if first != 0 {
        unlink_ring(space, cast[ptr[mut RingMapping]](first))
    }
    return first
}

// Raise Readable or Writable on the other end.
channel_notify :: fn(kernel: ptr[mut Kernel], end: ptr[mut Channel], signals: slop_os.Signals) -> slop_os.ChannelError? {
    core :: core_of(end)
    concurrency.lock(&core.lock)
    defer concurrency.unlock(&core.lock)
    if side_of(core, 1 - end.side).closed {
        return slop_os.ChannelError.PeerClosed
    }
    raised :: cast[u32](signals) & cast[u32](slop_os.SIGNAL_READABLE | slop_os.SIGNAL_WRITABLE)
    raise_signals(kernel, core, 1 - end.side, raised)
    return null
}

/*
 * Signals raised on side's end: each binding that sees any of them, and is armed, takes them into its
 * packet. Takes the core's lock as held.
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
            port :: cast[ptr[mut Port]](intrinsics.atomic_load_u64(&binding.port))
            concurrency.lock(&port.lock)
            // A binding the port dropped is no longer this one, whatever its slot holds now
            if binding.generation == slot.generation && binding.port == cast[u64](port) && !is_dying(cast[u64](port)) {
                signal_binding(kernel, port, binding, signals)
            }
            concurrency.unlock(&port.lock)
        }
    }
}

// Takes the port's lock as held.
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

// Drop a side's binding slot: the binding, off its port, unless the port dropped it first. Takes the core's lock as held.
drop_end_binding :: fn(kernel: ptr[mut Kernel], slot: ptr[mut EndBinding]) {
    if slot.binding == 0 {
        return void
    }
    binding :: cast[ptr[mut Binding]](slot.binding)
    port :: cast[ptr[mut Port]](intrinsics.atomic_load_u64(&binding.port))
    concurrency.lock(&port.lock)
    if binding.generation == slot.generation && binding.port == cast[u64](port) && !is_dying(cast[u64](port)) {
        _ = maps.map_remove(&port.bindings, binding.key)
        free_binding(kernel, port, binding)
    }
    concurrency.unlock(&port.lock)
    slot.binding = 0
}

/*
 * A binding for key on port, queuing a Signal packet when end raises any of signals: Persistent, or Once,
 * disarmed after each packet. Binding key again to the same end arms it again, with the new signals.
 * PeerClosed stays raised, so binding to an end whose peer is closed queues a packet at once.
 */
port_bind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], end: ptr[mut Channel], signals: slop_os.Signals, key: u64,
    mode: slop_os.BindMode) -> slop_os.PortError? {
    core :: core_of(end)
    side :: end.side
    concurrency.lock(&core.lock)
    defer concurrency.unlock(&core.lock)
    if is_dying(cast[u64](end)) {
        return slop_os.PortError.ObjectGone
    }
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
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
    return null
}

/*
 * One message, payload's size bytes from the caller's memory, into the end's ring, with the batch its
 * handles are in (slop_os.NO_BATCH for none), as a producer mapping the ring would write it. Without room,
 * it says it waits for room, then looks again, and fails with Full: the reader raises Writable once it
 * makes some. If the reader waits for a message, Readable is raised on its end.
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
    concurrency.lock(&core.lock)
    defer concurrency.unlock(&core.lock)
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

// What reading a message comes to: its size, and its flags and its batch's in the high 16 bits; or the
// error, and for BufferTooSmall, the message's size.
ReadOutcome :: union {
    Read(u32, u32),
    Failed(slop_os.ChannelError, u32),
}

/*
 * The next message in the other end's ring, its payload copied to buffer in the caller's memory, as a
 * consumer mapping the ring would read it: the header is read once, and checked against what the ring
 * holds. With nothing to read, it says it waits for a message, then looks again, and fails with Empty,
 * or PeerClosed once nothing more can come. If the writer waits for room, Writable is raised on its end.
 */
channel_read :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], end: ptr[mut Channel], buffer: u64, capacity: u32) -> ReadOutcome {
    core :: core_of(end)
    peer :: 1 - end.side
    ring_bytes :: core.ring_bytes
    concurrency.lock(&core.lock)
    defer concurrency.unlock(&core.lock)
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

/*
 * Move count handles, from handles in the caller's memory, out of its table into batch on the other end.
 * Each needs RIGHT_TRANSFER, and none can be this channel's own ends, nor an end whose rings are mapped.
 * Objects whose owning handles go keep their owner until the batch is taken; if it never is, they're
 * destroyed with it.
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
    concurrency.lock(&core.lock)
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
    concurrency.unlock(&core.lock)
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
    concurrency.lock(&core.lock)
    closed :: side_of(core, peer).closed
    slot^ = if closed { cast[u64](0) } else { block }
    concurrency.unlock(&core.lock)
    if closed {
        drop_batch(kernel, filled)
        return slop_os.ChannelError.PeerClosed
    }
    return null
}

set_batch :: fn(core: ptr[mut ChannelCore], slot: ptr[mut u64], value: u64) {
    concurrency.lock(&core.lock)
    slot^ = value
    concurrency.unlock(&core.lock)
}

// An end is about to be sent: unless its rings are mapped, it can't be mapped until it arrives.
hold_for_sending :: fn(end: ptr[mut Channel]) -> bool {
    core :: core_of(end)
    concurrency.lock(&core.lock)
    defer concurrency.unlock(&core.lock)
    if side_of(core, end.side).mapping.state != .None {
        return false
    }
    end.sending += 1
    return true
}

let_go_of_end :: fn(end: ptr[mut Channel], generation: u32) {
    core :: core_of(end)
    concurrency.lock(&core.lock)
    if end.header.generation == generation && end.sending != 0 {
        end.sending -= 1
    }
    concurrency.unlock(&core.lock)
}

// The ends among the first count handles, held by hold_for_sending, let go of again.
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

/*
 * A batch that won't be taken: owning handles' objects are destroyed, as closing them would, once the
 * destroy running on this CPU is done (destroy_later).
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

// How many handles were taken; or the error, and for BufferTooSmall, how many there are.
TakeOutcome :: union {
    Taken(u32),
    Failed(slop_os.ChannelError, u32),
}

/*
 * Take batch's handles into the caller's table, in order, writing them to handles in its memory, up to
 * capacity: how many there were. One whose object was destroyed meanwhile, or that doesn't fit in the
 * table, comes out as NO_HANDLE. An object whose owning handle comes is the caller's process's from then on.
 */
channel_take_handles :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], end: ptr[mut Channel], batch: u32, handles: u64,
    capacity: u32) -> TakeOutcome {
    if batch >= slop_os.HANDLE_BATCHES {
        return .Failed(.NoSuchBatch, 0)
    }
    core :: core_of(end)
    slot :: &side_of(core, end.side).batches[cast[usize](batch) % 16]
    concurrency.lock(&core.lock)
    address :: slot^
    if address <= RESERVED {
        concurrency.unlock(&core.lock)
        return .Failed(.NoSuchBatch, 0)
    }
    taken :: cast[ptr[mut HandleBatch]](address)
    count :: taken.count
    if count > capacity {
        concurrency.unlock(&core.lock)
        return .Failed(.BufferTooSmall, count)
    }
    if !is_user_writable(thread.space, handles, cast[u64](count) * 4) {
        concurrency.unlock(&core.lock)
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
        concurrency.unlock(&core.lock)
        return .Failed(.BudgetExceeded, 0)
    }
    slot^ = 0
    concurrency.unlock(&core.lock)
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

// One handle into process's table; an object whose owning handle it is, adopted first, or destroyed if that fails.
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
