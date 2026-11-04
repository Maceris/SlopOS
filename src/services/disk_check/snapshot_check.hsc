package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import storage from "../../protocols/storage"

/*
 * Snapshots and clones (roadmap 8e), through the storage manager: a snapshot of the system volume, which reads as the
 * volume did after a file is written to the volume, given as a read-only directory; found among the volume's
 * snapshots; a clone of it, written to apart from the volume; the snapshot refused deletion while its clone is there;
 * and a snapshot of the encrypted volume, opened with its passphrase. Checks from 80.
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
 * Check snapshots and clones through the storage manager, then quotas and volumes made.
 *
 * @param to The debug log, passed on.
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param system The system volume's root.
 * @param container The container's index among the storage manager's partitions.
 * @return 0 if all of it held; 80 if the buffer or a port couldn't be made, 81 if the snapshot couldn't be taken, 82
 *     if the file after it couldn't be written, 83 to 85 if the snapshot couldn't be opened read-only, didn't read the
 *     module, or had the file written after it, 87 and 88 if it wasn't first among the volume's snapshots, 89 to 93 if
 *     the clone couldn't be made, opened, read, or written apart from the volume, 94 if deleting the snapshot wasn't
 *     refused as InUse, and 95 and 96 if a snapshot of the encrypted volume couldn't be taken or read; and
 *     check_quotas' numbers.
 */
check_snapshots :: fn(to: slop_os.DebugLog, manager: slop_os.Channel, port: slop_os.Port, system: os.Channel[dir.Dir], container: u32) -> int {
    buffer := new_buffer() or_return 80
    budget :: slop_os.startup_block().budget
    system_port :: os.port_for(budget, system.end) or_return 80
    match volume_request(manager, port, container, SYSTEM_VOLUME, SNAPSHOT, .Take) {
        case Done => {}
        case _ => return 81
    }
    if !write_new(system.end, system_port, AFTER_SNAPSHOT_FILE, AFTER_SNAPSHOT_TEXT, &buffer) {
        return 82
    }
    // The snapshot reads as the volume did, its modules and not what was written after, and only reads
    snapshot := os.Channel[read_only_dir.ReadOnlyDir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_named(manager, port, container, "system@before", "") {
        case OpenedReadOnlyFiles(root) => snapshot = root
        case _ => return 83
    }
    snapshot_port :: os.port_for(budget, snapshot.end) or_return 83
    module : u8[..]
    defer runtime.array_free(&module)
    if !read_whole_read_only(snapshot.end, snapshot_port, MODULE_ON_VOLUME, &buffer, &module) || module.count == 0 {
        return 84
    }
    missing : u8[..]
    defer runtime.array_free(&missing)
    if read_whole_read_only(snapshot.end, snapshot_port, AFTER_SNAPSHOT_FILE, &buffer, &missing) {
        return 85
    }
    // Among the volume's snapshots
    out := os.Outgoing.{}
    listing :: os.begin[storage.Request](&out)
    listing^ = .SnapshotAt(storage.SnapshotIndexOf.{partition = container, volume = bytes_of(&out, SYSTEM_VOLUME), index = 0})
    into := os.Incoming.{}
    if storage.send_request(manager, port, &out) is_some {
        return 87
    }
    loop {
        match storage.receive_response(manager, port, &into, true) {
            case Received => break
            case Failed(error) => return 87
            case _ => continue
        }
    }
    match os.message_of[storage.Response](&into)^ {
        case Snapshot(info) => {
            name :: os.items(&into, info.name)
            if !same_text(name, SNAPSHOT) {
                return 88
            }
        }
        case _ => return 88
    }
    // A clone, written to apart from the volume
    out = os.Outgoing.{}
    cloning :: os.begin[storage.Request](&out)
    cloning^ = .Clone(storage.CloneOf.{partition = container, volume = bytes_of(&out, SYSTEM_VOLUME), snapshot = bytes_of(&out, SNAPSHOT),
        name = bytes_of(&out, CLONE)})
    match ask_storage(manager, port, &out) {
        case Done => {}
        case _ => return 89
    }
    clone := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_named(manager, port, container, CLONE, "") {
        case OpenedFiles(root) => clone = root
        case _ => return 90
    }
    clone_port :: os.port_for(budget, clone.end) or_return 90
    from_clone : u8[..]
    defer runtime.array_free(&from_clone)
    if !read_whole(clone.end, clone_port, MODULE_ON_VOLUME, &buffer, &from_clone) || from_clone.count != module.count {
        return 91
    }
    if !write_new(clone.end, clone_port, CLONE_FILE, CLONE_TEXT, &buffer) || !holds(clone.end, clone_port, CLONE_FILE, CLONE_TEXT, &buffer) {
        return 92
    }
    not_there : u8[..]
    defer runtime.array_free(&not_there)
    if read_whole(system.end, system_port, CLONE_FILE, &buffer, &not_there) {
        return 93
    }
    // The snapshot stays while its clone is there
    match volume_request(manager, port, container, SYSTEM_VOLUME, SNAPSHOT, .Delete) {
        case InUse => {}
        case _ => return 94
    }
    // A snapshot of the encrypted volume, opened with its passphrase
    match volume_request(manager, port, container, SEALED_VOLUME, "first", .Take) {
        case Done => {}
        case _ => return 95
    }
    match open_named(manager, port, container, "sealed@first", SEALED_PASSPHRASE) {
        case OpenedReadOnlyFiles(root) => {
            sealed_port :: os.port_for(budget, root.end) or_return 96
            text_storage : u8[64]
            text :: capitals(SEALED_TEXT, text_storage)
            back : u8[..]
            defer runtime.array_free(&back)
            if !read_whole_read_only(root.end, sealed_port, SEALED_FILE, &buffer, &back) || !same_text(back, text) {
                return 96
            }
        }
        case _ => return 96
    }
    runtime.log_info("snapshots: read one of the system volume as it was, read only, wrote to its clone, couldn't delete it while cloned, and read one of the sealed volume")
    return check_quotas(to, manager, port, clone, container)
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
 * @param volume The volume's name.
 * @param snapshot The snapshot's name.
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
