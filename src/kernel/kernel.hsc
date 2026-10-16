/*
 * The kernel core (L2): portable, using only the arch layer, BootInfo and std's freestanding and
 * allocating tiers (docs/architecture/layers.md, L2).
 *
 * So far it boots, sets up the boot CPU's entries and timer, starts the other CPUs, which go idle,
 * and halts after a few timer interrupts (roadmap M1, M3).
 */
package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import slop_os from "std/os"
import console from "console"
import frames from "frames"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

// Each CPU's kernel stack, where every entry runs (decisions/0023)
KERNEL_STACK_SIZE :: 16 * 1024
// Each CPU's stacks for NMIs, double faults and machine checks
CRITICAL_STACK_SIZE :: 4 * 1024

// State shared by every CPU, allocated once at boot and synchronized internally.
Kernel :: struct {
    arch : arch.ArchSystem,
    features : slop_os.CpuFeatures,
    // Of arch.counter(), in Hz.
    counter_frequency : u64,
    // Where the kernel image is, for stack traces relative to it.
    image_base : u64,
    // Every CPU, the boot CPU first. The first online_cpus of them are running.
    cpus : boot_info.BootCpu[],
    online_cpus : u32,
    options : Options,
    // Every frame of RAM the kernel owns.
    frames : frames.FrameAllocator,
    // Held while writing a line to the console, so lines from different CPUs don't mix.
    console_lock : concurrency.SpinLock,
    // Text on the first framebuffer, if there is one and it could be set up.
    framebuffer_console : console.Console,
    has_framebuffer_console : bool,
}

/*
 * One CPU's state. Its carrier block's program_data points back here, so kernel code reaches it
 * with per_cpu() (docs/architecture/layers.md, L1).
 */
PerCpu :: struct #align(64) {
    carrier : runtime.CarrierBlock,
    // What every entry on this CPU runs with.
    context : runtime.Context,
    kernel : ptr[mut Kernel],
    index : u32,
    arch : arch.ArchCpu,
    stacks : arch_interface.CpuStacks,
    timer_ticks : u64,
    // NMIs this CPU has handled.
    nmi_count : u32,
    // CPU_WAITING while the boot CPU starts this one, then CPU_ONLINE or CPU_ABANDONED (cpus.hsc).
    start_state : u32,
}

// The memory for one CPU's stacks.
CpuStackMemory :: struct #align(64) {
    kernel : u8[KERNEL_STACK_SIZE],
    nmi : u8[CRITICAL_STACK_SIZE],
    double_fault : u8[CRITICAL_STACK_SIZE],
    machine_check : u8[CRITICAL_STACK_SIZE],
}

// The calling CPU's PerCpu.
per_cpu :: fn() -> ptr[mut PerCpu] {
    return cast[ptr[mut PerCpu]](intrinsics.carrier().program_data)
}

/*
 * The portable kernel entry, called by the boot adapter (L0) on the boot CPU with interrupts
 * disabled, the boot context pushed, and the bootloader's page tables
 * (docs/specs/boot_info.md, Handoff).
 */
boot #never_returns :: fn(info: ptr[boot_info.BootInfo]) {
    options :: parse_command_line(info.command_line)
    log_boot_info(info)
    features :: arch.detect_features()
    check_baseline(&options, &features)

    // The kernel's state, in frames from the allocator, which starts out on this stack
    made := match frames.make(info.memory_map, info.direct_map_offset) {
        case Ok(allocator) => allocator
        case Error(error) => out_of_memory(&options, "no usable memory for the frame allocator's state")
    }
    /*
     * Its frames' address, not allocate_object: made is on this stack, so what allocate_object gives
     * for it would count as pointing here (Hemera's docs/memory.md, Returning). A frame's address
     * doesn't, being a physical address in the direct map.
     */
    kernel_frames :: frames.allocate_zeroed(&made, frames.order_for(cast[u64](size_of(Kernel))))
        or_else out_of_memory(&options, "no memory for the kernel's state")
    kernel :: cast[ptr[mut Kernel]](frames.virtual_of(&made, kernel_frames))
    kernel.frames = made
    log_memory(&kernel.frames)
    kernel.features = features
    kernel.options = options
    kernel.image_base = cast[u64](info.kernel_image.virtual_base)
    kernel.cpus = info.cpus[0..<1]
    kernel.online_cpus = 1
    cpu :: allocate_cpu(kernel, 0) or_else out_of_memory(&options, "no memory for the boot CPU's state")
    // The boot CPU keeps its boot stack's limit until it first enters through the kernel stack
    cpu.carrier.stack_limit = intrinsics.carrier().stack_limit
    cpu.carrier.native_stack_limit = cpu.carrier.stack_limit
    intrinsics.set_carrier(&cpu.carrier)
    arch.init_system(&kernel.arch)
    arch.init_cpu(&kernel.arch, &cpu.arch, &cpu.carrier, &cpu.context, &cpu.stacks)
    runtime.log_info("boot CPU set up: descriptor tables, entries and local APIC")
    start_framebuffer_console(kernel, info)
    push_context cpu_context from cpu.context {
        start_timer(kernel, info.counter_frequency_hint)
        start_cpus(kernel, info)
        if kernel.options.test_fault {
            runtime.log_info("test_fault: running an invalid instruction")
            intrinsics.trap()
        }
        if kernel.options.test_nmi {
            test_nmi(kernel, cpu)
        }
        if kernel.options.test_assert {
            runtime.log_info("test_assert: failing an assertion")
            runtime.assert(false, "test_assert")
        }
        runtime.log_info("idle")
        arch.idle()
    }
}

/*
 * A T in frames of its own, zeroed: the kernel's state that lives as long as it does. T's
 * alignment is at most a frame's.
 */
allocate_object :: fn[T](allocator: ptr[mut frames.FrameAllocator]) -> Result[ptr[mut T], frames.FrameError] {
    address :: frames.allocate_zeroed(allocator, frames.order_for(cast[u64](size_of(T))))?
    return .Ok(cast[ptr[mut T]](frames.virtual_of(allocator, address)))
}

log_memory :: fn(allocator: ptr[frames.FrameAllocator]) {
    runtime.log_info("frames: % MiB free of % MiB", allocator.free_frames / 256, allocator.total_frames / 256)
}

out_of_memory :: fn(options: ptr[Options], message: string) #never_returns {
    runtime.log_fatal(message)
    stop_with(options, .OutOfMemory)
}

// Raise an NMI, and wait up to a second for this CPU to handle it and come back.
test_nmi :: fn(kernel: ptr[Kernel], cpu: ptr[mut PerCpu]) {
    runtime.log_info("test_nmi: raising an NMI")
    arch.test_nmi()
    deadline :: arch.counter() + kernel.counter_frequency
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u32_acquire(&cpu.nmi_count) == 0 && arch.counter() < deadline
    if cpu.nmi_count == 0 {
        runtime.log_error("test_nmi: no NMI arrived")
        return void
    }
    runtime.log_info("test_nmi: back from the NMI")
}

// Stops with a message if the CPU lacks part of the baseline (decisions/0003).
check_baseline :: fn(options: ptr[Options], features: ptr[slop_os.CpuFeatures]) {
    missing :: arch.missing_baseline_feature(features) or_return void
    runtime.log_fatal("SlopOS needs an x86-64-v3 CPU, and this one lacks %", missing)
    stop_with(options, .CpuUnsupported)
}

/*
 * Show the log on the first framebuffer too. Without one, or if it can't be used, the log stays on
 * the early console.
 */
start_framebuffer_console :: fn(kernel: ptr[mut Kernel], info: ptr[boot_info.BootInfo]) {
    if info.framebuffers.count == 0 {
        runtime.log_info("no framebuffer: the log stays on the serial console")
        return void
    }
    match console.make_console(&info.framebuffers[0], info.direct_map_offset) {
        case Ok(made) => {
            // No other CPU runs yet, so nothing writes to the console while it's set up
            kernel.framebuffer_console = made
            kernel.has_framebuffer_console = true
            log_framebuffer(&kernel.framebuffer_console)
        }
        case Error(error) => runtime.log_warn("the framebuffer can't show the console")
    }
}

log_framebuffer :: fn(screen: ptr[console.Console]) {
    runtime.log_info("framebuffer console: %x% characters on %x% pixels", screen.columns, screen.rows, screen.width,
        screen.height)
}

range_of :: fn(low: ptr[u8], size: u64) -> arch_interface.StackRange {
    base :: cast[u64](low)
    return arch_interface.StackRange.{
        low = cast[arch_interface.VirtualAddress](base),
        high = cast[arch_interface.VirtualAddress](base + size),
    }
}
