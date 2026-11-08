package aml

/*
 * Fields (ACPI 6.5 §19.6.48, §5.5.2.4): bits of an operation region, reached a unit of the field's access width at a
 * time through the host; an index field's through its index and data fields, a bank field's after its bank's chosen;
 * and buffer fields, bits of a buffer.
 */

/** The most bits a field or buffer field may have: what a read of it makes is bounded by them. */
MAX_FIELD_BITS : u64 : 1 << 20

/**
 * Define a Field's, IndexField's or BankField's fields, its opcode read.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param cursor Just past the opcode; moved past the term.
 * @param opcode 0x81 for a Field, 0x86 for an IndexField, 0x87 for a BankField.
 * @error NotFound The region, or the index, data or bank field, isn't there.
 * @error AlreadyExists A field's name is in use in its scope.
 */
define_fields :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], cursor: ptr[mut Cursor], opcode: u8) -> Result[void, Error] {
    end :: package_end(cursor)?
    first := read_name(cursor)?
    region :: resolve(interpreter, frame.scope, &first) or_return .Error(not_found(interpreter, &first))
    data : ptr[mut Node]? = null
    bank : u64 = 0
    if opcode == 0x86 || opcode == 0x87 {
        second := read_name(cursor)?
        data = resolve(interpreter, frame.scope, &second) or_return .Error(not_found(interpreter, &second))
    }
    if opcode == 0x87 {
        bank = evaluate_integer(interpreter, frame, cursor)?
    }
    flags :: read_byte(cursor)?
    kind :: if opcode == 0x81 { NodeKind.Field } else if opcode == 0x86 { NodeKind.IndexField } else { NodeKind.BankField }
    access := access_type(flags & 15)
    update :: update_rule((flags >> 5) & 3)
    offset : u64 = 0
    inner := Cursor.{code = cursor.code, at = cursor.at, end = end}
    loop {
        if inner.at >= end {
            break
        }
        lead :: peek_byte(&inner) or_return .Error(.Truncated)
        if lead == 0x00 {
            // A reserved run of bits
            inner.at += 1
            offset += read_field_length(&inner)?
        }
        else if lead == 0x01 {
            // An access type for the fields after it
            inner.at += 1
            access = access_type(read_byte(&inner)? & 15)
            _ = read_byte(&inner)?
        }
        else if lead == 0x02 {
            // A connection, for the serial bus spaces, which aren't served: skipped
            inner.at += 1
            if (peek_byte(&inner) or_else 0) == 0x11 {
                inner.at += 1
                inner.at = package_end(&inner)?
            }
            else {
                _ = read_name(&inner)?
            }
        }
        else if lead == 0x03 {
            // An extended access type, its attribute and length
            inner.at += 1
            access = access_type(read_byte(&inner)? & 15)
            _ = read_byte(&inner)?
            _ = read_byte(&inner)?
        }
        else {
            segment :: read_integer(&inner, 4)?
            bits :: read_field_length(&inner)?
            if bits > MAX_FIELD_BITS {
                return .Error(.OutOfRange)
            }
            node :: define_segment(interpreter, frame, cast[u32](segment), kind)?
            node.region = region
            node.data = data
            node.bank = bank
            node.bit_offset = offset
            node.bit_length = bits
            node.access = access
            node.update = update
            offset += bits
        }
    }
    cursor.at = end
    return .Ok
}

/**
 * Read a field's length, a PkgLength that's a count of bits rather than a term's bytes.
 *
 * @param cursor Where; moved past it.
 * @return The bits.
 * @error Truncated At the end before it.
 */
read_field_length :: fn(cursor: ptr[mut Cursor]) -> Result[u64, Error] {
    lead :: read_byte(cursor)?
    following :: cast[u32](lead >> 6)
    if following == 0 {
        return .Ok(cast[u64](lead & 0x3f))
    }
    length := cast[u64](lead & 0x0f)
    for i in 0..<following {
        length |= cast[u64](read_byte(cursor)?) << (4 + 8 * cast[u64](i))
    }
    return .Ok(length)
}

/**
 * Make a node named by one segment in the frame's scope, as a field in a field list is.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param segment The name.
 * @param kind What it is.
 * @return The node.
 * @error AlreadyExists Something of that name is in the scope.
 * @error Memory The namespace's budget can't hold it.
 */
define_segment :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], segment: u32, kind: NodeKind) -> Result[ptr[mut Node], Error] {
    if child_of(frame.scope, segment) is_some {
        return .Error(.AlreadyExists)
    }
    temporary :: frame.method is_some
    node :: add_node(interpreter, frame.scope, segment, kind, temporary) or_return .Error(.Memory)
    if temporary {
        node.made_before = frame.made
        frame.made = node
    }
    return .Ok(node)
}

/**
 * A field's access type from its flags.
 *
 * @param value The flags' low 4 bits.
 * @return The type; Any for a value past Buffer.
 */
access_type :: fn(value: u8) -> AccessType {
    return if value <= 5 { cast[AccessType](value) } else { AccessType.Any }
}

/**
 * A field's update rule from its flags.
 *
 * @param value The flags' bits 5 and 6.
 * @return The rule; Preserve for 3.
 */
update_rule :: fn(value: u8) -> UpdateRule {
    return if value <= 2 { cast[UpdateRule](value) } else { UpdateRule.Preserve }
}

/**
 * The bytes a field reads and writes at a time.
 *
 * @param access The field's access type.
 * @return 1, 2, 4 or 8.
 */
access_bytes :: fn(access: AccessType) -> u64 {
    match access {
        case .Word => return 2
        case .DWord => return 4
        case .QWord => return 8
        case _ => return 1
    }
}

/**
 * Make a buffer field over a buffer, as CreateField and its fixed-size forms do.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param source The buffer: a Name's, shared, or one in the arena; a string is taken as its bytes.
 * @param offset The field's first bit.
 * @param bits Its bits.
 * @param name Its name.
 * @return Next.
 * @error WrongType A source that isn't a buffer or a string.
 * @error OutOfRange A field past the buffer's end.
 */
create_buffer_field :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], source #escaping : Value, offset: u64, bits: u64, name: ptr[NameString]) -> Result[Flow, Error] {
    bytes : ptr[mut Bytes]? = null
    match source {
        case Buffer(found) => bytes = found
        case String(found) => bytes = found
        case _ => return .Error(.WrongType)
    }
    buffer :: bytes or_return .Error(.WrongType)
    if bits == 0 || bits > MAX_FIELD_BITS || offset > cast[u64](buffer.data.count) * 8 || bits > cast[u64](buffer.data.count) * 8 - offset {
        return .Error(.OutOfRange)
    }
    node :: define(interpreter, frame, name, .BufferField)?
    node.buffer = buffer
    node.bit_offset = offset
    node.bit_length = bits
    return .Ok(.Next)
}

/**
 * Read bits into bytes: bit i of value goes to bit at + i of into.
 *
 * @param into The bytes, written.
 * @param at The first bit written.
 * @param value The bits.
 * @param count How many of value's low bits, at most 64.
 */
put_bits :: fn(into: mut u8[], at: u64, value: u64, count: u64) {
    for i in 0..<count {
        bit :: at + i
        index :: cast[usize](bit / 8)
        if index < into.count {
            mask :: cast[u8](1) << cast[u8](bit % 8)
            if (value >> i) & 1 != 0 {
                into[index] |= mask
            }
            else {
                into[index] &= ~mask
            }
        }
    }
}

/**
 * Take bits from bytes.
 *
 * @param from The bytes.
 * @param at The first bit taken.
 * @param count How many, at most 64.
 * @return The bits, bit at of from as its bit 0; a bit past from's end reads 0.
 */
take_bits :: fn(from: u8[], at: u64, count: u64) -> u64 {
    value : u64 = 0
    for i in 0..<count {
        bit :: at + i
        index :: cast[usize](bit / 8)
        if index < from.count && (from[index] >> cast[u8](bit % 8)) & 1 != 0 {
            value |= cast[u64](1) << i
        }
    }
    return value
}

/**
 * The bits a field's value is made of, as bytes: an integer's, little-endian; a buffer's or a string's own.
 *
 * @param interpreter The interpreter.
 * @param value The value.
 * @return The bytes.
 * @error WrongType A value that's none of those.
 */
field_bytes :: fn(interpreter: ptr[mut Interpreter], value #escaping : Value) -> Result[u8[], Error] #unrestricted {
    match value {
        case Buffer(bytes) => return .Ok(bytes.data)
        case String(text) => return .Ok(text.data)
        case _ => {
            number :: integer_of(interpreter, value)?
            made :: temporary_bytes(interpreter, 8)?
            put_bits(made.data, 0, number, 64)
            return .Ok(made.data)
        }
    }
}

/**
 * Give a field's or buffer field's bits as its value: an integer if they fit in one, a buffer if not.
 *
 * @param interpreter The interpreter.
 * @param bytes The bits, bit 0 first.
 * @param bits How many.
 * @return The value.
 */
field_value :: fn(interpreter: ptr[mut Interpreter], bytes: ptr[mut Bytes], bits: u64) -> Value {
    if bits <= 8 * cast[u64](integer_bytes(interpreter)) {
        return .Integer(take_bits(bytes.data, 0, if bits < 64 { bits } else { 64 }))
    }
    return .Buffer(bytes)
}

/**
 * Read a buffer field.
 *
 * @param interpreter The interpreter.
 * @param node The buffer field.
 * @return Its bits, as field_value gives them.
 * @error OutOfRange Its buffer's shrunk below it.
 * @error Memory The evaluation's budget can't hold it.
 */
read_buffer_field :: fn(interpreter: ptr[mut Interpreter], node: ptr[mut Node]) -> Result[Value, Error] #unrestricted {
    buffer :: node.buffer or_return .Error(.WrongType)
    if node.bit_offset + node.bit_length > cast[u64](buffer.data.count) * 8 {
        return .Error(.OutOfRange)
    }
    made :: temporary_bytes(interpreter, (node.bit_length + 7) / 8)?
    for done in 0..<((node.bit_length + 63) / 64) {
        at :: done * 64
        count :: if node.bit_length - at < 64 { node.bit_length - at } else { 64 }
        put_bits(made.data, at, take_bits(buffer.data, node.bit_offset + at, count), count)
    }
    return .Ok(field_value(interpreter, made, node.bit_length))
}

/**
 * Write a buffer field: its bits from the value's, zeros past the value's end.
 *
 * @param interpreter The interpreter.
 * @param node The buffer field.
 * @param value The value: an integer, a buffer or a string.
 * @error OutOfRange Its buffer's shrunk below it.
 * @error WrongType A value that's none of those.
 */
write_buffer_field :: fn(interpreter: ptr[mut Interpreter], node: ptr[mut Node], value #escaping : Value) -> Result[void, Error] {
    buffer :: node.buffer or_return .Error(.WrongType)
    if node.bit_offset + node.bit_length > cast[u64](buffer.data.count) * 8 {
        return .Error(.OutOfRange)
    }
    source :: field_bytes(interpreter, value)?
    for done in 0..<((node.bit_length + 63) / 64) {
        at :: done * 64
        count :: if node.bit_length - at < 64 { node.bit_length - at } else { 64 }
        put_bits(buffer.data, node.bit_offset + at, take_bits(source, at, count), count)
    }
    return .Ok
}

/**
 * Read a field: each access unit it covers read, and its bits taken.
 *
 * @param interpreter The interpreter.
 * @param frame The frame, for a PCI region's function's _ADR and the index and bank fields.
 * @param node The field.
 * @return Its bits, as field_value gives them.
 * @error OutOfRange A unit past its region's end.
 * @error RegionFailed The host couldn't read it.
 * @error Memory The evaluation's budget can't hold it.
 */
read_field :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], node: ptr[mut Node]) -> Result[Value, Error] #unrestricted {
    made :: temporary_bytes(interpreter, (node.bit_length + 7) / 8)?
    width :: access_bytes(node.access)
    unit_bits :: width * 8
    if node.bit_length == 0 {
        return .Ok(.Integer(0))
    }
    first :: node.bit_offset / unit_bits
    last :: (node.bit_offset + node.bit_length - 1) / unit_bits
    for unit in first..=last {
        value :: access_unit(interpreter, frame, node, unit * width, width, false, 0)?
        // The bits of this unit that are the field's
        unit_start :: unit * unit_bits
        from :: if node.bit_offset > unit_start { node.bit_offset } else { unit_start }
        to :: if node.bit_offset + node.bit_length < unit_start + unit_bits { node.bit_offset + node.bit_length } else { unit_start + unit_bits }
        put_bits(made.data, from - node.bit_offset, value >> (from - unit_start), to - from)
    }
    return .Ok(field_value(interpreter, made, node.bit_length))
}

/**
 * Write a field: each access unit it covers written, the bits of a unit outside it as its update rule says.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param node The field.
 * @param value The value: an integer, a buffer or a string; zeros past its end.
 * @error OutOfRange A unit past its region's end.
 * @error RegionFailed The host couldn't read or write it.
 * @error WrongType A value that's none of those.
 */
write_field :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], node: ptr[mut Node], value #escaping : Value) -> Result[void, Error] {
    source :: field_bytes(interpreter, value)?
    width :: access_bytes(node.access)
    unit_bits :: width * 8
    if node.bit_length == 0 {
        return .Ok
    }
    unit_mask :: if unit_bits >= 64 { cast[u64](0xffffffffffffffff) } else { (cast[u64](1) << unit_bits) - 1 }
    first :: node.bit_offset / unit_bits
    last :: (node.bit_offset + node.bit_length - 1) / unit_bits
    for unit in first..=last {
        unit_start :: unit * unit_bits
        from :: if node.bit_offset > unit_start { node.bit_offset } else { unit_start }
        to :: if node.bit_offset + node.bit_length < unit_start + unit_bits { node.bit_offset + node.bit_length } else { unit_start + unit_bits }
        whole :: from == unit_start && to == unit_start + unit_bits
        // What the unit's other bits are written as
        base : u64 = 0
        if !whole {
            match node.update {
                case .Preserve => base = access_unit(interpreter, frame, node, unit * width, width, false, 0)?
                case .WriteAsOnes => base = unit_mask
                case .WriteAsZeros => base = 0
            }
        }
        shift :: from - unit_start
        count :: to - from
        bits_mask :: if count >= 64 { cast[u64](0xffffffffffffffff) } else { ((cast[u64](1) << count) - 1) << shift }
        bits :: take_bits(source, from - node.bit_offset, count) << shift
        _ = access_unit(interpreter, frame, node, unit * width, width, true, (base & ~bits_mask) | (bits & bits_mask))?
    }
    return .Ok
}

/**
 * Read or write one access unit of a field.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param node The field.
 * @param offset The unit's offset in bytes, from the region's start, or the index's 0.
 * @param width The unit's bytes: 1, 2, 4 or 8.
 * @param write Whether it's written; read if not.
 * @param value What's written.
 * @return What was read; 0 for a write.
 * @error OutOfRange A unit past its region's end.
 * @error RegionFailed The host couldn't.
 */
access_unit :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], node: ptr[mut Node], offset: u64, width: u64, write: bool, value: u64) -> Result[u64, Error] {
    if node.kind == .IndexField {
        // The unit's offset to the index field, then the data field read or written
        index :: node.region or_return .Error(.NotFound)
        data :: node.data or_return .Error(.NotFound)
        store_to_node(interpreter, frame, .Integer(offset), index)?
        if write {
            store_to_node(interpreter, frame, .Integer(value), data)?
            return .Ok(0)
        }
        return integer_of(interpreter, value_of_node(interpreter, frame, data)?)
    }
    if node.kind == .BankField {
        bank :: node.data or_return .Error(.NotFound)
        store_to_node(interpreter, frame, .Integer(node.bank), bank)?
    }
    region :: node.region or_return .Error(.NotFound)
    if region.kind != .Region {
        return .Error(.WrongType)
    }
    if offset > region.length || width > region.length - offset {
        return .Error(.OutOfRange)
    }
    address := region.offset + offset
    if region.space == cast[u8](RegionSpace.PciConfig) {
        address = pci_function(interpreter, frame, region)? | (address & 0xffff)
    }
    bits :: cast[u32](width * 8)
    if write {
        if !interpreter.host.write(interpreter.host.state, region.space, address, bits, value) {
            return .Error(.RegionFailed)
        }
        return .Ok(0)
    }
    return .Ok(interpreter.host.read(interpreter.host.state, region.space, address, bits) or_return .Error(.RegionFailed))
}

/**
 * The PCI function a PCI_Config region is in, found once: its device's _ADR, and the _BBN and _SEG of the nearest
 * scopes up that have them, 0 where none does (ACPI 6.5 §6.1.1, §6.5.5, §6.5.6).
 *
 * @param interpreter The interpreter.
 * @param frame The frame, which _ADR, _BBN and _SEG are evaluated from.
 * @param region The region; its pci_found and pci are set.
 * @return The function, as pci_address makes it, with offset 0.
 */
pci_function :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], region: ptr[mut Node]) -> Result[u64, Error] {
    if region.pci_found {
        return .Ok(region.pci)
    }
    device :: region.parent or_return .Error(.NotFound)
    address :: optional_integer(interpreter, frame, device, "_ADR", false)?
    bus :: optional_integer(interpreter, frame, device, "_BBN", true)?
    segment :: optional_integer(interpreter, frame, device, "_SEG", true)?
    region.pci = pci_address(segment, bus, (address >> 16) & 0x1f, address & 7, 0)
    region.pci_found = true
    return .Ok(region.pci)
}

/**
 * Evaluate a node's child that's an integer, if it's there.
 *
 * @param interpreter The interpreter.
 * @param frame The frame.
 * @param scope The node it's looked for in.
 * @param name Its name.
 * @param upward Whether the scopes scope is in are looked in too, the nearest first.
 * @return Its value; 0 if it isn't there.
 */
optional_integer :: fn(interpreter: ptr[mut Interpreter], frame: ptr[mut Frame], scope: ptr[mut Node], name: string, upward: bool) -> Result[u64, Error] {
    at := scope
    loop {
        match child_of(at, segment_of(name)) {
            case Some(found) => return integer_of(interpreter, value_of_node(interpreter, frame, found)?)
            case None => {}
        }
        if !upward {
            break
        }
        at = at.parent or_break
    }
    return .Ok(0)
}

/**
 * The address the host is given for a PCI_Config region's access.
 *
 * @param segment The PCI segment group, 0 to 65535.
 * @param bus The bus, 0 to 255.
 * @param device The device, 0 to 31.
 * @param function The function, 0 to 7.
 * @param offset The offset in its configuration space, 0 to 4095.
 * @return The segment in bits 32 to 47, the bus in 24 to 31, the device in 19 to 23, the function in 16 to 18 and
 *     the offset in 0 to 15.
 */
pci_address :: fn(segment: u64, bus: u64, device: u64, function: u64, offset: u64) -> u64 {
    return ((segment & 0xffff) << 32) | ((bus & 0xff) << 24) | ((device & 0x1f) << 19) | ((function & 7) << 16) | (offset & 0xffff)
}
