package aml

/*
 * AML's one-byte expressions (ACPI 6.5 §20.2.5.4): storing, arithmetic, logic, references, and the conversions. Each
 * reads its operands as terms, in order, and its targets, and gives its result.
 */

/**
 * Evaluate a one-byte expression, its opcode read.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode; moved past the term.
 * @param opcode The opcode.
 * @return Its result.
 */
evaluate_operation :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor], opcode: u8) -> Result[Value, Error] #unrestricted {
    if opcode == 0x70 || opcode == 0x9d {
        // Store, CopyObject
        value :: evaluate_term(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        if opcode == 0x9d {
            copy_object(interpreter, frame, value, target)?
        }
        else {
            store(interpreter, frame, value, target)?
        }
        return .Ok(value)
    }
    if opcode == 0x71 {
        // RefOf
        match read_target(interpreter, frame, cursor)? {
            case Named(node) => return .Ok(.Reference(node))
            case Local(index) => return .Ok(.Element(local_reference(frame, index)?))
            case Argument(index) => return .Ok(.Element(argument_reference(frame, index)?))
            case Referred(value) => return .Ok(value)
            case _ => return .Error(.WrongType)
        }
    }
    if is_binary(opcode) {
        a :: evaluate_integer(interpreter, frame, cursor)?
        b :: evaluate_integer(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: masked(interpreter, binary(interpreter, opcode, a, b)?)
        store(interpreter, frame, .Integer(result), target)?
        return .Ok(.Integer(result))
    }
    if opcode == 0x75 || opcode == 0x76 {
        // Increment, Decrement
        target :: read_target(interpreter, frame, cursor)?
        now :: integer_of(interpreter, target_value(interpreter, frame, target)?)?
        result :: masked(interpreter, if opcode == 0x75 { now + 1 } else { now - 1 })
        store(interpreter, frame, .Integer(result), target)?
        return .Ok(.Integer(result))
    }
    if opcode == 0x78 {
        // Divide: the remainder stored first, then the quotient
        dividend :: evaluate_integer(interpreter, frame, cursor)?
        divisor :: evaluate_integer(interpreter, frame, cursor)?
        remainder_target :: read_target(interpreter, frame, cursor)?
        quotient_target :: read_target(interpreter, frame, cursor)?
        if divisor == 0 {
            return .Error(.DivideByZero)
        }
        store(interpreter, frame, .Integer(dividend % divisor), remainder_target)?
        store(interpreter, frame, .Integer(dividend / divisor), quotient_target)?
        return .Ok(.Integer(dividend / divisor))
    }
    if opcode == 0x80 || opcode == 0x81 || opcode == 0x82 {
        // Not, FindSetLeftBit, FindSetRightBit
        value :: evaluate_integer(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: masked(interpreter, if opcode == 0x80 { ~value } else if opcode == 0x81 { left_bit(value) } else { right_bit(value) })
        store(interpreter, frame, .Integer(result), target)?
        return .Ok(.Integer(result))
    }
    if opcode == 0x90 || opcode == 0x91 {
        // LAnd, LOr: both operands are evaluated, as AML has no short circuit
        a :: evaluate_integer(interpreter, frame, cursor)?
        b :: evaluate_integer(interpreter, frame, cursor)?
        return .Ok(truth(interpreter, if opcode == 0x90 { a != 0 && b != 0 } else { a != 0 || b != 0 }))
    }
    if opcode == 0x92 {
        // LNot, and LNotEqual, LLessEqual and LGreaterEqual, which are LNot of the comparison after it
        next :: peek_byte(cursor) or_return .Error(.Truncated)
        if next == 0x93 || next == 0x94 || next == 0x95 {
            cursor.at += 1
            order :: compare(interpreter, frame, cursor)?
            holds :: if next == 0x93 { order == 0 } else if next == 0x94 { order > 0 } else { order < 0 }
            return .Ok(truth(interpreter, !holds))
        }
        value :: evaluate_integer(interpreter, frame, cursor)?
        return .Ok(truth(interpreter, value == 0))
    }
    if opcode == 0x93 || opcode == 0x94 || opcode == 0x95 {
        // LEqual, LGreater, LLess
        order :: compare(interpreter, frame, cursor)?
        return .Ok(truth(interpreter, if opcode == 0x93 { order == 0 } else if opcode == 0x94 { order > 0 } else { order < 0 }))
    }
    if opcode == 0x83 {
        // DerefOf
        value :: evaluate_term(interpreter, frame, cursor)?
        return dereference(interpreter, frame, value)
    }
    if opcode == 0x87 {
        // SizeOf
        value :: target_value(interpreter, frame, read_target(interpreter, frame, cursor)?)?
        match value {
            case String(text) => return .Ok(.Integer(cast[u64](text.data.count)))
            case Buffer(bytes) => return .Ok(.Integer(cast[u64](bytes.data.count)))
            case Package(package) => return .Ok(.Integer(cast[u64](package.elements.count)))
            case _ => return .Error(.WrongType)
        }
    }
    if opcode == 0x8e {
        // ObjectType
        match read_target(interpreter, frame, cursor)? {
            case Named(node) => return .Ok(.Integer(node_type_number(node)))
            case Local(index) => return .Ok(.Integer(type_number(local_value(frame, index)?)))
            case Argument(index) => return .Ok(.Integer(type_number(argument_value(frame, index)?)))
            case Referred(value) => return .Ok(.Integer(type_number(value)))
            case Debug => return .Ok(.Integer(16))
            case Nothing => return .Ok(.Integer(0))
        }
    }
    if opcode == 0x88 {
        // Index
        source :: evaluate_term(interpreter, frame, cursor)?
        index :: evaluate_integer(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: index_of(source, index)?
        store(interpreter, frame, result, target)?
        return .Ok(result)
    }
    if opcode == 0x89 {
        return evaluate_match(interpreter, frame, cursor)
    }
    if opcode == 0x73 || opcode == 0x84 {
        // Concatenate, ConcatenateResTemplate
        a :: evaluate_term(interpreter, frame, cursor)?
        b :: evaluate_term(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: if opcode == 0x73 { concatenate(interpreter, a, b)? } else { concatenate_resources(interpreter, a, b)? }
        store(interpreter, frame, result, target)?
        return .Ok(result)
    }
    if opcode == 0x96 || opcode == 0x97 || opcode == 0x98 || opcode == 0x99 {
        // ToBuffer, ToDecimalString, ToHexString, ToInteger
        value :: evaluate_term(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: converted(interpreter, opcode, value)?
        store(interpreter, frame, result, target)?
        return .Ok(result)
    }
    if opcode == 0x9c {
        // ToString: a buffer's bytes up to its first 0, or a length
        value :: evaluate_term(interpreter, frame, cursor)?
        length :: evaluate_integer(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        bytes :: buffer_of(interpreter, value)?
        data :: bytes.data
        count : usize = 0
        for byte in data {
            if byte == 0 || cast[u64](count) >= length {
                break
            }
            count += 1
        }
        if count > data.count {
            return .Error(.OutOfRange)
        }
        result :: temporary_string(interpreter, data[0..<count])?
        store(interpreter, frame, result, target)?
        return .Ok(result)
    }
    if opcode == 0x9e {
        // Mid
        value :: evaluate_term(interpreter, frame, cursor)?
        index :: evaluate_integer(interpreter, frame, cursor)?
        length :: evaluate_integer(interpreter, frame, cursor)?
        target :: read_target(interpreter, frame, cursor)?
        result :: middle(interpreter, value, index, length)?
        store(interpreter, frame, result, target)?
        return .Ok(result)
    }
    return .Error(.BadOpcode)
}

/**
 * Tell whether an opcode is an arithmetic or bitwise operation of two integers and a target.
 *
 * @param opcode The opcode.
 * @return True for Add, Subtract, Multiply, ShiftLeft, ShiftRight, And, Nand, Or, Nor, Xor and Mod.
 */
is_binary :: fn(opcode: u8) -> bool {
    return opcode == 0x72 || opcode == 0x74 || opcode == 0x77 || (opcode >= 0x79 && opcode <= 0x7f) || opcode == 0x85
}

/**
 * Work out a binary operation.
 *
 * @param interpreter The interpreter, whose width a shift is bounded by.
 * @param opcode One is_binary takes.
 * @param a The first operand.
 * @param b The second.
 * @return The result, unmasked; a shift by the width or more gives 0.
 * @error DivideByZero Mod by 0.
 */
binary :: fn(interpreter: ptr[Interpreter], opcode: u8, a: u64, b: u64) -> Result[u64, Error] {
    width :: if interpreter.wide { cast[u64](64) } else { cast[u64](32) }
    match opcode {
        case 0x72 => return .Ok(a + b)
        case 0x74 => return .Ok(a - b)
        case 0x77 => return .Ok(a * b)
        case 0x79 => return .Ok(if b >= width { 0 } else { a << b })
        case 0x7a => return .Ok(if b >= width { 0 } else { a >> b })
        case 0x7b => return .Ok(a & b)
        case 0x7c => return .Ok(~(a & b))
        case 0x7d => return .Ok(a | b)
        case 0x7e => return .Ok(~(a | b))
        case 0x7f => return .Ok(a ~ b)
        case _ => {
            if b == 0 {
                return .Error(.DivideByZero)
            }
            return .Ok(a % b)
        }
    }
}

/**
 * The highest set bit, counted from 1, as FindSetLeftBit gives it.
 *
 * @param value The integer.
 * @return 1 to 64; 0 if no bit is set.
 */
left_bit :: fn(value: u64) -> u64 {
    for i in 0..<64 {
        bit :: 63 - cast[u64](i)
        if (value >> bit) & 1 != 0 {
            return bit + 1
        }
    }
    return 0
}

/**
 * The lowest set bit, counted from 1, as FindSetRightBit gives it.
 *
 * @param value The integer.
 * @return 1 to 64; 0 if no bit is set.
 */
right_bit :: fn(value: u64) -> u64 {
    for i in 0..<64 {
        if (value >> cast[u64](i)) & 1 != 0 {
            return cast[u64](i) + 1
        }
    }
    return 0
}

/**
 * A logical result, as AML writes one.
 *
 * @param interpreter The interpreter.
 * @param holds Whether it's true.
 * @return Ones for true, 0 for false.
 */
truth :: fn(interpreter: ptr[Interpreter], holds: bool) -> Value {
    return .Integer(if holds { ones(interpreter) } else { 0 })
}

/**
 * Compare two operands, as LEqual, LGreater and LLess do: integers as numbers; strings and buffers byte by byte, the
 * second converted to the first's type, a shorter one that's a prefix of the other less.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor At the first operand; moved past both.
 * @return Less than 0, 0, or more than 0, as the first is less than, equal to or more than the second.
 */
compare :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[i32, Error] {
    a :: evaluate_term(interpreter, frame, cursor)?
    b :: evaluate_term(interpreter, frame, cursor)?
    match a {
        case String(text) => return .Ok(compare_bytes(text.data, string_of_value(interpreter, b)?.data))
        case Buffer(bytes) => return .Ok(compare_bytes(bytes.data, buffer_of(interpreter, b)?.data))
        case _ => {
            x :: integer_of(interpreter, a)?
            y :: integer_of(interpreter, b)?
            return .Ok(if x < y { -1 } else if x > y { 1 } else { 0 })
        }
    }
}

/**
 * Compare bytes, as compare does.
 *
 * @param a The first.
 * @param b The second.
 * @return Less than 0, 0, or more than 0.
 */
compare_bytes :: fn(a: u8[], b: u8[]) -> i32 {
    for byte, i in a {
        if i >= b.count {
            return 1
        }
        if byte != b[i] {
            return if byte < b[i] { -1 } else { 1 }
        }
    }
    return if a.count < b.count { -1 } else { 0 }
}

/**
 * Follow a reference, as DerefOf does: a reference's target read; a string or a package's name resolved, and the
 * object it names read.
 *
 * @param interpreter The interpreter.
 * @param frame The frame, whose scope a string's name is resolved from.
 * @param value The reference.
 * @return What it refers to.
 * @error NotFound A name that isn't there.
 * @error WrongType A value that isn't a reference nor a name.
 */
dereference :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], value #escaping : Value) -> Result[Value, Error] #unrestricted {
    match value {
        case Reference(_) => return dereferenced(interpreter, frame, value)
        case Element(_) => return dereferenced(interpreter, frame, value)
        case Byte(_) => return dereferenced(interpreter, frame, value)
        case Path(path) => {
            node :: resolve_path(interpreter, path) or_return .Error(.NotFound)
            return value_of_node(interpreter, frame, node)
        }
        case String(text) => {
            node :: find_from(interpreter, frame.scope, text.data) or_return .Error(.NotFound)
            return value_of_node(interpreter, frame, node)
        }
        case _ => return .Error(.WrongType)
    }
}

/**
 * Find a node by a path written as text, as DerefOf of a string does: absolute with `\`, or one segment searched for
 * from a scope up.
 *
 * @param interpreter The interpreter.
 * @param scope The scope a relative path's searched from.
 * @param text The path's text.
 * @return The node; null if there's none.
 */
find_from :: fn(interpreter: ptr[mut Interpreter], scope: ptr[mut Node], text: u8[]) -> ptr[mut Node]? {
    if text.count > 0 && text[0] == cast[u8]('\\') {
        return find(interpreter, text_of(text))
    }
    if text.count <= 4 {
        segment : u32 = 0
        for i in 0..<4 {
            position :: cast[usize](i)
            character :: if position < text.count { text[position] } else { cast[u8]('_') }
            segment |= cast[u32](character) << (8 * cast[u32](i))
        }
        at := scope
        loop {
            match child_of(at, segment) {
                case Some(found) => return found
                case None => {}
            }
            at = at.parent or_break
        }
    }
    return null
}

/**
 * Index into a package, buffer or string.
 *
 * @param source What's indexed.
 * @param index The index.
 * @return A reference: an element's, or a byte's.
 * @error OutOfRange An index past its end.
 * @error WrongType Something that can't be indexed.
 */
index_of :: fn(source #escaping : Value, index: u64) -> Result[Value, Error] #unrestricted {
    match source {
        case Package(package) => {
            elements :: package.elements
            at :: cast[usize](index)
            if index >= cast[u64](elements.count) || at >= elements.count {
                return .Error(.OutOfRange)
            }
            return .Ok(.Element(ElementReference.{slot = &elements[at], persistent = package.persistent}))
        }
        case Buffer(bytes) => {
            if index >= cast[u64](bytes.data.count) {
                return .Error(.OutOfRange)
            }
            return .Ok(.Byte(ByteReference.{bytes = bytes, index = index, string = false}))
        }
        case String(text) => {
            if index >= cast[u64](text.data.count) {
                return .Error(.OutOfRange)
            }
            return .Ok(.Byte(ByteReference.{bytes = text, index = index, string = true}))
        }
        case _ => return .Error(.WrongType)
    }
}

/**
 * Concatenate two values, the result's type the first's: two integers into a buffer of both; two strings, the second
 * converted to one; two buffers, the second converted to one.
 *
 * @param interpreter The interpreter.
 * @param a The first.
 * @param b The second.
 * @return The result, in the arena.
 * @error WrongType A first operand that isn't an integer, a string or a buffer, or a second that won't convert.
 * @error Memory The evaluation's budget can't hold it.
 */
concatenate :: fn(interpreter: ptr[mut Interpreter], a #escaping : Value, b #escaping : Value) -> Result[Value, Error] #unrestricted {
    match a {
        case Integer(_) => {
            first :: buffer_of(interpreter, a)?
            second :: buffer_of(interpreter, .Integer(integer_of(interpreter, b)?))?
            return .Ok(.Buffer(joined(interpreter, first.data, second.data)?))
        }
        case String(text) => {
            second :: string_of_value(interpreter, b)?
            return .Ok(.String(joined(interpreter, text.data, second.data)?))
        }
        case Buffer(bytes) => {
            second :: buffer_of(interpreter, b)?
            return .Ok(.Buffer(joined(interpreter, bytes.data, second.data)?))
        }
        case _ => return .Error(.WrongType)
    }
}

/**
 * Join two runs of bytes into new bytes in the arena.
 *
 * @param interpreter The interpreter.
 * @param a The first.
 * @param b The second, after it.
 * @return The joined bytes.
 * @error Memory The evaluation's budget can't hold them.
 */
joined :: fn(interpreter: ptr[mut Interpreter], a: u8[], b: u8[]) -> Result[ptr[mut Bytes], Error] #unrestricted {
    made :: temporary_bytes(interpreter, cast[u64](a.count) + cast[u64](b.count))?
    data :: made.data
    copy_into(data, a)
    for byte, i in b {
        at :: a.count + i
        if at < data.count {
            data[at] = byte
        }
    }
    return .Ok(made)
}

/**
 * Concatenate two resource templates: the first's end tag dropped, the second's kept, its checksum 0 (ACPI 6.5
 * §19.6.13).
 *
 * @param interpreter The interpreter.
 * @param a The first template, a buffer.
 * @param b The second.
 * @return The joined template, in the arena.
 * @error WrongType An operand that isn't a buffer.
 * @error Memory The evaluation's budget can't hold it.
 */
concatenate_resources :: fn(interpreter: ptr[mut Interpreter], a #escaping : Value, b #escaping : Value) -> Result[Value, Error] #unrestricted {
    first :: buffer_of(interpreter, a)?
    second :: buffer_of(interpreter, b)?
    head :: first.data
    keep :: if head.count >= 2 && head[head.count - 2] == 0x79 { head.count - 2 } else { head.count }
    if keep > head.count {
        return .Error(.OutOfRange)
    }
    made :: joined(interpreter, head[0..<keep], second.data)?
    data :: made.data
    if data.count >= 2 && data[data.count - 2] == 0x79 {
        data[data.count - 1] = 0
    }
    return .Ok(.Buffer(made))
}

/**
 * Convert a value explicitly, as ToBuffer, ToDecimalString, ToHexString and ToInteger do.
 *
 * @param interpreter The interpreter.
 * @param opcode Which: 0x96, 0x97, 0x98 or 0x99.
 * @param value The value.
 * @return The converted value, in the arena; ToBuffer of a buffer and ToHexString of a string are the value itself.
 * @error WrongType A value that won't convert.
 * @error Memory The evaluation's budget can't hold it.
 */
converted :: fn(interpreter: ptr[mut Interpreter], opcode: u8, value #escaping : Value) -> Result[Value, Error] #unrestricted {
    if opcode == 0x96 {
        return .Ok(.Buffer(buffer_of(interpreter, value)?))
    }
    if opcode == 0x99 {
        match value {
            case String(text) => return .Ok(.Integer(masked(interpreter, explicit_integer(text.data))))
            case _ => return .Ok(.Integer(integer_of(interpreter, value)?))
        }
    }
    if opcode == 0x98 {
        return .Ok(.String(string_of_value(interpreter, value)?))
    }
    // ToDecimalString: an integer's digits, a buffer's bytes' separated by commas
    storage : u8[4096]
    count : usize = 0
    match value {
        case Integer(number) => count = decimal_into(storage[0..<storage.count], 0, number)
        case Buffer(bytes) => {
            for byte, i in bytes.data {
                if i > 0 && count < storage.count {
                    storage[count] = cast[u8](',')
                    count += 1
                }
                count = decimal_into(storage[0..<storage.count], count, cast[u64](byte))
            }
        }
        case String(text) => return .Ok(.String(text))
        case _ => return .Error(.WrongType)
    }
    if count > storage.count {
        return .Error(.OutOfRange)
    }
    return temporary_string(interpreter, storage[0..<count])
}

/**
 * Write a number's decimal digits.
 *
 * @param into Where.
 * @param at Where in it to start.
 * @param number The number.
 * @return Where its digits end; what doesn't fit is cut.
 */
decimal_into :: fn(into: mut u8[], at: usize, number: u64) -> usize {
    digits : u8[20]
    count : usize = 0
    rest := number
    loop {
        if count < digits.count {
            digits[count] = cast[u8]('0') + cast[u8](rest % 10)
            count += 1
        }
        rest /= 10
    }
    while rest != 0
    written := at
    for i in 0..<count {
        index :: count - 1 - i
        if written < into.count && index < digits.count {
            into[written] = digits[index]
            written += 1
        }
    }
    return written
}

/**
 * Part of a string or buffer, as Mid takes it.
 *
 * @param interpreter The interpreter.
 * @param value The string or buffer.
 * @param index Where the part starts.
 * @param length How long it is at most; it's cut at the value's end.
 * @return The part, of the value's type, in the arena; empty if index is past the end.
 * @error WrongType A value that isn't a string or a buffer.
 * @error Memory The evaluation's budget can't hold it.
 */
middle :: fn(interpreter: ptr[mut Interpreter], value #escaping : Value, index: u64, length: u64) -> Result[Value, Error] #unrestricted {
    data : u8[]
    is_string := false
    match value {
        case String(text) => {
            data = text.data
            is_string = true
        }
        case Buffer(bytes) => data = bytes.data
        case _ => return .Error(.WrongType)
    }
    count :: cast[u64](data.count)
    start :: if index < count { index } else { count }
    stop :: if length < count - start { start + length } else { count }
    from :: cast[usize](start)
    to :: cast[usize](stop)
    part :: if from <= to && to <= data.count { data[from..<to] } else { data[0..<0] }
    made :: temporary_bytes(interpreter, cast[u64](part.count))?
    copy_into(made.data, part)
    return .Ok(if is_string { Value.String(made) } else { Value.Buffer(made) })
}

/**
 * Evaluate Match, its opcode read: the first element of a package, from a start, that both comparisons hold for.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode; moved past the term.
 * @return The element's index; Ones if none holds.
 * @error WrongType A first operand that isn't a package.
 */
evaluate_match :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor]) -> Result[Value, Error] #unrestricted {
    source :: evaluate_term(interpreter, frame, cursor)?
    first_operation :: read_byte(cursor)?
    first :: evaluate_integer(interpreter, frame, cursor)?
    second_operation :: read_byte(cursor)?
    second :: evaluate_integer(interpreter, frame, cursor)?
    start :: evaluate_integer(interpreter, frame, cursor)?
    match source {
        case Package(package) => {
            for element, i in package.elements {
                if cast[u64](i) < start {
                    continue
                }
                match integer_of(interpreter, element) {
                    case Ok(number) => {
                        if matches(first_operation, number, first) && matches(second_operation, number, second) {
                            return .Ok(.Integer(cast[u64](i)))
                        }
                    }
                    case Error(_) => {}
                }
            }
            return .Ok(.Integer(ones(interpreter)))
        }
        case _ => return .Error(.WrongType)
    }
}

/**
 * Tell whether Match's comparison holds.
 *
 * @param operation MTR (0), MEQ (1), MLE (2), MLT (3), MGE (4) or MGT (5); any other never holds.
 * @param element The element.
 * @param operand What it's compared with.
 * @return Whether it holds.
 */
matches :: fn(operation: u8, element: u64, operand: u64) -> bool {
    match operation {
        case 0 => return true
        case 1 => return element == operand
        case 2 => return element <= operand
        case 3 => return element < operand
        case 4 => return element >= operand
        case 5 => return element > operand
        case _ => return false
    }
}

/**
 * Copy a value into a target as it is, without converting it to what the target held (CopyObject).
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param value The value.
 * @param target Where it goes.
 * @error WrongType A target that can't hold it: a field takes it as store does.
 * @error Memory What it's copied into can't hold it.
 */
copy_object :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], value #escaping : Value, target: Target) -> Result[void, Error] {
    match target {
        case Named(node) => {
            if node.kind != .Name {
                return store_to_node(interpreter, frame, value, node)
            }
            kept :: persist(interpreter, value)?
            release_persistent(interpreter, node.value)
            node.value = kept
            return .Ok
        }
        case _ => return store(interpreter, frame, value, target)
    }
}
