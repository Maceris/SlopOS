package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import log_line from "../../log_line"

/*
 * The system volume (decisions/0089): a SlopOS container's, served by a volume server through a container service.
 * The check reads a module from it and compares it with the copy on the EFI system partition, which Limine loaded it
 * from; writes a file of its own, syncs it, which commits it, and reads it back; and moves it into a directory it makes.
 * Checks from 40.
 */

MODULE_ON_VOLUME :: "modules/hello.elf"
MODULE_ON_ESP :: "boot/modules/hello.elf"
SYSTEM_FILE :: "Written to the system volume.txt"
SYSTEM_TEXT :: "Written to the system volume by the guest, and synced"
// The buffer file connections read and write through, and the most of a file read whole
TRANSFER_BYTES : u64 : 65536
MAX_FILE_BYTES : usize : 1 << 20

// A buffer for file connections: a memory object mapped here, given to each server as a handle of its own.
Buffer :: struct {
    memory : slop_os.Memory,
    address : u64,
}

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

// A handle to the buffer for a file's server, which maps it.
handed :: fn(buffer: ptr[Buffer]) -> slop_os.Memory? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](buffer.memory), rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

window_of :: fn(buffer: ptr[Buffer]) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](buffer.address), cast[usize](TRANSFER_BYTES))
}

check_system :: fn(to: slop_os.DebugLog, system: os.Channel[dir.Dir], esp: os.Channel[dir.Dir]?) -> int {
    buffer := new_buffer() or_return 40
    budget :: slop_os.startup_block().budget
    system_port :: os.port_for(budget, system.end) or_return 41
    from_volume : u8[..]
    defer runtime.array_free(&from_volume)
    if !read_whole(system.end, system_port, MODULE_ON_VOLUME, &buffer, &from_volume) || from_volume.count == 0 {
        return 42
    }
    // The same bytes as the copy Limine loaded it from
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
    // A file of its own, written, synced and read back
    if !write_new(system.end, system_port, SYSTEM_FILE, SYSTEM_TEXT, &buffer) {
        return 46
    }
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
    log_line.write(to, "disk_check: on the system volume, read % as the EFI system partition has it, wrote, synced and read back its own file, and moved it",
        MODULE_ON_VOLUME)
    return 0
}

// The file at path beneath a directory, read whole into bytes through a read_only_file connection.
read_whole :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, buffer: ptr[Buffer], bytes: ptr[mut u8[..]]) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenReadOnlyFile(bytes_of(&out, path))
    opened := os.Channel[read_only_file.ReadOnlyFile].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(end, port, &out, &into) {
        case OpenedReadOnlyFile(made) => opened = made
        case _ => return false
    }
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

// A new file at path beneath a directory holding text, written through a file connection and synced.
write_new :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, text: string, buffer: ptr[Buffer]) -> bool {
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
    requests := file.Request.[.UseBuffer(memory), .Write(files.Transfer.{offset = 0, count = cast[u32](text.count), buffer_offset = 0}), .Sync]
    for request in requests {
        out = os.Outgoing.{}
        made :: os.begin[file.Request](&out)
        made^ = request
        match ask_file(opened.end, file_port, &out, &into) {
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
