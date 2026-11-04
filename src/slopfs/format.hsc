/**
 * slopfs, SlopOS's own filesystem (roadmap 8c, design/storage.md §3, decisions/0085, 0088): a container of volumes on
 * a partition, every structure in it a copy-on-write B+tree reached from a checkpoint through block pointers that
 * carry each block's BLAKE3-256 seal, so what's read is checked all the way down. It's a portable package: built and
 * tested hosted over a buffer standing in for a disk, and served on SlopOS from 8d.
 *
 * This file is what's on the disk. A container is 4 KiB blocks: a superblock in the first and the last, naming it;
 * a ring of checkpoints after the first, one written per commit; and everything else, allocated in extents. The
 * container's trees are its space map (free extents, and those freed in the last commit, reusable once it's durable),
 * the owner of every allocated extent, and its volumes; each volume is one more tree, of objects, directory entries
 * and file extents. Tree nodes are 16 KiB, each with a header saying which tree, owner and transaction it's from and
 * where it was written, so a misdirected write reads back as one; data is checked by its seal alone.
 */
package slopfs

/** The size of a container's block, in bytes: the unit every address and extent length counts in. */
BLOCK_BYTES : u64 : 4096
/** The size of a tree node, in bytes. */
NODE_BYTES : u64 : 16384
/** The blocks a tree node takes: NODE_BYTES / BLOCK_BYTES. */
NODE_BLOCKS : u64 : 4
/**
 * The format's version, in the superblock and every checkpoint; a container of another isn't mounted. 3 from 8e:
 * owners with their extents' births, clones, snapshots and dead lists, quotas.
 */
FORMAT_VERSION : u32 : 3
/** The blocks of the checkpoint ring: blocks 1 to RING_BLOCKS, the one for transaction t at 1 + t % RING_BLOCKS. */
RING_BLOCKS : u64 : 16
/** The first block extents are allocated from, after the first superblock and the ring. */
FIRST_DATA : u64 : 17
/** The fewest blocks a container is made in or mounted from. */
MIN_BLOCKS : u64 : 256

/** The 8 ASCII bytes a superblock starts with, not terminated. */
SUPERBLOCK_MAGIC :: "SLOPFS01"
/** The 8 ASCII bytes a checkpoint starts with, not terminated. */
CHECKPOINT_MAGIC :: "SLOPCKPT"
/** The magic every node's header starts with: "SLFN", little-endian. */
NODE_MAGIC : u32 : 0x4e464c53

/** A block's or a record's seal: BLAKE3-256 of its bytes, or on an encrypted volume, its AEAD's tag and more. */
Seal :: u8[32]

/**
 * Where a block or an extent is, and how to check it.
 *
 * Container trees are written twice, as ZFS's ditto blocks are, so their pointers name a second copy. A pointer whose
 * address is 0 points at nothing, as an empty tree's root does.
 */
BlockPointer :: struct #packed {
    /** The extent's first block, from the container's start; 0 for no extent. */
    address : u64le,
    /** The first block of the extent's second copy, for a container tree's node; 0 for none. */
    copy : u64le,
    /** The transaction the extent was written in: for a clone, it says whose it is, and whether a snapshot holds it. */
    birth : u64le,
    /** The extent's length in blocks: NODE_BLOCKS for a node, 1 to CHUNK_BLOCKS for a file's chunk. */
    blocks : u32le,
    /** The key generation it's sealed with on an encrypted volume (keys.hsc); 0 on a volume that isn't encrypted. */
    generation : u32le,
    /**
     * Its seal: BLAKE3-256 of the extent's bytes, or on an encrypted volume, its AEAD's tag and what its key and
     * nonce came from (keys.hsc). A read that doesn't match it is Corrupt.
     */
    seal : Seal,
}

#assert size_of(BlockPointer) == 64

/** Which tree a node is of, as its header names it, so a node read for the wrong tree is Corrupt. */
TreeKind :: enum #backed_by(u16) {
    /** The container's free extents, and those freed in the last commit. */
    SpaceMap = 1,
    /** The container's record of every allocated extent's owner. */
    Owners = 2,
    /** The container's volumes, their keys, snapshots and dead lists. */
    Volumes = 3,
    /** A volume's own tree, of its objects, directory entries, file extents and history. */
    Volume = 4,
}

/** Every node's first 64 bytes, little-endian, written into it, so a node read from the wrong place shows it. */
NodeHeader :: struct #packed {
    /** NODE_MAGIC. */
    magic : u32le,
    /** The TreeKind of the tree it's in. */
    tree : u16le,
    /** Its level: 0 for a leaf, 1 and up for a branch, its children one level lower. */
    level : u16le,
    /** How many items (a leaf) or entries (a branch) it holds, after the header. */
    count : u16le,
    /**
     * A leaf's values are packed at its end, from this byte offset in the node to NODE_BYTES; NODE_BYTES for none.
     * Not used in a branch.
     */
    values_start : u16le,
    /** Reserved; zero. */
    reserved0 : u32le,
    /** The volume the tree belongs to, or 0, the container. */
    owner : u64le,
    /** The transaction it was written in. */
    transaction : u64le,
    /** The block it was written to, so a misdirected write reads back as Corrupt. */
    address : u64le,
    /** Reserved; zero. */
    reserved : u8[24],
}

#assert size_of(NodeHeader) == 64

/** What a record is, a key's middle part, which orders them after the object. */
RecordKind :: enum #backed_by(u8) {
    /** The space map: an extent free since a commit before the last, keyed by its first block. */
    Free = 1,
    /** The space map: an extent freed in the last commit, reusable once it's durable, keyed (0, Pending, first). */
    Pending = 2,
    /** The owners: an allocated extent's owner, keyed by its first block. */
    Owner = 3,
    /** The volumes: a volume, keyed by its ID. */
    VolumeEntry = 4,
    /** A volume: an object, keyed by its ID. */
    Object = 5,
    /** A volume: a directory's entries whose names hash alike, keyed (directory, Entry, hash). */
    Entry = 6,
    /** A volume: a file's chunk, keyed (file, Extent, byte offset). */
    Extent = 7,
    /** A volume: one change, keyed (0, Change, its sequence number from 1), and the history's own state at 0. */
    Change = 8,
    /**
     * A volume: an object no name leads to, kept while it's open, keyed (0, Orphan, object), destroyed when nothing
     * has it.
     */
    Orphan = 9,
    /** The volumes: an encrypted volume's key wrapped, keyed (volume, KeyWrap, index) (keys.hsc). */
    KeyWrap = 10,
    /** The volumes: one of its key generations, wrapped by its volume key, keyed (volume, KeyGeneration, number). */
    KeyGeneration = 11,
    /** The volumes: one of its snapshots, keyed (volume, Snapshot, number from 1) (snapshot.hsc). */
    Snapshot = 12,
    /** The volumes: an extent it gave back that a snapshot still holds, keyed (volume, Dead, first block). */
    Dead = 13,
    /** A volume: a stored link's record, what it leads to, keyed (link, Link, 0) (links.hsc). */
    Link = 14,
    /** A volume: a link it issued, keyed (0, Issued, number from 1), and the next number at 0. */
    Issued = 15,
}

/** A key as it's stored: ordered by object, then kind, then offset, each compared as an unsigned number. */
DiskKey :: struct #packed {
    /** The object or extent the record is of: an object ID, a volume ID, a first block, or 0, as its kind says. */
    object : u64le,
    /** The record's RecordKind. */
    kind : u8,
    /** Reserved; zero. */
    reserved : u8[7],
    /** Which of the object's records of the kind: a byte offset, a hash, a sequence number or 0, as its kind says. */
    offset : u64le,
}

#assert size_of(DiskKey) == 24

/** A leaf's item: its key and where its value is in the node. Items follow the header, in key order. */
LeafItem :: struct #packed {
    /** The record's key. */
    key : DiskKey,
    /** Where the value starts, in bytes from the node's start, at or after the header's values_start. */
    value_offset : u16le,
    /** The value's size in bytes, 0 to MAX_VALUE_BYTES. */
    value_bytes : u16le,
    /** Reserved; zero. */
    reserved : u32le,
}

#assert size_of(LeafItem) == 32

/** A branch's entry: a child, every key in which is at least key. Entries follow the header, in key order. */
BranchEntry :: struct #packed {
    /** The least key the child may hold; the first entry's isn't used, its child holding every key before the next. */
    key : DiskKey,
    /** Where the child node is, and its seal. */
    child : BlockPointer,
}

#assert size_of(BranchEntry) == 88

/** What names a container, in its first block and its last, little-endian; the rest of each block is zero. */
Superblock :: struct #packed {
    /** SUPERBLOCK_MAGIC's 8 bytes. */
    magic : u8[8],
    /** FORMAT_VERSION. */
    version : u32le,
    /** BLOCK_BYTES. */
    block_bytes : u32le,
    /** NODE_BYTES. */
    node_bytes : u32le,
    /** RING_BLOCKS. */
    ring_blocks : u32le,
    /** The container's ID, which every checkpoint has to name. */
    container : u8[16],
    /** The container's size in blocks, which the device's has to be for it to mount. */
    block_count : u64le,
    /** The ring's first block: 1. */
    ring_first : u64le,
    /** Reserved; zero. */
    reserved : u8[64],
    /** BLAKE3-256 of everything before it. */
    seal : Seal,
}

#assert size_of(Superblock) == 152

/**
 * A commit's record, in the ring, little-endian: its transaction, the container's trees' roots, and what's needed to
 * go on. Mounting takes the newest whose seal holds.
 */
Checkpoint :: struct #packed {
    /** CHECKPOINT_MAGIC's 8 bytes. */
    magic : u8[8],
    /** FORMAT_VERSION. */
    version : u32le,
    /** Reserved; zero. */
    reserved0 : u32le,
    /** The transaction this commit made durable; the newest in the ring is the container's state. */
    transaction : u64le,
    /** The container's ID, the superblock's. */
    container : u8[16],
    /** The space map's root. */
    space_map : BlockPointer,
    /** The owners tree's root. */
    owners : BlockPointer,
    /** The volumes tree's root. */
    volumes : BlockPointer,
    /** The blocks free when it was written, as the space in memory counted them; for reporting, not read at mount. */
    free_blocks : u64le,
    /** The ID the next volume made gets, from 1. */
    next_volume : u64le,
    /** Reserved; zero. */
    reserved : u8[64],
    /** BLAKE3-256 of everything before it. */
    seal : Seal,
}

#assert size_of(Checkpoint) == 344

/** A space map record's value: an extent's length, and for a pending one, the transaction that freed it. */
SpaceValue :: struct #packed {
    /** The extent's length in blocks, at least 1. */
    blocks : u64le,
    /** For a Pending extent, the transaction that freed it; 0 for a Free one. */
    transaction : u64le,
}

#assert size_of(SpaceValue) == 16

/** An owner record's value: the extent's length, its owner, and the transaction it was allocated in. */
OwnerValue :: struct #packed {
    /** The extent's length in blocks. */
    blocks : u64le,
    /** The volume that owns it, or 0, the container. */
    volume : u64le,
    /** The transaction it was allocated in. */
    birth : u64le,
}

#assert size_of(OwnerValue) == 24

/** The most bytes in a volume's or a snapshot's name. */
VOLUME_NAME_BYTES :: 64

/**
 * A volume's record in the container, little-endian.
 *
 * A clone's names the volume it was cloned from, the snapshot and the transaction that snapshot holds, whose blocks
 * are the origin's; and every volume names whose key records it uses, its own, or for a clone, its origin's
 * (snapshot.hsc), and the most blocks it may have (space.hsc).
 */
VolumeRecord :: struct #packed {
    /** Its tree's root, as its last commit wrote it. */
    root : BlockPointer,
    /** The ID its next object gets; IDs are never reused. */
    next_object : u64le,
    /** The key its directory entries' names are hashed with, its own, so names can't be made to collide at will. */
    hash_key : u8[32],
    /** When it was made, as the time its maker gave. */
    created : u64le,
    /** How many bytes of name are used, 1 to VOLUME_NAME_BYTES. */
    name_bytes : u16le,
    /** Its Cipher (keys.hsc): None for a volume sealed with BLAKE3 alone. */
    cipher : u8,
    /** Reserved; zero. */
    reserved : u8,
    /** Its newest key generation, which new blocks are sealed with; 0 on a volume that isn't encrypted. */
    generation : u32le,
    /** Its name, UTF-8, its first name_bytes used. */
    name : u8[VOLUME_NAME_BYTES],
    /** For a clone, the volume it was cloned from; 0 for a volume that isn't one. */
    origin : u64le,
    /** For a clone, the number of the origin's snapshot it was cloned from. */
    origin_snapshot : u64le,
    /** For a clone, the transaction that snapshot holds: blocks born at or before it are the origin's. */
    origin_transaction : u64le,
    /** The volume whose key records it uses: its own ID, or for a clone, its origin's; 0 is taken as its own. */
    key_owner : u64le,
    /** The most blocks it may have, its snapshots' included; 0 for no limit. */
    quota : u64le,
}

#assert size_of(VolumeRecord) == 224

/** What an object is. */
ObjectKind :: enum #backed_by(u32) {
    /** A file: bytes, in chunks. */
    File = 1,
    /** A directory: names, in entries. */
    Directory = 2,
    /** A stored link to an object in another volume (links.hsc). */
    Link = 3,
}

/** The object every volume's tree starts from, its root directory. */
ROOT_OBJECT : u64 : 1

/** An object's record, little-endian. */
ObjectRecord :: struct #packed {
    /** Its ObjectKind. */
    kind : u32le,
    /** Reserved; zero. */
    reserved : u32le,
    /** Its parent directory: there are no hard links, so there's one. The root's is itself, ROOT_OBJECT. */
    parent : u64le,
    /** A file's size in bytes; 0 for a directory or a link. */
    size : u64le,
    /** When it was made, in nanoseconds, as the volume's user gives them. */
    created : u64le,
    /** When its contents last changed, in nanoseconds, as the volume's user gives them. */
    modified : u64le,
    /** The transaction it last changed in. */
    changed : u64le,
    /** Its schema hash (decisions/0046), what a typed file holds; zero for plain bytes. */
    schema : u8[32],
}

#assert size_of(ObjectRecord) == 80

/** One name in a directory's entries that hash alike: the object, its kind, and the name's bytes after it. */
EntryHead :: struct #packed {
    /** The object the name leads to. */
    object : u64le,
    /** The object's ObjectKind, so a listing needn't read it. */
    kind : u32le,
    /** How many bytes of name follow, 1 to NAME_BYTES. */
    name_bytes : u16le,
    /** Reserved; zero. */
    reserved : u16le,
}

#assert size_of(EntryHead) == 16

/** The most bytes in a name, UTF-8 without '/' or NUL. */
NAME_BYTES :: 255

/*
 * A file's bytes are in chunks of CHUNK_BYTES from offset 0, each an extent of whole blocks, or the first held in its
 * record for a file of at most INLINE_BYTES. A chunk that isn't there is zeros, and so are its bytes past `bytes`.
 */
/** The bytes in a file's chunk, each one record keyed by its byte offset, a multiple of it. */
CHUNK_BYTES : u64 : 65536
/** The most blocks a chunk's extent takes: CHUNK_BYTES / BLOCK_BYTES. */
CHUNK_BLOCKS : u64 : 16
/** The most bytes a file's chunk holds in its record, inline, when the file is no bigger. */
INLINE_BYTES : u64 : 2048

/** Where a chunk's bytes are. */
ExtentKind :: enum #backed_by(u32) {
    /** In the record, after its INLINE_HEAD bytes. */
    Inline = 1,
    /** In an extent of whole blocks, which the record's pointer names. */
    Blocks = 2,
}

/** A chunk's record: inline, its bytes follow; in blocks, where they are. */
ExtentRecord :: struct #packed {
    /** Its ExtentKind. */
    kind : u32le,
    /** The chunk's bytes that were written, from its start; those after it, to CHUNK_BYTES, read as zeros. */
    bytes : u32le,
    /** For a chunk in blocks, its extent; an inline chunk's record ends at INLINE_HEAD, without it. */
    pointer : BlockPointer,
}

#assert size_of(ExtentRecord) == 72

/** The bytes of an inline chunk's record before its bytes: its kind and bytes. */
INLINE_HEAD : u64 : 8

/**
 * A volume's change history's state (decisions/0089), at sequence number 0 of its Change records.
 *
 * The history is what change cursors read: each change a record from sequence number 1, the oldest dropped once the
 * history passes its budget in bytes.
 */
ChangeState :: struct #packed {
    /** The sequence number of the oldest change kept; first == next when none is. */
    first : u64le,
    /** The sequence number the next change gets, from 1. */
    next : u64le,
    /** The bytes the kept changes' records take, header and name. */
    bytes : u64le,
}

#assert size_of(ChangeState) == 24

/** What a change did. */
ChangeKind :: enum #backed_by(u32) {
    /** An object made, under its name. */
    Created = 1,
    /** A file's bytes or size changed. */
    Written = 2,
    /** An object's name removed. */
    Removed = 3,
    /** An object moved away from its name; a MovedIn follows with its new one. */
    MovedOut = 4,
    /** An object moved to its new name. */
    MovedIn = 5,
    /** A file's contents swapped for new ones, whole (Replace). */
    Replaced = 6,
}

/** A change's record: what was done to what, with the name after it. */
ChangeRecord :: struct #packed {
    /** The transaction it was made in. */
    transaction : u64le,
    /** The object it was made to. */
    object : u64le,
    /** The directory the name is in. */
    parent : u64le,
    /** Its ChangeKind. */
    kind : u32le,
    /** How many bytes of name follow, 0 to NAME_BYTES. */
    name_bytes : u16le,
    /** Reserved; zero. */
    reserved : u16le,
}

#assert size_of(ChangeRecord) == 32

/** The history's budget a volume server keeps, in bytes; past it, the oldest changes are dropped. */
HISTORY_BYTES : u64 : 1 << 20

/** A record's value's most bytes, so every leaf holds at least two. */
MAX_VALUE_BYTES : u64 : 4096

/**
 * A snapshot's record: the volume's tree as its last commit left it, and when it was taken, and its name.
 */
SnapshotRecord :: struct #packed {
    /** The volume's root as its last commit had it. */
    root : BlockPointer,
    /** The transaction that commit made durable, which holds every block the tree has. */
    transaction : u64le,
    /** The volume's next object ID as its last commit had it. */
    next_object : u64le,
    /** When it was taken, as its taker says. */
    created : u64le,
    /** How many bytes of name are used, 1 to VOLUME_NAME_BYTES. */
    name_bytes : u16le,
    /** Reserved; zero. */
    reserved : u8[6],
    /** Its name, UTF-8, its first name_bytes used. */
    name : u8[VOLUME_NAME_BYTES],
}

#assert size_of(SnapshotRecord) == 160

/** A dead list's record: an extent a volume gave back, which a snapshot still holds, keyed by its first block. */
DeadValue :: struct #packed {
    /** The extent's length in blocks. */
    blocks : u64le,
    /** The transaction it was written in. */
    birth : u64le,
    /** The transaction it was given back in. */
    freed : u64le,
}

#assert size_of(DeadValue) == 24
