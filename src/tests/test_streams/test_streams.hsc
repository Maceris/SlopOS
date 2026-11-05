/**
 * test_streams (decisions/0164): typed streams between programs. Launched by the root task, it launches a copy of
 * itself with the writing ends of two streams, a Sink[Item] and a Sink[u8], and reads them: the copy writes COUNT
 * records, more than the ring holds at once, so the ring wraps and the writer waits for the reader to make room, and
 * BYTE_CHUNKS chunks of bytes; then ends both with status 0, the copy running the same test to write them and
 * reporting as "test_streams copy". Each record is checked, the bytes counted, and the
 * writer's status read.
 */
package test_streams

import compiler from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import stream from "std/os/slop_os"
import memory from "std"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_streams"
/** The copy's name, which starts each line the copy logs. */
COPY_NAME :: "test_streams copy"
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

/** What main was given that the tests use: the program's grants, the streams' writing ends among them only in the copy. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
    /** The process manager, which launches the copy; none in the copy. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which the copy is launched from; none in the copy. */
    program : slop_os.Memory?,
    /**
     * The channel end of the records' stream's writing end, whose presence says this is the copy: the end alone, as
     * what main is given can't hold a type with pointers in it, as Sink[Item] has in its schema (test_kit.run copies
     * it to the heap).
     */
    output : slop_os.Channel?,
    /** The writing end of the bytes' stream, in the copy. */
    bytes : os.Sink[u8]?,
}

/**
 * Check typed streams between programs: run by the root task, launch a copy and read the records and bytes it writes,
 * more than the ring holds at once, then see it end with 0, its own run of this test having passed, and its budget
 * come back to nothing; run as the copy, write them.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if, run by the root task, it wasn't given the process manager or its module, or a
 *     port, a stream, the log's copy, the launch, the arena or a reader couldn't be made; or, as the copy, if a
 *     writer couldn't be made or written.
 */
records_and_bytes_stream_between_programs #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    match given.output {
        case Some(end) => return write_copy(t, os.Sink[Item].{end = end}, given.bytes)
        case None => {}
    }
    block :: slop_os.startup_block()
    executable :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    loader :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, loader.end), "a port for the process manager's replies")?
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for the copy's watch")?
    items :: testing.require_ok(t, stream.pair[Item](block.budget), "a stream of records is made")?
    chunks :: testing.require_ok(t, stream.pair[u8](block.budget), "a stream of bytes is made")?
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    copy_log :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](given.log), rights), "the debug log can be copied for the copy")?
    launch :: os.launch(loader, manager_port, "test_streams copy", executable, COPY_BUDGET, main,
        CopyGrants.{log = cast[slop_os.DebugLog](copy_log), output = items.sink, bytes = chunks.sink},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}})
    launched :: testing.require_ok(t, launch, "the process manager launches the copy with the streams' writing ends")?
    // The records, each checked, read through an arena reset as it goes
    arena :: testing.require_some(t, memory.make_arena(), "an arena for the records read")?
    defer memory.free_arena(arena)
    reader := testing.require_ok(t, stream.reader_on(items.stream), "the records' stream is opened to read")?
    read := cast[u64](0)
    push_context reading (allocator = memory.arena_allocator(arena)) {
        loop {
            item :: stream.next(&reader) or_break
            testing.expect_eq(t, item.index, read, "records arrive in the order written, none lost, even as the ring wraps")
            testing.expect_eq(t, item.name, "record", "a record's string is copied with it")
            testing.expect_eq(t, item.even, read % 2 == 0, "a record's other fields are copied with it")
            read += 1
            if read % 256 == 0 {
                memory.reset_arena(arena)
            }
        }
    }
    testing.expect_eq(t, read, COUNT, "every record written is read, more than the ring holds at once")
    testing.expect_eq(t, reader.status, 0, "the reader sees the status the writer ended the stream with")
    stream.close_reader(&reader)
    // The bytes, counted
    byte_reader := testing.require_ok(t, stream.reader_on(chunks.stream), "the bytes' stream is opened to read")?
    total := cast[u64](0)
    loop {
        chunk :: stream.next_bytes(&byte_reader) or_break
        total += cast[u64](chunk.count)
    }
    testing.expect_eq(t, total, BYTE_CHUNKS * 3, "every byte written is read")
    stream.close_reader(&byte_reader)
    testing.expect_eq(t, ended_with(port), 0, "the copy wrote both streams and ended them, so its test passed")
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    testing.expect(t, test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000), "the copy's budget is back to nothing once it has ended")
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return .Ok
}

/**
 * Write the records and the bytes, as the copy, and end both streams with 0.
 *
 * @param t The test's state, which a writer that couldn't be made or written is recorded in.
 * @param sink The records' stream's writing end.
 * @param bytes The bytes' stream's writing end; null fails the test once the records are written.
 * @return Ok once both are written and ended; Error, recorded, if a writer couldn't be made or written.
 */
write_copy :: fn(t: ptr[mut testing.T], sink: os.Sink[Item], bytes: os.Sink[u8]?) -> testing.Outcome {
    writer := testing.require_ok(t, stream.writer_on(sink), "the records' stream is opened to write")?
    for i in cast[u64](0)..<COUNT {
        written :: stream.write(&writer, Item.{index = i, name = "record", even = i % 2 == 0})
        testing.require_none(t, written, "each record is written, the writer waiting for the reader when the ring is full")?
    }
    finished :: stream.finish(&writer, 0)
    testing.expect_none(t, finished, "the records' stream is ended with status 0")
    byte_sink :: testing.require_some(t, bytes, "the copy is given the bytes' stream's writing end")?
    byte_writer := testing.require_ok(t, stream.writer_on(byte_sink), "the bytes' stream is opened to write")?
    for i in cast[u64](0)..<BYTE_CHUNKS {
        written :: stream.write_bytes(&byte_writer, string_bytes(CHUNK))
        testing.require_none(t, written, "each chunk of bytes is written")?
    }
    bytes_finished :: stream.finish(&byte_writer, 0)
    testing.expect_none(t, bytes_finished, "the bytes' stream is ended with status 0")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log: as the program the root task ran, or, given output, as the copy, its
 * lines started with COPY_NAME.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param manager The process manager, which launches the copy; without it the test fails.
 * @param program The test's own module, which the copy is launched from; without it the test fails.
 * @param output Given only to the copy: where its records go. With it, this runs as the copy.
 * @param bytes Given only to the copy: where its bytes go. The copy without it fails.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, output: os.Sink[Item]?,
    bytes: os.Sink[u8]?) -> int {
    given := Given.{log = log, manager = manager, program = program, bytes = bytes}
    match output {
        case Some(sink) => given.output = sink.end
        case None => {}
    }
    name :: if output is_some { COPY_NAME } else { NAME }
    return test_kit.run(log, name, #insert testing.tests_of(compiler.load_package(".")), given)
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
