/*
 * Loading SlopOS programs (decisions/0004, 0058): position-independent ELF executables for the architecture
 * this is built for, x86-64's or AArch64's, whose only relocations are relative ones (R_X86_64_RELATIVE,
 * R_AARCH64_RELATIVE). The kernel uses it for the root task, and the root task and the
 * process manager for every other program. It allocates nothing:
 *
 *     executable :: elf_loader.read(file)?        // checked: segments, entry, relocations
 *     elf_loader.load(&executable, file, image)?  // the segments copied into image, executable.size zeroed bytes
 *     elf_loader.relocate(&executable, file, image, base)?
 *
 * after which image holds the program as it runs at base, and each segment's pages are mapped with its
 * protection. Anything else is refused: other kinds of file, other machines, an interpreter, shared
 * libraries, thread-local storage, other relocations, and segments that are writable and executable or
 * share a page.
 */
package elf_loader

import intrinsics from "base"
import slop_os from "std/os"

PAGE_SIZE : u64 : 4096
// The most loadable segments an executable may have.
MAX_SEGMENTS :: 8
// The largest image, 1 GiB, as large as one memory object can be.
MAX_IMAGE_SIZE : u64 : 1 << 30

// One loadable segment, from the image's base.
Segment :: struct {
    // Where it starts, and how many bytes it takes there: the first file_size of them from offset in the file, then zeros
    address : u64,
    memory_size : u64,
    offset : u64,
    file_size : u64,
    protection : slop_os.Protection,
}

// What loading an executable needs to know, from its file.
Executable :: struct {
    // Where it starts, from the image's base
    entry : u64,
    // The whole image, a whole number of pages: from its base to the end of its last segment
    size : u64,
    segments : Segment[MAX_SEGMENTS],
    segment_count : usize,
    // Its relocations, as file offset and count: RELA entries, each RELATIVE_RELOCATION into a writable segment
    relocations : u64,
    relocation_count : u64,
    // What's read-only once it's relocated (PT_GNU_RELRO), from the image's base: pages to map without write
    relro_address : u64,
    relro_size : u64,
}

LoadError :: enum {
    // Not an ELF file, or one cut short
    NotElf,
    // ELF, but not 64-bit little-endian for this architecture, or not a version this reads
    Unsupported,
    // Not position-independent (ET_DYN), so it can't go at a random base
    NotPositionIndependent,
    // Headers that don't fit together: sizes, offsets, alignment
    BadHeaders,
    TooManySegments,
    SegmentOutsideFile,
    // Segments out of order, or sharing a page, which can't then have their own protection
    SegmentsOverlap,
    WritableAndExecutable,
    EntryNotExecutable,
    // An interpreter, or shared libraries to load first
    NeedsInterpreter,
    ThreadLocalStorage,
    UnsupportedRelocation,
    RelocationOutsideImage,
    ImageTooLarge,
    // The image given to load or relocate is smaller than the executable's
    ImageTooSmall,
}

// ELF's constants that this reads.
ET_DYN : u64 : 3
// The machine programs are for, and their relative relocation: this architecture's
#if TARGET_ARCH == .arm64 {
    MACHINE : u64 : 183
    RELATIVE_RELOCATION : u64 : 1027
}
#else {
    MACHINE : u64 : 62
    RELATIVE_RELOCATION : u64 : 8
}
PT_LOAD : u64 : 1
PT_DYNAMIC : u64 : 2
PT_INTERP : u64 : 3
PT_TLS : u64 : 7
PT_GNU_STACK : u64 : 0x6474e551
PT_GNU_RELRO : u64 : 0x6474e552
PF_X : u64 : 1
PF_W : u64 : 2
PF_R : u64 : 4
DT_NULL : u64 : 0
DT_NEEDED : u64 : 1
DT_RELA : u64 : 7
DT_RELASZ : u64 : 8
DT_RELAENT : u64 : 9
DT_TEXTREL : u64 : 22
DT_REL : u64 : 17
DT_JMPREL : u64 : 23
HEADER_SIZE : u64 : 64
PROGRAM_HEADER_SIZE : u64 : 56
DYNAMIC_ENTRY_SIZE : u64 : 16
RELA_SIZE : u64 : 24

// The little-endian integer of size bytes at offset in bytes, or null past the end.
read_le :: fn(bytes: u8[], offset: u64, size: u64) -> u64? {
    count :: cast[u64](bytes.count)
    if offset > count || size > count - offset || size > 8 {
        return null
    }
    value : u64 = 0
    for i in 0..<size {
        at :: cast[usize](offset + size - 1 - i)
        if at >= bytes.count {
            return null
        }
        value = (value << 8) | cast[u64](bytes[at])
    }
    return value
}

// value rounded up to a whole number of pages, or null if that overflows.
page_up :: fn(value: u64) -> u64? {
    if value > ~cast[u64](0) - (PAGE_SIZE - 1) {
        return null
    }
    return (value + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
}

// What a program header's flags give, refusing writable and executable.
protection_of :: fn(flags: u64) -> Result[slop_os.Protection, LoadError] {
    if flags & PF_W != 0 && flags & PF_X != 0 {
        return .Error(.WritableAndExecutable)
    }
    bits : u32 = 0
    if flags & PF_R != 0 {
        bits |= cast[u32](slop_os.PROTECTION_READ)
    }
    if flags & PF_W != 0 {
        bits |= cast[u32](slop_os.PROTECTION_WRITE)
    }
    if flags & PF_X != 0 {
        bits |= cast[u32](slop_os.PROTECTION_EXECUTE)
    }
    return .Ok(cast[slop_os.Protection](bits))
}

// The segment of executable that address is in, its first count bytes, or null.
segment_at :: fn(executable: ptr[Executable], address: u64, count: u64) -> Segment? {
    for i in 0..<executable.segment_count {
        if i < executable.segments.count {
            segment :: executable.segments[i]
            if address >= segment.address && count <= segment.memory_size && address - segment.address <= segment.memory_size - count {
                return segment
            }
        }
    }
    return null
}

// Where address, in the image, is in the file, for count bytes the file holds there, or null.
file_offset_of :: fn(executable: ptr[Executable], address: u64, count: u64) -> u64? {
    segment :: segment_at(executable, address, count) or_return null
    within :: address - segment.address
    if count > segment.file_size || within > segment.file_size - count {
        return null
    }
    return segment.offset + within
}

// file's executable, checked, or why it can't be loaded.
read :: fn(file: u8[]) -> Result[Executable, LoadError] {
    // ELF
    if cast[u64](file.count) < HEADER_SIZE || file[0] != 0x7f || file[1] != 0x45 || file[2] != 0x4c || file[3] != 0x46 {
        return .Error(.NotElf)
    }
    // 64-bit, little-endian, ELF version 1
    if file[4] != 2 || file[5] != 1 || file[6] != 1 {
        return .Error(.Unsupported)
    }
    kind :: read_le(file, 16, 2) or_return .Error(.NotElf)
    machine :: read_le(file, 18, 2) or_return .Error(.NotElf)
    if machine != MACHINE {
        return .Error(.Unsupported)
    }
    if kind != ET_DYN {
        return .Error(.NotPositionIndependent)
    }
    executable : Executable
    executable.entry = read_le(file, 24, 8) or_return .Error(.NotElf)
    headers :: read_le(file, 32, 8) or_return .Error(.NotElf)
    header_size :: read_le(file, 54, 2) or_return .Error(.NotElf)
    header_count :: read_le(file, 56, 2) or_return .Error(.NotElf)
    if header_size != PROGRAM_HEADER_SIZE {
        return .Error(.BadHeaders)
    }
    dynamic_address : u64 = 0
    dynamic_size : u64 = 0
    has_dynamic := false
    end : u64 = 0
    segment_count : usize = 0
    for h in 0..<header_count {
        at :: headers + h * PROGRAM_HEADER_SIZE
        kind_of :: read_le(file, at, 4) or_return .Error(.BadHeaders)
        flags :: read_le(file, at + 4, 4) or_return .Error(.BadHeaders)
        offset :: read_le(file, at + 8, 8) or_return .Error(.BadHeaders)
        address :: read_le(file, at + 16, 8) or_return .Error(.BadHeaders)
        file_size :: read_le(file, at + 32, 8) or_return .Error(.BadHeaders)
        memory_size :: read_le(file, at + 40, 8) or_return .Error(.BadHeaders)
        if kind_of == PT_INTERP {
            return .Error(.NeedsInterpreter)
        }
        if kind_of == PT_TLS {
            return .Error(.ThreadLocalStorage)
        }
        if kind_of == PT_GNU_STACK && flags & PF_X != 0 {
            return .Error(.WritableAndExecutable)
        }
        if kind_of == PT_DYNAMIC {
            dynamic_address = address
            dynamic_size = memory_size
            has_dynamic = true
        }
        if kind_of == PT_GNU_RELRO {
            executable.relro_address = address
            executable.relro_size = memory_size
        }
        if kind_of != PT_LOAD {
            continue
        }
        if file_size > memory_size || address % PAGE_SIZE != offset % PAGE_SIZE {
            return .Error(.BadHeaders)
        }
        if offset > cast[u64](file.count) || file_size > cast[u64](file.count) - offset {
            return .Error(.SegmentOutsideFile)
        }
        if memory_size > MAX_IMAGE_SIZE || address > MAX_IMAGE_SIZE - memory_size {
            return .Error(.ImageTooLarge)
        }
        // In order, each starting on a page after the last one's
        if address & ~(PAGE_SIZE - 1) < end {
            return .Error(.SegmentsOverlap)
        }
        if segment_count >= MAX_SEGMENTS {
            return .Error(.TooManySegments)
        }
        protection :: protection_of(flags)?
        executable.segments[segment_count] = Segment.{
            address = address,
            memory_size = memory_size,
            offset = offset,
            file_size = file_size,
            protection = protection,
        }
        segment_count += 1
        executable.segment_count = segment_count
        end = page_up(address + memory_size) or_return .Error(.ImageTooLarge)
    }
    executable.size = end
    if executable.segment_count == 0 {
        return .Error(.BadHeaders)
    }
    entry_segment :: segment_at(&executable, executable.entry, 1) or_return .Error(.EntryNotExecutable)
    if cast[u32](entry_segment.protection) & cast[u32](slop_os.PROTECTION_EXECUTE) == 0 {
        return .Error(.EntryNotExecutable)
    }
    if has_dynamic {
        read_dynamic(&executable, file, dynamic_address, dynamic_size)?
    }
    return .Ok(executable)
}

// The dynamic section's relocations, checked: each RELATIVE_RELOCATION, into a writable segment.
read_dynamic :: fn(executable: ptr[mut Executable], file: u8[], address: u64, size: u64) -> Result[void, LoadError] {
    dynamic :: file_offset_of(executable, address, size) or_return .Error(.BadHeaders)
    relocations : u64 = 0
    relocations_size : u64 = 0
    entry_size := RELA_SIZE
    for i in 0..<size / DYNAMIC_ENTRY_SIZE {
        tag :: read_le(file, dynamic + i * DYNAMIC_ENTRY_SIZE, 8) or_return .Error(.BadHeaders)
        value :: read_le(file, dynamic + i * DYNAMIC_ENTRY_SIZE + 8, 8) or_return .Error(.BadHeaders)
        if tag == DT_NULL {
            break
        }
        if tag == DT_NEEDED {
            return .Error(.NeedsInterpreter)
        }
        if tag == DT_REL || tag == DT_JMPREL || tag == DT_TEXTREL {
            return .Error(.UnsupportedRelocation)
        }
        if tag == DT_RELA {
            relocations = value
        }
        if tag == DT_RELASZ {
            relocations_size = value
        }
        if tag == DT_RELAENT {
            entry_size = value
        }
    }
    if relocations_size == 0 {
        return .Ok
    }
    if entry_size != RELA_SIZE || relocations_size % RELA_SIZE != 0 {
        return .Error(.BadHeaders)
    }
    table :: file_offset_of(executable, relocations, relocations_size) or_return .Error(.BadHeaders)
    executable.relocations = table
    executable.relocation_count = relocations_size / RELA_SIZE
    for i in 0..<executable.relocation_count {
        at :: table + i * RELA_SIZE
        offset :: read_le(file, at, 8) or_return .Error(.BadHeaders)
        info :: read_le(file, at + 8, 8) or_return .Error(.BadHeaders)
        if info != RELATIVE_RELOCATION {
            return .Error(.UnsupportedRelocation)
        }
        target :: segment_at(executable, offset, 8) or_return .Error(.RelocationOutsideImage)
        if cast[u32](target.protection) & cast[u32](slop_os.PROTECTION_WRITE) == 0 {
            return .Error(.RelocationOutsideImage)
        }
    }
    return .Ok
}

// executable's segments copied from file into image, which is zeroed and at least executable.size bytes.
load :: fn(executable: ptr[Executable], file: u8[], image: mut u8[]) -> Result[void, LoadError] {
    if cast[u64](image.count) < executable.size {
        return .Error(.ImageTooSmall)
    }
    for i in 0..<executable.segment_count {
        if i >= executable.segments.count {
            break
        }
        segment :: executable.segments[i]
        count :: segment.file_size
        // read checked these; checked again, so nothing is copied past either end
        if segment.offset > cast[u64](file.count) || count > cast[u64](file.count) - segment.offset
            || segment.address > cast[u64](image.count) || count > cast[u64](image.count) - segment.address {
            return .Error(.SegmentOutsideFile)
        }
        if count > 0 {
            intrinsics.mem_copy_non_overlapping(cast[mut rawptr](cast[u64](image.data) + segment.address),
                cast[rawptr](cast[u64](file.data) + segment.offset), cast[usize](count))
        }
    }
    return .Ok
}

// executable's relocations applied to image, loaded from file, for it to run at base.
relocate :: fn(executable: ptr[Executable], file: u8[], image: mut u8[], base: u64) -> Result[void, LoadError] {
    if cast[u64](image.count) < executable.size {
        return .Error(.ImageTooSmall)
    }
    for i in 0..<executable.relocation_count {
        at :: executable.relocations + i * RELA_SIZE
        offset :: read_le(file, at, 8) or_return .Error(.BadHeaders)
        addend :: read_le(file, at + 16, 8) or_return .Error(.BadHeaders)
        if offset > cast[u64](image.count) || cast[u64](image.count) - offset < 8 {
            return .Error(.RelocationOutsideImage)
        }
        cast[ptr[mut u64]](cast[u64](image.data) + offset)^ = base + addend
    }
    return .Ok
}
