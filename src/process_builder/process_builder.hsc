/*
 * Building a process from an executable (decisions/0058, 0067), as the kernel builds the root task, through
 * system calls: the root task builds its first services with it, and the process manager every program
 * after them. The process, its address space and its budget are the requester's, made before:
 *
 *     thread :: process_builder.build(target, file, grants, seed, &stream)?
 *
 * The image, its stack and its startup block (docs/specs/programs.md) are memory objects charged to the
 * target's budget, each at a random place, and go to the process with its address space, its handles to
 * itself and its budget, and its grants; then its first thread starts. The builder keeps none of it.
 */
package process_builder

import runtime from "base"
import slop_os from "std/os"
import elf_loader from "../elf_loader"
import random_stream from "../random_stream"

PAGE : u64 : 4096
// The first thread's stack, and the free range a program's runtime maps its own memory in.
STACK_SIZE : u64 : 256 * 1024
FREE_SIZE : u64 : 1 << 40
// User addresses, on both architectures (src/arch/*/paging.hsc).
USER_LOW : u64 : 0x10000
USER_HIGH : u64 : 0x00007ffffffff000
// The most grants a process starts with, from this.
MAX_GRANTS :: 16
// Handles that go to the process besides its grants: its space, itself, its budget, its image, stack and block.
OWN_HANDLES :: 6

// What to build into: the requester's.
Target :: struct {
    // RIGHT_PROCESS_THREADS, RIGHT_DUPLICATE and RIGHT_TRANSFER
    process : slop_os.Process,
    // Owning: it goes to the process
    space : slop_os.AddressSpace,
    // RIGHT_BUDGET_CHARGE, RIGHT_DUPLICATE and RIGHT_TRANSFER: everything is charged to it
    budget : slop_os.MemoryBudget,
}

// A handle the process starts with, which goes to it, and its label, padded with zeros.
Grant :: struct {
    label : u8[slop_os.GRANT_LABEL_SIZE],
    handle : slop_os.Handle,
    // For a channel end, the protocol it speaks (os.protocol_tag), or 0
    tag : u64,
}

// A grant labeled label, for a channel end speaking tag's protocol.
grant :: fn(label: string, handle: slop_os.Handle, tag: u64 = 0) -> Grant {
    made := Grant.{handle = handle, tag = tag}
    for byte, i in label {
        if i < made.label.count {
            made.label[i] = cast[u8](byte)
        }
    }
    return made
}

BuildError :: enum {
    NotAProgram,
    TooManyGrants,
    // No room in the builder's free range for its own mappings
    NoAddresses,
    // The target's budget couldn't pay, or there was no memory
    NoMemory,
    // A call on the target's handles failed: missing rights, or objects gone
    Failed,
}

// Where its parts go in its address space.
Layout :: struct {
    image : u64,
    stack : u64,
    block : u64,
    free : u64,
}

/*
 * The executable in file, loaded into target with grants, and its first thread started: its ID. seed goes
 * in its startup block, for its context.random (decisions/0068), and random places its parts.
 * On a failure, what was made is closed, and the grants are the caller's still; the target is the
 * requester's to destroy.
 */
build :: fn(target: Target, file: u8[], grants: Grant[], seed: u8[32], random: ptr[mut random_stream.Stream]) -> Result[u64, BuildError] {
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
    staging :: runtime.reserve_addresses(cast[usize](executable.size)) or_return .Error(.NoAddresses)
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(image, own, staging, 0, executable.size, read_write) or_return .Error(.NoMemory)
    contents :: view_of(cast[ptr[mut u8]](staging), cast[usize](executable.size))
    loaded :: elf_loader.load(&executable, file, contents)
    relocated :: elf_loader.relocate(&executable, file, contents, layout.image)
    slop_os.memory_unmap(own, staging) or_return .Error(.Failed)
    loaded or_return .Error(.NotAProgram)
    relocated or_return .Error(.NotAProgram)
    map_segments(&executable, image, space, layout.image)?

    stack :: memory(&made, target.budget, STACK_SIZE)?
    slop_os.memory_map(stack, space, layout.stack, 0, STACK_SIZE, read_write) or_return .Error(.NoMemory)
    block_memory :: memory(&made, target.budget, block_size)?
    block_staging :: runtime.reserve_addresses(cast[usize](block_size)) or_return .Error(.NoAddresses)
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
    block.abi_version = slop_os.ABI_VERSION
    block.size = cast[u32](size_of(slop_os.StartupBlock))
    block.process = cast[slop_os.Process](given[1])
    block.space = cast[slop_os.AddressSpace](given[0])
    block.budget = cast[slop_os.MemoryBudget](given[2])
    block.grant_count = cast[u32](grants.count)
    block.free_base = layout.free
    block.free_size = FREE_SIZE
    block.stack_base = layout.stack
    block.stack_size = STACK_SIZE
    block.grants = grants_at
    block.seed = seed
    block.cpu_features = slop_os.startup_block().cpu_features
    written :: view_of(cast[ptr[mut slop_os.Grant]](block_staging + grants_at), grants.count)
    for &grant, i in written {
        if i < grants.count && i < kinds.count && OWN_HANDLES + i < given.count {
            grant.label = grants[i].label
            grant.tag = grants[i].tag
            grant.kind = kinds[i]
            grant.handle = given[OWN_HANDLES + i]
        }
    }
    // As a call leaves it: 8 below a multiple of 16
    thread :: slop_os.thread_create_in(target.process, target.budget, space, layout.image + executable.entry, layout.stack + STACK_SIZE - 8,
        layout.block) or_return .Error(.Failed)
    return .Ok(thread)
}

// Handles build made, closed if it fails before they go to the process.
Made :: struct {
    handles : slop_os.Handle[8],
    count : usize,
}

remember :: fn(made: ptr[mut Made], handle: slop_os.Handle) {
    if made.count < made.handles.count {
        made.handles[made.count] = handle
        made.count += 1
    }
}

close_all :: fn(made: ptr[mut Made]) {
    for handle, i in made.handles {
        if i >= made.count {
            break
        }
        _ = slop_os.handle_close(handle)
    }
    made.count = 0
}

// A memory object of size bytes, charged to budget, remembered in made.
memory :: fn(made: ptr[mut Made], budget: slop_os.MemoryBudget, size: u64) -> Result[slop_os.Memory, BuildError] {
    created :: slop_os.memory_create(budget, size) or_return .Error(.NoMemory)
    remember(made, cast[slop_os.Handle](created))
    return .Ok(created)
}

/*
 * The image's segments, mapped in space from base, each with its protection, and its RELRO pages
 * read-only.
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

// The image's pages from start to end, mapped at base + start with protection, if there are any.
map_part :: fn(image: slop_os.Memory, space: slop_os.AddressSpace, base: u64, start: u64, end: u64, protection: slop_os.Protection)
    -> Result[void, BuildError] {
    if end <= start {
        return .Ok
    }
    slop_os.memory_map(image, space, base + start, start, end - start, protection) or_return .Error(.NoMemory)
    return .Ok
}

/*
 * Where the image, the stack and the startup block, and the free range go: each at a random page in a
 * quarter of user addresses of its own (the free range in the upper half), as the kernel places the root
 * task's.
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

// A random page-aligned place for size bytes in the room bytes from start.
random_place :: fn(random: ptr[mut random_stream.Stream], start: u64, room: u64, size: u64) -> u64 {
    if size >= room {
        return start
    }
    return start + random_stream.below(random, (room - size) / PAGE + 1) * PAGE
}

page_up :: fn(value: u64) -> u64 {
    return (value + PAGE - 1) & ~(PAGE - 1)
}

min_u64 :: fn(a: u64, b: u64) -> u64 {
    return if a < b { a } else { b }
}

max_u64 :: fn(a: u64, b: u64) -> u64 {
    return if a > b { a } else { b }
}
