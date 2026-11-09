package kernel

import intrinsics from "base"
import slop_os from "std/os"
import boot_info from "../boot_info"
import frames from "frames"

/*
 * Per-thread pages (decisions/0041, 0185's 12h): a page of the thread's own memory that it and the kernel share, which
 * the thread writes and the kernel reads, through the direct map, at its scheduling points. It holds the CPU budget
 * binding, a handle, which the kernel resolves when it changes, so a fiber scheduler moves a thread between its
 * fibers' loans without a system call each time; and the running fiber, which samples and the trace record. The kernel
 * never writes it, and reads it only while its memory object lives: a page destroyed or changed under it costs the
 * thread its loan or its fiber's name, never the kernel's safety.
 */

/**
 * Find a thread's per-thread page, in the direct map.
 *
 * @param kernel The kernel, for its direct map.
 * @param thread The thread.
 * @return The page; null if it has none, or its memory object has been destroyed since thread_set_page.
 */
thread_page_of :: fn(kernel: ptr[mut Kernel], thread: ptr[Thread]) -> ptr[slop_os.ThreadPage]? {
    if thread.page_frame == 0 || !is_live(thread.page_memory, thread.page_generation) {
        return null
    }
    return cast[ptr[slop_os.ThreadPage]](cast[rawptr](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](thread.page_frame))))
}

/**
 * Tell which fiber a thread's per-thread page says is running.
 *
 * @param kernel The kernel, for its direct map.
 * @param thread The thread.
 * @return The fiber, as the thread's fiber scheduler names it; 0 for none, or with no page.
 */
running_fiber_of :: fn(kernel: ptr[mut Kernel], thread: ptr[Thread]) -> u64 {
    page :: thread_page_of(kernel, thread) or_return 0
    return intrinsics.volatile_load_u64(&page.fiber)
}

/**
 * Put a thread on the CPU budget its per-thread page binds it to, if the binding changed since it was last resolved:
 * the budget the handle names, if it's a CPU budget's with RIGHT_CPU_BUDGET_BIND in the thread's process's table, and
 * otherwise, or for 0, its process's own. A binding that's the same as last time changes nothing, so thread_use_cpu_budget
 * holds until the page's changes.
 *
 * @param kernel The kernel, whose cpu_budgets_lock set_thread_budget takes. Called from schedule, on the thread's
 *     CPU, with no lock held.
 * @param thread The CPU's current thread, charged for its time already.
 */
bind_from_page :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    page :: thread_page_of(kernel, thread) or_return void
    // A binding that isn't a handle, wider than one, is its process's own, as 0 is
    read :: intrinsics.volatile_load_u64(&page.budget)
    binding :: if read <= 0xffffffff { read } else { cast[u64](0) }
    if binding == cast[u64](thread.page_seen) {
        return void
    }
    thread.page_seen = cast[u32](binding)
    process :: process_of(thread)
    target := process.cpu_budget
    if binding != 0 && binding <= 0xffffffff {
        match object_of[slop_os.HandleError](process, cast[slop_os.Handle](cast[u32](binding)), slop_os.ObjectKind.CpuBudget,
            slop_os.RIGHT_CPU_BUDGET_BIND) {
            case Ok(object) => target = cast[u64](object)
            case Error(error) => {}
        }
    }
    _ = set_thread_budget(kernel, thread, target)
}

/**
 * Give the calling thread its per-thread page, or take it away (decisions/0041, 0185).
 *
 * @param thread The calling thread.
 * @param memory Anonymous memory of the caller's, which needs RIGHT_MEMORY_READ; NO_HANDLE for no page from now.
 * @param offset Where in it the page is, in bytes: page-aligned, and a page short of its size or more.
 * @return Nothing, the page in use from the thread's next scheduling point.
 * @error InvalidHandle The handle isn't in the caller's table.
 * @error ObjectGone The memory was destroyed.
 * @error MissingRight The handle lacks RIGHT_MEMORY_READ.
 * @error InvalidSize An offset that isn't page-aligned or leaves less than a page.
 * @error WrongKind Memory that isn't anonymous: device, a boot module's, contiguous, paged, or a window.
 * @error OutOfMemory Its page had no frame yet, and there were none.
 */
sys_thread_set_page :: fn(thread: ptr[mut Thread], memory: slop_os.Memory, offset: u64) -> Result[void, slop_os.MemoryError] {
    kernel :: per_cpu().kernel
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        // Back on its process's budget, if the page had it on another
        if thread.page_seen != 0 {
            _ = set_thread_budget(kernel, thread, process_of(thread).cpu_budget)
        }
        thread.page_frame = 0
        thread.page_memory = 0
        thread.page_seen = 0
        return .Ok
    }
    object :: object_of[slop_os.MemoryError](process_of(thread), cast[slop_os.Handle](memory), slop_os.ObjectKind.Memory, slop_os.RIGHT_MEMORY_READ)?
    found :: cast[ptr[Memory]](object)
    if offset % frames.FRAME_SIZE != 0 || offset >= found.size || found.size - offset < frames.FRAME_SIZE {
        return .Error(.InvalidSize)
    }
    if found.physical != 0 || found.parent != 0 || found.pager_binding != 0 || found.directory == 0 {
        return .Error(.WrongKind)
    }
    frame :: frame_for(kernel, found, offset / frames.FRAME_SIZE)
    if frame == 0 {
        return .Error(.OutOfMemory)
    }
    thread.page_frame = frame
    thread.page_memory = cast[u64](object)
    thread.page_generation = intrinsics.atomic_load_u32_acquire(&found.header.generation)
    thread.page_seen = 0
    return .Ok
}
