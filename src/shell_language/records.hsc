package shell_language

import runtime from "base"
import schema from "std"
import strings from "std"
import text_buffer from "std"

/*
 * Values written as a program's entry and a pipeline's records are laid out (std/schema's write_value), and read back:
 * the shell's typed values to and from the bytes of a manifest's types.
 */

/**
 * Write a value at an offset in out as a value of the type at a place is laid out, with what it points to added after
 * everything (std/schema's write_value: a string's bytes, a list's items, at their distance from the start).
 *
 * The shell writes integers, bools, strings, enums, durations, structs from records, optionals' Some, and views of
 * lists; a bare word is read by the type: a number, a member's name, a duration, or text.
 *
 * @param manifest The program's manifest, only read.
 * @param place The type's place among the manifest's types; an alias is followed to what it names.
 * @param given The value written, of any kind; which kinds a type takes is said above, and a Text is read by the type
 *     only when bare. A list's items and a record's fields are written in turn.
 * @param bare Whether the value is a bare word's text, so a number or duration is read from it.
 * @param out The value's bytes, grown with what it points to; the bytes at offset have to be there already.
 * @param offset Where the value goes in out, in bytes.
 * @return Null once it's written; why it can't be otherwise, a sentence for a person: the wrong kind of value, a number
 *     out of the type's range, an enum member it hasn't, a record missing a field, or a type the shell can't give.
 */
encode :: fn(manifest: ptr[schema.Schema], place: usize, given: Value, bare: bool, out: ptr[mut u8[..]], offset: usize) -> string? {
    unaliased :: schema.unaliased_place(manifest, place)
    type :: schema.type_in(manifest, unaliased) or_return "its manifest is cut short"
    size :: cast[usize](type.size)
    if type.kind == .Integer {
        number := cast[i64](0)
        match given {
            case Int(value) => number = value
            case Size(value) => number = cast[i64](value)
            case Text(text) => {
                if !bare {
                    return message("% isn't a number", type_text(manifest, place))
                }
                number = integer_of(text) or_return message("% isn't a number", text)
            }
            case _ => return message("it takes a number, not %", type_name(given))
        }
        if !type.is_signed && number < 0 {
            return message("% can't be below 0", number)
        }
        if size < 8 {
            bits :: 8 * cast[u64](size)
            limit :: if type.is_signed { cast[i64](1) << (bits - 1) } else { cast[i64](1) << bits }
            low :: if type.is_signed { 0 - limit } else { cast[i64](0) }
            if number >= limit || number < low {
                return message("% is too big for it", number)
            }
        }
        put(out, offset, cast[u64](number), size)
        return null
    }
    if type.kind == .Boolean {
        match given {
            case Bool(value) => put(out, offset, if value { cast[u64](1) } else { cast[u64](0) }, size)
            case Text(text) => {
                if !bare || (text != "true" && text != "false") {
                    return message("it takes true or false, not %", text)
                }
                put(out, offset, if text == "true" { cast[u64](1) } else { cast[u64](0) }, size)
            }
            case _ => return message("it takes true or false, not %", type_name(given))
        }
        return null
    }
    if type.kind == .String && !type.is_raw {
        text :: match given {
            case Text(value) => value
            case Path(value) => value
            case _ => return message("it takes text, not %", type_name(given))
        }
        put(out, offset, cast[u64](text.count), 8)
        put(out, offset + 8, cast[u64](tail(out, string_bytes(text))), 8)
        return null
    }
    if type.kind == .Enum {
        name :: match given {
            case Text(value) => value
            case _ => return message("it takes one of %'s members, not %", type.name, type_name(given))
        }
        for constant in type.constants {
            if constant.name == name {
                put(out, offset, constant.value, size)
                return null
            }
        }
        return message("% isn't one of %", name, members_text(type))
    }
    if type.kind == .Struct && type.name == "Duration" {
        nanoseconds := cast[i64](0)
        match given {
            case Duration(value) => nanoseconds = value
            case Text(text) => {
                if !bare {
                    return message("% isn't a duration, like 5s", text)
                }
                nanoseconds = duration_of(text) or_return message("% isn't a duration, like 5s", text)
            }
            case _ => return message("it takes a duration, like 5s, not %", type_name(given))
        }
        for member in type.members {
            if member.name == "seconds" {
                put(out, offset + cast[usize](member.offset), cast[u64](nanoseconds / 1000000000), 8)
            }
            else if member.name == "nanos" {
                put(out, offset + cast[usize](member.offset), cast[u64](nanoseconds % 1000000000), 4)
            }
        }
        return null
    }
    if type.kind == .Struct && !type.is_union {
        record :: match given {
            case Record(value) => value
            case _ => return message("it takes a record of %'s fields, not %", type.name, type_name(given))
        }
        for member in type.members {
            value :: field(record, member.name) or_return message("the record has no field %", member.name)
            problem :: encode(manifest, member.type, value, false, out, offset + cast[usize](member.offset))
            if problem is_some {
                return problem
            }
        }
        return null
    }
    if type.kind == .Union {
        // An optional's Some, written with its tag
        for variant, index in type.variants {
            if variant.name != "Some" || variant.held.count != 1 {
                continue
            }
            for held in variant.held {
                tag_size :: match schema.type_in(manifest, type.tag) {
                    case Some(tag) => cast[usize](tag.size)
                    case None => cast[usize](0)
                }
                put(out, offset, cast[u64](index), tag_size)
                return encode(manifest, held.type, given, bare, out, offset + cast[usize](held.offset))
            }
        }
        return message("the shell can't give a %", type_text(manifest, place))
    }
    if type.kind == .Array && type.dimensions.count == 1 {
        for dimension in type.dimensions {
            if dimension.kind != .View {
                break
            }
            list :: match given {
                case List(value) => value
                case _ => return message("it takes a list, not %", type_name(given))
            }
            element :: schema.type_in(manifest, type.base) or_return "its manifest is cut short"
            element_size :: cast[usize](element.size)
            align(out)
            start :: out.count
            zero(out, element_size * list.items.count)
            align(out)
            put(out, offset, cast[u64](list.items.count), 8)
            put(out, offset + 8, cast[u64](start), 8)
            for item, i in list.items {
                problem :: encode(manifest, type.base, item, false, out, start + i * element_size)
                if problem is_some {
                    return problem
                }
            }
            return null
        }
    }
    return message("the shell can't give a %", type_text(manifest, place))
}

/**
 * Write a number's low bytes, little-endian, in place; bytes past out's end aren't written.
 *
 * @param out The bytes written in.
 * @param offset Where the number's lowest byte goes in out, in bytes from its start.
 * @param value The number, of which only the low count bytes are written; any above are dropped.
 * @param count How many of its bytes, at most 8.
 */
put :: fn(out: ptr[mut u8[..]], offset: usize, value: u64, count: usize) {
    target : mut u8[] = out^
    for i in cast[usize](0)..<count {
        at :: offset + i
        if at < target.count && i < 8 {
            target[at] = cast[u8]((value >> (8 * cast[u64](i))) & 0xff)
        }
    }
}

/**
 * Add bytes after everything in out, at 8 bytes' alignment, out padded to 8 after them too.
 *
 * @param out The bytes added to.
 * @param bytes The bytes, copied.
 * @return Where they start in out, in bytes.
 */
tail :: fn(out: ptr[mut u8[..]], bytes: u8[]) -> usize {
    align(out)
    start :: out.count
    for byte in bytes {
        runtime.array_add(out, byte)
    }
    align(out)
    return start
}

/**
 * Add zero bytes after everything in out.
 *
 * @param out The bytes added to.
 * @param count How many zero bytes are added; 0 adds none.
 */
zero :: fn(out: ptr[mut u8[..]], count: usize) {
    for i in cast[usize](0)..<count {
        runtime.array_add(out, cast[u8](0))
    }
}

/**
 * Pad out with zero bytes to a multiple of 8 bytes.
 *
 * @param out The bytes, grown by 0 to 7 zero bytes; nothing's added when its count is a multiple of 8 already.
 */
align :: fn(out: ptr[mut u8[..]]) {
    loop {
        if out.count % 8 == 0 {
            break
        }
        runtime.array_add(out, cast[u8](0))
    }
}

/**
 * Read a word as a whole number, in decimal, with a - if it's negative.
 *
 * @param text The word, as written: an optional - then decimal digits, nothing else, not even spaces.
 * @return The number; null if it's empty, has anything but digits after the sign, or more than 18 digits.
 */
integer_of :: fn(text: string) -> i64? {
    if text.count == 0 {
        return null
    }
    negative :: slice(text, 0, 1) == "-"
    digits :: if negative { slice(text, 1, text.count) } else { text }
    if digits.count == 0 || digits.count > 18 {
        return null
    }
    result := cast[i64](0)
    for character in digits {
        if character < '0' || character > '9' {
            return null
        }
        result = result * 10 + cast[i64](cast[u8](character) - cast[u8]('0'))
    }
    return if negative { 0 - result } else { result }
}

/**
 * Read a word as a duration: a number then its unit (5s, 250ms), as unit_value names them.
 *
 * @param text The word; one starting with - isn't read.
 * @return The duration, in nanoseconds; null if it isn't one, or has a size's unit or none.
 */
duration_of :: fn(text: string) -> i64? {
    for character, i in text {
        if character < '0' || character > '9' {
            number :: integer_of(slice(text, 0, i)) or_return null
            unit :: unit_value(slice(text, i, text.count)) or_return null
            if unit.size {
                return null
            }
            return number * cast[i64](unit.scale)
        }
    }
    return null
}

/**
 * Name a type as a person reads it: its name, or its kind.
 *
 * @param manifest The program's manifest, only read.
 * @param place The type's place among the manifest's types, taken as it is: an alias is named as itself.
 * @return Its name, a view of the manifest's text; or its kind, a literal; "value" for a place not in the manifest.
 */
type_text :: fn(manifest: ptr[schema.Schema], place: usize) -> string {
    type :: schema.type_in(manifest, place) or_return "value"
    if type.name.count > 0 {
        return type.name
    }
    return match type.kind {
        case .Integer => if type.is_signed { "whole number" } else { "count" }
        case .Boolean => "bool"
        case .String => "string"
        case .Array => "list"
        case .Union => "choice"
        case _ => "value"
    }
}

/**
 * List an enum's members, to read: a, b or c.
 *
 * @param type The enum's type in a manifest, whose constants are listed in their order; only read. One without
 *     constants gives "".
 * @return The list, on the heap, never freed, cut at 256 bytes; the enum's name if it couldn't be copied.
 */
members_text :: fn(type: ptr[schema.Type]) -> string {
    storage : u8[256]
    out := text_buffer.make(storage)
    for constant, i in type.constants {
        if i > 0 {
            text_buffer.append(&out, if i + 1 == type.constants.count { " or " } else { ", " })
        }
        text_buffer.append(&out, constant.name)
    }
    return strings.clone(text_buffer.as_string(&out)) or_else type.name
}

/**
 * Read a value of the type at a place, at an offset in a record's bytes (as std/schema's write_value writes one), as
 * the shell's: integers, bools, text, an enum's member's name, a duration, a record of a struct's fields, an
 * optional's value or null, a union's variant as a record of it, and a list of an array's items.
 *
 * Bytes that aren't there read as 0, so a cut-short record gives zeros and empty text, never a fault.
 *
 * @param manifest The program's manifest, whose types the record's are; only read.
 * @param place The type's place among the manifest's types, an alias's followed to what it names.
 * @param bytes The record's bytes, the stream's, which nothing's kept of: text and names are copied to the heap.
 * @param at Where the value starts in bytes.
 * @param depth How deeply nested it is, from 0; past 16 it's Null, so a looping type can't recurse forever.
 * @return The value; Null for a type the shell doesn't read, or one not in the manifest. An enum's value without a
 *     member is an Int.
 */
decode :: fn(manifest: ptr[schema.Schema], place: usize, bytes: u8[], at: usize, depth: usize) -> Value {
    type :: schema.type_in(manifest, schema.unaliased_place(manifest, place)) or_return Value.Null
    size :: cast[usize](type.size)
    if depth > 16 {
        return .Null
    }
    if type.kind == .Integer {
        bits :: number_in(bytes, at, size)
        if type.is_signed && size < 8 && size > 0 {
            shift :: 64 - 8 * cast[u64](size)
            return .Int(cast[i64](bits << shift) >> shift)
        }
        return .Int(cast[i64](bits))
    }
    if type.kind == .Boolean {
        return .Bool(number_in(bytes, at, size) != 0)
    }
    if type.kind == .String && !type.is_raw {
        count :: cast[usize](number_in(bytes, at, 8))
        distance :: cast[usize](number_in(bytes, at + 8, 8))
        return .Text(text_in(bytes, distance, count))
    }
    if type.kind == .Enum {
        value :: number_in(bytes, at, size)
        for constant in type.constants {
            if constant.value == value {
                return .Text(strings.clone(constant.name) or_else "")
            }
        }
        return .Int(cast[i64](value))
    }
    if type.kind == .Struct && type.name == "Duration" {
        nanoseconds := cast[i64](0)
        for member in type.members {
            if member.name == "seconds" {
                nanoseconds += cast[i64](number_in(bytes, at + cast[usize](member.offset), 8)) * 1000000000
            }
            else if member.name == "nanos" {
                nanoseconds += cast[i64](number_in(bytes, at + cast[usize](member.offset), 4))
            }
        }
        return .Duration(nanoseconds)
    }
    if type.kind == .Struct && !type.is_union {
        made :: new_record()
        for member in type.members {
            member_type :: schema.type_in(manifest, member.type) or_continue
            if member_type.size == 0 {
                continue
            }
            set_field(made, strings.clone(member.name) or_else "", decode(manifest, member.type, bytes, at + cast[usize](member.offset), depth + 1))
        }
        return .Record(made)
    }
    if type.kind == .Union {
        tag_size :: match schema.type_in(manifest, type.tag) {
            case Some(tag) => cast[usize](tag.size)
            case None => cast[usize](0)
        }
        tag :: cast[usize](number_in(bytes, at, tag_size))
        for variant, index in type.variants {
            if index != tag {
                continue
            }
            if variant.name == "None" {
                return .Null
            }
            for held in variant.held {
                inner :: decode(manifest, held.type, bytes, at + cast[usize](held.offset), depth + 1)
                if variant.name == "Some" {
                    return inner
                }
                made :: new_record()
                set_field(made, strings.clone(variant.name) or_else "", inner)
                return .Record(made)
            }
            return .Text(strings.clone(variant.name) or_else "")
        }
        return .Null
    }
    if type.kind == .Array && type.dimensions.count == 1 {
        element :: schema.type_in(manifest, type.base) or_return Value.Null
        element_size :: cast[usize](element.size)
        made :: new_list()
        for dimension in type.dimensions {
            count := cast[usize](dimension.count)
            start := at
            if dimension.kind != .Static {
                count = cast[usize](number_in(bytes, at, 8))
                start = cast[usize](number_in(bytes, at + 8, 8))
            }
            if element_size == 0 || count > bytes.count / element_size {
                return .List(made)
            }
            for i in 0..<count {
                runtime.array_add(&made.items, decode(manifest, type.base, bytes, start + i * element_size, depth + 1))
            }
        }
        return .List(made)
    }
    if type.kind == .Pointer {
        distance :: cast[usize](number_in(bytes, at, 8))
        if distance == 0 || type.base == schema.NOWHERE {
            return .Null
        }
        return decode(manifest, type.base, bytes, distance, depth + 1)
    }
    return .Null
}

/**
 * Read a little-endian number.
 *
 * @param bytes The bytes read from, a record's; only read.
 * @param at Where it starts, in bytes.
 * @param count How many bytes it is, at most 8.
 * @return The number; 0 if the bytes aren't all there, or count is past 8.
 */
number_in :: fn(bytes: u8[], at: usize, count: usize) -> u64 {
    if count > 8 || at > bytes.count || count > bytes.count - at {
        return 0
    }
    result : u64 = 0
    for i in 0..<count {
        result |= cast[u64](bytes[(at + i) % bytes.count]) << (8 * cast[u64](i))
    }
    return result
}

/**
 * Copy bytes as text of the shell's own.
 *
 * @param bytes The bytes the text is copied from, a record's; nothing of them is kept.
 * @param at Where the text starts, in bytes.
 * @param count How many bytes it is.
 * @return The text, on the heap, never freed; "" if the bytes aren't all there, there are none, or there's no memory.
 */
text_in :: fn(bytes: u8[], at: usize, count: usize) -> string {
    if count == 0 || at >= bytes.count || count > bytes.count - at {
        return ""
    }
    return strings.clone(string_of(&bytes[at], count)) or_else ""
}
