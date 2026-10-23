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
    result :: dispatch_syscall(kernel, thread)
    arch.set_syscall_result(&thread.registers, &result)
    schedule(false)
}

dispatch_syscall :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) -> arch_interface.SyscallResult {
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
    return failed(.NoSuchCall)
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
