package kernel

import intrinsics from "base"
import maps from "std"
import testing from "std"
import text_buffer from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_binding_reuse: one binding slot unbound and bound again, over and over, on two ports in turn, while every other
 * CPU reads its port and its generation without a lock, as lock_bound_port and a binding slot's free check read a
 * binding kept after its port let it go. Each read has to be a value the slot held whole: its port 0 or one of the two
 * ports, its generation never behind the one read before it. Making a slot anew once zeroed it a byte at a time
 * with its port still in it, so a reader could take part of a port's address for a port and lock what's there
 * (decisions/0052). The other CPUs read when a reschedule IPI takes them from idle (read_for_binding_reuse_test).
 */
/** How many times the slot is unbound and bound again. */
BINDING_REUSE_ROUNDS :: 20000
/** How long the boot CPU waits for the other CPUs to start reading, and then to stop, in milliseconds. */
BINDING_REUSE_TIMEOUT_MS :: 1000
/** The key the slot is bound to, on whichever port has it. */
BINDING_REUSE_KEY : u64 : 1

/** test_binding_reuse's state, which the other CPUs reach through kernel.binding_reuse_test while it runs. */
BindingReuseTest :: struct {
    /** The binding slot's address: the one the binding pool gives back each time it's bound again. */
    binding : u64,
    /** The first port, by address, which has the slot on even rounds. */
    first : u64,
    /** The second port, by address, which has the slot on odd rounds. */
    second : u64,
    /** 1 while the boot CPU binds and unbinds; the readers read until it's 0. */
    running : u32,
    /** Readers that have started, incremented atomically. */
    started : u32,
    /** Readers that have stopped, incremented atomically. */
    stopped : u32,
    /** Reads made in all, added atomically as each reader stops. */
    reads : u64,
    /** Ports read that were neither 0 nor one of the two ports, counted atomically. */
    torn_ports : u64,
    /** Generations read that were behind the one read before them, counted atomically. */
    torn_generations : u64,
    /** The last port read that was neither 0 nor one of the two, for the failure's message; 0 for none. */
    torn_port : u64,
}

/**
 * Run test_binding_reuse on the boot CPU at boot, reporting it to the kernel's log.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu.
 */
test_binding_reuse :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_binding_reuse", testing.Test.[.{name = "a_binding_slot_reads_whole_while_it_is_made_anew",
        run = a_binding_slot_reads_whole_while_it_is_made_anew}])
}

/**
 * Check that a binding slot reads whole, without a lock, while it's unbound and bound again: the boot CPU moves one
 * binding between two ports BINDING_REUSE_ROUNDS times while every other CPU reads it.
 *
 * Runs on the boot CPU, with 2 CPUs or more online. Its state is never freed; the ports are destroyed once the readers
 * have stopped, or left as they are if they never do.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if there's only one CPU, no memory for the state or the ports, a bind fails, the pool
 *     doesn't give the slot back, or the other CPUs don't start or stop reading in time.
 */
a_binding_slot_reads_whole_while_it_is_made_anew #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    others :: kernel.online_cpus - 1
    testing.require_ge(t, others, 1, "the test is booted with other CPUs to read the slot")?
    made :: allocate_object[BindingReuseTest](&kernel.frames)
    test :: testing.require_ok(t, made, "a boot's free frames hold the test's state")?
    first_made :: create_port(kernel, 0, 0)
    first :: testing.require_ok(t, first_made, "the port pool has a slot at boot")?
    second_made :: create_port(kernel, 0, 0)
    second :: testing.require_ok(t, second_made, "the port pool has a second slot at boot")?
    testing.require(t, port_bind_wake(kernel, first, BINDING_REUSE_KEY) == null, "a new port binds a key")?
    test.binding = maps.map_get(&first.bindings, BINDING_REUSE_KEY) or_else 0
    test.first = cast[u64](first)
    test.second = cast[u64](second)
    intrinsics.atomic_store_u32(&test.running, 1)
    intrinsics.atomic_store_u64_release(&kernel.binding_reuse_test, cast[u64](test))
    cpus :: kernel.cpus
    for cpu, index in cpus {
        if index > 0 && index < cast[usize](kernel.online_cpus) {
            arch.send_ipi(cpu.hardware_id, .Reschedule)
        }
    }
    all_started :: wait_for_readers(kernel, &test.started, others)
    same := true
    if all_started {
        for round in 0..<BINDING_REUSE_ROUNDS {
            from :: if round % 2 == 0 { first } else { second }
            to :: if round % 2 == 0 { second } else { first }
            unbound :: port_unbind(kernel, from, BINDING_REUSE_KEY) == null
            bound :: unbound && port_bind_wake(kernel, to, BINDING_REUSE_KEY) == null
            same = bound && (maps.map_get(&to.bindings, BINDING_REUSE_KEY) or_else 0) == test.binding
            if !same {
                break
            }
        }
    }
    intrinsics.atomic_store_u32_release(&test.running, 0)
    all_stopped :: wait_for_readers(kernel, &test.stopped, intrinsics.atomic_load_u32_acquire(&test.started))
    testing.require(t, all_started, "every other CPU starts reading when asked")?
    testing.require(t, all_stopped, "every reader stops once the boot CPU is done")?
    intrinsics.atomic_store_u64_release(&kernel.binding_reuse_test, 0)
    _ = destroy_object(kernel, cast[u64](first))
    _ = destroy_object(kernel, cast[u64](second))
    testing.require(t, same, "unbinding and binding again gives back the binding pool's slot the readers read")?
    storage : u8[testing.TEXT_BYTES]
    message := text_buffer.make(storage)
    text_buffer.append_format(&message, "the slot's port reads 0 or a port, never part of an address (the last: %{#x})",
        intrinsics.atomic_load_u64(&test.torn_port))
    torn_ports :: intrinsics.atomic_load_u64(&test.torn_ports)
    ports_whole :: testing.expect_eq(t, torn_ports, 0, text_buffer.as_string(&message))
    generations_whole :: testing.expect_eq(t, intrinsics.atomic_load_u64(&test.torn_generations), 0,
        "the slot's generation never reads behind what it read before, as it would part zeroed")
    read :: testing.expect_gt(t, intrinsics.atomic_load_u64(&test.reads), 0,
        "the other CPUs read the slot while it was made anew")
    return testing.outcome_of(ports_whole && generations_whole && read)
}

/**
 * Wait for a count of readers to reach a number, up to BINDING_REUSE_TIMEOUT_MS.
 *
 * @param kernel The kernel, whose counter frequency times the wait.
 * @param count The count, read atomically.
 * @param wanted The number it has to reach.
 * @return True if it reached wanted in time.
 */
wait_for_readers :: fn(kernel: ptr[Kernel], count: ptr[u32], wanted: u32) -> bool {
    deadline :: arch.counter() + kernel.counter_frequency / 1000 * BINDING_REUSE_TIMEOUT_MS
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u32_acquire(count) < wanted && arch.counter() < deadline
    return intrinsics.atomic_load_u32_acquire(count) >= wanted
}

/**
 * Read test_binding_reuse's slot until the boot CPU is done with it, counting what didn't read whole; called at a
 * Reschedule IPI.
 *
 * Does nothing if kernel.binding_reuse_test is 0. Spins with interrupts disabled, answering TLB shootdowns as it goes,
 * since a shootdown waits for every CPU.
 */
read_for_binding_reuse_test :: fn() {
    cpu :: per_cpu()
    address :: intrinsics.atomic_load_u64_acquire(&cpu.kernel.binding_reuse_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut BindingReuseTest]](address)
    binding :: cast[ptr[Binding]](test.binding)
    _ = intrinsics.interlocked_increment_u32_release(&test.started)
    reads : u64 = 0
    last := intrinsics.atomic_load_u32(&binding.generation)
    loop {
        port :: intrinsics.atomic_load_u64(&binding.port)
        if port != 0 && port != test.first && port != test.second {
            _ = intrinsics.interlocked_increment_u64(&test.torn_ports)
            intrinsics.atomic_store_u64(&test.torn_port, port)
        }
        generation :: intrinsics.atomic_load_u32(&binding.generation)
        // It only goes up, wrapping past 0xffffffff, a few steps between reads; part zeroed, it would go back
        if generation - last >= 0x80000000 {
            _ = intrinsics.interlocked_increment_u64(&test.torn_generations)
        }
        last = generation
        reads += 1
        flush_for_shootdown(cpu)
    }
    while intrinsics.atomic_load_u32_acquire(&test.running) != 0
    _ = intrinsics.interlocked_exchange_add_u64(&test.reads, reads)
    _ = intrinsics.interlocked_increment_u32_release(&test.stopped)
}
