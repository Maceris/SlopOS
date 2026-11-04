package slopfs

/*
 * Stored links (roadmap 8f, design/security.md §8): authority that outlasts a reboot, kept by the storage service on
 * its holder's behalf. A link is an object in the recipient's volume, named like any other, whose record names the
 * volume it leads into, by its container and ID, and the number that volume issued it under. The volume it leads into
 * keeps what it issued: the object, whether it may be written, and which volume holds the link, so a link is only as
 * good as its issued record, and deleting that revokes it. A volume server follows a link through the storage
 * manager, which knows which volume asks; slopfs only keeps the records.
 */

/** A link's record, keyed (link, Link, 0): the volume it leads into and the number it was issued under there. */
LinkRecord :: struct #packed {
    /** The ID of the container the volume it leads into is in. */
    container : u8[16],
    /** The ID of the volume it leads into, in that container. */
    volume : u64le,
    /** The number that volume issued it under, from 1. */
    number : u64le,
    /** Whether it was issued to write, 1, or not, 0, as the volume it leads into said; only that volume's decides. */
    write : u8,
    /** Reserved; zero. */
    reserved : u8[7],
}

#assert size_of(LinkRecord) == 40

/**
 * A link a volume issued, keyed (0, Issued, number from 1).
 *
 * The issuing volume's ID is in it too, so a clone's copy of its origin's records, which no link names, issues nothing.
 */
IssuedRecord :: struct #packed {
    /** The ID of the volume that issued it; a record with another's is a clone's copy, and counts as not issued. */
    volume : u64le,
    /** The object it leads to, in the issuing volume. */
    object : u64le,
    /** When it was issued, as the issuer says (the volume's now). */
    created : u64le,
    /** The ID of the container of the volume holding the link. */
    recipient_container : u8[16],
    /** The ID of the volume holding the link. */
    recipient_volume : u64le,
    /** Whether it may be written through, 1, or only read, 0. */
    write : u8,
    /** Reserved; zero. */
    reserved : u8[7],
}

#assert size_of(IssuedRecord) == 56

/** The issued records' state, at number 0. */
IssuedState :: struct #packed {
    /** The number the next is issued under, from 1; numbers aren't reused, even once revoked. */
    next : u64le,
}

#assert size_of(IssuedState) == 8

/** What a volume issued, with its number. */
Issued :: struct {
    /** The number it was issued under, from 1. */
    number : u64,
    /** Its record. */
    record : IssuedRecord,
}

/**
 * Make a new link in a directory, leading where a record says.
 *
 * It's an object of kind Link, made as create makes one, its LinkRecord beside it; durable with the volume's next
 * commit. Nothing checks that the record names something issued: following it does.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory it goes in.
 * @param name The link's name in the directory, which has to hold (name_holds) and not be there already.
 * @param record Where it leads, copied.
 * @return The link's object ID.
 * @error NotFound The directory isn't there.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a link.
 * @error InvalidName The name can't name anything.
 * @error AlreadyExists The directory has something of the name.
 * @error TooLarge The directory's entries that hash alike have no room for the name.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
create_link :: fn(volume: ptr[mut Volume], directory: u64, name: string, record: ptr[LinkRecord]) -> Result[u64, Error] {
    object :: create(volume, directory, name, .Link)?
    tree_put(volume.nodes, &volume.tree, key_of(object, .Link, 0), view_of(cast[ptr[u8]](record), size_of(LinkRecord)))?
    return .Ok(object)
}

/**
 * Read where a link leads.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The link's object ID.
 * @return The link's record, a copy: where it leads, not checked against the volume it names.
 * @error NotFound The object isn't there, or isn't a link.
 * @error Corrupt The link has no LinkRecord, or one of the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
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

/** Where a path beneath a directory leads, as far as this volume goes. */
Walked :: struct {
    /** The object at the path's end, or the first link on the way. */
    object : u64,
    /** Whether object is a link the path goes on through, not its end. */
    link : bool,
    /**
     * The rest of the path after the link, a view into the path given, good as long as it is; "" if the link is its
     * last component, or there's no link.
     */
    rest : string,
}

/**
 * Walk a path beneath a directory as far as this volume goes: to its end, or to the first link on the way.
 *
 * Nothing is changed. A link at the path's end is returned as one, with rest "".
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory the path starts at.
 * @param path The path: names separated by single '/', none empty.
 * @return Where it leads.
 * @error InvalidName A component can't name anything: empty, ".", "..", or too long.
 * @error NotFound A component isn't there.
 * @error NotADirectory A component before the last is a file.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
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

/**
 * Issue a link to an object, recording what was issued under a new number, which the recipient's link names.
 *
 * It's durable with the volume's next commit.
 *
 * @param volume The volume issuing it, where the object is.
 * @param object The object it leads to.
 * @param write Whether it may be written through.
 * @param recipient_container The ID of the container of the volume that will hold the link.
 * @param recipient The ID of the volume that will hold the link.
 * @return The number it was issued under, from 1, each one new.
 * @error NotFound The object isn't there.
 * @error Corrupt The issued state says 0, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
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

/**
 * Look up what this volume issued under a number.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param number The number; 0 is never one.
 * @return The record; null if it's revoked, never was, or is a clone's copy of its origin's.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
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

/**
 * Find what this volume issued under the first number at or after another, for listing them in order.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param at The number to look from; 0 is taken as 1.
 * @return The issued record and its number; null after the last. A clone's copies of its origin's are skipped.
 * @error Corrupt A record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
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

/**
 * Revoke what was issued under a number, so every link naming it leads nowhere.
 *
 * It's durable with the volume's next commit. The links themselves stay, in their volumes.
 *
 * @param volume The volume that issued it.
 * @param number The number it was issued under; 0, or one never issued, revokes nothing.
 * @return True if something was issued under it and is revoked now; false if nothing was, or it already was.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
revoke :: fn(volume: ptr[mut Volume], number: u64) -> Result[bool, Error] {
    if (issued(volume, number)?) is_none {
        return .Ok(false)
    }
    tree_delete(volume.nodes, &volume.tree, key_of(0, .Issued, number))?
    volume.dirty = true
    return .Ok(true)
}
