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

BindingKind :: enum #backed_by(u8) {
    Wake,
    Timer,
    Signal,
}

// A key's packet slot, from a type-stable pool, so a timer that fires late finds a binding, if not its own.
Binding :: struct #align(16) {
    // The slab allocator's, while the slot is free.
    free_link : u64,
    // Changed when it's unbound, so a timer firing for it then sees it isn't its own.
    generation : u32,
    kind : BindingKind,
    queued : bool,
    key : u64,
    port : u64,
    // Wake bits or signals raised since its packet was taken; a timer's deadline, in nanoseconds.
    data : u64,
    // A signal binding's: the object and its generation, the signals it sees, and whether it's armed,
    // and disarmed once its packet is queued (BindMode.Once).
    object : u64,
    object_generation : u32,
    signals : u32,
    armed : bool,
    once : bool,
    // Its neighbors on the port's ready list.
    ready_next : u64,
    ready_previous : u64,
    timer : TimerEntry,
}

Port :: struct #align(16) {
    header : ObjectHeader,
    lock : concurrency.SpinLock,
    // Every binding's address, by key.
    bindings : maps.HashMap[u64, u64, maps.hash_integer[u64]],
    // Bindings with a packet, oldest first.
    ready_first : u64,
    ready_last : u64,
    // Threads waiting, the most recent first.
    waiters : u64,
}

// What starting a wait comes to.
WaitOutcome :: union {
    Done(u32),
    Failed(slop_os.PortError),
    // The thread left its CPU and waits.
    Blocked,
}

create_port :: fn(kernel: ptr[mut Kernel], owner: u64) -> Result[ptr[mut Port], ObjectError] {
    object :: new_object(kernel, .Port)?
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

// A wake binding for key.
// HEMERA(enum shorthand through an optional): `.ObjectGone` would do for these returns
port_bind_wake :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64) -> slop_os.PortError? {
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    if maps.map_has(&port.bindings, key) {
        return slop_os.PortError.KeyInUse
    }
    if new_binding(kernel, port, key, .Wake) == null {
        return slop_os.PortError.OutOfMemory
    }
    return null
}

// Raise bits on key's wake binding: its packet is queued, or takes the bits in if it already is.
port_wake :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64, bits: u64) -> slop_os.PortError? {
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    binding :: binding_of(port, key, .Wake) or_return slop_os.PortError.NoSuchKey
    binding.data |= bits
    queue_binding(kernel, port, binding)
    return null
}

/*
 * Key's timer, binding it if it isn't yet, for deadline (monotonic nanoseconds): its packet is queued
 * then. Setting it again moves the deadline.
 */
port_set_timer :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64, deadline: u64) -> slop_os.PortError? {
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    binding := binding_of(port, key, .Timer) or_else cast[ptr[mut Binding]](0)
    if cast[u64](binding) == 0 {
        if maps.map_has(&port.bindings, key) {
            return slop_os.PortError.KeyInUse
        }
        binding = new_binding(kernel, port, key, .Timer) or_return slop_os.PortError.OutOfMemory
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
        return slop_os.PortError.OutOfMemory
    }
    return null
}

// Take key's binding off the port, with its packet and its timer.
port_unbind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64) -> slop_os.PortError? {
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    address :: maps.map_get(&port.bindings, key) or_return slop_os.PortError.NoSuchKey
    _ = maps.map_remove(&port.bindings, key)
    free_binding(kernel, port, cast[ptr[mut Binding]](address))
    return null
}

/*
 * The calling thread's port_wait: up to capacity packets at buffer in its address space, at once if
 * there are any, nothing if deadline (counter ticks, or slop_os.NO_DEADLINE) has passed, and otherwise
 * it blocks.
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

/*
 * When a woken thread is about to run: its wait finished, its result in its registers, true; or false if
 * it found nothing and blocked again.
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

set_wait_result :: fn(thread: ptr[mut Thread], tag: u64, value: u64) {
    result :: arch_interface.SyscallResult.{tag = tag, values = u64.[value, 0]}
    arch.set_syscall_result(&thread.registers, &result)
}

/*
 * Take the thread's packets and finish its wait, or block it on its port: null when it blocked, having
 * saved its vector state, since another CPU may run it as soon as it's woken.
 */
finish_or_block :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) -> WaitOutcome? {
    port :: cast[ptr[mut Port]](thread.wait_port)
    packets : slop_os.Packet[slop_os.MAX_PACKETS_PER_WAIT]
    concurrency.lock(&port.lock)
    if port.header.generation != thread.wait_port_generation || is_dying(cast[u64](port)) {
        concurrency.unlock(&port.lock)
        thread.wait_port = 0
        return WaitOutcome.Failed(.ObjectGone)
    }
    taken :: take_packets(port, &packets, thread.wait_capacity)
    if taken > 0 {
        concurrency.unlock(&port.lock)
        thread.wait_port = 0
        if !copy_to_user(kernel, thread.space, thread.wait_buffer, cast[u64](&packets[0]), cast[u64](taken) * cast[u64](size_of(slop_os.Packet))) {
            return WaitOutcome.Failed(.BadBuffer)
        }
        return WaitOutcome.Done(taken)
    }
    now :: arch.counter()
    if thread.wait_deadline != slop_os.NO_DEADLINE && thread.wait_deadline <= now {
        concurrency.unlock(&port.lock)
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
    concurrency.unlock(&port.lock)
    return null
}

/*
 * Up to capacity packets from the ready bindings, oldest first, each binding's packet taken: wake bits
 * start again from none. Takes the lock as held.
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
                case _ => slop_os.PacketKind.User
            },
            reserved = 0,
            data = u64.[binding.data, 0],
        }
        if binding.kind != .Timer {
            binding.data = 0
        }
        taken += 1
    }
    while port.ready_first != 0 && taken < capacity && taken < slop_os.MAX_PACKETS_PER_WAIT
    return taken
}

// A binding's packet, queued if it isn't yet, which wakes a waiter. Takes the lock as held.
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

/*
 * The most recent waiter, woken: made ready, to take what's queued when it runs, on its own CPU, or on
 * this one during a handoff (ChannelNotifyAndWait), where the caller is about to wait. Takes the lock
 * as held.
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

push_waiter :: fn(port: ptr[mut Port], thread: ptr[mut Thread]) {
    thread.wait_previous = 0
    thread.wait_next = port.waiters
    if port.waiters != 0 {
        cast[ptr[mut Thread]](port.waiters).wait_previous = cast[u64](thread)
    }
    port.waiters = cast[u64](thread)
    thread.waiting = true
}

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

// A port timer came due: unless its binding was unbound or set again since, its packet is queued.
fire_port_timer :: fn(kernel: ptr[mut Kernel], fired: ptr[TimerEntry]) {
    port :: cast[ptr[mut Port]](fired.port)
    binding :: cast[ptr[mut Binding]](fired.owner)
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if is_dying(cast[u64](port)) || cast[u64](binding.generation) != fired.owner_generation || binding.port != cast[u64](port)
        || binding.timer.index != NOT_QUEUED {
        return void
    }
    queue_binding(kernel, port, binding)
}

// A waiting thread's deadline came: unless it was woken since, it's woken to find nothing.
fire_wait_timeout :: fn(kernel: ptr[mut Kernel], fired: ptr[TimerEntry]) {
    port :: cast[ptr[mut Port]](fired.port)
    thread :: cast[ptr[mut Thread]](fired.owner)
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    expected :: (cast[u64](thread.header.generation) << 32) | (thread.wait_sequence & 0xffffffff)
    if !thread.waiting || thread.wait_port != cast[u64](port) || expected != fired.owner_generation {
        return void
    }
    unlink_waiter(port, thread)
    make_ready(kernel, thread, thread.cpu)
}

// A thread being destroyed stops waiting.
cancel_wait :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    port_address :: thread.wait_port
    if port_address == 0 {
        return void
    }
    port :: cast[ptr[mut Port]](port_address)
    concurrency.lock(&port.lock)
    unlink_waiter(port, thread)
    concurrency.unlock(&port.lock)
    _ = cancel_timer(kernel, &thread.wait_timer)
}

// Destroying a port wakes its waiters, who find it gone, and drops its bindings.
destroy_port :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port]) {
    concurrency.lock(&port.lock)
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
    concurrency.unlock(&port.lock)
}

release_port :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port]) {
}

// key's binding of kind, or null. Takes the lock as held.
binding_of :: fn(port: ptr[mut Port], key: u64, kind: BindingKind) -> ptr[mut Binding]? {
    address :: maps.map_get(&port.bindings, key) or_return null
    binding :: cast[ptr[mut Binding]](address)
    return if binding.kind == kind { binding } else { null }
}

// A binding for key, in the port's map, with no packet yet. Takes the lock as held.
new_binding :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], key: u64, kind: BindingKind) -> ptr[mut Binding]? {
    address :: slab.allocate(&kernel.pools.bindings, &kernel.frames) or_return null
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
        return null
    }
    return binding
}

// Free a binding taken out of the port's map: off the ready list, its timer disarmed. Takes the lock as held.
free_binding :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], binding: ptr[mut Binding]) {
    unqueue(port, binding)
    _ = cancel_timer(kernel, &binding.timer)
    binding.generation += 1
    slab.free(&kernel.pools.bindings, &kernel.frames, cast[u64](binding))
}

// Monotonic nanoseconds as a counter value.
ticks_at :: fn(kernel: ptr[Kernel], nanoseconds: u64) -> u64 {
    if nanoseconds == slop_os.NO_DEADLINE {
        return slop_os.NO_DEADLINE
    }
    return kernel.clock_start + ticks_of(kernel, nanoseconds)
}

// Whether size bytes at address in space are all mapped for user mode and writable.
is_user_writable :: fn(space: ptr[mut AddressSpace], address: u64, size: u64) -> bool {
    low, high :: arch.user_address_range()
    if address < cast[u64](low) || address >= cast[u64](high) || size > cast[u64](high) - address {
        return false
    }
    concurrency.lock(&space.lock)
    defer concurrency.unlock(&space.lock)
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
