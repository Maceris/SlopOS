package kernel

import intrinsics from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * A ticket lock: CPUs take a ticket and are served in order, so none waits forever while others
 * keep taking the lock. The kernel runs with interrupts disabled, so a holder is never interrupted
 * by code that wants the same lock, except NMIs, which mustn't take locks.
 */
//STD(missing): a portable spin-wait hint in base (pause, yield), so this could live in std's concurrency
SpinLock :: struct {
    next_ticket : u32,
    now_serving : u32,
}

lock :: fn(spin_lock: ptr[mut SpinLock]) {
    ticket :: intrinsics.interlocked_exchange_add_u32_no_fence(&spin_lock.next_ticket, 1)
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u32_acquire(&spin_lock.now_serving) != ticket
}

unlock :: fn(spin_lock: ptr[mut SpinLock]) {
    // Only the holder writes now_serving
    serving :: intrinsics.atomic_load_u32_no_fence(&spin_lock.now_serving)
    intrinsics.atomic_store_u32_release(&spin_lock.now_serving, serving + 1)
}
