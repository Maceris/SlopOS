package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_file from "std/os/slop_os"

/*
 * Replace, transactions and change cursors on the system volume (decisions/0089): a file replaced whole while it's
 * open, the reader keeping the old contents; a transaction of two new files, which nothing sees before it commits;
 * one refused with Conflict once the file it wrote is changed outside it; one that fails partway through being
 * applied, leaving nothing of itself; and every change followed with a cursor.
 * Checks from 60.
 */

/** The size of the memory a transaction keeps its log in, given with Begin, in bytes. */
TRANSACTION_LOG_BYTES : u64 : 65536

/**
 * Check replacing, transactions and change cursors on the system volume.
 *
 * @param to The debug log; unused, as what's found is logged through runtime.
 * @param system The system volume's root.
 * @param buffer The buffer file connections read and write through.
 * @return 0 if all of it held; 60 if a port couldn't be made, 61 if the first cursor couldn't be had, 62 to 67 if
 *     replacing an open file failed or the reader didn't keep the old contents, 68 to 73 if the transaction of two new
 *     files failed or its files were seen before it committed, 74 to 77 if a conflicting transaction wasn't refused
 *     with Conflict or changed something, 81 to 85 if a transaction failing partway through left something of itself
 *     or the volume didn't go on after it, and 78 to 80 if following the changes failed or missed some. 60 to 67 are
 *     check_typed's numbers too, so they say which check failed only with the log.
 */
check_transactions :: fn(to: slop_os.DebugLog, system: os.Channel[dir.Dir], buffer: ptr[Buffer]) -> int {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, system.end) or_return 60
    into := os.Incoming.{}
    out := os.Outgoing.{}
    // The cursor to follow from: anything older resyncs
    cursor := cast[u64](0)
    out = os.Outgoing.{}
    asking :: os.begin[dir.Request](&out)
    asking^ = .Changes(0)
    match ask_dir(system.end, port, &out, &into) {
        case Resync(next) => cursor = next
        case _ => return 61
    }

    // Replaced whole, while a reader has the old one open
    if !write_file(system.end, port, "replace me.txt", .New, "the old contents", buffer) {
        return 62
    }
    old :: open_read_only(system.end, port, "replace me.txt", buffer) or_return 63
    defer slop_os.handle_close(cast[slop_os.Handle](old.end))
    old_port :: os.port_for(budget, old.end) or_return 63
    out = os.Outgoing.{}
    replacing :: os.begin[dir.Request](&out)
    replacing^ = .Replace(bytes_of(&out, "replace me.txt"))
    replacement := os.Channel[file.File].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(system.end, port, &out, &into) {
        case OpenedFile(made) => replacement = made
        case _ => return 64
    }
    if !write_through(replacement.end, "the new contents", buffer, true) {
        return 65
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](replacement.end))
    if !holds(system.end, port, "replace me.txt", "the new contents", buffer) {
        return 66
    }
    if !connection_holds(old.end, old_port, "the old contents", buffer) {
        return 67
    }

    // A transaction of two new files: not there until it commits, then both
    memory :: slop_os.memory_create(budget, TRANSACTION_LOG_BYTES) or_return 68
    out = os.Outgoing.{}
    beginning :: os.begin[dir.Request](&out)
    beginning^ = .Begin(memory)
    transaction := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(system.end, port, &out, &into) {
        case Began(made) => transaction = made
        case _ => return 69
    }
    defer slop_os.handle_close(cast[slop_os.Handle](transaction.end))
    transaction_port :: os.port_for(budget, transaction.end) or_return 69
    for name in string.["transacted one.txt", "transacted two.txt"] {
        if !write_file(transaction.end, transaction_port, name, .New, name, buffer) {
            return 70
        }
    }
    if open_read_only(system.end, port, "transacted one.txt", buffer) is_some {
        return 71
    }
    if !committed(transaction.end, transaction_port) {
        return 72
    }
    for name in string.["transacted one.txt", "transacted two.txt"] {
        if !holds(system.end, port, name, name, buffer) {
            return 73
        }
    }

    // A transaction that writes a file someone else changes meanwhile is refused, and changes nothing
    if !write_file(transaction.end, transaction_port, "transacted one.txt", .Existing, "from the transaction", buffer) {
        return 74
    }
    if !write_file(system.end, port, "transacted one.txt", .Truncate, "from outside", buffer) {
        return 75
    }
    out = os.Outgoing.{}
    committing :: os.begin[dir.Request](&out)
    committing^ = .Commit
    match ask_dir(transaction.end, transaction_port, &out, &into) {
        case Failed(error) => {
            if error != .Conflict {
                return 76
            }
        }
        case _ => return 76
    }
    if !holds(system.end, port, "transacted one.txt", "from outside", buffer) {
        return 77
    }

    // A transaction that fails partway through being applied leaves nothing of itself: its first file isn't there
    if !write_file(transaction.end, transaction_port, "half done.txt", .New, "never there", buffer) {
        return 81
    }
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(bytes_of(&out, "not there.txt"))
    match ask_dir(transaction.end, transaction_port, &out, &into) {
        case Done => {}
        case _ => return 82
    }
    out = os.Outgoing.{}
    failing :: os.begin[dir.Request](&out)
    failing^ = .Commit
    match ask_dir(transaction.end, transaction_port, &out, &into) {
        case Failed(error) => {
            if error != .NotFound {
                return 83
            }
        }
        case _ => return 83
    }
    if open_read_only(system.end, port, "half done.txt", buffer) is_some {
        return 84
    }
    // And the volume goes on: a file written and synced after it
    if !write_file(system.end, port, "after the undo.txt", .New, "after the undo", buffer) || !holds(system.end, port, "after the undo.txt", "after the undo", buffer) {
        return 85
    }

    // Everything since the cursor, followed to the end: the replacement and the transaction's two files among it
    followed := 0
    saw_replaced := false
    saw_created := 0
    loop {
        out = os.Outgoing.{}
        following :: os.begin[dir.Request](&out)
        following^ = .Changes(cursor)
        match ask_dir(system.end, port, &out, &into) {
            case Changed(change) => {
                followed += 1
                cursor = change.next
                name :: os.items(&into, change.name)
                if change.kind == .Replaced {
                    saw_replaced = true
                }
                if change.kind == .Created && name.count > 10 && name[0] == cast[u8]('t') {
                    saw_created += 1
                }
            }
            case UpToDate(next) => break
            case _ => return 78
        }
        if followed > 1000 {
            return 79
        }
    }
    if !saw_replaced || saw_created < 2 {
        return 80
    }
    runtime.log_info("on the system volume, replaced an open file, committed a transaction, was refused a conflicting one, had a failing one leave nothing, and followed every change")
    return 0
}

/**
 * Open a file through a dir connection, or a transaction's, write text as its whole contents, and sync it.
 *
 * @param end The directory, or a transaction, speaking dir.
 * @param port A port bound to end.
 * @param path The file's path beneath it.
 * @param creation Whether the file is made, must be there already, or is cut to nothing, as files.Creation says.
 * @param text The file's contents, at most TRANSFER_BYTES bytes.
 * @param buffer The buffer the file's server writes from; text is copied into it.
 * @return Whether it was opened, written, sized and synced; the file connection is closed either way.
 */
write_file :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, creation: files.Creation, text: string, buffer: ptr[Buffer]) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenFile(dir.OpenFile.{path = bytes_of(&out, path), creation = creation})
    opened := os.Channel[file.File].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(end, port, &out, &into) {
        case OpenedFile(made) => opened = made
        case _ => return false
    }
    defer slop_os.handle_close(cast[slop_os.Handle](opened.end))
    return write_through(opened.end, text, buffer, false)
}

/**
 * Write text as a file connection's whole contents: give it the buffer, write text, set its size to it, and sync it,
 * or install it, for a replacement.
 *
 * @param end The file connection, which stays open.
 * @param text The contents, at most TRANSFER_BYTES bytes.
 * @param buffer The buffer the file's server writes from; text is copied into it.
 * @param install Whether it's finished with Install, putting a replacement in its file's place, or with Sync.
 * @return Whether every request was done, and the write moved all of text.
 */
write_through :: fn(end: slop_os.Channel, text: string, buffer: ptr[Buffer], install: bool) -> bool {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, end) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    memory :: handed(buffer) or_return false
    window :: window_of(buffer)
    for character, i in text {
        if i < window.count {
            window[i] = cast[u8](character)
        }
    }
    last :: if install { file.Request.Install } else { file.Request.Sync }
    requests := file.Request.[.UseBuffer(memory), .Write(files.Transfer.{offset = 0, count = cast[u32](text.count), buffer_offset = 0}),
        .SetSize(cast[u64](text.count)), last]
    into := os.Incoming.{}
    for request in requests {
        out := os.Outgoing.{}
        made :: os.begin[file.Request](&out)
        made^ = request
        match ask_file(end, port, &out, &into) {
            case Done => {}
            case Transferred(count) => {
                if cast[usize](count) != text.count {
                    return false
                }
            }
            case _ => return false
        }
    }
    return true
}

/**
 * Open a file read-only through a dir connection; its buffer isn't given.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param path The file's path beneath the directory.
 * @param buffer Unused.
 * @return The connection, which the caller closes; null if the file isn't there, or couldn't be opened.
 */
open_read_only :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, buffer: ptr[Buffer]) -> os.Channel[read_only_file.ReadOnlyFile]? {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenReadOnlyFile(bytes_of(&out, path))
    match ask_dir(end, port, &out, &into) {
        case OpenedReadOnlyFile(made) => return made
        case _ => return null
    }
}

/**
 * Tell whether a file holds text, read through a connection of its own.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param path The file's path beneath the directory.
 * @param text What it should hold, exactly.
 * @param buffer The buffer the file's server reads into.
 * @return Whether it was read and holds text and nothing more.
 */
holds :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, text: string, buffer: ptr[Buffer]) -> bool {
    bytes : u8[..]
    defer runtime.array_free(&bytes)
    return read_whole(end, port, path, buffer, &bytes) && same_text(bytes, text)
}

/**
 * Tell whether a read-only file connection, open from before, holds text: one read of up to TRANSFER_BYTES.
 *
 * @param end The connection, which stays open.
 * @param port A port bound to end.
 * @param text What it should hold, exactly.
 * @param buffer The buffer the file's server reads into, a new handle to which it's given.
 * @return Whether it read text and nothing more.
 */
connection_holds :: fn(end: slop_os.Channel, port: slop_os.Port, text: string, buffer: ptr[Buffer]) -> bool {
    memory :: handed(buffer) or_return false
    into := os.Incoming.{}
    for request in read_only_file.Request.[.UseBuffer(memory), .Read(files.Transfer.{offset = 0, count = cast[u32](TRANSFER_BYTES), buffer_offset = 0})] {
        out := os.Outgoing.{}
        made :: os.begin[read_only_file.Request](&out)
        made^ = request
        match ask_read_only_file(end, port, &out, &into) {
            case Done => {}
            case Transferred(count) => {
                window :: window_of(buffer)
                if cast[usize](count) != text.count || cast[usize](count) > window.count {
                    return false
                }
                return same_text(window[0..<cast[usize](count)], text)
            }
            case _ => return false
        }
    }
    return false
}

/**
 * Tell whether bytes are a text's.
 *
 * @param bytes The bytes compared, as read back from a file; only read.
 * @param text The text they should be, compared byte for byte; only read.
 * @return Whether they're as long as each other, with the same bytes.
 */
same_text :: fn(bytes: u8[], text: string) -> bool {
    if bytes.count != text.count {
        return false
    }
    for character, i in text {
        if i < bytes.count && bytes[i] != cast[u8](character) {
            return false
        }
    }
    return true
}

/**
 * Commit a transaction.
 *
 * @param end The transaction, speaking dir.
 * @param port A port bound to end.
 * @return Whether it answered Done, committed.
 */
committed :: fn(end: slop_os.Channel, port: slop_os.Port) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    committing :: os.begin[dir.Request](&out)
    committing^ = .Commit
    match ask_dir(end, port, &out, &into) {
        case Done => return true
        case _ => return false
    }
}
