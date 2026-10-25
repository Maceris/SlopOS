/*
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

BLOCK_BYTES : u64 : 4096
NODE_BYTES : u64 : 16384
NODE_BLOCKS : u64 : 4
FORMAT_VERSION : u32 : 1
// The checkpoint ring: blocks 1 to RING_BLOCKS, the one for transaction t at 1 + t % RING_BLOCKS
RING_BLOCKS : u64 : 16
// The first block extents are allocated from, after the superblock and the ring
FIRST_DATA : u64 : 17
// The fewest blocks a container is made in
MIN_BLOCKS : u64 : 256

SUPERBLOCK_MAGIC :: "SLOPFS01"
CHECKPOINT_MAGIC :: "SLOPCKPT"
// "SLFN", little-endian
NODE_MAGIC : u32 : 0x4e464c53

Seal :: u8[32]

/*
 * Where a block or an extent is, and how to check it: its first block, a second copy's (container trees are written
 * twice, as ZFS's ditto blocks are, or 0), its length in blocks, the transaction it was written in, the key
 * generation it's sealed with (0 unencrypted, 8e), and its seal: BLAKE3-256 of its bytes.
 */
BlockPointer :: struct #packed {
    address : u64le,
    copy : u64le,
    birth : u64le,
    blocks : u32le,
    generation : u32le,
    seal : Seal,
}

#assert size_of(BlockPointer) == 64

// Each tree, which a node's header names.
TreeKind :: enum #backed_by(u16) {
    SpaceMap = 1,
    Owners = 2,
    Volumes = 3,
    Volume = 4,
}

// Every node's first 64 bytes.
NodeHeader :: struct #packed {
    magic : u32le,
    tree : u16le,
    // 0 for a leaf
    level : u16le,
    count : u16le,
    // A leaf's values are packed at its end, from here
    values_start : u16le,
    reserved0 : u32le,
    // The volume it belongs to, or 0, the container
    owner : u64le,
    transaction : u64le,
    address : u64le,
    reserved : u8[24],
}

#assert size_of(NodeHeader) == 64

// What a record is, a key's middle part, which orders them after the object.
RecordKind :: enum #backed_by(u8) {
    // The space map: an extent free since a commit before the last, keyed by its first block
    Free = 1,
    // The space map: an extent freed in the last commit, reusable once it's durable, keyed (0, Pending, first block)
    Pending = 2,
    // The owners: an allocated extent's owner, keyed by its first block
    Owner = 3,
    // The volumes: a volume, keyed by its ID
    VolumeEntry = 4,
    // A volume: an object, keyed by its ID
    Object = 5,
    // A volume: a directory's entries whose names hash alike, keyed (directory, Entry, hash)
    Entry = 6,
    // A volume: a file's chunk, keyed (file, Extent, byte offset)
    Extent = 7,
}

// A key as it's stored: ordered by object, then kind, then offset.
DiskKey :: struct #packed {
    object : u64le,
    kind : u8,
    reserved : u8[7],
    offset : u64le,
}

#assert size_of(DiskKey) == 24

// A leaf's item: its key and where its value is in the node.
LeafItem :: struct #packed {
    key : DiskKey,
    value_offset : u16le,
    value_bytes : u16le,
    reserved : u32le,
}

#assert size_of(LeafItem) == 32

// A branch's entry: a child, every key in which is at least key (the first entry's key isn't used).
BranchEntry :: struct #packed {
    key : DiskKey,
    child : BlockPointer,
}

#assert size_of(BranchEntry) == 88

// What names a container, in its first block and its last.
Superblock :: struct #packed {
    magic : u8[8],
    version : u32le,
    block_bytes : u32le,
    node_bytes : u32le,
    ring_blocks : u32le,
    container : u8[16],
    block_count : u64le,
    ring_first : u64le,
    reserved : u8[64],
    // BLAKE3-256 of everything before it
    seal : Seal,
}

#assert size_of(Superblock) == 152

/*
 * A commit's record, in the ring: its transaction, the container's trees' roots, and what's needed to go on. Mounting
 * takes the newest whose seal holds.
 */
Checkpoint :: struct #packed {
    magic : u8[8],
    version : u32le,
    reserved0 : u32le,
    transaction : u64le,
    container : u8[16],
    space_map : BlockPointer,
    owners : BlockPointer,
    volumes : BlockPointer,
    free_blocks : u64le,
    next_volume : u64le,
    reserved : u8[64],
    seal : Seal,
}

#assert size_of(Checkpoint) == 344

// A space map record's value: an extent's length, and for a pending one, the transaction that freed it.
SpaceValue :: struct #packed {
    blocks : u64le,
    transaction : u64le,
}

#assert size_of(SpaceValue) == 16

// An owner record's value.
OwnerValue :: struct #packed {
    blocks : u64le,
    volume : u64le,
}

#assert size_of(OwnerValue) == 16

// The most bytes in a volume's name.
VOLUME_NAME_BYTES :: 64

// A volume's record in the container: its tree, its next object's ID, the key its names hash with, and its name.
VolumeRecord :: struct #packed {
    root : BlockPointer,
    next_object : u64le,
    hash_key : u8[32],
    created : u64le,
    name_bytes : u16le,
    reserved : u8[6],
    name : u8[VOLUME_NAME_BYTES],
}

#assert size_of(VolumeRecord) == 184

ObjectKind :: enum #backed_by(u32) {
    File = 1,
    Directory = 2,
}

// The object every volume's tree starts from, its root directory.
ROOT_OBJECT : u64 : 1

/*
 * An object's record: its kind, its parent directory (there are no hard links, so there's one), its size in bytes,
 * its creation and modification times (nanoseconds, as the volume's user gives them), the transaction it last
 * changed in, and its schema hash (decisions/0046), zero for plain bytes.
 */
ObjectRecord :: struct #packed {
    kind : u32le,
    reserved : u32le,
    parent : u64le,
    size : u64le,
    created : u64le,
    modified : u64le,
    changed : u64le,
    schema : u8[32],
}

#assert size_of(ObjectRecord) == 80

// One name in a directory's entries that hash alike: the object, its kind, and the name's bytes after it.
EntryHead :: struct #packed {
    object : u64le,
    kind : u32le,
    name_bytes : u16le,
    reserved : u16le,
}

#assert size_of(EntryHead) == 16

// The most bytes in a name, UTF-8 without '/' or NUL.
NAME_BYTES :: 255

/*
 * A file's bytes are in chunks of CHUNK_BYTES from offset 0, each an extent of whole blocks, or the first held in its
 * record for a file of at most INLINE_BYTES. A chunk that isn't there is zeros, and so are its bytes past `bytes`.
 */
CHUNK_BYTES : u64 : 65536
CHUNK_BLOCKS : u64 : 16
INLINE_BYTES : u64 : 2048

ExtentKind :: enum #backed_by(u32) {
    Inline = 1,
    Blocks = 2,
}

// A chunk's record: inline, its bytes follow; in blocks, where they are.
ExtentRecord :: struct #packed {
    kind : u32le,
    // The chunk's bytes that were written, from its start
    bytes : u32le,
    pointer : BlockPointer,
}

#assert size_of(ExtentRecord) == 72

// An inline chunk's record before its bytes.
INLINE_HEAD : u64 : 8

// A record's value's most bytes, so every leaf holds at least two.
MAX_VALUE_BYTES : u64 : 4096
