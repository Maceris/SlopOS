package disk_check

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import grant from "std/os/slop_os"
import log_line from "../../log_line"

/*
 * Stored links (roadmap 8f): the encrypted volume grants a directory, to write, and a file in it, to read, and the
 * system volume keeps both as links, one in a directory of its own. Through the system volume, a file is written into
 * the encrypted one through the first link, which the encrypted volume then reads, and both are read through their
 * links; the file's link refuses writing, and lists as a link. A directory opened through a link grants nothing and
 * lists no links: what it reached isn't the holder's to share. The encrypted volume lists what it issued, and revokes
 * the file's link, which then opens nothing; and a grant kept in its own volume is refused. Removing a link removes
 * only the link. Checks from 120.
 */

SHARED_DIRECTORY :: "shared"
SHARED_FILE :: "shared/note.txt"
SHARED_TEXT :: "Kept in the sealed volume, read through a link"
THROUGH_FILE :: "linked/from the system volume.txt"
THROUGH_TEXT :: "Written through a link in the system volume"
LANDED_FILE :: "shared/from the system volume.txt"

check_links :: fn(to: slop_os.DebugLog, manager: slop_os.Channel, port: slop_os.Port, system: os.Channel[dir.Dir], sealed: os.Channel[dir.Dir],
    container: u32) -> int {
    buffer := new_buffer() or_return 120
    budget :: slop_os.startup_block().budget
    system_port :: os.port_for(budget, system.end) or_return 120
    sealed_port :: os.port_for(budget, sealed.end) or_return 120
    into := os.Incoming.{}

    // What the sealed volume shares, granted
    if !made_directory(sealed.end, sealed_port, SHARED_DIRECTORY) || !write_new(sealed.end, sealed_port, SHARED_FILE, SHARED_TEXT, &buffer) {
        return 121
    }
    whole :: granted(sealed.end, sealed_port, SHARED_DIRECTORY, true) or_return 122
    note :: granted(sealed.end, sealed_port, SHARED_FILE, false) or_return 123

    // Kept as links in the system volume
    if !made_directory(system.end, system_port, "links") {
        return 124
    }
    match linked(system.end, system_port, "linked", whole) {
        case Done => {}
        case _ => return 125
    }
    match linked(system.end, system_port, "links/note", note) {
        case Done => {}
        case _ => return 126
    }

    // Written and read through them
    if !write_new(system.end, system_port, THROUGH_FILE, THROUGH_TEXT, &buffer) || !holds(sealed.end, sealed_port, LANDED_FILE, THROUGH_TEXT, &buffer) {
        return 127
    }
    if !holds(system.end, system_port, "linked/note.txt", SHARED_TEXT, &buffer) || !holds(system.end, system_port, "links/note", SHARED_TEXT, &buffer) {
        return 128
    }
    out := os.Outgoing.{}
    writing :: os.begin[dir.Request](&out)
    writing^ = .OpenFile(dir.OpenFile.{path = bytes_of(&out, "links/note"), creation = .Existing})
    match ask_dir(system.end, system_port, &out, &into) {
        case Failed(error) => {
            if error != .ReadOnly {
                return 129
            }
        }
        case _ => return 129
    }
    if !lists_link(system.end, system_port, "linked") {
        return 130
    }

    // What a link reached isn't its holder's to share
    out = os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "linked"), create = false})
    reached := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(system.end, system_port, &out, &into) {
        case OpenedDirectory(made) => reached = made
        case _ => return 131
    }
    reached_port :: os.port_for(budget, reached.end) or_return 131
    if !holds(reached.end, reached_port, "note.txt", SHARED_TEXT, &buffer) {
        return 132
    }
    out = os.Outgoing.{}
    regranting :: os.begin[dir.Request](&out)
    regranting^ = .Grant(dir.GrantOf.{path = bytes_of(&out, "note.txt"), write = false})
    match ask_dir(reached.end, reached_port, &out, &into) {
        case Failed(error) => {
            if error != .ReadOnly {
                return 133
            }
        }
        case Granted(made) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            return 133
        }
        case _ => return 133
    }
    out = os.Outgoing.{}
    listing :: os.begin[dir.Request](&out)
    listing^ = .Links(0)
    match ask_dir(reached.end, reached_port, &out, &into) {
        case Failed(error) => {
            if error != .ReadOnly {
                return 134
            }
        }
        case _ => return 134
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](reached_port))
    _ = slop_os.handle_close(cast[slop_os.Handle](reached.end))

    // Listed and revoked by the volume that issued them
    numbers : u64[2]
    cursor : u64 = 0
    for i in cast[usize](0)..<3 {
        out = os.Outgoing.{}
        asking :: os.begin[dir.Request](&out)
        asking^ = .Links(cursor)
        match ask_dir(sealed.end, sealed_port, &out, &into) {
            case Issued(link) => {
                path :: os.items(&into, link.path)
                expected :: if i == 0 { SHARED_DIRECTORY } else { SHARED_FILE }
                if i >= 2 || !same_text(path, expected) || link.write != (i == 0) {
                    return 135
                }
                if i < numbers.count {
                    numbers[i] = link.number
                }
                cursor = link.next
            }
            case End => {
                if i != 2 {
                    return 135
                }
            }
            case _ => return 135
        }
    }
    out = os.Outgoing.{}
    revoking :: os.begin[dir.Request](&out)
    revoking^ = .Revoke(numbers[1])
    match ask_dir(sealed.end, sealed_port, &out, &into) {
        case Done => {}
        case _ => return 136
    }
    out = os.Outgoing.{}
    reopening :: os.begin[dir.Request](&out)
    reopening^ = .OpenReadOnlyFile(bytes_of(&out, "links/note"))
    match ask_dir(system.end, system_port, &out, &into) {
        case Failed(error) => {
            if error != .Revoked {
                return 137
            }
        }
        case _ => return 137
    }
    if !holds(system.end, system_port, "linked/note.txt", SHARED_TEXT, &buffer) {
        return 138
    }

    // A grant kept in its own volume is refused
    own :: granted(system.end, system_port, "links", false) or_return 139
    match linked(system.end, system_port, "links/itself", own) {
        case Failed(error) => {
            if error != .InvalidPath {
                return 140
            }
        }
        case _ => return 140
    }

    // Removing a link removes only the link
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(bytes_of(&out, "links/note"))
    match ask_dir(system.end, system_port, &out, &into) {
        case Done => {}
        case _ => return 141
    }
    if !holds(sealed.end, sealed_port, SHARED_FILE, SHARED_TEXT, &buffer) {
        return 142
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](system_port))
    _ = slop_os.handle_close(cast[slop_os.Handle](sealed_port))
    log_line.write(to, "disk_check: links: the system volume wrote and read through two from the sealed one; what one reached granted nothing; one revoked opened nothing")
    return 0
}

// A directory at path made, or there already.
made_directory :: fn(end: slop_os.Channel, port: slop_os.Port, path: string) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, path), create = true})
    match ask_dir(end, port, &out, &into) {
        case OpenedDirectory(made) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            return true
        }
        case _ => return false
    }
}

// What's at path granted, to write as well if write.
granted :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, write: bool) -> os.Channel[grant.Grant]? {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    granting :: os.begin[dir.Request](&out)
    granting^ = .Grant(dir.GrantOf.{path = bytes_of(&out, path), write = write})
    match ask_dir(end, port, &out, &into) {
        case Granted(made) => return made
        case _ => return null
    }
}

// A grant kept as a link at path.
linked :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, given: os.Channel[grant.Grant]) -> dir.Response {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    linking :: os.begin[dir.Request](&out)
    linking^ = .Link(dir.LinkTo.{path = bytes_of(&out, path), grant = given})
    return ask_dir(end, port, &out, &into)
}

// Whether a directory's listing has name in it, as a link.
lists_link :: fn(end: slop_os.Channel, port: slop_os.Port, name: string) -> bool {
    into := os.Incoming.{}
    cursor : u64 = 0
    for i in 0..<64 {
        out := os.Outgoing.{}
        listing :: os.begin[dir.Request](&out)
        listing^ = .List(cursor)
        match ask_dir(end, port, &out, &into) {
            case Listed(entry) => {
                if same_text(os.items(&into, entry.name), name) {
                    return entry.kind == .Link
                }
                cursor = entry.next
            }
            case _ => return false
        }
    }
    return false
}
