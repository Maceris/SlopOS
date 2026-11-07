/**
 * list (decisions/0179): a directory's entries, as records for the shell to show or a pipeline to take.
 */
package list

import memory from "std"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import stream from "std/os/slop_os"
import file_tools from "../../file_tools"

/** What an entry is. */
EntryKind :: enum {
    /** A file, of bytes or a typed value. */
    File,
    /** A directory. */
    Directory,
    /** A stored link into another volume. */
    Link,
}

/** One entry of the directory. */
Entry :: struct {
    /** Its name. */
    name : string,
    /** What it is. */
    kind : EntryKind,
    /** Its size in bytes; a directory's is 0. */
    size : memory.ByteCount,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: path, or here for the shell's directory. */
    parameter : os.ParameterName,
}

/** Why it couldn't list. */
ListError :: union {
    /** Nothing's at the path. */
    NotFound(Problem),
    /** What's at the path isn't a directory. */
    NotADirectory(Problem),
    /** The directory couldn't be read. */
    Unreadable(Problem),
}

/**
 * List a directory's entries, each a record of its name, what it is and its size.
 *
 * @param here The shell's directory, given without asking, which path is beneath.
 * @param path The directory to list, beneath here; without it, here itself.
 * @param all Whether to list the entries whose names start with a dot too, which are left out without it.
 * @param output Where the entries go: the shell, to show them, or what comes after it in a pipeline. Without it, they're
 *     only counted.
 * @return How many entries it listed.
 * @error NotFound There's nothing at that path; list a directory that's there.
 * @error NotADirectory That's a file; list the directory it's in.
 * @error Unreadable The directory couldn't be read, or its entries written.
 */
main :: fn(here: os.Channel[dir.Dir], path: string?, all: bool, output: os.Sink[Entry]?) -> Result[u64, ListError] {
    asked :: if path is_some { "path" } else { "here" }
    problem :: Problem.{parameter = os.ParameterName.{name = asked}}
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, here.end) or_return .Error(.Unreadable(problem))
    end := here.end
    // The directory beneath here, if one's asked for
    match path {
        case Some(given) => {
            out := os.Outgoing.{}
            // begin's pointer first: the append on the right would otherwise land before the message
            request :: os.begin[dir.Request](&out)
            request^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, string_bytes(given))})
            into := os.Incoming.{}
            if !file_tools.ask_dir(here.end, port, &out, &into) {
                return .Error(.Unreadable(problem))
            }
            match os.message_of[dir.Response](&into)^ {
                case OpenedDirectory(made) => end = made.end
                case Failed(error) => return .Error(listing_error(error, problem))
                case _ => return .Error(.Unreadable(problem))
            }
        }
        case None => {}
    }
    listing_port :: os.port_for(budget, end) or_return .Error(.Unreadable(problem))
    writer := stream.Writer[Entry].{}
    writing := false
    match output {
        case Some(sink) => {
            writer = stream.writer_on(sink) or_return .Error(.Unreadable(problem))
            writing = true
        }
        case None => {}
    }
    count := cast[u64](0)
    cursor := cast[u64](0)
    loop {
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .List(cursor)
        into := os.Incoming.{}
        if !file_tools.ask_dir(end, listing_port, &out, &into) {
            return .Error(.Unreadable(problem))
        }
        match os.message_of[dir.Response](&into)^ {
            case Listed(listed) => {
                cursor = listed.next
                name :: file_tools.copy_of(os.items(&into, listed.name)) or_return .Error(.Unreadable(problem))
                first :: string_bytes(name)
                if first.count == 0 || (!all && first[0] == cast[u8]('.')) {
                    continue
                }
                entry :: Entry.{name = name, kind = kind_of(listed.kind), size = cast[memory.ByteCount](listed.size)}
                count += 1
                if writing && (stream.write(&writer, entry) is_some) {
                    return .Error(.Unreadable(problem))
                }
            }
            case End => break
            case Failed(error) => return .Error(listing_error(error, problem))
            case _ => return .Error(.Unreadable(problem))
        }
    }
    if writing && (stream.finish(&writer, 0) is_some) {
        return .Error(.Unreadable(problem))
    }
    return .Ok(count)
}

/**
 * Say what an entry is, as a record has it.
 *
 * @param kind What the directory said it is.
 * @return The same, as EntryKind.
 */
kind_of :: fn(kind: files.Kind) -> EntryKind {
    return match kind {
        case .File => EntryKind.File
        case .Directory => EntryKind.Directory
        case .Link => EntryKind.Link
    }
}

/**
 * Say why a directory couldn't be listed, as list's error.
 *
 * @param error What the directory answered.
 * @param problem The parameter it came from.
 * @return NotFound, NotADirectory, or Unreadable for anything else.
 */
listing_error :: fn(error: files.FileError, problem: Problem) -> ListError {
    return match error {
        case .NotFound => ListError.NotFound(problem)
        case .NotADirectory => ListError.NotADirectory(problem)
        case _ => ListError.Unreadable(problem)
    }
}
