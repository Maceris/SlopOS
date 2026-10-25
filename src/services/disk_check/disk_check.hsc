/*
 * The disk check (decisions/0076, 0077, 0086): given a connector to the storage manager, it dials it, finds the
 * partition named CHECKED among every disk's, opens a block connection narrowed to it, describes it, takes its buffer,
 * reads the mark tools/boot.py wrote in the partition's block 0, writes its own into block 1, flushes, reads it back,
 * and reads blocks 2 to 9 with eight requests in flight at once, each holding its number as boot.py wrote it; then a
 * read of the block past the partition's end is refused. It says what it found in its debug log, and ends with 0 if
 * all of it held, or the number of the first check that didn't.
 */
package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import log_line from "../../log_line"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import partitions from "../../protocols/partitions"
import storage from "../../protocols/storage"

CHECKED :: "SlopOS check"
HOST_MARK :: "SlopOS disk check: from the host"
GUEST_MARK :: "SlopOS disk check: from the guest"
// Where in the buffer each part goes, in bytes
READ_AT : u32 : 0
WRITE_AT : u32 : 4096
CHECK_AT : u32 : 8192
MANY_AT : u32 : 16384
MANY :: 8

Disk :: struct {
    log : slop_os.DebugLog,
    end : slop_os.Channel,
    port : slop_os.Port,
    buffer : u64,
}

main :: fn(log: slop_os.DebugLog?, storage: os.Channel[connector.Connector]?) -> int {
    block_of_startup :: slop_os.startup_block()
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    dialing :: storage or_else os.Channel[connector.Connector].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    if cast[slop_os.Handle](dialing.end) == slop_os.NO_HANDLE {
        log_line.write(to, "disk_check: no storage manager")
        return 0
    }
    dial_port :: os.port_for(block_of_startup.budget, dialing.end) or_return 1
    manager :: connector.dial[storage.Storage](dialing.end, dial_port) or_return 1
    manager_port :: os.port_for(block_of_startup.budget, manager.end) or_return 1
    // The partition, among every disk's
    found := cast[u32](0xffffffff)
    partition := storage.Partition.{}
    for index in 0..<cast[u32](64) {
        match ask(manager.end, manager_port, .Describe(index)) {
            case Described(described) => {
                info := described.info
                if partitions.name_of(&info) == CHECKED {
                    found = index
                    partition = described
                    break
                }
            }
            case _ => break
        }
    }
    if found == 0xffffffff {
        log_line.write(to, "disk_check: no partition named %", CHECKED)
        return 13
    }
    connection := os.Channel[block.Block].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask(manager.end, manager_port, .Open(found)) {
        case Opened(opened) => connection = opened
        case _ => return 13
    }
    checked := Disk.{log = to, end = connection.end}
    checked.port = os.port_for(block_of_startup.budget, connection.end) or_return 1
    // What it is, and its buffer
    send(&checked, .Describe)
    info := block.Info.{}
    match receive(&checked) {
        case Described(described) => info = described
        case _ => return 2
    }
    send(&checked, .GetBuffer)
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match receive(&checked) {
        case Buffer(memory) => window = memory
        case _ => return 3
    }
    checked.buffer = runtime.reserve_addresses(cast[usize](info.buffer_bytes)) or_return 4
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(window, block_of_startup.space, checked.buffer, 0, info.buffer_bytes, read_write) or_return 4
    if info.block_count < 10 {
        log_line.write(to, "disk_check: the disk has only % blocks", info.block_count)
        return 5
    }

    // The host's mark, in block 0
    if run(&checked, .Read(block.Transfer.{tag = 1, first = 0, count = 1, offset = READ_AT})) != .Done {
        return 6
    }
    if !starts_with(&checked, READ_AT, HOST_MARK) {
        log_line.write(to, "disk_check: block 0 hasn't the host's mark")
        return 7
    }
    // Its own, in block 1, flushed, and read back
    put(&checked, WRITE_AT, GUEST_MARK)
    if run(&checked, .Write(block.Transfer.{tag = 2, first = 1, count = 1, offset = WRITE_AT})) != .Done {
        return 8
    }
    if run(&checked, .Flush(3)) != .Done {
        return 9
    }
    if run(&checked, .Read(block.Transfer.{tag = 4, first = 1, count = 1, offset = CHECK_AT})) != .Done
        || !starts_with(&checked, CHECK_AT, GUEST_MARK) {
        return 10
    }
    // Eight at once, answered in whatever order the device finishes them
    for i in 0..<MANY {
        send(&checked, .Read(block.Transfer.{tag = 100 + cast[u64](i), first = 2 + cast[u64](i), count = 1,
            offset = MANY_AT + cast[u32](i) * cast[u32](block.BLOCK_BYTES)}))
    }
    answered := cast[u32](0)
    for i in 0..<MANY {
        match receive(&checked) {
            case Finished(completion) => {
                if completion.status == .Done && completion.tag >= 100 && completion.tag < 100 + MANY {
                    answered |= cast[u32](1) << cast[u32](completion.tag - 100)
                }
            }
            case _ => {}
        }
    }
    if answered != (cast[u32](1) << MANY) - 1 {
        return 11
    }
    // The block past the partition's end, refused before it reaches the disk
    if info.block_count != partition.info.count
        || run(&checked, .Read(block.Transfer.{tag = 5, first = info.block_count, count = 1, offset = READ_AT})) != .OutOfRange {
        return 14
    }
    for i in 0..<MANY {
        storage : u8[16]
        label := text_buffer.make(storage)
        text_buffer.append_format(&label, "block %", 2 + i)
        if !starts_with(&checked, MANY_AT + cast[u32](i) * cast[u32](block.BLOCK_BYTES), text_buffer.as_string(&label)) {
            log_line.write(to, "disk_check: block % doesn't hold its number", 2 + i)
            return 12
        }
    }
    log_line.write(to, "disk_check: in %, % blocks from % of disk %, read the host's mark, wrote, flushed and read back block 1, read 8 blocks at once, and was refused the block past its end",
        CHECKED, info.block_count, partition.info.first, partition.disk)
    return 0
}

// One request to the storage manager, and its answer, waited for.
ask :: fn(end: slop_os.Channel, port: slop_os.Port, request: storage.Request) -> storage.Response {
    out := os.Outgoing.{}
    made :: os.begin[storage.Request](&out)
    made^ = request
    if storage.send_request(end, port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match storage.receive_response(end, port, &into, true) {
            case Received => return os.message_of[storage.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

send :: fn(disk: ptr[Disk], request: block.Request) {
    out := os.Outgoing.{}
    made :: os.begin[block.Request](&out)
    made^ = request
    _ = block.send_request(disk.end, disk.port, &out)
}

// The next answer, waited for; Unsupported if the connection's gone.
receive :: fn(disk: ptr[Disk]) -> block.Response {
    into := os.Incoming.{}
    loop {
        match block.receive_response(disk.end, disk.port, &into, true) {
            case Received => return os.message_of[block.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// One request, and how it finished.
run :: fn(disk: ptr[Disk], request: block.Request) -> block.Status {
    send(disk, request)
    return match receive(disk) {
        case Finished(completion) => completion.status
        case _ => .DeviceError
    }
}

put :: fn(disk: ptr[Disk], offset: u32, text: string) {
    bytes :: view_of(cast[ptr[mut u8]](disk.buffer + cast[u64](offset)), cast[usize](block.BLOCK_BYTES))
    for &byte, i in bytes {
        byte^ = if i < text.count { cast[u8](text[i]) } else { cast[u8](0) }
    }
}

starts_with :: fn(disk: ptr[Disk], offset: u32, text: string) -> bool {
    bytes :: view_of(cast[ptr[u8]](disk.buffer + cast[u64](offset)), text.count)
    for character, i in text {
        if i >= bytes.count || bytes[i] != cast[u8](character) {
            return false
        }
    }
    return true
}
