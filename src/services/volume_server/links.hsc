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

// What's asked of the storage manager, in order: for the connection waiting on it, and a claim's, for an Issue.
Asked :: struct {
    client : usize,
    claim : usize?,
}

// Where a request's path leads: within this volume, or through a link, which has been asked about.
Followed :: union {
    Local,
    Asked,
    Failed(files.FileError),
}

/*
 * A path from a client's connection followed: through a link, what it leads to asked for, as opening says, and the
 * connection left waiting for the answer; Local if the path stays in this volume or doesn't lead anywhere, for the
 * request's own code, which reports that. A linked connection follows no links.
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
        path = os.append(&out, view_of(cast[ptr[u8]](walked.rest.data), walked.rest.count)), opening = opening})
    if !ask_links(server, &out, Asked.{client = index, claim = null}) {
        return .Failed(.Unavailable)
    }
    return .Asked
}

// A request to the storage manager sent, and what it's for queued: false if it can't be.
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

// The storage manager's answers, each to what's first in the queue.
serve_links :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    loop {
        match links.receive_response(server.links, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
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
            case _ => continue
        }
        if server.asked_count == 0 {
            close_opened(os.message_of[links.Response](into)^)
            continue
        }
        asked :: take_asked(server)
        finish(server, asked, os.message_of[links.Response](into)^)
    }
}

take_asked :: fn(server: ptr[mut Server]) -> Asked {
    asked :: server.asked[server.asked_first % server.asked.count]
    server.asked_first = (server.asked_first + 1) % server.asked.count
    server.asked_count -= 1
    return asked
}

// An answer given to the connection that waited for it: a link made with an Issue's, or a Resolve's relayed.
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

// The link a claim was for, made now it's issued under number.
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

// What a link opened, relayed to the client that asked, as its own protocol has it.
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

// The connection an answer brought, if it brought one, closed.
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

/*
 * A grant kept as a link at path beneath directory: claimed from its server, on a connection of the grant's own, and
 * the client's left waiting until the link is made or refused. An error now if it can't be begun.
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

// A grant's answer to its Claim: what it says taken to the storage manager to be issued, or the link refused.
serve_claim :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count || server.connections[index].claimed {
        return void
    }
    end :: server.connections[index].end
    loop {
        match grant.receive_response(end, server.port, into, false) {
            case Received => break
            case Empty => return void
            case Failed(error) => {
                end_claim(server, index, files.FileError.NotFound)
                return void
            }
            case _ => continue
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

// A claim done with: its client answered, Done or with error, and the grant's connection closed.
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

// A grant of what's at path beneath directory ("" for directory itself), to write as well if write.
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

// A grant's one Claim: a ticket for the storage manager to bring back, made here at random.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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

// Whether two tickets are the same, looking at every byte whatever they hold.
same_ticket :: fn(a: u8[32], b: u8[32]) -> bool {
    differ : u8 = 0
    for byte, i in a {
        differ |= byte ~ b[i]
    }
    return differ == 0
}

// The grant whose claim gave ticket issued to the volume the storage manager says, durable before it's answered.
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

/*
 * What a link issued from here leads to, and path beneath it, opened as opening says for the volume the storage manager
 * says holds the link: Revoked if it wasn't issued to that volume, or isn't any more; ReadOnly to change what was
 * issued only to read. The connection is linked.
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
            opened :: if kind == .File { open_file_object(volume, object, path, asked.opening.creation) } else { readable_file(volume, object, path) }
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

// The file at path beneath directory, to read: IsADirectory or IsALink if it's neither.
readable_file :: fn(volume: ptr[mut slopfs.Volume], directory: u64, path: string) -> Result[u64, slopfs.Error] {
    object :: slopfs.resolve(volume, directory, path)?
    slopfs.file_record(volume, object)?
    return .Ok(object)
}

// Listing and revoking them (Links, Revoke)

// The first link issued at or after cursor for what's beneath directory, with the path to it from there.
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

// A link issued for what's beneath directory revoked by its number.
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
