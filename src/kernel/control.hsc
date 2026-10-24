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
HELD_SUSPEND : u32 : 1 << 0
HELD_STOP : u32 : 1 << 1

// How far up an ownership chain a walk goes, so one through slots reused meanwhile always ends.
MAX_OWNER_DEPTH :: 4096

// Hold thread for bit: parked at once if it's on a run queue; told, if it runs on another CPU.
hold_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], bit: u32) {
    concurrency.lock(&thread.control)
    defer concurrency.unlock(&thread.control)
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
        concurrency.lock(&cpu.run_queue.lock)
        if thread.cpu != index {
            concurrency.unlock(&cpu.run_queue.lock)
            continue
        }
        if thread.queued {
            unlink(&cpu.run_queue, thread)
            thread.parked = true
            thread.state = .Stopped
        }
        running :: cpu.current == cast[u64](thread)
        concurrency.unlock(&cpu.run_queue.lock)
        if running && cpu != per_cpu() {
            cpus :: kernel.cpus
            runtime.assert(cast[usize](index) < cpus.count, "every online CPU is in kernel.cpus")
            arch.send_ipi(cpus[index].hardware_id, .Reschedule)
        }
        break
    }
}

// Let go of thread for bit: made ready if it's parked and nothing else holds it.
unhold_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], bit: u32) {
    concurrency.lock(&thread.control)
    defer concurrency.unlock(&thread.control)
    thread.held &= ~bit
    if thread.held == 0 && thread.parked && !is_dying(cast[u64](thread)) {
        thread.parked = false
        make_ready(kernel, thread, thread.cpu)
    }
}

/*
 * Park thread if something holds it, saving its vector state if it's the CPU's current thread (saved):
 * whether it did. The caller takes it off the CPU.
 */
park_if_held :: fn(thread: ptr[mut Thread], saved: bool) -> bool {
    if intrinsics.atomic_load_u32_acquire(&thread.held) == 0 {
        return false
    }
    concurrency.lock(&thread.control)
    defer concurrency.unlock(&thread.control)
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

// Whether a thread is held and parked, so its registers are its own to read and write.
is_parked :: fn(thread: ptr[mut Thread]) -> bool {
    concurrency.lock(&thread.control)
    defer concurrency.unlock(&thread.control)
    return thread.parked
}

/*
 * Bind object, a process or a thread, to port under key, for its watchers: a Signal packet when it raises
 * any of signals, which only SIGNAL_TERMINATED is so far. Takes object's lock (lock) itself.
 */
watch_bind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], object: u64, watchers: ptr[mut EndBinding[2]], lock: ptr[mut concurrency.SpinLock],
    signals: slop_os.Signals, key: u64, mode: slop_os.BindMode) -> slop_os.PortError? {
    concurrency.lock(lock)
    defer concurrency.unlock(lock)
    if is_dying(object) {
        return slop_os.PortError.ObjectGone
    }
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
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

// Raise signals on the bindings watching an object. Takes its lock (lock) itself.
raise_watchers :: fn(kernel: ptr[mut Kernel], watchers: ptr[mut EndBinding[2]], lock: ptr[mut concurrency.SpinLock], signals: u32,
    detail: u64) {
    concurrency.lock(lock)
    defer concurrency.unlock(lock)
    for i in 0..<2 {
        slot :: &watchers^[i]
        if slot.binding != 0 {
            binding :: cast[ptr[mut Binding]](slot.binding)
            port :: cast[ptr[mut Port]](intrinsics.atomic_load_u64(&binding.port))
            concurrency.lock(&port.lock)
            // A binding the port dropped is no longer this one, whatever its slot holds now
            if binding.generation == slot.generation && binding.port == cast[u64](port) && !is_dying(cast[u64](port)) {
                binding.detail = detail
                signal_binding(kernel, port, binding, signals)
            }
            concurrency.unlock(&port.lock)
        }
    }
}

// Whether object is owned within process's subtree.
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

// Every thread, on the kernel's list, for finding one by its ID.
link_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    concurrency.lock(&kernel.threads_lock)
    thread.all_previous = 0
    thread.all_next = kernel.first_thread
    if kernel.first_thread != 0 {
        cast[ptr[mut Thread]](kernel.first_thread).all_previous = cast[u64](thread)
    }
    kernel.first_thread = cast[u64](thread)
    thread.on_list = true
    concurrency.unlock(&kernel.threads_lock)
}

unlink_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    concurrency.lock(&kernel.threads_lock)
    defer concurrency.unlock(&kernel.threads_lock)
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

// The live thread with id in process's subtree, or null.
thread_in :: fn(kernel: ptr[mut Kernel], process: u64, id: u64) -> ptr[mut Thread]? {
    concurrency.lock(&kernel.threads_lock)
    defer concurrency.unlock(&kernel.threads_lock)
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

// How many threads process's subtree has; the first capacity's IDs, written at ids.
threads_of :: fn(kernel: ptr[mut Kernel], process: u64, ids: ptr[mut u64[64]], capacity: u32) -> u32 {
    concurrency.lock(&kernel.threads_lock)
    defer concurrency.unlock(&kernel.threads_lock)
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

/*
 * Copy size bytes between two address spaces, through the kernel, a page's worth at a time: from (space,
 * address) to (other, buffer). False if either isn't mapped there.
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

// The most registers a debugger sees on any architecture: x86-64's 18, AArch64's 34.
MAX_USER_REGISTERS :: 64

// A thread's registers, as a debugger sees them (slop_os.THREAD_REGISTERS), written at buffer in space.
read_registers :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], space: ptr[mut AddressSpace], buffer: u64) -> bool {
    values : u64[MAX_USER_REGISTERS]
    count :: arch.user_register_count()
    runtime.assert(count <= MAX_USER_REGISTERS, "MAX_USER_REGISTERS covers every architecture's")
    for i in 0..<cast[usize](count) {
        values[i % MAX_USER_REGISTERS] = arch.get_user_register(&thread.registers, cast[u32](i))
    }
    return copy_to_user(kernel, space, buffer, cast[u64](&values[0]), cast[u64](count) * 8)
}

// A parked thread's registers, set from buffer in space: why not, if they couldn't be.
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
