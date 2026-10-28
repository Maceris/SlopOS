package disk_check

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import storage from "../../protocols/storage"

/*
 * An encrypted volume (roadmap 8e), which tools/boot.py has the image builder make in the system volume's container:
 * the storage manager refuses it without a passphrase and with the wrong one, then starts its volume server, which
 * unwraps its keys with the right one; the check reads the file the image builder put there, writes one of its own and
 * reads it back, has a new key generation started, writes another, reads all three, and is refused the wrong passphrase
 * again once it's served. What the files hold is in capitals, made here: the disk check's own bytes are on the disk
 * in the clear, so what it writes to the sealed volume, which tools/boot_tests.py finds nowhere on the disk, isn't
 * among them. Checks from 60.
 */

SEALED_VOLUME :: "sealed"
SEALED_PASSPHRASE :: "slopos test passphrase"
// What the image builder put in it (image_builder.hsc), in capitals, and what the check writes, in capitals
SEALED_FILE :: "sealed.txt"
SEALED_TEXT :: "only its passphrase opens this"
BEFORE_FILE :: "before.txt"
BEFORE_TEXT :: "Written to the sealed volume with its first key generation"
AFTER_FILE :: "after.txt"
AFTER_TEXT :: "Written to the sealed volume with its second key generation"
// A SlopOS container's partition type, "SLOPOS CONTAINER" in ASCII
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]

check_sealed :: fn(to: slop_os.DebugLog, manager: slop_os.Channel, port: slop_os.Port, system: os.Channel[dir.Dir]) -> int {
    container := cast[u32](0xffffffff)
    for index in 0..<cast[u32](64) {
        match ask(manager, port, .Describe(index)) {
            case Described(described) => {
                if described.info.type_guid == CONTAINER_TYPE {
                    container = index
                    break
                }
            }
            case _ => break
        }
    }
    if container == 0xffffffff {
        return 60
    }
    // Refused without its passphrase, and with the wrong one
    match open_volume(manager, port, container, "") {
        case Locked => {}
        case _ => return 61
    }
    match open_volume(manager, port, container, "not its passphrase") {
        case WrongKey => {}
        case _ => return 62
    }
    sealed := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_volume(manager, port, container, SEALED_PASSPHRASE) {
        case OpenedFiles(root) => sealed = root
        case _ => return 63
    }
    buffer := new_buffer() or_return 64
    budget :: slop_os.startup_block().budget
    sealed_port :: os.port_for(budget, sealed.end) or_return 64
    sealed_storage : u8[64]
    sealed_text :: capitals(SEALED_TEXT, sealed_storage)
    before_storage : u8[64]
    before_text :: capitals(BEFORE_TEXT, before_storage)
    after_storage : u8[64]
    after_text :: capitals(AFTER_TEXT, after_storage)
    if !holds(sealed.end, sealed_port, SEALED_FILE, sealed_text, &buffer) {
        return 65
    }
    if !write_new(sealed.end, sealed_port, BEFORE_FILE, before_text, &buffer) || !holds(sealed.end, sealed_port, BEFORE_FILE, before_text, &buffer) {
        return 66
    }
    // A new key generation, sealing what's written from now on
    generation := cast[u32](0)
    out := os.Outgoing.{}
    rotating :: os.begin[storage.Request](&out)
    rotating^ = .Rotate(storage.VolumeNamed.{partition = container, name = bytes_of(&out, SEALED_VOLUME)})
    match ask_storage(manager, port, &out) {
        case Rotated(made) => generation = made
        case _ => return 67
    }
    if generation != 2 {
        return 68
    }
    if !write_new(sealed.end, sealed_port, AFTER_FILE, after_text, &buffer) {
        return 69
    }
    if !holds(sealed.end, sealed_port, SEALED_FILE, sealed_text, &buffer) || !holds(sealed.end, sealed_port, BEFORE_FILE, before_text, &buffer)
        || !holds(sealed.end, sealed_port, AFTER_FILE, after_text, &buffer) {
        return 70
    }
    // Served now, it's opened again only with its passphrase
    match open_volume(manager, port, container, "not its passphrase") {
        case WrongKey => {}
        case _ => return 71
    }
    match open_volume(manager, port, container, SEALED_PASSPHRASE) {
        case OpenedFiles(again) => _ = slop_os.handle_close(cast[slop_os.Handle](again.end))
        case _ => return 72
    }
    log_line.write(to, "disk_check: on the sealed volume, was refused locked and with a wrong passphrase, unlocked it, read its file, wrote one, started key generation %, wrote another and read all three",
        generation)
    // Stored links between it and the system volume, while it's served
    failed :: check_links(to, manager, port, system, sealed, container)
    if failed != 0 {
        return failed
    }
    return check_snapshots(to, manager, port, system, container)
}

// text in capitals, in into.
capitals :: fn(text: string, into: mut u8[]) -> string {
    count : usize = 0
    for character, i in text {
        if i < into.count {
            byte :: cast[u8](character)
            into[i] = if byte >= cast[u8]('a') && byte <= cast[u8]('z') { byte - 32 } else { byte }
            count = i + 1
        }
    }
    if count == 0 {
        return ""
    }
    return string_of(&into[0], count)
}

// The sealed volume, opened with a passphrase, or without one, if it's empty.
open_volume :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, passphrase: string) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = container, name = bytes_of(&out, SEALED_VOLUME),
        passphrase = bytes_of(&out, passphrase)})
    return ask_storage(manager, port, &out)
}

// One request to the storage manager, sent from out, and its answer, waited for.
ask_storage :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing]) -> storage.Response {
    if storage.send_request(end, port, out) is_some {
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
