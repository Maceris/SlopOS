/*
 * The disk check (decisions/0076, 0077, 0086): given a connector to the storage manager, it dials it, finds the
 * partition named CHECKED among every disk's, opens a block connection narrowed to it, describes it, takes its buffer,
 * reads the mark tools/boot.py wrote in the partition's block 0, writes its own into block 1, flushes, reads it back,
 * and reads blocks 2 to 9 with eight requests in flight at once, each holding its number as boot.py wrote it; then a
 * read of the block past the partition's end is refused. Then, given the first EFI system partition's root as its
 * working directory, it uses std's files there (decisions/0087): it reads the files tools/boot.py put in EFI/SlopOS,
 * one with a long name, writes one of its own, makes a directory and moves its file into it, lists them, reads its file
 * back through the directory opened, and is refused a path above its working directory; and through the protocols
 * themselves, narrows EFI/SlopOS to read only, selects its files by a pattern, and is refused a file made in the set
 * the read-only directory gave. Given the system volume, it reads, writes and moves files there (system_check.hsc), and
 * unlocks an encrypted volume beside it through the storage manager (sealed_check.hsc), keeps links from one to the
 * other (link_check.hsc), and takes, reads and clones snapshots of them (snapshot_check.hsc). It says what it found in its
 * debug log, and ends with 0 if all of it held, or the number of the first check that didn't.
 */
package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import strings from "std"
import text_buffer from "std"
import dir from "std/os/slop_os"
import file_set from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import partitions from "../../protocols/partitions"
import storage from "../../protocols/storage"

CHECKED :: "SlopOS check"
// What tools/boot.py put on the EFI system partition, and what the check writes there
HOST_FILE :: "EFI/SlopOS/hello.txt"
HOST_TEXT :: "Hello from the host's FAT32"
LONG_FILE :: "EFI/SlopOS/A long name, from the host.txt"
LONG_TEXT :: "A long name, from the host"
GUEST_FILE :: "EFI/SlopOS/Written by the guest.txt"
GUEST_TEXT :: "Written by the guest, through std's files"
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

main :: fn(log: slop_os.DebugLog?, storage: os.Channel[connector.Connector]?, working_directory: os.Channel[dir.Dir]?,
    system: os.Channel[dir.Dir]?) -> int {
    block_of_startup :: slop_os.startup_block()
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    dialing :: storage or_else os.Channel[connector.Connector].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    if cast[slop_os.Handle](dialing.end) == slop_os.NO_HANDLE {
        runtime.log_info("no storage manager")
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
        runtime.log_info("no partition named %", CHECKED)
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
        runtime.log_info("the disk has only % blocks", info.block_count)
        return 5
    }

    // The host's mark, in block 0
    if run(&checked, .Read(block.Transfer.{tag = 1, first = 0, count = 1, offset = READ_AT})) != .Done {
        return 6
    }
    if !starts_with(&checked, READ_AT, HOST_MARK) {
        runtime.log_info("block 0 hasn't the host's mark")
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
            runtime.log_info("block % doesn't hold its number", 2 + i)
            return 12
        }
    }
    runtime.log_info("in %, % blocks from % of disk %, read the host's mark, wrote, flushed and read back block 1, read 8 blocks at once, and was refused the block past its end",
        CHECKED, info.block_count, partition.info.first, partition.disk)
    if working_directory is_none {
        runtime.log_info("no EFI system partition")
        return 0
    }
    failed :: check_files(to)
    if failed != 0 {
        return failed
    }
    failed_protocols :: check_protocols(to, working_directory or_return 31)
    if failed_protocols != 0 {
        return failed_protocols
    }
    match system {
        case Some(volume) => {
            failed_system :: check_system(to, volume, working_directory)
            if failed_system != 0 {
                return failed_system
            }
            // The system volume's container holds an encrypted one, too (sealed_check.hsc)
            return check_sealed(to, manager.end, manager_port, volume)
        }
        case None => {
            runtime.log_info("no system volume")
            return 0
        }
    }
}

// The EFI system partition, its working directory, through std's files.
check_files :: fn(to: slop_os.DebugLog) -> int {
    host :: os.read_entire_file(HOST_FILE) or_return 20
    long :: os.read_entire_file(LONG_FILE) or_return 21
    if !strings.equal(host, HOST_TEXT) || !strings.equal(long, LONG_TEXT) {
        runtime.log_info("the host's files hold % and %", host, long)
        return 22
    }
    if os.write_entire_file(GUEST_FILE, GUEST_TEXT) != null || os.make_directory("EFI/SlopOS/made") != null {
        return 23
    }
    if os.rename(GUEST_FILE, "EFI/SlopOS/made/Written by the guest.txt") != null || os.exists(GUEST_FILE) {
        return 24
    }
    entries :: os.list_directory("EFI/SlopOS") or_return 25
    names := 0
    for entry in entries {
        if (strings.equal(entry.name, "hello.txt") && !entry.is_directory) || (strings.equal(entry.name, "made") && entry.is_directory)
            || strings.equal(entry.name, "A long name, from the host.txt") {
            names += 1
        }
    }
    count :: entries.count
    os.free_directory_listing(entries)
    if names != 3 || count != 3 {
        return 26
    }
    made :: os.open_directory("EFI/SlopOS/made") or_return 27
    back :: os.read_entire_file_in(made, "Written by the guest.txt") or_return 28
    os.close_directory(made)
    if !strings.equal(back, GUEST_TEXT) {
        return 29
    }
    match os.read_entire_file("../EFI/SlopOS/hello.txt") {
        case Ok(text) => return 30
        case Error(error) => {
            if error != .InvalidPath {
                return 30
            }
        }
    }
    runtime.log_info("on the EFI system partition, read the host's files, wrote, moved and read back its own, listed %, and was refused a path above it",
        count)
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

/*
 * Beneath std's files, through the protocols: EFI/SlopOS opened, narrowed to read only, a set of its files selected
 * by a pattern, which FAT matches ignoring case, and a file made through that set refused.
 */
check_protocols :: fn(to: slop_os.DebugLog, working_directory: os.Channel[dir.Dir]) -> int {
    budget :: slop_os.startup_block().budget
    into := os.Incoming.{}
    port :: os.port_for(budget, working_directory.end) or_return 31
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "EFI/SlopOS")})
    directory := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_dir(working_directory.end, port, &out, &into) {
        case OpenedDirectory(made) => directory = made.end
        case _ => return 31
    }
    directory_port :: os.port_for(budget, directory) or_return 32
    out = os.Outgoing.{}
    narrowing :: os.begin[dir.Request](&out)
    narrowing^ = .Narrow
    read_only := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_dir(directory, directory_port, &out, &into) {
        case Narrowed(made) => read_only = made.end
        case _ => return 32
    }
    read_only_port :: os.port_for(budget, read_only) or_return 33
    out = os.Outgoing.{}
    selecting :: os.begin[read_only_dir.Request](&out)
    selecting^ = .Select(bytes_of(&out, "*.TXT"))
    set := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_read_only_dir(read_only, read_only_port, &out, &into) {
        case Selected(made) => set = made.end
        case _ => return 33
    }
    set_port :: os.port_for(budget, set) or_return 34
    matched := 0
    cursor : u64 = 0
    ended := false
    loop {
        out = os.Outgoing.{}
        listing :: os.begin[file_set.Request](&out)
        listing^ = .List(cursor)
        match ask_file_set(set, set_port, &out, &into) {
            case Listed(entry) => {
                matched += 1
                cursor = entry.next
            }
            case End => ended = true
            case _ => return 34
        }
    }
    while !ended && matched < 8
    // The host's two files; the directory the check made doesn't match
    if matched != 2 {
        return 35
    }
    out = os.Outgoing.{}
    creating :: os.begin[file_set.Request](&out)
    creating^ = .OpenFile(file_set.OpenFile.{name = bytes_of(&out, "Made through the set.txt"), creation = .New})
    match ask_file_set(set, set_port, &out, &into) {
        case Failed(error) => {
            if error != .ReadOnly {
                return 36
            }
        }
        case _ => return 36
    }
    runtime.log_info("narrowed EFI/SlopOS to read only, selected % of its files by *.TXT, and was refused a file made in the set",
        matched)
    return 0
}

// A path's bytes appended to out, as a Relative.
bytes_of :: fn(out: ptr[mut os.Outgoing], text: string) -> slop_os.Relative[u8] {
    return os.append(out, view_of(cast[ptr[u8]](text.data), text.count))
}

// One request on a dir connection, and its answer, waited for.
ask_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// One request on a read_only_dir connection, and its answer, waited for.
ask_read_only_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_dir.Response {
    if read_only_dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// One request on a file_set connection, and its answer, waited for.
ask_file_set :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> file_set.Response {
    if file_set.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match file_set.receive_response(end, port, into, true) {
            case Received => return os.message_of[file_set.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}
