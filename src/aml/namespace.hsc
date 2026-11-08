package aml

import runtime from "base"
import text_buffer from "std"

/*
 * The namespace: a tree of nodes, each named by a segment of four characters, the first in a u32's low byte as AML
 * packs them. Nodes live as long as the interpreter, but those a method makes, which are removed when it returns;
 * their memory counts against the namespace's budget.
 */

/** The root's name, `\`, which is no segment of AML's; it's never looked up by it. */
ROOT_NAME : u32 : 0x5c

/** What a node is: ACPI's object types, and what the interpreter needs beside them. */
NodeKind :: enum {
    /** A scope alone, as `\_SB` is: it holds nodes, and no value. */
    Scope,
    /** A named value, made by Name: an integer, string, buffer, package, or a reference stored in it. */
    Name,
    /** A method: its body's bytecode, how many arguments it takes. */
    Method,
    /** A method the interpreter answers itself, `\_OSI`. */
    Builtin,
    /** A device. */
    Device,
    /** A processor, as the old Processor term defines one. */
    Processor,
    /** A power resource. */
    PowerResource,
    /** A thermal zone. */
    ThermalZone,
    /** A mutex. */
    Mutex,
    /** An event. */
    Event,
    /** An operation region: its space, offset and length. */
    Region,
    /** A field in an operation region. */
    Field,
    /** A field reached through an index field and a data field. */
    IndexField,
    /** A field in a region whose bank a bank field picks. */
    BankField,
    /** A field in a buffer. */
    BufferField,
    /** Another name for a node, which every use of it reaches. */
    Alias,
}

/** A field's access width, as its flags say (ACPI 6.5 §19.6.48). */
AccessType :: enum #backed_by(u8) {
    /** Any width: taken here as a byte. */
    Any = 0,
    /** A byte at a time. */
    Byte = 1,
    /** 16 bits at a time. */
    Word = 2,
    /** 32 bits at a time. */
    DWord = 3,
    /** 64 bits at a time. */
    QWord = 4,
    /** As a buffer, for the serial bus spaces: taken here as a byte. */
    Buffer = 5,
}

/** What a field's write does to the bits of an access unit outside it. */
UpdateRule :: enum #backed_by(u8) {
    /** They're read first and written back as they were. */
    Preserve = 0,
    /** They're written as ones. */
    WriteAsOnes = 1,
    /** They're written as zeros. */
    WriteAsZeros = 2,
}

/** A namespace node. Which of its fields mean anything depends on its kind. */
Node :: struct {
    /** Its name, a segment; ROOT_NAME for the root. */
    name : u32,
    /** What it is. */
    kind : NodeKind,
    /** The node it's in; null for the root. */
    parent : ptr[mut Node]?,
    /** The first node in it, the newest; null for none. */
    first_child : ptr[mut Node]?,
    /** The next node in its parent, made before it. */
    next : ptr[mut Node]?,
    /** Whether a method made it, so it's removed when that call returns. */
    temporary : bool,
    /** The node the same call made before it, for removing them all when it returns; null for its first. */
    made_before : ptr[mut Node]?,
    /** A Name's value, persistent; an Alias's target as Object. */
    value : Value,
    /** A Method's body, a view into its table's kept bytecode. */
    body : u8[],
    /** How many arguments a Method or Builtin takes, 0 to 7. */
    argument_count : u8,
    /** A Mutex's sync level, 0 to 15. */
    sync_level : u8,
    /** How many times a Mutex is held now, by the one thread that evaluates; or an Event's count of signals. */
    count : u64,
    /** A Region's space, as RegionSpace numbers them. */
    space : u8,
    /** A Region's offset in its space; for PCI_Config, within the function's configuration space. */
    offset : u64,
    /** A Region's length in bytes. */
    length : u64,
    /** Whether a PCI_Config Region's function is found yet: pci holds it once it is. */
    pci_found : bool,
    /** A PCI_Config Region's function, as pci_address makes it, with offset 0. */
    pci : u64,
    /** A field's region; an IndexField's index field; a BankField's region. */
    region : ptr[mut Node]?,
    /** An IndexField's data field; a BankField's bank field. */
    data : ptr[mut Node]?,
    /** A BankField's bank value, written to its bank field before each access. */
    bank : u64,
    /** A field's first bit, from its region's start (an IndexField's, from the index's 0). */
    bit_offset : u64,
    /** A field's bits. */
    bit_length : u64,
    /** A field's access width. */
    access : AccessType,
    /** A field's update rule. */
    update : UpdateRule,
    /** A BufferField's buffer, shared with the value it was made from. */
    buffer : ptr[mut Bytes]?,
}

/**
 * Pack a segment's four characters, as AML does: the first in the low byte.
 *
 * @param text Four characters; a shorter text is padded with `_`, a longer cut to four.
 * @return The segment.
 */
segment_of :: fn(text: string) -> u32 {
    bytes :: string_bytes(text)
    segment : u32 = 0
    for i in 0..<4 {
        position :: cast[usize](i)
        character :: if position < bytes.count { bytes[position] } else { cast[u8]('_') }
        segment |= cast[u32](character) << (8 * cast[u32](i))
    }
    return segment
}

/**
 * Find a node's child by its name.
 *
 * @param parent The node looked in.
 * @param name The child's segment.
 * @return The child, following an Alias to what it names; null if there's none.
 */
child_of :: fn(parent: ptr[Node], name: u32) -> ptr[mut Node]? {
    child := parent.first_child
    loop {
        node :: child or_break
        if node.name == name {
            return resolved(node)
        }
        child = node.next
    }
    return null
}

/**
 * Follow an Alias to what it names, through aliases of aliases, at most 8.
 *
 * @param node The node.
 * @return What it names; itself if it isn't an Alias, or an Alias whose target isn't a node.
 */
resolved :: fn(node: ptr[mut Node]) -> ptr[mut Node] {
    at := node
    for hop in 0..<8 {
        if at.kind != .Alias {
            break
        }
        match at.value {
            case Object(target) => at = target
            case _ => break
        }
    }
    return at
}

/**
 * Make a node in a scope, counted against the namespace's budget.
 *
 * @param interpreter The interpreter, whose namespace_bytes it's counted in.
 * @param parent The scope it's made in.
 * @param name Its segment.
 * @param kind What it is.
 * @param temporary Whether a method makes it, so it's removed when the method returns.
 * @return The node, its other fields zero; null if the budget or the heap can't hold it.
 */
add_node :: fn(interpreter: ptr[mut Interpreter], parent #escaping : ptr[mut Node], name: u32, kind: NodeKind, temporary: bool) -> ptr[mut Node]? {
    if interpreter.namespace_bytes + size_of(Node) > interpreter.limits.namespace_bytes {
        return null
    }
    made, error :: runtime.new_aligned(Node, align_of(Node))
    if error != null {
        return null
    }
    interpreter.namespace_bytes += size_of(Node)
    made^ = Node.{name = name, kind = kind, parent = parent, next = parent.first_child, temporary = temporary}
    parent.first_child = made
    return made
}

/**
 * Remove a node a method made from its parent, and give back its memory and its value's.
 *
 * Nodes in it go too. A node something still refers to, a reference stored elsewhere, is left dangling: a method's
 * temporary objects don't outlive it, as ACPI says.
 *
 * @param interpreter The interpreter, whose namespace_bytes are given back.
 * @param node The node, a child of its parent.
 */
remove_node :: fn(interpreter: ptr[mut Interpreter], node: ptr[mut Node]) {
    child := node.first_child
    loop {
        inner :: child or_break
        child = inner.next
        remove_node(interpreter, inner)
    }
    node.first_child = null
    parent :: node.parent or_return void
    // Unlinked from its parent's list
    if parent.first_child == node {
        parent.first_child = node.next
    }
    else {
        before := parent.first_child
        loop {
            at :: before or_break
            if at.next == node {
                at.next = node.next
                break
            }
            before = at.next
        }
    }
    release_persistent(interpreter, node.value)
    runtime.free_aligned(node, align_of(Node))
    interpreter.namespace_bytes -= size_of(Node)
}

/**
 * Write a node's path, as ASL does: `\_SB_.PCI0._CRS`.
 *
 * @param out Where it's written; what doesn't fit is cut.
 * @param node The node.
 */
write_path :: fn(out: ptr[mut text_buffer.TextBuffer], node: ptr[Node]) {
    segments : u32[32]
    count : usize = 0
    at := node
    loop {
        parent :: at.parent or_break
        if count < segments.count {
            segments[count] = at.name
            count += 1
        }
        at = parent
    }
    text_buffer.append(out, "\\")
    for i in 0..<count {
        index :: count - 1 - i
        if index < segments.count {
            if i > 0 {
                text_buffer.append(out, ".")
            }
            segment :: segments[index]
            for shift in 0..<4 {
                text_buffer.append_byte(out, cast[u8]((segment >> (8 * cast[u32](shift))) & 0xff))
            }
        }
    }
}

/**
 * Visit every node beneath one, parents before what's in them, newest first among siblings.
 *
 * @param node Where to start; it's visited too.
 * @param visit Called with each node and state; returns false to stop the walk.
 * @param state Passed to visit as it is: the caller's own, as an address.
 * @return False if visit stopped it.
 */
walk :: fn(node #escaping : ptr[mut Node], visit: (fn(node #escaping : ptr[mut Node], state: u64) -> bool), state: u64) -> bool {
    if !visit(node, state) {
        return false
    }
    child := node.first_child
    loop {
        inner :: child or_break
        if !walk(inner, visit, state) {
            return false
        }
        child = inner.next
    }
    return true
}
