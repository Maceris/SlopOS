/*
 * A reader for the flattened device tree (the DTB a bootloader passes), enough to find devices by their
 * compatible strings and read their reg and interrupts properties. It reads the blob where it is, through
 * the direct map, and allocates nothing, so the arch layer can use it before there's a heap.
 */
//SPEC: Devicetree Specification 0.4, chapter 5 (the flattened format), §2.3 (#address-cells, #size-cells, reg, compatible)
package devicetree


FDT_MAGIC : u32 : 0xd00dfeed
TOKEN_BEGIN_NODE : u32 : 1
TOKEN_END_NODE : u32 : 2
TOKEN_PROPERTY : u32 : 3
TOKEN_NOP : u32 : 4
TOKEN_END : u32 : 9
// How deep nodes nest, at most, for the cells each level gives its children
MAX_DEPTH :: 16

// A tree in memory: its first byte's address, and where its structure and strings blocks are.
Tree :: struct {
    address : u64,
    size : u64,
    structure : u64,
    structure_size : u64,
    strings : u64,
    strings_size : u64,
}

// A node: where its structure starts, at its name, and the cells its parent gives reg.
Node :: struct {
    offset : u64,
    address_cells : u32,
    size_cells : u32,
}

// An address and a size from a reg property.
Region :: struct {
    address : u64,
    size : u64,
}

// A property's value: where it is, and how many bytes.
Property :: struct {
    address : u64,
    size : u64,
}

// The tree at address, a virtual address, or null if the header isn't one.
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

/*
 * The first node, in the tree's order, whose compatible property lists compatible, and which isn't disabled
 * (status "disabled"), or null.
 */
find_compatible :: fn(tree: ptr[Tree], compatible: string) -> Node? {
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
            if matched && !disabled {
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
            else if name == "compatible" && lists(value, compatible) {
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

// A property of node, by name, or null.
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

// The index-th address and size in node's reg, or null if it hasn't that many.
reg :: fn(tree: ptr[Tree], node: ptr[Node], index: u64) -> Region? {
    value :: property(tree, node, "reg") or_return null
    cells :: cast[u64](node.address_cells + node.size_cells)
    if cells == 0 || (index + 1) * cells * 4 > value.size || node.address_cells > 2 || node.size_cells > 2 {
        return null
    }
    start :: value.address + index * cells * 4
    return Region.{address = read_cells(start, node.address_cells), size = read_cells(start + cast[u64](node.address_cells) * 4, node.size_cells)}
}

// The index-th 32-bit cell of a property, or null.
cell :: fn(value: Property, index: u64) -> u32? {
    if (index + 1) * 4 > value.size {
        return null
    }
    return big_endian_u32(value.address + index * 4)
}

// One or two cells, as a number.
read_cells :: fn(address: u64, count: u32) -> u64 {
    result := cast[u64](0)
    for i in 0..<count {
        result = (result << 32) | cast[u64](big_endian_u32(address + cast[u64](i) * 4))
    }
    return result
}

// Whether a list of strings, each ending with a NUL, has text in it.
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

// The bytes at address are text's.
matches :: fn(address: u64, text: string) -> bool {
    for character, i in text {
        if byte_at(address + cast[u64](i)) != cast[u8](character) {
            return false
        }
    }
    return true
}

// The string at offset in the strings block, or "" outside it.
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

// How long the NUL-terminated node name at offset is, within the structure block.
name_length :: fn(tree: ptr[Tree], offset: u64) -> u64 {
    length := cast[u64](0)
    loop {
        if offset + length >= tree.structure_size || byte_at(tree.structure + offset + length) == 0 {
            return length
        }
        length += 1
    }
}

align4 :: fn(offset: u64) -> u64 {
    return (offset + 3) & ~cast[u64](3)
}

byte_at :: fn(address: u64) -> u8 {
    return cast[ptr[u8]](address)^
}

big_endian_u32 :: fn(address: u64) -> u32 {
    return cast[u32](byte_at(address)) << 24 | cast[u32](byte_at(address + 1)) << 16 | cast[u32](byte_at(address + 2)) << 8
        | cast[u32](byte_at(address + 3))
}
