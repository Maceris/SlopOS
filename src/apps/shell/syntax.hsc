package shell

import runtime from "base"
import strings from "std"

/*
 * The shell language's syntax (design/shell.md §2, decisions/0162, 0169), parsed straight from a line to a tree:
 *
 *     statements  statement, separated by line breaks or ;, a # to the line's end a comment
 *     statement   let name = pipeline | pipeline
 *     pipeline    element (| element)*, then ? or `or { statements }`
 *     element     a call: a bare word in command position, then its arguments, words read by the parameter's type
 *                 later, or $name, "text", (expression), [list] or --name; or an expression, anything else
 *     expression  or, and, not, comparisons, + - * /, unary -, .field and [index] after, around literals (numbers,
 *                 4MiB, 250ms, "text", true, false, null), $name or a bare name, (expression), [a, b] and {name: value}
 *
 * A call's arguments are kept as written; what a bare word is depends on what it's given to, which only the call knows.
 */

NodeKind :: enum {
    Statements,
    Let,
    Pipeline,
    // A pipeline's ? after it, and `or` with its block
    Try,
    Or,
    Call,
    // A call's --name, the argument after it its value unless the parameter's a bool
    Named,
    // A bare word in a call
    Word,
    Literal,
    // A string with $name in it, filled in when it's evaluated
    Interpolated,
    Variable,
    List,
    Record,
    Field,
    Index,
    Unary,
    Binary,
    // fn name(parameters) { body }: its parameters, then its body
    Function,
    // A function's parameter: its name, its type's name as Text in its value (Null for any), and its default, if any
    Parameter,
    // return, and the value after it, if any
    Return,
    // try { ... } catch name { ... }: the tried block, then the handler; text the name the error's bound to
    TryCatch,
}

Node :: struct {
    kind : NodeKind,
    // Where it starts in the line
    at : usize,
    // A name, a word, an operator, or a string's text
    text : string,
    value : Value,
    children : ptr[mut Node][..],
}

SyntaxError :: struct {
    message : string,
    at : usize,
}

Parser :: struct {
    text : string,
    at : usize,
    error : SyntaxError?,
}

// A line parsed: its statements, or why it isn't one.
parse :: fn(line: string) -> Result[ptr[mut Node], SyntaxError] {
    // A copy of its own, which the tree's words and names are parts of
    text :: strings.clone(line) or_return .Error(SyntaxError.{message = "there's no memory for it", at = 0})
    parser := Parser.{text = text}
    made :: parse_statements(&parser, false)
    match parser.error {
        case Some(error) => return .Error(error)
        case None => {}
    }
    return .Ok(made)
}

node :: fn(kind: NodeKind, at: usize) -> ptr[mut Node] {
    made :: runtime.new(Node)
    made.kind = kind
    made.at = at
    made.value = .Null
    return made
}

add :: fn(parent: ptr[mut Node], child #escaping : ptr[mut Node]) {
    runtime.array_add(&parent.children, child)
}

fail :: fn(parser: ptr[mut Parser], message #escaping : string) {
    if parser.error is_none {
        parser.error = SyntaxError.{message = message, at = parser.at}
    }
}

char_at :: fn(parser: ptr[Parser], at: usize) -> u8 {
    bytes :: string_bytes(parser.text)
    return if at < bytes.count { bytes[at] } else { 0 }
}

peek :: fn(parser: ptr[Parser]) -> u8 {
    return char_at(parser, parser.at)
}

// Spaces and tabs skipped, and a comment, to the line's end.
skip_spaces :: fn(parser: ptr[mut Parser]) {
    loop {
        byte :: peek(parser)
        if byte == cast[u8](' ') || byte == 9 {
            parser.at += 1
        }
        else if byte == cast[u8]('#') {
            loop {
                if parser.at >= parser.text.count || peek(parser) == 10 {
                    break
                }
                parser.at += 1
            }
        }
        else {
            return void
        }
    }
}

is_letter :: fn(byte: u8) -> bool {
    return (byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('A') && byte <= cast[u8]('Z')) || byte == cast[u8]('_')
}

is_digit :: fn(byte: u8) -> bool {
    return byte >= cast[u8]('0') && byte <= cast[u8]('9')
}

// A name: a letter or _, then letters, digits, _ and -, as manifests' names are.
parse_name :: fn(parser: ptr[mut Parser]) -> string {
    start :: parser.at
    if !is_letter(peek(parser)) {
        return ""
    }
    loop {
        byte :: peek(parser)
        if !is_letter(byte) && !is_digit(byte) && byte != cast[u8]('-') {
            break
        }
        parser.at += 1
    }
    return slice(parser.text, start, parser.at)
}

slice :: fn(text: string, start: usize, end: usize) -> string {
    return if start <= end && end <= text.count { text[start..<end] } else { "" }
}

// Whether the word at the parser is keyword, followed by something that ends it.
at_keyword :: fn(parser: ptr[Parser], keyword: string) -> bool {
    end :: parser.at + keyword.count
    if slice(parser.text, parser.at, end) != keyword {
        return false
    }
    after :: char_at(parser, end)
    return !is_letter(after) && !is_digit(after) && after != cast[u8]('-')
}

// Statements, up to the end, or a } for a block's.
parse_statements :: fn(parser: ptr[mut Parser], in_block: bool) -> ptr[mut Node] {
    made :: node(.Statements, parser.at)
    loop {
        skip_spaces(parser)
        byte :: peek(parser)
        if byte == 10 || byte == cast[u8](';') {
            parser.at += 1
            continue
        }
        if (parser.error is_some) || parser.at >= parser.text.count || (in_block && byte == cast[u8]('}')) {
            break
        }
        add(made, parse_statement(parser))
        skip_spaces(parser)
        after :: peek(parser)
        if parser.at < parser.text.count && after != 10 && after != cast[u8](';') && !(in_block && after == cast[u8]('}')) {
            fail(parser, "this doesn't go here: a statement ends at a line break or ;")
            break
        }
    }
    return made
}

parse_statement :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    if at_keyword(parser, "fn") {
        return parse_function(parser)
    }
    if at_keyword(parser, "return") {
        made :: node(.Return, parser.at)
        parser.at += 6
        skip_spaces(parser)
        byte :: peek(parser)
        if parser.at < parser.text.count && byte != 10 && byte != cast[u8](';') && byte != cast[u8]('}') {
            add(made, parse_pipeline(parser))
        }
        return made
    }
    if at_keyword(parser, "try") {
        made :: node(.TryCatch, parser.at)
        parser.at += 3
        skip_spaces(parser)
        add(made, parse_block(parser))
        skip_spaces(parser)
        if !at_keyword(parser, "catch") {
            fail(parser, "try needs catch after its block")
            return made
        }
        parser.at += 5
        skip_spaces(parser)
        if is_letter(peek(parser)) {
            made.text = parse_name(parser)
            skip_spaces(parser)
        }
        add(made, parse_block(parser))
        return made
    }
    if at_keyword(parser, "let") {
        made :: node(.Let, parser.at)
        parser.at += 3
        skip_spaces(parser)
        made.text = parse_name(parser)
        if made.text.count == 0 {
            fail(parser, "let needs a name")
            return made
        }
        skip_spaces(parser)
        if peek(parser) != cast[u8]('=') {
            fail(parser, "let needs = and what the name is")
            return made
        }
        parser.at += 1
        add(made, parse_pipeline(parser))
        return made
    }
    return parse_pipeline(parser)
}

// fn name(a: type = default, ...) { body }
parse_function :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    made :: node(.Function, parser.at)
    parser.at += 2
    skip_spaces(parser)
    made.text = parse_name(parser)
    if made.text.count == 0 {
        fail(parser, "fn needs a name")
        return made
    }
    skip_spaces(parser)
    if peek(parser) != cast[u8]('(') {
        fail(parser, "fn needs ( and its parameters after its name")
        return made
    }
    parser.at += 1
    loop {
        skip_spaces(parser)
        if (parser.error is_some) || peek(parser) == cast[u8](')') {
            break
        }
        parameter :: node(.Parameter, parser.at)
        parameter.text = parse_name(parser)
        if parameter.text.count == 0 {
            fail(parser, "a parameter needs a name")
            return made
        }
        skip_spaces(parser)
        if peek(parser) == cast[u8](':') {
            parser.at += 1
            skip_spaces(parser)
            type :: parse_name(parser)
            if type.count == 0 {
                fail(parser, "a parameter's type needs a name after :")
                return made
            }
            parameter.value = .Text(type)
            skip_spaces(parser)
        }
        if peek(parser) == cast[u8]('=') {
            parser.at += 1
            add(parameter, parse_expression(parser))
            skip_spaces(parser)
        }
        add(made, parameter)
        if peek(parser) == cast[u8](',') {
            parser.at += 1
            continue
        }
        if peek(parser) != cast[u8](')') {
            fail(parser, "parameters are separated by , and end with )")
            return made
        }
    }
    parser.at += 1
    skip_spaces(parser)
    add(made, parse_block(parser))
    return made
}

// element (| element)*, then ? or `or { ... }`.
parse_pipeline :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    skip_spaces(parser)
    start :: parser.at
    first :: parse_element(parser)
    made := first
    skip_spaces(parser)
    if peek(parser) == cast[u8]('|') {
        made = node(.Pipeline, start)
        add(made, first)
        loop {
            skip_spaces(parser)
            if peek(parser) != cast[u8]('|') || (parser.error is_some) {
                break
            }
            parser.at += 1
            skip_spaces(parser)
            add(made, parse_element(parser))
        }
    }
    skip_spaces(parser)
    if peek(parser) == cast[u8]('?') {
        parser.at += 1
        tried :: node(.Try, start)
        add(tried, made)
        made = tried
        skip_spaces(parser)
    }
    if at_keyword(parser, "or") {
        parser.at += 2
        skip_spaces(parser)
        handled :: node(.Or, start)
        add(handled, made)
        add(handled, parse_block(parser))
        made = handled
    }
    return made
}

// { statements }
parse_block :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    if peek(parser) != cast[u8]('{') {
        fail(parser, "a block starts with {")
        return node(.Statements, parser.at)
    }
    parser.at += 1
    made :: parse_statements(parser, true)
    if peek(parser) != cast[u8]('}') {
        fail(parser, "this block has no }")
        return made
    }
    parser.at += 1
    return made
}

// A call, for a bare word in command position; an expression otherwise.
parse_element :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    skip_spaces(parser)
    if is_letter(peek(parser)) && !at_keyword(parser, "true") && !at_keyword(parser, "false") && !at_keyword(parser, "null")
        && !at_keyword(parser, "not") {
        return parse_call(parser)
    }
    return parse_expression(parser)
}

// A call: its name, then arguments up to | ; ) } or ? or `or`, or the line's end.
parse_call :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    made :: node(.Call, parser.at)
    made.text = parse_name(parser)
    // A pipeline's where and map take an expression, of each item's fields
    if made.text == "where" || made.text == "map" {
        skip_spaces(parser)
        byte :: peek(parser)
        if parser.at < parser.text.count && byte != 10 && byte != cast[u8]('|') && byte != cast[u8](';') && byte != cast[u8]('}') {
            add(made, parse_expression(parser))
        }
        return made
    }
    loop {
        skip_spaces(parser)
        byte :: peek(parser)
        if (parser.error is_some) || parser.at >= parser.text.count || byte == 10 || byte == cast[u8]('|') || byte == cast[u8](';')
            || byte == cast[u8](')') || byte == cast[u8]('}') || byte == cast[u8]('?') || at_keyword(parser, "or") {
            break
        }
        add(made, parse_argument(parser))
    }
    return made
}

// One argument: --name, $name, "text", (expression), [list], or a bare word.
parse_argument :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    start :: parser.at
    byte :: peek(parser)
    if byte == cast[u8]('-') && char_at(parser, start + 1) == cast[u8]('-') && is_letter(char_at(parser, start + 2)) {
        parser.at += 2
        made :: node(.Named, start)
        made.text = parse_name(parser)
        return made
    }
    if byte == cast[u8]('$') || byte == cast[u8]('"') || byte == cast[u8]('(') || byte == cast[u8]('[') {
        return parse_postfix(parser, parse_primary(parser))
    }
    // A bare word: what it is, its parameter's type says
    loop {
        next :: peek(parser)
        if parser.at >= parser.text.count || next == cast[u8](' ') || next == 9 || next == 10 || next == cast[u8]('|') || next == cast[u8](';')
            || next == cast[u8](')') || next == cast[u8]('}') || next == cast[u8]('"') || next == cast[u8]('(') {
            break
        }
        parser.at += 1
    }
    made :: node(.Word, start)
    made.text = slice(parser.text, start, parser.at)
    return made
}

// ---- Expressions, by precedence

parse_expression :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    return parse_binary(parser, 0)
}

// Each level's operators, loosest first
LEVELS :: 5
OR_LEVEL :: string.["or"]
AND_LEVEL :: string.["and"]
COMPARING :: string.["==", "!=", "<=", ">=", "<", ">"]
ADDING :: string.["+", "-"]
MULTIPLYING :: string.["*", "/"]

operators_of :: fn(level: usize) -> string[] {
    return if level == 0 { OR_LEVEL[0..<OR_LEVEL.count] } else if level == 1 { AND_LEVEL[0..<AND_LEVEL.count] }
        else if level == 2 { COMPARING[0..<COMPARING.count] } else if level == 3 { ADDING[0..<ADDING.count] }
        else { MULTIPLYING[0..<MULTIPLYING.count] }
}

parse_binary :: fn(parser: ptr[mut Parser], level: usize) -> ptr[mut Node] {
    if level >= LEVELS {
        return parse_unary(parser)
    }
    left := parse_binary(parser, level + 1)
    loop {
        skip_spaces(parser)
        operator :: operator_at(parser, operators_of(level)) or_break
        start :: parser.at
        parser.at += operator.count
        made :: node(.Binary, start)
        made.text = operator
        add(made, left)
        add(made, parse_binary(parser, level + 1))
        left = made
    }
    return left
}

// Which of operators is at the parser: a word one only as a whole word.
operator_at :: fn(parser: ptr[Parser], operators: string[]) -> string? {
    for operator in operators {
        if is_letter(cast[u8](operator[0 % operator.count])) {
            if at_keyword(parser, operator) {
                return operator
            }
        }
        else if slice(parser.text, parser.at, parser.at + operator.count) == operator {
            return operator
        }
    }
    return null
}

parse_unary :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    skip_spaces(parser)
    start :: parser.at
    if at_keyword(parser, "not") {
        parser.at += 3
        made :: node(.Unary, start)
        made.text = "not"
        add(made, parse_unary(parser))
        return made
    }
    if peek(parser) == cast[u8]('-') && !is_digit(char_at(parser, start + 1)) {
        parser.at += 1
        made :: node(.Unary, start)
        made.text = "-"
        add(made, parse_unary(parser))
        return made
    }
    return parse_postfix(parser, parse_primary(parser))
}

// .field and [index] after a value.
parse_postfix :: fn(parser: ptr[mut Parser], base #escaping : ptr[mut Node]) -> ptr[mut Node] {
    made := base
    loop {
        byte :: peek(parser)
        if byte == cast[u8]('.') && is_letter(char_at(parser, parser.at + 1)) {
            parser.at += 1
            access :: node(.Field, parser.at)
            access.text = parse_name(parser)
            add(access, made)
            made = access
        }
        else if byte == cast[u8]('[') {
            parser.at += 1
            access :: node(.Index, parser.at)
            add(access, made)
            add(access, parse_expression(parser))
            skip_spaces(parser)
            if peek(parser) != cast[u8](']') {
                fail(parser, "an index needs ]")
                return made
            }
            parser.at += 1
            made = access
        }
        else {
            return made
        }
    }
}

parse_primary :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    skip_spaces(parser)
    start :: parser.at
    byte :: peek(parser)
    if byte == cast[u8]('(') {
        parser.at += 1
        inner :: parse_pipeline(parser)
        skip_spaces(parser)
        if peek(parser) != cast[u8](')') {
            fail(parser, "this ( has no )")
        }
        else {
            parser.at += 1
        }
        return inner
    }
    if byte == cast[u8]('[') {
        parser.at += 1
        made :: node(.List, start)
        parse_items(parser, made, cast[u8](']'), false)
        return made
    }
    if byte == cast[u8]('{') {
        parser.at += 1
        made :: node(.Record, start)
        parse_items(parser, made, cast[u8]('}'), true)
        return made
    }
    if byte == cast[u8]('"') {
        return parse_quoted(parser)
    }
    if byte == cast[u8]('$') {
        parser.at += 1
        made :: node(.Variable, start)
        made.text = parse_name(parser)
        if made.text.count == 0 {
            fail(parser, "$ needs a name after it")
        }
        return made
    }
    if is_digit(byte) {
        return parse_number(parser)
    }
    if is_letter(byte) {
        word :: parse_name(parser)
        made :: node(.Literal, start)
        if word == "true" {
            made.value = .Bool(true)
        }
        else if word == "false" {
            made.value = .Bool(false)
        }
        else if word == "null" {
            made.value = .Null
        }
        else {
            // A bare name in an expression is a variable
            made.kind = .Variable
            made.text = word
        }
        return made
    }
    fail(parser, if parser.at >= parser.text.count { "something's missing at the end" } else { "this isn't the start of a value" })
    parser.at += 1
    return node(.Literal, start)
}

// A list's items, or a record's name: value pairs, separated by commas, up to close.
parse_items :: fn(parser: ptr[mut Parser], made: ptr[mut Node], close: u8, named: bool) {
    loop {
        skip_spaces(parser)
        loop {
            if peek(parser) != 10 {
                break
            }
            parser.at += 1
            skip_spaces(parser)
        }
        if peek(parser) == close {
            parser.at += 1
            return void
        }
        if (parser.error is_some) || parser.at >= parser.text.count {
            fail(parser, if named { "this record has no }" } else { "this list has no ]" })
            return void
        }
        if named {
            key :: node(.Literal, parser.at)
            key.text = parse_name(parser)
            if key.text.count == 0 {
                fail(parser, "a record's field needs a name")
                return void
            }
            skip_spaces(parser)
            if peek(parser) != cast[u8](':') {
                fail(parser, "a record's field needs : and its value")
                return void
            }
            parser.at += 1
            add(made, key)
        }
        add(made, parse_expression(parser))
        skip_spaces(parser)
        if peek(parser) == cast[u8](',') {
            parser.at += 1
        }
    }
}

// "text", with \n \t \" \\ \$ escapes; $name in it is filled in when it's evaluated.
parse_quoted :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    start :: parser.at
    parser.at += 1
    text : u8[..]
    interpolated := false
    loop {
        if parser.at >= parser.text.count {
            fail(parser, "this string has no closing \"")
            break
        }
        byte :: peek(parser)
        parser.at += 1
        if byte == cast[u8]('"') {
            break
        }
        if byte == cast[u8]('\\') {
            escaped :: peek(parser)
            parser.at += 1
            runtime.array_add(&text, if escaped == cast[u8]('n') { cast[u8](10) } else if escaped == cast[u8]('t') { cast[u8](9) }
                else if escaped == cast[u8]('$') { cast[u8](0) } else { escaped })
            continue
        }
        if byte == cast[u8]('$') && is_letter(peek(parser)) {
            interpolated = true
        }
        runtime.array_add(&text, byte)
    }
    made :: node(if interpolated { NodeKind.Interpolated } else { NodeKind.Literal }, start)
    // An escaped $ was kept as a zero, so it isn't filled in, and is a $ again here unless it's interpolated
    for &byte in text {
        if byte^ == 0 && !interpolated {
            byte^ = cast[u8]('$')
        }
    }
    made.text = if text.count > 0 { string_of(&text[0], text.count) } else { "" }
    made.value = .Text(made.text)
    return made
}

// A number, with a size's or a duration's unit after it if it has one.
parse_number :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    start :: parser.at
    value := cast[u64](0)
    loop {
        byte :: peek(parser)
        if !is_digit(byte) {
            if byte == cast[u8]('_') {
                parser.at += 1
                continue
            }
            break
        }
        value = value * 10 + cast[u64](byte - cast[u8]('0'))
        parser.at += 1
    }
    made :: node(.Literal, start)
    unit_start :: parser.at
    unit :: parse_name(parser)
    made.value = .Int(cast[i64](value))
    match unit_value(unit) {
        case Some(found) => made.value = if found.size { Value.Size(value * found.scale) } else { Value.Duration(cast[i64](value * found.scale)) }
        case None => {
            if unit.count > 0 {
                parser.at = unit_start
                fail(parser, "that isn't a size's or a duration's unit")
            }
        }
    }
    return made
}

Unit :: struct {
    scale : u64,
    size : bool,
}

unit_value :: fn(unit: string) -> Unit? {
    sizes :: string.["B", "KiB", "MiB", "GiB", "TiB", "kB", "MB", "GB", "TB"]
    scales :: u64.[1, 1 << 10, 1 << 20, 1 << 30, 1 << 40, 1000, 1000 * 1000, 1000 * 1000 * 1000, 1000 * 1000 * 1000 * 1000]
    for each, i in sizes {
        if each == unit && i < scales.count {
            return Unit.{scale = scales[i], size = true}
        }
    }
    durations :: string.["ns", "us", "ms", "s", "m", "h", "d"]
    nanos :: u64.[1, 1000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
    for each, i in durations {
        if each == unit && i < nanos.count {
            return Unit.{scale = nanos[i], size = false}
        }
    }
    return null
}
