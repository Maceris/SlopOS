package slopfs_test

import runtime from "base"
import slopfs from ".."

/*
 * Quotas and the reserve (roadmap 8e, slopfs/space.hsc): a volume's files written until its quota refuses more, and a
 * file deleted at its quota, which makes room; a snapshot's blocks kept charged to its volume, so deleting files under
 * it frees nothing until the snapshot goes; a container filled to its reserve, where deleting and committing still
 * work; and a volume's count of its blocks, which always matches the owners tree, across a mount. Checks from 1100.
 */

QUOTA_BLOCKS : u64 : 2048
CHUNK : usize : 65536

// The blocks the owners tree says a volume has.
owned_blocks :: fn(container: ptr[mut slopfs.Container], id: u64) -> u64 {
    value := slopfs.OwnerValue.{}
    at := slopfs.Key.{}
    total : u64 = 0
    loop {
        found :: match slopfs.tree_next(&container.nodes, &container.owners, at, view_of(cast[ptr[mut u8]](&value), size_of(slopfs.OwnerValue))) {
            case Ok(next) => next or_break
            case Error(error) => return 0xffffffffffffffff
        }
        if cast[u64](value.volume) == id {
            total += cast[u64](value.blocks)
        }
        at = slopfs.key_after(found.key) or_break
    }
    return total
}

// Whether the volume's count of its blocks is what the owners tree says, once committed.
counted :: fn(container: ptr[mut slopfs.Container], id: u64) -> bool {
    return slopfs.usage_of(container, id).used == owned_blocks(container, id)
}

// A new file of a chunk's bytes in the root, named by number: whether it was written.
write_file :: fn(volume: ptr[mut slopfs.Volume], number: int, data: ptr[mut Data]) -> bool {
    name : u8[16]
    length :: name_of_number(name, number)
    file :: match slopfs.create(volume, slopfs.ROOT_OBJECT, string_of(&name[0], length), .File) {
        case Ok(made) => made
        case Error(error) => return false
    }
    match slopfs.write(volume, file, 0, data.bytes[0..<CHUNK]) {
        case Ok => return true
        case Error(error) => {
            _ = slopfs.remove(volume, slopfs.ROOT_OBJECT, string_of(&name[0], length))
            return false
        }
    }
}

remove_file :: fn(volume: ptr[mut slopfs.Volume], number: int) -> bool {
    name : u8[16]
    length :: name_of_number(name, number)
    match slopfs.remove(volume, slopfs.ROOT_OBJECT, string_of(&name[0], length)) {
        case Ok => return true
        case Error(error) => return false
    }
}

check_quotas :: fn() -> int {
    device :: new_device_of(QUOTA_BLOCKS) or_return 1100
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0x90 + i)
    }
    slopfs.format(device, id) or_return 1101
    container := slopfs.mount(device) or_return 1102
    volume := slopfs.create_volume(container, "limited", key_of_volume(), 1) or_return 1103
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes[0..<CHUNK], 5)
    if commit_failed(container) {
        return 1104
    }
    volume_id :: volume.id
    // Five chunks' worth, and room for the tree
    quota :: 5 * 16 + 16
    slopfs.set_quota(container, volume_id, quota) or_return 1105
    if commit_failed(container) || !counted(container, volume_id) {
        return 1106
    }

    // Written until the quota refuses more
    written := 0
    for number in 0..<20 {
        if !write_file(volume, number, data) {
            break
        }
        written += 1
    }
    if written < 4 || written > 6 {
        return 1107
    }
    if commit_failed(container) || !counted(container, volume_id) || slopfs.usage_of(container, volume_id).used > quota + 16 {
        return 1108
    }
    // Deleting at the quota works, and makes room
    if !remove_file(volume, 0) || commit_failed(container) {
        return 1109
    }
    if !write_file(volume, 100, data) || commit_failed(container) || !counted(container, volume_id) {
        return 1110
    }

    // A snapshot keeps what it holds charged: deleting under it frees nothing, until it goes
    slopfs.take_snapshot(container, volume_id, name_bytes("held"), 2) or_return 1111
    if commit_failed(container) {
        return 1112
    }
    before :: slopfs.usage_of(container, volume_id).used
    for number in 1..<written {
        _ = remove_file(volume, number)
    }
    _ = remove_file(volume, 100)
    if commit_failed(container) || !counted(container, volume_id) {
        return 1113
    }
    if slopfs.usage_of(container, volume_id).used + 8 < before {
        return 1114
    }
    if write_file(volume, 200, data) {
        return 1115
    }
    slopfs.delete_snapshot(container, volume_id, name_bytes("held"), null) or_return 1116
    if commit_failed(container) || !counted(container, volume_id) {
        return 1117
    }
    if slopfs.usage_of(container, volume_id).used >= before || !write_file(volume, 200, data) || commit_failed(container) {
        return 1118
    }

    // Across a mount: the quota, and every count
    slopfs.unmount(container)
    container = slopfs.mount(device) or_return 1119
    if !counted(container, volume_id) || slopfs.usage_of(container, volume_id).quota != quota {
        return 1120
    }
    volume = slopfs.open_volume(container, volume_id) or_return 1121
    if write_file(volume, 300, data) && write_file(volume, 301, data) && write_file(volume, 302, data) && write_file(volume, 303, data)
        && write_file(volume, 304, data) && write_file(volume, 305, data) {
        return 1122
    }
    slopfs.unmount(container)
    return check_reserve()
}

// A container filled to its reserve, with no quota: deleting and committing still work.
check_reserve :: fn() -> int {
    blocks : u64 = 512
    device :: new_device_of(blocks) or_return 1130
    defer free_device(device)
    id : u8[16]
    for i in 0..<id.count {
        id[i] = cast[u8](0xa0 + i)
    }
    slopfs.format(device, id) or_return 1131
    container := slopfs.mount(device) or_return 1132
    volume := slopfs.create_volume(container, "full", key_of_volume(), 1) or_return 1133
    data := runtime.new(Data)
    defer runtime.free(data)
    pattern(data.bytes[0..<CHUNK], 6)
    written := 0
    for number in 0..<100 {
        if !write_file(volume, number, data) {
            break
        }
        written += 1
        if number % 4 == 3 && commit_failed(container) {
            return 1134
        }
    }
    if written == 0 || commit_failed(container) {
        return 1135
    }
    // Full to the reserve, which only a file's bytes keep out of
    reserve :: slopfs.reserve_of(blocks)
    if slopfs.free_blocks(container) + 16 < reserve || slopfs.free_blocks(container) > reserve + 16 + 2 * slopfs.NODE_BLOCKS * 4 {
        return 1136
    }
    full :: slopfs.free_blocks(container)
    for number in 0..<written {
        if !remove_file(volume, number) {
            return 1137
        }
    }
    if commit_failed(container) || commit_failed(container) || slopfs.free_blocks(container) <= full {
        return 1138
    }
    slopfs.unmount(container)
    return 0
}
