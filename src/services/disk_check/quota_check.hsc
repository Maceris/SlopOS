package disk_check

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import storage from "../../protocols/storage"
import slopfs from "../../slopfs"

/*
 * Quotas (roadmap 8e), through the storage manager: the clone snapshot_check.hsc made given a quota a little past what
 * it has, which refuses a file's bytes past it and still takes a small file, kept in its tree; and its usage, which
 * says the quota. Checks from 100.
 */

QUOTA_FILE :: "Past the quota.bin"
SMALL_FILE :: "Within the quota.txt"
SMALL_TEXT :: "A small file, in the tree"
// A whole chunk, 16 blocks, more than the quota leaves room for
LARGE_BYTES : usize : 65536

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
    log_line.write(to, "disk_check: quotas: its clone's refused a file past it and took a small one, and its usage says so")
    return 0
}

// A volume's usage, through the storage manager.
usage_of :: fn(manager: slop_os.Channel, port: slop_os.Port, container: u32, volume: string) -> slopfs.Usage? {
    out := os.Outgoing.{}
    asking :: os.begin[storage.Request](&out)
    asking^ = .Usage(storage.VolumeNamed.{partition = container, name = bytes_of(&out, volume)})
    return match ask_storage(manager, port, &out) {
        case Used(usage) => usage
        case _ => null
    }
}
