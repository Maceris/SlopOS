package shell_language

import runtime from "base"
import strings from "std"

/*
 * The shell language's syntax (design/shell.md §2, decisions/0162, 0169), parsed straight from a line to a tree:
 *
 *     statements  statement, separated by line breaks or ;, a # to the line's end a comment
 *     statement   let name = pipeline | pipeline, then & to run it in the background | param parameters, a script's
 *                 first (name: type = default, separated by commas, each name with -- before it or not)
 *     pipeline    element (| element)*, then ? or `or { statements }`
 *     element     a call: a bare word in command position, then its arguments, words read by the parameter's type
 *                 later, or $name, "text", (expression), [list] or --name; or an expression, anything else
 *     expression  or, and, not, comparisons, + - * /, unary -, .field and [index] after, around literals (numbers,
 *                 4MiB, 250ms, "text", true, false, null), $name or a bare name, (expression), [a, b] and {name: value}
 *
 * A call's arguments are kept as written; what a bare word is depends on what it's given to, which only the call knows.
 */

/** What a node of the tree is, and so what its text, value and children hold. */
NodeKind :: enum {
    /** A line's or a block's statements: each a child, in order. */
    Statements,
    /** let name = pipeline: text the name, the one child what it's bound to. */
    Let,
    /** element | element ...: each element a child, in order. */
    Pipeline,
    /** A pipeline's ? after it: the one child the pipeline, whose error ends what's running. */
    Try,
    /** `or` with its block: the pipeline, then the block run if it fails. */
    Or,
    /** A call: text its name, each argument a child, as written. */
    Call,
    /** A call's --name, text the name; the argument after it is its value unless the parameter's a bool. */
    Named,
    /** A bare word in a call, text as written, read by its parameter's type when the call's made. */
    Word,
    /** A literal, its value in value: a number, a size, a duration, text, true, false or null; or a record's key. */
    Literal,
    /** A string with $name in it, text the string, filled in when it's evaluated. */
    Interpolated,
    /** $name or a bare name in an expression: text the name. */
    Variable,
    /** [a, b]: each item a child. */
    List,
    /** {name: value}: each field's name, a Literal with text the name, then its value, as children. */
    Record,
    /** value.field: text the field's name, the one child the value. */
    Field,
    /** value[index]: the value, then the index. */
    Index,
    /** not or unary -: text the operator, the one child its operand. */
    Unary,
    /** A binary operator: text the operator, the children its left and right operands. */
    Binary,
    /** fn name(parameters) { body }: text the name, its parameters, then its body. */
    Function,
    /**
     * A function's parameter: text its name, its type's name as Text in its value (Null for any), and its default,
     * if any, its one child.
     */
    Parameter,
    /** return, and the value after it, if any, its one child. */
    Return,
    /** try { ... } catch name { ... }: the tried block, then the handler; text the name the error's bound to. */
    TryCatch,
    /** pipeline &: the one child the pipeline, run as a job in the background (design/shell.md §6). */
    Background,
    /** param a: type = default, ...: a script's parameters (decisions/0179, 11e6), each a Parameter child. */
    Param,
}

/** A node of a parsed line's tree, on the heap, never freed. */
Node :: struct {
    /** What it is, which says what the rest hold. */
    kind : NodeKind,
    /** Where it starts in the line, in bytes from 0, for an error to point at. */
    at : usize,
    /** A name, a word, an operator, or a string's text, a view of the parse's copy of the line or the heap. */
    text : string,
    /** A Literal's value, a Parameter's type's name, or a string's text; Null otherwise. */
    value : Value,
    /** Its children, as its kind says. */
    children : ptr[mut Node][..],
}

/** Why a line isn't the shell language, and where. */
SyntaxError :: struct {
    /** What's wrong, a sentence for a person, a literal. */
    message : string,
    /** Where in the line, in bytes from 0. */
    at : usize,
}

/** A line being parsed. */
Parser :: struct {
    /** The line, the parse's own copy, which the tree's text views. */
    text : string,
    /** Where it's read to, in bytes from 0; can pass the line's end. */
    at : usize,
    /** The first error met, or null; once there's one the parse winds down, and later ones aren't kept. */
    error : SyntaxError?,
}

/**
 * Parse a line of the shell language into a tree of its statements.
 *
 * It fails with a SyntaxError when there's no memory for the copy, or the line isn't the shell language: the first
 * thing wrong, and where.
 *
 * @param line The line, copied: the tree's text views the copy, which, like the tree, is never freed.
 * @return The line's Statements node, each statement a child.
 */
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

/**
 * Find a node's first child.
 *
 * @param tree The node, of any kind, only read.
 * @return The child, the node's own, not a copy; null if it has none.
 */
first_child :: fn(tree: ptr[Node]) -> ptr[mut Node]? {
    return child(tree, 0)
}

/**
 * Find a node's child.
 *
 * @param tree The node, of any kind, only read; what its children mean is by its kind.
 * @param index The child's index, from 0.
 * @return The child; null past the node's children.
 */
child :: fn(tree: ptr[Node], index: usize) -> ptr[mut Node]? {
    return if index < tree.children.count { tree.children[index] } else { null }
}

/**
 * Find a list's item.
 *
 * @param list The list, only read.
 * @param index The item's index, from 0.
 * @return The item; null past the list's items.
 */
item :: fn(list: ptr[ValueList], index: usize) -> Value? {
    return if index < list.items.count { list.items[index] } else { null }
}

/**
 * Make a node, with no text, a Null value and no children.
 *
 * @param kind What it is, which says what its text, value and children are to hold; the caller fills them in.
 * @param at Where it starts in the line, in bytes.
 * @return The node, on the heap, never freed.
 */
node :: fn(kind: NodeKind, at: usize) -> ptr[mut Node] {
    made :: runtime.new(Node)
    made.kind = kind
    made.at = at
    made.value = .Null
    return made
}

/**
 * Add a child to a node, after the ones it has.
 *
 * @param parent The node whose children grow by one; what the child means is by parent's kind and its place.
 * @param child The child, kept by parent.
 */
add :: fn(parent: ptr[mut Node], child #escaping : ptr[mut Node]) {
    runtime.array_add(&parent.children, child)
}

/**
 * Record a syntax error where the parser is, unless there's one already: only the first is kept.
 *
 * @param parser The parser, whose error is set to the message at its position, unless it has one already.
 * @param message What's wrong, kept, so a literal.
 */
fail :: fn(parser: ptr[mut Parser], message #escaping : string) {
    if parser.error is_none {
        parser.error = SyntaxError.{message = message, at = parser.at}
    }
}

/**
 * Read a byte of the line.
 *
 * @param parser The parser, whose line is read; it isn't moved.
 * @param at Where, in bytes from 0.
 * @return The byte; 0 past the line's end.
 */
char_at :: fn(parser: ptr[Parser], at: usize) -> u8 {
    bytes :: string_bytes(parser.text)
    return if at < bytes.count { bytes[at] } else { 0 }
}

/**
 * Read the byte where the parser is, without moving on.
 *
 * @param parser The parser, read at its position, which isn't changed.
 * @return The byte; 0 at the line's end.
 */
peek :: fn(parser: ptr[Parser]) -> u8 {
    return char_at(parser, parser.at)
}

/**
 * Skip spaces and tabs, and a # comment, which runs to the line break or the end; a line break isn't skipped.
 *
 * @param parser The parser, moved on.
 */
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

/**
 * Tell whether a byte can start a name: an ASCII letter or _.
 *
 * @param byte Any byte; one of a UTF-8 sequence's, 128 or more, is never a letter.
 * @return True for a to z, A to Z and _.
 */
is_letter :: fn(byte: u8) -> bool {
    return (byte >= cast[u8]('a') && byte <= cast[u8]('z')) || (byte >= cast[u8]('A') && byte <= cast[u8]('Z')) || byte == cast[u8]('_')
}

/**
 * Tell whether a byte is an ASCII digit.
 *
 * @param byte Any byte, 0 included, as char_at gives past the line's end.
 * @return True for 0 to 9.
 */
is_digit :: fn(byte: u8) -> bool {
    return byte >= cast[u8]('0') && byte <= cast[u8]('9')
}

/**
 * Parse a name: a letter or _, then letters, digits, _ and -, as manifests' names are.
 *
 * @param parser The parser, moved past the name.
 * @return The name, a view of the parser's text; empty, and the parser not moved, if there's no name there.
 */
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

/**
 * Slice text, safely.
 *
 * @param text The text sliced, viewed, not copied: the slice is good for as long as it is.
 * @param start Where the slice starts, in bytes.
 * @param end Where it ends, in bytes, excluded.
 * @return The slice, a view of text; empty if the bounds are backwards or past text's end.
 */
slice :: fn(text: string, start: usize, end: usize) -> string {
    return if start <= end && end <= text.count { text[start..<end] } else { "" }
}

/**
 * Tell whether the word where the parser is is a keyword, followed by something that ends a name.
 *
 * @param parser The parser, not moved.
 * @param keyword The keyword, compared byte for byte with the line at the parser's position.
 * @return True if the keyword's there, as a whole word.
 */
at_keyword :: fn(parser: ptr[Parser], keyword: string) -> bool {
    end :: parser.at + keyword.count
    if slice(parser.text, parser.at, end) != keyword {
        return false
    }
    after :: char_at(parser, end)
    return !is_letter(after) && !is_digit(after) && after != cast[u8]('-')
}

/**
 * Parse statements, separated by line breaks or ;, up to the line's end, or a } for a block's.
 *
 * @param parser The parser, moved past them, to the } that ends a block, which isn't taken.
 * @param in_block Whether they're a block's, so a } ends them.
 * @return A Statements node, each statement a child; as far as it got if there's an error.
 */
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

/**
 * Parse one statement: fn, param, return, try and catch, let, or a pipeline, which & after it makes a background job's.
 *
 * @param parser The parser, moved past it.
 * @return The statement's node; as far as it got if there's an error.
 */
parse_statement :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    if at_keyword(parser, "fn") {
        return parse_function(parser)
    }
    if at_keyword(parser, "param") {
        return parse_param(parser)
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
    made :: parse_pipeline(parser)
    skip_spaces(parser)
    if peek(parser) != cast[u8]('&') {
        return made
    }
    parser.at += 1
    background :: node(.Background, made.at)
    add(background, made)
    return background
}

/**
 * Parse a function: fn name(a: type = default, ...) { body }.
 *
 * @param parser The parser, at fn, moved past the body.
 * @return The Function node; as far as it got if there's an error.
 */
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
    parse_parameters(parser, made, true)
    if parser.error is_some {
        return made
    }
    parser.at += 1
    skip_spaces(parser)
    add(made, parse_block(parser))
    return made
}

/**
 * Parse a script's parameters: param a: type = default, ... to the statement's end.
 *
 * @param parser The parser, at param, moved past the parameters.
 * @return The Param node; as far as it got if there's an error.
 */
parse_param :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    made :: node(.Param, parser.at)
    parser.at += 5
    parse_parameters(parser, made, false)
    return made
}

/**
 * Parse parameters, each a name, then : and its type's name, then = and its default, each but the name left out or
 * not, separated by commas: a function's, to its ), or a script's, to its statement's end, where a name may have -- in
 * front of it, as a call writes it.
 *
 * @param parser The parser, after fn's ( or param; moved to the ) for a function's, or to the statement's end.
 * @param made The node the Parameters are added to.
 * @param in_parentheses Whether they end with ), a function's; or at a line break, ; or the text's end, a script's.
 */
parse_parameters :: fn(parser: ptr[mut Parser], made: ptr[mut Node], in_parentheses: bool) {
    loop {
        skip_spaces(parser)
        byte :: peek(parser)
        if (parser.error is_some) || (in_parentheses && byte == cast[u8](')')) {
            break
        }
        if !in_parentheses && (parser.at >= parser.text.count || byte == 10 || byte == cast[u8](';')) {
            break
        }
        if !in_parentheses && byte == cast[u8]('-') && char_at(parser, parser.at + 1) == cast[u8]('-') {
            parser.at += 2
        }
        parameter :: node(.Parameter, parser.at)
        parameter.text = parse_name(parser)
        if parameter.text.count == 0 {
            fail(parser, "a parameter needs a name")
            return void
        }
        skip_spaces(parser)
        if peek(parser) == cast[u8](':') {
            parser.at += 1
            skip_spaces(parser)
            type :: parse_name(parser)
            if type.count == 0 {
                fail(parser, "a parameter's type needs a name after :")
                return void
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
        after :: peek(parser)
        if after == cast[u8](',') {
            parser.at += 1
            continue
        }
        if in_parentheses && after != cast[u8](')') {
            fail(parser, "parameters are separated by , and end with )")
            return void
        }
        if !in_parentheses && !(parser.at >= parser.text.count || after == 10 || after == cast[u8](';')) {
            fail(parser, "parameters are separated by , and end with the line")
            return void
        }
    }
}

/**
 * Parse a pipeline: element (| element)*, then ? or `or { ... }`, or both.
 *
 * @param parser The parser, moved past it.
 * @return The element itself when there's one and nothing after it; else a Pipeline, wrapped in Try for ? and in Or
 *     for `or`.
 */
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

/**
 * Parse a block: { statements }.
 *
 * @param parser The parser, at the {, moved past the }.
 * @return The block's Statements node; an empty one, with an error, if there's no { there.
 */
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

/**
 * Parse a pipeline's element: a call, for a bare word in command position other than true, false, null and not; an
 * expression otherwise.
 *
 * @param parser The parser, moved past it.
 * @return The Call node, or the expression's.
 */
parse_element :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    skip_spaces(parser)
    if is_letter(peek(parser)) && !at_keyword(parser, "true") && !at_keyword(parser, "false") && !at_keyword(parser, "null")
        && !at_keyword(parser, "not") {
        return parse_call(parser)
    }
    return parse_expression(parser)
}

/**
 * Parse a call: its name, a word or a path (a script's), then arguments up to | ; ) } ? & or `or`, or the line's end.
 *
 * where and map take one expression, of each item's fields, in place of arguments.
 *
 * @param parser The parser, at the name, moved past the arguments.
 * @return The Call node, text its name, each argument a child.
 */
parse_call :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    made :: node(.Call, parser.at)
    start :: parser.at
    made.text = parse_name(parser)
    // A path as the name, a script's (decisions/0179, 11e6): on through . and / to the word's end
    if peek(parser) == cast[u8]('.') || peek(parser) == cast[u8]('/') {
        loop {
            byte :: peek(parser)
            if !is_letter(byte) && !is_digit(byte) && byte != cast[u8]('-') && byte != cast[u8]('.') && byte != cast[u8]('/') {
                break
            }
            parser.at += 1
        }
        made.text = slice(parser.text, start, parser.at)
    }
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
            || byte == cast[u8](')') || byte == cast[u8]('}') || byte == cast[u8]('?') || byte == cast[u8]('&') || at_keyword(parser, "or") {
            break
        }
        add(made, parse_argument(parser))
    }
    return made
}

/**
 * Parse one argument: --name, $name, "text", (expression), [list], or a bare word.
 *
 * A bare word runs to a space, tab, line break, | ; ) } " ( or &, and is kept as written: what it is, its parameter's
 * type says.
 *
 * @param parser The parser, moved past it.
 * @return The argument's node: Named, Word, or the value's, with any .field or [index] after it.
 */
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
            || next == cast[u8](')') || next == cast[u8]('}') || next == cast[u8]('"') || next == cast[u8]('(') || next == cast[u8]('&') {
            break
        }
        parser.at += 1
    }
    made :: node(.Word, start)
    made.text = slice(parser.text, start, parser.at)
    return made
}

// ---- Expressions, by precedence

/**
 * Parse an expression, its operators by precedence.
 *
 * @param parser The parser, moved past it.
 * @return The expression's node: a Binary for an or, the loosest operator, at its top, else a tighter one's; as far as
 *     it got if there's an error.
 */
parse_expression :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    return parse_binary(parser, 0)
}

// Each level's operators, loosest first
/** How many levels of binary operators there are; the unary ones bind tighter than all. */
LEVELS :: 5
/** The loosest level's operator: or. */
OR_LEVEL :: string.["or"]
/** The second level's operator: and. */
AND_LEVEL :: string.["and"]
/** The third level's operators, comparisons; two-byte ones before their one-byte prefixes, so they're found first. */
COMPARING :: string.["==", "!=", "<=", ">=", "<", ">"]
/** The fourth level's operators: + and -. */
ADDING :: string.["+", "-"]
/** The tightest level's operators: * and /. */
MULTIPLYING :: string.["*", "/"]

/**
 * Find a level's operators.
 *
 * @param level The level, 0 the loosest; 4 and up are MULTIPLYING's.
 * @return The operators, a view of a constant.
 */
operators_of :: fn(level: usize) -> string[] {
    return if level == 0 { OR_LEVEL[0..<OR_LEVEL.count] } else if level == 1 { AND_LEVEL[0..<AND_LEVEL.count] }
        else if level == 2 { COMPARING[0..<COMPARING.count] } else if level == 3 { ADDING[0..<ADDING.count] }
        else { MULTIPLYING[0..<MULTIPLYING.count] }
}

/**
 * Parse an expression of a level's binary operators and tighter ones, left-associative.
 *
 * @param parser The parser, moved past it.
 * @param level The level, 0 the loosest; at LEVELS, a unary expression.
 * @return The expression's node: Binary nodes, the leftmost operation deepest.
 */
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

/**
 * Find which of some operators is where the parser is: a word one, like and, only as a whole word.
 *
 * @param parser The parser, not moved.
 * @param operators The operators, tried in order, so the first that matches wins.
 * @return The operator, a view of operators' string; null if none is there.
 */
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

/**
 * Parse a unary expression: not or - before one, or a value with any .field and [index] after it.
 *
 * A - right before a digit is left for parse_primary, which then fails, since numbers have no sign.
 *
 * @param parser The parser, moved past it.
 * @return A Unary node, text "not" or "-", its operand its one child; or the value's node, wrapped in any Field and
 *     Index nodes after it; as far as it got if there's an error.
 */
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

/**
 * Parse any .field and [index] after a value.
 *
 * @param parser The parser, after the value, moved past them.
 * @param base The value's node, kept in the tree.
 * @return The outermost Field or Index node, or base when there are none.
 */
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

/**
 * Parse a value: (pipeline), [list], {record}, "text", $name, a number, true, false, null, or a bare name, which is a
 * variable.
 *
 * @param parser The parser, moved past it; moved past one byte on an error, so parsing goes on.
 * @return The value's node; an empty Literal, with an error, if nothing that starts a value is there.
 */
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

/**
 * Parse a list's items, or a record's name: value pairs, separated by commas or line breaks, up to close.
 *
 * @param parser The parser, after the opening bracket, moved past close.
 * @param made The List or Record node the items are added to: for a record, each name a Literal, then its value.
 * @param close The closing byte: ] or }.
 * @param named Whether they're a record's fields.
 */
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

/**
 * Parse a string: "text", with \n \t \" \\ \$ escapes; $name in it is filled in when it's evaluated.
 *
 * Any other escaped byte is itself. An escaped $ in a string that's interpolated is kept as a 0 byte, so it isn't
 * filled in; the evaluator turns it back into a $.
 *
 * @param parser The parser, at the opening ", moved past the closing one.
 * @return A Literal with the text as its value, or an Interpolated node if a $ and a letter are in it; its text is
 *     on the heap, never freed.
 */
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

/**
 * Parse a number, its digits maybe separated by _, with a size's or a duration's unit after it if it has one.
 *
 * @param parser The parser, at the first digit, moved past the unit.
 * @return A Literal: an Int, or with a unit a Size in bytes or a Duration in nanoseconds; with an error if a name after
 *     the digits isn't a unit, or the number is past what its value holds: 2^63 - 1 for an integer or a duration's
 *     nanoseconds, 2^64 - 1 for a size's bytes.
 */
parse_number :: fn(parser: ptr[mut Parser]) -> ptr[mut Node] {
    start :: parser.at
    value := cast[u64](0)
    fits := true
    loop {
        byte :: peek(parser)
        if !is_digit(byte) {
            if byte == cast[u8]('_') {
                parser.at += 1
                continue
            }
            break
        }
        next :: added_sizes(multiplied_sizes(value, 10) or_else 0, cast[u64](byte - cast[u8]('0')))
        fits = fits && (multiplied_sizes(value, 10) is_some) && (next is_some)
        value = next or_else 0
        parser.at += 1
    }
    made :: node(.Literal, start)
    unit_start :: parser.at
    unit :: parse_name(parser)
    largest_signed :: cast[u64](SMALLEST) - 1
    made.value = .Int(cast[i64](value))
    match unit_value(unit) {
        case Some(found) => {
            scaled :: multiplied_sizes(value, found.scale)
            fits = fits && (scaled is_some) && (found.size || (scaled or_else 0) <= largest_signed)
            made.value = if found.size { Value.Size(scaled or_else 0) } else { Value.Duration(cast[i64](scaled or_else 0)) }
        }
        case None => {
            if unit.count > 0 {
                parser.at = unit_start
                fail(parser, "that isn't a size's or a duration's unit")
            }
            fits = fits && value <= largest_signed
        }
    }
    if !fits {
        parser.at = start
        fail(parser, "that number's too big: past what a 64-bit number holds")
    }
    return made
}

/** A unit a number can have after it. */
Unit :: struct {
    /** What one of it is: in bytes for a size, nanoseconds for a duration. */
    scale : u64,
    /** Whether it's a size's unit; a duration's if not. */
    size : bool,
}

/**
 * Find a unit by its name: B, KiB to TiB and kB to TB for sizes, ns, us, ms, s, m, h and d for durations.
 *
 * @param unit The name, case and all.
 * @return The unit; null for any other name.
 */
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
