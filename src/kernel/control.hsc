package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import maps from "std"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Process control (roadmap M5, decisions/0017, 0056, knowledge/design/kernel.md §4): rights on a process
 * cover its whole subtree. Through a process handle, a debugger lists its threads, reads and writes
 * their registers and its memory, suspends and resumes threads, and kills it; intercepts.hsc stops
 * threads at system calls and faults.
 *
 * A thread is held while anything holds it: a suspend, or a stop. A held thread stops only where its
 * whole state is its saved registers: on its next entry to the kernel if it's running, at once if it's
 * on a run queue, and once its wait is over if it's blocked, so a wait isn't cancelled and its results
 * are written first. It's then parked, on no queue, until nothing holds it, when it's made ready again.
 *
 * Lock order: a thread's control lock, then a run queue's.
 */

// What holds a thread (Thread.held).
/** Thread.held's bit for a suspend, through ThreadSuspend, until ThreadResume. */
HELD_SUSPEND : u32 : 1 << 0
/** Thread.held's bit for a stop by an intercept, until it lets the thread go. */
HELD_STOP : u32 : 1 << 1

/** How far up an ownership chain a walk goes, so one through slots reused meanwhile always ends. */
MAX_OWNER_DEPTH :: 4096

/**
 * Hold a thread for a reason: parked at once if it's on a run queue; told with an IPI, if it runs on another CPU, so
 * it parks as it next enters the kernel. A blocked thread parks once its wait is over.
 *
 * Takes the thread's control lock, then its run queue's.
 *
 * @param kernel The kernel, whose per_cpus give the thread's run queue, taken under its lock, and whose cpus give
 *     the hardware ID an IPI goes to.
 * @param thread The thread; its control lock is taken, so the caller holds none of rank ThreadControl or above.
 * @param bit What holds it, HELD_SUSPEND or HELD_STOP; holding it again for the same bit changes nothing.
 */
hold_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], bit: u32) {
    lock_at(&thread.control, .ThreadControl)
    defer unlock_at(&thread.control, .ThreadControl)
    thread.held |= bit
    if thread.parked {
        return void
    }
    per_cpus :: kernel.per_cpus
    // Its CPU may change until its run queue's lock is held and it's still that CPU
    loop {
        index :: intrinsics.atomic_load_u32_acquire(&thread.cpu)
        runtime.assert(cast[usize](index) < per_cpus.count, "a thread's CPU is one of the kernel's")
        cpu :: cast[ptr[mut PerCpu]](per_cpus[index])
        lock_at(&cpu.run_queue.lock, .RunQueue)
        if thread.cpu != index {
            unlock_at(&cpu.run_queue.lock, .RunQueue)
            continue
        }
        if thread.queued {
            unlink(&cpu.run_queue, thread)
            thread.parked = true
            thread.state = .Stopped
        }
        running :: cpu.current == cast[u64](thread)
        unlock_at(&cpu.run_queue.lock, .RunQueue)
        if running && cpu != per_cpu() {
            cpus :: kernel.cpus
            runtime.assert(cast[usize](index) < cpus.count, "every online CPU is in kernel.cpus")
            arch.send_ipi(cpus[index].hardware_id, .Reschedule)
        }
        break
    }
}

/**
 * Let go of a thread for a reason: made ready on its CPU if it's parked, nothing else holds it, and it isn't dying.
 * Takes the thread's control lock, then its run queue's.
 *
 * @param kernel The kernel, whose run queue on the thread's CPU it joins when it's made ready.
 * @param thread The thread; its control lock is taken, so the caller holds none of rank ThreadControl or above.
 *     One dying stays parked.
 * @param bit What no longer holds it, HELD_SUSPEND or HELD_STOP; one that didn't hold it changes nothing.
 */
unhold_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], bit: u32) {
    lock_at(&thread.control, .ThreadControl)
    defer unlock_at(&thread.control, .ThreadControl)
    thread.held &= ~bit
    if thread.held == 0 && thread.parked && !is_dying(cast[u64](thread)) {
        thread.parked = false
        make_ready(kernel, thread, thread.cpu)
    }
}

/**
 * Park a thread if something holds it, at a point where its whole state is its saved registers. Takes the thread's
 * control lock, only when it's held.
 *
 * @param thread The thread, about to leave the CPU at a point where its whole state is its saved registers.
 * @param saved Whether it's this CPU's current thread, whose vector state is still in the CPU and is saved.
 * @return True if it's parked, when the caller takes it off the CPU; false if nothing holds it.
 */
park_if_held :: fn(thread: ptr[mut Thread], saved: bool) -> bool {
    if intrinsics.atomic_load_u32_acquire(&thread.held) == 0 {
        return false
    }
    lock_at(&thread.control, .ThreadControl)
    defer unlock_at(&thread.control, .ThreadControl)
    if thread.held == 0 {
        return false
    }
    if saved {
        arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
    }
    thread.parked = true
    thread.state = .Stopped
    return true
}

/**
 * Tell whether a thread is parked, so its saved registers are a debugger's to read and write. Takes the thread's
 * control lock.
 *
 * @param thread The thread; its control lock is taken for the read.
 * @return True if it's parked; it stays so until whatever holds it lets go.
 */
is_parked :: fn(thread: ptr[mut Thread]) -> bool {
    lock_at(&thread.control, .ThreadControl)
    defer unlock_at(&thread.control, .ThreadControl)
    return thread.parked
}

/**
 * Bind an object to a port under a key, for its watchers: a Signal packet when it raises any of some signals.
 *
 * An object has two watchers' slots. Binding the same object to the same port and key again arms it again and
 * changes its signals and mode. Takes the object's watchers' lock, then the port's.
 *
 * @param kernel The kernel, whose pool the binding comes from.
 * @param port The port, which is charged for the binding.
 * @param object The object watched, a process, a thread or a device, as its address.
 * @param watchers The object's watchers' slots.
 * @param lock The lock that guards watchers.
 * @param rank lock's rank, as lock_at takes it.
 * @param signals The signals that raise a packet, like SIGNAL_TERMINATED.
 * @param key The key its packets carry, which no other binding on the port may have.
 * @param mode Once, for one packet and then none until it's bound again, or each signal's.
 * @return Null once bound and armed; ObjectGone if the object or the port is being destroyed; KeyInUse if the key
 *     is another binding's; TooManyBindings if both slots have bindings their ports still keep; BudgetExceeded or
 *     OutOfMemory if the binding couldn't be made.
 */
watch_bind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], object: u64, watchers: ptr[mut EndBinding[2]], lock: ptr[mut concurrency.SpinLock], rank: LockRank,
    signals: slop_os.Signals, key: u64, mode: slop_os.BindMode) -> slop_os.PortError? {
    lock_at(lock, rank)
    defer unlock_at(lock, rank)
    if is_dying(object) {
        return slop_os.PortError.ObjectGone
    }
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    generation :: cast[ptr[ObjectHeader]](object).generation
    binding := cast[ptr[mut Binding]](0)
    match maps.map_get(&port.bindings, key) {
        case Some(address) => {
            existing :: cast[ptr[mut Binding]](address)
            if existing.kind != .Signal || existing.object != object || existing.object_generation != generation {
                return slop_os.PortError.KeyInUse
            }
            binding = existing
        }
        case None => {
            free_slot := cast[ptr[mut EndBinding]](0)
            for i in 0..<2 {
                slot :: &watchers^[i]
                if cast[u64](free_slot) == 0 && (slot.binding == 0 || cast[ptr[Binding]](slot.binding).generation != slot.generation) {
                    free_slot = slot
                }
            }
            if cast[u64](free_slot) == 0 {
                return slop_os.PortError.TooManyBindings
            }
            binding = new_binding(kernel, port, key, .Signal) or_return binding_failure(port)
            binding.object = object
            binding.object_generation = generation
            free_slot.binding = cast[u64](binding)
            free_slot.generation = binding.generation
        }
    }
    binding.signals = cast[u32](signals)
    binding.once = mode == .Once
    binding.armed = true
    return null
}

/**
 * Raise signals on the bindings watching an object, each with a detail. A binding its port dropped is passed by.
 * Takes the watchers' lock, then each port's.
 *
 * @param kernel The kernel; only the ports' queues change, each under its port's lock.
 * @param watchers The object's watchers' slots.
 * @param lock The lock that guards watchers.
 * @param rank lock's rank, as lock_at takes it.
 * @param signals The signals raised, slop_os.SIGNAL_* bits; a binding not watching for any of them, or not
 *     armed, isn't queued.
 * @param detail What the packet carries besides, like a DMA fault's address.
 */
raise_watchers :: fn(kernel: ptr[mut Kernel], watchers: ptr[mut EndBinding[2]], lock: ptr[mut concurrency.SpinLock], rank: LockRank, signals: u32,
    detail: u64) {
    lock_at(lock, rank)
    defer unlock_at(lock, rank)
    for i in 0..<2 {
        slot :: &watchers^[i]
        if slot.binding != 0 {
            binding :: cast[ptr[mut Binding]](slot.binding)
            // A binding the port dropped is no longer this one, whatever its slot holds now
            match lock_bound_port(binding, slot.generation) {
                case Some(port) => {
                    binding.detail = detail
                    signal_binding(kernel, port, binding, signals)
                    unlock_at(&port.lock, .Port)
                }
                case None => {}
            }
        }
    }
}

/**
 * Tell whether an object is owned within a process's subtree, up at most MAX_OWNER_DEPTH owners.
 *
 * @param object The object, as its address.
 * @param process The Process, as its address.
 * @return True if the process owns the object, or owns what owns it, and so on; false for the process itself.
 */
in_subtree :: fn(object: u64, process: u64) -> bool {
    owner := cast[ptr[ObjectHeader]](object).owner
    for depth in 0..<MAX_OWNER_DEPTH {
        if owner == 0 {
            return false
        }
        if owner == process {
            return true
        }
        owner = cast[ptr[ObjectHeader]](owner).owner
    }
    return false
}

/**
 * Put a thread on the kernel's list of every thread, for finding one by its ID. Takes threads_lock.
 *
 * @param kernel The kernel, whose list of threads (first_thread) changes under threads_lock.
 * @param thread The thread, which isn't on the list yet.
 */
link_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    lock_at(&kernel.threads_lock, .Threads)
    thread.all_previous = 0
    thread.all_next = kernel.first_thread
    if kernel.first_thread != 0 {
        cast[ptr[mut Thread]](kernel.first_thread).all_previous = cast[u64](thread)
    }
    kernel.first_thread = cast[u64](thread)
    thread.on_list = true
    unlock_at(&kernel.threads_lock, .Threads)
}

/**
 * Take a thread off the kernel's list of every thread, if it's on it. Takes threads_lock.
 *
 * @param kernel The kernel, whose list of threads (first_thread) changes under threads_lock.
 * @param thread The thread, being destroyed; one not on the list is left alone.
 */
unlink_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    lock_at(&kernel.threads_lock, .Threads)
    defer unlock_at(&kernel.threads_lock, .Threads)
    if !thread.on_list {
        return void
    }
    if thread.all_previous != 0 {
        cast[ptr[mut Thread]](thread.all_previous).all_next = thread.all_next
    }
    else {
        kernel.first_thread = thread.all_next
    }
    if thread.all_next != 0 {
        cast[ptr[mut Thread]](thread.all_next).all_previous = thread.all_previous
    }
    thread.on_list = false
}

/**
 * Find a live thread by its ID in a process's subtree. Takes threads_lock.
 *
 * @param kernel The kernel, whose list of threads is walked under threads_lock.
 * @param process The Process, as its address.
 * @param id The thread's ID.
 * @return The thread, or null if none has the ID, or it's dying, or it isn't in the subtree. It may be destroyed
 *     at any time after, but its memory isn't freed before this CPU's next quiescent point.
 */
thread_in :: fn(kernel: ptr[mut Kernel], process: u64, id: u64) -> ptr[mut Thread]? {
    lock_at(&kernel.threads_lock, .Threads)
    defer unlock_at(&kernel.threads_lock, .Threads)
    with {
        address := kernel.first_thread
    }
    loop {
        if address == 0 {
            break
        }
        thread :: cast[ptr[mut Thread]](address)
        if thread.id == id {
            return if !is_dying(address) && in_subtree(address, process) { thread } else { null }
        }
        address = thread.all_next
    }
    return null
}

/**
 * Count the live threads in a process's subtree, and list their IDs. Takes threads_lock.
 *
 * @param kernel The kernel, whose list of threads is walked under threads_lock.
 * @param process The Process, as its address.
 * @param ids Where the IDs are written, the newest thread first.
 * @param capacity How many IDs to write, at most; more than 64 is taken as 64.
 * @return How many live threads the subtree has, which may be more than capacity.
 */
threads_of :: fn(kernel: ptr[mut Kernel], process: u64, ids: ptr[mut u64[64]], capacity: u32) -> u32 {
    lock_at(&kernel.threads_lock, .Threads)
    defer unlock_at(&kernel.threads_lock, .Threads)
    count := cast[u32](0)
    with {
        address := kernel.first_thread
    }
    loop {
        if address == 0 {
            break
        }
        thread :: cast[ptr[Thread]](address)
        if !is_dying(address) && in_subtree(address, process) {
            if count < capacity && cast[usize](count) < 64 {
                ids^[cast[usize](count) % 64] = thread.id
            }
            count += 1
        }
        address = thread.all_next
    }
    return count
}

/**
 * Copy bytes between two address spaces, through a 256-byte buffer on the kernel stack.
 *
 * @param kernel The kernel, for the direct map both spaces' pages are reached through; each space's lock is taken
 *     in turn, a part at a time, so the caller holds none of rank Space or above.
 * @param space The address space copied from.
 * @param address The user address in space the bytes start at.
 * @param other The address space copied to.
 * @param buffer The user address in other they go to.
 * @param size How many bytes; 0 copies nothing.
 * @return True if all of them were copied; false if either range isn't user memory mapped, readable or writable as
 *     it needs to be, in which case what's before the failed part may have been copied.
 */
copy_between :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, other: ptr[mut AddressSpace], buffer: u64,
    size: u64) -> bool {
    bounce : u8[256]
    done := cast[u64](0)
    loop {
        if done >= size {
            break
        }
        part :: if size - done < 256 { size - done } else { cast[u64](256) }
        if !copy_from_user(kernel, space, address + done, cast[u64](&bounce[0]), part)
            || !copy_to_user(kernel, other, buffer + done, cast[u64](&bounce[0]), part) {
            return false
        }
        done += part
    }
    return true
}

/** The most registers a debugger sees on any architecture: x86-64's 18, AArch64's 34. */
MAX_USER_REGISTERS :: 64

/**
 * Write a thread's saved registers, as a debugger sees them (slop_os.THREAD_REGISTERS), to user memory.
 *
 * @param kernel The kernel, for the direct map the registers are written through; space's lock is taken.
 * @param thread The thread, parked so its registers don't change.
 * @param space The caller's address space.
 * @param buffer The user address in space they go to: arch.user_register_count u64s.
 * @return True if written; false if the buffer isn't writable user memory.
 */
read_registers :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], space: ptr[mut AddressSpace], buffer: u64) -> bool {
    values : u64[MAX_USER_REGISTERS]
    count :: arch.user_register_count()
    runtime.assert(count <= MAX_USER_REGISTERS, "MAX_USER_REGISTERS covers every architecture's")
    for i in 0..<cast[usize](count) {
        values[i % MAX_USER_REGISTERS] = arch.get_user_register(&thread.registers, cast[u32](i))
    }
    return copy_to_user(kernel, space, buffer, cast[u64](&values[0]), cast[u64](count) * 8)
}

/**
 * Set a parked thread's saved registers from user memory, each checked, so a bad value leaves all of them as they
 * were.
 *
 * @param kernel The kernel, for the direct map the registers are read through; space's lock is taken.
 * @param thread The thread, parked.
 * @param space The caller's address space.
 * @param buffer The user address in space they come from: arch.user_register_count u64s.
 * @return Null once set; BadBuffer if the buffer isn't readable user memory; BadRegisters if a value is one user
 *     mode can't have.
 */
write_registers :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], space: ptr[mut AddressSpace], buffer: u64) -> slop_os.ControlError? {
    values : u64[MAX_USER_REGISTERS]
    count :: arch.user_register_count()
    runtime.assert(count <= MAX_USER_REGISTERS, "MAX_USER_REGISTERS covers every architecture's")
    if !copy_from_user(kernel, space, buffer, cast[u64](&values[0]), cast[u64](count) * 8) {
        return slop_os.ControlError.BadBuffer
    }
    // Checked on a copy, so a bad value leaves them as they were
    changed := thread.registers
    for i in 0..<cast[usize](count) {
        if !arch.set_user_register(&changed, cast[u32](i), values[i % MAX_USER_REGISTERS]) {
            return slop_os.ControlError.BadRegisters
        }
    }
    thread.registers = changed
    return null
}
