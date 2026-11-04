/**
 * The ELF loader's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked,
 * or the number of the first check that failed. Its argument is the folder the build put SlopOS's programs
 * in, and it loads hello.elf from there into a buffer, relocates it, then refuses copies of it made wrong.
 */
package elf_loader_test

import runtime from "base"
import os from "std"
import text_buffer from "std"
import elf_loader from ".."
import hosted_faults from "../../robustness/hosted"

/** The address the test relocates hello.elf to run at: a page-aligned user address, never actually run there. */
BASE : u64 : 0x7000_0000_0000

/**
 * Load hello.elf, relocate it, and check the result, then check that broken copies of it are refused.
 *
 * @return 0 if every check passed, or the number of the first that failed: 1 without the folder argument, 2 if
 *     the file can't be read, 3 to 10 for reading, loading and relocating it, and 20 to 28 from refusals.
 */
checks :: fn() -> int {
    arguments :: os.arguments()
    if arguments.count < 2 {
        return 1
    }
    path_storage : u8[1024]
    path := text_buffer.make(path_storage)
    text_buffer.append(&path, arguments[1])
    text_buffer.append(&path, "/hello.elf")
    contents :: os.read_entire_file(text_buffer.as_string(&path)) or_return 2
    file :: string_bytes(contents)
    executable :: elf_loader.read(file) or_return 3
    if executable.segment_count < 2 || executable.relocation_count == 0 || executable.size % elf_loader.PAGE_SIZE != 0 {
        return 4
    }
    // Loaded into a buffer and relocated: each relocated word is BASE and its addend
    image, error :: runtime.new_array(u8, cast[usize](executable.size))
    if error != null {
        return 5
    }
    defer runtime.free_array(image)
    if !done(elf_loader.load(&executable, file, image)) || !done(elf_loader.relocate(&executable, file, image, BASE)) {
        return 6
    }
    first :: elf_loader.read_le(file, executable.relocations, 8) or_return 7
    addend :: elf_loader.read_le(file, executable.relocations + 16, 8) or_return 7
    if elf_loader.read_le(image, first, 8) != BASE + addend {
        return 8
    }
    // A segment's bytes are where it says
    segment :: executable.segments[0]
    loaded :: elf_loader.read_le(image, segment.address, 4) or_return 9
    original :: elf_loader.read_le(file, segment.offset, 4) or_return 9
    if segment.file_size > 4 && loaded != original {
        return 9
    }
    too_small : u8[16]
    match refused(elf_loader.load(&executable, file, too_small)) {
        case Some(error) => {
            if error != .ImageTooSmall {
                return 10
            }
        }
        case None => return 10
    }
    return refusals(file, executable)
}

/**
 * Tell whether loading or relocating succeeded.
 *
 * @param result What load or relocate returned.
 * @return True for Ok, false for any error.
 */
done :: fn(result: Result[void, elf_loader.LoadError]) -> bool {
    return match result {
        case Ok => true
        case _ => false
    }
}

/**
 * Tell whether a file reads as an executable.
 *
 * @param file The bytes to read; only read.
 * @return True if elf_loader.read accepts them, false for any error.
 */
read_works :: fn(file: u8[]) -> bool {
    return match elf_loader.read(file) {
        case Ok => true
        case _ => false
    }
}

/**
 * Give the error a load or relocate result refused with.
 *
 * @param result What load or relocate returned.
 * @return The error; null for a result that wasn't refused at all.
 */
refused :: fn(result: Result[void, elf_loader.LoadError]) -> elf_loader.LoadError? {
    return match result {
        case Error(error) => error
        case Ok => null
    }
}

/**
 * Read a copy of a file with a few bytes changed, giving the error read refuses it with.
 *
 * The copy is made with the heap's allocator and freed before it returns; file isn't changed.
 *
 * @param file The executable's bytes to copy.
 * @param offset Where in the copy the change goes, in bytes; bytes past the copy's end aren't written.
 * @param size How many bytes are changed, 0 to 8.
 * @param value What's written there, little-endian, its low size bytes.
 * @return The error read refuses the copy with, or null if read accepts it or the copy couldn't be allocated.
 */
changed :: fn(file: u8[], offset: u64, size: u64, value: u64) -> elf_loader.LoadError? {
    copy, error :: runtime.new_array(u8, file.count)
    if error != null {
        return null
    }
    defer runtime.free_array(copy)
    for &byte, i in copy {
        if i < file.count {
            byte^ = file[i]
        }
    }
    for i in 0..<size {
        at :: cast[usize](offset + i)
        if at < copy.count {
            copy[at] = cast[u8]((value >> (i * 8)) & 0xff)
        }
    }
    return match elf_loader.read(copy) {
        case Error(error) => error
        case Ok => null
    }
}

/**
 * Check that copies of an executable made wrong are each refused for what's wrong with them.
 *
 * @param file The bytes of hello.elf, which read accepts.
 * @param executable What read gave for file, for where its relocations are and its size.
 * @return 0 if every copy was refused as it should be, or the number of the first check that failed, 20 to 28.
 */
refusals :: fn(file: u8[], executable: elf_loader.Executable) -> int {
    if changed(file, 0, 1, 0) != .NotElf {
        return 20
    }
    // An executable for a fixed address
    if changed(file, 16, 2, 2) != .NotPositionIndependent {
        return 21
    }
    // For the other architecture: ARM64's on x86-64, x86-64's on ARM64
    if changed(file, 18, 2, if elf_loader.MACHINE == 62 { cast[u64](183) } else { cast[u64](62) }) != .Unsupported {
        return 22
    }
    // The first loadable segment readable, writable and executable
    headers :: elf_loader.read_le(file, 32, 8) or_return 23
    count :: elf_loader.read_le(file, 56, 2) or_return 23
    load_header : u64 = 0
    for h in 0..<count {
        at :: headers + h * elf_loader.PROGRAM_HEADER_SIZE
        if elf_loader.read_le(file, at, 4) == elf_loader.PT_LOAD {
            load_header = at
            break
        }
    }
    if changed(file, load_header + 4, 4, elf_loader.PF_R | elf_loader.PF_W | elf_loader.PF_X) != .WritableAndExecutable {
        return 24
    }
    // A loadable segment past the end of the file
    if changed(file, load_header + 8, 8, cast[u64](file.count)) != .SegmentOutsideFile
        && changed(file, load_header + 8, 8, cast[u64](file.count)) != .BadHeaders {
        return 25
    }
    // A relocation of another kind
    if changed(file, executable.relocations + 8, 8, 1) != .UnsupportedRelocation {
        return 26
    }
    // A relocation outside the image
    if changed(file, executable.relocations, 8, executable.size) != .RelocationOutsideImage {
        return 27
    }
    // Cut short
    if file.count >= 32 && read_works(file[0..<32]) {
        return 28
    }
    return 0
}

/**
 * Run the checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return 0 if every check passed, or the number of the first that failed, as checks returns it.
 */
main :: fn() -> int {
    return hosted_faults.run(checks)
}
