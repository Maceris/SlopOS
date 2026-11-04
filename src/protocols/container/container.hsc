package container

import os from "std"
import slop_os from "std/os"
import slopfs from "../../slopfs"
import block from "../block"

/*
 * A container service's protocol (roadmap 8d, decisions/0089), which the storage manager and volume servers speak. On
 * the listener's connections, OpenVolume gives a connection of its own for one volume; on that, the volume server
 * describes its volume, allocates and gives back its extents, opens block connections that read and write only them,
 * and commits its tree: written through those connections, every write finished, then its record sent here, which
 * the container makes durable with a checkpoint. A volume server never reaches another volume's blocks or the
 * container's own, and the container service never reads a volume's tree.
 *
 * Snapshots and clones (roadmap 8e): on the listener's connections, a volume's snapshots are taken, listed and
 * deleted, and a clone made from one, each durable at once. OpenVolume with "volume@snapshot" gives a snapshot's
 * connection, read only: its block connections read only what the snapshot holds.
 */

/**
 * The container protocol, for the channels between a container service and the storage manager, on its listener's
 * connections, and each volume server, on its volume's connection: they send the requests, and the container service
 * answers them.
 */
Container :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the container service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "container", major_version = 1, lending = .Server}

/** An extent a volume gives back: its first 4 KiB block, its length, and the transaction it was written in. */
Released :: struct {
    /** Its first block, in the container's 4 KiB blocks, as Allocated gave it. */
    first : u64,
    /** How many 4 KiB blocks it has, as it was allocated with. */
    blocks : u64,
    /**
     * The transaction it was written in: one a snapshot holds keeps the extent on the volume's dead list, and one
     * before a clone's origin is the origin's, so giving it back changes nothing.
     */
    birth : u64,
}

/**
 * An extent of so many 4 KiB blocks, for a file's bytes, which its volume's quota and the reserve hold back, or a
 * tree's nodes.
 */
Allocation :: struct {
    /** How many 4 KiB blocks, at least 1, and at most the container service allows at once, or it's NoSpace. */
    blocks : u64,
    /**
     * Whether it's for a file's bytes, which the volume's quota and the container's reserve hold back; false for nodes.
     */
    data : bool,
}

/** A volume's quota, by name: the most blocks it may have, its snapshots' included, 0 for none. */
QuotaOf :: struct {
    /** The volume's name, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The most 4 KiB blocks it may have, its snapshots' included; 0 for no quota. */
    blocks : u64,
}

/** A new key generation's record, and its number, the one after the volume's newest. */
AddedGeneration :: struct {
    /** Its number, the one after the volume's newest. */
    number : u32,
    /** Its record, sealed by the volume server, which the container service keeps but can't open. */
    record : slopfs.GenerationRecord,
}

/** A new volume (decisions/0141): its name, its cipher (slopfs.Cipher's value, 0 for none), and when it's made. */
VolumeCreation :: struct {
    /** Its name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** slopfs.Cipher's value: None (0), ChaCha20Poly1305 or Aes256Gcm; another is refused. */
    cipher : u8,
    /** When it's made, as the asker says, in nanoseconds since 1970. */
    now : u64,
}

/** A new sealed volume's key, wrapped, which its volume server made (decisions/0141): the index'th way, from 0. */
AddedWrap :: struct {
    /** Which way it's wrapped, from 0. */
    index : u64,
    /** The wrapped key's record, which the container service keeps but can't open. */
    record : slopfs.WrapRecord,
}

/**
 * A volume as it was last committed, the transaction its changes go into now, the container it's in, who wrote a
 * clone's older blocks, and whether it's a snapshot, served read only.
 */
Described :: struct {
    /** The volume's ID within its container. */
    id : u64,
    /** Its record as last committed; for a snapshot, with the snapshot's root and next object. */
    record : slopfs.VolumeRecord,
    /** The container's transaction its changes go into now. */
    transaction : u64,
    /** The container's ID, 16 bytes as the storage service names it. */
    container : u8[16],
    /** Who wrote a clone's older blocks, for its reads; empty for a volume that isn't a clone. */
    lineage : slopfs.Lineage,
    /** Whether it's a snapshot, served read only. */
    read_only : bool,
}

/** A volume's snapshot, both by name, and when it's taken, as its taker says. */
SnapshotNamed :: struct {
    /** The volume's name, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The snapshot's name, as UTF-8, unique among the volume's. */
    snapshot : slop_os.Relative[u8],
    /** When it's taken, as its taker says, in nanoseconds since 1970; ignored by DeleteSnapshot. */
    now : u64,
}

/** A volume's snapshot by its place among them, oldest first, from 0. */
SnapshotIndex :: struct {
    /** The volume's name, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The snapshot's place, oldest first, from 0. */
    index : u64,
}

/** A snapshot: its name, the transaction it holds, and when it was taken. */
SnapshotInfo :: struct {
    /** Its name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** The container's transaction it holds: the volume as committed then. */
    transaction : u64,
    /** When it was taken, as its taker said, in nanoseconds since 1970. */
    created : u64,
}

/** A new volume named name, cloned from a volume's snapshot. */
Cloning :: struct {
    /** The name of the volume the snapshot is of, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The snapshot's name, as UTF-8, which stays while the clone is there. */
    snapshot : slop_os.Relative[u8],
    /** The clone's name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** When it's made, as the asker says, in nanoseconds since 1970. */
    now : u64,
}

/** What the storage manager, or a volume server, asks a container service. */
Request :: union {
    /**
     * Ask for the volume with a name, or "volume@snapshot" for a snapshot's, read only, on a new connection of its
     * own, for the volume's requests below. Answered with OpenedVolume, NoVolume, NoSnapshot, NoSpace, or Failed.
     */
    OpenVolume(slop_os.Relative[u8]),
    /** On a volume's connection: ask what the volume is. Answered with Described, or NoVolume. */
    Describe,
    /**
     * On a volume's connection: allocate an extent for the volume, kept as its own. Answered with Allocated, or
     * NoSpace.
     */
    Allocate(Allocation),
    /**
     * On a volume's connection: give back an extent, kept on the volume's dead list if a snapshot holds it. Answered
     * with Done, or NotYours for one that isn't the volume's as it was allocated.
     */
    Release(Released),
    /**
     * On a volume's connection: ask for a block connection to the container's partition, its reads and writes
     * allowed only in this volume's extents. Answered with Blocks, or NoSpace.
     */
    OpenBlocks,
    /**
     * On a volume's connection: make the volume's record durable, its tree written through block connections whose
     * writes have all finished; only its root and next object are taken. Answered with Committed, NotYours for a
     * root that isn't in its extents, NoVolume, or Failed.
     */
    Commit(slopfs.VolumeRecord),
    /**
     * On a volume's connection: undo everything the volume changed since its last commit, its allocations free again,
     * what it gave back its own. Answered with Done, or Failed.
     */
    Abandon,
    /**
     * On a volume's connection: ask for an encrypted volume's key wrapped, the index'th way from 0 (8e), sealed, so
     * the container service never holds what opens it. Answered with Wrap, NoMore past the last, or Failed.
     */
    WrapAt(u64),
    /**
     * On a volume's connection: ask for a key generation's record, by its number from 1. Answered with Generation,
     * NoMore past the newest, or Failed.
     */
    GenerationAt(u32),
    /**
     * On a volume's connection: keep a new key generation's record with the volume, which its record then names;
     * durable with the next commit. Answered with Done, NotYours for a number that isn't the next, or Failed.
     */
    AddGeneration(AddedGeneration),
    /**
     * On a volume's connection: keep a new volume's wrapped key, which its volume server made; only while the volume
     * has no root (decisions/0141). Answered with Done, NotYours once it has one, or Failed.
     */
    AddWrap(AddedWrap),
    /**
     * On the listener's connections (8e): take a snapshot of what a volume's last commit left, durable at once.
     * Answered with Done, NoVolume, AlreadyExists, or Failed.
     */
    TakeSnapshot(SnapshotNamed),
    /**
     * On the listener's connections: delete a volume's snapshot, freeing what only it held, durable at once.
     * Answered with Done, NoVolume, NoSnapshot, InUse, or Failed.
     */
    DeleteSnapshot(SnapshotNamed),
    /**
     * On the listener's connections: ask for a volume's snapshot by its place. Answered with Snapshot, NoMore past
     * the last, NoVolume, or Failed.
     */
    SnapshotAt(SnapshotIndex),
    /**
     * On the listener's connections: make a new volume cloned from a volume's snapshot, durable at once. Answered
     * with Done, NoVolume, NoSnapshot, AlreadyExists, or Failed.
     */
    Clone(Cloning),
    /**
     * On the listener's connections (8e): set a volume's quota, durable at once. Answered with Done, NoVolume, or
     * Failed.
     */
    SetQuota(QuotaOf),
    /**
     * On the listener's connections: ask how much a volume has, by its name, its quota, and what the container has
     * free past its reserve. Answered with Used, or NoVolume.
     */
    Usage(slop_os.Relative[u8]),
    /**
     * On the listener's connections (decisions/0141): make a new volume, with nothing in it, durable at once; the
     * volume server that serves it first gives it its keys and root. Answered with Created and its ID,
     * AlreadyExists, or Failed.
     */
    CreateVolume(VolumeCreation),
    /** Have the service serve another client, on the end given, which moves to it. Answered with nothing. */
    Connect(os.Channel[Container]),
}

/** What a container service answers. */
Response :: union {
    /** OpenVolume's answer: the volume's connection, which moves to the asker. */
    OpenedVolume(os.Channel[Container]),
    /** Describe's answer. */
    Described(Described),
    /** Allocate's answer: the extent's first block, in the container's 4 KiB blocks. */
    Allocated(u64),
    /** The answer when what was asked is done, and durable where the request says so. */
    Done,
    /** Commit's answer: the transaction committed, and the one changes go into next. */
    Committed(u64),
    /** OpenBlocks' answer: the block connection, which moves to the volume server. */
    Blocks(os.Channel[block.Block]),
    /** WrapAt's answer: the wrapped key's record. */
    Wrap(slopfs.WrapRecord),
    /** GenerationAt's answer: the generation's record. */
    Generation(slopfs.GenerationRecord),
    /** SnapshotAt's answer: the snapshot. */
    Snapshot(SnapshotInfo),
    /** Usage's answer: the volume's blocks used and quota, and the container's blocks free past its reserve. */
    Used(slopfs.Usage),
    /** CreateVolume's answer: the new volume's ID within the container. */
    Created(u64),
    /** The answer past the last wrap record, the newest generation or the last snapshot. */
    NoMore,
    /** The answer when a snapshot or volume with that name is there already. */
    AlreadyExists,
    /** DeleteSnapshot's answer for a snapshot a clone was made from, which stays while the clone's there. */
    InUse,
    /** The answer when the volume has no snapshot of that name. */
    NoSnapshot,
    /** The answer when there's no volume of that name. */
    NoVolume,
    /** The answer when an extent, a channel, a slot or the driver couldn't be had. */
    NoSpace,
    /**
     * The answer when the container couldn't do what was asked; for a commit, a write failed, or it doesn't hold
     * together, and every later commit fails too.
     */
    Failed,
    /** The answer to a volume's request on a connection that isn't a volume's. */
    NotAVolume,
    /**
     * The answer to what the volume may not do: an extent that isn't its own given back, a root that isn't in its
     * extents committed, a generation or wrap out of turn, or anything but reading on a snapshot's connection.
     */
    NotYours,
    /** The answer to a request the service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for what changes something each time: allocating, giving back, committing, adding a generation, and
 *     making or deleting a snapshot, a clone or a volume; true for the rest, which are as good done again.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case OpenVolume(_) => true
        case Describe => true
        case Allocate(_) => false
        case Release(_) => false
        case OpenBlocks => true
        case Commit(_) => false
        case Abandon => true
        case WrapAt(_) => true
        case GenerationAt(_) => true
        case AddGeneration(_) => false
        case AddWrap(_) => true
        case TakeSnapshot(_) => false
        case DeleteSnapshot(_) => false
        case SnapshotAt(_) => true
        case Clone(_) => false
        case SetQuota(_) => true
        case Usage(_) => true
        case CreateVolume(_) => false
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to a container service: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the service takes the end when it next serves its listener, which the caller learns of only by
 * using it.
 *
 * @param end The service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Container]? {
    pair :: os.channel_for[Container](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Container].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Container].{end = pair.b}
    }
}
