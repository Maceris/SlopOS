package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
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

/** The encrypted volume's name in the system volume's container. */
SEALED_VOLUME :: "sealed"
/** The passphrase the image builder sealed it with. */
SEALED_PASSPHRASE :: "slopos test passphrase"
/** The file the image builder put in the encrypted volume (image_builder.hsc). */
SEALED_FILE :: "sealed.txt"
/** What SEALED_FILE holds, in capitals; written here in lowercase, so these bytes aren't the file's on the disk. */
SEALED_TEXT :: "only its passphrase opens this"
/** The file the check writes before a new key generation. */
BEFORE_FILE :: "before.txt"
/** What BEFORE_FILE holds, in capitals. */
BEFORE_TEXT :: "Written to the sealed volume with its first key generation"
/** The file the check writes after a new key generation. */
AFTER_FILE :: "after.txt"
/** What AFTER_FILE holds, in capitals. */
AFTER_TEXT :: "Written to the sealed volume with its second key generation"
/** A SlopOS container's partition type, "SLOPOS CONTAINER" in ASCII. */
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]

/**
 * Check the encrypted volume in the system volume's container, through the storage manager, then links, snapshots,
 * quotas and volumes made, in turn.
 *
 * @param to The debug log, passed on.
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param system The system volume's root.
 * @return 0 if all of it held; 200 if no container was found among the first 64 partitions, 201 and 202 if it wasn't
 *     refused as Locked without a passphrase or as WrongKey with the wrong one, 203 if it couldn't be opened with its
 *     own, 204 if the buffer or a port couldn't be made, 205 if the image builder's file didn't read as it should, 206
 *     if the check's file couldn't be written or read back, 207 and 208 if a new key generation, the second, wasn't
 *     started, 209 and 210 if writing after it, or reading all three, failed, and 211 and 212 if, served, it wasn't
 *     refused the wrong passphrase or opened again with its own; and check_links', then check_snapshots', numbers.
 */
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
        return 200
    }
    // Refused without its passphrase, and with the wrong one
    match open_volume(manager, port, container, "") {
        case Locked => {}
        case _ => return 201
    }
    match open_volume(manager, port, container, "not its passphrase") {
        case WrongKey => {}
        case _ => return 202
    }
    sealed := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_volume(manager, port, container, SEALED_PASSPHRASE) {
        case OpenedFiles(root) => sealed = root
        case _ => return 203
    }
    buffer := new_buffer() or_return 204
    budget :: slop_os.startup_block().budget
    sealed_port :: os.port_for(budget, sealed.end) or_return 204
    sealed_storage : u8[64]
    sealed_text :: capitals(SEALED_TEXT, sealed_storage)
    before_storage : u8[64]
    before_text :: capitals(BEFORE_TEXT, before_storage)
    after_storage : u8[64]
    after_text :: capitals(AFTER_TEXT, after_storage)
    if !holds(sealed.end, sealed_port, SEALED_FILE, sealed_text, &buffer) {
        return 205
    }
    if !write_new(sealed.end, sealed_port, BEFORE_FILE, before_text, &buffer) || !holds(sealed.end, sealed_port, BEFORE_FILE, before_text, &buffer) {
        return 206
    }
    // A new key generation, sealing what's written from now on
    generation := cast[u32](0)
    out := os.Outgoing.{}
    rotating :: os.begin[storage.Request](&out)
    rotating^ = .Rotate(storage.VolumeNamed.{partition = container, name = bytes_of(&out, SEALED_VOLUME)})
    match ask_storage(manager, port, &out) {
        case Rotated(made) => generation = made
        case _ => return 207
    }
    if generation != 2 {
        return 208
    }
    if !write_new(sealed.end, sealed_port, AFTER_FILE, after_text, &buffer) {
        return 209
    }
    if !holds(sealed.end, sealed_port, SEALED_FILE, sealed_text, &buffer) || !holds(sealed.end, sealed_port, BEFORE_FILE, before_text, &buffer)
        || !holds(sealed.end, sealed_port, AFTER_FILE, after_text, &buffer) {
        return 210
    }
    // Served now, it's opened again only with its passphrase
    match open_volume(manager, port, container, "not its passphrase") {
        case WrongKey => {}
        case _ => return 211
    }
    match open_volume(manager, port, container, SEALED_PASSPHRASE) {
        case OpenedFiles(again) => _ = slop_os.handle_close(cast[slop_os.Handle](again.end))
        case _ => return 212
    }
    runtime.log_info("on the sealed volume, was refused locked and with a wrong passphrase, unlocked it, read its file, wrote one, started key generation %, wrote another and read all three",
        generation)
    // Stored links between it and the system volume, while it's served
    failed :: check_links(to, manager, port, system, sealed, container)
    if failed != 0 {
        return failed
    }
    return check_snapshots(to, manager, port, system, container)
}

/**
 * Make text in capitals, ASCII letters only.
 *
 * @param text The text to copy, only read; bytes other than a to z are copied as they are.
 * @param into Where it's made; what doesn't fit is cut off.
 * @return A view of into's bytes, good while into is unchanged; "" for nothing.
 */
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

/**
 * Ask the storage manager to open the encrypted volume, SEALED_VOLUME.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The container's index among the storage manager's partitions.
 * @param passphrase The passphrase, or "" for none.
 * @return The storage manager's answer: OpenedFiles with its root, which the caller owns, Locked without a passphrase,
 *     WrongKey with the wrong one, or another refusal; Unsupported if it couldn't be asked.
 */
open_volume :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, passphrase: string) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = container, name = bytes_of(&out, SEALED_VOLUME),
        passphrase = bytes_of(&out, passphrase)})
    return ask_storage(manager, port, &out)
}

/**
 * Send one request to the storage manager, and wait for its answer.
 *
 * @param end The connection to the storage manager.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @return The answer, a copy, whose handles the caller owns; its Relatives point into a message that's gone, so they
 *     aren't read. Unsupported if it couldn't be sent or the connection failed.
 */
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
