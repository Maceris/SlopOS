/**
 * The ELF loader's tests, as a hosted program (tools/unit_tests.py, decisions/0175): main runs them and returns how
 * many failed. Its argument is the folder the build put SlopOS's programs in, and the tests load hello.elf from there
 * into a buffer, relocate it, then refuse copies of it made wrong.
 */
package elf_loader_test

import compiler from "base"
import runtime from "base"
import os from "std"
import strings from "std"
import testing from "std"
import text_buffer from "std"
import elf_loader from ".."
import hosted_faults from "../../robustness/hosted"

/** The address the test relocates hello.elf to run at: a page-aligned user address, never actually run there. */
BASE : u64 : 0x7000_0000_0000

/** hello.elf, as hello reads it. */
Hello :: struct {
    /** The file's bytes, from the context's allocator, which free_hello gives back. */
    contents : string,
    /** What elf_loader.read made of them. */
    executable : elf_loader.Executable,
}

/**
 * Read hello.elf from the programs folder, the program's first argument, and read it as an executable.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The file and what read made of it, which the caller frees with free_hello; Error if there's no folder
 *     argument, the file can't be read, or read refuses it, the failure recorded.
 */
hello :: fn(t: ptr[mut testing.T]) -> Result[Hello, testing.Stopped] {
    arguments :: os.arguments()
    if arguments.count < 2 {
        testing.fail(t, "the first argument is the folder the build put SlopOS's programs in")
        return .Error(.Failed)
    }
    path_storage : u8[1024]
    path := text_buffer.make(path_storage)
    text_buffer.append(&path, arguments[1])
    text_buffer.append(&path, "/hello.elf")
    read_file :: os.read_entire_file(text_buffer.as_string(&path))
    contents :: testing.require_ok(t, read_file, "the build puts hello.elf in the programs folder")?
    read :: elf_loader.read(string_bytes(contents))
    match read {
        case Ok(executable) => return .Ok(Hello.{contents = contents, executable = executable})
        case Error => {
            _ = testing.expect_ok(t, read, "hello.elf, as the build makes it, reads as an executable")
            strings.free_string(contents)
            return .Error(.Failed)
        }
    }
}

/**
 * Give back what hello read.
 *
 * @param made What hello gave, whose contents aren't used after.
 */
free_hello :: fn(made: Hello) {
    strings.free_string(made.contents)
}

hello_reads_as_a_relocatable_executable #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: hello(t)?
    defer free_hello(made)
    executable :: made.executable
    testing.expect(t, executable.segment_count >= 2, "code and data are segments of their own")
    testing.expect(t, executable.relocation_count > 0, "a position-independent program has relocations")
    testing.expect_eq(t, executable.size % elf_loader.PAGE_SIZE, 0, "the image is a whole number of pages")
    return .Ok
}

hello_loads_and_relocates_into_a_buffer #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: hello(t)?
    defer free_hello(made)
    executable := made.executable
    file :: string_bytes(made.contents)
    image, error :: runtime.new_array(u8, cast[usize](executable.size))
    testing.require(t, error == null, "the image's buffer is allocated")?
    defer runtime.free_array(image)
    loaded_result :: elf_loader.load(&executable, file, image)
    testing.outcome_of(testing.expect_ok(t, loaded_result, "an image of the executable's size takes it"))?
    relocated :: elf_loader.relocate(&executable, file, image, BASE)
    testing.outcome_of(testing.expect_ok(t, relocated, "its relocations are all into its image"))?
    // Each relocated word is BASE and its addend
    first :: testing.require_some(t, elf_loader.read_le(file, executable.relocations, 8), "the first relocation's offset is in the file")?
    addend :: testing.require_some(t, elf_loader.read_le(file, executable.relocations + 16, 8), "and its addend")?
    word :: testing.require_some(t, elf_loader.read_le(image, first, 8), "the relocated word is in the image")?
    testing.expect_eq(t, word, BASE + addend, "a relative relocation's word is the base and its addend")
    // A segment's bytes are where it says
    segment :: executable.segments[0]
    loaded :: testing.require_some(t, elf_loader.read_le(image, segment.address, 4), "the first segment's address is in the image")?
    original :: testing.require_some(t, elf_loader.read_le(file, segment.offset, 4), "its offset is in the file")?
    if segment.file_size > 4 {
        testing.expect_eq(t, loaded, original, "a segment's bytes are copied from its offset in the file to its address")
    }
    return .Ok
}

an_image_too_small_is_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: hello(t)?
    defer free_hello(made)
    executable := made.executable
    too_small : u8[16]
    loaded :: elf_loader.load(&executable, string_bytes(made.contents), too_small)
    testing.expect_error(t, loaded, .ImageTooSmall, "16 bytes are less than hello's pages")
    return .Ok
}

copies_made_wrong_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: hello(t)?
    defer free_hello(made)
    file :: string_bytes(made.contents)
    executable :: made.executable
    expect_refused(t, file, 0, 1, 0, .NotElf, .NotElf, "without its magic, it isn't ELF")
    expect_refused(t, file, 16, 2, 2, .NotPositionIndependent, .NotPositionIndependent,
        "ET_EXEC is for a fixed address, and programs are loaded anywhere")
    // For the other architecture: ARM64's on x86-64, x86-64's on ARM64
    other :: if elf_loader.MACHINE == 62 { cast[u64](183) } else { cast[u64](62) }
    expect_refused(t, file, 18, 2, other, .Unsupported, .Unsupported, "an executable for the other architecture")
    // The first loadable segment readable, writable and executable
    headers :: testing.require_some(t, elf_loader.read_le(file, 32, 8), "the program headers' offset is in the file")?
    count :: testing.require_some(t, elf_loader.read_le(file, 56, 2), "and their count")?
    load_header : u64 = 0
    for h in 0..<count {
        at :: headers + h * elf_loader.PROGRAM_HEADER_SIZE
        if elf_loader.read_le(file, at, 4) == elf_loader.PT_LOAD {
            load_header = at
            break
        }
    }
    expect_refused(t, file, load_header + 4, 4, elf_loader.PF_R | elf_loader.PF_W | elf_loader.PF_X, .WritableAndExecutable,
        .WritableAndExecutable, "a segment both writable and executable is refused (W^X)")
    expect_refused(t, file, load_header + 8, 8, cast[u64](file.count), .SegmentOutsideFile, .BadHeaders,
        "a loadable segment past the end of the file")
    expect_refused(t, file, executable.relocations + 8, 8, 1, .UnsupportedRelocation, .UnsupportedRelocation,
        "only R_X86_64_RELATIVE's kind of relocation is applied")
    expect_refused(t, file, executable.relocations, 8, executable.size, .RelocationOutsideImage, .RelocationOutsideImage,
        "a relocation at the image's end is outside it")
    if file.count >= 32 {
        cut :: elf_loader.read(file[0..<32])
        testing.expect(t, cut is_error, "32 bytes are only part of an ELF header")
    }
    return .Ok
}

/**
 * Check that read refuses a copy of a file with a few bytes changed, for what's wrong with it.
 *
 * The copy is made with the context's allocator and freed before it returns; file isn't changed.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param file The executable's bytes to copy.
 * @param offset Where in the copy the change goes, in bytes; bytes past the copy's end aren't written.
 * @param size How many bytes are changed, 0 to 8.
 * @param value What's written there, little-endian, its low size bytes.
 * @param wanted The error read should refuse the copy with.
 * @param or_wanted Another error that will do as well; wanted again when only one will.
 * @param message Why it should be refused, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_refused :: fn(t: ptr[mut testing.T], file: u8[], offset: u64, size: u64, value: u64, wanted: elf_loader.LoadError,
        or_wanted: elf_loader.LoadError, message: string, location := #caller_location) {
    copy, error :: runtime.new_array(u8, file.count)
    if error != null {
        testing.record(t, message, "the copy couldn't be allocated", location)
        return void
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
    read :: elf_loader.read(copy)
    match read {
        case Error(found) => {
            if found == or_wanted {
                return void
            }
        }
        case Ok => {}
    }
    _ = testing.expect_error(t, read, wanted, message, location)
}

/**
 * Run the tests, reporting to standard output.
 *
 * @return How many failed: 0 when every one passed.
 */
run_tests :: fn() -> int {
    return cast[int](testing.run(#insert testing.tests_of(compiler.load_package(".")), testing.STANDARD_OUTPUT))
}

/**
 * Run the tests, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn() -> int {
    return hosted_faults.run(run_tests)
}
