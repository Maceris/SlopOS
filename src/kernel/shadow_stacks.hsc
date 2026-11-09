package kernel

import intrinsics from "base"
import slop_os from "std/os"
import frames from "frames"
import arch_interface from "../arch_interface"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Shadow stacks for user threads (decisions/0186): a process built for them gives the kernel a region of its address
 * space (process_set_control_flow), and every thread made in it from then on gets a shadow stack of its own there,
 * before its first instruction: a slot of SHADOW_STACK_STRIDE bytes, a guard page and then slop_os.SHADOW_STACK_BYTES of
 * memory the kernel makes, charged to the thread's budget and mapped as shadow-stack pages, which user code can't
 * write. Nothing else has a handle to it. The slot is given back when the thread ends. The thread's shadow-stack pointer
 * is kept in its Thread while it's out of user mode, read as it enters the kernel and loaded as it leaves.
 */

/**
 * A mapping's protection bit, kernel-only, for a shadow stack's pages: never one a memory_map call may give
 * (sys_memory_map refuses it), above the slop_os.PROTECTION_ bits.
 */
SHADOW_STACK_PROTECTION : u32 : 1 << 16
/** A shadow stack's slot: a guard page below it, then its memory. */
SHADOW_STACK_STRIDE : u64 : slop_os.SHADOW_STACK_BYTES + frames.FRAME_SIZE
/** The most shadow stacks a process can have at once: its region's slots, as Process.shadow_used's bits. */
MAX_SHADOW_STACKS :: 256

/**
 * Say what control-flow integrity a process's code was built for, and give the region its threads' shadow stacks go in
 * (decisions/0186).
 *
 * @param thread The calling thread.
 * @param process The process, which needs RIGHT_PROCESS_THREADS.
 * @param features slop_os.CONTROL_FLOW_ bits; others are ignored.
 * @param region Where the shadow stacks go, page-aligned, in user space; with CONTROL_FLOW_SHADOW_STACK, room for at
 *     least one slot, nothing else mapped there.
 * @param size The region's size in bytes; slots past MAX_SHADOW_STACKS are left unused.
 * @return Nothing, the features in effect for threads made from now on.
 * @error InvalidHandle The handle isn't in the caller's table.
 * @error ObjectGone The process was destroyed.
 * @error MissingRight The handle lacks RIGHT_PROCESS_THREADS.
 * @error WrongKind It isn't a process's.
 * @error BadAddress A shadow-stack region that isn't page-aligned, is too small for a slot, or wraps; or any, once a
 *     thread of the process has a shadow stack. One that isn't free user space fails each thread's creation instead.
 */
sys_process_set_control_flow :: fn(thread: ptr[mut Thread], process: slop_os.Process, features: u32, region: u64, size: u64)
    -> Result[void, slop_os.ControlError] {
    target :: object_of[slop_os.ControlError](process_of(thread), cast[slop_os.Handle](process), slop_os.ObjectKind.Process,
        slop_os.RIGHT_PROCESS_THREADS)?
    found :: cast[ptr[mut Process]](target)
    known :: features & (slop_os.CONTROL_FLOW_LANDING_PADS | slop_os.CONTROL_FLOW_SHADOW_STACK | slop_os.CONTROL_FLOW_SIGNED_RETURNS)
    if known & slop_os.CONTROL_FLOW_SHADOW_STACK != 0 {
        if region % frames.FRAME_SIZE != 0 || size < SHADOW_STACK_STRIDE || region + size < region {
            return .Error(.BadAddress)
        }
        for i in 0..<found.shadow_used.count {
            if intrinsics.atomic_load_u64(&found.shadow_used[i]) != 0 {
                return .Error(.BadAddress)
            }
        }
        slots :: size / SHADOW_STACK_STRIDE
        found.shadow_region = region
        found.shadow_slots = if slots > MAX_SHADOW_STACKS { cast[u64](MAX_SHADOW_STACKS) } else { slots }
    }
    intrinsics.atomic_store_u32_release(&found.control_flow, known)
    return .Ok
}

/** The bytes of each CPU's kernel shadow stack: as many as its kernel stack, a return address for every 8 bytes. */
KERNEL_SHADOW_STACK_SIZE : u64 : 16 * 1024

/**
 * Give a CPU the shadow stack its kernel stack runs with, where the kernel's code runs on them (decisions/0186, Hd):
 * zeroed frames, mapped in the kernel window between guard pages as a kernel shadow stack, owned by the kernel for
 * good. Called before the CPU first goes idle, once the window's there.
 *
 * @param kernel The kernel, whose frames and window are used.
 * @param cpu The CPU, not yet idle.
 * @return Whether it has one now, or needs none; false if frames or the window's addresses ran out, which the caller
 *     reports.
 */
give_kernel_shadow_stack :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu]) -> bool {
    if !arch.has_kernel_shadow_stacks() {
        return true
    }
    physical :: frames.allocate_zeroed(&kernel.frames, frames.order_for(KERNEL_SHADOW_STACK_SIZE)) or_return false
    mapping :: arch_interface.Mapping.{protection = .Read, cache = .WriteBack, user = false, global = true, shadow_stack = true}
    base :: map_guarded_in_window(kernel, cast[u64](physical), KERNEL_SHADOW_STACK_SIZE, mapping) or_return false
    arch.set_kernel_shadow_stack(&cpu.arch, base, KERNEL_SHADOW_STACK_SIZE)
    return true
}

/**
 * Give a new thread its shadow stack, where its process asks for them and the CPU has them: a free slot of the
 * process's region, its memory made and mapped as shadow-stack pages, and the thread's shadow-stack pointer at its top.
 *
 * @param kernel The kernel, whose frames the memory takes.
 * @param thread The thread, made and in its address space, not yet started.
 * @param process Its process.
 * @param memory_budget The budget, as an address, the memory is charged to: the thread's.
 * @return Null once it has one, or needs none; OutOfMemory if the region's slots are all taken or the memory couldn't be
 *     made or mapped, BudgetExceeded if the budget can't pay for it.
 */
give_shadow_stack :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], process: ptr[mut Process], memory_budget: u64) -> ThreadError? {
    if intrinsics.atomic_load_u32_acquire(&process.control_flow) & slop_os.CONTROL_FLOW_SHADOW_STACK == 0 || process.shadow_slots == 0
        || !arch.has_user_shadow_stacks() {
        return null
    }
    slot :: take_shadow_slot(process) or_return ThreadError.OutOfMemory
    memory := cast[ptr[mut Memory]](0)
    match create_memory(kernel, cast[u64](process), memory_budget, slop_os.SHADOW_STACK_BYTES) {
        case Ok(made) => memory = made
        case Error(error) => {
            give_back_shadow_slot(process, slot)
            return if error == .BudgetExceeded { ThreadError.BudgetExceeded } else { ThreadError.OutOfMemory }
        }
    }
    address :: process.shadow_region + slot * SHADOW_STACK_STRIDE + frames.FRAME_SIZE
    if memory_map(kernel, memory, thread.space, address, 0, slop_os.SHADOW_STACK_BYTES,
        cast[u32](slop_os.PROTECTION_READ) | SHADOW_STACK_PROTECTION) != null {
        _ = destroy_object(kernel, cast[u64](memory))
        give_back_shadow_slot(process, slot)
        return ThreadError.OutOfMemory
    }
    thread.shadow_slot = cast[u32](slot) + 1
    thread.shadow_pointer = address + slop_os.SHADOW_STACK_BYTES
    return null
}

/**
 * Give back a thread's shadow stack as it's destroyed: unmapped, its memory destroyed, and its slot free again.
 *
 * @param kernel The kernel.
 * @param thread The thread being destroyed; a thread without one is passed by.
 */
release_shadow_stack :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    if thread.shadow_slot == 0 {
        return void
    }
    slot :: cast[u64](thread.shadow_slot - 1)
    thread.shadow_slot = 0
    owner :: thread.header.owner
    if owner == 0 {
        return void
    }
    process :: cast[ptr[mut Process]](owner)
    address :: process.shadow_region + slot * SHADOW_STACK_STRIDE + frames.FRAME_SIZE
    // Its memory, what's mapped there; destroyed already if its process is, with what the process owned
    memory, generation :: memory_mapped_at(thread.space, address)
    _ = memory_unmap(kernel, thread.space, address)
    if memory != 0 && is_live(memory, generation) {
        _ = destroy_object(kernel, memory)
    }
    give_back_shadow_slot(process, slot)
}

/**
 * Take a free slot of a process's shadow-stack region, atomically.
 *
 * @param process The process.
 * @return The slot's index, below its shadow_slots; null if they're all taken.
 */
take_shadow_slot :: fn(process: ptr[mut Process]) -> u64? {
    for slot in cast[u64](0)..<process.shadow_slots {
        word :: cast[usize](slot / 64)
        if word >= process.shadow_used.count {
            return null
        }
        bit :: cast[u64](1) << (slot % 64)
        seen :: intrinsics.atomic_load_u64(&process.shadow_used[word])
        if seen & bit != 0 {
            continue
        }
        _, taken :: intrinsics.interlocked_compare_exchange_u64(&process.shadow_used[word], seen | bit, seen)
        if taken {
            return slot
        }
    }
    return null
}

/**
 * Give back a slot of a process's shadow-stack region, atomically.
 *
 * @param process The process.
 * @param slot The slot, which take_shadow_slot gave.
 */
give_back_shadow_slot :: fn(process: ptr[mut Process], slot: u64) {
    word :: cast[usize](slot / 64)
    if word >= process.shadow_used.count {
        return void
    }
    bit :: cast[u64](1) << (slot % 64)
    loop {
        seen :: intrinsics.atomic_load_u64(&process.shadow_used[word])
        _, given :: intrinsics.interlocked_compare_exchange_u64(&process.shadow_used[word], seen & ~bit, seen)
        if given {
            return void
        }
    }
}

/**
 * Keep the calling CPU's current thread's shadow-stack pointer as it enters the kernel from user mode, where it has
 * one: it moves with every call and return, and the CPU has only the one in use.
 */
note_user_control_flow :: fn() {
    cpu :: per_cpu()
    if cpu.current == 0 {
        return void
    }
    thread :: cast[ptr[mut Thread]](cpu.current)
    if thread.shadow_slot != 0 {
        thread.shadow_pointer = arch.read_user_shadow_stack()
    }
}
