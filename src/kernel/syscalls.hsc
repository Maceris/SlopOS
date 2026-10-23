package kernel

import runtime from "base"
import arch_interface from "../arch_interface"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * System calls (roadmap M5, knowledge/design/system-abi.md §4): the calling thread's registers are kept
 * in it, the call is found by its number in slop_os.Syscall, and its result goes in the thread's result
 * registers before the scheduler resumes it, or runs something else. Every handle is looked up in the
 * calling thread's process's table.
 */
//TODO(claude): generate the dispatch from the ABI package's table (M5, the ABI package)

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
    // A call that blocks has its result set when it finishes (ports.hsc, complete_wait)
    match dispatch_syscall(kernel, thread) {
        case Some(result) => {
            kept :: result
            arch.set_syscall_result(&thread.registers, &kept)
        }
        case None => {}
    }
    schedule(false)
}

dispatch_syscall :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) -> arch_interface.SyscallResult? {
    registers :: &thread.registers
    number :: arch.syscall_number(registers)
    process :: process_of(thread)
    if number == cast[u64](cast[u32](slop_os.Syscall.HandleClose)) {
        return handle_close(kernel, process, argument(registers, 0))
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.HandleDuplicate)) {
        return handle_duplicate(kernel, process, argument(registers, 0), cast[slop_os.Rights](cast[u32](arch.syscall_argument(registers, 1))))
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.HandleInfo)) {
        return handle_info(process, argument(registers, 0))
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.ThreadExit)) {
        _ = destroy_object(kernel, cast[u64](thread))
        return succeeded(0, 0)
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.ThreadCreate)) {
        return thread_create(kernel, process, argument(registers, 0), arch.syscall_argument(registers, 1),
            arch.syscall_argument(registers, 2), arch.syscall_argument(registers, 3))
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.ProcessCreate)) {
        return process_create(kernel, process)
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.AddressSpaceCreate)) {
        return address_space_create(kernel, process)
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.ClockMonotonic)) {
        return succeeded(cast[u64](kernel_monotonic(cast[rawptr](kernel))), 0)
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.PortCreate)) {
        match create_port(kernel, cast[u64](process)) {
            case Ok(made) => return owned_by_caller(kernel, process, cast[u64](made), false)
            case Error(error) => return failed(if error == .OutOfMemory { slop_os.HandleError.OutOfMemory } else { slop_os.HandleError.ObjectGone })
        }
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.PortBindWake)) {
        match port_of(process, argument(registers, 0), slop_os.RIGHT_PORT_BIND) {
            case Ok(port) => return port_done(port_bind_wake(kernel, port, arch.syscall_argument(registers, 1)))
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.PortWake)) {
        match port_of(process, argument(registers, 0), slop_os.RIGHT_PORT_BIND) {
            case Ok(port) => return port_done(port_wake(kernel, port, arch.syscall_argument(registers, 1), arch.syscall_argument(registers, 2)))
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.PortSetTimer)) {
        match port_of(process, argument(registers, 0), slop_os.RIGHT_PORT_BIND) {
            case Ok(port) => return port_done(port_set_timer(kernel, port, arch.syscall_argument(registers, 1), arch.syscall_argument(registers, 2)))
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.PortUnbind)) {
        match port_of(process, argument(registers, 0), slop_os.RIGHT_PORT_BIND) {
            case Ok(port) => return port_done(port_unbind(kernel, port, arch.syscall_argument(registers, 1)))
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    if number == cast[u64](cast[u32](slop_os.Syscall.PortWait)) {
        match port_of(process, argument(registers, 0), slop_os.RIGHT_PORT_WAIT) {
            case Ok(port) => {
                deadline :: ticks_at(kernel, arch.syscall_argument(registers, 3))
                return wait_result(port_wait_begin(kernel, thread, port, arch.syscall_argument(registers, 1),
                    cast[u32](arch.syscall_argument(registers, 2)), deadline))
            }
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    if number >= cast[u64](cast[u32](slop_os.Syscall.ChannelCreate)) && number <= cast[u64](cast[u32](slop_os.Syscall.PortBind)) {
        return dispatch_channel_call(kernel, thread, process, cast[slop_os.Syscall](cast[u32](number)))
    }
    return failed(.NoSuchCall)
}

// The channel calls, and binding to ports.
dispatch_channel_call :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], process: ptr[mut Process], call: slop_os.Syscall)
    -> arch_interface.SyscallResult? {
    registers :: &thread.registers
    if call == .ChannelCreate {
        match create_channel(kernel, cast[u64](process), cast[u32](arch.syscall_argument(registers, 0))) {
            case Ok(pair) => return owned_pair(kernel, process, pair)
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    if call == .PortBind {
        port := cast[ptr[mut Port]](0)
        match port_of(process, argument(registers, 0), slop_os.RIGHT_PORT_BIND) {
            case Ok(found) => port = found
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
        match channel_of(process, argument(registers, 1), cast[slop_os.Rights](0)) {
            case Ok(end) => {
                once :: arch.syscall_argument(registers, 4) == cast[u64](cast[u32](slop_os.BindMode.Once))
                mode :: if once { slop_os.BindMode.Once } else { slop_os.BindMode.Persistent }
                return port_done(port_bind(kernel, port, end, cast[slop_os.Signals](cast[u32](arch.syscall_argument(registers, 2))),
                    arch.syscall_argument(registers, 3), mode))
            }
            case Error(error) => return tagged(cast[u64](cast[u32](error)))
        }
    }
    right :: if call == .ChannelMap { slop_os.RIGHT_CHANNEL_MAP } else { cast[slop_os.Rights](0) }
    end := cast[ptr[mut Channel]](0)
    match channel_of(process, argument(registers, 0), right) {
        case Ok(found) => end = found
        case Error(error) => return tagged(cast[u64](cast[u32](error)))
    }
    if call == .ChannelMap {
        return channel_map_call(kernel, process, end, argument(registers, 1), arch.syscall_argument(registers, 2))
    }
    if call == .ChannelUnmap {
        return channel_done(channel_unmap(kernel, end))
    }
    if call == .ChannelNotify {
        return channel_done(channel_notify(kernel, end, cast[slop_os.Signals](cast[u32](arch.syscall_argument(registers, 1)))))
    }
    if call == .ChannelWrite {
        return channel_done(channel_write(kernel, thread, end, arch.syscall_argument(registers, 1),
            cast[u32](arch.syscall_argument(registers, 2)), cast[u32](arch.syscall_argument(registers, 3))))
    }
    if call == .ChannelRead {
        return read_result(channel_read(kernel, thread, end, arch.syscall_argument(registers, 1), cast[u32](arch.syscall_argument(registers, 2))))
    }
    if call == .ChannelSendHandles {
        return channel_done(channel_send_handles(kernel, thread, end, arch.syscall_argument(registers, 1),
            cast[u32](arch.syscall_argument(registers, 2)), cast[u32](arch.syscall_argument(registers, 3))))
    }
    if call == .ChannelTakeHandles {
        return take_result(channel_take_handles(kernel, thread, end, cast[u32](arch.syscall_argument(registers, 1)),
            arch.syscall_argument(registers, 2), cast[u32](arch.syscall_argument(registers, 3))))
    }
    return notify_and_wait(kernel, thread, process, end)
}

/*
 * ChannelNotifyAndWait: the notify, during which a thread it wakes is made ready on this CPU, to run
 * here once the caller waits, then PortWait (knowledge/design/ipc.md §5).
 */
notify_and_wait :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], process: ptr[mut Process], end: ptr[mut Channel])
    -> arch_interface.SyscallResult? {
    registers :: &thread.registers
    port := cast[ptr[mut Port]](0)
    match port_of(process, argument(registers, 2), slop_os.RIGHT_PORT_WAIT) {
        case Ok(found) => port = found
        case Error(error) => return tagged(cast[u64](cast[u32](error)))
    }
    cpu :: per_cpu()
    cpu.handoff = true
    notified :: channel_notify(kernel, end, cast[slop_os.Signals](cast[u32](arch.syscall_argument(registers, 1))))
    cpu.handoff = false
    match notified {
        case Some(error) => return tagged(cast[u64](cast[u32](error)))
        case None => {}
    }
    return wait_result(port_wait_begin(kernel, thread, port, arch.syscall_argument(registers, 3),
        cast[u32](arch.syscall_argument(registers, 4)), ticks_at(kernel, arch.syscall_argument(registers, 5))))
}

wait_result :: fn(outcome: WaitOutcome) -> arch_interface.SyscallResult? {
    return match outcome {
        case Done(taken) => succeeded(cast[u64](taken), 0)
        case Failed(error) => tagged(cast[u64](cast[u32](error)))
        case Blocked => null
    }
}

// Map end's rings in the address space a handle names, which needs RIGHT_SPACE_MAP.
channel_map_call :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], end: ptr[mut Channel], space: slop_os.Handle, address: u64)
    -> arch_interface.SyscallResult {
    match lookup(&process.table, space) {
        case Ok(found) => {
            if found.kind != .AddressSpace {
                return failed(.WrongKind)
            }
            if cast[u32](found.rights) & cast[u32](slop_os.RIGHT_SPACE_MAP) == 0 {
                return failed(.MissingRight)
            }
            return channel_done(channel_map(kernel, end, cast[ptr[mut AddressSpace]](found.object), address))
        }
        case Error(error) => return failed(error)
    }
}

// The channel end a handle refers to, if the handle has every right in rights.
channel_of :: fn(process: ptr[mut Process], handle: slop_os.Handle, rights: slop_os.Rights) -> Result[ptr[mut Channel], slop_os.ChannelError] {
    match lookup(&process.table, handle) {
        case Ok(found) => {
            if found.kind != .Channel {
                return .Error(.WrongKind)
            }
            if cast[u32](found.rights) & cast[u32](rights) != cast[u32](rights) {
                return .Error(.MissingRight)
            }
            return .Ok(cast[ptr[mut Channel]](found.object))
        }
        case Error(error) => return .Error(if error == .ObjectGone { slop_os.ChannelError.ObjectGone } else { slop_os.ChannelError.InvalidHandle })
    }
}

channel_done :: fn(error: slop_os.ChannelError?) -> arch_interface.SyscallResult {
    return match error {
        case Some(failure) => tagged(cast[u64](cast[u32](failure)))
        case None => succeeded(0, 0)
    }
}

read_result :: fn(outcome: ReadOutcome) -> arch_interface.SyscallResult {
    return match outcome {
        case Read(size, handles) => succeeded(cast[u64](size), cast[u64](handles))
        case Failed(error, size) => arch_interface.SyscallResult.{tag = cast[u64](cast[u32](error)), values = u64.[cast[u64](size), 0]}
    }
}

take_result :: fn(outcome: TakeOutcome) -> arch_interface.SyscallResult {
    return match outcome {
        case Taken(count) => succeeded(cast[u64](count), 0)
        case Failed(error, count) => arch_interface.SyscallResult.{tag = cast[u64](cast[u32](error)), values = u64.[cast[u64](count), 0]}
    }
}

// Owning handles in process to both ends of a new channel; without room for them, the channel is destroyed.
owned_pair :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], pair: ChannelPair) -> arch_interface.SyscallResult {
    a := slop_os.NO_HANDLE
    match install_owning(kernel, process, cast[u64](pair.a)) {
        case Ok(handle) => a = handle
        case Error(error) => {
            _ = destroy_object(kernel, cast[u64](pair.a))
            _ = destroy_object(kernel, cast[u64](pair.b))
            return failed(error)
        }
    }
    match install_owning(kernel, process, cast[u64](pair.b)) {
        case Ok(handle) => return succeeded(cast[u64](cast[u32](a)), cast[u64](cast[u32](handle)))
        case Error(error) => {
            _ = remove(&process.table, a)
            _ = destroy_object(kernel, cast[u64](pair.a))
            _ = destroy_object(kernel, cast[u64](pair.b))
            return failed(error)
        }
    }
}

// The port a handle refers to, if the handle has right.
port_of :: fn(process: ptr[mut Process], handle: slop_os.Handle, right: slop_os.Rights) -> Result[ptr[mut Port], slop_os.PortError] {
    match lookup(&process.table, handle) {
        case Ok(found) => {
            if found.kind != .Port {
                return .Error(.WrongKind)
            }
            if cast[u32](found.rights) & cast[u32](right) == 0 {
                return .Error(.MissingRight)
            }
            return .Ok(cast[ptr[mut Port]](found.object))
        }
        // The tags they share mean the same
        case Error(error) => return .Error(if error == .ObjectGone { slop_os.PortError.ObjectGone } else { slop_os.PortError.InvalidHandle })
    }
}

port_done :: fn(error: slop_os.PortError?) -> arch_interface.SyscallResult {
    return match error {
        case Some(failure) => tagged(cast[u64](cast[u32](failure)))
        case None => succeeded(0, 0)
    }
}

tagged :: fn(tag: u64) -> arch_interface.SyscallResult {
    return arch_interface.SyscallResult.{tag = tag, values = u64.[0, 0]}
}

argument :: fn(registers: ptr[arch.UserRegisters], index: u32) -> slop_os.Handle {
    return cast[slop_os.Handle](cast[u32](arch.syscall_argument(registers, index)))
}

succeeded :: fn(first: u64, second: u64) -> arch_interface.SyscallResult {
    return arch_interface.SyscallResult.{tag = 0, values = u64.[first, second]}
}

failed :: fn(error: slop_os.HandleError) -> arch_interface.SyscallResult {
    return arch_interface.SyscallResult.{tag = cast[u64](cast[u32](error)), values = u64.[0, 0]}
}

// Closing the owning handle destroys the object.
handle_close :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], handle: slop_os.Handle) -> arch_interface.SyscallResult {
    match remove(&process.table, handle) {
        case Ok(removed) => {
            if removed.owning && is_live(removed.object, removed.generation) {
                _ = destroy_object(kernel, removed.object)
            }
            return succeeded(0, 0)
        }
        case Error(error) => return failed(error)
    }
}

// Another handle to the same object, never owning, with rights the handle has.
handle_duplicate :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], handle: slop_os.Handle, rights: slop_os.Rights)
    -> arch_interface.SyscallResult {
    match lookup(&process.table, handle) {
        case Ok(found) => {
            held :: cast[u32](found.rights)
            if held & cast[u32](slop_os.RIGHT_DUPLICATE) == 0 || cast[u32](rights) & ~held != 0 {
                return failed(.MissingRight)
            }
            match install(kernel, &process.table, found.object, found.generation, found.kind, rights, false) {
                case Ok(made) => return succeeded(cast[u64](cast[u32](made)), 0)
                case Error(error) => return failed(error)
            }
        }
        case Error(error) => return failed(error)
    }
}

handle_info :: fn(process: ptr[mut Process], handle: slop_os.Handle) -> arch_interface.SyscallResult {
    match lookup(&process.table, handle) {
        case Ok(found) => return succeeded(cast[u64](cast[u8](found.kind)), cast[u64](cast[u32](found.rights)))
        case Error(error) => return failed(error)
    }
}

/*
 * A thread in the address space space names, owned by the caller's process, started at entry with stack
 * and argument: an owning handle to it.
 */
thread_create :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], space: slop_os.Handle, entry: u64, stack: u64,
    argument: u64) -> arch_interface.SyscallResult {
    found := Resolved.{}
    match lookup(&process.table, space) {
        case Ok(resolved) => found = resolved
        case Error(error) => return failed(error)
    }
    if found.kind != .AddressSpace {
        return failed(.WrongKind)
    }
    if cast[u32](found.rights) & cast[u32](slop_os.RIGHT_SPACE_THREADS) == 0 {
        return failed(.MissingRight)
    }
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](entry),
        stack_pointer = cast[arch_interface.VirtualAddress](stack),
        argument = argument,
    }
    made := cast[ptr[mut Thread]](0)
    match create_thread(kernel, cast[u64](process), cast[ptr[mut AddressSpace]](found.object), &start,
        arch_interface.VectorConfig.{extended = false}, 0) {
        case Ok(thread) => made = thread
        case Error(error) => return failed(if error == .OutOfMemory { slop_os.HandleError.OutOfMemory } else { slop_os.HandleError.ObjectGone })
    }
    return owned_by_caller(kernel, process, cast[u64](made), true)
}

// A new process, owned by the caller's: an owning handle to it.
process_create :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) -> arch_interface.SyscallResult {
    match create_process(kernel, cast[u64](process)) {
        case Ok(made) => return owned_by_caller(kernel, process, cast[u64](made), false)
        case Error(error) => return failed(if error == .OutOfMemory { slop_os.HandleError.OutOfMemory } else { slop_os.HandleError.ObjectGone })
    }
}

// A new, empty address space, owned by the caller's process: an owning handle to it.
address_space_create :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) -> arch_interface.SyscallResult {
    match create_address_space(kernel, cast[u64](process)) {
        case Ok(made) => return owned_by_caller(kernel, process, cast[u64](made), false)
        case Error(error) => return failed(if error == .OwnerGone { slop_os.HandleError.ObjectGone } else { slop_os.HandleError.OutOfMemory })
    }
}

/*
 * An owning handle in process to object, which it owns, and if it's a thread, started. Without room for
 * the handle, the object is destroyed.
 */
owned_by_caller :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], object: u64, start: bool) -> arch_interface.SyscallResult {
    match install_owning(kernel, process, object) {
        case Ok(handle) => {
            if start {
                start_thread(kernel, cast[ptr[mut Thread]](object))
            }
            return succeeded(cast[u64](cast[u32](handle)), 0)
        }
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return failed(error)
        }
    }
}
