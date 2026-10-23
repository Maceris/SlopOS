package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import slop_os from "std/os"
import slab from "slab"

/*
 * Kernel objects (roadmap M5, decisions/0008, 0034): every object has exactly one owner, a Process, and
 * lives in a type-stable pool of its kind, so its address is only ever an object of that kind.
 *
 * A handle names an object by its address and generation. Destroying it changes the generation, so
 * every handle to it, in every process, goes stale at once: destroying an object is revoking it. A
 * destroyed object goes on its CPU's limbo list, and its memory goes back to its pool only once every
 * CPU has passed a quiescent point since: returning to user mode, or going idle (scheduler.hsc). Kernel
 * code never keeps a pointer to an object across one.
 */
//SPEC: McKenney and Slingwine, "Read-Copy Update: Using Execution History to Solve Concurrency Problems"
//      (PDCS 1998), quiescent-state-based reclamation

// At the start of every kernel object.
ObjectHeader :: struct {
    // The slab allocator's, while the slot is free (slab.hsc), so it never touches what follows.
    free_link : u64,
    // Changed when the object is destroyed, so every handle to it goes stale.
    generation : u32,
    kind : slop_os.ObjectKind,
    // 1 once its destruction starts: lookups fail from then on, and it's destroyed only once.
    dying : u32,
    // The Process that owns it, as an address, 0 for one owned by the kernel itself.
    owner : u64,
    // Its neighbors among what its owner owns, and whether it's linked there.
    owned_next : u64,
    owned_previous : u64,
    owned : bool,
    // On its CPU's limbo list once destroyed, with the epoch it was destroyed in.
    limbo_next : u64,
    limbo_epoch : u64,
}

// What an owner keeps of what it owns.
OwnedList :: struct {
    lock : concurrency.SpinLock,
    first : u64,
}

ObjectError :: enum {
    OutOfMemory,
    // The owner it would belong to is being destroyed.
    OwnerGone,
}

// The pools, one per kind, type-stable (slab.hsc).
ObjectPools :: struct {
    processes : slab.SlabCache,
    threads : slab.SlabCache,
    spaces : slab.SlabCache,
}

init_pools :: fn(kernel: ptr[mut Kernel]) {
    kernel.pools.processes = object_cache(cast[u64](size_of(Process)), cast[u64](align_of(Process)))
    kernel.pools.threads = object_cache(cast[u64](size_of(Thread)), cast[u64](align_of(Thread)))
    kernel.pools.spaces = object_cache(cast[u64](size_of(AddressSpace)), cast[u64](align_of(AddressSpace)))
}

object_cache :: fn(size: u64, alignment: u64) -> slab.SlabCache {
    cache := slab.make_cache(size, alignment)
    cache.type_stable = true
    return cache
}

pool_of :: fn(kernel: ptr[mut Kernel], kind: slop_os.ObjectKind) -> ptr[mut slab.SlabCache] {
    return match kind {
        case .Process => &kernel.pools.processes
        case .Thread => &kernel.pools.threads
        case _ => &kernel.pools.spaces
    }
}

/*
 * A zeroed object of kind from its pool: its address. It keeps the generation its slot had, so handles
 * to whatever was there before stay stale.
 */
new_object :: fn(kernel: ptr[mut Kernel], kind: slop_os.ObjectKind) -> Result[u64, ObjectError] {
    pool :: pool_of(kernel, kind)
    address :: slab.allocate(pool, &kernel.frames) or_return .Error(.OutOfMemory)
    header :: cast[ptr[mut ObjectHeader]](address)
    generation :: header.generation
    intrinsics.mem_zero(cast[rawptr](address), cast[usize](pool.object_size))
    header.generation = generation
    header.kind = kind
    return .Ok(address)
}

/*
 * Give object to owner, a Process (0 for the kernel): unless owner is being destroyed, when object would
 * outlive it.
 */
adopt :: fn(owner: u64, object: u64) -> Result[void, ObjectError] {
    header :: cast[ptr[mut ObjectHeader]](object)
    header.owner = owner
    if owner == 0 {
        return .Ok
    }
    process :: cast[ptr[mut Process]](owner)
    list :: &process.owned
    concurrency.lock(&list.lock)
    defer concurrency.unlock(&list.lock)
    // Under the lock, so destroying the owner either sees it, or this sees the owner dying
    if intrinsics.atomic_load_u32_acquire(&process.header.dying) != 0 {
        return .Error(.OwnerGone)
    }
    header.owned_previous = 0
    header.owned_next = list.first
    if list.first != 0 {
        cast[ptr[mut ObjectHeader]](list.first).owned_previous = object
    }
    list.first = object
    header.owned = true
    return .Ok
}

// Take object off its owner's list, if it's on it.
disown :: fn(object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    if header.owner == 0 {
        return void
    }
    owner :: cast[ptr[mut Process]](header.owner)
    list :: &owner.owned
    concurrency.lock(&list.lock)
    defer concurrency.unlock(&list.lock)
    if !header.owned {
        return void
    }
    if header.owned_previous != 0 {
        cast[ptr[mut ObjectHeader]](header.owned_previous).owned_next = header.owned_next
    }
    else {
        list.first = header.owned_next
    }
    if header.owned_next != 0 {
        cast[ptr[mut ObjectHeader]](header.owned_next).owned_previous = header.owned_previous
    }
    header.owned = false
}

// The first object list's owner owns, taken off it, or 0.
take_owned :: fn(list: ptr[mut OwnedList]) -> u64 {
    concurrency.lock(&list.lock)
    defer concurrency.unlock(&list.lock)
    first :: list.first
    if first == 0 {
        return 0
    }
    header :: cast[ptr[mut ObjectHeader]](first)
    list.first = header.owned_next
    if header.owned_next != 0 {
        cast[ptr[mut ObjectHeader]](header.owned_next).owned_previous = 0
    }
    header.owned = false
    return first
}

// Whether object is the live object with generation: a handle's check.
is_live :: fn(object: u64, generation: u32) -> bool {
    header :: cast[ptr[ObjectHeader]](object)
    return intrinsics.atomic_load_u32_acquire(&header.generation) == generation && intrinsics.atomic_load_u32_acquire(&header.dying) == 0
}

/*
 * Destroy an object, once: every handle to it goes stale, what it owns or holds is destroyed or let go
 * (each kind's destroy), and its memory goes back to its pool after a grace period. False if it was
 * already being destroyed.
 */
destroy_object :: fn(kernel: ptr[mut Kernel], object: u64) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    _, first :: intrinsics.interlocked_compare_exchange_u32(&header.dying, 1, 0)
    if !first {
        return false
    }
    intrinsics.atomic_store_u32(&header.generation, header.generation + 1)
    disown(object)
    match header.kind {
        case .Process => destroy_process(kernel, cast[ptr[mut Process]](object))
        case .Thread => destroy_thread(kernel, cast[ptr[mut Thread]](object))
        case .AddressSpace => destroy_address_space(kernel, cast[ptr[mut AddressSpace]](object))
        case _ => {}
    }
    retire(kernel, object)
    return true
}

/*
 * Put a destroyed object on this CPU's limbo list, in the epoch it was destroyed in, which advances, so
 * it's freed once every CPU has passed a quiescent point in a later one.
 */
retire :: fn(kernel: ptr[mut Kernel], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    header.limbo_epoch = intrinsics.interlocked_increment_u64(&kernel.epoch)
    cpu :: per_cpu()
    header.limbo_next = cpu.limbo
    cpu.limbo = object
}

/*
 * A quiescent point on this CPU: it holds no object pointer from before now. Frees what's been in its
 * limbo long enough. Called with the epoch read before the caller's last check of what it resumes.
 */
pass_quiescent :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], epoch: u64) {
    intrinsics.atomic_store_u64(&cpu.quiescent_epoch, epoch)
    if cpu.limbo == 0 {
        return void
    }
    oldest :: oldest_quiescent(kernel)
    kept := cast[u64](0)
    with {
        object := cpu.limbo
    }
    loop {
        header :: cast[ptr[mut ObjectHeader]](object)
        next :: header.limbo_next
        if header.limbo_epoch < oldest {
            release_object(kernel, object)
        }
        else {
            header.limbo_next = kept
            kept = object
        }
        object = next
    }
    while object != 0
    cpu.limbo = kept
}

// The earliest epoch an online CPU last passed a quiescent point in.
oldest_quiescent :: fn(kernel: ptr[Kernel]) -> u64 {
    per_cpus :: kernel.per_cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    oldest := intrinsics.atomic_load_u64(&kernel.epoch) + 1
    for index in 0..<online {
        if index < per_cpus.count && per_cpus[index] != 0 {
            other :: cast[ptr[mut PerCpu]](per_cpus[index])
            seen :: intrinsics.atomic_load_u64(&other.quiescent_epoch)
            oldest = if seen < oldest { seen } else { oldest }
        }
    }
    return oldest
}

// Free a destroyed object's memory, and what it held that no CPU could still use.
release_object :: fn(kernel: ptr[mut Kernel], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    kind :: header.kind
    match kind {
        case .Process => release_process(kernel, cast[ptr[mut Process]](object))
        case .Thread => release_thread(kernel, cast[ptr[mut Thread]](object))
        case .AddressSpace => release_address_space(kernel, cast[ptr[mut AddressSpace]](object))
        case _ => {}
    }
    // A slot whose generation would wrap is never used again (decisions/0008)
    if header.generation == 0xffffffff {
        return void
    }
    slab.free(pool_of(kernel, kind), &kernel.frames, object)
}
