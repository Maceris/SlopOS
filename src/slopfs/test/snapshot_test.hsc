package slopfs_test

import runtime from "base"
import slopfs from ".."

/*
 * Snapshots and clones (roadmap 8e, slopfs/snapshot.hsc): a volume's snapshot reads as the volume did when it was
 * taken, while what the volume gives back that it holds goes on its dead list rather than being freed; deleting a
 * snapshot frees only what no other one holds; a clone starts as a snapshot, changes apart from its origin, and gives
 * back nothing of its origin's; a snapshot with a clone can't be deleted; everything holds across a mount, and the
 * container checks out whole at every step. Then the same for an encrypted volume, whose clone unlocks with its
 * origin's passphrase and shares its key generations. Checks from 900.
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

/**
 * Check snapshots and clones on a volume that isn't encrypted, then on one that is.
 *
 * @return 0 if every check passed, or the number of the first that failed: 900 to 949, or 950 to 999 for the
 *     encrypted volume.
 */
check_snapshots :: fn() -> int {
    failed := check_snapshots_of(false, 900)
    if failed != 0 {
        return failed
    }
    return check_snapshots_of(true, 950)
}

/**
 * Check snapshots and clones: a volume's snapshot reads as the volume did when it was taken, while what the volume
 * gives back that it holds goes on its dead list rather than being freed; deleting a snapshot frees only what no other
 * one holds; a clone starts as a snapshot, changes apart from its origin, and gives back nothing of its origin's; a
 * snapshot with a clone can't be deleted; everything holds across a mount, and the container checks out whole at
 * every step. An encrypted volume's clone unlocks with its origin's passphrase and shares its key generations.
 *
 * @param sealed Whether the volume is encrypted.
 * @param base The number of the first check, the rest numbered after it.
 * @return 0 if every check passed, or the number of the first that failed, base to base + 49.
 */
check_snapshots_of :: fn(sealed: bool, base: int) -> int {
    device :: new_device_of(SNAPSHOT_BLOCKS) or_return base
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0x50 + i)
    }
    slopfs.format(device, id) or_return base + 1
    container := slopfs.mount(device) or_return base + 2
    volume := create_test_volume(container, "origin", sealed) or_return base + 3
    root :: slopfs.ROOT_OBJECT
    data := runtime.new(Data)
    defer runtime.free(data)
    back := runtime.new(Data)
    defer runtime.free(back)
    small :: slopfs.create(volume, root, "small.txt", .File) or_return base + 4
    slopfs.write(volume, small, 0, name_bytes(FIRST_TEXT)) or_return base + 4
    large :: slopfs.create(volume, root, "large.bin", .File) or_return base + 5
    pattern(data.bytes[0..<200000], 11)
    slopfs.write(volume, large, 0, data.bytes[0..<200000]) or_return base + 5
    if commit_failed(container) {
        return base + 6
    }
    origin_id :: volume.id

    // A snapshot, then the volume changed: what it gives back that the snapshot holds goes on the dead list
    slopfs.take_snapshot(container, origin_id, name_bytes("one"), 10) or_return base + 7
    if commit_failed(container) {
        return base + 8
    }
    before_changes :: slopfs.free_blocks(container)
    slopfs.write(volume, small, 0, name_bytes(SECOND_TEXT)) or_return base + 9
    slopfs.set_size(volume, small, cast[u64](SECOND_TEXT.count)) or_return base + 9
    pattern(data.bytes[0..<200000], 12)
    slopfs.write(volume, large, 0, data.bytes[0..<200000]) or_return base + 10
    later :: slopfs.create(volume, root, "later.txt", .File) or_return base + 11
    slopfs.write(volume, later, 0, name_bytes(SECOND_TEXT)) or_return base + 11
    if commit_failed(container) {
        return base + 12
    }
    if dead_count(container, origin_id) == 0 || dead_count(container, origin_id) == 0xffffffff {
        return base + 13
    }
    // Nothing the snapshot holds was freed: the rewrite took more space, it didn't swap it
    if slopfs.free_blocks(container) >= before_changes {
        return base + 14
    }

    // The snapshot reads as the volume did
    keys :: if sealed { unlocked_keys(container, origin_id) } else { null }
    if sealed && (keys is_none) {
        return base + 15
    }
    one := slopfs.open_snapshot(container, origin_id, name_bytes("one"), keys) or_return base + 16
    if !file_holds(one, "small.txt", name_bytes(FIRST_TEXT)) || !large_holds(one, "large.bin", 11, 200000, data, back) {
        return base + 17
    }
    match slopfs.lookup(one, root, "later.txt") {
        case Ok(found) => {
            if found is_some {
                return base + 18
            }
        }
        case Error(error) => return base + 18
    }
    slopfs.free_volume(one)
    if !file_holds(volume, "small.txt", name_bytes(SECOND_TEXT)) || !large_holds(volume, "large.bin", 12, 200000, data, back) {
        return base + 19
    }

    // A second snapshot and a clone of it, changed apart
    slopfs.take_snapshot(container, origin_id, name_bytes("two"), 20) or_return base + 20
    if commit_failed(container) {
        return base + 21
    }
    clone_id :: slopfs.clone_snapshot(container, origin_id, name_bytes("two"), name_bytes("copy"), 30) or_return base + 22
    if commit_failed(container) {
        return base + 23
    }
    copy := open_test_volume_id(container, clone_id, sealed) or_return base + 24
    if !file_holds(copy, "small.txt", name_bytes(SECOND_TEXT)) || !large_holds(copy, "large.bin", 12, 200000, data, back) {
        return base + 25
    }
    // Its own writes, and one of its origin's files given back, which stays its origin's
    own :: slopfs.create(copy, root, "own.txt", .File) or_return base + 26
    slopfs.write(copy, own, 0, name_bytes(FIRST_TEXT)) or_return base + 26
    slopfs.remove(copy, root, "later.txt") or_return base + 27
    pattern(data.bytes[0..<100000], 13)
    slopfs.write(copy, found(copy, root, "large.bin") or_return base + 28, 0, data.bytes[0..<100000]) or_return base + 28
    if commit_failed(container) {
        return base + 29
    }
    if !file_holds(volume, "later.txt", name_bytes(SECOND_TEXT)) || !large_holds(volume, "large.bin", 12, 200000, data, back) {
        return base + 30
    }
    match slopfs.lookup(volume, root, "own.txt") {
        case Ok(found) => {
            if found is_some {
                return base + 31
            }
        }
        case Error(error) => return base + 31
    }
    // Not while its clone is there
    match slopfs.delete_snapshot(container, origin_id, name_bytes("two"), null) {
        case Ok => return base + 32
        case Error(error) => {
            if error != .InUse {
                return base + 33
            }
        }
    }

    // Deleting the first frees what only it held
    before_delete :: slopfs.free_blocks(container)
    slopfs.delete_snapshot(container, origin_id, name_bytes("one"), null) or_return base + 34
    if commit_failed(container) {
        return base + 35
    }
    if slopfs.free_blocks(container) <= before_delete {
        return base + 36
    }

    // All of it across a mount
    slopfs.unmount(container)
    container = slopfs.mount(device) or_return base + 37
    if !verified(container) {
        return base + 38
    }
    volume = open_test_volume_id(container, origin_id, sealed) or_return base + 39
    copy = open_test_volume_id(container, clone_id, sealed) or_return base + 40
    if !file_holds(copy, "own.txt", name_bytes(FIRST_TEXT)) || !large_holds(copy, "large.bin", 13, 100000, data, back)
        || !file_holds(volume, "later.txt", name_bytes(SECOND_TEXT)) {
        return base + 41
    }
    if slopfs.open_snapshot(container, origin_id, name_bytes("one"), null) is_ok {
        return base + 42
    }
    // Still holding what its clone shares: a change to the origin now, and the clone reads as it did
    pattern(data.bytes[0..<200000], 14)
    slopfs.write(volume, found(volume, root, "large.bin") or_return base + 43, 0, data.bytes[0..<200000]) or_return base + 43
    slopfs.remove(volume, root, "small.txt") or_return base + 44
    if commit_failed(container) {
        return base + 45
    }
    if !file_holds(copy, "small.txt", name_bytes(SECOND_TEXT)) || !large_holds(copy, "large.bin", 13, 100000, data, back) {
        return base + 46
    }
    if sealed {
        // A clone's generations are its origin's key records'
        generation :: slopfs.rotate(container, copy) or_return base + 47
        if generation != 2 {
            return base + 48
        }
        after :: slopfs.create(copy, root, "after.txt", .File) or_return base + 49
        slopfs.write(copy, after, 0, name_bytes(SECOND_TEXT)) or_return base + 49
        if commit_failed(container) {
            return base + 49
        }
        slopfs.unmount(container)
        container = slopfs.mount(device) or_return base + 37
        copy = open_test_volume_id(container, clone_id, sealed) or_return base + 40
        if !file_holds(copy, "after.txt", name_bytes(SECOND_TEXT)) || !file_holds(copy, "own.txt", name_bytes(FIRST_TEXT)) {
            return base + 49
        }
        match slopfs.newest_generation(container, origin_id) {
            case Ok(newest) => {
                if newest != 2 {
                    return base + 49
                }
            }
            case Error(error) => return base + 49
        }
    }
    slopfs.unmount(container)
    return 0
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
