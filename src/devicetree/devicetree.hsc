/**
 * A reader for the flattened device tree (the DTB a bootloader passes), enough to find devices by their
 * compatible strings and read their reg and interrupts properties.
 *
 * It reads the blob where it is, through the direct map, and allocates nothing, so the arch layer can use it before
 * there's a heap. Every address it takes or gives is a virtual address the blob is mapped at.
 *
 * SPEC: Devicetree Specification 0.4, chapter 5 (the flattened format), §2.3 (#address-cells, #size-cells, reg,
 * compatible).
 */
package devicetree


/** The header's magic, its first big-endian word (Devicetree Specification §5.2). */
FDT_MAGIC : u32 : 0xd00dfeed
/** FDT_BEGIN_NODE: a node starts, followed by its NUL-terminated name, padded to 4 bytes (§5.4.1). */
TOKEN_BEGIN_NODE : u32 : 1
/** FDT_END_NODE: the node begun last ends (§5.4.1). */
TOKEN_END_NODE : u32 : 2
/** FDT_PROP: a property, followed by its value's length and its name's offset in the strings block (§5.4.1). */
TOKEN_PROPERTY : u32 : 3
/** FDT_NOP: nothing, to be skipped (§5.4.1). */
TOKEN_NOP : u32 : 4
/** FDT_END: the structure block ends (§5.4.1). */
TOKEN_END : u32 : 9
/** How deep nodes nest, at most, for the cells each level gives its children; a deeper tree isn't read past it. */
MAX_DEPTH :: 16

/** A tree in memory: its first byte's address, and where its structure and strings blocks are. */
Tree :: struct {
    /** The virtual address of the blob's header. */
    address : u64,
    /** The whole blob's size in bytes, from the header's totalsize. */
    size : u64,
    /** The virtual address of the structure block. */
    structure : u64,
    /** The structure block's size in bytes. */
    structure_size : u64,
    /** The virtual address of the strings block. */
    strings : u64,
    /** The strings block's size in bytes. */
    strings_size : u64,
}

/** A node: where its structure starts, at its name, and the cells its parent gives reg. */
Node :: struct {
    /** The byte offset of the node's name in the structure block, just after its FDT_BEGIN_NODE token. */
    offset : u64,
    /** The parent's #address-cells: how many 32-bit cells an address in this node's reg takes, 2 by default. */
    address_cells : u32,
    /** The parent's #size-cells: how many 32-bit cells a size in this node's reg takes, 1 by default. */
    size_cells : u32,
}

/** An address and a size from a reg property. */
Region :: struct {
    /** The address, in the parent bus's address space (for top-level devices, a physical address). */
    address : u64,
    /** The size in bytes. */
    size : u64,
}

/** A property's value: where it is, and how many bytes. */
Property :: struct {
    /** The virtual address of the value's first byte, in the blob; values are big-endian. */
    address : u64,
    /** The value's length in bytes, 0 for a property with no value. */
    size : u64,
}

/**
 * Open the tree whose blob is at an address, checking its header.
 *
 * @param address The virtual address the blob is mapped at, 0 for none. It has to be readable for at least the
 *     header's 40 bytes, and the whole blob for as long as the Tree is used.
 * @return The tree, or null when address is 0, the magic is wrong, the version is below 17 (which has the blocks'
 *     sizes), or the structure block runs past the blob's end.
 */
open :: fn(address: u64) -> Tree? {
    if address == 0 || big_endian_u32(address) != FDT_MAGIC {
        return null
    }
    tree := Tree.{
        address = address,
        size = cast[u64](big_endian_u32(address + 4)),
        structure = address + cast[u64](big_endian_u32(address + 8)),
        strings = address + cast[u64](big_endian_u32(address + 12)),
        // Version 17 has the blocks' sizes
        strings_size = cast[u64](big_endian_u32(address + 32)),
        structure_size = cast[u64](big_endian_u32(address + 36)),
    }
    if big_endian_u32(address + 20) < 17 || tree.structure + tree.structure_size > address + tree.size {
        return null
    }
    return tree
}

/**
 * Find the first node, in the tree's order, whose compatible property lists a string and which isn't disabled.
 *
 * @param tree The tree, from open; only read, its blob walked from the structure block's start.
 * @param compatible The compatible string to look for, matched whole, like "arm,gic-v3"; not "".
 * @return The node, or null if none lists it, every one that does has status "disabled", or the tree is malformed
 *     or nests deeper than MAX_DEPTH before one is found.
 */
find_compatible :: fn(tree: ptr[Tree], compatible: string) -> Node? {
    return find_node(tree, compatible, 0)
}

/**
 * Find the first node that lists a compatible string, disabled or not.
 *
 * For a device firmware keeps for itself and marks disabled, like the real-time clock UEFI's runtime services use,
 * which SlopOS doesn't call.
 *
 * @param tree The tree, from open; only read, its blob walked from the structure block's start.
 * @param compatible The compatible string to look for, matched whole; not "".
 * @return The node, or null if none lists it or the tree is malformed before one is found.
 */
find_compatible_even_disabled :: fn(tree: ptr[Tree], compatible: string) -> Node? {
    return find_node(tree, compatible, 0, true)
}

/**
 * Find the node with a phandle, as another node's property refers to it (like iommu-map's).
 *
 * @param tree The tree, from open; only read, its blob walked from the structure block's start unless phandle
 *     is 0.
 * @param phandle The phandle; 0 is never a node's.
 * @return The node, or null when phandle is 0, no node has it, or the node with it is disabled.
 */
find_phandle :: fn(tree: ptr[Tree], phandle: u32) -> Node? {
    return if phandle == 0 { null } else { find_node(tree, "", phandle) }
}

/**
 * Find the first node, in the tree's order, that matches a compatible string, a phandle, or a property's first cell.
 *
 * It walks the structure block once, keeping each depth's #address-cells and #size-cells so the node it gives knows
 * its reg's cells.
 *
 * @param tree The tree, from open; only read, its blob walked from the structure block's start.
 * @param compatible A compatible string the node's compatible property lists, or "" not to match by it.
 * @param phandle The node's phandle property, or 0 not to match by it.
 * @param even_disabled Whether a node with status "disabled" is found too; false skips them.
 * @param cell_name A property whose first cell is cell_value, as gpio-keys' "linux,code", or "" not to match by one.
 * @param cell_value The value cell_name's first cell has to be.
 * @return The first matching node, or null if none matches, or the walk meets a malformed token, the structure
 *     block's end, or nesting deeper than MAX_DEPTH first.
 */
find_node :: fn(tree: ptr[Tree], compatible: string, phandle: u32, even_disabled: bool = false, cell_name: string = "",
    cell_value: u32 = 0) -> Node? {
    // The cells each depth gives its children: 2 and 1 by default
    address_cells : u32[MAX_DEPTH]
    size_cells : u32[MAX_DEPTH]
    depth : usize = 0
    offset := cast[u64](0)
    // The node the walk is in, until its properties are done
    current : Node? = null
    matched := false
    disabled := false
    loop {
        if offset + 4 > tree.structure_size {
            return null
        }
        token :: big_endian_u32(tree.structure + offset)
        offset += 4
        if token == TOKEN_BEGIN_NODE || token == TOKEN_END_NODE || token == TOKEN_END {
            // The node before is done: it's the one, if it matched and isn't disabled
            if matched && (!disabled || even_disabled) {
                return current
            }
            matched = false
            disabled = false
        }
        if token == TOKEN_BEGIN_NODE {
            if depth + 1 >= MAX_DEPTH {
                return null
            }
            parent :: depth
            depth += 1
            if depth < MAX_DEPTH {
                address_cells[depth] = 2
                size_cells[depth] = 1
            }
            // The parent's cells, for this node's reg: 2 and 1 for the root, which has none
            parent_address : u32 = if parent > 0 && parent < MAX_DEPTH { address_cells[parent] } else { 2 }
            parent_size : u32 = if parent > 0 && parent < MAX_DEPTH { size_cells[parent] } else { 1 }
            current = Node.{offset = offset, address_cells = parent_address, size_cells = parent_size}
            offset = align4(offset + name_length(tree, offset) + 1)
        }
        else if token == TOKEN_END_NODE {
            if depth == 0 {
                return null
            }
            depth -= 1
        }
        else if token == TOKEN_PROPERTY {
            if offset + 8 > tree.structure_size {
                return null
            }
            length :: cast[u64](big_endian_u32(tree.structure + offset))
            name :: string_at(tree, cast[u64](big_endian_u32(tree.structure + offset + 4)))
            value :: Property.{address = tree.structure + offset + 8, size = length}
            if name == "#address-cells" && length == 4 && depth < MAX_DEPTH {
                address_cells[depth] = big_endian_u32(value.address)
            }
            else if name == "#size-cells" && length == 4 && depth < MAX_DEPTH {
                size_cells[depth] = big_endian_u32(value.address)
            }
            else if name == "compatible" && compatible != "" && lists(value, compatible) {
                matched = true
            }
            else if name == "phandle" && phandle != 0 && length == 4 && big_endian_u32(value.address) == phandle {
                matched = true
            }
            else if cell_name != "" && name == cell_name && length >= 4 && big_endian_u32(value.address) == cell_value {
                matched = true
            }
            else if name == "status" && lists(value, "disabled") {
                disabled = true
            }
            offset = align4(offset + 8 + length)
        }
        else if token == TOKEN_END {
            return null
        }
        else if token != TOKEN_NOP {
            return null
        }
    }
}

/**
 * Read every CPU node's hardware identifier, in the tree's order.
 *
 * A node is a CPU's when its device_type is "cpu"; its identifier is its reg's address, of its parent's
 * #address-cells (MPIDR's affinity fields on AArch64). A CPU node without a reg that long is skipped.
 *
 * @param tree The tree, from open; only read, its blob walked from the structure block's start.
 * @param ids Where the identifiers go, from the start; CPUs past its count are left out.
 * @return How many identifiers were written, at most ids.count; the walk stops early, keeping those found, at a
 *     malformed token, the structure block's end, or nesting deeper than MAX_DEPTH.
 */
cpus :: fn(tree: ptr[Tree], ids: mut u64[]) -> usize {
    address_cells : u32[MAX_DEPTH]
    depth : usize = 0
    offset := cast[u64](0)
    count := cast[usize](0)
    // The node the walk is in: whether it's a CPU, its reg's value, and the cells its parent gives reg
    is_cpu := false
    reg := Property.{}
    cells := cast[u32](2)
    loop {
        if offset + 4 > tree.structure_size {
            return count
        }
        token :: big_endian_u32(tree.structure + offset)
        offset += 4
        if token == TOKEN_BEGIN_NODE || token == TOKEN_END_NODE || token == TOKEN_END {
            // The node before is done
            if is_cpu && reg.size >= cast[u64](cells) * 4 && count < ids.count {
                ids[count] = read_cells(reg.address, cells)
                count += 1
            }
            is_cpu = false
            reg = Property.{}
        }
        if token == TOKEN_BEGIN_NODE {
            if depth + 1 >= MAX_DEPTH {
                return count
            }
            parent :: depth
            depth += 1
            if depth < MAX_DEPTH {
                address_cells[depth] = 2
            }
            cells = if parent > 0 && parent < MAX_DEPTH { address_cells[parent] } else { 2 }
            offset = align4(offset + name_length(tree, offset) + 1)
        }
        else if token == TOKEN_END_NODE {
            if depth == 0 {
                return count
            }
            depth -= 1
        }
        else if token == TOKEN_PROPERTY {
            if offset + 8 > tree.structure_size {
                return count
            }
            length :: cast[u64](big_endian_u32(tree.structure + offset))
            name :: string_at(tree, cast[u64](big_endian_u32(tree.structure + offset + 4)))
            value :: Property.{address = tree.structure + offset + 8, size = length}
            if name == "#address-cells" && length == 4 && depth < MAX_DEPTH {
                address_cells[depth] = big_endian_u32(value.address)
            }
            else if name == "device_type" && lists(value, "cpu") {
                is_cpu = true
            }
            else if name == "reg" {
                reg = value
            }
            offset = align4(offset + 8 + length)
        }
        else if token == TOKEN_END {
            return count
        }
        else if token != TOKEN_NOP {
            return count
        }
    }
}

/**
 * Find one of a node's own properties by name.
 *
 * @param tree The tree node was found in, from open; only read.
 * @param node The node, from one of the find functions.
 * @param name The property's name, like "reg" or "interrupts".
 * @return The property's value, a view into the blob, or null if the node hasn't it.
 */
property :: fn(tree: ptr[Tree], node: ptr[Node], name: string) -> Property? {
    offset := node.offset
    offset = align4(offset + name_length(tree, offset) + 1)
    loop {
        if offset + 4 > tree.structure_size {
            return null
        }
        token :: big_endian_u32(tree.structure + offset)
        if token == TOKEN_NOP {
            offset += 4
            continue
        }
        if token != TOKEN_PROPERTY || offset + 12 > tree.structure_size {
            // Its properties come before its children, and none was that
            return null
        }
        length :: cast[u64](big_endian_u32(tree.structure + offset + 4))
        if string_at(tree, cast[u64](big_endian_u32(tree.structure + offset + 8))) == name {
            return Property.{address = tree.structure + offset + 12, size = length}
        }
        offset = align4(offset + 12 + length)
    }
}

/**
 * Read one address and size from a node's reg property.
 *
 * @param tree The tree node was found in, from open; only read. The address and size are copied out, so the
 *     Region outlives the blob.
 * @param node The node, whose address_cells and size_cells say how its reg is laid out.
 * @param index Which pair, from 0.
 * @return The pair, or null if the node has no reg, it hasn't that many pairs, or a pair's cells are 0 or an address
 *     or size takes more than 2 cells (more than 64 bits).
 */
reg :: fn(tree: ptr[Tree], node: ptr[Node], index: u64) -> Region? {
    value :: property(tree, node, "reg") or_return null
    cells :: cast[u64](node.address_cells + node.size_cells)
    if cells == 0 || (index + 1) * cells * 4 > value.size || node.address_cells > 2 || node.size_cells > 2 {
        return null
    }
    start :: value.address + index * cells * 4
    return Region.{address = read_cells(start, node.address_cells), size = read_cells(start + cast[u64](node.address_cells) * 4, node.size_cells)}
}

/**
 * Read one 32-bit cell of a property's value.
 *
 * @param value The property's value, from property; a view into the blob, which must still be mapped.
 * @param index Which cell, from 0.
 * @return The cell, converted from big-endian, or null if the value is too short to have it.
 */
cell :: fn(value: Property, index: u64) -> u32? {
    if (index + 1) * 4 > value.size {
        return null
    }
    return big_endian_u32(value.address + index * 4)
}

/**
 * Read consecutive big-endian cells as one number, the first the most significant.
 *
 * @param address The virtual address of the first cell.
 * @param count How many cells, 0 to 2; more keep only the last two's 64 bits.
 * @return The number, 0 for no cells.
 */
read_cells :: fn(address: u64, count: u32) -> u64 {
    result := cast[u64](0)
    for i in 0..<count {
        result = (result << 32) | cast[u64](big_endian_u32(address + cast[u64](i) * 4))
    }
    return result
}

/**
 * Tell whether a property's string list has a string in it.
 *
 * @param value A property whose value is NUL-terminated strings, one after another, like compatible's.
 * @param text The string, matched whole; a string in the list without its NUL isn't matched.
 * @return Whether one of the list's strings is exactly text.
 */
lists :: fn(value: Property, text: string) -> bool {
    start := cast[u64](0)
    for i in 0..<value.size {
        if byte_at(value.address + i) == 0 {
            if i - start == cast[u64](text.count) && matches(value.address + start, text) {
                return true
            }
            start = i + 1
        }
    }
    return false
}

/**
 * Tell whether the bytes at an address start with a string.
 *
 * @param address The virtual address of the bytes, readable for text's length.
 * @param text The string; each character is compared as one byte.
 * @return Whether the bytes equal text's.
 */
matches :: fn(address: u64, text: string) -> bool {
    for character, i in text {
        if byte_at(address + cast[u64](i)) != cast[u8](character) {
            return false
        }
    }
    return true
}

/**
 * Read a property's name from the strings block.
 *
 * @param tree The tree, from open, whose strings block holds the name; the string returned stays good only while
 *     the blob stays mapped.
 * @param offset The name's byte offset in the strings block.
 * @return The NUL-terminated string there, a view into the blob, cut short at the block's end; "" when offset is
 *     outside the block.
 */
string_at :: fn(tree: ptr[Tree], offset: u64) -> string {
    if offset >= tree.strings_size {
        return ""
    }
    length := cast[u64](0)
    loop {
        if offset + length >= tree.strings_size || byte_at(tree.strings + offset + length) == 0 {
            break
        }
        length += 1
    }
    return string_of(cast[ptr[u8]](tree.strings + offset), cast[usize](length))
}

/**
 * Measure a node's NUL-terminated name in the structure block.
 *
 * @param tree The tree, from open, whose structure block holds the name; only read.
 * @param offset The name's byte offset in the structure block.
 * @return The name's length in bytes, without its NUL, cut short at the block's end.
 */
name_length :: fn(tree: ptr[Tree], offset: u64) -> u64 {
    length := cast[u64](0)
    loop {
        if offset + length >= tree.structure_size || byte_at(tree.structure + offset + length) == 0 {
            return length
        }
        length += 1
    }
}

/**
 * Round an offset up to a multiple of 4, as the structure block's tokens are aligned.
 *
 * @param offset The offset in bytes.
 * @return The smallest multiple of 4 at least offset.
 */
align4 :: fn(offset: u64) -> u64 {
    return (offset + 3) & ~cast[u64](3)
}

/**
 * Read one byte of the blob.
 *
 * @param address The byte's virtual address, which has to be mapped.
 * @return The byte's value, read with a plain load; any of 0 to 255.
 */
byte_at :: fn(address: u64) -> u8 {
    return cast[ptr[u8]](address)^
}

/**
 * Read a big-endian 32-bit word, as the device tree stores every number, byte by byte so it needs no alignment.
 *
 * @param address The word's virtual address, which has to be mapped for 4 bytes.
 * @return The word's value: its first byte the most significant, any of 0 to 0xffffffff.
 */
big_endian_u32 :: fn(address: u64) -> u32 {
    return cast[u32](byte_at(address)) << 24 | cast[u32](byte_at(address + 1)) << 16 | cast[u32](byte_at(address + 2)) << 8
        | cast[u32](byte_at(address + 3))
}
