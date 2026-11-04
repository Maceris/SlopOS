package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"

/*
 * The system volume (decisions/0089): a SlopOS container's, served by a volume server through a container service.
 * The check reads a module from it and compares it with the copy on the EFI system partition, boot/modules, which the
 * test disk keeps beside the generation's objects; writes a file of its own, syncs it, which commits it, and reads it
 * back; and moves it into a directory it makes. Checks from 40.
 */

/** The module the check reads from the system volume, relative to its root. */
MODULE_ON_VOLUME :: "modules/hello.elf"
/** The same module's copy on the EFI system partition, which should hold the same bytes. */
MODULE_ON_ESP :: "boot/modules/hello.elf"
/** The file the check writes in the system volume's root, then moves into "made by the guest". */
SYSTEM_FILE :: "Written to the system volume.txt"
/** What the check writes in SYSTEM_FILE. */
SYSTEM_TEXT :: "Written to the system volume by the guest, and synced"
/** The size of the buffer file connections read and write through, in bytes: the most moved by one request. */
TRANSFER_BYTES : u64 : 65536
/** The most of a file read whole, in bytes; reading stops once past it, with what's been read. */
MAX_FILE_BYTES : usize : 1 << 20

/** A buffer for file connections: a memory object mapped here, given to each server as a handle of its own. */
Buffer :: struct {
    /** The memory object, TRANSFER_BYTES long, paid for from the process's budget; the check's own. */
    memory : slop_os.Memory,
    /** Where memory is mapped, readable and writable, in the process's address space. */
    address : u64,
}

/**
 * Make a buffer for file connections, mapped here.
 *
 * @return The buffer, which the caller unmaps and closes when it's done with it, if it is before the process ends;
 *     null if memory or addresses couldn't be had, or it couldn't be mapped.
 */
new_buffer :: fn() -> Buffer? {
    startup :: slop_os.startup_block()
    memory :: slop_os.memory_create(startup.budget, TRANSFER_BYTES) or_return null
    address :: runtime.reserve_addresses(cast[usize](TRANSFER_BYTES)) or_return null
    protection :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    match slop_os.memory_map(memory, startup.space, address, 0, TRANSFER_BYTES, protection) {
        case Ok => return Buffer.{memory = memory, address = address}
        case Error(error) => return null
    }
}

/**
 * Make a handle to the buffer for a file's server, which maps it to read into or write from.
 *
 * @param buffer The check's buffer, kept by it: its memory handle stays open, and the duplicate is a new handle to the
 *     same memory.
 * @return A new handle to its memory, to read, write and transfer, which the caller sends, moving it; null if it
 *     couldn't be duplicated.
 */
handed :: fn(buffer: ptr[Buffer]) -> slop_os.Memory? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](buffer.memory), rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

/**
 * Give the buffer's bytes, as mapped here.
 *
 * @param buffer The check's buffer, mapped at its address, readable and writable.
 * @return Its TRANSFER_BYTES bytes, a view good while it's mapped.
 */
window_of :: fn(buffer: ptr[Buffer]) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](buffer.address), cast[usize](TRANSFER_BYTES))
}

/**
 * Check the system volume: read a module and compare it with the EFI system partition's copy; write a file of its
 * own, sync it and read it back, logging how long making and syncing it took as a benchmark (decisions/0112); move
 * it into a directory it makes and sync that; then check typed files and transactions.
 *
 * @param to The debug log, passed on to the transactions' check.
 * @param system The system volume's root.
 * @param esp The EFI system partition's root, to compare the module with; without it, the module isn't compared.
 * @return 0 if all of it held; 40 if the buffer couldn't be made, 41 if a port couldn't be, 42 if the module couldn't
 *     be read or is empty, 43 to 45 if the ESP's copy couldn't be read or differs, 46 if the file couldn't be written
 *     and synced, 47 if it didn't read back as written, 48 if the directory couldn't be made, 49 if the move failed,
 *     50 if the sync failed; and check_typed's, then check_transactions', numbers.
 */
check_system :: fn(to: slop_os.DebugLog, system: os.Channel[dir.Dir], esp: os.Channel[dir.Dir]?) -> int {
    buffer := new_buffer() or_return 40
    budget :: slop_os.startup_block().budget
    system_port :: os.port_for(budget, system.end) or_return 41
    from_volume : u8[..]
    defer runtime.array_free(&from_volume)
    if !read_whole(system.end, system_port, MODULE_ON_VOLUME, &buffer, &from_volume) || from_volume.count == 0 {
        return 42
    }
    // The same bytes as the copy on the ESP
    match esp {
        case Some(partition) => {
            esp_port :: os.port_for(budget, partition.end) or_return 43
            from_esp : u8[..]
            defer runtime.array_free(&from_esp)
            if !read_whole(partition.end, esp_port, MODULE_ON_ESP, &buffer, &from_esp) {
                return 44
            }
            if from_esp.count != from_volume.count {
                return 45
            }
            for byte, i in from_esp {
                if i < from_volume.count && from_volume[i] != byte {
                    return 45
                }
            }
        }
        case None => {}
    }
    // A file of its own, written, synced and read back; how long making and syncing it took is a benchmark (decisions/0112)
    started :: slop_os.clock_monotonic() or_else 0
    if !write_new(system.end, system_port, SYSTEM_FILE, SYSTEM_TEXT, &buffer) {
        return 46
    }
    runtime.log_info("perf: file_create_sync %", (slop_os.clock_monotonic() or_else 0) - started)
    back : u8[..]
    defer runtime.array_free(&back)
    if !read_whole(system.end, system_port, SYSTEM_FILE, &buffer, &back) || back.count != SYSTEM_TEXT.count {
        return 47
    }
    for character, i in SYSTEM_TEXT {
        if i < back.count && back[i] != cast[u8](character) {
            return 47
        }
    }
    // Moved into a directory it makes, and synced
    into := os.Incoming.{}
    out := os.Outgoing.{}
    making :: os.begin[dir.Request](&out)
    making^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "made by the guest"), create = true})
    match ask_dir(system.end, system_port, &out, &into) {
        case OpenedDirectory(made) => _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
        case _ => return 48
    }
    out = os.Outgoing.{}
    renaming :: os.begin[dir.Request](&out)
    renaming^ = .Rename(dir.Rename.{from = bytes_of(&out, SYSTEM_FILE), to = bytes_of(&out, "made by the guest/moved.txt")})
    match ask_dir(system.end, system_port, &out, &into) {
        case Done => {}
        case _ => return 49
    }
    out = os.Outgoing.{}
    syncing :: os.begin[dir.Request](&out)
    syncing^ = .Sync
    match ask_dir(system.end, system_port, &out, &into) {
        case Done => {}
        case _ => return 50
    }
    runtime.log_info("on the system volume, read % as the EFI system partition has it, wrote, synced and read back its own file, and moved it",
        MODULE_ON_VOLUME)
    typed :: check_typed(system, system_port, esp)
    if typed != 0 {
        return typed
    }
    return check_transactions(to, system, &buffer)
}

/** A typed file's value (decisions/0046, 0108), as the system check writes it and reads it back. */
CheckedNote :: struct {
    /** A number the check writes, 0x51ed, and expects back. */
    mark : u32,
    /** True as written; a bool that's 2 makes a value that isn't a CheckedNote. */
    kept : bool,
    /** TYPED_TEXT's bytes. */
    text : slop_os.Relative[u8],
}

/** Another type, which the note's file isn't, so opening the file as one is refused. */
OtherNote :: struct {
    /** A field, so the type's schema differs from CheckedNote's. */
    mark : u64,
}

/** The typed file the check writes in the system volume's root. */
TYPED_FILE :: "A typed note"
/** The text in the note the check writes. */
TYPED_TEXT :: "kept with its type"

/**
 * Check typed files: on the system volume, one written as a CheckedNote, read back checked, and refused as an
 * OtherNote, and a value that isn't a CheckedNote refused; and on the EFI system partition, whose FAT keeps no types,
 * a typed file refused.
 *
 * @param system The system volume's root, which a second connection is made to.
 * @param port A port bound to system's end.
 * @param esp The EFI system partition's root; without it, that part isn't checked.
 * @return 0 if all of it held; 60 if a second connection couldn't be made, 61 if the note couldn't be written, 62 if
 *     it couldn't be read back, 63 if it read back wrong, 64 if opening it as an OtherNote wasn't refused as
 *     WrongType, 65 if a value that isn't a note wasn't refused as WrongType, 66 if the ESP couldn't be connected to,
 *     and 67 if a typed file on it wasn't refused as WrongType.
 */
check_typed :: fn(system: os.Channel[dir.Dir], port: slop_os.Port, esp: os.Channel[dir.Dir]?) -> int {
    directory :: second_connection(system, port) or_return 60
    defer os.close_directory(directory)
    out := os.Outgoing.{}
    note :: os.begin[CheckedNote](&out)
    note.mark = 0x51ed
    note.kept = true
    note.text = os.append(&out, string_bytes(TYPED_TEXT))
    if os.write_typed_in[CheckedNote](directory, TYPED_FILE, os.value_bytes(&out)) != null {
        return 61
    }
    back :: os.read_typed_in[CheckedNote](directory, TYPED_FILE) or_return 62
    defer runtime.free_array(back)
    read :: os.typed_value[CheckedNote](back)
    text :: os.items_of(back, read.text)
    if read.mark != 0x51ed || !read.kept || text.count != TYPED_TEXT.count {
        return 63
    }
    for byte, i in text {
        if i < TYPED_TEXT.count && byte != cast[u8](TYPED_TEXT[i]) {
            return 63
        }
    }
    // Of another type: refused, opened or read
    match os.open_typed_in[OtherNote](directory, TYPED_FILE, .READ) {
        case Ok(file) => {
            os.close(file)
            return 64
        }
        case Error(error) => {
            if error != .WrongType {
                return 64
            }
        }
    }
    // A value that isn't a CheckedNote isn't written as one: a bool that's 2
    bad := os.Outgoing.{}
    wrong :: os.begin[CheckedNote](&bad)
    wrong.mark = 1
    cast[ptr[mut u8]](&wrong.kept)^ = 2
    if os.write_typed_in[CheckedNote](directory, "Not a note", os.value_bytes(&bad)) != OsError.WrongType {
        return 65
    }
    match esp {
        case Some(partition) => {
            esp_port :: os.port_for(slop_os.startup_block().budget, partition.end) or_return 66
            fat :: second_connection(partition, esp_port) or_return 66
            defer os.close_directory(fat)
            if os.write_typed_in[CheckedNote](fat, "A typed note.bin", os.value_bytes(&out)) != OsError.WrongType {
                return 67
            }
        }
        case None => {}
    }
    runtime.log_info("a typed file written, read back checked, and refused as another type; a value that isn't one refused")
    return 0
}

/**
 * Make another connection to a directory, sending Connect on it, and open it as an os.Directory; Connect's answer,
 * if there is one, isn't waited for.
 *
 * @param directory The directory, which stays open.
 * @param port A port bound to directory's end.
 * @return The new connection, as a Directory, which the caller closes with os.close_directory; null if a channel or
 *     its port couldn't be made, or Connect couldn't be sent.
 */
second_connection :: fn(directory: os.Channel[dir.Dir], port: slop_os.Port) -> os.Directory? {
    budget :: slop_os.startup_block().budget
    pair :: os.channel_for[dir.Dir](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .Connect(os.Channel[dir.Dir].{end = pair.a})
    if dir.send_request(directory.end, port, &out) is_some {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    made, error :: os.directory_on(pair.b)
    if error != null {
        return null
    }
    return made
}

/**
 * Read a file beneath a directory whole, through a read_only_file connection, closed afterwards.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param path The file's path beneath the directory.
 * @param buffer The buffer the file's server reads into.
 * @param bytes What's read is added to, from the context's allocator, which the caller frees.
 * @return Whether it was read, up to MAX_FILE_BYTES and a transfer past them; false if it couldn't be opened or read,
 *     what's read so far left in bytes.
 */
read_whole :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, buffer: ptr[Buffer], bytes: ptr[mut u8[..]]) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenReadOnlyFile(bytes_of(&out, path))
    match ask_dir(end, port, &out, &into) {
        case OpenedReadOnlyFile(made) => return read_file_whole(made, buffer, bytes)
        case _ => return false
    }
}

/**
 * Read a file beneath a read-only directory whole, through a read_only_file connection, closed afterwards.
 *
 * @param end The directory, speaking read_only_dir.
 * @param port A port bound to end.
 * @param path The file's path beneath the directory.
 * @param buffer The buffer the file's server reads into.
 * @param bytes What's read is added to, from the context's allocator, which the caller frees.
 * @return Whether it was read, up to MAX_FILE_BYTES and a transfer past them; false if it couldn't be opened or read,
 *     what's read so far left in bytes.
 */
read_whole_read_only :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, buffer: ptr[Buffer], bytes: ptr[mut u8[..]]) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[read_only_dir.Request](&out)
    opening^ = .OpenReadOnlyFile(bytes_of(&out, path))
    match ask_read_only_dir(end, port, &out, &into) {
        case OpenedReadOnlyFile(made) => return read_file_whole(made, buffer, bytes)
        case _ => return false
    }
}

/**
 * Read a read_only_file connection's file whole, a transfer of up to TRANSFER_BYTES at a time, and close the
 * connection.
 *
 * @param opened The connection, which is closed here whatever happens.
 * @param buffer The buffer the file's server reads into, a new handle to which it's given.
 * @param bytes What's read is added to, from the context's allocator, which the caller frees.
 * @return Whether it was read: true once a transfer is short, or bytes is past MAX_FILE_BYTES; false if a port, the
 *     buffer's handle, or a read failed.
 */
read_file_whole :: fn(opened: os.Channel[read_only_file.ReadOnlyFile], buffer: ptr[Buffer], bytes: ptr[mut u8[..]]) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    defer slop_os.handle_close(cast[slop_os.Handle](opened.end))
    budget :: slop_os.startup_block().budget
    file_port :: os.port_for(budget, opened.end) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](file_port))
    memory :: handed(buffer) or_return false
    out = os.Outgoing.{}
    giving :: os.begin[read_only_file.Request](&out)
    giving^ = .UseBuffer(memory)
    match ask_read_only_file(opened.end, file_port, &out, &into) {
        case Done => {}
        case _ => return false
    }
    offset : u64 = 0
    loop {
        out = os.Outgoing.{}
        reading :: os.begin[read_only_file.Request](&out)
        reading^ = .Read(files.Transfer.{offset = offset, count = cast[u32](TRANSFER_BYTES), buffer_offset = 0})
        count := cast[u32](0)
        match ask_read_only_file(opened.end, file_port, &out, &into) {
            case Transferred(moved) => count = moved
            case _ => return false
        }
        window :: window_of(buffer)
        if runtime.array_try_reserve(bytes, bytes.count + cast[usize](count)) != null {
            return false
        }
        for i in 0..<cast[usize](count) {
            if i < window.count {
                runtime.array_add(bytes, window[i])
            }
        }
        offset += cast[u64](count)
        if cast[u64](count) < TRANSFER_BYTES || bytes.count > MAX_FILE_BYTES {
            return true
        }
    }
}

/**
 * Write a new file beneath a directory holding text, through a file connection, and sync it, which commits it.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param path The file's path beneath the directory; a file there already is a failure.
 * @param text The file's bytes, at most TRANSFER_BYTES of them.
 * @param buffer The buffer the file's server writes from; text is copied into it.
 * @return Whether it was made, written whole and synced.
 */
write_new :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, text: string, buffer: ptr[Buffer]) -> bool {
    return write_new_bytes(end, port, path, text, text.count, buffer)
}

/**
 * Write a new file beneath a directory, from the buffer, through a file connection, and sync it, which commits it.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param path The file's path beneath the directory; a file there already is a failure.
 * @param text What's copied to the buffer's start first; the rest of the buffer is as the caller left it.
 * @param count How many of the buffer's bytes the file holds, at most TRANSFER_BYTES.
 * @param buffer The buffer the file's server writes from.
 * @return Whether it was made, count bytes written, and synced; the file connection is closed either way.
 */
write_new_bytes :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, text: string, count: usize, buffer: ptr[Buffer]) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenFile(dir.OpenFile.{path = bytes_of(&out, path), creation = .New})
    opened := os.Channel[file.File].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(end, port, &out, &into) {
        case OpenedFile(made) => opened = made
        case _ => return false
    }
    defer slop_os.handle_close(cast[slop_os.Handle](opened.end))
    budget :: slop_os.startup_block().budget
    file_port :: os.port_for(budget, opened.end) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](file_port))
    memory :: handed(buffer) or_return false
    window :: window_of(buffer)
    for character, i in text {
        if i < window.count {
            window[i] = cast[u8](character)
        }
    }
    requests := file.Request.[.UseBuffer(memory), .Write(files.Transfer.{offset = 0, count = cast[u32](count), buffer_offset = 0}), .Sync]
    for request in requests {
        out = os.Outgoing.{}
        made :: os.begin[file.Request](&out)
        made^ = request
        match ask_file(opened.end, file_port, &out, &into) {
            case Done => {}
            case Transferred(moved) => {
                if cast[usize](moved) != count {
                    return false
                }
            }
            case _ => return false
        }
    }
    return true
}

/**
 * Send one request on a read_only_file connection, and wait for its answer.
 *
 * @param end The read_only_file connection, kept by the caller and not closed.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a copy; Unsupported if it couldn't be sent or the connection failed.
 */
ask_read_only_file :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_file.Response {
    if read_only_file.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_file.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_file.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/**
 * Send one request on a file connection, and wait for its answer.
 *
 * @param end The file connection, kept by the caller and not closed.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a copy; Unsupported if it couldn't be sent or the connection failed.
 */
ask_file :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> file.Response {
    if file.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match file.receive_response(end, port, into, true) {
            case Received => return os.message_of[file.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}
