package libc

/*
 * File descriptors (decisions/0201, 20l): unistd.h's, fcntl.h's open (through c/files.c, as it's variadic),
 * sys/stat.h's and dirent.h's, over std's files beneath the working directory. A path is resolved there by text: "/"
 * and "" are the directory itself, empty and "." components are dropped, and ".." goes up but never above it, as at
 * a file system's root. 0 is stdin, from the console a line at a time; 1 and 2 are stdout and stderr, to the console,
 * or a line at a time to the debug log or the logger. Each exported function sets errno and answers -1 when it fails,
 * as C's do.
 */

import runtime from "base:runtime"
import os from "std:os"
import terminal from "std:terminal"
import log_line from "../log_line"

/** open's access mode bits: O_RDONLY 0, O_WRONLY 1, O_RDWR 2. */
O_ACCMODE : i32 : 3
/** open's O_WRONLY. */
O_WRONLY : i32 : 1
/** open's O_RDWR. */
O_RDWR : i32 : 2
/** open's O_CREAT: made if it's missing. */
O_CREAT : i32 : 0o100
/** open's O_EXCL: with O_CREAT, EEXIST if it's there. */
O_EXCL : i32 : 0o200
/** open's O_TRUNC: emptied if it's there. */
O_TRUNC : i32 : 0o1000
/** open's O_APPEND: every write at the end. */
O_APPEND : i32 : 0o2000

/** fcntl's commands, as fcntl.h has them, and F_SETFD's one flag. */
F_GETFD : i32 : 1
F_SETFD : i32 : 2
F_GETFL : i32 : 3
F_SETFL : i32 : 4
FD_CLOEXEC : i64 : 1

/** lseek's SEEK_SET: from the start. */
SEEK_SET : i32 : 0
/** lseek's SEEK_CUR: from where it's at. */
SEEK_CUR : i32 : 1
/** lseek's SEEK_END: from the end. */
SEEK_END : i32 : 2

/** The most file descriptors a program may have open, stdin, stdout and stderr among them. */
MOST_DESCRIPTORS : usize : 64
/** The most bytes a path's component may have. */
MOST_NAME_BYTES : usize : 255

/** sys/stat.h's S_IFDIR, a directory's kind, with 0755. */
DIRECTORY_MODE : u32 : 0o040755
/** sys/stat.h's S_IFREG, a file's kind, with 0644. */
FILE_MODE : u32 : 0o100644
/** sys/stat.h's S_IFCHR, a terminal's or log's kind, with 0620. */
DEVICE_MODE : u32 : 0o020620
/** What fstat says of a socket: S_IFSOCK, rwx for its owner, r-x for the rest. */
SOCKET_MODE : u32 : 0o140755

/** C's struct stat, as include/sys/stat.h lays it out. */
Stat :: struct {
    /** The device: always 0. */
    device : u64,
    /** The file's number: always 0. */
    inode : u64,
    /** Its kind and permission bits: DIRECTORY_MODE, FILE_MODE or DEVICE_MODE. */
    mode : u32,
    /** How many links it has: always 1. */
    links : u64,
    /** Its owner: always 0. */
    user : u32,
    /** Its group: always 0. */
    group : u32,
    /** Its size in bytes: a file's; 0 for anything else. */
    size : i64,
    /** The size its reads and writes are best in: 4096. */
    block_size : i64,
    /** How many 512-byte blocks it takes, rounded up from its size. */
    blocks : i64,
    /** When it was last read: not kept, so 0. */
    read_time : i64,
    /** When it was last written: not kept, so 0. */
    write_time : i64,
    /** When it was last changed: not kept, so 0. */
    change_time : i64,
}

#assert size_of(Stat) == 88

/** C's struct dirent, as include/dirent.h lays it out. */
Dirent :: struct {
    /** The entry's number: always 0. */
    inode : u64,
    /** DT_DIR (4) for a directory, DT_REG (8) for anything else. */
    kind : u8,
    /** Its name, 0-terminated: at most 255 bytes of it, the rest cut. */
    name : u8[256],
}

#assert size_of(Dirent) == 272

/** A path resolved beneath the working directory: what resolve gives. */
Resolved :: struct {
    /** The bytes it was built in, on the heap; given back with free_resolved. */
    held : mut u8[],
    /** The path, a view of held: "" for the working directory itself, else as std's is_beneath takes it. */
    path : string,
}

/**
 * Resolve a C path beneath the working directory, by its text.
 *
 * @param state The libc's state, whose working directory it's beneath.
 * @param text The path, a C string.
 * @return The path; Error with ENOENT for "", or with no working directory; ENAMETOOLONG for a component of more than
 *     255 bytes; ENOMEM without the memory.
 */
resolve :: fn(state : ptr[State], text : ptr[u8]) -> Result[Resolved, i32] {
    if !state.has_working {
        return .Error(E_NOENT)
    }
    count :: strlen(text)
    if count == 0 {
        return .Error(E_NOENT)
    }
    held, error :: runtime.new_array(u8, count)
    if error != null {
        return .Error(E_NOMEM)
    }
    // Where each component kept so far starts, the first depth of them
    starts : usize[..]
    defer runtime.array_free(&starts)
    depth : usize = 0
    length : usize = 0
    at : usize = 0
    loop {
        if at >= count {
            break
        }
        // One component, from at to the next / or the end
        end := at
        loop {
            if end >= count || byte_at(text, end) == cast[u8]('/') {
                break
            }
            end += 1
        }
        size :: end - at
        if size > MOST_NAME_BYTES {
            runtime.free_array(held)
            return .Error(E_NAMETOOLONG)
        }
        dot :: cast[u8]('.')
        if size == 2 && byte_at(text, at) == dot && byte_at(text, at + 1) == dot {
            // Up, but never above the working directory
            if depth > 0 {
                depth -= 1
                last :: if depth < starts.count { starts[depth] } else { cast[usize](0) }
                length = if last > 0 { last - 1 } else { 0 }
            }
        }
        else if size > 0 && !(size == 1 && byte_at(text, at) == dot) {
            if length > 0 && length < held.count {
                held[length] = cast[u8]('/')
                length += 1
            }
            if depth < starts.count {
                starts[depth] = length
            }
            else {
                runtime.array_add(&starts, length)
            }
            depth += 1
            for k in 0..<size {
                place :: length + k
                if place < held.count {
                    held[place] = byte_at(text, at + k)
                }
            }
            length += size
        }
        at = end + 1
    }
    path :: if length == 0 || held.count == 0 { "" } else { string_of(&held[0], length) }
    return .Ok(Resolved.{held = held, path = path})
}

/**
 * Give back a resolved path's bytes.
 *
 * @param resolved What resolve gave; its path isn't good after.
 */
free_resolved :: fn(resolved : Resolved) {
    runtime.free_array(resolved.held)
}

/**
 * Translate std's error into errno's.
 *
 * @param error What std's files said.
 * @return The E constant: ENOENT, EACCES, EEXIST, ENOTDIR, EISDIR, ENOTEMPTY, ENOMEM, ENOSYS, EINVAL for an invalid
 *     path or a typed file, or EIO for anything else.
 */
errno_of :: fn(error : os.OsError) -> i32 {
    return match error {
        case .NotFound => E_NOENT
        case .AccessDenied => E_ACCES
        case .AlreadyExists => E_EXIST
        case .NotADirectory => E_NOTDIR
        case .IsADirectory => E_ISDIR
        case .DirectoryNotEmpty => E_NOTEMPTY
        case .InvalidPath => E_INVAL
        case .OutOfMemory => E_NOMEM
        case .WrongType => E_INVAL
        case .Unsupported => E_NOSYS
        case .Other => E_IO
    }
}

/**
 * Fail as C's functions do: errno set, -1 answered.
 *
 * @param number The E constant.
 * @return -1.
 */
failed :: fn(number : i32) -> i32 {
    set_errno(number)
    return -1
}

/**
 * Find an open file descriptor.
 *
 * @param state The libc's state.
 * @param fd The descriptor's number.
 * @return Its record; null for a number that's out of range or closed.
 */
descriptor_of :: fn(state : ptr[mut State], fd : i32) -> ptr[mut Descriptor]? {
    if fd < 0 {
        return null
    }
    index :: cast[usize](fd)
    if index >= state.descriptors.count {
        return null
    }
    found :: &state.descriptors[index]
    return if found.kind == .Closed { null } else { found }
}

/**
 * Open a file beneath the working directory, as C's open, called by it (c/files.c) with its mode dropped.
 *
 * @param path The path, a C string, resolved as resolve says.
 * @param flags O_RDONLY, O_WRONLY or O_RDWR, with any of O_CREAT, O_EXCL, O_TRUNC and O_APPEND, which starts the
 *     descriptor at the file's end, as every write is; others are taken and change nothing.
 * @return The lowest free file descriptor from 3; -1 with errno ENOENT for a missing file without O_CREAT, EEXIST
 *     with O_EXCL for one there, EISDIR for a directory, EMFILE when 64 are open, EINVAL for a bad access mode, or
 *     std's error.
 */
slopos_libc_open #export #calling_convention(.c) :: fn(path : ptr[u8], flags : i32) -> i32 {
    state :: state_of() or_return failed(E_NOSYS)
    access :: flags & O_ACCMODE
    if access == O_ACCMODE {
        return failed(E_INVAL)
    }
    resolved :: match resolve(state, path) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(resolved)
    if resolved.path.count == 0 {
        return failed(E_ISDIR)
    }
    kind :: os.path_kind_in(state.working, resolved.path)
    if kind == .DIRECTORY {
        return failed(E_ISDIR)
    }
    there :: kind == .FILE
    if there && (flags & O_CREAT) != 0 && (flags & O_EXCL) != 0 {
        return failed(E_EXIST)
    }
    if !there && (flags & O_CREAT) == 0 {
        return failed(E_NOENT)
    }
    writes :: access == O_WRONLY || access == O_RDWR
    // What std opens it as: READ for reading alone, WRITE to empty or make it, READ_WRITE for one there, kept
    mode := os.OpenMode.READ
    if writes || (flags & O_TRUNC) != 0 || !there {
        mode = if (flags & O_TRUNC) != 0 || !there { os.OpenMode.WRITE } else { os.OpenMode.READ_WRITE }
    }
    // Reading alone a file that's to be made or emptied: made or emptied, then reopened only to read
    if mode == .WRITE && !writes {
        match os.open_in(state.working, resolved.path, .WRITE) {
            case Ok(made) => os.close(made)
            case Error(error) => return failed(errno_of(error))
        }
        mode = .READ
    }
    file :: match os.open_in(state.working, resolved.path, mode) {
        case Ok(opened) => opened
        case Error(error) => return failed(errno_of(error))
    }
    // Appending starts at the end, so lseek and ftell say so before the first write, as every write goes there too
    if (flags & O_APPEND) != 0 {
        match os.file_size(file) {
            case Ok(size) => os.file_seek(file, size)
            case Error(error) => {
                os.close(file)
                return failed(errno_of(error))
            }
        }
    }
    made := Descriptor.{
        kind = .File,
        file = file,
        readable = access != O_WRONLY,
        writable = writes,
        append = (flags & O_APPEND) != 0,
    }
    for &descriptor, i in state.descriptors {
        if descriptor.kind == .Closed {
            descriptor^ = made
            return cast[i32](i)
        }
    }
    if state.descriptors.count >= MOST_DESCRIPTORS {
        os.close(file)
        return failed(E_MFILE)
    }
    runtime.array_add(&state.descriptors, made)
    return cast[i32](state.descriptors.count - 1)
}

/**
 * Ask about or change a descriptor, as C's fcntl, called by it (c/files.c) with its argument read.
 *
 * @param fd The descriptor.
 * @param command F_GETFD, F_SETFD, F_GETFL or F_SETFL.
 * @param argument For F_SETFD, FD_CLOEXEC or 0; for F_SETFL, flags whose O_APPEND is kept for a file and O_NONBLOCK
 *     for a socket, and the rest dropped, as the access mode can't change and files never block. Unread otherwise.
 * @return F_GETFD: FD_CLOEXEC or 0. F_GETFL: O_RDONLY, O_WRONLY or O_RDWR, with O_APPEND and O_NONBLOCK if it has
 *     them; stdin's is
 *     O_RDONLY, stdout's and stderr's O_WRONLY. 0 for the others. -1, errno EBADF for a descriptor that isn't open,
 *     or EINVAL for another command.
 */
slopos_libc_fcntl #export #calling_convention(.c) :: fn(fd : i32, command : i32, argument : i64) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if command == F_GETFD {
        return if descriptor.close_on_exec { cast[i32](FD_CLOEXEC) } else { 0 }
    }
    if command == F_SETFD {
        descriptor.close_on_exec = (argument & FD_CLOEXEC) != 0
        return 0
    }
    if command == F_GETFL {
        access :: match descriptor.kind {
            case .Input => cast[i32](0)
            case .Output => O_WRONLY
            case _ => if descriptor.readable && descriptor.writable { O_RDWR } else if descriptor.writable { O_WRONLY } else { cast[i32](0) }
        }
        return access | (if descriptor.append { O_APPEND } else { cast[i32](0) })
            | (if descriptor.nonblocking { O_NONBLOCK } else { cast[i32](0) })
    }
    if command == F_SETFL {
        if descriptor.kind == .File {
            descriptor.append = (argument & cast[i64](O_APPEND)) != 0
        }
        if descriptor.kind == .Socket {
            descriptor.nonblocking = (argument & cast[i64](O_NONBLOCK)) != 0
        }
        return 0
    }
    return failed(E_INVAL)
}

/**
 * Close a file descriptor.
 *
 * @param fd The descriptor; its number's free for the next open after. Closing stdin, stdout or stderr only marks it
 *     closed.
 * @return 0; -1 with errno EBADF for one that isn't open.
 */
close #export #calling_convention(.c) :: fn(fd : i32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if descriptor.kind == .Socket {
        close_socket(state, fd)
        return 0
    }
    if descriptor.kind == .File {
        os.close(descriptor.file)
    }
    descriptor^ = Descriptor.{}
    return 0
}

/**
 * Read from a file descriptor, from where it's at.
 *
 * @param fd The descriptor, open to read.
 * @param into Where the bytes go, count of them.
 * @param count The most bytes read; a file's read gives at most 64 KiB at once.
 * @return How many were read, 0 at the end; -1 with errno EBADF for one not open to read, or std's error.
 */
read #export #calling_convention(.c) :: fn(fd : i32, into : ptr[mut u8], count : usize) -> i64 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if !descriptor.readable {
        return failed(E_BADF)
    }
    if count == 0 {
        return 0
    }
    if descriptor.kind == .Input {
        return cast[i64](read_input(state, view_of(into, count)))
    }
    if descriptor.kind == .Socket {
        return read_socket(state, descriptor, fd, view_of(into, count))
    }
    if descriptor.kind != .File {
        return failed(E_BADF)
    }
    match os.read(descriptor.file, view_of(into, count)) {
        case Ok(got) => return cast[i64](got)
        case Error(error) => return failed(errno_of(error))
    }
}

/**
 * Write to a file descriptor, where it's at, or at the end with O_APPEND.
 *
 * @param fd The descriptor, open to write.
 * @param from The bytes, count of them.
 * @param count How many.
 * @return count, once all are written; -1 with errno EBADF for one not open to write, or std's error, with what came
 *     before it written.
 */
write #export #calling_convention(.c) :: fn(fd : i32, from : ptr[u8], count : usize) -> i64 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if !descriptor.writable {
        return failed(E_BADF)
    }
    if count == 0 {
        return 0
    }
    if descriptor.kind == .Socket {
        return write_socket(state, descriptor, fd, view_of(from, count))
    }
    bytes :: string_of(from, count)
    if descriptor.kind == .Output {
        write_output(state, if fd == 2 { cast[usize](1) } else { cast[usize](0) }, bytes)
        return cast[i64](count)
    }
    if descriptor.append {
        match os.file_size(descriptor.file) {
            case Ok(size) => os.file_seek(descriptor.file, size)
            case Error(error) => return failed(errno_of(error))
        }
    }
    match os.write(descriptor.file, bytes) {
        case Some(error) => return failed(errno_of(error))
        case None => return cast[i64](count)
    }
}

/**
 * Move where a file descriptor's next read or write is.
 *
 * @param fd The descriptor, a file's.
 * @param offset Bytes from where whence says.
 * @param whence SEEK_SET, SEEK_CUR or SEEK_END.
 * @return The new place, in bytes from the start; -1 with errno ESPIPE for stdin, stdout or stderr, EINVAL for a bad
 *     whence or a place before the start, EBADF for one not open.
 */
lseek #export #calling_convention(.c) :: fn(fd : i32, offset : i64, whence : i32) -> i64 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if descriptor.kind != .File {
        return failed(E_SPIPE)
    }
    base : i64 = 0
    if whence == SEEK_CUR {
        base = cast[i64](os.file_of(descriptor.file).offset)
    }
    else if whence == SEEK_END {
        match os.file_size(descriptor.file) {
            case Ok(size) => base = cast[i64](size)
            case Error(error) => return failed(errno_of(error))
        }
    }
    else if whence != SEEK_SET {
        return failed(E_INVAL)
    }
    place :: base + offset
    if place < 0 {
        return failed(E_INVAL)
    }
    os.file_seek(descriptor.file, cast[u64](place))
    return place
}

/**
 * Make an open file a size: cut short, or longer with zeros.
 *
 * @param fd The descriptor, a file's open to write; where it's at doesn't move.
 * @param size The size, in bytes.
 * @return 0; -1 with errno EBADF for one not open to write, EINVAL for a negative size, or std's error.
 */
ftruncate #export #calling_convention(.c) :: fn(fd : i32, size : i64) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if descriptor.kind != .File || !descriptor.writable {
        return failed(E_BADF)
    }
    if size < 0 {
        return failed(E_INVAL)
    }
    match os.file_set_size(descriptor.file, cast[u64](size)) {
        case Some(error) => return failed(errno_of(error))
        case None => return 0
    }
}

/**
 * Make what's written to a file descriptor last: each write's done by its server before it answers, so there's
 * nothing more to do.
 *
 * @param fd The descriptor.
 * @return 0; -1 with errno EBADF for one that isn't open.
 */
fsync #export #calling_convention(.c) :: fn(fd : i32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    return 0
}

/**
 * Tell whether a file descriptor is a terminal.
 *
 * @param fd The descriptor.
 * @return 1 for stdin, stdout and stderr when the program has a console; 0, errno ENOTTY, for anything else, or EBADF
 *     for one that isn't open.
 */
isatty #export #calling_convention(.c) :: fn(fd : i32) -> i32 {
    state :: state_of() or_return not_a_terminal(E_NOTTY)
    descriptor :: descriptor_of(state, fd) or_return not_a_terminal(E_BADF)
    if descriptor.kind != .File && state.output == .Console {
        return 1
    }
    return not_a_terminal(E_NOTTY)
}

/**
 * Answer isatty's no.
 *
 * @param number The E constant errno's set to.
 * @return 0.
 */
not_a_terminal :: fn(number : i32) -> i32 {
    set_errno(number)
    return 0
}

/**
 * Describe what's at a path, beneath the working directory.
 *
 * @param path The path, a C string.
 * @param into Where it's described.
 * @return 0; -1 with errno ENOENT if nothing's there, or resolve's error.
 */
stat #export #calling_convention(.c) :: fn(path : ptr[u8], into : ptr[mut Stat]) -> i32 {
    state :: state_of() or_return failed(E_NOENT)
    resolved :: match resolve(state, path) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(resolved)
    if resolved.path.count == 0 {
        into^ = described(DIRECTORY_MODE, 0)
        return 0
    }
    match os.path_kind_in(state.working, resolved.path) {
        case .NOTHING => return failed(E_NOENT)
        case .DIRECTORY => {
            into^ = described(DIRECTORY_MODE, 0)
            return 0
        }
        case .FILE => {
            file :: match os.open_in(state.working, resolved.path, .READ) {
                case Ok(opened) => opened
                case Error(error) => return failed(errno_of(error))
            }
            defer os.close(file)
            match os.file_size(file) {
                case Ok(size) => {
                    into^ = described(FILE_MODE, size)
                    return 0
                }
                case Error(error) => return failed(errno_of(error))
            }
        }
    }
}

/**
 * Describe what's at a path, as stat: SlopOS has no symbolic links for C to see.
 *
 * @param path The path, a C string.
 * @param into Where it's described.
 * @return As stat's.
 */
lstat #export #calling_convention(.c) :: fn(path : ptr[u8], into : ptr[mut Stat]) -> i32 {
    return stat(path, into)
}

/**
 * Describe an open file descriptor.
 *
 * @param fd The descriptor.
 * @param into Where it's described: a file's size, or a character device for stdin, stdout and stderr.
 * @return 0; -1 with errno EBADF for one that isn't open, or std's error.
 */
fstat #export #calling_convention(.c) :: fn(fd : i32, into : ptr[mut Stat]) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    descriptor :: descriptor_of(state, fd) or_return failed(E_BADF)
    if descriptor.kind != .File {
        into^ = described(if descriptor.kind == .Socket { SOCKET_MODE } else { DEVICE_MODE }, 0)
        return 0
    }
    match os.file_size(descriptor.file) {
        case Ok(size) => {
            into^ = described(FILE_MODE, size)
            return 0
        }
        case Error(error) => return failed(errno_of(error))
    }
}

/**
 * Make a stat's description.
 *
 * @param mode Its kind and permission bits.
 * @param size Its size in bytes.
 * @return The description, the rest 0, as SlopOS keeps none of it for C.
 */
described :: fn(mode : u32, size : u64) -> Stat {
    return Stat.{
        mode = mode,
        links = 1,
        size = cast[i64](size),
        block_size = 4096,
        blocks = cast[i64]((size + 511) / 512),
    }
}

/**
 * Tell whether a path can be reached, beneath the working directory.
 *
 * @param path The path, a C string.
 * @param mode F_OK, or any of R_OK, W_OK and X_OK, which SlopOS's files don't keep, so anything that's there allows.
 * @return 0 if something's there; -1 with errno ENOENT if not, or resolve's error.
 */
access #export #calling_convention(.c) :: fn(path : ptr[u8], mode : i32) -> i32 {
    state :: state_of() or_return failed(E_NOENT)
    resolved :: match resolve(state, path) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(resolved)
    if resolved.path.count == 0 || os.path_kind_in(state.working, resolved.path) != .NOTHING {
        return 0
    }
    return failed(E_NOENT)
}

/**
 * Do something to a path beneath the working directory that std's files do and answer like C's functions.
 *
 * @param path The path, a C string.
 * @param action What's done: 0 deletes a file, 1 removes an empty directory, 2 makes a directory.
 * @return 0; -1 with errno EBUSY's stand-in EACCES for the working directory itself, resolve's error, or std's.
 */
on_path :: fn(path : ptr[u8], action : int) -> i32 {
    state :: state_of() or_return failed(E_NOENT)
    resolved :: match resolve(state, path) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(resolved)
    if resolved.path.count == 0 {
        return failed(if action == 2 { E_EXIST } else { E_ACCES })
    }
    if action == 0 && os.path_kind_in(state.working, resolved.path) == .DIRECTORY {
        return failed(E_ISDIR)
    }
    error :: if action == 0 {
        os.delete_file_in(state.working, resolved.path)
    }
    else if action == 1 {
        os.remove_directory_in(state.working, resolved.path)
    }
    else {
        os.make_directory_in(state.working, resolved.path)
    }
    match error {
        case Some(failure) => return failed(errno_of(failure))
        case None => return 0
    }
}

/**
 * Delete a file beneath the working directory.
 *
 * @param path The file's path, a C string.
 * @return 0; -1 with errno EISDIR for a directory, ENOENT for nothing there, or std's error.
 */
unlink #export #calling_convention(.c) :: fn(path : ptr[u8]) -> i32 {
    return on_path(path, 0)
}

/**
 * Remove an empty directory beneath the working directory.
 *
 * @param path The directory's path, a C string.
 * @return 0; -1 with errno ENOTEMPTY for one with something in it, ENOENT for nothing there, or std's error.
 */
rmdir #export #calling_convention(.c) :: fn(path : ptr[u8]) -> i32 {
    return on_path(path, 1)
}

/**
 * Make a directory beneath the working directory, its parent there already.
 *
 * @param path The directory's path, a C string.
 * @param mode Its permissions, which SlopOS doesn't keep, so taken and not used.
 * @return 0; -1 with errno EEXIST for something there, ENOENT for a missing parent, or std's error.
 */
mkdir #export #calling_convention(.c) :: fn(path : ptr[u8], mode : u32) -> i32 {
    return on_path(path, 2)
}

/**
 * Rename a file or directory, both paths beneath the working directory; what's at to is replaced.
 *
 * @param from Its path, a C string.
 * @param to Its new path, a C string.
 * @return 0; -1 with errno ENOENT for nothing at from, resolve's error, or std's.
 */
rename #export #calling_convention(.c) :: fn(from : ptr[u8], to : ptr[u8]) -> i32 {
    state :: state_of() or_return failed(E_NOENT)
    source :: match resolve(state, from) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(source)
    target :: match resolve(state, to) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(target)
    if source.path.count == 0 || target.path.count == 0 {
        return failed(E_ACCES)
    }
    match os.rename_in(state.working, source.path, target.path) {
        case Some(failure) => return failed(errno_of(failure))
        case None => return 0
    }
}

/**
 * Give the working directory's path: always "/", the directory itself, as SlopOS has no paths above it.
 *
 * @param into Where it goes, size bytes.
 * @param size How many bytes into has: at least 2.
 * @return into; NULL with errno ERANGE when size is below 2.
 */
getcwd #export #calling_convention(.c) :: fn(into : ptr[mut u8], size : usize) -> ptr[mut u8]? {
    if size < 2 {
        set_errno(E_RANGE)
        return null
    }
    set_byte(into, 0, cast[u8]('/'))
    set_byte(into, 1, 0)
    return into
}

/**
 * Change the working directory: SlopOS's is the one the program was given, so only "/" and paths that resolve to it
 * are taken.
 *
 * @param path The path, a C string.
 * @return 0 for the directory itself; -1 with errno ENOSYS for anything else, or resolve's error.
 */
chdir #export #calling_convention(.c) :: fn(path : ptr[u8]) -> i32 {
    state :: state_of() or_return failed(E_NOENT)
    resolved :: match resolve(state, path) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(resolved)
    return if resolved.path.count == 0 { 0 } else { failed(E_NOSYS) }
}

/**
 * Read a directory's listing for opendir (c/files.c): read whole now, so what changes after isn't seen.
 *
 * @param path The directory's path, a C string.
 * @return Its handle, from 1, for slopos_libc_readdir and slopos_libc_closedir; -1 with errno ENOTDIR for a file, or resolve's
 *     error, or std's.
 */
slopos_libc_opendir #export #calling_convention(.c) :: fn(path : ptr[u8]) -> i32 {
    state :: state_of() or_return failed(E_NOENT)
    resolved :: match resolve(state, path) {
        case Ok(made) => made
        case Error(number) => return failed(number)
    }
    defer free_resolved(resolved)
    entries :: match os.list_directory_in(state.working, resolved.path) {
        case Ok(listed) => listed
        case Error(error) => return failed(errno_of(error))
    }
    made :: Listing.{open = true, entries = entries}
    for &listing, i in state.listings {
        if !listing.open {
            listing^ = made
            return cast[i32](i + 1)
        }
    }
    runtime.array_add(&state.listings, made)
    return cast[i32](state.listings.count)
}

/**
 * Find an open listing.
 *
 * @param state The libc's state.
 * @param handle What slopos_libc_opendir gave.
 * @return The listing; null for a handle that isn't open.
 */
listing_of :: fn(state : ptr[mut State], handle : i32) -> ptr[mut Listing]? {
    if handle < 1 {
        return null
    }
    index :: cast[usize](handle - 1)
    if index >= state.listings.count {
        return null
    }
    found :: &state.listings[index]
    return if found.open { found } else { null }
}

/**
 * Give the next entry of a listing, for readdir.
 *
 * @param handle What slopos_libc_opendir gave.
 * @param into Where the entry goes.
 * @return 1 once into has it; 0 at the listing's end; -1 with errno EBADF for a handle that isn't open.
 */
slopos_libc_readdir #export #calling_convention(.c) :: fn(handle : i32, into : ptr[mut Dirent]) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    listing :: listing_of(state, handle) or_return failed(E_BADF)
    if listing.next >= listing.entries.count {
        return 0
    }
    entry :: listing.entries[listing.next]
    listing.next += 1
    into.inode = 0
    into.kind = if entry.is_directory { cast[u8](4) } else { cast[u8](8) }
    bytes :: string_bytes(entry.name)
    count :: if bytes.count < MOST_NAME_BYTES { bytes.count } else { MOST_NAME_BYTES }
    for i in 0..<into.name.count {
        into.name[i] = if i < count && i < bytes.count { bytes[i] } else { 0 }
    }
    return 1
}

/**
 * Start a listing again from its first entry, for rewinddir.
 *
 * @param handle What slopos_libc_opendir gave; one that isn't open is ignored.
 */
slopos_libc_rewinddir #export #calling_convention(.c) :: fn(handle : i32) {
    state :: state_of() or_return void
    listing :: listing_of(state, handle) or_return void
    listing.next = 0
}

/**
 * Give a listing back, for closedir.
 *
 * @param handle What slopos_libc_opendir gave; its handle may be given to the next.
 * @return 0; -1 with errno EBADF for a handle that isn't open.
 */
slopos_libc_closedir #export #calling_convention(.c) :: fn(handle : i32) -> i32 {
    state :: state_of() or_return failed(E_BADF)
    listing :: listing_of(state, handle) or_return failed(E_BADF)
    os.free_directory_listing(listing.entries)
    listing^ = Listing.{}
    return 0
}

/**
 * Read stdin: what's left of the line read before, or the next line from the console, its line break added.
 *
 * @param state The libc's state.
 * @param into Where the bytes go.
 * @return How many bytes were read: 0 once stdin's ended (no console, Ctrl-C, the terminal gone, or a stop asked).
 */
read_input :: fn(state : ptr[mut State], into : mut u8[]) -> usize {
    loop {
        if state.input_at < state.input.count {
            count : usize = 0
            for i in 0..<into.count {
                at :: state.input_at + i
                if at >= state.input.count {
                    break
                }
                into[i] = state.input[at]
                count += 1
            }
            state.input_at += count
            return count
        }
        if state.input_ended {
            return 0
        }
        runtime.array_reset(&state.input)
        state.input_at = 0
        match terminal.read_line(&state.editor, &state.console, "") {
            case Line(text) => {
                for byte in string_bytes(text) {
                    runtime.array_add(&state.input, byte)
                }
                runtime.array_add(&state.input, cast[u8]('\n'))
                if text.count > 0 {
                    runtime.free_array(bit_cast[u8[]](text))
                }
            }
            case Other(packet) => {}
            case _ => state.input_ended = true
        }
    }
}

/**
 * Find stdout's or stderr's line so far, for the log or logger.
 *
 * @param state The libc's state.
 * @param which 0 for stdout; anything else for stderr.
 * @return The line, the state's.
 */
line_of :: fn(state : ptr[mut State], which : usize) -> ptr[mut u8[..]] {
    return if which == 0 { &state.output_line } else { &state.error_line }
}

/**
 * Write to stdout or stderr: to the console as it comes, or to the log or logger a line at a time.
 *
 * @param state The libc's state.
 * @param which 0 for stdout, 1 for stderr, whose lines are kept apart.
 * @param bytes What's written; any bytes, a line break ending each line.
 */
write_output :: fn(state : ptr[mut State], which : usize, bytes : string) {
    if state.output == .Console {
        _ = terminal.write(&state.console, bytes)
        return void
    }
    line :: line_of(state, which)
    for byte in string_bytes(bytes) {
        if byte == cast[u8]('\n') {
            write_line(state, which)
        }
        else {
            runtime.array_add(line, byte)
        }
    }
}

/**
 * Write stdout's or stderr's line so far to the log or logger, and empty it.
 *
 * @param state The libc's state.
 * @param which 0 for stdout, 1 for stderr.
 */
write_line :: fn(state : ptr[mut State], which : usize) {
    line :: line_of(state, which)
    bytes :: line^
    text := ""
    if bytes.count > 0 {
        text = string_of(&bytes[0], bytes.count)
    }
    if state.output == .Log {
        log_line.write(state.log, "%: %", state.name, text)
    }
    else {
        runtime.log_info("%", text)
    }
    runtime.array_reset(line)
}

/**
 * Write what stdout and stderr have of a line that hasn't ended, as the program ends.
 *
 * @param state The libc's state.
 */
flush_lines :: fn(state : ptr[mut State]) {
    for which in cast[usize](0)..<2 {
        if line_of(state, which).count > 0 {
            write_line(state, which)
        }
    }
}
