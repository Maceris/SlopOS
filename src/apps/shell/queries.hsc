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
 * query (decisions/0201's 20j): the typed files beneath the shell's directory whose indexed fields compare as asked,
 * as a table of their paths, like any program's results; and query --index, an index of a type's field declared on
 * the home's volume. Indexes are declared and listed on a volume's root alone, so both are asked of the shell's home,
 * which has to be one; the query itself is asked beneath the shell's directory. A type is named as its programs name
 * it, found among the manifests of the programs the shell can run, as view finds a typed file's.
 *
 *     query --index Note level
 *     query Note level >= 3 and title != draft
 */

/** The most files query lists; past them, it says there are more. */
MAX_QUERIED :: 1000
/** The most comparisons a query joins with and. */
MAX_COMPARISONS :: 16

/** A type found among the programs' manifests: its schema's bytes and hash. */
FoundType :: struct {
    /** Its schema's bytes, written for it alone (schema.write_rooted), on the heap, freed by the caller. */
    bytes : u8[..],
    /** Its schema hash, as its typed files have it. */
    hash : u8[32],
}

/**
 * Query the typed files beneath the shell's directory: query Type field op value [and field op value]..., or declare
 * an index: query --index Type field. An op is ==, !=, <, <=, > or >=; a value is read as the field's index holds it,
 * an integer, true or false, or text.
 *
 * It fails without a home, for arguments that aren't one of those, a type no program's manifest has, a field with no
 * index declared (or one that can't be indexed, for --index), a value that isn't the field's, a home that isn't its
 * volume's root, or what the directory answers.
 *
 * @param shell The shell, whose directory is queried, whose home's volume's indexes are listed or declared, and whose
 *     programs' manifests are where the type's found.
 * @param tree The Call node of query.
 * @return A list of records, path, beneath the shell's directory, and file, its number in its volume; Null when none
 *     matches, or after --index, which is said.
 */
query_files :: fn(shell : ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    usage :: "query takes a type and comparisons, query Note level >= 3 and title != draft; or --index, a type and a field"
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
    // The volume's indexes, on its root, which the home is
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
    if declaring {
        if children.count != 3 {
            return error_at(tree.at, usage)
        }
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
                if failure == .ReadOnly {
                    return error_at(tree.at, "indexes are declared on a volume's root, which the shell's home isn't")
                }
                return error_at(tree.at, message("the index couldn't be declared: %", file_problem(failure)))
            }
            case _ => return error_at(tree.at, "the directory keeps no indexes")
        }
    }
    // Comparisons: field op value, joined by and
    terms : query_protocol.Term[..]
    defer runtime.array_free(&terms)
    texts : u8[..]
    defer runtime.array_free(&texts)
    at := first + 1
    loop {
        if at + 3 > children.count || terms.count >= MAX_COMPARISONS * 2 {
            return error_at(tree.at, usage)
        }
        field_node :: children[at]
        field :: word_of(shell, field_node)?
        operator :: word_of(shell, children[at + 1])?
        comparison :: comparison_named(operator) or_return error_at(
            children[at + 1].at,
            message("% isn't a comparison: ==, !=, <, <=, > or >=", operator)
        )
        index :: index_named(root, root_port, found.hash, field) or_return error_at(
            field_node.at,
            message("there's no index of %1.%2: query --index %1 %2 declares one", type_name, field)
        )
        value_node :: children[at + 2]
        value :: word_of(shell, value_node)?
        term := query_protocol.Term.{
            kind = cast[u32](query_protocol.TermKind.Compare),
            comparison = cast[u32](comparison),
            index = index.number,
        }
        if index.kind == .Text {
            term.text_offset = cast[u32](texts.count)
            term.text_count = cast[u32](value.count)
            for character in value {
                runtime.array_add(&texts, cast[u8](character))
            }
        }
        else if index.kind == .Bool {
            if value != "true" && value != "false" {
                return error_at(value_node.at, message("%1.%2 is true or false, not %3", type_name, field, value))
            }
            term.number = if value == "true" { cast[u64](1) } else { cast[u64](0) }
        }
        else {
            number :: language.integer_of(value) or_return error_at(
                value_node.at,
                message("%1.%2 is a number, not %3", type_name, field, value)
            )
            term.number = cast[u64](number)
        }
        runtime.array_add(&terms, term)
        if terms.count > 1 {
            runtime.array_add(&terms, query_protocol.Term.{kind = cast[u32](query_protocol.TermKind.And)})
        }
        at += 3
        if at >= children.count {
            break
        }
        joining :: word_of(shell, children[at])?
        if joining != "and" {
            return error_at(children[at].at, message("comparisons are joined by and, not %", joining))
        }
        at += 1
    }
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
 * @param end The directory's connection: its volume's root, as only that lists them.
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
