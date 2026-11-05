package slopfs_test

import runtime from "base"
import maps from "std"
import testing from "std"
import slopfs from ".."

/*
 * Volumes apart from their container, as volume servers hold them (decisions/0089): each with nodes of its own,
 * allocating from the container's space as its own owner, and committing alone. A commit takes only that volume's
 * changes and the container's own: after a crash, the other's uncommitted writes are gone without leaking a block,
 * and what it freed but hasn't committed is still its own, unused by anyone.
 */

/** A volume's side of its container: what a volume server's requests to the container service carry. */
Side :: struct {
    /** The container the volume is in. */
    container : ptr[mut slopfs.Container],
    /** The volume's ID, which every block it takes and gives back is charged to. */
    id : u64,
}

/**
 * Allocate blocks from the container's space for a volume apart, as the container service does for a volume server.
 *
 * @param context The volume's Side, as a rawptr.
 * @param blocks How many blocks.
 * @param owner Whose the tree says they are; the Side's ID is used instead.
 * @param data Whether they're for a file's bytes, which a quota and the reserve hold back.
 * @return The first block; null if there's no room, as space_allocate says.
 */
side_allocate :: fn(context: rawptr, blocks: u64, owner: u64, data: bool) -> u64? {
    side :: cast[ptr[mut Side]](context)
    return slopfs.space_allocate(cast[rawptr](&side.container.space), blocks, side.id, data)
}

/**
 * Give blocks back to the container's space for a volume apart, as the container service does for a volume server.
 *
 * @param context The volume's Side, as a rawptr.
 * @param address The extent's first block.
 * @param blocks Its length in blocks.
 * @param owner Whose the tree says it is; the Side's ID is used instead.
 * @param birth The transaction it was born in.
 */
side_release :: fn(context: rawptr, address: u64, blocks: u64, owner: u64, birth: u64) {
    side :: cast[ptr[mut Side]](context)
    slopfs.space_release(cast[rawptr](&side.container.space), address, blocks, side.id, birth)
}

/** A volume taken out of the container's process and opened on nodes of its own. */
Apart :: struct {
    /** What its nodes allocate and release through. */
    side : Side,
    /** Its own nodes, its own transaction's, which allocate from the container's space as the volume's owner. */
    nodes : slopfs.Nodes,
    /** The volume, open on nodes. */
    volume : ptr[mut slopfs.Volume],
}

/**
 * Take a volume out of the container's process and open it on nodes of its own, as a volume server does.
 *
 * @param container The container, which has to outlive what's made; the volume is closed in it first.
 * @param id The volume to take out, whose record has to be there; it's closed in the container if it's open.
 * @return What's made, the caller's to free with free_apart; null if the volume's record or memory for it couldn't
 *     be had.
 */
apart :: fn(container #escaping : ptr[mut slopfs.Container], id: u64) -> ptr[mut Apart]? {
    record :: slopfs.volume_record(container, id) or_return null
    slopfs.close_volume(container, id)
    made := runtime.new(Apart)
    made.side = Side.{container = container, id = id}
    made.nodes = slopfs.Nodes.{device = container.device, transaction = container.nodes.transaction, space = cast[rawptr](&made.side),
        allocate = side_allocate, release = side_release}
    match slopfs.attach_volume(&made.nodes, container.device, id, record, null) {
        case Ok(volume) => made.volume = volume
        case Error(error) => {
            runtime.free(made)
            return null
        }
    }
    return made
}

/**
 * Commit a volume apart, as a volume server does: its tree written, then its record committed by the container,
 * which takes only its changes and the container's own. Its nodes then make the container's next transaction.
 *
 * @param made The volume apart, from apart; its nodes start the container's next transaction.
 * @return True if it was committed; false on any error.
 */
commit_apart :: fn(made: ptr[mut Apart]) -> bool {
    record :: slopfs.write_volume(made.volume) or_return false
    if slopfs.commit_volume(made.side.container, made.side.id, &record) is_error {
        return false
    }
    made.nodes.transaction = made.side.container.nodes.transaction
    return true
}

/**
 * Free a volume apart: its dirty nodes, uncommitted changes lost with them, its volume and itself.
 *
 * @param made The volume apart, from apart; it may not be used again.
 */
free_apart :: fn(made: ptr[mut Apart]) {
    for i in 0..<made.nodes.dirty.used.count {
        if i < made.nodes.dirty.used.count && i < made.nodes.dirty.values.count && made.nodes.dirty.used[i] {
            runtime.free(made.nodes.dirty.values[i])
        }
    }
    maps.map_free(&made.nodes.dirty)
    slopfs.free_volume(made.volume)
    runtime.free(made)
}

/**
 * Find a volume's ID by its name.
 *
 * @param container The container under test, mounted.
 * @param name The name looked for, compared byte for byte with each volume's.
 * @return Its ID; 0 if no volume has the name, or it couldn't be looked up.
 */
volume_id :: fn(container: ptr[mut slopfs.Container], name: string) -> u64 {
    match slopfs.find_volume(container, name) {
        case Ok(found) => return found or_else 0
        case Error(error) => return 0
    }
}

volumes_apart_commit_alone_and_a_crash_keeps_each_ones_last_commit_leaking_nothing #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    device :: formatted(t, BLOCKS, 0)?
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    making_a :: slopfs.create_volume(container, "a", key_of_volume(), 1)
    require_done(t, making_a, "a new container has room for a volume")?
    making_b :: slopfs.create_volume(container, "b", key_of_volume(), 1)
    require_done(t, making_b, "a new container has room for a second volume")?
    require_commit(t, container, "the new volumes commit")?
    a :: testing.require_some(t, apart(container, volume_id(container, "a")), "a committed volume is taken apart")?
    b :: testing.require_some(t, apart(container, volume_id(container, "b")), "a second committed volume is taken apart")?
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, 7)

    // b's old file, committed, then removed without committing that
    making_old :: slopfs.create(b.volume, slopfs.ROOT_OBJECT, "old", .File)
    old :: testing.require_ok(t, making_old, "a volume apart makes a file")?
    writing_old :: slopfs.write(b.volume, old, 0, data.bytes[0..<200000])
    require_done(t, writing_old, "a volume apart writes a file from the container's space")?
    testing.require(t, commit_apart(b), "a volume apart commits alone")?
    removing_old :: slopfs.remove(b.volume, slopfs.ROOT_OBJECT, "old")
    require_done(t, removing_old, "a volume apart removes a committed file")?
    // b writes more, uncommitted; a writes a lot and commits twice, so freed blocks would be reused if they were free
    making_pending :: slopfs.create(b.volume, slopfs.ROOT_OBJECT, "pending", .File)
    pending :: testing.require_ok(t, making_pending, "a volume apart makes a second file")?
    writing_pending :: slopfs.write(b.volume, pending, 0, data.bytes[0..<100000])
    require_done(t, writing_pending, "a volume apart writes a second file")?
    for round in 0..<2 {
        // From the disk's start, where b's freed blocks are, which a would take if they were free
        container.space.rotor = 0
        // Enough to sweep every free block the first-fit search reaches before the disk's middle
        for i in 0..<12 {
            text : u8[16]
            length :: name_of_number(text, round * 100 + i)
            making :: slopfs.create(a.volume, slopfs.ROOT_OBJECT, string_of(&text[0], length), .File)
            file :: testing.require_ok(t, making, "the other volume apart makes a file")?
            writing :: slopfs.write(a.volume, file, 0, data.bytes[0..<300000])
            require_done(t, writing, "the other volume apart writes a file, the disk having room for 24 of them")?
        }
        testing.require(t, commit_apart(a), "the other volume apart commits alone, b's changes left out")?
    }
    // The disk as a crash now would leave it
    saved, error :: runtime.new_array(u8, disk.bytes.count)
    testing.require(t, error == null, "a copy of the disk as a crash would leave it is allocated")?
    defer runtime.free_array(saved)
    copy_into(saved, disk.bytes)

    // Committed, b's removal and its new file are durable too, and everything checks out
    testing.expect(t, commit_apart(b), "a volume apart commits what it removed and wrote since")
    free_apart(a)
    free_apart(b)
    checks_out(t, container, "both volumes apart committed, nothing's leaked or used twice")
    slopfs.unmount(container)

    // After the crash: a's two files, b's old one whole, b's pending one never there, and nothing leaked
    copy_into(disk.bytes, saved)
    mounting_after :: slopfs.mount(device)
    after :: testing.require_ok(t, mounting_after, "the disk as the crash left it mounts")?
    defer slopfs.unmount(after)
    checks_out(t, after, "after the crash, b's uncommitted blocks aren't leaked, and what it freed uncommitted isn't used twice")
    opening_a :: slopfs.open_volume(after, volume_id(after, "a"))
    va :: testing.require_ok(t, opening_a, "a opens after the crash")?
    opening_b :: slopfs.open_volume(after, volume_id(after, "b"))
    vb :: testing.require_ok(t, opening_b, "b opens after the crash")?
    back := runtime.new(Data)
    defer runtime.free(back)
    for number in 0..<24 {
        text : u8[16]
        length :: name_of_number(text, number / 12 * 100 + number % 12)
        looking :: slopfs.lookup(va, slopfs.ROOT_OBJECT, string_of(&text[0], length))
        file :: testing.require_ok(t, looking, "each of a's files is looked up")?
        reading :: slopfs.read(va, file or_else 0, 0, back.bytes[0..<300000])
        read :: testing.require_ok(t, reading, "each of a's committed files is there and reads")?
        testing.expect_eq(t, read, 300000, "each of a's committed files is whole")
        testing.expect_none(t, difference(back.bytes[0..<300000], data.bytes[0..<300000]),
            "each of a's committed files holds what was written, none of its blocks taken by b's")
    }
    looking_old :: slopfs.lookup(vb, slopfs.ROOT_OBJECT, "old")
    kept :: testing.require_ok(t, looking_old, "b's old file is looked up")?
    reading_old :: slopfs.read(vb, kept or_else 0, 0, back.bytes[0..<200000])
    read :: testing.require_ok(t, reading_old, "b's removal wasn't committed, so its old file is there and reads")?
    testing.expect_eq(t, read, 200000, "b's old file is whole")
    testing.expect_none(t, difference(back.bytes[0..<200000], data.bytes[0..<200000]),
        "b's old file holds what was written: what b freed uncommitted wasn't given to a")
    looking_pending :: slopfs.lookup(vb, slopfs.ROOT_OBJECT, "pending")
    pending_after :: testing.require_ok(t, looking_pending, "b's pending file is looked up")?
    testing.expect_none(t, pending_after, "b's uncommitted file was never there")
    return .Ok
}
