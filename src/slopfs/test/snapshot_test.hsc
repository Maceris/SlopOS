package slopfs_test

import runtime from "base"
import testing from "std"
import slopfs from ".."

/*
 * Snapshots and clones (roadmap 8e, slopfs/snapshot.hsc): a volume's snapshot reads as the volume did when it was
 * taken, while what the volume gives back that it holds goes on its dead list rather than being freed; deleting a
 * snapshot frees only what no other one holds; a clone starts as a snapshot, changes apart from its origin, and gives
 * back nothing of its origin's; a snapshot with a clone can't be deleted; everything holds across a mount, and the
 * container checks out whole at every step. Then the same for an encrypted volume, whose clone unlocks with its
 * origin's passphrase and shares its key generations.
 */

/** The size of the snapshot test's disk, in blocks: 8 MiB. */
SNAPSHOT_BLOCKS : u64 : 2048
/** What a file holds when the snapshot is taken, which the snapshot keeps reading. */
FIRST_TEXT :: "what the volume held when the snapshot was taken"
/** What the file is changed to after the snapshot, which only the volume reads. */
SECOND_TEXT :: "what it holds now"

/**
 * Get text's bytes, as a volume's or a snapshot's name.
 *
 * @param text The text, whose bytes are viewed, not copied.
 * @return Its bytes, a view of it.
 */
name_bytes :: fn(text: string) -> u8[] {
    return string_bytes(text)
}

/**
 * Tell whether the file of a name in a volume's root holds text and only that.
 *
 * @param volume The volume under test, open.
 * @param name The name looked up in the volume's root; nothing of the name makes the answer false.
 * @param text The text, at most 256 bytes.
 * @return True if the file is there and its bytes are text's; false otherwise, or on any error.
 */
file_holds :: fn(volume: ptr[mut slopfs.Volume], name: string, text: u8[]) -> bool {
    file :: match slopfs.lookup(volume, slopfs.ROOT_OBJECT, name) {
        case Ok(found) => found or_return false
        case Error(error) => return false
    }
    bytes : u8[256]
    count :: slopfs.read(volume, file, 0, bytes) or_return false
    return count == text.count && count <= bytes.count && same(bytes[0..<count], text)
}

/**
 * Tell whether a large file in a volume's root holds the pattern a seed makes, and nothing past it.
 *
 * @param volume The volume under test, open.
 * @param name The name looked up in the volume's root; nothing of the name makes the answer false.
 * @param seed What pattern made the file's bytes from, any u64; the same seed makes the same bytes.
 * @param size The bytes it should hold, at most a Data's.
 * @param data Where the pattern is made, overwritten.
 * @param back Where the file is read to, overwritten.
 * @return True if the file is there and its first size bytes are the pattern's; false otherwise, or on any error.
 */
large_holds :: fn(volume: ptr[mut slopfs.Volume], name: string, seed: u64, size: usize, data: ptr[mut Data], back: ptr[mut Data]) -> bool {
    file :: match slopfs.lookup(volume, slopfs.ROOT_OBJECT, name) {
        case Ok(found) => found or_return false
        case Error(error) => return false
    }
    if size > data.bytes.count || size > back.bytes.count {
        return false
    }
    pattern(data.bytes[0..<size], seed)
    count :: slopfs.read(volume, file, 0, back.bytes[0..<size]) or_return false
    return count == size && same(back.bytes[0..<size], data.bytes[0..<size])
}

/**
 * Count the extents on a volume's dead list.
 *
 * @param container The container under test, mounted.
 * @param id The volume whose dead list is read; one that isn't there has none, giving 0.
 * @return How many there are; 0xffffffff if the list couldn't be read.
 */
dead_count :: fn(container: ptr[mut slopfs.Container], id: u64) -> u64 {
    dead : slopfs.DeadExtent[..]
    defer runtime.array_free(&dead)
    match slopfs.dead_extents(container, id, &dead) {
        case Ok => return cast[u64](dead.count)
        case Error(error) => return 0xffffffff
    }
}

snapshots_and_clones_read_as_taken_and_free_only_what_nothing_holds #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_snapshots_of(t, false)
}

an_encrypted_volumes_snapshots_and_clones_read_as_taken_and_share_its_keys #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_snapshots_of(t, true)
}

/**
 * Check snapshots and clones: a volume's snapshot reads as the volume did when it was taken, while what the volume
 * gives back that it holds goes on its dead list rather than being freed; deleting a snapshot frees only what no other
 * one holds; a clone starts as a snapshot, changes apart from its origin, and gives back nothing of its origin's; a
 * snapshot with a clone can't be deleted; everything holds across a mount, and the container checks out whole at
 * every step. An encrypted volume's clone unlocks with its origin's passphrase and shares its key generations.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param sealed Whether the volume is encrypted.
 * @return Ok once it's all checked, whatever was found; Error(Failed), the failure recorded, if what follows couldn't
 *     go on.
 */
check_snapshots_of :: fn(t: ptr[mut testing.T], sealed: bool) -> testing.Outcome {
    device :: formatted(t, SNAPSHOT_BLOCKS, 0x50)?
    defer free_device(device)
    mounting :: slopfs.mount(device)
    container := testing.require_ok(t, mounting, "a formatted disk mounts")?
    creating :: create_test_volume(container, "origin", sealed)
    volume := testing.require_ok(t, creating, "a new container has room for a volume")?
    root :: slopfs.ROOT_OBJECT
    data := runtime.new(Data)
    defer runtime.free(data)
    back := runtime.new(Data)
    defer runtime.free(back)
    making_small :: slopfs.create(volume, root, "small.txt", .File)
    small :: testing.require_ok(t, making_small, "a file is made in the root")?
    writing_small :: slopfs.write(volume, small, 0, name_bytes(FIRST_TEXT))
    require_done(t, writing_small, "a file is written inline")?
    making_large :: slopfs.create(volume, root, "large.bin", .File)
    large :: testing.require_ok(t, making_large, "a second file is made in the root")?
    pattern(data.bytes[0..<200000], 11)
    writing_large :: slopfs.write(volume, large, 0, data.bytes[0..<200000])
    require_done(t, writing_large, "a file is written across chunks")?
    require_commit(t, container, "the files commit")?
    origin_id :: volume.id

    // A snapshot, then the volume changed: what it gives back that the snapshot holds goes on the dead list
    taking_one :: slopfs.take_snapshot(container, origin_id, name_bytes("one"), 10)
    require_done(t, taking_one, "a volume takes a snapshot")?
    require_commit(t, container, "the snapshot commits")?
    before_changes :: slopfs.free_blocks(container)
    rewriting_small :: slopfs.write(volume, small, 0, name_bytes(SECOND_TEXT))
    require_done(t, rewriting_small, "a file the snapshot holds is overwritten")?
    cutting_small :: slopfs.set_size(volume, small, cast[u64](SECOND_TEXT.count))
    require_done(t, cutting_small, "a file the snapshot holds is cut")?
    pattern(data.bytes[0..<200000], 12)
    rewriting_large :: slopfs.write(volume, large, 0, data.bytes[0..<200000])
    require_done(t, rewriting_large, "a file the snapshot holds is rewritten across its chunks")?
    making_later :: slopfs.create(volume, root, "later.txt", .File)
    later :: testing.require_ok(t, making_later, "a file is made after the snapshot")?
    writing_later :: slopfs.write(volume, later, 0, name_bytes(SECOND_TEXT))
    require_done(t, writing_later, "a file made after the snapshot is written")?
    require_commit(t, container, "the changes after the snapshot commit")?
    dead :: dead_count(container, origin_id)
    testing.expect_ne(t, dead, 0xffffffff, "the volume's dead list reads")
    testing.expect_ne(t, dead, 0, "what the volume gave back that the snapshot holds goes on its dead list")
    testing.expect(t, slopfs.free_blocks(container) < before_changes,
        "nothing the snapshot holds was freed: the rewrite took more space, it didn't swap it")

    // The snapshot reads as the volume did
    keys :: if sealed { unlocked_keys(container, origin_id) } else { null }
    testing.require(t, !sealed || (keys is_some), "an encrypted volume's keys unlock with its passphrase, for its snapshot")?
    opening_one :: slopfs.open_snapshot(container, origin_id, name_bytes("one"), keys)
    one :: testing.require_ok(t, opening_one, "a snapshot opens")?
    testing.expect(t, file_holds(one, "small.txt", name_bytes(FIRST_TEXT)), "a snapshot reads a file as it was when taken")
    testing.expect(t, large_holds(one, "large.bin", 11, 200000, data, back), "a snapshot reads a file across chunks as it was when taken")
    looking_later :: slopfs.lookup(one, root, "later.txt")
    later_in_one :: testing.require_ok(t, looking_later, "a snapshot looks up a name")?
    testing.expect_none(t, later_in_one, "a file made after a snapshot isn't in it")
    slopfs.free_volume(one)
    testing.expect(t, file_holds(volume, "small.txt", name_bytes(SECOND_TEXT)), "the volume reads a file as changed after the snapshot")
    testing.expect(t, large_holds(volume, "large.bin", 12, 200000, data, back), "the volume reads a file across chunks as changed after the snapshot")

    // A second snapshot and a clone of it, changed apart
    taking_two :: slopfs.take_snapshot(container, origin_id, name_bytes("two"), 20)
    require_done(t, taking_two, "a volume takes a second snapshot")?
    require_commit(t, container, "the second snapshot commits")?
    cloning :: slopfs.clone_snapshot(container, origin_id, name_bytes("two"), name_bytes("copy"), 30)
    clone_id :: testing.require_ok(t, cloning, "a snapshot is cloned")?
    require_commit(t, container, "the clone commits")?
    opening_copy :: open_test_volume_id(container, clone_id, sealed)
    copy := testing.require_ok(t, opening_copy, "a clone opens, an encrypted one with its origin's passphrase")?
    testing.expect(t, file_holds(copy, "small.txt", name_bytes(SECOND_TEXT)), "a clone starts as the snapshot it's of")
    testing.expect(t, large_holds(copy, "large.bin", 12, 200000, data, back), "a clone starts as the snapshot it's of, across chunks")
    // Its own writes, and one of its origin's files given back, which stays its origin's
    making_own :: slopfs.create(copy, root, "own.txt", .File)
    own :: testing.require_ok(t, making_own, "a clone makes a file of its own")?
    writing_own :: slopfs.write(copy, own, 0, name_bytes(FIRST_TEXT))
    require_done(t, writing_own, "a clone writes a file of its own")?
    removing_later :: slopfs.remove(copy, root, "later.txt")
    require_done(t, removing_later, "a clone removes a file it shares with its origin")?
    pattern(data.bytes[0..<100000], 13)
    copy_large :: testing.require_some(t, found(copy, root, "large.bin"), "a clone has its origin's files")?
    rewriting_copy :: slopfs.write(copy, copy_large, 0, data.bytes[0..<100000])
    require_done(t, rewriting_copy, "a clone overwrites a file it shares with its origin")?
    require_commit(t, container, "the clone's changes commit")?
    testing.expect(t, file_holds(volume, "later.txt", name_bytes(SECOND_TEXT)), "a file a clone removed is still its origin's")
    testing.expect(t, large_holds(volume, "large.bin", 12, 200000, data, back), "a file a clone overwrote is as it was in its origin")
    looking_own :: slopfs.lookup(volume, root, "own.txt")
    own_in_origin :: testing.require_ok(t, looking_own, "the origin looks up a name")?
    testing.expect_none(t, own_in_origin, "a clone's own file isn't its origin's")
    // Not while its clone is there
    deleting_two :: slopfs.delete_snapshot(container, origin_id, name_bytes("two"), null)
    testing.expect_error(t, deleting_two, .InUse, "a snapshot with a clone isn't deleted, as the clone is made from it")

    // Deleting the first frees what only it held
    before_delete :: slopfs.free_blocks(container)
    deleting_one :: slopfs.delete_snapshot(container, origin_id, name_bytes("one"), null)
    require_done(t, deleting_one, "a snapshot without a clone is deleted")?
    require_commit(t, container, "the deletion commits")?
    testing.expect(t, slopfs.free_blocks(container) > before_delete, "deleting a snapshot frees what only it held")

    // All of it across a mount
    slopfs.unmount(container)
    mounting_again :: slopfs.mount(device)
    container = testing.require_ok(t, mounting_again, "the container mounts again")?
    checks_out(t, container, "snapshots, a clone and dead lists check out after a mount")
    reopening :: open_test_volume_id(container, origin_id, sealed)
    volume = testing.require_ok(t, reopening, "the origin opens after a mount")?
    reopening_copy :: open_test_volume_id(container, clone_id, sealed)
    copy = testing.require_ok(t, reopening_copy, "the clone opens after a mount")?
    testing.expect(t, file_holds(copy, "own.txt", name_bytes(FIRST_TEXT)), "a clone's own file is kept across a mount")
    testing.expect(t, large_holds(copy, "large.bin", 13, 100000, data, back), "a clone's overwrite is kept across a mount")
    testing.expect(t, file_holds(volume, "later.txt", name_bytes(SECOND_TEXT)), "the origin's file the clone removed is kept across a mount")
    gone :: slopfs.open_snapshot(container, origin_id, name_bytes("one"), null)
    testing.expect(t, gone is_error, "a deleted snapshot is gone after a mount")
    // Still holding what its clone shares: a change to the origin now, and the clone reads as it did
    pattern(data.bytes[0..<200000], 14)
    origin_large :: testing.require_some(t, found(volume, root, "large.bin"), "the origin still has its file")?
    rewriting_origin :: slopfs.write(volume, origin_large, 0, data.bytes[0..<200000])
    require_done(t, rewriting_origin, "the origin overwrites a file its clone shares")?
    removing_small :: slopfs.remove(volume, root, "small.txt")
    require_done(t, removing_small, "the origin removes a file its clone shares")?
    require_commit(t, container, "the origin's changes commit")?
    testing.expect(t, file_holds(copy, "small.txt", name_bytes(SECOND_TEXT)), "a file its origin removed is still the clone's")
    testing.expect(t, large_holds(copy, "large.bin", 13, 100000, data, back), "a file its origin overwrote is as the clone had it")
    if sealed {
        // A clone's generations are its origin's key records'
        rotating :: slopfs.rotate(container, copy)
        generation :: testing.require_ok(t, rotating, "an encrypted clone takes a new key generation")?
        testing.expect_eq(t, generation, 2, "a clone's generations follow its origin's")
        making_after :: slopfs.create(copy, root, "after.txt", .File)
        after :: testing.require_ok(t, making_after, "an encrypted clone makes a file with its new generation")?
        writing_after :: slopfs.write(copy, after, 0, name_bytes(SECOND_TEXT))
        require_done(t, writing_after, "an encrypted clone writes a file with its new generation")?
        require_commit(t, container, "the clone's new generation commits")?
        slopfs.unmount(container)
        mounting_last :: slopfs.mount(device)
        container = testing.require_ok(t, mounting_last, "the container mounts again")?
        reopening_last :: open_test_volume_id(container, clone_id, sealed)
        copy = testing.require_ok(t, reopening_last, "the clone opens again with its origin's passphrase")?
        testing.expect(t, file_holds(copy, "after.txt", name_bytes(SECOND_TEXT)), "a file sealed with a clone's new generation reads after a mount")
        testing.expect(t, file_holds(copy, "own.txt", name_bytes(FIRST_TEXT)), "a file sealed with the first generation still reads")
        reading_newest :: slopfs.newest_generation(container, origin_id)
        newest :: testing.require_ok(t, reading_newest, "the origin's key records read")?
        testing.expect_eq(t, newest, 2, "a clone's new generation is in its origin's key records, which it shares")
    }
    slopfs.unmount(container)
    return .Ok
}

/**
 * Open a volume by its ID: as it is, or unlocked with the tests' passphrase.
 *
 * @param container The container, which keeps the volume among its open ones.
 * @param id The volume to open, which has to be in the container; one open already is given back as it is.
 * @param sealed Whether the volume is encrypted.
 * @return The volume, or why it couldn't be opened, as open_volume or open_sealed_volume says.
 */
open_test_volume_id :: fn(container #escaping : ptr[mut slopfs.Container], id: u64, sealed: bool) -> Result[ptr[mut slopfs.Volume], slopfs.Error] {
    if sealed {
        return slopfs.open_sealed_volume(container, id, passphrase())
    }
    return slopfs.open_volume(container, id)
}

/**
 * Unlock an encrypted volume's keys with the tests' passphrase, for opening a snapshot of it.
 *
 * @param container The container under test, mounted.
 * @param id The volume's ID, whose own key records are used.
 * @return The keys, the caller's (open_snapshot takes them); null if they couldn't be read or unlocked.
 */
unlocked_keys :: fn(container: ptr[mut slopfs.Container], id: u64) -> ptr[mut slopfs.Keys]? {
    record :: slopfs.volume_record(container, id) or_return null
    wraps : slopfs.WrapRecord[..]
    defer runtime.array_free(&wraps)
    generations : slopfs.NumberedGeneration[..]
    defer runtime.array_free(&generations)
    if slopfs.volume_wraps(container, id, &wraps) is_error {
        return null
    }
    if slopfs.volume_generations(container, id, &generations) is_error {
        return null
    }
    keys :: slopfs.new_keys(.None) or_return null
    match slopfs.unlock(container.id, id, record, wraps, generations, passphrase(), keys) {
        case Ok => return keys
        case Error(error) => {
            slopfs.free_keys(keys)
            return null
        }
    }
}
