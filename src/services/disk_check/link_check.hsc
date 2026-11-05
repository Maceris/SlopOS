package disk_check

import os from "std"
import slop_os from "std/os"
import testing from "std"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import grant from "std/os/slop_os"
import test_kit from "../../test_kit"

/*
 * Stored links (roadmap 8f): the encrypted volume grants a directory, to write, and a file in it, to read, and the
 * system volume keeps both as links, one in a directory of its own. Through the system volume, a file is written into
 * the encrypted one through the first link, which the encrypted volume then reads, and both are read through their
 * links; the file's link refuses writing, and lists as a link. A directory opened through a link grants nothing and
 * lists no links: what it reached isn't the holder's to share. The encrypted volume lists what it issued, and revokes
 * the file's link, which then opens nothing; and a grant kept in its own volume is followed as any other
 * (decisions/0158). Removing a link removes only the link.
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
 * Check stored links between the system volume and the encrypted one beside it, which the sealed volume's test
 * unlocked.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the encrypted volume wasn't unlocked, the buffer or a port couldn't be made, or a
 *     step the rest builds on failed: making or granting what's shared, keeping it as links, opening what a link
 *     reached, or listing the links issued.
 */
links_reach_another_volume_and_grant_nothing_further #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    sealed :: testing.require_some(t, given.sealed, "the sealed volume's test, run before, unlocked the encrypted volume")?
    buffer :: buffer_of(t, given)?
    budget :: slop_os.startup_block().budget
    system_bound :: os.port_for(budget, system.end)
    system_port :: testing.require_some(t, system_bound, "the budget has room for a port")?
    sealed_bound :: os.port_for(budget, sealed.end)
    sealed_port :: testing.require_some(t, sealed_bound, "the budget has room for a port")?
    into := os.Incoming.{}

    // What the sealed volume shares, granted
    testing.require(t, made_directory(sealed.end, sealed_port, SHARED_DIRECTORY), "the encrypted volume makes a directory")?
    testing.require(t, write_new(sealed.end, sealed_port, SHARED_FILE, SHARED_TEXT, buffer), "the encrypted volume takes a new file")?
    granted_directory :: granted(sealed.end, sealed_port, SHARED_DIRECTORY, true)
    whole :: testing.require_some(t, granted_directory, "a volume grants a directory of its own, to write")?
    granted_file :: granted(sealed.end, sealed_port, SHARED_FILE, false)
    note :: testing.require_some(t, granted_file, "a volume grants a file of its own, to read")?

    // Kept as links in the system volume
    testing.require(t, made_directory(system.end, system_port, "links"), "the system volume makes a directory")?
    match linked(system.end, system_port, "linked", whole) {
        case Done => {}
        case _ => return stopped(t, "a volume keeps another's grant as a link")
    }
    match linked(system.end, system_port, "links/note", note) {
        case Done => {}
        case _ => return stopped(t, "a volume keeps another's grant as a link, in a directory of its own")
    }

    // Written and read through them
    testing.expect(t, write_new(system.end, system_port, THROUGH_FILE, THROUGH_TEXT, buffer),
        "a file is written through a link to a directory granted to write")
    testing.expect(t, holds(sealed.end, sealed_port, LANDED_FILE, THROUGH_TEXT, buffer),
        "a file written through a link lands in the volume that granted it")
    testing.expect(t, holds(system.end, system_port, "linked/note.txt", SHARED_TEXT, buffer), "a file reads through a link to its directory")
    testing.expect(t, holds(system.end, system_port, "links/note", SHARED_TEXT, buffer), "a file reads through a link to it")
    out := os.Outgoing.{}
    writing :: os.begin[dir.Request](&out)
    writing^ = .OpenFile(dir.OpenFile.{path = bytes_of(&out, "links/note"), creation = .Existing})
    match ask_dir(system.end, system_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .ReadOnly, "a link to a file granted to read opens nothing to write")
        case _ => testing.fail(t, "a link to a file granted to read opens nothing to write")
    }
    testing.expect(t, lists_link(system.end, system_port, "linked"), "a link lists as a link in its directory")

    // What a link reached isn't its holder's to share
    out = os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "linked"), create = false})
    reached := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask_dir(system.end, system_port, &out, &into) {
        case OpenedDirectory(made) => reached = made
        case _ => return stopped(t, "a link to a directory opens as a directory")
    }
    reached_bound :: os.port_for(budget, reached.end)
    reached_port :: testing.require_some(t, reached_bound, "the budget has room for a port")?
    testing.expect(t, holds(reached.end, reached_port, "note.txt", SHARED_TEXT, buffer), "a directory opened through a link reads its files")
    out = os.Outgoing.{}
    regranting :: os.begin[dir.Request](&out)
    regranting^ = .Grant(dir.GrantOf.{path = bytes_of(&out, "note.txt"), write = false})
    match ask_dir(reached.end, reached_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .ReadOnly, "what a link reached grants nothing: it isn't the holder's to share")
        case Granted(made) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            testing.fail(t, "what a link reached grants nothing: it isn't the holder's to share")
        }
        case _ => testing.fail(t, "what a link reached grants nothing: it isn't the holder's to share")
    }
    out = os.Outgoing.{}
    listing :: os.begin[dir.Request](&out)
    listing^ = .Links(0)
    match ask_dir(reached.end, reached_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .ReadOnly, "what a link reached lists no links: they're its volume's, not the holder's")
        case _ => testing.fail(t, "what a link reached lists no links: they're its volume's, not the holder's")
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
                testing.require_lt(t, i, 2, "the encrypted volume issued two links, so it lists two")?
                testing.expect(t, same_text(path, expected), "a volume lists the links it issued in the order it issued them, by path")
                testing.expect_eq(t, link.write, i == 0, "a volume lists whether each link it issued may write: the directory's, not the file's")
                if i < numbers.count {
                    numbers[i] = link.number
                }
                cursor = link.next
            }
            case End => testing.expect_eq(t, i, 2, "the encrypted volume issued two links, so it lists two")
            case _ => return stopped(t, "a volume lists the links it issued")
        }
    }
    out = os.Outgoing.{}
    revoking :: os.begin[dir.Request](&out)
    revoking^ = .Revoke(numbers[1])
    match ask_dir(sealed.end, sealed_port, &out, &into) {
        case Done => {}
        case _ => testing.fail(t, "a volume revokes a link it issued, by its number")
    }
    out = os.Outgoing.{}
    reopening :: os.begin[dir.Request](&out)
    reopening^ = .OpenReadOnlyFile(bytes_of(&out, "links/note"))
    match ask_dir(system.end, system_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .Revoked, "a link revoked opens nothing")
        case _ => testing.fail(t, "a link revoked opens nothing")
    }
    testing.expect(t, holds(system.end, system_port, "linked/note.txt", SHARED_TEXT, buffer), "revoking one link leaves the others working")

    // A grant kept in its own volume, followed as any other
    granted_own :: granted(system.end, system_port, "modules/hello.elf", false)
    own :: testing.require_some(t, granted_own, "a volume grants a file of its own, to read")?
    match linked(system.end, system_port, "links/itself", own) {
        case Done => {}
        case _ => return stopped(t, "a volume keeps a grant of its own as a link")
    }
    out = os.Outgoing.{}
    following :: os.begin[dir.Request](&out)
    following^ = .OpenReadOnlyFile(bytes_of(&out, "links/itself"))
    match ask_dir(system.end, system_port, &out, &into) {
        case OpenedReadOnlyFile(made) => _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
        case _ => testing.fail(t, "a link a volume keeps to itself is followed as any other")
    }

    // Removing a link removes only the link
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(bytes_of(&out, "links/note"))
    match ask_dir(system.end, system_port, &out, &into) {
        case Done => {}
        case _ => testing.fail(t, "a link is removed as a file is")
    }
    testing.expect(t, holds(sealed.end, sealed_port, SHARED_FILE, SHARED_TEXT, buffer), "removing a link leaves what it reached")
    _ = slop_os.handle_close(cast[slop_os.Handle](system_port))
    _ = slop_os.handle_close(cast[slop_os.Handle](sealed_port))
    return .Ok
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
