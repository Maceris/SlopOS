package slopfs_test

import runtime from "base"
import crypto from "std"
import testing from "std"
import slopfs from ".."

/*
 * Encrypted volumes (roadmap 8e, slopfs/keys.hsc): one made with a passphrase, written and committed, and nothing of
 * its names or bytes found anywhere on the disk; locked without its keys, refused with the wrong passphrase, and read
 * back whole with the right one, a container with it locked still checking out; a new key generation, what was
 * written before readable and what's written after sealed with it; a sealed chunk changed, or copied over another,
 * found by its seal; and the same with AES-256-GCM.
 */

/** The size of an encryption test's disk, in blocks: 4 MiB. */
SEALED_BLOCKS : u64 : 1024
/** The passphrase the tests' encrypted volumes are made with. */
PASSPHRASE :: "correct horse battery staple"
/** Argon2id's parameters, kept cheap for the tests: each mount of an encrypted volume derives its key again. */
TEST_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 64, passes = 1, lanes = 1}
/** What a file holds, which mustn't be found on the disk. */
MARKER :: "a sealed volume's own words"

/**
 * Get text's bytes.
 *
 * @param text The text, whose bytes are viewed, not copied.
 * @return Its bytes, a view of it.
 */
text_of :: fn(text: string) -> u8[] {
    return string_bytes(text)
}

/**
 * Get the tests' passphrase as bytes.
 *
 * @return PASSPHRASE's bytes.
 */
passphrase :: fn() -> u8[] {
    return text_of(PASSPHRASE)
}

/**
 * Tell whether bytes are anywhere on the disk, at any offset.
 *
 * @param disk The test disk, searched, not changed.
 * @param bytes The bytes looked for.
 * @return True if they're found; false if not, or if there are none.
 */
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

/**
 * Read a file's chunk's record.
 *
 * @param volume The volume under test, open.
 * @param file The file whose Extent record is read; not checked to be a file, so anything else has no chunks.
 * @param index Which chunk, from 0; its record's key offset is index * CHUNK_BYTES.
 * @return The record; null if the chunk has none, or it couldn't be read.
 */
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

/** A container with an encrypted volume written and committed, unmounted, as the encryption tests start from it. */
Sealed :: struct {
    /** The disk, of SEALED_BLOCKS blocks, freed by free_sealed. */
    device : slopfs.Device,
    /** The cipher the encrypted volume, 2, is made with. */
    cipher : slopfs.Cipher,
    /** "a sealed name.txt", in volume 2's root, holding MARKER. */
    small : u64,
    /** "large.bin", in volume 2's root, holding data's first 200000 bytes. */
    large : u64,
    /** Pattern 77 with MARKER at 70000, what large holds, from runtime.new, freed by free_sealed. */
    data : ptr[mut Data],
}

/**
 * Format a container of SEALED_BLOCKS blocks with a volume that isn't encrypted, 1, "plain", and an encrypted one, 2,
 * "secret"; write a small file holding MARKER and a large one holding it in a chunk of its own; commit, checking the
 * large file's chunk is sealed with the first key generation; and unmount.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param cipher The cipher volume 2 is made with: ChaCha20Poly1305 or Aes256Gcm.
 * @return The disk and what's on it, the caller's to free with free_sealed; Error if any of it failed, the failure
 *     recorded and nothing left to free.
 */
sealed_disk :: fn(t: ptr[mut testing.T], cipher: slopfs.Cipher) -> Result[Sealed, testing.Stopped] {
    device :: formatted(t, SEALED_BLOCKS, 0x5e)?
    made := Sealed.{device = device, cipher = cipher, data = runtime.new(Data)}
    if seal(t, &made) is_error {
        free_sealed(made)
        return .Error(.Failed)
    }
    return .Ok(made)
}

/**
 * Do sealed_disk's work on its formatted disk.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The disk, formatted, and its cipher; the rest is set here.
 * @return Ok if it's all done, the container unmounted; Error(Failed), the failure recorded, if not, the container
 *     left mounted.
 */
seal :: fn(t: ptr[mut testing.T], made: ptr[mut Sealed]) -> testing.Outcome {
    mounting :: slopfs.mount(made.device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    // A volume that isn't encrypted beside it, which stays readable without anyone's keys
    making_plain :: slopfs.create_volume(container, "plain", key_of_volume(), 1)
    require_done(t, making_plain, "a new container has room for a volume")?
    making :: slopfs.create_sealed_volume(container, "secret", key_of_volume(), 1, made.cipher, passphrase(), TEST_ARGON2)
    volume :: testing.require_ok(t, making, "a new container has room for an encrypted volume beside it")?
    root :: slopfs.ROOT_OBJECT
    making_small :: slopfs.create(volume, root, "a sealed name.txt", .File)
    made.small = testing.require_ok(t, making_small, "an encrypted volume makes a file")?
    writing_small :: slopfs.write(volume, made.small, 0, text_of(MARKER))
    require_done(t, writing_small, "an encrypted volume writes a file inline")?
    making_large :: slopfs.create(volume, root, "large.bin", .File)
    made.large = testing.require_ok(t, making_large, "an encrypted volume makes a second file")?
    data :: made.data
    pattern(data.bytes[0..<200000], 77)
    // The marker in a chunk of its own, past the inline part
    for character, i in MARKER {
        j :: 70000 + i
        if j < data.bytes.count {
            data.bytes[j] = cast[u8](character)
        }
    }
    writing_large :: slopfs.write(volume, made.large, 0, data.bytes[0..<200000])
    require_done(t, writing_large, "an encrypted volume writes a file across chunks")?
    require_commit(t, container, "an encrypted volume's files commit")?
    first_generation :: testing.require_some(t, chunk_record(volume, made.large, 1), "a chunk written has its record")?
    testing.expect_eq(t, cast[u32](first_generation.pointer.generation), 1, "what's written is sealed with the volume's first key generation")
    slopfs.unmount(container)
    return .Ok
}

/**
 * Give back what sealed_disk made: its disk and data.
 *
 * @param made What sealed_disk made, which isn't used after.
 */
free_sealed :: fn(made: Sealed) {
    runtime.free(made.data)
    free_device(made.device)
}

/** The records of two files' second chunks, one written before a new key generation and one after. */
Rotated :: struct {
    /** "later.bin", written after the new generation, holding pattern 78's first 100000 bytes. */
    later : u64,
    /** The record of large's second chunk, written with the first generation. */
    old_chunk : slopfs.ExtentRecord,
    /** The record of later's second chunk, written with the second generation. */
    new_chunk : slopfs.ExtentRecord,
}

/**
 * Make a new key generation for a sealed_disk's encrypted volume and write a file with it, committed; then mount
 * again, read both files' second chunks' records, and unmount.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made What sealed_disk made, unmounted; left unmounted.
 * @param back A buffer later's bytes are made in, overwritten.
 * @return The file written and the chunks' records; Error if any of it failed, the failure recorded.
 */
rotated :: fn(t: ptr[mut testing.T], made: ptr[mut Sealed], back: ptr[mut Data]) -> Result[Rotated, testing.Stopped] {
    found := Rotated.{}
    mounting :: slopfs.mount(made.device)
    container := testing.require_ok(t, mounting, "the container mounts")?
    opening :: slopfs.open_sealed_volume(container, 2, passphrase())
    volume := testing.require_ok(t, opening, "an encrypted volume opens with its passphrase")?
    rotating :: slopfs.rotate(container, volume)
    generation :: testing.require_ok(t, rotating, "an encrypted volume takes a new key generation")?
    testing.expect_eq(t, generation, 2, "a new generation is numbered after the first")
    making :: slopfs.create(volume, slopfs.ROOT_OBJECT, "later.bin", .File)
    found.later = testing.require_ok(t, making, "an encrypted volume makes a file with its new generation")?
    pattern(back.bytes[0..<100000], 78)
    writing :: slopfs.write(volume, found.later, 0, back.bytes[0..<100000])
    require_done(t, writing, "an encrypted volume writes a file with its new generation")?
    require_commit(t, container, "the new generation and the file commit")?
    slopfs.unmount(container)
    mounting_again :: slopfs.mount(made.device)
    container = testing.require_ok(t, mounting_again, "the container mounts again")?
    defer slopfs.unmount(container)
    opening_again :: slopfs.open_sealed_volume(container, 2, passphrase())
    volume = testing.require_ok(t, opening_again, "an encrypted volume opens again with its passphrase")?
    found.old_chunk = testing.require_some(t, chunk_record(volume, made.large, 1), "a chunk written before has its record")?
    found.new_chunk = testing.require_some(t, chunk_record(volume, found.later, 1), "a chunk written after has its record")?
    return .Ok(found)
}

an_encrypted_volume_leaves_nothing_of_its_names_or_bytes_on_the_disk_with_chacha #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_nothing_on_the_disk(t, .ChaCha20Poly1305)
}

an_encrypted_volume_leaves_nothing_of_its_names_or_bytes_on_the_disk_with_aes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_nothing_on_the_disk(t, .Aes256Gcm)
}

an_encrypted_volume_is_locked_refused_and_read_whole_with_its_passphrase_with_chacha #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_unlocking(t, .ChaCha20Poly1305)
}

an_encrypted_volume_is_locked_refused_and_read_whole_with_its_passphrase_with_aes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_unlocking(t, .Aes256Gcm)
}

a_new_key_generation_seals_what_follows_and_what_went_before_still_reads_with_chacha #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_generations(t, .ChaCha20Poly1305)
}

a_new_key_generation_seals_what_follows_and_what_went_before_still_reads_with_aes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_generations(t, .Aes256Gcm)
}

a_sealed_chunk_changed_or_copied_over_another_is_found_by_its_seal_with_chacha #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_tampering(t, .ChaCha20Poly1305)
}

a_sealed_chunk_changed_or_copied_over_another_is_found_by_its_seal_with_aes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    return check_tampering(t, .Aes256Gcm)
}

/**
 * Check that nothing of an encrypted volume's names or bytes is anywhere on the disk, though the container's own
 * records, the volumes' names among them, are.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param cipher The cipher the volume is made with.
 * @return Ok once it's checked; Error(Failed), the failure recorded, if the disk couldn't be made.
 */
check_nothing_on_the_disk :: fn(t: ptr[mut testing.T], cipher: slopfs.Cipher) -> testing.Outcome {
    made := sealed_disk(t, cipher)?
    defer free_sealed(made)
    disk :: cast[ptr[mut Disk]](made.device.context)
    testing.expect(t, !appears(disk, text_of(MARKER)), "a file's bytes, inline or in a chunk, are encrypted")
    testing.expect(t, !appears(disk, text_of("a sealed name")), "a file's name is encrypted")
    testing.expect(t, !appears(disk, text_of("large.bin")), "every file's name is encrypted")
    // design/storage.md §5
    testing.expect(t, appears(disk, text_of("secret")), "a volume's name is the container's, which isn't encrypted")
    return .Ok
}

/**
 * Check that an encrypted volume is locked without its keys, refused with the wrong passphrase, and read back whole
 * with the right one; verify taking a locked volume's extents as the owners tree says, and walking it once open.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param cipher The cipher the volume is made with.
 * @return Ok once it's checked; Error(Failed), the failure recorded, if what follows couldn't go on.
 */
check_unlocking :: fn(t: ptr[mut testing.T], cipher: slopfs.Cipher) -> testing.Outcome {
    made := sealed_disk(t, cipher)?
    defer free_sealed(made)
    mounting :: slopfs.mount(made.device)
    container :: testing.require_ok(t, mounting, "the container mounts")?
    defer slopfs.unmount(container)
    locked :: slopfs.open_volume(container, 2)
    testing.expect_error(t, locked, .Locked, "an encrypted volume doesn't open without its keys")
    wrong :: slopfs.open_sealed_volume(container, 2, text_of("not the passphrase"))
    testing.expect_error(t, wrong, .WrongKey, "the wrong passphrase doesn't unwrap the volume's keys")
    // Checked whole with it locked: its extents are taken as the owners tree says
    verifying_locked :: slopfs.verify(container)
    report_locked :: testing.require_ok(t, verifying_locked, "a container with a volume locked checks out")?
    testing.expect_eq(t, report_locked.locked, 1, "the encrypted volume is counted as locked")
    testing.expect_eq(t, report_locked.volumes, 2, "both volumes are counted")
    opening :: slopfs.open_sealed_volume(container, 2, passphrase())
    volume :: testing.require_ok(t, opening, "the right passphrase opens an encrypted volume")?
    back := runtime.new(Data)
    defer runtime.free(back)
    reading :: slopfs.read(volume, made.large, 0, back.bytes[0..<200000])
    got :: testing.require_ok(t, reading, "an encrypted file across chunks reads")?
    testing.expect_eq(t, got, 200000, "an encrypted file reads as long as was written")
    testing.expect_none(t, difference(back.bytes[0..<200000], made.data.bytes[0..<200000]), "an encrypted file reads as written")
    marker : u8[64]
    reading_marker :: slopfs.read(volume, made.small, 0, marker)
    got_marker :: testing.require_ok(t, reading_marker, "an encrypted inline file reads")?
    testing.expect_eq(t, got_marker, MARKER.count, "an encrypted inline file reads as long as was written")
    if got_marker > marker.count {
        testing.fail(t, "a read gives at most the buffer's bytes")
        return .Error(.Failed)
    }
    testing.expect_none(t, difference(marker[0..<got_marker], text_of(MARKER)), "an encrypted inline file reads as written")
    // Opened, it's walked whole
    verifying :: slopfs.verify(container)
    report :: testing.require_ok(t, verifying, "a container with its encrypted volume open checks out")?
    testing.expect_eq(t, report.locked, 0, "an open volume is walked, not taken as locked")
    return .Ok
}

/**
 * Check a new key generation: what's written from then on is sealed with it, and what was written before still reads,
 * after a mount.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param cipher The cipher the volume is made with.
 * @return Ok once it's checked; Error(Failed), the failure recorded, if what follows couldn't go on.
 */
check_generations :: fn(t: ptr[mut testing.T], cipher: slopfs.Cipher) -> testing.Outcome {
    made := sealed_disk(t, cipher)?
    defer free_sealed(made)
    back := runtime.new(Data)
    defer runtime.free(back)
    chunks :: rotated(t, &made, back)?
    testing.expect_eq(t, cast[u32](chunks.old_chunk.pointer.generation), 1, "a chunk written before a new generation keeps the old one")
    testing.expect_eq(t, cast[u32](chunks.new_chunk.pointer.generation), 2, "a chunk written after a new generation is sealed with it")
    mounting :: slopfs.mount(made.device)
    container :: testing.require_ok(t, mounting, "the container mounts")?
    defer slopfs.unmount(container)
    opening :: slopfs.open_sealed_volume(container, 2, passphrase())
    volume :: testing.require_ok(t, opening, "an encrypted volume opens with its passphrase")?
    reading :: slopfs.read(volume, made.large, 0, back.bytes[0..<200000])
    got :: testing.require_ok(t, reading, "a file written with the old generation reads")?
    testing.expect_eq(t, got, 200000, "a file written with the old generation reads as long as was written")
    testing.expect_none(t, difference(back.bytes[0..<200000], made.data.bytes[0..<200000]),
        "a file written with the old generation reads as written, its key still kept")
    pattern(made.data.bytes[0..<100000], 78)
    reading_later :: slopfs.read(volume, chunks.later, 0, back.bytes[0..<100000])
    got_later :: testing.require_ok(t, reading_later, "a file written with the new generation reads")?
    testing.expect_eq(t, got_later, 100000, "a file written with the new generation reads as long as was written")
    testing.expect_none(t, difference(back.bytes[0..<100000], made.data.bytes[0..<100000]), "a file written with the new generation reads as written")
    return .Ok
}

/**
 * Check that a sealed chunk changed is found by its seal, and so is one copied over another, sealed as it was for
 * another place.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param cipher The cipher the volume is made with.
 * @return Ok once it's checked; Error(Failed), the failure recorded, if what follows couldn't go on.
 */
check_tampering :: fn(t: ptr[mut testing.T], cipher: slopfs.Cipher) -> testing.Outcome {
    made := sealed_disk(t, cipher)?
    defer free_sealed(made)
    back := runtime.new(Data)
    defer runtime.free(back)
    chunks :: rotated(t, &made, back)?
    disk :: cast[ptr[mut Disk]](made.device.context)
    at :: cast[u64](chunks.old_chunk.pointer.address) * slopfs.BLOCK_BYTES
    index :: cast[usize](at)
    if index >= disk.bytes.count {
        testing.fail(t, "a chunk's record points within the disk")
        return .Error(.Failed)
    }
    saved :: disk.bytes[index]
    flip(disk, at)
    mounting :: slopfs.mount(made.device)
    container := testing.require_ok(t, mounting, "a container mounts with a chunk changed, which it doesn't read")?
    opening :: slopfs.open_sealed_volume(container, 2, passphrase())
    volume := testing.require_ok(t, opening, "an encrypted volume opens with a chunk changed")?
    changed :: slopfs.read(volume, made.large, 65536, back.bytes[0..<100])
    testing.expect_error(t, changed, .Corrupt, "a chunk changed doesn't open with its seal")
    slopfs.unmount(container)
    if index < disk.bytes.count {
        disk.bytes[index] = saved
    }
    from :: cast[usize](cast[u64](chunks.new_chunk.pointer.address) * slopfs.BLOCK_BYTES)
    to :: cast[usize](at)
    for i in 0..<cast[usize](slopfs.BLOCK_BYTES) {
        source :: from + i
        target :: to + i
        if source < disk.bytes.count && target < disk.bytes.count {
            disk.bytes[target] = disk.bytes[source]
        }
    }
    mounting_again :: slopfs.mount(made.device)
    container = testing.require_ok(t, mounting_again, "a container mounts with a chunk copied over another")?
    defer slopfs.unmount(container)
    opening_again :: slopfs.open_sealed_volume(container, 2, passphrase())
    volume = testing.require_ok(t, opening_again, "an encrypted volume opens with a chunk copied over another")?
    copied :: slopfs.read(volume, made.large, 65536, back.bytes[0..<100])
    testing.expect_error(t, copied, .Corrupt, "a chunk copied from another place doesn't open with this place's seal")
    return .Ok
}
