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

Error :: enum {
    // The device couldn't be read or written
    DeviceError,
    // What was read doesn't check out: a seal, a header or a structure
    Corrupt,
    NoSpace,
    NotFound,
    NotADirectory,
    IsADirectory,
    AlreadyExists,
    DirectoryNotEmpty,
    // Empty, too long, or holding '/' or NUL
    InvalidName,
    // A value, a name list or a file past what's held
    TooLarge,
    // Not a container: no superblock, or no checkpoint that checks out
    NotSlopfs,
    // A write failed: commits are refused until the container is mounted again (design/storage.md §4)
    Failed,
    // An encrypted volume, opened without its keys (keys.hsc)
    Locked,
    // A passphrase that doesn't unwrap the volume's key
    WrongKey,
    // A snapshot a clone was made from, which can't be deleted while it's there (snapshot.hsc)
    InUse,
    // A stored link, where a file or a directory was needed (links.hsc)
    IsALink,
    // No memory for a node or a buffer (decisions/0104): nothing was changed for want of it
    OutOfMemory,
}

/*
 * A new T, or OutOfMemory: every node and buffer slopfs takes comes from here (decisions/0104), each taken before
 * what it's for changes anything, so a caller can fail without it and nothing is left half done.
 */
make :: fn[T](T: type, location := #caller_location) -> Result[ptr[mut T], Error] {
    made, error :: runtime.new_aligned(T, align_of(T), context.allocator, location)
    if error != null {
        return .Error(.OutOfMemory)
    }
    return .Ok(made)
}

/*
 * A device of 4 KiB blocks: count of them from block into into, or from from, and making what's written durable. Its
 * context is memory that outlives it, not the stack, so the nodes and containers that hold it can be pointed to.
 */
Device :: struct {
    context : rawptr,
    block_count : u64,
    read : fn(context: rawptr, block: u64, count: u64, into: mut u8[]) -> bool,
    write : fn(context: rawptr, block: u64, count: u64, from: u8[]) -> bool,
    flush : fn(context: rawptr) -> bool,
}

// A key in memory.
Key :: struct {
    object : u64,
    kind : u8,
    offset : u64,
}

key_of :: fn(object: u64, kind: RecordKind, offset: u64) -> Key {
    return Key.{object = object, kind = cast[u8](kind), offset = offset}
}

// Below 0, a is before b; above, after; 0, they're the same.
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

// The key just after key, for walking records in order, or null after the last there can be.
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

disk_key_of :: fn(key: Key) -> DiskKey {
    return DiskKey.{object = cast[u64le](key.object), kind = key.kind, offset = cast[u64le](key.offset)}
}

memory_key_of :: fn(key: ptr[DiskKey]) -> Key {
    return Key.{object = cast[u64](key.object), kind = key.kind, offset = cast[u64](key.offset)}
}

NODE_SIZE :: 16384
HEADER_SIZE :: 64
ITEM_SIZE :: 32
ENTRY_SIZE :: 88
// A branch's entries at most, and a leaf's items
BRANCH_CAPACITY :: 185
LEAF_CAPACITY :: 510

// A node in memory: dirty, owned by the transaction's set until it's written; or read for a moment, then given back.
Node :: struct {
    bytes : u8[NODE_SIZE],
    copy : u64,
    dirty : bool,
}

/*
 * A tree: its root (address 0 while it's empty), which it is, whose, whether its nodes are written twice, an encrypted
 * volume's keys, which seal its nodes (keys.hsc), or null for a BLAKE3 seal, and for a clone's, who wrote its older
 * blocks.
 */
Tree :: struct {
    root : BlockPointer,
    kind : TreeKind,
    owner : u64,
    ditto : bool,
    keys : ptr[mut Keys]?,
    lineage : Lineage,
}

MAX_LINEAGE :: 4

/*
 * Who wrote a clone's older blocks (snapshot.hsc): its origin, up to the transaction the snapshot it was cloned from
 * holds, and the origin's own origin up to the one before, and so on, nearest first.
 */
Lineage :: struct {
    count : usize,
    owners : u64[MAX_LINEAGE],
    up_to : u64[MAX_LINEAGE],
}

// Whose a tree's block born in birth is: the oldest ancestor whose part holds it, or the tree's own owner's.
owner_at :: fn(tree: ptr[Tree], birth: u64) -> u64 {
    owner := tree.owner
    for i in 0..<tree.lineage.count {
        if i < MAX_LINEAGE && birth <= tree.lineage.up_to[i] {
            owner = tree.lineage.owners[i]
        }
    }
    return owner
}

/*
 * The nodes of one transaction: the device they're on, the dirty ones by address, and where extents come from and go
 * back to: allocate gives count blocks for owner, or null, data saying they're for a file's bytes rather than a tree's
 * nodes, which a quota and the reserve don't hold back (space.hsc); release takes an extent back, born in birth.
 */
Nodes :: struct {
    device : Device,
    transaction : u64,
    dirty : maps.HashMap[u64, ptr[mut Node], maps.hash_integer[u64]],
    space : rawptr,
    allocate : fn(space: rawptr, blocks: u64, owner: u64, data: bool) -> u64?,
    release : fn(space: rawptr, address: u64, blocks: u64, owner: u64, birth: u64),
}

// Fields of a node's bytes.

header_of :: fn(node: ptr[mut Node]) -> ptr[mut NodeHeader] {
    return cast[ptr[mut NodeHeader]](&node.bytes[0])
}

count_of :: fn(node: ptr[mut Node]) -> usize {
    return cast[usize](cast[u16](header_of(node).count))
}

level_of :: fn(node: ptr[mut Node]) -> u16 {
    return cast[u16](header_of(node).level)
}

set_count :: fn(node: ptr[mut Node], count: usize) {
    header_of(node).count = cast[u16le](cast[u16](count))
}

// A leaf's item at index, which its count bounds (checked when it's read).
item_at :: fn(node: ptr[mut Node], index: usize) -> ptr[mut LeafItem] {
    at :: HEADER_SIZE + index * ITEM_SIZE
    if at + ITEM_SIZE <= NODE_SIZE && at < node.bytes.count {
        return cast[ptr[mut LeafItem]](&node.bytes[at])
    }
    return cast[ptr[mut LeafItem]](&node.bytes[HEADER_SIZE])
}

entry_at :: fn(node: ptr[mut Node], index: usize) -> ptr[mut BranchEntry] {
    at :: HEADER_SIZE + index * ENTRY_SIZE
    if at + ENTRY_SIZE <= NODE_SIZE && at < node.bytes.count {
        return cast[ptr[mut BranchEntry]](&node.bytes[at])
    }
    return cast[ptr[mut BranchEntry]](&node.bytes[HEADER_SIZE])
}

item_key :: fn(node: ptr[mut Node], index: usize) -> Key {
    return memory_key_of(&item_at(node, index).key)
}

entry_key :: fn(node: ptr[mut Node], index: usize) -> Key {
    return memory_key_of(&entry_at(node, index).key)
}

// An item's value's bytes, in the node.
value_of :: fn(node: ptr[mut Node], index: usize) -> mut u8[] {
    item :: item_at(node, index)
    start :: cast[usize](cast[u16](item.value_offset))
    count :: cast[usize](cast[u16](item.value_bytes))
    if start >= node.bytes.count || start + count > node.bytes.count {
        return node.bytes[0..<0]
    }
    return view_of(&node.bytes[start], count)
}

values_start :: fn(node: ptr[mut Node]) -> usize {
    return cast[usize](cast[u16](header_of(node).values_start))
}

// A leaf's room between its items and its values.
leaf_room :: fn(node: ptr[mut Node]) -> usize {
    items_end :: HEADER_SIZE + count_of(node) * ITEM_SIZE
    start :: values_start(node)
    return if start > items_end { start - items_end } else { 0 }
}

// What a leaf's items and values take.
leaf_used :: fn(node: ptr[mut Node]) -> usize {
    used := count_of(node) * ITEM_SIZE
    for i in 0..<count_of(node) {
        used += cast[usize](cast[u16](item_at(node, i).value_bytes))
    }
    return used
}

// A node's bytes, starting empty: a header for tree at level, with nothing in it.
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

copy_bytes :: fn(into: mut u8[], at: usize, from: u8[]) {
    for byte, i in from {
        j :: at + i
        if j < into.count {
            into[j] = byte
        }
    }
}

// The node's structure, read from the device: its count within what it can hold, and a leaf's values inside it.
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

/*
 * The node a pointer names: dirty, if this transaction has it; otherwise read, from its first copy or its second,
 * each checked by its seal, its header and its structure. One read is given back with done.
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

// The node at place, into node: as it is, or opened with its tree's keys, which checks its seal.
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

// A node load gave, given back if it was only read.
done :: fn(node: ptr[mut Node]) {
    if !node.dirty {
        runtime.free(node)
    }
}

// Blocks for a node of tree, and a second place for a tree written twice.
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

// A placed node's blocks given back, unused: what place_node gave, when what it was for couldn't be made.
unplace :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: BlockPointer) {
    nodes.release(nodes.space, cast[u64](pointer.address), NODE_BLOCKS, tree.owner, nodes.transaction)
    if cast[u64](pointer.copy) != 0 {
        nodes.release(nodes.space, cast[u64](pointer.copy), NODE_BLOCKS, tree.owner, nodes.transaction)
    }
}

// A node and where it is.
Placed :: struct {
    node : ptr[mut Node],
    pointer : BlockPointer,
}

// A new, empty, dirty node of tree at level.
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

/*
 * The node pointer names, made writable in this transaction: dirty already, or copied to a new place, the old one
 * given back as of the transaction it was born in, and pointer changed to the copy (its seal is set when it's written).
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

// A dirty node taken out of the tree: forgotten, and its blocks given back.
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

// Where key is in a leaf, or would go, and whether it's there.
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

// The child of a branch key would be under: the last entry whose key is at most it, the first otherwise.
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

/*
 * A leaf's values packed at its end again, without the holes removals left, in place: each moved up in turn, the
 * highest first, so none is written over before it's moved, and nothing needs memory of its own (decisions/0104).
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

// A key and value put in a leaf at index, which has room for them once it's compacted.
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

// A leaf's item at index taken out, its value left as a hole until it's compacted.
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

// A branch's entry put at index.
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
NO_PARENT : u16 : 0xffff
MAX_LEVEL : u16 : 16

level_fits :: fn(node: ptr[mut Node], above: u16) -> bool {
    level :: level_of(node)
    return if above == NO_PARENT { level <= MAX_LEVEL } else { level + 1 == above }
}

// A node split in two: the right half's first key and where it is.
Split :: struct {
    key : Key,
    pointer : BlockPointer,
}

/*
 * A leaf too full for key and value, split: its items and the new one, in order, the first half of their bytes left
 * in it and the rest in a new leaf.
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

// A full branch split for an entry at index: half its entries, with the new one, moved to a new branch.
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

// key's value put in the tree, replacing what was there.
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

put_into :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], pointer: ptr[mut BlockPointer], above: u16, key: Key, value: u8[]) -> Result[Split?, Error] {
    node :: writable(nodes, tree, pointer)?
    if !level_fits(node, above) {
        return .Error(.Corrupt)
    }
    if level_of(node) == 0 {
        index, found :: leaf_find(node, key)
        if found {
            leaf_remove(node, index)
        }
        if leaf_used(node) + ITEM_SIZE + value.count <= NODE_SIZE - HEADER_SIZE && count_of(node) < LEAF_CAPACITY {
            leaf_insert(node, index, key, value)
            return .Ok(null)
        }
        return .Ok(split_leaf(nodes, tree, node, index, key, value)?)
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

// key taken out of the tree, and whether it was there.
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
        discard(nodes, tree, &tree.root)
        leaf :: new_node(nodes, tree, 0)?
        tree.root = leaf.pointer
    }
    else if level_of(root) > 0 && count_of(root) == 1 {
        child :: entry_at(root, 0).child
        discard(nodes, tree, &tree.root)
        tree.root = child
    }
    return .Ok(true)
}

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

node_used :: fn(node: ptr[mut Node]) -> usize {
    return if level_of(node) == 0 { leaf_used(node) } else { count_of(node) * ENTRY_SIZE }
}

// A branch's children at left and left + 1 made one, where both fit in one node.
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

// Whether key is in the tree.
tree_has :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key) -> Result[bool, Error] {
    scratch : u8[1]
    return .Ok(tree_get(nodes, tree, key, scratch)? is_some)
}

/*
 * key's value copied into into, as much as fits, and its length, or null if it isn't there. Reading walks down from
 * the root a node at a time.
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

// A record found by a search: its key and its value's length, the value copied as far as it fits.
Found :: struct {
    key : Key,
    bytes : usize,
}

// The first record whose key is at least key, or null.
tree_next :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key, into: mut u8[]) -> Result[Found?, Error] {
    if cast[u64](tree.root.address) == 0 {
        return .Ok(null)
    }
    return next_in(nodes, tree, &tree.root, NO_PARENT, key, into)
}

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

// The last record whose key is at most key, or null.
tree_previous :: fn(nodes: ptr[mut Nodes], tree: ptr[Tree], key: Key, into: mut u8[]) -> Result[Found?, Error] {
    if cast[u64](tree.root.address) == 0 {
        return .Ok(null)
    }
    return previous_in(nodes, tree, &tree.root, NO_PARENT, key, into)
}

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

/*
 * A tree's dirty nodes written, children first, each parent's pointer taking its child's seal, and the root's
 * pointer last. Writing allocates nothing, so it comes after everything else in a commit has changed what it will.
 */
tree_write :: fn(nodes: ptr[mut Nodes], tree: ptr[mut Tree]) -> Result[void, Error] {
    if cast[u64](tree.root.address) == 0 || cast[u64](tree.root.birth) != nodes.transaction {
        return .Ok
    }
    return write_node(nodes, tree, &tree.root)
}

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

// A node's bytes written at address, and at copy, its second place, unless that's 0.
write_node_bytes :: fn(nodes: ptr[mut Nodes], address: u64, copy: u64, bytes: u8[]) -> Result[void, Error] {
    if !nodes.device.write(nodes.device.context, address, NODE_BLOCKS, bytes) {
        return .Error(.DeviceError)
    }
    if copy != 0 && !nodes.device.write(nodes.device.context, copy, NODE_BLOCKS, bytes) {
        return .Error(.DeviceError)
    }
    return .Ok
}
