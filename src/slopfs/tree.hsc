package slopfs

import runtime from "base"
import crypto from "std"
import maps from "std"

/*
 * Copy-on-write B+trees of 16 KiB nodes (Rodeh, "B-trees, Shadowing, and Clones", TOS 2008): a node changed in a
 * transaction is first copied to a new place, and its parent changed to point there, up to the root, so the tree a
 * durable checkpoint names is never written over. Copies are kept in memory, dirty, and changed in place for the rest
 * of the transaction; committing writes them children first, each parent's pointer taking its child's seal.
 *
 * A leaf holds items, each a key and a value of up to MAX_VALUE_BYTES; a branch holds entries, each a key and a
 * child whose keys are all at least it, the first entry's key not used. Nodes that empty are dropped, and a node
 * left less than a quarter full is merged into its neighbour where both fit in one.
 */

/** Why a slopfs operation failed. */
Error :: enum {
    /** The device couldn't be written or flushed, or a file's bytes couldn't be read. */
    DeviceError,
    /** What was read doesn't check out, or couldn't be read: a seal, a header or a structure. */
    Corrupt,
    /** No free extent big enough, or a quota or the reserve refuses one. */
    NoSpace,
    /** No such object, name, volume, snapshot or record. */
    NotFound,
    /** A directory was needed, and it's a file. */
    NotADirectory,
    /** A file was needed, and it's a directory. */
    IsADirectory,
    /** Something of the name is there already. */
    AlreadyExists,
    /** A directory to remove has something in it. */
    DirectoryNotEmpty,
    /** Empty, too long, or holding '/' or NUL, or something else a name can't hold. */
    InvalidName,
    /** A value, a name list or a file past what's held. */
    TooLarge,
    /** Not a container: no superblock, or no checkpoint that checks out. */
    NotSlopfs,
    /** A write failed: commits are refused until the container is mounted again (design/storage.md §4). */
    Failed,
    /** An encrypted volume, opened without its keys (keys.hsc). */
    Locked,
    /** A passphrase that doesn't unwrap the volume's key. */
    WrongKey,
    /** A snapshot a clone was made from, which can't be deleted while it's there (snapshot.hsc). */
    InUse,
    /** A stored link, where a file or a directory was needed (links.hsc). */
    IsALink,
    /** No memory for a node or a buffer (decisions/0104): nothing was changed for want of it. */
    OutOfMemory,
    /** A typed file of another type than the one asked for (decisions/0108). */
    WrongType,
}

/**
 * Allocate a new T with context's allocator: every node and buffer slopfs takes comes from here (decisions/0104),
 * each taken before what it's for changes anything, so a caller can fail without it and nothing is left half done.
 *
 * @tparam T The type.
 * @param T The type, as a value.
 * @param location Where it's called from, for the allocator's records.
 * @return The new T, its contents as the allocator leaves them; the caller's to free with runtime.free.
 * @error OutOfMemory The allocator had no memory for it.
 */
make :: fn[T](T: type, location := #caller_location) -> Result[ptr[mut T], Error] {
    made, error :: runtime.new_aligned(T, align_of(T), context.allocator, location)
    if error != null {
        return .Error(.OutOfMemory)
    }
    return .Ok(made)
}

/** A device of BLOCK_BYTES blocks, read, written and flushed through its functions. */
Device :: struct {
    /**
     * What the functions are given back, the caller's own: memory that outlives the device, not the stack, so the
     * nodes and containers that hold it can be pointed to.
     */
    context : rawptr,
    /** The device's size in blocks. */
    block_count : u64,
    /** Read count blocks, from block, into into, at least count * BLOCK_BYTES bytes; true if they were read. */
    read : fn(context: rawptr, block: u64, count: u64, into: mut u8[]) -> bool,
    /**
     * Write count blocks, from block, from from's first count * BLOCK_BYTES bytes; true if they were written, though
     * not yet durable until a flush.
     */
    write : fn(context: rawptr, block: u64, count: u64, from: u8[]) -> bool,
    /** Make everything written so far durable; true if it is. */
    flush : fn(context: rawptr) -> bool,
}

/** A key in memory, ordered by object, then kind, then offset (compare_keys). */
Key :: struct {
    /** The object or extent the record is of, as DiskKey's. */
    object : u64,
    /** The record's RecordKind, as a byte. */
    kind : u8,
    /** Which of the object's records of the kind, as DiskKey's. */
    offset : u64,
}

/**
 * Make a key.
 *
 * @param object The object or extent the record is of.
 * @param kind What sort of record it is; stored as its byte, it orders keys after object and before offset.
 * @param offset Which of the object's records of the kind.
 * @return The key, its fields as given.
 */
key_of :: fn(object: u64, kind: RecordKind, offset: u64) -> Key {
    return Key.{object = object, kind = cast[u8](kind), offset = offset}
}

/**
 * Compare two keys, by object, then kind, then offset, each unsigned.
 *
 * @param a One key.
 * @param b The other key, compared with a.
 * @return -1 if a is before b, 1 if after, 0 if they're the same.
 */
compare_keys :: fn(a: Key, b: Key) -> int {
    if a.object != b.object {
        return if a.object < b.object { -1 } else { 1 }
    }
    if a.kind != b.kind {
        return if a.kind < b.kind { -1 } else { 1 }
    }
    if a.offset != b.offset {
        return if a.offset < b.offset { -1 } else { 1 }
    }
    return 0
}

/**
 * Get the key just after another, for walking records in order.
 *
 * @param key The key to step from, any key.
 * @return The least key greater than it; null after the last there can be, all ones.
 */
key_after :: fn(key: Key) -> Key? {
    if key.offset != 0xffffffffffffffff {
        return Key.{object = key.object, kind = key.kind, offset = key.offset + 1}
    }
    if key.kind != 0xff {
        return Key.{object = key.object, kind = key.kind + 1}
    }
    if key.object != 0xffffffffffffffff {
        return Key.{object = key.object + 1}
    }
    return null
}

/**
 * Make a key as it's stored.
 *
 * @param key The key in memory.
 * @return It as a DiskKey, little-endian, its reserved bytes zero.
 */
disk_key_of :: fn(key: Key) -> DiskKey {
    return DiskKey.{object = cast[u64le](key.object), kind = key.kind, offset = cast[u64le](key.offset)}
}

/**
 * Make a stored key a key in memory.
 *
 * @param key The stored key; its reserved bytes are ignored.
 * @return The key in memory, its fields as stored.
 */
memory_key_of :: fn(key: ptr[DiskKey]) -> Key {
    return Key.{object = cast[u64](key.object), kind = key.kind, offset = cast[u64](key.offset)}
}

/** A node's bytes, as an integer for sizes: NODE_BYTES. */
NODE_SIZE :: 16384
/** A node header's bytes: size_of(NodeHeader). */
HEADER_SIZE :: 64
/** A leaf item's bytes: size_of(LeafItem). */
ITEM_SIZE :: 32
/** A branch entry's bytes: size_of(BranchEntry). */
ENTRY_SIZE :: 88
/** The most entries a branch holds: as many as fit after its header. */
BRANCH_CAPACITY :: 185
/** The most items a leaf holds, values or none: as many 32-byte items as fit after its header, less one. */
LEAF_CAPACITY :: 510

/**
 * A node in memory: dirty, owned by the transaction's set until it's written; or read for a moment, then given back.
 *
 * It's from make; a dirty one is freed when it's written or discarded, a read one by done.
 */
Node :: struct {
    /** Its bytes, as they are on the device unsealed. */
    bytes : u8[NODE_SIZE],
    /** The first block of its second copy, for a tree written twice; 0 for none. */
    copy : u64,
    /** Whether it's among the transaction's dirty nodes, changed in place until it's written. */
    dirty : bool,
}

/** A tree: where its root is, which tree it is, whose, and how its nodes are sealed and placed. */
Tree :: struct {
    /** Its root's pointer; address 0 while it's empty. */
    root : BlockPointer,
    /** Which tree it is, as its nodes' headers say. */
    kind : TreeKind,
    /** The volume it's of, or 0, the container; its nodes' headers name it, and its new blocks are charged to it. */
    owner : u64,
    /** Whether its nodes are written twice, as the container's trees are. */
    ditto : bool,
    /** An encrypted volume's keys, which seal its nodes (keys.hsc); null for a BLAKE3 seal. Not the tree's to free. */
    keys : ptr[mut Keys]?,
    /** For a clone's tree, who wrote its older blocks; empty otherwise. */
    lineage : Lineage,
}

/** The most origins a clone's lineage goes back: a clone of a clone of a clone of a clone. */
MAX_LINEAGE :: 4

/**
 * Who wrote a clone's older blocks (snapshot.hsc): its origin, up to the transaction the snapshot it was cloned from
 * holds, and the origin's own origin up to the one before, and so on, nearest first.
 */
Lineage :: struct {
    /** How many of owners and up_to are used, 0 to MAX_LINEAGE. */
    count : usize,
    /** The origins, nearest first. */
    owners : u64[MAX_LINEAGE],
    /** For each origin, the last transaction whose blocks are its. */
    up_to : u64[MAX_LINEAGE],
}

/**
 * Work out whose a tree's block is: the oldest ancestor whose part holds it, or the tree's own owner's.
 *
 * @param tree The tree the block is in, its owner and lineage.
 * @param birth The transaction the block was born in.
 * @return The volume that wrote it, whose ID its header and associated data name.
 */
owner_at :: fn(tree: ptr[Tree], birth: u64) -> u64 {
    owner := tree.owner
    for i in 0..<tree.lineage.count {
        if i < MAX_LINEAGE && birth <= tree.lineage.up_to[i] {
            owner = tree.lineage.owners[i]
        }
    }
    return owner
}

/** The nodes of one transaction: the device they're on, the dirty ones by address, and where extents come from. */
Nodes :: struct {
    /** The device the nodes are on. */
    device : Device,
    /** The transaction being made: new nodes are born in it, and a node born in it is dirty. */
    transaction : u64,
    /** The dirty nodes, by address, each from make; written and freed by tree_write. */
    dirty : maps.HashMap[u64, ptr[mut Node], maps.hash_integer[u64]],
    /** What allocate and release are given back: the container's Space. */
    space : rawptr,
    /**
     * Allocate blocks for an owner, in one extent: its first block, or null if there's none. data says they're for a
     * file's bytes rather than a tree's nodes, which a quota and the reserve don't hold back (space.hsc).
     */
    allocate : fn(space: rawptr, blocks: u64, owner: u64, data: bool) -> u64?,
    /** Take back an extent an owner had, born in birth. */
    release : fn(space: rawptr, address: u64, blocks: u64, owner: u64, birth: u64),
}

// Fields of a node's bytes.

/**
 * Get a node's header.
 *
 * @param node The node, in memory, read or dirty.
 * @return Its header, a view of its first bytes, good as long as the node is.
 */
header_of :: fn(node: ptr[mut Node]) -> ptr[mut NodeHeader] {
    return cast[ptr[mut NodeHeader]](&node.bytes[0])
}

/**
 * Get how many items or entries a node holds.
 *
 * @param node The node, in memory, read or dirty.
 * @return Its header's count.
 */
count_of :: fn(node: ptr[mut Node]) -> usize {
    return cast[usize](cast[u16](header_of(node).count))
}

/**
 * Get a node's level.
 *
 * @param node The node, in memory, read or dirty.
 * @return 0 for a leaf; more for a branch.
 */
level_of :: fn(node: ptr[mut Node]) -> u16 {
    return cast[u16](header_of(node).level)
}

/**
 * Set how many items or entries a node holds.
 *
 * @param node The node, dirty or being made.
 * @param count The count, at most the node's capacity.
 */
set_count :: fn(node: ptr[mut Node], count: usize) {
    header_of(node).count = cast[u16le](cast[u16](count))
}

/**
 * Get a leaf's item.
 *
 * @param node The leaf, in memory; its count bounds its items.
 * @param index The item's index, which the leaf's count bounds (checked when it's read).
 * @return The item, in the node; the first one's place if index would be past the node's end.
 */
item_at :: fn(node: ptr[mut Node], index: usize) -> ptr[mut LeafItem] {
    at :: HEADER_SIZE + index * ITEM_SIZE
    if at + ITEM_SIZE <= NODE_SIZE && at < node.bytes.count {
        return cast[ptr[mut LeafItem]](&node.bytes[at])
    }
    return cast[ptr[mut LeafItem]](&node.bytes[HEADER_SIZE])
}

/**
 * Get a branch's entry.
 *
 * @param node The branch, in memory; its count bounds its entries.
 * @param index The entry's index, which the branch's count bounds.
 * @return The entry, in the node; the first one's place if index would be past the node's end.
 */
entry_at :: fn(node: ptr[mut Node], index: usize) -> ptr[mut BranchEntry] {
    at :: HEADER_SIZE + index * ENTRY_SIZE
    if at + ENTRY_SIZE <= NODE_SIZE && at < node.bytes.count {
        return cast[ptr[mut BranchEntry]](&node.bytes[at])
    }
    return cast[ptr[mut BranchEntry]](&node.bytes[HEADER_SIZE])
}

/**
 * Get a leaf's item's key.
 *
 * @param node The leaf, in memory; its count bounds its items.
 * @param index Which item, from 0; not checked against the count, and past the node's end it reads the first item.
 * @return The item's key, in memory form.
 */
item_key :: fn(node: ptr[mut Node], index: usize) -> Key {
    return memory_key_of(&item_at(node, index).key)
}

/**
 * Get a branch's entry's key.
 *
 * @param node The branch, in memory; its count bounds its entries.
 * @param index Which entry, from 0; not checked against the count, and past the node's end it reads the first entry.
 * @return The key; the first entry's isn't used.
 */
entry_key :: fn(node: ptr[mut Node], index: usize) -> Key {
    return memory_key_of(&entry_at(node, index).key)
}

/**
 * Get a leaf's item's value.
 *
 * @param node The leaf, in memory; its count bounds its items.
 * @param index Which item, from 0; not checked against the count, and past the node's end it reads the first item.
 * @return The value's bytes, a view into the node, good until the node changes or is freed; empty if the item says
 *     it's outside the node.
 */
value_of :: fn(node: ptr[mut Node], index: usize) -> mut u8[] {
    item :: item_at(node, index)
    start :: cast[usize](cast[u16](item.value_offset))
    count :: cast[usize](cast[u16](item.value_bytes))
    if start >= node.bytes.count || start + count > node.bytes.count {
        return node.bytes[0..<0]
    }
    return view_of(&node.bytes[start], count)
}

/**
 * Get where a leaf's values start.
 *
 * @param node The leaf, in memory; a branch's field is unused.
 * @return The byte offset in the node; NODE_SIZE when it has none.
 */
values_start :: fn(node: ptr[mut Node]) -> usize {
    return cast[usize](cast[u16](header_of(node).values_start))
}

/**
 * Get a leaf's room between its items and its values, not counting holes removals left.
 *
 * @param node The leaf, in memory, read or dirty.
 * @return The bytes free there, 0 or more.
 */
leaf_room :: fn(node: ptr[mut Node]) -> usize {
    items_end :: HEADER_SIZE + count_of(node) * ITEM_SIZE
    start :: values_start(node)
    return if start > items_end { start - items_end } else { 0 }
}

/**
 * Get what a leaf's items and values take, without the holes removals left.
 *
 * @param node The leaf, in memory, read or dirty.
 * @return The bytes, not counting the header.
 */
leaf_used :: fn(node: ptr[mut Node]) -> usize {
    used := count_of(node) * ITEM_SIZE
    for i in 0..<count_of(node) {
        used += cast[usize](cast[u16](item_at(node, i).value_bytes))
    }
    return used
}

/**
 * Start a node's bytes empty: zeros, and a header for a tree, with nothing in it.
 *
 * @param node The node; its copy and dirty are left as they were.
 * @param tree The tree it's of, which its header names, and its owner.
 * @param level Its level, 0 for a leaf.
 * @param transaction The transaction it's written in.
 * @param address The block it's to be written to.
 */
start_node :: fn(node: ptr[mut Node], tree: ptr[Tree], level: u16, transaction: u64, address: u64) {
    for i in 0..<node.bytes.count {
        node.bytes[i] = 0
    }
    header :: header_of(node)
    header.magic = cast[u32le](NODE_MAGIC)
    header.tree = cast[u16le](cast[u16](tree.kind))
    header.level = cast[u16le](level)
    header.values_start = cast[u16le](cast[u16](NODE_SIZE))
    header.owner = cast[u64le](tree.owner)
    header.transaction = cast[u64le](transaction)
    header.address = cast[u64le](address)
}

/**
 * Copy bytes into a buffer, as many as fit.
 *
 * @param into The bytes copied into, from at on.
 * @param at Where in it they go.
 * @param from The bytes; those that would fall past into's end are dropped.
 */
copy_bytes :: fn(into: mut u8[], at: usize, from: u8[]) {
    for byte, i in from {
        j :: at + i
        if j < into.count {
            into[j] = byte
        }
    }
}

/**
 * Check a node's structure, as read from the device: its count within what it can hold, and a leaf's values inside
 * it, of at most MAX_VALUE_BYTES, and its keys in order.
 *
 * @param node The node as read, before it's trusted.
 * @return True if it holds; false if anything's out of place, so it's Corrupt.
 */
structure_holds :: fn(node: ptr[mut Node]) -> bool {
    count :: count_of(node)
    if level_of(node) > 0 {
        return count >= 1 && count <= BRANCH_CAPACITY
    }
    if count > LEAF_CAPACITY {
        return false
    }
    items_end :: HEADER_SIZE + count * ITEM_SIZE
    start :: values_start(node)
    if start < items_end || start > NODE_SIZE {
        return false
    }
    for i in 0..<count {
        item :: item_at(node, i)
        offset :: cast[usize](cast[u16](item.value_offset))
        bytes :: cast[usize](cast[u16](item.value_bytes))
        if offset < start || offset + bytes > NODE_SIZE || cast[u64](bytes) > MAX_VALUE_BYTES {
            return false
        }
        if i > 0 && compare_keys(item_key(node, i - 1), item_key(node, i)) >= 0 {
            return false
        }
    }
    return true
}

/**
 * Get the node a pointer names: dirty, if this transaction has it; otherwise read, from its first copy or its second,
 * each checked by its seal, its header and its structure.
 *
 * @param nodes The transaction's nodes, only read: a node born in this transaction is taken from its dirty set,
 *     any other read from its device into new memory.
 * @param tree The tree it's in, which its header has to name, with its owner.
 * @param pointer Where the node is: its address and second copy (0 for none) to read from, and its birth, seal and
 *     address, which what's read has to match.
 * @return The node: a dirty one, the transaction's, or one read, the caller's; either way given back with done.
 * @error OutOfMemory No memory to read it into.
 * @error Corrupt Neither copy could be read and checks out: its seal, its header (magic, tree, owner, address,
 *     transaction) and its structure.
 */
load :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[BlockPointer]) -> Result[ptr[mut Node], Error] {
    address :: cast[u64](pointer.address)
    if cast[u64](pointer.birth) == nodes.transaction {
        match maps.map_get(&nodes.dirty, address) {
            case Some(found) => return .Ok(found)
            case None => {}
        }
    }
    node :: make(Node)?
    node.dirty = false
    node.copy = cast[u64](pointer.copy)
    for place in u64.[address, cast[u64](pointer.copy)] {
        if place == 0 {
            continue
        }
        if !read_node(nodes, tree, pointer, place, node) {
            continue
        }
        if node_checks_out(node, tree, pointer) {
            return .Ok(node)
        }
    }
    runtime.free(node)
    return .Error(.Corrupt)
}

/**
 * Read a node from a place: as it is, or opened with its tree's keys, which checks its seal.
 *
 * @param nodes The transaction's nodes, whose device it's read from; nothing in them changes.
 * @param tree The tree it's in.
 * @param pointer Its pointer, its seal and birth.
 * @param place The block to read it from: its address or its copy's.
 * @param node Where its bytes go.
 * @return True if it was read, and for an encrypted tree, opened; false if the device couldn't read it, its seal
 *     doesn't hold, or there wasn't the memory to open it.
 */
read_node :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[BlockPointer], place: u64, node: ptr[mut Node]) -> bool {
    match tree.keys {
        case None => return nodes.device.read(nodes.device.context, place, NODE_BLOCKS, node.bytes)
        case Some(keys) => {
            // Without memory to open it in, it's as if it couldn't be read
            sealed :: make(Node) or_return false
            defer runtime.free(sealed)
            if !nodes.device.read(nodes.device.context, place, NODE_BLOCKS, sealed.bytes) {
                return false
            }
            return open_block(keys, owner_at(tree, cast[u64](pointer.birth)), pointer, sealed.bytes, node.bytes)
        }
    }
}

/**
 * Check a node read: its BLAKE3 seal (an encrypted one's held when it was opened), its header and its structure.
 *
 * @param node The node, as read.
 * @param tree The tree it's in.
 * @param pointer The pointer it was reached by: for an unencrypted tree its seal has to be the node's BLAKE3, and
 *     the header has to name its address, its birth as the transaction and the owner that birth gives.
 * @return True if it checks out; false if anything doesn't, as for a damaged or misdirected write.
 */
node_checks_out :: fn(node: ptr[mut Node], tree: ptr[Tree], pointer: ptr[BlockPointer]) -> bool {
    // An encrypted node's seal held when it was opened
    if tree.keys is_none {
        seal : Seal
        crypto.blake3(node.bytes, seal)
        if seal != pointer.seal {
            return false
        }
    }
    header :: header_of(node)
    if cast[u32](header.magic) != NODE_MAGIC || cast[u16](header.tree) != cast[u16](tree.kind)
        || cast[u64](header.owner) != owner_at(tree, cast[u64](pointer.birth)) || cast[u64](header.address) != cast[u64](pointer.address)
        || cast[u64](header.transaction) != cast[u64](pointer.birth) {
        return false
    }
    return structure_holds(node)
}

/**
 * Give back a node load gave: freed if it was only read, kept if it's dirty.
 *
 * @param node The node; one that was only read may not be used again.
 */
done :: fn(node: ptr[mut Node]) {
    if !node.dirty {
        runtime.free(node)
    }
}

/**
 * Allocate blocks for a node of a tree, and a second place for a tree written twice.
 *
 * @param nodes The transaction's nodes: the blocks are allocated from their space, born in their transaction; the
 *     dirty set isn't changed.
 * @param tree The tree, whose owner they're charged to.
 * @return Its pointer: its address, its copy's or 0, its birth this transaction and NODE_BLOCKS; no seal yet.
 * @error NoSpace No free extent for it, or for its copy, the first given back then.
 */
place_node :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree]) -> Result[BlockPointer, Error] {
    address :: nodes.allocate(nodes.space, NODE_BLOCKS, tree.owner, false) or_return .Error(.NoSpace)
    copy : u64 = 0
    if tree.ditto {
        copy = nodes.allocate(nodes.space, NODE_BLOCKS, tree.owner, false) or_else 0
        if copy == 0 {
            nodes.release(nodes.space, address, NODE_BLOCKS, tree.owner, nodes.transaction)
            return .Error(.NoSpace)
        }
    }
    return .Ok(BlockPointer.{address = cast[u64le](address), copy = cast[u64le](copy), birth = cast[u64le](nodes.transaction),
        blocks = cast[u32le](cast[u32](NODE_BLOCKS))})
}

/**
 * Give back a placed node's blocks, unused: what place_node gave, when what it was for couldn't be made.
 *
 * @param nodes The transaction's nodes: the blocks are released to their space as born in their transaction; the
 *     dirty set isn't changed.
 * @param tree The tree it was for.
 * @param pointer What place_node gave.
 */
unplace :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: BlockPointer) {
    nodes.release(nodes.space, cast[u64](pointer.address), NODE_BLOCKS, tree.owner, nodes.transaction)
    if cast[u64](pointer.copy) != 0 {
        nodes.release(nodes.space, cast[u64](pointer.copy), NODE_BLOCKS, tree.owner, nodes.transaction)
    }
}

/** A node and where it is. */
Placed :: struct {
    /** The node, dirty, the transaction's. */
    node : ptr[mut Node],
    /** Where it is, its seal set when it's written. */
    pointer : BlockPointer,
}

/**
 * Make a new, empty, dirty node of a tree at a level.
 *
 * @param nodes The transaction's nodes, which keep it.
 * @param tree The tree it's for: its kind, owner and whether it's written twice.
 * @param level Its level, 0 for a leaf.
 * @return The node and its pointer.
 * @error OutOfMemory No memory for it, or to keep it among the dirty nodes; nothing was allocated.
 * @error NoSpace No free extent for it.
 */
new_node :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], level: u16) -> Result[Placed, Error] {
    // Its memory first, so a node placed is a node made
    node :: make(Node)?
    pointer := BlockPointer.{}
    match place_node(nodes, tree) {
        case Ok(placed) => pointer = placed
        case Error(error) => {
            runtime.free(node)
            return .Error(error)
        }
    }
    start_node(node, tree, level, nodes.transaction, cast[u64](pointer.address))
    node.copy = cast[u64](pointer.copy)
    node.dirty = true
    if maps.map_try_put(&nodes.dirty, cast[u64](pointer.address), node) != null {
        unplace(nodes, tree, pointer)
        runtime.free(node)
        return .Error(.OutOfMemory)
    }
    return .Ok(Placed.{node = node, pointer = pointer})
}

/**
 * Make the node a pointer names writable in this transaction: dirty already, or copied to a new place, the old one
 * given back as of the transaction it was born in, and the pointer changed to the copy.
 *
 * @param nodes The transaction's nodes: the copy's blocks are allocated from their space and the copy added to
 *     their dirty set, and the old node's blocks released.
 * @param tree The tree it's in; the copy is its owner's, even a clone's copy of its origin's node.
 * @param pointer Its pointer, in its parent or the tree's root, changed to the copy's (its seal is set when it's
 *     written).
 * @return The node, dirty, the transaction's.
 * @error OutOfMemory No memory for it or its copy; nothing was changed.
 * @error NoSpace No free extent for the copy; nothing was changed.
 * @error Corrupt It couldn't be read, or didn't check out.
 */
writable :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[mut BlockPointer]) -> Result[ptr[mut Node], Error] {
    node :: load(nodes, tree, pointer)?
    if node.dirty {
        return .Ok(node)
    }
    // The copy's memory before anything moves
    copy :: match make(Node) {
        case Ok(made) => made
        case Error(error) => {
            done(node)
            return .Error(error)
        }
    }
    placed := BlockPointer.{}
    match place_node(nodes, tree) {
        case Ok(made) => placed = made
        case Error(error) => {
            runtime.free(copy)
            done(node)
            return .Error(error)
        }
    }
    // Kept among the dirty nodes before the old one's given back, so there's nothing to undo past here
    if maps.map_try_put(&nodes.dirty, cast[u64](placed.address), copy) != null {
        unplace(nodes, tree, placed)
        runtime.free(copy)
        done(node)
        return .Error(.OutOfMemory)
    }
    nodes.release(nodes.space, cast[u64](pointer.address), NODE_BLOCKS, tree.owner, cast[u64](pointer.birth))
    if cast[u64](pointer.copy) != 0 {
        nodes.release(nodes.space, cast[u64](pointer.copy), NODE_BLOCKS, tree.owner, cast[u64](pointer.birth))
    }
    // The copy, in memory of its own, as what load read is given back
    copy^ = node^
    done(node)
    header :: header_of(copy)
    header.transaction = cast[u64le](nodes.transaction)
    header.address = placed.address
    // A clone's copy of its origin's node is its own
    header.owner = cast[u64le](tree.owner)
    copy.copy = cast[u64](placed.copy)
    copy.dirty = true
    pointer^ = placed
    return .Ok(copy)
}

/**
 * Take a node out of the tree: forgotten if it's dirty, and its blocks given back as of when it was born.
 *
 * @param nodes The transaction's nodes: a node born in this transaction is taken out of their dirty set and freed,
 *     and its blocks are released to their space either way.
 * @param tree The tree it was in.
 * @param pointer Its pointer, which may not be loaded again.
 */
discard :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[BlockPointer]) {
    address :: cast[u64](pointer.address)
    if cast[u64](pointer.birth) == nodes.transaction {
        match maps.map_get(&nodes.dirty, address) {
            case Some(found) => {
                _ = maps.map_remove(&nodes.dirty, address)
                runtime.free(found)
            }
            case None => {}
        }
    }
    nodes.release(nodes.space, address, NODE_BLOCKS, tree.owner, cast[u64](pointer.birth))
    if cast[u64](pointer.copy) != 0 {
        nodes.release(nodes.space, cast[u64](pointer.copy), NODE_BLOCKS, tree.owner, cast[u64](pointer.birth))
    }
}

/**
 * Find where a key is in a leaf, or would go.
 *
 * @param node The leaf, in memory, its keys in order.
 * @param key The key looked for.
 * @return index The item's index if it's there; otherwise the index it would go at, 0 to the leaf's count.
 * @return found Whether it's there.
 */
leaf_find :: fn(node: ptr[mut Node], key: Key) -> (index : usize, found : bool) {
    low : usize = 0
    high := count_of(node)
    loop {
        middle :: low + (high - low) / 2
        order :: compare_keys(item_key(node, middle), key)
        if order == 0 {
            return middle, true
        }
        if order < 0 {
            low = middle + 1
        }
        else {
            high = middle
        }
    }
    while low < high
    return low, false
}

/**
 * Find the child of a branch a key would be under.
 *
 * @param node The branch, with at least one entry.
 * @param key The key looked for.
 * @return The index of the last entry whose key is at most it, the first's key not counted; 0 if there's none.
 */
branch_find :: fn(node: ptr[mut Node], key: Key) -> usize {
    low : usize = 1
    high := count_of(node)
    loop {
        middle :: low + (high - low) / 2
        if compare_keys(entry_key(node, middle), key) <= 0 {
            low = middle + 1
        }
        else {
            high = middle
        }
    }
    while low < high
    return low - 1
}

/**
 * Pack a leaf's values at its end again, without the holes removals left, in place.
 *
 * Each is moved up in turn, the highest first, so none is written over before it's moved, and nothing needs memory of
 * its own (decisions/0104).
 *
 * @param node The leaf; its items' offsets and values_start change, not their order.
 */
leaf_compact :: fn(node: ptr[mut Node]) {
    count :: count_of(node)
    end : usize = NODE_SIZE
    // The last value moved: its offset, and its item, for values at the same offset (empty ones)
    above_offset : usize = NODE_SIZE + 1
    above_index : usize = count
    for moved in 0..<count {
        // The value not yet moved that's highest in the node, by its offset, then its item
        best := count
        best_offset : usize = 0
        for i in 0..<count {
            offset :: cast[usize](cast[u16](item_at(node, i).value_offset))
            unmoved :: offset < above_offset || (offset == above_offset && i < above_index)
            if unmoved && (best == count || offset > best_offset || (offset == best_offset && i > best)) {
                best = i
                best_offset = offset
            }
        }
        if best == count {
            break
        }
        value :: value_of(node, best)
        length :: value.count
        to :: end - length
        // Up, never down: from its last byte, as the two may overlap
        with {
            j := length
        }
        loop {
            if j == 0 {
                break
            }
            j -= 1
            if to + j < node.bytes.count && best_offset + j < node.bytes.count {
                node.bytes[to + j] = node.bytes[best_offset + j]
            }
        }
        item_at(node, best).value_offset = cast[u16le](cast[u16](to))
        end = to
        above_offset = best_offset
        above_index = best
    }
    header_of(node).values_start = cast[u16le](cast[u16](end))
}

/**
 * Put a key and value in a leaf, compacting it first if it has to.
 *
 * @param node The leaf, which has to have room for them once it's compacted, and fewer than LEAF_CAPACITY items.
 * @param index Where the item goes, keeping the keys in order: 0 to the leaf's count.
 * @param key The key, which isn't in the leaf.
 * @param value The value, at most MAX_VALUE_BYTES, copied.
 */
leaf_insert :: fn(node: ptr[mut Node], index: usize, key: Key, value: u8[]) {
    if leaf_room(node) < ITEM_SIZE + value.count {
        leaf_compact(node)
    }
    count :: count_of(node)
    with {
        i := count
    }
    loop {
        item_at(node, i)^ = item_at(node, i - 1)^
        i -= 1
    }
    while i > index
    start :: values_start(node) - value.count
    copy_bytes(node.bytes, start, value)
    header_of(node).values_start = cast[u16le](cast[u16](start))
    item_at(node, index)^ = LeafItem.{key = disk_key_of(key), value_offset = cast[u16le](cast[u16](start)),
        value_bytes = cast[u16le](cast[u16](value.count))}
    set_count(node, count + 1)
}

/**
 * Take a leaf's item out, its value left as a hole until it's compacted.
 *
 * @param node The leaf, with at least one item.
 * @param index The item's index, below the leaf's count.
 */
leaf_remove :: fn(node: ptr[mut Node], index: usize) {
    count :: count_of(node)
    for i in index..<count - 1 {
        item_at(node, i)^ = item_at(node, i + 1)^
    }
    set_count(node, count - 1)
    if count == 1 {
        header_of(node).values_start = cast[u16le](cast[u16](NODE_SIZE))
    }
}

/**
 * Put an entry in a branch.
 *
 * @param node The branch, with fewer than BRANCH_CAPACITY entries.
 * @param index Where it goes, keeping the keys in order: 0 to the branch's count.
 * @param key The least key the child holds; not used for the first entry.
 * @param child Where the child is.
 */
branch_insert :: fn(node: ptr[mut Node], index: usize, key: Key, child: BlockPointer) {
    count :: count_of(node)
    with {
        i := count
    }
    loop {
        entry_at(node, i)^ = entry_at(node, i - 1)^
        i -= 1
    }
    while i > index
    entry_at(node, index)^ = BranchEntry.{key = disk_key_of(key), child = child}
    set_count(node, count + 1)
}

/**
 * Take an entry out of a branch, the child it names left alone.
 *
 * @param node The branch, with at least one entry.
 * @param index The entry's index, below the branch's count.
 */
branch_remove :: fn(node: ptr[mut Node], index: usize) {
    count :: count_of(node)
    for i in index..<count - 1 {
        entry_at(node, i)^ = entry_at(node, i + 1)^
    }
    set_count(node, count - 1)
}

/*
 * A node's level where it's reached: a root's at most MAX_LEVEL, and a child's one below its parent's, so a tree read
 * from the disk can't lead back up into itself, however its seals were made.
 */
/** The level given for a root, which has no parent. */
NO_PARENT : u16 : 0xffff
/** The highest level a root may be at, far more than a tree of a container's size needs. */
MAX_LEVEL : u16 : 16

/**
 * Tell whether a node's level fits where it's reached.
 *
 * @param node The node as reached, read or dirty.
 * @param above Its parent's level, or NO_PARENT for a root.
 * @return True if a root's is at most MAX_LEVEL, or a child's is one below its parent's.
 */
level_fits :: fn(node: ptr[mut Node], above: u16) -> bool {
    level :: level_of(node)
    return if above == NO_PARENT { level <= MAX_LEVEL } else { level + 1 == above }
}

/** A node split in two: the right half's first key and where it is. */
Split :: struct {
    /** The right half's first key, its entry's key in the parent. */
    key : Key,
    /** Where the right half is, a new dirty node. */
    pointer : BlockPointer,
}

/**
 * Split a leaf too full for a key and value: its items and the new one, in order, the first half of their bytes left
 * in it and the rest in a new leaf.
 *
 * @param nodes The transaction's nodes, whose space the new leaf's blocks come from and whose dirty set keeps it.
 * @param tree The tree the leaf is in, whose owner the new leaf is charged to.
 * @param node The leaf, dirty; it keeps its address.
 * @param index Where the new item goes among the leaf's.
 * @param key The new item's key.
 * @param value The new item's value.
 * @return The new right leaf's first key and pointer, for the parent to take.
 * @error OutOfMemory No memory for the copy or the new leaf; the leaf is unchanged.
 * @error NoSpace No free extent for the new leaf; the leaf is unchanged.
 */
split_leaf :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], node: ptr[mut Node], index: usize, key: Key, value: u8[]) -> Result[Split, Error] {
    // Its memory first, so nothing's changed without it
    old :: make(Node)?
    defer runtime.free(old)
    right :: new_node(nodes, tree, 0)?
    old^ = node^
    count :: count_of(old)
    total := leaf_used(old) + ITEM_SIZE + value.count
    start_node(node, tree, 0, nodes.transaction, cast[u64](header_of(old).address))
    node.copy = old.copy
    node.dirty = true
    left_bytes : usize = 0
    for j in 0..<count + 1 {
        item_key_now := key
        item_value := value
        if j < index {
            item_key_now = item_key(old, j)
            item_value = value_of(old, j)
        }
        else if j > index {
            item_key_now = item_key(old, j - 1)
            item_value = value_of(old, j - 1)
        }
        // The left keeps at least one, and the right gets at least one
        to_left :: j == 0 || (left_bytes * 2 < total && j < count)
        target :: if to_left { node } else { right.node }
        leaf_insert(target, count_of(target), item_key_now, item_value)
        if to_left {
            left_bytes += ITEM_SIZE + item_value.count
        }
    }
    return .Ok(Split.{key = item_key(right.node, 0), pointer = right.pointer})
}

/**
 * Split a full branch for a new entry: half its entries, with the new one where it goes, moved to a new branch.
 *
 * @param nodes The transaction's nodes, whose space the new branch's blocks come from and whose dirty set keeps
 *     it.
 * @param tree The tree the branch is in, whose owner the new branch is charged to.
 * @param node The branch, dirty and full.
 * @param index Where the new entry goes among the branch's.
 * @param key The new entry's key.
 * @param child The new entry's child.
 * @return The new right branch's first key and pointer, for the parent to take.
 * @error OutOfMemory No memory for the new branch; the branch is unchanged.
 * @error NoSpace No free extent for the new branch; the branch is unchanged.
 */
split_branch :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], node: ptr[mut Node], index: usize, key: Key, child: BlockPointer) -> Result[Split, Error] {
    right :: new_node(nodes, tree, level_of(node))?
    count :: count_of(node)
    half :: (count + 1) / 2
    // The entries from half on, moved, and then the new one into whichever side it's in
    for j in half..<count {
        branch_insert(right.node, j - half, entry_key(node, j), entry_at(node, j).child)
    }
    set_count(node, half)
    if index <= half {
        branch_insert(node, index, key, child)
    }
    else {
        branch_insert(right.node, index - half, key, child)
    }
    return .Ok(Split.{key = entry_key(right.node, 0), pointer = right.pointer})
}

/**
 * Put a key's value in a tree, replacing what was there.
 *
 * The nodes on the way are made writable, copied in this transaction; nothing is written to the device until
 * tree_write. A split that fails for want of memory or space leaves the key's old value taken out.
 *
 * @param nodes The transaction's nodes: those on the key's path are made dirty, copied into their dirty set, with
 *     blocks from their space and the old ones released.
 * @param tree The tree; its root changes when it's copied, made or split.
 * @param key The record's key; a record already there is replaced.
 * @param value The value, at most MAX_VALUE_BYTES, copied.
 * @error TooLarge The value is longer than MAX_VALUE_BYTES; nothing changed.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_put :: fn(nodes: ptr[mut Nodes], tree: ptr[mut Tree], key: Key, value: u8[]) -> Result[void, Error] {
    if cast[u64](value.count) > MAX_VALUE_BYTES {
        return .Error(.TooLarge)
    }
    if cast[u64](tree.root.address) == 0 {
        made :: new_node(nodes, tree, 0)?
        tree.root = made.pointer
    }
    split :: put_into(nodes, tree, &tree.root, NO_PARENT, key, value)?
    match split {
        case Some(halves) => {
            old_root :: load(nodes, tree, &tree.root)?
            level :: level_of(old_root) + 1
            root :: new_node(nodes, tree, level)?
            branch_insert(root.node, 0, Key.{}, tree.root)
            branch_insert(root.node, 1, halves.key, halves.pointer)
            tree.root = root.pointer
        }
        case None => {}
    }
    return .Ok
}

/**
 * Put a key's value beneath a node, splitting what's too full on the way back up.
 *
 * @param nodes The transaction's nodes: those on the key's path are made dirty, copied into their dirty set, with
 *     blocks from their space and the old ones released.
 * @param tree The tree the node is in.
 * @param pointer The node's pointer, changed if it's copied.
 * @param above Its parent's level, or NO_PARENT for the root.
 * @param key The key the value goes under, followed down through the branches; a record already there is replaced.
 * @param value The record's value, at most MAX_VALUE_BYTES, copied.
 * @return The node's right half, if it was split, for its parent to take; null if it wasn't.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
put_into :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[mut BlockPointer], above: u16, key: Key, value: u8[]) -> Result[Split?, Error] {
    node :: writable(nodes, tree, pointer)?
    if !level_fits(node, above) {
        return .Error(.Corrupt)
    }
    if level_of(node) == 0 {
        index, found :: leaf_find(node, key)
        /*
         * The key's old value, copied aside before it's taken out, so a split that fails (no memory, no space) puts it
         * back, and a failed put changes nothing the next commit would write
         */
        old : u8[]
        if found {
            kept, error :: runtime.new_array(u8, value_of(node, index).count)
            if error != null {
                return .Error(.OutOfMemory)
            }
            for byte, i in value_of(node, index) {
                if i < kept.count {
                    kept[i] = byte
                }
            }
            old = kept
            leaf_remove(node, index)
        }
        defer runtime.free_array(old)
        if leaf_used(node) + ITEM_SIZE + value.count <= NODE_SIZE - HEADER_SIZE && count_of(node) < LEAF_CAPACITY {
            leaf_insert(node, index, key, value)
            return .Ok(null)
        }
        match split_leaf(nodes, tree, node, index, key, value) {
            case Ok(split) => return .Ok(split)
            case Error(error) => {
                // Back as it was: it fit before it was taken out
                if found {
                    leaf_insert(node, index, key, old)
                }
                return .Error(error)
            }
        }
    }
    index :: branch_find(node, key)
    split :: put_into(nodes, tree, &entry_at(node, index).child, level_of(node), key, value)?
    match split {
        case Some(halves) => {
            if count_of(node) < BRANCH_CAPACITY {
                branch_insert(node, index + 1, halves.key, halves.pointer)
                return .Ok(null)
            }
            return .Ok(split_branch(nodes, tree, node, index + 1, halves.key, halves.pointer)?)
        }
        case None => return .Ok(null)
    }
}

/**
 * Make the path to the leaf holding a key writable, if that leaf was sealed with a generation before a floor, so the
 * next commit seals it again, and every branch above it, with the current one (decisions/0181's F5).
 *
 * Found by reading first, so a leaf already sealed again, or written in this transaction, costs nothing. A branch
 * sealed before the floor has only leaves sealed before it beneath it, since a child written since would have had its
 * branch written too, so touching every such leaf seals every such branch again.
 *
 * @param nodes The transaction's nodes: those on the key's path are made dirty, copied into their dirty set, with
 *     blocks from their space and the old ones released, when the leaf is older than floor.
 * @param tree The tree; its root changes when it's copied.
 * @param key A key, followed down through the branches to its leaf, whether or not a record of it is there.
 * @param floor The generation the leaf has to be sealed with, or a later one.
 * @return True if the path was made writable; false if the leaf was sealed with floor or later, is new in this
 *     transaction, or the tree is empty.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_touch_older :: fn(nodes: ptr[mut Nodes], tree: ptr[mut Tree], key: Key, floor: u32) -> Result[bool, Error] {
    if cast[u64](tree.root.address) == 0 {
        return .Ok(false)
    }
    leaf :: leaf_pointer(nodes, tree, &tree.root, NO_PARENT, key)?
    if cast[u32](leaf.generation) >= floor || cast[u64](leaf.birth) == nodes.transaction {
        return .Ok(false)
    }
    touch_into(nodes, tree, &tree.root, NO_PARENT, key)?
    return .Ok(true)
}

/**
 * Find the pointer of the leaf a key leads to, only reading.
 *
 * @param nodes The transaction's nodes, only read.
 * @param tree The tree the node is in.
 * @param pointer The node's pointer.
 * @param above Its parent's level, or NO_PARENT for the root.
 * @param key The key followed down through the branches.
 * @return The leaf's pointer, a copy.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
leaf_pointer :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[BlockPointer], above: u16, key: Key) -> Result[BlockPointer, Error] {
    node :: load(nodes, tree, pointer)?
    if !level_fits(node, above) {
        done(node)
        return .Error(.Corrupt)
    }
    level :: level_of(node)
    if level == 0 {
        done(node)
        return .Ok(pointer^)
    }
    child := entry_at(node, branch_find(node, key)).child
    done(node)
    return leaf_pointer(nodes, tree, &child, level, key)
}

/**
 * Make every node on the path to the leaf a key leads to writable, changing nothing in them.
 *
 * @param nodes The transaction's nodes: those on the path are made dirty, copied into their dirty set.
 * @param tree The tree the node is in.
 * @param pointer The node's pointer, changed if it's copied.
 * @param above Its parent's level, or NO_PARENT for the root.
 * @param key The key followed down through the branches.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
touch_into :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[mut BlockPointer], above: u16, key: Key) -> Result[void, Error] {
    node :: writable(nodes, tree, pointer)?
    if !level_fits(node, above) {
        return .Error(.Corrupt)
    }
    if level_of(node) == 0 {
        return .Ok
    }
    return touch_into(nodes, tree, &entry_at(node, branch_find(node, key)).child, level_of(node), key)
}

/**
 * Take a key out of a tree.
 *
 * Nodes left empty are dropped, a node left less than a quarter full is merged into its neighbour where both fit,
 * and a branch root left with one child gives way to it.
 *
 * @param nodes The transaction's nodes: those on the key's path are made dirty, copied into their dirty set, and
 *     nodes dropped or merged away are taken out of it, their blocks released to their space.
 * @param tree The tree; its root changes when it's copied or replaced.
 * @param key The record's key; one that isn't there changes nothing.
 * @return True if it was there and is taken out; false if it wasn't, nothing changed.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_delete :: fn(nodes: ptr[mut Nodes], tree: ptr[mut Tree], key: Key) -> Result[bool, Error] {
    if cast[u64](tree.root.address) == 0 || !(tree_has(nodes, tree, key)?) {
        return .Ok(false)
    }
    delete_from(nodes, tree, &tree.root, NO_PARENT, key)?
    /*
     * A branch root left with one child gives way to it, and one left with none to an empty leaf. A leaf root that's
     * emptied stays, so a tree that empties and fills in one commit, as the space map can, doesn't churn its root.
     */
    root :: load(nodes, tree, &tree.root)?
    if level_of(root) > 0 && count_of(root) == 0 {
        // The new leaf made first, so a failure to make it leaves the root as it was, not discarded
        leaf :: new_node(nodes, tree, 0)?
        discard(nodes, tree, &tree.root)
        tree.root = leaf.pointer
    }
    else if level_of(root) > 0 && count_of(root) == 1 {
        child :: entry_at(root, 0).child
        discard(nodes, tree, &tree.root)
        tree.root = child
    }
    return .Ok(true)
}

/**
 * Take a key out from beneath a node, dropping children left empty and merging those left less than a quarter full.
 *
 * @param nodes The transaction's nodes: those on the key's path are made dirty, copied into their dirty set, and
 *     nodes dropped or merged away are taken out of it, their blocks released to their space.
 * @param tree The tree the node is in.
 * @param pointer The node's pointer, changed if it's copied.
 * @param above Its parent's level, or NO_PARENT for the root.
 * @param key The key; not being there is no error.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
delete_from :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[mut BlockPointer], above: u16, key: Key) -> Result[void, Error] {
    node :: writable(nodes, tree, pointer)?
    if !level_fits(node, above) {
        return .Error(.Corrupt)
    }
    if level_of(node) == 0 {
        index, found :: leaf_find(node, key)
        if found {
            leaf_remove(node, index)
        }
        return .Ok
    }
    index :: branch_find(node, key)
    delete_from(nodes, tree, &entry_at(node, index).child, level_of(node), key)?
    child :: load(nodes, tree, &entry_at(node, index).child)?
    if count_of(child) == 0 {
        discard(nodes, tree, &entry_at(node, index).child)
        branch_remove(node, index)
        return .Ok
    }
    if node_used(child) * 4 < NODE_SIZE - HEADER_SIZE && count_of(node) > 1 {
        neighbour :: if index + 1 < count_of(node) { index + 1 } else { index - 1 }
        merge(nodes, tree, node, if neighbour > index { index } else { neighbour })?
    }
    return .Ok
}

/**
 * Get what a node's contents take.
 *
 * @param node The node, in memory, read or dirty.
 * @return The bytes its items and values (a leaf) or entries (a branch) take, not counting the header.
 */
node_used :: fn(node: ptr[mut Node]) -> usize {
    return if level_of(node) == 0 { leaf_used(node) } else { count_of(node) * ENTRY_SIZE }
}

/**
 * Merge two neighbouring children of a branch into the left one, where both fit in one node; otherwise leave them.
 *
 * @param nodes The transaction's nodes: both children are made dirty, copied into their dirty set, even when they
 *     don't fit together; a right child merged away is taken out of it and its blocks released to their space.
 * @param tree The tree the children are in.
 * @param parent The branch, dirty.
 * @param left The left child's index; the right is the one after it, and nothing's done if there's none.
 * @error OutOfMemory No memory for a child's copy.
 * @error NoSpace No free extent for a child's copy.
 * @error Corrupt A child couldn't be read, didn't check out, or is at the wrong level.
 */
merge :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], parent: ptr[mut Node], left: usize) -> Result[void, Error] {
    right_index :: left + 1
    if right_index >= count_of(parent) {
        return .Ok
    }
    left_node :: writable(nodes, tree, &entry_at(parent, left).child)?
    right_node :: writable(nodes, tree, &entry_at(parent, right_index).child)?
    if !level_fits(left_node, level_of(parent)) || !level_fits(right_node, level_of(parent)) {
        return .Error(.Corrupt)
    }
    if level_of(left_node) == 0 {
        if leaf_used(left_node) + leaf_used(right_node) > NODE_SIZE - HEADER_SIZE
            || count_of(left_node) + count_of(right_node) > LEAF_CAPACITY {
            return .Ok
        }
        for i in 0..<count_of(right_node) {
            leaf_insert(left_node, count_of(left_node), item_key(right_node, i), value_of(right_node, i))
        }
    }
    else {
        if count_of(left_node) + count_of(right_node) > BRANCH_CAPACITY {
            return .Ok
        }
        // The right's first entry takes the separator, since its own key isn't used
        separator :: entry_key(parent, right_index)
        for i in 0..<count_of(right_node) {
            key :: if i == 0 { separator } else { entry_key(right_node, i) }
            branch_insert(left_node, count_of(left_node), key, entry_at(right_node, i).child)
        }
    }
    discard(nodes, tree, &entry_at(parent, right_index).child)
    branch_remove(parent, right_index)
    return .Ok
}

/**
 * Tell whether a key is in a tree.
 *
 * @param nodes The transaction's nodes, only read: this transaction's dirty nodes are seen, others read from the
 *     device.
 * @param tree The tree, its root as this transaction has it.
 * @param key The key looked for, matched exactly: object, kind and offset.
 * @return True if it is.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_has :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key) -> Result[bool, Error] {
    scratch : u8[1]
    return .Ok(tree_get(nodes, tree, key, scratch)? is_some)
}

/**
 * Get a key's value from a tree. Reading walks down from the root a node at a time, and changes nothing.
 *
 * @param nodes The transaction's nodes, only read: this transaction's dirty nodes are seen, others read from the
 *     device.
 * @param tree The tree, its root as this transaction has it.
 * @param key The key looked for, matched exactly: object, kind and offset.
 * @param into Where the value is copied, as much as fits; the rest of it is left as it was.
 * @return The value's whole length in bytes, which may be more than into holds; null if the key isn't there.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_get :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key, into: mut u8[]) -> Result[usize?, Error] {
    if cast[u64](tree.root.address) == 0 {
        return .Ok(null)
    }
    pointer := tree.root
    above := NO_PARENT
    loop {
        node :: load(nodes, tree, &pointer)?
        if !level_fits(node, above) {
            done(node)
            return .Error(.Corrupt)
        }
        above = level_of(node)
        if level_of(node) == 0 {
            index, found :: leaf_find(node, key)
            if !found {
                done(node)
                return .Ok(null)
            }
            value :: value_of(node, index)
            copy_bytes(into, 0, value)
            length :: value.count
            done(node)
            return .Ok(length)
        }
        pointer = entry_at(node, branch_find(node, key)).child
        done(node)
    }
}

/** A record found by a search: its key and its value's length, the value copied as far as it fits. */
Found :: struct {
    /** The record's key. */
    key : Key,
    /** The value's whole length in bytes, which may be more than was copied. */
    bytes : usize,
}

/**
 * Find the first record in a tree whose key is at least a key.
 *
 * @param nodes The transaction's nodes, only read: this transaction's dirty nodes are seen, others read from the
 *     device.
 * @param tree The tree, its root as this transaction has it.
 * @param key The least key the record may have.
 * @param into Where its value is copied, as much as fits.
 * @return The record found; null if there's none at or after the key.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_next :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key, into: mut u8[]) -> Result[Found?, Error] {
    if cast[u64](tree.root.address) == 0 {
        return .Ok(null)
    }
    return next_in(nodes, tree, &tree.root, NO_PARENT, key, into)
}

/**
 * Find the first record beneath a node whose key is at least a key.
 *
 * @param nodes The transaction's nodes, only read: this transaction's dirty nodes are seen, others read from the
 *     device.
 * @param tree The tree the node is in.
 * @param pointer Where the node is, as its parent or the tree's root has it; only read, never changed.
 * @param above Its parent's level, or NO_PARENT for the root.
 * @param key The least key the record may have.
 * @param into Where its value is copied, as much as fits.
 * @return The record found; null if there's none beneath the node.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
next_in :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[BlockPointer], above: u16, key: Key, into: mut u8[]) -> Result[Found?, Error] {
    node :: load(nodes, tree, pointer)?
    defer done(node)
    if !level_fits(node, above) {
        return .Error(.Corrupt)
    }
    if level_of(node) == 0 {
        index, found :: leaf_find(node, key)
        if index >= count_of(node) {
            return .Ok(null)
        }
        value :: value_of(node, index)
        copy_bytes(into, 0, value)
        return .Ok(Found.{key = item_key(node, index), bytes = value.count})
    }
    for i in branch_find(node, key)..<count_of(node) {
        child :: entry_at(node, i).child
        next :: next_in(nodes, tree, &child, level_of(node), key, into)?
        match next {
            case Some(record) => return .Ok(record)
            case None => {}
        }
    }
    return .Ok(null)
}

/**
 * Find the last record in a tree whose key is at most a key.
 *
 * @param nodes The transaction's nodes, only read: this transaction's dirty nodes are seen, others read from the
 *     device.
 * @param tree The tree, its root as this transaction has it.
 * @param key The greatest key the record may have.
 * @param into Where its value is copied, as much as fits.
 * @return The record found; null if there's none at or before the key.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
tree_previous :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key, into: mut u8[]) -> Result[Found?, Error] {
    if cast[u64](tree.root.address) == 0 {
        return .Ok(null)
    }
    return previous_in(nodes, tree, &tree.root, NO_PARENT, key, into)
}

/**
 * Find the last record beneath a node whose key is at most a key.
 *
 * @param nodes The transaction's nodes, only read: this transaction's dirty nodes are seen, others read from the
 *     device.
 * @param tree The tree the node is in.
 * @param pointer Where the node is, as its parent or the tree's root has it; only read, never changed.
 * @param above Its parent's level, or NO_PARENT for the root.
 * @param key The greatest key the record may have.
 * @param into Where its value is copied, as much as fits.
 * @return The record found; null if there's none beneath the node.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read, didn't check out, or is at the wrong level.
 */
previous_in :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[BlockPointer], above: u16, key: Key, into: mut u8[]) -> Result[Found?, Error] {
    node :: load(nodes, tree, pointer)?
    defer done(node)
    if !level_fits(node, above) {
        return .Error(.Corrupt)
    }
    if level_of(node) == 0 {
        index, found :: leaf_find(node, key)
        at := index
        if !found {
            if index == 0 {
                return .Ok(null)
            }
            at = index - 1
        }
        value :: value_of(node, at)
        copy_bytes(into, 0, value)
        return .Ok(Found.{key = item_key(node, at), bytes = value.count})
    }
    with {
        i := branch_find(node, key) + 1
    }
    loop {
        i -= 1
        child :: entry_at(node, i).child
        previous :: previous_in(nodes, tree, &child, level_of(node), key, into)?
        match previous {
            case Some(record) => return .Ok(record)
            case None => {}
        }
    }
    while i > 0
    return .Ok(null)
}

/**
 * Write a tree's dirty nodes, children first, each parent's pointer taking its child's seal, and the root's pointer
 * last.
 *
 * Writing allocates nothing, so it comes after everything else in a commit has changed what it will. Nothing is
 * flushed: what's written isn't durable until the commit's flush. Nodes written are freed, so a failure partway
 * leaves the rest dirty.
 *
 * @param nodes The transaction's nodes: the tree's dirty ones are written to their device and taken out of their
 *     dirty set and freed; a root not born in this transaction means nothing to write.
 * @param tree The tree; its root's seal is set.
 * @error DeviceError A node couldn't be written.
 * @error OutOfMemory No memory to seal an encrypted node in.
 * @error Corrupt An encrypted node couldn't be sealed.
 */
tree_write :: fn(nodes: ptr[mut Nodes], tree: ptr[mut Tree]) -> Result[void, Error] {
    if cast[u64](tree.root.address) == 0 || cast[u64](tree.root.birth) != nodes.transaction {
        return .Ok
    }
    return write_node(nodes, tree, &tree.root)
}

/**
 * Write a dirty node and its dirty children, children first, and free it.
 *
 * @param nodes The transaction's nodes: the node and its children born in this transaction are written to their
 *     device, then taken out of their dirty set and freed.
 * @param tree The tree the node is in, whose keys, if any, seal it.
 * @param pointer The node's pointer, which takes its seal (and on an encrypted tree, its generation); a node that
 *     isn't dirty is left alone.
 * @error DeviceError A node couldn't be written.
 * @error OutOfMemory No memory to seal an encrypted node in.
 * @error Corrupt An encrypted node couldn't be sealed.
 */
write_node :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[mut BlockPointer]) -> Result[void, Error] {
    address :: cast[u64](pointer.address)
    node :: maps.map_get(&nodes.dirty, address) or_return .Ok
    if level_of(node) > 0 {
        for i in 0..<count_of(node) {
            entry :: entry_at(node, i)
            if cast[u64](entry.child.birth) == nodes.transaction {
                write_node(nodes, tree, &entry.child)?
            }
        }
    }
    // Encrypted, the sealed bytes are written, and the pointer takes their seal and generation
    match tree.keys {
        case Some(keys) => {
            sealed :: make(Node)?
            defer runtime.free(sealed)
            if !seal_block(keys, tree.owner, pointer, node.bytes, sealed.bytes) {
                return .Error(.Corrupt)
            }
            write_node_bytes(nodes, address, node.copy, sealed.bytes)?
        }
        case None => {
            crypto.blake3(node.bytes, pointer.seal)
            write_node_bytes(nodes, address, node.copy, node.bytes)?
        }
    }
    _ = maps.map_remove(&nodes.dirty, address)
    runtime.free(node)
    return .Ok
}

/**
 * Write a node's bytes to its place, and to its second place unless that's 0.
 *
 * @param nodes The transaction's nodes, used only for their device; nothing is flushed.
 * @param address Its first block.
 * @param copy Its second copy's first block, or 0.
 * @param bytes Its bytes as they go on the device, NODE_SIZE of them.
 * @error DeviceError A copy couldn't be written.
 */
write_node_bytes :: fn(nodes: ptr[mut Nodes], address: u64, copy: u64, bytes: u8[]) -> Result[void, Error] {
    if !nodes.device.write(nodes.device.context, address, NODE_BLOCKS, bytes) {
        return .Error(.DeviceError)
    }
    if copy != 0 && !nodes.device.write(nodes.device.context, copy, NODE_BLOCKS, bytes) {
        return .Error(.DeviceError)
    }
    return .Ok
}
