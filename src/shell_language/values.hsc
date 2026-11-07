package shell_language

import runtime from "base"
import text_buffer from "std"
import unicode from "std"
import slop_os from "std/os"

/*
 * The shell's values (design/shell.md §2): typed, never re-parsed as text. Sizes are bytes and durations nanoseconds;
 * a path is the text written for it, resolved beneath the shell's directories when it's used; lists and records hold
 * values. Rendering is the shell's: a value written for a person, as a result is shown.
 */

/** A shell value: typed, never re-parsed as text. */
Value :: union {
    /** No value: what a statement without one gives, and what isn't shown. */
    Null,
    /** True or false. */
    Bool(bool),
    /** A whole number, signed, 64 bits. */
    Int(i64),
    /** A size, in bytes. */
    Size(u64),
    /** A duration, in nanoseconds; negative for one backwards. */
    Duration(i64),
    /** Text, UTF-8, from the heap or the line, never freed. */
    Text(string),
    /** A path, as the text written for it, resolved beneath the shell's directory only when it's used. */
    Path(string),
    /** A list of values, on the heap, shared by every copy of the value. */
    List(ptr[mut ValueList]),
    /** A record of named values, on the heap, shared by every copy of the value. */
    Record(ptr[mut RecordValue]),
    /**
     * A directory or file a script was given (decisions/0179, 11e6), on the heap, shared by every copy of the value: a
     * program's parameter of its kind is given another connection to it.
     */
    Handle(ptr[mut HandleValue]),
}

/** What a handle is a connection to. */
HandleKind :: enum {
    /** A directory, speaking dir. */
    Dir,
    /** A file to read and write, speaking file. */
    File,
    /** A file only to read, speaking read_only_file. */
    ReadOnlyFile,
}

/** A handle a script was given: what it reaches, its connection, and the name it was given by. */
HandleValue :: struct {
    /** What it's a connection to. */
    kind : HandleKind,
    /** The connection, the script's, never closed while it runs. */
    end : slop_os.Channel,
    /** The parameter it was given as, which it's shown by. */
    name : string,
}

/** A list's items. */
ValueList :: struct {
    /** The items, in order, from the heap. */
    items : Value[..],
}

/** A record's fields: names and values, each name's value at its own index. */
RecordValue :: struct {
    /** The fields' names, in the order they were first set; each appears once. */
    names : string[..],
    /** The fields' values, names[i]'s at i. */
    values : Value[..],
}

/**
 * Make an empty list.
 *
 * @return The list, on the heap from context's allocator; the shell never frees it.
 */
new_list :: fn() -> ptr[mut ValueList] {
    return runtime.new(ValueList)
}

/**
 * Make an empty record.
 *
 * @return The record, on the heap from context's allocator; the shell never frees it.
 */
new_record :: fn() -> ptr[mut RecordValue] {
    return runtime.new(RecordValue)
}

/**
 * Find a record's field by name.
 *
 * @param record The record searched, read only; its names and values are kept the same length by set_field.
 * @param name The field's name, compared exactly.
 * @return The field's value, a copy sharing any list or record in it; null if the record has no such field.
 */
field :: fn(record: ptr[RecordValue], name: string) -> Value? {
    for each, i in record.names {
        if each == name && i < record.values.count {
            return record.values[i]
        }
    }
    return null
}

/**
 * Set a record's field: replace its value if the record has it, or add it after the rest.
 *
 * @param record The record changed in place, which every copy of a value holding it sees.
 * @param name The field's name, kept by the record as it's given when the field is added, so it has to live as long.
 * @param value The value, kept by the record.
 */
set_field :: fn(record: ptr[mut RecordValue], name #escaping : string, value #escaping : Value) {
    for each, i in record.names {
        if each == name && i < record.values.count {
            record.values[i] = value
            return void
        }
    }
    runtime.array_add(&record.names, name)
    runtime.array_add(&record.values, value)
}

/**
 * Name what kind of value a value is, as errors say it.
 *
 * @param value Any value; only its kind is looked at, not what it holds.
 * @return Its kind with an article, like "an integer", or "null"; a literal, never freed.
 */
type_name :: fn(value: Value) -> string {
    return match value {
        case Null => "null"
        case Bool(_) => "a bool"
        case Int(_) => "an integer"
        case Size(_) => "a size"
        case Duration(_) => "a duration"
        case Text(_) => "a string"
        case Path(_) => "a path"
        case List(_) => "a list"
        case Record(_) => "a record"
        case Handle(handle) => match handle.kind {
            case .Dir => "a directory"
            case .File => "a file"
            case .ReadOnlyFile => "a file to read"
        }
    }
}

/**
 * Append a value as a person reads it.
 *
 * At the top, text is as it is, a list is one item a line, or a table when every item's a record, and a record is one
 * field a line. Inside a list or record, text is quoted, a list is in brackets and a record in braces, on one line. A
 * size is in the largest unit of 1024 it reaches, with a tenth when it isn't whole, and a duration in the largest unit
 * it's a whole number of.
 *
 * @param out The text appended to; what doesn't fit its storage is dropped, as text_buffer drops it.
 * @param value What's written, of any kind; a list's items and a record's fields are written in turn, nested.
 * @param nested Whether it's inside a list or record, so it's written on one line; false at the top.
 */
render :: fn(out: ptr[mut text_buffer.TextBuffer], value: Value, nested: bool = false) {
    match value {
        case Null => text_buffer.append(out, "null")
        case Bool(truth) => text_buffer.append(out, if truth { "true" } else { "false" })
        case Int(number) => append_signed(out, number)
        case Size(bytes) => append_size(out, bytes)
        case Duration(nanos) => append_duration(out, nanos)
        case Text(text) => {
            if nested {
                text_buffer.append(out, "\"")
                text_buffer.append(out, text)
                text_buffer.append(out, "\"")
            }
            else {
                text_buffer.append(out, text)
            }
        }
        case Path(text) => text_buffer.append(out, text)
        case Handle(handle) => {
            text_buffer.append(out, "<")
            text_buffer.append(out, type_name(Value.Handle(handle)))
            text_buffer.append(out, " ")
            text_buffer.append(out, handle.name)
            text_buffer.append(out, ">")
        }
        case List(list) => {
            if nested {
                text_buffer.append(out, "[")
                for item, i in list.items {
                    if i > 0 {
                        text_buffer.append(out, ", ")
                    }
                    render(out, item, true)
                }
                text_buffer.append(out, "]")
            }
            else if is_table(list) {
                render_table(out, list)
            }
            else {
                for item, i in list.items {
                    if i > 0 {
                        text_buffer.append(out, "\n")
                    }
                    render(out, item, true)
                }
            }
        }
        case Record(record) => {
            if nested {
                text_buffer.append(out, "{")
                for name, i in record.names {
                    if i > 0 {
                        text_buffer.append(out, ", ")
                    }
                    text_buffer.append(out, name)
                    text_buffer.append(out, ": ")
                    if i < record.values.count {
                        render(out, record.values[i], true)
                    }
                }
                text_buffer.append(out, "}")
            }
            else {
                for name, i in record.names {
                    if i > 0 {
                        text_buffer.append(out, "\n")
                    }
                    text_buffer.append(out, name)
                    text_buffer.append(out, ": ")
                    if i < record.values.count {
                        render(out, record.values[i], true)
                    }
                }
            }
        }
    }
}

/**
 * Append a signed number in decimal, with a '-' when it's negative.
 *
 * @param out The text appended to.
 * @param number The number, any i64, the smallest included.
 */
append_signed :: fn(out: ptr[mut text_buffer.TextBuffer], number: i64) {
    if number < 0 {
        text_buffer.append(out, "-")
    }
    text_buffer.append_unsigned(out, magnitude_of(number))
}

/**
 * Find a number's distance from 0, as a u64, which holds every i64's, the smallest's included.
 *
 * @param number The number, any i64.
 * @return Its magnitude: 2^63 for the smallest i64, which has no positive i64.
 */
magnitude_of :: fn(number: i64) -> u64 {
    // Negated as a u64, which wraps where an i64 would overflow
    return if number < 0 { 0 - cast[u64](number) } else { cast[u64](number) }
}

/** The units a size is shown in, each 1024 of the one before. */
SIZE_UNITS :: string.["B", "KiB", "MiB", "GiB", "TiB"]

/**
 * Append a size in the largest of SIZE_UNITS it reaches, with one decimal, truncated, when it isn't whole, like
 * "1.5 KiB".
 *
 * @param out The text appended to.
 * @param bytes The size, in bytes; past 1023 TiB it's still shown in TiB.
 */
append_size :: fn(out: ptr[mut text_buffer.TextBuffer], bytes: u64) {
    unit : usize = 0
    whole := bytes
    tenths := cast[u64](0)
    loop {
        if whole < 1024 || unit + 1 >= SIZE_UNITS.count {
            break
        }
        tenths = (whole % 1024) * 10 / 1024
        whole = whole / 1024
        unit += 1
    }
    text_buffer.append_unsigned(out, whole)
    if tenths > 0 {
        text_buffer.append(out, ".")
        text_buffer.append_unsigned(out, tenths)
    }
    text_buffer.append(out, " ")
    text_buffer.append(out, SIZE_UNITS[unit % SIZE_UNITS.count])
}

/**
 * Append a duration in the largest unit, from hours to nanoseconds, it's a whole number of, like "90 s" or "2 h".
 *
 * @param out The text appended to.
 * @param nanos The duration, in nanoseconds; negative ones get a '-'. 0 is written "0 ns".
 */
append_duration :: fn(out: ptr[mut text_buffer.TextBuffer], nanos: i64) {
    if nanos < 0 {
        text_buffer.append(out, "-")
    }
    magnitude :: magnitude_of(nanos)
    units :: u64.[3_600_000_000_000, 60_000_000_000, 1_000_000_000, 1_000_000, 1_000, 1]
    names :: string.["h", "m", "s", "ms", "us", "ns"]
    for unit, i in units {
        if magnitude >= unit && magnitude % unit == 0 && i < names.count {
            text_buffer.append_unsigned(out, magnitude / unit)
            text_buffer.append(out, " ")
            text_buffer.append(out, names[i])
            return void
        }
    }
    text_buffer.append_unsigned(out, magnitude)
    text_buffer.append(out, " ns")
}

/**
 * Tell whether a list is shown as a table.
 *
 * @param list The list looked at, read only.
 * @return True if it has items and every one's a record.
 */
is_table :: fn(list: ptr[ValueList]) -> bool {
    for item in list.items {
        match item {
            case Record(_) => {}
            case _ => return false
        }
    }
    return list.items.count > 0
}

/**
 * Append a list of records as a table: a column for each field, in the order they're first met, headed by its name,
 * each as wide as its widest cell, two spaces apart; a record without a field leaves its cell blank.
 *
 * Widths are the columns text takes on a terminal (unicode.text_width), so wide characters and accents line up.
 *
 * @param out The text appended to: the heading line, then a line for each record, without a line break at the end.
 * @param list The list, every item a record (is_table); an item that isn't is a blank row.
 */
render_table :: fn(out: ptr[mut text_buffer.TextBuffer], list: ptr[ValueList]) {
    columns : string[..]
    defer runtime.array_free(&columns)
    widths : usize[..]
    defer runtime.array_free(&widths)
    for item in list.items {
        match item {
            case Record(record) => {
                for name in record.names {
                    known := false
                    for column in columns {
                        known = known || column == name
                    }
                    if !known {
                        runtime.array_add(&columns, name)
                        runtime.array_add(&widths, width_of(name))
                    }
                }
            }
            case _ => {}
        }
    }
    for item in list.items {
        for column, i in columns {
            cell :: cell_width(item, column)
            if i < widths.count && cell > widths[i] {
                widths[i] = cell
            }
        }
    }
    for column, i in columns {
        wide :: if i < widths.count { widths[i] } else { 0 }
        text_buffer.append(out, column)
        if i + 1 < columns.count {
            written :: width_of(column)
            pad(out, (if wide > written { wide - written } else { 0 }) + 2)
        }
    }
    for item in list.items {
        text_buffer.append(out, "\n")
        for column, i in columns {
            wide :: if i < widths.count { widths[i] } else { 0 }
            written :: cell_width(item, column)
            render_cell(out, item, column)
            if i + 1 < columns.count {
                pad(out, (if wide > written { wide - written } else { 0 }) + 2)
            }
        }
    }
}

/**
 * Measure text as a terminal shows it.
 *
 * @param text The text, UTF-8 or not, only read.
 * @return The columns it takes (unicode.text_width): wide characters 2, accents 0, a byte that isn't UTF-8 1.
 */
width_of :: fn(text: string) -> usize {
    return unicode.text_width(string_bytes(text))
}

/**
 * Append a table's cell: a record's field, text as it is, anything else as it's shown inside a list.
 *
 * @param out The text appended to.
 * @param item The row's record; nothing's appended for anything else.
 * @param column The field's name; nothing's appended if the record hasn't the field.
 */
render_cell :: fn(out: ptr[mut text_buffer.TextBuffer], item: Value, column: string) {
    match item {
        case Record(record) => {
            value :: field(record, column) or_return void
            match value {
                case Text(text) => text_buffer.append(out, text)
                case _ => render(out, value, true)
            }
        }
        case _ => {}
    }
}

/**
 * Measure a table's cell as render_cell writes it.
 *
 * @param item The row's record; anything else is a cell 0 wide.
 * @param column The field's name; 0 if the record hasn't the field.
 * @return The columns the cell takes (width_of), of its first 256 bytes: what's past them isn't counted.
 */
cell_width :: fn(item: Value, column: string) -> usize {
    storage : u8[256]
    out := text_buffer.make(storage)
    render_cell(&out, item, column)
    return width_of(text_buffer.as_string(&out))
}

/**
 * Append spaces.
 *
 * @param out The text appended to.
 * @param count How many spaces.
 */
pad :: fn(out: ptr[mut text_buffer.TextBuffer], count: usize) {
    for i in 0..<count {
        text_buffer.append(out, " ")
    }
}
