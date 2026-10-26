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
 * "volume@snapshot". Connections arrive on its listener as Connects.
 */

Storage :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "storage", major_version = 1, lending = .Server}

// A partition, and which disk it's on, from 0, and which of that disk's it is.
Partition :: struct {
    disk : u32,
    index : u32,
    info : partitions.PartitionInfo,
}

// A volume of the container on a partition, by name, and the passphrase that unlocks it, empty for one that isn't encrypted.
VolumeAt :: struct {
    partition : u32,
    name : slop_os.Relative[u8],
    passphrase : slop_os.Relative[u8],
}

// A volume of the container on a partition, by name.
VolumeNamed :: struct {
    partition : u32,
    name : slop_os.Relative[u8],
}

// A volume's snapshot, both by name, and when it's taken, as the asker says.
SnapshotOf :: struct {
    partition : u32,
    volume : slop_os.Relative[u8],
    snapshot : slop_os.Relative[u8],
    now : u64,
}

// A volume's snapshot by its place among them, oldest first, from 0.
SnapshotIndexOf :: struct {
    partition : u32,
    volume : slop_os.Relative[u8],
    index : u64,
}

// A volume's quota: the most blocks it may have, its snapshots' included, 0 for none.
QuotaFor :: struct {
    partition : u32,
    volume : slop_os.Relative[u8],
    blocks : u64,
}

// A new volume named name, cloned from a volume's snapshot.
CloneOf :: struct {
    partition : u32,
    volume : slop_os.Relative[u8],
    snapshot : slop_os.Relative[u8],
    name : slop_os.Relative[u8],
    now : u64,
}

Request :: union {
    // The partition at an index, across every disk, from 0
    Describe(u32),
    // A new block connection narrowed to the partition at an index
    Open(u32),
    // The root of the FAT volume on the partition at an index, or of the system volume of the container there
    OpenFiles(u32),
    // The root of a container's volume, started the first time, unlocked if it's encrypted; after that, checked
    OpenVolume(VolumeAt),
    // A new key generation for an encrypted volume being served, sealing what's written from now on (decisions/0042)
    Rotate(VolumeNamed),
    // A snapshot of what a volume has committed, which a volume being served commits first; deleted; found by its
    // place; and a clone made from one (8e)
    TakeSnapshot(SnapshotOf),
    DeleteSnapshot(SnapshotOf),
    SnapshotAt(SnapshotIndexOf),
    Clone(CloneOf),
    // A volume's quota set, and how much it has, its quota, and what its container has free past its reserve (8e)
    SetQuota(QuotaFor),
    Usage(VolumeNamed),
    // Serve another client, on its end
    Connect(os.Channel[Storage]),
}

Response :: union {
    Described(Partition),
    Opened(os.Channel[block.Block]),
    OpenedFiles(os.Channel[dir.Dir]),
    // A snapshot's root, read only (8e)
    OpenedReadOnlyFiles(os.Channel[read_only_dir.ReadOnlyDir]),
    NoPartition,
    // The partition isn't one of a kind that holds files, or its FAT server couldn't be started
    NoFiles,
    // No volume of that name, or it isn't being served
    NoVolume,
    // An encrypted volume, asked for without a passphrase
    Locked,
    // The passphrase doesn't unlock the volume
    WrongKey,
    // The generation now sealing what the volume writes
    Rotated(u32),
    // The volume isn't encrypted
    NotEncrypted,
    // Its servers couldn't be started, or did something that failed
    Failed,
    Done,
    // A snapshot, its name, transaction and when it was taken
    Snapshot(container.SnapshotInfo),
    Used(slopfs.Usage),
    // Past the last snapshot
    NoMore,
    NoSnapshot,
    // A snapshot or volume with that name is there already
    AlreadyExists,
    // A snapshot a clone was made from, which stays while it's there
    InUse,
    Unsupported,
}

is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe(_) => true
        case Open(_) => true
        case OpenFiles(_) => true
        case OpenVolume(_) => true
        case Rotate(_) => false
        case TakeSnapshot(_) => false
        case DeleteSnapshot(_) => false
        case SnapshotAt(_) => true
        case Clone(_) => false
        case SetQuota(_) => true
        case Usage(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the storage manager listening on end, or null (as entropy.connect).
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
