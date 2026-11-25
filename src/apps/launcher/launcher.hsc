/**
 * The launcher (decisions/0192, 15e and 15g): a GUI session's first program. It lists the bundle store's programs,
 * itself left out: the GUI programs, those whose manifest is a GUI program's entry (src/gui_programs), which it starts
 * when clicked, and the rest as commands, each of which, clicked, shows a form made from its manifest (src/forms). A
 * form run starts a terminal window whose shell runs the command line it makes. It starts nothing itself: it asks the
 * session manager, on the session's own programs connection, to start each as one of the session's programs (Start),
 * given a connection of its own to the session's home. It says what it lists and starts in its log: "lists <n>
 * programs and <m> commands", "started <name>", and "a form for <name>" once the form's first drawn.
 */
package launcher

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import schema from "std:schema"
import ui from "std:ui"
import forms from "../../forms"
import gui_kit from "../../gui_kit"
import gui_programs from "../../gui_programs"
import programs from "../../protocols/programs"
import surface from "../../protocols/surface"
import sound as sound_protocol from "../../protocols/sound"

/** The most programs and commands it lists, together. */
MAX_LISTED :: 128
/** The most bytes of a program's name. */
NAME_BYTES :: 32
/** The most bytes of a manifest it reads for a form: 256 KiB. */
MAX_MANIFEST : u64 : 256 * 1024

/** A program it lists. */
Listed :: struct {
    /** Its name, the first name_count bytes. */
    name : u8[NAME_BYTES],
    /** How many bytes of name it has. */
    name_count #at_most(name.count) : usize,
    /** Whether it's a GUI program, started when clicked; a command shows its form. */
    gui : bool,
}

/** The launcher's state, on the heap. */
Launcher :: struct {
    /** Its window. */
    window : ptr[mut gui_kit.Window],
    /** Its session's own programs connection, which lists and starts programs. */
    programs : os.Channel[programs.Programs],
    /** The port its programs connection's bound to. */
    programs_port : slop_os.Port,
    /** The session's home, which each program it starts is given a connection of its own to; null without one. */
    home : os.Channel[dir.Dir]?,
    /** The port home's bound to; NO_HANDLE without one. */
    home_port : slop_os.Port,
    /** What it lists, the first listed_count: GUI programs and commands, in the store's order. */
    listed : Listed[MAX_LISTED],
    /** How many it lists. */
    listed_count #at_most(listed.count) : usize,
    /** The form shown in place of the list, while showing is set. */
    form : forms.Form,
    /** Whether form is shown, in place of the list. */
    showing : bool,
    /** Whether the form's been said to be shown in its debug log, once its first frame's drawn. */
    announced : bool,
    /** What's typed in the find field: the list shows only the programs whose names have it. */
    find : u8[..],
}

/**
 * List the programs and start what's clicked, or show a command's form and run it, until the window's closed.
 *
 * @param log Not used: its lines go through base's logger, to its session's ring.
 * @param surface Its connection to the compositor.
 * @param home The session's home, each program it starts given a connection of its own to; without it, it starts
 *     none.
 * @param programs Its session's own programs connection, which lists and starts programs.
 * @param open Not used: it's asked to open nothing.
 * @param terminal Not used: it serves no terminal.
 * @param activation Not used: its window is the session's first, with nothing else to take focus from.
 * @param sound Not used: it plays nothing, and closes it.
 * @return 0 once its window's closed; 2 without a compositor or a programs connection, or when its window can't be
 *     made.
 */
main :: fn(
    log : slop_os.DebugLog?,
    surface : os.Channel[surface.Surface]?,
    home : os.Channel[dir.Dir]?,
    programs : os.Channel[programs.Programs]?,
    open : string?,
    terminal : os.Channel[terminal.Terminal]?,
    activation : u64?,
    sound : os.Channel[sound_protocol.Sound]?
) -> int {
    // It plays nothing: its sound connection's let go at once, the audio service's place for it freed
    match sound {
        case Some(given) => _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
        case None => {}
    }
    startup :: slop_os.startup_block()
    launcher :: runtime.new(Launcher)
    launcher.programs = programs or_return 2
    launcher.programs_port = os.port_for(startup.budget, launcher.programs.end) or_return 2
    launcher.home_port = cast[slop_os.Port](slop_os.NO_HANDLE)
    match home {
        case Some(given) => {
            match os.port_for(startup.budget, given.end) {
                case Some(port) => {
                    launcher.home = given
                    launcher.home_port = port
                }
                case None => {}
            }
        }
        case None => {}
    }
    launcher.window = gui_kit.open_on(surface or_return 2, "Programs", 360, 560, activation or_else 0) or_return 2
    list_programs(launcher)
    runtime.log_info("lists % programs and % commands", count_of(launcher, true), count_of(launcher, false))
    loop {
        if !gui_kit.take(launcher.window) {
            return 2
        }
        if launcher.window.closing {
            return 0
        }
        if launcher.window.due {
            frame(launcher)
        }
        gui_kit.wait(launcher.window, slop_os.NO_DEADLINE)
    }
}

/** Ask the programs connection something, giving its answer. */
ask :: fn(launcher : ptr[mut Launcher], out : ptr[mut os.Outgoing], into : ptr[mut os.Incoming]) -> programs.Response? {
    if programs.send_request(launcher.programs.end, launcher.programs_port, out) is_some {
        return null
    }
    match programs.receive_response(launcher.programs.end, launcher.programs_port, into, true) {
        case Received => return os.message_of[programs.Response](into)^
        case _ => return null
    }
}

/** List the bundle store's programs, GUI programs and commands, itself left out. */
list_programs :: fn(launcher : ptr[mut Launcher]) {
    expected :: schema.hash(type_info_of(type_of(gui_programs.shape)))
    into := os.Incoming.{}
    for index in cast[u32](0)..<256 {
        out := os.Outgoing.{}
        request :: os.begin[programs.Request](&out)
        request^ = .List(index)
        name := Listed.{}
        answer :: ask(launcher, &out, &into) or_else programs.Response.Unsupported
        match answer {
            case Named(given) => {
                for byte in os.items(&into, given) {
                    if name.name_count < name.name.count {
                        name.name[name.name_count] = byte
                        name.name_count += 1
                    }
                }
            }
            case _ => return void
        }
        // Itself not among them: it's running
        if name.name_count == 0 || is_named(&name, "launcher") {
            continue
        }
        // Its entry asked, not its executable: listing gets nothing of a program from the store but its record
        asking := os.Outgoing.{}
        entry :: os.begin[programs.Request](&asking)
        entry^ = .EntryOf(os.append(&asking, name_of(&name)))
        answered := os.Incoming.{}
        entry_answer :: ask(launcher, &asking, &answered) or_else programs.Response.Unsupported
        match entry_answer {
            case EntryIs(given) => name.gui = given.bytes == expected
            case _ => continue
        }
        if launcher.listed_count < launcher.listed.count {
            launcher.listed[launcher.listed_count] = name
            launcher.listed_count += 1
        }
    }
}

/** How many it lists that are GUI programs, or that are commands. */
count_of :: fn(launcher : ptr[Launcher], gui : bool) -> usize {
    count := cast[usize](0)
    for each, i in launcher.listed {
        if i < launcher.listed_count && each.gui == gui {
            count += 1
        }
    }
    return count
}

/**
 * Read a program's manifest, asked for alone (ManifestOf), so nothing of the store's is held for it.
 *
 * @return The manifest, the caller's to free (schema.free); null if there's no such program, the answer didn't come,
 *     it's past MAX_MANIFEST bytes, or it doesn't read.
 */
manifest_of :: fn(launcher : ptr[mut Launcher], name : u8[]) -> schema.Schema? {
    out := os.Outgoing.{}
    // Begun before the name's appended, as begin starts the message afresh
    request :: os.begin[programs.Request](&out)
    request^ = .ManifestOf(os.append(&out, name))
    into := os.Incoming.{}
    answer :: ask(launcher, &out, &into) or_else programs.Response.Unsupported
    given :: match answer {
        case Manifest(given) => given
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](given.record))
    if given.size == 0 || given.size > MAX_MANIFEST {
        return null
    }
    bytes, made :: runtime.new_array(u8, cast[usize](given.size))
    if made != null {
        return null
    }
    defer runtime.free_array(bytes)
    if slop_os.memory_read(given.record, 0, bytes) is_error {
        return null
    }
    return schema.parse(bytes)
}

/**
 * A frame: the list of programs and commands, or a command's form, and what was clicked or submitted in it acted on.
 * Enter in the find field picks the first program it shows; Enter in a form's field runs the form, as Run does.
 */
frame :: fn(launcher : ptr[mut Launcher]) {
    u :: gui_kit.begin(launcher.window)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 12, padding_y = 12, gap = 8})
    clicked := launcher.listed.count
    run := false
    back := false
    if launcher.showing {
        form :: &launcher.form
        _ = ui.label(u, string_of_bytes(forms.program_of(form)), ui.TextStyle.{size = 18})
        _ = ui.scroll_area(u, "form", ui.Box.{width = ui.grow(), height = ui.grow(), gap = 10})
        run = forms.show_form(u, form)
        ui.close(u)
        back = ui.button(u, "Back")
    }
    else {
        clicked = list_frame(launcher, u)
    }
    ui.close(u)
    submitted := false
    for event in gui_kit.finish(launcher.window) {
        submitted = submitted || event.kind == .Submitted
    }
    // Said once its first frame's drawn, so what's typed after is the form's
    if launcher.showing && !launcher.announced {
        launcher.announced = true
        runtime.log_info("a form for %", string_of_bytes(forms.program_of(&launcher.form)))
    }
    if launcher.showing {
        if (run || submitted) && !launcher.form.unfit {
            line :: forms.command_line(&launcher.form)
            runtime.log_info("runs %", line)
            start(launcher, string_bytes("terminal_window"), line)
            back = true
        }
        if back {
            forms.free_form(&launcher.form)
            launcher.showing = false
            launcher.window.due = true
        }
        return void
    }
    if submitted && clicked >= launcher.listed.count {
        clicked = first_shown(launcher)
    }
    if clicked < launcher.listed_count && clicked < launcher.listed.count {
        choose(launcher, clicked)
    }
}

/**
 * The list: the find field, then the GUI programs and the commands whose names have what's typed in it, a button each.
 *
 * @return The index in launcher.listed of the one clicked; launcher.listed.count for none.
 */
list_frame :: fn(launcher : ptr[mut Launcher], u : ptr[mut ui.Ui]) -> usize {
    clicked := launcher.listed.count
    _ = ui.text_field(u, "Find", &launcher.find)
    _ = ui.scroll_area(u, "list", ui.Box.{width = ui.grow(), height = ui.grow(), gap = 8})
    for gui in bool.[true, false] {
        _ = ui.label(u, if gui { "Programs" } else { "Commands" }, ui.TextStyle.{size = 18})
        shown := 0
        for &each, i in launcher.listed {
            if i < launcher.listed_count && each.gui == gui && is_shown(launcher, each) {
                shown += 1
                if ui.button(u, string_of_bytes(name_of(each)), key = cast[u64](i)) {
                    clicked = i
                }
            }
        }
        if shown == 0 {
            _ = ui.label(u, if gui { "No programs to start." } else { "No commands." })
        }
    }
    ui.close(u)
    return clicked
}

/** The first program the list shows, a GUI program before a command; launcher.listed.count for none. */
first_shown :: fn(launcher : ptr[Launcher]) -> usize {
    for gui in bool.[true, false] {
        for &each, i in launcher.listed {
            if i < launcher.listed_count && each.gui == gui && is_shown(launcher, each) {
                return i
            }
        }
    }
    return launcher.listed.count
}

/** Whether a program's shown: its name has what's typed in the find field, or nothing is. */
is_shown :: fn(launcher : ptr[Launcher], listed : ptr[Listed]) -> bool {
    wanted :: ui.contents(&launcher.find)
    name :: name_of(listed)
    if wanted.count == 0 {
        return true
    }
    if wanted.count > name.count {
        return false
    }
    for start in cast[usize](0)..<(name.count - wanted.count + 1) {
        same := true
        for byte, i in wanted {
            if start + i >= name.count || name[start + i] != byte {
                same = false
                break
            }
        }
        if same {
            return true
        }
    }
    return false
}

/** Act on a program chosen from the list: a GUI program started, a command's form shown. */
choose :: fn(launcher : ptr[mut Launcher], index : usize) {
    if index >= launcher.listed_count || index >= launcher.listed.count {
        return void
    }
    chosen :: launcher.listed[index]
    // The list's shown whole again after, whatever was chosen, and nothing's focused: Tab goes to the find field
    runtime.array_reset(&launcher.find)
    ui.set_focus(&launcher.window.ui, 0)
    if chosen.gui {
        start(launcher, name_of(&chosen), null)
        return void
    }
    manifest := manifest_of(launcher, name_of(&chosen)) or_return void
    defer schema.free(&manifest)
    launcher.form = forms.form_of(&manifest, name_of(&chosen)) or_return void
    launcher.showing = true
    launcher.announced = false
    launcher.window.due = true
}

/**
 * Have the session manager start a program in the session (programs' Start), given a connection of its own to the
 * home: a GUI program, or the terminal window, whose shell it starts too.
 *
 * @param name_bytes The program's name.
 * @param open What it's to open, only read: for the terminal window, the command line its shell runs alone. Null for
 *     nothing.
 */
start :: fn(launcher : ptr[mut Launcher], name_bytes : u8[], open : string?) {
    if name_bytes.count == 0 {
        return void
    }
    name :: string_of_bytes(name_bytes)
    given :: launcher.home or_return void
    home :: dir.connect(given.end, launcher.home_port, slop_os.startup_block().budget) or_return void
    // The token for the click, or the Enter, that asked for it, so its window takes focus when it's shown
    activation :: gui_kit.token(launcher.window)
    out := os.Outgoing.{}
    // Begun before the bytes are appended, as begin starts the message afresh
    request :: os.begin[programs.Request](&out)
    request^ = .Start(
        programs.Starting.{
            name = os.append(&out, name_bytes),
            home = home,
            open = os.append(&out, string_bytes(open or_else "")),
            activation = activation,
        }
    )
    into := os.Incoming.{}
    answer :: ask(launcher, &out, &into) or_else programs.Response.Unsupported
    match answer {
        case Done => runtime.log_info("started %", name)
        case Missing => runtime.log_info("% didn't start: it isn't a GUI program", name)
        case _ => runtime.log_info("% didn't start", name)
    }
}

/** A program's name as it's listed. */
name_of :: fn(listed : ptr[Listed]) -> u8[] {
    kept :: listed.name[0..<NAME_BYTES]
    return if listed.name_count <= kept.count { kept[0..<listed.name_count] } else { kept }
}

/** Bytes as text. */
string_of_bytes :: fn(bytes : u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/** Whether a program's listed name is a name. */
is_named :: fn(listed : ptr[Listed], name : string) -> bool {
    bytes :: name_of(listed)
    other :: string_bytes(name)
    if bytes.count != other.count {
        return false
    }
    for byte, i in bytes {
        if i < other.count && other[i] != byte {
            return false
        }
    }
    return true
}
