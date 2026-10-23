package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * TLB shootdown (roadmap M3, docs/specs/arch_interface.md, Rules for L2): after a mapping changes,
 * every CPU that may have it in its TLB flushes it before what it mapped is used again.
 *
 * One shootdown runs at a time. Its CPU puts the batch where every CPU can read it, asks each other
 * online CPU to flush with a TlbFlush IPI, flushes its own TLB, and waits until all have. A CPU
 * flushes when the IPI takes it from idle, or while it waits for a shootdown of its own to start,
 * so two CPUs starting shootdowns at once don't wait on each other. Since the kernel runs with
 * interrupts disabled, a CPU holding a lock another waits for could wait for that one forever, so
 * a shootdown starts with no other lock held.
 */

Shootdown :: struct {
    // 0, or 1 while a shootdown runs.
    running : u32,
    batch : arch_interface.TlbBatch,
    // CPUs that haven't flushed this batch yet.
    pending : u32,
}

/*
 * Flush batch from every online CPU's TLB, this one's included, and return once they all have.
 * Called with no other lock held.
 */
shootdown :: fn(kernel: ptr[mut Kernel], batch: ptr[arch_interface.TlbBatch]) {
    cpu :: per_cpu()
    loop {
        flush_for_shootdown(cpu)
        arch.spin_hint()
    }
    while !start_shootdown(&kernel.shootdown)
    kernel.shootdown.batch = batch^
    cpus :: kernel.cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    others : u32 = 0
    for index in 0..<cpus.count {
        if index < online && cast[u32](index) != cpu.index {
            others += 1
        }
    }
    intrinsics.atomic_store_u32_release(&kernel.shootdown.pending, others)
    for other, index in cpus {
        if index < online && cast[u32](index) != cpu.index {
            per_cpus :: kernel.per_cpus
            runtime.assert(index < per_cpus.count, "every online CPU has a PerCpu")
            target :: cast[ptr[mut PerCpu]](per_cpus[index])
            intrinsics.atomic_store_u32_release(&target.flush_requested, 1)
            arch.send_ipi(other.hardware_id, .TlbFlush)
        }
    }
    arch.flush_tlb(&kernel.shootdown.batch)
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u32_acquire(&kernel.shootdown.pending) != 0
    intrinsics.atomic_store_u32_release(&kernel.shootdown.running, 0)
}

start_shootdown :: fn(shootdown: ptr[mut Shootdown]) -> bool {
    _, started :: intrinsics.interlocked_compare_exchange_u32_acquire(&shootdown.running, 1, 0)
    return started
}

/*
 * Flush this CPU's TLB for the shootdown waiting on it, if there is one: at a TlbFlush IPI, and while
 * waiting to start a shootdown.
 */
flush_for_shootdown :: fn(cpu: ptr[mut PerCpu]) {
    if intrinsics.atomic_load_u32_acquire(&cpu.flush_requested) == 0 {
        return void
    }
    kernel :: cpu.kernel
    arch.flush_tlb(&kernel.shootdown.batch)
    intrinsics.atomic_store_u32_no_fence(&cpu.flush_requested, 0)
    intrinsics.interlocked_decrement_u32_release(&kernel.shootdown.pending)
}
