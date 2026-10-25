package slopfs_test

import runtime from "base"
import slopfs from ".."

/*
 * The container and its volumes: formatted, mounted, a volume made with directories and files of every size, renamed
 * and removed, committed and mounted again; space coming back once what held it is gone; and what's damaged on the
 * disk found, a checkpoint by falling back to the one before, a file's block by its seal. Checks from 100.
 */
check_container :: fn() -> int {
    device :: new_device() or_return 100
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](i + 1)
    }
    match slopfs.mount(device) {
        case Ok(container) => return 101
        case Error(error) => {
            if error != .NotSlopfs {
                return 102
            }
        }
    }
    match slopfs.format(device, id) {
        case Ok => {}
        case Error(error) => return 103
    }
    return check_volume(&device)
}

key_of_volume :: fn() -> u8[32] {
    key : u8[32]
    for i in 0..<key.count {
        key[i] = cast[u8](i * 7 + 3)
    }
    return key
}

check_volume :: fn(device: ptr[slopfs.Device]) -> int {
    container := slopfs.mount(device^) or_return 104
    // Only the space map and owners' nodes, two copies each, are used
    after_format :: slopfs.free_blocks(container)
    if after_format + 4 * slopfs.NODE_BLOCKS + slopfs.FIRST_DATA + 1 < BLOCKS || after_format >= BLOCKS - slopfs.FIRST_DATA - 1 {
        return 106
    }
    volume := slopfs.create_volume(container, "system", key_of_volume(), 1000) or_return 107
    if commit_failed(container) {
        return 108
    }
    baseline :: slopfs.free_blocks(container)

    // Directories and files: an empty one, one inline, one across chunks, one with a hole
    root :: slopfs.ROOT_OBJECT
    docs :: slopfs.create(volume, root, "docs", .Directory) or_return 110
    empty :: slopfs.create(volume, docs, "empty.txt", .File) or_return 111
    small :: slopfs.create(volume, docs, "small.txt", .File) or_return 112
    large :: slopfs.create(volume, root, "large.bin", .File) or_return 113
    holey :: slopfs.create(volume, root, "holey.bin", .File) or_return 114
    match slopfs.create(volume, docs, "small.txt", .File) {
        case Ok(again) => return 115
        case Error(error) => {
            if error != .AlreadyExists {
                return 116
            }
        }
    }
    for name in string.["", ".", "..", "a/b"] {
        match slopfs.create(volume, root, name, .File) {
            case Ok(made) => return 117
            case Error(error) => {
                if error != .InvalidName {
                    return 118
                }
            }
        }
    }
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes, 1)
    slopfs.write(volume, small, 0, data.bytes[0..<100]) or_return 120
    slopfs.write(volume, large, 0, data.bytes[0..<200000]) or_return 121
    slopfs.write(volume, holey, 300000, data.bytes[0..<10]) or_return 122
    failed := check_files(volume, data, small, large, holey, 130)
    if failed != 0 {
        return failed
    }
    if commit_failed(container) {
        return 140
    }

    // Mounted again, the same
    slopfs.unmount(container)
    container = slopfs.mount(device^) or_return 141
    volume = slopfs.open_volume(container, 1) or_return 142
    found_docs :: slopfs.lookup(volume, root, "docs") or_return 143
    if found_docs != docs {
        return 144
    }
    failed = check_files(volume, data, small, large, holey, 150)
    if failed != 0 {
        return failed
    }
    if count_entries(volume, root) != 3 || count_entries(volume, docs) != 2 {
        return 160
    }

    // Changed: overwritten in the middle, grown past inline, cut, renamed over, moved, and a directory refused beneath itself
    pattern(data.bytes, 2)
    slopfs.write(volume, large, 70000, data.bytes[0..<5]) or_return 161
    back := runtime.new(Data)
    defer runtime.free(back)
    read :: slopfs.read(volume, large, 69998, back.bytes[0..<9]) or_return 162
    pattern(data.bytes, 1)
    if read != 9 || back.bytes[0] != data.bytes[69998] || back.bytes[1] != data.bytes[69999] || back.bytes[7] != data.bytes[70005] {
        return 163
    }
    slopfs.write(volume, small, 3000, data.bytes[0..<10]) or_return 164
    if (slopfs.info(volume, small) or_return 165).size != 3010 {
        return 166
    }
    slopfs.set_size(volume, large, 1000) or_return 167
    slopfs.set_size(volume, large, 90000) or_return 168
    read_again :: slopfs.read(volume, large, 0, back.bytes[0..<90000]) or_return 169
    if read_again != 90000 || back.bytes[999] != data.bytes[999] || back.bytes[1000] != 0 || back.bytes[80000] != 0 {
        return 170
    }
    slopfs.rename(volume, docs, "small.txt", docs, "empty.txt") or_return 171
    gone :: slopfs.lookup(volume, docs, "small.txt") or_return 172
    replaced :: slopfs.lookup(volume, docs, "empty.txt") or_return 173
    if (gone is_some) || (replaced or_else 0) != small {
        return 174
    }
    slopfs.rename(volume, root, "holey.bin", docs, "holey.bin") or_return 175
    moved :: slopfs.info(volume, holey) or_return 176
    if moved.parent != docs {
        return 177
    }
    match slopfs.rename(volume, root, "docs", docs, "inside") {
        case Ok => return 178
        case Error(error) => {}
    }
    match slopfs.remove(volume, root, "docs") {
        case Ok => return 179
        case Error(error) => {
            if error != .DirectoryNotEmpty {
                return 180
            }
        }
    }
    if commit_failed(container) {
        return 181
    }
    slopfs.unmount(container)
    container = slopfs.mount(device^) or_return 182
    volume = slopfs.open_volume(container, 1) or_return 183
    read_after :: slopfs.read(volume, large, 0, back.bytes[0..<90000]) or_return 184
    if read_after != 90000 || back.bytes[999] != data.bytes[999] || back.bytes[1000] != 0 {
        return 185
    }
    if count_entries(volume, docs) != 2 || count_entries(volume, root) != 2 {
        return 186
    }

    // Everything removed, and committed twice, so what the first freed is free: the space is back
    slopfs.remove(volume, docs, "empty.txt") or_return 187
    slopfs.remove(volume, docs, "holey.bin") or_return 188
    slopfs.remove(volume, root, "docs") or_return 189
    slopfs.remove(volume, root, "large.bin") or_return 190
    if count_entries(volume, root) != 0 {
        return 191
    }
    if commit_failed(container) || commit_failed(container) {
        return 192
    }
    if slopfs.free_blocks(container) + 8 * slopfs.NODE_BLOCKS < baseline {
        return 193
    }
    slopfs.unmount(container)
    failed = check_damage(device, data)
    if failed != 0 {
        return failed
    }
    return check_model(device)
}

Data :: struct {
    bytes : u8[400000],
}

pattern :: fn(into: mut u8[], seed: u64) {
    state := seed * 0x9e3779b97f4a7c15 + 1
    for i in 0..<into.count {
        state = state * 6364136223846793005 + 1442695040888963407
        into[i] = cast[u8](state >> 56)
    }
}

commit_failed :: fn(container: ptr[mut slopfs.Container]) -> bool {
    match slopfs.commit(container) {
        case Ok => return false
        case Error(error) => return true
    }
}

count_entries :: fn(volume: ptr[mut slopfs.Volume], directory: u64) -> u64 {
    name : u8[255]
    count : u64 = 0
    cursor : u64 = 0
    for step in 0..<100000 {
        match slopfs.list(volume, directory, cursor, name) {
            case Ok(listed) => {
                entry :: listed or_return count
                count += 1
                cursor = entry.next
            }
            case Error(error) => return 9999
        }
    }
    return count
}

// The files as written: the empty one, 100 bytes, 200000 bytes, and 10 bytes after a 300000-byte hole.
check_files :: fn(volume: ptr[mut slopfs.Volume], data: ptr[mut Data], small: u64, large: u64, holey: u64, base: int) -> int {
    back := runtime.new(Data)
    defer runtime.free(back)
    small_read :: slopfs.read(volume, small, 0, back.bytes[0..<1000]) or_return base
    if small_read != 100 || !same(back.bytes[0..<100], data.bytes[0..<100]) {
        return base + 1
    }
    large_read :: slopfs.read(volume, large, 0, back.bytes[0..<400000]) or_return base + 2
    if large_read != 200000 || !same(back.bytes[0..<200000], data.bytes[0..<200000]) {
        return base + 3
    }
    // Across the chunks' edges
    middle :: slopfs.read(volume, large, 65530, back.bytes[0..<20]) or_return base + 4
    if middle != 20 || !same(back.bytes[0..<20], data.bytes[65530..<65550]) {
        return base + 5
    }
    holey_read :: slopfs.read(volume, holey, 0, back.bytes[0..<400000]) or_return base + 6
    if holey_read != 300010 || back.bytes[0] != 0 || back.bytes[299999] != 0 || !same(back.bytes[300000..<300010], data.bytes[0..<10]) {
        return base + 7
    }
    return 0
}

/*
 * Damage: the newest checkpoint broken, so mounting takes the one before and what it named; a file's block broken,
 * so reading it is Corrupt. Checks from 300.
 */
check_damage :: fn(device: ptr[slopfs.Device], data: ptr[mut Data]) -> int {
    container := slopfs.mount(device^) or_return 300
    volume := slopfs.open_volume(container, 1) or_return 301
    file :: slopfs.create(volume, slopfs.ROOT_OBJECT, "kept", .File) or_return 302
    pattern(data.bytes, 3)
    slopfs.write(volume, file, 0, data.bytes[0..<8192]) or_return 303
    if commit_failed(container) {
        return 304
    }
    kept_in :: slopfs.durable_transaction(container)
    slopfs.write(volume, file, 0, data.bytes[8192..<16384]) or_return 305
    if commit_failed(container) {
        return 306
    }
    newest :: slopfs.durable_transaction(container)
    slopfs.unmount(container)
    disk :: cast[ptr[mut Disk]](device.context)
    flip(disk, (1 + newest % slopfs.RING_BLOCKS) * slopfs.BLOCK_BYTES + 100)
    container = slopfs.mount(device^) or_return 307
    if slopfs.durable_transaction(container) != kept_in {
        return 308
    }
    volume = slopfs.open_volume(container, 1) or_return 309
    back := runtime.new(Data)
    defer runtime.free(back)
    read :: slopfs.read(volume, file, 0, back.bytes[0..<8192]) or_return 310
    if read != 8192 || !same(back.bytes[0..<8192], data.bytes[0..<8192]) {
        return 311
    }
    slopfs.unmount(container)
    // The file's first block, found by its bytes, broken
    at :: find(disk, data.bytes[0..<64]) or_return 312
    flip(disk, at + 10)
    container = slopfs.mount(device^) or_return 313
    volume = slopfs.open_volume(container, 1) or_return 314
    match slopfs.read(volume, file, 0, back.bytes[0..<8192]) {
        case Ok(count) => return 315
        case Error(error) => {
            if error != .Corrupt {
                return 316
            }
        }
    }
    slopfs.unmount(container)
    return 0
}

flip :: fn(disk: ptr[mut Disk], at: u64) {
    index :: cast[usize](at)
    if index < disk.bytes.count {
        disk.bytes[index] = disk.bytes[index] ~ 0x5a
    }
}

// Where bytes first are on the disk, at a block's start.
find :: fn(disk: ptr[mut Disk], bytes: u8[]) -> u64? {
    for block in 0..<BLOCKS {
        start :: cast[usize](block * slopfs.BLOCK_BYTES)
        end :: start + bytes.count
        if end <= disk.bytes.count && start <= end && same(disk.bytes[start..<end], bytes) {
            return block * slopfs.BLOCK_BYTES
        }
    }
    return null
}

FILES :: 6
MODEL_BYTES :: 300000

Models :: struct {
    files : Model[FILES],
}

// What each file should hold, and how long it is.
Model :: struct {
    bytes : u8[MODEL_BYTES],
    size : usize,
    object : u64,
}

/*
 * Files against a model: hundreds of writes at random places and lengths, sizes set up and down, reads compared,
 * committed every so often and mounted again; then a directory of many entries, listed whole. Checks from 400.
 */
check_model :: fn(device: ptr[slopfs.Device]) -> int {
    container := slopfs.mount(device^) or_return 400
    volume := slopfs.open_volume(container, 1) or_return 401
    models := runtime.new(Models)
    defer runtime.free(models)
    directory :: slopfs.create(volume, slopfs.ROOT_OBJECT, "model", .Directory) or_return 402
    for i in 0..<models.files.count {
        name : u8[1]
        name[0] = cast[u8]('a') + cast[u8](i)
        if i < models.files.count {
            models.files[i].object = slopfs.create(volume, directory, string_of(&name[0], 1), .File) or_return 403
            models.files[i].size = 0
        }
    }
    random := Random.{state = 0x1234567887654321}
    data := runtime.new(Data)
    defer runtime.free(data)
    back := runtime.new(Data)
    defer runtime.free(back)
    for step in 0..<600 {
        which :: cast[usize](next_random(&random) % FILES)
        if which >= models.files.count {
            continue
        }
        model :: &models.files[which]
        choice :: next_random(&random) % 10
        if choice < 6 {
            offset :: cast[usize](next_random(&random) % (MODEL_BYTES - 1))
            room :: MODEL_BYTES - offset
            length := cast[usize](next_random(&random) % 70000) + 1
            if length > room {
                length = room
            }
            if length > data.bytes.count {
                return 409
            }
            pattern(data.bytes[0..<length], next_random(&random))
            slopfs.write(volume, model.object, cast[u64](offset), data.bytes[0..<length]) or_return 404
            for i in 0..<length {
                j :: offset + i
                if j < model.bytes.count && i < data.bytes.count {
                    model.bytes[j] = data.bytes[i]
                }
            }
            for i in model.size..<offset {
                if i < model.bytes.count {
                    model.bytes[i] = 0
                }
            }
            if offset + length > model.size {
                model.size = offset + length
            }
        }
        else if choice < 8 {
            size :: cast[usize](next_random(&random) % MODEL_BYTES)
            slopfs.set_size(volume, model.object, cast[u64](size)) or_return 405
            for i in model.size..<size {
                if i < model.bytes.count {
                    model.bytes[i] = 0
                }
            }
            model.size = size
        }
        else {
            failed :: compare_file(volume, model, back, 410)
            if failed != 0 {
                return failed
            }
        }
        if step % 50 == 49 {
            if commit_failed(container) {
                return 406
            }
        }
        if step % 150 == 149 {
            slopfs.unmount(container)
            container = slopfs.mount(device^) or_return 407
            volume = slopfs.open_volume(container, 1) or_return 408
        }
    }
    for i in 0..<models.files.count {
        if i < models.files.count {
            failed :: compare_file(volume, &models.files[i], back, 420)
            if failed != 0 {
                return failed
            }
        }
    }
    // Many entries in one directory, so its records split across leaves, every one listed once
    many :: slopfs.create(volume, slopfs.ROOT_OBJECT, "many", .Directory) or_return 430
    text : u8[16]
    for i in 0..<1500 {
        length :: name_of_number(text, i)
        slopfs.create(volume, many, string_of(&text[0], length), .File) or_return 431
    }
    if commit_failed(container) {
        return 432
    }
    if count_entries(volume, many) != 1500 {
        return 433
    }
    for i in 0..<1500 {
        length :: name_of_number(text, i)
        found :: slopfs.lookup(volume, many, string_of(&text[0], length)) or_return 434
        if found is_none {
            return 435
        }
    }
    slopfs.unmount(container)
    return 0
}

// "file-" and a number's digits.
name_of_number :: fn(text: mut u8[], number: int) -> usize {
    prefix :: "file-"
    for character, i in prefix {
        if i < text.count {
            text[i] = cast[u8](character)
        }
    }
    digits : u8[8]
    count : usize = 0
    value := number
    loop #at_least_once {
        if count < digits.count {
            digits[count] = cast[u8]('0') + cast[u8](value % 10)
        }
        count += 1
        value = value / 10
    }
    while value > 0
    for i in 0..<count {
        at :: prefix.count + i
        from :: count - 1 - i
        if at < text.count && from < digits.count {
            text[at] = digits[from]
        }
    }
    return prefix.count + count
}

compare_file :: fn(volume: ptr[mut slopfs.Volume], model: ptr[mut Model], back: ptr[mut Data], base: int) -> int {
    info :: slopfs.info(volume, model.object) or_return base
    if info.size != cast[u64](model.size) {
        return base + 1
    }
    read :: slopfs.read(volume, model.object, 0, back.bytes[0..<MODEL_BYTES]) or_return base + 2
    if read != model.size || model.size > MODEL_BYTES || !same(back.bytes[0..<model.size], model.bytes[0..<model.size]) {
        return base + 3
    }
    return 0
}
