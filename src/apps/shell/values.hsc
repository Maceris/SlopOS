package shell

import runtime from "base"
import text_buffer from "std"

/*
 * The shell's values (design/shell.md §2): typed, never re-parsed as text. Sizes are bytes and durations nanoseconds;
 * a path is the text written for it, resolved beneath the shell's directories when it's used; lists and records hold
 * values. Rendering is the shell's: a value written for a person, as a result is shown.
 */

Value :: union {
    Null,
    Bool(bool),
    Int(i64),
    // Bytes
    Size(u64),
    // Nanoseconds
    Duration(i64),
    Text(string),
    Path(string),
    List(ptr[mut ValueList]),
    Record(ptr[mut RecordValue]),
}

ValueList :: struct {
    items : Value[..],
}

RecordValue :: struct {
    names : string[..],
    values : Value[..],
}

new_list :: fn() -> ptr[mut ValueList] {
    return runtime.new(ValueList)
}

new_record :: fn() -> ptr[mut RecordValue] {
    return runtime.new(RecordValue)
}

// A record's field by name, or null.
field :: fn(record: ptr[RecordValue], name: string) -> Value? {
    for each, i in record.names {
        if each == name && i < record.values.count {
            return record.values[i]
        }
    }
    return null
}

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

// What a value is, by name, as errors say.
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
    }
}

/*
 * A value as a person reads it, appended to out: text as it is at the top, quoted inside a list or record; a size in the
 * largest unit it's a whole number of, or with one decimal; a list one item a line, a record one field a line.
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

append_signed :: fn(out: ptr[mut text_buffer.TextBuffer], number: i64) {
    if number < 0 {
        text_buffer.append(out, "-")
        text_buffer.append_unsigned(out, cast[u64](0 - number))
    }
    else {
        text_buffer.append_unsigned(out, cast[u64](number))
    }
}

SIZE_UNITS :: string.["B", "KiB", "MiB", "GiB", "TiB"]

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

append_duration :: fn(out: ptr[mut text_buffer.TextBuffer], nanos: i64) {
    if nanos < 0 {
        text_buffer.append(out, "-")
    }
    magnitude :: cast[u64](if nanos < 0 { 0 - nanos } else { nanos })
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

// Whether a list is shown as a table: it has items, and every one's a record.
is_table :: fn(list: ptr[ValueList]) -> bool {
    for item in list.items {
        match item {
            case Record(_) => {}
            case _ => return false
        }
    }
    return list.items.count > 0
}

/*
 * A list of records as a table: a column for each field, in the order they're first met, headed by its name, each as
 * wide as its widest cell, two spaces apart; a record without a field leaves its cell blank.
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
                        runtime.array_add(&widths, name.count)
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
        last :: i + 1 == columns.count
        text_buffer.append(out, column)
        if !last && i < widths.count {
            pad(out, widths[i] - column.count + 2)
        }
    }
    for item in list.items {
        text_buffer.append(out, "\n")
        for column, i in columns {
            last :: i + 1 == columns.count
            start :: out.count
            render_cell(out, item, column)
            if !last && i < widths.count {
                written :: out.count - start
                pad(out, (if widths[i] > written { widths[i] - written } else { 0 }) + 2)
            }
        }
    }
}

// A table's cell: a record's field, text as it is, anything else as it's shown inside a list.
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

cell_width :: fn(item: Value, column: string) -> usize {
    storage : u8[256]
    out := text_buffer.make(storage)
    render_cell(&out, item, column)
    return out.count
}

pad :: fn(out: ptr[mut text_buffer.TextBuffer], count: usize) {
    for i in 0..<count {
        text_buffer.append(out, " ")
    }
}
