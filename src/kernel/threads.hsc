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

/** Where a thread is in the scheduler's eyes. */
ThreadState :: enum #backed_by(u8) {
    /** On a CPU's run queue. */
    Ready,
    /** On a CPU, as that CPU's current thread. */
    Running,
    /** Waiting on a port (ports.hsc). */
    Blocked,
    /** Held, and parked on no queue until nothing holds it (control.hsc). */
    Stopped,
}

/** A thread: what runs in user mode, an object owned by a process (or the kernel), under 1 KiB. */
Thread :: struct #align(16) {
    /** Its object header. */
    header : ObjectHeader,
    /** Saved at every entry from user mode, and restored by return_to_user. */
    registers : arch.UserRegisters,
    /** Its arch.VectorState's address, from the kernel heap, freed at its release; 0 once freed. */
    vector : u64,
    /** The bytes of its vector state's block, as arch.vector_state_size gave for its configuration. */
    vector_size : u64,
    /** The address space it runs in, which outlives it: destroying the space destroys its threads. */
    space : ptr[mut AddressSpace],
    /** Its CpuTime (budgets.hsc), as an address, or 0 for the background band only. */
    budget : u64,
    /** The CpuBudget object that time is part of, as an address, 0 for none; under kernel.cpu_budgets_lock. */
    budget_object : u64,
    /** The next thread on its CPU budget's list, 0 at the end; under kernel.cpu_budgets_lock (cpu_budgets.hsc). */
    budget_next : u64,
    /** The previous thread on its CPU budget's list, 0 at the start; under kernel.cpu_budgets_lock. */
    budget_previous : u64,
    /** Where it is in the scheduler: ready, running, blocked or stopped. */
    state : ThreadState,
    /**
     * The index of the CPU it's on, or last ran on; written with a release store under that CPU's run-queue lock, so
     * it may change until that lock is held and it's still the same (scheduler.hsc).
     */
    cpu : u32,
    /** The run-queue level it's queued at, or runs at, on that CPU: 0 for the background band, a priority plus 1. */
    level : u32,
    /** Whether it's on its CPU's run queue; under that queue's lock. */
    queued : bool,
    /** The next thread at its level on its run queue, as an address, 0 at the end; under the queue's lock. */
    next : u64,
    /** The previous thread at its level on its run queue, as an address, 0 at the start; under the queue's lock. */
    previous : u64,
    /** The next thread in its address space, 0 at the end; under the space's threads_lock. */
    space_next : u64,
    /** The previous thread in its address space, 0 at the start; under the space's threads_lock. */
    space_previous : u64,
    /** Whether it's on its address space's list of threads; under the space's threads_lock. */
    in_space : bool,
    /** Started, so counted among its process's live threads (Process.live_threads). */
    counted : bool,
    /** The counter ticks it has run, charged at each entry to the scheduler. */
    run_time : u64,
    /** Its ID, unique for as long as the kernel runs, from 1 up (Kernel.next_thread_id). */
    id : u64,
    /** The port its port_wait waits on, as an address, 0 while it has none (ports.hsc). */
    wait_port : u64,
    /** That port's generation when the wait began, so a port destroyed since isn't used. */
    wait_port_generation : u32,
    /** How many packets its wait's buffer holds. */
    wait_capacity : u32,
    /** Where its wait's packets go: a user virtual address in its space. */
    wait_buffer : u64,
    /** When its wait times out, in counter ticks, or slop_os.NO_DEADLINE for never. */
    wait_deadline : u64,
    /** Whether it's on its port's list of waiters; under the port's lock. */
    waiting : bool,
    /** The next waiter on its port's list, or on its paged memory's, as an address, 0 at the end. */
    wait_next : u64,
    /** The previous waiter on its port's list, or on its paged memory's, as an address, 0 at the start. */
    wait_previous : u64,
    /**
     * The paged memory it waits on for a page (paging.hsc), 0 if none; linked there through wait_next and
     * wait_previous.
     */
    fault_memory : u64,
    /** Counts its waits, so a deadline from an earlier one doesn't wake a later one. */
    wait_sequence : u64,
    /** The timer that ends its wait at wait_deadline (timers.hsc). */
    wait_timer : TimerEntry,
    /** Its debugging state, which a debugger sets (thread_set_debug) and returning to user mode loads; none at first. */
    debug : arch.DebugRegisters,
    /**
     * The timer that ends its process if it stays stopped at a fault past FAULT_STOP_LIMIT, under an intercept with
     * STOP_FAULT_LIMITED (intercepts.hsc).
     */
    fault_timer : TimerEntry,
    /** Counts its stops at a fault, so a fault timer from an earlier one doesn't end a later one. */
    fault_stops : u32,
    /** Process control's lock (control.hsc), at rank ThreadControl: guards held, parked, its stop and watchers. */
    control : concurrency.SpinLock,
    /** What holds it, HELD_* bits (control.hsc): it doesn't run while any is set. */
    held : u32,
    /** Whether it's parked: held, and on no run queue until nothing holds it. */
    parked : bool,
    /** Whether its stop has been reported to its intercept (intercepts.hsc). */
    stop_reported : bool,
    /** Whether it's on its intercept's list of stopped threads; under the intercept's lock. */
    stop_linked : bool,
    /** Its next system call's entry stop is passed over: it's the call made again after one. */
    restarted : bool,
    /** Where it stopped, a slop_os.StopPoint's value. */
    stop_point : u32,
    /** Why it stopped: the system call's number, or a fault's access. */
    stop_number : u32,
    /** The Intercept that stopped it, as an address, while it's stopped. */
    stop_intercept : u64,
    /** A fault's address, for a stop at a fault: a user virtual address. */
    stop_address : u64,
    /** The next thread on its intercept's list of stopped threads, 0 at the end; under the intercept's lock. */
    stop_next : u64,
    /** The previous thread on that list, 0 at the start; under the intercept's lock. */
    stop_previous : u64,
    /** The system call it's in, for its exit stop. */
    syscall_number : u64,
    /** Whether it's on the kernel's list of threads; under kernel.threads_lock. */
    on_list : bool,
    /** The next thread on the kernel's list, 0 at the end; under kernel.threads_lock. */
    all_next : u64,
    /** The previous thread on the kernel's list, 0 at the start; under kernel.threads_lock. */
    all_previous : u64,
    /** Bindings watching for it to end (SIGNAL_TERMINATED), under control. */
    watchers : EndBinding[2],
}

#assert size_of(Thread) <= 1024

/** Why a thread couldn't be made. */
ThreadError :: enum {
    /** No slot for it, or no heap memory for its vector state. */
    OutOfMemory,
    /** Its owner or its address space is being destroyed. */
    OwnerGone,
    /** Its memory budget can't pay for it. */
    BudgetExceeded,
}

/**
 * Make a thread. It doesn't run until start_thread.
 *
 * @param kernel The kernel: its pools give the slot, its heap the vector state, kernel.next_thread_id the ID, and
 *     kernel.threads_lock and kernel.cpu_budgets_lock are taken to put it on their lists.
 * @param owner The Process that owns it, as an address, or 0 for the kernel.
 * @param space The address space it runs in, which keeps it on its list of threads.
 * @param start Where it starts: its instruction pointer, its stack pointer and its argument, user virtual addresses
 *     in space; read before this returns.
 * @param config What vector state it has, which says how big that state is.
 * @param budget The CpuTime it runs on, as an address, as the kernel's tests give; or 0, when an owned thread joins
 *     its process's CPU budget, and one the kernel owns runs only in the background band.
 * @param memory_budget The MemoryBudget it's charged to, as an address, 0 for the kernel's own: its slot and its
 *     vector state.
 * @return The thread, owned by owner, on the kernel's list of threads, with an ID of its own.
 * @error OutOfMemory No slot for it, or no heap memory for its vector state.
 * @error BudgetExceeded memory_budget can't pay for it.
 * @error OwnerGone Its owner or its address space is being destroyed; the thread was destroyed again.
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
    thread.debug = arch.DebugRegisters.{}
    thread.fault_timer = make_timer()
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

/**
 * Start a new thread: make it ready on the next CPU in turn that its budget has, and count it among its process's
 * live threads, so the process ends when the last goes. An intercept with STOP_THREAD_START stops it first, before
 * its first instruction, and it's made ready once it's let go.
 *
 * @param kernel The kernel, whose next_start_cpu is advanced, and the chosen CPU's run-queue lock taken.
 * @param thread The thread, made by create_thread and not yet started; started again, it isn't counted twice.
 */
start_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    owner :: thread.header.owner
    if owner != 0 && !thread.counted && cast[ptr[ObjectHeader]](owner).kind == .Process {
        thread.counted = true
        _ = intrinsics.interlocked_increment_u32(&cast[ptr[mut Process]](owner).live_threads)
    }
    cpus :: if thread.budget != 0 { intrinsics.atomic_load_u64_acquire(&cast[ptr[mut CpuTime]](thread.budget).cpus) } else { ~cast[u64](0) }
    cpu :: next_cpu_of(kernel, &kernel.next_start_cpu, cpus)
    intrinsics.atomic_store_u32_release(&thread.cpu, cpu)
    if stop_thread(kernel, thread, .ThreadStart, 0, 0, false) {
        return void
    }
    make_ready(kernel, thread, cpu)
}

/**
 * Destroy a thread, as destroy_object does for its kind: off its CPU budget, its wait, its address space's list, its
 * intercept's, the kernel's list and its run queue.
 *
 * Its watchers are raised with SIGNAL_TERMINATED, and its process ends if it was its last live thread. If another
 * CPU runs it, that CPU gets a reschedule IPI, and doesn't resume it; if this CPU runs it, the scheduler drops it at
 * its next entry.
 *
 * @param kernel The kernel: among others, kernel.cpu_budgets_lock, kernel.threads_lock, its space's threads_lock, its
 *     control lock and its CPU's run-queue lock are each taken in turn; called during destroy_object.
 * @param thread The thread, already dying, its generation advanced.
 */
destroy_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    leave_thread_budget(kernel, thread)
    cancel_wait(kernel, thread)
    cancel_fault_wait(thread)
    leave_space(thread)
    forget_stop(thread)
    unlink_thread(kernel, thread)
    raise_watchers(kernel, &thread.watchers, &thread.control, .ThreadControl, cast[u32](slop_os.SIGNAL_TERMINATED), 0)
    end_process_if_last(kernel, thread)
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
 * End a started thread's process as killed, once that was its last live thread, unless it's ending already
 * (decisions/0104): so a process whose threads all fault, with nothing to fix them, doesn't linger with none, and
 * whoever watches it learns it ended.
 *
 * The process is destroyed after the destroy this one's part of, if any (destroy_later).
 *
 * @param kernel The kernel, for destroying the process later (destroy_later), on this CPU's doomed list.
 * @param thread The thread that's going; one never started, or already uncounted, changes nothing.
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

/**
 * Release a destroyed thread once no CPU can use it, as release_object does for its kind: its vector state goes
 * back to the heap.
 *
 * @param kernel The kernel, unused; the vector state goes back to the context's allocator, the kernel heap.
 * @param thread The thread, its grace period over, or one create_thread is letting go of before it had vector state.
 */
release_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    if thread.vector != 0 {
        runtime.free_array_aligned(view_of(cast[ptr[u8]](thread.vector), cast[usize](thread.vector_size)), arch.vector_state_alignment())
        thread.vector = 0
    }
}

/**
 * Tell whether an object's destruction has started.
 *
 * @param object The object's address, a slot of a type-stable pool.
 * @return True once its destruction has started, with a plain atomic load: it can become true the moment after false.
 */
is_dying :: fn(object: u64) -> bool {
    header :: cast[ptr[ObjectHeader]](object)
    return intrinsics.atomic_load_u32(&header.dying) != 0
}

/**
 * Keep the registers an entry from user mode saved, in the CPU's current thread.
 *
 * @param registers The registers, on this CPU's kernel stack; copied, so they needn't outlive the call. With no
 *     current thread, as when idle, nothing is kept.
 */
save_user_registers :: fn(registers: ptr[arch.UserRegisters]) {
    cpu :: per_cpu()
    if cpu.current != 0 {
        cast[ptr[mut Thread]](cpu.current).registers = registers^
    }
}
