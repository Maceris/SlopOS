package slopfs

/*
 * Stored links (roadmap 8f, design/security.md §8): authority that outlasts a reboot, kept by the storage service on its
 * holder's behalf. A link is an object in the recipient's volume, named like any other, whose record names the volume
 * it leads into, by its container and ID, and the number that volume issued it under. The volume it leads into keeps
 * what it issued: the object, whether it may be written, and which volume holds the link, so a link is only as good as
 * its issued record, and deleting that revokes it. A volume server follows a link through the storage manager, which
 * knows which volume asks; slopfs only keeps the records.
 */

// A link's record, keyed (link, Link, 0): the volume it leads into and the number it was issued under there.
LinkRecord :: struct #packed {
    container : u8[16],
    volume : u64le,
    number : u64le,
    // Whether it was issued to write, as the volume it leads into said; only that volume's record decides
    write : u8,
    reserved : u8[7],
}

#assert size_of(LinkRecord) == 40

/*
 * A link a volume issued, keyed (0, Issued, number from 1): the object it leads to, whether it may be written, when it
 * was issued, as the issuer says, and the volume holding it. The issuing volume's ID is in it too, so a clone's copy of
 * its origin's records, which no link names, issues nothing.
 */
IssuedRecord :: struct #packed {
    volume : u64le,
    object : u64le,
    created : u64le,
    recipient_container : u8[16],
    recipient_volume : u64le,
    write : u8,
    reserved : u8[7],
}

#assert size_of(IssuedRecord) == 56

// The issued records' state, at number 0: the number the next is issued under.
IssuedState :: struct #packed {
    next : u64le,
}

#assert size_of(IssuedState) == 8

// What a volume issued, with its number.
Issued :: struct {
    number : u64,
    record : IssuedRecord,
}

// A new link named name in directory, leading where record says.
create_link :: fn(volume: ptr[mut Volume], directory: u64, name: string, record: ptr[LinkRecord]) -> Result[u64, Error] {
    object :: create(volume, directory, name, .Link)?
    tree_put(volume.nodes, &volume.tree, key_of(object, .Link, 0), view_of(cast[ptr[u8]](record), size_of(LinkRecord)))?
    return .Ok(object)
}

// Where a link leads, or NotFound if it isn't one.
link_of :: fn(volume: ptr[mut Volume], object: u64) -> Result[LinkRecord, Error] {
    record :: get_object(volume, object)?
    if kind_of_record(&record) != .Link {
        return .Error(.NotFound)
    }
    link := LinkRecord.{}
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(object, .Link, 0),
        view_of(cast[ptr[mut u8]](&link), size_of(LinkRecord)))? or_return .Error(.Corrupt)
    if bytes != size_of(LinkRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(link)
}

/*
 * Where a path beneath directory leads, as far as this volume goes: the object at its end, or the first link on the way
 * and the rest of the path after it, "" if the link is its last component.
 */
Walked :: struct {
    object : u64,
    link : bool,
    rest : string,
}

walk :: fn(volume: ptr[mut Volume], directory: u64, path: string) -> Result[Walked, Error] {
    at := directory
    start : usize = 0
    for i in 0..<path.count + 1 {
        if i < path.count && path[i] != '/' {
            continue
        }
        if start > i {
            return .Error(.InvalidName)
        }
        component :: path[start..<i]
        start = i + 1
        at = lookup(volume, at, component)? or_return .Error(.NotFound)
        record :: get_object(volume, at)?
        if kind_of_record(&record) == .Link {
            rest :: if i < path.count { path[i + 1..<path.count] } else { path[path.count..<path.count] }
            return .Ok(Walked.{object = at, link = true, rest = rest})
        }
    }
    return .Ok(Walked.{object = at, link = false, rest = path[path.count..<path.count]})
}

/*
 * A link issued for object, to the volume recipient in the container recipient_container, writable if write: its
 * number, which that volume's link names.
 */
issue :: fn(volume: ptr[mut Volume], object: u64, write: bool, recipient_container: u8[16], recipient: u64) -> Result[u64, Error] {
    get_object(volume, object)?
    state := IssuedState.{next = cast[u64le](cast[u64](1))}
    _ = tree_get(volume.nodes, &volume.tree, key_of(0, .Issued, 0), view_of(cast[ptr[mut u8]](&state), size_of(IssuedState)))?
    number :: cast[u64](state.next)
    if number == 0 {
        return .Error(.Corrupt)
    }
    record := IssuedRecord.{volume = cast[u64le](volume.id), object = cast[u64le](object), created = cast[u64le](volume.now),
        recipient_container = recipient_container, recipient_volume = cast[u64le](recipient), write = if write { cast[u8](1) } else { cast[u8](0) }}
    tree_put(volume.nodes, &volume.tree, key_of(0, .Issued, number), view_of(cast[ptr[u8]](&record), size_of(IssuedRecord)))?
    state.next = cast[u64le](number + 1)
    tree_put(volume.nodes, &volume.tree, key_of(0, .Issued, 0), view_of(cast[ptr[u8]](&state), size_of(IssuedState)))?
    volume.dirty = true
    return .Ok(number)
}

// What this volume issued under a number, or null if it's revoked, or never was.
issued :: fn(volume: ptr[mut Volume], number: u64) -> Result[IssuedRecord?, Error] {
    if number == 0 {
        return .Ok(null)
    }
    record := IssuedRecord.{}
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(0, .Issued, number),
        view_of(cast[ptr[mut u8]](&record), size_of(IssuedRecord)))? or_return .Ok(null)
    if bytes != size_of(IssuedRecord) {
        return .Error(.Corrupt)
    }
    if cast[u64](record.volume) != volume.id {
        return .Ok(null)
    }
    return .Ok(record)
}

// What this volume issued under the first number at or after at, or null after the last.
next_issued :: fn(volume: ptr[mut Volume], at: u64) -> Result[Issued?, Error] {
    number := if at == 0 { cast[u64](1) } else { at }
    loop {
        record := IssuedRecord.{}
        found :: tree_next(volume.nodes, &volume.tree, key_of(0, .Issued, number),
            view_of(cast[ptr[mut u8]](&record), size_of(IssuedRecord)))? or_return .Ok(null)
        if found.key.object != 0 || found.key.kind != cast[u8](RecordKind.Issued) {
            return .Ok(null)
        }
        if found.bytes != size_of(IssuedRecord) || found.key.offset < number {
            return .Error(.Corrupt)
        }
        if cast[u64](record.volume) == volume.id {
            return .Ok(Issued.{number = found.key.offset, record = record})
        }
        number = found.key.offset + 1
    }
}

// What was issued under a number revoked: whether there was one.
revoke :: fn(volume: ptr[mut Volume], number: u64) -> Result[bool, Error] {
    if (issued(volume, number)?) is_none {
        return .Ok(false)
    }
    tree_delete(volume.nodes, &volume.tree, key_of(0, .Issued, number))?
    volume.dirty = true
    return .Ok(true)
}
