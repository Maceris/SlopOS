package slopfs_test

import runtime from "base"
import testing from "std"
import slopfs from ".."

/*
 * Quotas and the reserve (roadmap 8e, slopfs/space.hsc): a volume's files written until its quota refuses more, and a
 * file deleted at its quota, which makes room; a snapshot's blocks kept charged to its volume, so deleting files under
 * it frees nothing until the snapshot goes; a container filled to its reserve, where deleting and committing still
 * work; and a volume's count of its blocks, which always matches the owners tree, across a mount.
 */

/** The size of the quota test's disk, in blocks: 8 MiB. */
QUOTA_BLOCKS : u64 : 2048
/** The bytes of each file the tests write: one chunk, slopfs.CHUNK_BYTES, so 16 blocks. */
CHUNK : usize : 65536

/**
 * Count the blocks the owners tree says a volume has, as its last commit (or this transaction's changes taken so
 * far) left them.
 *
 * @param container The container under test, mounted.
 * @param id The volume whose owners records are summed; any ID, one with none giving 0.
 * @return The blocks; all ones if the owners tree couldn't be read.
 */
owned_blocks :: fn(container: ptr[mut slopfs.Container], id: u64) -> u64 {
    value := slopfs.OwnerValue.{}
    at := slopfs.Key.{}
    total : u64 = 0
    loop {
        found :: match slopfs.tree_next(&container.nodes, &container.owners, at, view_of(cast[ptr[mut u8]](&value), size_of(slopfs.OwnerValue))) {
            case Ok(next) => next or_break
            case Error(error) => return 0xffffffffffffffff
        }
        if cast[u64](value.volume) == id {
            total += cast[u64](value.blocks)
        }
        at = slopfs.key_after(found.key) or_break
    }
    return total
}

/**
 * Tell whether a volume's count of its blocks is what the owners tree says; it should be once committed.
 *
 * @param container The container under test, mounted.
 * @param id The volume to compare; any ID, one with no account and no owners records counting as 0 both ways.
 * @return True if usage_of's used is owned_blocks'.
 */
counted :: fn(container: ptr[mut slopfs.Container], id: u64) -> bool {
    return slopfs.usage_of(container, id).used == owned_blocks(container, id)
}

/**
 * Make a new file of a chunk's bytes in the root, named by a number; one that can't be written whole is removed.
 *
 * @param volume The volume under test, open.
 * @param number The file's number, its name.
 * @param data The bytes, the first CHUNK of them written.
 * @return True if it was made and written; false if either failed, as at a quota or the reserve.
 */
write_file :: fn(volume: ptr[mut slopfs.Volume], number: int, data: ptr[mut Data]) -> bool {
    name : u8[16]
    length :: name_of_number(name, number)
    file :: match slopfs.create(volume, slopfs.ROOT_OBJECT, string_of(&name[0], length), .File) {
        case Ok(made) => made
        case Error(error) => return false
    }
    match slopfs.write(volume, file, 0, data.bytes[0..<CHUNK]) {
        case Ok => return true
        case Error(error) => {
            _ = slopfs.remove(volume, slopfs.ROOT_OBJECT, string_of(&name[0], length))
            return false
        }
    }
}

/**
 * Remove a file in the root named by a number.
 *
 * @param volume The volume under test, open.
 * @param number The file's number, its name.
 * @return True if it was removed; false on any error.
 */
remove_file :: fn(volume: ptr[mut slopfs.Volume], number: int) -> bool {
    name : u8[16]
    length :: name_of_number(name, number)
    match slopfs.remove(volume, slopfs.ROOT_OBJECT, string_of(&name[0], length)) {
        case Ok => return true
        case Error(error) => return false
    }
}

/** A volume with a quota, as the quota tests start from it. */
Limited :: struct {
    /** The disk, of QUOTA_BLOCKS blocks, freed by free_limited. */
    device : slopfs.Device,
    /** The container, mounted while mounted is true. */
    container : ptr[mut slopfs.Container],
    /** Whether container is mounted, so free_limited unmounts it. */
    mounted : bool,
    /** The volume "limited", open in container, empty. */
    volume : ptr[mut slopfs.Volume],
    /** volume's ID. */
    id : u64,
    /** volume's quota in blocks: QUOTA. */
    quota : u64,
    /** A chunk of pattern 5 to write, from runtime.new, freed by free_limited. */
    data : ptr[mut Data],
}

/** The quota the quota tests' volume has, in blocks: five chunks' worth, and room for the tree. */
QUOTA : u64 : 5 * 16 + 16

/**
 * Format a container of QUOTA_BLOCKS blocks, make a volume, "limited", in it, and give it a quota of QUOTA blocks, all
 * committed; checking the volume's count of its blocks is what the owners tree says.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The volume, the caller's to free with free_limited; Error if any of it failed, the failure recorded and
 *     nothing left to free.
 */
limited :: fn(t: ptr[mut testing.T]) -> Result[Limited, testing.Stopped] {
    device :: formatted(t, QUOTA_BLOCKS, 0x90)?
    made := Limited.{device = device, quota = QUOTA, data = runtime.new(Data)}
    pattern(made.data.bytes[0..<CHUNK], 5)
    if limit(t, &made) is_error {
        free_limited(&made)
        return .Error(.Failed)
    }
    return .Ok(made)
}

/**
 * Do limited's work on its formatted disk.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The disk, formatted; the rest is set here.
 * @return Ok if it's all done; Error(Failed), the failure recorded, if not.
 */
limit :: fn(t: ptr[mut testing.T], made: ptr[mut Limited]) -> testing.Outcome {
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a formatted disk mounts")?
    made.mounted = true
    creating :: slopfs.create_volume(made.container, "limited", key_of_volume(), 1)
    made.volume = testing.require_ok(t, creating, "a new container has room for a volume")?
    made.id = made.volume.id
    require_commit(t, made.container, "a new volume commits")?
    setting :: slopfs.set_quota(made.container, made.id, made.quota)
    require_done(t, setting, "a volume takes a quota")?
    require_commit(t, made.container, "a quota commits")?
    testing.expect(t, counted(made.container, made.id), "a volume's count of its blocks is the owners tree's, once committed")
    return .Ok
}

/**
 * Give back what limited made: the container unmounted if it's mounted, the disk and data freed.
 *
 * @param made What limited made, which isn't used after.
 */
free_limited :: fn(made: ptr[mut Limited]) {
    if made.mounted {
        slopfs.unmount(made.container)
    }
    runtime.free(made.data)
    free_device(made.device)
}

/**
 * Write files of a chunk each, numbered from 0, until the quota refuses one, and commit them, checking they stop near
 * the quota and the counts still match.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The volume with a quota, empty.
 * @return How many files were written, numbered 0 on; Error(Failed), the failure recorded, if they didn't commit.
 */
fill_to_quota :: fn(t: ptr[mut testing.T], made: ptr[mut Limited]) -> Result[int, testing.Stopped] {
    written := 0
    for number in 0..<20 {
        if !write_file(made.volume, number, made.data) {
            break
        }
        written += 1
    }
    testing.expect(t, written >= 4 && written <= 6, "a quota of five chunks and room for the tree takes about five chunks")
    require_commit(t, made.container, "what was written within the quota commits")?
    testing.expect(t, counted(made.container, made.id), "a volume's count of its blocks is the owners tree's, once committed")
    testing.expect(t, slopfs.usage_of(made.container, made.id).used <= made.quota + 16, "a volume uses at most its quota and a chunk")
    return .Ok(written)
}

writes_stop_at_the_quota_and_a_delete_makes_room #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := limited(t)?
    defer free_limited(&made)
    fill_to_quota(t, &made)?
    testing.expect(t, remove_file(made.volume, 0), "deleting works at the quota, though it rewrites the tree")
    require_commit(t, made.container, "a delete at the quota commits")?
    testing.expect(t, write_file(made.volume, 100, made.data), "a delete at the quota makes room for another file")
    require_commit(t, made.container, "a file written in the room made commits")?
    testing.expect(t, counted(made.container, made.id), "a volume's count of its blocks is the owners tree's, once committed")
    return .Ok
}

a_snapshot_keeps_its_blocks_charged_until_it_goes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := limited(t)?
    defer free_limited(&made)
    container :: made.container
    written :: fill_to_quota(t, &made)?
    taking :: slopfs.take_snapshot(container, made.id, name_bytes("held"), 2)
    require_done(t, taking, "a volume at its quota takes a snapshot, which takes no blocks of its own")?
    require_commit(t, container, "the snapshot commits")?
    before :: slopfs.usage_of(container, made.id).used
    for number in 0..<written {
        _ = remove_file(made.volume, number)
    }
    require_commit(t, container, "removing the files commits")?
    testing.expect(t, counted(container, made.id), "a volume's count of its blocks is the owners tree's with a snapshot")
    testing.expect(t, slopfs.usage_of(container, made.id).used + 8 >= before,
        "files deleted under a snapshot free nothing: the snapshot holds their blocks, charged to the volume")
    testing.expect(t, !write_file(made.volume, 200, made.data), "with the snapshot's blocks charged, the volume is still at its quota")
    deleting :: slopfs.delete_snapshot(container, made.id, name_bytes("held"), null)
    require_done(t, deleting, "a snapshot without clones is deleted")?
    require_commit(t, container, "the snapshot's deletion commits")?
    testing.expect(t, counted(container, made.id), "a volume's count of its blocks is the owners tree's once its snapshot goes")
    testing.expect(t, slopfs.usage_of(container, made.id).used < before, "deleting the snapshot frees the blocks only it held")
    testing.expect(t, write_file(made.volume, 200, made.data), "with the snapshot gone, there's room under the quota")
    _ = commits(t, container, "a file written once the snapshot went commits")
    return .Ok
}

the_quota_and_every_count_last_across_a_mount #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := limited(t)?
    defer free_limited(&made)
    written :: fill_to_quota(t, &made)?
    // All but one removed, so some more fit, but not six
    for number in 1..<written {
        testing.expect(t, remove_file(made.volume, number), "each file written is removed")
    }
    require_commit(t, made.container, "the removals commit")?
    require_commit(t, made.container, "a commit after the removals frees what they gave back")?
    slopfs.unmount(made.container)
    made.mounted = false
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "the container mounts again")?
    made.mounted = true
    testing.expect(t, counted(made.container, made.id), "a volume's count of its blocks is the owners tree's after a mount")
    testing.expect_eq(t, slopfs.usage_of(made.container, made.id).quota, made.quota, "a volume's quota is kept across a mount")
    opening :: slopfs.open_volume(made.container, made.id)
    made.volume = testing.require_ok(t, opening, "the volume opens again")?
    all_six := true
    for number in 300..<306 {
        if !write_file(made.volume, number, made.data) {
            all_six = false
            break
        }
    }
    testing.expect(t, !all_six, "six more chunks don't fit a quota of five beside the one kept: it holds after a mount")
    return .Ok
}

the_reserve_keeps_room_to_delete_and_commit #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    blocks : u64 = 512
    device :: formatted(t, blocks, 0xa0)?
    defer free_device(device)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    defer slopfs.unmount(container)
    creating :: slopfs.create_volume(container, "full", key_of_volume(), 1)
    volume :: testing.require_ok(t, creating, "a new container has room for a volume")?
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes[0..<CHUNK], 6)
    written := 0
    for number in 0..<100 {
        if !write_file(volume, number, data) {
            break
        }
        written += 1
        if number % 4 == 3 {
            require_commit(t, container, "every fourth file written commits")?
        }
    }
    testing.expect_ne(t, written, 0, "an empty container has room for a file")
    require_commit(t, container, "a container full to its reserve commits")?
    // Full to the reserve, which only a file's bytes keep out of
    reserve :: slopfs.reserve_of(blocks)
    testing.expect_ge(t, slopfs.free_blocks(container) + 16, reserve, "files' bytes don't go into the reserve")
    testing.expect(t, slopfs.free_blocks(container) <= reserve + 16 + 2 * slopfs.NODE_BLOCKS * 4,
        "files' bytes take everything but the reserve, a chunk, and the trees' nodes")
    full :: slopfs.free_blocks(container)
    for number in 0..<written {
        testing.expect(t, remove_file(volume, number), "deleting works full to the reserve, the tree's rewrite taken from it")
    }
    require_commit(t, container, "deletes full to the reserve commit")?
    require_commit(t, container, "a commit after the deletes frees what they gave back")?
    testing.expect_gt(t, slopfs.free_blocks(container), full, "deleting full to the reserve frees blocks")
    return .Ok
}
