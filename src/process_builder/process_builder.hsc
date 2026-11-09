/**
 * Building a process from an executable (decisions/0058, 0067), as the kernel builds the root task, through
 * system calls: the root task builds its first services with it, and the process manager every program
 * after them. The process, its address space and its budget are the requester's, made before:
 *
 *     built :: process_builder.build(target, file, grants, seed, &stream)?
 *
 * The image, its stack and its startup block (docs/specs/programs.md) are memory objects charged to the
 * target's budget, each at a random place, and go to the process with its address space, its handles to
 * itself and its budget, and its grants; then its first thread starts. The builder keeps none of it.
 *
 * Every segment is mapped from the image, the process's own: none from the memory its file is in, which its bundle
 * store's memory would be, so a store that ends takes no process's code with it (decisions/0186's chaos finding, as
 * 0181's F6 asks of every service).

 *
 * The startup block says the kernel's ABI version, unless a test asks for another (abi_version), to see a program
 * refuse it.
 */
package process_builder

import runtime from "base"
import slop_os from "std/os"
import elf_loader from "../elf_loader"
import random_stream from "../random_stream"

/** The page size mappings are made in, in bytes: 4 KiB, on both architectures. */
PAGE : u64 : 4096
// The first thread's stack, and the free range a program's runtime maps its own memory in.
/** The first thread's stack's size, in bytes: 256 KiB, a whole number of pages. */
STACK_SIZE : u64 : 256 * 1024
/** The free range's size, in bytes: 1 TiB of addresses, none of them mapped at the start. */
FREE_SIZE : u64 : 1 << 40
/**
 * The region its threads' shadow stacks go in, from the top of its free range, which is that much smaller: room for 256
 * slots, each a guard page and slop_os.SHADOW_STACK_BYTES (decisions/0186).
 */
SHADOW_REGION_SIZE : u64 : 256 * (slop_os.SHADOW_STACK_BYTES + PAGE)
// User addresses, on both architectures (src/arch/*/paging.hsc).
/** The lowest user address a part is placed at: 64 KiB, the architectures' lowest user address. */
USER_LOW : u64 : 0x10000
/** One past the highest user address a part is placed at: a page below 2^47. */
USER_HIGH : u64 : 0x00007ffffffff000
/** The most grants a process starts with, from this; build refuses more with TooManyGrants. */
MAX_GRANTS :: 48
/** Handles that go to the process besides its grants: its space, itself, its budget, its image, stack and block. */
OWN_HANDLES :: 6

/** What to build into: the requester's, made before build is called, and still the requester's to destroy. */
Target :: struct {
    /** The process, with RIGHT_PROCESS_THREADS, RIGHT_DUPLICATE and RIGHT_TRANSFER; build doesn't close it. */
    process : slop_os.Process,
    /**
     * The process's address space, an owning handle: build maps in it and starts the thread in it through a duplicate,
     * and the handle itself goes to the process when build gets that far, staying the caller's if build fails before.
     */
    space : slop_os.AddressSpace,
    /**
     * The budget everything is charged to: the image, stack, block and first thread. It needs RIGHT_BUDGET_CHARGE,
     * RIGHT_DUPLICATE and RIGHT_TRANSFER; build gives the process a duplicate of it, and doesn't close it.
     */
    budget : slop_os.MemoryBudget,
}

/** A handle the process starts with, which goes to it, and its label, padded with zeros. */
Grant :: struct {
    /**
     * The label the process finds the handle by in its startup block: text padded with zeros, not necessarily ended
     * by one when it takes all GRANT_LABEL_SIZE bytes.
     */
    label : u8[slop_os.GRANT_LABEL_SIZE],
    /** The handle, which needs RIGHT_TRANSFER: it moves to the process once build gives the process its handles. */
    handle : slop_os.Handle,
}

/**
 * Make a grant from a label's text and a handle.
 *
 * @param label The label; bytes past GRANT_LABEL_SIZE are silently left out.
 * @param handle The handle the grant gives; it isn't checked or duplicated.
 * @return The grant, its label padded with zeros.
 */
grant :: fn(label: string, handle: slop_os.Handle) -> Grant {
    made := Grant.{handle = handle}
    for byte, i in label {
        if i < made.label.count {
            made.label[i] = cast[u8](byte)
        }
    }
    return made
}

/** Why a process couldn't be built. */
BuildError :: enum {
    /** The file isn't an executable elf_loader can load. */
    NotAProgram,
    /** More than MAX_GRANTS grants. */
    TooManyGrants,
    /** No room in the builder's own free range for its own mappings (runtime.reserve_addresses). */
    NoAddresses,
    /** The target's budget couldn't pay, there was no memory, or a mapping couldn't be made. */
    NoMemory,
    /** A call on the target's or the grants' handles failed: missing rights, or objects gone. */
    Failed,
}

/** Where a process's parts go in its address space: page-aligned user addresses. */
Layout :: struct {
    /** The image's base, the address its relocations are applied for, in the lowest quarter of user addresses. */
    image : u64,
    /** The stack's lowest address, in the second quarter of user addresses; the stack grows down from its top. */
    stack : u64,
    /** The startup block's address: a page above the stack's top, the page between left unmapped. */
    block : u64,
    /** The free range's start, FREE_SIZE bytes in the upper half of user addresses. */
    free : u64,
}

/**
 * Where a builder stages what it builds, in its own address space, kept from build to build: the image's addresses,
 * and the startup block's. Zero is none yet.
 */
Staging :: struct {
    /** Each area's address, 0 for none yet: the image's first, then the startup block's. */
    addresses : u64[2],
    /** Each area's size in bytes, a whole number of pages. */
    sizes : u64[2],
}

/**
 * Give an address to stage size bytes at, from staging's area if it's big enough, or else a new area of the builder's
 * free range, at least twice the old one so a run of growing builds takes few.
 *
 * @param staging The builder's staging, whose area is replaced when it's too small; null takes new addresses.
 * @param area Which area: 0 for the image, 1 for the startup block.
 * @param size How many bytes are to be mapped there, in bytes.
 * @return The area's address, page aligned, with at least size bytes nothing else uses; null if the free range has no
 *     room left.
 */
staged :: fn(staging: ptr[mut Staging]?, area: usize, size: u64) -> u64? {
    match staging {
        case Some(kept) => {
            if area >= kept.addresses.count || area >= kept.sizes.count {
                return null
            }
            if kept.addresses[area] != 0 && kept.sizes[area] >= size {
                return kept.addresses[area]
            }
            wanted :: if kept.sizes[area] * 2 > size { kept.sizes[area] * 2 } else { page_up(size) }
            address :: runtime.reserve_addresses(cast[usize](wanted)) or_return null
            kept.addresses[area] = address
            kept.sizes[area] = wanted
            return address
        }
        case None => return runtime.reserve_addresses(cast[usize](size))
    }
}

/**
 * Build a process from an executable in the target, and start its first thread.
 *
 * The image, stack and startup block are made, each a memory object charged to the target's budget, and mapped at
 * random places in the target's address space; then they, the address space, a handle to the process itself, a
 * duplicate of its budget, and the grants all go to the process, and its first thread starts at the executable's
 * entry with the startup block's address as its argument. The builder keeps none of it.
 *
 * On a failure the handles made are closed, but what's already mapped in the target's space stays: the target is the
 * requester's to destroy. The grants and the target's space are the caller's still, unless only starting the thread
 * failed, by when they've gone to the process. The builder stages the image and the startup block at addresses from
 * its own free range, which can't be given back: given staging, the same ones are used again for every build, and a
 * bigger one taken only when a build needs it; without, each build takes new ones, for good.
 *
 * @param target The process, address space and budget to build into, with the rights Target's fields say.
 * @param file The whole executable file; only read, and not kept.
 * @param grants The handles the process starts with, at most MAX_GRANTS, each with RIGHT_TRANSFER, in the order the
 *     startup block lists them.
 * @param seed The 32 bytes that go in the startup block, for the process's context.random (decisions/0068); they
 *     should be secret and random.
 * @param random The stream the parts' places are drawn from, moved on by each draw; the layout is as random as it.
 * @param abi_version The ABI version the startup block says: the kernel's, unless a test asks for another to see a
 *     program refuse it.
 * @param staging Where the builder stages, kept from build to build by a caller that builds many processes over its
 *     life, so its free range isn't used up; null for a caller that builds few, which takes new addresses each time.
 *     Not safe to share between builds running at once.
 * @return The process's first thread's ID, not a handle the caller owns, and where its image is.
 * @error TooManyGrants There are more than MAX_GRANTS grants; nothing is made.
 * @error NotAProgram elf_loader can't read, load or relocate the file.
 * @error NoAddresses The builder's free range has no room left to stage the image or the block.
 * @error NoMemory The budget couldn't pay for a memory object, or a mapping couldn't be made.
 * @error Failed A handle couldn't be duplicated or inspected, the staging couldn't be unmapped, the handles couldn't
 *     go to the process, or the thread couldn't be started.
 */
build :: fn(target: Target, file: u8[], grants: Grant[], seed: u8[32], random: ptr[mut random_stream.Stream],
    abi_version: u32 = slop_os.ABI_VERSION, staging: ptr[mut Staging]? = null) -> Result[Built, BuildError] {
    if grants.count > MAX_GRANTS {
        return .Error(.TooManyGrants)
    }
    executable := elf_loader.read(file) or_return .Error(.NotAProgram)
    own :: slop_os.startup_block().space
    made := Made.{}
    defer close_all(&made)
    // A handle to the space to work with, kept while the owning one goes to the process
    space_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_SPACE_MAP) | cast[u32](slop_os.RIGHT_SPACE_THREADS))
    space :: cast[slop_os.AddressSpace](slop_os.handle_duplicate(cast[slop_os.Handle](target.space), space_rights) or_return .Error(.Failed))
    defer _ = slop_os.handle_close(cast[slop_os.Handle](space))
    grants_at :: (cast[u64](size_of(slop_os.StartupBlock)) + 7) & ~cast[u64](7)
    block_size :: page_up(grants_at + cast[u64](grants.count) * cast[u64](size_of(slop_os.Grant)))
    layout :: choose_layout(random, executable.size, block_size)

    // The image, loaded and relocated where the builder can reach it, then mapped a segment at a time
    image :: memory(&made, target.budget, executable.size)?
    image_staging :: staged(staging, 0, executable.size) or_return .Error(.NoAddresses)
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(image, own, image_staging, 0, executable.size, read_write) or_return .Error(.NoMemory)
    contents :: view_of(cast[ptr[mut u8]](image_staging), cast[usize](executable.size))
    loaded :: elf_loader.load(&executable, file, contents)
    relocated :: elf_loader.relocate(&executable, file, contents, layout.image)
    slop_os.memory_unmap(own, image_staging) or_return .Error(.Failed)
    loaded or_return .Error(.NotAProgram)
    relocated or_return .Error(.NotAProgram)
    map_segments(&executable, image, space, layout.image)?

    stack :: memory(&made, target.budget, STACK_SIZE)?
    slop_os.memory_map(stack, space, layout.stack, 0, STACK_SIZE, read_write) or_return .Error(.NoMemory)
    block_memory :: memory(&made, target.budget, block_size)?
    block_staging :: staged(staging, 1, block_size) or_return .Error(.NoAddresses)
    slop_os.memory_map(block_memory, own, block_staging, 0, block_size, read_write) or_return .Error(.NoMemory)
    defer _ = slop_os.memory_unmap(own, block_staging)
    slop_os.memory_map(block_memory, space, layout.block, 0, block_size, slop_os.PROTECTION_READ) or_return .Error(.NoMemory)

    // Everything that goes to the process, its own handles first, and what kind each grant is
    self_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    self :: slop_os.handle_duplicate(cast[slop_os.Handle](target.process), self_rights) or_return .Error(.Failed)
    remember(&made, self)
    budget_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_BUDGET_CHARGE) | cast[u32](slop_os.RIGHT_DUPLICATE)
        | cast[u32](slop_os.RIGHT_TRANSFER))
    budget :: slop_os.handle_duplicate(cast[slop_os.Handle](target.budget), budget_rights) or_return .Error(.Failed)
    remember(&made, budget)
    handles : slop_os.Handle[OWN_HANDLES + MAX_GRANTS]
    handles[0] = cast[slop_os.Handle](target.space)
    handles[1] = self
    handles[2] = budget
    handles[3] = cast[slop_os.Handle](image)
    handles[4] = cast[slop_os.Handle](stack)
    handles[5] = cast[slop_os.Handle](block_memory)
    kinds : slop_os.ObjectKind[MAX_GRANTS]
    for grant, i in grants {
        handles[OWN_HANDLES + i] = grant.handle
        info :: slop_os.handle_info(grant.handle) or_return .Error(.Failed)
        kinds[i] = info.kind
    }
    count :: OWN_HANDLES + grants.count
    given : slop_os.Handle[OWN_HANDLES + MAX_GRANTS]
    slop_os.process_give_handles(target.process, view_of(&handles[0], count), view_of(&given[0], count)) or_return .Error(.Failed)
    // They're the process's now
    made.count = 0

    block :: cast[ptr[mut slop_os.StartupBlock]](block_staging)
    block.abi_version = abi_version
    block.size = cast[u32](size_of(slop_os.StartupBlock))
    block.process = cast[slop_os.Process](given[1])
    block.space = cast[slop_os.AddressSpace](given[0])
    block.budget = cast[slop_os.MemoryBudget](given[2])
    block.grant_count = cast[u32](grants.count)
    block.free_base = layout.free
    block.free_size = FREE_SIZE - SHADOW_REGION_SIZE
    block.stack_base = layout.stack
    block.stack_size = STACK_SIZE
    block.grants = grants_at
    block.seed = seed
    block.cpu_features = slop_os.startup_block().cpu_features
    written :: view_of(cast[ptr[mut slop_os.Grant]](block_staging + grants_at), grants.count)
    for &grant, i in written {
        if i < grants.count && i < kinds.count && OWN_HANDLES + i < given.count {
            grant.label = grants[i].label
            grant.kind = kinds[i]
            grant.handle = given[OWN_HANDLES + i]
        }
    }
    // What its code was built for, and its shadow stacks' region, before its first thread (decisions/0186)
    slop_os.process_set_control_flow(target.process, executable.control_flow, layout.free + FREE_SIZE - SHADOW_REGION_SIZE,
        SHADOW_REGION_SIZE) or_return .Error(.Failed)
    // As a call leaves it: 8 below a multiple of 16
    thread :: slop_os.thread_create_in(target.process, target.budget, space, layout.image + executable.entry, layout.stack + STACK_SIZE - 8,
        layout.block) or_return .Error(.Failed)
    return .Ok(Built.{thread = thread, image = layout.image})
}

/** A process build started. */
Built :: struct {
    /** Its first thread's ID in the target process, not a handle. */
    thread : u64,
    /** The address its image is at in the target's space, which its relocations were applied for. */
    image : u64,
}

/** Handles build made, closed if it fails before they go to the process. */
Made :: struct {
    /** The handles, owning, their first count used; build makes 5 of them. */
    handles : slop_os.Handle[8],
    /** How many of handles are build's to close: 0 once they've gone to the process. */
    count : usize,
}

/**
 * Remember a handle build made, to be closed if build fails.
 *
 * @param made Where it's remembered.
 * @param handle The handle, owning; when made is full it isn't remembered, and wouldn't be closed.
 */
remember :: fn(made: ptr[mut Made], handle: slop_os.Handle) {
    if made.count < made.handles.count {
        made.handles[made.count] = handle
        made.count += 1
    }
}

/**
 * Close every handle remembered, ignoring failures, and forget them.
 *
 * @param made The handles; its count is 0 after, so closing again closes nothing.
 */
close_all :: fn(made: ptr[mut Made]) {
    for handle, i in made.handles {
        if i >= made.count {
            break
        }
        _ = slop_os.handle_close(handle)
    }
    made.count = 0
}

/**
 * Make a memory object charged to a budget, and remember it to close if build fails.
 *
 * @param made Where the new handle is remembered.
 * @param budget The budget that pays for it, with RIGHT_BUDGET_CHARGE.
 * @param size Its size in bytes, as memory_create takes it.
 * @return An owning handle to the memory object, zeroed as memory_create makes it.
 * @error NoMemory The budget couldn't pay, or memory_create failed for another reason.
 */
memory :: fn(made: ptr[mut Made], budget: slop_os.MemoryBudget, size: u64) -> Result[slop_os.Memory, BuildError] {
    created :: slop_os.memory_create(budget, size) or_return .Error(.NoMemory)
    remember(made, cast[slop_os.Handle](created))
    return .Ok(created)
}

/**
 * Map the image's segments in an address space, each with its protection, and its RELRO pages read-only.
 *
 * Each segment takes whole pages, from the page its start is on to the page its end is on. In a writable segment,
 * the RELRO range's pages, its start rounded down and its end rounded down, are mapped read only. Every segment is
 * mapped from the image.
 *
 * @param executable The executable the image was loaded from; not changed.
 * @param image The memory object holding the loaded, relocated image, its byte 0 the image's base.
 * @param space The address space to map in, with RIGHT_SPACE_MAP.
 * @param base Where the image's base goes in space, page-aligned.
 * @error NoMemory A mapping from image couldn't be made; segments before it stay mapped.
 */
map_segments :: fn(executable: ptr[elf_loader.Executable], image: slop_os.Memory, space: slop_os.AddressSpace, base: u64)
    -> Result[void, BuildError] {
    relro_start :: executable.relro_address & ~(PAGE - 1)
    relro_end :: (executable.relro_address + executable.relro_size) & ~(PAGE - 1)
    for i in 0..<executable.segment_count {
        if i >= executable.segments.count {
            break
        }
        segment :: executable.segments[i]
        start :: segment.address & ~(PAGE - 1)
        end :: page_up(segment.address + segment.memory_size)
        protection :: segment.protection
        writable :: cast[u32](protection) & cast[u32](slop_os.PROTECTION_WRITE) != 0
        if writable && relro_start < end && relro_end > start {
            // Before the RELRO pages, the RELRO pages read-only, and after
            middle_start :: max_u64(start, relro_start)
            middle_end :: min_u64(end, relro_end)
            map_part(image, space, base, start, middle_start, protection)?
            map_part(image, space, base, middle_start, middle_end, slop_os.PROTECTION_READ)?
            map_part(image, space, base, middle_end, end, protection)?
            continue
        }
        map_part(image, space, base, start, end, protection)?
    }
    return .Ok
}

/**
 * Map a range of the image's pages in an address space, if there are any.
 *
 * @param image The memory object holding the image.
 * @param space The address space to map in.
 * @param base Where the image's base goes in space, page-aligned.
 * @param start Where the range starts, in bytes from the image's base, page-aligned.
 * @param end Where it ends, in bytes from the image's base, page-aligned; at or below start maps nothing.
 * @param protection What the pages are mapped with.
 * @error NoMemory The mapping couldn't be made.
 */
map_part :: fn(image: slop_os.Memory, space: slop_os.AddressSpace, base: u64, start: u64, end: u64, protection: slop_os.Protection)
    -> Result[void, BuildError] {
    if end <= start {
        return .Ok
    }
    slop_os.memory_map(image, space, base + start, start, end - start, protection) or_return .Error(.NoMemory)
    return .Ok
}

/**
 * Choose where the image, the stack and the startup block, and the free range go.
 *
 * Each goes at a random page in a quarter of user addresses of its own (the free range in the upper half), as the
 * kernel places the root task's, the block a page above the stack's top.
 *
 * @param random The stream the places are drawn from, moved on by each draw.
 * @param image_size The image's size in bytes, a whole number of pages.
 * @param block_size The startup block's size in bytes, a whole number of pages.
 * @return The layout, every address page-aligned.
 */
choose_layout :: fn(random: ptr[mut random_stream.Stream], image_size: u64, block_size: u64) -> Layout {
    quarter :: ((USER_HIGH - USER_LOW) / 4) & ~(PAGE - 1)
    stack :: random_place(random, USER_LOW + quarter, quarter, STACK_SIZE + PAGE + block_size)
    return Layout.{
        image = random_place(random, USER_LOW, quarter, image_size),
        stack = stack,
        // A page above the stack's top, unmapped, then the block
        block = stack + STACK_SIZE + PAGE,
        free = random_place(random, USER_LOW + 2 * quarter, 2 * quarter, FREE_SIZE),
    }
}

/**
 * Choose a random page-aligned place for a range, within a region.
 *
 * @param random The stream the place is drawn from, moved on by a draw.
 * @param start Where the region starts, page-aligned.
 * @param room The region's size in bytes.
 * @param size The range's size in bytes.
 * @return An address from start up to start + room - size, a whole number of pages past start, each as likely; start
 *     itself when size is room or more, so the range may then run past the region.
 */
random_place :: fn(random: ptr[mut random_stream.Stream], start: u64, room: u64, size: u64) -> u64 {
    if size >= room {
        return start
    }
    return start + random_stream.below(random, (room - size) / PAGE + 1) * PAGE
}

/**
 * Round a size or address up to a whole number of pages.
 *
 * @param value The bytes to round up; at most 2^64 - 4096, or the result wraps.
 * @return value rounded up to a multiple of PAGE, value itself if it's one already.
 */
page_up :: fn(value: u64) -> u64 {
    return (value + PAGE - 1) & ~(PAGE - 1)
}

/**
 * Give the smaller of two numbers.
 *
 * @param a One number, any value.
 * @param b The other number, any value; it's what comes back when the two are equal.
 * @return The smaller, b when they're equal.
 */
min_u64 :: fn(a: u64, b: u64) -> u64 {
    return if a < b { a } else { b }
}

/**
 * Give the larger of two numbers.
 *
 * @param a One number, any value.
 * @param b The other number, any value; it's what comes back when the two are equal.
 * @return The larger, b when they're equal.
 */
max_u64 :: fn(a: u64, b: u64) -> u64 {
    return if a > b { a } else { b }
}
