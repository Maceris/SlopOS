package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Tracing and sampling (decisions/0183, 12d). The trace: each CPU keeps the last slop_os.TRACE_EVENTS of its
 * scheduler's events, a thread switched to and a thread made ready, in a ring of its own, under its own lock, which
 * trace_read drains; tracing is off until trace_set or the command line's trace_boot turns it on, a ring made for each
 * CPU the first time. Sampling: an intercept that samples (intercept_sample) gets, at each tick of a CPU interrupted
 * running one of its subtree's threads in user mode, the thread's program counter and the return addresses its frame
 * pointers chain, in a ring of the last slop_os.SAMPLES, which intercept_samples drains.
 */

#if TARGET_ARCH == .arm64 {
    /** Where the frame pointer (x29) is among a thread's registers, as get_user_register numbers them. */
    SAMPLE_FRAME_REGISTER : u32 : 29
}
#else {
    /** Where the frame pointer (rbp) is among a thread's registers, as get_user_register numbers them. */
    SAMPLE_FRAME_REGISTER : u32 : 6
}

/** A CPU's trace: its last events, from the kernel heap. */
TraceRing :: struct {
    /** Held, at LockRank Trace, while events are written or taken. */
    lock : concurrency.SpinLock,
    /** How many events have been written, ever; the next goes at this modulo TRACE_EVENTS. */
    written : u64,
    /** How many have been taken: trace_read takes from here, or the oldest kept if that's later. */
    taken : u64,
    /** The events. */
    events : slop_os.TraceEvent[slop_os.TRACE_EVENTS],
}

/** An intercept's samples: its last, from the kernel heap. */
SampleRing :: struct {
    /** How many samples have been written, ever. */
    written : u64,
    /** How many have been taken. */
    taken : u64,
    /** The samples. */
    samples : slop_os.Sample[slop_os.SAMPLES],
}

/**
 * Note a scheduler's event in the calling CPU's trace, if tracing's on. Takes the ring's lock, at rank Trace, the
 * highest a scheduler's path holds, with interrupts off.
 *
 * @param kernel The kernel, whose tracing says whether it's on.
 * @param kind What happened.
 * @param thread The thread's ID.
 * @param other What else, as kind says.
 */
trace_event :: fn(kernel: ptr[mut Kernel], kind: slop_os.TraceKind, thread: u64, other: u64) {
    if intrinsics.atomic_load_u32_acquire(&kernel.tracing) == 0 {
        return void
    }
    cpu :: per_cpu()
    address :: intrinsics.atomic_load_u64_acquire(&cpu.trace_ring)
    if address == 0 {
        return void
    }
    ring :: cast[ptr[mut TraceRing]](address)
    event :: slop_os.TraceEvent.{time = cast[u64](kernel_monotonic(cast[mut rawptr](kernel))), kind = kind, cpu = cpu.index, thread = thread,
        other = other}
    lock_at(&ring.lock, .Trace)
    ring.events[cast[usize](ring.written % cast[u64](slop_os.TRACE_EVENTS))] = event
    ring.written += 1
    unlock_at(&ring.lock, .Trace)
}

/**
 * Turn tracing on or off, a ring made for each online CPU that hasn't one the first time it's on.
 *
 * @param kernel The kernel.
 * @param on Whether it's on from now.
 * @return False, with tracing as it was, if a ring couldn't be made.
 */
set_tracing :: fn(kernel: ptr[mut Kernel], on: bool) -> bool {
    if on {
        per_cpus :: kernel.per_cpus
        for address, index in per_cpus {
            if index >= cast[usize](kernel.online_cpus) || address == 0 {
                continue
            }
            cpu :: cast[ptr[mut PerCpu]](address)
            if intrinsics.atomic_load_u64_acquire(&cpu.trace_ring) != 0 {
                continue
            }
            ring, failed :: runtime.new_aligned(TraceRing, align_of(TraceRing))
            if failed != null {
                return false
            }
            intrinsics.atomic_store_u64_release(&cpu.trace_ring, cast[u64](ring))
        }
    }
    intrinsics.atomic_store_u32_release(&kernel.tracing, if on { 1 } else { 0 })
    return true
}

/**
 * Take the trace's events not yet taken into a buffer of the caller's, each CPU's in turn.
 *
 * @param kernel The kernel.
 * @param space The caller's address space.
 * @param buffer Where they go, in the caller's memory.
 * @param capacity How many fit.
 * @return How many were written; null if the buffer couldn't be written.
 */
read_trace :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], buffer: u64, capacity: u64) -> u32? {
    count : u64 = 0
    per_cpus :: kernel.per_cpus
    for address, index in per_cpus {
        if address == 0 || count >= capacity {
            continue
        }
        cpu :: cast[ptr[mut PerCpu]](address)
        ring_address :: intrinsics.atomic_load_u64_acquire(&cpu.trace_ring)
        if ring_address == 0 {
            continue
        }
        ring :: cast[ptr[mut TraceRing]](ring_address)
        loop {
            event := slop_os.TraceEvent.{}
            lock_at(&ring.lock, .Trace)
            kept :: if ring.written > cast[u64](slop_os.TRACE_EVENTS) { ring.written - cast[u64](slop_os.TRACE_EVENTS) } else { 0 }
            if ring.taken < kept {
                ring.taken = kept
            }
            more :: ring.taken < ring.written
            if more {
                event = ring.events[cast[usize](ring.taken % cast[u64](slop_os.TRACE_EVENTS))]
                ring.taken += 1
            }
            unlock_at(&ring.lock, .Trace)
            if !more || count >= capacity {
                break
            }
            if !copy_to_user(kernel, space, buffer + count * cast[u64](size_of(slop_os.TraceEvent)), cast[u64](&event),
                cast[u64](size_of(slop_os.TraceEvent))) {
                return null
            }
            count += 1
        }
    }
    return cast[u32](count)
}

/**
 * Take a sample of the calling CPU's current thread, interrupted in user mode at a tick, for the intercept of its
 * subtree, if that samples. Reads the thread's stack through its space's lock; called at the interrupt's entry, with
 * no lock held.
 *
 * @param kernel The kernel.
 */
take_sample :: fn(kernel: ptr[mut Kernel]) {
    if intrinsics.atomic_load_u32_acquire(&kernel.intercepts) == 0 {
        return void
    }
    cpu :: per_cpu()
    if cpu.current == 0 {
        return void
    }
    thread :: cast[ptr[mut Thread]](cpu.current)
    found :: intercept_of(kernel, thread)
    if found == 0 {
        return void
    }
    intercept :: cast[ptr[mut Intercept]](found)
    ring_address :: intrinsics.atomic_load_u64_acquire(&intercept.samples)
    if intrinsics.atomic_load_u32_acquire(&intercept.sampling) == 0 || ring_address == 0 {
        return void
    }
    sample := slop_os.Sample.{thread = thread.id, count = 1}
    sample.frames[0] = cast[u64](arch.instruction_pointer(&thread.registers))
    frame := arch.get_user_register(&thread.registers, SAMPLE_FRAME_REGISTER)
    for depth in cast[usize](1)..<sample.frames.count {
        record : u64[2]
        if frame == 0 || frame & 7 != 0 || !copy_from_user(kernel, thread.space, frame, cast[u64](&record[0]), 16) || record[1] == 0 {
            break
        }
        sample.frames[depth] = record[1]
        sample.count = cast[u32](depth) + 1
        if record[0] <= frame {
            break
        }
        frame = record[0]
    }
    ring :: cast[ptr[mut SampleRing]](ring_address)
    lock_at(&intercept.lock, .Intercept)
    // Unless free_samples took it meanwhile
    if intercept.samples == ring_address {
        ring.samples[cast[usize](ring.written % cast[u64](slop_os.SAMPLES))] = sample
        ring.written += 1
    }
    unlock_at(&intercept.lock, .Intercept)
}

/**
 * Turn an intercept's sampling on or off, its ring made the first time it's on.
 *
 * @param intercept The intercept.
 * @param on Whether it samples from now.
 * @return False, with sampling as it was, if its ring couldn't be made.
 */
set_sampling :: fn(intercept: ptr[mut Intercept], on: bool) -> bool {
    if on && intrinsics.atomic_load_u64_acquire(&intercept.samples) == 0 {
        ring, failed :: runtime.new_aligned(SampleRing, align_of(SampleRing))
        if failed != null {
            return false
        }
        lock_at(&intercept.lock, .Intercept)
        if intercept.samples == 0 {
            intrinsics.atomic_store_u64_release(&intercept.samples, cast[u64](ring))
            unlock_at(&intercept.lock, .Intercept)
        }
        else {
            unlock_at(&intercept.lock, .Intercept)
            runtime.free(ring)
        }
    }
    intrinsics.atomic_store_u32_release(&intercept.sampling, if on { 1 } else { 0 })
    return true
}

/**
 * Take an intercept's samples not yet taken into a buffer of the caller's, oldest first.
 *
 * @param kernel The kernel.
 * @param intercept The intercept.
 * @param space The caller's address space.
 * @param buffer Where they go, in the caller's memory.
 * @param capacity How many fit.
 * @return How many were written; null if the buffer couldn't be written.
 */
read_samples :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept], space: ptr[mut AddressSpace], buffer: u64, capacity: u64) -> u32? {
    ring_address :: intrinsics.atomic_load_u64_acquire(&intercept.samples)
    if ring_address == 0 {
        return 0
    }
    ring :: cast[ptr[mut SampleRing]](ring_address)
    count : u64 = 0
    loop {
        sample := slop_os.Sample.{}
        lock_at(&intercept.lock, .Intercept)
        kept :: if ring.written > cast[u64](slop_os.SAMPLES) { ring.written - cast[u64](slop_os.SAMPLES) } else { 0 }
        if ring.taken < kept {
            ring.taken = kept
        }
        more :: ring.taken < ring.written && count < capacity
        if more {
            sample = ring.samples[cast[usize](ring.taken % cast[u64](slop_os.SAMPLES))]
            ring.taken += 1
        }
        unlock_at(&intercept.lock, .Intercept)
        if !more {
            break
        }
        if !copy_to_user(kernel, space, buffer + count * cast[u64](size_of(slop_os.Sample)), cast[u64](&sample), cast[u64](size_of(slop_os.Sample))) {
            return null
        }
        count += 1
    }
    return cast[u32](count)
}

/**
 * Let go of an intercept's samples, as it's destroyed. Takes its lock, so a sample being taken on another CPU sees
 * them gone (take_sample).
 *
 * @param intercept The intercept, whose sampling and samples are 0 after.
 */
free_samples :: fn(intercept: ptr[mut Intercept]) {
    lock_at(&intercept.lock, .Intercept)
    address :: intercept.samples
    intrinsics.atomic_store_u32_release(&intercept.sampling, 0)
    intrinsics.atomic_store_u64_release(&intercept.samples, 0)
    unlock_at(&intercept.lock, .Intercept)
    if address != 0 {
        runtime.free(cast[ptr[mut SampleRing]](address))
    }
}
