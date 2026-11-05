package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import testing from "std"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import test_kit from "../../test_kit"

/*
 * The system volume (decisions/0089): a SlopOS container's, served by a volume server through a container service.
 * The check reads a module from it and compares it with the copy on the EFI system partition, boot/modules, which the
 * test disk keeps beside the generation's objects; writes a file of its own, syncs it, which commits it, and reads it
 * back; and moves it into a directory it makes; and checks typed files.
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
 * Find the buffer the tests share for file connections, making it the first time.
 *
 * @param t The test's state, which a failure is recorded in if it can't be made.
 * @param given What main was given, whose buffer is made and kept, for every test after, if it wasn't.
 * @param location Where the test asked; the caller's own.
 * @return The buffer, in given, good while the tests run; Error(Failed), recorded, if memory or addresses
 *     couldn't be had for it, or it couldn't be mapped.
 */
buffer_of :: fn(t: ptr[mut testing.T], given: ptr[mut Given], location := #caller_location) -> Result[ptr[Buffer], testing.Stopped] {
    if !given.has_buffer {
        made :: new_buffer()
        given.buffer = testing.require_some(t, made, "the budget has room for a buffer for file connections, mapped here", location)?
        given.has_buffer = true
    }
    return .Ok(&given.buffer)
}

/**
 * Check the system volume: read a module and compare it with the EFI system partition's copy; write a file of its
 * own, sync it and read it back, logging how long making and syncing it took as a benchmark (decisions/0112); and move
 * it into a directory it makes and sync that.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the buffer or a port couldn't be made, the module couldn't be read, or the file
 *     couldn't be written, its directory made, or it moved.
 */
the_system_volume_reads_writes_and_moves_files #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    buffer :: buffer_of(t, given)?
    budget :: slop_os.startup_block().budget
    bound :: os.port_for(budget, system.end)
    system_port :: testing.require_some(t, bound, "the budget has room for a port")?
    from_volume : u8[..]
    defer runtime.array_free(&from_volume)
    testing.require(t, read_whole(system.end, system_port, MODULE_ON_VOLUME, buffer, &from_volume),
        "the image builder put hello's module on the system volume")?
    testing.require_ne(t, from_volume.count, 0, "hello's module isn't empty")?
    // The same bytes as the copy on the ESP
    match given.working_directory {
        case Some(partition) => {
            esp_bound :: os.port_for(budget, partition.end)
            esp_port :: testing.require_some(t, esp_bound, "the budget has room for a port")?
            from_esp : u8[..]
            defer runtime.array_free(&from_esp)
            testing.require(t, read_whole(partition.end, esp_port, MODULE_ON_ESP, buffer, &from_esp),
                "the test disk keeps the generation's modules on the EFI system partition too")?
            testing.expect_eq(t, from_esp.count, from_volume.count, "both copies of hello's module are the same size")
            differs : usize? = null
            for byte, i in from_esp {
                if (differs is_none) && i < from_volume.count && from_volume[i] != byte {
                    differs = i
                }
            }
            testing.expect_none(t, differs, "both copies of hello's module have the same bytes, the system volume's read whole through its server")
        }
        case None => {}
    }
    // A file of its own, written, synced and read back; how long making and syncing it took is a benchmark (decisions/0112)
    started :: slop_os.clock_monotonic() or_else 0
    testing.require(t, write_new(system.end, system_port, SYSTEM_FILE, SYSTEM_TEXT, buffer),
        "the system volume takes a new file, written and synced")?
    runtime.log_info("perf: file_create_sync %", (slop_os.clock_monotonic() or_else 0) - started)
    testing.expect(t, holds(system.end, system_port, SYSTEM_FILE, SYSTEM_TEXT, buffer), "the file reads back as written, once synced")
    // Moved into a directory it makes, and synced
    into := os.Incoming.{}
    out := os.Outgoing.{}
    making :: os.begin[dir.Request](&out)
    making^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "made by the guest"), create = true})
    match ask_dir(system.end, system_port, &out, &into) {
        case OpenedDirectory(made) => _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
        case _ => return stopped(t, "the system volume makes a directory when asked")
    }
    out = os.Outgoing.{}
    renaming :: os.begin[dir.Request](&out)
    renaming^ = .Rename(dir.Rename.{from = bytes_of(&out, SYSTEM_FILE), to = bytes_of(&out, "made by the guest/moved.txt")})
    match ask_dir(system.end, system_port, &out, &into) {
        case Done => {}
        case _ => return stopped(t, "a file moves into a directory beside it")
    }
    out = os.Outgoing.{}
    syncing :: os.begin[dir.Request](&out)
    syncing^ = .Sync
    match ask_dir(system.end, system_port, &out, &into) {
        case Done => {}
        case _ => testing.fail(t, "the system volume syncs the move, committing it")
    }
    return .Ok
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
 * @param t The test's state.
 * @return Ok once it's run; Error if a port or a second connection couldn't be made, or the note couldn't be written
 *     or read back.
 */
typed_files_keep_their_type #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    bound :: os.port_for(slop_os.startup_block().budget, system.end)
    port :: testing.require_some(t, bound, "the budget has room for a port")?
    connected :: second_connection(system, port)
    directory :: testing.require_some(t, connected, "the system volume takes a second connection to its root")?
    defer os.close_directory(directory)
    out := os.Outgoing.{}
    note :: os.begin[CheckedNote](&out)
    note.mark = 0x51ed
    note.kept = true
    note.text = os.append(&out, string_bytes(TYPED_TEXT))
    written :: os.write_typed_in[CheckedNote](directory, TYPED_FILE, os.value_bytes(&out))
    testing.require_none(t, written, "the system volume takes a typed file, its value a CheckedNote")?
    read_back :: os.read_typed_in[CheckedNote](directory, TYPED_FILE)
    back :: testing.require_ok(t, read_back, "a typed file reads back as its own type")?
    defer runtime.free_array(back)
    read :: os.typed_value[CheckedNote](back)
    text :: os.items_of(back, read.text)
    testing.expect_eq(t, read.mark, 0x51ed, "a typed file's value reads back as written")
    testing.expect(t, read.kept, "a typed file's value reads back as written")
    testing.expect(t, same_text(text, TYPED_TEXT), "a typed file's value's text reads back as written, inside it")
    // Of another type: refused, opened or read
    match os.open_typed_in[OtherNote](directory, TYPED_FILE, .READ) {
        case Ok(file) => {
            os.close(file)
            testing.fail(t, "a typed file isn't opened as another type")
        }
        case Error(error) => testing.expect_eq(t, error, OsError.WrongType, "a typed file isn't opened as another type")
    }
    // A value that isn't a CheckedNote isn't written as one: a bool that's 2
    bad := os.Outgoing.{}
    wrong :: os.begin[CheckedNote](&bad)
    wrong.mark = 1
    cast[ptr[mut u8]](&wrong.kept)^ = 2
    refused :: os.write_typed_in[CheckedNote](directory, "Not a note", os.value_bytes(&bad))
    wrong_type : OsError? = OsError.WrongType
    testing.expect_eq(t, refused, wrong_type, "a value that isn't a CheckedNote, a bool in it 2, isn't written as one")
    match given.working_directory {
        case Some(partition) => {
            esp_bound :: os.port_for(slop_os.startup_block().budget, partition.end)
            esp_port :: testing.require_some(t, esp_bound, "the budget has room for a port")?
            fat_connected :: second_connection(partition, esp_port)
            fat :: testing.require_some(t, fat_connected, "the EFI system partition takes a second connection to its root")?
            defer os.close_directory(fat)
            on_fat :: os.write_typed_in[CheckedNote](fat, "A typed note.bin", os.value_bytes(&out))
            testing.expect_eq(t, on_fat, wrong_type, "FAT keeps no types, so it takes no typed file")
        }
        case None => {}
    }
    return .Ok
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
