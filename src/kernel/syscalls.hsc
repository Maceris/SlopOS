package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import arch_interface from "../arch_interface"
import slop_os from "std/os"
import boot_info from "../boot_info"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * System calls (roadmap M5, knowledge/design/system-abi.md §4, decisions/0057): the calling thread's
 * registers are kept in it, and the dispatch generated from the ABI package's table (slop_os.Syscalls)
 * decodes the call's arguments from them and calls its handler here, sys_<name>, with the calling thread.
 * Its result goes in the thread's result registers before the scheduler resumes it, or runs something
 * else; a handler that blocks gives back null, and its result is written when the wait is over. Every
 * handle is looked up in the calling thread's process's table.
 */

/*
 * A system call from the CPU's current thread, whose registers are saved. Never returns: the scheduler
 * picks up from here.
 */
handle_syscall :: fn(registers: ptr[arch.UserRegisters]) #never_returns {
    save_user_registers(registers)
    cpu :: per_cpu()
    kernel :: cpu.kernel
    runtime.assert(cpu.current != 0, "a system call comes from a thread")
    thread :: cast[ptr[mut Thread]](cpu.current)
    number :: arch.syscall_number(&thread.registers)
    thread.syscall_number = number
    // A debugger's stops (intercepts.hsc), at its entry, and at its exit once its result is written
    if stop_thread(kernel, thread, .SyscallEntry, number, 0, true) {
        leave_cpu(cpu)
        schedule(false)
    }
    /*
     * A call that blocked the thread took it off this CPU, and its result is set when its wait is over
     * (ports.hsc, complete_wait), when it stops at its exit too. Only this CPU changes its current thread.
     */
    result :: dispatch_syscall(thread)
    if cpu.current == cast[u64](thread) {
        arch.set_syscall_result(&thread.registers, &result)
        if stop_thread(kernel, thread, .SyscallExit, number, 0, true) {
            leave_cpu(cpu)
        }
    }
    schedule(false)
}

// The CPU's current thread stopped: nothing runs here until the scheduler picks something.
leave_cpu :: fn(cpu: ptr[mut PerCpu]) {
    cpu.current = 0
    intrinsics.atomic_store_u32_release(&cpu.current_level, IDLE_LEVEL)
}

/*
 * A fault from user mode, by the CPU's current thread, whose registers are saved: a page of memory mapped
 * in its space, filled in if it wasn't yet (memory.hsc), after which it goes on; otherwise a stop for its
 * debugger (intercepts.hsc), or its end. Never returns: the scheduler picks up from here.
 */
handle_user_fault :: fn(registers: ptr[arch.UserRegisters], fault: arch_interface.Fault) #never_returns {
    save_user_registers(registers)
    cpu :: per_cpu()
    kernel :: cpu.kernel
    runtime.assert(cpu.current != 0, "a fault from user mode comes from a thread")
    thread :: cast[ptr[mut Thread]](cpu.current)
    outcome := FaultOutcome.Failed
    access := cast[u64](0)
    address := cast[u64](0)
    match fault {
        case Page(page) => {
            outcome = resolve_fault(kernel, thread, page)
            access = cast[u64](cast[u8](page.access))
            address = cast[u64](page.address)
        }
        case _ => access = 0xff
    }
    // Waiting for its pager: it runs again, touching the page again, once it's supplied
    if outcome == .Blocked {
        leave_cpu(cpu)
    }
    if outcome == .Failed {
        if stop_thread(kernel, thread, .Fault, access, address, true) {
            leave_cpu(cpu)
        }
        else {
            // A process being destroyed loses its memory while its threads may still run, which then fault: as expected
            owner :: thread.header.owner
            if !is_dying(cast[u64](thread)) && (owner == 0 || !is_dying(owner)) {
                runtime.log_info("thread % stopped by a fault: %", thread.id, fault)
            }
            _ = destroy_object(kernel, cast[u64](thread))
        }
    }
    schedule(false)
}

// The call in thread's registers, by the dispatch generated from the ABI package's table.
dispatch_syscall :: fn(thread: ptr[mut Thread]) -> arch_interface.SyscallResult {
    registers :: &thread.registers
    number :: arch.syscall_number(registers)
    #insert slop_os.syscall_dispatch()
    return answered(cast[u64](cast[u32](slop_os.HandleError.NoSuchCall)), 0, 0)
}

// What the generated dispatch decodes arguments with, and answers with (slop_os.syscall_dispatch).
word :: fn(registers: ptr[arch.UserRegisters], index: u64) -> u64 {
    return arch.syscall_argument(registers, cast[u32](index))
}

buffer :: fn(registers: ptr[arch.UserRegisters], index: u64) -> slop_os.UserBuffer {
    return slop_os.UserBuffer.{address = word(registers, index), count = word(registers, index + 1)}
}

answered :: fn(tag: u64, first: u64, second: u64) -> arch_interface.SyscallResult {
    return arch_interface.SyscallResult.{tag = tag, values = u64.[first, second]}
}

// ---- Handles

sys_handle_close :: fn(thread: ptr[mut Thread], handle: slop_os.Handle) -> Result[void, slop_os.HandleError] {
    removed :: remove(&process_of(thread).table, handle)?
    if removed.owning && is_live(removed.object, removed.generation) {
        _ = destroy_object(per_cpu().kernel, removed.object)
    }
    return .Ok
}

// Another handle to the same object, never owning, with rights the handle has.
sys_handle_duplicate :: fn(thread: ptr[mut Thread], handle: slop_os.Handle, rights: slop_os.Rights) -> Result[slop_os.Handle, slop_os.HandleError] {
    process :: process_of(thread)
    found :: lookup(&process.table, handle)?
    held :: cast[u32](found.rights)
    if held & cast[u32](slop_os.RIGHT_DUPLICATE) == 0 || cast[u32](rights) & ~held != 0 {
        return .Error(.MissingRight)
    }
    made :: install(per_cpu().kernel, &process.table, found.object, found.generation, found.kind, rights, false)?
    return .Ok(made)
}

sys_handle_info :: fn(thread: ptr[mut Thread], handle: slop_os.Handle) -> Result[slop_os.HandleInfo, slop_os.HandleError] {
    found :: lookup(&process_of(thread).table, handle)?
    return .Ok(slop_os.HandleInfo.{kind = found.kind, rights = found.rights})
}

/*
 * The object a handle of kind refers to, if the handle has every right in rights, with its error as
 * the call's: they share HandleError's tags.
 */
object_of :: fn[E](process: ptr[mut Process], handle: slop_os.Handle, kind: slop_os.ObjectKind, rights: slop_os.Rights) -> Result[u64, E] {
    match lookup(&process.table, handle) {
        case Ok(found) => {
            if found.kind != kind {
                return .Error(cast[E](cast[u32](slop_os.HandleError.WrongKind)))
            }
            if cast[u32](found.rights) & cast[u32](rights) != cast[u32](rights) {
                return .Error(cast[E](cast[u32](slop_os.HandleError.MissingRight)))
            }
            return .Ok(found.object)
        }
        case Error(error) => return .Error(cast[E](cast[u32](error)))
    }
}

// A handle error, as a call's own: every error type shares HandleError's tags.
converted :: fn[E](error: slop_os.HandleError) -> E {
    return cast[E](cast[u32](error))
}

// What a handle refers to, with its error as the call's.
found_of :: fn[E](process: ptr[mut Process], handle: slop_os.Handle) -> Result[Resolved, E] {
    match lookup(&process.table, handle) {
        case Ok(found) => return .Ok(found)
        case Error(error) => return .Error(converted[E](error))
    }
}

/*
 * An owning handle in process to object, which it owns, and if it's a thread, started. Without room for
 * the handle, the object is destroyed.
 */
owning_handle :: fn[E](kernel: ptr[mut Kernel], process: ptr[mut Process], object: u64, start: bool) -> Result[slop_os.Handle, E] {
    match install_owning(kernel, process, object) {
        case Ok(handle) => {
            if start {
                start_thread(kernel, cast[ptr[mut Thread]](object))
            }
            return .Ok(handle)
        }
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(converted[E](error))
        }
    }
}

/*
 * The budget a handle names, as the address of what will pay, if the handle has RIGHT_BUDGET_CHARGE
 * (decisions/0011, 0054).
 */
paying_budget :: fn[E](process: ptr[mut Process], budget: slop_os.MemoryBudget) -> Result[u64, E] {
    return object_of[E](process, cast[slop_os.Handle](budget), slop_os.ObjectKind.MemoryBudget, slop_os.RIGHT_BUDGET_CHARGE)
}

// What creating an object failing means to the caller.
object_failure :: fn(error: ObjectError) -> slop_os.HandleError {
    if error == .OutOfMemory {
        return .OutOfMemory
    }
    return if error == .BudgetExceeded { slop_os.HandleError.BudgetExceeded } else { slop_os.HandleError.ObjectGone }
}

// ---- Threads, processes, address spaces

sys_thread_exit :: fn(thread: ptr[mut Thread]) {
    _ = destroy_object(per_cpu().kernel, cast[u64](thread))
}

/*
 * A thread in space, owned by the caller's process, started at entry with stack and argument: an owning
 * handle to it.
 */
sys_thread_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, space: slop_os.AddressSpace, entry: u64, stack: u64,
    argument: u64) -> Result[slop_os.Thread, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.HandleError](process, budget)?
    target :: object_of[slop_os.HandleError](process, cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_THREADS)
       ?
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](entry),
        stack_pointer = cast[arch_interface.VirtualAddress](stack),
        argument = argument,
    }
    made := cast[ptr[mut Thread]](0)
    match create_thread(kernel, cast[u64](process), cast[ptr[mut AddressSpace]](target), &start,
        arch_interface.VectorConfig.{extended = false}, 0, paying) {
        case Ok(created) => made = created
        case Error(error) => return .Error(if error == .OutOfMemory { slop_os.HandleError.OutOfMemory }
            else if error == .BudgetExceeded { slop_os.HandleError.BudgetExceeded } else { slop_os.HandleError.ObjectGone })
    }
    handle :: owning_handle[slop_os.HandleError](kernel, process, cast[u64](made), true)?
    return .Ok(cast[slop_os.Thread](handle))
}

// A new process, owned by the caller's, with budget its budget: an owning handle to it.
sys_process_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget) -> Result[slop_os.Process, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.HandleError](process, budget)?
    made := cast[ptr[mut Process]](0)
    match create_process(kernel, cast[u64](process), paying) {
        case Ok(created) => made = created
        case Error(error) => return .Error(object_failure(error))
    }
    handle :: owning_handle[slop_os.HandleError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Process](handle))
}

// A new, empty address space, owned by the caller's process: an owning handle to it.
sys_address_space_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget) -> Result[slop_os.AddressSpace, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.HandleError](process, budget)?
    made := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), paying) {
        case Ok(created) => made = created
        case Error(error) => return .Error(if error == .OwnerGone { slop_os.HandleError.ObjectGone }
            else if error == .BudgetExceeded { slop_os.HandleError.BudgetExceeded } else { slop_os.HandleError.OutOfMemory })
    }
    handle :: owning_handle[slop_os.HandleError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.AddressSpace](handle))
}

sys_clock_monotonic :: fn(thread: ptr[mut Thread]) -> Result[u64, slop_os.HandleError] {
    return .Ok(cast[u64](kernel_monotonic(cast[mut rawptr](per_cpu().kernel))))
}

// ---- Ports

sys_port_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget) -> Result[slop_os.Port, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.HandleError](process, budget)?
    made := cast[ptr[mut Port]](0)
    match create_port(kernel, cast[u64](process), paying) {
        case Ok(created) => made = created
        case Error(error) => return .Error(object_failure(error))
    }
    handle :: owning_handle[slop_os.HandleError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Port](handle))
}

// The port a handle refers to, if the handle has right.
port_of :: fn(thread: ptr[mut Thread], port: slop_os.Port, right: slop_os.Rights) -> Result[ptr[mut Port], slop_os.PortError] {
    object :: object_of[slop_os.PortError](process_of(thread), cast[slop_os.Handle](port), slop_os.ObjectKind.Port, right)?
    return .Ok(cast[ptr[mut Port]](object))
}

// A port call's outcome as its result.
port_done :: fn(error: slop_os.PortError?) -> Result[void, slop_os.PortError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

sys_port_bind_wake :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_bind_wake(per_cpu().kernel, found, key))
}

sys_port_wake :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64, bits: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_wake(per_cpu().kernel, found, key, bits))
}

sys_port_set_timer :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64, deadline: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_set_timer(per_cpu().kernel, found, key, deadline))
}

sys_port_unbind :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_unbind(per_cpu().kernel, found, key))
}

sys_port_wait :: fn(thread: ptr[mut Thread], port: slop_os.Port, packets: slop_os.UserBuffer, deadline: u64) -> Result[u32, slop_os.PortError] {
    kernel :: per_cpu().kernel
    found :: port_of(thread, port, slop_os.RIGHT_PORT_WAIT)?
    return wait_result[slop_os.PortError](port_wait_begin(kernel, thread, found, packets.address, cast[u32](min_u64(packets.count, 0xffffffff)),
        ticks_at(kernel, deadline)))
}

// A wait's outcome as its result; if the thread blocked, its result is written when the wait is over.
wait_result :: fn[E](outcome: WaitOutcome) -> Result[u32, E] {
    match outcome {
        case Done(taken) => return .Ok(taken)
        case Failed(error) => return .Error(cast[E](cast[u32](error)))
        case Blocked => return .Ok(0)
    }
}

// A Signal packet when a channel end, a process or a thread raises signals, or an Irq packet for an IRQ.
sys_port_bind :: fn(thread: ptr[mut Thread], port: slop_os.Port, object: slop_os.Handle, signals: slop_os.Signals, key: u64,
    mode: slop_os.BindMode) -> Result[void, slop_os.PortError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    found_port :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    once :: if mode == .Once { slop_os.BindMode.Once } else { slop_os.BindMode.Persistent }
    found :: found_of[slop_os.PortError](process, object)?
    if found.kind == .Process {
        if cast[u32](found.rights) & cast[u32](slop_os.RIGHT_PROCESS_INSPECT) == 0 {
            return .Error(.MissingRight)
        }
        watched :: cast[ptr[mut Process]](found.object)
        return port_done(watch_bind(kernel, found_port, found.object, &watched.watchers, &watched.watch_lock, .Watchers, signals, key, once))
    }
    if found.kind == .Thread {
        watched :: cast[ptr[mut Thread]](found.object)
        return port_done(watch_bind(kernel, found_port, found.object, &watched.watchers, &watched.control, .ThreadControl, signals, key, once))
    }
    if found.kind == .Irq {
        return port_done(irq_bind(kernel, found_port, cast[ptr[mut Irq]](found.object), key, once))
    }
    if found.kind == .Device {
        watched :: cast[ptr[mut Device]](found.object)
        return port_done(watch_bind(kernel, found_port, found.object, &watched.watchers, &watched.watch_lock, .Watchers, signals, key, once))
    }
    if found.kind != .Channel {
        return .Error(.WrongKind)
    }
    return port_done(port_bind(kernel, found_port, cast[ptr[mut Channel]](found.object), signals, key, once))
}

// ---- Channels

// The channel end a handle refers to, if the handle has every right in rights.
end_of :: fn(thread: ptr[mut Thread], end: slop_os.Channel, rights: slop_os.Rights) -> Result[ptr[mut Channel], slop_os.ChannelError] {
    object :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](end), slop_os.ObjectKind.Channel, rights)?
    return .Ok(cast[ptr[mut Channel]](object))
}

channel_done :: fn(error: slop_os.ChannelError?) -> Result[void, slop_os.ChannelError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

// Owning handles in the caller's process to both ends of a new channel; without room for them, it's destroyed.
sys_channel_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, ring_bytes: u32, tag: u64)
    -> Result[slop_os.ChannelPair, slop_os.ChannelError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.ChannelError](process, budget)?
    pair :: create_channel(kernel, cast[u64](process), paying, ring_bytes, tag)?
    a := slop_os.NO_HANDLE
    match install_owning(kernel, process, cast[u64](pair.a)) {
        case Ok(handle) => a = handle
        case Error(error) => {
            _ = destroy_object(kernel, cast[u64](pair.a))
            _ = destroy_object(kernel, cast[u64](pair.b))
            return .Error(converted[slop_os.ChannelError](error))
        }
    }
    match install_owning(kernel, process, cast[u64](pair.b)) {
        case Ok(b) => return .Ok(slop_os.ChannelPair.{a = cast[slop_os.Channel](a), b = cast[slop_os.Channel](b)})
        case Error(error) => {
            _ = remove(&process.table, a)
            _ = destroy_object(kernel, cast[u64](pair.a))
            _ = destroy_object(kernel, cast[u64](pair.b))
            return .Error(converted[slop_os.ChannelError](error))
        }
    }
}

// Map end's rings in space, which needs RIGHT_SPACE_MAP.
sys_channel_map :: fn(thread: ptr[mut Thread], end: slop_os.Channel, space: slop_os.AddressSpace, address: u64) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, slop_os.RIGHT_CHANNEL_MAP)?
    target :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_MAP)?
    return channel_done(channel_map(per_cpu().kernel, found, cast[ptr[mut AddressSpace]](target), address))
}

sys_channel_unmap :: fn(thread: ptr[mut Thread], end: slop_os.Channel) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_unmap(per_cpu().kernel, found))
}

sys_channel_notify :: fn(thread: ptr[mut Thread], end: slop_os.Channel, signals: slop_os.Signals) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_notify(per_cpu().kernel, found, signals))
}

sys_channel_write :: fn(thread: ptr[mut Thread], end: slop_os.Channel, payload: slop_os.UserBuffer, batch: u32) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_write(per_cpu().kernel, thread, found, payload.address, cast[u32](min_u64(payload.count, 0xffffffff)), batch))
}

// Into buffer: the message's size, also at size, and its flags and batch.
sys_channel_read :: fn(thread: ptr[mut Thread], end: slop_os.Channel, buffer: slop_os.UserBuffer, size: u64) -> Result[slop_os.MessageInfo, slop_os.ChannelError] {
    kernel :: per_cpu().kernel
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    match channel_read(kernel, thread, found, buffer.address, cast[u32](min_u64(buffer.count, 0xffffffff))) {
        case Read(read, flags_and_batch) => {
            if !tell(kernel, thread, size, read) {
                return .Error(.BadBuffer)
            }
            return .Ok(slop_os.MessageInfo.{size = read, flags_and_batch = flags_and_batch})
        }
        case Failed(error, needed) => {
            if error == .BufferTooSmall {
                _ = tell(kernel, thread, size, needed)
            }
            return .Error(error)
        }
    }
}

// value, written at address in the caller's memory, if there's an address.
tell :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], address: u64, value: u32) -> bool {
    kept :: value
    return address == 0 || copy_to_user(kernel, thread.space, address, cast[u64](&kept), 4)
}

sys_channel_send_handles :: fn(thread: ptr[mut Thread], end: slop_os.Channel, handles: slop_os.UserBuffer, batch: u32) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_send_handles(per_cpu().kernel, thread, found, handles.address, cast[u32](min_u64(handles.count, 0xffffffff)), batch))
}

// How many handles it took into handles; how many there are, also at count.
sys_channel_take_handles :: fn(thread: ptr[mut Thread], end: slop_os.Channel, batch: u32, handles: slop_os.UserBuffer, count: u64) -> Result[u32, slop_os.ChannelError] {
    kernel :: per_cpu().kernel
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    match channel_take_handles(kernel, thread, found, batch, handles.address, cast[u32](min_u64(handles.count, 0xffffffff))) {
        case Taken(taken) => {
            if !tell(kernel, thread, count, taken) {
                return .Error(.BadBuffer)
            }
            return .Ok(taken)
        }
        case Failed(error, there) => {
            if error == .BufferTooSmall {
                _ = tell(kernel, thread, count, there)
            }
            return .Error(error)
        }
    }
}

/*
 * The notify, during which a thread it wakes is made ready on this CPU, to run here once the caller waits,
 * then port_wait (knowledge/design/ipc.md §5).
 */
sys_channel_notify_and_wait :: fn(thread: ptr[mut Thread], end: slop_os.Channel, signals: slop_os.Signals, port: slop_os.Port,
    packets: slop_os.UserBuffer, deadline: u64) -> Result[u32, slop_os.ChannelError] {
    kernel :: per_cpu().kernel
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    waited :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](port), slop_os.ObjectKind.Port, slop_os.RIGHT_PORT_WAIT)?
    cpu :: per_cpu()
    cpu.handoff = true
    notified :: channel_notify(kernel, found, signals)
    cpu.handoff = false
    match notified {
        case Some(error) => return .Error(error)
        case None => {}
    }
    return wait_result[slop_os.ChannelError](port_wait_begin(kernel, thread, cast[ptr[mut Port]](waited), packets.address,
        cast[u32](min_u64(packets.count, 0xffffffff)), ticks_at(kernel, deadline)))
}

// ---- Memory budgets and memory objects (memory_budgets.hsc, memory.hsc)

memory_done :: fn(error: slop_os.MemoryError?) -> Result[void, slop_os.MemoryError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

sys_memory_budget_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, limit: u64) -> Result[slop_os.MemoryBudget, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.HandleError](process, budget)?
    made := cast[ptr[mut MemoryBudget]](0)
    match create_budget(kernel, cast[u64](process), paying, limit) {
        case Ok(created) => made = created
        case Error(error) => return .Error(object_failure(error))
    }
    handle :: owning_handle[slop_os.HandleError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.MemoryBudget](handle))
}

sys_memory_budget_info :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget) -> Result[slop_os.BudgetInfo, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.MemoryBudget, cast[slop_os.Rights](0))
       ?
    limit, used :: budget_info(cast[ptr[mut MemoryBudget]](object))
    return .Ok(slop_os.BudgetInfo.{limit = limit, used = used})
}

sys_memory_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, size: u64) -> Result[slop_os.Memory, slop_os.MemoryError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.MemoryError](process, budget)?
    made :: create_memory(kernel, cast[u64](process), paying, size)?
    handle :: owning_handle[slop_os.MemoryError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Memory](handle))
}

// The tag the channel was made with.
sys_channel_tag :: fn(thread: ptr[mut Thread], end: slop_os.Channel) -> Result[u64, slop_os.ChannelError] {
    object :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](end), slop_os.ObjectKind.Channel, cast[slop_os.Rights](0))?
    return .Ok(core_of(cast[ptr[Channel]](object)).tag)
}

sys_memory_size :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, cast[slop_os.Rights](0))?
    return .Ok(cast[ptr[Memory]](object).size)
}

// The memory needs the rights its protection asks for, and the space RIGHT_SPACE_MAP.
sys_memory_map :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, space: slop_os.AddressSpace, address: u64, offset: u64, size: u64,
    protection: slop_os.Protection) -> Result[void, slop_os.MemoryError] {
    process :: process_of(thread)
    bits :: cast[u32](protection)
    needed := cast[u32](slop_os.RIGHT_MEMORY_READ)
    if bits & cast[u32](slop_os.PROTECTION_WRITE) != 0 {
        needed |= cast[u32](slop_os.RIGHT_MEMORY_WRITE)
    }
    if bits & cast[u32](slop_os.PROTECTION_EXECUTE) != 0 {
        needed |= cast[u32](slop_os.RIGHT_MEMORY_EXECUTE)
    }
    found :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, cast[slop_os.Rights](needed))?
    target :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_MAP)?
    return memory_done(memory_map(per_cpu().kernel, cast[ptr[mut Memory]](found), cast[ptr[mut AddressSpace]](target), address, offset, size, bits))
}

// A port for the pager, which may be bound to (RIGHT_PORT_BIND), and the budget paged memory is charged to.
sys_memory_create_paged :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, port: slop_os.Port, key: u64, size: u64)
    -> Result[slop_os.Memory, slop_os.MemoryError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    pager :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](port), slop_os.ObjectKind.Port, slop_os.RIGHT_PORT_BIND)?
    paying :: paying_budget[slop_os.MemoryError](process, budget)?
    made :: create_paged_memory(kernel, cast[u64](process), paying, cast[ptr[mut Port]](pager), key, size)?
    handle :: owning_handle[slop_os.MemoryError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Memory](handle))
}

// Only a handle that may write the paged memory asks what it's waited for.
sys_memory_page_wanted :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    return page_wanted(cast[ptr[mut Memory]](found))
}

// The paged memory's handle may write it, and source's read it.
sys_memory_supply :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64, source: slop_os.Memory, source_offset: u64)
    -> Result[void, slop_os.MemoryError] {
    process :: process_of(thread)
    found :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    from :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](source), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_READ)?
    return memory_done(supply_page(per_cpu().kernel, cast[ptr[mut Memory]](found), offset, cast[ptr[Memory]](from), source_offset))
}

// The memory needs RIGHT_MEMORY_READ.
sys_memory_read :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64, buffer: slop_os.UserBuffer)
    -> Result[void, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_READ)?
    return memory_done(copy_memory(per_cpu().kernel, cast[ptr[Memory]](found), offset, thread.space, buffer.address, buffer.count, true))
}

// The memory needs RIGHT_MEMORY_WRITE.
sys_memory_write :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64, bytes: slop_os.UserBuffer)
    -> Result[void, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    return memory_done(copy_memory(per_cpu().kernel, cast[ptr[Memory]](found), offset, thread.space, bytes.address, bytes.count, false))
}

sys_memory_unmap :: fn(thread: ptr[mut Thread], space: slop_os.AddressSpace, address: u64) -> Result[void, slop_os.MemoryError] {
    target :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_MAP)?
    return memory_done(memory_unmap(per_cpu().kernel, cast[ptr[mut AddressSpace]](target), address))
}

// A window may be mapped only as the memory's handle may be.
sys_memory_create_window :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, budget: slop_os.MemoryBudget, offset: u64, size: u64)
    -> Result[slop_os.Memory, slop_os.MemoryError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    found :: found_of[slop_os.MemoryError](process, cast[slop_os.Handle](memory))?
    if found.kind != .Memory {
        return .Error(.WrongKind)
    }
    paying :: paying_budget[slop_os.MemoryError](process, budget)?
    rights :: cast[u32](found.rights)
    allowed := cast[u32](0)
    if rights & cast[u32](slop_os.RIGHT_MEMORY_READ) != 0 {
        allowed |= cast[u32](slop_os.PROTECTION_READ)
    }
    if rights & cast[u32](slop_os.RIGHT_MEMORY_WRITE) != 0 {
        allowed |= cast[u32](slop_os.PROTECTION_WRITE)
    }
    if rights & cast[u32](slop_os.RIGHT_MEMORY_EXECUTE) != 0 {
        allowed |= cast[u32](slop_os.PROTECTION_EXECUTE)
    }
    made :: create_window(kernel, cast[u64](process), paying, cast[ptr[mut Memory]](found.object), offset, size, allowed)?
    handle :: owning_handle[slop_os.MemoryError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Memory](handle))
}

// ---- Devices (irqs.hsc)

// The platform capability a handle names.
platform_of :: fn(thread: ptr[mut Thread], platform: slop_os.Platform) -> Result[u64, slop_os.DeviceError] {
    return object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](platform), slop_os.ObjectKind.Platform, cast[slop_os.Rights](0))
}

sys_controller_register :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, kind: slop_os.ControllerKind, registers: u64)
    -> Result[slop_os.ControllerInfo, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    _ = platform_of(thread, platform)?
    known :: controller_kind(cast[u32](kind)) or_return .Error(.NoController)
    if registers & (frames.FRAME_SIZE - 1) != 0 || overlaps_kernel_ram(kernel, registers, CONTROLLER_REGISTERS_SIZE) {
        return .Error(.BadAddress)
    }
    match register_controller(kernel, known, cast[boot_info.PhysicalAddress](registers)) {
        case Ok(index) => return .Ok(slop_os.ControllerInfo.{number = index, lines = kernel.controllers[cast[usize](index) % MAX_CONTROLLERS].lines})
        case Error(error) => return .Error(if error == .TooManyControllers { slop_os.DeviceError.TooManyControllers }
            else if error == .NoMapping { slop_os.DeviceError.OutOfMemory } else { slop_os.DeviceError.NoController })
    }
}

sys_irq_create :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, budget: slop_os.MemoryBudget, controller: u32, line: u32,
    flags: u32) -> Result[slop_os.Irq, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    trigger :: if flags & slop_os.IRQ_LEVEL != 0 { arch_interface.Trigger.Level } else { arch_interface.Trigger.Edge }
    polarity :: if flags & slop_os.IRQ_ACTIVE_LOW != 0 { arch_interface.Polarity.ActiveLow } else { arch_interface.Polarity.ActiveHigh }
    made :: create_irq(kernel, cast[u64](process), paying, controller, line, trigger, polarity)?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Irq](handle))
}

sys_irq_ack :: fn(thread: ptr[mut Thread], irq: slop_os.Irq) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](irq), slop_os.ObjectKind.Irq, slop_os.RIGHT_IRQ_ACK)?
    irq_ack(per_cpu().kernel, cast[ptr[mut Irq]](object))
    return .Ok
}

sys_memory_create_physical :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, budget: slop_os.MemoryBudget, address: u64, size: u64,
    cache: slop_os.CacheMode) -> Result[slop_os.Memory, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    mode := arch_interface.CacheMode.Device
    if cache == .WriteBack {
        mode = .WriteBack
    }
    else if cache == .WriteCombining {
        mode = .WriteCombining
    }
    else if cache != .Device {
        return .Error(.InvalidSize)
    }
    made :: create_device_memory(kernel, cast[u64](process), paying, address, size, mode)?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Memory](handle))
}

// ---- Devices and DMA (devices.hsc)

sys_device_create :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, budget: slop_os.MemoryBudget, address: u32, msi_source: u32,
    config: u64) -> Result[slop_os.Device, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    made :: create_device(kernel, cast[u64](process), paying, address, msi_source, config)?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Device](handle))
}

sys_device_attach :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, device: slop_os.Device, domain: slop_os.DmaDomain)
    -> Result[void, slop_os.DeviceError] {
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    found :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](device), slop_os.ObjectKind.Device, cast[slop_os.Rights](0))?
    target :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](domain), slop_os.ObjectKind.DmaDomain, cast[slop_os.Rights](0))?
    return attach_device(per_cpu().kernel, cast[ptr[mut Device]](found), cast[ptr[mut DmaDomain]](target))
}

sys_irq_create_msi :: fn(thread: ptr[mut Thread], device: slop_os.Device, budget: slop_os.MemoryBudget) -> Result[slop_os.Irq, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    found :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](device), slop_os.ObjectKind.Device, cast[slop_os.Rights](0))?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    made :: create_msi_irq(kernel, cast[u64](process), paying, cast[ptr[mut Device]](found))?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Irq](handle))
}

// A wired line's IRQ has no message.
sys_irq_message :: fn(thread: ptr[mut Thread], irq: slop_os.Irq) -> Result[slop_os.MsiMessage, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](irq), slop_os.ObjectKind.Irq, cast[slop_os.Rights](0))?
    found :: cast[ptr[Irq]](object)
    if !found.msi {
        return .Error(.NoMsi)
    }
    return .Ok(slop_os.MsiMessage.{address = found.message.address, data = found.message.data})
}

// A message-signaled IRQ routed to the CPU with index cpu instead, which the caller's CPU budget must have.
sys_irq_set_cpu :: fn(thread: ptr[mut Thread], irq: slop_os.Irq, cpu: u32) -> Result[void, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    object :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](irq), slop_os.ObjectKind.Irq, cast[slop_os.Rights](0))?
    found :: cast[ptr[mut Irq]](object)
    if !found.msi {
        return .Error(.NoMsi)
    }
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    if cpu >= online || (cpu < 64 && (cpus_of(kernel, process) >> cast[u64](cpu)) & 1 == 0) {
        return .Error(.InvalidArgument)
    }
    return move_msi_irq(kernel, found, cpu)
}

sys_dma_domain_create :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, budget: slop_os.MemoryBudget, flags: u32)
    -> Result[slop_os.DmaDomain, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    made :: create_dma_domain(kernel, cast[u64](process), paying, flags & slop_os.DMA_DOMAIN_TRUSTED != 0)?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.DmaDomain](handle))
}

sys_dma_memory_create :: fn(thread: ptr[mut Thread], domain: slop_os.DmaDomain, budget: slop_os.MemoryBudget, size: u64, limit: u64)
    -> Result[slop_os.Memory, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    found :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](domain), slop_os.ObjectKind.DmaDomain, cast[slop_os.Rights](0))?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    made :: create_dma_memory(kernel, cast[u64](process), paying, cast[ptr[mut DmaDomain]](found), size, limit)?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Memory](handle))
}

sys_memory_device_address :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, cast[slop_os.Rights](0))?
    return device_address_of(cast[ptr[Memory]](object))
}

// registers is device memory itself, uncached, not a window onto it (iommus.hsc).
sys_iommu_register :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, kind: slop_os.IommuKind, registers: slop_os.Memory, first: u32,
    count: u32, stream: u32) -> Result[u32, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    known :: iommu_kind(cast[u32](kind)) or_return .Error(.NoIommu)
    object :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](registers), slop_os.ObjectKind.Memory, cast[slop_os.Rights](0))?
    memory :: cast[ptr[Memory]](object)
    if memory.physical == 0 || memory.parent != 0 || memory.cache != .Device {
        return .Error(.BadAddress)
    }
    if memory.size > MAX_IOMMU_REGISTERS {
        return .Error(.InvalidSize)
    }
    return register_iommu(kernel, known, memory.physical, memory.size, first, count, stream)
}

// ---- Process control (control.hsc, intercepts.hsc): rights on a process cover its subtree (decisions/0017)

// The process a handle names, if the handle has right.
target_of :: fn(thread: ptr[mut Thread], process: slop_os.Process, right: slop_os.Rights) -> Result[ptr[mut Process], slop_os.ControlError] {
    object :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](process), slop_os.ObjectKind.Process, right)?
    return .Ok(cast[ptr[mut Process]](object))
}

control_done :: fn(error: slop_os.ControlError?) -> Result[void, slop_os.ControlError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

sys_process_threads :: fn(thread: ptr[mut Thread], process: slop_os.Process, ids: slop_os.UserBuffer) -> Result[u32, slop_os.ControlError] {
    kernel :: per_cpu().kernel
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_INSPECT)?
    found : u64[64]
    capacity :: cast[u32](min_u64(ids.count, 64))
    count :: threads_of(kernel, cast[u64](target), &found, capacity)
    written :: min_u64(cast[u64](count), cast[u64](capacity))
    if !copy_to_user(kernel, thread.space, ids.address, cast[u64](&found[0]), written * 8) {
        return .Error(.BadBuffer)
    }
    return .Ok(count)
}

// The address space a handle names, if it's in the subtree.
subtree_space :: fn(thread: ptr[mut Thread], target: ptr[mut Process], space: slop_os.AddressSpace) -> Result[ptr[mut AddressSpace], slop_os.ControlError] {
    object :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, cast[slop_os.Rights](0))?
    if !in_subtree(object, cast[u64](target)) {
        return .Error(.BadAddress)
    }
    return .Ok(cast[ptr[mut AddressSpace]](object))
}

sys_process_read_memory :: fn(thread: ptr[mut Thread], process: slop_os.Process, space: slop_os.AddressSpace, address: u64,
    buffer: slop_os.UserBuffer) -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_READ_MEMORY)?
    other :: subtree_space(thread, target, space)?
    if !copy_between(per_cpu().kernel, other, address, thread.space, buffer.address, buffer.count) {
        return .Error(.BadAddress)
    }
    return .Ok
}

sys_process_write_memory :: fn(thread: ptr[mut Thread], process: slop_os.Process, space: slop_os.AddressSpace, address: u64,
    buffer: slop_os.UserBuffer) -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE)?
    other :: subtree_space(thread, target, space)?
    if !copy_between(per_cpu().kernel, thread.space, buffer.address, other, address, buffer.count) {
        return .Error(.BadAddress)
    }
    return .Ok
}

// A thread in the subtree, by ID.
subtree_thread :: fn(thread: ptr[mut Thread], process: slop_os.Process, right: slop_os.Rights, id: u64) -> Result[ptr[mut Thread], slop_os.ControlError] {
    target :: target_of(thread, process, right)?
    found :: thread_in(per_cpu().kernel, cast[u64](target), id) or_return .Error(.NoSuchThread)
    return .Ok(found)
}

sys_thread_suspend :: fn(thread: ptr[mut Thread], process: slop_os.Process, id: u64) -> Result[void, slop_os.ControlError] {
    found :: subtree_thread(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE, id)?
    hold_thread(per_cpu().kernel, found, HELD_SUSPEND)
    return .Ok
}

sys_thread_resume :: fn(thread: ptr[mut Thread], process: slop_os.Process, id: u64) -> Result[void, slop_os.ControlError] {
    found :: subtree_thread(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE, id)?
    unhold_thread(per_cpu().kernel, found, HELD_SUSPEND)
    return .Ok
}

// Registers, only while they're the thread's alone: parked.
sys_thread_read_registers :: fn(thread: ptr[mut Thread], process: slop_os.Process, id: u64, registers: slop_os.UserBuffer) -> Result[void, slop_os.ControlError] {
    found :: subtree_thread(thread, process, slop_os.RIGHT_PROCESS_INSPECT, id)?
    if registers.count < cast[u64](slop_os.THREAD_REGISTERS) {
        return .Error(.BadBuffer)
    }
    lock_at(&found.control, .ThreadControl)
    defer unlock_at(&found.control, .ThreadControl)
    if !found.parked {
        return .Error(.NotStopped)
    }
    if !read_registers(per_cpu().kernel, found, thread.space, registers.address) {
        return .Error(.BadBuffer)
    }
    return .Ok
}

sys_thread_write_registers :: fn(thread: ptr[mut Thread], process: slop_os.Process, id: u64, registers: slop_os.UserBuffer) -> Result[void, slop_os.ControlError] {
    found :: subtree_thread(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE, id)?
    if registers.count < cast[u64](slop_os.THREAD_REGISTERS) {
        return .Error(.BadBuffer)
    }
    lock_at(&found.control, .ThreadControl)
    defer unlock_at(&found.control, .ThreadControl)
    if !found.parked {
        return .Error(.NotStopped)
    }
    return control_done(write_registers(per_cpu().kernel, found, thread.space, registers.address))
}

// Paid for by the caller's process's own budget, as it has no budget argument.
sys_intercept_attach :: fn(thread: ptr[mut Thread], process: slop_os.Process, port: slop_os.Port, key: u64, calls: u64, points: u32)
    -> Result[slop_os.Intercept, slop_os.ControlError] {
    kernel :: per_cpu().kernel
    caller :: process_of(thread)
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_INTERCEPT)?
    reporting :: object_of[slop_os.ControlError](caller, cast[slop_os.Handle](port), slop_os.ObjectKind.Port, slop_os.RIGHT_PORT_BIND)?
    made :: create_intercept(kernel, cast[u64](caller), caller.header.budget, target, cast[ptr[mut Port]](reporting), key, calls, points)?
    handle :: owning_handle[slop_os.ControlError](kernel, caller, cast[u64](made), false)?
    return .Ok(cast[slop_os.Intercept](handle))
}

intercept_of_handle :: fn(thread: ptr[mut Thread], intercept: slop_os.Intercept) -> Result[ptr[mut Intercept], slop_os.ControlError] {
    object :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](intercept), slop_os.ObjectKind.Intercept, cast[slop_os.Rights](0))?
    return .Ok(cast[ptr[mut Intercept]](object))
}

sys_intercept_next :: fn(thread: ptr[mut Thread], intercept: slop_os.Intercept, stop: u64) -> Result[void, slop_os.ControlError] {
    found :: intercept_of_handle(thread, intercept)?
    return control_done(intercept_next(per_cpu().kernel, found, thread.space, stop))
}

sys_intercept_resume :: fn(thread: ptr[mut Thread], intercept: slop_os.Intercept, id: u64, action: slop_os.InterceptAction)
    -> Result[void, slop_os.ControlError] {
    found :: intercept_of_handle(thread, intercept)?
    if action != .Continue && action != .Skip && action != .Kill {
        return .Error(.NotStopped)
    }
    return control_done(intercept_resume(per_cpu().kernel, found, id, action))
}

// The caller's process ends, with its subtree, the calling thread with it: code goes to whoever watches it end.
sys_process_exit :: fn(thread: ptr[mut Thread], code: u32) {
    process :: process_of(thread)
    process.exited = true
    process.exit_code = code
    _ = destroy_object(per_cpu().kernel, cast[u64](process))
}

sys_process_kill :: fn(thread: ptr[mut Thread], process: slop_os.Process) -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_KILL)?
    _ = destroy_object(per_cpu().kernel, cast[u64](target))
    return .Ok
}

/*
 * A thread owned by the process, in space, which must be in its subtree, started at entry with stack and
 * argument, as thread_create would in the caller's: its ID (decisions/0067).
 */
sys_thread_create_in :: fn(thread: ptr[mut Thread], process: slop_os.Process, budget: slop_os.MemoryBudget, space: slop_os.AddressSpace,
    entry: u64, stack: u64, argument: u64) -> Result[u64, slop_os.ControlError] {
    kernel :: per_cpu().kernel
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_THREADS)?
    caller :: process_of(thread)
    paying :: paying_budget[slop_os.ControlError](caller, budget)?
    found :: object_of[slop_os.ControlError](caller, cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_THREADS)?
    if !in_subtree(found, cast[u64](target)) {
        return .Error(.BadAddress)
    }
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](entry),
        stack_pointer = cast[arch_interface.VirtualAddress](stack),
        argument = argument,
    }
    match create_thread(kernel, cast[u64](target), cast[ptr[mut AddressSpace]](found), &start,
        arch_interface.VectorConfig.{extended = false}, 0, paying) {
        case Ok(made) => {
            id :: made.id
            start_thread(kernel, made)
            return .Ok(id)
        }
        case Error(error) => return .Error(if error == .OutOfMemory { slop_os.ControlError.OutOfMemory }
            else if error == .BudgetExceeded { slop_os.ControlError.BudgetExceeded } else { slop_os.ControlError.ObjectGone })
    }
}

sys_process_give_handles :: fn(thread: ptr[mut Thread], process: slop_os.Process, handles: slop_os.UserBuffer, given: slop_os.UserBuffer)
    -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_THREADS)?
    return control_done(give_handles(per_cpu().kernel, thread, target, handles, given))
}

// CPU budgets and I/O ports (roadmap 9a, decisions/0093)

cpu_budget_failure :: fn(error: CpuBudgetError) -> slop_os.HandleError {
    return match error {
        case .OutOfMemory => slop_os.HandleError.OutOfMemory
        case .OwnerGone => slop_os.HandleError.ObjectGone
        case .BudgetExceeded => slop_os.HandleError.BudgetExceeded
        case .TooMuch => slop_os.HandleError.BudgetExceeded
        case .InvalidArgument => slop_os.HandleError.InvalidArgument
    }
}

// A child of the parent budget, owned by the caller's process: an owning handle to it.
sys_cpu_budget_create :: fn(thread: ptr[mut Thread], parent: slop_os.CpuBudget, budget: slop_os.MemoryBudget, priority: u32, period: u64,
    time: u64) -> Result[slop_os.CpuBudget, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    from :: object_of[slop_os.HandleError](process, cast[slop_os.Handle](parent), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_SPLIT)?
    paying :: paying_budget[slop_os.HandleError](process, budget)?
    made := cast[ptr[mut CpuBudget]](0)
    match create_cpu_budget(kernel, cast[u64](process), paying, cast[ptr[mut CpuBudget]](from), priority, period, time) {
        case Ok(created) => made = created
        case Error(error) => return .Error(cpu_budget_failure(error))
    }
    handle :: owning_handle[slop_os.HandleError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.CpuBudget](handle))
}

sys_cpu_budget_set :: fn(thread: ptr[mut Thread], budget: slop_os.CpuBudget, priority: u32, period: u64, time: u64) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_SET)?
    match set_cpu_budget(per_cpu().kernel, cast[ptr[mut CpuBudget]](object), priority, period, time) {
        case Ok => return .Ok
        case Error(error) => return .Error(cpu_budget_failure(error))
    }
}

sys_cpu_budget_set_cpus :: fn(thread: ptr[mut Thread], budget: slop_os.CpuBudget, cpus: u64) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_SET)?
    match set_cpu_budget_cpus(per_cpu().kernel, cast[ptr[mut CpuBudget]](object), cpus) {
        case Ok => return .Ok
        case Error(error) => return .Error(cpu_budget_failure(error))
    }
}

sys_cpu_budget_info :: fn(thread: ptr[mut Thread], budget: slop_os.CpuBudget, info: slop_os.UserBuffer) -> Result[void, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, cast[slop_os.Rights](0))?
    if info.count < cast[u64](slop_os.CPU_BUDGET_INFO_WORDS) {
        return .Error(.BadBuffer)
    }
    words : u64[slop_os.CPU_BUDGET_INFO_WORDS]
    cpu_budget_words(kernel, cast[ptr[CpuBudget]](object), words)
    if !copy_to_user(kernel, thread.space, info.address, cast[u64](&words[0]), cast[u64](size_of(u64[slop_os.CPU_BUDGET_INFO_WORDS]))) {
        return .Error(.BadBuffer)
    }
    return .Ok
}

// The process, which must be in the caller's subtree, put on the budget, with every thread of its.
sys_process_set_cpu_budget :: fn(thread: ptr[mut Thread], process: slop_os.Process, budget: slop_os.CpuBudget) -> Result[void, slop_os.HandleError] {
    caller :: process_of(thread)
    target :: object_of[slop_os.HandleError](caller, cast[slop_os.Handle](process), slop_os.ObjectKind.Process, slop_os.RIGHT_PROCESS_THREADS)?
    object :: object_of[slop_os.HandleError](caller, cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_BIND)?
    if !set_process_budget(per_cpu().kernel, cast[ptr[mut Process]](target), cast[ptr[mut CpuBudget]](object)) {
        return .Error(.ObjectGone)
    }
    return .Ok
}

sys_io_ports_create :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, budget: slop_os.MemoryBudget, first: u32, count: u32)
    -> Result[slop_os.IoPortRange, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    made := cast[ptr[mut IoPortRange]](0)
    match create_io_ports(kernel, cast[u64](process), paying, first, count) {
        case Ok(created) => made = created
        case Error(error) => return .Error(match error {
            case .OutOfMemory => slop_os.DeviceError.OutOfMemory
            case .OwnerGone => slop_os.DeviceError.ObjectGone
            case .BudgetExceeded => slop_os.DeviceError.BudgetExceeded
            case .InvalidArgument => slop_os.DeviceError.InvalidArgument
        })
    }
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.IoPortRange](handle))
}

sys_io_port_read :: fn(thread: ptr[mut Thread], ports: slop_os.IoPortRange, offset: u32, width: u32) -> Result[u32, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](ports), slop_os.ObjectKind.IoPortRange, slop_os.RIGHT_IO_PORTS_ACCESS)?
    port :: port_at(cast[ptr[IoPortRange]](object), offset, width) or_return .Error(.InvalidArgument)
    value :: arch.port_read(port, width) or_return .Error(.InvalidArgument)
    return .Ok(value)
}

sys_io_port_write :: fn(thread: ptr[mut Thread], ports: slop_os.IoPortRange, offset: u32, width: u32, value: u32) -> Result[void, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](ports), slop_os.ObjectKind.IoPortRange, slop_os.RIGHT_IO_PORTS_ACCESS)?
    port :: port_at(cast[ptr[IoPortRange]](object), offset, width) or_return .Error(.InvalidArgument)
    if !arch.port_write(port, width, value) {
        return .Error(.InvalidArgument)
    }
    return .Ok
}
