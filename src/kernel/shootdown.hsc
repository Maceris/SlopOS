package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import shootdowns from "shootdowns"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
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
 * a shootdown starts with no other lock held. Its handshake is the shootdowns package's. While it
 * waits, interrupts off, its ticks don't come, so it checks the other CPUs for lockups itself
 * (lockups.hsc): one stuck with interrupts off never flushes, and would stop it too.
 */

/** The kernel's one TLB shootdown at a time: the batch being flushed and who hasn't flushed it yet. */
Shootdown :: struct {
    /** Which shootdown runs, and who hasn't flushed its batch. */
    handshake : shootdowns.Handshake,
    /** What the running shootdown flushes, copied here so every CPU can read it until each has flushed. */
    batch : arch_interface.TlbBatch,
}

/**
 * Flush a batch from every online CPU's TLB, this one's included, and return once they all have.
 *
 * Waits for any other shootdown to finish first, flushing for it meanwhile, so two CPUs starting shootdowns at once
 * don't wait on each other. Each other online CPU is sent a TlbFlush IPI and spun on until it has flushed, a CPU
 * that's stuck and never does reported as a lockup, which stops the kernel. Called with no lock held, since a CPU
 * holding one another CPU waits for, with interrupts off, would never take the IPI.
 *
 * @param kernel The kernel, whose shootdown state and online CPUs are used.
 * @param batch The TLB entries to flush, copied before the IPIs go, so it needn't outlive the call.
 */
shootdown :: fn(kernel: ptr[mut Kernel], batch: ptr[arch_interface.TlbBatch]) {
    cpu :: per_cpu()
    loop {
        flush_for_shootdown(cpu)
        check_lockups_while_waiting(kernel, cpu)
        arch.spin_hint()
    }
    while !shootdowns.try_start(&kernel.shootdown.handshake)
    kernel.shootdown.batch = batch^
    cpus :: kernel.cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    others : u32 = 0
    for index in 0..<cpus.count {
        if index < online && cast[u32](index) != cpu.index {
            others += 1
        }
    }
    shootdowns.expect_flushes(&kernel.shootdown.handshake, others)
    for other, index in cpus {
        if index < online && cast[u32](index) != cpu.index {
            per_cpus :: kernel.per_cpus
            runtime.assert(index < per_cpus.count, "every online CPU has a PerCpu")
            target :: cast[ptr[mut PerCpu]](per_cpus[index])
            shootdowns.request(&target.flush_requested)
            arch.send_ipi(other.hardware_id, .TlbFlush)
        }
    }
    arch.flush_tlb(&kernel.shootdown.batch)
    loop {
        check_lockups_while_waiting(kernel, cpu)
        arch.spin_hint()
    }
    while !shootdowns.all_flushed(&kernel.shootdown.handshake)
    shootdowns.finish(&kernel.shootdown.handshake)
}

/**
 * Flush this CPU's TLB for the shootdown waiting on it, if there is one, and tell the shootdown's CPU it has.
 *
 * Called at a TlbFlush IPI, and while waiting to start a shootdown. Does nothing if no flush was requested of this CPU.
 *
 * @param cpu The calling CPU's PerCpu, whose flush_requested is cleared once it has flushed.
 */
flush_for_shootdown :: fn(cpu: ptr[mut PerCpu]) {
    if !shootdowns.is_requested(&cpu.flush_requested) {
        return void
    }
    kernel :: cpu.kernel
    arch.flush_tlb(&kernel.shootdown.batch)
    shootdowns.flushed(&kernel.shootdown.handshake, &cpu.flush_requested)
}
