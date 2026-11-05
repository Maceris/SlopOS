package slopfs_test

import runtime from "base"
import testing from "std"
import slopfs from ".."

/*
 * The container and its volumes: an empty disk isn't mounted, and a formatted one is; a volume made with directories
 * and files of every size, renamed and removed, committed and mounted again; space coming back once what held it is
 * gone; and what's damaged on the disk found, a checkpoint by falling back to the one before, a file's block by its
 * seal; and files against a model of what they should hold.
 */

/**
 * Make the hash key the tests' volumes are made with: fixed, so runs are alike.
 *
 * @return The key: byte i is i * 7 + 3.
 */
key_of_volume :: fn() -> u8[32] {
    key : u8[32]
    for i in 0..<key.count {
        key[i] = cast[u8](i * 7 + 3)
    }
    return key
}

/** A buffer of test bytes, too big for the stack, from runtime.new. */
Data :: struct {
    /** The bytes. */
    bytes : u8[400000],
}

/**
 * Fill bytes with a pattern made from a seed, the same for the same seed and different for others.
 *
 * @param into The bytes, all filled.
 * @param seed The seed, any value; the same seed makes the same bytes.
 */
pattern :: fn(into: mut u8[], seed: u64) {
    state := seed * 0x9e3779b97f4a7c15 + 1
    for i in 0..<into.count {
        state = state * 6364136223846793005 + 1442695040888963407
        into[i] = cast[u8](state >> 56)
    }
}

/** A container on a BLOCKS disk with volume 1, "system", made and committed: what the container tests start from. */
System :: struct {
    /** The disk, freed by free_system. */
    device : slopfs.Device,
    /** The container, mounted while mounted is true; remount mounts it again. */
    container : ptr[mut slopfs.Container],
    /** Whether container is mounted, so free_system unmounts it; false between remount's unmount and its mount. */
    mounted : bool,
    /** Volume 1, open in container. */
    volume : ptr[mut slopfs.Volume],
    /** The container's free blocks once the volume was committed, before anything was written in it. */
    baseline : u64,
    /** A buffer for the bytes a test writes, from runtime.new, freed by free_system. */
    data : ptr[mut Data],
    /** A buffer for the bytes a test reads back, from runtime.new, freed by free_system. */
    back : ptr[mut Data],
}

/**
 * Format a container on a disk of BLOCKS blocks, mount it, and make volume 1, "system", in it, committed.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The container, the caller's to free with free_system; Error if any of it failed, the failure recorded and
 *     nothing left to free.
 */
system :: fn(t: ptr[mut testing.T]) -> Result[System, testing.Stopped] {
    device :: formatted(t, BLOCKS, 1)?
    made := System.{device = device, data = runtime.new(Data), back = runtime.new(Data)}
    if start_system(t, &made) is_error {
        free_system(&made)
        return .Error(.Failed)
    }
    return .Ok(made)
}

/**
 * Mount system's container and make its volume.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The container's disk, formatted, and its buffers; its container, volume and baseline are set here.
 * @return Ok if it's all done; Error(Failed), the failure recorded, if not.
 */
start_system :: fn(t: ptr[mut testing.T], made: ptr[mut System]) -> testing.Outcome {
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a formatted disk mounts")?
    made.mounted = true
    creating :: slopfs.create_volume(made.container, "system", key_of_volume(), 1000)
    made.volume = testing.require_ok(t, creating, "a new container has room for a volume")?
    require_commit(t, made.container, "a new volume commits")?
    made.baseline = slopfs.free_blocks(made.container)
    return .Ok
}

/**
 * Mount a system's container again, from what it last committed, and open volume 1 again.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The container, mounted; unmounted and mounted again, its container and volume replaced.
 * @return Ok if it mounted and the volume opened; Error(Failed), the failure recorded, if not.
 */
remount :: fn(t: ptr[mut testing.T], made: ptr[mut System]) -> testing.Outcome {
    slopfs.unmount(made.container)
    made.mounted = false
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a container mounts again from what it committed")?
    made.mounted = true
    opening :: slopfs.open_volume(made.container, 1)
    made.volume = testing.require_ok(t, opening, "a committed volume opens again")?
    return .Ok
}

/**
 * Give back a container system made: unmounted if it's mounted, its disk and buffers freed.
 *
 * @param made The container, which isn't used after.
 */
free_system :: fn(made: ptr[mut System]) {
    if made.mounted {
        slopfs.unmount(made.container)
    }
    runtime.free(made.data)
    runtime.free(made.back)
    free_device(made.device)
}

/** The files made_files makes in a system's volume: their IDs. */
Files :: struct {
    /** The directory "docs", in the root. */
    docs : u64,
    /** "docs/empty.txt", empty. */
    empty : u64,
    /** "docs/small.txt", 100 bytes, held inline in its record. */
    small : u64,
    /** "large.bin", 200000 bytes, across chunks. */
    large : u64,
    /** "holey.bin", 10 bytes after a 300000-byte hole. */
    holey : u64,
}

/**
 * Make directories and files in a system's volume, written from its data with pattern 1, uncommitted: an empty file,
 * one inline, one across chunks, and one with a hole.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The container, its volume open; its data is filled with pattern 1.
 * @return The files' IDs; Error if any couldn't be made or written, the failure recorded.
 */
made_files :: fn(t: ptr[mut testing.T], made: ptr[mut System]) -> Result[Files, testing.Stopped] {
    volume :: made.volume
    root :: slopfs.ROOT_OBJECT
    files := Files.{}
    docs :: slopfs.create(volume, root, "docs", .Directory)
    files.docs = testing.require_ok(t, docs, "a directory is made in the root")?
    empty :: slopfs.create(volume, files.docs, "empty.txt", .File)
    files.empty = testing.require_ok(t, empty, "a file is made in a directory")?
    small :: slopfs.create(volume, files.docs, "small.txt", .File)
    files.small = testing.require_ok(t, small, "a second file is made in a directory")?
    large :: slopfs.create(volume, root, "large.bin", .File)
    files.large = testing.require_ok(t, large, "a file is made in the root")?
    holey :: slopfs.create(volume, root, "holey.bin", .File)
    files.holey = testing.require_ok(t, holey, "a second file is made in the root")?
    pattern(made.data.bytes, 1)
    small_written :: slopfs.write(volume, files.small, 0, made.data.bytes[0..<100])
    require_done(t, small_written, "100 bytes are written inline")?
    large_written :: slopfs.write(volume, files.large, 0, made.data.bytes[0..<200000])
    require_done(t, large_written, "200000 bytes are written across chunks")?
    holey_written :: slopfs.write(volume, files.holey, 300000, made.data.bytes[0..<10])
    require_done(t, holey_written, "10 bytes are written past a hole")?
    return .Ok(files)
}

/**
 * Check the files as made_files wrote them: the empty one, 100 bytes, 200000 bytes, and 10 bytes after a 300000-byte
 * hole, which reads as zeros.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The container, its volume open, its data holding pattern 1.
 * @param files The files made_files made.
 * @return Ok once they're checked, whatever was found; Error(Failed), the failure recorded, if one couldn't be read.
 */
check_files :: fn(t: ptr[mut testing.T], made: ptr[mut System], files: Files) -> testing.Outcome {
    volume :: made.volume
    data :: made.data
    back :: made.back
    small :: slopfs.read(volume, files.small, 0, back.bytes[0..<1000])
    small_read :: testing.require_ok(t, small, "an inline file reads")?
    testing.expect_eq(t, small_read, 100, "an inline file reads as long as was written")
    testing.expect_none(t, difference(back.bytes[0..<100], data.bytes[0..<100]), "an inline file reads as written")
    large :: slopfs.read(volume, files.large, 0, back.bytes[0..<400000])
    large_read :: testing.require_ok(t, large, "a file across chunks reads")?
    testing.expect_eq(t, large_read, 200000, "a file across chunks reads as long as was written")
    testing.expect_none(t, difference(back.bytes[0..<200000], data.bytes[0..<200000]), "a file across chunks reads as written")
    middle :: slopfs.read(volume, files.large, 65530, back.bytes[0..<20])
    middle_read :: testing.require_ok(t, middle, "a file reads from across its chunks' edge")?
    testing.expect_eq(t, middle_read, 20, "20 bytes read across a chunk's edge, all within the file")
    testing.expect_none(t, difference(back.bytes[0..<20], data.bytes[65530..<65550]), "bytes across a chunk's edge read as written")
    holey :: slopfs.read(volume, files.holey, 0, back.bytes[0..<400000])
    holey_read :: testing.require_ok(t, holey, "a file with a hole reads")?
    testing.expect_eq(t, holey_read, 300010, "a file with a hole is as long as its hole and what's past it")
    testing.expect_eq(t, back.bytes[0], 0, "a hole's first byte reads as zero")
    testing.expect_eq(t, back.bytes[299999], 0, "a hole's last byte reads as zero")
    testing.expect_none(t, difference(back.bytes[300000..<300010], data.bytes[0..<10]), "what's past a hole reads as written")
    return .Ok
}

an_empty_disk_isnt_mounted_and_a_formatted_one_is #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    device :: testing.require_some(t, new_device(), "the disk's bytes are allocated")?
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](i + 1)
    }
    empty :: slopfs.mount(device)
    testing.expect_error(t, empty, .NotSlopfs, "zeros aren't a container")
    formatting :: slopfs.format(device, id)
    require_done(t, formatting, "a zeroed disk takes a container")?
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    defer slopfs.unmount(container)
    after_format :: slopfs.free_blocks(container)
    testing.expect(t, after_format + 4 * slopfs.NODE_BLOCKS + slopfs.FIRST_DATA + 1 >= BLOCKS,
        "only the space map's and owners' nodes, two copies each, are used after formatting")
    testing.expect_lt(t, after_format, BLOCKS - slopfs.FIRST_DATA - 1, "formatting writes the space map's and owners' nodes")
    return .Ok
}

names_already_there_or_that_arent_names_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    files :: made_files(t, &made)?
    again :: slopfs.create(made.volume, files.docs, "small.txt", .File)
    testing.expect_error(t, again, .AlreadyExists, "a name already in a directory isn't made again")
    for name in string.["", ".", "..", "a/b"] {
        refused :: slopfs.create(made.volume, slopfs.ROOT_OBJECT, name, .File)
        testing.expect_error(t, refused, .InvalidName, "nothing, a dot, two dots and a slash aren't names")
    }
    return .Ok
}

names_that_would_show_other_than_their_bytes_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    volume :: made.volume
    root :: slopfs.ROOT_OBJECT
    // decisions/0108
    zero_width :: create_named(volume, root, u8.[0x61, 0xe2, 0x80, 0x8b, 0x62])
    testing.expect_error(t, zero_width, .InvalidName, "a zero-width space hides between what shows")
    right_to_left :: create_named(volume, root, u8.[0xe2, 0x80, 0xae, 0x61])
    testing.expect_error(t, right_to_left, .InvalidName, "a right-to-left override shows what follows backwards")
    escape :: create_named(volume, root, u8.[0x61, 0x1b])
    testing.expect_error(t, escape, .InvalidName, "an escape starts a terminal's control sequence")
    c1 :: create_named(volume, root, u8.[0xc2, 0x85])
    testing.expect_error(t, c1, .InvalidName, "a C1 control is a control, not a character")
    not_utf8 :: create_named(volume, root, u8.[0x61, 0xff])
    testing.expect_error(t, not_utf8, .InvalidName, "bytes that aren't UTF-8 show as whatever a reader guesses")
    accented :: create_named(volume, root, ACCENTED)
    testing.expect_ok(t, accented, "a name with an accent shows as it is")
    removed :: slopfs.remove(volume, root, string_of(&ACCENTED[0], ACCENTED.count))
    testing.expect_ok(t, removed, "a name with an accent is found by its bytes")
    return .Ok
}

a_typed_files_schema_is_kept #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    creating :: slopfs.create(made.volume, slopfs.ROOT_OBJECT, "typed", .File)
    typed :: testing.require_ok(t, creating, "a file is made in the root")?
    schema : u8[32]
    schema[0] = 0x5c
    schema[31] = 0x1e
    setting :: slopfs.set_schema(made.volume, typed, schema)
    require_done(t, setting, "a file takes a schema")?
    getting :: slopfs.info(made.volume, typed)
    info :: testing.require_ok(t, getting, "a typed file's record reads")?
    testing.expect(t, info.schema == schema, "a file's schema is kept in its record as set")
    return .Ok
}

files_read_back_as_written #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    files :: made_files(t, &made)?
    check_files(t, &made, files)?
    _ = commits(t, made.container, "what was written commits")
    return .Ok
}

files_read_back_the_same_after_a_mount #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    files :: made_files(t, &made)?
    require_commit(t, made.container, "what was written commits")?
    remount(t, &made)?
    looking :: slopfs.lookup(made.volume, slopfs.ROOT_OBJECT, "docs")
    found_docs :: testing.require_ok(t, looking, "a committed directory is looked up")?
    expected : u64? = files.docs
    testing.expect_eq(t, found_docs, expected, "a committed name names what it did")
    check_files(t, &made, files)?
    testing.expect_eq(t, count_entries(made.volume, slopfs.ROOT_OBJECT), 3, "the root lists docs, large.bin and holey.bin")
    testing.expect_eq(t, count_entries(made.volume, files.docs), 2, "docs lists empty.txt and small.txt")
    return .Ok
}

files_change_as_overwritten_grown_cut_renamed_and_moved #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    files :: made_files(t, &made)?
    require_commit(t, made.container, "what was written commits")?
    remount(t, &made)?
    volume :: made.volume
    root :: slopfs.ROOT_OBJECT
    data :: made.data
    back :: made.back

    // Overwritten in the middle: only those bytes change
    pattern(data.bytes, 2)
    overwriting :: slopfs.write(volume, files.large, 70000, data.bytes[0..<5])
    require_done(t, overwriting, "a file is overwritten in its middle")?
    reading :: slopfs.read(volume, files.large, 69998, back.bytes[0..<9])
    read :: testing.require_ok(t, reading, "a file reads around what was overwritten")?
    testing.expect_eq(t, read, 9, "9 bytes within the file read whole")
    testing.expect_eq(t, back.bytes[2], data.bytes[0], "the first byte overwritten has what was written")
    pattern(data.bytes, 1)
    testing.expect_eq(t, back.bytes[0], data.bytes[69998], "the byte two before what was overwritten is as it was")
    testing.expect_eq(t, back.bytes[1], data.bytes[69999], "the byte just before what was overwritten is as it was")
    testing.expect_eq(t, back.bytes[7], data.bytes[70005], "the byte just after what was overwritten is as it was")

    // Grown past inline
    growing :: slopfs.write(volume, files.small, 3000, data.bytes[0..<10])
    require_done(t, growing, "an inline file is written past its end")?
    getting :: slopfs.info(volume, files.small)
    grown_info :: testing.require_ok(t, getting, "a grown file's record reads")?
    testing.expect_eq(t, grown_info.size, 3010, "a file written past its end grows to the write's end")

    // Cut, then grown again: what was cut reads as zeros
    cutting :: slopfs.set_size(volume, files.large, 1000)
    require_done(t, cutting, "a file is cut")?
    regrowing :: slopfs.set_size(volume, files.large, 90000)
    require_done(t, regrowing, "a cut file is grown again")?
    reading_again :: slopfs.read(volume, files.large, 0, back.bytes[0..<90000])
    read_again :: testing.require_ok(t, reading_again, "a file cut and grown reads")?
    testing.expect_eq(t, read_again, 90000, "a file grown reads as long as its new size")
    testing.expect_eq(t, back.bytes[999], data.bytes[999], "what was kept by the cut is as it was")
    testing.expect_eq(t, back.bytes[1000], 0, "what was cut reads as zero once grown again")
    testing.expect_eq(t, back.bytes[80000], 0, "what was cut reads as zero far past the cut too")

    // Renamed over another file, which it replaces
    over :: slopfs.rename(volume, files.docs, "small.txt", files.docs, "empty.txt")
    require_done(t, over, "a file is renamed over another")?
    looking_gone :: slopfs.lookup(volume, files.docs, "small.txt")
    gone :: testing.require_ok(t, looking_gone, "the old name is looked up")?
    testing.expect_none(t, gone, "a renamed file's old name is gone")
    looking_replaced :: slopfs.lookup(volume, files.docs, "empty.txt")
    replaced :: testing.require_ok(t, looking_replaced, "the new name is looked up")?
    small : u64? = files.small
    testing.expect_eq(t, replaced, small, "a name renamed over names the file renamed")

    // Moved to another directory; a directory isn't moved beneath itself
    moving :: slopfs.rename(volume, root, "holey.bin", files.docs, "holey.bin")
    require_done(t, moving, "a file is moved to another directory")?
    getting_moved :: slopfs.info(volume, files.holey)
    moved :: testing.require_ok(t, getting_moved, "a moved file's record reads")?
    testing.expect_eq(t, moved.parent, files.docs, "a moved file's parent is where it went")
    inside :: slopfs.rename(volume, root, "docs", files.docs, "inside")
    testing.expect(t, inside is_error, "a directory moved beneath itself would be cut off from the root")
    removing :: slopfs.remove(volume, root, "docs")
    testing.expect_error(t, removing, .DirectoryNotEmpty, "a directory with something in it isn't removed")
    require_commit(t, made.container, "the changes commit")?

    // Mounted again, as changed
    remount(t, &made)?
    reading_after :: slopfs.read(made.volume, files.large, 0, back.bytes[0..<90000])
    read_after :: testing.require_ok(t, reading_after, "a changed file reads after a mount")?
    testing.expect_eq(t, read_after, 90000, "a file's new size is committed")
    testing.expect_eq(t, back.bytes[999], data.bytes[999], "what the cut kept is committed")
    testing.expect_eq(t, back.bytes[1000], 0, "what was cut is committed as zeros")
    testing.expect_eq(t, count_entries(made.volume, files.docs), 2, "docs lists empty.txt, renamed over, and holey.bin, moved in")
    testing.expect_eq(t, count_entries(made.volume, root), 2, "the root lists docs and large.bin, holey.bin moved out")
    return .Ok
}

removing_everything_gives_the_space_back #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    files :: made_files(t, &made)?
    require_commit(t, made.container, "what was written commits")?
    volume :: made.volume
    root :: slopfs.ROOT_OBJECT
    for name in string.["empty.txt", "small.txt"] {
        removing :: slopfs.remove(volume, files.docs, name)
        require_done(t, removing, "a file in a directory is removed")?
    }
    for name in string.["docs", "large.bin", "holey.bin"] {
        removing :: slopfs.remove(volume, root, name)
        require_done(t, removing, "an empty directory, or a file, is removed from the root")?
    }
    testing.expect_eq(t, count_entries(volume, root), 0, "everything in the root was removed")
    // Committed twice, so what the first freed is free
    require_commit(t, made.container, "the removals commit")?
    require_commit(t, made.container, "a commit after the removals frees what they gave back")?
    testing.expect(t, slopfs.free_blocks(made.container) + 8 * slopfs.NODE_BLOCKS >= made.baseline,
        "with everything removed, the space is back, but for the trees' nodes, two copies each, rewritten")
    return .Ok
}

verify_finds_blocks_allocated_and_never_used #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    container :: made.container
    allocating :: container.nodes.allocate(container.nodes.space, 3, 1, true)
    leaked :: testing.require_some(t, allocating, "a new container has 3 blocks to give")?
    committing :: slopfs.commit(container)
    require_done(t, committing, "a commit doesn't look for what's used")?
    verifying :: slopfs.verify(container)
    testing.expect_error(t, verifying, .Leak, "blocks allocated that nothing holds are a leak")
    container.nodes.release(container.nodes.space, leaked, 3, 1, slopfs.durable_transaction(container))
    require_commit(t, container, "the leaked blocks given back commit")?
    require_commit(t, container, "a commit after they're given back frees them, and nothing's leaked")?
    return .Ok
}

a_broken_newest_checkpoint_falls_back_to_the_one_before #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    data :: made.data
    back :: made.back
    creating :: slopfs.create(made.volume, slopfs.ROOT_OBJECT, "kept", .File)
    file :: testing.require_ok(t, creating, "a file is made in the root")?
    pattern(data.bytes, 3)
    writing :: slopfs.write(made.volume, file, 0, data.bytes[0..<8192])
    require_done(t, writing, "two blocks are written")?
    require_commit(t, made.container, "the file commits")?
    kept_in :: slopfs.durable_transaction(made.container)
    rewriting :: slopfs.write(made.volume, file, 0, data.bytes[8192..<16384])
    require_done(t, rewriting, "the file is overwritten")?
    require_commit(t, made.container, "the overwrite commits")?
    newest :: slopfs.durable_transaction(made.container)
    slopfs.unmount(made.container)
    made.mounted = false
    disk :: cast[ptr[mut Disk]](made.device.context)
    flip(disk, (1 + newest % slopfs.RING_BLOCKS) * slopfs.BLOCK_BYTES + 100)
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a container with its newest checkpoint broken mounts from the one before")?
    made.mounted = true
    testing.expect_eq(t, slopfs.durable_transaction(made.container), kept_in, "the checkpoint before the broken one is taken")
    opening :: slopfs.open_volume(made.container, 1)
    volume :: testing.require_ok(t, opening, "the volume opens as the checkpoint before named it")?
    reading :: slopfs.read(volume, file, 0, back.bytes[0..<8192])
    read :: testing.require_ok(t, reading, "the file reads as the checkpoint before had it")?
    testing.expect_eq(t, read, 8192, "the file is as long as it was then")
    testing.expect_none(t, difference(back.bytes[0..<8192], data.bytes[0..<8192]), "the file holds what it did then, not the overwrite")
    return .Ok
}

a_broken_block_of_a_file_reads_as_corrupt #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    data :: made.data
    creating :: slopfs.create(made.volume, slopfs.ROOT_OBJECT, "kept", .File)
    file :: testing.require_ok(t, creating, "a file is made in the root")?
    pattern(data.bytes, 3)
    writing :: slopfs.write(made.volume, file, 0, data.bytes[0..<8192])
    require_done(t, writing, "two blocks are written")?
    require_commit(t, made.container, "the file commits")?
    slopfs.unmount(made.container)
    made.mounted = false
    // The file's first block, found by its bytes, broken
    disk :: cast[ptr[mut Disk]](made.device.context)
    at :: testing.require_some(t, find(disk, data.bytes[0..<64]), "a file that isn't encrypted is on the disk as written")?
    flip(disk, at + 10)
    mounting :: slopfs.mount(made.device)
    made.container = testing.require_ok(t, mounting, "a container mounts with a file's block broken, which it doesn't read")?
    made.mounted = true
    opening :: slopfs.open_volume(made.container, 1)
    volume :: testing.require_ok(t, opening, "the volume opens with a file's block broken")?
    reading :: slopfs.read(volume, file, 0, made.back.bytes[0..<8192])
    testing.expect_error(t, reading, .Corrupt, "a broken block doesn't match the seal it's read with")
    return .Ok
}

/**
 * Change one byte of a test disk, as damage would.
 *
 * @param disk The test disk, changed in place.
 * @param at The byte's offset; past the disk's end, nothing changes.
 */
flip :: fn(disk: ptr[mut Disk], at: u64) {
    index :: cast[usize](at)
    if index < disk.bytes.count {
        disk.bytes[index] = disk.bytes[index] ~ 0x5a
    }
}

/**
 * Find where bytes first are on a test disk, at a block's start.
 *
 * @param disk The test disk, searched, not changed.
 * @param bytes The bytes looked for, at most a block of them.
 * @return Their byte offset on the disk, a block's start; null if no block starts with them.
 */
find :: fn(disk: ptr[mut Disk], bytes: u8[]) -> u64? {
    for block in 0..<BLOCKS {
        start :: cast[usize](block * slopfs.BLOCK_BYTES)
        end :: start + bytes.count
        if end <= disk.bytes.count && start <= end && same(disk.bytes[start..<end], bytes) {
            return block * slopfs.BLOCK_BYTES
        }
    }
    return null
}

/**
 * Count a directory's entries by listing them.
 *
 * @param volume The volume under test, open.
 * @param directory The directory to list, in the volume; anything that isn't one fails the listing.
 * @return How many there are, up to 100000; 9999 if listing failed.
 */
count_entries :: fn(volume: ptr[mut slopfs.Volume], directory: u64) -> u64 {
    name : u8[255]
    count : u64 = 0
    cursor : u64 = 0
    for step in 0..<100000 {
        match slopfs.list(volume, directory, cursor, name) {
            case Ok(listed) => {
                entry :: listed or_return count
                count += 1
                cursor = entry.next
            }
            case Error(error) => return 9999
        }
    }
    return count
}

/** How many files the model test keeps a model of. */
FILES :: 6
/** The most bytes a modelled file grows to. */
MODEL_BYTES :: 300000

/** Every modelled file, too big for the stack, from runtime.new. */
Models :: struct {
    /** The files' models. */
    files : Model[FILES],
}

/** What a file should hold, and how long it is. */
Model :: struct {
    /** Its bytes as they should be, its first size used; zeros past what was written. */
    bytes : u8[MODEL_BYTES],
    /** Its size in bytes, at most MODEL_BYTES. */
    size : usize,
    /** The file's ID. */
    object : u64,
}

/** A modelled file as compare_file found it, for a failure to say which file, when, and what was wrong. */
Compared :: struct {
    /** The step of the model test it was compared at; 600 for the comparison after the last step. */
    step : int,
    /** The file's place among the models, 0 to FILES - 1. */
    file : usize,
    /** Its size, as its record says, or as the model has it. */
    size : u64,
    /** Where its bytes first differ from the model's; none if they don't. */
    differs : usize?,
}

files_match_a_model_through_random_writes_cuts_and_mounts #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    models := runtime.new(Models)
    defer runtime.free(models)
    creating :: slopfs.create(made.volume, slopfs.ROOT_OBJECT, "model", .Directory)
    directory :: testing.require_ok(t, creating, "a directory is made in the root")?
    for &model, i in models.files {
        name : u8[1]
        name[0] = cast[u8]('a') + cast[u8](i)
        making :: slopfs.create(made.volume, directory, string_of(&name[0], 1), .File)
        model.object = testing.require_ok(t, making, "a file is made for each model")?
        model.size = 0
    }
    random := Random.{state = 0x1234567887654321}
    data :: made.data
    for step in 0..<600 {
        which :: cast[usize](next_random(&random) % FILES)
        if which >= models.files.count {
            continue
        }
        model :: &models.files[which]
        choice :: next_random(&random) % 10
        if choice < 6 {
            offset :: cast[usize](next_random(&random) % (MODEL_BYTES - 1))
            room :: MODEL_BYTES - offset
            length := cast[usize](next_random(&random) % 70000) + 1
            if length > room {
                length = room
            }
            if length > data.bytes.count {
                testing.fail(t, "a write is at most 70000 bytes, which the buffer holds")
                return .Error(.Failed)
            }
            pattern(data.bytes[0..<length], next_random(&random))
            writing :: slopfs.write(made.volume, model.object, cast[u64](offset), data.bytes[0..<length])
            require_done(t, writing, "a write within a modelled file's 300000 bytes fits the disk")?
            for i in 0..<length {
                j :: offset + i
                if j < model.bytes.count && i < data.bytes.count {
                    model.bytes[j] = data.bytes[i]
                }
            }
            for i in model.size..<offset {
                if i < model.bytes.count {
                    model.bytes[i] = 0
                }
            }
            if offset + length > model.size {
                model.size = offset + length
            }
        }
        else if choice < 8 {
            size :: cast[usize](next_random(&random) % MODEL_BYTES)
            sizing :: slopfs.set_size(made.volume, model.object, cast[u64](size))
            require_done(t, sizing, "a modelled file is cut or grown")?
            for i in model.size..<size {
                if i < model.bytes.count {
                    model.bytes[i] = 0
                }
            }
            model.size = size
        }
        else {
            compare_file(t, made.volume, model, made.back, step, which)?
        }
        if step % 50 == 49 {
            require_commit(t, made.container, "the files' changes commit")?
        }
        if step % 150 == 149 {
            remount(t, &made)?
        }
    }
    for &model, i in models.files {
        compare_file(t, made.volume, model, made.back, 600, i)?
    }
    return .Ok
}

a_directory_of_many_entries_lists_each_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := system(t)?
    defer free_system(&made)
    creating :: slopfs.create(made.volume, slopfs.ROOT_OBJECT, "many", .Directory)
    many :: testing.require_ok(t, creating, "a directory is made in the root")?
    text : u8[16]
    for i in 0..<1500 {
        length :: name_of_number(text, i)
        making :: slopfs.create(made.volume, many, string_of(&text[0], length), .File)
        require_done(t, making, "a directory takes 1500 entries, its records split across leaves")?
    }
    require_commit(t, made.container, "1500 entries commit")?
    testing.expect_eq(t, count_entries(made.volume, many), 1500, "listing a directory gives each entry once")
    for i in 0..<1500 {
        length :: name_of_number(text, i)
        looking :: slopfs.lookup(made.volume, many, string_of(&text[0], length))
        found :: testing.require_ok(t, looking, "each name is looked up")?
        testing.expect_some(t, found, "each name made is found, wherever its record went")
    }
    return .Ok
}

/**
 * Make a file's name from a number: "file-" and its digits.
 *
 * @param text Where the name goes; what doesn't fit is cut.
 * @param number The number, 0 or more, at most 8 digits.
 * @return The name's length in bytes, counted as if it all fit.
 */
name_of_number :: fn(text: mut u8[], number: int) -> usize {
    prefix :: "file-"
    for character, i in prefix {
        if i < text.count {
            text[i] = cast[u8](character)
        }
    }
    digits : u8[8]
    count : usize = 0
    value := number
    loop #at_least_once {
        if count < digits.count {
            digits[count] = cast[u8]('0') + cast[u8](value % 10)
        }
        count += 1
        value = value / 10
    }
    while value > 0
    for i in 0..<count {
        at :: prefix.count + i
        from :: count - 1 - i
        if at < text.count && from < digits.count {
            text[at] = digits[from]
        }
    }
    return prefix.count + count
}

/**
 * Compare a file with its model, its size and every byte, reporting the step and the file with what was wrong.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param volume The volume under test, open.
 * @param model What the file should hold: its object is the file read, its size and first size bytes what it should
 *     have; only read.
 * @param back A buffer to read it into, overwritten.
 * @param step The model test's step, for the failure.
 * @param which The file's place among the models, for the failure.
 * @return Ok if it matches; Error(Failed), the failure recorded, if it doesn't or couldn't be read.
 */
compare_file :: fn(t: ptr[mut testing.T], volume: ptr[mut slopfs.Volume], model: ptr[mut Model], back: ptr[mut Data], step: int,
    which: usize) -> testing.Outcome {

    getting :: slopfs.info(volume, model.object)
    info :: testing.require_ok(t, getting, "a modelled file's record reads")?
    expected := Compared.{step = step, file = which, size = cast[u64](model.size)}
    testing.require_eq(t, Compared.{step = step, file = which, size = info.size}, expected, "a file is as long as the model says")?
    reading :: slopfs.read(volume, model.object, 0, back.bytes[0..<MODEL_BYTES])
    read :: testing.require_ok(t, reading, "a modelled file reads")?
    if model.size > MODEL_BYTES {
        testing.fail(t, "a model is at most MODEL_BYTES")
        return .Error(.Failed)
    }
    found := Compared.{step = step, file = which, size = cast[u64](read)}
    found.differs = difference(back.bytes[0..<model.size], model.bytes[0..<model.size])
    testing.require_eq(t, found, expected, "a file reads as long as the model and byte for byte as it")?
    return .Ok
}

/** "naïve" in UTF-8: an accent, which a name may have. */
ACCENTED :: u8.[0x6e, 0x61, 0xc3, 0xaf, 0x76, 0x65]

/**
 * Make a file of a name given as bytes, which may not be UTF-8.
 *
 * @param volume The volume under test, open.
 * @param directory The directory to make it in.
 * @param bytes The name's bytes, viewed as a string as they are; none makes the name "".
 * @return The file's ID, or why it wasn't made, as create says.
 */
create_named :: fn(volume: ptr[mut slopfs.Volume], directory: u64, bytes: u8[]) -> Result[u64, slopfs.Error] {
    if bytes.count == 0 {
        return slopfs.create(volume, directory, "", .File)
    }
    return slopfs.create(volume, directory, string_of(&bytes[0], bytes.count), .File)
}
