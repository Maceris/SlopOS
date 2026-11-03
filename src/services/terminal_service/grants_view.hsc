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

USAGE_G : u16 : 0x0a
USAGE_TAB : u16 : 0x2b
MAX_GRANTS_SHOWN :: 16
GRANTS_ROW : u16 : 5

/** A grant kept: its issued record's number, what it reaches, and whether it may write. */
Kept :: struct {
    number : u64,
    path : u8[PATH_BYTES],
    count : usize,
    write : bool,
}

GrantsView :: struct {
    entries : Kept[MAX_GRANTS_SHOWN],
    count : usize,
    selected : usize,
}

/** The grants view, over the secure attention key's screen, for the active view's session. */
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

/** A key while the grants view's up. */
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

/** The links the home has issued, as many as are shown. */
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

/** A kept grant revoked: its issued record deleted, so its link opens nothing. */
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

/** One request on the home's connection, and its answer, waited for. */
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
 * Another connection to the directory end speaks for, its one end sent to its server, which takes it without answering.
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
