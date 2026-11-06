package shell_language

import runtime from "base"
import text_buffer from "std"

/** The shell's names and their values: a function's call has its own, in the scope it was called from. */
Scope :: struct {
    /** The names bound here, each once. */
    names : string[..],
    /** Their values, names[i]'s at i. */
    values : Value[..],
    /** The scope it's in, whose names are seen when this hasn't them; null for the shell's own, the outermost. */
    parent : ptr[Scope]?,
}

/**
 * Find a name's value, in a scope or the ones it's in, the innermost first.
 *
 * @param scope The scope looked in first.
 * @param name The name, compared exactly.
 * @return Its value; null if no scope binds it.
 */
lookup :: fn(scope: ptr[Scope], name: string) -> Value? {
    for each, i in scope.names {
        if each == name && i < scope.values.count {
            return scope.values[i]
        }
    }
    match scope.parent {
        case Some(outer) => return lookup(outer, name)
        case None => return null
    }
}

/**
 * Bind a name in a scope, replacing its value if the scope has it already; an outer scope's isn't changed.
 *
 * @param scope The scope the name's bound in, changed in place; the scopes it's in are left as they are.
 * @param name The name, kept by the scope as given when it's new, so it has to live as long.
 * @param value The value, kept by the scope.
 */
bind :: fn(scope: ptr[mut Scope], name #escaping : string, value #escaping : Value) {
    for each, i in scope.names {
        if each == name && i < scope.values.count {
            scope.values[i] = value
            return void
        }
    }
    runtime.array_add(&scope.names, name)
    runtime.array_add(&scope.values, value)
}

/**
 * Fill in a string's $names with their values, as render writes them; one that isn't bound is left as it was written.
 *
 * A name here runs over letters, digits, _ and -, as a name does everywhere in the language (parse_name), so
 * "$file-name" fills in file-name. A 0 byte, an escaped $, becomes a $.
 *
 * @param scope The scope the names are looked up in, then the scopes it's in.
 * @param text The string, as parse_quoted made it.
 * @return The string filled in, on the heap, never freed; a value is cut at 1024 bytes.
 */
interpolate :: fn(scope: ptr[Scope], text: string) -> string {
    bytes :: string_bytes(text)
    made : u8[..]
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        byte :: bytes[at]
        if byte == 0 {
            // An escaped $
            runtime.array_add(&made, cast[u8]('$'))
            at += 1
            continue
        }
        if byte == cast[u8]('$') && at + 1 < bytes.count && is_letter(bytes[at + 1]) {
            start :: at + 1
            end := start
            loop {
                if end >= bytes.count || (!is_letter(bytes[end]) && !is_digit(bytes[end]) && bytes[end] != cast[u8]('-')) {
                    break
                }
                end += 1
            }
            name :: if start <= end && end <= bytes.count { string_of(&bytes[start % bytes.count], end - start) } else { "" }
            match lookup(scope, name) {
                case Some(value) => {
                    storage : u8[1024]
                    out := text_buffer.make(storage)
                    render(&out, value)
                    for rendered in string_bytes(text_buffer.as_string(&out)) {
                        runtime.array_add(&made, rendered)
                    }
                }
                case None => {
                    for kept in bytes[at..<end] {
                        runtime.array_add(&made, kept)
                    }
                }
            }
            at = end
            continue
        }
        runtime.array_add(&made, byte)
        at += 1
    }
    return if made.count > 0 { string_of(&made[0], made.count) } else { "" }
}
