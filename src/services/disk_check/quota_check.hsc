package disk_check

import os from "std"
import slop_os from "std/os"
import testing from "std"
import storage from "../../protocols/storage"
import slopfs from "../../slopfs"
import test_kit from "../../test_kit"

/*
 * Quotas (roadmap 8e), through the storage manager: the clone snapshot_check.hsc made given a quota a little past what
 * it has, which refuses a file's bytes past it and still takes a small file, kept in its tree; and its usage, which
 * says the quota.
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
 * Check quotas through the storage manager: give the clone the snapshots' test made a quota 8 blocks past what it
 * uses, be refused a file's bytes past it, still write a small file, and read the quota back in its usage.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the clone wasn't made, the buffer or a port couldn't be made, or the clone's
 *     usage couldn't be had or its quota set.
 */
a_quota_refuses_what_is_past_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    // Beside the system volume, so skipped without it
    _ = system_of(t, given)?
    manager :: manager_of(t, given)?
    clone :: testing.require_some(t, given.clone, "the snapshots' test, run before, made and opened the clone")?
    container :: testing.require_some(t, given.container, "the sealed volume's test, run before, found the container")?
    buffer :: buffer_of(t, given)?
    bound :: os.port_for(slop_os.startup_block().budget, clone.end)
    clone_port :: testing.require_some(t, bound, "the budget has room for a port")?
    before :: usage_of(manager.end, manager.port, container, CLONE)
    used :: testing.require_some(t, before, "the storage manager says the usage of a volume it serves")?
    quota :: used.used + 8
    out := os.Outgoing.{}
    setting :: os.begin[storage.Request](&out)
    setting^ = .SetQuota(storage.QuotaFor.{partition = container, volume = bytes_of(&out, CLONE), blocks = quota})
    match ask_storage(manager.end, manager.port, &out) {
        case Done => {}
        case _ => return stopped(t, "the storage manager sets a quota on a volume it serves")
    }
    testing.expect(t, !write_new_bytes(clone.end, clone_port, QUOTA_FILE, "", LARGE_BYTES, buffer),
        "a file's 16 blocks aren't written past a quota 8 blocks above what the volume uses")
    testing.expect(t, write_new(clone.end, clone_port, SMALL_FILE, SMALL_TEXT, buffer) && holds(clone.end, clone_port, SMALL_FILE, SMALL_TEXT, buffer),
        "a small file, kept in the volume's tree, is still written within the quota, and reads back")
    after_usage :: usage_of(manager.end, manager.port, container, CLONE)
    after :: testing.require_some(t, after_usage, "the storage manager says the usage of a volume it serves")?
    testing.expect_eq(t, after.quota, quota, "a volume's usage says the quota set on it")
    testing.expect_le(t, after.used, quota + 16, "a volume uses at most a chunk past its quota, as only the chunk being written can go past it")
    return .Ok
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
