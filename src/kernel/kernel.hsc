/*
 * The kernel core (L2): portable, using only the arch layer, BootInfo and std's freestanding and
 * allocating tiers (docs/architecture/layers.md, L2).
 *
 * So far it boots one CPU, sets up its entries and timer, and halts after a few timer interrupts
 * (roadmap M1).
 */
package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import slop_os from "std/os"
import text_buffer from "std"
import console from "console"
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
    options : Options,
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

    /*
     * Until there's a frame allocator, the kernel's state lives in this frame, which never ends:
     * after boot, every entry runs on the kernel stacks below.
     */
    //TODO(claude): allocate these from the frame allocator (M2), so the boot stack can be reclaimed
    kernel : Kernel
    cpu : PerCpu
    stack_memory : CpuStackMemory
    kernel.features = features
    kernel.options = options
    kernel.image_base = cast[u64](info.kernel_image.virtual_base)
    start_boot_cpu(&kernel, &cpu, &stack_memory)
    start_framebuffer_console(&kernel, info)
    push_context cpu_context from cpu.context {
        start_timer(&kernel, info.counter_frequency_hint)
        if kernel.options.test_fault {
            runtime.log_info("test_fault: running an invalid instruction")
            intrinsics.trap()
        }
        if kernel.options.test_assert {
            runtime.log_info("test_assert: failing an assertion")
            runtime.assert(false, "test_assert")
        }
        runtime.log_info("idle")
        arch.idle()
    }
}

// Stops with a message if the CPU lacks part of the baseline (decisions/0003).
check_baseline :: fn(options: ptr[Options], features: ptr[slop_os.CpuFeatures]) {
    missing :: arch.missing_baseline_feature(features) or_return void
    storage : u8[160]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "SlopOS needs an x86-64-v3 CPU, and this one lacks ")
    text_buffer.append(&line, missing)
    runtime.log_fatal(text_buffer.as_string(&line))
    stop_with(options, .CpuUnsupported)
}

/*
 * Give the boot CPU its own carrier block and context, then set up the architecture's state for it.
 * The carrier block keeps the boot stack's limit until the CPU first enters through the kernel stack.
 */
start_boot_cpu :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], stack_memory: ptr[mut CpuStackMemory]) {
    cpu.kernel = kernel
    cpu.index = 0
    cpu.carrier.stack_limit = intrinsics.carrier().stack_limit
    cpu.carrier.index = 0
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

    arch.init_system(&kernel.arch)
    arch.init_cpu(&kernel.arch, &cpu.arch, &cpu.carrier, &cpu.context, &cpu.stacks)
    runtime.log_info("boot CPU set up: descriptor tables, entries and local APIC")
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
    storage : u8[96]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "framebuffer console: ")
    text_buffer.append_unsigned(&line, cast[u64](screen.columns))
    text_buffer.append(&line, "x")
    text_buffer.append_unsigned(&line, cast[u64](screen.rows))
    text_buffer.append(&line, " characters on ")
    text_buffer.append_unsigned(&line, cast[u64](screen.width))
    text_buffer.append(&line, "x")
    text_buffer.append_unsigned(&line, cast[u64](screen.height))
    text_buffer.append(&line, " pixels")
    runtime.log_info(text_buffer.as_string(&line))
}

range_of :: fn(low: ptr[u8], size: u64) -> arch_interface.StackRange {
    base :: cast[u64](low)
    return arch_interface.StackRange.{
        low = cast[arch_interface.VirtualAddress](base),
        high = cast[arch_interface.VirtualAddress](base + size),
    }
}
