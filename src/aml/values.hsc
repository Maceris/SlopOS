package aml

import runtime from "base"
import memory from "std"

/*
 * AML's values. A string's, a buffer's and a package's contents are on one of two allocators: the evaluation's arena,
 * for what a method makes along the way, emptied when the evaluation ends; or the heap, for what the namespace keeps,
 * a Name's value and what's in it, each owned by its one holder and given back when that's replaced. Storing into the
 * namespace copies a value onto the heap (persist); reading a Name gives its value itself, so Index of it reaches its
 * own elements, and storing it into a local copies it into the arena.
 */

/** A string's or a buffer's bytes; a string's without its terminating 0. */
Bytes :: struct {
    /** The bytes, which a buffer field and Index reach in place. */
    data : mut u8[],
    /** Whether they're on the heap, kept by the namespace, rather than in the arena. */
    persistent : bool,
}

/** A package's elements. */
Package :: struct {
    /** The elements; an element Index reaches in place. */
    elements : mut Value[],
    /** Whether they're on the heap, kept by the namespace, rather than in the arena. */
    persistent : bool,
}

/** A reference to a value in a slot: a package's element, a local or an argument. */
ElementReference :: struct {
    /** The slot. */
    slot : ptr[mut Value],
    /** Whether it's a persistent package's element, so what's stored into it is copied onto the heap. */
    persistent : bool,
}

/** A reference to a byte of a buffer or a string, as Index of one makes. */
ByteReference :: struct {
    /** The buffer or string. */
    bytes : ptr[mut Bytes],
    /** The byte's index, below its count when it was made. */
    index : u64,
    /** Whether it's a string's byte, which ObjectType says it is as a buffer field's. */
    string : bool,
}

/** A name in a package, not resolved until it's used (ACPI 6.5 §19.6.102): where it was written, and the name. */
PathName :: struct {
    /** The scope the package was defined in, which the name's resolved from. */
    scope : ptr[mut Node],
    /** The name's bytes, as AML encodes a NameString. */
    path : u8[],
}

/** A value, as AML's terms make and take them. */
Value :: union {
    /** No value: an uninitialized local or argument, or what a method that returns nothing gives. */
    Uninitialized,
    /** An integer, 64 bits, or 32 before a DSDT says otherwise (masked to them). */
    Integer(u64),
    /** A string. */
    String(ptr[mut Bytes]),
    /** A buffer. */
    Buffer(ptr[mut Bytes]),
    /** A package. */
    Package(ptr[mut Package]),
    /** A named object that holds no data of its own, as an operand: a device, a mutex, a method, a region. */
    Object(ptr[mut Node]),
    /** A reference to a named object, as RefOf makes. */
    Reference(ptr[mut Node]),
    /** A reference to a package's element, or to a local or an argument, as Index and RefOf make. */
    Element(ElementReference),
    /** A reference to a byte of a buffer or a string, as Index makes. */
    Byte(ByteReference),
    /** A name in a package, resolved when it's used. */
    Path(ptr[mut PathName]),
    /** The debug object, which a value stored to is shown to the host. */
    Debug,
}

/**
 * Mask an integer to the interpreter's width.
 *
 * @param interpreter The interpreter, whose wide says the width.
 * @param value The integer.
 * @return It, cut to 32 bits unless integers are 64.
 */
masked :: fn(interpreter: ptr[Interpreter], value: u64) -> u64 {
    return if interpreter.wide { value } else { value & 0xffffffff }
}

/**
 * The integer with every bit set, Ones, at the interpreter's width.
 *
 * @param interpreter The interpreter.
 * @return All ones, 64 or 32 bits of them.
 */
ones :: fn(interpreter: ptr[Interpreter]) -> u64 {
    return masked(interpreter, 0xffffffffffffffff)
}

/**
 * The bytes an integer is, as a buffer: 8, or 4 at 32 bits.
 *
 * @param interpreter The interpreter.
 * @return 8 or 4.
 */
integer_bytes :: fn(interpreter: ptr[Interpreter]) -> usize {
    return if interpreter.wide { 8 } else { 4 }
}

// ---- Making values

/**
 * Count bytes against the evaluation's budget.
 *
 * @param interpreter The interpreter, whose evaluation_bytes grow.
 * @param size The bytes about to be taken.
 * @return Null if they fit; Memory if they'd pass limits.evaluation_bytes.
 */
spend :: fn(interpreter: ptr[mut Interpreter], size: usize) -> Error? {
    if size > interpreter.limits.evaluation_bytes || interpreter.evaluation_bytes > interpreter.limits.evaluation_bytes - size {
        return .Memory
    }
    interpreter.evaluation_bytes += size
    return null
}

/**
 * Make bytes in the evaluation's arena, zeroed.
 *
 * @param interpreter The interpreter.
 * @param count How many.
 * @return The bytes, good until the evaluation ends.
 * @error Memory The evaluation's budget, or the heap, can't hold them.
 */
temporary_bytes :: fn(interpreter: ptr[mut Interpreter], count: u64) -> Result[ptr[mut Bytes], Error] #unrestricted {
    if count > cast[u64](interpreter.limits.evaluation_bytes) {
        return .Error(.Memory)
    }
    size :: cast[usize](count)
    if spend(interpreter, size + size_of(Bytes)) is_some {
        return .Error(.Memory)
    }
    allocator :: memory.arena_allocator(interpreter.arena)
    made, error :: runtime.new_aligned(Bytes, align_of(Bytes), allocator)
    if error != null {
        return .Error(.Memory)
    }
    data, data_error :: runtime.new_array(u8, size, allocator)
    if data_error != null {
        return .Error(.Memory)
    }
    made^ = Bytes.{data = data, persistent = false}
    return .Ok(made)
}

/**
 * Make a package in the evaluation's arena, its elements Uninitialized.
 *
 * @param interpreter The interpreter.
 * @param count How many elements.
 * @return The package, good until the evaluation ends.
 * @error Memory The evaluation's budget, or the heap, can't hold it.
 */
temporary_package :: fn(interpreter: ptr[mut Interpreter], count: u64) -> Result[ptr[mut Package], Error] #unrestricted {
    if count > cast[u64](interpreter.limits.evaluation_bytes / size_of(Value)) {
        return .Error(.Memory)
    }
    size :: cast[usize](count)
    if spend(interpreter, size * size_of(Value) + size_of(Package)) is_some {
        return .Error(.Memory)
    }
    allocator :: memory.arena_allocator(interpreter.arena)
    made, error :: runtime.new_aligned(Package, align_of(Package), allocator)
    if error != null {
        return .Error(.Memory)
    }
    elements, elements_error :: runtime.new_array(Value, size, allocator)
    if elements_error != null {
        return .Error(.Memory)
    }
    for &element in elements {
        element^ = .Uninitialized
    }
    made^ = Package.{elements = elements, persistent = false}
    return .Ok(made)
}

/**
 * Make a string in the evaluation's arena from text.
 *
 * @param interpreter The interpreter.
 * @param text The text, copied.
 * @return The string.
 * @error Memory The evaluation's budget, or the heap, can't hold it.
 */
temporary_string :: fn(interpreter: ptr[mut Interpreter], text: u8[]) -> Result[Value, Error] #unrestricted {
    made :: temporary_bytes(interpreter, cast[u64](text.count))?
    data :: made.data
    for byte, i in text {
        if i < data.count {
            data[i] = byte
        }
    }
    return .Ok(.String(made))
}

/**
 * Count bytes against the namespace's budget.
 *
 * @param interpreter The interpreter, whose namespace_bytes grow.
 * @param size The bytes about to be taken.
 * @return Null if they fit; Memory if they'd pass limits.namespace_bytes.
 */
keep :: fn(interpreter: ptr[mut Interpreter], size: usize) -> Error? {
    if size > interpreter.limits.namespace_bytes || interpreter.namespace_bytes > interpreter.limits.namespace_bytes - size {
        return .Memory
    }
    interpreter.namespace_bytes += size
    return null
}

/**
 * Make bytes on the heap for the namespace, counted against its budget, zeroed.
 *
 * @param interpreter The interpreter.
 * @param count How many.
 * @return data The bytes, the caller's to give back with runtime.free_array and namespace_bytes lessened; empty on an
 *     error.
 * @return failed Null, or Memory if the budget or the heap can't hold them.
 */
persistent_bytes :: fn(interpreter: ptr[mut Interpreter], count: usize) -> (data #unrestricted : mut u8[], failed : Error?) {
    empty : mut u8[]
    if keep(interpreter, count) is_some {
        return empty, .Memory
    }
    data, error :: runtime.new_array(u8, count)
    if error != null {
        interpreter.namespace_bytes -= count
        return empty, .Memory
    }
    return data, null
}

/**
 * Make a Bytes on the heap for the namespace.
 *
 * @param interpreter The interpreter.
 * @param count How many bytes.
 * @return The Bytes, persistent, its bytes zero; null if the budget or the heap can't hold it.
 */
persistent_block :: fn(interpreter: ptr[mut Interpreter], count: usize) -> ptr[mut Bytes]? #unrestricted {
    if keep(interpreter, size_of(Bytes)) is_some {
        return null
    }
    made, error :: runtime.new_aligned(Bytes, align_of(Bytes))
    if error != null {
        interpreter.namespace_bytes -= size_of(Bytes)
        return null
    }
    data, failed :: persistent_bytes(interpreter, count)
    if failed is_some {
        runtime.free_aligned(made, align_of(Bytes))
        interpreter.namespace_bytes -= size_of(Bytes)
        return null
    }
    made^ = Bytes.{data = data, persistent = true}
    return made
}

/**
 * Make a string on the heap for the namespace.
 *
 * @param interpreter The interpreter.
 * @param text The text, copied.
 * @return The string, persistent; null if the budget or the heap can't hold it.
 */
persistent_string :: fn(interpreter: ptr[mut Interpreter], text: string) -> Value? #unrestricted {
    bytes :: string_bytes(text)
    made :: persistent_block(interpreter, bytes.count) or_return null
    data :: made.data
    for byte, i in bytes {
        if i < data.count {
            data[i] = byte
        }
    }
    return .String(made)
}

/**
 * Copy a value onto the heap for the namespace, deeply: a package's elements are copied too. References and objects
 * are kept as they are, as they name nodes, which live in the namespace already.
 *
 * @param interpreter The interpreter.
 * @param value The value.
 * @param depth How deep in packages it is; past 32, it's too deep to copy.
 * @return The copy, owned by whoever it's stored in, given back with release_persistent.
 * @error Memory The namespace's budget, or the heap, can't hold it.
 * @error Depth Packages nested more than 32 deep.
 */
persist :: fn(interpreter: ptr[mut Interpreter], value #escaping : Value, depth: u32 = 0) -> Result[Value, Error] #unrestricted {
    if depth > 32 {
        return .Error(.Depth)
    }
    match value {
        case String(text) => return .Ok(.String(persistent_copy(interpreter, text)?))
        case Buffer(bytes) => return .Ok(.Buffer(persistent_copy(interpreter, bytes)?))
        case Package(package) => {
            count :: package.elements.count
            if keep(interpreter, size_of(Package) + count * size_of(Value)) is_some {
                return .Error(.Memory)
            }
            made, error :: runtime.new_aligned(Package, align_of(Package))
            elements, elements_error :: runtime.new_array(Value, count)
            if error != null || elements_error != null {
                return .Error(.Memory)
            }
            for &element in elements {
                element^ = .Uninitialized
            }
            made^ = Package.{elements = elements, persistent = true}
            source :: package.elements
            for i in 0..<elements.count {
                if i < source.count {
                    elements[i] = persist(interpreter, source[i], depth + 1)?
                }
            }
            return .Ok(.Package(made))
        }
        case Path(name) => {
            if keep(interpreter, size_of(PathName)) is_some {
                return .Error(.Memory)
            }
            made, error :: runtime.new_aligned(PathName, align_of(PathName))
            if error != null {
                return .Error(.Memory)
            }
            path, failed :: persistent_bytes(interpreter, name.path.count)
            if failed is_some {
                return .Error(.Memory)
            }
            for byte, i in name.path {
                if i < path.count {
                    path[i] = byte
                }
            }
            made^ = PathName.{scope = name.scope, path = path}
            return .Ok(.Path(made))
        }
        case _ => return .Ok(value)
    }
}

/**
 * Copy a Bytes onto the heap.
 *
 * @param interpreter The interpreter.
 * @param bytes The bytes.
 * @return The copy, persistent.
 * @error Memory The namespace's budget, or the heap, can't hold it.
 */
persistent_copy :: fn(interpreter: ptr[mut Interpreter], bytes: ptr[Bytes]) -> Result[ptr[mut Bytes], Error] #unrestricted {
    made :: persistent_block(interpreter, bytes.data.count) or_return .Error(.Memory)
    data :: made.data
    for byte, i in bytes.data {
        if i < data.count {
            data[i] = byte
        }
    }
    return .Ok(made)
}

/**
 * Give back what a persistent value holds on the heap, deeply; a temporary value, or one without contents, is left.
 *
 * @param interpreter The interpreter, whose namespace_bytes are lessened.
 * @param value The value, which mustn't be used after.
 */
release_persistent :: fn(interpreter: ptr[mut Interpreter], value: Value) {
    match value {
        case String(bytes) => release_bytes(interpreter, bytes)
        case Buffer(bytes) => release_bytes(interpreter, bytes)
        case Package(package) => {
            if !package.persistent {
                return void
            }
            for element in package.elements {
                release_persistent(interpreter, element)
            }
            interpreter.namespace_bytes -= size_of(Package) + package.elements.count * size_of(Value)
            runtime.free_array(package.elements)
            runtime.free_aligned(package, align_of(Package))
        }
        case Path(name) => {
            // A path's never temporary once it's in a persistent package; those in the arena aren't given back here
            interpreter.namespace_bytes -= size_of(PathName) + name.path.count
            runtime.free_array(name.path)
            runtime.free_aligned(name, align_of(PathName))
        }
        case _ => {}
    }
}

/**
 * Give back a persistent Bytes.
 *
 * @param interpreter The interpreter, whose namespace_bytes are lessened.
 * @param bytes The bytes; a temporary one is left.
 */
release_bytes :: fn(interpreter: ptr[mut Interpreter], bytes: ptr[mut Bytes]) {
    if !bytes.persistent {
        return void
    }
    interpreter.namespace_bytes -= size_of(Bytes) + bytes.data.count
    runtime.free_array(bytes.data)
    runtime.free_aligned(bytes, align_of(Bytes))
}

/**
 * Copy a value into the evaluation's arena, deeply, as storing it into a local does.
 *
 * @param interpreter The interpreter.
 * @param value The value.
 * @param depth How deep in packages it is; past 32, it's too deep to copy.
 * @return The copy; references and objects as they are.
 * @error Memory The evaluation's budget can't hold it.
 * @error Depth Packages nested more than 32 deep.
 */
temporary_copy :: fn(interpreter: ptr[mut Interpreter], value #escaping : Value, depth: u32 = 0) -> Result[Value, Error] #unrestricted {
    if depth > 32 {
        return .Error(.Depth)
    }
    match value {
        case String(text) => {
            made :: temporary_bytes(interpreter, cast[u64](text.data.count))?
            copy_into(made.data, text.data)
            return .Ok(.String(made))
        }
        case Buffer(bytes) => {
            made :: temporary_bytes(interpreter, cast[u64](bytes.data.count))?
            copy_into(made.data, bytes.data)
            return .Ok(.Buffer(made))
        }
        case Package(package) => {
            made :: temporary_package(interpreter, cast[u64](package.elements.count))?
            elements :: made.elements
            source :: package.elements
            for i in 0..<elements.count {
                if i < source.count {
                    elements[i] = temporary_copy(interpreter, source[i], depth + 1)?
                }
            }
            return .Ok(.Package(made))
        }
        case _ => return .Ok(value)
    }
}

/**
 * Bytes as text, for comparing and showing them.
 *
 * @param bytes The bytes.
 * @return A string viewing them; empty for none.
 */
text_of :: fn(bytes: u8[]) -> string {
    if bytes.count == 0 {
        return ""
    }
    return string_of(&bytes[0], bytes.count)
}

/**
 * Copy bytes, as many as both have.
 *
 * @param into Where they're copied to.
 * @param from Where they're copied from.
 */
copy_into :: fn(into: mut u8[], from: u8[]) {
    for byte, i in from {
        if i < into.count {
            into[i] = byte
        }
    }
}

// ---- Conversions (ACPI 6.5 §19.3.5)

/**
 * Convert a value to an integer, as an operand that has to be one is.
 *
 * A string is read as hexadecimal, up to its first character that isn't a hex digit (an optional "0x" first); a buffer
 * is its first 8 bytes, or 4 at 32 bits, little-endian, fewer if it has fewer.
 *
 * @param interpreter The interpreter.
 * @param value The value, already resolved to data: not a field or a reference.
 * @return The integer, masked.
 * @error WrongType A package, an object, a reference, or Uninitialized.
 */
integer_of :: fn(interpreter: ptr[Interpreter], value: Value) -> Result[u64, Error] {
    match value {
        case Integer(number) => return .Ok(masked(interpreter, number))
        case String(text) => return .Ok(masked(interpreter, hexadecimal(text.data)))
        case Buffer(bytes) => {
            number : u64 = 0
            for i in 0..<integer_bytes(interpreter) {
                if i < bytes.data.count {
                    number |= cast[u64](bytes.data[i]) << (8 * cast[u64](i))
                }
            }
            return .Ok(number)
        }
        case _ => return .Error(.WrongType)
    }
}

/**
 * Read text as hexadecimal, as an implicit conversion of a string to an integer does.
 *
 * @param text The text: an optional "0x" or "0X", then hex digits; it stops at the first that isn't one.
 * @return The number, its digits past 16 shifted out.
 */
hexadecimal :: fn(text: u8[]) -> u64 {
    number : u64 = 0
    start : usize = 0
    if text.count >= 2 && text[0] == cast[u8]('0') && (text[1] == cast[u8]('x') || text[1] == cast[u8]('X')) {
        start = 2
    }
    for i in start..<text.count {
        digit :: digit_value(text[i])
        if digit >= 16 {
            break
        }
        number = (number << 4) | digit
    }
    return number
}

/**
 * Read text as a decimal or, with "0x", hexadecimal number, as ToInteger does.
 *
 * @param text The text, leading spaces skipped; it stops at the first character that isn't a digit of its base.
 * @return The number, wrapping past 64 bits.
 */
explicit_integer :: fn(text: u8[]) -> u64 {
    start : usize = 0
    loop {
        if start >= text.count || text[start] != cast[u8](' ') {
            break
        }
        start += 1
    }
    if start + 1 < text.count && text[start] == cast[u8]('0') && (text[start + 1] == cast[u8]('x') || text[start + 1] == cast[u8]('X')) {
        return hexadecimal(text[start..<text.count])
    }
    number : u64 = 0
    for i in start..<text.count {
        digit :: digit_value(text[i])
        if digit >= 10 {
            break
        }
        number = number * 10 + digit
    }
    return number
}

/**
 * A digit's value.
 *
 * @param character An ASCII character.
 * @return 0 to 15 for 0-9, a-f and A-F; 16 for anything else.
 */
digit_value :: fn(character: u8) -> u64 {
    if character >= cast[u8]('0') && character <= cast[u8]('9') {
        return cast[u64](character - cast[u8]('0'))
    }
    if character >= cast[u8]('a') && character <= cast[u8]('f') {
        return cast[u64](character - cast[u8]('a')) + 10
    }
    if character >= cast[u8]('A') && character <= cast[u8]('F') {
        return cast[u64](character - cast[u8]('A')) + 10
    }
    return 16
}

/**
 * Convert a value to a buffer, as an operand that has to be one is: an integer's 8 bytes (4 at 32 bits),
 * little-endian; a string's bytes and its terminating 0; a buffer as it is.
 *
 * @param interpreter The interpreter.
 * @param value The value, resolved to data.
 * @return The buffer: the value's own for a buffer, else a new one in the arena.
 * @error WrongType A package, an object, a reference, or Uninitialized.
 * @error Memory The evaluation's budget can't hold it.
 */
buffer_of :: fn(interpreter: ptr[mut Interpreter], value #escaping : Value) -> Result[ptr[mut Bytes], Error] #unrestricted {
    match value {
        case Buffer(bytes) => return .Ok(bytes)
        case Integer(number) => {
            count :: integer_bytes(interpreter)
            made :: temporary_bytes(interpreter, cast[u64](count))?
            data :: made.data
            for i in 0..<data.count {
                data[i] = cast[u8]((number >> (8 * cast[u64](i))) & 0xff)
            }
            return .Ok(made)
        }
        case String(text) => {
            made :: temporary_bytes(interpreter, cast[u64](text.data.count) + 1)?
            copy_into(made.data, text.data)
            return .Ok(made)
        }
        case _ => return .Error(.WrongType)
    }
}

/**
 * Convert a value to a string, as an operand that has to be one is: an integer as hexadecimal, 16 digits (8 at 32
 * bits), upper case; a buffer's bytes as two hex digits each, separated by spaces; a string as it is.
 *
 * @param interpreter The interpreter.
 * @param value The value, resolved to data.
 * @return The string: the value's own for a string, else a new one in the arena.
 * @error WrongType A package, an object, a reference, or Uninitialized.
 * @error Memory The evaluation's budget can't hold it.
 */
string_of_value :: fn(interpreter: ptr[mut Interpreter], value #escaping : Value) -> Result[ptr[mut Bytes], Error] #unrestricted {
    match value {
        case String(text) => return .Ok(text)
        case Integer(number) => {
            digits :: 2 * integer_bytes(interpreter)
            made :: temporary_bytes(interpreter, cast[u64](digits))?
            data :: made.data
            for i in 0..<data.count {
                shift :: 4 * cast[u64](data.count - 1 - i)
                data[i] = HEX_DIGITS[cast[usize]((number >> shift) & 15)]
            }
            return .Ok(made)
        }
        case Buffer(bytes) => {
            count :: bytes.data.count
            made :: temporary_bytes(interpreter, if count == 0 { 0 } else { cast[u64](count) * 3 - 1 })?
            data :: made.data
            for byte, i in bytes.data {
                at :: 3 * i
                if at < data.count && at + 1 < data.count {
                    data[at] = HEX_DIGITS[cast[usize]((byte >> 4) & 15)]
                    data[at + 1] = HEX_DIGITS[cast[usize](byte & 15)]
                }
                if at < data.count && at + 2 < data.count {
                    data[at + 2] = cast[u8](' ')
                }
            }
            return .Ok(made)
        }
        case _ => return .Error(.WrongType)
    }
}

/** The hex digits, upper case, as AML's conversions write them. */
HEX_DIGITS : u8[16] : u8.[0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46]

/**
 * ACPI's object type number for ObjectType (ACPI 6.5 §19.6.97).
 *
 * @param value The value.
 * @return Its type's number: 0 uninitialized, 1 integer, 2 string, 3 buffer, 4 package, 5 field, 6 device, 7 event,
 *     8 method, 9 mutex, 10 region, 11 power resource, 12 processor, 13 thermal zone, 14 buffer field, 16 debug; a
 *     reference's, its target's.
 */
type_number :: fn(value: Value) -> u64 {
    match value {
        case Uninitialized => return 0
        case Integer(_) => return 1
        case String(_) => return 2
        case Buffer(_) => return 3
        case Package(_) => return 4
        case Object(node) => return node_type_number(node)
        case Reference(node) => return node_type_number(node)
        case Element(element) => return type_number(element.slot^)
        case Byte(_) => return 14
        case Path(_) => return 2
        case Debug => return 16
    }
}

/**
 * ACPI's object type number of a node.
 *
 * @param node The node.
 * @return As type_number's: a Name's, its value's.
 */
node_type_number :: fn(node: ptr[Node]) -> u64 {
    match node.kind {
        case .Scope => return 0
        case .Name => return type_number(node.value)
        case .Method => return 8
        case .Builtin => return 8
        case .Device => return 6
        case .Processor => return 12
        case .PowerResource => return 11
        case .ThermalZone => return 13
        case .Mutex => return 9
        case .Event => return 7
        case .Region => return 10
        case .Field => return 5
        case .IndexField => return 5
        case .BankField => return 5
        case .BufferField => return 14
        case .Alias => return 0
    }
}
