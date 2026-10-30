package slopfs_test

import runtime from "base"
import crypto from "std"
import slopfs from ".."

/*
 * Encrypted volumes (roadmap 8e, slopfs/keys.hsc): one made with a passphrase, written and committed, and nothing of
 * its names or bytes found anywhere on the disk; locked without its keys, refused with the wrong passphrase, and read
 * back whole with the right one, a container with it locked still checking out; a new key generation, what was
 * written before readable and what's written after sealed with it; a sealed chunk changed, or copied over another,
 * found by its seal; and the same with AES-256-GCM. Checks from 800.
 */

SEALED_BLOCKS : u64 : 1024
PASSPHRASE :: "correct horse battery staple"
// Argon2id kept cheap for the tests: each mount of an encrypted volume derives its key again
TEST_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 64, passes = 1, lanes = 1}
// What a file holds, which mustn't be found on the disk
MARKER :: "a sealed volume's own words"

text_of :: fn(text: string) -> u8[] {
    return string_bytes(text)
}

passphrase :: fn() -> u8[] {
    return text_of(PASSPHRASE)
}

// Whether bytes are anywhere on the disk, at any offset.
appears :: fn(disk: ptr[mut Disk], bytes: u8[]) -> bool {
    if bytes.count == 0 || disk.bytes.count < bytes.count {
        return false
    }
    first :: bytes[0]
    for at in 0..<disk.bytes.count - bytes.count + 1 {
        if at >= disk.bytes.count || disk.bytes[at] != first {
            continue
        }
        end :: at + bytes.count
        if end <= disk.bytes.count && at <= end && same(disk.bytes[at..<end], bytes) {
            return true
        }
    }
    return false
}

// A file's chunk's record, at index.
chunk_record :: fn(volume: ptr[mut slopfs.Volume], file: u64, index: u64) -> slopfs.ExtentRecord? {
    record := slopfs.ExtentRecord.{}
    match slopfs.tree_get(volume.nodes, &volume.tree, slopfs.key_of(file, .Extent, index * slopfs.CHUNK_BYTES),
        view_of(cast[ptr[mut u8]](&record), size_of(slopfs.ExtentRecord))) {
        case Ok(found) => {
            found or_return null
            return record
        }
        case Error(error) => return null
    }
}

check_sealed :: fn() -> int {
    failed := check_cipher(.ChaCha20Poly1305, 800)
    if failed != 0 {
        return failed
    }
    return check_cipher(.Aes256Gcm, 850)
}

check_cipher :: fn(cipher: slopfs.Cipher, base: int) -> int {
    device :: new_device_of(SEALED_BLOCKS) or_return base
    defer free_device(device)
    disk :: cast[ptr[mut Disk]](device.context)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0x5e + i)
    }
    slopfs.format(device, id) or_return base + 1
    container := slopfs.mount(device) or_return base + 2
    // A volume that isn't encrypted beside it, which stays readable without anyone's keys
    plain :: slopfs.create_volume(container, "plain", key_of_volume(), 1) or_return base + 3
    volume := slopfs.create_sealed_volume(container, "secret", key_of_volume(), 1, cipher, passphrase(), TEST_ARGON2) or_return base + 4
    root :: slopfs.ROOT_OBJECT
    small :: slopfs.create(volume, root, "a sealed name.txt", .File) or_return base + 5
    slopfs.write(volume, small, 0, text_of(MARKER)) or_return base + 6
    large :: slopfs.create(volume, root, "large.bin", .File) or_return base + 7
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes[0..<200000], 77)
    // The marker in a chunk of its own, past the inline part
    for character, i in MARKER {
        j :: 70000 + i
        if j < data.bytes.count {
            data.bytes[j] = cast[u8](character)
        }
    }
    slopfs.write(volume, large, 0, data.bytes[0..<200000]) or_return base + 8
    if commit_failed(container) {
        return base + 9
    }
    first_generation :: chunk_record(volume, large, 1) or_return base + 10
    if cast[u32](first_generation.pointer.generation) != 1 {
        return base + 11
    }
    slopfs.unmount(container)
    if appears(disk, text_of(MARKER)) || appears(disk, text_of("a sealed name")) || appears(disk, text_of("large.bin")) {
        return base + 12
    }
    // The plain volume's name, and the sealed one's, are the container's, which isn't encrypted (design/storage.md §5)
    if !appears(disk, text_of("secret")) {
        return base + 13
    }

    // Locked, refused, and unlocked
    container = slopfs.mount(device) or_return base + 14
    match slopfs.open_volume(container, 2) {
        case Ok(opened) => return base + 15
        case Error(error) => {
            if error != .Locked {
                return base + 16
            }
        }
    }
    match slopfs.open_sealed_volume(container, 2, text_of("not the passphrase")) {
        case Ok(opened) => return base + 17
        case Error(error) => {
            if error != .WrongKey {
                return base + 18
            }
        }
    }
    // Checked whole with it locked: its extents are taken as the owners tree says
    match slopfs.verify(container) {
        case Ok(report) => {
            if report.locked != 1 || report.volumes != 2 {
                return base + 19
            }
        }
        case Error(problem) => return base + 20
    }
    volume = slopfs.open_sealed_volume(container, 2, passphrase()) or_return base + 21
    back := runtime.new(Data)
    defer runtime.free(back)
    got :: slopfs.read(volume, large, 0, back.bytes[0..<200000]) or_return base + 22
    if got != 200000 || !same(back.bytes[0..<200000], data.bytes[0..<200000]) {
        return base + 23
    }
    marker : u8[64]
    got_marker :: slopfs.read(volume, small, 0, marker) or_return base + 24
    if got_marker != MARKER.count || got_marker > marker.count || !same(marker[0..<got_marker], text_of(MARKER)) {
        return base + 25
    }
    // Opened, it's walked whole
    match slopfs.verify(container) {
        case Ok(report) => {
            if report.locked != 0 {
                return base + 26
            }
        }
        case Error(problem) => return base + 27
    }

    // A new generation: what's written from now on is sealed with it, and what was written before still reads
    generation :: slopfs.rotate(container, volume) or_return base + 28
    if generation != 2 {
        return base + 29
    }
    later :: slopfs.create(volume, root, "later.bin", .File) or_return base + 30
    pattern(back.bytes[0..<100000], 78)
    slopfs.write(volume, later, 0, back.bytes[0..<100000]) or_return base + 31
    if commit_failed(container) {
        return base + 32
    }
    slopfs.unmount(container)
    container = slopfs.mount(device) or_return base + 33
    volume = slopfs.open_sealed_volume(container, 2, passphrase()) or_return base + 34
    old_chunk :: chunk_record(volume, large, 1) or_return base + 35
    new_chunk :: chunk_record(volume, later, 1) or_return base + 36
    if cast[u32](old_chunk.pointer.generation) != 1 || cast[u32](new_chunk.pointer.generation) != 2 {
        return base + 37
    }
    got_again :: slopfs.read(volume, large, 0, back.bytes[0..<200000]) or_return base + 38
    if got_again != 200000 || !same(back.bytes[0..<200000], data.bytes[0..<200000]) {
        return base + 39
    }
    pattern(data.bytes[0..<100000], 78)
    got_later :: slopfs.read(volume, later, 0, back.bytes[0..<100000]) or_return base + 40
    if got_later != 100000 || !same(back.bytes[0..<100000], data.bytes[0..<100000]) {
        return base + 41
    }
    _ = plain
    slopfs.unmount(container)

    // A sealed chunk changed is found by its seal; so is one copied over another, sealed as it was for another place
    at :: cast[u64](old_chunk.pointer.address) * slopfs.BLOCK_BYTES
    index :: cast[usize](at)
    if index >= disk.bytes.count {
        return base + 50
    }
    saved :: disk.bytes[index]
    flip(disk, at)
    container = slopfs.mount(device) or_return base + 42
    volume = slopfs.open_sealed_volume(container, 2, passphrase()) or_return base + 43
    match slopfs.read(volume, large, 65536, back.bytes[0..<100]) {
        case Ok(count) => return base + 44
        case Error(error) => {
            if error != .Corrupt {
                return base + 45
            }
        }
    }
    slopfs.unmount(container)
    if index < disk.bytes.count {
        disk.bytes[index] = saved
    }
    from :: cast[usize](cast[u64](new_chunk.pointer.address) * slopfs.BLOCK_BYTES)
    to :: cast[usize](at)
    for i in 0..<cast[usize](slopfs.BLOCK_BYTES) {
        source :: from + i
        target :: to + i
        if source < disk.bytes.count && target < disk.bytes.count {
            disk.bytes[target] = disk.bytes[source]
        }
    }
    container = slopfs.mount(device) or_return base + 46
    volume = slopfs.open_sealed_volume(container, 2, passphrase()) or_return base + 47
    match slopfs.read(volume, large, 65536, back.bytes[0..<100]) {
        case Ok(count) => return base + 48
        case Error(error) => {
            if error != .Corrupt {
                return base + 49
            }
        }
    }
    slopfs.unmount(container)
    return 0
}
