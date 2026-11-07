package kernel

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import slop_os from "std/os"
import slab from "slab"
import robustness from "../robustness"

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

/** The part at the start of every kernel object, which the kernel's generic object code works on. */
ObjectHeader :: struct {
    /** The slab allocator's, while the slot is free (slab.hsc), so it never touches what follows. */
    free_link : u64,
    /**
     * The object's generation, which a handle to it carries: incremented when the object is destroyed, so every
     * handle to it goes stale at once. Written and read atomically; a slot whose generation reaches 0xffffffff is
     * retired once released (release_object).
     */
    generation : u32,
    /** What kind of object it is, which says which pool it's in and which type it is past the header. */
    kind : slop_os.ObjectKind,
    /** 1 once its destruction starts: lookups fail from then on, and it's destroyed only once. */
    dying : u32,
    /**
     * The Process that owns it, as an address, 0 for one owned by the kernel itself. Written atomically, under the new
     * owner's OwnedList lock when it's adopted, so a reader without a lock sees one owner or the other, whole.
     */
    owner : u64,
    /** The next object its owner owns, as an address, 0 at the list's end; under the owner's OwnedList lock. */
    owned_next : u64,
    /** The previous object its owner owns, as an address, 0 at the list's start; under the owner's OwnedList lock. */
    owned_previous : u64,
    /**
     * The Process whose list it's linked on, as an address, 0 for none: written atomically, only by the holder of that
     * list's lock, from 0 to the owner by adopt, and back by disown or take_owned. disown reads it without a lock to
     * find the list, then again under its lock, so it never unlinks from a list it isn't on.
     */
    owned_by : u64,
    /** The next object on its CPU's limbo list once it's destroyed, as an address, 0 at the list's end. */
    limbo_next : u64,
    /** The epoch it was destroyed in: it's freed once every online CPU has passed a quiescent point after it. */
    limbo_epoch : u64,
    /** On its CPU's list of objects to destroy once what it's destroying now is done (destroy_later). */
    doomed_next : u64,
    /**
     * The MemoryBudget it's charged to, as an address, 0 for the kernel's own (memory_budgets.hsc). Written with
     * a release store under that budget's lock.
     */
    budget : u64,
    /** How many bytes it's charged: its slot, and what it holds; under its budget's lock. */
    charge : u64,
    /** The next object on its budget's list of what it's charged, 0 at the list's end; under the budget's lock. */
    charged_next : u64,
    /** The previous object on its budget's list, 0 at the list's start; under the budget's lock. */
    charged_previous : u64,
}

/** What an owner keeps of what it owns: a list through each object's ObjectHeader.owned_next. */
OwnedList :: struct {
    /** Held, at rank ObjectList, while the list or an object's links on it change. */
    lock : concurrency.SpinLock,
    /** The first object on the list, as an address, 0 when it's empty. */
    first : u64,
}

/** Why an object couldn't be made or given to its owner. */
ObjectError :: enum {
    /** No memory for its slot: its pool's slab cache couldn't get frames. */
    OutOfMemory,
    /** The owner it would belong to is being destroyed. */
    OwnerGone,
    /** The object itself is being destroyed, as a handle to it is taken by its new owner. */
    ObjectGone,
    /** The budget paying for it can't (memory_budgets.hsc). */
    BudgetExceeded,
}

/**
 * The kernel's objects, one field per kind (decisions/0034, 0057): its type is the object, named as its
 * kind is in slop_os.ObjectKind, and its name names the kind's destroy_ and release_ functions. The code
 * for each kind, its pool and its destruction, is generated from this table.
 */
KernelObjects :: struct {
    /** Processes (processes.hsc): destroy_process, release_process. */
    process : Process,
    /** Threads (threads.hsc): destroy_thread, release_thread. */
    thread : Thread,
    /** Address spaces (spaces.hsc). */
    address_space : AddressSpace,
    /** Ports (ports.hsc). */
    port : Port,
    /** Channel ends (channels.hsc). */
    channel : Channel,
    /** Memory budgets (memory_budgets.hsc). */
    memory_budget : MemoryBudget,
    /** Memory objects (memory.hsc). */
    memory : Memory,
    /** IRQs (irqs.hsc). */
    irq : Irq,
    /** The platform capability (irqs.hsc). */
    platform : Platform,
    /** Intercepts (intercepts.hsc). */
    intercept : Intercept,
    /** Debug logs (debug_log.hsc). */
    debug_log : DebugLog,
    /** Devices (devices.hsc). */
    device : Device,
    /** DMA domains (devices.hsc). */
    dma_domain : DmaDomain,
    /** CPU budgets (cpu_budgets.hsc). */
    cpu_budget : CpuBudget,
    /** I/O port ranges (io_ports.hsc). */
    io_port_range : IoPortRange,
}

/** How many pools there are for kinds, by their slop_os.ObjectKind value, which is below this. */
OBJECT_KIND_SLOTS :: 16

/** The pools, type-stable (slab.hsc): one per kind of object, and the other things objects hold. */
ObjectPools :: struct {
    /** One pool per kind, by its slop_os.ObjectKind value; a kind not in KernelObjects has its pool unmade. */
    objects : slab.SlabCache[OBJECT_KIND_SLOTS],
    /** Port bindings, which aren't objects but are reached the same way (ports.hsc). */
    bindings : slab.SlabCache,
    /** What a channel's ends share (channels.hsc). */
    channel_cores : slab.SlabCache,
    /** Where memory objects are mapped (memory.hsc). */
    mappings : slab.SlabCache,
}

/**
 * Make every pool: each kind's and the bindings' type-stable, the channel cores' and the mappings' not.
 *
 * Called once, on the boot CPU at boot, before any object is made; making a pool takes no memory until it's used.
 *
 * @param kernel The kernel, whose pools are set.
 */
init_pools :: fn(kernel: ptr[mut Kernel]) {
    #insert object_pools()
    kernel.pools.bindings = object_cache(cast[u64](size_of(Binding)), cast[u64](align_of(Binding)))
    kernel.pools.channel_cores = slab.make_cache(cast[u64](size_of(ChannelCore)), cast[u64](align_of(ChannelCore)))
    kernel.pools.mappings = slab.make_cache(cast[u64](size_of(MemoryMapping)), cast[u64](align_of(MemoryMapping)))
}

/**
 * Generate the statements that make each kind's pool, for init_pools: run at compile time.
 *
 * @return One statement per field of KernelObjects, making the pool at its kind's index with object_cache, for an
 *     object of the field's type, its size and alignment; written for where kernel is in scope.
 */
object_pools :: fn() -> compiler.Code {
    made : compiler.Code[..]
    for field in object_table().members {
        type :: compiler.type_code(compiler.described_type(field.member_type))
        index :: cast[u64](cast[u8](kind_of(field)))
        array_add(&made, #code {
            kernel.pools.objects[#insert index] = object_cache(cast[u64](size_of(#insert type)), cast[u64](align_of(#insert type)))
        })
    }
    return compiler.list(made)
}

/**
 * Generate a call of each kind's own function: run at compile time.
 *
 * @param prefix The start of each function's name, which ends with the KernelObjects field's name, as "destroy_"
 *     makes destroy_process. Every kind has to have its function, taking the kernel and a pointer to its object.
 * @return One statement per kind, which calls its function with kernel and object, cast to that kind's type, when
 *     kind is that kind; written for where kind, kernel and object (an address) are in scope.
 */
per_kind :: fn(prefix: string) -> compiler.Code {
    made : compiler.Code[..]
    for field in object_table().members {
        type :: compiler.type_code(compiler.described_type(field.member_type))
        kind :: kind_of(field)
        array_add(&made, #code {
            if kind == #insert kind {
                run :: #insert compiler.name(prefix, field.name)
                run(kernel, cast[ptr[mut #insert type]](object))
            }
        })
    }
    return compiler.list(made)
}

/**
 * Find the table of the kernel's objects, at compile time.
 *
 * @return KernelObjects's type information, whose members are the kinds.
 */
object_table :: fn() -> ptr[compiler.TypeInfoStruct] {
    return cast[ptr[compiler.TypeInfoStruct]](type_info_of(KernelObjects))
}

/**
 * Find the kind a table field is, at compile time: the ObjectKind member named as its type is.
 *
 * @param field A member of KernelObjects, whose type is a struct.
 * @return The ObjectKind of the same name as the field's type. With none, a compile error is reported, and Process
 *     comes back in its place.
 */
kind_of :: fn(field: compiler.StructMember) -> slop_os.ObjectKind {
    name :: cast[ptr[compiler.TypeInfoStruct]](field.member_type).name
    kinds :: cast[ptr[compiler.TypeInfoEnum]](type_info_of(slop_os.ObjectKind))
    for member, i in kinds.members {
        if member == name && i < kinds.values.count {
            return cast[slop_os.ObjectKind](cast[u8](kinds.values[i]))
        }
    }
    compiler.report_error(#caller_location, "no ObjectKind is named %", name)
    return .Process
}

/*
 * A fresh object's generation: whatever its slot's memory held, or with robustness=on a few uses before 0xffffffff,
 * where a slot is retired (decisions/0096, 0105), so retiring runs in every test.
 */
#if robustness.ON {
    /** The generation written in each slot of a new slab: 0xfffffffc, four destroys short of retiring. */
    OBJECT_GENERATION_START : u32 : 0xfffffffc
}
#else {
    /** 0, which a new slab doesn't write: its slots' generations are whatever its frames held. */
    OBJECT_GENERATION_START : u32 : 0
}

/**
 * Make a type-stable pool for objects with an ObjectHeader, whose new slots start at OBJECT_GENERATION_START.
 *
 * @param size The bytes of each object.
 * @param alignment The objects' alignment in bytes, a power of two up to a frame.
 * @return The cache, which keeps its empty slabs rather than freeing them, so a slot only ever holds its kind.
 */
object_cache :: fn(size: u64, alignment: u64) -> slab.SlabCache {
    cache := slab.make_cache(size, alignment)
    cache.type_stable = true
    cache.fresh_offset = cast[u64](offset_of(ObjectHeader, generation))
    cache.fresh_value = OBJECT_GENERATION_START
    return cache
}

/**
 * Find the pool for objects of a kind.
 *
 * @param kernel The kernel, whose pools are searched.
 * @param kind The kind; its value is taken modulo OBJECT_KIND_SLOTS, so any value finds a pool.
 * @return The kind's pool in kernel.pools, good for as long as the kernel runs.
 */
pool_of :: fn(kernel: ptr[mut Kernel], kind: slop_os.ObjectKind) -> ptr[mut slab.SlabCache] {
    return &kernel.pools.objects[cast[usize](cast[u8](kind)) % OBJECT_KIND_SLOTS]
}

/**
 * Log what's left in the pools, once everything but the kernel's own objects should be gone, as when the root task
 * has ended: the kernel keeps the root budget, the root CPU budget and the platform capability, and nothing else.
 *
 * One info line if only those are left; otherwise an error line of the counts, and one for each kind with objects.
 *
 * @param kernel The kernel, whose pools' counts are read without their locks, so they're a moment's.
 */
log_objects_left :: fn(kernel: ptr[mut Kernel]) {
    pools :: &kernel.pools
    others : u64 = 0
    for pool, i in pools.objects {
        if i != cast[usize](cast[u8](slop_os.ObjectKind.MemoryBudget)) && i != cast[usize](cast[u8](slop_os.ObjectKind.Platform))
            && i != cast[usize](cast[u8](slop_os.ObjectKind.CpuBudget)) {
            others += pool.allocated
        }
    }
    budgets :: pool_of(kernel, .MemoryBudget).allocated
    platforms :: pool_of(kernel, .Platform).allocated
    cpu_budgets :: pool_of(kernel, .CpuBudget).allocated
    if others == 0 && budgets == 1 && platforms <= 1 && cpu_budgets <= 1 && pools.bindings.allocated == 0 && pools.channel_cores.allocated == 0
        && pools.mappings.allocated == 0 {
        runtime.log_info("objects left: only the kernel's own")
        return void
    }
    runtime.log_error("objects left: % budgets, % CPU budgets, % platforms, % other objects, % bindings, % channel cores, % mappings", budgets,
        cpu_budgets, platforms, others, pools.bindings.allocated, pools.channel_cores.allocated, pools.mappings.allocated)
    for pool, i in pools.objects {
        if pool.allocated != 0 {
            runtime.log_error("objects left: % of kind %", pool.allocated, i)
        }
    }
}

/**
 * Make a zeroed object of a kind from its pool.
 *
 * It keeps the generation its slot had, so handles to whatever was there before stay stale. It's owned by nobody
 * yet: the caller gives it to its owner with adopt, or lets it go with release_object. The generation isn't written,
 * so is_live, through a stale handle meanwhile, never reads it part zeroed, as an older generation it might match.
 *
 * @param kernel The kernel, whose pools and frames it comes from.
 * @param kind The kind of object, which says its pool and its size.
 * @param budget The MemoryBudget it's charged to, as an address, or 0 for the kernel's own, which charges nothing.
 * @param extra Bytes charged beyond its slot, for what it holds, as a thread's vector state; 0 for none.
 * @return Its address in the direct map, its header's kind set and the rest zeroed but its generation.
 * @error OutOfMemory Its pool couldn't get frames for a slot.
 * @error BudgetExceeded The budget is closed, can't take its slot and extra bytes, or fault injection failed it; the
 *     slot went back to its pool.
 */
new_object :: fn(kernel: ptr[mut Kernel], kind: slop_os.ObjectKind, budget: u64, extra: u64) -> Result[u64, ObjectError] {
    pool :: pool_of(kernel, kind)
    address :: slab.allocate(pool, &kernel.frames) or_return .Error(.OutOfMemory)
    header :: cast[ptr[mut ObjectHeader]](address)
    zero_but_generation(address, pool.object_size, cast[u64](offset_of(ObjectHeader, generation)))
    header.kind = kind
    if !charge_new(budget, address, pool.object_size + extra) {
        slab.free(pool, &kernel.frames, address)
        return .Error(.BudgetExceeded)
    }
    return .Ok(address)
}

/**
 * Zero a type-stable slot being made anew, all but its generation, whose bytes aren't written.
 *
 * Its generation is read without a lock through what kept the slot's address, as is_live and lock_bound_port read
 * it. Zeroing it and writing it back would let them see it part zeroed meanwhile, since mem_zero may write a byte at a
 * time: a value it never had, which could be an older generation they kept (decisions/0052).
 *
 * @param address The slot's address, in the direct map.
 * @param size The slot's bytes, all of which but the generation's are zeroed.
 * @param generation_at The generation's offset in the slot, in bytes: a u32 that ends within size.
 */
zero_but_generation :: fn(address: u64, size: u64, generation_at: u64) {
    after :: generation_at + cast[u64](size_of(u32))
    runtime.assert(after <= size, "a slot's generation is within it")
    intrinsics.mem_zero(cast[mut rawptr](address), cast[usize](generation_at))
    intrinsics.mem_zero(cast[mut rawptr](address + after), cast[usize](size - after))
}

/**
 * Give an object to its owner, unless the owner or the object is being destroyed, when the object would outlive it, or
 * be left on a list once it's gone.
 *
 * Takes the owner's OwnedList lock, at rank ObjectList. The object's linked first, and its owned_by set, then whether
 * it's dying is read, with a full fence between: destroy_object marks it dying, with a full barrier, before it disowns
 * it, so either this sees it dying and unlinks it again, or disown sees it on this list and waits for the lock to
 * unlink it (decisions/0051's "Found later"). The object's owner field is set even when this fails, so the caller
 * destroys it.
 *
 * @param owner The Process that owns it from now on, as an address, or 0 for the kernel, which keeps no list.
 * @param object The object, as an address: one not on any owner's list.
 * @return Nothing; the object is on the owner's list, and destroyed with it.
 * @error OwnerGone The owner is being destroyed; the object isn't on its list.
 * @error ObjectGone The object is being destroyed; it isn't on the owner's list.
 */
adopt :: fn(owner: u64, object: u64) -> Result[void, ObjectError] {
    header :: cast[ptr[mut ObjectHeader]](object)
    if owner == 0 {
        intrinsics.atomic_store_u64_release(&header.owner, 0)
        return .Ok
    }
    process :: cast[ptr[mut Process]](owner)
    list :: &process.owned
    lock_at(&list.lock, .ObjectList)
    defer unlock_at(&list.lock, .ObjectList)
    intrinsics.atomic_store_u64_release(&header.owner, owner)
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
    intrinsics.atomic_store_u64_release(&header.owned_by, owner)
    // Linked, then dying read: a destroy that marked it first is seen here, and one that marks it after finds it here
    intrinsics.fence_sequentially_consistent()
    if intrinsics.atomic_load_u32_acquire(&header.dying) != 0 {
        unlink_owned(list, object)
        return .Error(.ObjectGone)
    }
    return .Ok
}

/**
 * Take an object off whichever owner's list it's on, if any; its owner field stays as it was.
 *
 * Its owned_by is read to find the list, that list's lock taken, and owned_by read again: if it's moved meanwhile, to
 * another list or none, the lock's let go and it's looked for again, so it's unlinked only from the list it's on, by
 * the holder of that list's lock.
 *
 * @param object The object, as an address; one on no list, as one owned by the kernel (owner 0) is, is left alone.
 */
disown :: fn(object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    loop {
        owned_by :: intrinsics.atomic_load_u64_acquire(&header.owned_by)
        if owned_by == 0 {
            return void
        }
        list :: &cast[ptr[mut Process]](owned_by).owned
        lock_at(&list.lock, .ObjectList)
        if intrinsics.atomic_load_u64_acquire(&header.owned_by) == owned_by {
            unlink_owned(list, object)
            unlock_at(&list.lock, .ObjectList)
            return void
        }
        unlock_at(&list.lock, .ObjectList)
    }
}

/**
 * Unlink an object from the list it's on, and mark it on none.
 *
 * @param list The list, its lock held, which the object is on (its owned_by is the list's process).
 * @param object The object, as an address.
 */
unlink_owned :: fn(list: ptr[mut OwnedList], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    if header.owned_previous != 0 {
        cast[ptr[mut ObjectHeader]](header.owned_previous).owned_next = header.owned_next
    }
    else {
        list.first = header.owned_next
    }
    if header.owned_next != 0 {
        cast[ptr[mut ObjectHeader]](header.owned_next).owned_previous = header.owned_previous
    }
    header.owned_previous = 0
    header.owned_next = 0
    intrinsics.atomic_store_u64_release(&header.owned_by, 0)
}

/**
 * Take the first object off an owner's list.
 *
 * Takes the list's lock, at rank ObjectList.
 *
 * @param list The list of objects an owner owns (a process's owned); its first object is unlinked under its lock, the
 *     rest left.
 * @return The object, as an address, no longer on the list but still naming its owner; 0 if the list was empty.
 */
take_owned :: fn(list: ptr[mut OwnedList]) -> u64 {
    lock_at(&list.lock, .ObjectList)
    defer unlock_at(&list.lock, .ObjectList)
    first :: list.first
    if first == 0 {
        return 0
    }
    unlink_owned(list, first)
    return first
}

/**
 * Tell whether an object is still the live one a handle names: a handle's check.
 *
 * Without a lock: the answer can change the moment after, but an object destroyed since is only freed after this
 * CPU's next quiescent point, so its memory stays an object of its kind until then.
 *
 * @param object The object's address, a slot of a type-stable pool.
 * @param generation The generation the handle carries.
 * @return True if its generation is still that one and its destruction hasn't started.
 */
is_live :: fn(object: u64, generation: u32) -> bool {
    header :: cast[ptr[ObjectHeader]](object)
    return intrinsics.atomic_load_u32_acquire(&header.generation) == generation && intrinsics.atomic_load_u32_acquire(&header.dying) == 0
}

/**
 * Destroy an object, once: every handle to it goes stale, what it owns or holds is destroyed or let go
 * (each kind's destroy), and its memory goes back to its pool after a grace period.
 *
 * It's taken off its owner's list, and goes on this CPU's limbo list. Each kind's destroy may destroy other objects,
 * nested, or leave them for later (destroy_later); the outermost destroy on this CPU finishes those before it
 * returns. Called with no lock held that a kind's destroy takes.
 *
 * @param kernel The kernel: its epoch is advanced (retire), this CPU's PerCpu destroying, draining, doomed and limbo
 *     list change, and each kind's destroy may take that kind's locks and the owner's OwnedList lock.
 * @param object The object, as an address: a live one, or one already dying.
 * @return True if this call destroyed it; false if it was already being destroyed, when nothing was done.
 */
destroy_object :: fn(kernel: ptr[mut Kernel], object: u64) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    _, first :: intrinsics.interlocked_compare_exchange_u32(&header.dying, 1, 0)
    if !first {
        return false
    }
    cpu :: per_cpu()
    cpu.destroying += 1
    intrinsics.atomic_store_u32(&header.generation, header.generation + 1)
    disown(object)
    // Each kind's own (KernelObjects)
    kind :: header.kind
    #insert per_kind("destroy_")
    retire(kernel, object)
    cpu.destroying -= 1
    // The outermost destroy finishes what the ones inside it left for later
    if cpu.destroying == 0 && !cpu.draining {
        cpu.draining = true
        loop {
            doomed :: cpu.doomed
            if doomed == 0 {
                break
            }
            cpu.doomed = cast[ptr[ObjectHeader]](doomed).doomed_next
            _ = destroy_object(kernel, doomed)
        }
        cpu.draining = false
    }
    return true
}

/**
 * Destroy an object, if it's still the one with a generation: at once, or, during another destroy on this
 * CPU, once that's done.
 *
 * So objects that hold one another, a channel end in a batch on another channel, and so on, are destroyed one after
 * another, never nested deeper than one.
 *
 * @param kernel The kernel, passed to destroy_object if it runs now; otherwise only this CPU's doomed list changes.
 * @param object The object, as an address.
 * @param generation The generation it had when the caller found it; if it's changed, or it's dying, nothing is done.
 */
destroy_later :: fn(kernel: ptr[mut Kernel], object: u64, generation: u32) {
    if !is_live(object, generation) {
        return void
    }
    cpu :: per_cpu()
    if cpu.destroying == 0 && !cpu.draining {
        _ = destroy_object(kernel, object)
        return void
    }
    header :: cast[ptr[mut ObjectHeader]](object)
    header.doomed_next = cpu.doomed
    cpu.doomed = object
}

/**
 * Put a destroyed object on this CPU's limbo list, in the epoch it was destroyed in, which advances, so
 * it's freed once every CPU has passed a quiescent point in a later one.
 *
 * @param kernel The kernel, whose epoch is incremented atomically.
 * @param object The object, as an address, destroyed and not yet on any limbo list.
 */
retire :: fn(kernel: ptr[mut Kernel], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    header.limbo_epoch = intrinsics.interlocked_increment_u64(&kernel.epoch)
    cpu :: per_cpu()
    header.limbo_next = cpu.limbo
    cpu.limbo = object
}

/**
 * Pass a quiescent point on this CPU, where it holds no object pointer from before now, and free what's been in its
 * limbo long enough.
 *
 * Called on the CPU it's for, as it returns to user mode or goes idle (scheduler.hsc), with no lock held that an
 * object's release takes.
 *
 * @param kernel The kernel, whose online CPUs' quiescent epochs are read; objects it frees go back to its pools,
 *     their charges to their budgets, taking each budget's lock.
 * @param cpu The calling CPU's PerCpu, whose quiescent_epoch is set and whose limbo list is walked.
 * @param epoch The kernel's epoch, read before the caller's last check of what it resumes (that it isn't dying).
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

/**
 * The quiescent epoch of a CPU idle without ticking (decisions/0128): it holds nothing, so it's past every quiescent
 * point until an interrupt wakes it, which records the epoch then before anything runs (leave_idle).
 */
IDLE_EPOCH : u64 : 0xffffffffffffffff

/**
 * Find the earliest epoch an online CPU last passed a quiescent point in.
 *
 * @param kernel The kernel, whose CPUs' quiescent epochs are read atomically, without a lock.
 * @return That epoch: an object destroyed in an epoch below it can be freed. At most one past the kernel's epoch,
 *     which it is when every online CPU is idle without ticking (IDLE_EPOCH) or has no PerCpu yet.
 */
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

/**
 * Free a destroyed object's memory, and what it held that no CPU could still use (each kind's release).
 *
 * Its whole charge goes back to its budget. A slot whose generation is 0xffffffff is retired instead of freed.
 * Called once its grace period has passed, or on an object never handed out, as when making one fails.
 *
 * @param kernel The kernel, whose pool for the object's kind it goes back to, and whose frames each kind's release
 *     gives back what it held to.
 * @param object The object, as an address; it's no longer the caller's to touch.
 */
release_object :: fn(kernel: ptr[mut Kernel], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    kind :: header.kind
    #insert per_kind("release_")
    return_charge(object)
    // A slot whose generation would wrap is never used again (decisions/0008), nor counted as in use
    if header.generation == 0xffffffff {
        slab.retire(pool_of(kernel, kind), object)
        return void
    }
    slab.free(pool_of(kernel, kind), &kernel.frames, object)
}
