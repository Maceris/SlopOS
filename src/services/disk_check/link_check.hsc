package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import grant from "std/os/slop_os"

/*
 * Stored links (roadmap 8f): the encrypted volume grants a directory, to write, and a file in it, to read, and the
 * system volume keeps both as links, one in a directory of its own. Through the system volume, a file is written into
 * the encrypted one through the first link, which the encrypted volume then reads, and both are read through their
 * links; the file's link refuses writing, and lists as a link. A directory opened through a link grants nothing and
 * lists no links: what it reached isn't the holder's to share. The encrypted volume lists what it issued, and revokes
 * the file's link, which then opens nothing; and a grant kept in its own volume is followed as any other
 * (decisions/0158). Removing a link removes only the link. Checks from 120.
 */

/** The directory the encrypted volume makes and grants, to write, kept as the system volume's link "linked". */
SHARED_DIRECTORY :: "shared"
/** The file in it the encrypted volume grants, to read, kept as the system volume's link "links/note". */
SHARED_FILE :: "shared/note.txt"
/** What SHARED_FILE holds. */
SHARED_TEXT :: "Kept in the sealed volume, read through a link"
/** The file written in the system volume, through the link to SHARED_DIRECTORY. */
THROUGH_FILE :: "linked/from the system volume.txt"
/** What THROUGH_FILE is written with. */
THROUGH_TEXT :: "Written through a link in the system volume"
/** Where THROUGH_FILE lands in the encrypted volume. */
LANDED_FILE :: "shared/from the system volume.txt"

/**
 * Check stored links between the system volume and the encrypted one beside it.
 *
 * @param to The debug log; unused, as what's found is logged through runtime.
 * @param manager The connection to the storage manager; unused.
 * @param port A port bound to manager; unused.
 * @param system The system volume's root.
 * @param sealed The encrypted volume's root, unlocked.
 * @param container The container's partition index; unused.
 * @return 0 if all of it held; 120 if the buffer or a port couldn't be made, 121 to 123 if the encrypted volume's
 *     directory and file couldn't be made or granted, 124 to 126 if they couldn't be kept as links, 127 and 128 if
 *     writing or reading through them failed, 129 if the file's link didn't refuse writing as ReadOnly, 130 if the
 *     directory's link didn't list as one, 131 to 134 if a directory opened through a link granted or listed links,
 *     135 if the encrypted volume didn't list the two links it issued, 136 to 138 if revoking the file's link didn't
 *     work, or touched the other, 139 and 140 if a grant kept in its own volume couldn't be followed, and 141 and 142
 *     if removing a link failed or removed what it reached.
 */
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

    // A grant kept in its own volume, followed as any other
    own :: granted(system.end, system_port, "modules/hello.elf", false) or_return 139
    match linked(system.end, system_port, "links/itself", own) {
        case Done => {}
        case _ => return 140
    }
    out = os.Outgoing.{}
    following :: os.begin[dir.Request](&out)
    following^ = .OpenReadOnlyFile(bytes_of(&out, "links/itself"))
    match ask_dir(system.end, system_port, &out, &into) {
        case OpenedReadOnlyFile(made) => _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
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
    runtime.log_info("links: the system volume wrote and read through two from the sealed one; what one reached granted nothing; one revoked opened nothing; one into itself opened")
    return 0
}

/**
 * Make a directory, or find it there already.
 *
 * @param end The directory it's made beneath, speaking dir.
 * @param port A port bound to end.
 * @param path Its path beneath end.
 * @return Whether it's there; the connection opened to it is closed.
 */
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

/**
 * Ask a volume for a grant to what's at a path.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param path The file or directory's path beneath end.
 * @param write Whether the grant is to write as well as read.
 * @return The grant, which the caller owns, to keep as a link or close; null if it was refused.
 */
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

/**
 * Keep a grant as a link in a volume.
 *
 * @param end The directory it's kept beneath, speaking dir.
 * @param port A port bound to end.
 * @param path The link's path beneath end.
 * @param given The grant, which moves to the volume with the request.
 * @return The volume's answer: Done once it's kept; Unsupported if it couldn't be sent or the connection failed.
 */
linked :: fn(end: slop_os.Channel, port: slop_os.Port, path: string, given: os.Channel[grant.Grant]) -> dir.Response {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    linking :: os.begin[dir.Request](&out)
    linking^ = .Link(dir.LinkTo.{path = bytes_of(&out, path), grant = given})
    return ask_dir(end, port, &out, &into)
}

/**
 * Tell whether a directory lists a name as a link.
 *
 * @param end The directory, speaking dir.
 * @param port A port bound to end.
 * @param name The name looked for, compared byte for byte with each listed entry's.
 * @return Whether it's among the first 64 entries listed, and is a link; false if the listing fails first.
 */
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
