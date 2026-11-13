/**
 * SFTP, version 3 (draft-ietf-secsh-filexfer-02), as OpenSSH's sftp and scp speak it (decisions/0191): its packets
 * answered on a home, which is its root, "/". Paths are made relative to it, "." and ".." taken away, never above it.
 * What's given is whole packets, a uint32's length and the packet; what's answered goes to the Sftp's outbox, for its
 * caller to send.
 *
 * Files are read and written from where their handles are: a read from elsewhere opens the file again and reads on to
 * where it's asked, and a write elsewhere is refused, as SlopOS's files have no seek; sftp and scp go in order. SETSTAT
 * and FSETSTAT are answered OK and do nothing, as SlopOS's files have no owners or modes; files are shown as 0644 and
 * directories 0755.
 */
package sftp

import runtime from "base"
import os from "std"
import ssh from "std"

// Requests and answers
SSH_FXP_INIT : u8 : 1
SSH_FXP_VERSION : u8 : 2
SSH_FXP_OPEN : u8 : 3
SSH_FXP_CLOSE : u8 : 4
SSH_FXP_READ : u8 : 5
SSH_FXP_WRITE : u8 : 6
SSH_FXP_LSTAT : u8 : 7
SSH_FXP_FSTAT : u8 : 8
SSH_FXP_SETSTAT : u8 : 9
SSH_FXP_FSETSTAT : u8 : 10
SSH_FXP_OPENDIR : u8 : 11
SSH_FXP_READDIR : u8 : 12
SSH_FXP_REMOVE : u8 : 13
SSH_FXP_MKDIR : u8 : 14
SSH_FXP_RMDIR : u8 : 15
SSH_FXP_REALPATH : u8 : 16
SSH_FXP_STAT : u8 : 17
SSH_FXP_RENAME : u8 : 18
SSH_FXP_STATUS : u8 : 101
SSH_FXP_HANDLE : u8 : 102
SSH_FXP_DATA : u8 : 103
SSH_FXP_NAME : u8 : 104
SSH_FXP_ATTRS : u8 : 105
// Statuses
SSH_FX_OK : u32 : 0
SSH_FX_EOF : u32 : 1
SSH_FX_NO_SUCH_FILE : u32 : 2
SSH_FX_PERMISSION_DENIED : u32 : 3
SSH_FX_FAILURE : u32 : 4
SSH_FX_BAD_MESSAGE : u32 : 5
SSH_FX_OP_UNSUPPORTED : u32 : 8
// OPEN's flags
SSH_FXF_READ : u32 : 1
SSH_FXF_WRITE : u32 : 2
SSH_FXF_APPEND : u32 : 4
SSH_FXF_CREAT : u32 : 8
SSH_FXF_TRUNC : u32 : 16
SSH_FXF_EXCL : u32 : 32
// Attributes' flags
SSH_FILEXFER_ATTR_SIZE : u32 : 1
SSH_FILEXFER_ATTR_PERMISSIONS : u32 : 4

/** The most bytes of a request kept: a WRITE of 32 KiB and its header, and more. */
SFTP_PACKET_BYTES :: 40000
/** The most bytes a READ gives at once. */
SFTP_READ_BYTES :: 32768
/** The most handles open at once. */
SFTP_HANDLES :: 8
/** The most bytes of a path kept. */
SFTP_PATH_BYTES :: 512
/** Directory entries a READDIR answer gives at once, at most. */
SFTP_NAMES_AT_ONCE :: 32

/** An open file or directory. */
SftpHandle :: struct {
    used : bool,
    directory : bool,
    file : os.File,
    writing : bool,
    position : u64,
    path : u8[SFTP_PATH_BYTES],
    path_count : usize,
    listing : os.DirectoryEntry[..],
    listed : bool,
    next : usize,
}

/** An SFTP stream's state: its home, what's come and what's to go, and its handles. */
Sftp :: struct {
    home : os.Directory,
    inbox : u8[SFTP_PACKET_BYTES],
    inbox_count : usize,
    handles : SftpHandle[SFTP_HANDLES],
    message : u8[SFTP_READ_BYTES + 1024],
    /** Answers to be sent, their first outbox_count bytes. */
    outbox : u8[OUTBOX_BYTES],
    outbox_count : usize,
}

/** The most bytes of answers held at once, for the caller to send: a READ's data and room besides. */
OUTBOX_BYTES :: SFTP_READ_BYTES + 4096

/**
 * Start SFTP on a home.
 *
 * @param home The home, its root; the Sftp's from now on, closed by end_sftp.
 * @return The Sftp, which end_sftp gives back.
 */
start_sftp :: fn(home: os.Directory) -> ptr[mut Sftp] {
    made :: runtime.new(Sftp)
    made.home = home
    return made
}

/**
 * Answer every whole packet in what's come, while there's room in the outbox for the answers.
 *
 * @param sftp The Sftp; its inbox, filled by the caller up to inbox_count, is taken from as packets are answered.
 * @return False if a packet's length can't be: the caller ends the stream.
 */
serve :: fn(sftp: ptr[mut Sftp]) -> bool {
    loop {
        if sftp.outbox_count + SFTP_READ_BYTES + 2048 > sftp.outbox.count || sftp.inbox_count < 4 {
            break
        }
        length :: (cast[usize](ssh.byte_at(sftp.inbox[0..<SFTP_PACKET_BYTES], 0)) << 24) | (cast[usize](ssh.byte_at(sftp.inbox[0..<SFTP_PACKET_BYTES], 1)) << 16)
            | (cast[usize](ssh.byte_at(sftp.inbox[0..<SFTP_PACKET_BYTES], 2)) << 8) | cast[usize](ssh.byte_at(sftp.inbox[0..<SFTP_PACKET_BYTES], 3))
        if length == 0 || length + 4 > SFTP_PACKET_BYTES {
            return false
        }
        if sftp.inbox_count < length + 4 {
            break
        }
        request(sftp, ssh.range(sftp.inbox[0..<SFTP_PACKET_BYTES], 4, 4 + length))
        sftp.inbox_count = ssh.drop_front(sftp.inbox[0..<SFTP_PACKET_BYTES], sftp.inbox_count, length + 4)
    }
    while true
    return true
}

/** Take what's been sent from the outbox: count bytes from its front. */
sent :: fn(sftp: ptr[mut Sftp], count: usize) {
    sftp.outbox_count = ssh.drop_front(sftp.outbox[0..<OUTBOX_BYTES], sftp.outbox_count, count)
}

/** Answer one request. */
request :: fn(sftp: ptr[mut Sftp], packet: u8[]) {
    reader := ssh.Reader.{at = 1, end = packet.count}
    kind :: ssh.byte_at(packet, 0)
    if kind == SSH_FXP_INIT {
        writer := ssh.Writer.{}
        out :: sftp.message[0..<sftp.message.count]
        put_header(out, &writer, SSH_FXP_VERSION)
        ssh.put_u32(out, &writer, 3)
        send(sftp, out, &writer)
        return void
    }
    id :: ssh.get_u32(packet, &reader)
    if kind == SSH_FXP_REALPATH {
        path :: ssh.get_string(packet, &reader)
        normal : u8[SFTP_PATH_BYTES]
        count :: normalize(path, normal[0..<SFTP_PATH_BYTES]) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        shown : u8[SFTP_PATH_BYTES + 1]
        shown[0] = 0x2f
        for i in cast[usize](0)..<count {
            if i + 1 < shown.count && i < normal.count {
                shown[i + 1] = normal[i]
            }
        }
        name_answer(sftp, id, ssh.range(shown[0..<shown.count], 0, count + 1), true, 0)
        return void
    }
    if kind == SSH_FXP_STAT || kind == SSH_FXP_LSTAT {
        relative : u8[SFTP_PATH_BYTES]
        count :: normalize(ssh.get_string(packet, &reader), relative[0..<SFTP_PATH_BYTES]) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        path :: ssh.range(relative[0..<SFTP_PATH_BYTES], 0, count)
        attrs_answer(sftp, id, path)
        return void
    }
    if kind == SSH_FXP_OPEN || kind == SSH_FXP_OPENDIR {
        relative : u8[SFTP_PATH_BYTES]
        count :: normalize(ssh.get_string(packet, &reader), relative[0..<SFTP_PATH_BYTES]) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        flags :: if kind == SSH_FXP_OPEN { ssh.get_u32(packet, &reader) } else { cast[u32](0) }
        open(sftp, id, ssh.range(relative[0..<SFTP_PATH_BYTES], 0, count), kind == SSH_FXP_OPENDIR, flags)
        return void
    }
    if kind == SSH_FXP_CLOSE || kind == SSH_FXP_READ || kind == SSH_FXP_WRITE || kind == SSH_FXP_READDIR || kind == SSH_FXP_FSTAT
        || kind == SSH_FXP_FSETSTAT {
        index :: handle_index(ssh.get_string(packet, &reader)) or_return status(sftp, id, SSH_FX_FAILURE)
        if index >= sftp.handles.count || !sftp.handles[index].used {
            status(sftp, id, SSH_FX_FAILURE)
            return void
        }
        handle :: &sftp.handles[index]
        if kind == SSH_FXP_CLOSE {
            close_handle(handle)
            status(sftp, id, SSH_FX_OK)
        }
        else if kind == SSH_FXP_READ {
            offset :: (cast[u64](ssh.get_u32(packet, &reader)) << 32) | cast[u64](ssh.get_u32(packet, &reader))
            wanted :: ssh.get_u32(packet, &reader)
            read(sftp, id, handle, offset, if wanted < cast[u32](SFTP_READ_BYTES) { cast[usize](wanted) } else { cast[usize](SFTP_READ_BYTES) })
        }
        else if kind == SSH_FXP_WRITE {
            offset :: (cast[u64](ssh.get_u32(packet, &reader)) << 32) | cast[u64](ssh.get_u32(packet, &reader))
            data :: ssh.get_string(packet, &reader)
            if handle.directory || !handle.writing || offset != handle.position {
                status(sftp, id, SSH_FX_FAILURE)
            }
            else if data.count == 0 || os.write(handle.file, string_of(&data[0], data.count)) == null {
                handle.position += cast[u64](data.count)
                status(sftp, id, SSH_FX_OK)
            }
            else {
                status(sftp, id, SSH_FX_FAILURE)
            }
        }
        else if kind == SSH_FXP_READDIR {
            read_directory(sftp, id, handle)
        }
        else if kind == SSH_FXP_FSTAT {
            attrs_answer(sftp, id, ssh.range(handle.path[0..<SFTP_PATH_BYTES], 0, handle.path_count))
        }
        else {
            status(sftp, id, SSH_FX_OK)
        }
        return void
    }
    if kind == SSH_FXP_SETSTAT {
        status(sftp, id, SSH_FX_OK)
        return void
    }
    if kind == SSH_FXP_REMOVE || kind == SSH_FXP_MKDIR || kind == SSH_FXP_RMDIR {
        relative : u8[SFTP_PATH_BYTES]
        count :: normalize(ssh.get_string(packet, &reader), relative[0..<SFTP_PATH_BYTES]) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        if count == 0 {
            status(sftp, id, SSH_FX_PERMISSION_DENIED)
            return void
        }
        path :: string_of(&relative[0], count)
        failed :: if kind == SSH_FXP_REMOVE { os.delete_file_in(sftp.home, path) } else if kind == SSH_FXP_MKDIR { os.make_directory_in(sftp.home, path) }
            else { os.remove_directory_in(sftp.home, path) }
        status(sftp, id, code_of(failed))
        return void
    }
    if kind == SSH_FXP_RENAME {
        from : u8[SFTP_PATH_BYTES]
        to : u8[SFTP_PATH_BYTES]
        from_count :: normalize(ssh.get_string(packet, &reader), from[0..<SFTP_PATH_BYTES]) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        to_count :: normalize(ssh.get_string(packet, &reader), to[0..<SFTP_PATH_BYTES]) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        if from_count == 0 || to_count == 0 {
            status(sftp, id, SSH_FX_PERMISSION_DENIED)
            return void
        }
        status(sftp, id, code_of(os.rename_in(sftp.home, string_of(&from[0], from_count), string_of(&to[0], to_count))))
        return void
    }
    status(sftp, id, SSH_FX_OP_UNSUPPORTED)
}

/** Open a file or a directory as a new handle, answered with it. */
open :: fn(sftp: ptr[mut Sftp], id: u32, path: u8[], directory: bool, flags: u32) {
    free := sftp.handles.count
    for &each, i in sftp.handles {
        if !each.used && free == sftp.handles.count {
            free = i
        }
    }
    if free >= sftp.handles.count || path.count > SFTP_PATH_BYTES {
        status(sftp, id, SSH_FX_FAILURE)
        return void
    }
    handle :: &sftp.handles[free]
    text :: if path.count > 0 { string_of(&path[0], path.count) } else { "" }
    if directory {
        listing :: os.list_directory_in(sftp.home, text) or_return status(sftp, id, SSH_FX_NO_SUCH_FILE)
        handle^ = SftpHandle.{used = true, directory = true, listing = listing, listed = true}
    }
    else {
        if path.count == 0 {
            status(sftp, id, SSH_FX_FAILURE)
            return void
        }
        writing :: flags & SSH_FXF_WRITE != 0
        there :: os.path_kind_in(sftp.home, text)
        if writing && flags & SSH_FXF_EXCL != 0 && there != .NOTHING {
            status(sftp, id, SSH_FX_FAILURE)
            return void
        }
        mode :: if !writing { os.OpenMode.READ } else if flags & SSH_FXF_APPEND != 0 { os.OpenMode.APPEND }
            else if flags & SSH_FXF_TRUNC != 0 || there == .NOTHING { os.OpenMode.WRITE } else { os.OpenMode.READ_WRITE }
        if writing && there == .NOTHING && flags & SSH_FXF_CREAT == 0 {
            status(sftp, id, SSH_FX_NO_SUCH_FILE)
            return void
        }
        file :: os.open_in(sftp.home, text, mode) or_return status(sftp, id, if there == .NOTHING { SSH_FX_NO_SUCH_FILE } else { SSH_FX_PERMISSION_DENIED })
        handle^ = SftpHandle.{used = true, file = file, writing = writing}
    }
    for byte, i in path {
        if i < handle.path.count {
            handle.path[i] = byte
        }
    }
    handle.path_count = path.count
    writer := ssh.Writer.{}
    out :: sftp.message[0..<sftp.message.count]
    put_header(out, &writer, SSH_FXP_HANDLE)
    ssh.put_u32(out, &writer, id)
    number : u8[1]
    number[0] = cast[u8](0x30 + free)
    ssh.put_string(out, &writer, number[0..<1])
    send(sftp, out, &writer)
}

/** Read from a file's handle, from an offset: from where it is, or opened again and read on to it. */
read :: fn(sftp: ptr[mut Sftp], id: u32, handle: ptr[mut SftpHandle], offset: u64, wanted: usize) {
    if handle.directory || handle.writing {
        status(sftp, id, SSH_FX_FAILURE)
        return void
    }
    if offset < handle.position {
        os.close(handle.file)
        handle.file = os.open_in(sftp.home, string_of(&handle.path[0], handle.path_count), .READ) or_return status(sftp, id, SSH_FX_FAILURE)
        handle.position = 0
    }
    writer := ssh.Writer.{}
    out :: sftp.message[0..<sftp.message.count]
    put_header(out, &writer, SSH_FXP_DATA)
    ssh.put_u32(out, &writer, id)
    length_at :: ssh.start_string(out, &writer)
    data :: ssh.range_mut(out, writer.at, writer.at + wanted)
    got := cast[usize](0)
    loop {
        // What's before the offset read and passed over
        skipping :: handle.position < offset
        room :: if skipping { if offset - handle.position < cast[u64](data.count) { cast[usize](offset - handle.position) } else { data.count } }
            else { data.count - got }
        into :: if skipping { ssh.range_mut(data, 0, room) } else { ssh.range_mut(data, got, got + room) }
        count :: os.read(handle.file, into) or_else 0
        if count == 0 {
            break
        }
        handle.position += cast[u64](count)
        if !skipping {
            got += count
        }
    }
    while got < data.count
    if got == 0 {
        status(sftp, id, SSH_FX_EOF)
        return void
    }
    writer.at += got
    ssh.end_string(out, &writer, length_at)
    send(sftp, out, &writer)
}

/** Answer a READDIR with the next entries, or EOF. */
read_directory :: fn(sftp: ptr[mut Sftp], id: u32, handle: ptr[mut SftpHandle]) {
    if !handle.directory || handle.next >= handle.listing.count {
        status(sftp, id, SSH_FX_EOF)
        return void
    }
    writer := ssh.Writer.{}
    out :: sftp.message[0..<sftp.message.count]
    put_header(out, &writer, SSH_FXP_NAME)
    ssh.put_u32(out, &writer, id)
    count_at :: writer.at
    ssh.put_u32(out, &writer, 0)
    count := cast[u32](0)
    loop {
        if handle.next >= handle.listing.count || count >= SFTP_NAMES_AT_ONCE || writer.at + 1024 > out.count {
            break
        }
        entry :: handle.listing[handle.next]
        handle.next += 1
        name :: string_bytes(entry.name)
        size :: if entry.is_directory { cast[u64](0) } else { size_of_in(sftp, handle, name) }
        ssh.put_string(out, &writer, name)
        put_long_name(out, &writer, name, entry.is_directory, size)
        put_attrs(out, &writer, entry.is_directory, size)
        count += 1
    }
    while true
    for i in cast[usize](0)..<4 {
        ssh.set_byte(out, count_at + i, cast[u8](count >> (8 * (3 - i))))
    }
    send(sftp, out, &writer)
}

/** The size of a file in a listed directory. */
size_of_in :: fn(sftp: ptr[mut Sftp], handle: ptr[SftpHandle], name: u8[]) -> u64 {
    path : u8[SFTP_PATH_BYTES]
    at := cast[usize](0)
    for byte in ssh.range(handle.path[0..<SFTP_PATH_BYTES], 0, handle.path_count) {
        ssh.set_byte(path[0..<SFTP_PATH_BYTES], at, byte)
        at += 1
    }
    if at > 0 {
        ssh.set_byte(path[0..<SFTP_PATH_BYTES], at, 0x2f)
        at += 1
    }
    for byte in name {
        ssh.set_byte(path[0..<SFTP_PATH_BYTES], at, byte)
        at += 1
    }
    if at == 0 || at > path.count {
        return 0
    }
    return file_size_at(sftp, string_of(&path[0], at))
}

/** A file's size, by its path; 0 if it can't be read. */
file_size_at :: fn(sftp: ptr[mut Sftp], path: string) -> u64 {
    file :: os.open_in(sftp.home, path, .READ) or_return 0
    defer os.close(file)
    return os.file_size(file) or_else 0
}

/** Answer with a path's attributes, or NO_SUCH_FILE. */
attrs_answer :: fn(sftp: ptr[mut Sftp], id: u32, path: u8[]) {
    directory := path.count == 0
    size := cast[u64](0)
    if path.count > 0 {
        text :: string_of(&path[0], path.count)
        match os.path_kind_in(sftp.home, text) {
            case .NOTHING => {
                status(sftp, id, SSH_FX_NO_SUCH_FILE)
                return void
            }
            case .DIRECTORY => directory = true
            case .FILE => size = file_size_at(sftp, text)
        }
    }
    writer := ssh.Writer.{}
    out :: sftp.message[0..<sftp.message.count]
    put_header(out, &writer, SSH_FXP_ATTRS)
    ssh.put_u32(out, &writer, id)
    put_attrs(out, &writer, directory, size)
    send(sftp, out, &writer)
}

/** Answer with one name: a path, as REALPATH's answer, its attributes a directory's. */
name_answer :: fn(sftp: ptr[mut Sftp], id: u32, name: u8[], directory: bool, size: u64) {
    writer := ssh.Writer.{}
    out :: sftp.message[0..<sftp.message.count]
    put_header(out, &writer, SSH_FXP_NAME)
    ssh.put_u32(out, &writer, id)
    ssh.put_u32(out, &writer, 1)
    ssh.put_string(out, &writer, name)
    put_long_name(out, &writer, name, directory, size)
    put_attrs(out, &writer, directory, size)
    send(sftp, out, &writer)
}

/** Write attributes: a size and permissions, 0755 for a directory, 0644 for a file. */
put_attrs :: fn(out: mut u8[], writer: ptr[mut ssh.Writer], directory: bool, size: u64) {
    ssh.put_u32(out, writer, SSH_FILEXFER_ATTR_SIZE | SSH_FILEXFER_ATTR_PERMISSIONS)
    ssh.put_u32(out, writer, cast[u32](size >> 32))
    ssh.put_u32(out, writer, cast[u32](size))
    ssh.put_u32(out, writer, if directory { cast[u32](0o40755) } else { cast[u32](0o100644) })
}

/** Write ls -l's line for a name, which sftp's ls -l shows. */
put_long_name :: fn(out: mut u8[], writer: ptr[mut ssh.Writer], name: u8[], directory: bool, size: u64) {
    at :: ssh.start_string(out, writer)
    ssh.put_bytes(out, writer, string_bytes(if directory { "drwxr-xr-x    1 user     user     " } else { "-rw-r--r--    1 user     user     " }))
    digits : u8[20]
    count := cast[usize](0)
    left := size
    loop {
        ssh.set_byte(digits[0..<20], count, cast[u8](0x30 + left % 10))
        count += 1
        left /= 10
    }
    while left > 0 && count < 20
    if size == 0 {
        ssh.set_byte(digits[0..<20], 0, 0x30)
        count = 1
    }
    for i in cast[usize](0)..<count {
        ssh.put_u8(out, writer, ssh.byte_at(digits[0..<20], count - 1 - i))
    }
    ssh.put_bytes(out, writer, string_bytes(" Jan  1 00:00 "))
    ssh.put_bytes(out, writer, name)
    ssh.end_string(out, writer, at)
}

/** Answer with a status. */
status :: fn(sftp: ptr[mut Sftp], id: u32, code: u32) {
    writer := ssh.Writer.{}
    out :: sftp.message[0..<sftp.message.count]
    put_header(out, &writer, SSH_FXP_STATUS)
    ssh.put_u32(out, &writer, id)
    ssh.put_u32(out, &writer, code)
    ssh.put_text(out, &writer, if code == SSH_FX_OK { "OK" } else if code == SSH_FX_EOF { "end of file" } else if code == SSH_FX_NO_SUCH_FILE { "no such file" }
        else if code == SSH_FX_PERMISSION_DENIED { "not allowed" } else if code == SSH_FX_OP_UNSUPPORTED { "not supported" } else { "failed" })
    ssh.put_text(out, &writer, "en")
    send(sftp, out, &writer)
}

/** A status for what a file call gave. */
code_of :: fn(error: os.OsError?) -> u32 {
    match error {
        case None => return SSH_FX_OK
        case Some(failure) => return if failure == .NotFound { SSH_FX_NO_SUCH_FILE } else if failure == .AccessDenied { SSH_FX_PERMISSION_DENIED } else { SSH_FX_FAILURE }
    }
}

/** Start an answer: room for its length, then its type. */
put_header :: fn(out: mut u8[], writer: ptr[mut ssh.Writer], kind: u8) {
    ssh.put_u32(out, writer, 0)
    ssh.put_u8(out, writer, kind)
}

/** Send an answer: its length filled in, and added to the outbox. */
send :: fn(sftp: ptr[mut Sftp], out: mut u8[], writer: ptr[mut ssh.Writer]) {
    if writer.overflow || writer.at < 4 {
        return void
    }
    length :: writer.at - 4
    for i in cast[usize](0)..<4 {
        ssh.set_byte(out, i, cast[u8](length >> (8 * (3 - i))))
    }
    for byte in ssh.range(out, 0, writer.at) {
        if sftp.outbox_count < sftp.outbox.count {
            sftp.outbox[sftp.outbox_count] = byte
            sftp.outbox_count += 1
        }
    }
}

/** A handle's index, from its one byte. */
handle_index :: fn(handle: u8[]) -> usize? {
    if handle.count != 1 || handle[0] < 0x30 {
        return null
    }
    return cast[usize](handle[0] - 0x30)
}

/** Close a handle. */
close_handle :: fn(handle: ptr[mut SftpHandle]) {
    if handle.directory {
        os.free_directory_listing(handle.listing)
    }
    else {
        os.close(handle.file)
    }
    handle.used = false
}

/** Close every handle and the home, as the stream ends, and give the Sftp back. */
end_sftp :: fn(sftp: ptr[mut Sftp]) {
    for &handle in sftp.handles {
        if handle.used {
            close_handle(handle)
        }
    }
    os.close_directory(sftp.home)
    runtime.free(sftp)
}

/**
 * Make a client's path relative to the home: its parts, "." and empty ones left out, ".." taking the one before away,
 * never above the home.
 *
 * @param path The path, absolute from the home's "/" or relative to it.
 * @param into Where the path goes, its parts between '/'; empty for the home itself.
 * @return Its length; null if it's too long, or has a 0 byte.
 */
normalize :: fn(path: u8[], into: mut u8[]) -> usize? {
    count := cast[usize](0)
    start := cast[usize](0)
    for i in cast[usize](0)..<path.count + 1 {
        end_of_part :: i == path.count || ssh.byte_at(path, i) == 0x2f
        if i < path.count && ssh.byte_at(path, i) == 0 {
            return null
        }
        if !end_of_part {
            continue
        }
        part :: ssh.range(path, start, i)
        start = i + 1
        if part.count == 0 || ssh.is(part, ".") {
            continue
        }
        if ssh.is(part, "..") {
            // Back to the last '/', or the start
            loop {
                count -= 1
            }
            while count > 0 && ssh.byte_at(into, count - 1) != 0x2f
            if count > 0 {
                count -= 1
            }
            continue
        }
        if count > 0 {
            if count >= into.count {
                return null
            }
            ssh.set_byte(into, count, 0x2f)
            count += 1
        }
        for byte in part {
            if count >= into.count {
                return null
            }
            ssh.set_byte(into, count, byte)
            count += 1
        }
    }
    return count
}
