package slopfs_test

import runtime from "base"
import crypto from "std"
import slopfs from ".."

/*
 * The crash-state tester (design/storage.md §9, after CrashMonkey, Mohan et al., OSDI 2018): a workload of commits run
 * on a disk that records every write and flush; then the disk as a crash could leave it, at every prefix of the
 * writes, at random subsets of the writes between two flushes (which a disk may make durable in any order), and with
 * each write torn halfway. Every one must mount, check out whole, take another commit, and hold the state after the
 * last acknowledged commit, or the one being made: a prefix of what was acknowledged (decisions/0085). A snapshot is
 * taken partway and deleted later, so its record and the dead list are in the commits checked too. Checks from 500.
 *
 * Failed writes beside torn ones (decisions/0096's R4, 0112): a write the disk refuses is refused, the chunk it was for
 * refused to reads rather than given as it was, while other files read; every commit after it fails, not only the
 * first; and the disk, mounted again, holds the last acknowledged commit. Checks from 560.
 */

CRASH_BLOCKS : u64 : 1024
STEPS :: 14
// Random subsets tried for each interval between flushes
SUBSETS :: 6

// The state after an acknowledged commit, and how much of the log it took, through its last flush.
Acknowledged :: struct {
    digest : slopfs.Seal,
    log_end : usize,
}

check_crashes :: fn(sealed: bool) -> int {
    device :: new_device_of(CRASH_BLOCKS) or_return 500
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0xc0 + i)
    }
    slopfs.format(device, id) or_return 501
    container := slopfs.mount(device) or_return 502
    volume := create_test_volume(container, "crash", sealed) or_return 503
    if commit_failed(container) {
        return 504
    }
    base, error :: runtime.new_array(u8, disk.bytes.count)
    if error != null {
        return 505
    }
    defer runtime.free_array(base)
    copy_into(base, disk.bytes)
    acknowledged : Acknowledged[..]
    defer runtime.array_free(&acknowledged)
    runtime.array_add(&acknowledged, Acknowledged.{digest = state_digest(volume) or_return 506, log_end = 0})
    disk.recording = true
    for step in 0..<STEPS {
        // Taken with the commit that shrinks a file, so what it gives back goes on the dead list; deleted later
        if step == 5 {
            if slopfs.take_snapshot(container, volume.id, name_bytes("crash"), 1) is_error {
                return 509
            }
        }
        else if step == 10 {
            if slopfs.delete_snapshot(container, volume.id, name_bytes("crash"), null) is_error {
                return 509
            }
        }
        failed :: workload(volume, step)
        if failed != 0 {
            return 510 + failed
        }
        if slopfs.commit(container) is_error {
            return 507
        }
        runtime.array_add(&acknowledged, Acknowledged.{digest = state_digest(volume) or_return 508, log_end = disk.log.count})
    }
    disk.recording = false
    slopfs.unmount(container)
    return replay(base, disk, acknowledged, sealed)
}

copy_into :: fn(into: mut u8[], from: u8[]) {
    for byte, i in from {
        if i < into.count {
            into[i] = byte
        }
    }
}

// One step of the workload: files made, written, overwritten, renamed, cut and removed.
workload :: fn(volume: ptr[mut slopfs.Volume], step: int) -> int {
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, cast[u64](step) + 100)
    root :: slopfs.ROOT_OBJECT
    text : u8[16]
    if step == 0 {
        file :: slopfs.create(volume, root, "a.txt", .File) or_return 1
        slopfs.write(volume, file, 0, data.bytes[0..<100]) or_return 2
    }
    else if step == 1 {
        file :: slopfs.create(volume, root, "big.bin", .File) or_return 1
        slopfs.write(volume, file, 0, data.bytes[0..<150000]) or_return 2
    }
    else if step == 2 {
        file :: found(volume, root, "big.bin") or_return 1
        slopfs.write(volume, file, 70000, data.bytes[0..<5000]) or_return 2
    }
    else if step == 3 {
        directory :: slopfs.create(volume, root, "dir", .Directory) or_return 1
        for i in 0..<40 {
            length :: name_of_number(text, i)
            file :: slopfs.create(volume, directory, string_of(&text[0], length), .File) or_return 2
            slopfs.write(volume, file, 0, data.bytes[0..<200]) or_return 3
        }
    }
    else if step == 4 {
        directory :: found(volume, root, "dir") or_return 1
        slopfs.rename(volume, root, "a.txt", directory, "a.txt") or_return 2
    }
    else if step == 5 {
        file :: found(volume, root, "big.bin") or_return 1
        slopfs.set_size(volume, file, 30000) or_return 2
    }
    else if step == 6 {
        directory :: found(volume, root, "dir") or_return 1
        for i in 0..<20 {
            length :: name_of_number(text, i * 2)
            slopfs.remove(volume, directory, string_of(&text[0], length)) or_return 2
        }
    }
    else if step == 7 {
        directory :: found(volume, root, "dir") or_return 1
        file :: found(volume, directory, "a.txt") or_return 2
        slopfs.write(volume, file, 0, data.bytes[0..<5000]) or_return 3
    }
    else if step == 8 {
        directory :: found(volume, root, "dir") or_return 1
        slopfs.rename(volume, root, "big.bin", directory, "file-25") or_return 2
    }
    else if step == 9 {
        file :: slopfs.create(volume, root, "b.bin", .File) or_return 1
        slopfs.write(volume, file, 0, data.bytes[0..<100000]) or_return 2
    }
    else if step == 10 {
        slopfs.remove(volume, root, "b.bin") or_return 1
    }
    else if step == 11 {
        directory :: found(volume, root, "dir") or_return 1
        file :: found(volume, directory, "a.txt") or_return 2
        slopfs.set_size(volume, file, 0) or_return 3
    }
    else if step == 12 {
        for i in 0..<30 {
            length :: name_of_number(text, i + 100)
            file :: slopfs.create(volume, root, string_of(&text[0], length), .File) or_return 1
            slopfs.write(volume, file, 0, data.bytes[0..<3000]) or_return 2
        }
    }
    else {
        directory :: found(volume, root, "dir") or_return 1
        name : u8[255]
        loop {
            listed :: slopfs.list(volume, directory, 0, name) or_return 2
            entry :: listed or_break
            slopfs.remove(volume, directory, string_of(&name[0], entry.name_bytes)) or_return 3
        }
        slopfs.remove(volume, root, "dir") or_return 4
    }
    return 0
}

// What's named name in directory, if it's there and nothing went wrong.
found :: fn(volume: ptr[mut slopfs.Volume], directory: u64, name: string) -> u64? {
    match slopfs.lookup(volume, directory, name) {
        case Ok(object) => return object
        case Error(error) => return null
    }
}

// A volume's whole state, every name, kind and byte, as one BLAKE3 hash.
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

// Replaying: the counts of what was checked, for the log.
Replayed :: struct {
    images : u64,
    newer : u64,
}

/*
 * Every image a crash could leave, from base and the log: prefixes as the log goes, and at each flush, the interval
 * before it in random subsets and with each write torn.
 */
replay :: fn(base: u8[], recorded: ptr[mut Disk], acknowledged: Acknowledged[], sealed: bool) -> int {
    image :: new_device_of(CRASH_BLOCKS) or_return 520
    defer free_device(image)
    scratch :: cast[ptr[mut Disk]](image.context)
    running, running_error :: runtime.new_array(u8, base.count)
    snapshot, snapshot_error :: runtime.new_array(u8, base.count)
    if running_error != null || snapshot_error != null {
        return 521
    }
    defer runtime.free_array(running)
    defer runtime.free_array(snapshot)
    copy_into(running, base)
    copy_into(snapshot, base)
    random := Random.{state = 0x5eed5eed5eed5eed}
    replayed := Replayed.{}
    interval_start : usize = 0
    for at in 0..<recorded.log.count + 1 {
        // The log up to here, applied
        copy_into(scratch.bytes, running)
        failed := check_image(&image, acknowledged, at, at % 8 == 0, &replayed, sealed)
        if failed != 0 {
            runtime.log_error("crash: prefix of % entries: check %", at, failed)
            return failed
        }
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
            failed = check_image(&image, acknowledged, interval_start, true, &replayed, sealed)
            if failed != 0 {
                runtime.log_error("crash: subset % of the writes from % to %: check %", subset, interval_start, at, failed)
                return failed
            }
        }
        for torn in interval_start..<at {
            copy_into(scratch.bytes, snapshot)
            for i in interval_start..<torn + 1 {
                if i < recorded.log.count {
                    apply(scratch.bytes, recorded, recorded.log[i], i == torn)
                }
            }
            failed = check_image(&image, acknowledged, interval_start, false, &replayed, sealed)
            if failed != 0 {
                runtime.log_error("crash: the write at % torn: check %", torn, failed)
                return failed
            }
        }
        copy_into(snapshot, running)
        interval_start = at + 1
    }
    runtime.log_info("crash%: % images checked, % of them holding the commit being made", if sealed { " (sealed)" } else { "" }, replayed.images, replayed.newer)
    return 0
}

// A recorded write applied to an image: whole, or torn, its first half only.
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

/*
 * The image mounts and checks out whole, and holds the state after the last commit the log through `durable` made
 * durable, or the one after it; and, with usable, takes another commit and still checks out.
 */
check_image :: fn(device: ptr[slopfs.Device], acknowledged: Acknowledged[], durable: usize, usable: bool, replayed: ptr[mut Replayed],
    sealed: bool) -> int {

    replayed.images += 1
    last : usize = 0
    for each, i in acknowledged {
        if each.log_end <= durable {
            last = i
        }
    }
    container :: slopfs.mount(device^) or_return 530
    defer slopfs.unmount(container)
    if !verified(container) {
        return 531
    }
    volume :: open_test_volume(container, sealed) or_return 532
    digest :: state_digest(volume) or_return 533
    if last >= acknowledged.count {
        return 534
    }
    if digest != acknowledged[last].digest {
        next :: last + 1
        if next >= acknowledged.count || digest != acknowledged[next].digest {
            return 535
        }
        replayed.newer += 1
    }
    if usable {
        file :: slopfs.create(volume, slopfs.ROOT_OBJECT, "after the crash", .File) or_return 536
        bytes : u8[3000]
        slopfs.write(volume, file, 0, bytes) or_return 537
        if commit_failed(container) {
            return 538
        }
    }
    return 0
}

// The data a failed write is tried with: big enough to be written as blocks, not inline in its record
FAILED_BYTES :: 8192

check_failed_writes :: fn(sealed: bool) -> int {
    device :: new_device_of(CRASH_BLOCKS) or_return 560
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0xd0 + i)
    }
    slopfs.format(device, id) or_return 561
    container :: slopfs.mount(device) or_return 562
    defer slopfs.unmount(container)
    volume := create_test_volume(container, "failing", sealed) or_return 563
    data := runtime.new(Data)
    defer runtime.free(data)
    fill(data.bytes, 1, FAILED_BYTES)
    kept :: slopfs.create(volume, slopfs.ROOT_OBJECT, "kept", .File) or_return 564
    lost :: slopfs.create(volume, slopfs.ROOT_OBJECT, "lost", .File) or_return 564
    if (slopfs.write(volume, kept, 0, data.bytes[0..<FAILED_BYTES]) is_error) || (slopfs.write(volume, lost, 0, data.bytes[0..<FAILED_BYTES]) is_error)
        || commit_failed(container) {
        return 565
    }
    acknowledged :: state_digest(volume) or_return 566
    // The disk refuses the next write: refused, and the chunk it was for refused to reads, the other file's read
    fill(data.bytes, 2, FAILED_BYTES)
    disk.read_only = true
    refused :: slopfs.write(volume, lost, 0, data.bytes[0..<FAILED_BYTES]) is_error
    disk.read_only = false
    if !refused {
        return 567
    }
    if slopfs.read(volume, lost, 0, data.bytes[0..<FAILED_BYTES]) is_ok {
        return 568
    }
    if slopfs.read(volume, kept, 0, data.bytes[0..<FAILED_BYTES]) is_error {
        return 569
    }
    // Every commit after it fails, the second as the first
    if (slopfs.commit(container) is_ok) || (slopfs.commit(container) is_ok) {
        return 570
    }
    // Mounted again, the disk holds the last acknowledged commit
    again :: slopfs.mount(device) or_return 571
    defer slopfs.unmount(again)
    reopened :: open_test_volume(again, sealed) or_return 572
    if (state_digest(reopened) or_return 573) != acknowledged {
        return 574
    }
    return 0
}

