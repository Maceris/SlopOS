/**
 * libc (decisions/0201, 20l): a small C library for porting C tools to SlopOS, over the program's own capabilities.
 * Its functions are Hemera's where they can be, each exported to C by name (#export #calling_convention(.c)), with a
 * context where it allocates or needs the runtime and #no_context where it's pure; what can't be, the printf family's
 * variadic formatting, stdio's streams over the file descriptors, setjmp and longjmp, and what keeps state of C's own,
 * is C, in c/, built into libc_c's library by tools/c_libraries.py; its headers are include/.
 *
 * A program of C has a Hemera main that calls run with what it was given, its C's main declared #foreign from its own
 * C library: run builds argv from its arguments, keeps the libc's state as a context extension, which every export
 * called back from C finds, and calls main through the C start-up (c/start.c), which flushes every stream once main
 * returns or exit's called. Files are beneath the program's working directory: its "here", or its working_directory
 * grant; there's no global filesystem. stdin reads its terminal; stdout and stderr write to it, or without one to its
 * debug log or, without that, its logger, a line at a time. There's no fork, exec, pipe or signal, and no sockets yet.
 */
package libc

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import terminal as protocol from "std:os/slop_os/terminal"
import terminal from "std:terminal"
import time as std_time from "std:time"

/** The libc's C, libc_c's library, which tools/c_libraries.py builds from c/ beside this. */
LIBC_C :: #library("libc_c")

/**
 * Run C's main and give back what it returns, as c/start.c does: stdio set up, main called, then what atexit
 * registered run and every stream flushed.
 *
 * @param argc How many arguments argv has, the program's name first: at least 1.
 * @param argv The arguments, argc of them then a NULL, each a C string; they stay the program's until it ends.
 * @param entry C's main.
 * @return What main returned, or 0 if C's exit wasn't called and main returned nothing else.
 */
c_start #foreign(LIBC_C) #link_name("__libc_start") : fn(argc : i32, argv : ptr[mut cstring?], entry : CMain) -> i32 : ---

/**
 * Set C's errno (c/errno.c), for the exports that fail as C's functions say.
 *
 * @param number The error, one of the E constants.
 */
c_set_errno #foreign(LIBC_C) #link_name("__libc_set_errno") : fn(number : i32) : ---

/** C's main: given argc and argv, it answers the program's exit code. */
CMain :: alias fn(argc : i32, argv : ptr[mut cstring?]) -> i32 #calling_convention(.c) #no_context

/** What the program was given that C reaches: run's argument. */
Start :: struct {
    /** The program's name, argv[0], which starts each line it writes to a debug log. */
    name : string,
    /** Its arguments after its name, argv[1] on; each copied for C, so they needn't outlast run. */
    arguments : string[],
    /** The directory paths are beneath, its "here"; None for its working_directory grant, if it has one. */
    here : os.Channel[dir.Dir]?,
    /** The terminal stdin reads and stdout and stderr write; None to write to the log instead, with stdin empty. */
    console : os.Channel[protocol.Terminal]?,
    /** The debug log stdout and stderr write a line at a time to without a console; None for the program's logger. */
    log : slop_os.DebugLog?,
}

/** Where stdout and stderr go. */
OutputKind :: enum {
    /** The terminal, as it's written. */
    Console,
    /** The debug log, a line at a time, after the program's name. */
    Log,
    /** The program's logger, a line at a time, at info. */
    Logger,
}

/** What a file descriptor is. */
DescriptorKind :: enum {
    /** Closed: free for the next open. */
    Closed,
    /** stdin. */
    Input,
    /** stdout or stderr. */
    Output,
    /** A file beneath the working directory. */
    File,
}

/** A file descriptor: its index in State's descriptors is its number. */
Descriptor :: struct {
    /** What it is. */
    kind : DescriptorKind,
    /** The open file, for a File; owned, closed by close. */
    file : os.File,
    /** Whether it was opened to read. */
    readable : bool,
    /** Whether it was opened to write. */
    writable : bool,
    /** O_APPEND: every write goes to the file's end, wherever it's at. */
    append : bool,
}

/** An open directory's listing, from opendir: its names, read a name at a time. */
Listing :: struct {
    /** Whether it's in use; one that isn't is free for the next opendir. */
    open : bool,
    /** The names, as std's listing gave them; owned, freed by closedir. */
    entries : os.DirectoryEntry[..],
    /** The next one readdir gives. */
    next : usize,
}

/** The libc's state, which run keeps on the heap and pushes as a context extension. */
State :: struct {
    /** The program's name, argv[0]: a heap copy, the State's. */
    name : string,
    /** The directory paths are beneath; valid when has_working. */
    working : os.Directory,
    /** Whether there's a working directory: without one, a path's ENOENT. */
    has_working : bool,
    /** Where stdout and stderr go. */
    output : OutputKind,
    /** The terminal, when output is Console. */
    console : terminal.Terminal,
    /** What reads stdin's lines from the console. */
    editor : terminal.LineEditor,
    /** The debug log, when output is Log. */
    log : slop_os.DebugLog,
    /** stdout's line so far, for Log and Logger, written once it ends. */
    output_line : u8[..],
    /** stderr's line so far, as output_line. */
    error_line : u8[..],
    /** stdin's line so far read, its line break added, from input_at on still to be read. */
    input : u8[..],
    /** How much of input's been read. */
    input_at : usize,
    /** Whether stdin's ended: no console, or it hung up, or the program was asked to stop. */
    input_ended : bool,
    /** The file descriptors, each its index; 0 to 2 are stdin, stdout and stderr. */
    descriptors : Descriptor[..],
    /** The open directories' listings; a DIR is its index plus 1. */
    listings : Listing[..],
    /** When run started, for clock. */
    started : runtime.MonotonicTime,
}

/*
 * The errors, with Linux's numbers as include/errno.h has them, which exports set errno to.
 */
/** Nothing at the path. */
E_NOENT : i32 : 2
/** The device or server failed. */
E_IO : i32 : 5
/** Not an open file descriptor, or not one open for that. */
E_BADF : i32 : 9
/** Out of memory. */
E_NOMEM : i32 : 12
/** Access denied, or a revoked grant. */
E_ACCES : i32 : 13
/** Something's at the path already. */
E_EXIST : i32 : 17
/** A part of the path isn't a directory. */
E_NOTDIR : i32 : 20
/** A directory, where a file was wanted. */
E_ISDIR : i32 : 21
/** An argument isn't valid. */
E_INVAL : i32 : 22
/** No file descriptor left. */
E_MFILE : i32 : 24
/** Not a terminal. */
E_NOTTY : i32 : 25
/** Can't seek on it. */
E_SPIPE : i32 : 29
/** A result out of range. */
E_RANGE : i32 : 34
/** A path or name too long. */
E_NAMETOOLONG : i32 : 36
/** Not on SlopOS. */
E_NOSYS : i32 : 38
/** A directory with something in it. */
E_NOTEMPTY : i32 : 39

/**
 * Run a program's C: argv made from start, the libc's state made and pushed, and main called through C's start-up;
 * once it's returned, or when C calls exit, what stdout and stderr have of a line is written.
 *
 * @param start What the program was given; its strings are copied, and its channels kept for as long as run runs.
 * @param entry C's main, declared #foreign from the program's own C library.
 * @return main's return, the program's exit code, reduced to its low 8 bits as POSIX does (0 to 255: -1 is 255); 2 if
 *     there wasn't the memory to start it.
 */
run :: fn(start : Start, entry : CMain) -> int {
    state :: runtime.new(State)
    defer runtime.free(state)
    state.name = clone_text(start.name) or_return 2
    state.started = std_time.monotonic()
    match start.here {
        case Some(here) => {
            directory, error :: os.directory_on(here.end)
            state.working = directory
            state.has_working = error == null
        }
        case None => match os.working_directory() {
            case Ok(directory) => {
                state.working = directory
                state.has_working = true
            }
            case Error(error) => {}
        }
    }
    state.output = .Logger
    match start.log {
        case Some(log) => {
            state.log = log
            state.output = .Log
        }
        case None => {}
    }
    state.input_ended = true
    match start.console {
        case Some(connection) => match terminal.open(connection) {
            case Some(opened) => {
                state.console = opened
                state.output = .Console
                state.input_ended = false
            }
            case None => {}
        }
        case None => {}
    }
    for kind in DescriptorKind.[.Input, .Output, .Output] {
        runtime.array_add(&state.descriptors, Descriptor.{kind = kind, readable = kind == .Input, writable = kind != .Input})
    }
    // argv: the name, the arguments, then NULL, each a 0-terminated copy on the heap, C's for the rest of the program
    argv, failed :: runtime.new_array(cstring?, start.arguments.count + 2)
    if failed != null || argv.count < 2 {
        return 2
    }
    argv[0] = c_copy(start.name) or_return 2
    for argument, i in start.arguments {
        place :: i + 1
        if place < argv.count {
            argv[place] = c_copy(argument) or_return 2
        }
    }
    node := runtime.extension_node(state)
    code := 0
    push_context with_libc (extensions = &node) {
        code = cast[int](c_start(cast[i32](argv.count - 1), &argv[0], entry))
        flush_lines(state)
    }
    close_all(state)
    return code & 0xff
}

/**
 * Find the libc's state, which run pushed, from an export called back from C.
 *
 * @return The state; null outside run, where an export does nothing, as with nothing open.
 */
state_of :: fn() -> ptr[mut State]? {
    found :: runtime.get_extension(State) or_return null
    return cast[ptr[mut State]](found)
}

/**
 * Set C's errno.
 *
 * @param number The error, an E constant.
 */
set_errno :: fn(number : i32) {
    c_set_errno(number)
}

/**
 * Copy text to the heap.
 *
 * @param text The text, only read.
 * @return The copy, the caller's, given back with free_text; null without the memory. "" owns nothing.
 */
clone_text :: fn(text : string) -> string? {
    if text.count == 0 {
        return ""
    }
    bytes, error :: runtime.new_array(u8, text.count)
    if error != null {
        return null
    }
    source :: string_bytes(text)
    for i in 0..<bytes.count {
        if i < source.count {
            bytes[i] = source[i]
        }
    }
    return bit_cast[string](bytes)
}

/**
 * Copy text to the heap as a C string, with a 0 byte after it.
 *
 * @param text The text, only read; a 0 byte in it ends the C string early.
 * @return The C string, which stays for the rest of the program; null without the memory.
 */
c_copy :: fn(text : string) -> cstring? {
    bytes, error :: runtime.new_array(u8, text.count + 1)
    if error != null || bytes.count == 0 {
        return null
    }
    source :: string_bytes(text)
    for i in 0..<source.count {
        if i < bytes.count {
            bytes[i] = source[i]
        }
    }
    return bit_cast[cstring](&bytes[0])
}

/**
 * Close every file descriptor and listing still open, as the program ends, and the working directory.
 *
 * @param state The libc's state; what it holds is given back.
 */
close_all :: fn(state : ptr[mut State]) {
    for &descriptor in state.descriptors {
        if descriptor.kind == .File {
            os.close(descriptor.file)
            descriptor.kind = .Closed
        }
    }
    runtime.array_free(&state.descriptors)
    for &listing in state.listings {
        if listing.open {
            os.free_directory_listing(listing.entries)
            listing.open = false
        }
    }
    runtime.array_free(&state.listings)
    runtime.array_free(&state.output_line)
    runtime.array_free(&state.error_line)
    runtime.array_free(&state.input)
    if state.output == .Console {
        terminal.free_editor(&state.editor)
    }
    if state.has_working {
        os.close_directory(state.working)
        state.has_working = false
    }
    if state.name.count > 0 {
        runtime.free_array(bit_cast[u8[]](state.name))
    }
}

/**
 * End the program at once with a code, after what stdout and stderr have of a line is written: C's exit calls it, after
 * running what atexit registered and flushing every stream; so does _exit, without those.
 *
 * @param code The exit code, any int: the program's is its low 8 bits, as POSIX's exit status, so -1 is 255 and 256
 *     is 0.
 */
slopos_libc_exit #export #calling_convention(.c) :: fn(code : i32) #never_returns {
    match state_of() {
        case Some(state) => flush_lines(state)
        case None => {}
    }
    os.exit(cast[u32](code & 0xff))
}

/**
 * Give the program's process ID: SlopOS gives programs none, so it's always 1.
 *
 * @return 1.
 */
getpid #export #calling_convention(.c) #no_context :: fn() -> i32 {
    return 1
}

/**
 * Give the program's user ID: SlopOS's files have no owners, so it's always 0.
 *
 * @return 0.
 */
getuid #export #calling_convention(.c) #no_context :: fn() -> u32 {
    return 0
}

/**
 * Give the program's effective user ID, as getuid's.
 *
 * @return 0.
 */
geteuid #export #calling_convention(.c) #no_context :: fn() -> u32 {
    return 0
}
