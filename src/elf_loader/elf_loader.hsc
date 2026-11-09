/**
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

/** The page size segments are laid out in and protected by, in bytes: 4 KiB, on both architectures. */
PAGE_SIZE : u64 : 4096
/** The most loadable (PT_LOAD) segments an executable may have; read refuses one more with TooManySegments. */
MAX_SEGMENTS :: 8
/**
 * The largest image, in bytes: 1 GiB, as large as one memory object can be. No segment may end past it, from the
 * image's base.
 */
MAX_IMAGE_SIZE : u64 : 1 << 30

/** One loadable segment, its addresses from the image's base (the address it's linked at, 0 for the image's start). */
Segment :: struct {
    /** Where the segment starts, in bytes from the image's base; not necessarily page-aligned. */
    address : u64,
    /** How many bytes it takes in the image from address: its file_size bytes from the file, then zeros. */
    memory_size : u64,
    /** Where its bytes start in the file, in bytes; the same as address within a page (both the same modulo 4096). */
    offset : u64,
    /** How many of its bytes come from the file, at most memory_size; the rest of the segment is zeros. */
    file_size : u64,
    /** The protection its pages are mapped with: never both writable and executable. */
    protection : slop_os.Protection,
}

/** What loading an executable needs to know, read from its file and checked by read. */
Executable :: struct {
    /** Where the program starts, in bytes from the image's base; always in an executable segment. */
    entry : u64,
    /** The whole image's size in bytes, a whole number of pages: from its base to its last segment's page's end. */
    size : u64,
    /** Its loadable segments, in order of address, each on pages of its own; only the first segment_count are used. */
    segments : Segment[MAX_SEGMENTS],
    /** How many of segments are used: 1 to MAX_SEGMENTS. */
    segment_count : usize,
    /**
     * Where its relocations start in the file, in bytes: RELA entries, each a RELATIVE_RELOCATION of 8 bytes into a
     * writable segment. 0 when it has none.
     */
    relocations : u64,
    /** How many RELA entries there are at relocations, each RELA_SIZE bytes; 0 when it has none. */
    relocation_count : u64,
    /**
     * Where what's read-only once it's relocated (PT_GNU_RELRO) starts, in bytes from the image's base, for its pages
     * to be mapped without write; 0, with relro_size 0, when there's none. Read as the file gives it, not checked.
     */
    relro_address : u64,
    /** How many bytes from relro_address are read-only once relocated; 0 when there's none. */
    relro_size : u64,
    /**
     * What hardware control-flow integrity the code was built for, as its property note's features say
     * (decisions/0186): FEATURE_LANDING_PADS, FEATURE_SIGNED_RETURNS and FEATURE_SHADOW_STACK, for this architecture;
     * 0 without a note. With landing pads, its executable segments are guarded (PROTECTION_GUARDED).
     */
    control_flow : u64,
}

/** Why an executable can't be loaded. */
LoadError :: enum {
    /** Not an ELF file, or one cut short. */
    NotElf,
    /** ELF, but not 64-bit little-endian for this architecture's machine, or not ELF version 1. */
    Unsupported,
    /** Not position-independent (ET_DYN), so it can't go at a random base. */
    NotPositionIndependent,
    /**
     * Headers that don't fit together: a program header's size, offsets and addresses that differ within a page, a
     * segment with more bytes in the file than in memory, a dynamic section or relocation table outside the file's
     * segments, or no loadable segment at all.
     */
    BadHeaders,
    /** More than MAX_SEGMENTS loadable segments. */
    TooManySegments,
    /** A loadable segment whose bytes run past the file's end. */
    SegmentOutsideFile,
    /** Segments out of order, or sharing a page, which can't then have their own protection. */
    SegmentsOverlap,
    /** A segment, or the stack (PT_GNU_STACK), both writable and executable, or a stack asked to be executable. */
    WritableAndExecutable,
    /** The entry isn't in a segment, or is in one that isn't executable. */
    EntryNotExecutable,
    /** An interpreter (PT_INTERP), or shared libraries to load first (DT_NEEDED). */
    NeedsInterpreter,
    /** Thread-local storage (PT_TLS), which the loader doesn't set up. */
    ThreadLocalStorage,
    /** A relocation other than this architecture's relative one, or REL, PLT or text relocations. */
    UnsupportedRelocation,
    /** A relocation whose 8 bytes aren't all in one writable segment, or past the image given. */
    RelocationOutsideImage,
    /** A segment that ends past MAX_IMAGE_SIZE, or whose end overflows when rounded up to a page. */
    ImageTooLarge,
    /** The image given to load or relocate is smaller than the executable's size. */
    ImageTooSmall,
}

/** ELF's object file type for a shared object (e_type), which a position-independent executable is. */
ET_DYN : u64 : 3
/* The machine programs are for, and their relative relocation: this architecture's. */
#if TARGET_ARCH == .arm64 {
    /** The ELF machine (e_machine) programs are for: EM_AARCH64. */
    MACHINE : u64 : 183
    /** The property note's control-flow features (GNU_PROPERTY_AARCH64_FEATURE_1_AND). */
    FEATURES_PROPERTY : u64 : 0xc0000000
    /** Its bits: BTI (landing pads), PAC (signed returns) and GCS (a shadow stack). */
    FEATURE_LANDING_PADS : u64 : 1
    FEATURE_SIGNED_RETURNS : u64 : 2
    FEATURE_SHADOW_STACK : u64 : 4
    /** The only relocation type read (r_info, with symbol 0): R_AARCH64_RELATIVE, base plus addend. */
    RELATIVE_RELOCATION : u64 : 1027
}
#else {
    /** The ELF machine (e_machine) programs are for: EM_X86_64. */
    MACHINE : u64 : 62
    /** The property note's control-flow features (GNU_PROPERTY_X86_FEATURE_1_AND). */
    FEATURES_PROPERTY : u64 : 0xc0000002
    /** Its bits: IBT (landing pads) and SHSTK (a shadow stack); x86-64 has no signed returns. */
    FEATURE_LANDING_PADS : u64 : 1
    FEATURE_SHADOW_STACK : u64 : 2
    FEATURE_SIGNED_RETURNS : u64 : 0
    /** The only relocation type read (r_info, with symbol 0): R_X86_64_RELATIVE, base plus addend. */
    RELATIVE_RELOCATION : u64 : 8
}
/** Program header type: a loadable segment. */
PT_LOAD : u64 : 1
/** Program header type: the dynamic section, where the relocations are found. */
PT_DYNAMIC : u64 : 2
/** Program header type: an interpreter's path, which is refused. */
PT_INTERP : u64 : 3
/** Program header type: thread-local storage's template, which is refused. */
PT_TLS : u64 : 7
/** Program header type (GNU): the stack's protection, refused if it asks for executable. */
PT_GNU_STACK : u64 : 0x6474e551
/** Program header type (GNU): what's made read-only once it's relocated. */
PT_GNU_RELRO : u64 : 0x6474e552
/** Program header type (GNU): the property note, which says what control-flow integrity the code was built for. */
PT_GNU_PROPERTY : u64 : 0x6474e553
/** The property note's type, NT_GNU_PROPERTY_TYPE_0, under the name "GNU". */
NOTE_GNU_PROPERTY : u64 : 5
/** Program header flag: executable. */
PF_X : u64 : 1
/** Program header flag: writable. */
PF_W : u64 : 2
/** Program header flag: readable. */
PF_R : u64 : 4
/** Dynamic tag: the dynamic section's end. */
DT_NULL : u64 : 0
/** Dynamic tag: a shared library needed, which is refused. */
DT_NEEDED : u64 : 1
/** Dynamic tag: the RELA relocation table's address. */
DT_RELA : u64 : 7
/** Dynamic tag: the RELA relocation table's size, in bytes. */
DT_RELASZ : u64 : 8
/** Dynamic tag: one RELA entry's size, in bytes, which has to be RELA_SIZE. */
DT_RELAENT : u64 : 9
/** Dynamic tag: relocations of read-only text, which are refused. */
DT_TEXTREL : u64 : 22
/** Dynamic tag: a REL relocation table (no addends), which is refused. */
DT_REL : u64 : 17
/** Dynamic tag: the PLT's relocations, which are refused. */
DT_JMPREL : u64 : 23
/** The ELF64 file header's size, in bytes. */
HEADER_SIZE : u64 : 64
/** An ELF64 program header's size, in bytes. */
PROGRAM_HEADER_SIZE : u64 : 56
/** An ELF64 dynamic entry's size, in bytes: its tag, then its value, each 8 bytes. */
DYNAMIC_ENTRY_SIZE : u64 : 16
/** An ELF64 RELA entry's size, in bytes: its offset, its info, then its addend, each 8 bytes. */
RELA_SIZE : u64 : 24

/**
 * Read a little-endian unsigned integer from bytes.
 *
 * @param bytes The bytes to read from; only read.
 * @param offset Where the integer starts, in bytes from bytes' start.
 * @param size How many bytes the integer takes, 0 to 8; 0 reads 0.
 * @return The integer, or null if size is more than 8 or any of its bytes is past bytes' end.
 */
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

/**
 * Round a size or address up to a whole number of pages.
 *
 * @param value The bytes to round up; any value.
 * @return value rounded up to a multiple of PAGE_SIZE, value itself if it's one already, or null if that would
 *     overflow 64 bits.
 */
page_up :: fn(value: u64) -> u64? {
    if value > ~cast[u64](0) - (PAGE_SIZE - 1) {
        return null
    }
    return (value + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
}

/**
 * Read a property note's control-flow features (decisions/0186): an ELF note of type NOTE_GNU_PROPERTY named "GNU",
 * whose properties, each a type, a size and its data padded to 8 bytes, include FEATURES_PROPERTY's 4 bytes.
 *
 * @param file The whole file.
 * @param offset Where the note starts in the file, in bytes.
 * @param size Its size in bytes.
 * @return FEATURES_PROPERTY's bits; 0 for a note that isn't one, or is cut short, or doesn't have it.
 */
control_flow_of :: fn(file: u8[], offset: u64, size: u64) -> u64 {
    if size < 16 || offset > cast[u64](file.count) || size > cast[u64](file.count) - offset {
        return 0
    }
    name_size :: read_le(file, offset, 4) or_return 0
    description_size :: read_le(file, offset + 4, 4) or_return 0
    kind :: read_le(file, offset + 8, 4) or_return 0
    name :: read_le(file, offset + 12, 4) or_return 0
    // "GNU" and its terminator, little-endian
    if name_size != 4 || kind != NOTE_GNU_PROPERTY || name != 0x00554e47 || description_size > size - 16 {
        return 0
    }
    at := offset + 16
    end :: offset + 16 + description_size
    loop {
        if at + 8 > end {
            return 0
        }
        property :: read_le(file, at, 4) or_return 0
        data_size :: read_le(file, at + 4, 4) or_return 0
        if property == FEATURES_PROPERTY && data_size == 4 {
            return read_le(file, at + 8, 4) or_return 0
        }
        // The next, after this one's data padded to 8 bytes
        at += 8 + ((data_size + 7) & ~cast[u64](7))
    }
}

/**
 * Turn a program header's flags into the protection its pages are mapped with.
 *
 * @param flags The program header's p_flags: PF_R, PF_W and PF_X; other bits are ignored.
 * @return The protection with read, write and execute as the flags give them; no flags give no access.
 * @error WritableAndExecutable The flags have both PF_W and PF_X, which no segment may have.
 */
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

/**
 * Find the segment that holds a range of the image.
 *
 * @param executable The executable whose segments are searched, its first segment_count of them; not changed.
 * @param address Where the range starts, in bytes from the image's base.
 * @param count How many bytes the range takes; they all have to be within one segment's memory_size, zeros
 *     included. 0 finds the segment address is in, or ends at.
 * @return A copy of the first segment holding all count bytes from address, or null if none does.
 */
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

/**
 * Find where a range of the image comes from in the file.
 *
 * @param executable The executable whose segments map the image to the file; not changed.
 * @param address Where the range starts, in bytes from the image's base.
 * @param count How many bytes the range takes; all of them have to be in one segment's bytes from the file, not
 *     its zeros past file_size.
 * @return The range's offset in the file, in bytes, or null if no one segment's file bytes hold all of it.
 */
file_offset_of :: fn(executable: ptr[Executable], address: u64, count: u64) -> u64? {
    segment :: segment_at(executable, address, count) or_return null
    within :: address - segment.address
    if count > segment.file_size || within > segment.file_size - count {
        return null
    }
    return segment.offset + within
}

/**
 * Read an executable's headers from its file, and check that it can be loaded.
 *
 * Nothing is allocated or copied: the executable says where in the file its parts are, so the same file is passed
 * to load and relocate after.
 *
 * @param file The whole ELF file; only read, and not kept.
 * @return The executable: its entry, size, loadable segments, relocations and RELRO range, all checked but the
 *     RELRO range.
 * @error NotElf The file isn't ELF, or its header is cut short.
 * @error Unsupported It isn't 64-bit little-endian ELF version 1 for this architecture's machine.
 * @error NotPositionIndependent It isn't ET_DYN.
 * @error BadHeaders Its program headers aren't 56 bytes or run past the file, a segment has more file bytes than
 *     memory bytes or an offset and address that differ within a page, it has no loadable segment, or its dynamic
 *     section or relocations don't fit (read_dynamic).
 * @error SegmentOutsideFile A loadable segment's file bytes run past the file's end.
 * @error ImageTooLarge A segment ends past MAX_IMAGE_SIZE.
 * @error SegmentsOverlap A segment starts before the page after the last one's end.
 * @error TooManySegments It has more than MAX_SEGMENTS loadable segments.
 * @error WritableAndExecutable A segment is both writable and executable, or the stack is asked to be executable.
 * @error EntryNotExecutable The entry isn't in an executable segment.
 * @error NeedsInterpreter It has an interpreter or needs shared libraries.
 * @error ThreadLocalStorage It has thread-local storage.
 * @error UnsupportedRelocation It has relocations other than relative RELA ones.
 * @error RelocationOutsideImage A relocation isn't into a writable segment.
 */
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
        if kind_of == PT_GNU_PROPERTY {
            executable.control_flow = control_flow_of(file, offset, file_size)
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
    // With landing pads, its code where indirect branches may land only on them (decisions/0186)
    if executable.control_flow & FEATURE_LANDING_PADS != 0 {
        for i in 0..<segment_count {
            if i < executable.segments.count && cast[u32](executable.segments[i].protection) & cast[u32](slop_os.PROTECTION_EXECUTE) != 0 {
                executable.segments[i].protection = cast[slop_os.Protection](cast[u32](executable.segments[i].protection)
                    | cast[u32](slop_os.PROTECTION_GUARDED))
            }
        }
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

/**
 * Read the dynamic section, recording its relocations in the executable and checking each is one load can apply.
 *
 * Entries are read up to DT_NULL or the section's end. DT_RELAENT, when given, has to be RELA_SIZE.
 *
 * @param executable The executable, its segments already read; its relocations and relocation_count are set when it
 *     has relocations, and left 0 when it has none.
 * @param file The whole ELF file; only read.
 * @param address Where the dynamic section starts, in bytes from the image's base (PT_DYNAMIC's address).
 * @param size The dynamic section's size in bytes; whole DYNAMIC_ENTRY_SIZE entries in it are read.
 * @error BadHeaders The section or the relocation table isn't within one segment's file bytes, an entry can't be
 *     read, DT_RELAENT isn't RELA_SIZE, or DT_RELASZ isn't a multiple of it.
 * @error NeedsInterpreter It needs a shared library (DT_NEEDED).
 * @error UnsupportedRelocation It has REL, PLT or text relocations, or a RELA entry of another type.
 * @error RelocationOutsideImage A relocation's 8 bytes aren't all in one writable segment.
 */
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

/**
 * Copy an executable's segments from its file into an image.
 *
 * Only the segments' file bytes are copied; the bytes between and after them, a segment's zeros included, are left
 * as they are, so image has to be zeroed before.
 *
 * @param executable The executable, from read of the same file; not changed.
 * @param file The whole ELF file read gave executable for; only read.
 * @param image Where the image goes, at least executable.size bytes, all zero; its byte 0 is the image's base.
 * @error ImageTooSmall image is smaller than executable.size; nothing is copied.
 * @error SegmentOutsideFile A segment's bytes run past the file's or the image's end, which read rules out for the
 *     file it read; segments before it are already copied.
 */
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

/**
 * Apply an executable's relocations to its loaded image, for it to run at base.
 *
 * Each relocated word is written as base plus its addend, so relocating twice, at the same base or another, gives
 * what relocating once at the last base does.
 *
 * @param executable The executable, from read of the same file; not changed.
 * @param file The whole ELF file read gave executable for, where the relocations are read from.
 * @param image The image load copied the segments into, at least executable.size bytes.
 * @param base The virtual address the image's byte 0 will be at in the program's address space; any value, though
 *     a page-aligned one keeps the segments' pages apart.
 * @error ImageTooSmall image is smaller than executable.size; nothing is changed.
 * @error BadHeaders A relocation can't be read from file, which read rules out for the file it read.
 * @error RelocationOutsideImage A relocation's 8 bytes run past image's end; those before it are already applied.
 */
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
