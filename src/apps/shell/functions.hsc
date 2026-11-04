package shell

import runtime from "base"
import os from "std"
import strings from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * Shell functions, errors as values, and the shell's directory (decisions/0171). A function is local to the session:
 * its parameters are matched as a program's are, by position and --name, and a bare word is read by the parameter's
 * type; its body runs in a scope of its own, its last statement's value or a return's its result. An error a
 * statement of its body meets is fatal unless the statement has ?, which makes it the function's own, for its caller
 * to handle.
 */

/** How deep calls of shell functions go before the shell says so. */
MAX_DEPTH :: 64

/** The types a function's parameters can have. */
TYPE_NAMES :: string.["int", "size", "duration", "bool", "string", "path", "list", "record"]

/**
 * Define a shell function, replacing one of the same name; the built-ins' names (print, exit, cd) are theirs.
 *
 * It fails, defining nothing, for a built-in's name or a parameter of a type the shell hasn't (TYPE_NAMES).
 *
 * @param shell The shell, whose functions it's added to.
 * @param tree The Function node, kept by the shell for as long as it runs: its parameters, then its body.
 * @return Null.
 */
define :: fn(shell: ptr[mut Shell], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    if tree.text == "print" || tree.text == "exit" || tree.text == "cd" {
        return error_at(tree.at, message("% is built in", tree.text))
    }
    for parameter in tree.children {
        if parameter.kind != .Parameter {
            continue
        }
        match parameter.value {
            case Text(type) => {
                known := false
                for each in TYPE_NAMES {
                    known = known || each == type
                }
                if !known {
                    return error_at(parameter.at, message("% isn't a type the shell has", type))
                }
            }
            case _ => {}
        }
    }
    for &each in shell.functions {
        if each^.text == tree.text {
            each^ = tree
            return .Ok(.Null)
        }
    }
    runtime.array_add(&shell.functions, tree)
    return .Ok(.Null)
}

/**
 * Find a shell function by name.
 *
 * @param shell The shell, whose functions are searched, read only.
 * @param name The name, compared exactly.
 * @return The function's Function node; null if there's none of that name.
 */
function_named :: fn(shell: ptr[Shell], name: string) -> ptr[Node]? {
    for each in shell.functions {
        if each.text == name {
            return each
        }
    }
    return null
}

/**
 * Call a shell function: its arguments matched to its parameters and bound in a scope of its own, and its body run
 * there.
 *
 * Arguments are matched by --name, or by position to the first parameter not yet given; a bool's --name alone is true.
 * A bare word is read by its parameter's type, anything else evaluated in the caller's scope; a parameter not given
 * takes its default, false for a bool, or the call fails. A text value given for a path parameter becomes a path.
 *
 * It fails for calls more than MAX_DEPTH deep, arguments that don't match or aren't of their parameters' types, or a
 * parameter missing. An error the body meets without ? comes back fatal, its message starting "in name: "; one passed
 * by ? comes back as the function's own, which the caller can handle.
 *
 * @param shell The shell, whose scope is the function's while its body runs, and the caller's again after.
 * @param function The function's Function node, as define kept it: its Parameter children, then its body, the last
 *     child that isn't a Parameter; define's, kept by the shell for as long as it runs.
 * @param tree The Call node, whose children are the arguments: Named nodes for --name, each followed by its value
 *     unless it's a bool's given alone; Word nodes read by their parameter's type; anything else evaluated in the
 *     caller's scope.
 * @return The body's last statement's value, or what a return gave (shell.returned); an error as described above.
 */
call_function :: fn(shell: ptr[mut Shell], function #escaping : ptr[Node], tree #escaping : ptr[Node]) -> Result[Value, EvalError] {
    if shell.depth >= MAX_DEPTH {
        return error_at(tree.at, message("% calls functions more than % deep", tree.text, MAX_DEPTH))
    }
    scope := runtime.new(Scope)
    scope.parent = shell.scope
    // Each parameter's argument, by matching as a program's are; bound once they're all evaluated, in the caller's scope
    matched : Matched[..]
    defer runtime.array_free(&matched)
    parameters : ptr[Node][..]
    defer runtime.array_free(&parameters)
    body := function
    for each in function.children {
        if each.kind == .Parameter {
            runtime.array_add(&parameters, each)
            runtime.array_add(&matched, Matched.{})
        }
        else {
            body = each
        }
    }
    at : usize = 0
    loop {
        argument :: child(tree, at) or_break
        at += 1
        index := parameters.count
        if argument.kind == .Named {
            for parameter, i in parameters {
                if parameter.text == argument.text {
                    index = i
                }
            }
            if index >= parameters.count {
                return error_at(argument.at, message("% takes no --%", tree.text, argument.text))
            }
            next :: child(tree, at)
            if index >= matched.count || index >= parameters.count {
                return error_at(argument.at, message("% takes no --%", tree.text, argument.text))
            }
            if type_of_parameter(parameters[index]) == "bool" && !is_bool_word(next) {
                for &each, i in matched {
                    if i == index {
                        each.flag = true
                    }
                }
                continue
            }
            value :: next or_return error_at(argument.at, message("--% needs a value after it", argument.text))
            for &each, i in matched {
                if i == index {
                    each.node = value
                }
            }
            at += 1
            continue
        }
        for each, i in matched {
            if (each.node is_none) && !each.flag {
                index = i
                break
            }
        }
        if index >= matched.count {
            return error_at(argument.at, message("% takes no more arguments", tree.text))
        }
        for &each, i in matched {
            if i == index {
                each.node = argument
            }
        }
    }
    for parameter, i in parameters {
        value := Value.Null
        type :: type_of_parameter(parameter)
        argument :: if i < matched.count { matched[i].node } else { null }
        match argument {
            case Some(node) => {
                if node.kind == .Word {
                    value = word_as(type, node.text) or_return error_at(node.at, message("--%: % isn't %", parameter.text, node.text,
                        type_article(type)))
                }
                else {
                    value = evaluate(shell, node)?
                }
            }
            case None => {
                if i < matched.count && matched[i].flag {
                    value = .Bool(true)
                }
                else {
                    match first_child(parameter) {
                        case Some(default) => value = evaluate(shell, default)?
                        case None => {
                            if type != "bool" {
                                return error_at(tree.at, message("% needs its %", tree.text, parameter.text))
                            }
                            value = .Bool(false)
                        }
                    }
                }
            }
        }
        if !of_type(type, value) {
            return error_at(match argument { case Some(node) => node.at case None => tree.at },
                message("--% takes %, not %", parameter.text, type_article(type), type_name(value)))
        }
        bind(scope, parameter.text, if type == "path" { as_path(value) } else { value })
    }
    outer :: shell.scope
    shell.scope = scope
    shell.depth += 1
    result :: evaluate(shell, body)
    shell.depth -= 1
    shell.scope = outer
    match result {
        case Ok(value) => return .Ok(value)
        case Error(error) => {
            if error.returning {
                return .Ok(shell.returned)
            }
            ended := error
            if !ended.fatal && !ended.passed {
                ended.fatal = true
                ended.message = message("in %: %", tree.text, error.message)
            }
            ended.passed = false
            return .Error(ended)
        }
    }
}

/** What a parameter's given: its argument, or for a bool's --name alone, true. */
Matched :: struct {
    /** The argument's node; null if it's given none. */
    node : ptr[Node]?,
    /** Whether it's a bool given by its --name alone, so it's true. */
    flag : bool,
}

/**
 * Find a parameter's type's name.
 *
 * @param parameter A Parameter node of a Function, whose value is its type's name as Text when it's given one.
 * @return One of TYPE_NAMES; "" for a parameter of any type.
 */
type_of_parameter :: fn(parameter: ptr[Node]) -> string {
    return match parameter.value {
        case Text(type) => type
        case _ => ""
    }
}

/**
 * Read a bare word as a parameter's type: a number, a size or a duration as they're written in expressions, a bool,
 * or text.
 *
 * @param type The type's name, "" for any; for any, string, list and record the word is text, and for path a path.
 * @param word The word, as written.
 * @return The value; null if the word isn't one of the type, like a bool other than true or false. For int, size and
 *     duration, any number literal is given, of whatever kind it is, for the caller to check.
 */
word_as :: fn(type: string, word: string) -> Value? {
    if type == "" || type == "string" || type == "list" || type == "record" {
        return .Text(word)
    }
    if type == "path" {
        return .Path(word)
    }
    if type == "bool" {
        return if word == "true" { Value.Bool(true) } else if word == "false" { Value.Bool(false) } else { null }
    }
    // A number, with its unit if it has one, read as a literal
    match parse(word) {
        case Ok(tree) => {
            literal :: first_child(tree) or_return null
            if literal.kind != .Literal || tree.children.count != 1 {
                return null
            }
            return literal.value
        }
        case Error(error) => return null
    }
}

/**
 * Tell whether a value is of a parameter's type: text and a path are each of the other's type, and anything is of no
 * type.
 *
 * @param type The type's name, "" for any; a name not in TYPE_NAMES takes nothing.
 * @param value The value checked; only its kind is looked at, so any Int is an int and any list a list.
 * @return True if the parameter takes it; Null is taken only by "", any type.
 */
of_type :: fn(type: string, value: Value) -> bool {
    return match value {
        case Null => type == ""
        case Bool(_) => type == "" || type == "bool"
        case Int(_) => type == "" || type == "int"
        case Size(_) => type == "" || type == "size"
        case Duration(_) => type == "" || type == "duration"
        case Text(_) => type == "" || type == "string" || type == "path"
        case Path(_) => type == "" || type == "path" || type == "string"
        case List(_) => type == "" || type == "list"
        case Record(_) => type == "" || type == "record"
    }
}

/**
 * Make text a path.
 *
 * @param value Any value; a Text's string is shared by the Path made, not copied.
 * @return A Path of the same text for Text; any other value as it is.
 */
as_path :: fn(value: Value) -> Value {
    return match value {
        case Text(text) => Value.Path(text)
        case _ => value
    }
}

/**
 * Name what a parameter's type takes, as errors say it.
 *
 * @param type The type's name, one of TYPE_NAMES or "" for any; any other name is said as "text".
 * @return Its name with an article, like "an integer"; "text" for string, any or an unknown name.
 */
type_article :: fn(type: string) -> string {
    return if type == "int" { "an integer" } else if type == "size" { "a size" } else if type == "duration" { "a duration" }
        else if type == "bool" { "true or false" } else if type == "path" { "a path" } else if type == "list" { "a list" }
        else if type == "record" { "a record" } else { "text" }
}

/**
 * Make an error a value, for catch: a record of its message and where in the line it was.
 *
 * @param error The error, whose message the record keeps.
 * @return A record of message, Text, and at, an Int of bytes from the line's start.
 */
error_record :: fn(error #escaping : EvalError) -> Value {
    made :: new_record()
    set_field(made, "message", .Text(error.message))
    set_field(made, "at", .Int(cast[i64](error.at)))
    return .Record(made)
}

// ---- The shell's directory

/**
 * Change the shell's directory, for cd: to a path beneath its home, from where it is; alone, to its home.
 *
 * It fails if cd is given more than one argument or one that isn't a path or text, the path goes above the home, or
 * isn't a directory there; the directory is then as it was.
 *
 * @param shell The shell, whose directory changes.
 * @param tree The Call node of cd, its one argument, if any, the path.
 * @return Null.
 */
change_directory :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count > 1 {
        return error_at(tree.at, "cd takes one path")
    }
    argument :: first_child(tree)
    given := "~"
    match argument {
        case Some(node) => {
            if node.kind == .Word {
                given = node.text
            }
            else {
                got :: evaluate(shell, node)?
                match got {
                    case Text(text) => given = text
                    case Path(text) => given = text
                    case _ => return error_at(node.at, message("cd takes a path, not %", type_name(got)))
                }
            }
        }
        case None => {}
    }
    at :: match argument {
        case Some(node) => node.at
        case None => tree.at
    }
    path :: match resolve_path(shell, given) {
        case Ok(resolved) => resolved
        case Error(problem) => return error_at(at, message("%: %", given, problem))
    }
    if path.count > 0 {
        match opened_beneath_home(shell, path, .Dir) {
            case Ok(handle) => _ = slop_os.handle_close(handle)
            case Error(problem) => return error_at(at, message("%: %", given, problem))
        }
    }
    shell.directory = path
    return .Ok(.Null)
}

/**
 * Resolve a path as the shell does, beneath its home: ~ is the home, ~/ starts from it, anything else starts from the
 * shell's directory; . is where it is and .. the directory above, never above the home.
 *
 * It fails, with why as a sentence for a person, for a path starting with / or going above the home. Nothing is
 * opened, so what it names needn't exist.
 *
 * @param shell The shell, whose directory a relative path starts from.
 * @param given The path, as written.
 * @return The path from the home, its parts separated by /, on the heap; "" for the home itself.
 */
resolve_path :: fn(shell: ptr[Shell], given #escaping : string) -> Result[string, string] {
    if given.count > 0 && slice(given, 0, 1) == "/" {
        return .Error("paths are beneath your home, written without a / first")
    }
    from_home :: given == "~" || (given.count >= 2 && slice(given, 0, 2) == "~/")
    rest :: if given == "~" { "" } else if from_home { slice(given, 2, given.count) } else { given }
    parts : string[..]
    defer runtime.array_free(&parts)
    if !from_home {
        add_parts(&parts, shell.directory)?
    }
    add_parts(&parts, rest)?
    joined : u8[..]
    for part, i in parts {
        if i > 0 {
            runtime.array_add(&joined, cast[u8]('/'))
        }
        for byte in string_bytes(part) {
            runtime.array_add(&joined, byte)
        }
    }
    return .Ok(if joined.count > 0 { string_of(&joined[0], joined.count) } else { "" })
}

/**
 * Add a path's parts to a list of them: empty parts and . skipped, .. taking the last away.
 *
 * It fails, saying the path's above the home, for a .. with no part left to take away.
 *
 * @param parts The parts so far, each a view of its path, added to.
 * @param path The path, its parts separated by /, viewed by the parts added.
 * @return "", once the parts are added.
 */
add_parts :: fn(parts: ptr[mut string[..]], path #escaping : string) -> Result[string, string] {
    start : usize = 0
    for i in 0..<path.count + 1 {
        if i < path.count && slice(path, i, i + 1) != "/" {
            continue
        }
        part :: slice(path, start, i)
        start = i + 1
        if part.count == 0 || part == "." {
            continue
        }
        if part == ".." {
            if parts.count == 0 {
                return .Error("that's above your home")
            }
            runtime.resizable(parts).count = parts.count - 1
            continue
        }
        runtime.array_add(parts, part)
    }
    return .Ok("")
}
