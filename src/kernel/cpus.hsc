package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Starting the other CPUs, one at a time (docs/specs/boot_info.md, CPUs). Each one sets itself up
 * and reports in; a CPU that doesn't within CPU_START_TIMEOUT_MS is given up on, and so are the
 * ones after it.
 */

CPU_START_TIMEOUT_MS :: 1000

/*
 * What a CPU being started reads before it has a PerCpu, through its first carrier block's
 * program_data. It lives in boot's frame, which never ends, so a CPU that reports in late still
 * finds it.
 */
CpuStart :: struct {
    kernel : ptr[mut Kernel],
    index : u32,
    // CPU_WAITING until the CPU reports in (CPU_ONLINE) or the boot CPU gives up (CPU_ABANDONED).
    state : u32,
}

CPU_WAITING : u32 : 0
CPU_ONLINE : u32 : 1
CPU_ABANDONED : u32 : 2

/*
 * Start every CPU after the boot CPU, on the boot CPU, once its timer runs. start and carrier are
 * what each CPU starts with, reused for the next once it reports in.
 */
start_cpus :: fn(kernel: ptr[mut Kernel], info: ptr[boot_info.BootInfo], start: ptr[mut CpuStart],
    carrier: ptr[mut runtime.CarrierBlock]) {

    kernel.cpus = info.cpus
    kernel.online_cpus = 1
    start_cpu :: info.start_cpu or_return void
    timeout :: kernel.counter_frequency / 1000 * CPU_START_TIMEOUT_MS
    for index in 1..<info.cpus.count {
        start.kernel = kernel
        start.index = cast[u32](index)
        start.state = CPU_WAITING
        carrier^ = runtime.CarrierBlock.{}
        carrier.index = index
        carrier.program_data = cast[rawptr](start)
        start_cpu(&info.cpus[index], carrier, cpu_started)
        deadline :: arch.counter() + timeout
        loop {
            arch.spin_hint()
        }
        while intrinsics.atomic_load_u32_acquire(&start.state) == CPU_WAITING && arch.counter() < deadline
        // It may report in right now, so it's given up on only if it still hasn't
        _, abandoned :: intrinsics.interlocked_compare_exchange_u32(&start.state, CPU_ABANDONED, CPU_WAITING)
        if abandoned {
            runtime.log_warn("CPU % (hardware ID %) didn't start, so it and the ones after it are left out", index,
                info.cpus[index].hardware_id)
            break
        }
        kernel.online_cpus += 1
    }
    runtime.log_info("% of % CPUs online", kernel.online_cpus, info.cpus.count)
}

/*
 * Where a started CPU enters the kernel, with its CpuStart in the carrier block's program_data.
 * Its kernel state lives in this frame, which never ends, like the boot CPU's in boot.
 */
cpu_started :: fn() #never_returns {
    start :: cast[ptr[mut CpuStart]](intrinsics.carrier().program_data)
    kernel :: start.kernel
    //TODO(claude): allocate these from the frame allocator (M2), so the boot stack can be reclaimed
    cpu : PerCpu
    stack_memory : CpuStackMemory
    set_up_cpu(kernel, &cpu, &stack_memory, start.index)
    arch.init_cpu(&kernel.arch, &cpu.arch, &cpu.carrier, &cpu.context, &cpu.stacks)
    // From here on, start belongs to the next CPU
    _, online :: intrinsics.interlocked_compare_exchange_u32(&start.state, CPU_ONLINE, CPU_WAITING)
    if !online {
        // Too late: the boot CPU went on without it
        arch.halt()
    }
    push_context cpu_context from cpu.context {
        runtime.log_info("CPU % online", cpu.index)
        arch.idle()
    }
}

/*
 * Give a CPU its own carrier block and context, and the stacks entries use. The carrier block
 * keeps the boot stack's limit until the CPU first enters through the kernel stack.
 */
set_up_cpu :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], stack_memory: ptr[mut CpuStackMemory], index: u32) {
    cpu.kernel = kernel
    cpu.index = index
    cpu.carrier.stack_limit = intrinsics.carrier().stack_limit
    cpu.carrier.index = cast[usize](index)
    cpu.carrier.program_data = cast[rawptr](cpu)
    cpu.carrier.native_stack_limit = cpu.carrier.stack_limit
    intrinsics.set_carrier(&cpu.carrier)

    cpu.context = runtime.MINIMAL_CONTEXT
    cpu.context.logger = &KERNEL_LOGGER
    cpu.context.log_level = .INFO
    cpu.context.assertion_handler = kernel_assertion_handler

    cpu.stacks.kernel = range_of(&stack_memory.kernel[0], KERNEL_STACK_SIZE)
    cpu.stacks.critical[cast[u8](arch_interface.CriticalEvent.Nmi)] = range_of(&stack_memory.nmi[0], CRITICAL_STACK_SIZE)
    cpu.stacks.critical[cast[u8](arch_interface.CriticalEvent.DoubleFault)] = range_of(&stack_memory.double_fault[0], CRITICAL_STACK_SIZE)
    cpu.stacks.critical[cast[u8](arch_interface.CriticalEvent.MachineCheck)] = range_of(&stack_memory.machine_check[0], CRITICAL_STACK_SIZE)
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
