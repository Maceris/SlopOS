/**
 * search (decisions/0179): the lines of text files beneath a directory that a pattern matches, or the names it
 * matches, as records for the shell to show or a pipeline to take.
 */
package search

import runtime from "base"
import os from "std"
import regex from "std"
import strings from "std"
import unicode from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import stream from "std/os/slop_os"
import file_tools from "../../file_tools"

/** The most bytes of a file that are searched: 4 MiB. What's past them isn't. */
MAX_FILE_BYTES : u64 : 4 * 1024 * 1024
/** The most bytes of a matching line a Found holds; what's past them is cut, at a character's start. */
MAX_TEXT_BYTES :: 200
/** How deeply directories are gone into beneath the one searched; deeper ones aren't searched. */
MAX_DEPTH :: 32

/** A line that matched, or with names, a name. */
Found :: struct {
    /** The file's or directory's path beneath the shell's directory, its parts separated by /. */
    path : string,
    /** The line's number in the file, from 1; 0 for a name that matched. */
    line : u64,
    /** The line, without its line break, cut at MAX_TEXT_BYTES; empty for a name. */
    text : string,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: path, or here for the shell's directory. */
    parameter : os.ParameterName,
}

/** A pattern that isn't one, and where. */
PatternProblem :: struct {
    /** The parameter: pattern. */
    parameter : os.ParameterName,
    /** The byte of the pattern where it's wrong, from 0: for a parenthesis, class or repetition, where it opens. */
    at : u64,
}

/** Why it couldn't search. */
SearchError :: union {
    /** The pattern isn't a regular expression. */
    BadPattern(PatternProblem),
    /** Nothing's at the path. */
    NotFound(Problem),
    /** The directory couldn't be read, or what was found written. */
    Unreadable(Problem),
}

/** What a search goes on with: the pattern, where it writes, and how many it's found. */
Search :: struct {
    /** The compiled pattern. */
    pattern : regex.Regex,
    /** Whether names are matched, rather than lines. */
    names : bool,
    /** The output's writer, when writing. */
    writer : stream.Writer[Found],
    /** Whether there's an output to write to. */
    writing : bool,
    /** How many lines or names it's found. */
    count : u64,
}

/**
 * Search the text files beneath a directory for lines a pattern matches; with names, the names of what's beneath it.
 *
 * Files are searched in the order their directory lists them, a directory's before what's beneath it. A typed file
 * isn't searched, and neither is one with a 0 byte, as it isn't text; past its first 4 MiB, a file isn't searched
 * either.
 *
 * @param pattern A regular expression (std/regex's syntax: RE2's, but for what isn't linear), matched anywhere in a
 *     line, or a name.
 * @param here The shell's directory, given without asking, which path is beneath.
 * @param path The directory to search beneath, or a file to search, beneath here; without it, here itself.
 * @param ignore_case Whether ASCII letters match either case, as (?i) at the pattern's start does.
 * @param names Whether the names of files and directories are matched, rather than the lines in files.
 * @param output Where what's found goes: the shell, to show it, or what comes after it in a pipeline. Without it, it's
 *     only counted.
 * @return How many lines, or names, matched.
 * @error BadPattern The pattern isn't a regular expression; check its parentheses, brackets and repetitions.
 * @error NotFound There's nothing at that path; search a directory or file that's there.
 * @error Unreadable The directory couldn't be read, or what was found written.
 */
main :: fn(pattern: string, here: os.Channel[dir.Dir], path: string?, ignore_case: bool, names: bool, output: os.Sink[Found]?) -> Result[u64,
    SearchError] {
    asked :: if path is_some { "path" } else { "here" }
    problem :: Problem.{parameter = os.ParameterName.{name = asked}}
    search := Search.{names = names}
    match regex.compile(pattern, regex.Flags.{ignore_case = ignore_case}) {
        case Ok(compiled) => search.pattern = compiled
        case Error(error) => return .Error(.BadPattern(PatternProblem.{parameter = os.ParameterName.{name = "pattern"}, at = cast[u64](error.at)}))
    }
    defer regex.free(&search.pattern)
    directory, opened :: os.directory_on(here.end)
    if opened is_some {
        return .Error(.Unreadable(problem))
    }
    start :: path or_else ""
    source :: file_tools.live_source(directory)
    kind :: if start.count == 0 { file_tools.Kind.Directory } else { file_tools.kind_at(source, start) }
    if kind == .Missing {
        return .Error(.NotFound(problem))
    }
    match output {
        case Some(sink) => {
            search.writer = stream.writer_on(sink) or_return .Error(.Unreadable(problem))
            search.writing = true
        }
        case None => {}
    }
    went :: if kind == .File {
        search_file(&search, directory, start)
    }
    else {
        search_directory(&search, source, directory, start, 0)
    }
    if !went {
        return .Error(.Unreadable(problem))
    }
    if search.writing && (stream.finish(&search.writer, 0) is_some) {
        return .Error(.Unreadable(problem))
    }
    return .Ok(search.count)
}

/**
 * Search what's in a directory, and beneath it: each file's lines, or each name, and each directory in turn.
 *
 * @param search The search, whose count grows and whose writer is written to.
 * @param source The shell's directory, as a file_tools Source, for listing.
 * @param directory The shell's directory, which files are opened beneath.
 * @param path The directory's path beneath it; "" for itself.
 * @param depth How deep it is beneath the one searched, from 0; past MAX_DEPTH, nothing beneath it is searched.
 * @return False if what was found couldn't be written, which ends the search; true otherwise, also when a directory
 *     or a file couldn't be read, which is passed over.
 */
search_directory :: fn(search: ptr[mut Search], source: file_tools.Source, directory: os.Directory, path: string, depth: usize) -> bool {
    if depth > MAX_DEPTH {
        return true
    }
    entries : os.DirectoryEntry[..]
    defer file_tools.free_names(&entries)
    if file_tools.names_at(source, path, &entries) is_some {
        return true
    }
    for entry in entries {
        inner :: file_tools.joined(path, entry.name) or_continue
        defer strings.free_string(inner)
        if search.names {
            if regex.is_match(&search.pattern, entry.name) && !found(search, inner, 0, "") {
                return false
            }
        }
        else if !entry.is_directory && !search_file(search, directory, inner) {
            return false
        }
        if entry.is_directory && !search_directory(search, source, directory, inner, depth + 1) {
            return false
        }
    }
    return true
}

/**
 * Search a file's lines, unless it's typed or isn't text; with names, its name.
 *
 * @param search The search.
 * @param directory The shell's directory.
 * @param path The file's path beneath it.
 * @return False if what was found couldn't be written; true otherwise, also for a file that couldn't be read.
 */
search_file :: fn(search: ptr[mut Search], directory: os.Directory, path: string) -> bool {
    if search.names {
        if regex.is_match(&search.pattern, file_tools.last_name(path)) {
            return found(search, path, 0, "")
        }
        return true
    }
    file :: os.open_in(directory, path, .READ) or_return true
    defer os.close(file)
    size, schema, error :: os.file_info(file)
    if (error is_some) || !os.all_zero(schema) {
        return true
    }
    most :: if size < MAX_FILE_BYTES { size } else { MAX_FILE_BYTES }
    if most == 0 {
        return true
    }
    bytes, made :: runtime.new_array(u8, cast[usize](most))
    if made != null {
        return true
    }
    defer runtime.free_array(bytes)
    filled := cast[usize](0)
    loop {
        if filled >= bytes.count {
            break
        }
        count :: os.read(file, bytes[filled..<bytes.count]) or_return true
        if count == 0 {
            break
        }
        filled += count
    }
    if filled > bytes.count {
        return true
    }
    held :: bytes[0..<filled]
    for byte in held {
        if byte == 0 {
            return true
        }
    }
    // Each line, from start to the line feed or the end
    start := cast[usize](0)
    number := cast[u64](1)
    loop {
        if start >= held.count {
            break
        }
        end := start
        loop {
            if end >= held.count || held[end] == cast[u8]('\n') {
                break
            }
            end += 1
        }
        shown := end
        if shown > start && held[shown - 1] == cast[u8]('\r') {
            shown -= 1
        }
        line :: file_tools.string_of_view(string_of(&held[0], held.count), start, shown)
        if regex.is_match(&search.pattern, line) && !found(search, path, number, cut(line)) {
            return false
        }
        start = end + 1
        number += 1
    }
    return true
}

/**
 * Count what was found, and write it to the output, if there's one.
 *
 * @param search The search.
 * @param path Its path beneath the shell's directory, copied.
 * @param line The line's number, from 1; 0 for a name.
 * @param text The line, copied; empty for a name.
 * @return False if it couldn't be copied or written.
 */
found :: fn(search: ptr[mut Search], path: string, line: u64, text: string) -> bool {
    search.count += 1
    if !search.writing {
        return true
    }
    kept_path :: strings.clone(path) or_return false
    kept_text :: if text.count == 0 { "" } else { strings.clone(text) or_return false }
    return stream.write(&search.writer, Found.{path = kept_path, line = line, text = kept_text}) is_none
}

/**
 * Cut a line to at most MAX_TEXT_BYTES, at a grapheme cluster's start, so a character isn't split.
 *
 * @param line The line.
 * @return A view of its start: the whole line if it fits.
 */
cut :: fn(line: string) -> string {
    bytes :: string_bytes(line)
    if bytes.count <= MAX_TEXT_BYTES {
        return line
    }
    end := cast[usize](0)
    loop {
        next :: unicode.grapheme_end(bytes, end)
        if next <= end || next > MAX_TEXT_BYTES {
            break
        }
        end = next
    }
    return file_tools.string_of_view(line, 0, end)
}
