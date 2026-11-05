package slopfs_test

import runtime from "base"
import crypto from "std"
import testing from "std"
import slopfs from ".."

/*
 * The crash-state tester (design/storage.md §9, after CrashMonkey, Mohan et al., OSDI 2018): a workload of commits run
 * on a disk that records every write and flush; then the disk as a crash could leave it, at every prefix of the
 * writes, at random subsets of the writes between two flushes (which a disk may make durable in any order), and with
 * each write torn halfway. Every one must mount, check out whole, take another commit, and hold the state after the
 * last acknowledged commit, or the one being made: a prefix of what was acknowledged (decisions/0085). A snapshot is
 * taken partway and deleted later, so its record and the dead list are in the commits checked too.
 *
 * Failed writes beside torn ones (decisions/0096's R4, 0112): a write the disk refuses is refused, the chunk it was for
 * refused to reads rather than given as it was, while other files read; every commit after it fails, not only the
 * first; and the disk, mounted again, holds the last acknowledged commit.
 */

/** The size of the crash tests' disk, in blocks: 4 MiB. */
CRASH_BLOCKS : u64 : 1024
/** How many steps of the workload run, each followed by a commit. */
STEPS :: 14
/** Random subsets tried for each interval between flushes. */
SUBSETS :: 6

/** The state after an acknowledged commit, and how much of the log it took, through its last flush. */
Acknowledged :: struct {
    /** The volume's state then, as state_digest makes it. */
    digest : slopfs.Seal,
    /** How many entries of the disk's log the commit took, through its last flush; 0 for the state before the log. */
    log_end : usize,
}

a_crash_leaves_the_last_acknowledged_commit_or_the_one_being_made #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_crashes(t, false)
}

a_crash_leaves_an_encrypted_volume_at_the_last_acknowledged_commit_or_the_one_being_made #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_crashes(t, true)
}

a_failed_write_is_refused_and_leaves_the_last_acknowledged_commit #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_failed_writes(t, false)
}

a_failed_write_to_an_encrypted_volume_is_refused_and_leaves_the_last_acknowledged_commit #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_failed_writes(t, true)
}

/**
 * Check crashes: a workload of commits run on a disk that records every write and flush, with a snapshot taken
 * partway and deleted later, then every image a crash could leave replayed (replay).
 *
 * @param t The test's state, which a failure is recorded in.
 * @param sealed Whether the volume is encrypted.
 * @return Ok once every image is checked, whatever was found; Error(Failed), the failure recorded, if the workload
 *     couldn't be run.
 */
check_crashes :: fn(t: ptr[mut testing.T], sealed: bool) -> testing.Outcome {
    device :: formatted(t, CRASH_BLOCKS, 0xc0)?
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    creating :: create_test_volume(container, "crash", sealed)
    volume :: testing.require_ok(t, creating, "a new container has room for a volume")?
    require_commit(t, container, "a new volume commits")?
    base, error :: runtime.new_array(u8, disk.bytes.count)
    testing.require(t, error == null, "a copy of the disk before the log is allocated")?
    defer runtime.free_array(base)
    copy_into(base, disk.bytes)
    acknowledged : Acknowledged[..]
    defer runtime.array_free(&acknowledged)
    before :: testing.require_some(t, state_digest(volume), "a new volume's state is hashed")?
    runtime.array_add(&acknowledged, Acknowledged.{digest = before, log_end = 0})
    disk.recording = true
    for step in 0..<STEPS {
        // Taken with the commit that shrinks a file, so what it gives back goes on the dead list; deleted later
        if step == 5 {
            taking :: slopfs.take_snapshot(container, volume.id, name_bytes("crash"), 1)
            require_done(t, taking, "a volume takes a snapshot")?
        }
        else if step == 10 {
            deleting :: slopfs.delete_snapshot(container, volume.id, name_bytes("crash"), null)
            require_done(t, deleting, "a snapshot without clones is deleted")?
        }
        workload(t, volume, step)?
        committing :: slopfs.commit(container)
        require_done(t, committing, "each step of the workload commits")?
        after :: testing.require_some(t, state_digest(volume), "the volume's state is hashed after each commit")?
        runtime.array_add(&acknowledged, Acknowledged.{digest = after, log_end = disk.log.count})
    }
    disk.recording = false
    slopfs.unmount(container)
    return replay(t, base, disk, acknowledged, sealed)
}

/**
 * Copy bytes into a buffer, as many as fit.
 *
 * @param into The buffer, from its start.
 * @param from The bytes; those past into's end are dropped.
 */
copy_into :: fn(into: mut u8[], from: u8[]) {
    for byte, i in from {
        if i < into.count {
            into[i] = byte
        }
    }
}

/**
 * Run one step of the workload: files made, written, overwritten, renamed, cut and removed, without committing.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param volume The volume under test, open, with what the steps before this one did in it.
 * @param step The step, 0 to STEPS - 1, each doing its own part.
 * @return Ok if it ran; Error(Failed), the failure recorded, if any of it failed.
 */
workload :: fn(t: ptr[mut testing.T], volume: ptr[mut slopfs.Volume], step: int) -> testing.Outcome {
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, cast[u64](step) + 100)
    root :: slopfs.ROOT_OBJECT
    text : u8[16]
    if step == 0 {
        creating :: slopfs.create(volume, root, "a.txt", .File)
        file :: testing.require_ok(t, creating, "a file is made in the root")?
        writing :: slopfs.write(volume, file, 0, data.bytes[0..<100])
        require_done(t, writing, "100 bytes are written inline")?
    }
    else if step == 1 {
        creating :: slopfs.create(volume, root, "big.bin", .File)
        file :: testing.require_ok(t, creating, "a second file is made in the root")?
        writing :: slopfs.write(volume, file, 0, data.bytes[0..<150000])
        require_done(t, writing, "150000 bytes are written across chunks")?
    }
    else if step == 2 {
        file :: testing.require_some(t, found(volume, root, "big.bin"), "big.bin was made")?
        writing :: slopfs.write(volume, file, 70000, data.bytes[0..<5000])
        require_done(t, writing, "a file is overwritten in its middle")?
    }
    else if step == 3 {
        creating :: slopfs.create(volume, root, "dir", .Directory)
        directory :: testing.require_ok(t, creating, "a directory is made in the root")?
        for i in 0..<40 {
            length :: name_of_number(text, i)
            making :: slopfs.create(volume, directory, string_of(&text[0], length), .File)
            file :: testing.require_ok(t, making, "40 files are made in a directory")?
            writing :: slopfs.write(volume, file, 0, data.bytes[0..<200])
            require_done(t, writing, "each of the 40 files is written")?
        }
    }
    else if step == 4 {
        directory :: testing.require_some(t, found(volume, root, "dir"), "dir was made")?
        renaming :: slopfs.rename(volume, root, "a.txt", directory, "a.txt")
        require_done(t, renaming, "a file is moved into a directory")?
    }
    else if step == 5 {
        file :: testing.require_some(t, found(volume, root, "big.bin"), "big.bin was made")?
        cutting :: slopfs.set_size(volume, file, 30000)
        require_done(t, cutting, "a file is cut")?
    }
    else if step == 6 {
        directory :: testing.require_some(t, found(volume, root, "dir"), "dir was made")?
        for i in 0..<20 {
            length :: name_of_number(text, i * 2)
            removing :: slopfs.remove(volume, directory, string_of(&text[0], length))
            require_done(t, removing, "every other file in the directory is removed")?
        }
    }
    else if step == 7 {
        directory :: testing.require_some(t, found(volume, root, "dir"), "dir was made")?
        file :: testing.require_some(t, found(volume, directory, "a.txt"), "a.txt was moved into dir")?
        writing :: slopfs.write(volume, file, 0, data.bytes[0..<5000])
        require_done(t, writing, "an inline file is grown past inline")?
    }
    else if step == 8 {
        directory :: testing.require_some(t, found(volume, root, "dir"), "dir was made")?
        renaming :: slopfs.rename(volume, root, "big.bin", directory, "file-25")
        require_done(t, renaming, "a file is moved into a directory under a name its removal freed")?
    }
    else if step == 9 {
        creating :: slopfs.create(volume, root, "b.bin", .File)
        file :: testing.require_ok(t, creating, "a file is made in the root")?
        writing :: slopfs.write(volume, file, 0, data.bytes[0..<100000])
        require_done(t, writing, "100000 bytes are written across chunks")?
    }
    else if step == 10 {
        removing :: slopfs.remove(volume, root, "b.bin")
        require_done(t, removing, "a file written in the step before is removed")?
    }
    else if step == 11 {
        directory :: testing.require_some(t, found(volume, root, "dir"), "dir was made")?
        file :: testing.require_some(t, found(volume, directory, "a.txt"), "a.txt was moved into dir")?
        cutting :: slopfs.set_size(volume, file, 0)
        require_done(t, cutting, "a file is cut to nothing")?
    }
    else if step == 12 {
        for i in 0..<30 {
            length :: name_of_number(text, i + 100)
            creating :: slopfs.create(volume, root, string_of(&text[0], length), .File)
            file :: testing.require_ok(t, creating, "30 files are made in the root")?
            writing :: slopfs.write(volume, file, 0, data.bytes[0..<3000])
            require_done(t, writing, "each of the 30 files is written")?
        }
    }
    else {
        directory :: testing.require_some(t, found(volume, root, "dir"), "dir was made")?
        name : u8[255]
        loop {
            listing :: slopfs.list(volume, directory, 0, name)
            listed :: testing.require_ok(t, listing, "a directory being emptied lists")?
            entry :: listed or_break
            removing :: slopfs.remove(volume, directory, string_of(&name[0], entry.name_bytes))
            require_done(t, removing, "each name listed is removed")?
        }
        removing :: slopfs.remove(volume, root, "dir")
        require_done(t, removing, "a directory emptied is removed")?
    }
    return .Ok
}

/**
 * Look up what a name names in a directory.
 *
 * @param volume The volume under test, open.
 * @param directory The directory to look in, in the volume; anything that isn't one fails the lookup, giving null.
 * @param name The name to look up.
 * @return The object's ID; null if nothing has the name, or the lookup failed.
 */
found :: fn(volume: ptr[mut slopfs.Volume], directory: u64, name: string) -> u64? {
    match slopfs.lookup(volume, directory, name) {
        case Ok(object) => return object
        case Error(error) => return null
    }
}

/**
 * Hash a volume's whole state, every name, kind and byte, beneath its root, as one BLAKE3 hash.
 *
 * @param volume The volume under test, open.
 * @return The hash, the same for the same state; null if anything couldn't be listed or read.
 */
state_digest :: fn(volume: ptr[mut slopfs.Volume]) -> slopfs.Seal? {
    hasher := crypto.blake3_start()
    buffer := runtime.new(Data)
    defer runtime.free(buffer)
    if !digest_directory(volume, &hasher, slopfs.ROOT_OBJECT, buffer, 0) {
        return null
    }
    seal : slopfs.Seal
    crypto.blake3_finish(&hasher, seal)
    return seal
}

/**
 * Hash a directory's entries, in listing order: each name and kind, and a file's size and bytes, or a directory's
 * entries in turn.
 *
 * @param volume The volume under test, open.
 * @param hasher The hash, updated.
 * @param directory The directory whose entries are hashed, in the volume; anything that isn't one fails the
 *     listing.
 * @param buffer Where files are read to, overwritten; a file bigger than it fails.
 * @param depth How deep the directory is, from 0 for the root; past 8 fails.
 * @return True if it was all hashed; false if anything couldn't be listed or read.
 */
digest_directory :: fn(volume: ptr[mut slopfs.Volume], hasher: ptr[mut crypto.Blake3], directory: u64, buffer: ptr[mut Data], depth: int) -> bool {
    if depth > 8 {
        return false
    }
    name : u8[255]
    cursor : u64 = 0
    loop {
        listed := slopfs.Listed.{}
        match slopfs.list(volume, directory, cursor, name) {
            case Ok(next) => listed = next or_break
            case Error(error) => return false
        }
        if listed.name_bytes > name.count {
            return false
        }
        crypto.blake3_update(hasher, name[0..<listed.name_bytes])
        kind : u8[1]
        kind[0] = if listed.kind == .Directory { cast[u8](2) } else { cast[u8](1) }
        crypto.blake3_update(hasher, kind)
        if listed.kind == .Directory {
            if !digest_directory(volume, hasher, listed.object, buffer, depth + 1) {
                return false
            }
        }
        else {
            match slopfs.read(volume, listed.object, 0, buffer.bytes) {
                case Ok(count) => {
                    if count > buffer.bytes.count {
                        return false
                    }
                    size : u8[8]
                    for i in 0..<size.count {
                        size[i] = cast[u8](cast[u64](count) >> cast[u64](i * 8))
                    }
                    crypto.blake3_update(hasher, size)
                    crypto.blake3_update(hasher, buffer.bytes[0..<count])
                }
                case Error(error) => return false
            }
        }
        cursor = listed.next
    }
    return true
}

/** Replaying: the counts of what was checked, for the log. */
Replayed :: struct {
    /** How many images were checked. */
    images : u64,
    /** How many of them held the commit being made, not the last acknowledged one. */
    newer : u64,
}

/** How an image a crash could leave was made from the log. */
Way :: enum {
    /** The log's first entries applied, all of them: `at` is how many. */
    Prefix,
    /** A random subset of the writes between two flushes applied: `at` is the flush's entry, `subset` which subset. */
    Subset,
    /** The writes between two flushes applied up to one, torn halfway: `at` is the torn write's entry. */
    Torn,
}

/** What checking an image a crash could leave found: Held if it's all as it should be, or the first thing that wasn't. */
Found :: enum {
    /** It mounted, checked out whole, held an acknowledged state, and took another commit if asked to. */
    Held,
    /** It didn't mount. */
    NotMounted,
    /** It mounted, but verify found a problem. */
    NotWhole,
    /** Its volume didn't open. */
    NotOpened,
    /** Its volume's state couldn't be listed or read whole. */
    NotRead,
    /** No acknowledged state goes with how much of the log it has, which only a broken log would make. */
    Unacknowledged,
    /** Its volume held neither the last acknowledged commit nor the one being made. */
    NeitherState,
    /** A file couldn't be made in it after the crash. */
    NotMade,
    /** A file made after the crash couldn't be written. */
    NotWritten,
    /** A commit after the crash failed, or didn't check out whole. */
    NotCommitted,
}

/** An image a crash could leave, and what checking it found, as a failure reports it. */
Crash :: struct {
    /** How it was made. */
    way : Way,
    /** Which entry of the log it was made at, as way says. */
    at : usize,
    /** Which random subset it is, 0 to SUBSETS - 1, for a Subset; 0 otherwise. */
    subset : int,
    /** What checking it found. */
    found : Found,
}

/**
 * Check every image a crash could leave, from the disk before the log and the log: prefixes as the log goes, and at
 * each flush, the interval before it in random subsets and with each write torn. An image that isn't as it should be
 * is recorded as a failure saying which it was, and the rest are still checked.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param base The disk's bytes before the log.
 * @param recorded The disk that recorded the log.
 * @param acknowledged The states after each acknowledged commit, the first the one before the log.
 * @param sealed Whether the volume is encrypted.
 * @return Ok once every image is checked, whatever was found; Error(Failed), the failure recorded, if the memory to
 *     check them couldn't be had.
 */
replay :: fn(t: ptr[mut testing.T], base: u8[], recorded: ptr[mut Disk], acknowledged: Acknowledged[], sealed: bool) -> testing.Outcome {
    image :: testing.require_some(t, new_device_of(CRASH_BLOCKS), "the disk the images are made on is allocated")?
    defer free_device(image)
    scratch :: cast[ptr[mut Disk]](image.context)
    running, running_error :: runtime.new_array(u8, base.count)
    testing.require(t, running_error == null, "the disk as the log goes is allocated")?
    defer runtime.free_array(running)
    snapshot, snapshot_error :: runtime.new_array(u8, base.count)
    testing.require(t, snapshot_error == null, "the disk at the last flush is allocated")?
    defer runtime.free_array(snapshot)
    copy_into(running, base)
    copy_into(snapshot, base)
    random := Random.{state = 0x5eed5eed5eed5eed}
    replayed := Replayed.{}
    interval_start : usize = 0
    WHOLE :: "an image a crash could leave mounts, checks out whole, holds the last acknowledged commit or the one being made, and takes another commit"
    for at in 0..<recorded.log.count + 1 {
        // The log up to here, applied
        copy_into(scratch.bytes, running)
        prefix :: check_image(&image, acknowledged, at, at % 8 == 0, &replayed, sealed)
        testing.expect_eq(t, Crash.{way = .Prefix, at = at, found = prefix}, Crash.{way = .Prefix, at = at, found = .Held}, WHOLE)
        if at >= recorded.log.count {
            break
        }
        entry :: recorded.log[at]
        if !entry.flush {
            apply(running, recorded, entry, false)
            continue
        }
        // The interval before this flush: random subsets of it, and each write in it torn after those before it
        for subset in 0..<SUBSETS {
            copy_into(scratch.bytes, snapshot)
            for i in interval_start..<at {
                chosen :: next_random(&random) % 2 == 0
                if chosen && i < recorded.log.count {
                    apply(scratch.bytes, recorded, recorded.log[i], false)
                }
            }
            found_in_subset :: check_image(&image, acknowledged, interval_start, true, &replayed, sealed)
            testing.expect_eq(t, Crash.{way = .Subset, at = at, subset = subset, found = found_in_subset},
                Crash.{way = .Subset, at = at, subset = subset, found = .Held}, WHOLE)
        }
        for torn in interval_start..<at {
            copy_into(scratch.bytes, snapshot)
            for i in interval_start..<torn + 1 {
                if i < recorded.log.count {
                    apply(scratch.bytes, recorded, recorded.log[i], i == torn)
                }
            }
            found_torn :: check_image(&image, acknowledged, interval_start, false, &replayed, sealed)
            testing.expect_eq(t, Crash.{way = .Torn, at = torn, found = found_torn}, Crash.{way = .Torn, at = torn, found = .Held}, WHOLE)
        }
        copy_into(snapshot, running)
        interval_start = at + 1
    }
    runtime.log_info("crash%: % images checked, % of them holding the commit being made", if sealed { " (sealed)" } else { "" }, replayed.images, replayed.newer)
    return .Ok
}

/**
 * Apply a recorded write to an image: whole, or torn, its first half only.
 *
 * @param image The disk image the write lands in, changed in place; bytes the write would put past its end are
 *     skipped.
 * @param recorded The disk that recorded the write, its logged bytes.
 * @param entry The write; a flush applies nothing.
 * @param torn Whether only its first half is applied.
 */
apply :: fn(image: mut u8[], recorded: ptr[mut Disk], entry: Recorded, torn: bool) {
    start :: cast[usize](entry.block * slopfs.BLOCK_BYTES)
    length := cast[usize](entry.count * slopfs.BLOCK_BYTES)
    if torn {
        length = length / 2
    }
    for i in 0..<length {
        from :: entry.at + i
        to :: start + i
        if from < recorded.logged.count && to < image.count {
            image[to] = recorded.logged[from]
        }
    }
}

/**
 * Check an image a crash could leave: it mounts and checks out whole, and holds the state after the last commit the
 * log through `durable` made durable, or the one after it; and, with usable, takes another commit and still checks
 * out.
 *
 * @param device The device over the image.
 * @param acknowledged The states after each acknowledged commit.
 * @param durable How many of the log's entries are surely on the disk.
 * @param usable Whether to make a file and commit after the crash too.
 * @param replayed The counts, updated.
 * @param sealed Whether the volume is encrypted.
 * @return Held if it checked out; otherwise the first thing that didn't.
 */
check_image :: fn(device: ptr[slopfs.Device], acknowledged: Acknowledged[], durable: usize, usable: bool, replayed: ptr[mut Replayed],
    sealed: bool) -> Found {

    replayed.images += 1
    last : usize = 0
    for each, i in acknowledged {
        if each.log_end <= durable {
            last = i
        }
    }
    container :: slopfs.mount(device^) or_return .NotMounted
    defer slopfs.unmount(container)
    if slopfs.verify(container) is_error {
        return .NotWhole
    }
    volume :: open_test_volume(container, sealed) or_return .NotOpened
    digest :: state_digest(volume) or_return .NotRead
    if last >= acknowledged.count {
        return .Unacknowledged
    }
    if digest != acknowledged[last].digest {
        next :: last + 1
        if next >= acknowledged.count || digest != acknowledged[next].digest {
            return .NeitherState
        }
        replayed.newer += 1
    }
    if usable {
        file :: slopfs.create(volume, slopfs.ROOT_OBJECT, "after the crash", .File) or_return .NotMade
        bytes : u8[3000]
        slopfs.write(volume, file, 0, bytes) or_return .NotWritten
        if commit_failed(container) {
            return .NotCommitted
        }
    }
    return .Held
}

/** The bytes a failed write is tried with: big enough to be written as blocks, not inline in its record. */
FAILED_BYTES :: 8192

/**
 * Check failed writes beside torn ones (decisions/0096's R4, 0112): a write the disk refuses is refused, the chunk it
 * was for refused to reads rather than given as it was, while other files read; every commit after it fails, not only
 * the first; and the disk, mounted again, holds the last acknowledged commit.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param sealed Whether the volume is encrypted.
 * @return Ok once it's all checked, whatever was found; Error(Failed), the failure recorded, if what's checked couldn't
 *     be set up.
 */
check_failed_writes :: fn(t: ptr[mut testing.T], sealed: bool) -> testing.Outcome {
    device :: formatted(t, CRASH_BLOCKS, 0xd0)?
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    defer slopfs.unmount(container)
    creating :: create_test_volume(container, "failing", sealed)
    volume :: testing.require_ok(t, creating, "a new container has room for a volume")?
    data := runtime.new(Data)
    defer runtime.free(data)
    fill(data.bytes, 1, FAILED_BYTES)
    making_kept :: slopfs.create(volume, slopfs.ROOT_OBJECT, "kept", .File)
    kept :: testing.require_ok(t, making_kept, "a file is made in the root")?
    making_lost :: slopfs.create(volume, slopfs.ROOT_OBJECT, "lost", .File)
    lost :: testing.require_ok(t, making_lost, "a second file is made in the root")?
    writing_kept :: slopfs.write(volume, kept, 0, data.bytes[0..<FAILED_BYTES])
    require_done(t, writing_kept, "a file is written as blocks")?
    writing_lost :: slopfs.write(volume, lost, 0, data.bytes[0..<FAILED_BYTES])
    require_done(t, writing_lost, "a second file is written as blocks")?
    require_commit(t, container, "the files commit")?
    acknowledged :: testing.require_some(t, state_digest(volume), "the committed state is hashed")?
    // The disk refuses the next write: refused, and the chunk it was for refused to reads, the other file's read
    fill(data.bytes, 2, FAILED_BYTES)
    disk.read_only = true
    refused :: slopfs.write(volume, lost, 0, data.bytes[0..<FAILED_BYTES])
    disk.read_only = false
    testing.expect(t, refused is_error, "a write the disk refuses is refused")
    reading_lost :: slopfs.read(volume, lost, 0, data.bytes[0..<FAILED_BYTES])
    testing.expect(t, reading_lost is_error, "a chunk whose write failed is refused to reads, being neither what it was nor what was written")
    reading_kept :: slopfs.read(volume, kept, 0, data.bytes[0..<FAILED_BYTES])
    testing.expect_ok(t, reading_kept, "a file the failed write wasn't for still reads")
    // Every commit after it fails, the second as the first
    first :: slopfs.commit(container)
    testing.expect(t, first is_error, "a commit after a failed write fails, as what it would commit isn't on the disk")
    second :: slopfs.commit(container)
    testing.expect(t, second is_error, "a second commit after a failed write fails as the first did")
    // Mounted again, the disk holds the last acknowledged commit
    mounting_again :: slopfs.mount(device)
    again :: testing.require_ok(t, mounting_again, "the disk mounts again after the failed write")?
    defer slopfs.unmount(again)
    reopening :: open_test_volume(again, sealed)
    reopened :: testing.require_ok(t, reopening, "the volume opens again after the failed write")?
    now :: testing.require_some(t, state_digest(reopened), "the volume's state is hashed after the failed write")?
    testing.expect_eq(t, now, acknowledged, "the disk holds the last acknowledged commit, nothing of the failed write")
    return .Ok
}
