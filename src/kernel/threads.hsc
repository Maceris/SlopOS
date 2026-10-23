package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import slab from "slab"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Threads (roadmap M4, knowledge/design/threads.md, decisions/0023): what runs in user mode. One kernel
 * stack per CPU, so a thread is its saved registers, its vector state, and its place in the scheduler:
 * a slab object, under 1 KiB, and its vector state from the heap, about 1 KiB more.
 *
 * Without system calls yet (M5), a thread runs until the kernel stops: it's created by the kernel, is
 * preempted by the timer, and moves between CPUs.
 */
//TODO(claude): blocking, exiting and destroying threads, and thread_create as a system call (M5)

ThreadState :: enum #backed_by(u8) {
    // On a CPU's run queue.
    Ready,
    // On a CPU, as that CPU's current thread.
    Running,
}

Thread :: struct #align(16) {
    // Saved at every entry from user mode, and restored by return_to_user.
    registers : arch.UserRegisters,
    // Its arch.VectorState, from the heap.
    vector : u64,
    space : ptr[mut AddressSpace],
    // Its CpuBudget, or 0 for the background band only.
    budget : u64,
    state : ThreadState,
    // The CPU it's on, or last ran on, and the run-queue level it's on there (scheduler.hsc).
    cpu : u32,
    level : u32,
    // Its neighbors on a run queue, as addresses, 0 at either end.
    next : u64,
    previous : u64,
    // Counter ticks it's run.
    run_time : u64,
    id : u64,
}

#assert size_of(Thread) <= 1024

ThreadError :: enum {
    OutOfMemory,
}

init_threads :: fn(kernel: ptr[mut Kernel]) {
    kernel.thread_cache = slab.make_cache(cast[u64](size_of(Thread)), cast[u64](align_of(Thread)))
}

/*
 * A thread in space, starting at start, with vector state for config, bound to budget (0 for none).
 * It doesn't run until start_thread.
 */
create_thread :: fn(kernel: ptr[mut Kernel], space #escaping : ptr[mut AddressSpace], start: ptr[arch_interface.UserStart],
    config: arch_interface.VectorConfig, budget: u64) -> Result[ptr[mut Thread], ThreadError] {
    vector, error :: runtime.new_array_aligned(u8, arch.vector_state_size(config), arch.vector_state_alignment())
    if error != null {
        return .Error(.OutOfMemory)
    }
    object :: slab.allocate(&kernel.thread_cache, &kernel.frames) or_else 0
    if object == 0 {
        runtime.free_array_aligned(vector, arch.vector_state_alignment())
        return .Error(.OutOfMemory)
    }
    thread :: cast[ptr[mut Thread]](object)
    thread^ = Thread.{}
    thread.vector = cast[u64](vector.data)
    arch.init_vector_state(cast[ptr[mut arch.VectorState]](thread.vector), config)
    arch.init_user_registers(&thread.registers, start)
    thread.space = space
    thread.budget = budget
    thread.id = intrinsics.interlocked_increment_u64(&kernel.next_thread_id) + 1
    return .Ok(thread)
}

// Make a new thread ready on the next CPU in turn.
start_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    cpu :: cast[u32](intrinsics.interlocked_increment_u32(&kernel.next_start_cpu)) % online
    make_ready(kernel, thread, cpu)
}

// Keep the registers an entry from user mode saved, in the CPU's current thread.
save_user_registers :: fn(registers: ptr[arch.UserRegisters]) {
    cpu :: per_cpu()
    if cpu.current != 0 {
        cast[ptr[mut Thread]](cpu.current).registers = registers^
    }
}
