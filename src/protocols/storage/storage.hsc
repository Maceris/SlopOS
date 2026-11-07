package storage

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import block from "../block"
import partitions from "../partitions"
import container from "../container"
import slopfs from "../../slopfs"

/*
 * The storage manager's protocol (roadmap 8a, decisions/0086): every partition of every disk it holds, by one index
 * from 0, and block connections narrowed to one, from that disk's partition server, or the files of a FAT partition
 * (an EFI system partition or a basic data one), as a dir connection to its root, from a FAT server for it; a SlopOS
 * container's files are its system volume's (decisions/0089). Any of a container's volumes is opened by name, an
 * encrypted one with its passphrase, which its volume server, and nothing else, unwraps its keys with (roadmap 8e).
 * Its snapshots are taken, listed and deleted here, each a clone made from, and opened read only as
 * "volume@snapshot". A volume is made at run time (decisions/0141): a sealed one by the volume server started for it,
 * which makes and wraps its key, so the container service is given only the wrapped records. Connections arrive on
 * its listener as Connects.
 */

/**
 * The storage protocol, for the channels between the storage manager and its clients, and its listener: the clients
 * send the requests, and the storage manager answers them.
 */
Storage :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the storage manager, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "storage", major_version = 1, lending = .Server}

/** A partition, and which disk it's on, from 0, and which of that disk's it is. */
Partition :: struct {
    /** The disk it's on, from 0, in the order the storage manager found them. */
    disk : u32,
    /** Which of that disk's partitions it is, from 0, as its partition server numbers them. */
    index : u32,
    /** The partition, as the disk's GPT describes it. */
    info : partitions.PartitionInfo,
}

/**
 * A volume of the container on a partition, by name, and the passphrase that unlocks it, empty for one that isn't
 * encrypted.
 */
VolumeAt :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The volume's name, as UTF-8, at most 64 bytes; "volume@snapshot" opens a snapshot of it, read only. */
    name : slop_os.Relative[u8],
    /**
     * The passphrase's bytes, passed to the volume's server, which unwraps its keys with them; empty for a volume
     * that isn't encrypted, and Locked for one that is.
     */
    passphrase : slop_os.Relative[u8],
}

/**
 * A new volume of the container on a partition, sealed with cipher (slopfs.Cipher) by a passphrase, or neither, and
 * when it's made, as the asker says.
 */
NewVolume :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The volume's name, as UTF-8, 1 to 64 bytes, and not a snapshot's ("volume@snapshot"). */
    name : slop_os.Relative[u8],
    /** The passphrase's bytes, which its key is wrapped with: given exactly when cipher seals it, or it's Failed. */
    passphrase : slop_os.Relative[u8],
    /** A slopfs.Cipher's value, the cipher that seals it; 0 (None) for a volume that isn't sealed. */
    cipher : u8,
    /** When it's made, as the asker says, in nanoseconds since 1970; written into its record, 0 if unknown. */
    now : u64,
}

/** A volume of the container on a partition, by name. */
VolumeNamed :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The volume's name, as UTF-8. */
    name : slop_os.Relative[u8],
}

/** A volume's snapshot, both by name, and when it's taken, as the asker says. */
SnapshotOf :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The volume's name, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The snapshot's name, as UTF-8, unique among the volume's. */
    snapshot : slop_os.Relative[u8],
    /** When it's taken, as the asker says, in nanoseconds since 1970; ignored by DeleteSnapshot. */
    now : u64,
}

/** A volume's snapshot by its place among them, oldest first, from 0. */
SnapshotIndexOf :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The volume's name, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The snapshot's place among the volume's, oldest first, from 0. */
    index : u64,
}

/** A volume's quota: the most blocks it may have, its snapshots' included, 0 for none. */
QuotaFor :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The volume's name, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The most blocks the volume may have, its snapshots' included, in the container's blocks; 0 for no quota. */
    blocks : u64,
}

/** A new volume named name, cloned from a volume's snapshot. */
CloneOf :: struct {
    /** The partition the container is on, by its index across every disk, as Describe numbers them. */
    partition : u32,
    /** The name of the volume the snapshot is of, as UTF-8. */
    volume : slop_os.Relative[u8],
    /** The snapshot's name, as UTF-8, which the clone starts as; it stays while the clone is there. */
    snapshot : slop_os.Relative[u8],
    /** The new volume's name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** When it's made, as the asker says, in nanoseconds since 1970; written into its record, 0 if unknown. */
    now : u64,
}

/** What a client asks the storage manager. */
Request :: union {
    /** Ask for the partition at an index, across every disk, from 0. Answered with Described, or NoPartition. */
    Describe(u32),
    /**
     * Ask for a new block connection narrowed to the partition at an index, from that disk's partition server.
     * Answered with Opened, or NoPartition when there's none there or it couldn't be opened.
     */
    Open(u32),
    /**
     * Ask for the root of the FAT volume on the partition at an index, an EFI system partition or a basic data one,
     * from a FAT server for it, started the first time; or of the system volume of the container there
     * (decisions/0089). Answered with OpenedFiles, NoFiles, or NoPartition.
     */
    OpenFiles(u32),
    /**
     * Ask for the root of a container's volume: its volume server started the first time, unlocked if it's
     * encrypted; after that, the passphrase checked. Answered with OpenedFiles, OpenedReadOnlyFiles for a snapshot,
     * NoVolume, Locked, WrongKey, Failed, or NoPartition for a partition that isn't a container.
     */
    OpenVolume(VolumeAt),
    /**
     * Make a new volume, with nothing in it but its root directory, and open it as OpenVolume opens one
     * (decisions/0141); a sealed one has its key made and wrapped by the volume server started for it. Answered as
     * OpenVolume is, AlreadyExists for a name that's taken, or Failed for a name empty, too long or a snapshot's, or a
     * passphrase given without a cipher, or the other way round.
     */
    CreateVolume(NewVolume),
    /**
     * Start a new key generation for an encrypted volume being served, sealing what's written from now on
     * (decisions/0042). Answered with Rotated, NotEncrypted, NoVolume for one not being served, or Failed.
     */
    Rotate(VolumeNamed),
    /**
     * Take a snapshot of what a volume has committed, which a volume being served commits first (roadmap 8e).
     * Answered with Done, NoVolume, AlreadyExists, or Failed.
     */
    TakeSnapshot(SnapshotOf),
    /** Delete a volume's snapshot. Answered with Done, NoVolume, NoSnapshot, InUse, or Failed. */
    DeleteSnapshot(SnapshotOf),
    /**
     * Ask for a volume's snapshot by its place among them, to list them. Answered with Snapshot, NoMore past the
     * last, NoVolume, or Failed.
     */
    SnapshotAt(SnapshotIndexOf),
    /**
     * Make a new volume, a clone of a volume's snapshot (roadmap 8e). Answered with Done, NoVolume, NoSnapshot,
     * AlreadyExists, or Failed.
     */
    Clone(CloneOf),
    /** Set a volume's quota (roadmap 8e). Answered with Done, NoVolume, or Failed. */
    SetQuota(QuotaFor),
    /**
     * Ask how much a volume has, its quota, and what its container has free past its reserve (roadmap 8e). Answered
     * with Used, NoVolume, or Failed.
     */
    Usage(VolumeNamed),
    /**
     * Have the storage manager serve another client, on the end given, which moves to it; it's closed if the storage
     * manager already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Storage]),
    /**
     * For a test only, refused (Unsupported) unless the storage manager was started with test_storage_restart on the
     * kernel's command line: kill the partition server of the disk at an index, and answer once it's started again
     * (decisions/0098). Answered with Done, or NoPartition when it couldn't be.
     */
    TestRestart(u32),
    /**
     * Have every writable volume being served commit what's changed, as before the system shuts down (decisions/0180).
     * Answered with Done once each has, or Failed if any couldn't.
     */
    CommitAll,
}

/** What the storage manager answers. */
Response :: union {
    /** Describe's answer: the partition. */
    Described(Partition),
    /** Open's answer: the client's end of the new block connection, which moves to the client. */
    Opened(os.Channel[block.Block]),
    /** OpenFiles', OpenVolume's or CreateVolume's answer: a connection to the root, which moves to the client. */
    OpenedFiles(os.Channel[dir.Dir]),
    /**
     * OpenVolume's answer for a snapshot (roadmap 8e): a connection to its root, read only, which moves to the
     * client.
     */
    OpenedReadOnlyFiles(os.Channel[read_only_dir.ReadOnlyDir]),
    /** The answer when there's no partition at the index given, or none of the kind asked about there. */
    NoPartition,
    /**
     * OpenFiles' answer when the partition isn't one of a kind that holds files, or its FAT server couldn't be
     * started.
     */
    NoFiles,
    /** The answer when there's no volume of that name, or, for Rotate, it isn't being served. */
    NoVolume,
    /** OpenVolume's answer for an encrypted volume asked for without a passphrase. */
    Locked,
    /** OpenVolume's answer when the passphrase doesn't unlock the volume. */
    WrongKey,
    /** Rotate's answer: the generation now sealing what the volume writes. */
    Rotated(u32),
    /** Rotate's answer when the volume isn't encrypted. */
    NotEncrypted,
    /** The answer when its servers couldn't be started, or asked, or did something that failed. */
    Failed,
    /** The answer when what was asked is done. */
    Done,
    /** SnapshotAt's answer: a snapshot, its name, transaction and when it was taken. */
    Snapshot(container.SnapshotInfo),
    /** Usage's answer: the volume's blocks used and quota, and the container's blocks free past its reserve. */
    Used(slopfs.Usage),
    /** SnapshotAt's answer past the last snapshot. */
    NoMore,
    /** The answer when the volume has no snapshot of that name. */
    NoSnapshot,
    /** The answer when a snapshot or volume with that name is there already. */
    AlreadyExists,
    /** DeleteSnapshot's answer for a snapshot a clone was made from, which stays while the clone's there. */
    InUse,
    /**
     * The answer to a request the storage manager doesn't know, as from a newer client, and to TestRestart outside a
     * test; every protocol has it.
     */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for what only asks or opens, and SetQuota, which sets the same quota again; false for what makes or
 *     deletes something, or rotates or restarts, which would do it again.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe(_) => true
        case Open(_) => true
        case OpenFiles(_) => true
        case OpenVolume(_) => true
        case CreateVolume(_) => false
        case Rotate(_) => false
        case TakeSnapshot(_) => false
        case DeleteSnapshot(_) => false
        case SnapshotAt(_) => true
        case Clone(_) => false
        case SetQuota(_) => true
        case Usage(_) => true
        case Connect(_) => true
        case TestRestart(_) => false
        case CommitAll => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the storage manager: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the storage manager takes the end when it next serves its listener, or closes it when it's full,
 * which the caller learns of as its end's peer gone.
 *
 * @param end The storage manager's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Storage]? {
    pair :: os.channel_for[Storage](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Storage].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Storage].{end = pair.b}
    }
}
