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

/**
 * Handle a system call from the CPU's current thread, whose registers are saved: dispatch it, write its result, and
 * schedule. Never returns: the scheduler picks up from here.
 *
 * Runs on the calling thread's CPU, entered from the architecture's system call entry with interrupts as that entry
 * leaves them. A debugger's intercept may stop the thread at the call's entry and at its exit (intercepts.hsc). A call
 * that blocked the thread, or ended it, leaves its result to be written later, or never.
 *
 * @param registers The user registers the entry saved, which are copied into the thread.
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

/**
 * Take the CPU's current thread off it, stopped or blocked: nothing runs here until the scheduler picks something.
 *
 * Only the CPU itself changes its current thread, so it takes no lock.
 *
 * @param cpu The calling CPU's PerCpu.
 */
leave_cpu :: fn(cpu: ptr[mut PerCpu]) {
    cpu.current = 0
    intrinsics.atomic_store_u32_release(&cpu.current_level, IDLE_LEVEL)
}

/**
 * Handle a fault from user mode by the CPU's current thread, whose registers are saved, then schedule. Never returns:
 * the scheduler picks up from here.
 *
 * A page fault in memory mapped in the thread's space is resolved (memory.hsc), filling the page in if it wasn't yet,
 * and the thread goes on, touching it again; one waiting for its pager leaves the CPU until the page is supplied. Any
 * other fault stops the thread for its debugger (intercepts.hsc), or, without one, destroys it, logging why unless its
 * process is already being destroyed.
 *
 * @param registers The user registers the entry saved, which are copied into the thread.
 * @param fault What faulted: a page fault's address and access, or another kind, reported to a debugger as access 0xff.
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

/**
 * Run the call in a thread's registers, by the dispatch generated from the ABI package's table
 * (slop_os.syscall_dispatch), which decodes its arguments and calls its sys_ handler.
 *
 * @param thread The calling thread, the CPU's current one, its registers saved.
 * @return The call's result, for its result registers: tag 0 and its values on success, or its error's value as the
 *     tag; HandleError.NoSuchCall for a number the table hasn't. A call that blocked or ended the thread gives a result
 *     that isn't written.
 */
dispatch_syscall :: fn(thread: ptr[mut Thread]) -> arch_interface.SyscallResult {
    registers :: &thread.registers
    number :: arch.syscall_number(registers)
    #insert slop_os.syscall_dispatch()
    return answered(cast[u64](cast[u32](slop_os.HandleError.NoSuchCall)), 0, 0)
}

/**
 * Read one argument word of a system call, as the generated dispatch decodes arguments (slop_os.syscall_dispatch).
 *
 * @param registers The calling thread's saved registers.
 * @param index The argument's index, from 0, as the architecture's calling convention numbers them.
 * @return The argument, as the caller passed it: untrusted, unchecked.
 */
word :: fn(registers: ptr[arch.UserRegisters], index: u64) -> u64 {
    return arch.syscall_argument(registers, cast[u32](index))
}

/**
 * Read a slice argument of a system call: its address and its count, in two argument words.
 *
 * @param registers The calling thread's saved registers.
 * @param index The index of the address's word; the count is the next one.
 * @return The slice, its address a user virtual address and its count in elements, both untrusted and unchecked.
 */
buffer :: fn(registers: ptr[arch.UserRegisters], index: u64) -> slop_os.UserBuffer {
    return slop_os.UserBuffer.{address = word(registers, index), count = word(registers, index + 1)}
}

/**
 * Make a system call's result, as the generated dispatch answers.
 *
 * @param tag 0 for success, or the error's value.
 * @param first The first result word.
 * @param second The second result word.
 * @return The result, for the thread's result registers.
 */
answered :: fn(tag: u64, first: u64, second: u64) -> arch_interface.SyscallResult {
    return arch_interface.SyscallResult.{tag = tag, values = u64.[first, second]}
}

// ---- Handles

/**
 * Close a handle in the caller's table; closing an owning handle to a live object destroys the object.
 *
 * No right is needed. The handle's slot is free again once its generation is bumped, so the old value never names it.
 *
 * @param thread The calling thread, whose process's table it's in.
 * @param handle The handle to close.
 * @error InvalidHandle Not a handle in the caller's table, or one already closed.
 */
sys_handle_close :: fn(thread: ptr[mut Thread], handle: slop_os.Handle) -> Result[void, slop_os.HandleError] {
    removed :: remove(&process_of(thread).table, handle)?
    if removed.owning && is_live(removed.object, removed.generation) {
        _ = destroy_object(per_cpu().kernel, removed.object)
    }
    else if removed.kind == .Memory {
        let_go_of_memory(per_cpu().kernel, removed.object, removed.generation)
    }
    return .Ok
}

/**
 * Make another handle to the same object in the caller's table, never an owning one.
 *
 * @param thread The calling thread, whose process's table both handles are in.
 * @param handle The handle to duplicate, which needs RIGHT_DUPLICATE; it stays as it was.
 * @param rights The new handle's rights, each of which handle has to have.
 * @return The new handle in the caller's table, with rights, not owning: closing it leaves the object alone, and it
 *     goes stale when the object is destroyed.
 * @error InvalidHandle Not a handle in the caller's table, or one already closed.
 * @error ObjectGone The object was destroyed, or the caller's table is closed as its process is destroyed.
 * @error MissingRight The handle lacks RIGHT_DUPLICATE, or one of rights.
 * @error TableFull The caller's table has no room.
 * @error BudgetExceeded The caller's process's budget can't pay for another page of its table.
 * @error OutOfMemory No frame for another page of its table.
 */
sys_handle_duplicate :: fn(thread: ptr[mut Thread], handle: slop_os.Handle, rights: slop_os.Rights) -> Result[slop_os.Handle, slop_os.HandleError] {
    process :: process_of(thread)
    found :: lookup(&process.table, handle)?
    held :: cast[u32](found.rights)
    if held & cast[u32](slop_os.RIGHT_DUPLICATE) == 0 || cast[u32](rights) & ~held != 0 {
        return .Error(.MissingRight)
    }
    made :: install(per_cpu().kernel, &process.table, found.object, found.generation, found.kind, rights, false)?
    if found.kind == .Memory {
        hold_memory(found.object, found.generation)
    }
    return .Ok(made)
}

/**
 * Describe a handle in the caller's table; no right is needed.
 *
 * @param thread The calling thread, whose process's table it's in.
 * @param handle The handle, of any kind.
 * @return The kind of object it's to, and the rights it has.
 * @error InvalidHandle Not a handle in the caller's table, or one already closed.
 * @error ObjectGone The object was destroyed.
 */
sys_handle_info :: fn(thread: ptr[mut Thread], handle: slop_os.Handle) -> Result[slop_os.HandleInfo, slop_os.HandleError] {
    found :: lookup(&process_of(thread).table, handle)?
    return .Ok(slop_os.HandleInfo.{kind = found.kind, rights = found.rights})
}

/**
 * Find the object a handle in process's table refers to, if it's of kind and has every right in rights, with its error
 * as the call's: they share HandleError's tags.
 *
 * Reads the table without its lock. The object is live when it's looked up, and its memory stays until this CPU passes
 * a quiescent point, though it may be destroyed meanwhile.
 *
 * @tparam E The call's error type, which shares HandleError's tags for the errors it returns.
 * @param process The process whose table the handle is in.
 * @param handle The handle, as the caller passed it, untrusted.
 * @param kind The kind of object it has to be.
 * @param rights The rights it has to have, each of them; none for no right.
 * @return The object's address; or InvalidHandle if the handle isn't in the table or is closed, ObjectGone if the
 *     object was destroyed, WrongKind if it isn't of kind, or MissingRight if the handle lacks one of rights.
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

/**
 * Convert a handle error to a call's own error type: every error type shares HandleError's tags.
 *
 * @tparam E The call's error type.
 * @param error What a handle lookup or install failed with.
 * @return The same tag, as E.
 */
converted :: fn[E](error: slop_os.HandleError) -> E {
    return cast[E](cast[u32](error))
}

/**
 * Find what a handle in process's table refers to, of any kind and with any rights, with its error as the call's.
 *
 * @tparam E The call's error type, which shares HandleError's tags.
 * @param process The process whose table the handle is in.
 * @param handle The handle, as the caller passed it, untrusted.
 * @return The object, its generation, kind and rights, and whether the handle owns it; or InvalidHandle if the handle
 *     isn't in the table or is closed, or ObjectGone if the object was destroyed.
 */
found_of :: fn[E](process: ptr[mut Process], handle: slop_os.Handle) -> Result[Resolved, E] {
    match lookup(&process.table, handle) {
        case Ok(found) => return .Ok(found)
        case Error(error) => return .Error(converted[E](error))
    }
}

/**
 * Install an owning handle in process's table to an object just made, which it owns, and if it's a thread, start it.
 * Without room for the handle, the object is destroyed.
 *
 * @tparam E The call's error type, which shares HandleError's tags.
 * @param kernel The kernel: the handle table's new pages come from its frames, a thread is started on its run queues,
 *     and an object without a handle is destroyed through it.
 * @param process The process to hold the handle, which the object belongs to.
 * @param object The new object's address; the caller hands it over, and mustn't use it after an error.
 * @param start Whether the object is a thread to start once its handle is installed.
 * @return The handle, with every right; or ObjectGone if the table is closed as process is being destroyed, TableFull
 *     if it has no room, or BudgetExceeded or OutOfMemory if another page of it couldn't be paid for or had.
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

/**
 * Find the memory budget a handle names, to pay for what a call makes (decisions/0011, 0054).
 *
 * @tparam E The call's error type, which shares HandleError's tags.
 * @param process The calling process, whose table the handle is in.
 * @param budget The handle, which needs RIGHT_BUDGET_CHARGE.
 * @return The MemoryBudget's address, for the object's charges; or InvalidHandle if the handle isn't in the table,
 *     ObjectGone if the budget was destroyed, WrongKind if it isn't a memory budget's, or MissingRight if it lacks
 *     RIGHT_BUDGET_CHARGE.
 */
paying_budget :: fn[E](process: ptr[mut Process], budget: slop_os.MemoryBudget) -> Result[u64, E] {
    return object_of[E](process, cast[slop_os.Handle](budget), slop_os.ObjectKind.MemoryBudget, slop_os.RIGHT_BUDGET_CHARGE)
}

/**
 * Tell what an object failing to be made means to the caller.
 *
 * @param error Why new_object or adopt failed.
 * @return OutOfMemory or BudgetExceeded as error says, or ObjectGone for OwnerGone: the caller's process is being
 *     destroyed.
 */
object_failure :: fn(error: ObjectError) -> slop_os.HandleError {
    if error == .OutOfMemory {
        return .OutOfMemory
    }
    return if error == .BudgetExceeded { slop_os.HandleError.BudgetExceeded } else { slop_os.HandleError.ObjectGone }
}

// ---- Threads, processes, address spaces

/**
 * End the calling thread, which raises its SIGNAL_TERMINATED; the call never returns to it.
 *
 * The thread is destroyed at once, while it's still the CPU's current one; the scheduler drops it after.
 *
 * @param thread The calling thread, the CPU's current one, destroyed here; it never runs again.
 */
sys_thread_exit :: fn(thread: ptr[mut Thread]) {
    _ = destroy_object(per_cpu().kernel, cast[u64](thread))
}

/**
 * Make a thread in an address space, owned by the caller's process, and start it.
 *
 * The thread starts in user mode without extended vector state. It's started only once its handle is installed, and
 * destroyed if it can't be.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param budget The memory budget that pays for the thread, which needs RIGHT_BUDGET_CHARGE.
 * @param space Where it runs, which needs RIGHT_SPACE_THREADS.
 * @param entry The user virtual address in space it starts at; not checked here, so a bad one faults when it runs.
 * @param stack Its initial stack pointer, a user virtual address in space, likewise unchecked.
 * @param argument A word handed to it in its first argument register.
 * @return An owning handle to the thread, which is ready to run by the time the call returns.
 * @error InvalidHandle The budget or the space isn't a handle in the caller's table.
 * @error ObjectGone The budget or the space was destroyed, the caller's process or the space is being destroyed, or
 *     the caller's table is closed.
 * @error WrongKind The budget or the space is another kind of handle.
 * @error MissingRight A handle lacks its right.
 * @error OutOfMemory No memory for the thread or its vector state, or no frame for a page of the caller's table.
 * @error BudgetExceeded The budget can't pay for the thread, or the caller's for a page of its table.
 * @error TableFull The caller's table has no room.
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

/**
 * Make a process, a child of the caller's, with no threads or address spaces yet.
 *
 * @param thread The calling thread, whose process owns the new one.
 * @param budget The memory budget that pays for the process and becomes its own, which needs RIGHT_BUDGET_CHARGE.
 * @return An owning handle to the process; closing it destroys the process and its subtree.
 * @error InvalidHandle The budget isn't a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind The budget is another kind of handle.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error OutOfMemory No slot for the process, or no frame for a page of the caller's table.
 * @error BudgetExceeded The budget can't pay for the process, or the caller's for a page of its table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Make an empty address space, owned by the caller's process.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param budget The memory budget that pays for it and its page tables, which needs RIGHT_BUDGET_CHARGE.
 * @return An owning handle to the address space.
 * @error InvalidHandle The budget isn't a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind The budget is another kind of handle.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error OutOfMemory No slot, no frame for its top-level table, no address space tag free, or no frame for a page of
 *     the caller's table.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Read the monotonic clock (clock.hsc), which never goes back.
 *
 * @param thread The calling thread; unused.
 * @return The time in nanoseconds. It always succeeds.
 */
sys_clock_monotonic :: fn(thread: ptr[mut Thread]) -> Result[u64, slop_os.HandleError] {
    return .Ok(cast[u64](kernel_monotonic(cast[mut rawptr](per_cpu().kernel))))
}

// ---- Ports

/**
 * Make a port, owned by the caller's process.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param budget The memory budget that pays for the port and its bindings, which needs RIGHT_BUDGET_CHARGE.
 * @return An owning handle to the port, with every right.
 * @error InvalidHandle The budget isn't a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind The budget is another kind of handle.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error OutOfMemory No slot for the port, or no frame for a page of the caller's table.
 * @error BudgetExceeded The budget can't pay for the port, or the caller's for a page of its table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Find the port a handle in the caller's table refers to, if the handle has right.
 *
 * @param thread The calling thread, whose process's table the handle is in.
 * @param port The port's handle, as the caller passed it, untrusted.
 * @param right The right it needs: RIGHT_PORT_BIND or RIGHT_PORT_WAIT.
 * @return The port, live when it was looked up; it may be destroyed meanwhile, and its memory stays until this CPU
 *     passes a quiescent point.
 * @error InvalidHandle Not a handle in the caller's table, or one already closed.
 * @error ObjectGone The port was destroyed.
 * @error WrongKind Not a port's handle.
 * @error MissingRight The handle lacks right.
 */
port_of :: fn(thread: ptr[mut Thread], port: slop_os.Port, right: slop_os.Rights) -> Result[ptr[mut Port], slop_os.PortError] {
    object :: object_of[slop_os.PortError](process_of(thread), cast[slop_os.Handle](port), slop_os.ObjectKind.Port, right)?
    return .Ok(cast[ptr[mut Port]](object))
}

/**
 * Turn a port operation's outcome into a call's result.
 *
 * @param error The operation's error, or null if it succeeded.
 * @return Ok for null, or Error with that error, whichever variant it is.
 */
port_done :: fn(error: slop_os.PortError?) -> Result[void, slop_os.PortError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

/**
 * Bind a key on a port to a wake binding, for port_wake to raise.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param port The port, which needs RIGHT_PORT_BIND.
 * @param key The key, any value not bound on the port already.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The port was destroyed, or is being.
 * @error WrongKind Not a port's handle.
 * @error MissingRight The handle lacks RIGHT_PORT_BIND.
 * @error KeyInUse The key is bound already.
 * @error BudgetExceeded The port's budget can't pay for the binding.
 * @error OutOfMemory No slot for the binding, or no room in the port's map.
 */
sys_port_bind_wake :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_bind_wake(per_cpu().kernel, found, key))
}

/**
 * Raise bits on a wake binding: queue its User packet, or OR the bits into the one already queued.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param port The port, which needs RIGHT_PORT_BIND.
 * @param key A key port_bind_wake bound.
 * @param bits Bits for the packet's data[0], ORed with any raised since it was last taken.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The port was destroyed, or is being.
 * @error WrongKind Not a port's handle.
 * @error MissingRight The handle lacks RIGHT_PORT_BIND.
 * @error NoSuchKey No wake binding has the key.
 */
sys_port_wake :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64, bits: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_wake(per_cpu().kernel, found, key, bits))
}

/**
 * Set a timer on a port: a Timer packet for key when the monotonic clock reaches deadline, binding key if it isn't
 * yet, and moving the deadline if it's a timer already.
 *
 * @param thread The calling thread; the timer is armed on its CPU.
 * @param port The port, which needs RIGHT_PORT_BIND.
 * @param key Any value the caller picks: the Timer packet carries it, and it names the binding for later calls such as
 *     port_unbind.
 * @param deadline When, in monotonic nanoseconds; one that has passed fires at once.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The port was destroyed, or is being.
 * @error WrongKind Not a port's handle.
 * @error MissingRight The handle lacks RIGHT_PORT_BIND.
 * @error KeyInUse The key is bound to something other than a timer.
 * @error BudgetExceeded The port's budget can't pay for a new binding.
 * @error OutOfMemory No slot for a new binding, or no memory to arm the timer.
 */
sys_port_set_timer :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64, deadline: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_set_timer(per_cpu().kernel, found, key, deadline))
}

/**
 * Remove a binding of any kind from a port, with its packet if one is queued and its timer if it's armed.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param port The port, which needs RIGHT_PORT_BIND.
 * @param key The key the binding was made with; any value, and one no binding has gives NoSuchKey.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The port was destroyed, or is being.
 * @error WrongKind Not a port's handle.
 * @error MissingRight The handle lacks RIGHT_PORT_BIND.
 * @error NoSuchKey No binding has the key.
 */
sys_port_unbind :: fn(thread: ptr[mut Thread], port: slop_os.Port, key: u64) -> Result[void, slop_os.PortError] {
    found :: port_of(thread, port, slop_os.RIGHT_PORT_BIND)?
    return port_done(port_unbind(per_cpu().kernel, found, key))
}

/**
 * Wait for packets on a port, taking those queued: at once if there are any, or else blocking until one comes or the
 * deadline does.
 *
 * @param thread The calling thread, which may leave its CPU here; its result is then written when the wait is over.
 * @param port The port, which needs RIGHT_PORT_WAIT.
 * @param packets Where packets go in the caller's memory: at most slop_os.MAX_PACKETS_PER_WAIT of them, however big it
 *     is; empty, the call returns 0 at once.
 * @param deadline When to give up, in monotonic nanoseconds, or slop_os.NO_DEADLINE to wait for as long as it takes.
 * @return How many packets were written at the start of packets: at least 1, or 0 when the deadline came first. When
 *     the thread blocks, the 0 returned here isn't written; complete_wait writes the result.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The port was destroyed, or is being, before or during the wait.
 * @error WrongKind Not a port's handle.
 * @error MissingRight The handle lacks RIGHT_PORT_WAIT.
 * @error BadBuffer The packets aren't mapped writable user memory; packets taken when writing them failed are lost.
 */
sys_port_wait :: fn(thread: ptr[mut Thread], port: slop_os.Port, packets: slop_os.UserBuffer, deadline: u64) -> Result[u32, slop_os.PortError] {
    kernel :: per_cpu().kernel
    found :: port_of(thread, port, slop_os.RIGHT_PORT_WAIT)?
    return wait_result[slop_os.PortError](port_wait_begin(kernel, thread, found, packets.address, cast[u32](min_u64(packets.count, 0xffffffff)),
        ticks_at(kernel, deadline)))
}

/**
 * Turn a wait's outcome into a call's result; if the thread blocked, its result is written when the wait is over.
 *
 * @tparam E The call's error type, which shares PortError's tags.
 * @param outcome What port_wait_begin came to.
 * @return How many packets were taken: 0 when the deadline passed, or when the thread blocked, which isn't written;
 *     or ObjectGone if the port was destroyed, or BadBuffer if the packets aren't writable user memory.
 */
wait_result :: fn[E](outcome: WaitOutcome) -> Result[u32, E] {
    match outcome {
        case Done(taken) => return .Ok(taken)
        case Failed(error) => return .Error(cast[E](cast[u32](error)))
        case Blocked => return .Ok(0)
    }
}

/**
 * Bind an object's events to a port: a Signal packet for key when the object raises any of signals, or an Irq packet
 * for an IRQ's interrupts.
 *
 * Channel ends, processes, threads, devices and memory budgets raise Signal packets; a budget's holder, who may charge
 * it, watches it for pressure (decisions/0111).
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param port The port, which needs RIGHT_PORT_BIND.
 * @param object What to watch: a channel end, a process (which needs RIGHT_PROCESS_INSPECT), a thread, an IRQ, a
 *     Device, a memory budget (which needs RIGHT_BUDGET_CHARGE), or a memory object, through its owning handle, for
 *     SIGNAL_UNHELD (decisions/0178); the others need no right.
 * @param signals The slop_os.SIGNAL_ bits to see; ignored for an IRQ.
 * @param key The binding's key, which its packets carry: one not bound on the port, or one bound to this same object.
 * @param mode Once, disarmed once its packet is queued; any other value is Persistent.
 * @error InvalidHandle The port or the object isn't a handle in the caller's table.
 * @error ObjectGone The port or the object was destroyed, or is being.
 * @error WrongKind The port isn't a port's handle, or the object is one no port can watch.
 * @error MissingRight The port lacks RIGHT_PORT_BIND, or the object the right its kind needs, or for memory, isn't its
 *     owning handle.
 * @error KeyInUse The key is bound to something else.
 * @error TooManyBindings The object has as many bindings as it takes.
 * @error BudgetExceeded The port's budget can't pay for the binding.
 * @error OutOfMemory No slot for the binding, or no room in the port's map.
 */
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
    // A budget's holder, who may charge it, watches it for pressure (decisions/0111)
    if found.kind == .MemoryBudget {
        if cast[u32](found.rights) & cast[u32](slop_os.RIGHT_BUDGET_CHARGE) == 0 {
            return .Error(.MissingRight)
        }
        watched :: cast[ptr[mut MemoryBudget]](found.object)
        return port_done(watch_bind(kernel, found_port, found.object, &watched.watchers, &watched.watch_lock, .Watchers, signals, key, once))
    }
    // Its owner watches it for no one else holding it (decisions/0178)
    if found.kind == .Memory {
        if !found.owning {
            return .Error(.MissingRight)
        }
        watched :: cast[ptr[mut Memory]](found.object)
        return port_done(watch_bind(kernel, found_port, found.object, &watched.watchers, &watched.watch_lock, .Watchers, signals, key, once))
    }
    if found.kind != .Channel {
        return .Error(.WrongKind)
    }
    return port_done(port_bind(kernel, found_port, cast[ptr[mut Channel]](found.object), signals, key, once))
}

// ---- Channels

/**
 * Find the channel end a handle in the caller's table refers to, if the handle has every right in rights.
 *
 * @param thread The calling thread, whose process's table the handle is in.
 * @param end The end's handle, as the caller passed it, untrusted.
 * @param rights The rights it needs, none for most calls.
 * @return The end, live when it was looked up; it may be destroyed meanwhile, and its memory stays until this CPU
 *     passes a quiescent point.
 * @error InvalidHandle Not a handle in the caller's table, or one already closed.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 * @error MissingRight The handle lacks one of rights.
 */
end_of :: fn(thread: ptr[mut Thread], end: slop_os.Channel, rights: slop_os.Rights) -> Result[ptr[mut Channel], slop_os.ChannelError] {
    object :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](end), slop_os.ObjectKind.Channel, rights)?
    return .Ok(cast[ptr[mut Channel]](object))
}

/**
 * Turn a channel operation's outcome into a call's result.
 *
 * @param error The operation's error, or null if it succeeded.
 * @return Ok for null, or Error with that error, whichever variant it is.
 */
channel_done :: fn(error: slop_os.ChannelError?) -> Result[void, slop_os.ChannelError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

/**
 * Make a channel, with owning handles to both ends in the caller's process; without room for them, it's destroyed.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param budget The memory budget that pays for the channel and its rings, which needs RIGHT_BUDGET_CHARGE.
 * @param ring_bytes Each ring's size in bytes: a power of two from slop_os.CHANNEL_MIN_RING to
 *     slop_os.CHANNEL_MAX_RING, or 0 for slop_os.CHANNEL_DEFAULT_RING.
 * @param tag The protocol the channel speaks, which channel_tag tells either end's holder, or 0 for none.
 * @return Owning handles to both ends, with every right.
 * @error InvalidHandle The budget isn't a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind The budget is another kind of handle.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error InvalidSize ring_bytes isn't 0 or a power of two in range.
 * @error BudgetExceeded The budget can't pay for the channel, or the caller's for a page of its table.
 * @error OutOfMemory No slot, core or ring memory, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room for both handles.
 */
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

/**
 * Map a channel's memory, its indices and both rings, in an address space, read/write, for the end's holder to read and
 * write its rings directly.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param end The end, which needs RIGHT_CHANNEL_MAP; one end is mapped once at a time.
 * @param space Where, which needs RIGHT_SPACE_MAP.
 * @param address A page-aligned user virtual address with slop_os.channel_memory_size(ring_bytes) bytes free from it.
 * @error InvalidHandle The end or the space isn't a handle in the caller's table.
 * @error ObjectGone The end or the space was destroyed, or is being.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The end lacks RIGHT_CHANNEL_MAP, or the space RIGHT_SPACE_MAP.
 * @error BadAddress Not a page-aligned user address range, or something is mapped there.
 * @error Mapped The end is mapped already, or being mapped or unmapped.
 * @error InFlight The end is in a handle batch on its way.
 * @error OutOfMemory No frame for a page table.
 * @error BudgetExceeded The space's budget can't pay for a page table.
 */
sys_channel_map :: fn(thread: ptr[mut Thread], end: slop_os.Channel, space: slop_os.AddressSpace, address: u64) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, slop_os.RIGHT_CHANNEL_MAP)?
    target :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_MAP)?
    return channel_done(channel_map(per_cpu().kernel, found, cast[ptr[mut AddressSpace]](target), address))
}

/**
 * Unmap what channel_map mapped for an end.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param end The end; no right is needed.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 * @error BadAddress The end isn't mapped, or is being mapped or unmapped.
 */
sys_channel_unmap :: fn(thread: ptr[mut Thread], end: slop_os.Channel) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_unmap(per_cpu().kernel, found))
}

/**
 * Raise Readable, Writable or both on the other end, after writing or reading its ring directly: the doorbell of the
 * rings' wake protocol (knowledge/design/ipc.md §2).
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param end The caller's end; no right is needed.
 * @param signals slop_os.SIGNAL_READABLE, slop_os.SIGNAL_WRITABLE, or both; other bits are ignored.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 * @error PeerClosed The other end is closed.
 */
sys_channel_notify :: fn(thread: ptr[mut Thread], end: slop_os.Channel, signals: slop_os.Signals) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_notify(per_cpu().kernel, found, signals))
}

/**
 * Write one message into the end's ring through the kernel, for a holder that hasn't mapped it, raising Readable on the
 * other end if its reader waits.
 *
 * @param thread The calling thread, which doesn't block here: the end is looked up in its process's table, and the
 *     payload is copied from its address space.
 * @param end The caller's end; no right is needed.
 * @param payload The message's bytes in the caller's memory, copied; a count past 2^32 - 1 is taken as that.
 * @param batch The handle batch channel_send_handles filled for this message, or slop_os.NO_BATCH for none.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 * @error TooBig The payload is bigger than channel_max_payload of the ring's size.
 * @error NoSuchBatch A batch number of slop_os.HANDLE_BATCHES or more that isn't NO_BATCH.
 * @error PeerClosed The other end is closed.
 * @error Corrupt The ring's indices are impossible: the other end broke them.
 * @error Full The ring has no room for the message now; wait for Writable.
 * @error BadBuffer The payload isn't mapped readable user memory.
 */
sys_channel_write :: fn(thread: ptr[mut Thread], end: slop_os.Channel, payload: slop_os.UserBuffer, batch: u32) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_write(per_cpu().kernel, thread, found, payload.address, cast[u32](min_u64(payload.count, 0xffffffff)), batch))
}

/**
 * Read the next message from the other end's ring through the kernel, for a holder that hasn't mapped it, raising
 * Writable on the other end if its writer waits for room.
 *
 * @param thread The calling thread, which doesn't block here: the end is looked up in its process's table, and the
 *     payload and size are written to its address space.
 * @param end The caller's end; no right is needed.
 * @param buffer Where the payload goes in the caller's memory; a count past 2^32 - 1 is taken as that.
 * @param size A user virtual address where the message's size in bytes is written too, as a u32, also when buffer is
 *     too small; 0 for nowhere.
 * @return The message's size in bytes, and its header's flags with its batch's number at bit 16.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 * @error Empty No message is waiting, and the other end is open.
 * @error PeerClosed No message is waiting, and the other end is closed, so none will come.
 * @error Corrupt The ring's indices or the message's header are impossible.
 * @error BufferTooSmall The message doesn't fit in buffer; it stays in the ring, and its size is at size.
 * @error BadBuffer The buffer isn't mapped writable user memory, when the message stays; or size isn't, after the
 *     message was read, when it's consumed.
 */
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

/**
 * Write a u32 to an address in the caller's memory, if there's an address.
 *
 * @param kernel The kernel, for the direct map the write goes through; the space's lock is taken.
 * @param thread The calling thread, into whose address space it's written.
 * @param address A user virtual address, any alignment, or 0 for nowhere.
 * @param value What to write: 4 bytes, in the CPU's byte order.
 * @return True if it was written, or address is 0; false if the 4 bytes there aren't writable user memory.
 */
tell :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], address: u64, value: u32) -> bool {
    kept :: value
    return address == 0 || copy_to_user(kernel, thread.space, address, cast[u64](&kept), 4)
}

/**
 * Move handles out of the caller's table into a handle batch on the other end, for the message that names it to
 * carry (knowledge/design/ipc.md, Handle transfer).
 *
 * @param thread The calling thread, which doesn't block here: the handles are read from its address space and moved out
 *     of its process's table.
 * @param end The caller's end; no right is needed.
 * @param handles The handles in the caller's memory, at most slop_os.MAX_HANDLES_PER_BATCH, each with RIGHT_TRANSFER.
 *     Once the call returns Ok they're no longer the caller's.
 * @param batch Which batch on the other end, below slop_os.HANDLE_BATCHES, not in use already.
 * @error InvalidHandle The end, or one of the handles, isn't a handle in the caller's table.
 * @error ObjectGone The end, or one of the handles' objects, was destroyed.
 * @error WrongKind The end isn't a channel end's handle.
 * @error MissingRight A handle lacks RIGHT_TRANSFER.
 * @error TooBig More than slop_os.MAX_HANDLES_PER_BATCH handles.
 * @error NoSuchBatch A batch number of slop_os.HANDLE_BATCHES or more.
 * @error BadBuffer The handles aren't readable user memory.
 * @error NotTransferable A handle is to one of this channel's own ends.
 * @error BudgetExceeded The end's budget can't pay for the batch.
 * @error OutOfMemory No memory for the batch.
 * @error PeerClosed The other end is closed; if it closed after the handles were moved, they're gone.
 * @error BatchInUse The batch is in use.
 * @error Mapped A handle is to a channel end whose rings are mapped.
 */
sys_channel_send_handles :: fn(thread: ptr[mut Thread], end: slop_os.Channel, handles: slop_os.UserBuffer, batch: u32) -> Result[void, slop_os.ChannelError] {
    found :: end_of(thread, end, cast[slop_os.Rights](0))?
    return channel_done(channel_send_handles(per_cpu().kernel, thread, found, handles.address, cast[u32](min_u64(handles.count, 0xffffffff)), batch))
}

/**
 * Take a batch the other end sent into the caller's table, the caller's budget taking over their objects' charges
 * (decisions/0011).
 *
 * @param thread The calling thread, which doesn't block here: the handles go into its process's table, the objects'
 *     charges to its process's budget, and the values to its address space.
 * @param end The caller's end; no right is needed.
 * @param batch The batch a message named, below slop_os.HANDLE_BATCHES.
 * @param handles Where the new handles are written in the caller's memory, in the order they were sent, NO_HANDLE for
 *     one that couldn't be had.
 * @param count A user virtual address where how many the batch has is written too, as a u32, also when handles is too
 *     small; 0 for nowhere.
 * @return How many handles it took.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 * @error NoSuchBatch No batch of that number is waiting to be taken.
 * @error BufferTooSmall The handles can't hold the batch; it stays, and how many it has is at count.
 * @error BudgetExceeded The caller's budget can't take over the objects' charges; the batch stays.
 * @error BadBuffer The handles aren't writable user memory, when the batch stays; or writing them or count failed
 *     after they were taken.
 */
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

/**
 * Raise signals on the other end as channel_notify does, then wait on a port as port_wait does, in one call: a thread
 * the notify wakes is made ready on this CPU, to run here once the caller waits (knowledge/design/ipc.md §5).
 *
 * @param thread The calling thread, which may leave its CPU here; its result is then written when the wait is over.
 * @param end The caller's end; no right is needed.
 * @param signals What to raise on the other end, as channel_notify's.
 * @param port The port to wait on, which needs RIGHT_PORT_WAIT.
 * @param packets Where packets go in the caller's memory, as port_wait's.
 * @param deadline When to give up, in monotonic nanoseconds, as port_wait's.
 * @return How many packets were written, as port_wait's.
 * @error InvalidHandle The end or the port isn't a handle in the caller's table.
 * @error ObjectGone The end or the port was destroyed, or the port was during the wait.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The port lacks RIGHT_PORT_WAIT.
 * @error PeerClosed The other end is closed; nothing is waited for.
 * @error BadBuffer The packets aren't writable user memory.
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

/**
 * Turn a memory operation's outcome into a call's result.
 *
 * @param error The operation's error, or null if it succeeded.
 * @return Ok for null, or Error with that error, whichever variant it is.
 */
memory_done :: fn(error: slop_os.MemoryError?) -> Result[void, slop_os.MemoryError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

/**
 * Make a child memory budget, carved out of a budget: the child's whole limit is charged to its parent at once.
 *
 * @param thread The calling thread, whose process owns the child.
 * @param budget The parent budget, which pays for the child and needs RIGHT_BUDGET_CHARGE.
 * @param limit The most the child can charge, in bytes; it's charged to the parent with the child's slot.
 * @return An owning handle to the child.
 * @error InvalidHandle The budget isn't a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind The budget is another kind of handle.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error OutOfMemory No slot for the child, or no frame for a page of the caller's table.
 * @error BudgetExceeded The parent can't pay for the child's slot and limit, or the caller's budget for a page of its
 *     table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Describe a memory budget; no right is needed.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param budget The budget's handle, of any rights.
 * @return Its limit, and how much of it is charged, in bytes.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The budget was destroyed.
 * @error WrongKind Not a memory budget's handle.
 */
sys_memory_budget_info :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget) -> Result[slop_os.BudgetInfo, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.MemoryBudget, cast[slop_os.Rights](0))
       ?
    limit, used :: budget_info(cast[ptr[mut MemoryBudget]](object))
    return .Ok(slop_os.BudgetInfo.{limit = limit, used = used})
}

/**
 * Set a memory budget's pressure threshold (decisions/0111): SIGNAL_PRESSURE is raised as what it has charged reaches
 * it, and at once if it's there already. The budget's holder, who may charge it, sets it.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param budget The budget, which needs RIGHT_BUDGET_CHARGE.
 * @param threshold In bytes, or 0 for none.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The budget was destroyed.
 * @error WrongKind Not a memory budget's handle.
 * @error MissingRight The handle lacks RIGHT_BUDGET_CHARGE.
 */
sys_memory_budget_set_threshold :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, threshold: u64) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.MemoryBudget,
        slop_os.RIGHT_BUDGET_CHARGE)?
    set_threshold(cast[ptr[mut MemoryBudget]](object), threshold)
    return .Ok
}

/**
 * Make a memory object, its pages zero-filled as they're touched, owned by the caller's process; its whole size is
 * charged to the budget at once.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @return An owning handle to it, with every right.
 * @error InvalidHandle The budget isn't a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind The budget is another kind of handle.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error InvalidSize The size isn't a whole number of pages, is 0, or is more than slop_os.MAX_MEMORY_SIZE.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot or page list for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
sys_memory_create :: fn(thread: ptr[mut Thread], budget: slop_os.MemoryBudget, size: u64) -> Result[slop_os.Memory, slop_os.MemoryError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    paying :: paying_budget[slop_os.MemoryError](process, budget)?
    made :: create_memory(kernel, cast[u64](process), paying, size)?
    handle :: owning_handle[slop_os.MemoryError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Memory](handle))
}

/**
 * Tell what protocol a channel speaks; no right is needed.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param end Either end.
 * @return The tag the channel was made with, 0 for none.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The end was destroyed.
 * @error WrongKind Not a channel end's handle.
 */
sys_channel_tag :: fn(thread: ptr[mut Thread], end: slop_os.Channel) -> Result[u64, slop_os.ChannelError] {
    object :: object_of[slop_os.ChannelError](process_of(thread), cast[slop_os.Handle](end), slop_os.ObjectKind.Channel, cast[slop_os.Rights](0))?
    return .Ok(core_of(cast[ptr[Channel]](object)).tag)
}

/**
 * Tell how big a memory object is; no right is needed.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The memory's handle, of any rights.
 * @return Its size in bytes, a whole number of pages.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle.
 */
sys_memory_size :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, cast[slop_os.Rights](0))?
    return .Ok(cast[ptr[Memory]](object).size)
}

/**
 * Map part of a memory object in an address space; nothing is mapped until it's touched.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The memory, which needs RIGHT_MEMORY_READ, and RIGHT_MEMORY_WRITE or RIGHT_MEMORY_EXECUTE when
 *     protection asks for them.
 * @param space Where, which needs RIGHT_SPACE_MAP.
 * @param address A page-aligned user virtual address with size bytes free from it.
 * @param offset Where in the memory the mapping starts, in bytes, a whole number of pages.
 * @param size How many bytes, a whole number of pages, at least one, within the memory.
 * @param protection slop_os.PROTECTION_ bits: readable, and writable or executable but not both.
 * @error InvalidHandle The memory or the space isn't a handle in the caller's table.
 * @error ObjectGone The memory or the space was destroyed, or is being.
 * @error WrongKind A handle of another kind.
 * @error MissingRight A handle lacks a right protection needs, or a window doesn't allow it.
 * @error BadProtection Writable and executable at once, no access at all, or bits that aren't protections.
 * @error InvalidSize The size or offset isn't a whole number of pages, or runs past the memory's end.
 * @error BadAddress Not a page-aligned user address range, or it overlaps a mapping.
 * @error BudgetExceeded The space's budget can't pay for the mapping.
 * @error OutOfMemory No slot for the mapping.
 */
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

/**
 * Make a memory object whose pages its pager supplies (decisions/0094), owned by the caller's process: a touch of one
 * that isn't there yet waits, and raises key's wake binding on port.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param budget The memory budget that pays for it and, as they're supplied, its pages; needs RIGHT_BUDGET_CHARGE.
 * @param port The pager's port, which needs RIGHT_PORT_BIND.
 * @param key A wake binding on port.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @return An owning handle to the memory.
 * @error InvalidHandle The budget or the port isn't a handle in the caller's table.
 * @error ObjectGone The budget or the port was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The port lacks RIGHT_PORT_BIND, or the budget RIGHT_BUDGET_CHARGE.
 * @error NoPager The port has no wake binding with that key, or is being destroyed.
 * @error InvalidSize Not a whole number of pages, none, or more than slop_os.MAX_MEMORY_SIZE.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot or page list for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Ask which page of paged memory a touch is waiting for, each reported once. Only a handle that may write the memory
 * asks.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The paged memory, which needs RIGHT_MEMORY_WRITE.
 * @return The page's offset in bytes.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle.
 * @error MissingRight The handle lacks RIGHT_MEMORY_WRITE.
 * @error NotPaged Not paged memory.
 * @error NothingWanted No page is waited for that hasn't been reported.
 */
sys_memory_page_wanted :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    return page_wanted(cast[ptr[mut Memory]](found))
}

/**
 * Supply a page of paged memory, copied from a page of another memory object, and wake whoever waited for it.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The paged memory, which needs RIGHT_MEMORY_WRITE.
 * @param offset The page's offset in memory, in bytes, a whole number of pages.
 * @param source Where it's copied from, which needs RIGHT_MEMORY_READ.
 * @param source_offset The page's offset in source, in bytes, a whole number of pages.
 * @error InvalidHandle The memory or the source isn't a handle in the caller's table.
 * @error ObjectGone The memory or the source was destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The memory lacks RIGHT_MEMORY_WRITE, or the source RIGHT_MEMORY_READ.
 * @error NotPaged The memory isn't paged memory.
 * @error InvalidSize An offset that isn't a whole number of pages, or past its memory's end.
 * @error OutOfMemory No frame for the page.
 * @error BudgetExceeded The memory's budget can't pay for the page.
 */
sys_memory_supply :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64, source: slop_os.Memory, source_offset: u64)
    -> Result[void, slop_os.MemoryError] {
    process :: process_of(thread)
    found :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    from :: object_of[slop_os.MemoryError](process, cast[slop_os.Handle](source), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_READ)?
    return memory_done(supply_page(per_cpu().kernel, cast[ptr[mut Memory]](found), offset, cast[ptr[Memory]](from), source_offset))
}

/**
 * Give back a page of paged memory: unmapped everywhere, its frame freed and its charge returned, so the next touch
 * waits for its pager again. Only a handle that may write the memory gives its pages back.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The paged memory, which needs RIGHT_MEMORY_WRITE.
 * @param offset The page's offset in bytes.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle.
 * @error MissingRight The handle lacks RIGHT_MEMORY_WRITE.
 * @error NotPaged Not paged memory.
 * @error InvalidSize The offset is past the memory's end.
 * @error MappedWidely More address spaces map the page than one call takes it from.
 * @error NotSupplied The page isn't there.
 */
sys_memory_evict :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64) -> Result[void, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    return memory_done(evict_page(per_cpu().kernel, cast[ptr[mut Memory]](found), offset))
}

/**
 * Ask whether a page of paged memory was touched since the last time this asked, through any mapping, clearing the
 * marks that say so. Only a handle that may write the memory asks.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The paged memory, which needs RIGHT_MEMORY_WRITE.
 * @param offset The page's offset in bytes.
 * @return 1 if it was touched, 0 if it wasn't; always 0 where the hardware doesn't keep the marks.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle.
 * @error MissingRight The handle lacks RIGHT_MEMORY_WRITE.
 * @error NotPaged Not paged memory.
 * @error InvalidSize The offset is past the memory's end.
 */
sys_memory_page_accessed :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64) -> Result[u64, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    return page_accessed(per_cpu().kernel, cast[ptr[mut Memory]](found), offset)
}

/**
 * Count who holds a memory object besides its owner (decisions/0178): handles to it that aren't the owning one, in any
 * table or on their way in a channel's batch, its mappings, and its windows.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handle is looked up.
 * @param memory The memory, its owning handle.
 * @return How many hold it, read atomically: a moment's count, which a holder made or let go of later changes.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle.
 * @error MissingRight Not the owning handle: only its owner asks.
 */
sys_memory_holders :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.MemoryError] {
    found :: found_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory))?
    if found.kind != .Memory {
        return .Error(.WrongKind)
    }
    if !found.owning {
        return .Error(.MissingRight)
    }
    return .Ok(intrinsics.atomic_load_u64(&cast[ptr[mut Memory]](found.object).held))
}

/**
 * Copy bytes of anonymous memory into the caller's buffer, through the kernel, with no mapping (decisions/0098).
 *
 * @param thread The calling thread, into whose memory they're copied.
 * @param memory The memory, which needs RIGHT_MEMORY_READ.
 * @param offset Where in it to start, in bytes; any offset.
 * @param buffer Where the bytes go in the caller's memory; it's filled.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle, or not anonymous memory: device, paged, DMA memory, or a window.
 * @error MissingRight The handle lacks RIGHT_MEMORY_READ.
 * @error InvalidSize The range runs past the memory's end.
 * @error OutOfMemory No frame for a page of the memory not yet touched.
 * @error BadAddress The buffer isn't writable user memory.
 */
sys_memory_read :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64, buffer: slop_os.UserBuffer)
    -> Result[void, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_READ)?
    return memory_done(copy_memory(per_cpu().kernel, cast[ptr[Memory]](found), offset, thread.space, buffer.address, buffer.count, true))
}

/**
 * Copy bytes from the caller's memory into anonymous memory, through the kernel, with no mapping.
 *
 * @param thread The calling thread, from whose memory they're copied.
 * @param memory The memory, which needs RIGHT_MEMORY_WRITE.
 * @param offset Where in it to start, in bytes; any offset.
 * @param bytes The bytes to write, in the caller's memory.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle, or not anonymous memory: device, paged, DMA memory, or a window.
 * @error MissingRight The handle lacks RIGHT_MEMORY_WRITE.
 * @error InvalidSize The range runs past the memory's end.
 * @error OutOfMemory No frame for a page of the memory not yet touched.
 * @error BadAddress The bytes aren't readable user memory.
 */
sys_memory_write :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64, bytes: slop_os.UserBuffer)
    -> Result[void, slop_os.MemoryError] {
    found :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_WRITE)?
    return memory_done(copy_memory(per_cpu().kernel, cast[ptr[Memory]](found), offset, thread.space, bytes.address, bytes.count, false))
}

/**
 * Unmap the memory mapping that starts at an address, all of it.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param space The address space, which needs RIGHT_SPACE_MAP.
 * @param address The user virtual address a mapping starts at.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The space was destroyed.
 * @error WrongKind Not an address space's handle.
 * @error MissingRight The handle lacks RIGHT_SPACE_MAP.
 * @error NotMapped No mapping starts at that address.
 */
sys_memory_unmap :: fn(thread: ptr[mut Thread], space: slop_os.AddressSpace, address: u64) -> Result[void, slop_os.MemoryError] {
    target :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, slop_os.RIGHT_SPACE_MAP)?
    return memory_done(memory_unmap(per_cpu().kernel, cast[ptr[mut AddressSpace]](target), address))
}

/**
 * Make a window onto part of a memory object, owned by the caller's process: a memory object of its own that maps
 * those pages, which may be mapped only as the memory's handle may be.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param memory The memory; no right is needed, but its RIGHT_MEMORY_ rights limit the window's mappings.
 * @param budget The memory budget that pays for the window's slot, which needs RIGHT_BUDGET_CHARGE.
 * @param offset Where the window starts in the memory, in bytes, a whole number of pages.
 * @param size How many bytes, a whole number of pages, at least one, within the memory.
 * @return An owning handle to the window.
 * @error InvalidHandle The memory or the budget isn't a handle in the caller's table.
 * @error ObjectGone The memory or the budget was destroyed, or the memory or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error InvalidSize The offset or size isn't a whole number of pages, is 0, or runs past the memory's end.
 * @error BudgetExceeded The budget can't pay for the window, or the caller's for a page of its table.
 * @error OutOfMemory No slot for the window, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Find the platform capability a handle names, which device calls take as their authority; no right is needed.
 *
 * @param thread The calling thread, whose process's handle table the platform's handle is looked up in.
 * @param platform The platform's handle, as the caller passed it, untrusted, of any rights.
 * @return The Platform object's address.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The platform was destroyed.
 * @error WrongKind Not the platform's handle.
 */
platform_of :: fn(thread: ptr[mut Thread], platform: slop_os.Platform) -> Result[u64, slop_os.DeviceError] {
    return object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](platform), slop_os.ObjectKind.Platform, cast[slop_os.Rights](0))
}

/**
 * Register an interrupt controller the firmware tables describe, for its lines' IRQs.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param kind What kind of controller.
 * @param registers The physical address of its registers, page-aligned, not in RAM the kernel owns.
 * @return The controller's number, for irq_create, and how many lines it has.
 * @error InvalidHandle The platform isn't a handle in the caller's table.
 * @error ObjectGone The platform was destroyed.
 * @error WrongKind Not the platform's handle.
 * @error NoController A kind the kernel doesn't know, none of that kind there, or none the architecture has.
 * @error BadAddress The registers aren't page-aligned, or are in the kernel's memory.
 * @error TooManyControllers Every controller the kernel takes is registered.
 * @error OutOfMemory The registers couldn't be mapped.
 */
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

/**
 * Make an IRQ for a controller's line, routed and unmasked, owned by the caller's process, for a driver to bind to a
 * port.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param controller A number controller_register gave.
 * @param line The line, below the controller's count of lines.
 * @param flags slop_os.IRQ_LEVEL and slop_os.IRQ_ACTIVE_LOW from the firmware tables, or 0 for edge-triggered and
 *     active-high; other bits are ignored.
 * @return An owning handle to the IRQ, with every right.
 * @error InvalidHandle The platform or the budget isn't a handle in the caller's table.
 * @error ObjectGone The platform or the budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error NoController Wired lines' interrupts are blocked (translation.hsc), as a forged message's would be.
 * @error NoSuchController No controller has that number.
 * @error NoSuchLine The controller has no such line.
 * @error LineInUse The line already has an IRQ.
 * @error NoFreeInterrupt No interrupt vector is free to route it to.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Acknowledge an IRQ's interrupt, unmasking a level-triggered line again once its driver has dealt with it.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param irq The IRQ, which needs RIGHT_IRQ_ACK.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The IRQ was destroyed.
 * @error WrongKind Not an IRQ's handle.
 * @error MissingRight The handle lacks RIGHT_IRQ_ACK.
 */
sys_irq_ack :: fn(thread: ptr[mut Thread], irq: slop_os.Irq) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](irq), slop_os.ObjectKind.Irq, slop_os.RIGHT_IRQ_ACK)?
    irq_ack(per_cpu().kernel, cast[ptr[mut Irq]](object))
    return .Ok
}

/**
 * Make a memory object of device memory at a physical address, owned by the caller's process, to map a device's
 * registers or memory.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param address The physical address, page-aligned, not in RAM the kernel owns.
 * @param size Its size in bytes, a whole number of pages.
 * @param cache How it's cached: Device for registers, WriteCombining or WriteBack.
 * @return An owning handle to the memory.
 * @error InvalidHandle The platform or the budget isn't a handle in the caller's table.
 * @error ObjectGone The platform or the budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error InvalidSize Not a whole number of pages, or a cache mode that isn't one.
 * @error BadAddress Not page-aligned, or memory the kernel owns.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Make a Device for a PCIe function, owned by the caller's process, for its message-signaled interrupts and its DMA
 * domain.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param address The function's address (slop_os.device_address).
 * @param msi_source What the interrupt controller knows its message-signaled interrupts as: on AArch64, the ITS's
 *     device ID; unused on x86-64.
 * @param config The physical address of its 4 KiB of configuration space, where its DMA is turned off when the Device
 *     is destroyed.
 * @return An owning handle to the Device.
 * @error InvalidHandle The platform or the budget isn't a handle in the caller's table.
 * @error ObjectGone The platform or the budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error BadAddress The configuration space isn't page-aligned, or is in the kernel's memory.
 * @error DeviceExists Another Device has that address, or that MSI source where the controller uses sources.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or its configuration space couldn't be mapped, or no frame for a page of the
 *     caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Put a device's DMA in a domain: what an IOMMU will confine it to.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param device The device; no right is needed.
 * @param domain The domain; no right is needed.
 * @error InvalidHandle A handle isn't in the caller's table.
 * @error ObjectGone The platform, the device or the domain was destroyed.
 * @error WrongKind A handle of another kind.
 * @error WrongIommu The device isn't behind the IOMMU the domain's other devices are, or behind none where they're
 *     behind one.
 * @error OutOfMemory No domain ID or translation table could be had.
 * @error BudgetExceeded The domain's budget can't pay for its translation tables.
 */
sys_device_attach :: fn(thread: ptr[mut Thread], platform: slop_os.Platform, device: slop_os.Device, domain: slop_os.DmaDomain)
    -> Result[void, slop_os.DeviceError] {
    process :: process_of(thread)
    _ = platform_of(thread, platform)?
    found :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](device), slop_os.ObjectKind.Device, cast[slop_os.Rights](0))?
    target :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](domain), slop_os.ObjectKind.DmaDomain, cast[slop_os.Rights](0))?
    return attach_device(per_cpu().kernel, cast[ptr[mut Device]](found), cast[ptr[mut DmaDomain]](target))
}

/**
 * Make an IRQ for one of a device's message-signaled interrupts, routed to a CPU the kernel picks, owned by the
 * caller's process.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param device The device; no right is needed.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @return An owning handle to the IRQ; irq_message says what the device writes to raise it.
 * @error InvalidHandle The device or the budget isn't a handle in the caller's table.
 * @error ObjectGone The device or the budget was destroyed, or the device or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error NoMsi No interrupt controller here takes message-signaled interrupts.
 * @error TooManyVectors The device has as many of them as it takes already.
 * @error NoFreeInterrupt No CPU has a device interrupt free.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
sys_irq_create_msi :: fn(thread: ptr[mut Thread], device: slop_os.Device, budget: slop_os.MemoryBudget) -> Result[slop_os.Irq, slop_os.DeviceError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    found :: object_of[slop_os.DeviceError](process, cast[slop_os.Handle](device), slop_os.ObjectKind.Device, cast[slop_os.Rights](0))?
    paying :: paying_budget[slop_os.DeviceError](process, budget)?
    made :: create_msi_irq(kernel, cast[u64](process), paying, cast[ptr[mut Device]](found))?
    handle :: owning_handle[slop_os.DeviceError](kernel, process, cast[u64](made), false)?
    return .Ok(cast[slop_os.Irq](handle))
}

/**
 * Tell what a device writes, and where, to raise a message-signaled IRQ, for its driver to program; a wired line's IRQ
 * has no message.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param irq The IRQ; no right is needed.
 * @return The message's address and data.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The IRQ was destroyed.
 * @error WrongKind Not an IRQ's handle.
 * @error NoMsi The IRQ is a wired line's.
 */
sys_irq_message :: fn(thread: ptr[mut Thread], irq: slop_os.Irq) -> Result[slop_os.MsiMessage, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](irq), slop_os.ObjectKind.Irq, cast[slop_os.Rights](0))?
    found :: cast[ptr[Irq]](object)
    if !found.msi {
        return .Error(.NoMsi)
    }
    return .Ok(slop_os.MsiMessage.{address = found.message.address, data = found.message.data})
}

/**
 * Route a message-signaled IRQ to another CPU, which the caller's CPU budget must have.
 *
 * @param thread The calling thread, whose process's CPU budget limits the CPUs.
 * @param irq The IRQ; no right is needed.
 * @param cpu The CPU's index: online, and, if below 64, one of the caller's CPU budget's CPUs.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The IRQ was destroyed, or its device is being.
 * @error WrongKind Not an IRQ's handle.
 * @error NoMsi The IRQ is a wired line's.
 * @error InvalidArgument A CPU that isn't online, or isn't the caller's CPU budget's.
 * @error NoFreeInterrupt That CPU has no device interrupt free; the IRQ stays where it was.
 */
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

/**
 * Make a DMA domain, owned by the caller's process. Without an IOMMU, its device addresses are physical addresses, and
 * only a domain made trusted has DMA memory.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param flags slop_os.DMA_DOMAIN_TRUSTED, or 0; other bits are ignored.
 * @return An owning handle to the domain.
 * @error InvalidHandle The platform or the budget isn't a handle in the caller's table.
 * @error ObjectGone The platform or the budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Make memory for DMA in a domain, owned by the caller's process: pinned, physically contiguous, and zeroed.
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param domain The domain; no right is needed.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param size Its size in bytes, a whole number of pages, at least one.
 * @param limit The highest device address it may end at, for devices that reach only so far, or 0 for none.
 * @return An owning handle to the memory; memory_device_address says where devices see it.
 * @error InvalidHandle The domain or the budget isn't a handle in the caller's table.
 * @error ObjectGone The domain or the budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error Untrusted No IOMMU translates the domain, and it wasn't made trusted.
 * @error InvalidSize Not a whole number of pages, or none.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot, no contiguous frames below the limit, no device addresses in the domain, or no frame for
 *     a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Tell where DMA memory is, to the devices in its domain.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param memory The memory; no right is needed.
 * @return Its device address: where an IOMMU maps it, or its physical address without one.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error WrongKind Not a memory object's handle.
 * @error NotDmaMemory Not memory dma_memory_create made, or its domain is gone.
 */
sys_memory_device_address :: fn(thread: ptr[mut Thread], memory: slop_os.Memory) -> Result[u64, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, cast[slop_os.Rights](0))?
    return device_address_of(cast[ptr[Memory]](object))
}

/**
 * Register an IOMMU the firmware tables describe, covering a range of requester IDs.
 *
 * The registers are device memory itself, uncached, not a window onto it (iommus.hsc). The same IOMMU registered again
 * gives the same number, and covers those requester IDs too.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param kind What kind of IOMMU.
 * @param registers Its registers: memory memory_create_physical made, cached as Device; no right is needed.
 * @param first The first requester ID it covers (slop_os.device_address, its segment in the upper 16 bits).
 * @param count How many requester IDs it covers from first.
 * @param stream The stream ID first is at the IOMMU, counting up from it for the next IDs.
 * @return The IOMMU's number; the same number for the same IOMMU registered again.
 * @error InvalidHandle The platform or the registers isn't a handle in the caller's table.
 * @error ObjectGone The platform or the registers was destroyed.
 * @error WrongKind A handle of another kind.
 * @error NoIommu A kind the kernel doesn't know, none of that kind there, or none it can drive.
 * @error BadAddress The registers isn't device memory itself.
 * @error InvalidSize The registers is bigger than an IOMMU's registers can be, or count and stream are out of range.
 * @error OutOfMemory The registers couldn't be mapped.
 * @error TooManyIommus Every IOMMU the kernel takes is registered, or every range of requester IDs one covers.
 */
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

/**
 * Find the process a handle in the caller's table names, if the handle has right; rights on a process cover its
 * subtree (decisions/0017).
 *
 * @param thread The calling thread, whose process's handle table the process's handle is looked up in.
 * @param process The process's handle, as the caller passed it, untrusted.
 * @param right The right it needs.
 * @return The process, live when it was looked up; it may be destroyed meanwhile, and its memory stays until this CPU
 *     passes a quiescent point.
 * @error InvalidHandle Not a handle in the caller's table, or one already closed.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks right.
 */
target_of :: fn(thread: ptr[mut Thread], process: slop_os.Process, right: slop_os.Rights) -> Result[ptr[mut Process], slop_os.ControlError] {
    object :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](process), slop_os.ObjectKind.Process, right)?
    return .Ok(cast[ptr[mut Process]](object))
}

/**
 * Turn a process control operation's outcome into a call's result.
 *
 * @param error The operation's error, or null if it succeeded.
 * @return Ok for null, or Error with that error, whichever variant it is.
 */
control_done :: fn(error: slop_os.ControlError?) -> Result[void, slop_os.ControlError] {
    match error {
        case Some(failure) => return .Error(failure)
        case None => return .Ok
    }
}

/**
 * List the threads of a process's subtree.
 *
 * @param thread The calling thread, into whose memory the IDs are written.
 * @param process The process, which needs RIGHT_PROCESS_INSPECT.
 * @param ids Where the threads' IDs go in the caller's memory, at most 64 of them however big it is.
 * @return How many threads the subtree has, which can be more than were written.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks RIGHT_PROCESS_INSPECT.
 * @error BadBuffer The IDs aren't writable user memory.
 */
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

/**
 * Find the address space a handle in the caller's table names, if it's owned within target's subtree.
 *
 * @param thread The calling thread, whose process's handle table the space's handle is looked up in.
 * @param target The process whose subtree it has to be in.
 * @param space The handle; no right is needed.
 * @return The address space, live when it was looked up, and owned within target's subtree.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The space was destroyed.
 * @error WrongKind Not an address space's handle.
 * @error BadAddress The space isn't in target's subtree.
 */
subtree_space :: fn(thread: ptr[mut Thread], target: ptr[mut Process], space: slop_os.AddressSpace) -> Result[ptr[mut AddressSpace], slop_os.ControlError] {
    object :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](space), slop_os.ObjectKind.AddressSpace, cast[slop_os.Rights](0))?
    if !in_subtree(object, cast[u64](target)) {
        return .Error(.BadAddress)
    }
    return .Ok(cast[ptr[mut AddressSpace]](object))
}

/**
 * Copy bytes from an address space in a process's subtree into the caller's buffer, through the kernel.
 *
 * @param thread The calling thread, into whose memory they're copied.
 * @param process The process, which needs RIGHT_PROCESS_READ_MEMORY.
 * @param space An address space in its subtree, through a handle the caller has; no right is needed.
 * @param address Where in space to read from, a user virtual address.
 * @param buffer Where the bytes go in the caller's memory; it's filled.
 * @error InvalidHandle The process or the space isn't a handle in the caller's table.
 * @error ObjectGone The process or the space was destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The process lacks RIGHT_PROCESS_READ_MEMORY.
 * @error BadAddress The space isn't in the subtree, or the range isn't mapped there or in the caller's memory.
 */
sys_process_read_memory :: fn(thread: ptr[mut Thread], process: slop_os.Process, space: slop_os.AddressSpace, address: u64,
    buffer: slop_os.UserBuffer) -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_READ_MEMORY)?
    other :: subtree_space(thread, target, space)?
    if !copy_between(per_cpu().kernel, other, address, thread.space, buffer.address, buffer.count) {
        return .Error(.BadAddress)
    }
    return .Ok
}

/**
 * Copy the caller's bytes into an address space in a process's subtree, through the kernel.
 *
 * @param thread The calling thread, from whose memory they're copied.
 * @param process The process, which needs RIGHT_PROCESS_WRITE_STATE.
 * @param space An address space in its subtree, through a handle the caller has; no right is needed.
 * @param address Where in space to write to, a user virtual address.
 * @param buffer The bytes to write, in the caller's memory.
 * @error InvalidHandle The process or the space isn't a handle in the caller's table.
 * @error ObjectGone The process or the space was destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The process lacks RIGHT_PROCESS_WRITE_STATE.
 * @error BadAddress The space isn't in the subtree, or the range isn't mapped there or in the caller's memory.
 */
sys_process_write_memory :: fn(thread: ptr[mut Thread], process: slop_os.Process, space: slop_os.AddressSpace, address: u64,
    buffer: slop_os.UserBuffer) -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE)?
    other :: subtree_space(thread, target, space)?
    if !copy_between(per_cpu().kernel, thread.space, buffer.address, other, address, buffer.count) {
        return .Error(.BadAddress)
    }
    return .Ok
}

/**
 * Find a live thread in a process's subtree, by ID.
 *
 * @param thread The calling thread, whose process's handle table the process's handle is looked up in.
 * @param process The process's handle, which needs right.
 * @param right The right the call needs on the process.
 * @param id The thread's ID, as process_threads gives it.
 * @return The thread, live when it was found, owned within the process's subtree.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks right.
 * @error NoSuchThread No live thread with that ID in the subtree.
 */
subtree_thread :: fn(thread: ptr[mut Thread], process: slop_os.Process, right: slop_os.Rights, id: u64) -> Result[ptr[mut Thread], slop_os.ControlError] {
    target :: target_of(thread, process, right)?
    found :: thread_in(per_cpu().kernel, cast[u64](target), id) or_return .Error(.NoSuchThread)
    return .Ok(found)
}

/**
 * Suspend a thread in a process's subtree until thread_resume: parked at once if it's queued, or told to stop if it
 * runs on another CPU. Suspending one already suspended changes nothing.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param process The process, which needs RIGHT_PROCESS_WRITE_STATE.
 * @param id The thread's ID, as process_threads gives it.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks RIGHT_PROCESS_WRITE_STATE.
 * @error NoSuchThread No live thread with that ID in the subtree.
 */
sys_thread_suspend :: fn(thread: ptr[mut Thread], process: slop_os.Process, id: u64) -> Result[void, slop_os.ControlError] {
    found :: subtree_thread(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE, id)?
    hold_thread(per_cpu().kernel, found, HELD_SUSPEND)
    return .Ok
}

/**
 * Resume a thread thread_suspend suspended: made ready if it's parked and nothing else holds it.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param process The process, which needs RIGHT_PROCESS_WRITE_STATE.
 * @param id The thread's ID, as process_threads gives it.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks RIGHT_PROCESS_WRITE_STATE.
 * @error NoSuchThread No live thread with that ID in the subtree.
 */
sys_thread_resume :: fn(thread: ptr[mut Thread], process: slop_os.Process, id: u64) -> Result[void, slop_os.ControlError] {
    found :: subtree_thread(thread, process, slop_os.RIGHT_PROCESS_WRITE_STATE, id)?
    unhold_thread(per_cpu().kernel, found, HELD_SUSPEND)
    return .Ok
}

/**
 * Read a parked thread's registers, only while they're the thread's alone, as a debugger sees them.
 *
 * Takes the thread's control lock while it reads.
 *
 * @param thread The calling thread, into whose memory they're written.
 * @param process The process, which needs RIGHT_PROCESS_INSPECT.
 * @param id The thread's ID, as process_threads gives it.
 * @param registers Where the registers go in the caller's memory: at least slop_os.THREAD_REGISTERS words, in its
 *     order.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks RIGHT_PROCESS_INSPECT.
 * @error NoSuchThread No live thread with that ID in the subtree.
 * @error BadBuffer Fewer than slop_os.THREAD_REGISTERS words, or not writable user memory.
 * @error NotStopped The thread isn't parked: stopped or suspended, and off its CPU.
 */
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

/**
 * Write a parked thread's registers, for when it runs again.
 *
 * Takes the thread's control lock while it writes.
 *
 * @param thread The calling thread, from whose memory they're read.
 * @param process The process, which needs RIGHT_PROCESS_WRITE_STATE.
 * @param id The thread's ID, as process_threads gives it.
 * @param registers The registers in the caller's memory: at least slop_os.THREAD_REGISTERS words, in its order.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks RIGHT_PROCESS_WRITE_STATE.
 * @error NoSuchThread No live thread with that ID in the subtree.
 * @error BadBuffer Fewer than slop_os.THREAD_REGISTERS words, or not readable user memory.
 * @error NotStopped The thread isn't parked: stopped or suspended, and off its CPU.
 * @error BadRegisters A value user mode can't have, like a kernel address for the instruction pointer.
 */
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

/**
 * Intercept a process's subtree, for a debugger: its threads stop where points says, and each stop raises a Stop
 * packet on a port. Paid for by the caller's process's own budget, as it has no budget argument.
 *
 * @param thread The calling thread, whose process owns the intercept.
 * @param process The process, which needs RIGHT_PROCESS_INTERCEPT.
 * @param port The port stops are reported to, which needs RIGHT_PORT_BIND.
 * @param key The Stop packets' key, bound on port.
 * @param calls Which system calls stop at entry or exit: a bit per call number below 64.
 * @param points slop_os.STOP_ bits: where threads stop.
 * @return An owning handle to the intercept; closing it lets the subtree run on unintercepted.
 * @error InvalidHandle The process or the port isn't a handle in the caller's table.
 * @error ObjectGone The process or the port was destroyed, or is being, or the caller's process is.
 * @error WrongKind A handle of another kind, or the key is bound on port already.
 * @error MissingRight The process lacks RIGHT_PROCESS_INTERCEPT, or the port RIGHT_PORT_BIND.
 * @error AlreadyIntercepted The process is intercepted already.
 * @error BudgetExceeded The caller's budget can't pay for the intercept, its binding, or a page of its table.
 * @error OutOfMemory No slot for the intercept or its binding, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Find the intercept a handle in the caller's table refers to; no right is needed.
 *
 * @param thread The calling thread, whose process's handle table the intercept's handle is looked up in.
 * @param intercept The intercept's handle, as the caller passed it, untrusted, of any rights.
 * @return The intercept, live when it was looked up; it may be destroyed meanwhile, and its memory stays until this CPU
 *     passes a quiescent point.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The intercept was destroyed.
 * @error WrongKind Not an intercept's handle.
 */
intercept_of_handle :: fn(thread: ptr[mut Thread], intercept: slop_os.Intercept) -> Result[ptr[mut Intercept], slop_os.ControlError] {
    object :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](intercept), slop_os.ObjectKind.Intercept, cast[slop_os.Rights](0))?
    return .Ok(cast[ptr[mut Intercept]](object))
}

/**
 * Take the next stop an intercept hasn't reported yet.
 *
 * @param thread The calling thread, into whose memory the stop is written.
 * @param intercept The intercept; no right is needed.
 * @param stop A user virtual address where the slop_os.StopInfo is written.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The intercept was destroyed.
 * @error WrongKind Not an intercept's handle.
 * @error Empty No stop left to report.
 * @error BadBuffer The stop isn't writable user memory.
 */
sys_intercept_next :: fn(thread: ptr[mut Thread], intercept: slop_os.Intercept, stop: u64) -> Result[void, slop_os.ControlError] {
    found :: intercept_of_handle(thread, intercept)?
    return control_done(intercept_next(per_cpu().kernel, found, thread.space, stop))
}

/**
 * Let a thread an intercept stopped go on.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param intercept The intercept; no right is needed.
 * @param id The stopped thread's ID, as intercept_next gave it.
 * @param action What it does: Continue, Skip (only at a system call's entry), or Kill.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The intercept was destroyed.
 * @error WrongKind Not an intercept's handle.
 * @error NoSuchThread No thread with that ID the intercept stopped.
 * @error NotStopped The thread isn't stopped, Skip somewhere other than a system call's entry, or an action that isn't
 *     one.
 */
sys_intercept_resume :: fn(thread: ptr[mut Thread], intercept: slop_os.Intercept, id: u64, action: slop_os.InterceptAction)
    -> Result[void, slop_os.ControlError] {
    found :: intercept_of_handle(thread, intercept)?
    if action != .Continue && action != .Skip && action != .Kill {
        return .Error(.NotStopped)
    }
    return control_done(intercept_resume(per_cpu().kernel, found, id, action))
}

/**
 * End the caller's process, with its subtree, the calling thread with it; the call never returns to it.
 *
 * @param thread The calling thread, the CPU's current one: its process, which it ends with, gets the exit code, and is
 *     destroyed with its subtree.
 * @param code The exit code, for whoever watches it end: data[1] of the SIGNAL_TERMINATED packet.
 */
sys_process_exit :: fn(thread: ptr[mut Thread], code: u32) {
    process :: process_of(thread)
    process.exited = true
    process.exit_code = code
    _ = destroy_object(per_cpu().kernel, cast[u64](process))
}

/**
 * Destroy a process and its subtree, which raises SIGNAL_TERMINATED with EXIT_KILLED.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param process The process, which needs RIGHT_PROCESS_KILL; it may be the caller's own.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The handle lacks RIGHT_PROCESS_KILL.
 */
sys_process_kill :: fn(thread: ptr[mut Thread], process: slop_os.Process) -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_KILL)?
    _ = destroy_object(per_cpu().kernel, cast[u64](target))
    return .Ok
}

/**
 * Make a thread owned by another process, in an address space in its subtree, and start it, as thread_create would in
 * the caller's (decisions/0067).
 *
 * @param thread The calling thread, which doesn't block here: the handles are looked up in its process's table; the new
 *     thread is owned by process, not by the caller.
 * @param process The process that owns the thread, which needs RIGHT_PROCESS_THREADS.
 * @param budget The memory budget that pays for the thread, which needs RIGHT_BUDGET_CHARGE.
 * @param space Where it runs, which needs RIGHT_SPACE_THREADS and has to be in process's subtree.
 * @param entry The user virtual address in space it starts at; unchecked, so a bad one faults when it runs.
 * @param stack Its initial stack pointer, a user virtual address in space, likewise unchecked.
 * @param argument A word handed to it in its first argument register.
 * @return The thread's ID, not a handle: the caller doesn't own it.
 * @error InvalidHandle A handle isn't in the caller's table.
 * @error ObjectGone A handle's object was destroyed, or the process or the space is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight A handle lacks its right.
 * @error BadAddress The address space isn't in the process's subtree.
 * @error OutOfMemory No memory for the thread or its vector state.
 * @error BudgetExceeded The budget can't pay for the thread.
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

/**
 * Move handles out of the caller's table into another process's, for building it from an executable (decisions/0067).
 *
 * @param thread The calling thread, which doesn't block here: the handles come out of its process's table, and the
 *     slices are read from and written to its address space.
 * @param process The process, which needs RIGHT_PROCESS_THREADS.
 * @param handles The handles in the caller's memory, at most slop_os.MAX_HANDLES_PER_BATCH, each with RIGHT_TRANSFER.
 *     Once the call returns Ok they're no longer the caller's.
 * @param given Where each one's handle in the process is written, in the same order, NO_HANDLE for one closed meanwhile
 *     or that didn't fit: at least as many.
 * @error InvalidHandle The process isn't a handle in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error WrongKind Not a process's handle.
 * @error MissingRight The process lacks RIGHT_PROCESS_THREADS, or a handle RIGHT_TRANSFER.
 * @error TooBig More than slop_os.MAX_HANDLES_PER_BATCH handles.
 * @error BadBuffer given is too short, or either slice isn't the caller's memory.
 * @error NotTransferable A handle that can't go to the process: an owning one to it or a process above it, or a channel
 *     end whose rings are mapped.
 * @error BudgetExceeded The process's budget can't take over what the owning handles own.
 */
sys_process_give_handles :: fn(thread: ptr[mut Thread], process: slop_os.Process, handles: slop_os.UserBuffer, given: slop_os.UserBuffer)
    -> Result[void, slop_os.ControlError] {
    target :: target_of(thread, process, slop_os.RIGHT_PROCESS_THREADS)?
    return control_done(give_handles(per_cpu().kernel, thread, target, handles, given))
}

// CPU budgets and I/O ports (roadmap 9a, decisions/0093)

/**
 * Tell what a CPU budget operation failing means to the caller.
 *
 * @param error Why it failed.
 * @return The HandleError with the same meaning: ObjectGone for OwnerGone, and BudgetExceeded for TooMuch, a share
 *     past what the parent has left.
 */
cpu_budget_failure :: fn(error: CpuBudgetError) -> slop_os.HandleError {
    return match error {
        case .OutOfMemory => slop_os.HandleError.OutOfMemory
        case .OwnerGone => slop_os.HandleError.ObjectGone
        case .BudgetExceeded => slop_os.HandleError.BudgetExceeded
        case .TooMuch => slop_os.HandleError.BudgetExceeded
        case .InvalidArgument => slop_os.HandleError.InvalidArgument
    }
}

/**
 * Make a CPU budget, a child of the parent budget, owned by the caller's process (decisions/0037, 0093).
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param parent The budget it's split off, which needs RIGHT_CPU_BUDGET_SPLIT.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param priority Its threads' priority, at most its parent's.
 * @param period How often its time comes back, in nanoseconds, more than 0.
 * @param time How much CPU it gets each period, in nanoseconds, at most period.
 * @return An owning handle to the budget.
 * @error InvalidHandle A handle isn't in the caller's table.
 * @error ObjectGone A handle's object was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The parent lacks RIGHT_CPU_BUDGET_SPLIT, or the budget RIGHT_BUDGET_CHARGE.
 * @error InvalidArgument A period of 0, a time over period, or a priority over its parent's.
 * @error BudgetExceeded Its share would take its parent's children past the parent's own, or the memory budget can't
 *     pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Change a CPU budget's priority, period and time, within its parent's as cpu_budget_create's are.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param budget The budget, which needs RIGHT_CPU_BUDGET_SET.
 * @param priority Its threads' priority, at most its parent's.
 * @param period How often its time comes back, in nanoseconds, more than 0.
 * @param time How much CPU it gets each period, in nanoseconds, at most period.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The budget was destroyed.
 * @error WrongKind Not a CPU budget's handle.
 * @error MissingRight The handle lacks RIGHT_CPU_BUDGET_SET.
 * @error InvalidArgument A period of 0, a time over period, or a priority over its parent's.
 * @error BudgetExceeded The new share would take its parent's children past the parent's own, or be less than its own
 *     children's.
 */
sys_cpu_budget_set :: fn(thread: ptr[mut Thread], budget: slop_os.CpuBudget, priority: u32, period: u64, time: u64) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_SET)?
    match set_cpu_budget(per_cpu().kernel, cast[ptr[mut CpuBudget]](object), priority, period, time) {
        case Ok => return .Ok
        case Error(error) => return .Error(cpu_budget_failure(error))
    }
}

/**
 * Set the CPUs a CPU budget's threads may run on; they move at their next tick.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param budget The budget, which needs RIGHT_CPU_BUDGET_SET.
 * @param cpus A bit per CPU's index: at least one of them online, within its parent's, and over each of its children's.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The budget was destroyed.
 * @error WrongKind Not a CPU budget's handle.
 * @error MissingRight The handle lacks RIGHT_CPU_BUDGET_SET.
 * @error InvalidArgument None of the CPUs online.
 * @error BudgetExceeded CPUs outside its parent's, or not covering one of its children's.
 */
sys_cpu_budget_set_cpus :: fn(thread: ptr[mut Thread], budget: slop_os.CpuBudget, cpus: u64) -> Result[void, slop_os.HandleError] {
    object :: object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_SET)?
    match set_cpu_budget_cpus(per_cpu().kernel, cast[ptr[mut CpuBudget]](object), cpus) {
        case Ok => return .Ok
        case Error(error) => return .Error(cpu_budget_failure(error))
    }
}

/**
 * Describe a CPU budget, as words in slop_os.CpuBudgetInfo's fields' order.
 *
 * @param thread The calling thread, into whose memory they're written.
 * @param budget The budget; no right is needed.
 * @param info Where the words go in the caller's memory: at least slop_os.CPU_BUDGET_INFO_WORDS of them.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The budget was destroyed.
 * @error WrongKind Not a CPU budget's handle.
 * @error BadBuffer Fewer than slop_os.CPU_BUDGET_INFO_WORDS words, or not writable user memory.
 */
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

/**
 * Put a process, and every thread of its, now and later, on a CPU budget.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param process The process, which needs RIGHT_PROCESS_THREADS.
 * @param budget The budget, which needs RIGHT_CPU_BUDGET_BIND.
 * @error InvalidHandle A handle isn't in the caller's table.
 * @error ObjectGone The process or the budget was destroyed, or is being.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The process lacks RIGHT_PROCESS_THREADS, or the budget RIGHT_CPU_BUDGET_BIND.
 */
sys_process_set_cpu_budget :: fn(thread: ptr[mut Thread], process: slop_os.Process, budget: slop_os.CpuBudget) -> Result[void, slop_os.HandleError] {
    caller :: process_of(thread)
    target :: object_of[slop_os.HandleError](caller, cast[slop_os.Handle](process), slop_os.ObjectKind.Process, slop_os.RIGHT_PROCESS_THREADS)?
    object :: object_of[slop_os.HandleError](caller, cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_BIND)?
    if !set_process_budget(per_cpu().kernel, cast[ptr[mut Process]](target), cast[ptr[mut CpuBudget]](object)) {
        return .Error(.ObjectGone)
    }
    return .Ok
}

/**
 * Run the calling thread on a lent CPU budget from now on, or on its process's again with NO_HANDLE (decisions/0130);
 * what it has run so far is charged to the one it was on.
 *
 * @param thread The calling thread, the CPU's current one, which is moved onto the budget and doesn't block here; the
 *     budget's handle is looked up in its process's table.
 * @param budget The budget, which needs RIGHT_CPU_BUDGET_BIND, or NO_HANDLE for the process's own.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The budget was destroyed, or is being.
 * @error WrongKind Not a CPU budget's handle.
 * @error MissingRight The handle lacks RIGHT_CPU_BUDGET_BIND.
 */
sys_thread_use_cpu_budget :: fn(thread: ptr[mut Thread], budget: slop_os.CpuBudget) -> Result[void, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    process :: process_of(thread)
    if cast[slop_os.Handle](budget) == slop_os.NO_HANDLE {
        _ = set_thread_budget(kernel, thread, process.cpu_budget)
        return .Ok
    }
    object :: object_of[slop_os.HandleError](process, cast[slop_os.Handle](budget), slop_os.ObjectKind.CpuBudget, slop_os.RIGHT_CPU_BUDGET_BIND)?
    if !set_thread_budget(kernel, thread, cast[u64](object)) {
        return .Error(.ObjectGone)
    }
    return .Ok
}

/**
 * Make an object of a range of I/O ports, owned by the caller's process, on an architecture that has them (x86-64).
 *
 * @param thread The calling thread, which doesn't block here: its process owns what's made, the handles are looked up
 *     in its process's table, and the new handle goes there, any new page of the table charged to the process's budget.
 * @param platform The platform capability's handle, of any rights, which is the call's authority.
 * @param budget The memory budget that pays for it, which needs RIGHT_BUDGET_CHARGE.
 * @param first The first port's number; the range from it has to end at the architecture's last port or below.
 * @param count How many ports, from first to first + count - 1.
 * @return An owning handle to the range.
 * @error InvalidHandle The platform or the budget isn't a handle in the caller's table.
 * @error ObjectGone The platform or the budget was destroyed, or the caller's process is being destroyed.
 * @error WrongKind A handle of another kind.
 * @error MissingRight The budget lacks RIGHT_BUDGET_CHARGE.
 * @error InvalidArgument Ports past the last one, none, or an architecture without ports.
 * @error BudgetExceeded The budget can't pay for it, or the caller's for a page of its table.
 * @error OutOfMemory No slot for it, or no frame for a page of the caller's table.
 * @error TableFull The caller's table has no room.
 */
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

/**
 * Read an I/O port in a range.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param ports The range, which needs RIGHT_IO_PORTS_ACCESS.
 * @param offset The port's offset from the range's first, in ports.
 * @param width How many bytes: 1, 2 or 4.
 * @return The value read, zero-extended.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The range was destroyed.
 * @error WrongKind Not an I/O port range's handle.
 * @error MissingRight The handle lacks RIGHT_IO_PORTS_ACCESS.
 * @error InvalidArgument A port outside the range, a width that isn't 1, 2 or 4, or an architecture without ports.
 */
sys_io_port_read :: fn(thread: ptr[mut Thread], ports: slop_os.IoPortRange, offset: u32, width: u32) -> Result[u32, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](ports), slop_os.ObjectKind.IoPortRange, slop_os.RIGHT_IO_PORTS_ACCESS)?
    port :: port_at(cast[ptr[IoPortRange]](object), offset, width) or_return .Error(.InvalidArgument)
    value :: arch.port_read(port, width) or_return .Error(.InvalidArgument)
    return .Ok(value)
}

/**
 * Write an I/O port in a range.
 *
 * @param thread The calling thread, the CPU's current one, which doesn't block here: its process's handle table is
 *     where the handles are looked up.
 * @param ports The range, which needs RIGHT_IO_PORTS_ACCESS.
 * @param offset The port's offset from the range's first, in ports.
 * @param width How many bytes: 1, 2 or 4.
 * @param value The value, of which only the low width bytes are written.
 * @error InvalidHandle Not a handle in the caller's table.
 * @error ObjectGone The range was destroyed.
 * @error WrongKind Not an I/O port range's handle.
 * @error MissingRight The handle lacks RIGHT_IO_PORTS_ACCESS.
 * @error InvalidArgument A port outside the range, a width that isn't 1, 2 or 4, or an architecture without ports.
 */
sys_io_port_write :: fn(thread: ptr[mut Thread], ports: slop_os.IoPortRange, offset: u32, width: u32, value: u32) -> Result[void, slop_os.DeviceError] {
    object :: object_of[slop_os.DeviceError](process_of(thread), cast[slop_os.Handle](ports), slop_os.ObjectKind.IoPortRange, slop_os.RIGHT_IO_PORTS_ACCESS)?
    port :: port_at(cast[ptr[IoPortRange]](object), offset, width) or_return .Error(.InvalidArgument)
    if !arch.port_write(port, width, value) {
        return .Error(.InvalidArgument)
    }
    return .Ok
}
