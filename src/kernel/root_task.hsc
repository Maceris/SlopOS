package kernel

import intrinsics from "base"
import runtime from "base"
import slop_os from "std/os"
import text_buffer from "std"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import elf_loader from "../elf_loader"
import frames from "frames"
import test_device from "../test_device"
import robustness from "../robustness"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * The root task (decisions/0012, 0058, 0060): the one process the kernel starts, from the first boot
 * module, given everything. The kernel loads it with the shared loader (src/elf_loader) into memory
 * objects it owns, at random places in its own address space, and starts its first thread with its
 * startup block (docs/specs/programs.md). Its grants:
 * - "platform", the platform capability;
 * - "debug_log", a debug log;
 * - "command_line", the kernel's command line, its bytes then zeros;
 * - "firmware", the firmware tables' copy (firmware.hsc, slop_os.FirmwareTables), read-only, if the boot has them;
 * - "test_device", with test_device on the command line: what the firmware tables say of the test device;
 * - "module:<name>", each other boot module, a read-only memory object over the frames it was loaded into; or
 *   "library:<name>" for a typed library, <name> ending in .library, which the root task's runtime binds before its
 *   main as any program's does (decisions/0121), mappable to run.
 * Its own handles are to itself, its address space and the root memory budget, and its startup block
 * has the boot's random seed. Its end is the machine's: the kernel stops (processes.hsc), and only then.
 */

/** The bytes of the root task's first thread's stack: 256 KiB, mapped readable and writable. */
ROOT_STACK_SIZE : u64 : 256 * 1024
/** The bytes of the free range the root task's runtime maps its own memory in: 1 TiB. */
ROOT_FREE_SIZE : u64 : 1 << 40
/** The most grants the root task is given: its own, and one for every boot module after the first. */
MAX_ROOT_GRANTS :: 64
/** A page's bytes, a frame's: 4 KiB. */
PAGE : u64 : frames.FRAME_SIZE

/** Where the root task's parts go in its address space: page-aligned user virtual addresses. */
RootLayout :: struct {
    /** Where its image is loaded and relocated to. */
    image : u64,
    /** Its stack's lowest address; the stack is ROOT_STACK_SIZE bytes. */
    stack : u64,
    /** Its startup block, a page above the stack's top, the page between left unmapped. */
    block : u64,
    /** The free range, ROOT_FREE_SIZE bytes, which its startup block tells its runtime of. */
    free : u64,
}

/**
 * Start the root task from the first boot module, if the boot has any; on a failure, say why, and the
 * kernel carries on without it.
 *
 * On a failure, the firmware tables' copy kept for it is destroyed, and with robustness=on the kernel stops
 * ROOT_END_TICKS later, so what the failed process held is freed before the check of what's left.
 *
 * @param kernel The kernel, with its root budget, root CPU budget and platform capability made; called once, on the
 *     boot CPU.
 */
start_root_task :: fn(kernel: ptr[mut Kernel]) {
    if kernel.modules.count == 0 {
        runtime.log_warn("no root task: the boot has no modules")
        return void
    }
    module :: kernel.modules[0]
    match load_root_task(kernel, module) {
        case Some(failure) => {
            runtime.log_error("root task %: %", module.name, failure)
            // What was kept for it, nobody else is given
            if kernel.firmware != 0 {
                _ = destroy_object(kernel, kernel.firmware)
                kernel.firmware = 0
            }
            // Its process's destruction takes a grace period for each step, as a root task's end does, before what's
            // left is checked when the kernel halts (timer.hsc)
            #if robustness.ON {
                kernel.stop_after_ticks += ROOT_END_TICKS
            }
        }
        case None => {}
    }
}

/**
 * Load a boot module as the root task and start it.
 *
 * Its process, owned by the kernel and charged to the root budget, is destroyed if it can't start, with everything
 * it was given (decisions/0104).
 *
 * @param kernel The kernel, on the boot CPU at boot: its frames hold the module, and its root budget pays for the
 *     process; kernel.root_task and stop_after_ticks are set once it starts.
 * @param module The module, an ELF executable in frames the bootloader loaded it into, read through the direct map.
 * @return Null once it's started; otherwise what went wrong, always a constant string, never on the stack.
 */
load_root_task :: fn(kernel: ptr[mut Kernel], module: boot_info.BootModule) -> string? #unrestricted {
    file :: view_of(cast[ptr[u8]](frames.virtual_of(&kernel.frames, module.contents.base)), cast[usize](module.contents.size))
    executable := elf_loader.Executable.{}
    match elf_loader.read(file) {
        case Ok(read) => executable = read
        case Error(error) => return "not a program the loader takes"
    }
    budget :: kernel.root_budget
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, budget) {
        case Ok(made) => process = made
        case Error(error) => return "no process"
    }
    // What it was given goes with it if it can't start (decisions/0104): destroying it destroys everything it owns
    failure :: start_in(kernel, module, process, &executable, file)
    if failure is_some {
        _ = destroy_object(kernel, cast[u64](process))
    }
    return failure
}

/**
 * Make the root task's address space, image, stack, startup block and first thread, in its process, and start it.
 *
 * Once it's started, kernel.root_task is its process, and only its end stops the kernel. On a failure, what was made
 * is left in the process, for the caller to destroy with it.
 *
 * @param kernel The kernel, on the boot CPU at boot: kernel.root_budget pays for everything, and kernel.root_task and
 *     stop_after_ticks are set once the thread starts.
 * @param module The module it's loaded from, for its name in the log.
 * @param process Its process, new, which owns everything made here, all charged to the root budget.
 * @param executable The module's executable, as elf_loader.read found it.
 * @param file The module's bytes, in the direct map.
 * @return Null once it's started; otherwise what failed, a constant string.
 */
start_in :: fn(kernel: ptr[mut Kernel], module: boot_info.BootModule, process: ptr[mut Process], executable: ptr[elf_loader.Executable],
    file: u8[]) -> string? #unrestricted {
    budget :: kernel.root_budget
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), budget) {
        case Ok(made) => space = made
        case Error(error) => return "no address space"
    }
    // Room for as many grants as it can be given, which add_grant doesn't pass
    grant_count :: MAX_ROOT_GRANTS
    block_size :: page_up(cast[u64](size_of(slop_os.StartupBlock)) + cast[u64](grant_count + 1) * cast[u64](size_of(slop_os.Grant)))
    layout :: choose_layout(kernel, executable.size, block_size)
    not_loaded :: load_image(kernel, process, space, executable, file, layout.image)
    if (not_loaded is_some) {
        return not_loaded
    }
    stack :: create_memory(kernel, cast[u64](process), budget, ROOT_STACK_SIZE) or_return "no memory for its stack"
    read_write :: cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE)
    if memory_map(kernel, stack, space, layout.stack, 0, ROOT_STACK_SIZE, read_write) != null {
        return "its stack doesn't map"
    }
    not_written :: write_startup_block(kernel, process, space, module, layout, block_size)
    if (not_written is_some) {
        return not_written
    }
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](layout.image + executable.entry),
        // As a call leaves it: 8 below a multiple of 16
        stack_pointer = cast[arch_interface.VirtualAddress](layout.stack + ROOT_STACK_SIZE - 8),
        argument = layout.block,
    }
    thread := cast[ptr[mut Thread]](0)
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0, budget) {
        case Ok(made) => thread = made
        case Error(error) => return "no thread"
    }
    intrinsics.atomic_store_u64_release(&kernel.root_task, cast[u64](process))
    // From here, the root task's end is the kernel's, not a number of ticks
    kernel.stop_after_ticks = 0xffffffffffffffff
    start_thread(kernel, thread)
    runtime.log_info("root task % started at %{#018x}", module.name, layout.image)
    return null
}

/**
 * Choose where the image, the stack and the startup block, and the free range go: each at a random page in a
 * quarter of user addresses of its own (the free range in the upper half), the same every boot without KASLR.
 *
 * @param kernel The kernel, for its options and randomness.
 * @param image_size The image's bytes in memory.
 * @param block_size The startup block's bytes, a whole number of pages.
 * @return The layout, every address page-aligned and in the user range. A part bigger than its room is put at the
 *     room's start.
 */
choose_layout :: fn(kernel: ptr[Kernel], image_size: u64, block_size: u64) -> RootLayout {
    low_address, high_address :: arch.user_address_range()
    low :: page_up(cast[u64](low_address))
    high :: cast[u64](high_address) & ~(PAGE - 1)
    quarter :: ((high - low) / 4) & ~(PAGE - 1)
    stack_and_block :: ROOT_STACK_SIZE + PAGE + block_size
    stack :: random_place(kernel, low + quarter, quarter, stack_and_block)
    return RootLayout.{
        image = random_place(kernel, low, quarter, image_size),
        stack = stack,
        // A page above the stack's top, unmapped, then the block
        block = stack + ROOT_STACK_SIZE + PAGE,
        free = random_place(kernel, low + 2 * quarter, 2 * quarter, ROOT_FREE_SIZE),
    }
}

/**
 * Choose a random page-aligned place for some bytes in a room.
 *
 * @param kernel The kernel, for its options and randomness.
 * @param start The room's start, page-aligned.
 * @param room The room's bytes, a multiple of a page.
 * @param size The bytes to place.
 * @return An address from start to start plus room less size, page-aligned, so the bytes fit; start itself with
 *     no_kaslr, or when size is room or more, when they may not fit.
 */
random_place :: fn(kernel: ptr[Kernel], start: u64, room: u64, size: u64) -> u64 {
    if kernel.options.no_kaslr || size >= room {
        return start
    }
    pages :: (room - size) / PAGE
    return start + (random_bits(kernel) % (pages + 1)) * PAGE
}

/**
 * Get 64 random bits: the CPU's, or the boot seed's when it has none.
 *
 * @param kernel The kernel, for the boot seed.
 * @return The CPU's hardware entropy, tried up to 10 times; failing that, the boot seed's 32 bytes folded into 64
 *     bits by exclusive or, the same value at every call.
 */
random_bits :: fn(kernel: ptr[Kernel]) -> u64 {
    for i in 0..<10 {
        match arch.hardware_entropy() {
            case Some(value) => return value
            case None => {}
        }
    }
    seed : u64 = 0
    for byte, i in kernel.boot_seed {
        seed = seed ~ (cast[u64](byte) << ((cast[u64](i) % 8) * 8))
    }
    return seed
}

/**
 * Round a number of bytes, or an address, up to whole pages.
 *
 * @param value The bytes or address, at most a page below 2^64, where it would wrap.
 * @return The smallest multiple of PAGE at least value.
 */
page_up :: fn(value: u64) -> u64 {
    return (value + PAGE - 1) & ~(PAGE - 1)
}

/**
 * Find the larger of two numbers.
 *
 * @param a One number, any u64.
 * @param b The number compared with a, any u64.
 * @return Whichever is larger, b when they're equal.
 */
max_u64 :: fn(a, b: u64) -> u64 {
    return if a > b { a } else { b }
}

/**
 * Load the root task's image: the executable, loaded and relocated for base, in a memory object the process owns,
 * mapped in its space a segment at a time with each one's protection, and its RELRO pages read-only.
 *
 * The loading is done in a buffer from the kernel heap, freed before this returns, then copied into the memory
 * object's frames.
 *
 * @param kernel The kernel, on the boot CPU at boot: the buffer comes from its heap, the image's frames from its
 *     frame allocator, charged to kernel.root_budget.
 * @param process The process that owns the image's memory, charged to the root budget.
 * @param space The process's address space, where it's mapped.
 * @param executable The executable, as elf_loader.read found it.
 * @param file The whole executable file, as elf_loader.read read executable from; only read, its segments copied into
 *     the buffer, and not kept.
 * @param base Where the image goes, a page-aligned user virtual address.
 * @return Null once it's loaded and mapped; otherwise what failed, a constant string.
 */
load_image :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], space: ptr[mut AddressSpace], executable: ptr[elf_loader.Executable],
    file: u8[], base: u64) -> string? #unrestricted {
    buffer, error :: runtime.new_array(u8, cast[usize](executable.size))
    if error != null {
        return "no memory to load it in"
    }
    defer runtime.free_array(buffer)
    if elf_loader.load(executable, file, buffer) is_error {
        return "its segments don't load"
    }
    if elf_loader.relocate(executable, file, buffer, base) is_error {
        return "its relocations don't apply"
    }
    image :: create_memory(kernel, cast[u64](process), kernel.root_budget, executable.size) or_return "no memory for its image"
    if !copy_into(kernel, image, buffer) {
        return "no frames for its image"
    }
    relro_start :: executable.relro_address & ~(PAGE - 1)
    relro_end :: (executable.relro_address + executable.relro_size) & ~(PAGE - 1)
    for i in 0..<executable.segment_count {
        if i >= executable.segments.count {
            break
        }
        segment :: executable.segments[i]
        start :: segment.address & ~(PAGE - 1)
        end :: page_up(segment.address + segment.memory_size)
        protection :: cast[u32](segment.protection)
        writable :: protection & cast[u32](slop_os.PROTECTION_WRITE) != 0
        if writable && relro_start < end && relro_end > start {
            // Before the RELRO pages, the RELRO pages read-only, and after
            middle_start :: max_u64(start, relro_start)
            middle_end :: min_u64(end, relro_end)
            failure := map_part(kernel, image, space, base, start, middle_start, protection)
            if (failure is_none) {
                failure = map_part(kernel, image, space, base, middle_start, middle_end, cast[u32](slop_os.PROTECTION_READ))
            }
            if (failure is_none) {
                failure = map_part(kernel, image, space, base, middle_end, end, protection)
            }
            if (failure is_some) {
                return failure
            }
            continue
        }
        not_mapped :: map_part(kernel, image, space, base, start, end, protection)
        if (not_mapped is_some) {
            return not_mapped
        }
    }
    return null
}

/**
 * Map part of the root task's image.
 *
 * @param kernel The kernel, on the boot CPU at boot, for memory_map, which charges the mapping to space.
 * @param image The image's memory object.
 * @param space The address space it's mapped in.
 * @param base Where the image starts in space, a page-aligned user virtual address.
 * @param start The part's start, an offset in the image, page-aligned.
 * @param end The part's end, an offset in the image, page-aligned; at or below start, nothing is mapped.
 * @param protection The part's protection, slop_os.PROTECTION_* bits.
 * @return Null once it's mapped, or when there was nothing to map; otherwise what failed, a constant string.
 */
map_part :: fn(kernel: ptr[mut Kernel], image: ptr[mut Memory], space: ptr[mut AddressSpace], base: u64, start: u64, end: u64,
    protection: u32) -> string? #unrestricted {
    if end <= start {
        return null
    }
    if memory_map(kernel, image, space, base + start, start, end - start, protection) != null {
        return "a segment doesn't map"
    }
    return null
}

/**
 * Copy bytes into a memory object's pages from its start, giving it frames.
 *
 * @param kernel The kernel, whose frame allocator gives the pages that have none, through the direct map.
 * @param memory The memory object, at least as big as bytes; its pages past them stay as they were, zeroed if new.
 * @param bytes The bytes, from the start of the memory object on; the caller keeps them, as they're copied.
 * @return True once they're all copied; false if a frame couldn't be had, when the pages before it are copied.
 */
copy_into :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory], bytes: u8[]) -> bool {
    count :: cast[u64](bytes.count)
    for page in 0..<page_up(count) / PAGE {
        frame :: frame_for(kernel, memory, page)
        if frame == 0 {
            return false
        }
        offset :: page * PAGE
        size :: min_u64(PAGE, count - offset)
        intrinsics.mem_copy_non_overlapping(cast[mut rawptr](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](frame))),
            cast[rawptr](cast[u64](bytes.data) + offset), cast[usize](size))
    }
    return true
}

/**
 * Make the root task's handles and grants, and its startup block, written in memory of its own, mapped
 * read-only at layout.block.
 *
 * The firmware tables' copy, if there is one, is the process's from here on, and kernel.firmware is 0.
 *
 * @param kernel The kernel, on the boot CPU at boot: its platform, root budget, root CPU budget, boot seed,
 *     features, command line, modules and options are read, and kernel.firmware is taken.
 * @param process The root task's process, which owns everything made here, charged to the root budget.
 * @param space The process's address space.
 * @param own The root task's own module. It isn't used: the grants are of kernel.modules after the first.
 * @param layout Where things go in space.
 * @param block_size The startup block's bytes, a whole number of pages, with room for MAX_ROOT_GRANTS grants.
 * @return Null once it's written and mapped; otherwise what failed, a constant string.
 */
write_startup_block :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], space: ptr[mut AddressSpace], own: boot_info.BootModule,
    layout: RootLayout, block_size: u64) -> string? #unrestricted {
    buffer, error :: runtime.new_array(u8, cast[usize](block_size))
    if error != null {
        return "no memory for its startup block"
    }
    defer runtime.free_array(buffer)
    block :: cast[ptr[mut slop_os.StartupBlock]](buffer.data)
    block.abi_version = slop_os.ABI_VERSION
    block.size = cast[u32](size_of(slop_os.StartupBlock))
    block.process = cast[slop_os.Process](handle_for(kernel, process, cast[u64](process), .Process, false) or_return "no handle to itself")
    block.space = cast[slop_os.AddressSpace](handle_for(kernel, process, cast[u64](space), .AddressSpace, true) or_return "no handle to its space")
    block.budget = cast[slop_os.MemoryBudget](handle_for(kernel, process, kernel.root_budget, .MemoryBudget, false)
        or_return "no handle to the root budget")
    block.free_base = layout.free
    block.free_size = ROOT_FREE_SIZE
    block.stack_base = layout.stack
    block.stack_size = ROOT_STACK_SIZE
    block.seed = kernel.boot_seed
    block.cpu_features = kernel.features
    block.grants = (cast[u64](size_of(slop_os.StartupBlock)) + 7) & ~cast[u64](7)
    grants :: view_of(cast[ptr[mut slop_os.Grant]](cast[u64](buffer.data) + block.grants), MAX_ROOT_GRANTS)
    count : usize = 0
    platform :: handle_for(kernel, process, kernel.platform, .Platform, false) or_return "no handle to the platform"
    count = add_grant(grants, count, "platform", .Platform, platform)
    // The root CPU budget, which it gives the scheduler service to split (decisions/0093)
    cpu_budget :: handle_for(kernel, process, kernel.root_cpu_budget, .CpuBudget, false) or_return "no handle to the root CPU budget"
    count = add_grant(grants, count, "cpu_budget", .CpuBudget, cpu_budget)
    log :: create_debug_log(kernel, process) or_return "no debug log"
    count = add_grant(grants, count, "debug_log", .DebugLog, log)
    command_line :: copy_of_command_line(kernel, process) or_return "no memory for its command line"
    count = add_grant(grants, count, "command_line", .Memory, command_line)
    if kernel.firmware != 0 {
        firmware :: kernel.firmware
        kernel.firmware = 0
        if adopt(cast[u64](process), firmware) is_error {
            return "no firmware tables: it's being destroyed"
        }
        handle :: handle_for(kernel, process, firmware, .Memory, true) or_return "no handle to the firmware tables"
        count = add_grant(grants, count, "firmware", .Memory, handle)
    }
    if kernel.options.test_device {
        device :: test_device_page(kernel, process) or_return "no memory for its test device"
        count = add_grant(grants, count, "test_device", .Memory, device)
    }
    for module, i in kernel.modules {
        if i == 0 {
            continue
        }
        memory :: create_module_memory(kernel, cast[u64](process), kernel.root_budget, cast[u64](module.contents.base),
            page_up(module.contents.size)) or_return "no memory object for a module"
        handle :: handle_for(kernel, process, cast[u64](memory), .Memory, true) or_return "no handle to a module"
        label_storage : u8[slop_os.GRANT_LABEL_SIZE]
        label := text_buffer.make(label_storage)
        text_buffer.append(&label, if is_library(module.name) { "library:" } else { "module:" })
        text_buffer.append(&label, module.name)
        count = add_grant(grants, count, text_buffer.as_string(&label), .Memory, handle)
    }
    block.grant_count = cast[u32](count)
    if cast[u64](block.grants) + cast[u64](count) * cast[u64](size_of(slop_os.Grant)) > block_size {
        return "too many grants"
    }
    memory :: create_memory(kernel, cast[u64](process), kernel.root_budget, block_size) or_return "no memory for its startup block"
    if !copy_into(kernel, memory, buffer) {
        return "no frames for its startup block"
    }
    if memory_map(kernel, memory, space, layout.block, 0, block_size, cast[u32](slop_os.PROTECTION_READ)) != null {
        return "its startup block doesn't map"
    }
    return null
}

/**
 * Copy the kernel's command line into memory a process owns, its bytes then zeros.
 *
 * @param kernel The kernel, whose command_line is copied and whose root budget pays for the memory.
 * @param process The process, charged to the root budget.
 * @return An owning handle to the memory, in the process's table, at least one byte bigger than the command line, a
 *     whole number of pages; null if there's no memory or no handle.
 */
copy_of_command_line :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) -> slop_os.Handle? {
    text :: kernel.command_line
    memory :: create_memory(kernel, cast[u64](process), kernel.root_budget, page_up(cast[u64](text.count) + 1)) or_return null
    if !copy_into(kernel, memory, string_bytes(text)) {
        return null
    }
    return handle_for(kernel, process, cast[u64](memory), .Memory, true)
}

/**
 * Write what the firmware tables would say of the test device in a page a process owns (test_device.TestDeviceInfo).
 *
 * @param kernel The kernel, whose root budget pays for the page and whose frame allocator gives its frame.
 * @param process The process, charged to the root budget.
 * @return An owning handle to the page's memory, in the process's table; the RAM it gives as the kernel's is the
 *     page's own frame's physical address. Null if there's no memory, no frame or no handle.
 */
test_device_page :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) -> slop_os.Handle? {
    memory :: create_memory(kernel, cast[u64](process), kernel.root_budget, PAGE) or_return null
    frame :: frame_for(kernel, memory, 0)
    if frame == 0 {
        return null
    }
    device :: arch.test_device()
    info :: cast[ptr[mut test_device.TestDeviceInfo]](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](frame)))
    kind : slop_os.ControllerKind = match device.kind {
        case .IoApic => .IoApic
        case .GicDistributor => .GicDistributor
        case _ => .Plic
    }
    info.kind = cast[u32](kind)
    info.line = device.line
    info.flags = (if device.trigger == .Level { cast[u32](slop_os.IRQ_LEVEL) } else { cast[u32](0) })
        | (if device.polarity == .ActiveLow { cast[u32](slop_os.IRQ_ACTIVE_LOW) } else { cast[u32](0) })
    info.registers = cast[u64](device.registers)
    info.kernel_ram = frame
    return handle_for(kernel, process, cast[u64](memory), .Memory, true)
}

/**
 * Make a handle with every right in a process's table.
 *
 * @param kernel The kernel, whose frames pay for a new page of the table, if one is needed.
 * @param process The process whose table it goes in; it takes the table's lock, at rank HandleTable.
 * @param object The object, as an address, live; its current generation goes in the handle.
 * @param kind The object's kind, which has to be what object is: it's stored in the handle, not checked.
 * @param owning Whether it's the owning handle: the caller sees the process owns the object.
 * @return The handle, or null if it couldn't be made, as the table is full or there's no memory.
 */
handle_for :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], object: u64, kind: slop_os.ObjectKind, owning: bool) -> slop_os.Handle? {
    header :: cast[ptr[ObjectHeader]](object)
    match install(kernel, &process.table, object, header.generation, kind, slop_os.RIGHTS_ALL, owning) {
        case Ok(handle) => return handle
        case Error(error) => return null
    }
}

/**
 * Add a grant after the first ones in a startup block's grants.
 *
 * @param grants The grants, in the startup block's buffer, zeroed past count.
 * @param count How many grants are there already.
 * @param label The grant's label, cut short at slop_os.GRANT_LABEL_SIZE bytes; zeros fill the rest.
 * @param kind The kind of object the handle is to.
 * @param handle The handle, in the root task's table.
 * @return How many grants there are now: count plus 1, or count if there was no room, when an error is logged.
 */
add_grant :: fn(grants: mut slop_os.Grant[], count: usize, label: string, kind: slop_os.ObjectKind, handle: slop_os.Handle) -> usize {
    if count >= grants.count {
        runtime.log_error("the root task has room for % grants, so it isn't given %", grants.count, label)
        return count
    }
    grant :: &grants[count]
    for byte, i in label {
        if i < grant.label.count {
            grant.label[i] = cast[u8](byte)
        }
    }
    grant.kind = kind
    grant.handle = handle
    return count + 1
}

/**
 * Tell whether a boot module is a typed library, by its name's ending: .library.
 *
 * @param name A boot module's name, any string; compared byte by byte, so the case of the ending matters.
 * @return True if it ends with ".library", which may be all of it.
 */
is_library :: fn(name: string) -> bool {
    ending :: ".library"
    if name.count < ending.count {
        return false
    }
    start :: name.count - ending.count
    return start <= name.count && name[start..<name.count] == ending
}
