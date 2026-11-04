/**
 * slopfs's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number of
 * the first check that failed. Over a buffer standing in for a disk: the B+tree against a model, through splits,
 * merges and commits; and the container and its volumes (container_test.hsc).
 */
package slopfs_test

import runtime from "base"
import maps from "std"
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
 * Run every check in order, stopping at the first that fails: the tree, the container and its volumes, volumes
 * apart, history, encryption, snapshots, quotas, links and volumes made at run time; then the crash-state tester, the
 * failed-write checks and the fuzzer, on a volume that isn't encrypted and on one that is.
 *
 * @return 0 if every check passed, or the number of the first that failed: each group's numbers are its own, as its
 *     function says.
 */
checks :: fn() -> int {
    failed := check_tree()
    if failed != 0 {
        return failed
    }
    failed = check_container()
    if failed != 0 {
        return failed
    }
    failed = check_apart()
    if failed != 0 {
        return failed
    }
    failed = check_history()
    if failed != 0 {
        return failed
    }
    failed = check_sealed()
    if failed != 0 {
        return failed
    }
    failed = check_snapshots()
    if failed != 0 {
        return failed
    }
    failed = check_quotas()
    if failed != 0 {
        return failed
    }
    failed = check_links()
    if failed != 0 {
        return failed
    }
    failed = check_made()
    if failed != 0 {
        return failed
    }
    // The crash-state tester and the fuzzer, on a volume that isn't encrypted and on one that is
    for sealed in bool.[false, true] {
        failed = check_crashes(sealed)
        if failed != 0 {
            return failed
        }
        failed = check_failed_writes(sealed)
        if failed != 0 {
            return failed
        }
        failed = check_fuzz(sealed)
        if failed != 0 {
            return failed
        }
    }
    return 0
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
 * Check the tree against a model: a map from each key's object to the value written for it. Thousands of puts,
 * replacing and deleting at random, with values of many lengths, committed every so often, then every key read back,
 * and the records walked in order both ways.
 *
 * @return 0 if every check passed, or the number of the first that failed, 1 to 25.
 */
check_tree :: fn() -> int {
    device :: new_device() or_return 1
    defer free_device(device)
    bump := runtime.new(Bump)
    defer runtime.free(bump)
    bump^ = Bump.{next = slopfs.FIRST_DATA}
    nodes := slopfs.Nodes.{device = device, transaction = 1, space = cast[rawptr](bump), allocate = bump_allocate,
        release = bump_release}
    tree := slopfs.Tree.{kind = .Volume, owner = 7}
    model : maps.HashMap[u64, u64, maps.hash_integer[u64]]
    defer maps.map_free(&model)
    random := Random.{state = 0x9e3779b97f4a7c15}
    value : u8[600]
    read_back : u8[600]
    KEYS :: 3000
    for step in 0..<20000 {
        object :: next_random(&random) % KEYS
        choice :: next_random(&random) % 4
        if choice == 0 {
            match slopfs.tree_delete(&nodes, &tree, slopfs.key_of(object, .Object, 0)) {
                case Ok(was_there) => {
                    if was_there != maps.map_has(&model, object) {
                        return 10
                    }
                }
                case Error(failure) => return 11
            }
            _ = maps.map_remove(&model, object)
        }
        else {
            seed :: next_random(&random)
            length :: cast[usize](seed % 600)
            fill(value, seed, length)
            if slopfs.tree_put(&nodes, &tree, slopfs.key_of(object, .Object, 0), value[0..<length]) is_error {
                return 12
            }
            maps.map_put(&model, object, seed)
        }
        if step % 997 == 996 {
            if slopfs.tree_write(&nodes, &tree) is_error {
                return 13
            }
            if nodes.dirty.count != 0 {
                return 14
            }
            nodes.transaction += 1
        }
    }
    // Grown past one leaf, so splits and merges were taken
    root :: slopfs.load(&nodes, &tree, &tree.root) or_return 24
    level :: slopfs.level_of(root)
    slopfs.done(root)
    if level == 0 {
        return 25
    }
    // Every key, read back from the tree as it's left, half of it written and half still dirty
    for object in 0..<cast[u64](KEYS) {
        match slopfs.tree_get(&nodes, &tree, slopfs.key_of(object, .Object, 0), read_back) {
            case Ok(found) => {
                match maps.map_get(&model, object) {
                    case Some(seed) => {
                        length :: cast[usize](seed % 600)
                        fill(value, seed, length)
                        if found != length || !same(read_back[0..<length], value[0..<length]) {
                            return 15
                        }
                    }
                    case None => {
                        if found is_some {
                            return 16
                        }
                    }
                }
            }
            case Error(failure) => return 17
        }
    }
    // In order, forward and back, as many as the model has
    count : u64 = 0
    at := slopfs.Key.{}
    walking := true
    loop {
        match slopfs.tree_next(&nodes, &tree, at, read_back) {
            case Ok(found) => {
                match found {
                    case Some(record) => {
                        if !maps.map_has(&model, record.key.object) || compare_after(record.key, at) {
                            return 18
                        }
                        count += 1
                        at = slopfs.Key.{object = record.key.object, kind = record.key.kind, offset = record.key.offset + 1}
                    }
                    case None => walking = false
                }
            }
            case Error(failure) => return 19
        }
    }
    while walking
    if count != cast[u64](model.count) {
        return 20
    }
    count = 0
    at = slopfs.Key.{object = 0xffffffffffffffff, kind = 0xff, offset = 0xffffffffffffffff}
    walking = true
    loop {
        match slopfs.tree_previous(&nodes, &tree, at, read_back) {
            case Ok(found) => {
                match found {
                    case Some(record) => {
                        if !maps.map_has(&model, record.key.object) {
                            return 21
                        }
                        count += 1
                        if record.key.object == 0 {
                            walking = false
                        }
                        else {
                            at = slopfs.Key.{object = record.key.object - 1, kind = 0xff, offset = 0xffffffffffffffff}
                        }
                    }
                    case None => walking = false
                }
            }
            case Error(failure) => return 22
        }
    }
    while walking
    if count != cast[u64](model.count) {
        return 23
    }
    return 0
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
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && b[i] != byte {
            return false
        }
    }
    return true
}

/**
 * Run the checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return 0 if every check passed, or the number of the first that failed.
 */
main :: fn() -> int {
    return hosted_faults.run(checks)
}
