package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Threads (roadmap M4, M5, knowledge/design/threads.md, decisions/0023, 0050): what runs in user mode.
 * One kernel stack per CPU, so a thread is its saved registers, its vector state, and its place in the
 * scheduler: an object under 1 KiB, owned by a process, and its vector state from the heap, about
 * 1 KiB more.
 *
 * Destroying one, by closing its owning handle, by its owner's destruction, by its address space's, or
 * by thread_exit, takes it off its run queue at once. A CPU running it sees it's dying at its next
 * entry and doesn't resume it (scheduler.hsc).
 */
//TODO(claude): blocking threads on ports (M5, ports)

ThreadState :: enum #backed_by(u8) {
    // On a CPU's run queue.
    Ready,
    // On a CPU, as that CPU's current thread.
    Running,
}

Thread :: struct #align(16) {
    header : ObjectHeader,
    // Saved at every entry from user mode, and restored by return_to_user.
    registers : arch.UserRegisters,
    // Its arch.VectorState, from the heap, and that block's size.
    vector : u64,
    vector_size : u64,
    space : ptr[mut AddressSpace],
    // Its CpuBudget, or 0 for the background band only.
    budget : u64,
    state : ThreadState,
    // The CPU it's on, or last ran on; the run-queue level it's on there, and whether it's queued, which
    // that CPU's run-queue lock guards (scheduler.hsc).
    cpu : u32,
    level : u32,
    queued : bool,
    // Its neighbors on a run queue, as addresses, 0 at either end.
    next : u64,
    previous : u64,
    // Its neighbors among its address space's threads.
    space_next : u64,
    space_previous : u64,
    in_space : bool,
    // Counter ticks it's run.
    run_time : u64,
    id : u64,
}

#assert size_of(Thread) <= 1024

ThreadError :: enum {
    OutOfMemory,
    // Its owner or its address space is being destroyed.
    OwnerGone,
}

/*
 * A thread owned by owner (a Process's address, 0 for the kernel), in space, starting at start, with
 * vector state for config, bound to budget (0 for none). It doesn't run until start_thread.
 */
create_thread :: fn(kernel: ptr[mut Kernel], owner: u64, space #escaping : ptr[mut AddressSpace], start: ptr[arch_interface.UserStart],
    config: arch_interface.VectorConfig, budget: u64) -> Result[ptr[mut Thread], ThreadError] {
    object := cast[u64](0)
    match new_object(kernel, .Thread) {
        case Ok(address) => object = address
        case Error(error) => return .Error(.OutOfMemory)
    }
    thread :: cast[ptr[mut Thread]](object)
    vector, error :: runtime.new_array_aligned(u8, arch.vector_state_size(config), arch.vector_state_alignment())
    if error != null {
        release_object(kernel, object)
        return .Error(.OutOfMemory)
    }
    thread.vector = cast[u64](vector.data)
    thread.vector_size = cast[u64](vector.count)
    arch.init_vector_state(cast[ptr[mut arch.VectorState]](thread.vector), config)
    arch.init_user_registers(&thread.registers, start)
    thread.space = space
    thread.budget = budget
    thread.id = intrinsics.interlocked_increment_u64(&kernel.next_thread_id) + 1
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.OwnerGone)
        }
    }
    if !join_space(space, thread) {
        _ = destroy_object(kernel, object)
        return .Error(.OwnerGone)
    }
    return .Ok(thread)
}

// Make a new thread ready on the next CPU in turn.
start_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    cpu :: cast[u32](intrinsics.interlocked_increment_u32(&kernel.next_start_cpu)) % online
    make_ready(kernel, thread, cpu)
}

/*
 * Destroying a thread: off its address space's list and its run queue. If another CPU runs it, that CPU
 * is told, and doesn't resume it.
 */
destroy_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    leave_space(thread)
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

// Once no CPU can use it: its vector state.
release_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    if thread.vector != 0 {
        runtime.free_array_aligned(view_of(cast[ptr[u8]](thread.vector), cast[usize](thread.vector_size)), arch.vector_state_alignment())
        thread.vector = 0
    }
}

is_dying :: fn(object: u64) -> bool {
    header :: cast[ptr[ObjectHeader]](object)
    return intrinsics.atomic_load_u32(&header.dying) != 0
}

// Keep the registers an entry from user mode saved, in the CPU's current thread.
save_user_registers :: fn(registers: ptr[arch.UserRegisters]) {
    cpu :: per_cpu()
    if cpu.current != 0 {
        cast[ptr[mut Thread]](cpu.current).registers = registers^
    }
}
