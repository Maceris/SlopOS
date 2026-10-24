package kernel

import intrinsics from "base"
import runtime from "base"
import slop_os from "std/os"
import text_buffer from "std"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import elf_loader from "../elf_loader"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * The root task (decisions/0012, 0058, 0060): the one process the kernel starts, from the first boot
 * module, given everything. The kernel loads it with the shared loader (src/elf_loader) into memory
 * objects it owns, at random places in its own address space, and starts its first thread with its
 * startup block (docs/specs/programs.md). Its grants:
 * - "platform", the platform capability;
 * - "debug_log", a debug log;
 * - "module:<name>", each other boot module, a read-only memory object over the frames it was loaded into.
 * Its own handles are to itself, its address space and the root memory budget, and its startup block
 * has the boot's random seed. Its end is the machine's: the kernel stops (processes.hsc).
 */

ROOT_STACK_SIZE : u64 : 256 * 1024
// The free range the root task's runtime maps its own memory in, 1 TiB.
ROOT_FREE_SIZE : u64 : 1 << 40
MAX_ROOT_GRANTS :: 32
PAGE : u64 : frames.FRAME_SIZE

// Where the root task's parts go in its address space.
RootLayout :: struct {
    image : u64,
    stack : u64,
    block : u64,
    free : u64,
}

/*
 * Start the root task from the first boot module, if the boot has any; on a failure, say why, and the
 * kernel carries on without it.
 */
start_root_task :: fn(kernel: ptr[mut Kernel]) {
    if kernel.modules.count == 0 {
        runtime.log_warn("no root task: the boot has no modules")
        return void
    }
    module :: kernel.modules[0]
    match load_root_task(kernel, module) {
        case Some(failure) => runtime.log_error("root task %: %", module.name, failure)
        case None => {}
    }
}

// Load module as the root task and start it, or what went wrong: always a constant, never on the stack.
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
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), budget) {
        case Ok(made) => space = made
        case Error(error) => return "no address space"
    }
    grant_count :: kernel.modules.count + 1
    block_size :: page_up(cast[u64](size_of(slop_os.StartupBlock)) + cast[u64](grant_count + 1) * cast[u64](size_of(slop_os.Grant)))
    layout :: choose_layout(kernel, executable.size, block_size)
    not_loaded :: load_image(kernel, process, space, &executable, file, layout.image)
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
    start_thread(kernel, thread)
    runtime.log_info("root task % started at %", module.name, cast[rawptr](layout.image))
    return null
}

/*
 * Where the image, the stack and the startup block, and the free range go: each at a random page in a
 * quarter of user addresses of its own (the free range in the upper half), the same every boot without KASLR.
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

// A random page-aligned place for size bytes in the room bytes from start.
random_place :: fn(kernel: ptr[Kernel], start: u64, room: u64, size: u64) -> u64 {
    if kernel.options.no_kaslr || size >= room {
        return start
    }
    pages :: (room - size) / PAGE
    return start + (random_bits(kernel) % (pages + 1)) * PAGE
}

// 64 random bits: the CPU's, or the boot seed's when it has none.
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

// value rounded up to whole pages.
page_up :: fn(value: u64) -> u64 {
    return (value + PAGE - 1) & ~(PAGE - 1)
}

/*
 * The executable, loaded and relocated for base, in a memory object process owns, mapped in space a segment
 * at a time with each one's protection, and its RELRO pages read-only.
 */
load_image :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], space: ptr[mut AddressSpace], executable: ptr[elf_loader.Executable],
    file: u8[], base: u64) -> string? #unrestricted {
    buffer, error :: runtime.new_array(u8, cast[usize](executable.size))
    if error != null {
        return "no memory to load it in"
    }
    defer runtime.free_array(buffer)
    match elf_loader.load(executable, file, buffer) {
        case Ok => {}
        case Error(failed) => return "its segments don't load"
    }
    match elf_loader.relocate(executable, file, buffer, base) {
        case Ok => {}
        case Error(failed) => return "its relocations don't apply"
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

// The image's pages from start to end, mapped at base + start with protection, if there are any.
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

// bytes copied into memory's pages from its start, giving it frames: false if there are none.
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

/*
 * The root task's handles and grants, and its startup block, written in memory of its own, mapped
 * read-only at layout.block.
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
    log :: create_debug_log(kernel, process) or_return "no debug log"
    count = add_grant(grants, count, "debug_log", .DebugLog, log)
    for module, i in kernel.modules {
        if i == 0 {
            continue
        }
        memory :: create_module_memory(kernel, cast[u64](process), kernel.root_budget, cast[u64](module.contents.base),
            page_up(module.contents.size)) or_return "no memory object for a module"
        handle :: handle_for(kernel, process, cast[u64](memory), .Memory, true) or_return "no handle to a module"
        label_storage : u8[slop_os.GRANT_LABEL_SIZE]
        label := text_buffer.make(label_storage)
        text_buffer.append(&label, "module:")
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

// A handle in process's table to object, owning if it owns it: every right.
handle_for :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], object: u64, kind: slop_os.ObjectKind, owning: bool) -> slop_os.Handle? {
    header :: cast[ptr[ObjectHeader]](object)
    match install(kernel, &process.table, object, header.generation, kind, slop_os.RIGHTS_ALL, owning) {
        case Ok(handle) => return handle
        case Error(error) => return null
    }
}

// grants with one more, labeled label, after its first count: how many it has now.
add_grant :: fn(grants: mut slop_os.Grant[], count: usize, label: string, kind: slop_os.ObjectKind, handle: slop_os.Handle) -> usize {
    if count >= grants.count {
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
