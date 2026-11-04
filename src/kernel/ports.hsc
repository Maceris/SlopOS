package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"
import maps from "std"
import slop_os from "std/os"
import slab from "slab"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Ports (roadmap M5, knowledge/design/ipc.md §3, decisions/0035): the one wait mechanism. A port has
 * bindings, each with a key the binder chose and a packet slot of its own, made when it's bound, so
 * nothing allocates when an event comes: a binding already queued just takes the new event in (wake
 * bits ORed together). Ready bindings are taken first in, first out; waiting threads are woken one per
 * packet, the most recent first.
 *
 * So far: wake bindings (port_wake), timers, and channel ends' signals (channels.hsc, port_bind). IRQs
 * and process events come with the objects that raise them.
 *
 * A thread that finds nothing blocks: it saves its vector state, leaves its CPU, and waits on the port.
 * When woken, by a packet, its deadline or the port's destruction, it's made ready, and finishes its
 * wait when it next runs (complete_wait, from the scheduler): it takes the packets then, or blocks
 * again if another waiter took them first.
 */
//TODO(claude): slack, to coalesce timers (knowledge/design/scheduling.md §2, Timers); bindings charged to a budget (M5, budgets)

/** What raises a binding's packet, which says what its data holds and which PacketKind its packet reports. */
BindingKind :: enum #backed_by(u8) {
    /** A port_wake binding: data is the bits raised since its packet was last taken; packets are User. */
    Wake,
    /** A timer (port_set_timer): data is its deadline, in monotonic nanoseconds, kept when its packet is taken. */
    Timer,
    /** An object's signals (a channel end, a process, a thread, a device, a budget): data is the signals seen. */
    Signal,
    /** An IRQ's (irqs.hsc): data counts the interrupts. */
    Irq,
    /** An intercept's (intercepts.hsc): data counts the stops. */
    Stop,
}

/**
 * A key's packet slot, from a type-stable pool, so a timer that fires late finds a binding, if not its own.
 *
 * It's made when the key is bound (new_binding), so raising an event never allocates: a binding already queued just
 * takes the new event into data. Its fields are under its port's lock, unless a field says otherwise.
 */
Binding :: struct #align(16) {
    /** The slab allocator's, while the slot is free. */
    free_link : u64,
    /**
     * The slot's generation, kept across reuse and changed when it's unbound (free_binding), so a timer or an object
     * that kept the binding's address sees it isn't its own any more.
     */
    generation : u32,
    /** What raises its packet, and what data holds. */
    kind : BindingKind,
    /** Whether its packet is on the port's ready list, waiting to be taken. */
    queued : bool,
    /** The key the binder chose, unique on its port, reported in its packets. */
    key : u64,
    /**
     * The address of the Port it's on; read without the lock by lock_bound_port, and 0 for a moment while new_binding
     * makes the slot anew.
     */
    port : u64,
    /** Wake bits or signals raised since its packet was taken; a timer's deadline, in nanoseconds. */
    data : u64,
    /** Its packet's second word: for a process's end, how it ended (slop_os.EXIT_KILLED or its code). */
    detail : u64,
    /** A signal binding's object: its address, 0 for other kinds. */
    object : u64,
    /** A signal binding's object's generation when it was bound, telling that object from a later one in its slot. */
    object_generation : u32,
    /** A signal binding's: the signals (slop_os.SIGNAL_ bits) it queues a packet for. */
    signals : u32,
    /** A signal binding's: whether a signal it sees queues its packet now. */
    armed : bool,
    /** A signal binding's: whether it's disarmed once its packet is queued (BindMode.Once), or stays armed. */
    once : bool,
    /** The next binding on the port's ready list, a newer one, or 0 for the last. */
    ready_next : u64,
    /** The previous binding on the port's ready list, an older one, or 0 for the first. */
    ready_previous : u64,
    /** A timer binding's entry in a CPU's timer heap, armed in counter ticks; unarmed for other kinds. */
    timer : TimerEntry,
}

/**
 * A port: the one wait mechanism (knowledge/design/ipc.md §3). Everything but its header is under its lock, which ranks
 * as LockRank.Port: after a channel core's, before a run queue's.
 */
Port :: struct #align(16) {
    /** The object header every kernel object starts with. */
    header : ObjectHeader,
    /** Guards the bindings, the ready list, the waiters and short_of_budget. */
    lock : concurrency.SpinLock,
    /** Every binding's address, by key. */
    bindings : maps.HashMap[u64, u64, maps.hash_integer[u64]],
    /** The oldest binding with a packet waiting to be taken, or 0 for none. */
    ready_first : u64,
    /** The newest binding with a packet waiting to be taken, or 0 for none. */
    ready_last : u64,
    /** Threads waiting, the most recent first. */
    waiters : u64,
    /** Whether the last binding couldn't be made because its budget was short, under lock. */
    short_of_budget : bool,
}

/**
 * Tell why new_binding gave no binding, as the error the call that asked for one returns.
 *
 * @param port The port new_binding failed on, whose lock the caller still holds since that call.
 * @return BudgetExceeded if the port's memory budget couldn't pay for the binding, OutOfMemory if the binding pool
 *     couldn't give a slot or the port's map couldn't grow.
 */
binding_failure :: fn(port: ptr[Port]) -> slop_os.PortError {
    return if port.short_of_budget { slop_os.PortError.BudgetExceeded } else { slop_os.PortError.OutOfMemory }
}

/** What starting a wait comes to. */
WaitOutcome :: union {
    /** The wait is over: how many packets were written to the caller's buffer, 0 when the deadline passed first. */
    Done(u32),
    /** The wait failed: ObjectGone if the port was destroyed, BadBuffer if the buffer isn't writable. */
    Failed(slop_os.PortError),
    /** The thread left its CPU and waits; its result is written when the wait is over (complete_wait). */
    Blocked,
}

/**
 * Make a port, empty: its bindings are made as keys are bound.
 *
 * @param kernel The kernel, whose port pool the port comes from.
 * @param owner The Process the port belongs to, by address, or 0 for the kernel; destroying the owner destroys it.
 * @param budget The MemoryBudget that pays for the port, by address, or 0 for the kernel's own; each binding is charged
 *     to it too, when it's made.
 * @return The new port, live, owned by owner; the caller makes its handle.
 * @error OutOfMemory The port pool had no slot.
 * @error BudgetExceeded The budget couldn't pay for the port.
 * @error OwnerGone The owner is being destroyed; the port was destroyed again.
 */
create_port :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64) -> Result[ptr[mut Port], ObjectError] {
    object :: new_object(kernel, .Port, budget, 0)?
    port :: cast[ptr[mut Port]](object)
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(error)
        }
    }
    return .Ok(port)
}

/**
 * Bind key to a wake binding on a port, for port_wake to raise bits on.
 *
 * Takes the port's lock. The binding is charged to the port's memory budget.
 *
 * @param kernel The kernel, whose binding pool the binding comes from.
 * @param port The port, live or being destroyed.
 * @param key The key, any value not yet bound on the port.
 * @return Null once it's bound, with no packet queued; otherwise the error, and nothing is bound: ObjectGone if the
 *     port is being destroyed, KeyInUse if key is bound already, of any kind, or BudgetExceeded or OutOfMemory as
 *     binding_failure says.
 */
port_bind_wake :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64) -> slop_os.PortError? {
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) {
        return .ObjectGone
    }
    if maps.map_has(&port.bindings, key) {
        return .KeyInUse
    }
    if new_binding(kernel, port, key, .Wake) == null {
        return binding_failure(port)
    }
    return null
}

/**
 * Raise bits on key's wake binding: its packet is queued, or takes the bits in if it already is.
 *
 * Takes the port's lock. Queuing the packet wakes the port's most recent waiter, if there is one.
 *
 * @param kernel The kernel, whose timer heaps and run queues waking a port's waiter goes through.
 * @param port The port, live or being destroyed.
 * @param key The key of a wake binding on the port.
 * @param bits The bits to raise, ORed into the bits raised since the packet was last taken; 0 still queues the packet.
 * @return Null once the bits are raised; ObjectGone if the port is being destroyed, or NoSuchKey if key isn't bound or
 *     isn't a wake binding.
 */
port_wake :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64, bits: u64) -> slop_os.PortError? {
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) {
        return .ObjectGone
    }
    binding :: binding_of(port, key, .Wake) or_return .NoSuchKey
    binding.data |= bits
    queue_binding(kernel, port, binding)
    return null
}

/**
 * Set key's timer, binding it if it isn't yet, for deadline: its packet is queued then. Setting it again moves the
 * deadline.
 *
 * Takes the port's lock. The timer is armed on the calling CPU's timer heap, and fires from its timer interrupt
 * (fire_port_timer). A packet already queued for an earlier deadline stays queued.
 *
 * @param kernel The kernel, whose binding pool a new binding comes from.
 * @param port The port, live or being destroyed.
 * @param key The key of a timer binding on the port, or a key not yet bound, which is bound to a new timer binding.
 * @param deadline When, in monotonic nanoseconds, as the timer packet's data[0] reports it; one passed already, or
 *     before the monotonic clock starts, queues the packet at once; slop_os.NO_DEADLINE arms it for a time that never
 *     comes.
 * @return Null once it's set; otherwise ObjectGone if the port is being destroyed, KeyInUse if key is bound to another
 *     kind of binding, BudgetExceeded or OutOfMemory if a new binding couldn't be made (binding_failure), or
 *     OutOfMemory if the CPU's timer heap couldn't grow, when the binding stays, with its deadline but unarmed.
 */
port_set_timer :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64, deadline: u64) -> slop_os.PortError? {
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) {
        return .ObjectGone
    }
    binding := binding_of(port, key, .Timer) or_else cast[ptr[mut Binding]](0)
    if cast[u64](binding) == 0 {
        if maps.map_has(&port.bindings, key) {
            return .KeyInUse
        }
        binding = new_binding(kernel, port, key, .Timer) or_return binding_failure(port)
    }
    _ = cancel_timer(kernel, &binding.timer)
    binding.data = deadline
    ticks :: ticks_at(kernel, deadline)
    if ticks <= arch.counter() {
        queue_binding(kernel, port, binding)
        return null
    }
    binding.timer.kind = .PortTimer
    binding.timer.owner = cast[u64](binding)
    binding.timer.owner_generation = cast[u64](binding.generation)
    binding.timer.port = cast[u64](port)
    if !arm_timer(&binding.timer, ticks) {
        return .OutOfMemory
    }
    return null
}

/**
 * Take key's binding off the port, with its packet and its timer, and free it.
 *
 * Takes the port's lock. The binding's charge goes back to the port's budget, and its generation changes, so an object
 * that kept it (a channel end, an IRQ) sees it's gone.
 *
 * @param kernel The kernel, whose binding pool the binding goes back to.
 * @param port The port, live or being destroyed.
 * @param key The key of a binding of any kind on the port.
 * @return Null once it's unbound; ObjectGone if the port is being destroyed, or NoSuchKey if key isn't bound.
 */
port_unbind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64) -> slop_os.PortError? {
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) {
        return .ObjectGone
    }
    address :: maps.map_get(&port.bindings, key) or_return .NoSuchKey
    _ = maps.map_remove(&port.bindings, key)
    free_binding(kernel, port, cast[ptr[mut Binding]](address))
    return null
}

/**
 * Start the calling thread's port_wait: take packets at once if there are any, give nothing if the deadline has passed,
 * and otherwise block.
 *
 * Runs on the thread's own CPU, in its system call. Blocking takes the thread off the CPU (the CPU's current thread
 * becomes 0), so the caller mustn't write its result: complete_wait writes it once the wait is over.
 *
 * @param kernel The kernel: packets are copied through its direct map, and a blocked thread's deadline is armed on the
 *     calling CPU's timer heap.
 * @param thread The calling thread, the CPU's current one; its wait fields are set for the wait.
 * @param port The port to wait on, from a handle with RIGHT_PORT_WAIT.
 * @param buffer Where the packets go: a user address in the thread's address space, checked here to be writable for
 *     the packets that fit, and written again when they're taken.
 * @param capacity How many packets fit at buffer; at most slop_os.MAX_PACKETS_PER_WAIT are taken, whatever it says,
 *     and 0 gives Done(0) at once without looking.
 * @param deadline When to give up, in counter ticks (ticks_at), or slop_os.NO_DEADLINE to wait for as long as it takes.
 * @return Done with how many packets were written, or 0 when the deadline passed; Failed with BadBuffer if buffer
 *     isn't writable user memory, or ObjectGone if the port is being destroyed; or Blocked if the thread waits.
 */
port_wait_begin :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], port: ptr[mut Port], buffer: u64, capacity: u32,
    deadline: u64) -> WaitOutcome {
    count :: if capacity < slop_os.MAX_PACKETS_PER_WAIT { capacity } else { slop_os.MAX_PACKETS_PER_WAIT }
    if count == 0 {
        return .Done(0)
    }
    if !is_user_writable(thread.space, buffer, cast[u64](count) * cast[u64](size_of(slop_os.Packet))) {
        return .Failed(.BadBuffer)
    }
    thread.wait_port = cast[u64](port)
    thread.wait_port_generation = port.header.generation
    thread.wait_buffer = buffer
    thread.wait_capacity = count
    thread.wait_deadline = deadline
    match finish_or_block(kernel, thread) {
        case Some(outcome) => return outcome
        case None => {
            // It left the CPU: nothing more for it here
            cpu :: per_cpu()
            cpu.current = 0
            intrinsics.atomic_store_u32_release(&cpu.current_level, IDLE_LEVEL)
            return .Blocked
        }
    }
}

/**
 * Finish a woken thread's wait as it's about to run, from the scheduler: take its packets, or block it again if another
 * waiter took them first.
 *
 * Takes the port's lock. On the CPU about to run the thread, which is its current thread then.
 *
 * @param kernel The kernel: packets are copied through its direct map, and a thread that blocks again has its deadline
 *     armed on this CPU's timer heap.
 * @param thread The thread, whose wait_port isn't 0: it was blocked in port_wait_begin and has been woken.
 * @return True if its wait is over, its result (the packet count, or the error's tag) written to its system call
 *     result registers, and it can run; false if it found nothing before its deadline and blocked again, when it has
 *     left the CPU.
 */
complete_wait :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) -> bool {
    match finish_or_block(kernel, thread) {
        case Some(outcome) => {
            match outcome {
                case Done(taken) => set_wait_result(thread, 0, cast[u64](taken))
                case Failed(error) => set_wait_result(thread, cast[u64](cast[u32](error)), 0)
                case Blocked => {}
            }
            return true
        }
        case None => return false
    }
}

/**
 * Write a finished wait's result into the thread's saved registers, as its system call's result.
 *
 * @param thread The thread, not running, whose registers are written.
 * @param tag The result's tag: 0 for success, or the error's value (slop_os.PortError, or the ChannelError of
 *     ChannelNotifyAndWait, which shares its tags).
 * @param value The first result value: the packet count on success, 0 otherwise.
 */
set_wait_result :: fn(thread: ptr[mut Thread], tag: u64, value: u64) {
    result :: arch_interface.SyscallResult.{tag = tag, values = u64.[value, 0]}
    arch.set_syscall_result(&thread.registers, &result)
}

/**
 * Take the thread's packets and finish its wait, or block it on its port.
 *
 * Takes the port's lock, and copies the packets to the thread's buffer after letting go of it. Blocking saves the
 * thread's vector state first if it's the CPU's current thread, since another CPU may run it as soon as it's woken,
 * charges its time so far to its budget, and arms its wait timer on the calling CPU for its deadline; if the timer heap
 * can't grow, it waits without its deadline rather than fail.
 *
 * @param kernel The kernel, for the direct map the packets are copied through.
 * @param thread The waiting thread, its wait fields (wait_port, wait_buffer, wait_capacity, wait_deadline) set by
 *     port_wait_begin; wait_port is set to 0 once the wait is over.
 * @return The wait's outcome when it's over: Done with the packets taken, Done(0) when the deadline has passed, Failed
 *     with ObjectGone if the port was destroyed (or its slot reused), or Failed with BadBuffer if the packets taken
 *     couldn't be written, when they're lost. Null when the thread blocked, waiting on the port.
 */
finish_or_block :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) -> WaitOutcome? {
    port :: cast[ptr[mut Port]](thread.wait_port)
    packets : slop_os.Packet[slop_os.MAX_PACKETS_PER_WAIT]
    lock_at(&port.lock, .Port)
    if port.header.generation != thread.wait_port_generation || is_dying(cast[u64](port)) {
        unlock_at(&port.lock, .Port)
        thread.wait_port = 0
        return WaitOutcome.Failed(.ObjectGone)
    }
    taken :: take_packets(port, &packets, thread.wait_capacity)
    if taken > 0 {
        unlock_at(&port.lock, .Port)
        thread.wait_port = 0
        if !copy_to_user(kernel, thread.space, thread.wait_buffer, cast[u64](&packets[0]), cast[u64](taken) * cast[u64](size_of(slop_os.Packet))) {
            return WaitOutcome.Failed(.BadBuffer)
        }
        return WaitOutcome.Done(taken)
    }
    now :: arch.counter()
    if thread.wait_deadline != slop_os.NO_DEADLINE && thread.wait_deadline <= now {
        unlock_at(&port.lock, .Port)
        thread.wait_port = 0
        return WaitOutcome.Done(0)
    }
    // Blocks: saved first, then where wakers find it
    cpu :: per_cpu()
    if cpu.current == cast[u64](thread) {
        account(cpu, thread, now)
        arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
    }
    thread.state = .Blocked
    thread.wait_sequence += 1
    if thread.wait_deadline != slop_os.NO_DEADLINE {
        thread.wait_timer.kind = .WaitTimeout
        thread.wait_timer.owner = cast[u64](thread)
        thread.wait_timer.owner_generation = (cast[u64](thread.header.generation) << 32) | (thread.wait_sequence & 0xffffffff)
        thread.wait_timer.port = cast[u64](port)
        // Without memory for the timer, it waits without its deadline rather than fail
        _ = arm_timer(&thread.wait_timer, thread.wait_deadline)
    }
    push_waiter(port, thread)
    unlock_at(&port.lock, .Port)
    return null
}

/**
 * Take up to capacity packets from the ready bindings, oldest first, each binding's packet taken: wake bits, signals
 * and counts start again from none; a timer's deadline stays.
 *
 * Takes the port's lock as held.
 *
 * @param port The port, whose lock the caller holds; the bindings taken come off its ready list.
 * @param packets Where the packets go, from the first.
 * @param capacity The most packets to take; at most slop_os.MAX_PACKETS_PER_WAIT are, and 0 takes none.
 * @return How many packets were taken and written, from 0 when no binding is ready.
 */
take_packets :: fn(port: ptr[mut Port], packets: ptr[mut slop_os.Packet[slop_os.MAX_PACKETS_PER_WAIT]], capacity: u32) -> u32 {
    taken : u32 = 0
    loop {
        binding :: cast[ptr[mut Binding]](port.ready_first)
        unqueue(port, binding)
        index :: cast[usize](taken) % cast[usize](slop_os.MAX_PACKETS_PER_WAIT)
        packets^[index] = slop_os.Packet.{
            key = binding.key,
            kind = match binding.kind {
                case .Timer => slop_os.PacketKind.Timer
                case .Signal => slop_os.PacketKind.Signal
                case .Irq => slop_os.PacketKind.Irq
                case .Stop => slop_os.PacketKind.Stop
                case _ => slop_os.PacketKind.User
            },
            reserved = 0,
            data = u64.[binding.data, binding.detail],
        }
        if binding.kind != .Timer {
            binding.data = 0
        }
        taken += 1
    }
    while port.ready_first != 0 && taken < capacity && taken < slop_os.MAX_PACKETS_PER_WAIT
    return taken
}

/**
 * Queue a binding's packet, last on the ready list, if it isn't queued yet, which wakes the port's most recent waiter.
 *
 * Takes the port's lock as held. A binding already queued is left where it is, and no waiter is woken.
 *
 * @param kernel The kernel, whose timer heaps and run queues waking a port's waiter goes through.
 * @param port The binding's port.
 * @param binding The binding, whose data the caller has already updated.
 */
queue_binding :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], binding: ptr[mut Binding]) {
    if binding.queued {
        return void
    }
    binding.ready_next = 0
    binding.ready_previous = port.ready_last
    if port.ready_last != 0 {
        cast[ptr[mut Binding]](port.ready_last).ready_next = cast[u64](binding)
    }
    else {
        port.ready_first = cast[u64](binding)
    }
    port.ready_last = cast[u64](binding)
    binding.queued = true
    wake_waiter(kernel, port)
}

/**
 * Take a binding's packet off the port's ready list, if it's on it.
 *
 * Takes the port's lock as held. The binding's data is left as it is.
 *
 * @param port The binding's port.
 * @param binding The binding, queued or not.
 */
unqueue :: fn(port: ptr[mut Port], binding: ptr[mut Binding]) {
    if !binding.queued {
        return void
    }
    if binding.ready_previous != 0 {
        cast[ptr[mut Binding]](binding.ready_previous).ready_next = binding.ready_next
    }
    else {
        port.ready_first = binding.ready_next
    }
    if binding.ready_next != 0 {
        cast[ptr[mut Binding]](binding.ready_next).ready_previous = binding.ready_previous
    }
    else {
        port.ready_last = binding.ready_previous
    }
    binding.queued = false
}

/**
 * Wake the port's most recent waiter, if it has one: made ready, to take what's queued when it runs, on its own CPU, or
 * on this one during a handoff (ChannelNotifyAndWait), where the caller is about to wait.
 *
 * Takes the port's lock as held, and takes the timer heap's lock to disarm the waiter's deadline, and a run queue's to
 * make it ready.
 *
 * @param kernel The kernel: the waiter's deadline is disarmed on whichever CPU's timer heap it's on, and it's made
 *     ready on a run queue.
 * @param port The port, whose lock the caller holds; one with no waiters is left as it is.
 */
wake_waiter :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port]) {
    first :: port.waiters
    if first == 0 {
        return void
    }
    thread :: cast[ptr[mut Thread]](first)
    unlink_waiter(port, thread)
    _ = cancel_timer(kernel, &thread.wait_timer)
    cpu :: per_cpu()
    make_ready(kernel, thread, if cpu.handoff { cpu.index } else { thread.cpu })
}

/**
 * Put a thread first on the port's waiters, the next to be woken.
 *
 * Takes the port's lock as held.
 *
 * @param port The port, whose lock the caller holds.
 * @param thread The thread, blocked, and not on any port's waiters.
 */
push_waiter :: fn(port: ptr[mut Port], thread: ptr[mut Thread]) {
    thread.wait_previous = 0
    thread.wait_next = port.waiters
    if port.waiters != 0 {
        cast[ptr[mut Thread]](port.waiters).wait_previous = cast[u64](thread)
    }
    port.waiters = cast[u64](thread)
    thread.waiting = true
}

/**
 * Take a thread off the port's waiters, if it's on them.
 *
 * Takes the port's lock as held. The thread's state isn't changed; the caller makes it ready if it should run.
 *
 * @param port The port the thread waits on.
 * @param thread The thread, waiting or not.
 */
unlink_waiter :: fn(port: ptr[mut Port], thread: ptr[mut Thread]) {
    if !thread.waiting {
        return void
    }
    if thread.wait_previous != 0 {
        cast[ptr[mut Thread]](thread.wait_previous).wait_next = thread.wait_next
    }
    else {
        port.waiters = thread.wait_next
    }
    if thread.wait_next != 0 {
        cast[ptr[mut Thread]](thread.wait_next).wait_previous = thread.wait_previous
    }
    thread.waiting = false
}

/**
 * Queue a port timer's packet as it comes due, unless its binding was unbound or set again since.
 *
 * Runs from the timer interrupt of the CPU it was armed on (fire_timers), with the entry already off the heap. Takes
 * the port's lock.
 *
 * @param kernel The kernel, whose timer heaps and run queues waking a port's waiter goes through.
 * @param fired A copy of the timer's entry, taken while it was armed: its owner is the binding, its owner_generation
 *     the binding's generation then, and its port the binding's port. The binding's slot may have been freed or reused
 *     since; it's type-stable, so it's still a Binding.
 */
fire_port_timer :: fn(kernel: ptr[mut Kernel], fired: ptr[TimerEntry]) {
    port :: cast[ptr[mut Port]](fired.port)
    binding :: cast[ptr[mut Binding]](fired.owner)
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    if is_dying(cast[u64](port)) || cast[u64](binding.generation) != fired.owner_generation || binding.port != cast[u64](port)
        || binding.timer.index != NOT_QUEUED {
        return void
    }
    queue_binding(kernel, port, binding)
}

/**
 * Wake a waiting thread whose deadline came, unless it was woken since: it's made ready on its own CPU, to find
 * nothing, or what came meanwhile, when it runs.
 *
 * Runs from the timer interrupt of the CPU it was armed on (fire_timers). Takes the port's lock.
 *
 * @param kernel The kernel, on whose run queues the thread is made ready.
 * @param fired A copy of the wait timer's entry: its owner is the thread, its owner_generation the thread's generation
 *     in the high 32 bits and its wait's sequence number in the low, and its port the port it waits on. A thread whose
 *     generation or wait has changed since is left alone.
 */
fire_wait_timeout :: fn(kernel: ptr[mut Kernel], fired: ptr[TimerEntry]) {
    port :: cast[ptr[mut Port]](fired.port)
    thread :: cast[ptr[mut Thread]](fired.owner)
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
    expected :: (cast[u64](thread.header.generation) << 32) | (thread.wait_sequence & 0xffffffff)
    if !thread.waiting || thread.wait_port != cast[u64](port) || expected != fired.owner_generation {
        return void
    }
    unlink_waiter(port, thread)
    make_ready(kernel, thread, thread.cpu)
}

/**
 * Stop a thread being destroyed from waiting: off its port's waiters, its deadline disarmed.
 *
 * Takes the port's lock, then the timer heap's. Does nothing if the thread isn't in a wait.
 *
 * @param kernel The kernel, on one of whose per-CPU timer heaps the thread's deadline may be armed.
 * @param thread The thread being destroyed.
 */
cancel_wait :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    port_address :: thread.wait_port
    if port_address == 0 {
        return void
    }
    port :: cast[ptr[mut Port]](port_address)
    lock_at(&port.lock, .Port)
    unlink_waiter(port, thread)
    unlock_at(&port.lock, .Port)
    _ = cancel_timer(kernel, &thread.wait_timer)
}

/**
 * Destroy a port: wake its waiters, who find it gone, and free its bindings and their map.
 *
 * Called once, from destroy_object, with the port already dying. Takes the port's lock. Each binding's charge goes
 * back to the port's budget and its generation changes, so objects that kept it see it's gone.
 *
 * @param kernel The kernel: waiters are made ready on its run queues, and bindings go back to its binding pool.
 * @param port The port being destroyed.
 */
destroy_port :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port]) {
    lock_at(&port.lock, .Port)
    loop {
        if port.waiters == 0 {
            break
        }
        wake_waiter(kernel, port)
    }
    bindings :: port.bindings.values
    used :: port.bindings.used
    for i in 0..<used.count {
        if used[i] && i < bindings.count {
            free_binding(kernel, port, cast[ptr[mut Binding]](bindings[i]))
        }
    }
    maps.map_free(&port.bindings)
    port.ready_first = 0
    port.ready_last = 0
    unlock_at(&port.lock, .Port)
}

/**
 * Release a port once no CPU can use it: nothing to do, since destroy_port freed what it held.
 *
 * @param kernel The kernel; unused.
 * @param port The port, destroyed, about to go back to its pool.
 */
release_port :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port]) {
}

/**
 * Find key's binding, if it's of kind.
 *
 * Takes the port's lock as held.
 *
 * @param port The port, whose lock the caller holds.
 * @param key The key, any value; one not bound gives null.
 * @param kind The kind it has to be.
 * @return The binding, valid while the lock is held; null if key isn't bound, or is bound to another kind.
 */
binding_of :: fn(port: ptr[mut Port], key: u64, kind: BindingKind) -> ptr[mut Binding]? {
    address :: maps.map_get(&port.bindings, key) or_return null
    binding :: cast[ptr[mut Binding]](address)
    return if binding.kind == kind { binding } else { null }
}

/**
 * Lock the port of a binding kept elsewhere (an end's, a watcher's, an IRQ's, an intercept's), if it's still the
 * binding with generation and its port isn't dying.
 *
 * Bindings are type-stable, so one its port freed is still a Binding, its generation changed; but while new_binding
 * makes the slot anew, for any port, its port reads 0 for a moment, and it isn't this binding then either.
 *
 * @param binding The binding's address, as it was kept; its slot may have been freed or reused since.
 * @param generation The binding's generation when it was kept.
 * @return The binding's port with its lock taken, for the caller to let go of; null, with no lock held, if the binding
 *     isn't that one any more or its port is being destroyed.
 */
lock_bound_port :: fn(binding: ptr[Binding], generation: u32) -> ptr[mut Port]? {
    address :: intrinsics.atomic_load_u64(&binding.port)
    if address == 0 {
        return null
    }
    port :: cast[ptr[mut Port]](address)
    lock_at(&port.lock, .Port)
    if binding.generation == generation && binding.port == address && !is_dying(address) {
        return port
    }
    unlock_at(&port.lock, .Port)
    return null
}

/**
 * Make a binding for key, in the port's map, with no packet yet and its data 0.
 *
 * Takes the port's lock as held. The binding is charged to the port's memory budget. It sets short_of_budget, for
 * binding_failure to tell why it failed.
 *
 * @param kernel The kernel, whose binding pool the slot comes from.
 * @param port The port, not dying.
 * @param key The key, which the caller has checked isn't bound.
 * @param kind What the binding is for; the caller fills in the fields its kind uses.
 * @return The binding, which keeps its slot's generation; null if the budget couldn't pay for it, the pool had no slot,
 *     or the map couldn't grow, when nothing is left charged or allocated.
 */
new_binding :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64, kind: BindingKind) -> ptr[mut Binding]? {
    port.short_of_budget = false
    if !charge_more(cast[u64](port), kernel.pools.bindings.object_size) {
        port.short_of_budget = true
        return null
    }
    address :: slab.allocate(&kernel.pools.bindings, &kernel.frames) or_else 0
    if address == 0 {
        uncharge(cast[u64](port), port.header.generation, kernel.pools.bindings.object_size)
        return null
    }
    binding :: cast[ptr[mut Binding]](address)
    generation :: binding.generation
    binding^ = Binding.{}
    binding.generation = generation
    binding.kind = kind
    binding.key = key
    binding.port = cast[u64](port)
    binding.timer = make_timer()
    if maps.map_try_put(&port.bindings, key, address) != null {
        slab.free(&kernel.pools.bindings, &kernel.frames, address)
        uncharge(cast[u64](port), port.header.generation, kernel.pools.bindings.object_size)
        return null
    }
    return binding
}

/**
 * Free a binding taken out of the port's map: off the ready list, its timer disarmed, its generation changed, its
 * charge back to the port's budget.
 *
 * Takes the port's lock as held, and takes the timer heap's.
 *
 * @param kernel The kernel, whose binding pool the slot goes back to.
 * @param port The binding's port.
 * @param binding The binding, already removed from the port's map.
 */
free_binding :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], binding: ptr[mut Binding]) {
    unqueue(port, binding)
    _ = cancel_timer(kernel, &binding.timer)
    binding.generation += 1
    slab.free(&kernel.pools.bindings, &kernel.frames, cast[u64](binding))
    uncharge(cast[u64](port), port.header.generation, kernel.pools.bindings.object_size)
}

/**
 * Convert a monotonic time to the counter value it comes at.
 *
 * @param kernel The kernel, whose clock start and counter frequency convert it.
 * @param nanoseconds A monotonic time, in nanoseconds as the monotonic clock reads (clock.hsc), or slop_os.NO_DEADLINE.
 * @return The counter value, in ticks; the clock's start for a time before it starts; slop_os.NO_DEADLINE for
 *     slop_os.NO_DEADLINE.
 */
ticks_at :: fn(kernel: ptr[Kernel], nanoseconds: u64) -> u64 {
    if nanoseconds == slop_os.NO_DEADLINE {
        return slop_os.NO_DEADLINE
    }
    // A monotonic time, from where it starts (clock.hsc); one before that is now
    if nanoseconds < MONOTONIC_START {
        return kernel.clock_start
    }
    return kernel.clock_start + ticks_of(kernel, nanoseconds - MONOTONIC_START)
}

/**
 * Tell whether a range of user memory is all mapped for user mode and writable now.
 *
 * Takes the space's lock. It reads the page tables only, so memory mapped but not yet touched (memory.hsc), which a
 * fault would fill in, counts as not writable.
 *
 * @param space The address space whose page tables are read; its lock is taken, so the caller holds none at that level
 *     or above.
 * @param address The range's start, a user virtual address, any alignment.
 * @param size The range's size in bytes; 0 is writable if address is a user address.
 * @return True if every page the range touches is mapped user and read/write; false if any isn't, or the range isn't
 *     within the user address range.
 */
is_user_writable :: fn(space: ptr[mut AddressSpace], address: u64, size: u64) -> bool {
    low, high :: arch.user_address_range()
    if address < cast[u64](low) || address >= cast[u64](high) || size > cast[u64](high) - address {
        return false
    }
    lock_at(&space.lock, .Space)
    defer unlock_at(&space.lock, .Space)
    page := address & ~cast[u64](4095)
    loop {
        found :: arch.translate(&space.table, cast[arch_interface.VirtualAddress](page)) or_return false
        if !found.mapping.user || found.mapping.protection != .ReadWrite {
            return false
        }
        page += 4096
    }
    while page < address + size
    return true
}
