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

CPU_START_TIMEOUT_MS :: 1000

// PerCpu.start_state.
CPU_WAITING : u32 : 0
CPU_ONLINE : u32 : 1
CPU_ABANDONED : u32 : 2

// Start every CPU after the boot CPU, on the boot CPU, once its timer runs.
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

/*
 * Where a started CPU enters the kernel, with its PerCpu's carrier block loaded, its stack_limit
 * set for the boot stack until the CPU first enters through the kernel stack.
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

/*
 * A CPU's PerCpu and stacks, from the frame allocator, with its context and its carrier block
 * pointing back at the PerCpu. The carrier block's stack_limit is set once the CPU is on the stack
 * it starts on.
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

// Stop every other CPU that's online. They halt when the IPI arrives.
stop_other_cpus :: fn(kernel: ptr[Kernel]) {
    self :: per_cpu().index
    for cpu, index in kernel.cpus {
        if index < cast[usize](kernel.online_cpus) && cast[u32](index) != self {
            arch.send_ipi(cpu.hardware_id, .Stop)
        }
    }
}
