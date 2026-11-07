package volume_server

import runtime from "base"
import os from "std"
import strings from "std"
import time from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import slopfs from "../../slopfs"
import container from "../../protocols/container"

/*
 * Snapshots through dir (decisions/0179): Snapshot takes one of the whole volume, Snapshots lists them, and
 * OpenSnapshot gives a directory as one has it, read only. The volume server asks the container service on its own
 * volume's connection, which reaches only this volume's snapshots, and serves a snapshot's tree itself, beside the
 * live one: its own connection to the container service and block connection, which read only what the snapshot
 * holds, and the live volume's keys, so an encrypted volume's past opens with nothing more. A directory's object is the
 * same in a snapshot as in its volume, so what's seen of the past is only what's beneath the connection asking.
 *
 * Connections to a snapshot are ReadOnlyDir and ReadOnlyFile ones whose past names it; they follow no links, list no
 * changes and select no sets. A snapshot's tree is let go of once nothing has it open.
 */

/** The most snapshots served at once; OpenSnapshot of one more, while each has something open, is NoSpace. */
MAX_PASTS :: 4
/** The start of the name of a snapshot Snapshot takes, before the nanoseconds it's taken at. */
ASKED_PREFIX :: "asked-"

/** A snapshot being served: its name, and its tree, as it was. */
Past :: struct {
    /** The snapshot's name, name_length bytes of it. */
    name : u8[slopfs.VOLUME_NAME_BYTES],
    /** How many of name's bytes are its. */
    name_length : usize,
    /** Its tree, on the heap, the slot's; null for a slot no snapshot has. */
    tree : ptr[mut PastTree]?,
}

/** A snapshot's tree: how its blocks are reached, its nodes, and its volume, as it was. */
PastTree :: struct {
    /** Its connection to the container service, which reads only what it holds, and its block connection. */
    reach : Reach,
    /** Its tree's nodes, which never change: nothing's written to a snapshot. */
    nodes : slopfs.Nodes,
    /** Its volume, as the snapshot holds it, its keys the live volume's, lent; null until it's attached. */
    volume : ptr[mut slopfs.Volume]?,
}

/**
 * Answer a dir connection's Snapshot, Snapshots or OpenSnapshot, asking the container service and waiting for it.
 *
 * @param server The server: Snapshot commits what's changed first; OpenSnapshot may serve a snapshot's tree and adds a
 *     connection to it.
 * @param index The client's connection's slot, a Dir.
 * @param request The request.
 * @param name OpenSnapshot's snapshot name, its bytes; empty for the others.
 * @param out The answer being built, which a snapshot's name is appended to.
 * @return The answer: Snapshotted, SnapshotListed, End, Narrowed, or Failed: ReadOnly on a connection reached through
 *     a stored link; AlreadyExists for a Snapshot taken twice in a nanosecond; DeviceError if what's changed couldn't
 *     be committed first; Unavailable if the container service didn't answer as it should; and OpenSnapshot's
 *     failures (open_snapshot).
 */
snapshot_answer :: fn(server: ptr[mut Server], index: usize, request: dir.Request, name: u8[], out: ptr[mut os.Outgoing]) -> dir.Response {
    if index >= server.connections.count || server.connections[index].linked {
        return .Failed(.ReadOnly)
    }
    directory :: server.connections[index].object
    match request {
        case Snapshot => return snapshot_taken_now(server, out)
        case Snapshots(cursor) => {
            asking := os.Outgoing.{}
            made :: os.begin[container.Request](&asking)
            made^ = .OwnSnapshotAt(cursor)
            into := os.Incoming.{}
            return match ask_built(&server.own, &asking, &into) {
                case Snapshot(info) => dir.Response.SnapshotListed(files.Snapshot.{name = os.append(out, os.items(&into, info.name)),
                    taken = info.created, next = cursor + 1})
                case NoMore => dir.Response.End
                case _ => dir.Response.Failed(.Unavailable)
            }
        }
        case OpenSnapshot(_) => return open_snapshot(server, directory, name)
        case _ => return .Unsupported
    }
}

/**
 * Take a snapshot of the volume now, named asked- and the wall clock's nanoseconds since 1970 (the monotonic clock's,
 * without a wall clock), what's changed committed first so it holds everything done before it was asked for.
 *
 * @param server The server, whose volume is committed if it's changed.
 * @param out The answer being built, which the snapshot's name is appended to.
 * @return Snapshotted, its next 0; Failed: DeviceError if the commit failed, AlreadyExists if the name's taken,
 *     NoSpace without memory for the name, Unavailable for any other answer of the container service's.
 */
snapshot_taken_now :: fn(server: ptr[mut Server], out: ptr[mut os.Outgoing]) -> dir.Response {
    if server.volume.dirty && !commit(server) {
        return .Failed(.DeviceError)
    }
    taken := cast[u64](0)
    match time.now() {
        case Ok(now) => taken = cast[u64](now.seconds) * 1000000000 + cast[u64](now.nanos)
        case Error(error) => {}
    }
    stamp :: if taken != 0 { taken } else { slop_os.clock_monotonic() or_else 0 }
    name :: strings.format("%1%2", ASKED_PREFIX, stamp) or_return .Failed(.NoSpace)
    defer strings.free_string(name)
    asking := os.Outgoing.{}
    made :: os.begin[container.Request](&asking)
    made^ = .TakeOwnSnapshot(container.OwnSnapshot.{snapshot = os.append(&asking, string_bytes(name)), now = taken})
    into := os.Incoming.{}
    return match ask_built(&server.own, &asking, &into) {
        case Done => dir.Response.Snapshotted(files.Snapshot.{name = os.append(out, string_bytes(name)), taken = taken, next = 0})
        case AlreadyExists => dir.Response.Failed(.AlreadyExists)
        case _ => dir.Response.Failed(.Unavailable)
    }
}

/**
 * Open a directory as a snapshot has it, read only: the snapshot's tree served if it isn't yet.
 *
 * @param server The server, whose pasts may gain the snapshot, and which gains a ReadOnlyDir connection to it.
 * @param directory The directory's object, the same in the snapshot.
 * @param name The snapshot's name.
 * @return Narrowed with the connection, which the client owns; Failed: InvalidPath for a name empty or too long,
 *     NotFound for no such snapshot or a directory not in it, NotADirectory for an object that isn't one there,
 *     NoSpace without a slot or memory, Unavailable if it couldn't be reached.
 */
open_snapshot :: fn(server: ptr[mut Server], directory: u64, name: u8[]) -> dir.Response {
    if name.count == 0 || name.count > slopfs.VOLUME_NAME_BYTES {
        return .Failed(.InvalidPath)
    }
    slot := cast[usize](0)
    match past_named(server, name) {
        case Ok(found) => slot = found
        case Error(error) => return .Failed(error)
    }
    volume :: volume_of_past(server, slot + 1)
    match slopfs.directory_record(volume, directory) {
        case Ok(_) => {}
        case Error(error) => {
            let_go_if_unused(server, slot)
            return .Failed(file_error(error))
        }
    }
    server.pasting = slot + 1
    defer server.pasting = 0
    match open_connection[read_only_dir.ReadOnlyDir](server, .ReadOnlyDir, directory, true, "") {
        case Some(made) => return .Narrowed(made)
        case None => {
            let_go_if_unused(server, slot)
            return .Failed(.NoSpace)
        }
    }
}

/**
 * Find a snapshot being served by its name, or serve it: its connection asked of the container service, its blocks
 * reached, and its tree attached with the live volume's keys.
 *
 * @param server The server, whose pasts gain it in a free slot, or one nothing has open, let go of first.
 * @param name The snapshot's name, 1 to slopfs.VOLUME_NAME_BYTES bytes.
 * @return Its slot in pasts; NotFound for no such snapshot, NoSpace if every slot has something open or there's no
 *     memory, Unavailable if the container service or its blocks couldn't be reached.
 */
past_named :: fn(server: ptr[mut Server], name: u8[]) -> Result[usize, files.FileError] {
    free := server.pasts.count
    for &past, i in server.pasts {
        match past.tree {
            case Some(_) => {
                if past.name_length == name.count && past.name_length <= past.name.count && same_name(past.name[0..<past.name_length], name) {
                    return .Ok(i)
                }
            }
            case None => if free == server.pasts.count {
                free = i
            }
        }
    }
    if free == server.pasts.count {
        for i in 0..<server.pasts.count {
            if !past_in_use(server, i) {
                let_go_of_past(server, i)
                free = i
                break
            }
        }
    }
    if free >= server.pasts.count {
        return .Error(.NoSpace)
    }
    asking := os.Outgoing.{}
    made :: os.begin[container.Request](&asking)
    made^ = .OpenOwnSnapshot(os.append(&asking, name))
    into := os.Incoming.{}
    end := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_built(&server.own, &asking, &into) {
        case OpenedVolume(opened) => end = opened.end
        case NoSnapshot => return .Error(.NotFound)
        case NoSpace => return .Error(.NoSpace)
        case _ => return .Error(.Unavailable)
    }
    tree_made, tree_error :: runtime.new_aligned(PastTree, align_of(PastTree))
    if tree_error != null {
        _ = slop_os.handle_close(cast[slop_os.Handle](end))
        return .Error(.NoSpace)
    }
    tree :: tree_made
    tree^ = PastTree.{}
    described := container.Described.{}
    match reach(&tree.reach, end) {
        case Ok(found) => described = found
        case Error(code) => {
            let_go_of_reach(&tree.reach)
            runtime.free(tree)
            return .Error(.Unavailable)
        }
    }
    device :: slopfs.Device.{context = cast[rawptr](&tree.reach), block_count = tree.reach.block_count, read = read_blocks,
        write = refuse_write, flush = no_flush}
    tree.nodes = slopfs.Nodes.{device = device, transaction = described.transaction, space = cast[rawptr](tree), allocate = refuse_allocate,
        release = refuse_release}
    match slopfs.attach_volume(&tree.nodes, device, described.id, described.record, null) {
        case Ok(attached) => {
            attached.tree.lineage = described.lineage
            // The live volume's keys, lent: a snapshot's blocks were sealed with its generations, which it holds
            attached.tree.keys = server.volume.tree.keys
            tree.volume = attached
        }
        case Error(error) => {
            let_go_of_reach(&tree.reach)
            runtime.free(tree)
            return .Error(.NoSpace)
        }
    }
    past :: &server.pasts[free]
    past.tree = tree
    past.name_length = name.count
    for byte, i in name {
        if i < past.name.count {
            past.name[i] = byte
        }
    }
    return .Ok(free)
}

/**
 * Tell whether two names have the same bytes.
 *
 * @param a One name's bytes.
 * @param b The other's; a different count is never the same.
 * @return Whether they're as long as each other, with the same bytes.
 */
same_name :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

/**
 * Tell whether any connection has a snapshot being served open.
 *
 * @param server The server, whose connections are read.
 * @param slot The snapshot's slot in pasts.
 * @return Whether a connection's past names it.
 */
past_in_use :: fn(server: ptr[Server], slot: usize) -> bool {
    for connection, i in server.connections {
        if i < server.count && connection.kind != .Free && connection.past == slot + 1 {
            return true
        }
    }
    return false
}

/**
 * Let go of a snapshot's tree if nothing has it open any more, as when its last connection's dropped.
 *
 * @param server The server, whose pasts may lose it.
 * @param slot The snapshot's slot in pasts; one past them, or free, is left.
 */
let_go_if_unused :: fn(server: ptr[mut Server], slot: usize) {
    if slot < server.pasts.count && !past_in_use(server, slot) {
        let_go_of_past(server, slot)
    }
}

/**
 * Let go of a snapshot's tree: its volume freed, its lent keys kept, and its connections to the container service
 * closed.
 *
 * @param server The server, whose pasts slot is left free.
 * @param slot The snapshot's slot in pasts; one past them, or free, is left.
 */
let_go_of_past :: fn(server: ptr[mut Server], slot: usize) {
    if slot >= server.pasts.count {
        return void
    }
    past :: &server.pasts[slot]
    tree :: past.tree or_return void
    match tree.volume {
        case Some(volume) => {
            // Its keys are the live volume's, which free_volume would free
            volume.tree.keys = null
            slopfs.free_volume(volume)
        }
        case None => {}
    }
    let_go_of_reach(&tree.reach)
    runtime.free(tree)
    past.tree = null
    past.name_length = 0
}

/**
 * Give the volume a connection's requests are served from: the live one, or the snapshot its past names.
 *
 * @param server The server.
 * @param past A connection's past: 0 for the live volume, a slot in pasts plus 1 for a snapshot's.
 * @return The volume; the live one for a past that names no snapshot being served.
 */
volume_of_past :: fn(server: ptr[mut Server], past: usize) -> ptr[mut slopfs.Volume] {
    if past == 0 || past > server.pasts.count {
        return server.volume
    }
    tree :: server.pasts[past - 1].tree or_return server.volume
    return tree.volume or_else server.volume
}

/**
 * Refuse to write, for a snapshot's Device: nothing's written to one.
 *
 * @param context Unused.
 * @param first Unused.
 * @param count Unused.
 * @param from Unused.
 * @return False.
 */
refuse_write :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    return false
}

/**
 * Refuse to allocate, for a snapshot's Nodes: nothing's written to one.
 *
 * @param context Unused.
 * @param blocks Unused.
 * @param owner Unused.
 * @param data Unused.
 * @return Null.
 */
refuse_allocate :: fn(context: rawptr, blocks: u64, owner: u64, data: bool) -> u64? {
    return null
}

/**
 * Give nothing back, for a snapshot's Nodes: nothing of one is ever let go of.
 *
 * @param context Unused.
 * @param address Unused.
 * @param blocks Unused.
 * @param owner Unused.
 * @param birth Unused.
 */
refuse_release :: fn(context: rawptr, address: u64, blocks: u64, owner: u64, birth: u64) {}
