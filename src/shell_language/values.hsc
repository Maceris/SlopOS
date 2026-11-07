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
    /** A point in time, in nanoseconds since 1970-01-01T00:00:00Z, UTC; negative before it (decisions/0181, F1). */
    Instant(i64),
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
        case Instant(_) => "an instant"
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
 * @param columns How wide a table may be, in the terminal's columns (decisions/0181, F1): wider, its widest columns are
 *     narrowed until it fits, and cells cut, ending in …; 0 for no limit.
 */
render :: fn(out: ptr[mut text_buffer.TextBuffer], value: Value, nested: bool = false, columns: usize = 0) {
    match value {
        case Null => text_buffer.append(out, "null")
        case Bool(truth) => text_buffer.append(out, if truth { "true" } else { "false" })
        case Int(number) => append_signed(out, number)
        case Size(bytes) => append_size(out, bytes)
        case Duration(nanos) => append_duration(out, nanos)
        case Instant(nanos) => append_instant(out, nanos)
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
                render_table(out, list, columns)
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
 * Append an instant as ISO 8601 in UTC, to the second: 2026-11-07T09:30:00Z.
 *
 * @param out The text appended to.
 * @param nanos Nanoseconds since 1970-01-01T00:00:00Z; negative before it, rounded down to the second.
 */
append_instant :: fn(out: ptr[mut text_buffer.TextBuffer], nanos: i64) {
    seconds :: if nanos >= 0 { nanos / 1000000000 } else { (nanos - 999999999) / 1000000000 }
    days :: if seconds >= 0 { seconds / 86400 } else { (seconds - 86399) / 86400 }
    in_day :: seconds - days * 86400
    // The civil date from days since the epoch (Howard Hinnant's days_from_civil, run backwards)
    shifted :: days + 719468
    era :: (if shifted >= 0 { shifted } else { shifted - 146096 }) / 146097
    day_of_era :: shifted - era * 146097
    year_of_era :: (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365
    day_of_year :: day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
    month_index :: (5 * day_of_year + 2) / 153
    day :: day_of_year - (153 * month_index + 2) / 5 + 1
    month :: if month_index < 10 { month_index + 3 } else { month_index - 9 }
    year :: year_of_era + era * 400 + (if month <= 2 { cast[i64](1) } else { cast[i64](0) })
    append_signed(out, year)
    for part in i64.[month, day] {
        text_buffer.append(out, "-")
        append_two(out, part)
    }
    text_buffer.append(out, "T")
    append_two(out, in_day / 3600)
    text_buffer.append(out, ":")
    append_two(out, in_day / 60 % 60)
    text_buffer.append(out, ":")
    append_two(out, in_day % 60)
    text_buffer.append(out, "Z")
}

/**
 * Append a number of two digits, with a 0 in front below 10.
 *
 * @param out The text appended to.
 * @param number The number, 0 to 99.
 */
append_two :: fn(out: ptr[mut text_buffer.TextBuffer], number: i64) {
    if number < 10 {
        text_buffer.append(out, "0")
    }
    append_signed(out, number)
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
 * each as wide as its widest cell, two spaces apart; a record without a field leaves its cell blank. A table wider
 * than columns has its widest column narrowed a column at a time, down to MIN_COLUMN, until it fits, and a cell, or a
 * heading, wider than its column is cut, ending in … .
 *
 * Widths are the columns text takes on a terminal (unicode.text_width), so wide characters and accents line up.
 *
 * @param out The text appended to: the heading line, then a line for each record, without a line break at the end.
 * @param list The list, every item a record (is_table); an item that isn't is a blank row.
 * @param columns How wide the table may be, in columns; 0 for no limit.
 */
render_table :: fn(out: ptr[mut text_buffer.TextBuffer], list: ptr[ValueList], columns: usize = 0) {
    names : string[..]
    defer runtime.array_free(&names)
    widths : usize[..]
    defer runtime.array_free(&widths)
    for item in list.items {
        match item {
            case Record(record) => {
                for name in record.names {
                    known := false
                    for column in names {
                        known = known || column == name
                    }
                    if !known {
                        runtime.array_add(&names, name)
                        runtime.array_add(&widths, width_of(name))
                    }
                }
            }
            case _ => {}
        }
    }
    for item in list.items {
        for column, i in names {
            cell :: cell_width(item, column)
            if i < widths.count && cell > widths[i] {
                widths[i] = cell
            }
        }
    }
    if columns > 0 {
        fit_widths(&widths, columns)
    }
    for column, i in names {
        wide :: if i < widths.count { widths[i] } else { 0 }
        written :: append_cut(out, column, wide)
        if i + 1 < names.count {
            pad(out, (if wide > written { wide - written } else { 0 }) + 2)
        }
    }
    for item in list.items {
        text_buffer.append(out, "\n")
        for column, i in names {
            wide :: if i < widths.count { widths[i] } else { 0 }
            storage : u8[256]
            cell := text_buffer.make(storage)
            render_cell(&cell, item, column)
            written :: append_cut(out, text_buffer.as_string(&cell), wide)
            if i + 1 < names.count {
                pad(out, (if wide > written { wide - written } else { 0 }) + 2)
            }
        }
    }
}

/** The narrowest a column is made to fit a table to the terminal: room for a letter or two and the … . */
MIN_COLUMN :: 4

/**
 * Narrow a table's widest columns, a column at a time, until the table fits, or every column is MIN_COLUMN or less.
 *
 * @param widths The columns' widths, changed in place.
 * @param columns How wide the table may be, two spaces between its columns counted.
 */
fit_widths :: fn(widths: ptr[mut usize[..]], columns: usize) {
    loop {
        total := cast[usize](0)
        widest := cast[usize](0)
        widest_at := widths.count
        for width, i in widths^ {
            total += width + (if i > 0 { cast[usize](2) } else { cast[usize](0) })
            if width > widest {
                widest = width
                widest_at = i
            }
        }
        if total <= columns || widest <= MIN_COLUMN || widest_at >= widths.count {
            return void
        }
        for &width, i in widths^ {
            if i == widest_at {
                width^ = widest - 1
            }
        }
    }
}

/**
 * Append text cut to a width: whole if it fits, else as many grapheme clusters as fit with … after them.
 *
 * @param out The text appended to.
 * @param text The text.
 * @param wide The most columns it may take; 0 appends nothing.
 * @return How many columns were appended.
 */
append_cut :: fn(out: ptr[mut text_buffer.TextBuffer], text: string, wide: usize) -> usize {
    whole :: width_of(text)
    if whole <= wide {
        text_buffer.append(out, text)
        return whole
    }
    if wide == 0 {
        return 0
    }
    bytes :: string_bytes(text)
    taken := cast[usize](0)
    end := cast[usize](0)
    loop {
        if end >= bytes.count {
            break
        }
        next :: unicode.grapheme_end(bytes, end)
        if next <= end || next > bytes.count {
            break
        }
        cluster :: unicode.grapheme_width(bytes[end..<next])
        if taken + cluster > wide - 1 {
            break
        }
        taken += cluster
        end = next
    }
    if end > 0 {
        text_buffer.append(out, string_of(&bytes[0], end))
    }
    text_buffer.append(out, "…")
    return taken + 1
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
