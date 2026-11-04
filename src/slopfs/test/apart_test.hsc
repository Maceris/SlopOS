package slopfs_test

import runtime from "base"
import maps from "std"
import slopfs from ".."

/*
 * Volumes apart from their container, as volume servers hold them (decisions/0089): each with nodes of its own,
 * allocating from the container's space as its own owner, and committing alone. A commit takes only that volume's
 * changes and the container's own: after a crash, the other's uncommitted writes are gone without leaking a block,
 * and what it freed but hasn't committed is still its own, unused by anyone. Checks from 700.
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
 * @param id The volume's ID.
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
 * @param name The volume's name.
 * @return Its ID; 0 if no volume has the name, or it couldn't be looked up.
 */
volume_id :: fn(container: ptr[mut slopfs.Container], name: string) -> u64 {
    match slopfs.find_volume(container, name) {
        case Ok(found) => return found or_else 0
        case Error(error) => return 0
    }
}

/**
 * Check volumes apart from their container, as volume servers hold them: two volumes commit alone, one freeing a file
 * it committed and writing another without committing, while the other commits twice from where the freed blocks are.
 * As a crash would leave the disk then, the first volume's committed file is whole, its uncommitted one never there,
 * the second's files all there, and the container checks out with nothing leaked; committed, it checks out too.
 *
 * @return 0 if every check passed, or the number of the first that failed, 700 to 733.
 */
check_apart :: fn() -> int {
    device :: new_device() or_return 700
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    id : u8[16]
    slopfs.format(device, id) or_return 701
    container := slopfs.mount(device) or_return 702
    slopfs.create_volume(container, "a", key_of_volume(), 1) or_return 703
    slopfs.create_volume(container, "b", key_of_volume(), 1) or_return 704
    if commit_failed(container) {
        return 705
    }
    a :: apart(container, volume_id(container, "a")) or_return 706
    b :: apart(container, volume_id(container, "b")) or_return 707
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, 7)

    // b's old file, committed, then removed without committing that
    old :: slopfs.create(b.volume, slopfs.ROOT_OBJECT, "old", .File) or_return 710
    slopfs.write(b.volume, old, 0, data.bytes[0..<200000]) or_return 711
    if !commit_apart(b) {
        return 712
    }
    slopfs.remove(b.volume, slopfs.ROOT_OBJECT, "old") or_return 713
    // b writes more, uncommitted; a writes a lot and commits twice, so freed blocks would be reused if they were free
    pending :: slopfs.create(b.volume, slopfs.ROOT_OBJECT, "pending", .File) or_return 714
    slopfs.write(b.volume, pending, 0, data.bytes[0..<100000]) or_return 715
    for round in 0..<2 {
        // From the disk's start, where b's freed blocks are, which a would take if they were free
        container.space.rotor = 0
        // Enough to sweep every free block the first-fit search reaches before the disk's middle
        for i in 0..<12 {
            text : u8[16]
            length :: name_of_number(text, round * 100 + i)
            file :: slopfs.create(a.volume, slopfs.ROOT_OBJECT, string_of(&text[0], length), .File) or_return 716
            slopfs.write(a.volume, file, 0, data.bytes[0..<300000]) or_return 717
        }
        if !commit_apart(a) {
            return 718
        }
    }
    // The disk as a crash now would leave it
    saved, error :: runtime.new_array(u8, disk.bytes.count)
    if error != null {
        return 719
    }
    defer runtime.free_array(saved)
    copy_into(saved, disk.bytes)

    // Committed, b's removal and its new file are durable too, and everything checks out
    if !commit_apart(b) {
        return 720
    }
    free_apart(a)
    free_apart(b)
    if !verified(container) {
        return 721
    }
    slopfs.unmount(container)

    // After the crash: a's two files, b's old one whole, b's pending one never there, and nothing leaked
    copy_into(disk.bytes, saved)
    after := slopfs.mount(device) or_return 722
    defer slopfs.unmount(after)
    if !verified(after) {
        return 723
    }
    va :: slopfs.open_volume(after, volume_id(after, "a")) or_return 724
    vb :: slopfs.open_volume(after, volume_id(after, "b")) or_return 725
    back := runtime.new(Data)
    defer runtime.free(back)
    for number in 0..<24 {
        text : u8[16]
        length :: name_of_number(text, number / 12 * 100 + number % 12)
        file :: slopfs.lookup(va, slopfs.ROOT_OBJECT, string_of(&text[0], length)) or_return 726
        read :: slopfs.read(va, file or_else 0, 0, back.bytes[0..<300000]) or_return 727
        if read != 300000 || !same(back.bytes[0..<300000], data.bytes[0..<300000]) {
            return 728
        }
    }
    kept :: slopfs.lookup(vb, slopfs.ROOT_OBJECT, "old") or_return 729
    read :: slopfs.read(vb, kept or_else 0, 0, back.bytes[0..<200000]) or_return 730
    if read != 200000 || !same(back.bytes[0..<200000], data.bytes[0..<200000]) {
        return 731
    }
    if (slopfs.lookup(vb, slopfs.ROOT_OBJECT, "pending") or_return 732) is_some {
        return 733
    }
    return 0
}
