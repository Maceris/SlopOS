/**
 * The kernel core (L2): portable, using only the arch layer, BootInfo and std's freestanding and
 * allocating tiers (docs/architecture/layers.md, L2).
 *
 * So far it boots, sets up the boot CPU's entries, its own page tables and the timer, starts the
 * other CPUs, reclaims boot memory, runs whatever user threads its tests start, and halts after a few
 * timer interrupts (roadmap M1 to M4).
 */
package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import slop_os from "std/os"
import console from "console"
import frames from "frames"
import slab from "slab"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/** The bytes of each CPU's kernel stack, where every entry runs (decisions/0023): 16 KiB. */
KERNEL_STACK_SIZE :: 16 * 1024
/** The bytes of each of a CPU's stacks for NMIs, double faults and machine checks: 4 KiB each. */
CRITICAL_STACK_SIZE :: 4 * 1024

/**
 * State shared by every CPU, allocated once at boot and synchronized internally.
 *
 * It lives in frames of its own in the direct map from boot until the kernel stops, so a pointer to it never goes
 * stale. Each field says what guards it; one that says nothing is written only on the boot CPU before the other CPUs
 * start, and read only after.
 */
Kernel :: struct {
    /** The architecture's system-wide state, set up by arch.init_system at boot. */
    arch : arch.ArchSystem,
    /** The boot CPU's features, which every CPU is taken to share; passed on in the root task's startup block. */
    features : slop_os.CpuFeatures,
    /** The frequency of arch.counter(), in Hz: counter ticks per second, the unit of every kernel deadline. */
    counter_frequency : u64,
    /** The kernel image's virtual base address, so stack traces show addresses relative to it. */
    image_base : u64,
    /**
     * Every CPU the boot information lists, the boot CPU first; kept past boot (keep_boot_info). Only the first
     * online_cpus of them are running.
     */
    cpus : boot_info.BootCpu[],
    /**
     * How many CPUs are running: the first this many of cpus, by index. Starts at 1 and only grows as CPUs start
     * (cpus.hsc); read with an acquire load.
     */
    online_cpus : u32,
    /** The options parsed from the kernel's command line (command_line.hsc). */
    options : Options,
    /** Every frame of RAM the kernel owns. */
    frames : frames.FrameAllocator,
    /** The slab caches behind the kernel heap (heap.hsc). */
    heap : Heap,
    /** The kernel's own address space, which every address space shares as its kernel half (address_space.hsc). */
    page_table : arch.PageTable,
    /** Held while changing page_table. */
    page_table_lock : concurrency.SpinLock,
    /** The bootloader's memory, physical ranges reclaimed once every CPU is done with it. */
    boot_memory : boot_info.PhysicalRange[],
    /** The physical RAM the kernel owns, from the memory map (address_space.hsc, keep_boot_info). */
    ram : boot_info.PhysicalRange[],
    /** How many CPUs must leave their boot stacks before boot memory is reclaimed, 0 until it's known. */
    cpus_leaving_boot_stacks : u32,
    /** How many CPUs have left their boot stacks, counted atomically; the last to do so reclaims boot memory. */
    cpus_off_boot_stacks : u32,
    /**
     * Each CPU's PerCpu, by index, as an address in the direct map: 0 until it's allocated. Its count is the
     * number of CPUs in cpus, and a PerCpu once allocated is never freed.
     */
    per_cpus : mut u64[],
    /** The TLB shootdown in progress, if any (shootdown.hsc). */
    shootdown : Shootdown,
    /** Kernel addresses for device registers and other mappings of the kernel's own (window.hsc). */
    window : Window,
    /** Every CPU's context.clock: monotonic time from arch.counter() (clock.hsc). */
    clock : runtime.Clock,
    /** The counter's value when the clock started: monotonic time's MONOTONIC_START (clock.hsc). */
    clock_start : u64,
    /** The counter's frequency the clock converts with, in Hz. */
    clock_frequency : u64,
    /** The registered interrupt controllers (interrupts.hsc), the first controller_count in use. */
    controllers : WiredController[MAX_CONTROLLERS],
    /** How many of controllers are registered, at most MAX_CONTROLLERS. */
    controller_count : u32,
    /** Held while registering interrupt controllers and routing their lines. */
    interrupts_lock : concurrency.SpinLock,
    /** The registered IOMMUs (iommus.hsc), the first iommu_count in use, under iommus_lock. */
    iommus : RegisteredIommu[MAX_IOMMUS],
    /** How many of iommus are registered, at most MAX_IOMMUS. */
    iommu_count : u32,
    /** The requester IDs each IOMMU covers, the first iommu_scope_count in use, under iommus_lock. */
    iommu_scopes : IommuScope[MAX_IOMMU_SCOPES],
    /** How many of iommu_scopes are in use, at most MAX_IOMMU_SCOPES. */
    iommu_scope_count : u32,
    /** Held while registering IOMMUs and their scopes, and while binding a DMA domain to one. */
    iommus_lock : concurrency.SpinLock,
    /**
     * 1 once an IOMMU remaps interrupts, which blocks every wired line's not remapped yet (translation.hsc); 0
     * before. Written and read atomically.
     */
    wired_lines_blocked : u32,
    /**
     * 1 once an IOMMU that doesn't signal its faults translates, so CPU 0 reads their faults at its ticks; 0 before.
     * Written and read atomically.
     */
    iommus_polled : u32,
    /** test_shootdown's state, as an address, while CPUs are asked to read its page (shootdown_test.hsc), else 0. */
    shootdown_test : u64,
    /** test_binding_reuse's state, as an address, while CPUs read its slot (binding_reuse_test.hsc), else 0. */
    binding_reuse_test : u64,
    /** test_ownership_race's state, as an address, while a CPU destroys its objects (ownership_race_test.hsc), else 0. */
    ownership_race_test : u64,
    /** How many interrupts test_ioapic's device has raised so far (device_test.hsc). */
    test_device_count : u64,
    /** The index of the interrupt controller test_ioapic routes through (device_test.hsc). */
    test_controller : u32,
    /** The physical address where the kernel image's frames start, for mapping its code elsewhere. */
    image_physical : u64,
    /** The kernel objects' pools, one per kind, and the pools of what objects hold (objects.hsc). */
    pools : ObjectPools,
    /**
     * The epoch objects are destroyed in, incremented by each destroy (objects.hsc, retire): an object is freed
     * once every online CPU has passed a quiescent point in a later epoch. Only grows.
     */
    epoch : u64,
    /** The root MemoryBudget, as an address, which every other budget is split from (memory_budgets.hsc). */
    root_budget : u64,
    /** Held while changing two memory budgets at once, as a split or a move of charges does (memory_budgets.hsc). */
    budgets_lock : concurrency.SpinLock,
    /**
     * The root CpuBudget, as an address, which every other CPU budget is split from (cpu_budgets.hsc); 0 until
     * the root task is about to start, and with no_root_task.
     */
    root_cpu_budget : u64,
    /** Held while changing the shape of the CPU budgets' tree, and what runs on each (cpu_budgets.hsc). */
    cpu_budgets_lock : concurrency.SpinLock,
    /** The platform capability, a Platform object's address, granted to the root task (irqs.hsc). */
    platform : u64,
    /** The boot modules, the root task's first, their names kept past boot (keep_boot_info). */
    modules : boot_info.BootModule[],
    /** The boot's random seed, from the bootloader, passed on in the root task's startup block. */
    boot_seed : u8[32],
    /** The kernel's command line, kept past boot, for the root task. */
    command_line : string,
    /**
     * The root task's process, as an address, once it's started, 0 before; its end stops the kernel
     * (root_task.hsc). Written and read atomically.
     */
    root_task : u64,
    /**
     * 0 while the root task runs, 1 once it has ended, 2 once the boot CPU has noted when to stop for it, at
     * root_stop_tick (timer.hsc, root_task_ended). Written and read atomically.
     */
    root_ended : u32,
    /** The boot CPU's tick the kernel stops at once the root task has ended, set when root_ended goes to 2. */
    root_stop_tick : u64,
    /** 1 once a lockup's been seen, so only one CPU reports it (lockups.hsc); compare-exchanged. */
    lockup : u32,
    /** The stuck CPU's index plus one, whose NMI notes where it was; 0 before a lockup (lockups.hsc). */
    lockup_target : u32,
    /** 1 while the trace is on (tracing.hsc, trace_set); read and written atomically. */
    tracing : u32,
    /** The counter next_cpu_of turns from, so IRQs are routed to the CPUs in turn (irqs.hsc, devices.hsc). */
    next_irq_cpu : u32,
    /** Held while changing the list of devices from first_device (devices.hsc). */
    devices_lock : concurrency.SpinLock,
    /** The first Device on the kernel's list, as an address, 0 for none: for refusing a second at the same address. */
    first_device : u64,
    /**
     * The firmware tables' copy, a Memory's address, for the root task's "firmware" grant (firmware.hsc); 0 without
     * one, and once the root task has been given it.
     */
    firmware : u64,
    /** The panic record's page, as its address in the direct map, 0 without one (boot_info.PanicRecord, stop.hsc). */
    panic_record : u64,
    /** How the machine is reset and turned off, as arch.reset_method says, for panic_reset and power.hsc. */
    reset_method : u8,
    /** How the machine turns off and resets as the firmware says, and what the root task's end does (power.hsc). */
    power : PowerSettings,
    /** Held while changing the list of threads from first_thread (control.hsc). */
    threads_lock : concurrency.SpinLock,
    /** The first Thread on the kernel's list of every thread, as an address, 0 for none: for finding one by ID. */
    first_thread : u64,
    /** How many intercepts exist (intercepts.hsc), counted atomically, so a thread's stops cost nothing with none. */
    intercepts : u32,
    /** The last thread ID handed out, incremented atomically; IDs start at 1 and are never reused (threads.hsc). */
    next_thread_id : u64,
    /** The counter next_cpu_of turns from, so new threads start on the CPUs in turn (threads.hsc, start_thread). */
    next_start_cpu : u32,
    /** The address-space tags in use (spaces.hsc). */
    tags : TagSet,
    /**
     * The boot CPU's tick the kernel stops at (timer.hsc): BOOT_TICKS at boot, all ones once the root task starts,
     * when only its end stops the kernel.
     */
    stop_after_ticks : u64,
    /** test_tickless's count of the other CPUs' timer interrupts at its start (tickless_test.hsc). */
    tickless_baseline : u64,
    /** Held while writing a line to the console, so lines from different CPUs don't mix. */
    console_lock : concurrency.SpinLock,
    /** test_pool's state, as an address, once the boot CPU has set it up for the others (pool_test.hsc); 0 before. */
    pool_test : u64,
    /** Text on the first framebuffer, when has_framebuffer_console says it's set up. */
    framebuffer_console : console.Console,
    /** Whether framebuffer_console is set up: there's a framebuffer, and it could show the console. */
    has_framebuffer_console : bool,
    /**
     * The physical address of the framebuffer the console draws on, which device memory over it takes from the
     * console (memory.hsc); 0 without one.
     */
    framebuffer_physical : u64,
    /** The bytes of that framebuffer, 0 without one. */
    framebuffer_size : u64,
}

/**
 * One CPU's state. Its carrier block's program_data points back here, so kernel code reaches it
 * with per_cpu() (docs/architecture/layers.md, L1).
 *
 * It's allocated once, when the CPU is (cpus.hsc), and never freed. Fields without a word on synchronization are
 * this CPU's alone, which the kernel touches only on this CPU, with interrupts off.
 */
PerCpu :: struct #align(64) {
    /** The CPU's carrier block, which intrinsics.carrier() returns on it; its program_data is this PerCpu. */
    carrier : runtime.CarrierBlock,
    /** The context every entry on this CPU runs with: the kernel's logger, heap allocator and clock. */
    context : runtime.Context,
    /** The kernel's shared state. */
    kernel : ptr[mut Kernel],
    /** This CPU's index in kernel.cpus and kernel.per_cpus; the boot CPU's is 0. */
    index : u32,
    /** The locks this CPU holds, by rank (locks.hsc); kept with robustness=on. */
    held_ranks : concurrency.HeldRanks,
    /** Whether this CPU is reporting a broken lock order, so the report's own locks aren't checked (locks.hsc). */
    reporting_locks : bool,
    /** The architecture's per-CPU state. */
    arch : arch.ArchCpu,
    /** The CPU's kernel stack and critical stacks, in a CpuStackMemory of its own. */
    stacks : arch_interface.CpuStacks,
    /** How many of this CPU's timer interrupts were ticks, counted from 1 at the first (timer.hsc). */
    timer_ticks : u64,
    /** How many NMIs this CPU has handled; written atomically by the NMI handler. */
    nmi_count : u32,
    /** When this CPU last ticked, in counter ticks, for lockup detection (lockups.hsc); written atomically. */
    heartbeat : u64,
    /** This CPU's trace ring (tracing.hsc), as an address on the kernel heap; 0 until tracing's first on. */
    trace_ring : u64,
    /** Where a lockup's NMI found this CPU: the interrupted program counter (lockups.hsc). */
    lockup_pc : u64,
    /** 1 once lockup_pc is written, read atomically. */
    lockup_seen : u32,
    /** CPU_WAITING while the boot CPU starts this one, then CPU_ONLINE or CPU_ABANDONED (cpus.hsc). */
    start_state : u32,
    /** Whether an interrupt has taken this CPU to its kernel stack, off its boot stack for good. */
    left_boot_stack : bool,
    /** This CPU's magazines in front of the kernel heap's caches. */
    heap : CpuHeap,
    /** This CPU's single frames in front of the frame allocator. */
    frame_cache : frames.FrameCache,
    /** 1 while a TLB shootdown waits for this CPU to flush, 0 otherwise; written and read atomically. */
    flush_requested : u32,
    /** Where each of this CPU's device interrupt IDs comes from (interrupts.hsc). */
    device_routes : DeviceRoute[MAX_DEVICE_INTERRUPTS],
    /** Its ready threads (scheduler.hsc), under the queue's own lock. */
    run_queue : RunQueue,
    /** The thread it runs, as an address, 0 when idle. */
    current : u64,
    /** The run-queue level of the thread it runs, IDLE_LEVEL when idle; read by other CPUs with an acquire load. */
    current_level : u32,
    /** The address space active on it, as an address, 0 for the kernel's own. */
    space : u64,
    /** When the current thread last started running, or was last charged, in counter ticks. */
    run_start : u64,
    /** The objects this CPU destroyed, waiting for a grace period: a list through ObjectHeader.limbo_next, or 0. */
    limbo : u64,
    /**
     * The epoch this CPU last passed a quiescent point in (objects.hsc), or IDLE_EPOCH while it's idle without
     * ticking; read by every CPU atomically.
     */
    quiescent_epoch : u64,
    /** Its armed timers (timers.hsc). */
    timers : TimerHeap,
    /** When its next tick is due, in counter ticks (timer.hsc). */
    next_tick : u64,
    /**
     * 1 while it's idle without ticking, which only an interrupt ends (decisions/0128), 0 otherwise; read by other
     * CPUs atomically.
     */
    tickless : u32,
    /** How many timer interrupts this CPU has taken, ticks or not (timer.hsc, tickless_test.hsc). */
    timer_interrupts : u64,
    /** While ChannelNotifyAndWait notifies: threads it wakes are made ready here (ports.hsc, wake_waiter). */
    handoff : bool,
    /** How many destroys are running on this CPU, nested (objects.hsc, destroy_object). */
    destroying : u32,
    /** Whether the outermost destroy is finishing those left for later (objects.hsc, destroy_later). */
    draining : bool,
    /** The objects left for later, a list through ObjectHeader.doomed_next, 0 for none (objects.hsc, destroy_later). */
    doomed : u64,
}

/** The memory for one CPU's stacks, allocated with its PerCpu and never freed. */
CpuStackMemory :: struct #align(64) {
    /** The kernel stack, where every entry runs. */
    kernel : u8[KERNEL_STACK_SIZE],
    /** The stack NMIs run on. */
    nmi : u8[CRITICAL_STACK_SIZE],
    /** The stack double faults run on. */
    double_fault : u8[CRITICAL_STACK_SIZE],
    /** The stack machine checks run on. */
    machine_check : u8[CRITICAL_STACK_SIZE],
}

/**
 * Find the calling CPU's PerCpu.
 *
 * @return The PerCpu, through the carrier block's program_data; good for as long as the kernel runs, as a PerCpu is
 *     never freed. Kernel code runs with interrupts off, so it stays on this CPU while it uses it. Null before the
 *     boot CPU sets its carrier block in boot.
 */
per_cpu :: fn() -> ptr[mut PerCpu] {
    return cast[ptr[mut PerCpu]](intrinsics.carrier().program_data)
}

/**
 * Boot the kernel: the portable kernel entry, called by the boot adapter (L0) on the boot CPU with interrupts
 * disabled, the boot context pushed, and the bootloader's page tables (docs/specs/boot_info.md, Handoff).
 *
 * It sets up the frame allocator, the kernel's state, the boot CPU, the kernel's own page tables, the timer and the
 * other CPUs, runs the tests the command line asks for, starts the root task unless no_root_task says not to, and
 * goes idle.
 *
 * @param info The boot information, in boot memory: read while boot memory is there, and what the kernel needs of
 *     it is copied out (keep_boot_info) before boot memory is reclaimed.
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
    // Every pass from here on counts, the Kernel's own frames' first
    made.faults.spec = options.fail
    made.faults.on_fail = log_failure
    /*
     * Its frames' address, not allocate_object: made is on this stack, so what allocate_object gives
     * for it would count as pointing here (Hemera's docs/memory.md, Returning). A frame's address
     * doesn't, being a physical address in the direct map.
     */
    kernel_frames :: frames.allocate_zeroed(&made, frames.order_for(cast[u64](size_of(Kernel))))
        or_else out_of_memory(&options, "no memory for the kernel's state")
    kernel :: cast[ptr[mut Kernel]](frames.virtual_of(&made, kernel_frames))
    kernel.frames = made
    init_heap(&kernel.heap)
    init_clock(kernel)
    init_pools(kernel)
    kernel.stop_after_ticks = BOOT_TICKS
    kernel.image_physical = cast[u64](info.kernel_image.physical.base)
    log_memory(&kernel.frames)
    kernel.features = features
    kernel.options = options
    kernel.image_base = cast[u64](info.kernel_image.virtual_base)
    runtime.assert(info.cpus.count >= 1, "the boot information lists the boot CPU")
    keep_boot_info(kernel, info)
    match info.panic_record {
        case Some(range) => kernel.panic_record = info.direct_map_offset + cast[u64](range.base)
        case None => {}
    }
    kernel.reset_method = arch.reset_method(&info.firmware_tables, info.direct_map_offset)
    kernel.online_cpus = 1
    cpu :: allocate_cpu(kernel, 0) or_else out_of_memory(&options, "no memory for the boot CPU's state")
    // The boot CPU keeps its boot stack's limit until it first enters through the kernel stack
    cpu.carrier.stack_limit = intrinsics.carrier().stack_limit
    cpu.carrier.native_stack_limit = cpu.carrier.stack_limit
    intrinsics.set_carrier(&cpu.carrier)
    arch.init_system(&kernel.arch, &info.firmware_tables, info.direct_map_offset)
    arch.init_cpu(&kernel.arch, &cpu.arch, &cpu.carrier, &cpu.context, &cpu.stacks)
    runtime.log_info("boot CPU set up: its entries and its own state")
    start_address_space(kernel, info)
    start_framebuffer_console(kernel, info)
    push_context cpu_context from cpu.context {
        start_timer(kernel, info.counter_frequency_hint)
        // While the bootloader's memory, which may hold them, is still there
        copy_firmware_tables(kernel, &info.firmware_tables, info.framebuffers, info.direct_map_offset)
        start_cpus(kernel, info)
        // The trace from here, every CPU online, for a boot's timeline (decisions/0183)
        if kernel.options.trace_boot && !set_tracing(kernel, true) {
            runtime.log_error("no memory for the trace's rings")
        }
        start_msis(kernel)
        leave_boot_stacks(kernel)
        // Of the memory free once boot memory is back
        // Everything the root task's processes are charged to, and the hardware: without them, nothing can run
        kernel.root_budget = make_root_budget(kernel)
        kernel.platform = new_object(kernel, .Platform, 0, 0) or_else 0
        if kernel.root_budget == 0 || kernel.platform == 0 {
            out_of_memory(&kernel.options, "no memory for the root budget or the platform capability")
        }
        if kernel.options.test_clock {
            test_clock(kernel)
        }
        if kernel.options.test_shootdown {
            test_shootdown(kernel)
        }
        if kernel.options.test_binding_reuse {
            test_binding_reuse(kernel)
        }
        if kernel.options.test_ownership_race {
            test_ownership_race(kernel)
        }
        if kernel.options.test_tickless {
            start_tickless_test(kernel)
        }
        if kernel.options.test_ioapic {
            test_io_apic(kernel)
        }
        memory_tests(kernel)
        if kernel.options.test_panic_once {
            test_panic_once(info)
        }
        if kernel.options.test_nmi {
            test_nmi(kernel, cpu)
        }
        if kernel.options.test_lockup {
            // Running until lockup detection stops it, with Lockup
            kernel.stop_after_ticks = 0xffffffffffffffff
        }
        if kernel.options.test_fibers {
            test_fibers(kernel)
        }
        if kernel.options.test_segments {
            test_segments(kernel)
        }
        if kernel.options.test_pool {
            test_pool(kernel)
        }
        if !kernel.options.no_root_task {
            // Of every CPU's time, which the root task's processes run on; the kernel's own tests above run on none
            kernel.root_cpu_budget = make_root_cpu_budget(kernel)
            if kernel.root_cpu_budget == 0 {
                out_of_memory(&kernel.options, "no memory for the root CPU budget")
            }
            start_root_task(kernel)
        }
        runtime.log_info("idle")
        arch.idle()
    }
}

/**
 * Run the tests that need only memory, each that the command line asks for: a fault, the heap, writing the kernel's
 * read-only code and a failed assertion.
 *
 * test_fault, test_write_code (when the code is read-only, as it should be) and test_assert each stop the kernel, so
 * nothing after the first of them runs.
 *
 * @param kernel The kernel, whose options say which tests run; called on the boot CPU at boot.
 */
memory_tests :: fn(kernel: ptr[mut Kernel]) {
    if kernel.options.test_fault {
        runtime.log_info("test_fault: running an invalid instruction")
        intrinsics.trap()
    }
    if kernel.options.test_heap {
        test_heap()
    }
    if kernel.options.test_write_code {
        runtime.log_info("test_write_code: writing to the kernel's code")
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](cast[u64](boot)), 0xcc)
        runtime.log_error("test_write_code: the kernel's code is writable")
    }
    if kernel.options.test_assert {
        runtime.log_info("test_assert: failing an assertion")
        runtime.assert(false, "test_assert")
    }
}

/**
 * Fail an assertion, which stops the kernel, unless the bootloader handed over the last panic's record
 * (decisions/0134): so the boot after the panic, which has it, goes on.
 *
 * @param info The boot information, whose modules are searched for boot_info.LAST_PANIC_MODULE; it has to still be
 *     in boot memory.
 */
test_panic_once :: fn(info: ptr[boot_info.BootInfo]) {
    for module in info.modules {
        if module.name == boot_info.LAST_PANIC_MODULE {
            return void
        }
    }
    runtime.log_info("test_panic_once: failing an assertion")
    runtime.assert(false, "test_panic_once")
}

/**
 * Allocate a T in frames of its own, zeroed: for the kernel's state that lives as long as it does.
 *
 * Its address is a frame's in the direct map, not a stack's, so it may be kept anywhere. Nothing frees it but
 * frames.free with the order of T's size.
 *
 * @tparam T The type allocated; its alignment is at most a frame's, 4 KiB.
 * @param allocator The frame allocator it comes from, which isn't locked here: called at boot, or on the frame
 *     allocator's own terms (frames.hsc).
 * @return The T, zeroed, in the smallest power-of-two block of frames that holds it.
 * @error OutOfMemory No block that size was free, or fault injection failed this pass; nothing was taken.
 */
allocate_object :: fn[T](allocator: ptr[mut frames.FrameAllocator]) -> Result[ptr[mut T], frames.FrameError] {
    address :: frames.allocate_zeroed(allocator, frames.order_for(cast[u64](size_of(T))))?
    return .Ok(cast[ptr[mut T]](frames.virtual_of(allocator, address)))
}

/**
 * Log how much of the frame allocator's memory is free, in MiB.
 *
 * @param allocator The frame allocator, read without its lock, so the numbers are a moment's; its frames are taken
 *     to be 4 KiB, 256 to a MiB.
 */
log_memory :: fn(allocator: ptr[frames.FrameAllocator]) {
    runtime.log_info("frames: % MiB free of % MiB", allocator.free_frames / 256, allocator.total_frames / 256)
}

/**
 * Stop the kernel for want of memory, saying what for.
 *
 * Once this CPU has the kernel's state, every CPU stops (stop); before then, only this one does.
 *
 * @param options The command line's options, which say how to stop (test_exit, panic_reset) before there's a
 *     kernel; once there is one, its own options are used instead.
 * @param message What there was no memory for, logged as fatal.
 */
out_of_memory :: fn(options: ptr[Options], message: string) #never_returns {
    runtime.log_fatal(message)
    // Once there's a kernel, every CPU stops, as for any other reason
    if intrinsics.carrier().program_data != null {
        stop(.OutOfMemory)
    }
    stop_with(options, .OutOfMemory)
}

/**
 * Raise an NMI, and wait up to a second for this CPU to handle it and come back, logging whether it did.
 *
 * @param kernel The kernel, for the counter's frequency.
 * @param cpu The calling CPU's PerCpu, whose nmi_count the NMI handler increments.
 */
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

/**
 * Stop with a message if the CPU lacks part of the baseline (decisions/0003): x86-64-v3, or ARMv8.2-A with LSE.
 *
 * Returns only if the CPU has everything; otherwise it stops this CPU with CpuUnsupported, as there's no kernel yet.
 *
 * @param options The command line's options, which say how to stop.
 * @param features The boot CPU's features, as arch.detect_features found them.
 */
check_baseline :: fn(options: ptr[Options], features: ptr[slop_os.CpuFeatures]) {
    missing :: arch.missing_baseline_feature(features) or_return void
    #if TARGET_ARCH == .x86_64 {
        runtime.log_fatal("SlopOS needs an x86-64-v3 CPU, and this one lacks %", missing)
    }
    #else {
        runtime.log_fatal("SlopOS needs an ARMv8.2-A CPU with LSE, and this one lacks %", missing)
    }
    stop_with(options, .CpuUnsupported)
}

/**
 * Show the log on the first framebuffer too. Without one, or if it can't be used, the log stays on
 * the early console, and a line says why.
 *
 * Called on the boot CPU before any other CPU starts, so nothing writes to the console while it's set up.
 *
 * @param kernel The kernel, whose framebuffer_console, has_framebuffer_console, framebuffer_physical and
 *     framebuffer_size are set when the console is.
 * @param info The boot information, whose first framebuffer is used; read through the direct map.
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
            for shown, i in info.framebuffers {
                if i == 0 {
                    kernel.framebuffer_physical = cast[u64](shown.memory.base)
                    kernel.framebuffer_size = shown.memory.size
                }
            }
            log_framebuffer(&kernel.framebuffer_console)
        }
        case Error(error) => runtime.log_warn("the framebuffer can't show the console")
    }
}

/**
 * Log the framebuffer console's size, in characters and in pixels.
 *
 * @param screen The console, set up.
 */
log_framebuffer :: fn(screen: ptr[console.Console]) {
    runtime.log_info("framebuffer console: %x% characters on %x% pixels", screen.columns, screen.rows, screen.width,
        screen.height)
}

/**
 * Describe a stack by its memory.
 *
 * @param low The stack's lowest byte, a kernel virtual address.
 * @param size The stack's size in bytes.
 * @return The range from low to low plus size, its high end one past the last byte, where the stack starts.
 */
range_of :: fn(low: ptr[u8], size: u64) -> arch_interface.StackRange {
    base :: cast[u64](low)
    return arch_interface.StackRange.{
        low = cast[arch_interface.VirtualAddress](base),
        high = cast[arch_interface.VirtualAddress](base + size),
    }
}
