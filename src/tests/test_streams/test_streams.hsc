/*
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

NAME :: "test_streams"
COPY_BUDGET : u64 : 4 << 20
WATCH_KEY : u64 : 1
COUNT : u64 : 3000
BYTE_CHUNKS : u64 : 100
CHUNK :: "abc"

Item :: struct {
    index : u64,
    name : string,
    even : bool,
}

CopyGrants :: struct {
    log : slop_os.DebugLog,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    output : os.Sink[Item]?,
    bytes : os.Sink[u8]?,
}

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

// In the copy: the records and the bytes written, and both streams ended with 0.
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

// How the process watched on port ended: its code, once it has.
ended_with :: fn(port: slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
