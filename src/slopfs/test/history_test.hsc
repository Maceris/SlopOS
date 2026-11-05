package slopfs_test

import runtime from "base"
import testing from "std"
import slopfs from ".."

/*
 * What a volume server keeps beyond the volume (history.hsc), on a volume apart: its change history, read beneath a
 * directory and trimmed to its budget; files replaced whole through orphans, the old contents readable until they're
 * given back, and an orphan left behind swept; and everything since a commit forgotten and undone, leaving nothing
 * behind.
 */

/** A volume apart with a history budget, as the history tests start from it. */
Kept :: struct {
    /** The disk, freed by free_kept. */
    device : slopfs.Device,
    /** The container, mounted, unmounted by free_kept. */
    container : ptr[mut slopfs.Container],
    /** Volume "h", apart from the container, with a history budget of 4096 bytes; freed by free_kept. */
    made : ptr[mut Apart],
}

/**
 * Format a container, make a volume, "h", in it, committed, and take it apart, its history kept to 4096 bytes.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The volume apart, the caller's to free with free_kept; Error if any of it failed, the failure recorded.
 */
kept_volume :: fn(t: ptr[mut testing.T]) -> Result[Kept, testing.Stopped] {
    device :: formatted(t, BLOCKS, 0)?
    mounting :: slopfs.mount(device)
    container :: match mounting {
        case Ok(mounted) => mounted
        case Error(error) => {
            _ = testing.expect_ok(t, mounting, "a formatted disk mounts")
            free_device(device)
            return .Error(.Failed)
        }
    }
    creating :: slopfs.create_volume(container, "h", key_of_volume(), 1)
    if !testing.expect_ok(t, creating, "a new container has room for a volume") || !commits(t, container, "a new volume commits") {
        slopfs.unmount(container)
        free_device(device)
        return .Error(.Failed)
    }
    match apart(container, volume_id(container, "h")) {
        case Some(made) => {
            made.volume.history_bytes = 4096
            return .Ok(Kept.{device = device, container = container, made = made})
        }
        case None => {
            testing.fail(t, "a committed volume is taken apart")
            slopfs.unmount(container)
            free_device(device)
            return .Error(.Failed)
        }
    }
}

/**
 * Give back a volume apart kept_volume made, and its container and disk.
 *
 * @param kept The volume, which isn't used after.
 */
free_kept :: fn(kept: Kept) {
    free_apart(kept.made)
    slopfs.unmount(kept.container)
    free_device(kept.device)
}

changes_come_in_order_beneath_a_directory_and_past_the_budget_resync #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    name : u8[255]

    // A cursor from before anything is kept resyncs; then each change comes in order, and only those beneath
    starting :: slopfs.changes_since(volume, root, 0, name)
    start :: testing.require_ok(t, starting, "the history reads from the start")?
    testing.expect_eq(t, start.are, .Resync, "a cursor from before anything is kept has to resync")
    cursor := start.next
    making_sub :: slopfs.create(volume, root, "sub", .Directory)
    sub :: testing.require_ok(t, making_sub, "a directory is made in the root")?
    making_file :: slopfs.create(volume, sub, "f", .File)
    file :: testing.require_ok(t, making_file, "a file is made in it")?
    writing :: slopfs.write(volume, file, 0, text_bytes("some bytes"))
    require_done(t, writing, "the file is written")?
    writing_more :: slopfs.write(volume, file, 5, text_bytes("more"))
    require_done(t, writing_more, "the file is written again")?
    renaming :: slopfs.rename(volume, sub, "f", root, "g")
    require_done(t, renaming, "the file is moved out to the root")?
    expected :: slopfs.ChangeKind.[.Created, .Created, .Written, .MovedOut, .MovedIn]
    for kind, i in expected {
        reading :: slopfs.changes_since(volume, root, cursor, name)
        found :: testing.require_ok(t, reading, "the history reads on from each change")?
        testing.expect_eq(t, found.are, .Found, "every change made is kept, within the budget")
        testing.expect_eq(t, found.kind, kind, "changes come in the order they were made, two writes as one")
        cursor = found.next
    }
    reading_last :: slopfs.changes_since(volume, root, cursor, name)
    last :: testing.require_ok(t, reading_last, "the history reads past the last change")?
    testing.expect_eq(t, last.are, .UpToDate, "past the last change there's nothing more")
    // Beneath sub, only what happened to its names
    in_sub := 0
    at := start.next
    loop {
        reading :: slopfs.changes_since(volume, sub, at, name)
        found :: testing.require_ok(t, reading, "the history reads beneath a directory")?
        if found.are != .Found {
            break
        }
        in_sub += 1
        at = found.next
    }
    testing.expect_eq(t, in_sub, 3, "beneath sub: f made in it, written in it, and moved out of it")
    // Past the budget the oldest go, and a cursor from then resyncs
    for i in 0..<200 {
        text : u8[16]
        length :: name_of_number(text, i)
        making :: slopfs.create(volume, root, string_of(&text[0], length), .File)
        require_done(t, making, "200 files are made in the root")?
    }
    reading_trimmed :: slopfs.changes_since(volume, root, cursor, name)
    trimmed :: testing.require_ok(t, reading_trimmed, "the history reads from an old cursor")?
    testing.expect_eq(t, trimmed.are, .Resync, "200 changes pass a 4096-byte budget, so an old cursor has to resync")
    testing.expect(t, commit_apart(kept.made), "a volume with its history trimmed commits")
    return .Ok
}

a_file_replaced_whole_reads_old_until_given_back_and_a_lost_orphan_is_swept #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    making :: slopfs.create(volume, root, "g", .File)
    g :: testing.require_ok(t, making, "a file is made in the root")?
    writing :: slopfs.write(volume, g, 0, text_bytes("some mores"))
    require_done(t, writing, "the file is written")?
    testing.require(t, commit_apart(kept.made), "the file commits")?

    // Replaced whole: the old file orphaned and still readable, until it's given back
    looking :: slopfs.lookup(volume, root, "g")
    looked :: testing.require_ok(t, looking, "the file is looked up")?
    old :: testing.require_some(t, looked, "a committed file is found")?
    orphaning :: slopfs.create_orphan(volume, root)
    replacement :: testing.require_ok(t, orphaning, "an orphan is made to replace it")?
    filling :: slopfs.write(volume, replacement, 0, text_bytes("the new contents"))
    require_done(t, filling, "the orphan is written")?
    installing :: slopfs.install(volume, root, "g", replacement)
    swapped :: testing.require_ok(t, installing, "the orphan is installed over the file")?
    expected_swap : u64? = old
    testing.expect_eq(t, swapped, expected_swap, "installing gives back what the name named before, now an orphan")
    back : u8[64]
    looking_now :: slopfs.lookup(volume, root, "g")
    now :: testing.require_ok(t, looking_now, "the name is looked up again")?
    reading_now :: slopfs.read(volume, now or_else 0, 0, back)
    read_now :: testing.require_ok(t, reading_now, "the name names a file that reads")?
    testing.expect_none(t, difference(slopfs.part(back, 0, read_now), text_bytes("the new contents")), "the name reads as the replacement")
    reading_old :: slopfs.read(volume, old, 0, back)
    read_old :: testing.require_ok(t, reading_old, "the old file, orphaned, still reads")?
    testing.expect_none(t, difference(slopfs.part(back, 0, read_old), text_bytes("some mores")), "the old file reads as it was until it's given back")
    releasing :: slopfs.release_orphan(volume, old)
    testing.expect_ok(t, releasing, "the old file, orphaned, is given back")
    // An orphan left behind, as a crash would leave a replacement never installed, is swept
    left :: slopfs.create_orphan(volume, root)
    require_done(t, left, "a second orphan is made, never installed")?
    sweeping :: slopfs.sweep_orphans(volume)
    swept :: testing.require_ok(t, sweeping, "orphans are swept")?
    testing.expect_eq(t, swept, 1, "the orphan never installed is swept, and only it")
    testing.expect(t, commit_apart(kept.made), "the replacement commits")
    return .Ok
}

everything_since_a_commit_is_forgotten_and_undone_leaving_nothing #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    making :: slopfs.create(volume, root, "g", .File)
    g :: testing.require_ok(t, making, "a file is made in the root")?
    writing :: slopfs.write(volume, g, 0, text_bytes("the new contents"))
    require_done(t, writing, "the file is written")?
    testing.require(t, commit_apart(kept.made), "the file commits")?
    committed :: slopfs.record_of(volume)

    // Everything since that commit forgotten, and undone in the container: nothing of it left, and nothing leaked
    making_lost :: slopfs.create(volume, root, "lost", .File)
    lost :: testing.require_ok(t, making_lost, "a second file is made")?
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, 9)
    writing_lost :: slopfs.write(volume, lost, 0, data.bytes[0..<200000])
    require_done(t, writing_lost, "200000 bytes are written, taking blocks from the container")?
    removing :: slopfs.remove(volume, root, "g")
    require_done(t, removing, "the committed file is removed")?
    undone : slopfs.Change[..]
    defer runtime.array_free(&undone)
    slopfs.abandon_volume(kept.container, kept.made.side.id, &undone)
    slopfs.forget(volume, committed)
    looking_lost :: slopfs.lookup(volume, root, "lost")
    still_lost :: testing.require_ok(t, looking_lost, "the forgotten file's name is looked up")?
    looking_g :: slopfs.lookup(volume, root, "g")
    still_there :: testing.require_ok(t, looking_g, "the committed file's name is looked up")?
    testing.expect_ne(t, undone.count, 0, "the container undoes the blocks taken and given back since the commit")
    testing.expect_none(t, still_lost, "a file made since the commit is forgotten")
    testing.expect_some(t, still_there, "a file removed since the commit is there again")
    testing.expect(t, commit_apart(kept.made), "a volume rolled back commits")
    checks_out(t, kept.container, "nothing the forgotten changes took is leaked")
    return .Ok
}

/**
 * Get text's bytes.
 *
 * @param text The text, whose bytes are viewed, not copied.
 * @return Its bytes, a view of it.
 */
text_bytes :: fn(text: string) -> u8[] {
    return string_bytes(text)
}
