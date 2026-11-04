package bootloader

import boot_protocol from "../../boot_protocol"

/*
 * The kernel's ELF (src/boot/slopos's linker scripts): a position-independent executable linked in the top 2 GiB, whose
 * loadable segments are copied into pages of their own, as one image, moved by a random multiple of 2 MiB, under 1 GiB,
 * with its relative relocations applied, the only kind it has.
 */

/** An ELF64 file header's size in bytes (System V ABI, ELF specification). */
ELF_HEADER_SIZE : u64 : 64
/** An ELF64 program header's size in bytes, which the file's e_phentsize has to be. */
PROGRAM_HEADER_SIZE : u64 : 56
/** A program header's type for a loadable segment. */
PT_LOAD : u32 : 1
/** A program header's type for the dynamic segment, which holds the relocations' tags. */
PT_DYNAMIC : u32 : 2
/** A program header's flag: the segment is executable. */
PF_EXECUTE : u32 : 1
/** A program header's flag: the segment is writable. */
PF_WRITE : u32 : 2
/** A dynamic entry's tag that ends the dynamic segment. */
DT_NULL : u64 : 0
/** A dynamic entry's tag whose value is the RELA table's virtual address, as linked. */
DT_RELA : u64 : 7
/** A dynamic entry's tag whose value is the RELA table's size in bytes. */
DT_RELASZ : u64 : 8
/** An Elf64_Rela entry's size in bytes: its offset, info and addend, each 8. */
RELA_SIZE : u64 : 24

#if TARGET_ARCH == .x86_64 {
    /** The ELF machine the kernel has to be for: EM_X86_64. */
    ELF_MACHINE : u64 : 62
    /** The only relocation type the kernel may have: R_X86_64_RELATIVE, the slide added to the addend. */
    RELATIVE : u64 : 8
}
#else {
    /** The ELF machine the kernel has to be for: EM_AARCH64. */
    ELF_MACHINE : u64 : 183
    /** The only relocation type the kernel may have: R_AARCH64_RELATIVE, the slide added to the addend. */
    RELATIVE : u64 : 1027
}

/** The kernel loaded: its pages, where it runs, its entry from there, and its segments. */
LoadedKernel :: struct {
    /** The image's physical address, 4096-aligned, in KERNEL_MEMORY pages. */
    physical : u64,
    /**
     * The image's size in bytes, from its lowest segment's page to its highest's end: a multiple of 4096, at most
     * 1 GiB.
     */
    size : u64,
    /** The virtual address the image's first byte runs at: its lowest link address, page-aligned, plus the slide. */
    virtual_base : u64,
    /** The entry point's offset in bytes from virtual_base. */
    entry : u64,
    /** The loadable segments, as they run: their virtual addresses with the slide, sizes in memory and permissions. */
    segments : boot_protocol.Segment[boot_protocol.MAX_SEGMENTS],
    /** How many of segments are filled; segments past MAX_SEGMENTS are loaded but not listed. */
    segment_count : usize,
}

/**
 * Read a little-endian number from a file in pages.
 *
 * @param file The file's pages.
 * @param offset Where the number starts, in bytes from the file's start.
 * @param size How many bytes it is, 1 to 8.
 * @return The number; 0 if any of it is past the file's end.
 */
read_at :: fn(file: Pages, offset: u64, size: u64) -> u64 {
    if offset > file.size || size > file.size - offset {
        return 0
    }
    value := cast[u64](0)
    for i in cast[u64](0)..<size {
        value |= cast[u64](cast[ptr[u8]](cast[rawptr](file.address + offset + i))^) << (8 * i)
    }
    return value
}

/**
 * Load the kernel's ELF into pages of its own and relocate it to a random place.
 *
 * Its loadable segments are copied into one image, zeroed where a segment's memory is longer than its file, and moved
 * by a random multiple of 2 MiB under 1 GiB (none without KASLR), with its relative relocations applied. Pages are not
 * freed when it fails part way.
 *
 * @param file The kernel's file, read whole; it's read, not changed, and may be freed after.
 * @param random Where the slide comes from.
 * @return The kernel loaded; null if it isn't a little-endian ELF64 shared object for this machine, its segments span
 *     more than 1 GiB or none, a segment's bytes are outside the file, pages couldn't be had, or it has a relocation
 *     other than a relative one, or one outside the image.
 */
load_kernel :: fn(file: Pages, random: ptr[Random]) -> LoadedKernel? {
    if file.size < ELF_HEADER_SIZE || read_at(file, 0, 4) != 0x464c457f || read_at(file, 4, 1) != 2 || read_at(file, 5, 1) != 1
        || read_at(file, 16, 2) != 3 || read_at(file, 18, 2) != ELF_MACHINE || read_at(file, 54, 2) != PROGRAM_HEADER_SIZE {
        return null
    }
    headers :: read_at(file, 32, 8)
    count :: read_at(file, 56, 2)
    lowest := ~cast[u64](0)
    highest := cast[u64](0)
    dynamic := cast[u64](0)
    for i in cast[u64](0)..<count {
        at :: headers + i * PROGRAM_HEADER_SIZE
        kind :: cast[u32](read_at(file, at, 4))
        address :: read_at(file, at + 16, 8)
        if kind == PT_DYNAMIC {
            dynamic = address
        }
        if kind != PT_LOAD {
            continue
        }
        end :: address + read_at(file, at + 40, 8)
        lowest = if address < lowest { address } else { lowest }
        highest = if end > highest { end } else { highest }
    }
    lowest = lowest & ~cast[u64](4095)
    highest = (highest + 4095) & ~cast[u64](4095)
    if highest <= lowest || highest - lowest > (1 << 30) {
        return null
    }
    size :: highest - lowest
    physical :: allocate_pages(KERNEL_MEMORY, size) or_return null
    loaded := LoadedKernel.{physical = physical, size = size}
    slide :: (random_u64(random) % 512) * (1 << 21)
    loaded.virtual_base = lowest + slide
    loaded.entry = read_at(file, 24, 8) - lowest
    for i in cast[u64](0)..<count {
        at :: headers + i * PROGRAM_HEADER_SIZE
        if cast[u32](read_at(file, at, 4)) != PT_LOAD {
            continue
        }
        flags :: cast[u32](read_at(file, at + 4, 4))
        offset :: read_at(file, at + 8, 8)
        address :: read_at(file, at + 16, 8)
        file_size :: read_at(file, at + 32, 8)
        memory_size :: read_at(file, at + 40, 8)
        if offset > file.size || file_size > file.size - offset || file_size > memory_size {
            return null
        }
        copy(physical + (address - lowest), file.address + offset, file_size)
        if loaded.segment_count < loaded.segments.count {
            loaded.segments[loaded.segment_count] = boot_protocol.Segment.{virtual_base = address + slide, size = memory_size,
                writable = if flags & PF_WRITE != 0 { 1 } else { 0 }, executable = if flags & PF_EXECUTE != 0 { 1 } else { 0 }}
            loaded.segment_count += 1
        }
    }
    if dynamic != 0 && !relocate(&loaded, lowest, dynamic, slide) {
        return null
    }
    return loaded
}

/**
 * Apply the relative relocations the dynamic segment names, in the loaded image, for its slide.
 *
 * Each relocated word becomes its addend plus slide. The dynamic segment is read from the image, not the file.
 *
 * @param loaded The kernel loaded, its segments copied in.
 * @param lowest The image's lowest link address, page-aligned, which link addresses are made image offsets with.
 * @param dynamic The dynamic segment's link address.
 * @param slide How far the image moves from its link addresses, in bytes.
 * @return True if every relocation was applied, or there were none; false at the first of another kind than
 *     RELATIVE, or one whose word is outside the image, those before it applied.
 */
relocate :: fn(loaded: ptr[LoadedKernel], lowest: u64, dynamic: u64, slide: u64) -> bool {
    image :: Pages.{address = loaded.physical, size = loaded.size}
    table := cast[u64](0)
    bytes := cast[u64](0)
    at := dynamic - lowest
    loop {
        tag :: read_at(image, at, 8)
        value :: read_at(image, at + 8, 8)
        if tag == DT_NULL || at >= image.size {
            break
        }
        if tag == DT_RELA {
            table = value - lowest
        }
        else if tag == DT_RELASZ {
            bytes = value
        }
        at += 16
    }
    for i in cast[u64](0)..<bytes / RELA_SIZE {
        entry :: table + i * RELA_SIZE
        offset :: read_at(image, entry, 8) - lowest
        if read_at(image, entry + 8, 8) & 0xffffffff != RELATIVE || offset > image.size - 8 {
            return false
        }
        cast[ptr[mut u64]](cast[rawptr](image.address + offset))^ = read_at(image, entry + 16, 8) + slide
    }
    return true
}

/**
 * Copy bytes between physical addresses, one at a time.
 *
 * @param to Where they go, identity-mapped.
 * @param from Where they come from, identity-mapped; the ranges shouldn't overlap.
 * @param count How many bytes.
 */
copy :: fn(to: u64, from: u64, count: u64) {
    for i in cast[u64](0)..<count {
        cast[ptr[mut u8]](cast[rawptr](to + i))^ = cast[ptr[u8]](cast[rawptr](from + i))^
    }
}
