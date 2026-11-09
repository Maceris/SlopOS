package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Starting the other CPUs, one at a time (docs/specs/boot_info.md, CPUs). The boot CPU gives each
 * one a PerCpu and stacks, and starts it with the PerCpu's carrier block; the CPU sets itself up
 * and reports in. A CPU that doesn't within CPU_START_TIMEOUT_MS is given up on, and so are the
 * ones after it.
 */

/**
 * How long the boot CPU waits for a CPU it started to report in, in milliseconds, before giving up on it and the ones
 * after it.
 */
CPU_START_TIMEOUT_MS :: 1000

// PerCpu.start_state.
/** The CPU has been started but hasn't reported in yet, and the boot CPU still waits for it. */
CPU_WAITING : u32 : 0
/** The CPU reported in before the boot CPU gave up, and runs the kernel. */
CPU_ONLINE : u32 : 1
/** The boot CPU gave up on the CPU; if it starts after all, it halts at once (cpu_started). */
CPU_ABANDONED : u32 : 2

/**
 * Start every CPU after the boot CPU, one at a time, in kernel.cpus' order.
 *
 * Runs on the boot CPU, once its timer runs, so kernel.counter_frequency is known. Each CPU gets a PerCpu and stacks
 * (allocate_cpu) and is started at cpu_started; the boot CPU spins until it reports in or CPU_START_TIMEOUT_MS pass.
 * A CPU that can't be given memory, or doesn't report in, is left out, and so is every one after it, so the online
 * CPUs are always indices 0 to online_cpus - 1. A CPU given up on keeps its PerCpu and stacks, which it may still use.
 *
 * @param kernel The kernel, whose online_cpus is set to 1 and counts each CPU that reports in; kept by the CPUs
 *     started.
 * @param info The boot information, whose start_cpu starts a CPU; if it has none, only the boot CPU is online.
 */
start_cpus :: fn(kernel #escaping : ptr[mut Kernel], info: ptr[boot_info.BootInfo]) {
    // A copy of the view, which the calls below can't change
    cpus :: kernel.cpus
    kernel.online_cpus = 1
    start_cpu :: info.start_cpu or_return void
    timeout :: kernel.counter_frequency / 1000 * CPU_START_TIMEOUT_MS
    for index in 1..<cpus.count {
        allocated : ptr[mut PerCpu]? = null
        match allocate_cpu(kernel, cast[u32](index)) {
            case Ok(made) => allocated = made
            case Error(error) => runtime.log_warn("no memory for CPU %, so it and the ones after it are left out", index)
        }
        // Its kernel shadow stack, where the kernel's code runs on them (decisions/0186, Hd)
        match allocated {
            case Some(made) => if !give_kernel_shadow_stack(kernel, made) {
                runtime.log_warn("no memory for CPU %'s kernel shadow stack, so it and the ones after it are left out", index)
                allocated = null
            }
            case None => {}
        }
        cpu :: allocated or_break
        start_cpu(&cpus[index], &cpu.carrier, cpu_started)
        deadline :: arch.counter() + timeout
        loop {
            arch.spin_hint()
        }
        while intrinsics.atomic_load_u32_acquire(&cpu.start_state) == CPU_WAITING && arch.counter() < deadline
        // It may report in right now, so it's given up on only if it still hasn't. Its PerCpu and
        // stacks stay allocated, since it may still start and use them.
        _, abandoned :: intrinsics.interlocked_compare_exchange_u32(&cpu.start_state, CPU_ABANDONED, CPU_WAITING)
        if abandoned {
            runtime.log_warn("CPU % (hardware ID %) didn't start, so it and the ones after it are left out", index,
                cpus[index].hardware_id)
            break
        }
        kernel.online_cpus += 1
    }
    runtime.log_info("% of % CPUs online", kernel.online_cpus, cpus.count)
}

/**
 * Enter the kernel on a CPU start_cpus started, and run it there: never returns.
 *
 * Runs on the new CPU with its PerCpu's carrier block loaded, its stack_limit set for the boot stack until the CPU
 * first enters through the kernel stack. It sets the CPU up and takes the kernel's page table, then reports in by
 * moving start_state from CPU_WAITING to CPU_ONLINE; if the boot CPU already gave up on it (CPU_ABANDONED), it halts
 * instead. Online, it sets up its timer and first tick, joins the pool test if that's on, and goes idle.
 */
cpu_started :: fn() #never_returns {
    cpu :: per_cpu()
    kernel :: cpu.kernel
    arch.init_cpu(&kernel.arch, &cpu.arch, &cpu.carrier, &cpu.context, &cpu.stacks)
    arch.activate(&kernel.page_table)
    _, online :: intrinsics.interlocked_compare_exchange_u32(&cpu.start_state, CPU_ONLINE, CPU_WAITING)
    if !online {
        // Too late: the boot CPU went on without it
        arch.halt()
    }
    push_context cpu_context from cpu.context {
        // The counter's frequency is known, so this only sets the CPU's timer up
        _ = arch.init_timer(kernel.counter_frequency)
        set_next_tick(kernel)
        runtime.log_info("CPU % online", cpu.index)
        if kernel.options.test_pool {
            join_pool_test(kernel, cpu.index)
        }
        arch.idle()
    }
}

/**
 * Make a CPU's PerCpu and stacks, from the frame allocator, with its context and its carrier block pointing back at
 * the PerCpu.
 *
 * The PerCpu is recorded in kernel.per_cpus at index, with start_state CPU_WAITING. Its context has the kernel's
 * logger, heap allocator and clock. The carrier block's stack_limit is set once the CPU is on the stack it starts on.
 * Neither is ever freed.
 *
 * @param kernel The kernel, whose frames they come from; kept in the PerCpu.
 * @param index The CPU's index in kernel.cpus, below per_cpus' count, which keep_boot_info makes room for.
 * @return The CPU's PerCpu, in the direct map, owned by the kernel for good.
 * @error OutOfMemory No frames were left for the PerCpu or its stacks; a PerCpu made before the stacks failed isn't
 *     given back.
 */
allocate_cpu :: fn(kernel #escaping : ptr[mut Kernel], index: u32) -> Result[ptr[mut PerCpu], frames.FrameError] {
    cpu :: allocate_object[PerCpu](&kernel.frames)?
    stack_memory :: allocate_object[CpuStackMemory](&kernel.frames)?
    cpu.kernel = kernel
    cpu.index = index
    per_cpus :: kernel.per_cpus
    runtime.assert(cast[usize](index) < per_cpus.count, "keep_boot_info makes room for every CPU's PerCpu")
    per_cpus[index] = cast[u64](cpu)
    cpu.start_state = CPU_WAITING
    cpu.current_level = IDLE_LEVEL
    cpu.carrier.index = cast[usize](index)
    cpu.carrier.program_data = cast[rawptr](cpu)

    cpu.context = runtime.MINIMAL_CONTEXT
    cpu.context.logger = &KERNEL_LOGGER
    cpu.context.log_level = .INFO
    cpu.context.assertion_handler = kernel_assertion_handler
    cpu.context.allocator = heap_allocator(kernel)
    cpu.context.clock = &kernel.clock

    cpu.stacks.kernel = range_of(&stack_memory.kernel[0], KERNEL_STACK_SIZE)
    cpu.stacks.critical[cast[u8](arch_interface.CriticalEvent.Nmi)] = range_of(&stack_memory.nmi[0], CRITICAL_STACK_SIZE)
    cpu.stacks.critical[cast[u8](arch_interface.CriticalEvent.DoubleFault)] = range_of(&stack_memory.double_fault[0], CRITICAL_STACK_SIZE)
    cpu.stacks.critical[cast[u8](arch_interface.CriticalEvent.MachineCheck)] = range_of(&stack_memory.machine_check[0], CRITICAL_STACK_SIZE)
    return .Ok(cpu)
}

/**
 * Stop every other online CPU, with a Stop IPI each; they halt when it arrives.
 *
 * Returns once the IPIs are sent, without waiting for the CPUs to halt.
 *
 * @param kernel The kernel, whose first online_cpus CPUs, the caller's apart, are sent the IPI.
 */
stop_other_cpus :: fn(kernel: ptr[Kernel]) {
    self :: per_cpu().index
    for cpu, index in kernel.cpus {
        if index < cast[usize](kernel.online_cpus) && cast[u32](index) != self {
            arch.send_ipi(cpu.hardware_id, .Stop)
        }
    }
}
