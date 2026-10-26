package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import log_line from "../../log_line"
import storage from "../../protocols/storage"

/*
 * Snapshots and clones (roadmap 8e), through the storage manager: a snapshot of the system volume, which reads as the
 * volume did after a file is written to the volume, given as a read-only directory; found among the volume's
 * snapshots; a clone of it, written to apart from the volume; the snapshot refused deletion while its clone is there;
 * and a snapshot of the encrypted volume, opened with its passphrase. Checks from 80.
 */

SYSTEM_VOLUME :: "system"
SNAPSHOT :: "before"
CLONE :: "trial"
AFTER_SNAPSHOT_FILE :: "Written after the snapshot.txt"
AFTER_SNAPSHOT_TEXT :: "Written to the system volume after its snapshot was taken"
CLONE_FILE :: "Written to the clone.txt"
CLONE_TEXT :: "Written to a clone of the system volume's snapshot"

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
    log_line.write(to, "disk_check: snapshots: read one of the system volume as it was, read only, wrote to its clone, couldn't delete it while cloned, and read one of the sealed volume")
    return check_quotas(to, manager, port, clone, container)
}

SnapshotAction :: enum {
    Take,
    Delete,
}

// A snapshot of a volume taken or deleted.
volume_request :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, volume: string, snapshot: string,
    action: SnapshotAction) -> storage.Response {

    out := os.Outgoing.{}
    request :: os.begin[storage.Request](&out)
    of :: storage.SnapshotOf.{partition = container, volume = bytes_of(&out, volume), snapshot = bytes_of(&out, snapshot), now = 1}
    request^ = if action == .Take { storage.Request.TakeSnapshot(of) } else { storage.Request.DeleteSnapshot(of) }
    return ask_storage(manager, port, &out)
}

// A container's volume, or "volume@snapshot", opened, with a passphrase if it's encrypted, or without one, if it's empty.
open_named :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, name: string, passphrase: string) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = container, name = bytes_of(&out, name), passphrase = bytes_of(&out, passphrase)})
    return ask_storage(manager, port, &out)
}
