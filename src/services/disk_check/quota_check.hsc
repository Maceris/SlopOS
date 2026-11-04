package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import storage from "../../protocols/storage"
import slopfs from "../../slopfs"

/*
 * Quotas (roadmap 8e), through the storage manager: the clone snapshot_check.hsc made given a quota a little past what
 * it has, which refuses a file's bytes past it and still takes a small file, kept in its tree; and its usage, which
 * says the quota. Checks from 100.
 */

/** The file whose bytes the quota refuses. */
QUOTA_FILE :: "Past the quota.bin"
/** A small file the quota still takes, kept in the volume's tree. */
SMALL_FILE :: "Within the quota.txt"
/** What SMALL_FILE holds. */
SMALL_TEXT :: "A small file, in the tree"
/** The bytes written to QUOTA_FILE: a whole chunk, 16 blocks, more than the quota leaves room for. */
LARGE_BYTES : usize : 65536

/**
 * Check quotas through the storage manager: give the clone snapshot_check.hsc made a quota 8 blocks past what it
 * uses, be refused a file's bytes past it, still write a small file, and read the quota back in its usage. Then check
 * volumes made at run time.
 *
 * @param to The debug log; unused, as what's found is logged through runtime.
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param clone A connection to the root of the clone named CLONE, writable, borrowed and not closed here: a file
 *     past its quota is tried in it, and a small one written and read back.
 * @param container The container's index among the storage manager's partitions.
 * @return 0 if all of it held; 100 if the buffer or a port couldn't be made, 101 if the clone's usage couldn't be
 *     had, 102 if the quota couldn't be set, 103 if the large file was written, 104 if the small one wasn't, or didn't
 *     read back, 105 and 106 if the usage after didn't say the quota or is past it by more than a chunk; and
 *     check_made's numbers.
 */
check_quotas :: fn(to: slop_os.DebugLog, manager: slop_os.Channel, port: slop_os.Port, clone: os.Channel[dir.Dir], container: u32) -> int {
    buffer := new_buffer() or_return 100
    budget :: slop_os.startup_block().budget
    clone_port :: os.port_for(budget, clone.end) or_return 100
    used :: usage_of(manager, port, container, CLONE) or_return 101
    quota :: used.used + 8
    out := os.Outgoing.{}
    setting :: os.begin[storage.Request](&out)
    setting^ = .SetQuota(storage.QuotaFor.{partition = container, volume = bytes_of(&out, CLONE), blocks = quota})
    match ask_storage(manager, port, &out) {
        case Done => {}
        case _ => return 102
    }
    if write_new_bytes(clone.end, clone_port, QUOTA_FILE, "", LARGE_BYTES, &buffer) {
        return 103
    }
    if !write_new(clone.end, clone_port, SMALL_FILE, SMALL_TEXT, &buffer) || !holds(clone.end, clone_port, SMALL_FILE, SMALL_TEXT, &buffer) {
        return 104
    }
    after :: usage_of(manager, port, container, CLONE) or_return 105
    if after.quota != quota || after.used > quota + 16 {
        return 106
    }
    runtime.log_info("quotas: its clone's refused a file past it and took a small one, and its usage says so")
    return check_made(manager, port, container, &buffer)
}

/**
 * Ask the storage manager for a volume's usage.
 *
 * @param manager The connection to the storage manager.
 * @param port A port bound to manager.
 * @param container The container's index among the storage manager's partitions.
 * @param volume The volume's name in the container; one no volume has is refused, giving null.
 * @return Its usage, in blocks, with its quota; null if it was refused or couldn't be asked.
 */
usage_of :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, volume: string) -> slopfs.Usage? {
    out := os.Outgoing.{}
    asking :: os.begin[storage.Request](&out)
    asking^ = .Usage(storage.VolumeNamed.{partition = container, name = bytes_of(&out, volume)})
    return match ask_storage(manager, port, &out) {
        case Used(usage) => usage
        case _ => null
    }
}
