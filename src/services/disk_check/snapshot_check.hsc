package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import testing from "std"
import dir from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import storage from "../../protocols/storage"
import test_kit from "../../test_kit"

/*
 * Snapshots and clones (roadmap 8e), through the storage manager: a snapshot of the system volume, which reads as the
 * volume did after a file is written to the volume, given as a read-only directory; found among the volume's
 * snapshots; a clone of it, written to apart from the volume; the snapshot refused deletion while its clone is there;
 * and a snapshot of the encrypted volume, opened with its passphrase.
 */

/** The system volume's name in its container. */
SYSTEM_VOLUME :: "system"
/** The name of the system volume's snapshot the check takes. */
SNAPSHOT :: "before"
/** The name of the clone the check makes of the snapshot, which quota_check.hsc gives a quota. */
CLONE :: "trial"
/** The file written to the system volume after the snapshot, which the snapshot hasn't. */
AFTER_SNAPSHOT_FILE :: "Written after the snapshot.txt"
/** What AFTER_SNAPSHOT_FILE holds. */
AFTER_SNAPSHOT_TEXT :: "Written to the system volume after its snapshot was taken"
/** The file written to the clone, which the system volume hasn't. */
CLONE_FILE :: "Written to the clone.txt"
/** What CLONE_FILE holds. */
CLONE_TEXT :: "Written to a clone of the system volume's snapshot"

/**
 * Check snapshots and clones through the storage manager.
 *
 * @param t The test's state.
 * @return Ok once it's run, the clone's root kept in Given for the quota's test; Error if the container wasn't
 *     found, the buffer or a port couldn't be made, or a step the rest builds on failed: taking or opening the
 *     snapshot, writing after it, reading its module, or making or opening the clone.
 */
snapshots_read_as_the_volume_was_and_clone #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    manager :: manager_of(t, given)?
    container :: testing.require_some(t, given.container, "the sealed volume's test, run before, found the container")?
    buffer :: buffer_of(t, given)?
    budget :: slop_os.startup_block().budget
    system_bound :: os.port_for(budget, system.end)
    system_port :: testing.require_some(t, system_bound, "the budget has room for a port")?
    match volume_request(manager.end, manager.port, container, SYSTEM_VOLUME, SNAPSHOT, .Take) {
        case Done => {}
        case _ => return stopped(t, "the storage manager takes a snapshot of a volume it serves")
    }
    testing.require(t, write_new(system.end, system_port, AFTER_SNAPSHOT_FILE, AFTER_SNAPSHOT_TEXT, buffer),
        "the system volume takes a new file after its snapshot")?
    // The snapshot reads as the volume did, its modules and not what was written after, and only reads
    snapshot := os.Channel[read_only_dir.ReadOnlyDir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_named(manager.end, manager.port, container, "system@before", "") {
        case OpenedReadOnlyFiles(root) => snapshot = root
        case _ => return stopped(t, "a snapshot opens by its volume's name and its own, read only")
    }
    snapshot_bound :: os.port_for(budget, snapshot.end)
    snapshot_port :: testing.require_some(t, snapshot_bound, "the budget has room for a port")?
    module : u8[..]
    defer runtime.array_free(&module)
    testing.require(t, read_whole_read_only(snapshot.end, snapshot_port, MODULE_ON_VOLUME, buffer, &module),
        "a snapshot has the files its volume had when it was taken")?
    testing.require_ne(t, module.count, 0, "hello's module isn't empty in the snapshot")?
    missing : u8[..]
    defer runtime.array_free(&missing)
    testing.expect(t, !read_whole_read_only(snapshot.end, snapshot_port, AFTER_SNAPSHOT_FILE, buffer, &missing),
        "a snapshot hasn't what its volume was given after it was taken")
    // Among the volume's snapshots
    out := os.Outgoing.{}
    listing :: os.begin[storage.Request](&out)
    listing^ = .SnapshotAt(storage.SnapshotIndexOf.{partition = container, volume = bytes_of(&out, SYSTEM_VOLUME), index = 0})
    into := os.Incoming.{}
    sent :: storage.send_request(manager.end, manager.port, &out)
    received := sent is_none
    if received {
        loop {
            match storage.receive_response(manager.end, manager.port, &into, true) {
                case Received => break
                case _ => {
                    received = false
                    break
                }
            }
        }
    }
    if !received {
        testing.fail(t, "the storage manager answers what a volume's first snapshot is")
    }
    else {
        match os.message_of[storage.Response](&into)^ {
            case Snapshot(info) => {
                name :: os.items(&into, info.name)
                testing.expect(t, same_text(name, SNAPSHOT), "the system volume's first snapshot is the one just taken, its only one")
            }
            case _ => testing.fail(t, "the system volume has a snapshot, its first the one just taken")
        }
    }
    // A clone, written to apart from the volume
    out = os.Outgoing.{}
    cloning :: os.begin[storage.Request](&out)
    cloning^ = .Clone(storage.CloneOf.{partition = container, volume = bytes_of(&out, SYSTEM_VOLUME), snapshot = bytes_of(&out, SNAPSHOT),
        name = bytes_of(&out, CLONE)})
    match ask_storage(manager.end, manager.port, &out) {
        case Done => {}
        case _ => return stopped(t, "the storage manager clones a snapshot as a volume of its own")
    }
    clone := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_named(manager.end, manager.port, container, CLONE, "") {
        case OpenedFiles(root) => clone = root
        case _ => return stopped(t, "a clone opens by its name, to write")
    }
    given.clone = clone
    clone_bound :: os.port_for(budget, clone.end)
    clone_port :: testing.require_some(t, clone_bound, "the budget has room for a port")?
    from_clone : u8[..]
    defer runtime.array_free(&from_clone)
    testing.expect(t, read_whole(clone.end, clone_port, MODULE_ON_VOLUME, buffer, &from_clone), "a clone has its snapshot's files")
    testing.expect_eq(t, from_clone.count, module.count, "a clone's files are its snapshot's")
    testing.expect(t, write_new(clone.end, clone_port, CLONE_FILE, CLONE_TEXT, buffer) && holds(clone.end, clone_port, CLONE_FILE, CLONE_TEXT, buffer),
        "a clone takes a new file, and reads it back")
    not_there : u8[..]
    defer runtime.array_free(&not_there)
    testing.expect(t, !read_whole(system.end, system_port, CLONE_FILE, buffer, &not_there), "what's written to a clone isn't in its volume")
    // The snapshot stays while its clone is there
    match volume_request(manager.end, manager.port, container, SYSTEM_VOLUME, SNAPSHOT, .Delete) {
        case InUse => {}
        case _ => testing.fail(t, "a snapshot isn't deleted while a clone of it is there, but refused as in use")
    }
    // A snapshot of the encrypted volume, opened with its passphrase
    match volume_request(manager.end, manager.port, container, SEALED_VOLUME, "first", .Take) {
        case Done => {}
        case _ => return stopped(t, "the storage manager takes a snapshot of the encrypted volume it serves")
    }
    match open_named(manager.end, manager.port, container, "sealed@first", SEALED_PASSPHRASE) {
        case OpenedReadOnlyFiles(root) => {
            sealed_bound :: os.port_for(budget, root.end)
            sealed_port :: testing.require_some(t, sealed_bound, "the budget has room for a port")?
            text_storage : u8[64]
            text :: capitals(SEALED_TEXT, text_storage)
            back : u8[..]
            defer runtime.array_free(&back)
            testing.expect(t, read_whole_read_only(root.end, sealed_port, SEALED_FILE, buffer, &back) && same_text(back, text),
                "a snapshot of an encrypted volume reads, decrypted, as the volume did")
        }
        case _ => testing.fail(t, "a snapshot of an encrypted volume opens with the volume's passphrase")
    }
    return .Ok
}

/** What volume_request asks of a snapshot. */
SnapshotAction :: enum {
    /** Take it, as the volume is now. */
    Take,
    /** Delete it. */
    Delete,
}

/**
 * Ask the storage manager to take or delete a snapshot of a volume, at time 1.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The container's index among the storage manager's partitions.
 * @param volume The volume's name in the container; one no volume has is answered NoVolume.
 * @param snapshot The name of the snapshot to take, or to delete: taking one the volume has already is answered
 *     AlreadyExists, and deleting one it hasn't, NoSnapshot.
 * @param action Whether it's taken or deleted.
 * @return The storage manager's answer: Done, InUse for a snapshot a clone keeps, or another refusal; Unsupported if
 *     it couldn't be asked.
 */
volume_request :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, volume: string, snapshot: string,
    action: SnapshotAction) -> storage.Response {

    out := os.Outgoing.{}
    request :: os.begin[storage.Request](&out)
    of :: storage.SnapshotOf.{partition = container, volume = bytes_of(&out, volume), snapshot = bytes_of(&out, snapshot), now = 1}
    request^ = if action == .Take { storage.Request.TakeSnapshot(of) } else { storage.Request.DeleteSnapshot(of) }
    return ask_storage(manager, port, &out)
}

/**
 * Ask the storage manager to open a container's volume, or a snapshot of one.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The container's index among the storage manager's partitions.
 * @param name The volume's name, or "volume@snapshot" for a snapshot.
 * @param passphrase The passphrase, for an encrypted volume, or "" for none.
 * @return The storage manager's answer: OpenedFiles with a volume's root, or OpenedReadOnlyFiles with a snapshot's,
 *     which the caller owns, or a refusal; Unsupported if it couldn't be asked.
 */
open_named :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, name: string, passphrase: string) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = container, name = bytes_of(&out, name), passphrase = bytes_of(&out, passphrase)})
    return ask_storage(manager, port, &out)
}
