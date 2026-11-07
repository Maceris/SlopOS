package slopfs_test

import runtime from "base"
import testing from "std"
import slopfs from ".."

/*
 * A new volume key (decisions/0181's F5, slopfs/keys.hsc, reseal.hsc): an encrypted volume given one, wrapped by a new
 * passphrase, opens with it and not the old, and still reads what was written before; a new key not committed leaves
 * the old passphrase opening it; its blocks sealed again a few at a time, a step left uncommitted only lost, every
 * chunk then sealed with the floor; and once sealed again, the generations before the floor deleted, the volume
 * still opening and reading whole without them, unless a snapshot taken before still holds old blocks.
 */

/** The passphrase a volume's new key is wrapped by. */
NEW_PASSPHRASE :: "a passphrase only the members left have"
/** How many blocks a test's step of sealing again seals, few, so it takes many steps. */
STEP_BLOCKS : u64 : 3

/**
 * Get the new passphrase as bytes.
 *
 * @return NEW_PASSPHRASE's bytes.
 */
new_passphrase :: fn() -> u8[] {
    return text_of(NEW_PASSPHRASE)
}

/**
 * Check that a sealed_disk's large file reads back whole, as written.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param volume The volume, open and unlocked.
 * @param made What sealed_disk made.
 * @param back A buffer the file is read into, overwritten.
 * @param message What's checked, for the failures.
 */
check_large :: fn(t: ptr[mut testing.T], volume: ptr[mut slopfs.Volume], made: ptr[Sealed], back: ptr[mut Data], message: string) {
    got :: slopfs.read(volume, made.large, 0, back.bytes[0..<200000]) or_else 0
    testing.expect_eq(t, got, 200000, message)
    testing.expect_none(t, difference(back.bytes[0..<200000], made.data.bytes[0..<200000]), message)
}

/**
 * Seal a volume's blocks again to a floor, a step at a time, each committed, until the walk's done.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param container The container, mounted.
 * @param volume The volume, unlocked, its keys' current generation the floor.
 * @param floor The floor.
 * @return How many steps it took; Error if a step or a commit failed, recorded.
 */
seal_again :: fn(t: ptr[mut testing.T], container: ptr[mut slopfs.Container], volume: ptr[mut slopfs.Volume], floor: u32) -> Result[u64, testing.Stopped] {
    from := slopfs.Key.{}
    steps := cast[u64](0)
    loop {
        stepping :: slopfs.reseal_step(volume, floor, from, STEP_BLOCKS)
        next :: testing.require_ok(t, stepping, "a step of sealing again is taken")?
        require_commit(t, container, "a step of sealing again commits")?
        steps += 1
        from = next or_break
        if steps > 10000 {
            testing.fail(t, "sealing again ends")
            return .Error(.Failed)
        }
    }
    return .Ok(steps)
}

/**
 * Check that a volume given a new volume key opens with its new passphrase, not its old, reads what was written before,
 * and, sealed again, deletes the generations before its floor and still opens and reads whole without them; and that
 * a new key not committed changes nothing.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if what followed couldn't go on, the failure recorded.
 */
a_new_volume_key_seals_everything_again_and_the_old_generations_go #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := sealed_disk(t, .ChaCha20Poly1305)?
    defer free_sealed(made)
    back := runtime.new(Data)
    defer runtime.free(back)
    // A new key not committed: the old passphrase still opens the volume
    container := testing.require_ok(t, slopfs.mount(made.device), "the container mounts")?
    volume := testing.require_ok(t, slopfs.open_sealed_volume(container, 2, passphrase()), "the volume opens with its passphrase")?
    testing.require_ok(t, slopfs.rekey_volume(container, volume, new_passphrase(), TEST_ARGON2), "the volume takes a new volume key")?
    slopfs.unmount(container)
    container = testing.require_ok(t, slopfs.mount(made.device), "the container mounts again")?
    volume = testing.require_ok(t, slopfs.open_sealed_volume(container, 2, passphrase()),
        "a new volume key not committed leaves the old passphrase opening the volume")?
    // Committed, the new passphrase opens it and the old doesn't
    floor :: testing.require_ok(t, slopfs.rekey_volume(container, volume, new_passphrase(), TEST_ARGON2), "the volume takes a new volume key")?
    testing.expect_eq(t, floor, 2, "the new volume key's generation, its floor, is after the newest")
    require_commit(t, container, "the new volume key commits")?
    slopfs.unmount(container)
    container = testing.require_ok(t, slopfs.mount(made.device), "the container mounts again")?
    testing.expect_error(t, slopfs.open_sealed_volume(container, 2, passphrase()), slopfs.Error.WrongKey, "the old passphrase opens the volume no more")
    volume = testing.require_ok(t, slopfs.open_sealed_volume(container, 2, new_passphrase()), "the new passphrase opens the volume")?
    check_large(t, volume, &made, back, "what was written before the new volume key reads whole")
    old :: testing.require_some(t, chunk_record(volume, made.large, 1), "a chunk written before has its record")?
    testing.expect_eq(t, cast[u32](old.pointer.generation), 1, "a chunk written before the new volume key is sealed with the old generation until it's sealed again")
    // Not sealed again yet, the old generation stays
    testing.expect_none(t, slopfs.drop_old_generations(container, 2) or_else null, "the generations before the floor stay while blocks may be sealed with them")
    // A step not committed is only lost
    testing.require_ok(t, slopfs.reseal_step(volume, floor, slopfs.Key.{}, STEP_BLOCKS), "a step of sealing again is taken")?
    slopfs.unmount(container)
    container = testing.require_ok(t, slopfs.mount(made.device), "the container mounts after a step not committed")?
    volume = testing.require_ok(t, slopfs.open_sealed_volume(container, 2, new_passphrase()), "the volume opens after a step not committed")?
    check_large(t, volume, &made, back, "a step of sealing again not committed loses nothing")
    // Sealed again, a step at a time
    steps :: seal_again(t, container, volume, floor)?
    testing.expect(t, steps > 1, "sealing again takes more than one step of a few blocks")
    for index in cast[u64](0)..<4 {
        match chunk_record(volume, made.large, index) {
            case Some(record) => if cast[u32](record.kind) == cast[u32](slopfs.ExtentKind.Blocks) {
                testing.expect_eq(t, cast[u32](record.pointer.generation), floor, "every chunk is sealed with the floor once it's sealed again")
            }
            case None => {}
        }
    }
    check_large(t, volume, &made, back, "what was sealed again reads whole")
    sealing :: slopfs.sealed_again(container, 2, floor)
    testing.expect_eq(t, testing.require_ok(t, sealing, "the floor is marked sealed")?, true, "a floor still being sealed is marked sealed")
    dropping :: slopfs.drop_old_generations(container, 2)
    dropped :: testing.require_ok(t, dropping, "the generations before the floor are deleted")?
    testing.expect_eq(t, dropped or_else 0, floor, "once sealed again, the generations before the floor are deleted")
    keys :: testing.require_some(t, volume.tree.keys, "the volume has keys")?
    testing.expect_eq(t, slopfs.forget_generations_below(keys, floor), 1, "the volume's keys forget the generation before the floor")
    require_commit(t, container, "the deleted generations commit")?
    slopfs.unmount(container)
    // Without them, it opens and reads whole: nothing needs them
    container = testing.require_ok(t, slopfs.mount(made.device), "the container mounts at the end")?
    defer slopfs.unmount(container)
    testing.expect_none(t, testing.require_ok(t, slopfs.volume_generation(container, 2, 1), "a generation is looked for")?,
        "the old generation's record is gone from the disk")
    volume = testing.require_ok(t, slopfs.open_sealed_volume(container, 2, new_passphrase()), "the volume opens with only the floor's generation")?
    check_large(t, volume, &made, back, "the volume reads whole with only the floor's generation")
    small : u8[64]
    reading_small :: slopfs.read(volume, made.small, 0, small)
    testing.expect_eq(t, testing.require_ok(t, reading_small, "the small file reads")?, MARKER.count, "the small file, inline in a leaf sealed again, reads whole")
    return .Ok
}

/**
 * Check that a snapshot taken before a volume is sealed again keeps the generations before its floor, which it may
 * hold blocks sealed with, until it's deleted.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if what followed couldn't go on, the failure recorded.
 */
a_snapshot_from_before_keeps_the_old_generations_until_it_goes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := sealed_disk(t, .ChaCha20Poly1305)?
    defer free_sealed(made)
    container := testing.require_ok(t, slopfs.mount(made.device), "the container mounts")?
    defer slopfs.unmount(container)
    volume := testing.require_ok(t, slopfs.open_sealed_volume(container, 2, passphrase()), "the volume opens with its passphrase")?
    testing.require_ok(t, slopfs.take_snapshot(container, 2, text_of("before"), 5), "a snapshot is taken before the new key")?
    floor :: testing.require_ok(t, slopfs.rekey_volume(container, volume, new_passphrase(), TEST_ARGON2), "the volume takes a new volume key")?
    require_commit(t, container, "the snapshot and the new key commit")?
    seal_again(t, container, volume, floor)?
    testing.require_ok(t, slopfs.sealed_again(container, 2, floor), "the floor is marked sealed")?
    require_commit(t, container, "the floor marked sealed commits")?
    kept :: testing.require_ok(t, slopfs.drop_old_generations(container, 2), "the old generations are asked to go")?
    testing.expect_none(t, kept, "a snapshot from before the volume was sealed again keeps the old generations")
    testing.require_ok(t, slopfs.delete_snapshot(container, 2, text_of("before"), null), "the snapshot from before is deleted")?
    dropped :: testing.require_ok(t, slopfs.drop_old_generations(container, 2), "the old generations are asked to go again")?
    testing.expect_eq(t, dropped or_else 0, floor, "with the snapshot gone, the old generations go")
    return .Ok
}
