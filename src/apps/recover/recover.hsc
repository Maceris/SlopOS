/**
 * recover (decisions/0179): what's gone from the shell's directory found in the volume's recent snapshots, and brought
 * back. Nothing records what was removed: what a recent snapshot has, and the directory hasn't now, is what's offered,
 * and only beneath the directory it's given.
 */
package recover

import runtime from "base"
import memory from "std"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import stream from "std/os/slop_os"
import file_tools from "../../file_tools"

/** The most snapshots looked in, newest first: each is served to be read, which takes a while. */
MAX_LOOKED :: 8

/** Something gone from the directory, that a snapshot still has. */
Gone :: struct {
    /** Its name in the directory. */
    name : string,
    /** Whether it's a directory. */
    directory : bool,
    /** The newest snapshot that has it, which recover brings it back from. */
    snapshot : string,
}

/** What it brought back. */
Recovered :: struct {
    /** What it brought back, or how many things it found gone, when it was only looking. */
    name : string,
    /** The snapshot it came from; "" when it was only looking. */
    snapshot : string,
    /** How many files it wrote back. */
    files : u64,
    /** Their bytes. */
    bytes : memory.ByteCount,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: name, or here. */
    parameter : os.ParameterName,
}

/** Why it couldn't recover. */
RecoverError :: union {
    /** No recent snapshot has it, beneath this directory. */
    NotFound(Problem),
    /** Something's at the name now. */
    AlreadyThere(Problem),
    /** The volume's snapshots couldn't be listed or read. */
    NoSnapshots(Problem),
    /** It couldn't be written back; what was before it stays. */
    Failed(Problem),
}

/**
 * Find what's gone from the shell's directory that a recent snapshot of its volume still has, and bring it back: with a
 * name, that, from the newest snapshot that has it; without one, list what could be.
 *
 * @param here The shell's directory, given without asking, which it looks in and writes back to.
 * @param name What to bring back, beneath here: a file, or a directory, which comes back whole. Without it, nothing's
 *     brought back, and what could be is listed.
 * @param output Where what could be brought back goes, without a name: the shell, to show, or a pipeline. Without it,
 *     it's only counted.
 * @return What it brought back, and from which snapshot; or, without a name, how many things it found.
 * @error NotFound No recent snapshot has that here; recover lists what they have.
 * @error AlreadyThere Something's there now; move it away first.
 * @error NoSnapshots The volume's snapshots couldn't be read, or it has none.
 * @error Failed It couldn't be written back.
 */
main :: fn(here: os.Channel[dir.Dir], name: string?, output: os.Sink[Gone]?) -> Result[Recovered, RecoverError] {
    asked :: if name is_some { "name" } else { "here" }
    problem :: Problem.{parameter = os.ParameterName.{name = asked}}
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, here.end) or_return .Error(.Failed(problem))
    // A second connection to here, for what's there now, as std/os's Directory takes its connection over
    second :: dir.connect(here.end, port, budget) or_return .Error(.Failed(problem))
    directory, opened :: os.directory_on(second.end)
    if opened is_some {
        return .Error(.Failed(problem))
    }
    now :: file_tools.live_source(directory)
    seen : file_tools.Seen[..]
    defer file_tools.free_seen(&seen)
    if (file_tools.snapshots_of(here.end, &seen) is_some) || seen.count == 0 {
        return .Error(.NoSnapshots(problem))
    }
    match name {
        case Some(wanted) => return brought_back(here.end, directory, now, seen, wanted, problem)
        case None => return listed(here.end, now, seen, output, problem)
    }
}

/**
 * Bring back what's at a name from the newest of the snapshots looked in that has it.
 *
 * @param end here's connection, which snapshots are opened through.
 * @param directory here, written back to.
 * @param now here, as a Source, for what's there now.
 * @param seen The volume's snapshots, newest first.
 * @param wanted The name, beneath here.
 * @param problem The parameter, name.
 * @return What it brought back; NotFound, AlreadyThere or Failed.
 */
brought_back :: fn(end: slop_os.Channel, directory: os.Directory, now: file_tools.Source, seen: file_tools.Seen[..], wanted: string,
    problem: Problem) -> Result[Recovered, RecoverError] {
    if file_tools.kind_at(now, wanted) != .Missing {
        return .Error(.AlreadyThere(problem))
    }
    for each, i in seen {
        if i >= MAX_LOOKED {
            break
        }
        past :: file_tools.open_snapshot(end, each.name) or_continue
        defer file_tools.close_source(past)
        if file_tools.kind_at(past, wanted) == .Missing {
            continue
        }
        copied := file_tools.Copied.{}
        if file_tools.copy_tree(past, wanted, directory, wanted, file_tools.count_files(past, wanted), &copied) is_some {
            return .Error(.Failed(problem))
        }
        return .Ok(Recovered.{name = wanted, snapshot = each.name, files = copied.files, bytes = copied.bytes})
    }
    return .Error(.NotFound(problem))
}

/**
 * List what the snapshots looked in have, in here, that here hasn't now: each name once, with the newest snapshot that
 * has it.
 *
 * @param end here's connection, which snapshots are opened through.
 * @param now here, as a Source, for what's there now.
 * @param seen The volume's snapshots, newest first.
 * @param output Where each goes; without it, they're only counted.
 * @param problem The parameter, here.
 * @return How many it found, as a Recovered's name; Failed if they couldn't be written.
 */
listed :: fn(end: slop_os.Channel, now: file_tools.Source, seen: file_tools.Seen[..], output: os.Sink[Gone]?, problem: Problem)
    -> Result[Recovered, RecoverError] {
    writer := stream.Writer[Gone].{}
    writing := false
    match output {
        case Some(sink) => {
            writer = stream.writer_on(sink) or_return .Error(.Failed(problem))
            writing = true
        }
        case None => {}
    }
    found : string[..]
    for each, i in seen {
        if i >= MAX_LOOKED {
            break
        }
        past :: file_tools.open_snapshot(end, each.name) or_continue
        defer file_tools.close_source(past)
        names : os.DirectoryEntry[..]
        defer file_tools.free_names(&names)
        if file_tools.names_at(past, "", &names) is_some {
            continue
        }
        for entry in names {
            if already(found, entry.name) || file_tools.kind_at(now, entry.name) != .Missing {
                continue
            }
            kept :: file_tools.copy_of(string_bytes(entry.name)) or_continue
            runtime.array_add(&found, kept)
            if writing && (stream.write(&writer, Gone.{name = kept, directory = entry.is_directory, snapshot = each.name}) is_some) {
                return .Error(.Failed(problem))
            }
        }
    }
    if writing && (stream.finish(&writer, 0) is_some) {
        return .Error(.Failed(problem))
    }
    return .Ok(Recovered.{name = "", snapshot = "", files = cast[u64](found.count)})
}

/**
 * Tell whether a name's among those found already.
 *
 * @param found The names found.
 * @param name The name.
 * @return Whether it's there.
 */
already :: fn(found: string[..], name: string) -> bool {
    for each in found {
        if each == name {
            return true
        }
    }
    return false
}
