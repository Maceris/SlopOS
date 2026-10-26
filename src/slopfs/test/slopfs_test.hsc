/*
 * slopfs's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number of
 * the first check that failed. Over a buffer standing in for a disk: the B+tree against a model, through splits,
 * merges and commits; and the container and its volumes (container_test.hsc).
 */
package slopfs_test

import runtime from "base"
import maps from "std"
import slopfs from ".."

// 32 MiB of 4 KiB blocks
BLOCKS : u64 : 8192

/*
 * A disk in memory. Recording, it keeps every write's blocks and bytes, and every flush, in order, for the crash-state
 * tester; read-only, it refuses writes.
 */
Disk :: struct {
    bytes : mut u8[],
    writes : u64,
    flushes : u64,
    recording : bool,
    read_only : bool,
    log : Recorded[..],
    logged : u8[..],
}

// A write the disk recorded, its bytes at `at` in its log, or a flush.
Recorded :: struct {
    flush : bool,
    block : u64,
    count : u64,
    at : usize,
}

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

flush_blocks :: fn(context: rawptr) -> bool {
    disk :: cast[ptr[mut Disk]](context)
    disk.flushes += 1
    if disk.recording {
        runtime.array_add(&disk.log, Recorded.{flush = true})
    }
    return true
}

// A bump allocator for the tree's own test, giving back nothing.
Bump :: struct {
    next : u64,
    released : u64,
}

bump_allocate :: fn(space: rawptr, blocks: u64, owner: u64) -> u64? {
    bump :: cast[ptr[mut Bump]](space)
    if bump.next + blocks > BLOCKS {
        return null
    }
    at :: bump.next
    bump.next += blocks
    return at
}

bump_release :: fn(space: rawptr, address: u64, blocks: u64, owner: u64, birth: u64) {
    bump :: cast[ptr[mut Bump]](space)
    bump.released += blocks
}

// xorshift64*, for keys that look random and come out the same every run.
Random :: struct {
    state : u64,
}

next_random :: fn(random: ptr[mut Random]) -> u64 {
    x := random.state
    x = x ~ (x >> 12)
    x = x ~ (x << 25)
    x = x ~ (x >> 27)
    random.state = x
    return x * 0x2545f4914f6cdd1d
}

main :: fn() -> int {
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
    failed = check_crashes()
    if failed != 0 {
        return failed
    }
    failed = check_fuzz()
    if failed != 0 {
        return failed
    }
    return 0
}

// A disk of BLOCKS zeroed blocks in memory, as a device; nothing of it is on the stack, so what holds it can be pointed to.
new_device :: fn() -> slopfs.Device? {
    return new_device_of(BLOCKS)
}

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

free_device :: fn(device: slopfs.Device) {
    disk :: cast[ptr[mut Disk]](device.context)
    runtime.free_array(disk.bytes)
    runtime.array_free(&disk.log)
    runtime.array_free(&disk.logged)
    runtime.free(disk)
}

/*
 * The tree against a model: a map from each key's object to the value written for it. Thousands of puts, replacing
 * and deleting at random, with values of many lengths, committed every so often, then every key read back, and the
 * records walked in order both ways.
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
            match slopfs.tree_put(&nodes, &tree, slopfs.key_of(object, .Object, 0), value[0..<length]) {
                case Ok => {}
                case Error(failure) => return 12
            }
            maps.map_put(&model, object, seed)
        }
        if step % 997 == 996 {
            match slopfs.tree_write(&nodes, &tree) {
                case Ok => {}
                case Error(failure) => return 13
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

// Whether a found key is before the one searched from, which tree_next never gives.
compare_after :: fn(found: slopfs.Key, from: slopfs.Key) -> bool {
    return slopfs.compare_keys(found, from) < 0
}

fill :: fn(into: mut u8[], seed: u64, length: usize) {
    for i in 0..<length {
        if i < into.count {
            into[i] = cast[u8]((seed >> cast[u64](i % 8 * 8)) + cast[u64](i))
        }
    }
}

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
