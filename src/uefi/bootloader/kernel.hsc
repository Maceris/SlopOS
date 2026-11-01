package bootloader

import boot_protocol from "../../boot_protocol"

/*
 * The kernel's ELF (src/boot/slopos's linker scripts): a position-independent executable linked in the top 2 GiB, whose
 * loadable segments are copied into pages of their own, as one image, moved by a random multiple of 2 MiB, under 1 GiB,
 * with its relative relocations applied, the only kind it has.
 */

ELF_HEADER_SIZE : u64 : 64
PROGRAM_HEADER_SIZE : u64 : 56
PT_LOAD : u32 : 1
PT_DYNAMIC : u32 : 2
PF_EXECUTE : u32 : 1
PF_WRITE : u32 : 2
DT_NULL : u64 : 0
DT_RELA : u64 : 7
DT_RELASZ : u64 : 8
RELA_SIZE : u64 : 24

#if TARGET_ARCH == .x86_64 {
    ELF_MACHINE : u64 : 62
    RELATIVE : u64 : 8
}
#else {
    ELF_MACHINE : u64 : 183
    RELATIVE : u64 : 1027
}

// The kernel loaded: its pages, where it runs, its entry from there, and its segments.
LoadedKernel :: struct {
    physical : u64,
    size : u64,
    virtual_base : u64,
    entry : u64,
    segments : boot_protocol.Segment[boot_protocol.MAX_SEGMENTS],
    segment_count : usize,
}

// size bytes, little-endian, at offset in a file in pages, or 0 past its end.
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

// The kernel in file, loaded and relocated; null if it isn't an ELF kernel for this machine.
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

/*
 * The relative relocations the dynamic segment at dynamic names, applied in the loaded image for its slide; false for
 * one of another kind, or outside the image.
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

// count bytes from one address to another.
copy :: fn(to: u64, from: u64, count: u64) {
    for i in cast[u64](0)..<count {
        cast[ptr[mut u8]](cast[rawptr](to + i))^ = cast[ptr[u8]](cast[rawptr](from + i))^
    }
}
