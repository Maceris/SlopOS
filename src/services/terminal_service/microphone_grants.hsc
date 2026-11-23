/**
 * The microphone on the console's trusted path (decisions/0196, 17f): once the user allows a program the microphone on
 * the elevation screen, the terminal service has the audio service make a grant, through a microphone connection the
 * supervisor makes for it (power's MicrophoneConnection), and gives the program the grant's sound connection. While any
 * grant's held, the status line says who holds it, in every view; M on the secure attention key's screen takes every
 * grant back, the audio service closing each one's connection. A grant's gone once the program lets it go, or it's
 * taken back, which the audio service says (WaitReleased).
 */
package terminal_service

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import terminal from "std:os/slop_os/terminal"
import text_buffer from "std:text_buffer"
import microphone from "../../protocols/microphone"
import power as power_protocol from "../../protocols/power"
import sound from "../../protocols/sound"
import screen from "../../screen"

/** The port key the microphone connection is bound under, above the clients'. */
MICROPHONE_KEY : u64 : 1003
/** The most grants held at once that the console shows; another's refused. */
MAX_HOLDERS :: 4
/** The most bytes of a holder's name kept. */
HOLDER_NAME_BYTES :: 32
/** The USB HID usage of M, which takes the microphone back on the secure attention key's screen. */
USAGE_M : u16 : 0x10

/** A grant of the microphone, held by a program. */
Holder :: struct {
    /** The grant's id, as the audio service gave it. */
    id : u32,
    /** The program's name, as its powerbox gave it, the first count bytes; cut at HOLDER_NAME_BYTES. */
    name : u8[HOLDER_NAME_BYTES],
    count : usize,
}

/** The microphone's state on the console. */
Microphone :: struct {
    /** The microphone connection to the audio service, bound under MICROPHONE_KEY; NONE until it's first needed. */
    end : slop_os.Channel,
    /** The grants held, the first count of them. */
    holders : Holder[MAX_HOLDERS],
    count : usize,
}

/**
 * The microphone connection, asked of the supervisor the first time, and again once it's gone.
 *
 * @param service The service, whose power connection is asked; the connection's kept in its microphone state.
 * @return Its end; null without a power connection, an audio service, or a port binding.
 */
microphone_end :: fn(service : ptr[mut Service]) -> slop_os.Channel? {
    if service.microphone.end != NONE {
        return service.microphone.end
    }
    connection :: service.power or_return null
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[power_protocol.Request](&out)^ = .MicrophoneConnection
    if power_protocol.send_request(connection.end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    match power_protocol.receive_response(connection.end, port, &into, true) {
        case Received => {}
        case _ => return null
    }
    given :: match os.message_of[power_protocol.Response](&into)^ {
        case MicrophoneConnection(made) => made
        case _ => return null
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](given.end), signals, MICROPHONE_KEY, .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
        return null
    }
    service.microphone.end = given.end
    return given.end
}

/**
 * Have the audio service make a grant of the microphone for a program the user's allowed it, waiting for the answer,
 * and show it held.
 *
 * @param service The service; the grant's kept among its holders, and a WaitReleased sent for it.
 * @param requester The program's name, as its powerbox gave it.
 * @return The grant's sound connection, for the program; null without a microphone connection, with MAX_HOLDERS held,
 *     or if the audio service refused, as without a sound device.
 */
grant_microphone :: fn(service : ptr[mut Service], requester : u8[]) -> os.Channel[sound.Sound]? {
    if service.microphone.count >= MAX_HOLDERS {
        runtime.log_info("microphone: held by as many as it may be")
        return null
    }
    end :: microphone_end(service) or_return null
    port :: os.port_for(slop_os.startup_block().budget, end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[microphone.Request](&out)^ = .Grant
    if microphone.send_request(end, port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    found : microphone.Granted? = null
    loop {
        match microphone.receive_response(end, port, &into, true) {
            case Received => {}
            case _ => {
                microphone_gone(service)
                return null
            }
        }
        // A grant let go meanwhile is said first, and a Revoke's answers, a grant gone already NoGrant, aren't Grant's
        match os.message_of[microphone.Response](&into)^ {
            case Granted(made) => found = made
            case Released(id) => released(service, id)
            case Revoked => {}
            case Refused(why) => if why != .NoGrant {
                runtime.log_info("microphone: the audio service refused")
                return null
            }
            case _ => {
                runtime.log_info("microphone: the audio service refused")
                return null
            }
        }
    }
    while found is_none
    granted :: found or_return null
    holder := Holder.{id = granted.id}
    for byte, i in requester {
        if i < holder.name.count {
            holder.name[i] = byte
            holder.count = i + 1
        }
    }
    if service.microphone.count < service.microphone.holders.count {
        service.microphone.holders[service.microphone.count] = holder
        service.microphone.count += 1
    }
    watching := os.Outgoing.{}
    os.begin[microphone.Request](&watching)^ = .WaitReleased(granted.id)
    _ = microphone.send_request(end, port, &watching)
    runtime.log_info("microphone: % holds it", bytes_text(requester))
    update_status(service)
    return granted.end
}

/**
 * Take what the audio service has said on the microphone connection: each grant gone is shown gone. If the connection's
 * gone, as when the audio service is, so is every grant, closed with it.
 *
 * @param service The service, from its main loop.
 * @param into Where each answer is received.
 */
take_microphone :: fn(service : ptr[mut Service], into : ptr[mut os.Incoming]) {
    if service.microphone.end == NONE {
        return void
    }
    loop {
        match microphone.receive_response(service.microphone.end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                microphone_gone(service)
                return void
            }
        }
        match os.message_of[microphone.Response](into)^ {
            case Released(id) => released(service, id)
            case _ => {}
        }
    }
}

/**
 * The microphone connection's gone: closed, and every grant shown gone, as the audio service closes them with it.
 *
 * @param service The service.
 */
microphone_gone :: fn(service : ptr[mut Service]) {
    if service.microphone.end != NONE {
        _ = slop_os.port_unbind(service.port, MICROPHONE_KEY)
        _ = slop_os.handle_close(cast[slop_os.Handle](service.microphone.end))
        service.microphone.end = NONE
    }
    if service.microphone.count > 0 {
        service.microphone.count = 0
        runtime.log_info("microphone: the audio service is gone, and every grant with it")
        microphone_changed(service)
    }
}

/**
 * A grant's gone: no longer shown held.
 *
 * @param service The service.
 * @param id The grant's id.
 */
released :: fn(service : ptr[mut Service], id : u32) {
    state :: &service.microphone
    for i in 0..<state.count {
        if i >= state.holders.count || state.holders[i].id != id {
            continue
        }
        gone :: state.holders[i]
        runtime.log_info("microphone: % no longer holds it", bytes_text(first_of(gone.name[0..<gone.name.count], gone.count)))
        for k in i..<state.count {
            next :: k + 1
            if next < state.count && k < state.holders.count && next < state.holders.count {
                state.holders[k] = state.holders[next]
            }
        }
        state.count -= 1
        microphone_changed(service)
        return void
    }
}

/**
 * Take every grant back, for M on the secure attention key's screen: the audio service closes each one's connection,
 * and says each gone (take_microphone).
 *
 * @param service The service.
 */
take_back_microphone :: fn(service : ptr[mut Service]) {
    end :: service.microphone.end
    if end == NONE || service.microphone.count == 0 {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    for holder, i in service.microphone.holders {
        if i >= service.microphone.count {
            break
        }
        runtime.log_info(
            "microphone: the user took it back from %",
            bytes_text(first_of(holder.name[0..<holder.name.count], holder.count))
        )
        out := os.Outgoing.{}
        os.begin[microphone.Request](&out)^ = .Revoke(holder.id)
        _ = microphone.send_request(end, port, &out)
    }
}

/**
 * Show what's changed of who holds the microphone: the status line, and the secure attention key's panel if it's up.
 *
 * @param service The service.
 */
microphone_changed :: fn(service : ptr[mut Service]) {
    update_status(service)
    if service.attention && !service.choosing && !service.granting && service.setup == .Off {
        draw_panel(service)
    }
}

/**
 * Add who holds the microphone to a status line: " │ microphone: " and their names, if any does.
 *
 * @param service The service.
 * @param status The status line so far.
 */
append_microphone :: fn(service : ptr[mut Service], status : ptr[mut text_buffer.TextBuffer]) {
    state :: &service.microphone
    if state.count == 0 {
        return void
    }
    text_buffer.append(status, " │ microphone: ")
    for holder, i in state.holders {
        if i >= state.count {
            break
        }
        if i > 0 {
            text_buffer.append(status, ", ")
        }
        text_buffer.append(status, bytes_text(first_of(holder.name[0..<holder.name.count], holder.count)))
    }
}

/**
 * Say on the secure attention key's panel who holds the microphone, and that M takes it back.
 *
 * @param service The service, its panel being drawn.
 * @param row The panel's row to say it on.
 */
draw_microphone :: fn(service : ptr[mut Service], row : u16) {
    state :: &service.microphone
    if state.count == 0 {
        return void
    }
    storage : u8[160]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "M takes the microphone back from ")
    for holder, i in state.holders {
        if i >= state.count {
            break
        }
        if i > 0 {
            text_buffer.append(&line, ", ")
        }
        text_buffer.append(&line, bytes_text(first_of(holder.name[0..<holder.name.count], holder.count)))
    }
    text_buffer.append(&line, ".")
    screen.write_at(&view(service).screen.panel, row, 2, text_buffer.as_string(&line), terminal.Style.{})
}
