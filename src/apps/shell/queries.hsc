package shell

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import query as query_protocol from "std:os/slop_os/query"
import schema from "std:schema"
import shell_language as language from "../../shell_language"

/*
 * query (decisions/0201's 20j, 0202's 21e): the typed files beneath the shell's directory whose indexed fields compare
 * as asked, as a table of their paths, like any program's results; and query --index, an index of a type's field
 * declared on the home's volume. Indexes are declared on a volume's root alone, so --index is asked of the shell's
 * home, which has to be one; they're listed, and the query asked, beneath the shell's directory. A type is named as
 * its programs name it, found among the manifests of the programs the shell can run, as view finds a typed file's.
 *
 * Comparisons are joined by and, or and not, not binding tightest and or loosest, and grouped by parentheses. As or and
 * parentheses are the shell's own syntax between commands, a predicate that uses them is given as one text, which
 * query reads itself; a value with spaces or parentheses in it is quoted there with ':
 *
 *     query --index Note level
 *     query Note level >= 3 and not title == draft
 *     query Note "level >= 3 and (title == 'to do' or done == true)"
 */

/** The most files query lists; past them, it says there are more. */
MAX_QUERIED :: 1000

/** A word of a predicate: a field, an operator, a value, and, or, not or a parenthesis, and where it was written. */
Token :: struct {
    /** Its text, a view of the argument it's from, or of a copy of it. */
    text : string,
    /** Where its argument starts in the line, for an error. */
    at : usize,
    /** Whether it was quoted, so and, or, not and parentheses are a value's text, not the grammar's. */
    quoted : bool,
}

/** A predicate being read: its words, the next one's place, and the terms made so far, in postfix order. */
Reading :: struct {
    /** The words. */
    tokens : Token[..],
    /** The next word's place among them. */
    next : usize,
    /** The terms, in postfix order, as the query protocol has them. */
    terms : query_protocol.Term[..],
    /** The text constants' bytes, each text term's at its text_offset. */
    texts : u8[..],
    /** The type's name, for errors. */
    type_name : string,
    /** The type's schema hash, which its indexes are found by. */
    hash : u8[32],
    /** The shell's directory, whose volume's indexes are listed. */
    end : slop_os.Channel,
    /** A port bound to end. */
    port : slop_os.Port,
}

/** A type found among the programs' manifests: its schema's bytes and hash. */
FoundType :: struct {
    /** Its schema's bytes, written for it alone (schema.write_rooted), on the heap, freed by the caller. */
    bytes : u8[..],
    /** Its schema hash, as its typed files have it. */
    hash : u8[32],
}

/**
 * Query the typed files beneath the shell's directory: query Type predicate, its comparisons field op value joined by
 * and, or and not and grouped by parentheses, from bare words and texts (as the comment at the top says); or declare an
 * index: query --index Type field. An op is ==, !=, <, <=, > or >=; a value is read as the field's index holds it, an
 * integer, true or false, or text.
 *
 * It fails without a home, for arguments that aren't one of those, a type no program's manifest has, a field with no
 * index declared (or one that can't be indexed, for --index), a value that isn't the field's, a home that isn't its
 * volume's root (for --index), or what the directory answers.
 *
 * @param shell The shell, whose directory is queried and its volume's indexes listed, whose home's volume's indexes
 *     are declared, and whose programs' manifests are where the type's found.
 * @param tree The Call node of query.
 * @return A list of records, path, beneath the shell's directory, and file, its number in its volume; Null when none
 *     matches, or after --index, which is said.
 */
query_files :: fn(shell : ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    usage :: "query takes a type and comparisons, query Note level >= 3 and not title == draft; or --index, a type and a field"
    children :: tree.children
    declaring :: children.count > 0 && children[0].kind == .Named && children[0].text == "index"
    first :: if declaring { cast[usize](1) } else { cast[usize](0) }
    if children.count < first + 2 {
        return error_at(tree.at, usage)
    }
    type_name :: word_of(shell, children[first])?
    found := found_type(shell, type_name) or_return error_at(
        children[first].at,
        message("no program here has a type named %", type_name)
    )
    defer runtime.array_free(&found.bytes)
    handle :: match opened_beneath_home(shell, ".", .Dir) {
        case Ok(made) => made
        case Error(problem) => return error_at(tree.at, message("the directory: %", problem))
    }
    end :: cast[slop_os.Channel](handle)
    defer slop_os.handle_close(handle)
    port :: os.port_for(slop_os.startup_block().budget, end) or_return error_at(tree.at, "there's no memory for a port")
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if declaring {
        if children.count != 3 {
            return error_at(tree.at, usage)
        }
        // Declared on the volume's root, which the home is
        root_handle :: match opened_beneath_home(shell, "~", .Dir) {
            case Ok(made) => made
            case Error(problem) => return error_at(tree.at, message("the home: %", problem))
        }
        root :: cast[slop_os.Channel](root_handle)
        defer slop_os.handle_close(root_handle)
        root_port :: os.port_for(slop_os.startup_block().budget, root) or_return error_at(
            tree.at,
            "there's no memory for a port"
        )
        defer slop_os.handle_close(cast[slop_os.Handle](root_port))
        field :: word_of(shell, children[2])?
        out := os.Outgoing.{}
        request :: os.begin[dir.Request](&out)
        request^ = .DeclareIndex(
            files.IndexOf.{schema = os.append(&out, view_of(&found.bytes[0], found.bytes.count)), field = os.append(&out, string_bytes(field))}
        )
        into := os.Incoming.{}
        match asked(root, root_port, &out, &into) {
            case Declared(number) => {
                say(shell, message("index % of %.%", number, type_name, field))
                return .Ok(.Null)
            }
            case Failed(failure) => {
                if failure == .WrongType {
                    return error_at(children[2].at, message("%1.%2 can't be indexed: it isn't an integer, a bool or text", type_name, field))
                }
                if failure == .NotVolumeRoot || failure == .ReadOnly {
                    return error_at(tree.at, "indexes are declared on a volume's root, which the shell's home isn't")
                }
                return error_at(tree.at, message("the index couldn't be declared: %", file_problem(failure)))
            }
            case _ => return error_at(tree.at, "the directory keeps no indexes")
        }
    }
    // The predicate: its words, from bare words and texts, read by precedence into postfix terms
    reading := Reading.{type_name = type_name, hash = found.hash, end = end, port = port}
    defer runtime.array_free(&reading.tokens)
    defer runtime.array_free(&reading.terms)
    defer runtime.array_free(&reading.texts)
    for i in first + 1..<children.count {
        child :: children[i]
        if child.kind == .Word {
            runtime.array_add(&reading.tokens, Token.{text = child.text, at = child.at})
            continue
        }
        text :: word_of(shell, child)?
        predicate_words(&reading.tokens, text, child.at)?
    }
    if reading.tokens.count == 0 {
        return error_at(tree.at, usage)
    }
    read_or(&reading)?
    if reading.next < reading.tokens.count {
        extra :: reading.tokens[reading.next]
        return error_at(extra.at, message("% doesn't follow: comparisons are joined by and, or and not", extra.text))
    }
    if reading.terms.count > query_protocol.MAX_TERMS {
        return error_at(tree.at, message("a query has at most % terms, comparisons, ands, ors and nots", query_protocol.MAX_TERMS))
    }
    terms :: reading.terms
    texts :: reading.texts
    made :: new_list()
    cursor := query_protocol.Cursor.{}
    asking :: terms
    bytes :: texts
    loop {
        if asking.count == 0 {
            return error_at(tree.at, usage)
        }
        out := os.Outgoing.{}
        request :: os.begin[dir.Request](&out)
        predicate := query_protocol.Predicate.{terms = os.append(&out, view_of(&asking[0], asking.count))}
        if bytes.count > 0 {
            predicate.texts = os.append(&out, view_of(&bytes[0], bytes.count))
        }
        request^ = .Query(query_protocol.Ask.{predicate = predicate, cursor = cursor})
        into := os.Incoming.{}
        match asked(end, port, &out, &into) {
            case Matched(matched) => {
                // None in what the volume looked at this time: on from where it got to
                if matched.file == 0 {
                    cursor = matched.next
                    continue
                }
                if made.items.count >= MAX_QUERIED {
                    say(shell, message("more than % match; the first % are listed", MAX_QUERIED, MAX_QUERIED))
                    break
                }
                record :: new_record()
                set_field(record, "path", .Path(copied(os.items(&into, matched.name))))
                set_field(record, "file", .Int(cast[i64](matched.file)))
                runtime.array_add(&made.items, Value.Record(record))
                cursor = matched.next
            }
            case End => break
            case Failed(failure) => return error_at(tree.at, message("the query couldn't be asked: %", file_problem(failure)))
            case _ => return error_at(tree.at, "the directory keeps no indexes")
        }
    }
    if made.items.count == 0 {
        say(shell, "no file matches")
        return .Ok(.Null)
    }
    return .Ok(.List(made))
}

/**
 * Split a text into a predicate's words: runs of characters between spaces and tabs, each parenthesis a word of its
 * own, and a run quoted with ' one word, its quotes left out, however it's spaced or parenthesized.
 *
 * @param tokens Where the words are added, views of text.
 * @param text The text, kept by the caller while they're used.
 * @param at Where its argument starts in the line, each word's place for an error.
 * @return Void once they're added; an error for a quote with no end.
 */
predicate_words :: fn(tokens : ptr[mut Token[..]], text #escaping : string, at : usize) -> Result[void, EvalError] {
    bytes :: string_bytes(text)
    i := cast[usize](0)
    loop {
        if i >= bytes.count {
            return .Ok
        }
        byte :: bytes[i]
        if byte == cast[u8](' ') || byte == 9 {
            i += 1
            continue
        }
        if byte == cast[u8]('(') || byte == cast[u8](')') {
            runtime.array_add(tokens, Token.{text = text_part(bytes, i, i + 1), at = at})
            i += 1
            continue
        }
        if byte == QUOTE {
            close := i + 1
            loop {
                if close >= bytes.count {
                    return .Error(EvalError.{message = "this ' has no end", at = at})
                }
                if bytes[close] == QUOTE {
                    break
                }
                close += 1
            }
            runtime.array_add(tokens, Token.{text = text_part(bytes, i + 1, close), at = at, quoted = true})
            i = close + 1
            continue
        }
        word_start :: i
        loop {
            if i >= bytes.count {
                break
            }
            next :: bytes[i]
            if next == cast[u8](' ') || next == 9 || next == cast[u8]('(') || next == cast[u8](')') || next == QUOTE {
                break
            }
            i += 1
        }
        runtime.array_add(tokens, Token.{text = text_part(bytes, word_start, i), at = at})
    }
}

/** The quote a predicate's text quotes a value with: '. */
QUOTE : u8 : 39

/**
 * Take part of a text's bytes, as a text.
 *
 * @param bytes The text's bytes.
 * @param from The first byte's place, at most bytes.count.
 * @param to One past the last's, from to bytes.count.
 * @return The bytes from from to to, a view of bytes; empty if they're out of order or past its end.
 */
text_part :: fn(bytes #escaping : u8[], from : usize, to : usize) -> string {
    if from >= to || to > bytes.count || from >= bytes.count {
        return ""
    }
    return string_of(&bytes[from], to - from)
}

/**
 * Get one of a predicate's words.
 *
 * @param reading The predicate being read, only looked at.
 * @param place The word's place among its words.
 * @return The word; an empty one, at 0, past the last.
 */
token_at :: fn(reading : ptr[Reading], place : usize) -> Token {
    if place < reading.tokens.count {
        return reading.tokens[place]
    }
    return Token.{}
}

/**
 * Tell whether the next word of a predicate is one of its grammar's, unquoted.
 *
 * @param reading The predicate being read, only looked at.
 * @param word The grammar's word: and, or, not, ( or ).
 * @return True if the next word is it.
 */
next_is :: fn(reading : ptr[Reading], word : string) -> bool {
    if reading.next >= reading.tokens.count {
        return false
    }
    token :: reading.tokens[reading.next]
    return !token.quoted && token.text == word
}

/**
 * Read comparisons joined by or, the loosest, into postfix terms: each and-joined run's, then an Or for each or.
 *
 * @param reading The predicate being read, moved past them.
 * @return Void once they're read; an error for words that aren't a predicate.
 */
read_or :: fn(reading : ptr[mut Reading]) -> Result[void, EvalError] {
    read_and(reading)?
    loop {
        if !next_is(reading, "or") {
            return .Ok
        }
        reading.next += 1
        read_and(reading)?
        runtime.array_add(&reading.terms, query_protocol.Term.{kind = cast[u32](query_protocol.TermKind.Or)})
    }
}

/**
 * Read comparisons joined by and into postfix terms.
 *
 * @param reading The predicate being read, moved past them.
 * @return Void once they're read; an error for words that aren't a predicate.
 */
read_and :: fn(reading : ptr[mut Reading]) -> Result[void, EvalError] {
    read_not(reading)?
    loop {
        if !next_is(reading, "and") {
            return .Ok
        }
        reading.next += 1
        read_not(reading)?
        runtime.array_add(&reading.terms, query_protocol.Term.{kind = cast[u32](query_protocol.TermKind.And)})
    }
}

/**
 * Read a comparison, one with not before it, or a parenthesized predicate, into postfix terms.
 *
 * @param reading The predicate being read, moved past it.
 * @return Void once it's read; an error for words that aren't a predicate, a ( with no ), a field with no index, or a
 *     value that isn't the field's.
 */
read_not :: fn(reading : ptr[mut Reading]) -> Result[void, EvalError] {
    if reading.next >= reading.tokens.count {
        at :: if reading.tokens.count > 0 { reading.tokens[reading.tokens.count - 1].at } else { cast[usize](0) }
        return .Error(EvalError.{message = "a comparison is missing: field op value", at = at})
    }
    if next_is(reading, "not") {
        reading.next += 1
        read_not(reading)?
        runtime.array_add(&reading.terms, query_protocol.Term.{kind = cast[u32](query_protocol.TermKind.Not)})
        return .Ok
    }
    if next_is(reading, "(") {
        open :: reading.tokens[reading.next]
        reading.next += 1
        read_or(reading)?
        if !next_is(reading, ")") {
            return .Error(EvalError.{message = "this ( has no )", at = open.at})
        }
        reading.next += 1
        return .Ok
    }
    return read_comparison(reading)
}

/**
 * Read a comparison, field op value, into a term, finding the field's index on the directory's volume.
 *
 * @param reading The predicate being read, moved past it; its term and a text's bytes are added.
 * @return Void once it's read; an error for fewer than three words left, an op that isn't one, a field with no index,
 *     or a value that isn't the field's.
 */
read_comparison :: fn(reading : ptr[mut Reading]) -> Result[void, EvalError] {
    if reading.next + 3 > reading.tokens.count {
        at :: token_at(reading, reading.next).at
        return .Error(EvalError.{message = "a comparison is field op value, like level >= 3", at = at})
    }
    field_token :: token_at(reading, reading.next)
    operator_token :: token_at(reading, reading.next + 1)
    value_token :: token_at(reading, reading.next + 2)
    reading.next += 3
    field :: field_token.text
    type_name :: reading.type_name
    comparison :: comparison_named(operator_token.text) or_return .Error(
        EvalError.{
            message = message("% isn't a comparison: ==, !=, <, <=, > or >=", operator_token.text),
            at = operator_token.at,
        }
    )
    index :: index_named(reading.end, reading.port, reading.hash, field) or_return .Error(
        EvalError.{
            message = message("there's no index of %1.%2: query --index %1 %2 declares one", type_name, field),
            at = field_token.at,
        }
    )
    value :: value_token.text
    term := query_protocol.Term.{
        kind = cast[u32](query_protocol.TermKind.Compare),
        comparison = cast[u32](comparison),
        index = index.number,
    }
    if index.kind == .Text {
        term.text_offset = cast[u32](reading.texts.count)
        term.text_count = cast[u32](value.count)
        for character in value {
            runtime.array_add(&reading.texts, cast[u8](character))
        }
    }
    else if index.kind == .Bool {
        if value != "true" && value != "false" {
            return .Error(
                EvalError.{message = message("%1.%2 is true or false, not %3", type_name, field, value), at = value_token.at}
            )
        }
        term.number = if value == "true" { cast[u64](1) } else { cast[u64](0) }
    }
    else {
        number :: language.integer_of(value) or_return .Error(
            EvalError.{message = message("%1.%2 is a number, not %3", type_name, field, value), at = value_token.at}
        )
        term.number = cast[u64](number)
    }
    runtime.array_add(&reading.terms, term)
    return .Ok
}

/**
 * Find a type by its name among the manifests of the programs the shell can run: the first struct of the name, in the
 * order the programs are listed.
 *
 * @param shell The shell, whose programs connection finds each program and its manifest.
 * @param name The type's name, as its program declares it.
 * @return Its schema's bytes and hash, the bytes the caller's to free; null if no manifest has a struct of the name,
 *     or there's no memory to write its schema.
 */
found_type :: fn(shell : ptr[mut Shell], name : string) -> FoundType? {
    for program in program_names(shell) {
        manifest := program_manifest(shell, program) or_continue
        defer schema.free(&manifest)
        for type, i in manifest.types {
            if type.kind == .Struct && !type.is_union && type.name == name {
                made := FoundType.{hash = schema.hash_rooted(&manifest, i)}
                if schema.write_rooted(&manifest, i, &made.bytes) != null || made.bytes.count == 0 {
                    runtime.array_free(&made.bytes)
                    return null
                }
                return made
            }
        }
    }
    return null
}

/**
 * Get the comparison an operator names.
 *
 * @param operator The operator, as written.
 * @return Its comparison; null for one that isn't ==, !=, <, <=, > or >=.
 */
comparison_named :: fn(operator : string) -> query_protocol.Comparison? {
    return if operator == "==" {
        query_protocol.Comparison.Equal
    }
    else if operator == "!=" {
        query_protocol.Comparison.NotEqual
    }
    else if operator == "<" {
        query_protocol.Comparison.Less
    }
    else if operator == "<=" {
        query_protocol.Comparison.LessOrEqual
    }
    else if operator == ">" {
        query_protocol.Comparison.Greater
    }
    else if operator == ">=" { query_protocol.Comparison.GreaterOrEqual } else { cast[query_protocol.Comparison?](null) }
}

/** An index a directory's volume keeps, as query finds it: its number and what its field holds. */
NamedIndex :: struct {
    /** Its number. */
    number : u32,
    /** What its field holds. */
    kind : files.IndexedKind,
}

/**
 * Find the index of a type's field on a directory's volume, by listing them.
 *
 * @param end The directory's connection, any directory of the volume.
 * @param port A port bound to end.
 * @param hash The type's schema hash.
 * @param field The field's name.
 * @return The index; null if none is of the field, or they couldn't be listed.
 */
index_named :: fn(end : slop_os.Channel, port : slop_os.Port, hash : u8[32], field : string) -> NamedIndex? {
    cursor := cast[u32](0)
    loop {
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Indexes(cursor)
        into := os.Incoming.{}
        match asked(end, port, &out, &into) {
            case IndexListed(index) => {
                if same_hash(index.schema, hash) && copied(os.items(&into, index.field)) == field {
                    return NamedIndex.{number = index.number, kind = index.kind}
                }
                if index.next <= cursor {
                    return null
                }
                cursor = index.next
            }
            case _ => return null
        }
    }
}

/**
 * Send a request on a directory connection and wait for its answer.
 *
 * @param end The connection, kept by the caller.
 * @param port A port bound to end.
 * @param out The request, built with os.begin[dir.Request].
 * @param into Where the answer goes.
 * @return The answer, a copy; Unsupported if it couldn't be sent, or the connection's gone.
 */
asked :: fn(end : slop_os.Channel, port : slop_os.Port, out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    match dir.receive_response(end, port, into, true) {
        case Received => return os.message_of[dir.Response](into)^
        case _ => return .Unsupported
    }
}
