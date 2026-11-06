/**
 * The shell's language on the host (roadmap 11d): lines parsed, values written as a program's entry reads them and
 * read back, arithmetic at the edges of its numbers, names filled into strings, the stages' grouping, and results
 * rendered. Property tests draw lines and values; the rest are examples.
 */
package shell_language_test

import runtime from "base"
import schema from "std"
import testing from "std"
import text_buffer from "std"
import language from ".."

/**
 * Find a parsed line's first statement.
 *
 * @param tree The line's Statements node.
 * @return Its first child; null for a line without statements.
 */
first_of :: fn(tree: ptr[language.Node]) -> ptr[language.Node]? {
    for statement in tree.children {
        return statement
    }
    return null
}

// ---- Drawing lines and values

/**
 * The pieces lines are drawn from: what the language gives meaning to, with words, numbers, units and text that isn't
 * ASCII among them, so drawn lines reach every part of the parser.
 */
LINE_PIECES :: string.[" ", "a", "x-y", "let ", "fn ", "or ", "try ", "catch ", "return ", "not ", "and ", "true", "null", "1", "42",
    "9223372036854775807", "99999999999999999999", "4MiB", "250ms", "s", "$", "$a", "\"", "\"$a\"", "\\", "(", ")", "[", "]", "{", "}", "|", ";",
    "?", ",", ":", "=", "==", "+", "-", "*", "/", "<", ">=", ".", ".n", "#", "--", "--a", "\n", "where ", "take ", "group ", "sort ", "map ", "&",
    "日本", "é"]

/**
 * Draw a line: up to most pieces of LINE_PIECES, one after another.
 *
 * @param source The source drawn from.
 * @param most The most pieces.
 * @return The line, on the heap, never freed; "" for no pieces.
 */
draw_line :: fn(source: ptr[mut testing.Source], most: usize) -> string {
    made : u8[..]
    for i in 0..<testing.draw_count(source, most) {
        piece :: LINE_PIECES[cast[usize](testing.draw_below(source, cast[u64](LINE_PIECES.count))) % LINE_PIECES.count]
        for byte in string_bytes(piece) {
            runtime.array_add(&made, byte)
        }
    }
    line :: if made.count > 0 { string_of(&made[0], made.count) } else { "" }
    testing.show(source, line)
    return line
}

/** The pieces a value's text is drawn from: ASCII, a wide character and an accent, and a quote. */
TEXT_PIECES :: string.["a", "b", " ", "日", "é", "\"", "-"]

/**
 * Draw text: up to most pieces of TEXT_PIECES.
 *
 * @param source The source drawn from.
 * @param most The most pieces.
 * @return The text, on the heap, never freed; "" for no pieces.
 */
draw_text :: fn(source: ptr[mut testing.Source], most: usize) -> string {
    made : u8[..]
    for i in 0..<testing.draw_count(source, most) {
        piece :: TEXT_PIECES[cast[usize](testing.draw_below(source, cast[u64](TEXT_PIECES.count))) % TEXT_PIECES.count]
        for byte in string_bytes(piece) {
            runtime.array_add(&made, byte)
        }
    }
    return if made.count > 0 { string_of(&made[0], made.count) } else { "" }
}

/**
 * Render a value as the shell shows it inside a list, on one line.
 *
 * @param value The value.
 * @return The text, on the heap, never freed; cut at 4 KiB.
 */
rendered :: fn(value: language.Value, nested: bool = true) -> string {
    storage : u8[4096]
    out := text_buffer.make(storage)
    language.render(&out, value, nested)
    return language.joined(text_buffer.as_string(&out), "")
}

// ---- Parsing and evaluating

/** Drawn lines either parse or fail at a place in them; none hangs or faults the parser. */
any_line_parses_or_fails_inside_it #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    line :: draw_line(source, 24)
    match language.parse(line) {
        case Ok(tree) => testing.expect_le(t, tree.at, line.count, "the tree starts inside the line")
        case Error(error) => testing.expect_le(t, error.at, line.count, "the syntax error is at or before the line's end")
    }
    return .Ok
}

/** A whole number's digits parse to it up to 2^63 - 1, and past it are an error, not a number wrapped. */
numbers_parse_to_themselves_or_are_too_big #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    number :: testing.draw[u64](source)
    storage : u8[32]
    out := text_buffer.make(storage)
    text_buffer.append_unsigned(&out, number)
    parsed :: language.parse(text_buffer.as_string(&out))
    if number > cast[u64](language.SMALLEST) - 1 {
        return testing.require(t, parsed is_error, "a number past an i64's is refused")
    }
    tree :: testing.require_ok(t, parsed, "a number an i64 holds parses")?
    literal :: testing.require_some(t, first_of(tree), "the line has its number")?
    match literal.value {
        case Int(value) => testing.expect_eq(t, cast[u64](value), number, "the number is what was written")
        case _ => testing.fail(t, "the number isn't an Int")
    }
    return .Ok
}

/** The shell's size and duration units scale, and a scaled number past its value's range is an error. */
units_scale_or_are_too_big #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    tree :: testing.require_ok(t, language.parse("2KiB"), "a size parses")?
    literal :: testing.require_some(t, first_of(tree), "the line has its size")?
    testing.expect_eq(t, rendered(literal.value), "2 KiB", "2KiB is 2048 bytes")
    testing.expect(t, language.parse("20000000TiB") is_error, "a size past 2^64 bytes is refused")
    testing.expect(t, language.parse("200000000h") is_error, "a duration past 2^63 nanoseconds is refused")
    return .Ok
}

/** A string's $name runs over - as a name in the language does, and one not bound is left as written. */
interpolation_takes_names_with_hyphens #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    scope :: runtime.new(language.Scope)
    language.bind(scope, "file-name", .Text("notes"))
    testing.expect_eq(t, language.interpolate(scope, "open $file-name now"), "open notes now", "file-name is filled in")
    testing.expect_eq(t, language.interpolate(scope, "$missing-one"), "$missing-one", "a name not bound is kept as written")
    return .Ok
}

// ---- Arithmetic at its edges

/** The largest i64 and 2^63 - 1 written out. */
LARGEST :: cast[i64](cast[u64](language.SMALLEST) - 1)

/** A sum is the shell's when it's in an i64's range, and an overflow otherwise, by a reference that can't overflow. */
sums_are_checked #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    a :: testing.draw[i64](source)
    b :: testing.draw[i64](source)
    overflows :: (b > 0 && a > LARGEST - b) || (b < 0 && a < language.SMALLEST - b)
    match language.added(a, b) {
        case Some(sum) => {
            testing.expect(t, !overflows, "a sum past an i64's range isn't given")
            testing.expect_eq(t, sum - b, a, "the sum less b is a")
        }
        case None => testing.expect(t, overflows, "a sum in an i64's range is given")
    }
    return .Ok
}

/** A difference is the shell's when it's in an i64's range, and an overflow otherwise. */
differences_are_checked #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    a :: testing.draw[i64](source)
    b :: testing.draw[i64](source)
    overflows :: (b < 0 && a > LARGEST + b) || (b > 0 && a < language.SMALLEST + b)
    match language.subtracted(a, b) {
        case Some(difference) => {
            testing.expect(t, !overflows, "a difference past an i64's range isn't given")
            testing.expect_eq(t, difference + b, a, "the difference plus b is a")
        }
        case None => testing.expect(t, overflows, "a difference in an i64's range is given")
    }
    return .Ok
}

/** A product is the shell's when it's in an i64's range, so dividing it gives a back; an overflow otherwise. */
products_are_checked #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    a :: testing.draw[i64](source)
    b :: testing.draw[i64](source)
    // The magnitudes' product fits below the limit of the result's sign, 2^63 - 1 or 2^63
    magnitude_a :: language.magnitude_of(a)
    magnitude_b :: language.magnitude_of(b)
    limit :: if (a < 0) != (b < 0) { cast[u64](language.SMALLEST) } else { cast[u64](LARGEST) }
    overflows :: magnitude_a != 0 && magnitude_b > limit / magnitude_a
    match language.multiplied(a, b) {
        case Some(product) => {
            testing.expect(t, !overflows, "a product past an i64's range isn't given")
            if b != 0 {
                testing.expect_eq(t, language.divided(product, b) or_else 0, a, "the product over b is a")
            }
        }
        case None => testing.expect(t, overflows, "a product in an i64's range is given")
    }
    return .Ok
}

/**
 * Work out a parsed expression of literals, - and the arithmetic operators, as the shell's evaluation does with
 * language.calculate.
 *
 * @param tree The expression's node: a Literal, a Unary - or a Binary of + - * /.
 * @return Its value; why it can't be worked out otherwise, as calculate says it, or "not arithmetic" for another node.
 */
worked_out :: fn(tree: ptr[language.Node]) -> Result[language.Value, string] {
    if tree.kind == .Literal {
        return .Ok(tree.value)
    }
    operands : language.Value[2]
    for operand, i in tree.children {
        if i < operands.count {
            operands[i] = worked_out(operand)?
        }
    }
    if tree.kind == .Unary && tree.children.count == 1 {
        return language.calculate("-", .Int(0), operands[0])
    }
    if tree.kind == .Binary && tree.children.count == 2 {
        return language.calculate(tree.text, operands[0], operands[1])
    }
    return .Error("not arithmetic")
}

/**
 * Work out a line of one arithmetic expression, and render its value.
 *
 * @param line The line, parsed.
 * @return The value, rendered; why it couldn't be worked out, or "doesn't parse".
 */
worked_out_text :: fn(line: string) -> string {
    tree :: match language.parse(line) {
        case Ok(made) => made
        case Error(error) => return "doesn't parse"
    }
    for statement in tree.children {
        return match worked_out(statement) {
            case Ok(value) => rendered(value)
            case Error(problem) => problem
        }
    }
    return "doesn't parse"
}

/** Arithmetic past an i64 is an error, and the smallest i64 is shown as itself. */
overflowing_arithmetic_is_an_error #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    for line in string.["9223372036854775807 + 1", "-(9223372036854775807) - 2", "4611686018427387904 * 2", "9223372036854775807ns * 2",
        "18446744073709551615B + 1B"] {
        tree :: testing.require_ok(t, language.parse(line), "the line parses")?
        testing.require_eq(t, tree.children.count, 1, "the line has a statement")?
        for statement in tree.children {
            testing.expect_error(t, worked_out(statement), language.TOO_BIG, "it says it's too big")
        }
    }
    testing.expect_eq(t, worked_out_text("6 * 7 - 2"), "40", "arithmetic in range is worked out")
    testing.expect_eq(t, rendered(.Int(language.SMALLEST)), "-9223372036854775808", "the smallest i64 is shown as itself")
    return .Ok
}

// ---- Values written and read back

/** A choice a record holds, written by its member's name. */
Speed :: enum {
    /** One member. */
    Slow,
    /** The other. */
    Fast,
}

/** A record of the types the shell writes, with lists whose items leave the bytes unaligned. */
Row :: struct {
    /** A count. */
    id : u32,
    /** A signed number. */
    delta : i32,
    /** Text. */
    name : string,
    /** A list of text. */
    tags : string[],
    /** A list of 4-byte numbers, which can end off 8 bytes' alignment. */
    scores : i32[],
    /** A flag. */
    loud : bool,
    /** A choice. */
    speed : Speed,
    /** A list of bytes, after which the next is aligned again. */
    marks : u8[],
}

/**
 * A record of Row's fields, written by the shell as Row is laid out, reads back the same: its numbers, text, lists and
 * choice.
 */
records_read_back_as_written #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    written : u8[..]
    defer runtime.array_free(&written)
    schema.write(type_info_of(Row), &written)
    manifest := testing.require_some(t, schema.parse(written[0..<written.count]), "Row's schema reads")?
    defer schema.free(&manifest)
    record :: language.new_record()
    language.set_field(record, "id", .Int(cast[i64](testing.draw[u32](source))))
    language.set_field(record, "delta", .Int(cast[i64](testing.draw[i32](source))))
    language.set_field(record, "name", .Text(draw_text(source, 6)))
    tags :: language.new_list()
    for i in 0..<testing.draw_count(source, 4) {
        runtime.array_add(&tags.items, language.Value.Text(draw_text(source, 4)))
    }
    language.set_field(record, "tags", .List(tags))
    scores :: language.new_list()
    for i in 0..<testing.draw_count(source, 5) {
        runtime.array_add(&scores.items, language.Value.Int(cast[i64](testing.draw[i32](source))))
    }
    language.set_field(record, "scores", .List(scores))
    language.set_field(record, "loud", .Bool(testing.draw_bool(source)))
    language.set_field(record, "speed", .Text(if testing.draw_bool(source) { "Fast" } else { "Slow" }))
    marks :: language.new_list()
    for i in 0..<testing.draw_count(source, 9) {
        runtime.array_add(&marks.items, language.Value.Int(cast[i64](testing.draw[u8](source))))
    }
    language.set_field(record, "marks", .List(marks))
    value :: language.Value.Record(record)
    testing.show(source, rendered(value))
    bytes : u8[..]
    defer runtime.array_free(&bytes)
    language.zero(&bytes, size_of(Row))
    match language.encode(&manifest, 0, value, false, &bytes, 0) {
        case Some(problem) => return testing.require(t, false, problem)
        case None => {}
    }
    back :: language.decode(&manifest, 0, bytes[0..<bytes.count], 0, 0)
    testing.expect_eq(t, rendered(back), rendered(value), "the record reads back as written")
    return .Ok
}

// ---- Stages and rendering

/**
 * Make a record of one field.
 *
 * @param name The field's name, kept.
 * @param value Its value.
 * @return The record, a value.
 */
record_of :: fn(name #escaping : string, value #escaping : language.Value) -> language.Value {
    made :: language.new_record()
    language.set_field(made, name, value)
    return .Record(made)
}

/** Grouped by a field named count, the groups name its value key, and their own count and items stay theirs. */
grouping_by_count_keeps_the_groups_own_fields #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    items :: language.new_list()
    for count in i64.[1, 1, 2] {
        runtime.array_add(&items.items, record_of("count", .Int(count)))
    }
    groups :: language.group_items(items.items[0..<items.items.count], "count")
    testing.expect_eq(t, rendered(.List(groups)), "[{key: 1, count: 2, items: [{count: 1}, {count: 1}]}, {key: 2, count: 1, items: [{count: 2}]}]",
        "each group has its value as key, its count and its items")
    return .Ok
}

/** A table's columns line up by the columns their text takes, wide characters two and accents none. */
tables_line_up_by_columns #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    rows :: language.new_list()
    for name, i in string.["日本", "ab", "é"] {
        row :: language.new_record()
        language.set_field(row, "name", .Text(name))
        language.set_field(row, "n", .Int(cast[i64](i)))
        runtime.array_add(&rows.items, language.Value.Record(row))
    }
    testing.expect_eq(t, rendered(.List(rows), false), "name  n\n日本  0\nab    1\né     2", "the n column starts at column 6 on every line")
    return .Ok
}
