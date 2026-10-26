package slopfs_test

import runtime from "base"
import crypto from "std"
import os from "std"
import slopfs from ".."

/*
 * The fuzzer (design/storage.md §9): an image with a volume of files and directories in it, damaged in many ways, each
 * mounted and used as far as it goes: checked whole, read, written and committed. Nothing may crash or hang; errors
 * are expected. Damage comes three ways: bytes flipped anywhere, blocks copied over others or zeroed, and nodes
 * changed somewhere down a tree with every seal from there to the checkpoint made again, as someone who can compute
 * BLAKE3 could, so what's behind the seals is fuzzed too. SLOPOS_FUZZ_ROUNDS asks for more rounds than the
 * default. Checks from 600.
 */

FUZZ_BLOCKS : u64 : 1024
FUZZ_ROUNDS :: 600

// What the rounds came to, for the log.
Survived :: struct {
    rounds : u64,
    refused : u64,
    mounted : u64,
    verified : u64,
    committed : u64,
}

check_fuzz :: fn(sealed: bool) -> int {
    device :: new_device_of(FUZZ_BLOCKS) or_return 600
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0xf0 + i)
    }
    slopfs.format(device, id) or_return 601
    container := slopfs.mount(device) or_return 602
    volume := create_test_volume(container, "fuzz", sealed) or_return 603
    for step in 0..<STEPS - 1 {
        if workload(volume, step) != 0 || commit_failed(container) {
            return 604
        }
    }
    slopfs.unmount(container)
    base, error :: runtime.new_array(u8, disk.bytes.count)
    if error != null {
        return 605
    }
    defer runtime.free_array(base)
    copy_into(base, disk.bytes)
    rounds : u64 = FUZZ_ROUNDS
    match os.get_environment("SLOPOS_FUZZ_ROUNDS") {
        case Ok(text) => rounds = number_of(text) or_else rounds
        case Error(failure) => {}
    }
    random := Random.{state = 0xf0f0f0f00f0f0f0f}
    survived := Survived.{}
    for round in 0..<rounds {
        copy_into(disk.bytes, base)
        way :: round % 3
        if way == 0 {
            flips :: next_random(&random) % 8 + 1
            for flip_index in 0..<flips {
                at :: cast[usize](next_random(&random) % cast[u64](disk.bytes.count))
                change :: cast[u8](next_random(&random) % 255 + 1)
                if at < disk.bytes.count {
                    disk.bytes[at] = disk.bytes[at] ~ change
                }
            }
        }
        else if way == 1 {
            from :: next_random(&random) % FUZZ_BLOCKS
            to :: next_random(&random) % FUZZ_BLOCKS
            zero :: next_random(&random) % 4 == 0
            for i in 0..<cast[usize](slopfs.BLOCK_BYTES) {
                source :: cast[usize](from * slopfs.BLOCK_BYTES) + i
                target :: cast[usize](to * slopfs.BLOCK_BYTES) + i
                if source < base.count && target < disk.bytes.count {
                    disk.bytes[target] = if zero { cast[u8](0) } else { base[source] }
                }
            }
        }
        else {
            mutate_sealed(disk, &random)
        }
        exercise(&device, &survived, sealed)
        survived.rounds += 1
    }
    runtime.log_info("fuzz%: % rounds: % refused at mount, % mounted, % of those checked out whole, % committed after", if sealed { " (sealed)" } else { "" },
        survived.rounds, survived.refused, survived.mounted, survived.verified, survived.committed)
    // The sealed rounds, at least, mostly mount: their damage is behind the seals
    if survived.mounted == 0 {
        return 606
    }
    return 0
}

number_of :: fn(text: string) -> u64? {
    value : u64 = 0
    if text.count == 0 {
        return null
    }
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](cast[u8](character) - cast[u8]('0'))
    }
    return value
}

// A damaged image, mounted and used as far as it goes, every error taken.
exercise :: fn(device: ptr[slopfs.Device], survived: ptr[mut Survived], sealed: bool) {
    container := slopfs.Container.{}
    mounted := false
    match slopfs.mount(device^) {
        case Ok(made) => {
            survived.mounted += 1
            match slopfs.verify(made) {
                case Ok(report) => survived.verified += 1
                case Error(problem) => {}
            }
            for id in 1..=cast[u64](2) {
                opened :: if sealed { slopfs.open_sealed_volume(made, id, passphrase()) } else { slopfs.open_volume(made, id) }
                match opened {
                    case Ok(volume) => use_volume(volume)
                    case Error(failure) => {}
                }
            }
            match slopfs.commit(made) {
                case Ok => survived.committed += 1
                case Error(failure) => {}
            }
            slopfs.unmount(made)
        }
        case Error(failure) => survived.refused += 1
    }
}

use_volume :: fn(volume: ptr[mut slopfs.Volume]) {
    _ = state_digest(volume)
    root :: slopfs.ROOT_OBJECT
    bytes : u8[5000]
    match slopfs.create(volume, root, "fuzzed", .File) {
        case Ok(file) => {
            _ = slopfs.write(volume, file, 70000, bytes)
            _ = slopfs.set_size(volume, file, 100)
            _ = slopfs.rename(volume, root, "fuzzed", root, "fuzzed again")
        }
        case Error(failure) => {}
    }
    _ = slopfs.remove(volume, root, "fuzzed again")
    _ = slopfs.remove(volume, root, "big.bin")
    _ = slopfs.remove(volume, root, "a.txt")
}

/*
 * A node of the newest checkpoint's trees changed, and resealed with every node above it and the checkpoint, so
 * mounting reads it as if it had been written so.
 */
mutate_sealed :: fn(disk: ptr[mut Disk], random: ptr[mut Random]) {
    newest : usize = 0
    newest_transaction : u64 = 0
    for slot in 0..<slopfs.RING_BLOCKS {
        at :: cast[usize]((1 + slot) * slopfs.BLOCK_BYTES)
        if at + slopfs.size_of_checkpoint() > disk.bytes.count || at >= disk.bytes.count {
            continue
        }
        checkpoint :: cast[ptr[slopfs.Checkpoint]](&disk.bytes[at])
        if cast[u64](checkpoint.transaction) >= newest_transaction && checkpoint.magic[0] == cast[u8]('S') {
            newest_transaction = cast[u64](checkpoint.transaction)
            newest = at
        }
    }
    if newest == 0 || newest >= disk.bytes.count {
        return void
    }
    checkpoint :: cast[ptr[mut slopfs.Checkpoint]](&disk.bytes[newest])
    which :: next_random(random) % 3
    if which == 0 {
        mutate_at(disk, &checkpoint.space_map, false, random, 0)
    }
    else if which == 1 {
        mutate_at(disk, &checkpoint.owners, false, random, 0)
    }
    else {
        mutate_at(disk, &checkpoint.volumes, true, random, 0)
    }
    if newest < disk.bytes.count {
        slopfs.seal_record(view_of(&disk.bytes[newest], slopfs.size_of_checkpoint()), &checkpoint.seal)
    }
}

/*
 * The node a pointer names, or one beneath it, changed: going down to a random child, or for the volumes tree from a
 * leaf into a volume's tree, or changing this one's bytes; then resealed, both copies written, and the pointer given
 * the new seal.
 */
mutate_at :: fn(disk: ptr[mut Disk], pointer: ptr[mut slopfs.BlockPointer], volumes: bool, random: ptr[mut Random], depth: int) -> bool {
    start :: cast[usize](cast[u64](pointer.address) * slopfs.BLOCK_BYTES)
    length :: cast[usize](slopfs.NODE_BYTES)
    if cast[u64](pointer.address) == 0 || start + length > disk.bytes.count {
        return false
    }
    node := runtime.new(slopfs.Node)
    defer runtime.free(node)
    for i in 0..<length {
        j :: start + i
        if j < disk.bytes.count && i < node.bytes.count {
            node.bytes[i] = disk.bytes[j]
        }
    }
    count :: slopfs.count_of(node)
    level :: slopfs.level_of(node)
    descended := false
    if next_random(random) % 4 != 0 && depth < 8 {
        if level > 0 && count > 0 && count <= slopfs.BRANCH_CAPACITY {
            entry :: slopfs.entry_at(node, cast[usize](next_random(random)) % count)
            descended = mutate_at(disk, &entry.child, volumes, random, depth + 1)
        }
        else if level == 0 && volumes && count > 0 && count <= slopfs.LEAF_CAPACITY {
            index :: cast[usize](next_random(random)) % count
            value :: slopfs.value_of(node, index)
            if value.count >= 64 {
                root :: cast[ptr[mut slopfs.BlockPointer]](value.data)
                descended = mutate_at(disk, root, false, random, depth + 1)
            }
        }
    }
    if !descended {
        // Mostly the header and items, where the structure is, now and then anywhere
        span := slopfs.HEADER_SIZE + count * slopfs.ITEM_SIZE + 64
        if span > node.bytes.count || next_random(random) % 4 == 0 {
            span = node.bytes.count
        }
        flips :: next_random(random) % 4 + 1
        for flip_index in 0..<flips {
            at :: cast[usize](next_random(random)) % span
            change :: cast[u8](next_random(random) % 255 + 1)
            if at < node.bytes.count {
                node.bytes[at] = node.bytes[at] ~ change
            }
        }
    }
    crypto.blake3(node.bytes, pointer.seal)
    for place in u64.[cast[u64](pointer.address), cast[u64](pointer.copy)] {
        if place == 0 {
            continue
        }
        to :: cast[usize](place * slopfs.BLOCK_BYTES)
        for i in 0..<length {
            j :: to + i
            if j < disk.bytes.count && i < node.bytes.count {
                disk.bytes[j] = node.bytes[i]
            }
        }
    }
    return true
}
