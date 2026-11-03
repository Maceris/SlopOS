/*
 * The shell (roadmap M11, design/shell.md, decisions/0162, 0169): the session's first program, reading lines with
 * std/terminal's line editor and evaluating each in the shell language, showing a statement's value when it has one and
 * an error with where in the line it was. Its names are its own (let), never given to the programs it runs.
 */
package shell

import runtime from "base"
import os from "std"
import text_buffer from "std"
import terminal from "std"
import slop_os from "std/os"
import terminal as protocol from "std/os/slop_os"
import dir from "std/os/slop_os"

PROMPT :: "> "

Shell :: struct {
    console : terminal.Terminal,
    scope : Scope,
    exiting : bool,
}

main :: fn(log: slop_os.DebugLog?, session_terminal: os.Channel[protocol.Terminal], home: os.Channel[dir.Dir]?) -> int {
    shell := runtime.new(Shell)
    shell.console = terminal.open(session_terminal) or_return 2
    say(shell, "SlopOS shell")
    runtime.log_info("reading commands")
    editor := terminal.LineEditor.{}
    loop {
        if shell.exiting {
            return 0
        }
        match terminal.read_line(&editor, &shell.console, PROMPT) {
            case Line(line) => run_line(shell, line)
            case Interrupted => {}
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

// A line run: parsed, each statement evaluated in turn and its value shown, the first error shown and the rest left.
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
                        render(&out, value)
                        say(shell, text_buffer.as_string(&out))
                    }
                }
            }
            case Error(error) => {
                show_error(shell, line, error.at, error.message)
                return void
            }
        }
    }
}

// An error, and where in the line it is, under it.
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
    for i in 0..<(if at < line.count { at } else { line.count }) {
        text_buffer.append(&pointer, " ")
    }
    text_buffer.append(&pointer, "^")
    say(shell, text_buffer.as_string(&pointer))
    runtime.log_info("error: %", message)
}

say :: fn(shell: ptr[mut Shell], text: string) {
    _ = terminal.write_line(&shell.console, text)
}

// A program called: through its manifest, in 11b2.
run_program :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    return error_at(tree.at, message("there's no command named %", tree.text))
}
