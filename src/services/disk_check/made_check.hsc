package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import storage from "../../protocols/storage"
import slopfs from "../../slopfs"

/*
 * Volumes made at run time (decisions/0141), through the storage manager: a plain one and a sealed one, each opened as
 * it's made, written and read back; the same name refused again; the sealed one refused with the wrong passphrase and
 * opened again with its own. Checks from 160.
 */

/** The name of the plain volume the check makes in the container. */
MADE_PLAIN :: "made"
/** The name of the sealed volume the check makes in the container. */
MADE_SEALED :: "made sealed"
/** The sealed volume's passphrase. */
MADE_PASSPHRASE :: "a volume made while running"
/** The file written in each volume made, in its root. */
MADE_FILE :: "Made.txt"
/** What MADE_FILE holds. */
MADE_TEXT :: "Written to a volume made at run time"

/**
 * Check volumes made at run time through the storage manager: a plain one and a sealed one, each opened as it's made,
 * a file written and read back, and the same name refused again; then the sealed one refused with the wrong
 * passphrase and opened again with its own.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The index, among the storage manager's partitions, of the container the volumes are made in.
 * @param buffer The buffer file connections read and write through.
 * @return 0 if all of it held; 160 if a volume couldn't be made, 161 if a port couldn't be, 162 if its file couldn't be
 *     written or read back, 163 if making it again wasn't refused with AlreadyExists, 164 if the wrong passphrase
 *     wasn't refused with WrongKey, and 165 to 167 if the sealed one couldn't be opened again and read.
 */
check_made :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, buffer: ptr[Buffer]) -> int {
    budget :: slop_os.startup_block().budget
    for name, i in string.[MADE_PLAIN, MADE_SEALED] {
        sealed :: i == 1
        root :: match create(manager, port, container, name, if sealed { MADE_PASSPHRASE } else { "" }) {
            case OpenedFiles(opened) => opened
            case _ => return 160
        }
        root_port :: os.port_for(budget, root.end) or_return 161
        if !write_new(root.end, root_port, MADE_FILE, MADE_TEXT, buffer) || !holds(root.end, root_port, MADE_FILE, MADE_TEXT, buffer) {
            return 162
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](root_port))
        _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
        match create(manager, port, container, name, if sealed { MADE_PASSPHRASE } else { "" }) {
            case AlreadyExists => {}
            case _ => return 163
        }
    }
    match open_named(manager, port, container, MADE_SEALED, "not its passphrase") {
        case WrongKey => {}
        case _ => return 164
    }
    match open_named(manager, port, container, MADE_SEALED, MADE_PASSPHRASE) {
        case OpenedFiles(again) => {
            again_port :: os.port_for(budget, again.end) or_return 165
            if !holds(again.end, again_port, MADE_FILE, MADE_TEXT, buffer) {
                return 166
            }
            _ = slop_os.handle_close(cast[slop_os.Handle](again_port))
            _ = slop_os.handle_close(cast[slop_os.Handle](again.end))
        }
        case _ => return 167
    }
    runtime.log_info("made: a volume and a sealed one at run time, wrote and read back a file on each, was refused either again, and opened the sealed one only with its passphrase")
    return 0
}

/**
 * Make a new volume in a container through the storage manager, and open it.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The container's index among the storage manager's partitions.
 * @param name The volume's name.
 * @param passphrase The passphrase it's sealed with, with AES-256-GCM; "" for a plain volume.
 * @return The storage manager's answer: OpenedFiles with the volume's root, which the caller owns, AlreadyExists for a
 *     name taken, or another refusal; Unsupported if it couldn't be asked.
 */
create :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, name: string, passphrase: string) -> storage.Response {
    out := os.Outgoing.{}
    creating :: os.begin[storage.Request](&out)
    creating^ = .CreateVolume(storage.NewVolume.{partition = container, name = bytes_of(&out, name), passphrase = bytes_of(&out, passphrase),
        cipher = if passphrase.count > 0 { cast[u8](slopfs.Cipher.Aes256Gcm) } else { cast[u8](slopfs.Cipher.None) }, now = 1})
    return ask_storage(manager, port, &out)
}
