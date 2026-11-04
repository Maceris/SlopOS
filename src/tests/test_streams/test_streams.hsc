/**
 * test_streams (decisions/0164): typed streams between programs. Launched by the root task, it launches a copy of
 * itself with the writing ends of two streams, a Sink[Item] and a Sink[u8], and reads them: the copy writes COUNT
 * records, more than the ring holds at once, so the ring wraps and the writer waits for the reader to make room, and
 * BYTE_CHUNKS chunks of bytes; then ends both with status 0. Each record is checked, the bytes counted, and the
 * writer's status read.
 */
package test_streams

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import stream from "std/os/slop_os"
import memory from "std"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_streams"
/** The copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 << 20
/** The key the copy's watch queues its end under. */
WATCH_KEY : u64 : 1
/** How many records the copy writes: more than the ring holds at once, so it wraps and the writer waits. */
COUNT : u64 : 3000
/** How many chunks of bytes the copy writes. */
BYTE_CHUNKS : u64 : 100
/** Each chunk of bytes the copy writes: 3 bytes. */
CHUNK :: "abc"

/** A record the copy writes and the test reads. */
Item :: struct {
    /** The record's index, from 0 in the order written. */
    index : u64,
    /** "record", every time, so each record has a value on the heap to copy. */
    name : string,
    /** Whether index is even. */
    even : bool,
}

/** What the copy is launched with, as main takes it. */
CopyGrants :: struct {
    /** A copy of the test's debug log, writable. */
    log : slop_os.DebugLog,
    /** Not given. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Not given. */
    program : slop_os.Memory?,
    /** The writing end of the records' stream, which makes main run as the copy. */
    output : os.Sink[Item]?,
    /** The writing end of the bytes' stream. */
    bytes : os.Sink[u8]?,
}

/**
 * Check typed streams between programs: read records and bytes a copy writes; or, run as the copy, write them.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param manager The process manager, which launches the copy; without it the test ends with 101.
 * @param program The test's own module, which the copy is launched from; without it the test ends with 100.
 * @param output Given only to the copy: where its records go. With it, this runs as the copy.
 * @param bytes Given only to the copy: where its bytes go. The copy without it ends with 4.
 * @return 0 if every check passed. Otherwise the first that failed: 1 if other than COUNT records were read, 2 if
 *     any was wrong, or 3 the writer's status wasn't 0; 4 if other than BYTE_CHUNKS chunks' bytes were read; 5 if the
 *     copy didn't end with 0, or 6 its budget didn't come back to nothing. 102 to 109 if setting up failed: 102 and
 *     103 the ports, 104 the streams, 105 the log's copy, 106 launching the copy, 107 the arena, 108 and 109 opening
 *     the streams. As the copy, what write_copy gives.
 */
main :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, output: os.Sink[Item]?,
    bytes: os.Sink[u8]?) -> int {
    match output {
        case Some(sink) => return write_copy(sink, bytes)
        case None => {}
    }
    block :: slop_os.startup_block()
    executable :: program or_return 100
    loader :: manager or_return 101
    manager_port :: os.port_for(block.budget, loader.end) or_return 102
    port :: slop_os.port_create(block.budget) or_return 103
    items :: stream.pair[Item](block.budget) or_return 104
    chunks :: stream.pair[u8](block.budget) or_return 104
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy_log :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), rights) or_return 105)
    launched :: os.launch(loader, manager_port, "test_streams copy", executable, COPY_BUDGET, main,
        CopyGrants.{log = copy_log, output = items.sink, bytes = chunks.sink},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}) or_return 106

    results : u64[6]
    // The records, each checked, read through an arena reset as it goes
    arena :: memory.make_arena() or_return 107
    defer memory.free_arena(arena)
    reader := stream.reader_on(items.stream) or_return 108
    read := cast[u64](0)
    right := cast[u64](0)
    push_context reading (allocator = memory.arena_allocator(arena)) {
        loop {
            item :: stream.next(&reader) or_break
            if item.index == read && item.name == "record" && item.even == (read % 2 == 0) {
                right += 1
            }
            read += 1
            if read % 256 == 0 {
                memory.reset_arena(arena)
            }
        }
    }
    results[0] = read
    results[1] = right
    results[2] = cast[u64](reader.status)
    stream.close_reader(&reader)
    // The bytes, counted
    byte_reader := stream.reader_on(chunks.stream) or_return 109
    total := cast[u64](0)
    loop {
        chunk :: stream.next_bytes(&byte_reader) or_break
        total += cast[u64](chunk.count)
    }
    results[3] = total
    stream.close_reader(&byte_reader)
    results[4] = ended_with(port)
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    results[5] = if test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    failed :: test_kit.check(log, NAME, results, u64.[COUNT, COUNT, 0, BYTE_CHUNKS * 3, 0, 1])
    if failed == 0 {
        log_line.write(log, "%: read % records and % bytes from a copy through two streams, more than the ring holds at once", NAME, COUNT,
            BYTE_CHUNKS * 3)
    }
    return failed
}

/**
 * Write the records and the bytes, as the copy, and end both streams with 0.
 *
 * @param sink The records' stream's writing end.
 * @param bytes The bytes' stream's writing end; null makes the copy end with 4 once the records are written.
 * @return 0 once both are written and ended. 10 plus the error's tag if the records' writer couldn't be made, 20
 *     plus it if a record couldn't be written, 3 if the records' stream couldn't be ended; 4 without bytes, 5 if the
 *     bytes' writer couldn't be made, 6 if a chunk couldn't be written, 7 if the bytes' stream couldn't be ended.
 */
write_copy :: fn(sink: os.Sink[Item], bytes: os.Sink[u8]?) -> int {
    writer := match stream.writer_on(sink) {
        case Ok(made) => made
        case Error(error) => return 10 + cast[int](error)
    }
    for i in cast[u64](0)..<COUNT {
        match stream.write(&writer, Item.{index = i, name = "record", even = i % 2 == 0}) {
            case Some(error) => return 20 + cast[int](error)
            case None => {}
        }
    }
    if stream.finish(&writer, 0) is_some {
        return 3
    }
    byte_sink :: bytes or_return 4
    byte_writer := stream.writer_on(byte_sink) or_return 5
    for i in cast[u64](0)..<BYTE_CHUNKS {
        if stream.write_bytes(&byte_writer, string_bytes(CHUNK)) is_some {
            return 6
        }
    }
    if stream.finish(&byte_writer, 0) is_some {
        return 7
    }
    return 0
}

/**
 * Wait for a watched process to end, and tell how.
 *
 * @param port The port its watch, for SIGNAL_TERMINATED, queues on; nothing else may be bound to it.
 * @return The process's exit code, or 0xffff if the wait failed.
 */
ended_with :: fn(port: slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
