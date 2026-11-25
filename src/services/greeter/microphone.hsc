package greeter

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import text_buffer from "std:text_buffer"
import ui from "std:ui"
import gui_kit from "../../gui_kit"
import microphone as microphone_protocol from "../../protocols/microphone"
import power as power_protocol from "../../protocols/power"
import prompt from "../../protocols/prompt"
import session from "../../protocols/session"
import sound from "../../protocols/sound"
import surface from "../../protocols/surface"

/*
 * Sound in the GUI's trusted layer (decisions/0196, 17f and 17g): the sound window, passive, in the screen's top right
 * corner, never taking the keyboard, shown while the GUI session runs or the microphone's held.
 *
 * The microphone: once the user allows a program it in the prompt, the greeter has the audio service make a grant,
 * through a microphone connection the supervisor makes for it (power's MicrophoneConnection), and answers with the
 * grant's sound connection. While any grant's held, the sound window says who holds it, below the volume, and its "Take
 * it back" takes every grant back, the audio service closing each one's connection. A grant's gone once the program
 * lets it go, or it's taken back, which the audio service says (WaitReleased). Each holding program's windows are
 * marked on their identity bands too: the compositor's told the holders' names (MicrophoneHeld), which are the names
 * the session manager gave the programs' powerbox and compositor connections alike, from their launch (decisions/0197,
 * N1). Two running copies of one program share a name, so both are marked while either holds it.
 *
 * The session's volume: the sound window's - and + turn it down and up a tenth, the session manager setting it on the
 * session's sound (session's SetVolume).
 */

/** The sound window's width, in pixels. */
SOUND_WIDTH : u32 : 300
/** Its height: the microphone's row and the volume's. */
SOUND_HEIGHT : u32 : 110
/** How much - and + change the session's volume by: a tenth of full. */
VOLUME_STEP : u16 : 100
/** The most grants held at once; another's refused. */
MAX_HOLDERS :: 4
/** The most bytes of a holder's name kept. */
HOLDER_NAME_BYTES :: 32

/** A grant of the microphone, held by a program. */
Holder :: struct {
    /** The grant's id, as the audio service gave it. */
    id : u32,
    /** The program's name, as its powerbox gave it, the first count bytes; cut at HOLDER_NAME_BYTES. */
    name : u8[HOLDER_NAME_BYTES],
    count #at_most(name.count) : usize,
}

/** The microphone's state in the GUI. */
Microphone :: struct {
    /** The microphone connection to the audio service; NO_HANDLE until it's first needed. */
    end : slop_os.Channel,
    /** A port bound to end, waited on for its answers. */
    port : slop_os.Port,
    /** The grants held, the first count of them. */
    holders : Holder[MAX_HOLDERS],
    count #at_most(holders.count) : usize,
    /** The sound window, passive, in the trusted layer; null until it's first needed. */
    window : ptr[mut gui_kit.Window]?,
    /** The GUI session's volume, as last set: 0 to sound.FULL_VOLUME, full when the session starts. */
    volume : u16,
}

/**
 * The microphone connection, asked of the supervisor the first time, and again once it's gone.
 *
 * @param greeter The greeter, whose power connection is asked; the connection's kept in its microphone state.
 * @return Its end; null without a power connection or an audio service.
 */
microphone_end :: fn(greeter : ptr[mut Greeter]) -> slop_os.Channel? {
    state :: &greeter.microphone
    if cast[slop_os.Handle](state.end) != slop_os.NO_HANDLE {
        return state.end
    }
    connection :: greeter.power or_return null
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
    made_port :: os.port_for(slop_os.startup_block().budget, given.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](made_port) == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
        return null
    }
    state.end = given.end
    state.port = made_port
    return given.end
}

/**
 * The user allowed the microphone in the prompt: have the audio service make a grant, answer with its connection, or
 * Refused if it couldn't be made, and let go of what was asked.
 *
 * @param greeter The greeter, the microphone asked for.
 */
answer_microphone :: fn(greeter : ptr[mut Greeter]) {
    out := os.Outgoing.{}
    response :: os.begin[prompt.Response](&out)
    match grant_microphone(greeter, ui.contents(&greeter.asking.requester)) {
        case Some(connection) => {
            response^ = .MicrophoneGranted(connection)
            runtime.log_info("allowed % the microphone", text(&greeter.asking.requester))
        }
        case None => {
            response^ = .Refused
            runtime.log_info("couldn't give % the microphone", text(&greeter.asking.requester))
        }
    }
    _ = prompt.send_response(greeter.prompts, greeter.prompts_port, &out)
    drop_asking(greeter)
}

/**
 * Have the audio service make a grant of the microphone, waiting for the answer, and show it held.
 *
 * @param greeter The greeter; the grant's kept among its holders, and a WaitReleased sent for it.
 * @param requester The program's name, as its powerbox gave it.
 * @return The grant's sound connection, for the program; null without a microphone connection, with MAX_HOLDERS held,
 *     without the sound window to show it held, or if the audio service refused.
 */
grant_microphone :: fn(greeter : ptr[mut Greeter], requester : u8[]) -> os.Channel[sound.Sound]? {
    state :: &greeter.microphone
    if state.count >= MAX_HOLDERS {
        return null
    }
    // Nothing's held that can't be shown held
    if sound_window(greeter) is_none {
        runtime.log_info("microphone: refused, as the sound window couldn't be made to show it held")
        return null
    }
    end :: microphone_end(greeter) or_return null
    out := os.Outgoing.{}
    os.begin[microphone_protocol.Request](&out)^ = .Grant
    if microphone_protocol.send_request(end, state.port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    found : microphone_protocol.Granted? = null
    deadline :: (slop_os.clock_monotonic() or_else 0) + ANSWER_LIMIT
    loop {
        // Within ANSWER_LIMIT, or the connection's let go, every grant with it, as the audio service closes them (N3)
        match microphone_protocol.receive_response(end, state.port, &into, true, deadline) {
            case Received => {}
            case Empty => {
                runtime.log_info("microphone: the audio service didn't answer in time")
                microphone_gone(greeter)
                return null
            }
            case _ => {
                microphone_gone(greeter)
                return null
            }
        }
        // A grant let go meanwhile is said first, and a Revoke's answers, a grant gone already NoGrant, aren't Grant's
        match os.message_of[microphone_protocol.Response](&into)^ {
            case Granted(made) => found = made
            case Released(id) => released(greeter, id)
            case Revoked => {}
            case Refused(why) => if why != .NoGrant {
                return null
            }
            case _ => return null
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
    if state.count < state.holders.count {
        state.holders[state.count] = holder
        state.count += 1
    }
    watching := os.Outgoing.{}
    os.begin[microphone_protocol.Request](&watching)^ = .WaitReleased(granted.id)
    _ = microphone_protocol.send_request(end, state.port, &watching)
    runtime.log_info("microphone: % holds it", name_text(&holder))
    show_microphone(greeter)
    return granted.end
}

/**
 * Take what the audio service has said on the microphone connection: each grant gone is shown gone. If the connection's
 * gone, so is every grant, closed with it.
 *
 * @param greeter The greeter, from its loop.
 */
take_microphone :: fn(greeter : ptr[mut Greeter]) {
    state :: &greeter.microphone
    if cast[slop_os.Handle](state.end) == slop_os.NO_HANDLE {
        return void
    }
    into := os.Incoming.{}
    loop {
        match microphone_protocol.receive_response(state.end, state.port, &into, false) {
            case Received => {}
            case Empty => break
            case _ => {
                microphone_gone(greeter)
                break
            }
        }
        match os.message_of[microphone_protocol.Response](&into)^ {
            case Released(id) => released(greeter, id)
            case _ => {}
        }
    }
    match state.window {
        case Some(window) => {
            _ = gui_kit.take(window)
            if (state.count > 0 || greeter.session is_some) && window.due {
                microphone_frame(greeter, window)
            }
        }
        case None => {}
    }
}

/**
 * The microphone connection's gone: closed, and every grant shown gone, as the audio service closes them with it.
 *
 * @param greeter The greeter.
 */
microphone_gone :: fn(greeter : ptr[mut Greeter]) {
    state :: &greeter.microphone
    if cast[slop_os.Handle](state.end) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](state.port))
        _ = slop_os.handle_close(cast[slop_os.Handle](state.end))
        state.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
        state.port = cast[slop_os.Port](slop_os.NO_HANDLE)
    }
    if state.count > 0 {
        state.count = 0
        runtime.log_info("microphone: the audio service is gone, and every grant with it")
        show_microphone(greeter)
    }
}

/**
 * A grant's gone: no longer shown held.
 *
 * @param greeter The greeter.
 * @param id The grant's id.
 */
released :: fn(greeter : ptr[mut Greeter], id : u32) {
    state :: &greeter.microphone
    for i in 0..<state.count {
        if i >= state.holders.count || state.holders[i].id != id {
            continue
        }
        // Out of the list before it's said, as what's known of the count doesn't outlast a call
        gone :: state.holders[i]
        for k in i..<state.count {
            next :: k + 1
            if next < state.count {
                state.holders[k] = state.holders[next]
            }
        }
        state.count -= 1
        runtime.log_info("microphone: % no longer holds it", name_text(&gone))
        show_microphone(greeter)
        return void
    }
}

/**
 * Show the sound window while the GUI session runs or a grant's held, made the first time, its next frame due; hide it
 * otherwise.
 *
 * @param greeter The greeter.
 */
show_microphone :: fn(greeter : ptr[mut Greeter]) {
    state :: &greeter.microphone
    mark_holders(greeter)
    if state.count == 0 && greeter.session is_none {
        match state.window {
            case Some(window) => gui_kit.hide(window)
            case None => {}
        }
        return void
    }
    match sound_window(greeter) {
        case Some(window) => window.due = true
        case None => runtime.log_info("the sound window couldn't be made")
    }
}

/**
 * Tell the compositor who holds the microphone, through the greeter's trusted connection, so each holder's windows are
 * marked on their bands (decisions/0197, N1); none when nothing's held.
 *
 * @param greeter The greeter, its holders as they are now.
 */
mark_holders :: fn(greeter : ptr[mut Greeter]) {
    state :: &greeter.microphone
    names : u8[surface.MAX_HELD_BYTES]
    count := cast[usize](0)
    for &holder, i in state.holders {
        if i >= state.count {
            break
        }
        // Each whole, with its line break, or not at all
        name :: string_bytes(name_text(holder))
        if count + name.count + 1 > names.count {
            break
        }
        for byte in name {
            if count < names.count {
                names[count] = byte
                count += 1
            }
        }
        if count < names.count {
            names[count] = cast[u8]('\n')
            count += 1
        }
    }
    out := os.Outgoing.{}
    request :: os.begin[surface.Request](&out)
    request^ = .MicrophoneHeld(os.append(&out, names[0..<count]))
    if surface.send_request(greeter.window.end, greeter.window.port, &out) is_some {
        runtime.log_info("microphone: the compositor couldn't be told who holds it")
    }
}

/**
 * The sound window, made the first time.
 *
 * @param greeter The greeter.
 * @return It; null if it couldn't be made.
 */
sound_window :: fn(greeter : ptr[mut Greeter]) -> ptr[mut gui_kit.Window]? {
    state :: &greeter.microphone
    if state.window == null {
        budget :: slop_os.startup_block().budget
        // Its own connection, made from the trusted one, so it's in the trusted layer too
        match surface.connect(greeter.window.end, greeter.window.port, budget) {
            case Some(given) => state.window = gui_kit.open_on(given, "Sound", SOUND_WIDTH, SOUND_HEIGHT, passive = true)
            case None => {}
        }
    }
    return state.window
}

/**
 * A frame of the sound window: while the session runs, - and + and its volume, first, so they stay put; then, while a
 * grant's held, "Take it back" and who holds it, a click on it taking every grant back.
 *
 * @param greeter The greeter.
 * @param window The sound window.
 */
microphone_frame :: fn(greeter : ptr[mut Greeter], window : ptr[mut gui_kit.Window]) {
    state :: &greeter.microphone
    u :: gui_kit.begin(window)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 10, padding_y = 10, gap = 6})
    quieter := false
    louder := false
    if greeter.session is_some {
        _ = ui.open(u, "volume", ui.Box.{direction = .Row, gap = 6})
        quieter = ui.button(u, "-")
        louder = ui.button(u, "+")
        storage : u8[40]
        line := text_buffer.make(storage)
        text_buffer.append(&line, "Volume: ")
        text_buffer.append_unsigned(&line, cast[u64](state.volume / 10))
        text_buffer.append(&line, "%")
        _ = ui.label(u, text_buffer.as_string(&line), ui.TextStyle.{size = 14})
        ui.close(u)
    }
    taken := false
    if state.count > 0 {
        taken = ui.button(u, "Take it back")
        holders_label(greeter, u)
    }
    ui.close(u)
    _ = gui_kit.finish(window)
    if taken {
        take_back_microphone(greeter)
    }
    if quieter || louder {
        change_volume(greeter, louder)
        window.due = true
    }
}

/**
 * Turn the GUI session's volume up or down a step: the session manager sets it on the session's sound.
 *
 * @param greeter The greeter, its session running.
 * @param up Whether it's turned up, rather than down.
 */
change_volume :: fn(greeter : ptr[mut Greeter], up : bool) {
    state :: &greeter.microphone
    number :: greeter.session or_return void
    volume :: if up {
        if state.volume + VOLUME_STEP > sound.FULL_VOLUME { sound.FULL_VOLUME } else { state.volume + VOLUME_STEP }
    }
    else {
        if state.volume < VOLUME_STEP { cast[u16](0) } else { state.volume - VOLUME_STEP }
    }
    out := os.Outgoing.{}
    os.begin[session.Request](&out)^ = .SetVolume(session.SessionVolume.{session = number, volume = volume})
    if session.send_request(greeter.sessions_end, greeter.sessions_port, &out) is_some {
        return void
    }
    into := os.Incoming.{}
    if !session_answer(greeter, &into, ANSWER_LIMIT) {
        runtime.log_info("the session's volume couldn't be set")
        return void
    }
    match os.message_of[session.Response](&into)^ {
        case Noted => {
            state.volume = volume
            runtime.log_info("the session's volume set to % percent", volume / 10)
        }
        case _ => runtime.log_info("the session's volume couldn't be set")
    }
}

/**
 * Say who holds the microphone, in the sound window.
 *
 * @param greeter The greeter, a grant held.
 * @param u The sound window's frame.
 */
holders_label :: fn(greeter : ptr[mut Greeter], u : ptr[mut ui.Ui]) {
    state :: &greeter.microphone
    storage : u8[200]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "The microphone: ")
    for &holder, i in state.holders {
        if i >= state.count {
            break
        }
        if i > 0 {
            text_buffer.append(&line, ", ")
        }
        text_buffer.append(&line, name_text(holder))
    }
    _ = ui.label(u, text_buffer.as_string(&line), ui.TextStyle.{size = 14})
}

/**
 * Take every grant back: the audio service closes each one's connection, and says each gone (take_microphone).
 *
 * @param greeter The greeter.
 */
take_back_microphone :: fn(greeter : ptr[mut Greeter]) {
    state :: &greeter.microphone
    if cast[slop_os.Handle](state.end) == slop_os.NO_HANDLE {
        return void
    }
    for &holder, i in state.holders {
        if i >= state.count {
            break
        }
        runtime.log_info("microphone: the user took it back from %", name_text(holder))
        out := os.Outgoing.{}
        os.begin[microphone_protocol.Request](&out)^ = .Revoke(holder.id)
        _ = microphone_protocol.send_request(state.end, state.port, &out)
    }
}

/** A holder's name as text. */
name_text :: fn(holder : ptr[Holder]) -> string {
    return if holder.count > 0 { string_of(&holder.name[0], holder.count) } else { "" }
}
