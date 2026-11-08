/**
 * The shell (roadmap M11, design/shell.md, decisions/0162, 0169): the session's first program, reading lines with
 * std/terminal's line editor and evaluating each in the shell language, showing a statement's value when it has one
 * and an error with where in the line it was. Its names are its own (let), never given to the programs it runs.
 */
package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import text_buffer from "std"
import terminal from "std"
import unicode from "std"
import slop_os from "std/os"
import terminal as protocol from "std/os/slop_os"
import dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import programs as finding from "../../protocols/programs"
import installations from "../../installations"

/** The prompt in the shell's home; elsewhere it's the directory, then "> ". */
PROMPT :: "> "

/** The shell's state, on the heap for as long as it runs. */
Shell :: struct {
    /** The session's terminal, which lines are read from and everything's written to. */
    console : terminal.Terminal,
    /** The scope names are bound in now: the shell's own, or a function's call's or a stage's item's while it runs. */
    scope : ptr[mut Scope],
    /** Whether exit has been run, so the shell ends before reading another line. */
    exiting : bool,
    /** Its functions, their Function nodes kept, one to a name. */
    functions : ptr[Node][..],
    /** How deep the calls of shell functions running are, from 0; at most MAX_DEPTH. */
    depth : usize,
    /** What the last return gave, Null for a return without a value, for the function's call to take. */
    returned : Value,
    /** Its directory, as a path beneath its home, "" for the home itself. */
    directory : string,
    /** The ends of programs it's started that it's seen but not waited for yet. */
    ended : EndedProgram[..],
    /** Its home, which paths are beneath; null if it wasn't given one, so no path can be opened. */
    home : os.Channel[dir.Dir]?,
    /** A port bound to home's end, waited on for its answers; unset without a home. */
    home_port : slop_os.Port,
    /** The process manager it starts programs through; null if it wasn't given one, so no program can start. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** A port bound to manager's end; unset without one. */
    manager_port : slop_os.Port,
    /** The session manager's connection it finds programs on (decisions/0170); null if it wasn't given one. */
    programs : os.Channel[finding.Programs]?,
    /** A port bound to programs' end; unset without one. */
    programs_port : slop_os.Port,
    /** The names of the programs it can run, once program_names has asked for them, each its own; for completion. */
    names : string[..],
    /** Whether names has been asked for, so it's asked once. */
    names_listed : bool,
    /** Its data directory, where its history's kept; null without one. */
    data : os.Directory?,
    /** The programs running in the foreground, which Ctrl-C stops; null while none are. */
    foreground : ptr[mut Running]?,
    /** Its jobs in the background, oldest first. */
    jobs : Job[..],
    /** The number the newest job was given; 0 before any. */
    last_job : u32,
    /** The key the next programs started together have their ends watched under, from FIRST_KEY. */
    next_key : u64,
    /** The crash reports of the programs it's started, oldest first, at most MAX_CRASHES; each its own. */
    crashes : Crash[..],
}

/**
 * Read lines on the session's terminal and run each in the shell language, until exit, or the terminal goes.
 *
 * A line is statements, separated by line breaks or ;: let name = value binds a name of the shell's own, fn defines
 * a function, and a call runs a program by its name, its arguments matched to its manifest's parameters by position
 * or --name; | connects programs and the built-in stages where, map, sort, take and group. Each statement's value is
 * shown when it has one; the first error is shown with a ^ under where it is in the line, and the rest of the line
 * isn't run. print writes its arguments, cd changes the directory, beneath the home, and exit ends the shell.
 *
 * @param log The kernel's debug log. The shell writes its lines through base's logger, to the events service,
 *     instead, so it's taken but not used.
 * @param session_terminal The connection to the session's terminal, read and written for as long as the shell runs,
 *     and connected to again for each program that asks for a terminal; when it goes, the shell ends.
 * @param home The home directory, which paths, cd and the directories and files programs are given are beneath.
 *     Without it, nothing can be opened by a path.
 * @param manager The process manager programs are started through. Without it, a call of a program fails.
 * @param programs The session manager's connection that finds programs by their names (decisions/0170). Without it,
 *     no program is found.
 * @param data The shell's own data directory, where its history is kept, read when it starts and written after each
 *     line. Without it, history lasts only as long as the shell.
 * @param script A script to run (decisions/0179, 11e6), instead of reading lines: its parameters bound to the grants
 *     and values of their names, then its statements run in turn, its home its here. Without it, the shell reads lines
 *     on its terminal.
 * @return 0 after exit, or when it's asked to stop on its lifecycle channel; 2 if the terminal couldn't be opened or
 *     a port couldn't be made; 3 when its terminal goes. For a script: 0 once it's run to its end, 1 for its error, 2
 *     if it couldn't be read.
 */
main :: fn(log: slop_os.DebugLog?, session_terminal: os.Channel[protocol.Terminal], home: os.Channel[dir.Dir]?,
    manager: os.Channel[process_manager.ProcessManager]?, programs: os.Channel[finding.Programs]?, data: installations.AppData?,
    script: os.Channel[read_only_file.ReadOnlyFile]?) -> int {
    block :: slop_os.startup_block()
    shell := runtime.new(Shell)
    shell.scope = runtime.new(Scope)
    shell.console = terminal.open(session_terminal) or_return 2
    shell.next_key = FIRST_KEY
    shell.home = home
    match home {
        case Some(given) => shell.home_port = os.port_for(block.budget, given.end) or_return 2
        case None => {}
    }
    shell.manager = manager
    match manager {
        case Some(given) => shell.manager_port = os.port_for(block.budget, given.end) or_return 2
        case None => {}
    }
    shell.programs = programs
    match programs {
        case Some(given) => shell.programs_port = os.port_for(block.budget, given.end) or_return 2
        case None => {}
    }
    match script {
        case Some(given) => return run_script(shell, given)
        case None => {}
    }
    say(shell, "SlopOS shell")
    runtime.log_info("reading commands")
    editor := terminal.LineEditor.{}
    terminal.set_completer(&editor, complete_line, shell)
    match data {
        case Some(given) => {
            directory, error :: os.directory_on(given.end)
            if error == null {
                shell.data = directory
                load_history(shell, &editor)
            }
        }
        case None => {}
    }
    loop {
        if shell.exiting {
            return 0
        }
        match terminal.read_line(&editor, &shell.console, prompt_of(shell)) {
            case Line(line) => {
                // The parse copies it, so nothing run keeps it
                run_line(shell, line)
                runtime.free_array(bit_cast[u8[]](line))
                save_history(shell, &editor)
            }
            case Interrupted => {}
            case Other(packet) => take_while_reading(shell, packet)
            case HangUp => {
                runtime.log_info("its terminal went")
                return 3
            }
            case Stop => {
                runtime.log_info("stopping, as asked")
                return 0
            }
        }
    }
}

/**
 * Run a line: parse it, then evaluate each statement in turn, showing its value unless it's Null; the first error is
 * shown, and the rest of the line left.
 *
 * A value is shown as render writes it, cut at 8 KiB, a table to the terminal's width (table_columns).
 *
 * @param shell The shell: its scope, functions and programs are used and changed as the statements run, and the
 *     values and errors are written on its terminal.
 * @param line The line, which the parse copies, so it's the caller's still.
 */
run_line :: fn(shell: ptr[mut Shell], line: string) {
    tree :: match parse(line) {
        case Ok(made) => made
        case Error(error) => {
            show_error(shell, line, error.at, error.message)
            return void
        }
    }
    for statement in tree.children {
        match evaluate(shell, statement) {
            case Ok(value) => {
                match value {
                    case Null => {}
                    case _ => {
                        storage : u8[8192]
                        out := text_buffer.make(storage)
                        render(&out, value, false, table_columns(shell, value))
                        say(shell, text_buffer.as_string(&out))
                    }
                }
            }
            case Error(error) => {
                if error.returning {
                    show_error(shell, line, error.at, "return is a function's, and this isn't in one")
                    return void
                }
                show_error(shell, line, error.at, error.message)
                return void
            }
        }
    }
}

/**
 * Make the prompt: "> ", after ~/ and the shell's directory when it isn't its home.
 *
 * @param shell The shell, whose directory is read; nothing is changed.
 * @return The prompt: PROMPT in the home, or a message on the heap, never freed.
 */
prompt_of :: fn(shell: ptr[Shell]) -> string {
    if shell.directory.count == 0 {
        return PROMPT
    }
    return message("~/%> ", shell.directory)
}

/**
 * Show an error: "error: " and its message, then the line, then a ^ under where in the line it is; and log it.
 *
 * @param shell The shell, whose terminal it's shown on.
 * @param line The line the error is in, written as it is under the message; with the two spaces before it, what
 *     doesn't fit 512 bytes is cut.
 * @param at Where the error is in the line, in bytes from 0; past the line's end, the ^ is at its end. The ^ goes as
 *     many columns along as the line's text before it takes on the terminal (unicode.text_width).
 * @param message What's wrong; each line is cut at 512 bytes.
 */
show_error :: fn(shell: ptr[mut Shell], line: string, at: usize, message: string) {
    storage : u8[512]
    out := text_buffer.make(storage)
    text_buffer.append(&out, "error: ")
    text_buffer.append(&out, message)
    say(shell, text_buffer.as_string(&out))
    pointer := text_buffer.make(storage)
    text_buffer.append(&pointer, "  ")
    text_buffer.append(&pointer, line)
    say(shell, text_buffer.as_string(&pointer))
    pointer = text_buffer.make(storage)
    text_buffer.append(&pointer, "  ")
    before :: language.slice(line, 0, if at < line.count { at } else { line.count })
    language.pad(&pointer, unicode.text_width(string_bytes(before)))
    text_buffer.append(&pointer, "^")
    say(shell, text_buffer.as_string(&pointer))
    runtime.log_info("error: %", message)
}

/**
 * Write a line on the terminal, ignoring a failure: a terminal that's gone is noticed when the next line is read.
 *
 * @param shell The shell, whose terminal it's written on.
 * @param text The line, without its line feed.
 */
say :: fn(shell: ptr[mut Shell], text: string) {
    _ = terminal.write_line(&shell.console, text)
}
