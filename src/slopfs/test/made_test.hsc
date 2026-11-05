package slopfs_test

import testing from "std"
import slopfs from ".."

/*
 * Volumes made at run time (decisions/0141), as the container service and a volume server make them between them: one
 * registered with nothing in it, which the same name can't be again; a sealed one's first keys made apart from the
 * container, which is given only the wrapped records, as the container service is; each filled with its root
 * directory, written, committed, and read back whole after a mount, the sealed one only with its passphrase.
 */

/** What each volume made at run time is given to hold, in its file "made.txt". */
MADE_TEXT :: "made at run time"

a_volume_made_at_run_time_is_registered_once_by_its_name #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    device :: formatted(t, SEALED_BLOCKS, 0x6a)?
    defer free_device(device)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    defer slopfs.unmount(container)
    registering :: slopfs.register_volume(container, text_of("plain"), key_of_volume(), 5, .None)
    require_done(t, registering, "a new container registers a volume")?
    again :: slopfs.register_volume(container, text_of("plain"), key_of_volume(), 5, .None)
    testing.expect_error(t, again, .AlreadyExists, "a volume's name is its own: the same name isn't registered twice")
    return .Ok
}

volumes_made_at_run_time_are_filled_and_read_back_after_a_mount #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    device :: formatted(t, SEALED_BLOCKS, 0x6a)?
    defer free_device(device)
    mounting :: slopfs.mount(device)
    container := testing.require_ok(t, mounting, "a formatted disk mounts")?
    registering :: slopfs.register_volume(container, text_of("plain"), key_of_volume(), 5, .None)
    plain :: testing.require_ok(t, registering, "a new container registers a volume")?
    registering_sealed :: slopfs.register_volume(container, text_of("sealed"), key_of_volume(), 5, .Aes256Gcm)
    sealed :: testing.require_ok(t, registering_sealed, "a new container registers an encrypted volume")?
    reading :: slopfs.volume_record(container, sealed)
    record := testing.require_ok(t, reading, "a registered volume's record reads")?
    testing.expect(t, slopfs.is_unfilled(&record), "a volume registered has nothing in it yet, not even its root")
    // The volume server's part: its keys made from the passphrase, only the wrapped records handed over
    making_keys :: slopfs.new_keys(.Aes256Gcm)
    keys :: testing.require_ok(t, making_keys, "keys for AES-256-GCM are made")?
    making_first :: slopfs.first_keys(keys, passphrase(), TEST_ARGON2, container.id, sealed, container.nodes.transaction)
    slopfs.free_keys(keys)
    made :: testing.require_ok(t, making_first, "a volume's first keys are made from its passphrase")?
    wrapping :: slopfs.put_wrap(container, sealed, 0, &made.wrap)
    require_done(t, wrapping, "the container takes the wrapped key record")?
    generating :: slopfs.put_generation(container, sealed, made.number, &made.generation)
    require_done(t, generating, "the container takes the first generation's record")?
    require_commit(t, container, "the registered volumes and the key records commit")?

    // Each filled with its root directory, and written
    for which in u64.[plain, sealed] {
        opening :: if which == sealed { slopfs.open_sealed_volume(container, which, passphrase()) } else { slopfs.open_volume(container, which) }
        volume :: testing.require_ok(t, opening, "a registered volume opens, the encrypted one with its passphrase")?
        filling :: slopfs.fill_volume(volume, 5)
        require_done(t, filling, "a registered volume is filled with its root directory")?
        creating :: slopfs.create(volume, slopfs.ROOT_OBJECT, "made.txt", .File)
        file :: testing.require_ok(t, creating, "a filled volume makes a file in its root")?
        writing :: slopfs.write(volume, file, 0, text_of(MADE_TEXT))
        require_done(t, writing, "a filled volume writes a file")?
    }
    require_commit(t, container, "the filled volumes commit")?
    slopfs.unmount(container)

    // Filled now, and read back; the sealed one locked without its passphrase
    mounting_again :: slopfs.mount(device)
    container = testing.require_ok(t, mounting_again, "the container mounts again")?
    defer slopfs.unmount(container)
    locked :: slopfs.open_volume(container, sealed)
    testing.expect_error(t, locked, .Locked, "an encrypted volume made at run time doesn't open without its passphrase")
    for which in u64.[plain, sealed] {
        reading_filled :: slopfs.volume_record(container, which)
        filled := testing.require_ok(t, reading_filled, "a filled volume's record reads")?
        testing.expect(t, !slopfs.is_unfilled(&filled), "a filled volume's record has its root, after a mount")
        opening :: if which == sealed { slopfs.open_sealed_volume(container, which, passphrase()) } else { slopfs.open_volume(container, which) }
        volume :: testing.require_ok(t, opening, "a filled volume opens after a mount, the encrypted one with its passphrase")?
        looking :: slopfs.lookup(volume, slopfs.ROOT_OBJECT, "made.txt")
        found :: testing.require_ok(t, looking, "a filled volume looks up a name")?
        file :: testing.require_some(t, found, "the file written is kept across a mount")?
        back : u8[64]
        reading_file :: slopfs.read(volume, file, 0, back)
        got :: testing.require_ok(t, reading_file, "the file reads")?
        testing.expect_eq(t, got, MADE_TEXT.count, "the file is as long as was written")
        if got > back.count {
            testing.fail(t, "a read gives at most the buffer's bytes")
            return .Error(.Failed)
        }
        testing.expect_none(t, difference(back[0..<got], text_of(MADE_TEXT)), "the file reads as written")
    }
    return .Ok
}
