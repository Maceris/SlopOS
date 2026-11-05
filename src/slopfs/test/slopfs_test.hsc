/**
 * slopfs's tests, as a hosted program (tools/unit_tests.py, decisions/0175): main runs them and returns how many
 * failed. Over a buffer standing in for a disk: the B+tree against a model, through splits, merges and commits; the
 * container and its volumes (container_test.hsc), volumes apart, history, encryption, snapshots, quotas, links and
 * volumes made at run time; then the crash-state tester, failed writes and the fuzzer, on a volume that isn't
 * encrypted and on one that is.
 */
package slopfs_test

import compiler from "base"
import runtime from "base"
import maps from "std"
import testing from "std"
import slopfs from ".."
import hosted_faults from "../../robustness/hosted"

/** The size of a test disk, in 4 KiB blocks: 32 MiB. */
BLOCKS : u64 : 8192

/**
 * A disk in memory. Recording, it keeps every write's blocks and bytes, and every flush, in order, for the crash-state
 * tester; read-only, it refuses writes.
 */
Disk :: struct {
    /** The disk's bytes, from runtime.new_array, freed by free_device. */
    bytes : mut u8[],
    /** How many writes it has taken. */
    writes : u64,
    /** How many flushes it has taken. */
    flushes : u64,
    /** Whether it records each write and flush in log. */
    recording : bool,
    /** Whether it refuses every write. */
    read_only : bool,
    /** The writes and flushes recorded, in order. */
    log : Recorded[..],
    /** The recorded writes' bytes, one after another, as log's entries say. */
    logged : u8[..],
}

/** A write the disk recorded, its bytes at `at` in its log, or a flush. */
Recorded :: struct {
    /** Whether it's a flush, whose other fields are 0. */
    flush : bool,
    /** The write's first block. */
    block : u64,
    /** How many blocks it wrote. */
    count : u64,
    /** Where its bytes start in the disk's logged. */
    at : usize,
}

/**
 * Read blocks from a test disk, as a slopfs.Device's read does.
 *
 * @param context The Disk, as a rawptr.
 * @param block The first block, from the disk's start.
 * @param count How many blocks.
 * @param into Where they go, at least count * BLOCK_BYTES bytes.
 * @return True if they were read; false if they run past the disk's end or into is too small.
 */
read_blocks :: fn(context: rawptr, block: u64, count: u64, into: mut u8[]) -> bool {
    disk :: cast[ptr[mut Disk]](context)
    start :: cast[usize](block * slopfs.BLOCK_BYTES)
    length :: cast[usize](count * slopfs.BLOCK_BYTES)
    if start + length > disk.bytes.count || length > into.count {
        return false
    }
    for i in 0..<length {
        j :: start + i
        if j < disk.bytes.count && i < into.count {
            into[i] = disk.bytes[j]
        }
    }
    return true
}

/**
 * Write blocks to a test disk, as a slopfs.Device's write does, recording the write if the disk is recording.
 *
 * @param context The Disk, as a rawptr.
 * @param block The first block, from the disk's start.
 * @param count How many blocks.
 * @param from Their bytes, at least count * BLOCK_BYTES.
 * @return True if they were written; false, writing nothing, if the disk is read-only, they run past its end, or from
 *     is too small.
 */
write_blocks :: fn(context: rawptr, block: u64, count: u64, from: u8[]) -> bool {
    disk :: cast[ptr[mut Disk]](context)
    start :: cast[usize](block * slopfs.BLOCK_BYTES)
    length :: cast[usize](count * slopfs.BLOCK_BYTES)
    if disk.read_only || start + length > disk.bytes.count || length > from.count {
        return false
    }
    for i in 0..<length {
        j :: start + i
        if j < disk.bytes.count && i < from.count {
            disk.bytes[j] = from[i]
        }
    }
    disk.writes += 1
    if disk.recording {
        runtime.array_add(&disk.log, Recorded.{block = block, count = count, at = disk.logged.count})
        for i in 0..<length {
            if i < from.count {
                runtime.array_add(&disk.logged, from[i])
            }
        }
    }
    return true
}

/**
 * Flush a test disk, as a slopfs.Device's flush does: counted, and recorded if the disk is recording.
 *
 * @param context The Disk, as a rawptr.
 * @return True: a disk in memory is always durable.
 */
flush_blocks :: fn(context: rawptr) -> bool {
    disk :: cast[ptr[mut Disk]](context)
    disk.flushes += 1
    if disk.recording {
        runtime.array_add(&disk.log, Recorded.{flush = true})
    }
    return true
}

/** A bump allocator for the tree's own test, giving back nothing. */
Bump :: struct {
    /** The next block it gives. */
    next : u64,
    /** How many blocks were released to it, which it counts and never reuses. */
    released : u64,
}

/**
 * Allocate blocks from a bump allocator, as a slopfs.Nodes' allocate does.
 *
 * @param space The Bump, as a rawptr.
 * @param blocks How many blocks.
 * @param owner Whose they are; not used.
 * @param data Whether they're for a file's bytes; not used.
 * @return The first block; null once the blocks would pass BLOCKS.
 */
bump_allocate :: fn(space: rawptr, blocks: u64, owner: u64, data: bool) -> u64? {
    bump :: cast[ptr[mut Bump]](space)
    if bump.next + blocks > BLOCKS {
        return null
    }
    at :: bump.next
    bump.next += blocks
    return at
}

/**
 * Release blocks to a bump allocator, as a slopfs.Nodes' release does: only counted.
 *
 * @param space The Bump, as a rawptr.
 * @param address The extent's first block; not used.
 * @param blocks How many blocks, added to its released.
 * @param owner Whose they were; not used.
 * @param birth When they were born; not used.
 */
bump_release :: fn(space: rawptr, address: u64, blocks: u64, owner: u64, birth: u64) {
    bump :: cast[ptr[mut Bump]](space)
    bump.released += blocks
}

/** A random number generator, xorshift64*, for keys that look random and come out the same every run. */
Random :: struct {
    /** The generator's state; never 0, which would give only 0s. */
    state : u64,
}

/**
 * Get the next random number.
 *
 * @param random The generator, its state advanced.
 * @return A number, any u64.
 */
next_random :: fn(random: ptr[mut Random]) -> u64 {
    x := random.state
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    random.state = x
    return x * 0x2545f4914f6cdd1d
}

/**
 * Open the test volume, 1: as it is, or unlocked with the tests' passphrase.
 *
 * @param container The container, which keeps the volume among its open ones.
 * @param sealed Whether the volume is encrypted.
 * @return The volume, or why it couldn't be opened, as open_volume or open_sealed_volume says.
 */
open_test_volume :: fn(container #escaping : ptr[mut slopfs.Container], sealed: bool) -> Result[ptr[mut slopfs.Volume], slopfs.Error] {
    if sealed {
        return slopfs.open_sealed_volume(container, 1, passphrase())
    }
    return slopfs.open_volume(container, 1)
}

/**
 * Make a new test volume: as it is, or encrypted with ChaCha20-Poly1305 and the tests' passphrase.
 *
 * @param container The container, which keeps the volume among its open ones.
 * @param name The new volume's name, 1 to VOLUME_NAME_BYTES bytes, as create_volume needs.
 * @param sealed Whether to encrypt it, with TEST_ARGON2's quick parameters.
 * @return The volume, or why it couldn't be made, as create_volume or create_sealed_volume says.
 */
create_test_volume :: fn(container #escaping : ptr[mut slopfs.Container], name: string, sealed: bool) -> Result[ptr[mut slopfs.Volume], slopfs.Error] {
    if sealed {
        return slopfs.create_sealed_volume(container, name, key_of_volume(), 1, .ChaCha20Poly1305, passphrase(), TEST_ARGON2)
    }
    return slopfs.create_volume(container, name, key_of_volume(), 1)
}

/**
 * Make a disk of BLOCKS zeroed blocks in memory, as a device; nothing of it is on the stack, so what holds it can be
 * pointed to.
 *
 * @return The device, the caller's to free with free_device; null without the memory for its bytes.
 */
new_device :: fn() -> slopfs.Device? {
    return new_device_of(BLOCKS)
}

/**
 * Make a disk of zeroed blocks in memory, as a device.
 *
 * @param blocks Its size in blocks.
 * @return The device, its context a Disk, the caller's to free with free_device; null without the memory for its
 *     bytes.
 */
new_device_of :: fn(blocks: u64) -> slopfs.Device? {
    bytes, error :: runtime.new_array(u8, cast[usize](blocks * slopfs.BLOCK_BYTES))
    if error != null {
        return null
    }
    for i in 0..<bytes.count {
        bytes[i] = 0
    }
    disk := runtime.new(Disk)
    disk^ = Disk.{bytes = bytes}
    return slopfs.Device.{context = cast[rawptr](disk), block_count = blocks, read = read_blocks, write = write_blocks,
        flush = flush_blocks}
}

/**
 * Free a test disk: its bytes, its log and the Disk.
 *
 * @param device The device, from new_device or new_device_of; it may not be used again.
 */
free_device :: fn(device: slopfs.Device) {
    disk :: cast[ptr[mut Disk]](device.context)
    runtime.free_array(disk.bytes)
    runtime.array_free(&disk.log)
    runtime.array_free(&disk.logged)
    runtime.free(disk)
}

/**
 * Make a disk in memory and format a container on it, for a test that mounts it.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param blocks The disk's size in blocks, enough for a container (BLOCKS, or a test's own smaller size).
 * @param first The container ID's first byte, each byte after it one more, so each test's container is its own.
 * @return The device, the caller's to free with free_device; Error if it couldn't be had or formatted, the failure
 *     recorded and nothing left to free.
 */
formatted :: fn(t: ptr[mut testing.T], blocks: u64, first: u8) -> Result[slopfs.Device, testing.Stopped] {
    device :: testing.require_some(t, new_device_of(blocks), "the disk's bytes are allocated")?
    id : u8[16]
    for i in 0..<id.count {
        id[i] = first + cast[u8](i)
    }
    formatting :: slopfs.format(device, id)
    if !testing.expect_ok(t, formatting, "a zeroed disk takes a container") {
        free_device(device)
        return .Error(.Failed)
    }
    return .Ok(device)
}

/**
 * Require a result to be Ok, as expect_ok checks, ending the test with ? if it isn't; unlike testing.require_ok, for a
 * result of any value, void too, which is dropped.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param result The result, of any Result type.
 * @param message Why it should succeed, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return Ok if it was Ok; Error(Failed), the failure recorded with the error, if it was an Error.
 */
require_done :: fn[V, E](t: ptr[mut testing.T], result: Result[V, E], message: string, location := #caller_location) -> testing.Outcome {
    return testing.outcome_of(testing.expect_ok(t, result, message, location))
}

/**
 * Commit a container, checking that the commit succeeds and that what it left checks out whole.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param container The container under test, mounted.
 * @param message Why the commit should succeed, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return True if it committed and verify found nothing wrong; false, the failure (the commit's error, or the problem
 *     verify found) recorded, if not.
 */
commits :: fn(t: ptr[mut testing.T], container: ptr[mut slopfs.Container], message: string, location := #caller_location) -> bool {
    committed :: slopfs.commit(container)
    if !testing.expect_ok(t, committed, message, location) {
        return false
    }
    return checks_out(t, container, message, location)
}

/**
 * Commit a container, as commits checks, ending the test with ? if it doesn't commit or check out.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param container The container under test, mounted.
 * @param message Why the commit should succeed, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return Ok if it committed and checked out; Error(Failed), the failure recorded, if not.
 */
require_commit :: fn(t: ptr[mut testing.T], container: ptr[mut slopfs.Container], message: string, location := #caller_location) -> testing.Outcome {
    return testing.outcome_of(commits(t, container, message, location))
}

/**
 * Check that a container checks out whole: verify finds no problem.
 *
 * @param t The test's state, which a failure, with the problem verify found, is recorded in.
 * @param container The container under test, mounted.
 * @param message Why it should check out, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return True if verify found no problem; false, the failure recorded, if it did.
 */
checks_out :: fn(t: ptr[mut testing.T], container: ptr[mut slopfs.Container], message: string, location := #caller_location) -> bool {
    verified :: slopfs.verify(container)
    return testing.expect_ok(t, verified, message, location)
}

/**
 * Commit a container, and tell whether the commit failed, or what it left doesn't check out whole, for code that
 * only counts or names what went wrong rather than asserting it (the crash images).
 *
 * @param container The container under test, mounted.
 * @return True if the commit failed or verify found a problem; false if all's well.
 */
commit_failed :: fn(container: ptr[mut slopfs.Container]) -> bool {
    match slopfs.commit(container) {
        case Ok => return slopfs.verify(container) is_error
        case Error(error) => return true
    }
}

/** The tree test's tree, grown against its model: what each of the tree tests checks. */
Grown :: struct {
    /** The disk the tree's nodes are written to, freed with free_grown. */
    device : slopfs.Device,
    /** Where the tree's blocks come from, from runtime.new, freed with free_grown. */
    bump : ptr[mut Bump],
    /** The tree's nodes, half of them written and half still dirty. */
    nodes : slopfs.Nodes,
    /** The tree, of kind Volume and owner 7. */
    tree : slopfs.Tree,
    /** Each key's object, mapped to the seed of the value last put for it; a key deleted isn't there. */
    model : maps.HashMap[u64, u64, maps.hash_integer[u64]],
}

/** How many objects the tree test's keys are drawn from. */
TREE_KEYS :: 3000
/** The most bytes a value in the tree test has. */
TREE_VALUE_BYTES :: 600

/**
 * Grow a tree against a model, a map from each key's object to the value written for it: 20000 puts, replacing and
 * deleting at random, with values of 0 to 599 bytes, committed every 997 steps, checking that each delete finds what
 * the model has and each write leaves nothing dirty.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The tree, the caller's to free with free_grown; Error if the disk couldn't be had or the tree refused a put,
 *     delete or write, the failure recorded and nothing left to free.
 */
grown :: fn(t: ptr[mut testing.T]) -> Result[Grown, testing.Stopped] {
    device :: testing.require_some(t, new_device(), "the disk's bytes are allocated")?
    bump := runtime.new(Bump)
    bump^ = Bump.{next = slopfs.FIRST_DATA}
    made := Grown.{device = device, bump = bump, tree = slopfs.Tree.{kind = .Volume, owner = 7}}
    made.nodes = slopfs.Nodes.{device = device, transaction = 1, space = cast[rawptr](bump), allocate = bump_allocate,
        release = bump_release}
    if grow(t, &made) is_error {
        free_grown(&made)
        return .Error(.Failed)
    }
    return .Ok(made)
}

/**
 * Do grown's puts, deletes and commits on a tree made for them.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param made The tree, empty, with its nodes and model; grown in place.
 * @return Ok once every step is done; Error(Failed), the failure recorded, if the tree refused one.
 */
grow :: fn(t: ptr[mut testing.T], made: ptr[mut Grown]) -> testing.Outcome {
    random := Random.{state = 0x9e3779b97f4a7c15}
    value : u8[TREE_VALUE_BYTES]
    for step in 0..<20000 {
        object :: next_random(&random) % TREE_KEYS
        choice :: next_random(&random) % 4
        key :: slopfs.key_of(object, .Object, 0)
        if choice == 0 {
            deleted :: slopfs.tree_delete(&made.nodes, &made.tree, key)
            was_there :: testing.require_ok(t, deleted, "a delete works whether or not the key is there")?
            testing.expect_eq(t, was_there, maps.map_has(&made.model, object), "a delete finds the key just when the model has it")
            _ = maps.map_remove(&made.model, object)
        }
        else {
            seed :: next_random(&random)
            length :: cast[usize](seed % TREE_VALUE_BYTES)
            fill(value, seed, length)
            put :: slopfs.tree_put(&made.nodes, &made.tree, key, value[0..<length])
            require_done(t, put, "a put of up to 599 bytes fits a leaf, and the disk has room")?
            maps.map_put(&made.model, object, seed)
        }
        if step % 997 == 996 {
            written :: slopfs.tree_write(&made.nodes, &made.tree)
            require_done(t, written, "the tree's dirty nodes are written")?
            testing.expect_eq(t, made.nodes.dirty.count, 0, "a written tree has no dirty nodes left")
            made.nodes.transaction += 1
        }
    }
    return .Ok
}

/**
 * Give back a tree grown made.
 *
 * @param made The tree, whose model, allocator and disk aren't used after.
 */
free_grown :: fn(made: ptr[mut Grown]) {
    maps.map_free(&made.model)
    runtime.free(made.bump)
    free_device(made.device)
}

a_tree_grows_past_one_leaf_through_puts_and_deletes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := grown(t)?
    defer free_grown(&made)
    loaded :: slopfs.load(&made.nodes, &made.tree, &made.tree.root)
    root :: testing.require_ok(t, loaded, "the tree's root loads")?
    level :: slopfs.level_of(root)
    slopfs.done(root)
    testing.expect_ne(t, level, 0, "thousands of keys don't fit one leaf, so splits and merges were taken")
    return .Ok
}

every_key_reads_back_as_the_model_has_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := grown(t)?
    defer free_grown(&made)
    value : u8[TREE_VALUE_BYTES]
    read_back : u8[TREE_VALUE_BYTES]
    // Half of it written and half still dirty
    for object in 0..<cast[u64](TREE_KEYS) {
        got :: slopfs.tree_get(&made.nodes, &made.tree, slopfs.key_of(object, .Object, 0), read_back)
        found :: testing.require_ok(t, got, "a key reads whether or not it's there")?
        match maps.map_get(&made.model, object) {
            case Some(seed) => {
                length :: cast[usize](seed % TREE_VALUE_BYTES)
                fill(value, seed, length)
                expected : usize? = length
                testing.expect_eq(t, found, expected, "a key the model has is found, as long as the value last put")
                testing.expect_none(t, difference(read_back[0..<length], value[0..<length]), "a key reads as the value last put")
            }
            case None => testing.expect_none(t, found, "a key the model hasn't, never put or deleted, isn't found")
        }
    }
    return .Ok
}

walking_forward_finds_every_key_in_order #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := grown(t)?
    defer free_grown(&made)
    read_back : u8[TREE_VALUE_BYTES]
    count : u64 = 0
    at := slopfs.Key.{}
    loop {
        next :: slopfs.tree_next(&made.nodes, &made.tree, at, read_back)
        found :: testing.require_ok(t, next, "the next record reads")?
        record :: found or_break
        testing.expect(t, maps.map_has(&made.model, record.key.object), "every record walked to is a key the model has")
        testing.expect(t, !compare_after(record.key, at), "the next record is at or after the key searched from")
        count += 1
        at = slopfs.Key.{object = record.key.object, kind = record.key.kind, offset = record.key.offset + 1}
    }
    testing.expect_eq(t, count, cast[u64](made.model.count), "walking forward finds each of the model's keys once")
    return .Ok
}

walking_back_finds_every_key #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := grown(t)?
    defer free_grown(&made)
    read_back : u8[TREE_VALUE_BYTES]
    count : u64 = 0
    at := slopfs.Key.{object = 0xffffffffffffffff, kind = 0xff, offset = 0xffffffffffffffff}
    loop {
        previous :: slopfs.tree_previous(&made.nodes, &made.tree, at, read_back)
        found :: testing.require_ok(t, previous, "the previous record reads")?
        record :: found or_break
        testing.expect(t, maps.map_has(&made.model, record.key.object), "every record walked to is a key the model has")
        count += 1
        if record.key.object == 0 {
            break
        }
        at = slopfs.Key.{object = record.key.object - 1, kind = 0xff, offset = 0xffffffffffffffff}
    }
    testing.expect_eq(t, count, cast[u64](made.model.count), "walking back finds each of the model's keys once")
    return .Ok
}

/**
 * Tell whether a found key is before the one searched from, which tree_next never gives.
 *
 * @param found The key tree_next found.
 * @param from The key searched from.
 * @return True if found is before from, so the search went wrong.
 */
compare_after :: fn(found: slopfs.Key, from: slopfs.Key) -> bool {
    return slopfs.compare_keys(found, from) < 0
}

/**
 * Fill bytes with a pattern made from a seed, the same for the same seed.
 *
 * @param into The bytes; those past length are left as they were.
 * @param seed The seed, any value; the same seed makes the same bytes.
 * @param length How many bytes to fill.
 */
fill :: fn(into: mut u8[], seed: u64, length: usize) {
    for i in 0..<length {
        if i < into.count {
            into[i] = cast[u8]((seed >> cast[u64](i % 8 * 8)) + cast[u64](i))
        }
    }
}

/**
 * Tell whether two byte strings are the same.
 *
 * @param a A byte string, of any length.
 * @param b The other byte string, of any length.
 * @return True if they're the same length and byte for byte alike.
 */
same :: fn(a: u8[], b: u8[]) -> bool {
    return difference(a, b) is_none
}

/**
 * Find where two byte strings first differ, for an assertion to report.
 *
 * @param a A byte string, of any length: what was read.
 * @param b The other byte string, of any length: what it should be.
 * @return The offset of the first byte that differs, or the shorter one's length if one is a prefix of the other;
 *     null if they're the same length and byte for byte alike.
 */
difference :: fn(a: u8[], b: u8[]) -> usize? {
    for byte, i in a {
        if i >= b.count || b[i] != byte {
            return i
        }
    }
    if a.count != b.count {
        return a.count
    }
    return null
}

/**
 * Run the tests, reporting to standard output.
 *
 * @return How many failed: 0 when every one passed.
 */
run_tests :: fn() -> int {
    return cast[int](testing.run(#insert testing.tests_of(compiler.load_package(".")), testing.STANDARD_OUTPUT))
}

/**
 * Run the tests, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn() -> int {
    return hosted_faults.run(run_tests)
}
