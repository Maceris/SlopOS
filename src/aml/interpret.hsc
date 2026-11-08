package aml

import memory from "std"
import runtime from "base"
import text_buffer from "std"

/*
 * Running AML: a cursor over its bytecode, read term by term, each run as it's read (ACPI 6.5 §20). A table's AML is
 * run once, at the root, when it's loaded; a method's body is run each time it's called, from where its table's
 * bytecode is kept. Every read is checked against the end of what's being read, and every term counts a step.
 */

/** Where a method's call, or a table's load, is: its scope, locals, arguments and what it returns. */
Frame :: struct {
    /** The scope names are resolved from, and new objects made in. */
    scope : ptr[mut Node],
    /** The method called; null for a table's load. */
    method : ptr[mut Node]?,
    /** Local0 to Local7, in the arena; empty for a table's load, which has none. */
    locals : mut Value[],
    /** Arg0 to Arg6, in the arena; empty for a table's load. */
    arguments : mut Value[],
    /** What Return gave. */
    result : Value,
    /** The newest node this call made, which it removes with those before it when it returns; null for none. */
    made : ptr[mut Node]?,
}

/** How a term list's running ended. */
Flow :: enum {
    /** It ran to its end. */
    Next,
    /** Return ran: the frame's result holds its value. */
    Return,
    /** Break ran, ending the While it's in. */
    Break,
    /** Continue ran, going around the While it's in again. */
    Continue,
}

/** A position in bytecode: what it reads, and where it stops. */
Cursor :: struct {
    /** The bytecode. */
    code : u8[],
    /** The next byte to read. */
    at : usize,
    /** Where the term list or term being read ends, at most code.count. */
    end : usize,
}

/** A name as AML encodes it (ACPI 6.5 §20.2.2): from the root, or up some scopes, then segments. */
NameString :: struct {
    /** Whether it starts at the root, `\`. */
    from_root : bool,
    /** How many `^` it starts with: scopes up from the current one. */
    up : u32,
    /** Its segments, four bytes each; empty for the null name. */
    segments : u8[],
    /** Where it starts in the bytecode it was read from, its prefixes included. */
    start : usize,
    /** Where it ends there. */
    stop : usize,
}

/** Where a value's stored: a target, or a SuperName (ACPI 6.5 §20.2.5). */
Target :: union {
    /** Nowhere: the null name, as a target left out is. */
    Nothing,
    /** Local0 to Local7. */
    Local(u8),
    /** Arg0 to Arg6. */
    Argument(u8),
    /** A named object. */
    Named(ptr[mut Node]),
    /** The debug object. */
    Debug,
    /** What a reference refers to: an element, a byte, or a named object, as Index, RefOf and DerefOf give. */
    Referred(Value),
}

// ---- Reading the bytecode

/**
 * Count a term: a step against the evaluation's budget, and a level of nesting.
 *
 * @param interpreter The interpreter, whose steps and nesting grow; leave takes the nesting back.
 * @error Steps The budget of steps is spent.
 * @error Depth Terms are nested as deep as they may be.
 */
enter :: fn(interpreter: ptr[mut Interpreter]) -> Result[void, Error] {
    if interpreter.steps >= interpreter.limits.steps {
        return .Error(.Steps)
    }
    if interpreter.nesting >= interpreter.limits.nesting {
        return .Error(.Depth)
    }
    interpreter.steps += 1
    interpreter.nesting += 1
    return .Ok
}

/**
 * Take back a level of nesting enter counted.
 *
 * @param interpreter The interpreter.
 */
leave :: fn(interpreter: ptr[mut Interpreter]) {
    interpreter.nesting -= 1
}

/**
 * Read a byte.
 *
 * @param cursor Where; moved past it.
 * @return The byte.
 * @error Truncated At the end.
 */
read_byte :: fn(cursor: ptr[mut Cursor]) -> Result[u8, Error] {
    at :: cursor.at
    if at >= cursor.end || at >= cursor.code.count {
        return .Error(.Truncated)
    }
    cursor.at = at + 1
    return .Ok(cursor.code[at])
}

/**
 * Look at the next byte without reading it.
 *
 * @param cursor Where.
 * @param ahead How many bytes past the next: 0 for the next itself.
 * @return The byte; null past the end.
 */
peek_byte :: fn(cursor: ptr[Cursor], ahead: usize = 0) -> u8? {
    if ahead >= cursor.code.count {
        return null
    }
    at :: cursor.at + ahead
    if at < cursor.at || at >= cursor.end || at >= cursor.code.count {
        return null
    }
    return cursor.code[at]
}

/**
 * Read a little-endian integer of some bytes.
 *
 * @param cursor Where; moved past it.
 * @param count How many bytes: 1 to 8.
 * @return The integer.
 * @error Truncated At the end before it.
 */
read_integer :: fn(cursor: ptr[mut Cursor], count: u32) -> Result[u64, Error] {
    value : u64 = 0
    for i in 0..<count {
        value |= cast[u64](read_byte(cursor)?) << (8 * cast[u64](i))
    }
    return .Ok(value)
}

/**
 * Read a PkgLength (ACPI 6.5 §20.2.4): how far the term it starts runs, from the PkgLength's own first byte.
 *
 * @param cursor Where; moved past it.
 * @return Where the term ends, in the cursor's code.
 * @error Truncated At the end before it, or a length that runs past the cursor's end.
 */
package_end :: fn(cursor: ptr[mut Cursor]) -> Result[usize, Error] {
    start :: cursor.at
    lead :: read_byte(cursor)?
    following :: cast[u32](lead >> 6)
    length : u64 = 0
    if following == 0 {
        length = cast[u64](lead & 0x3f)
    }
    else {
        length = cast[u64](lead & 0x0f)
        for i in 0..<following {
            length |= cast[u64](read_byte(cursor)?) << (4 + 8 * cast[u64](i))
        }
    }
    if length > cast[u64](cursor.end - start) {
        return .Error(.Truncated)
    }
    return .Ok(start + cast[usize](length))
}

/**
 * Tell whether a byte starts a NameString.
 *
 * @param byte The byte.
 * @return True for `\`, `^`, a dual or multiple name prefix, A to Z, or `_`.
 */
starts_name :: fn(byte: u8) -> bool {
    return byte == 0x5c || byte == 0x5e || byte == 0x2e || byte == 0x2f || (byte >= cast[u8]('A') && byte <= cast[u8]('Z')) || byte == cast[u8]('_')
}

/**
 * Read a NameString.
 *
 * @param cursor Where; moved past it.
 * @return The name, its segments a view into the cursor's code.
 * @error Truncated At the end before it ends.
 * @error BadOpcode A segment that doesn't start as one can.
 */
read_name :: fn(cursor: ptr[mut Cursor]) -> Result[NameString, Error] {
    name := NameString.{start = cursor.at, stop = cursor.at}
    match peek_byte(cursor) {
        case Some(first) => {
            if first == 0x5c {
                name.from_root = true
                cursor.at += 1
            }
        }
        case None => return .Error(.Truncated)
    }
    loop {
        byte :: peek_byte(cursor) or_return .Error(.Truncated)
        if byte != 0x5e {
            break
        }
        name.up += 1
        cursor.at += 1
    }
    prefix :: read_byte(cursor)?
    count : usize = 0
    if prefix == 0x00 {
        name.stop = cursor.at
        return .Ok(name)
    }
    if prefix == 0x2e {
        count = 2
    }
    else if prefix == 0x2f {
        count = cast[usize](read_byte(cursor)?)
    }
    else {
        // The first byte of a single segment, read already
        cursor.at -= 1
        count = 1
    }
    code :: cursor.code
    start :: cursor.at
    bytes :: count * 4
    if start > cursor.end || bytes > cursor.end - start || cursor.end > code.count {
        return .Error(.Truncated)
    }
    stop :: start + bytes
    if start > stop || stop > code.count {
        return .Error(.Truncated)
    }
    segments :: code[start..<stop]
    for byte, i in segments {
        if i % 4 == 0 && !(byte == cast[u8]('_') || (byte >= cast[u8]('A') && byte <= cast[u8]('Z'))) {
            return .Error(.BadOpcode)
        }
    }
    name.segments = segments
    cursor.at = stop
    name.stop = stop
    return .Ok(name)
}

/**
 * A name's segment.
 *
 * @param name The name.
 * @param index Which segment, below name.segments.count / 4.
 * @return The segment; 0 past its last.
 */
segment_at :: fn(name: ptr[NameString], index: usize) -> u32 {
    segments :: name.segments
    at :: index * 4
    if at < segments.count && at + 3 < segments.count {
        return cast[u32](segments[at]) | (cast[u32](segments[at + 1]) << 8) | (cast[u32](segments[at + 2]) << 16) | (cast[u32](segments[at + 3]) << 24)
    }
    return 0
}

/**
 * Find the scope a name starts from: the root, or the current scope, up as many as its `^`s.
 *
 * @param interpreter The interpreter.
 * @param scope The current scope.
 * @param name The name.
 * @return The scope; the root if `^` would go past it.
 */
start_of :: fn(interpreter: ptr[mut Interpreter], scope: ptr[mut Node], name: ptr[NameString]) -> ptr[mut Node] {
    if name.from_root {
        return interpreter.root
    }
    at := scope
    for level in 0..<name.up {
        at = at.parent or_else interpreter.root
    }
    return at
}

/**
 * Resolve a name to its node, as a reference to one is: a single segment with no prefix is looked for in the current
 * scope, then each scope it's in up to the root (ACPI 6.5 §5.3); any other from where it starts.
 *
 * @param interpreter The interpreter.
 * @param scope The current scope.
 * @param name The name.
 * @return The node; for a prefix alone, the scope it reaches; null if there's none, or for the null name.
 */
resolve :: fn(interpreter: ptr[mut Interpreter], scope: ptr[mut Node], name: ptr[NameString]) -> ptr[mut Node]? {
    count :: name.segments.count / 4
    start :: start_of(interpreter, scope, name)
    if count == 0 {
        // A prefix alone, `\` or `^`, names the scope it reaches; the null name names nothing
        return if name.from_root || name.up > 0 { start } else { null }
    }
    if count == 1 && !name.from_root && name.up == 0 {
        segment :: segment_at(name, 0)
        at := start
        loop {
            match child_of(at, segment) {
                case Some(found) => return found
                case None => {}
            }
            at = at.parent or_break
        }
        return null
    }
    at := start
    for i in 0..<count {
        at = child_of(at, segment_at(name, i)) or_return null
    }
    return at
}

/**
 * Note a name that isn't in the namespace, for the host's log, and give NotFound.
 *
 * @param interpreter The interpreter, whose missing is set to the name's last segment.
 * @param name The name.
 * @return NotFound.
 */
not_found :: fn(interpreter: ptr[mut Interpreter], name: ptr[NameString]) -> Error {
    count :: name.segments.count / 4
    interpreter.missing = if count > 0 { segment_at(name, count - 1) } else { 0 }
    return .NotFound
}

/**
 * Note where a term failed, for the host's log: the innermost term's, as the first noted in an evaluation is.
 *
 * @param interpreter The interpreter, whose failed_at and failed_bytes are set if nothing's been noted yet.
 * @param cursor The cursor the term was read from.
 * @param start Where the term started.
 */
note_failure :: fn(interpreter: ptr[mut Interpreter], cursor: ptr[Cursor], start: usize) {
    if interpreter.failure_noted {
        return void
    }
    interpreter.failure_noted = true
    interpreter.failed_at = start
    code :: cursor.code
    for i in 0..<interpreter.failed_bytes.count {
        at :: start + i
        interpreter.failed_bytes[i] = if at < code.count { code[at] } else { 0 }
    }
}

/**
 * Make a node a definition names: in the scope its name's prefix and all but its last segment reach.
 *
 * @param interpreter The interpreter.
 * @param frame The frame defining it: a method's call makes it temporary, removed when the call returns.
 * @param name The name.
 * @param kind What it is.
 * @return The node.
 * @error NotFound The scope the name's in isn't there, or the name's null.
 * @error AlreadyExists Something of that name is in that scope already.
 * @error Memory The namespace's budget can't hold it.
 */
define :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], name: ptr[NameString], kind: NodeKind) -> Result[ptr[mut Node], Error] {
    count :: name.segments.count / 4
    if count == 0 {
        return .Error(.NotFound)
    }
    at := start_of(interpreter, frame.scope, name)
    for i in 0..<count - 1 {
        at = child_of(at, segment_at(name, i)) or_return .Error(not_found(interpreter, name))
    }
    last :: segment_at(name, count - 1)
    if child_of(at, last) is_some {
        return .Error(.AlreadyExists)
    }
    temporary :: frame.method is_some
    node :: add_node(interpreter, at, last, kind, temporary) or_return .Error(.Memory)
    if temporary {
        node.made_before = frame.made
        frame.made = node
    }
    return .Ok(node)
}

// ---- Term lists and statements

/**
 * Run a term list: each term in turn until its end, or until one ends the list early.
 *
 * @param interpreter The interpreter.
 * @param frame The frame it runs in.
 * @param code The bytecode it's in.
 * @param from Where it starts.
 * @param to Where it ends, at most code.count.
 * @return How it ended.
 */
run_terms :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], code #escaping : u8[], from: usize, to: usize) -> Result[Flow, Error] {
    cursor := Cursor.{code = code, at = from, end = if to <= code.count { to } else { code.count }}
    loop {
        if cursor.at >= cursor.end {
            break
        }
        flow :: run_term(interpreter, frame, &cursor)?
        if flow != .Next {
            return .Ok(flow)
        }
    }
    return .Ok(.Next)
}

/**
 * Run one term of a term list: a definition, a statement, or an expression whose value is dropped.
 *
 * @param interpreter The interpreter.
 * @param frame The frame it runs in.
 * @param cursor Where it starts; moved past it.
 * @return How it ended: Next unless it's a Return, Break or Continue, or holds one.
 */
run_term :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Flow, Error] {
    start :: cursor.at
    flow :: run_term_counted(interpreter, frame, cursor)
    match flow {
        case Error(_) => note_failure(interpreter, cursor, start)
        case Ok(_) => {}
    }
    return flow
}

/**
 * Run one term of a term list, counted as a step and a level of nesting, as run_term does.
 *
 * @param interpreter The interpreter.
 * @param frame The frame it runs in.
 * @param cursor Where it starts; moved past it.
 * @return How it ended.
 */
run_term_counted :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Flow, Error] {
    enter(interpreter)?
    defer leave(interpreter)
    opcode :: peek_byte(cursor) or_return .Error(.Truncated)
    if opcode == 0x5b {
        extended :: peek_byte(cursor, 1) or_return .Error(.Truncated)
        if is_extended_statement(extended) {
            cursor.at += 2
            return run_extended_statement(interpreter, frame, cursor, extended)
        }
    }
    else if is_statement(opcode) {
        cursor.at += 1
        return run_statement(interpreter, frame, cursor, opcode)
    }
    _ = evaluate_term(interpreter, frame, cursor)?
    return .Ok(.Next)
}

/**
 * Tell whether an opcode, after 0x5b, is a definition or statement run_extended_statement runs.
 *
 * @param opcode The byte after 0x5b.
 * @return True for those that aren't expressions.
 */
is_extended_statement :: fn(opcode: u8) -> bool {
    return opcode == 0x01 || opcode == 0x02 || opcode == 0x13 || opcode == 0x20 || opcode == 0x21 || opcode == 0x22 || opcode == 0x24
        || opcode == 0x26 || opcode == 0x27 || opcode == 0x2a || opcode == 0x32 || opcode == 0x80 || opcode == 0x81 || opcode == 0x82
        || opcode == 0x83 || opcode == 0x84 || opcode == 0x85 || opcode == 0x86 || opcode == 0x87 || opcode == 0x88
}

/**
 * Tell whether a one-byte opcode is a definition or statement run_statement runs.
 *
 * @param opcode The byte.
 * @return True for those that aren't expressions.
 */
is_statement :: fn(opcode: u8) -> bool {
    return opcode == 0x06 || opcode == 0x08 || opcode == 0x10 || opcode == 0x14 || opcode == 0x15 || opcode == 0x86 || opcode == 0x8a
        || opcode == 0x8b || opcode == 0x8c || opcode == 0x8d || opcode == 0x8f || opcode == 0x9f || (opcode >= 0xa0 && opcode <= 0xa5)
        || opcode == 0xcc
}

/**
 * Run a one-byte definition or statement, its opcode read.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode; moved past the term.
 * @param opcode The opcode, one is_statement takes.
 * @return How it ended.
 */
run_statement :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor], opcode: u8) -> Result[Flow, Error] {
    if opcode == 0x10 {
        // Scope
        end :: package_end(cursor)?
        name := read_name(cursor)?
        node :: resolve(interpreter, frame.scope, &name) or_return .Error(not_found(interpreter, &name))
        return run_inside(interpreter, frame, node, cursor, end)
    }
    if opcode == 0x08 {
        // Name
        name := read_name(cursor)?
        value :: evaluate_term(interpreter, frame, cursor)?
        node :: define(interpreter, frame, &name, .Name)?
        node.value = persist(interpreter, value)?
        return .Ok(.Next)
    }
    if opcode == 0x14 {
        // Method: its body is run when it's called
        end :: package_end(cursor)?
        name := read_name(cursor)?
        flags :: read_byte(cursor)?
        node :: define(interpreter, frame, &name, .Method)?
        node.argument_count = flags & 7
        start :: cursor.at
        node.body = if start <= end && end <= cursor.code.count { cursor.code[start..<end] } else { cursor.code[0..<0] }
        cursor.at = end
        return .Ok(.Next)
    }
    if opcode == 0x06 {
        // Alias
        source := read_name(cursor)?
        alias := read_name(cursor)?
        target :: resolve(interpreter, frame.scope, &source) or_return .Error(not_found(interpreter, &source))
        node :: define(interpreter, frame, &alias, .Alias)?
        node.value = .Object(target)
        return .Ok(.Next)
    }
    if opcode == 0x15 {
        // External: a declaration for the compiler; nothing to run
        _ = read_name(cursor)?
        _ = read_byte(cursor)?
        _ = read_byte(cursor)?
        return .Ok(.Next)
    }
    if opcode == 0x86 {
        // Notify
        target :: read_target(interpreter, frame, cursor)?
        value :: evaluate_integer(interpreter, frame, cursor)?
        match target {
            case Named(node) => interpreter.host.notify(interpreter.host.state, node, value)
            case Referred(referred) => match referred {
                case Reference(node) => interpreter.host.notify(interpreter.host.state, node, value)
                case _ => return .Error(.WrongType)
            }
            case _ => return .Error(.WrongType)
        }
        return .Ok(.Next)
    }
    if opcode == 0x8a || opcode == 0x8b || opcode == 0x8c || opcode == 0x8d || opcode == 0x8f {
        // CreateDWordField, CreateWordField, CreateByteField, CreateBitField, CreateQWordField
        source :: evaluate_term(interpreter, frame, cursor)?
        index :: evaluate_integer(interpreter, frame, cursor)?
        name := read_name(cursor)?
        bits : u64 = if opcode == 0x8a { 32 } else if opcode == 0x8b { 16 } else if opcode == 0x8c { 8 } else if opcode == 0x8d { 1 } else { 64 }
        offset :: if opcode == 0x8d { index } else { index * 8 }
        return create_buffer_field(interpreter, frame, source, offset, bits, &name)
    }
    if opcode == 0xa0 {
        // If, and the Else that may follow it
        end :: package_end(cursor)?
        taken :: evaluate_integer(interpreter, frame, cursor)? != 0
        start :: cursor.at
        cursor.at = end
        has_else :: (peek_byte(cursor) or_else 0) == 0xa1
        else_start : usize = 0
        else_end : usize = 0
        if has_else {
            cursor.at += 1
            else_end = package_end(cursor)?
            else_start = cursor.at
            cursor.at = else_end
        }
        if taken {
            return run_terms(interpreter, frame, cursor.code, start, end)
        }
        if has_else {
            return run_terms(interpreter, frame, cursor.code, else_start, else_end)
        }
        return .Ok(.Next)
    }
    if opcode == 0xa1 {
        // An Else without an If before it: skipped, as its If's would be
        cursor.at = package_end(cursor)?
        return .Ok(.Next)
    }
    if opcode == 0xa2 {
        // While
        end :: package_end(cursor)?
        predicate :: cursor.at
        loop {
            enter(interpreter)?
            leave(interpreter)
            cursor.at = predicate
            if evaluate_integer(interpreter, frame, cursor)? == 0 {
                break
            }
            flow :: run_terms(interpreter, frame, cursor.code, cursor.at, end)?
            if flow == .Break {
                break
            }
            if flow == .Return {
                cursor.at = end
                return .Ok(.Return)
            }
        }
        cursor.at = end
        return .Ok(.Next)
    }
    if opcode == 0xa3 || opcode == 0xcc {
        // Noop, BreakPoint
        return .Ok(.Next)
    }
    if opcode == 0xa4 {
        // Return
        value :: evaluate_term(interpreter, frame, cursor)?
        frame.result = value
        return .Ok(.Return)
    }
    if opcode == 0xa5 {
        return .Ok(.Break)
    }
    if opcode == 0x9f {
        return .Ok(.Continue)
    }
    return .Error(.BadOpcode)
}

/**
 * Run a term list in another scope, as Scope, Device and the like do, the frame's scope put back after.
 *
 * @param interpreter The interpreter.
 * @param frame The frame, whose scope is node's while it runs.
 * @param node The scope.
 * @param cursor At the term list's start; moved to end.
 * @param end Where the term list ends.
 * @return How it ended.
 */
run_inside :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], node #escaping : ptr[mut Node], cursor: ptr[mut Cursor], end: usize) -> Result[Flow, Error] {
    outer :: frame.scope
    frame.scope = node
    flow :: run_terms(interpreter, frame, cursor.code, cursor.at, end)
    frame.scope = outer
    cursor.at = end
    return flow
}

/**
 * Run a two-byte definition or statement, its opcode read.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode's two bytes; moved past the term.
 * @param opcode The opcode's second byte, one is_extended_statement takes.
 * @return How it ended.
 */
run_extended_statement :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor], opcode: u8) -> Result[Flow, Error] {
    if opcode == 0x82 || opcode == 0x85 {
        // Device, ThermalZone
        end :: package_end(cursor)?
        name := read_name(cursor)?
        node :: define(interpreter, frame, &name, if opcode == 0x82 { NodeKind.Device } else { NodeKind.ThermalZone })?
        return run_inside(interpreter, frame, node, cursor, end)
    }
    if opcode == 0x83 {
        // Processor: its ID, its PBLK's address and length, then what's in it
        end :: package_end(cursor)?
        name := read_name(cursor)?
        _ = read_integer(cursor, 6)?
        node :: define(interpreter, frame, &name, .Processor)?
        return run_inside(interpreter, frame, node, cursor, end)
    }
    if opcode == 0x84 {
        // PowerResource: its system level and resource order, then what's in it
        end :: package_end(cursor)?
        name := read_name(cursor)?
        _ = read_integer(cursor, 3)?
        node :: define(interpreter, frame, &name, .PowerResource)?
        return run_inside(interpreter, frame, node, cursor, end)
    }
    if opcode == 0x80 {
        // OperationRegion
        name := read_name(cursor)?
        space :: read_byte(cursor)?
        offset :: evaluate_integer(interpreter, frame, cursor)?
        length :: evaluate_integer(interpreter, frame, cursor)?
        node :: define(interpreter, frame, &name, .Region)?
        node.space = space
        node.offset = offset
        node.length = length
        return .Ok(.Next)
    }
    if opcode == 0x88 {
        // DataTableRegion: a region over a firmware table, which isn't reached here; its fields fail as out of range
        name := read_name(cursor)?
        for argument in 0..<3 {
            _ = evaluate_term(interpreter, frame, cursor)?
        }
        node :: define(interpreter, frame, &name, .Region)?
        node.space = cast[u8](RegionSpace.SystemMemory)
        return .Ok(.Next)
    }
    if opcode == 0x81 || opcode == 0x86 || opcode == 0x87 {
        // Field, IndexField, BankField
        define_fields(interpreter, frame, cursor, opcode)?
        return .Ok(.Next)
    }
    if opcode == 0x01 {
        // Mutex
        name := read_name(cursor)?
        flags :: read_byte(cursor)?
        node :: define(interpreter, frame, &name, .Mutex)?
        node.sync_level = flags & 15
        return .Ok(.Next)
    }
    if opcode == 0x02 {
        // Event
        name := read_name(cursor)?
        _ = define(interpreter, frame, &name, .Event)?
        return .Ok(.Next)
    }
    if opcode == 0x13 {
        // CreateField: a buffer field of any bits
        source :: evaluate_term(interpreter, frame, cursor)?
        offset :: evaluate_integer(interpreter, frame, cursor)?
        bits :: evaluate_integer(interpreter, frame, cursor)?
        name := read_name(cursor)?
        return create_buffer_field(interpreter, frame, source, offset, bits, &name)
    }
    if opcode == 0x22 {
        // Sleep, in milliseconds
        milliseconds :: evaluate_integer(interpreter, frame, cursor)?
        interpreter.host.sleep(interpreter.host.state, if milliseconds < interpreter.limits.sleep_milliseconds { milliseconds } else { interpreter.limits.sleep_milliseconds })
        return .Ok(.Next)
    }
    if opcode == 0x21 {
        // Stall, in microseconds, at most 100
        microseconds :: evaluate_integer(interpreter, frame, cursor)?
        interpreter.host.stall(interpreter.host.state, if microseconds < 100 { microseconds } else { 100 })
        return .Ok(.Next)
    }
    if opcode == 0x24 || opcode == 0x26 || opcode == 0x27 {
        // Signal, Reset, Release
        node :: named_target(interpreter, frame, cursor)?
        if opcode == 0x27 {
            if node.kind != .Mutex {
                return .Error(.WrongType)
            }
            if node.count > 0 {
                node.count -= 1
            }
            return .Ok(.Next)
        }
        if node.kind != .Event {
            return .Error(.WrongType)
        }
        node.count = if opcode == 0x24 { node.count + 1 } else { 0 }
        return .Ok(.Next)
    }
    if opcode == 0x32 {
        // Fatal: its type, code and argument read, and the evaluation ended
        _ = read_byte(cursor)?
        _ = read_integer(cursor, 4)?
        _ = evaluate_term(interpreter, frame, cursor)?
        return .Error(.Fatal)
    }
    // Load, Unload
    return .Error(.Unsupported)
}

/**
 * The named object a SuperName names: what Signal, Release and the like act on.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor At the SuperName; moved past it.
 * @return The node, a reference to one followed.
 * @error WrongType A target that isn't a named object, nor a reference to one.
 */
named_target :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[ptr[mut Node], Error] {
    match read_target(interpreter, frame, cursor)? {
        case Named(node) => return .Ok(node)
        case Referred(value) => match value {
            case Reference(node) => return .Ok(node)
            case Object(node) => return .Ok(node)
            case _ => return .Error(.WrongType)
        }
        case Local(index) => match local_value(frame, index)? {
            case Reference(node) => return .Ok(node)
            case Object(node) => return .Ok(node)
            case _ => return .Error(.WrongType)
        }
        case Argument(index) => match argument_value(frame, index)? {
            case Reference(node) => return .Ok(node)
            case Object(node) => return .Ok(node)
            case _ => return .Error(.WrongType)
        }
        case _ => return .Error(.WrongType)
    }
    return .Error(.WrongType)
}

// ---- Expressions

/**
 * Evaluate a term that has to give an integer, converting what it gives.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor At the term; moved past it.
 * @return The integer, masked.
 */
evaluate_integer :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[u64, Error] {
    value :: evaluate_term(interpreter, frame, cursor)?
    return integer_of(interpreter, value)
}

/**
 * A local's value.
 *
 * @param frame The frame.
 * @param index 0 to 7.
 * @return The value, as it is: a reference in it isn't followed.
 * @error BadOpcode A table's load, which has no locals.
 */
local_value :: fn(frame: ptr[Frame], index: u8) -> Result[Value, Error] {
    locals :: frame.locals
    at :: cast[usize](index)
    if at >= locals.count {
        return .Error(.BadOpcode)
    }
    return .Ok(locals[at])
}

/**
 * An argument's value.
 *
 * @param frame The frame.
 * @param index 0 to 6.
 * @return The value, as it is.
 * @error BadOpcode A table's load, which has no arguments.
 */
argument_value :: fn(frame: ptr[Frame], index: u8) -> Result[Value, Error] {
    arguments :: frame.arguments
    at :: cast[usize](index)
    if at >= arguments.count {
        return .Error(.BadOpcode)
    }
    return .Ok(arguments[at])
}

/**
 * Evaluate a TermArg: a constant, a data object, a local or an argument, a name (a method called with its
 * arguments, a field read, a Name's value), or an expression.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor At the term; moved past it.
 * @return Its value. An argument holding a reference gives what it refers to; a local, the reference itself.
 */
evaluate_term :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Value, Error] #unrestricted {
    start :: cursor.at
    value :: evaluate_term_counted(interpreter, frame, cursor)
    match value {
        case Error(_) => note_failure(interpreter, cursor, start)
        case Ok(_) => {}
    }
    return value
}

/**
 * Evaluate a TermArg, counted as a step and a level of nesting, as evaluate_term does.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor At the term; moved past it.
 * @return Its value.
 */
evaluate_term_counted :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Value, Error] #unrestricted {
    enter(interpreter)?
    defer leave(interpreter)
    opcode :: peek_byte(cursor) or_return .Error(.Truncated)
    if starts_name(opcode) {
        name := read_name(cursor)?
        node :: resolve(interpreter, frame.scope, &name) or_return .Error(not_found(interpreter, &name))
        if node.kind == .Method || node.kind == .Builtin {
            arguments : Value[7]
            count :: cast[usize](node.argument_count)
            for i in 0..<arguments.count {
                arguments[i] = .Uninitialized
                if i < count {
                    arguments[i] = evaluate_term(interpreter, frame, cursor)?
                }
            }
            if count > arguments.count {
                return .Error(.BadOpcode)
            }
            return call(interpreter, frame, node, arguments[0..<count])
        }
        return value_of_node(interpreter, frame, node)
    }
    cursor.at += 1
    if opcode >= 0x60 && opcode <= 0x67 {
        return local_value(frame, opcode - 0x60)
    }
    if opcode >= 0x68 && opcode <= 0x6e {
        value :: argument_value(frame, opcode - 0x68)?
        return dereferenced(interpreter, frame, value)
    }
    match opcode {
        case 0x00 => return .Ok(.Integer(0))
        case 0x01 => return .Ok(.Integer(1))
        case 0xff => return .Ok(.Integer(ones(interpreter)))
        case 0x0a => return .Ok(.Integer(read_integer(cursor, 1)?))
        case 0x0b => return .Ok(.Integer(read_integer(cursor, 2)?))
        case 0x0c => return .Ok(.Integer(read_integer(cursor, 4)?))
        case 0x0e => return .Ok(.Integer(masked(interpreter, read_integer(cursor, 8)?)))
        case 0x0d => {
            // A string, to its 0
            start :: cursor.at
            loop {
                if read_byte(cursor)? == 0 {
                    break
                }
            }
            stop :: cursor.at - 1
            if start <= stop && stop <= cursor.code.count {
                return temporary_string(interpreter, cursor.code[start..<stop])
            }
            return .Error(.Truncated)
        }
        case 0x11 => return evaluate_buffer(interpreter, frame, cursor)
        case 0x12 => return evaluate_package(interpreter, frame, cursor, false)
        case 0x13 => return evaluate_package(interpreter, frame, cursor, true)
        case 0x5b => return evaluate_extended(interpreter, frame, cursor)
        case _ => return evaluate_operation(interpreter, frame, cursor, opcode)
    }
}

/**
 * What a reference refers to, read: a Name's value, a field read, an element or a byte; anything else as it is.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param value The value.
 * @return What it refers to, or itself.
 */
dereferenced :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], value #escaping : Value) -> Result[Value, Error] #unrestricted {
    match value {
        case Reference(node) => return value_of_node(interpreter, frame, node)
        case Element(slot) => return .Ok(slot.slot^)
        case Byte(byte) => {
            data :: byte.bytes.data
            at :: cast[usize](byte.index)
            if byte.index >= cast[u64](data.count) || at >= data.count {
                return .Error(.OutOfRange)
            }
            return .Ok(.Integer(cast[u64](data[at])))
        }
        case _ => return .Ok(value)
    }
}

/**
 * A node's value, as an operand reads it: a Name's value itself, a field read, a method called with no arguments; any
 * other named object as an Object.
 *
 * @param interpreter The interpreter.
 * @param frame The frame, whose scope a method called is called from.
 * @param node The node.
 * @return The value.
 */
value_of_node :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], node #escaping : ptr[mut Node]) -> Result[Value, Error] #unrestricted {
    match node.kind {
        case .Name => return .Ok(node.value)
        case .Field => return read_field(interpreter, frame, node)
        case .IndexField => return read_field(interpreter, frame, node)
        case .BankField => return read_field(interpreter, frame, node)
        case .BufferField => return read_buffer_field(interpreter, node)
        case .Method => return call(interpreter, frame, node, view_of(cast[ptr[Value]](null), 0))
        case .Alias => return value_of_node(interpreter, frame, resolved(node))
        case _ => return .Ok(.Object(node))
    }
}

/**
 * Evaluate a Buffer term, its opcode read: its size, then the bytes it starts with.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode; moved past the term.
 * @return The buffer, in the arena: its size's bytes, or as many as it starts with if they're more, the rest zero.
 */
evaluate_buffer :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Value, Error] #unrestricted {
    end :: package_end(cursor)?
    size :: evaluate_integer(interpreter, frame, cursor)?
    start :: cursor.at
    if start > end || end > cursor.code.count {
        return .Error(.Truncated)
    }
    given :: cursor.code[start..<end]
    made :: temporary_bytes(interpreter, if cast[u64](given.count) > size { cast[u64](given.count) } else { size })?
    copy_into(made.data, given)
    cursor.at = end
    return .Ok(.Buffer(made))
}

/**
 * Evaluate a Package or VarPackage term, its opcode read: its count of elements, then the elements given, each a data
 * object or a name, which is kept unresolved until it's used.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode; moved past the term.
 * @param variable Whether it's a VarPackage, whose count is a term rather than a byte.
 * @return The package, in the arena: its count's elements, or as many as given if they're more, the rest
 *     Uninitialized.
 */
evaluate_package :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor], variable: bool) -> Result[Value, Error] #unrestricted {
    end :: package_end(cursor)?
    count :: if variable { evaluate_integer(interpreter, frame, cursor)? } else { cast[u64](read_byte(cursor)?) }
    elements : Value[..]
    defer runtime.array_free(&elements)
    inner := Cursor.{code = cursor.code, at = cursor.at, end = end}
    loop {
        if inner.at >= end {
            break
        }
        first :: peek_byte(&inner) or_return .Error(.Truncated)
        if starts_name(first) {
            name := read_name(&inner)?
            if spend(interpreter, size_of(PathName)) is_some {
                return .Error(.Memory)
            }
            path, error :: runtime.new_aligned(PathName, align_of(PathName), memory.arena_allocator(interpreter.arena))
            if error != null {
                return .Error(.Memory)
            }
            path^ = PathName.{scope = frame.scope, path = name_bytes(cursor.code, &name)}
            if runtime.array_try_add(&elements, Value.Path(path)) is_some {
                return .Error(.Memory)
            }
        }
        else if runtime.array_try_add(&elements, evaluate_term(interpreter, frame, &inner)?) is_some {
            return .Error(.Memory)
        }
    }
    total :: if cast[u64](elements.count) > count { cast[u64](elements.count) } else { count }
    made :: temporary_package(interpreter, total)?
    made_elements :: made.elements
    for element, i in elements {
        if i < made_elements.count {
            made_elements[i] = element
        }
    }
    cursor.at = end
    return .Ok(.Package(made))
}

/**
 * The bytes a name was read from, as a NameString encodes it again for PathName.
 *
 * @param code The bytecode it was read from.
 * @param name The name, whose segments are a view into code.
 * @return The bytes: its prefixes, then its segments with the prefix their count needs.
 */
name_bytes :: fn(code: u8[], name: ptr[NameString]) -> u8[] {
    start :: name.start
    stop :: name.stop
    if start <= stop && stop <= code.count {
        return code[start..<stop]
    }
    return code[0..<0]
}

/**
 * Resolve a name a package holds, from where the package was defined.
 *
 * @param interpreter The interpreter.
 * @param path The name.
 * @return The node; null if there's none.
 */
resolve_path :: fn(interpreter: ptr[mut Interpreter], path: ptr[PathName]) -> ptr[mut Node]? {
    cursor := Cursor.{code = path.path, at = 0, end = path.path.count}
    match read_name(&cursor) {
        case Ok(name) => {
            found := name
            return resolve(interpreter, path.scope, &found)
        }
        case Error(_) => return null
    }
}

/**
 * Evaluate a two-byte expression, its first byte, 0x5b, read.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past 0x5b; moved past the term.
 * @return Its value.
 */
evaluate_extended :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Value, Error] #unrestricted {
    opcode :: read_byte(cursor)?
    if opcode == 0x30 {
        // Revision: this interpreter's
        return .Ok(.Integer(REVISION))
    }
    if opcode == 0x31 {
        return .Ok(.Debug)
    }
    if opcode == 0x33 {
        // Timer
        return .Ok(.Integer(interpreter.host.timer(interpreter.host.state)))
    }
    if opcode == 0x12 {
        // CondRefOf: whether the name's there, and a reference to it stored if it is
        name_or_target :: peek_byte(cursor) or_return .Error(.Truncated)
        found : Value = .Uninitialized
        if starts_name(name_or_target) {
            name := read_name(cursor)?
            match resolve(interpreter, frame.scope, &name) {
                case Some(node) => found = .Reference(node)
                case None => {}
            }
        }
        else {
            match read_target(interpreter, frame, cursor)? {
                case Local(index) => found = .Element(local_reference(frame, index)?)
                case Argument(index) => found = .Element(argument_reference(frame, index)?)
                case Named(node) => found = .Reference(node)
                case Referred(value) => found = value
                case _ => {}
            }
        }
        target :: read_target(interpreter, frame, cursor)?
        match found {
            case Uninitialized => return .Ok(.Integer(0))
            case _ => {
                store(interpreter, frame, found, target)?
                return .Ok(.Integer(ones(interpreter)))
            }
        }
    }
    if opcode == 0x23 {
        // Acquire: the one thread evaluating always gets it, as many times as it asks
        node :: named_target(interpreter, frame, cursor)?
        _ = read_integer(cursor, 2)?
        if node.kind != .Mutex {
            return .Error(.WrongType)
        }
        node.count += 1
        return .Ok(.Integer(0))
    }
    if opcode == 0x25 {
        // Wait: no other thread can signal it while this one waits, so it times out unless it's signaled already
        node :: named_target(interpreter, frame, cursor)?
        _ = evaluate_integer(interpreter, frame, cursor)?
        if node.kind != .Event {
            return .Error(.WrongType)
        }
        if node.count > 0 {
            node.count -= 1
            return .Ok(.Integer(0))
        }
        return .Ok(.Integer(ones(interpreter)))
    }
    if opcode == 0x28 || opcode == 0x29 {
        // FromBCD, ToBCD
        value :: evaluate_integer(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: if opcode == 0x28 { from_bcd(value) } else { to_bcd(value) }
        store(interpreter, frame, .Integer(masked(interpreter, result)), target)?
        return .Ok(.Integer(masked(interpreter, result)))
    }
    if opcode == 0x1f {
        // LoadTable
        return .Error(.Unsupported)
    }
    return .Error(.BadOpcode)
}

/** What Revision gives: this interpreter's version, as a date. */
REVISION : u64 : 0x20261107

/**
 * Read binary-coded decimal.
 *
 * @param value The BCD, a decimal digit each 4 bits.
 * @return Its number; a nibble past 9 counts as its value.
 */
from_bcd :: fn(value: u64) -> u64 {
    result : u64 = 0
    scale : u64 = 1
    for i in 0..<16 {
        result += ((value >> (4 * cast[u64](i))) & 15) * scale
        scale *= 10
    }
    return result
}

/**
 * Write a number as binary-coded decimal.
 *
 * @param value The number.
 * @return Its BCD, a decimal digit each 4 bits; its digits past 16 are lost.
 */
to_bcd :: fn(value: u64) -> u64 {
    result : u64 = 0
    rest := value
    for i in 0..<16 {
        result |= (rest % 10) << (4 * cast[u64](i))
        rest /= 10
    }
    return result
}

// ---- Targets and storing

/**
 * Read a target or SuperName: where a value's stored, or what an operation acts on.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor At it; moved past it.
 * @return The target: a name isn't called, even a method's.
 * @error NotFound A name that isn't there.
 * @error WrongType A term that gives no reference.
 */
read_target :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Target, Error] {
    opcode :: peek_byte(cursor) or_return .Error(.Truncated)
    if opcode == 0x00 {
        cursor.at += 1
        return .Ok(.Nothing)
    }
    if opcode >= 0x60 && opcode <= 0x67 {
        cursor.at += 1
        return .Ok(.Local(opcode - 0x60))
    }
    if opcode >= 0x68 && opcode <= 0x6e {
        cursor.at += 1
        return .Ok(.Argument(opcode - 0x68))
    }
    if opcode == 0x5b && (peek_byte(cursor, 1) or_else 0) == 0x31 {
        cursor.at += 2
        return .Ok(.Debug)
    }
    if starts_name(opcode) {
        name := read_name(cursor)?
        return .Ok(.Named(resolve(interpreter, frame.scope, &name) or_return .Error(not_found(interpreter, &name))))
    }
    value :: evaluate_term(interpreter, frame, cursor)?
    match value {
        case Reference(_) => return .Ok(.Referred(value))
        case Element(_) => return .Ok(.Referred(value))
        case Byte(_) => return .Ok(.Referred(value))
        case Object(node) => return .Ok(.Named(node))
        case _ => return .Error(.WrongType)
    }
}

/**
 * A reference to a local, as RefOf makes.
 *
 * @param frame The frame.
 * @param index 0 to 7.
 * @return The reference.
 * @error BadOpcode A table's load, which has no locals.
 */
local_reference :: fn(frame: ptr[mut Frame], index: u8) -> Result[ElementReference, Error] {
    locals :: frame.locals
    at :: cast[usize](index)
    if at >= locals.count {
        return .Error(.BadOpcode)
    }
    return .Ok(ElementReference.{slot = &locals[at], persistent = false})
}

/**
 * A reference to an argument, as RefOf makes.
 *
 * @param frame The frame.
 * @param index 0 to 6.
 * @return The reference.
 * @error BadOpcode A table's load, which has no arguments.
 */
argument_reference :: fn(frame: ptr[mut Frame], index: u8) -> Result[ElementReference, Error] {
    arguments :: frame.arguments
    at :: cast[usize](index)
    if at >= arguments.count {
        return .Error(.BadOpcode)
    }
    return .Ok(ElementReference.{slot = &arguments[at], persistent = false})
}

/**
 * The value a target holds now, as Increment reads it: a reference in a local or an argument followed.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param target The target.
 * @return The value.
 * @error WrongType Nothing, or the debug object.
 */
target_value :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], target #escaping : Target) -> Result[Value, Error] #unrestricted {
    match target {
        case Local(index) => return dereferenced(interpreter, frame, local_value(frame, index)?)
        case Argument(index) => return dereferenced(interpreter, frame, argument_value(frame, index)?)
        case Named(node) => return value_of_node(interpreter, frame, node)
        case Referred(value) => return dereferenced(interpreter, frame, value)
        case _ => return .Error(.WrongType)
    }
}

/**
 * Store a value into a target (ACPI 6.5 §19.3.5.8): into a local, replacing what it held; into an argument, or
 * through a reference an argument holds; into a Name, converted to its value's type if that's an integer, a string
 * or a buffer (a buffer kept at its length, cut or padded with zeros); into a field, written; into an element,
 * replacing it; into a byte, its low 8 bits; into the debug object, shown to the host.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param value The value; copied wherever it's kept.
 * @param target Where it goes.
 * @error WrongType A target that can't hold it.
 * @error Memory What it's copied into can't hold it.
 */
store :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], value #escaping : Value, target: Target) -> Result[void, Error] {
    match target {
        case Nothing => return .Ok
        case Debug => {
            show(interpreter, value)
            return .Ok
        }
        case Local(index) => {
            slot :: local_reference(frame, index)?
            slot.slot^ = temporary_copy(interpreter, value)?
            return .Ok
        }
        case Argument(index) => {
            slot :: argument_reference(frame, index)?
            match slot.slot^ {
                case Reference(_) => return store(interpreter, frame, value, .Referred(slot.slot^))
                case Element(_) => return store(interpreter, frame, value, .Referred(slot.slot^))
                case Byte(_) => return store(interpreter, frame, value, .Referred(slot.slot^))
                case _ => {
                    slot.slot^ = temporary_copy(interpreter, value)?
                    return .Ok
                }
            }
        }
        case Named(node) => return store_to_node(interpreter, frame, value, node)
        case Referred(referred) => match referred {
            case Reference(node) => return store_to_node(interpreter, frame, value, node)
            case Element(element) => {
                if element.persistent {
                    kept :: persist(interpreter, value)?
                    release_persistent(interpreter, element.slot^)
                    element.slot^ = kept
                }
                else {
                    element.slot^ = temporary_copy(interpreter, value)?
                }
                return .Ok
            }
            case Byte(byte) => {
                number :: integer_of(interpreter, value)?
                data :: byte.bytes.data
                at :: cast[usize](byte.index)
                if byte.index >= cast[u64](data.count) || at >= data.count {
                    return .Error(.OutOfRange)
                }
                data[at] = cast[u8](number & 0xff)
                return .Ok
            }
            case _ => return .Error(.WrongType)
        }
    }
    return .Error(.WrongType)
}

/**
 * Store a value into a named object, as store does.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param value The value.
 * @param node The object.
 */
store_to_node :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], value #escaping : Value, node: ptr[mut Node]) -> Result[void, Error] {
    match node.kind {
        case .Name => {
            match node.value {
                case Integer(_) => {
                    node.value = .Integer(integer_of(interpreter, value)?)
                    return .Ok
                }
                case Buffer(bytes) => {
                    source :: buffer_of(interpreter, value)?
                    data :: bytes.data
                    for i in 0..<data.count {
                        data[i] = 0
                    }
                    copy_into(data, source.data)
                    return .Ok
                }
                case String(_) => {
                    kept :: persist(interpreter, .String(string_of_value(interpreter, value)?))?
                    release_persistent(interpreter, node.value)
                    node.value = kept
                    return .Ok
                }
                case _ => {
                    kept :: persist(interpreter, value)?
                    release_persistent(interpreter, node.value)
                    node.value = kept
                    return .Ok
                }
            }
        }
        case .Field => return write_field(interpreter, frame, node, value)
        case .IndexField => return write_field(interpreter, frame, node, value)
        case .BankField => return write_field(interpreter, frame, node, value)
        case .BufferField => return write_buffer_field(interpreter, node, value)
        case .Alias => return store_to_node(interpreter, frame, value, resolved(node))
        case _ => return .Error(.WrongType)
    }
}

/**
 * Show a value to the host, as storing it to the debug object does.
 *
 * @param interpreter The interpreter, whose host's debug is called.
 * @param value The value: an integer in hex, a string as it is, a buffer's bytes in hex, anything else by its type.
 */
show :: fn(interpreter: ptr[mut Interpreter], value: Value) {
    storage : u8[256]
    out := text_buffer.make(storage)
    match value {
        case Integer(number) => {
            text_buffer.append(&out, "0x")
            text_buffer.append_unsigned(&out, number, 16)
        }
        case String(text) => text_buffer.append(&out, text_of(text.data))
        case Buffer(bytes) => {
            text_buffer.append(&out, "buffer:")
            for byte in bytes.data {
                text_buffer.append(&out, " ")
                text_buffer.append_unsigned(&out, cast[u64](byte), 16, 2)
            }
        }
        case Package(package) => {
            text_buffer.append(&out, "package of ")
            text_buffer.append_unsigned(&out, cast[u64](package.elements.count))
        }
        case Object(node) => write_path(&out, node)
        case Reference(node) => {
            text_buffer.append(&out, "reference to ")
            write_path(&out, node)
        }
        case _ => text_buffer.append(&out, "a reference")
    }
    interpreter.host.debug(interpreter.host.state, text_buffer.as_string(&out))
}

// ---- Calling methods

/**
 * Call a method with arguments: its body run in a frame of its own, in its scope, the objects it made removed when it
 * returns.
 *
 * @param interpreter The interpreter.
 * @param caller The frame it's called from.
 * @param method The method, or a builtin.
 * @param arguments Its arguments, copied; as many as it takes are used, Uninitialized for any not given.
 * @return What it returned; Uninitialized if it returned nothing.
 * @error Depth Methods are called as deep as they may be.
 */
call :: fn(interpreter: ptr[mut Interpreter], caller: ptr[mut Frame], method #escaping : ptr[mut Node], arguments: Value[]) -> Result[Value, Error] #unrestricted {
    if method.kind == .Builtin {
        return osi(interpreter, arguments)
    }
    if interpreter.calls >= interpreter.limits.calls {
        return .Error(.Depth)
    }
    allocator :: memory.arena_allocator(interpreter.arena)
    if spend(interpreter, 15 * size_of(Value)) is_some {
        return .Error(.Memory)
    }
    locals, locals_error :: runtime.new_array(Value, 8, allocator)
    passed, passed_error :: runtime.new_array(Value, 7, allocator)
    if locals_error != null || passed_error != null {
        return .Error(.Memory)
    }
    for &local in locals {
        local^ = .Uninitialized
    }
    for i in 0..<passed.count {
        passed[i] = .Uninitialized
        if i < arguments.count && i < cast[usize](method.argument_count) {
            passed[i] = temporary_copy(interpreter, arguments[i])?
        }
    }
    frame := Frame.{scope = method, method = method, locals = locals, arguments = passed, result = .Uninitialized}
    interpreter.calls += 1
    flow :: run_terms(interpreter, &frame, method.body, 0, method.body.count)
    interpreter.calls -= 1
    // The objects it made go, whether it returned or failed
    loop {
        made :: frame.made or_break
        frame.made = made.made_before
        remove_node(interpreter, made)
    }
    match flow {
        case Ok(how) => return .Ok(if how == .Return { frame.result } else { Value.Uninitialized })
        case Error(error) => return .Error(error)
    }
}

/**
 * Answer `\_OSI`: whether the interface named is one the interpreter claims.
 *
 * @param interpreter The interpreter, whose interfaces are claimed beside WINDOWS_INTERFACES.
 * @param arguments Its argument, a string.
 * @return Ones if it's claimed, 0 if not.
 * @error WrongType An argument that isn't a string.
 */
osi :: fn(interpreter: ptr[mut Interpreter], arguments: Value[]) -> Result[Value, Error] #unrestricted {
    if arguments.count == 0 {
        return .Error(.WrongType)
    }
    match arguments[0] {
        case String(text) => {
            asked :: text_of(text.data)
            for known in WINDOWS_INTERFACES {
                if known == asked {
                    return .Ok(.Integer(ones(interpreter)))
                }
            }
            for known in interpreter.interfaces {
                if known == asked {
                    return .Ok(.Integer(ones(interpreter)))
                }
            }
            return .Ok(.Integer(0))
        }
        case _ => return .Error(.WrongType)
    }
}
