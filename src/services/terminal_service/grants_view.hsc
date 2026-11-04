/**
 * The grants view (decisions/0158), on the trusted path: from the secure attention key's screen, G lists the links the
 * session's home has issued, the grants its user has let programs keep through the powerbox, each with what it reaches
 * and whether it may write. Delete revokes the one chosen, which then opens nothing; Escape goes back to the screen. It
 * reads the home through a connection of its own, made when the session is.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import terminal from "std/os/slop_os"
import dir from "std/os/slop_os"
import screen from "../../screen"

/** The USB HID usage of the G key, which opens the grants view from the secure attention key's screen. */
USAGE_G : u16 : 0x0a
/** The USB HID usage of the Tab key, which ticks the chooser's "keep for next time". */
USAGE_TAB : u16 : 0x2b
/** The most kept grants the view lists; the home's links past these aren't shown, and can't be revoked here. */
MAX_GRANTS_SHOWN :: 16
/** The panel row the grants view's first grant is drawn on. */
GRANTS_ROW : u16 : 5

/** A grant kept: its issued record's number, what it reaches, and whether it may write. */
Kept :: struct {
    /** The number of the link's issued record in the home, which Revoke takes. */
    number : u64,
    /** The path beneath the home the link reaches, its first count bytes; a longer path is cut short. */
    path : u8[PATH_BYTES],
    /** How many bytes of path are used, 0 to PATH_BYTES. */
    count : usize,
    /** Whether the link may write, rather than only read. */
    write : bool,
}

/** The grants view's state: the kept grants listed from the home, and the one chosen. */
GrantsView :: struct {
    /** The kept grants, in the order the home lists them; the first count are used. */
    entries : Kept[MAX_GRANTS_SHOWN],
    /** How many of entries are used, 0 to MAX_GRANTS_SHOWN. */
    count : usize,
    /** The index in entries of the grant chosen, which Delete revokes; 0 when there are none. */
    selected : usize,
}

/**
 * Open the grants view over the secure attention key's screen, for the active view's session, listing what its user
 * has let programs keep.
 *
 * Nothing happens without a connection to the session's home (a session with no user has none). Keys go to grants_key
 * until Escape or Enter goes back.
 *
 * @param service The service, its secure attention key's screen up.
 */
enter_grants :: fn(service: ptr[mut Service]) {
    if view(service).home_end == NONE {
        return void
    }
    service.granting = true
    service.grants = GrantsView.{}
    runtime.log_info("showing what programs may keep")
    list_grants(service)
    draw_grants(service)
}

/**
 * Take a key while the grants view is up: Up and Down choose, Delete revokes the grant chosen and lists them again,
 * Escape or Enter goes back to the secure attention key's screen. Other keys are ignored.
 *
 * @param service The service, its grants view up.
 * @param event The key, by its USB HID usage; its modifiers aren't looked at.
 */
grants_key :: fn(service: ptr[mut Service], event: terminal.Event) {
    grants :: &service.grants
    if event.code == USAGE_ESCAPE || event.code == USAGE_ENTER {
        service.granting = false
        draw_panel(service)
    }
    else if event.code == USAGE_UP && grants.selected > 0 {
        grants.selected -= 1
        draw_grants(service)
    }
    else if event.code == USAGE_DOWN && grants.selected + 1 < grants.count {
        grants.selected += 1
        draw_grants(service)
    }
    else if event.code == USAGE_DELETE && grants.selected < grants.count && grants.selected < grants.entries.count {
        revoke(service, grants.entries[grants.selected])
        list_grants(service)
        if grants.selected >= grants.count && grants.selected > 0 {
            grants.selected = grants.count - 1
        }
        draw_grants(service)
    }
}

/**
 * List the links the active view's home has issued into service.grants, up to MAX_GRANTS_SHOWN of them.
 *
 * Each is asked for in turn (Links, from a cursor), the answer waited for, on a port made for the home's connection and
 * closed after; the list stops at the first answer that isn't Issued. A home that can't be reached leaves it empty.
 *
 * @param service The service, whose active view has a home connection.
 */
list_grants :: fn(service: ptr[mut Service]) {
    grants :: &service.grants
    grants.count = 0
    home :: view(service).home_end
    port :: os.port_for(slop_os.startup_block().budget, home) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    cursor := cast[u64](0)
    loop {
        at :: grants.count
        if at >= grants.entries.count {
            break
        }
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Links(cursor)
        into := os.Incoming.{}
        match ask_home(home, port, &out, &into) {
            case Issued(link) => {
                made := Kept.{number = link.number, write = link.write}
                made.count = copy_bytes(os.items(&into, link.path), made.path[0..<made.path.count])
                grants.entries[at] = made
                grants.count = at + 1
                cursor = link.next
            }
            case _ => break
        }
    }
}

/**
 * Revoke a kept grant: ask the active view's home to delete its issued record (Revoke), so its link opens nothing, and
 * wait for the answer.
 *
 * Whether it worked is only logged; the caller lists the grants again to see.
 *
 * @param service The service, whose active view has a home connection.
 * @param kept The grant, as listed; only its number is sent.
 */
revoke :: fn(service: ptr[mut Service], kept: Kept) {
    home :: view(service).home_end
    port :: os.port_for(slop_os.startup_block().budget, home) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Revoke(kept.number)
    into := os.Incoming.{}
    match ask_home(home, port, &out, &into) {
        case Done => runtime.log_info("revoked a kept grant of %", bytes_text(first_of(kept.path[0..<kept.path.count], kept.count)))
        case _ => runtime.log_info("couldn't revoke a kept grant")
    }
}

/**
 * Draw the grants view on the active view's panel: each kept grant's path and whether it may write, the chosen one
 * inverse, and the keys.
 *
 * @param service The service, its grants view up.
 */
draw_grants :: fn(service: ptr[mut Service]) {
    screen.show_panel(&view(service).screen, true)
    panel :: &view(service).screen.panel
    grants :: &service.grants
    plain :: terminal.Style.{}
    screen.write_at(panel, 1, 2, "What programs may keep", terminal.Style.{attributes = terminal.BOLD})
    screen.write_at(panel, 3, 2, "What you've let programs keep for next time, from your home:", plain)
    if grants.count == 0 {
        screen.write_at(panel, GRANTS_ROW, 2, "Nothing is kept.", plain)
    }
    for &kept, i in grants.entries {
        if i >= grants.count {
            break
        }
        storage : u8[PATH_BYTES + 32]
        line := text_buffer.make(storage)
        text_buffer.append(&line, bytes_text(first_of(kept.path[0..<kept.path.count], kept.count)))
        text_buffer.append(&line, if kept.write { "   may write" } else { "   may read" })
        screen.write_at(panel, GRANTS_ROW + cast[u16](i), 4, text_buffer.as_string(&line),
            if i == grants.selected { terminal.Style.{attributes = terminal.INVERSE} } else { plain })
    }
    screen.write_at(panel, GRANTS_ROW + cast[u16](MAX_GRANTS_SHOWN) + 1, 2, "Up and Down choose, Delete revokes the one chosen, Esc goes back.", plain)
    redraw(service)
}

/**
 * Send one request on a home's directory connection and wait, with no deadline, for its answer.
 *
 * @param end The directory connection, which stays the caller's.
 * @param port A port for end, the caller's, which the answer is waited on.
 * @param out The request, built by the caller; handles in it move to the server once it's sent.
 * @param into Where the answer's message is received; its items, such as names, stay readable there until into is
 *     used again.
 * @return The answer; Unsupported also when the request couldn't be sent or the connection failed.
 */
ask_home :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/**
 * Make another connection to the directory end speaks for: a new channel, one end sent to its server (Connect), which
 * takes it without answering.
 *
 * @param end A directory connection, which stays the caller's and isn't changed.
 * @return The new connection's other end, the caller's to close; null if no port or channel could be made or Connect
 *     couldn't be sent.
 */
another_connection :: fn(end: slop_os.Channel) -> slop_os.Channel? {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    pair :: os.channel_for[dir.Dir](budget, 0) or_return null
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Connect(os.Channel[dir.Dir].{end = pair.a})
    if dir.send_request(end, port, &out) is_some {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return pair.b
}
