package disk_check

import os from "std"
import slop_os from "std/os"
import testing from "std"
import storage from "../../protocols/storage"
import slopfs from "../../slopfs"
import test_kit from "../../test_kit"

/*
 * Volumes made at run time (decisions/0141), through the storage manager: a plain one and a sealed one, each opened as
 * it's made, written and read back; the same name refused again; the sealed one refused with the wrong passphrase and
 * opened again with its own.
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
 * @param t The test's state.
 * @return Ok once it's run; Error if the container wasn't found, the buffer or a port couldn't be made, or a volume
 *     couldn't be made.
 */
volumes_are_made_at_run_time #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    manager :: manager_of(t, given)?
    container :: testing.require_some(t, given.container, "the sealed volume's test, run before, found the container")?
    buffer :: buffer_of(t, given)?
    budget :: slop_os.startup_block().budget
    for name, i in string.[MADE_PLAIN, MADE_SEALED] {
        sealed :: i == 1
        root :: match create(manager.end, manager.port, container, name, if sealed { MADE_PASSPHRASE } else { "" }) {
            case OpenedFiles(opened) => opened
            case _ => return stopped(t, "the storage manager makes a new volume in the container, plain or sealed, and opens it")
        }
        bound :: os.port_for(budget, root.end)
        root_port :: testing.require_some(t, bound, "the budget has room for a port")?
        testing.expect(t, write_new(root.end, root_port, MADE_FILE, MADE_TEXT, buffer) && holds(root.end, root_port, MADE_FILE, MADE_TEXT, buffer),
            "a volume made at run time takes a file, which reads back")
        _ = slop_os.handle_close(cast[slop_os.Handle](root_port))
        _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
        match create(manager.end, manager.port, container, name, if sealed { MADE_PASSPHRASE } else { "" }) {
            case AlreadyExists => {}
            case _ => testing.fail(t, "a volume isn't made with a name another in the container has, but refused")
        }
    }
    match open_named(manager.end, manager.port, container, MADE_SEALED, "not its passphrase") {
        case WrongKey => {}
        case _ => testing.fail(t, "a sealed volume made at run time isn't opened with the wrong passphrase")
    }
    match open_named(manager.end, manager.port, container, MADE_SEALED, MADE_PASSPHRASE) {
        case OpenedFiles(again) => {
            again_bound :: os.port_for(budget, again.end)
            again_port :: testing.require_some(t, again_bound, "the budget has room for a port")?
            testing.expect(t, holds(again.end, again_port, MADE_FILE, MADE_TEXT, buffer), "a sealed volume opened again has the file written to it")
            _ = slop_os.handle_close(cast[slop_os.Handle](again_port))
            _ = slop_os.handle_close(cast[slop_os.Handle](again.end))
        }
        case _ => testing.fail(t, "a sealed volume made at run time opens again with its passphrase")
    }
    return .Ok
}

/**
 * Make a new volume in a container through the storage manager, and open it.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The container's index among the storage manager's partitions.
 * @param name The new volume's name in the container; one a volume already has is refused with AlreadyExists.
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
