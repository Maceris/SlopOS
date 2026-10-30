package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * The kernel's own address space (roadmap M2, decisions/0048), which every address space shares as
 * its kernel half:
 * - the direct map: the RAM in the memory map at direct_map_offset plus its physical address, as the
 *   bootloader had it, never executable, with the kernel image's frames read-only there;
 * - the kernel image at the address the bootloader loaded it, each segment with its own protection.
 * Nothing in it is both writable and executable (W^X).
 *
 * Once every CPU runs on these tables and has left its boot stack, the bootloader's memory is
 * reclaimed (docs/specs/boot_info.md, Reclaiming Boot Memory).
 */

// The kernel's own table's address-space tag. Kernel mappings are global, so it rarely matters.
KERNEL_TAG :: cast[arch_interface.AddressSpaceTag](0)

DIRECT_MAP_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = false, global = true}
DIRECT_MAP_READ_ONLY :: arch_interface.Mapping.{protection = .Read, cache = .WriteBack, user = false, global = true}
DIRECT_MAP_FRAMEBUFFER :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteCombining, user = false, global = true}

// What building the kernel's tables keeps between mappings.
Mapper :: struct {
    // Zeroed frames for new tables, which map takes from.
    tables : arch_interface.TableFrames,
    pages_1g : bool,
    // Bytes the direct map covers, for the log.
    direct_bytes : u64,
}

/*
 * Build the kernel's page tables and switch the calling CPU, the boot CPU, to them. The other CPUs
 * switch as they start (cpu_started).
 */
start_address_space :: fn(kernel: ptr[mut Kernel], info: ptr[boot_info.BootInfo]) {
    root :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "no memory for the kernel's page tables")
    half_count :: cast[u64](arch.kernel_half_frames())
    half := cast[boot_info.PhysicalAddress](0)
    if half_count > 0 {
        half = frames.allocate_zeroed(&kernel.frames, frames.order_for(half_count * frames.FRAME_SIZE))
            or_else out_of_memory(&kernel.options, "no memory for the kernel's page tables")
    }
    arch.init_kernel_page_table(&kernel.page_table, root, half, KERNEL_TAG, info.direct_map_offset)

    mapper : Mapper
    mapper.pages_1g = arch.supports_page_size(.Size1G)
    map_direct(kernel, info.memory_map, info.direct_map_offset, &mapper)
    map_image(kernel, &info.kernel_image, &mapper)
    // The frames no mapping took
    count :: cast[usize](mapper.tables.count)
    runtime.assert(count <= 4, "TableFrames holds 4 frames")
    for i in 0..<count {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, mapper.tables.frames[i])
    }
    arch.activate(&kernel.page_table)
    runtime.log_info("kernel page tables active: % MiB of RAM in the direct map at %{#018x}, the image in % segments",
        mapper.direct_bytes >> 20, info.direct_map_offset, info.kernel_image.segments.count)
    start_window(kernel, info, mapper.direct_bytes)
}

/*
 * The direct map, of every region the frame allocator may own and the rest of the RAM the kernel
 * reads or hands on. Neighboring regions mapped alike are mapped as one, so they get the largest
 * pages that fit.
 */
map_direct :: fn(kernel: ptr[mut Kernel], memory_map: boot_info.MemoryRegion[], offset: u64, mapper: ptr[mut Mapper]) {
    run_start : u64 = 0
    run_end : u64 = 0
    run_mapping := DIRECT_MAP_DATA
    for region in memory_map {
        if !is_direct_mapped(region.kind) {
            continue
        }
        base :: cast[u64](region.range.base)
        mapping :: direct_mapping(region.kind)
        if base == run_end && run_end != 0 && same_mapping(mapping, run_mapping) {
            run_end = base + region.range.size
            continue
        }
        map_direct_run(kernel, offset, run_start, run_end, run_mapping, mapper)
        run_start = base
        run_end = base + region.range.size
        run_mapping = mapping
    }
    map_direct_run(kernel, offset, run_start, run_end, run_mapping, mapper)
}

map_direct_run :: fn(kernel: ptr[mut Kernel], offset: u64, start: u64, end: u64, mapping: arch_interface.Mapping, mapper: ptr[mut Mapper]) {
    if end > start {
        map_range(kernel, offset + start, start, end - start, mapping, mapper)
        mapper.direct_bytes += end - start
    }
}

// Whether the direct map covers memory of this kind: RAM, but not what's reserved or defective.
is_direct_mapped :: fn(kind: boot_info.MemoryKind) -> bool {
    return kind != .Reserved && kind != .Defective
}

/*
 * The kernel image's frames are read-only in the direct map, so no frame is writable through one
 * mapping and executable through another.
 */
direct_mapping :: fn(kind: boot_info.MemoryKind) -> arch_interface.Mapping {
    if kind == .KernelImage {
        return DIRECT_MAP_READ_ONLY
    }
    if kind == .Framebuffer {
        return DIRECT_MAP_FRAMEBUFFER
    }
    return DIRECT_MAP_DATA
}

same_mapping :: fn(a, b: arch_interface.Mapping) -> bool {
    return a.protection == b.protection && a.cache == b.cache && a.user == b.user && a.global == b.global
}

/*
 * Each loaded segment of the kernel image, at the address the bootloader loaded it, from its frames
 * in the image's physical range.
 */
map_image :: fn(kernel: ptr[mut Kernel], image: ptr[boot_info.KernelImage], mapper: ptr[mut Mapper]) {
    image_base :: cast[u64](image.virtual_base)
    physical_base :: cast[u64](image.physical.base)
    segments :: image.segments
    for segment in segments {
        runtime.assert(!(segment.writable && segment.executable), "no segment of the kernel image is both writable and executable (W^X)")
        start :: cast[u64](segment.virtual_base) & ~(frames.FRAME_SIZE - 1)
        end :: frames.round_up(cast[u64](segment.virtual_base) + segment.size, frames.FRAME_SIZE)
        runtime.assert(start >= image_base && end - image_base <= image.physical.size, "each segment is inside the kernel image")
        protection :: if segment.writable {
            arch_interface.Protection.ReadWrite
        }
        else if segment.executable {
            arch_interface.Protection.ReadExecute
        }
        else {
            arch_interface.Protection.Read
        }
        mapping :: arch_interface.Mapping.{protection = protection, cache = .WriteBack, user = false, global = true}
        map_range(kernel, start, physical_base + (start - image_base), end - start, mapping, mapper)
    }
}

// Map size bytes at virtual_address to physical, in the largest pages their alignment allows.
map_range :: fn(kernel: ptr[mut Kernel], virtual_address: u64, physical: u64, size: u64, mapping: arch_interface.Mapping, mapper: ptr[mut Mapper]) {
    offset : u64 = 0
    loop {
        page :: largest_page(virtual_address + offset, physical + offset, size - offset, mapper.pages_1g)
        map_page(kernel, virtual_address + offset, physical + offset, page, mapping, mapper)
        offset += page_bytes(page)
    }
    while offset < size
}

largest_page :: fn(virtual_address: u64, physical: u64, left: u64, pages_1g: bool) -> arch_interface.PageSize {
    if pages_1g && fits(virtual_address, physical, left, page_bytes(.Size1G)) {
        return .Size1G
    }
    if fits(virtual_address, physical, left, page_bytes(.Size2M)) {
        return .Size2M
    }
    return .Size4K
}

fits :: fn(virtual_address: u64, physical: u64, left: u64, bytes: u64) -> bool {
    return virtual_address % bytes == 0 && physical % bytes == 0 && left >= bytes
}

page_bytes :: fn(size: arch_interface.PageSize) -> u64 {
    return match size {
        case .Size4K => frames.FRAME_SIZE
        case .Size2M => frames.FRAME_SIZE << 9
        case .Size1G => frames.FRAME_SIZE << 18
    }
}

// Map one page in the kernel's table, giving it more table frames as it needs them.
map_page :: fn(kernel: ptr[mut Kernel], virtual_address: u64, physical: u64, size: arch_interface.PageSize, mapping: arch_interface.Mapping, mapper: ptr[mut Mapper]) {
    lock_at(&kernel.page_table_lock, .PageTable)
    defer unlock_at(&kernel.page_table_lock, .PageTable)
    loop {
        result :: arch.map(&kernel.page_table, cast[arch_interface.VirtualAddress](virtual_address),
            cast[arch_interface.PhysicalAddress](physical), size, mapping, &mapper.tables)
        match result {
            case Ok => return void
            case Error(error) => {
                runtime.assert(error == .NeedTableFrames, "the kernel's own mappings are aligned, supported and don't overlap")
                refill_tables(kernel, &mapper.tables)
            }
        }
    }
}

// Zeroed frames for new tables, from the calling CPU's cache of single frames.
refill_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[mut arch_interface.TableFrames]) {
    cache :: &per_cpu().frame_cache
    for i in cast[usize](tables.count)..<4 {
        frame :: frames.take_frame(cache, &kernel.frames) or_else out_of_memory(&kernel.options, "no memory for the kernel's page tables")
        intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, frame)), cast[usize](frames.FRAME_SIZE))
        tables.frames[i] = frame
    }
    tables.count = 4
}

/*
 * What the kernel keeps of BootInfo, which is in boot memory: the CPUs, and where boot memory is,
 * to reclaim it.
 */
keep_boot_info :: fn(kernel: ptr[mut Kernel], info: ptr[boot_info.BootInfo]) {
    cpus :: info.cpus
    cpus_address :: allocate_kept(kernel, cpus.count * size_of(boot_info.BootCpu))
    kept_cpus :: view_of(cast[ptr[mut boot_info.BootCpu]](cpus_address), cpus.count)
    kernel.cpus = kept_cpus
    kernel.per_cpus = view_of(cast[ptr[mut u64]](allocate_kept(kernel, cpus.count * size_of(u64))), cpus.count)
    for cpu, i in cpus {
        kept_cpus[i] = cpu
    }

    memory_map :: info.memory_map
    count : usize = 0
    for region in memory_map {
        if region.kind == .BootReclaimable {
            count += 1
        }
    }
    boot_memory :: view_of(cast[ptr[mut boot_info.PhysicalRange]](allocate_kept(kernel, count * size_of(boot_info.PhysicalRange))), count)
    kernel.boot_memory = boot_memory
    kept : usize = 0
    for region in memory_map {
        if region.kind == .BootReclaimable && kept < boot_memory.count {
            boot_memory[kept] = region.range
            kept += 1
        }
    }

    // The boot modules, their names copied out of boot memory
    modules :: view_of(cast[ptr[mut boot_info.BootModule]](allocate_kept(kernel, info.modules.count * size_of(boot_info.BootModule))),
        info.modules.count)
    for module, i in info.modules {
        if i < modules.count {
            name :: cast[ptr[mut u8]](allocate_kept(kernel, module.name.count))
            intrinsics.mem_copy_non_overlapping(cast[mut rawptr](name), cast[rawptr](module.name.data), module.name.count)
            modules[i] = boot_info.BootModule.{name = string_of(name, module.name.count), command_line = "", contents = module.contents}
        }
    }
    kernel.modules = modules
    // The command line, for the root task too
    command_line :: cast[ptr[mut u8]](allocate_kept(kernel, info.command_line.count))
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](command_line), cast[rawptr](info.command_line.data), info.command_line.count)
    kernel.command_line = string_of(command_line, info.command_line.count)
    // The boot's random seed, for the root task: the bootloader's, mixed with the CPU's
    match info.bootloader_entropy {
        case Some(bytes) => kernel.boot_seed = bytes
        case None => {}
    }
    for word in 0..<4 {
        match arch.hardware_entropy() {
            case Some(value) => {
                for b in 0..<8 {
                    at :: cast[usize](word * 8 + b)
                    if at < kernel.boot_seed.count {
                        kernel.boot_seed[at] = kernel.boot_seed[at] ~ cast[u8]((value >> (cast[u64](b) * 8)) & 0xff)
                    }
                }
            }
            case None => {}
        }
    }


    // The RAM the kernel owns, which device memory can't be made over (memory.hsc)
    owned : usize = 0
    for region in memory_map {
        if is_kernel_ram(region.kind) {
            owned += 1
        }
    }
    ram :: view_of(cast[ptr[mut boot_info.PhysicalRange]](allocate_kept(kernel, owned * size_of(boot_info.PhysicalRange))), owned)
    kernel.ram = ram
    kept_ram : usize = 0
    for region in memory_map {
        if is_kernel_ram(region.kind) && kept_ram < ram.count {
            ram[kept_ram] = region.range
            kept_ram += 1
        }
    }
}

/*
 * RAM the kernel hands out or holds: free memory, boot memory, its image and boot modules. A
 * framebuffer, firmware tables and the firmware's own memory are left to the platform service.
 */
is_kernel_ram :: fn(kind: boot_info.MemoryKind) -> bool {
    return kind == .Usable || kind == .BootReclaimable || kind == .KernelImage || kind == .BootModule
}

/*
 * size bytes in frames of their own, zeroed, for as long as the kernel runs: their address in the
 * direct map, which isn't held to any stack frame the way a pointer from a call can be (Hemera's
 * docs/memory.md, Returning).
 */
allocate_kept :: fn(kernel: ptr[mut Kernel], size: usize) -> u64 {
    address :: frames.allocate_zeroed(&kernel.frames, frames.order_for(cast[u64](size)))
        or_else out_of_memory(&kernel.options, "no memory for what the kernel keeps of the boot information")
    return frames.virtual_of(&kernel.frames, address)
}

/*
 * Once the other CPUs have started, get every CPU off its boot stack, so boot memory can be
 * reclaimed: a CPU leaves it for good the first time an interrupt takes it from idle to its kernel
 * stack (left_boot_stack). The boot CPU's first timer interrupt does that for it; the others are
 * woken. If a CPU didn't start, the bootloader may still have it waiting in boot memory, which then
 * stays as it is.
 */
leave_boot_stacks :: fn(kernel: ptr[mut Kernel]) {
    if cast[usize](kernel.online_cpus) < kernel.cpus.count {
        runtime.log_warn("boot memory isn't reclaimed: CPUs that didn't start may still be using it")
        return void
    }
    intrinsics.atomic_store_u32_release(&kernel.cpus_leaving_boot_stacks, kernel.online_cpus)
    cpus :: kernel.cpus
    for cpu, index in cpus {
        if index > 0 && index < cast[usize](kernel.online_cpus) {
            // Nothing is scheduled, so it goes straight back to idle, on its kernel stack
            arch.send_ipi(cpu.hardware_id, .Reschedule)
        }
    }
}

/*
 * Called at every interrupt from idle, on the CPU's kernel stack. The first time, it has left its
 * boot stack; the last CPU to do so reclaims boot memory.
 */
left_boot_stack :: fn() {
    cpu :: per_cpu()
    if cpu.left_boot_stack {
        return void
    }
    cpu.left_boot_stack = true
    kernel :: cpu.kernel
    left :: intrinsics.interlocked_increment_u32_acquire_release(&kernel.cpus_off_boot_stacks) + 1
    if left == intrinsics.atomic_load_u32_acquire(&kernel.cpus_leaving_boot_stacks) {
        reclaim_boot_memory(kernel)
    }
}

// Every CPU runs on the kernel's tables, off its boot stack, and the kernel kept what it needs of BootInfo.
reclaim_boot_memory :: fn(kernel: ptr[mut Kernel]) {
    boot_memory :: kernel.boot_memory
    for range in boot_memory {
        start :: cast[u64](range.base)
        frames.add_range(&kernel.frames, start, start + range.size)
    }
    runtime.log_info("boot memory reclaimed")
    log_memory(&kernel.frames)
}
