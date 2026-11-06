package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import strings from "std"
import terminal from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import bundle from "../../bundle"

/*
 * Completion (design/shell.md §6): Tab completes the word before the cursor by where it is. In a command's place, a
 * built-in's, a shell function's or a program's name; --name, the command's parameters; $name, the names the shell has
 * bound; after an enum's --name, its members; any other argument, a path beneath the home, by listing the directory
 * it'd be in. When several are listed, each has what it is beside it: a built-in's sentence, a program's summary from
 * its documentation, a parameter's type and documentation.
 */

/** The most candidates offered, so a directory of thousands, or a long list of programs, stays quick. */
MAX_CANDIDATES :: 64
/** The most programs whose summaries are asked for when several are listed: each is a request to the session manager. */
MAX_SUMMARIES :: 24

/**
 * Fill in the completions for the word before the cursor, for the line editor's Tab (terminal.Completer).
 *
 * @param shell The shell, whose names, functions, programs connection and home the candidates come from.
 * @param line The line being edited, a view of the editor's, good only during the call.
 * @param cursor The cursor, as a byte offset in line; past its end, its end.
 * @param into The completions, empty to start with: start is set to where the word starts, and each candidate, and its
 *     description, added with context.allocator, for the editor to free.
 */
complete_line :: fn(shell: ptr[mut Shell], line: u8[], cursor: usize, into: ptr[mut terminal.Completions]) {
    end :: if cursor < line.count { cursor } else { line.count }
    start := end
    loop {
        if start == 0 || start > line.count || ends_word(line[start - 1]) {
            break
        }
        start -= 1
    }
    into.start = start
    prefix :: text_of(line, start, end)
    // The command the word's an argument of: the first word after the last | ; ( or {, if one comes before it
    segment := start
    loop {
        if segment == 0 || segment > line.count || ends_command(line[segment - 1]) {
            break
        }
        segment -= 1
    }
    piped :: segment > 0 && segment <= line.count && line[segment - 1] == cast[u8]('|')
    words, command, previous :: words_of(text_of(line, segment, start))
    if prefix.count > 0 && slice_of(prefix, 0, 1) == "$" {
        complete_names(shell, prefix, into)
        return void
    }
    if words == 0 {
        complete_commands(shell, prefix, piped, into)
        return void
    }
    if prefix.count >= 2 && slice_of(prefix, 0, 2) == "--" {
        complete_parameters(shell, command, prefix, into)
        return void
    }
    if previous.count > 2 && slice_of(previous, 0, 2) == "--" && complete_members(shell, command, slice_of(previous, 2, previous.count), prefix, into) {
        return void
    }
    complete_paths(shell, prefix, into)
}

/**
 * Tell whether a byte ends the word before the cursor: a space or tab, or what separates or groups the language's
 * parts.
 *
 * @param byte A byte of the line.
 * @return True for a space, a tab, a line break, | ; ( ) { } [ ] , = or ".
 */
ends_word :: fn(byte: u8) -> bool {
    for each in " \t\n|;(){}[],=\"" {
        if byte == cast[u8](each) {
            return true
        }
    }
    return false
}

/**
 * Tell whether a byte ends a command and its arguments, so the next word is in a command's place.
 *
 * @param byte A byte of the line.
 * @return True for | ; ( { and a line break.
 */
ends_command :: fn(byte: u8) -> bool {
    return byte == cast[u8]('|') || byte == cast[u8](';') || byte == cast[u8]('(') || byte == cast[u8]('{') || byte == 10
}

/**
 * View part of a line as text.
 *
 * @param line The line's bytes.
 * @param start Where the text starts, in bytes.
 * @param end Where it ends, excluded.
 * @return The text, a view of line; empty for bounds backwards or past its end.
 */
text_of :: fn(line: u8[], start: usize, end: usize) -> string {
    if start >= end || end > line.count {
        return ""
    }
    return string_of(&line[start], end - start)
}

/**
 * Slice text, safely.
 *
 * @param text The text, viewed.
 * @param start Where the slice starts, in bytes.
 * @param end Where it ends, excluded.
 * @return The slice; empty for bounds backwards or past text's end.
 */
slice_of :: fn(text: string, start: usize, end: usize) -> string {
    return language.slice(text, start, end)
}

/**
 * Find text's words, separated by spaces and tabs: how many, the first and the last.
 *
 * @param text The text, viewed by the words given back.
 * @return count How many words; 0 for none.
 * @return first The first word; empty for none.
 * @return last The last word, the first again for one; empty for none.
 */
words_of :: fn(text: string) -> (count : usize, first : string, last : string) {
    count : usize = 0
    first := ""
    last := ""
    start : usize = 0
    for i in 0..<text.count + 1 {
        if i < text.count && slice_of(text, i, i + 1) != " " && slice_of(text, i, i + 1) != "\t" {
            continue
        }
        if i > start {
            last = slice_of(text, start, i)
            first = if count == 0 { last } else { first }
            count += 1
        }
        start = i + 1
    }
    return count, first, last
}

/**
 * Tell whether text starts with a prefix.
 *
 * @param text The text.
 * @param prefix The prefix; empty starts everything.
 * @return True if text's first bytes are prefix's.
 */
starts_with :: fn(text: string, prefix: string) -> bool {
    return prefix.count <= text.count && slice_of(text, 0, prefix.count) == prefix
}

/**
 * Add a candidate and what it is, each copied with context.allocator for the editor to free, unless there are
 * MAX_CANDIDATES already, or it's offered already.
 *
 * @param into The completions added to; its candidates and descriptions stay the same length.
 * @param candidate What would replace the word: a directory's path ends with /, so its entries can be completed next.
 * @param description What it is, shown beside it when several are listed; "" for nothing.
 */
offer :: fn(into: ptr[mut terminal.Completions], candidate: string, description: string) {
    if into.candidates.count >= MAX_CANDIDATES {
        return void
    }
    for each in into.candidates {
        if each == candidate {
            return void
        }
    }
    runtime.array_add(&into.candidates, strings.clone(candidate) or_else "")
    runtime.array_add(&into.descriptions, strings.clone(description) or_else "")
}

/**
 * Offer the commands a word in a command's place could be: the built-ins, the stages after |, the shell's functions,
 * and the programs, each with what it is.
 *
 * Programs' summaries are asked for only when several are offered, and at most MAX_SUMMARIES of them.
 *
 * @param shell The shell, whose functions and programs are offered.
 * @param prefix What's typed of the command.
 * @param piped Whether the word comes after a |, where the stages go.
 * @param into The completions, added to.
 */
complete_commands :: fn(shell: ptr[mut Shell], prefix: string, piped: bool, into: ptr[mut terminal.Completions]) {
    for each in BUILTINS {
        if starts_with(each.name, prefix) && (piped || !is_stage_name(each.name)) {
            offer(into, each.name, each.summary)
        }
    }
    for function in shell.functions {
        if starts_with(function.text, prefix) {
            offer(into, function.text, "a shell function")
        }
    }
    first_program :: into.candidates.count
    for name in program_names(shell) {
        if starts_with(name, prefix) {
            offer(into, name, "")
        }
    }
    // Summaries, once it's known several are listed
    if into.candidates.count < 2 || into.candidates.count - first_program > MAX_SUMMARIES {
        return void
    }
    for i in first_program..<into.candidates.count {
        if i >= into.candidates.count || i >= into.descriptions.count {
            break
        }
        name :: into.candidates[i]
        match program_documentation(shell, name) {
            case Some(found) => {
                described :: strings.clone(found.summary) or_else ""
                // Proven again after the calls, which forget what's known through into
                if found.summary.count > 0 && i < into.descriptions.count {
                    replaced :: into.descriptions[i]
                    into.descriptions[i] = described
                    runtime.free_array(bit_cast[u8[]](replaced))
                }
            }
            case None => {}
        }
    }
}

/**
 * Tell whether a built-in's name is a stage's, which only goes after |.
 *
 * @param name The name.
 * @return True for one of STAGES.
 */
is_stage_name :: fn(name: string) -> bool {
    for each in STAGES {
        if each == name {
            return true
        }
    }
    return false
}

/**
 * Offer the names the shell has bound, as $name, the innermost scope's first.
 *
 * @param shell The shell, whose scopes are looked in.
 * @param prefix What's typed, starting with $.
 * @param into The completions, added to, each described by its value's kind.
 */
complete_names :: fn(shell: ptr[mut Shell], prefix: string, into: ptr[mut terminal.Completions]) {
    typed :: slice_of(prefix, 1, prefix.count)
    scope : ptr[Scope]? = shell.scope
    loop {
        current :: scope or_break
        for name, i in current.names {
            kind :: if i < current.values.count { type_name(current.values[i]) } else { "" }
            if starts_with(name, typed) {
                offer(into, message("$%", name), kind)
            }
        }
        scope = current.parent
    }
}

/**
 * Offer a command's parameters, as --name: a shell function's, or a program's from its manifest, each with its type and
 * what its documentation says of it.
 *
 * A program's terminal, input and output aren't offered, since they're never given by name.
 *
 * @param shell The shell, whose functions and programs are looked in.
 * @param command The command's name, the first word of its call.
 * @param prefix What's typed, starting with --.
 * @param into The completions, added to.
 */
complete_parameters :: fn(shell: ptr[mut Shell], command: string, prefix: string, into: ptr[mut terminal.Completions]) {
    typed :: slice_of(prefix, 2, prefix.count)
    match function_named(shell, command) {
        case Some(function) => {
            for parameter in function.children {
                if parameter.kind == .Parameter && starts_with(parameter.text, typed) {
                    type :: type_of_parameter(parameter)
                    offer(into, message("--%", parameter.text), if type.count > 0 { type } else { "any type" })
                }
            }
            return void
        }
        case None => {}
    }
    if (builtin_named(command) is_some) {
        return void
    }
    manifest := program_manifest(shell, command) or_return void
    defer schema.free(&manifest)
    entry :: schema.type_in(&manifest, 0) or_return void
    documentation :: program_documentation(shell, command) or_else bundle.Documentation.{}
    for input in entry.inputs {
        parameter :: parameter_of(&manifest, input)
        if parameter.giving == .Terminal || parameter.giving == .Input || parameter.giving == .Output || !starts_with(parameter.name, typed) {
            continue
        }
        text := given_text(&manifest, parameter)
        for each in documentation.parameters {
            if each.name == parameter.name && each.text.count > 0 {
                text = message("%: %", text, each.text)
            }
        }
        offer(into, message("--%", parameter.name), text)
    }
}

/**
 * Offer an enum parameter's members, for the word after its --name.
 *
 * @param shell The shell, whose programs connection finds the program's manifest.
 * @param command The command's name.
 * @param name The parameter's name, without its --.
 * @param prefix What's typed of the member.
 * @param into The completions, added to.
 * @return True if the parameter is an enum's, so its members are what's offered; false otherwise, for paths instead.
 */
complete_members :: fn(shell: ptr[mut Shell], command: string, name: string, prefix: string, into: ptr[mut terminal.Completions]) -> bool {
    if (function_named(shell, command) is_some) || (builtin_named(command) is_some) {
        return false
    }
    manifest := program_manifest(shell, command) or_return false
    defer schema.free(&manifest)
    entry :: schema.type_in(&manifest, 0) or_return false
    for input in entry.inputs {
        parameter :: parameter_of(&manifest, input)
        if parameter.name != name {
            continue
        }
        type :: schema.type_in(&manifest, schema.unaliased_place(&manifest, parameter.held)) or_return false
        if type.kind != .Enum {
            return false
        }
        for constant in type.constants {
            if starts_with(constant.name, prefix) {
                offer(into, constant.name, type.name)
            }
        }
        return true
    }
    return false
}

/**
 * Offer paths beneath the shell's home: the entries of the directory the typed path's last / ends, from the shell's
 * directory or the home, a directory's with a / after it.
 *
 * Nothing's offered without a home, for a path that doesn't resolve, or a directory that can't be opened or listed.
 *
 * @param shell The shell, whose home is asked.
 * @param prefix What's typed of the path.
 * @param into The completions, added to: the typed path's directory part, then each entry's name.
 */
complete_paths :: fn(shell: ptr[mut Shell], prefix: string, into: ptr[mut terminal.Completions]) {
    split := prefix.count
    loop {
        if split == 0 || slice_of(prefix, split - 1, split) == "/" {
            break
        }
        split -= 1
    }
    directory :: slice_of(prefix, 0, split)
    typed :: slice_of(prefix, split, prefix.count)
    // A copy, as opening keeps the path it's given
    given :: strings.clone(if directory.count > 0 { directory } else { "." }) or_return void
    defer runtime.free_array(bit_cast[u8[]](given))
    handle :: match opened_beneath_home(shell, given, .Dir) {
        case Ok(opened) => opened
        case Error(problem) => return void
    }
    end :: cast[slop_os.Channel](handle)
    defer slop_os.handle_close(handle)
    port :: os.port_for(slop_os.startup_block().budget, end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    cursor := cast[u64](0)
    loop {
        if into.candidates.count >= MAX_CANDIDATES {
            break
        }
        asking := os.Outgoing.{}
        os.begin[dir.Request](&asking)^ = .List(cursor)
        if dir.send_request(end, port, &asking) is_some {
            break
        }
        listed := os.Incoming.{}
        if !received(dir.receive_response(end, port, &listed, true)) {
            break
        }
        match os.message_of[dir.Response](&listed)^ {
            case Listed(entry) => {
                bytes :: os.items(&listed, entry.name)
                name :: if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
                if name.count > 0 && starts_with(name, typed) && (typed.count > 0 || slice_of(name, 0, 1) != ".") {
                    folder :: entry.kind == .Directory
                    offer(into, message("%1%2%3", directory, name, if folder { "/" } else { "" }), if folder { "directory" } else { "" })
                }
                cursor = entry.next
            }
            case _ => break
        }
    }
}
