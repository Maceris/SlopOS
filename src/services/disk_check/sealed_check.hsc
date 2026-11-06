package disk_check

import os from "std"
import slop_os from "std/os"
import testing from "std"
import dir from "std/os/slop_os"
import storage from "../../protocols/storage"
import test_kit from "../../test_kit"

/*
 * An encrypted volume (roadmap 8e), which tools/boot.py has the image builder make in the system volume's container:
 * the storage manager refuses it without a passphrase and with the wrong one, then starts its volume server, which
 * unwraps its keys with the right one; the check reads the file the image builder put there, writes one of its own and
 * reads it back, has a new key generation started, writes another, reads all three, and is refused the wrong passphrase
 * again once it's served. What the files hold is in capitals, made here: the disk check's own bytes are on the disk
 * in the clear, so what it writes to the sealed volume, which tools/boot_tests.py finds nowhere on the disk, isn't
 * among them.
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
 * Check the encrypted volume in the system volume's container, through the storage manager: refused locked and with
 * the wrong passphrase, opened with its own, its file read, one written, a new key generation started, another
 * written, all three read, and, served, refused the wrong passphrase again and opened with its own.
 *
 * @param t The test's state.
 * @return Ok once it's run, the container's index and the volume's root kept in Given for the tests after;
 *     Error if the container wasn't found, the volume couldn't be opened, the buffer or a port made, a file written,
 *     or a key generation started.
 */
the_sealed_volume_opens_only_with_its_passphrase #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    // Beside the system volume, so skipped without it
    _ = system_of(t, given)?
    manager :: manager_of(t, given)?
    container := cast[u32](0xffffffff)
    for index in 0..<MOST_PARTITIONS {
        match ask(manager.end, manager.port, .Describe(index)) {
            case Described(described) => {
                if described.info.type_guid == CONTAINER_TYPE {
                    container = index
                    break
                }
            }
            case _ => break
        }
    }
    testing.require_ne(t, container, cast[u32](0xffffffff), "the test disk's system volume is in a SlopOS container, which the storage manager describes")?
    given.container = container
    // Refused without its passphrase, and with the wrong one
    match open_volume(manager.end, manager.port, container, "") {
        case Locked => {}
        case _ => testing.fail(t, "an encrypted volume isn't opened without a passphrase, but refused as locked")
    }
    match open_volume(manager.end, manager.port, container, "not its passphrase") {
        case WrongKey => {}
        case _ => testing.fail(t, "an encrypted volume isn't opened with the wrong passphrase, which unwraps no key")
    }
    sealed := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_volume(manager.end, manager.port, container, SEALED_PASSPHRASE) {
        case OpenedFiles(root) => sealed = root
        case _ => return stopped(t, "an encrypted volume opens with the passphrase the image builder sealed it with")
    }
    given.sealed = sealed
    buffer :: buffer_of(t, given)?
    bound :: os.port_for(slop_os.startup_block().budget, sealed.end)
    sealed_port :: testing.require_some(t, bound, "the budget has room for a port")?
    sealed_storage : u8[64]
    sealed_text :: capitals(SEALED_TEXT, sealed_storage)
    before_storage : u8[64]
    before_text :: capitals(BEFORE_TEXT, before_storage)
    after_storage : u8[64]
    after_text :: capitals(AFTER_TEXT, after_storage)
    testing.expect(t, holds(sealed.end, sealed_port, SEALED_FILE, sealed_text, buffer),
        "the file the image builder put in the encrypted volume reads back, decrypted, as it wrote it")
    testing.require(t, write_new(sealed.end, sealed_port, BEFORE_FILE, before_text, buffer), "the encrypted volume takes a new file")?
    testing.expect(t, holds(sealed.end, sealed_port, BEFORE_FILE, before_text, buffer), "a file written to the encrypted volume reads back")
    // A new key generation, sealing what's written from now on
    generation := cast[u32](0)
    out := os.Outgoing.{}
    rotating :: os.begin[storage.Request](&out)
    rotating^ = .Rotate(storage.VolumeNamed.{partition = container, name = bytes_of(&out, SEALED_VOLUME)})
    match ask_storage(manager.end, manager.port, &out) {
        case Rotated(made) => generation = made
        case _ => return stopped(t, "the storage manager starts a new key generation for a volume it serves")
    }
    testing.expect_eq(t, generation, 2, "the image builder sealed the volume with key generation 1, so the next is 2")
    testing.require(t, write_new(sealed.end, sealed_port, AFTER_FILE, after_text, buffer),
        "the encrypted volume takes a new file, sealed with the new key generation")?
    testing.expect(t, holds(sealed.end, sealed_port, SEALED_FILE, sealed_text, buffer), "a file sealed before the image was made still reads")
    testing.expect(t, holds(sealed.end, sealed_port, BEFORE_FILE, before_text, buffer), "a file sealed with the old key generation still reads")
    testing.expect(t, holds(sealed.end, sealed_port, AFTER_FILE, after_text, buffer), "a file sealed with the new key generation reads")
    // Served now, it's opened again only with its passphrase
    match open_volume(manager.end, manager.port, container, "not its passphrase") {
        case WrongKey => {}
        case _ => testing.fail(t, "an encrypted volume being served still isn't opened with the wrong passphrase")
    }
    match open_volume(manager.end, manager.port, container, SEALED_PASSPHRASE) {
        case OpenedFiles(again) => _ = slop_os.handle_close(cast[slop_os.Handle](again.end))
        case _ => testing.fail(t, "an encrypted volume being served opens again with its passphrase")
    }
    return .Ok
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
            case _ => return .Unsupported
        }
    }
}
