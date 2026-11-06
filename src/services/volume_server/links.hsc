package volume_server

import os from "std"
import random from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import grant from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import slopfs from "../../slopfs"
import links from "../../protocols/links"
import volume_protocol from "../../protocols/volume"

/*
 * Stored links (roadmap 8f, design/security.md §8, slopfs/links.hsc), from both ends.
 *
 * Holding them: a path that runs through a link is opened by the volume the link leads into. The volume server asks
 * the storage manager (the links protocol), which asks that volume's server, and the connection it opens comes back
 * to the client. Meanwhile the client's connection waits, unread, and everything else is served: a volume server never
 * waits on the storage manager, which may be waiting on it. Link keeps a grant from another volume: its claim, from
 * the grant's server, goes to the storage manager to be issued to this volume, and the link is made with the number
 * it's issued under.
 *
 * Issuing them: Grant gives a connection speaking grant for what's at a path, which its holder hands to a directory in
 * another volume; its Claim gives a ticket, which the storage manager brings back with the volume to issue it to
 * (IssueTo). OpenIssued opens what an issued link leads to for the volume holding it, checked against what was issued;
 * what's opened is linked, as is everything opened from it, so none of it grants, links, or lists or revokes links,
 * and a link beneath it isn't followed. Links lists what was issued for what's beneath a directory, and Revoke deletes
 * an issued record, after which its link opens nothing.
 */

/** What's asked of the storage manager, in order: for the connection waiting on it, and a claim's, for an Issue. */
Asked :: struct {
    /** The slot of the client's connection waiting for the answer. */
    client : usize,
    /** For an Issue, the slot of the claim's connection; null for a Resolve. */
    claim : usize?,
}

/** Where a request's path leads: within this volume, or through a link, which has been asked about. */
Followed :: union {
    /** Within this volume, or nowhere, for the request's own code to open or report. */
    Local,
    /** Through a link: the storage manager has been asked, and the connection waits for its answer. */
    Asked,
    /** Through a link that couldn't be read or asked about: answered with this. */
    Failed(files.FileError),
}

/**
 * Follow a path from a client's connection: through a link, ask the storage manager for what it leads to, as opening
 * says, and leave the connection waiting for the answer.
 *
 * @param server The server, whose volume's tree is walked; through a link, the storage manager is asked on its links
 *     connection, and not waited for.
 * @param index The client's connection's slot; a linked connection follows no links.
 * @param directory The directory object the path is beneath.
 * @param path The path; "" stays Local.
 * @param opening How what it leads to is opened.
 * @return Local if the path stays in this volume or doesn't lead anywhere, for the request's own code, which reports
 *     that; Asked once the storage manager's asked; Failed if the link can't be read, or the storage manager can't be
 *     asked (Unavailable).
 */
follow :: fn(server: ptr[mut Server], index: usize, directory: u64, path: string, opening: links.Opening) -> Followed {
    if index >= server.connections.count || server.connections[index].linked || path.count == 0 {
        return .Local
    }
    walked := slopfs.Walked.{}
    match slopfs.walk(server.volume, directory, path) {
        case Ok(made) => walked = made
        case Error(error) => return .Local
    }
    if !walked.link {
        return .Local
    }
    link := slopfs.LinkRecord.{}
    match slopfs.link_of(server.volume, walked.object) {
        case Ok(found) => link = found
        case Error(error) => return .Failed(file_error(error))
    }
    out := os.Outgoing.{}
    request :: os.begin[links.Request](&out)
    request^ = .Resolve(links.Resolving.{container = link.container, volume = cast[u64](link.volume), number = cast[u64](link.number),
        path = os.append(&out, string_bytes(walked.rest)), opening = opening})
    if !ask_links(server, &out, Asked.{client = index, claim = null}) {
        return .Failed(.Unavailable)
    }
    return .Asked
}

/**
 * Send a request to the storage manager on the links connection, queue what it's for, and mark the client waiting.
 *
 * @param server The server, whose queue of what's asked grows by one, and whose client's connection is marked waiting,
 *     so it isn't read until answered.
 * @param out The request; its handles are moved out when it's sent.
 * @param asked What it's for, answered in the order asked.
 * @return Whether it was sent and queued; false if MAX_CONNECTIONS are waiting already, the storage manager's gone, or
 *     it couldn't be sent.
 */
ask_links :: fn(server: ptr[mut Server], out: ptr[mut os.Outgoing], asked: Asked) -> bool {
    if server.asked_count >= server.asked.count || cast[slop_os.Handle](server.links) == slop_os.NO_HANDLE {
        return false
    }
    if links.send_request(server.links, server.port, out) is_some {
        return false
    }
    slot :: (server.asked_first + server.asked_count) % server.asked.count
    server.asked[slot] = asked
    server.asked_count += 1
    if asked.client < server.connections.count {
        server.connections[asked.client].waiting = true
    }
    return true
}

/**
 * Give the storage manager's answers on the links connection, each to what's first in the queue; an answer with
 * nothing queued has its connection closed.
 *
 * If the storage manager's gone, everything queued is answered Unavailable and the links connection dropped.
 *
 * @param server The server, whose queue of what's asked is taken from; if the storage manager's gone, its links is set
 *     to NO_HANDLE.
 * @param index The links connection's slot.
 * @param into Where each answer is read into, reused.
 */
serve_links :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    loop {
        match links.receive_response(server.links, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                // The storage manager is gone: nothing asked will be answered
                loop {
                    if server.asked_count == 0 {
                        break
                    }
                    asked :: take_asked(server)
                    finish(server, asked, links.Response.Failed(.Unavailable))
                }
                drop(server, index)
                server.links = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
        }
        if server.asked_count == 0 {
            close_opened(os.message_of[links.Response](into)^)
            continue
        }
        asked :: take_asked(server)
        finish(server, asked, os.message_of[links.Response](into)^)
    }
}

/**
 * Take what's first in the queue of what's asked of the storage manager.
 *
 * @param server The server, whose queue isn't empty.
 * @return What was first.
 */
take_asked :: fn(server: ptr[mut Server]) -> Asked {
    asked :: server.asked[server.asked_first % server.asked.count]
    server.asked_first = (server.asked_first + 1) % server.asked.count
    server.asked_count -= 1
    return asked
}

/**
 * Give an answer to the connection that waited for it: for an Issue, the link made with the number issued, or why
 * not; for a Resolve, the connection opened, relayed.
 *
 * @param server The server: for an Issue, a link is made in its volume and the claim's connection dropped; for a
 *     Resolve, the client is answered.
 * @param asked What the answer is for.
 * @param answer The storage manager's answer, whose connection, if it has one the client can't take, is closed.
 */
finish :: fn(server: ptr[mut Server], asked: Asked, answer: links.Response) {
    match asked.claim {
        case Some(claim) => {
            error : files.FileError? = files.FileError.Unavailable
            match answer {
                case Issued(number) => error = made_link(server, claim, number)
                case Failed(refused) => error = refused
                case _ => close_opened(answer)
            }
            end_claim(server, claim, error)
        }
        case None => answer_opened(server, asked.client, answer)
    }
}

/**
 * Make the link a claim was for, now it's issued, at the claim's name in its target directory.
 *
 * @param server The server, whose volume is given the link, durable with its next commit; the claim's connection gives
 *     its grant's container, volume and write, and its target and name.
 * @param claim The claim's connection's slot.
 * @param number The number the link is issued under, by the volume it leads into.
 * @return Null once it's made; why not, otherwise, Unavailable for a slot past them.
 */
made_link :: fn(server: ptr[mut Server], claim: usize, number: u64) -> files.FileError? {
    if claim >= server.connections.count {
        return files.FileError.Unavailable
    }
    connection :: &server.connections[claim]
    record := slopfs.LinkRecord.{container = connection.claim.container, volume = cast[u64le](connection.claim.volume),
        number = cast[u64le](number), write = if connection.claim.write { cast[u8](1) } else { cast[u8](0) }}
    match slopfs.create_link(server.volume, connection.target, name_of(connection), &record) {
        case Ok(_) => return null
        case Error(error) => return file_error(error)
    }
}

/**
 * Relay what a link opened to the client that asked, as its own protocol has it, and let it be read again.
 *
 * @param server The server, whose added is set so the client is served again.
 * @param client The client's connection's slot; one gone, or not waiting, has the answer's connection closed.
 * @param answer The storage manager's answer: the connection opened, which moves to the client, or why not. One the
 *     client's protocol can't take, as a writable file for a read-only directory, is closed, and Unavailable answered.
 */
answer_opened :: fn(server: ptr[mut Server], client: usize, answer: links.Response) {
    if client >= server.connections.count || !server.connections[client].waiting {
        close_opened(answer)
        return void
    }
    connection :: &server.connections[client]
    connection.waiting = false
    server.added = true
    out := os.Outgoing.{}
    if connection.kind == .ReadOnlyDir {
        response :: os.begin[read_only_dir.Response](&out)
        response^ = .Failed(.Unavailable)
        match answer {
            case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
            case OpenedReadOnlyDirectory(made) => response^ = .OpenedDirectory(made)
            case Failed(error) => response^ = .Failed(error)
            case _ => close_opened(answer)
        }
        if read_only_dir.send_response(connection.end, server.port, &out) is_some {
            close_opened(answer)
        }
        return void
    }
    response :: os.begin[dir.Response](&out)
    response^ = .Failed(.Unavailable)
    match answer {
        case OpenedFile(made) => response^ = .OpenedFile(made)
        case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
        case OpenedDirectory(made) => response^ = .OpenedDirectory(made)
        case Failed(error) => response^ = .Failed(error)
        case _ => close_opened(answer)
    }
    if dir.send_response(connection.end, server.port, &out) is_some {
        close_opened(answer)
    }
}

/**
 * Close the connection an answer brought, if it brought one.
 *
 * @param answer An answer of the storage manager's; an Opened one's connection is closed, and anything else left.
 */
close_opened :: fn(answer: links.Response) {
    handle :: match answer {
        case OpenedFile(made) => cast[slop_os.Handle](made.end)
        case OpenedReadOnlyFile(made) => cast[slop_os.Handle](made.end)
        case OpenedDirectory(made) => cast[slop_os.Handle](made.end)
        case OpenedReadOnlyDirectory(made) => cast[slop_os.Handle](made.end)
        case _ => slop_os.NO_HANDLE
    }
    if handle != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(handle)
    }
}

// Making a link (Link)

/**
 * Begin keeping a grant as a link: claim it from its server, on a connection of the grant's own, and leave the
 * client's connection waiting until the link is made or refused.
 *
 * @param server The server, whose volume is read; a Claim connection is added and the Claim sent on it, not waited for,
 *     and the client's connection marked waiting.
 * @param index The client's connection's slot.
 * @param directory The directory object the path is beneath.
 * @param path The link's path; nothing may be there.
 * @param given The grant, which the server takes over: kept as the claim's connection, or closed if it can't be begun.
 * @return Null once it's begun, the answer to come; why not, now: AlreadyExists for something at path, NoSpace without
 *     a slot, Unavailable if the claim couldn't be sent, or why the path couldn't be followed.
 */
begin_link :: fn(server: ptr[mut Server], index: usize, directory: u64, path: string, given: os.Channel[grant.Grant]) -> files.FileError? {
    leaf := slopfs.Leaf.{}
    match slopfs.leaf_of(server.volume, directory, path) {
        case Ok(found) => leaf = found
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
            return file_error(error)
        }
    }
    match slopfs.lookup(server.volume, leaf.directory, leaf.name) {
        case Ok(existing) => {
            if existing is_some {
                _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
                return files.FileError.AlreadyExists
            }
        }
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
            return file_error(error)
        }
    }
    claim :: add(server, .Claim, given.end, 0, false, leaf.name) or_return files.FileError.NoSpace
    if claim >= server.connections.count || index >= server.connections.count {
        drop(server, claim)
        return files.FileError.NoSpace
    }
    server.connections[claim].target = leaf.directory
    server.connections[claim].client = index
    out := os.Outgoing.{}
    request :: os.begin[grant.Request](&out)
    request^ = .Claim
    if grant.send_request(given.end, server.port, &out) is_some {
        drop(server, claim)
        return files.FileError.Unavailable
    }
    server.connections[index].waiting = true
    return null
}

/**
 * Read a grant's answer to its Claim: take what it says to the storage manager to be issued, or refuse the link.
 *
 * @param server The server: the claim's connection is marked claimed and the storage manager asked to Issue, or the
 *     claim is ended and its client answered.
 * @param index The claim's connection's slot; one claimed already is left alone.
 * @param into Where the answer is read into.
 */
serve_claim :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count || server.connections[index].claimed {
        return void
    }
    end :: server.connections[index].end
    loop {
        match grant.receive_response(end, server.port, into, false) {
            case Received => break
            case Empty => return void
            case _ => {
                end_claim(server, index, files.FileError.NotFound)
                return void
            }
        }
    }
    match os.message_of[grant.Response](into)^ {
        case Claimed(claim) => {
            connection :: &server.connections[index]
            connection.claimed = true
            connection.claim = claim
            out := os.Outgoing.{}
            request :: os.begin[links.Request](&out)
            request^ = .Issue(claim)
            if !ask_links(server, &out, Asked.{client = connection.client, claim = index}) {
                end_claim(server, index, files.FileError.Unavailable)
            }
        }
        case Failed(error) => end_claim(server, index, error)
        case Unsupported => end_claim(server, index, files.FileError.Unavailable)
    }
}

/**
 * Be done with a claim: close the grant's connection, and answer its client, if it's still waiting.
 *
 * @param server The server, whose claim connection is dropped; its client, if it's waiting, is answered and let be read
 *     again.
 * @param claim The claim's connection's slot.
 * @param error Why the link wasn't made; null for Done.
 */
end_claim :: fn(server: ptr[mut Server], claim: usize, error: files.FileError?) {
    if claim >= server.connections.count {
        return void
    }
    client :: server.connections[claim].client
    drop(server, claim)
    if client >= server.connections.count || !server.connections[client].waiting {
        return void
    }
    connection :: &server.connections[client]
    connection.waiting = false
    server.added = true
    out := os.Outgoing.{}
    response :: os.begin[dir.Response](&out)
    response^ = .Done
    match error {
        case Some(failed) => response^ = .Failed(failed)
        case None => {}
    }
    _ = dir.send_response(connection.end, server.port, &out)
}

// Issuing them (Grant, and the storage manager's IssueTo and OpenIssued)

/**
 * Make a grant of what's at a path, a connection speaking grant, which its holder hands to a directory in another
 * volume to keep as a link.
 *
 * @param server The server, whose volume is read, not changed, and which a Grant connection is added to.
 * @param index The client's connection's slot; a linked one grants nothing (ReadOnly).
 * @param directory The directory object the path is beneath.
 * @param path The path, or "" for the directory itself.
 * @param write Whether the grant is to write as well as read.
 * @return Granted with the grant's other end, which the caller sends; Failed with ReadOnly, IsALink for a link,
 *     NoSpace without a slot, or why the path couldn't be followed.
 */
grant_of :: fn(server: ptr[mut Server], index: usize, directory: u64, path: string, write: bool) -> dir.Response {
    if index >= server.connections.count || server.connections[index].linked {
        return .Failed(.ReadOnly)
    }
    object := directory
    if path.count != 0 {
        match slopfs.resolve(server.volume, directory, path) {
            case Ok(found) => object = found
            case Error(error) => return .Failed(file_error(error))
        }
    }
    match slopfs.info(server.volume, object) {
        case Ok(info) => {
            if info.kind == .Link {
                return .Failed(.IsALink)
            }
        }
        case Error(error) => return .Failed(file_error(error))
    }
    made :: open_connection[grant.Grant](server, .Grant, object, !write, path) or_return .Failed(.NoSpace)
    return .Granted(made)
}

/**
 * Answer a grant's one Claim with a ticket, made here at random, for the storage manager to bring back with the
 * volume to issue it to; a second Claim is refused with AlreadyExists. A grant whose end fails is dropped.
 *
 * @param server The server, whose grant connection keeps the ticket and is marked claimed.
 * @param index The grant's connection's slot.
 * @param into Where each request is read into, reused.
 */
serve_grant :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match grant.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = grant.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        connection :: &server.connections[index]
        out := os.Outgoing.{}
        response :: os.begin[grant.Response](&out)
        if connection.claimed {
            response^ = .Failed(.AlreadyExists)
        }
        else {
            random.fill(connection.ticket)
            connection.claimed = true
            response^ = .Claimed(grant.Claim.{container = server.described.container, volume = server.described.id, ticket = connection.ticket,
                write = !connection.read_only})
        }
        _ = grant.send_response(end, server.port, &out)
    }
}

/**
 * Tell whether two tickets are the same, looking at every byte whatever they hold, so how long it takes says nothing.
 *
 * @param a One ticket, 32 bytes.
 * @param b The other ticket, 32 bytes.
 * @return Whether every byte is the same.
 */
same_ticket :: fn(a: u8[32], b: u8[32]) -> bool {
    differ : u8 = 0
    for byte, i in a {
        differ |= byte ~ b[i]
    }
    return differ == 0
}

/**
 * Issue the grant whose claim gave a ticket to the volume the storage manager says, durable before it's answered.
 *
 * A grant issues once: its ticket matches nothing after.
 *
 * @param server The server: the grant matched is marked issued, and the issued record added to its volume and
 *     committed, waited for.
 * @param to The ticket, and the volume to issue it to.
 * @return Issued with the link's number, once committed; Failed if the commit failed; Refused with NotFound for a
 *     ticket no unissued grant has, or why it couldn't be issued.
 */
issue_to :: fn(server: ptr[mut Server], to: volume_protocol.IssueTo) -> volume_protocol.Response {
    for &connection, i in server.connections {
        if i >= server.count || connection.kind != .Grant || !connection.claimed || connection.issued || !same_ticket(connection.ticket, to.ticket) {
            continue
        }
        connection.issued = true
        server.volume.now = slop_os.clock_monotonic() or_else 0
        match slopfs.issue(server.volume, connection.object, !connection.read_only, to.recipient_container, to.recipient) {
            case Ok(number) => {
                if !commit(server) {
                    return .Failed
                }
                return .Issued(number)
            }
            case Error(error) => return .Refused(file_error(error))
        }
    }
    return .Refused(.NotFound)
}

/**
 * Open what a link issued from here leads to, and a path beneath it, as the link's opening says, for the volume the
 * storage manager says holds the link. The connection is linked, as is everything opened from it.
 *
 * @param server The server, whose volume is read, changed only when a File or Directory opening makes or cuts
 *     something, and given the connection opened, linked.
 * @param asked The link's number, the volume holding it, and how it's opened.
 * @param path The path beneath what it leads to, at most files.PATH_BYTES bytes; "" for that itself.
 * @return The connection opened, a file's or a directory's, read only or not, which goes to the storage manager;
 *     Refused with Revoked if it wasn't issued to that volume, or isn't any more, ReadOnly to change what was issued
 *     only to read, AlreadyExists for a New file that is the link's target, NoSpace without a slot, or why the path
 *     couldn't be opened.
 */
open_issued :: fn(server: ptr[mut Server], asked: volume_protocol.OpenIssued, path: string) -> volume_protocol.Response {
    record := slopfs.IssuedRecord.{}
    match slopfs.issued(server.volume, asked.number) {
        case Ok(found) => record = found or_return .Refused(.Revoked)
        case Error(error) => return .Refused(file_error(error))
    }
    if record.recipient_container != asked.recipient_container || cast[u64](record.recipient_volume) != asked.recipient {
        return .Refused(.Revoked)
    }
    write :: record.write != 0
    kind :: asked.opening.kind
    if !write && (kind == .File || kind == .Directory) {
        return .Refused(.ReadOnly)
    }
    server.linking = true
    defer server.linking = false
    object :: cast[u64](record.object)
    volume :: server.volume
    if kind == .File || kind == .ReadOnlyFile {
        found := object
        if path.count != 0 {
            opened :: if kind == .File { open_file_object(volume, object, path, asked.opening.creation, no_schema()) } else { readable_file(volume, object, path) }
            match opened {
                case Ok(made) => found = made
                case Error(error) => return .Refused(file_error(error))
            }
        }
        else {
            match slopfs.file_record(volume, object) {
                case Ok(_) => {}
                case Error(error) => return .Refused(file_error(error))
            }
            if kind == .File && asked.opening.creation == .New {
                return .Refused(.AlreadyExists)
            }
            if kind == .File && asked.opening.creation == .Truncate {
                match slopfs.set_size(volume, object, 0) {
                    case Ok => {}
                    case Error(error) => return .Refused(file_error(error))
                }
            }
        }
        if kind == .File {
            made :: open_connection[file.File](server, .File, found, false, path) or_return .Refused(.NoSpace)
            return .OpenedFile(made)
        }
        made :: open_connection[read_only_file.ReadOnlyFile](server, .ReadOnlyFile, found, true, path) or_return .Refused(.NoSpace)
        return .OpenedReadOnlyFile(made)
    }
    found := object
    if path.count != 0 {
        match open_directory_object(volume, object, path, kind == .Directory && asked.opening.create) {
            case Ok(made) => found = made
            case Error(error) => return .Refused(file_error(error))
        }
    }
    else {
        match slopfs.directory_record(volume, object) {
            case Ok(_) => {}
            case Error(error) => return .Refused(file_error(error))
        }
    }
    if kind == .Directory {
        made :: open_connection[dir.Dir](server, .Dir, found, false, path) or_return .Refused(.NoSpace)
        return .OpenedDirectory(made)
    }
    made :: open_connection[read_only_dir.ReadOnlyDir](server, .ReadOnlyDir, found, true, path) or_return .Refused(.NoSpace)
    return .OpenedReadOnlyDirectory(made)
}

/**
 * Find a file to read.
 *
 * @param volume The volume, read only.
 * @param directory The directory object the path is beneath.
 * @param path The path from directory: names separated by single '/', none empty; links on the way aren't followed.
 * @return The object number of the file at path, checked to be a file; nothing is opened.
 * @error NotFound Nothing is at path.
 * @error IsADirectory It's a directory.
 * @error IsALink It's a link.
 * @error NotADirectory What's on the way to it isn't a directory.
 * @error DeviceError A block couldn't be read.
 * @error Corrupt The tree couldn't be read as one.
 */
readable_file :: fn(volume: ptr[mut slopfs.Volume], directory: u64, path: string) -> Result[u64, slopfs.Error] {
    object :: slopfs.resolve(volume, directory, path)?
    slopfs.file_record(volume, object)?
    return .Ok(object)
}

// Listing and revoking them (Links, Revoke)

/**
 * List the first link issued at or after a cursor for what's beneath a directory, with the path to it from there.
 *
 * Links for what's gone, or moved out from beneath the directory, or whose path can't be found, are passed over.
 *
 * @param server The server, whose volume's issued records are read, not changed.
 * @param index The client's connection's slot; a linked one lists nothing (ReadOnly).
 * @param directory The directory object whose links, for itself or what's beneath it, are listed, their paths from it.
 * @param cursor Where to start: 0, or what the last listing's next said.
 * @param out The answer being built, which the path is appended to.
 * @return Issued with its number, the path, whether it's to write, when it was made and the next cursor; End past the
 *     last; or Failed.
 */
issued_link :: fn(server: ptr[mut Server], index: usize, directory: u64, cursor: u64, out: ptr[mut os.Outgoing]) -> dir.Response {
    if index >= server.connections.count || server.connections[index].linked {
        return .Failed(.ReadOnly)
    }
    at := cursor
    loop {
        found := slopfs.Issued.{}
        match slopfs.next_issued(server.volume, at) {
            case Ok(next) => found = next or_return .End
            case Error(error) => return .Failed(file_error(error))
        }
        at = found.number + 1
        object :: cast[u64](found.record.object)
        // What's gone, or moved out from beneath the directory, isn't its to list
        if !(slopfs.is_beneath(server.volume, object, directory) or_else false) {
            continue
        }
        path : u8[files.PATH_BYTES]
        length :: if object == directory { cast[usize](0) } else { path_to(server, directory, object, path) }
        if object != directory && length == 0 {
            continue
        }
        shown :: if length < path.count { length } else { path.count }
        return .Issued(files.IssuedLink.{number = found.number, path = os.append(out, path[0..<shown]), write = found.record.write != 0,
            created = cast[u64](found.record.created), next = at})
    }
}

/**
 * Revoke a link issued for what's beneath a directory, by its number, so it opens nothing.
 *
 * @param server The server, whose volume's issued record is deleted, durable with its next commit.
 * @param index The client's connection's slot; a linked one revokes nothing (ReadOnly).
 * @param directory The directory object; one issued for what's gone may be revoked beneath the root.
 * @param number The number the link was issued with, as a listing of links gives it; one with no issued record, or
 *     not for what's beneath directory, is NotFound.
 * @return Done once it's revoked, durable with the volume's next commit; Failed with NotFound for no such link, or one
 *     not beneath the directory, or why it couldn't be revoked.
 */
revoked :: fn(server: ptr[mut Server], index: usize, directory: u64, number: u64) -> dir.Response {
    if index >= server.connections.count || server.connections[index].linked {
        return .Failed(.ReadOnly)
    }
    record := slopfs.IssuedRecord.{}
    match slopfs.issued(server.volume, number) {
        case Ok(found) => record = found or_return .Failed(.NotFound)
        case Error(error) => return .Failed(file_error(error))
    }
    // One for an object that's gone is anyone's beneath the root to revoke
    beneath :: slopfs.is_beneath(server.volume, cast[u64](record.object), directory) or_else directory == slopfs.ROOT_OBJECT
    if !beneath {
        return .Failed(.NotFound)
    }
    match slopfs.revoke(server.volume, number) {
        case Ok(_) => return .Done
        case Error(error) => return .Failed(file_error(error))
    }
}
