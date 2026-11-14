/**
 * The launcher (decisions/0192, 15e): a GUI session's first program. It lists the bundle store's GUI programs, those
 * whose manifest is a GUI program's entry (src/gui_programs), by name, itself left out, and starts the one clicked, giving it a
 * connection to the compositor of its own, its own connection to the process manager, and a programs connection that
 * only finds programs. It says what it lists and starts in its debug log: "lists <n> programs", "started <name>".
 */
package launcher

import runtime from "base"
import crypto from "std"
import os from "std"
import schema from "std"
import ui from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import gui_kit from "../../gui_kit"
import gui_programs from "../../gui_programs"
import programs from "../../protocols/programs"
import surface from "../../protocols/surface"

/** The most programs it lists. */
MAX_LISTED :: 32
/** The most bytes of a program's name. */
NAME_BYTES :: 32
/** The memory a program it starts is given. */
PROGRAM_BUDGET : u64 : 48 * 1024 * 1024
/** Each row of its list, in pixels. */
ROW : f32 : 36

/** A program it lists. */
Listed :: struct {
    /** Its name, the first name_count bytes. */
    name : u8[NAME_BYTES],
    /** How many bytes of name it has. */
    name_count : usize,
}

/** The launcher's state, on the heap. */
Launcher :: struct {
    /** Its window. */
    window : ptr[mut gui_kit.Window],
    /** Its connection to the process manager. */
    manager : os.Channel[process_manager.ProcessManager],
    /** The port its manager connection's bound to. */
    manager_port : slop_os.Port,
    /** Its programs connection. */
    programs : os.Channel[programs.Programs],
    /** The port its programs connection's bound to. */
    programs_port : slop_os.Port,
    /** What it lists, the first listed_count. */
    listed : Listed[MAX_LISTED],
    /** How many it lists. */
    listed_count : usize,
}

/**
 * List the GUI programs and start what's clicked, until the window's closed.
 *
 * @param log Its debug log; its lines go through base's logger instead.
 * @param surface Its connection to the compositor.
 * @param home The session's home; not used.
 * @param manager Its process manager connection, which programs are launched through.
 * @param programs Its programs connection, which finds them.
 * @return 0 once its window's closed; 2 without a compositor, the process manager or a programs connection, or when its
 *     window can't be made.
 */
main :: fn(log: slop_os.DebugLog?, surface: os.Channel[surface.Surface]?, home: os.Channel[dir.Dir]?,
    manager: os.Channel[process_manager.ProcessManager]?, programs: os.Channel[programs.Programs]?) -> int {
    startup :: slop_os.startup_block()
    launcher :: runtime.new(Launcher)
    launcher.manager = manager or_return 2
    launcher.manager_port = os.port_for(startup.budget, launcher.manager.end) or_return 2
    launcher.programs = programs or_return 2
    launcher.programs_port = os.port_for(startup.budget, launcher.programs.end) or_return 2
    launcher.window = gui_kit.open_on(surface or_return 2, "Programs", 360, 480) or_return 2
    list_programs(launcher)
    runtime.log_info("lists % programs", launcher.listed_count)
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
        gui_kit.wait(launcher.window)
    }
}

/** Ask the programs connection something, giving its answer. */
ask :: fn(launcher: ptr[mut Launcher], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> programs.Response? {
    if programs.send_request(launcher.programs.end, launcher.programs_port, out) is_some {
        return null
    }
    match programs.receive_response(launcher.programs.end, launcher.programs_port, into, true) {
        case Received => return os.message_of[programs.Response](into)^
        case _ => return null
    }
}

/** List the bundle store's programs whose manifest is a GUI program's entry. */
list_programs :: fn(launcher: ptr[mut Launcher]) {
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
        found :: find(launcher, name_of(&name)) or_else programs.Program.{executable = cast[slop_os.Memory](slop_os.NO_HANDLE),
            manifest = cast[slop_os.Memory](slop_os.NO_HANDLE)}
        // Itself not among them: it's running
        gui :: manifest_hash(found.manifest, found.manifest_size) == expected && !is_named(&name, "launcher")
        _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
        _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
        if gui && launcher.listed_count < launcher.listed.count {
            launcher.listed[launcher.listed_count] = name
            launcher.listed_count += 1
        }
    }
}

/** Find a program by name: its executable and manifest, the caller's to close. */
find :: fn(launcher: ptr[mut Launcher], name: u8[]) -> programs.Program? {
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Find(os.append(&out, name))
    into := os.Incoming.{}
    answer :: ask(launcher, &out, &into) or_else programs.Response.Unsupported
    match answer {
        case Found(program) => return program
        case _ => return null
    }
}

/** A manifest's schema hash: BLAKE3 of its bytes; all zeros when it can't be read. */
manifest_hash :: fn(manifest: slop_os.Memory, size: u64) -> u8[32] {
    hashed : u8[32]
    if size == 0 || size > 1 << 20 {
        return hashed
    }
    mapped :: (size + 4095) / 4096 * 4096
    address :: runtime.reserve_addresses(cast[usize](mapped)) or_return hashed
    if slop_os.memory_map(manifest, slop_os.startup_block().space, address, 0, mapped, slop_os.PROTECTION_READ) is_error {
        return hashed
    }
    hasher := crypto.blake3_start()
    crypto.blake3_update(&hasher, view_of(cast[ptr[u8]](address), cast[usize](size)))
    crypto.blake3_finish(&hasher, hashed[0..<32])
    _ = slop_os.memory_unmap(slop_os.startup_block().space, address)
    return hashed
}

/** A frame: the programs, a button each; the one clicked started. */
frame :: fn(launcher: ptr[mut Launcher]) {
    u :: gui_kit.begin(launcher.window)
    _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 12, padding_y = 12, gap = 8})
    _ = ui.label(u, "Programs", ui.TextStyle.{size = 18})
    clicked := launcher.listed.count
    for &each, i in launcher.listed {
        if i < launcher.listed_count && each.name_count <= each.name.count && each.name_count > 0 {
            if ui.button(u, string_of_bytes(name_of(each)), key = cast[u64](i)) {
                clicked = i
            }
        }
    }
    if launcher.listed_count == 0 {
        _ = ui.label(u, "No programs to start.")
    }
    ui.close(u)
    _ = gui_kit.finish(launcher.window)
    if clicked < launcher.listed_count && clicked < launcher.listed.count {
        start(launcher, launcher.listed[clicked])
    }
}

/** Start a program it lists, with its grants. */
start :: fn(launcher: ptr[mut Launcher], listed: Listed) {
    if listed.name_count == 0 || listed.name_count > listed.name.count {
        return void
    }
    name :: string_of_bytes(name_of(&listed))
    found :: find(launcher, name_of(&listed)) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](found.executable))
    _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
    budget :: slop_os.startup_block().budget
    grants := gui_programs.GuiGrants.{
        surface = surface.connect(launcher.window.end, launcher.window.port, budget),
        manager = process_manager.connect(launcher.manager.end, launcher.manager_port, budget),
        programs = programs.connect(launcher.programs.end, launcher.programs_port, budget)}
    match os.launch(launcher.manager, launcher.manager_port, name, found.executable, PROGRAM_BUDGET, gui_programs.shape, grants) {
        case Ok(_) => runtime.log_info("started %", name)
        case Error(_) => runtime.log_info("% didn't start", name)
    }
}

/** A program's name as it's listed. */
name_of :: fn(listed: ptr[Listed]) -> u8[] {
    kept :: listed.name[0..<NAME_BYTES]
    return if listed.name_count <= kept.count { kept[0..<listed.name_count] } else { kept }
}

/** Bytes as text. */
string_of_bytes :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/** Whether a program's listed name is a name. */
is_named :: fn(listed: ptr[Listed], name: string) -> bool {
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
