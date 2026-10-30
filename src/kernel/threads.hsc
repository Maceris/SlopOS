package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
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
    // Waiting on a port (ports.hsc).
    Blocked,
    // Held, and parked on no queue until nothing holds it (control.hsc).
    Stopped,
}

Thread :: struct #align(16) {
    header : ObjectHeader,
    // Saved at every entry from user mode, and restored by return_to_user.
    registers : arch.UserRegisters,
    // Its arch.VectorState, from the heap, and that block's size.
    vector : u64,
    vector_size : u64,
    space : ptr[mut AddressSpace],
    // Its CpuTime (budgets.hsc), or 0 for the background band only.
    budget : u64,
    // The CpuBudget object that time is, and its neighbors among what runs on it (cpu_budgets.hsc), under kernel.cpu_budgets_lock.
    budget_object : u64,
    budget_next : u64,
    budget_previous : u64,
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
    // Started, so counted among its process's live threads (Process.live_threads)
    counted : bool,
    // Counter ticks it's run.
    run_time : u64,
    id : u64,
    // Its port_wait, while it has one (ports.hsc): the port and its generation, where its packets go and how
    // many, until when (counter ticks, or slop_os.NO_DEADLINE), and its place among the port's waiters.
    wait_port : u64,
    wait_port_generation : u32,
    wait_capacity : u32,
    wait_buffer : u64,
    wait_deadline : u64,
    waiting : bool,
    wait_next : u64,
    wait_previous : u64,
    // The paged memory it waits on for a page (paging.hsc), 0 if none; linked there through wait_next and wait_previous.
    fault_memory : u64,
    // Counts its waits, so a deadline from an earlier one doesn't wake a later one.
    wait_sequence : u64,
    wait_timer : TimerEntry,
    // Process control (control.hsc): what holds it (HELD_*), and whether it's parked, under control.
    control : concurrency.SpinLock,
    held : u32,
    parked : bool,
    // A stop (intercepts.hsc): the intercept, where and why, whether it's been reported, and its neighbors
    // on the intercept's list.
    stop_reported : bool,
    stop_linked : bool,
    // Its next system call's entry stop is passed over: it's the call made again after one.
    restarted : bool,
    stop_point : u32,
    stop_number : u32,
    stop_intercept : u64,
    stop_address : u64,
    stop_next : u64,
    stop_previous : u64,
    // The system call it's in, for its exit stop.
    syscall_number : u64,
    // On the kernel's list of threads, under threads_lock.
    on_list : bool,
    all_next : u64,
    all_previous : u64,
    // Bindings watching for it to end (SIGNAL_TERMINATED), under control.
    watchers : EndBinding[2],
}

#assert size_of(Thread) <= 1024

ThreadError :: enum {
    OutOfMemory,
    // Its owner or its address space is being destroyed.
    OwnerGone,
    // Its memory budget can't pay for it.
    BudgetExceeded,
}

/*
 * A thread owned by owner (a Process's address, 0 for the kernel), in space, starting at start, with
 * vector state for config, bound to CPU budget (0 for none), charged to memory_budget with its vector state.
 * It doesn't run until start_thread.
 */
create_thread :: fn(kernel: ptr[mut Kernel], owner: u64, space #escaping : ptr[mut AddressSpace], start: ptr[arch_interface.UserStart],
    config: arch_interface.VectorConfig, budget: u64, memory_budget: u64) -> Result[ptr[mut Thread], ThreadError] {
    object := cast[u64](0)
    match new_object(kernel, .Thread, memory_budget, cast[u64](arch.vector_state_size(config))) {
        case Ok(address) => object = address
        case Error(error) => return .Error(if error == .BudgetExceeded { ThreadError.BudgetExceeded } else { ThreadError.OutOfMemory })
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
    // A CpuTime of its own, as the kernel's tests give, or its process's budget once it's adopted
    thread.budget = budget
    thread.wait_timer = make_timer()
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
    link_thread(kernel, thread)
    if budget == 0 && owner != 0 {
        join_process_budget(kernel, thread, cast[ptr[Process]](owner))
    }
    return .Ok(thread)
}

// Make a new thread ready on the next CPU in turn that its budget has.
start_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    owner :: thread.header.owner
    if owner != 0 && !thread.counted && cast[ptr[ObjectHeader]](owner).kind == .Process {
        thread.counted = true
        _ = intrinsics.interlocked_increment_u32(&cast[ptr[mut Process]](owner).live_threads)
    }
    cpus :: if thread.budget != 0 { intrinsics.atomic_load_u64_acquire(&cast[ptr[mut CpuTime]](thread.budget).cpus) } else { ~cast[u64](0) }
    make_ready(kernel, thread, next_cpu_of(kernel, &kernel.next_start_cpu, cpus))
}

/*
 * Destroying a thread: off its address space's list and its run queue. If another CPU runs it, that CPU
 * is told, and doesn't resume it.
 */
destroy_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    leave_thread_budget(kernel, thread)
    cancel_wait(kernel, thread)
    cancel_fault_wait(thread)
    leave_space(thread)
    forget_stop(thread)
    unlink_thread(kernel, thread)
    raise_watchers(kernel, &thread.watchers, &thread.control, cast[u32](slop_os.SIGNAL_TERMINATED), 0)
    end_process_if_last(kernel, thread)
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

/*
 * A started thread's process, once that was its last live thread, ends as killed, unless it's ending already
 * (decisions/0104): so a process whose threads all fault, with nothing to fix them, doesn't linger with none, and
 * whoever watches it learns it ended. After the destroy this one's part of, if any.
 */
end_process_if_last :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    if !thread.counted {
        return void
    }
    thread.counted = false
    owner :: thread.header.owner
    process :: cast[ptr[mut Process]](owner)
    if intrinsics.interlocked_decrement_u32(&process.live_threads) == 1 && !is_dying(owner) {
        destroy_later(kernel, owner, intrinsics.atomic_load_u32_acquire(&process.header.generation))
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
