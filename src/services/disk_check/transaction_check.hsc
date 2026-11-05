package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import testing from "std"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import test_kit from "../../test_kit"

/*
 * Replace, transactions and change cursors on the system volume (decisions/0089): a file replaced whole while it's
 * open, the reader keeping the old contents; a transaction of two new files, which nothing sees before it commits;
 * one refused with Conflict once the file it wrote is changed outside it; one that fails partway through being
 * applied, leaving nothing of itself; and every change followed with a cursor.
 */

/** The size of the memory a transaction keeps its log in, given with Begin, in bytes. */
TRANSACTION_LOG_BYTES : u64 : 65536

/**
 * Check replacing, transactions and change cursors on the system volume.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the buffer, a port or the first cursor couldn't be had, or a step the rest builds
 *     on failed: writing or replacing a file, beginning, writing in or committing a transaction.
 */
transactions_replace_commit_conflict_and_undo #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    buffer :: buffer_of(t, given)?
    budget :: slop_os.startup_block().budget
    bound :: os.port_for(budget, system.end)
    port :: testing.require_some(t, bound, "the budget has room for a port")?
    into := os.Incoming.{}
    out := os.Outgoing.{}
    // The cursor to follow from: anything older resyncs
    cursor := cast[u64](0)
    out = os.Outgoing.{}
    asking :: os.begin[dir.Request](&out)
    asking^ = .Changes(0)
    match ask_dir(system.end, port, &out, &into) {
        case Resync(next) => cursor = next
        case _ => return stopped(t, "asked for changes since cursor 0, older than the volume keeps, the volume says to resync from now")
    }

    // Replaced whole, while a reader has the old one open
    testing.require(t, write_file(system.end, port, "replace me.txt", .New, "the old contents", buffer),
        "the system volume takes a new file, written and synced")?
    opened_old :: open_read_only(system.end, port, "replace me.txt", buffer)
    old :: testing.require_some(t, opened_old, "a file just written opens to read")?
    defer slop_os.handle_close(cast[slop_os.Handle](old.end))
    old_bound :: os.port_for(budget, old.end)
    old_port :: testing.require_some(t, old_bound, "the budget has room for a port")?
    out = os.Outgoing.{}
    replacing :: os.begin[dir.Request](&out)
    replacing^ = .Replace(bytes_of(&out, "replace me.txt"))
    replacement := os.Channel[file.File].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(system.end, port, &out, &into) {
        case OpenedFile(made) => replacement = made
        case _ => return stopped(t, "a file that's there, open or not, can be replaced: a new file to install in its place")
    }
    testing.require(t, write_through(replacement.end, "the new contents", buffer, true), "a replacement is written and installed")?
    _ = slop_os.handle_close(cast[slop_os.Handle](replacement.end))
    testing.expect(t, holds(system.end, port, "replace me.txt", "the new contents", buffer), "a file installed in another's place is what its path opens")
    testing.expect(t, connection_holds(old.end, old_port, "the old contents", buffer),
        "a reader that had the file open before it was replaced keeps reading the old contents")

    // A transaction of two new files: not there until it commits, then both
    created :: slop_os.memory_create(budget, TRANSACTION_LOG_BYTES)
    memory :: testing.require_ok(t, created, "the budget has room for a transaction's log")?
    out = os.Outgoing.{}
    beginning :: os.begin[dir.Request](&out)
    beginning^ = .Begin(memory)
    transaction := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(system.end, port, &out, &into) {
        case Began(made) => transaction = made
        case _ => return stopped(t, "the system volume begins a transaction, given memory for its log")
    }
    defer slop_os.handle_close(cast[slop_os.Handle](transaction.end))
    transaction_bound :: os.port_for(budget, transaction.end)
    transaction_port :: testing.require_some(t, transaction_bound, "the budget has room for a port")?
    for name in string.["transacted one.txt", "transacted two.txt"] {
        testing.require(t, write_file(transaction.end, transaction_port, name, .New, name, buffer), "a transaction takes new files")?
    }
    early :: open_read_only(system.end, port, "transacted one.txt", buffer)
    testing.expect(t, early is_none, "nothing a transaction writes is seen outside it before it commits")
    testing.require(t, committed(transaction.end, transaction_port), "a transaction nothing else touched commits")?
    for name in string.["transacted one.txt", "transacted two.txt"] {
        testing.expect(t, holds(system.end, port, name, name, buffer), "every file a transaction wrote is there once it commits")
    }

    // A transaction that writes a file someone else changes meanwhile is refused, and changes nothing
    testing.require(t, write_file(transaction.end, transaction_port, "transacted one.txt", .Existing, "from the transaction", buffer),
        "a transaction, committed, goes on, writing a file it made")?
    testing.require(t, write_file(system.end, port, "transacted one.txt", .Truncate, "from outside", buffer),
        "the same file is written outside the transaction meanwhile")?
    out = os.Outgoing.{}
    committing :: os.begin[dir.Request](&out)
    committing^ = .Commit
    match ask_dir(transaction.end, transaction_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .Conflict, "a transaction whose file was changed outside it since it read it is refused")
        case _ => testing.fail(t, "a transaction whose file was changed outside it since it read it is refused")
    }
    testing.expect(t, holds(system.end, port, "transacted one.txt", "from outside", buffer), "a transaction refused changes nothing")

    // A transaction that fails partway through being applied leaves nothing of itself: its first file isn't there
    testing.require(t, write_file(transaction.end, transaction_port, "half done.txt", .New, "never there", buffer),
        "a transaction, refused, goes on, taking a new file")?
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(bytes_of(&out, "not there.txt"))
    match ask_dir(transaction.end, transaction_port, &out, &into) {
        case Done => {}
        case _ => return stopped(t, "a transaction takes a removal, checked only as it's applied")
    }
    out = os.Outgoing.{}
    failing :: os.begin[dir.Request](&out)
    failing^ = .Commit
    match ask_dir(transaction.end, transaction_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .NotFound, "a transaction removing a file that isn't there fails as it's applied")
        case _ => testing.fail(t, "a transaction removing a file that isn't there fails as it's applied")
    }
    half :: open_read_only(system.end, port, "half done.txt", buffer)
    testing.expect(t, half is_none, "a transaction that failed partway through being applied leaves nothing of itself")
    // And the volume goes on: a file written and synced after it
    testing.expect(t, write_file(system.end, port, "after the undo.txt", .New, "after the undo", buffer)
        && holds(system.end, port, "after the undo.txt", "after the undo", buffer), "the volume goes on after a transaction is undone")

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
            case _ => return stopped(t, "a cursor the volume gave is followed, change by change, to the end")
        }
        if followed > 1000 {
            return stopped(t, "the changes since the first cursor come to an end, the check having made a few dozen")
        }
    }
    testing.expect(t, saw_replaced, "following the changes finds the file replaced")
    testing.expect(t, saw_created >= 2, "following the changes finds both files the transaction made")
    return .Ok
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
