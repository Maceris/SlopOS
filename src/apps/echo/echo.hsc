/**
 * echo (decisions/0136, 0150): a session's first program until the shell, which the session manager starts with the
 * session's terminal connection, and its home volume's root once someone's logged in; it says how many entries the
 * home directory has, then how numbers and dates look in its session's locale (decisions/0152). It reads lines with
 * Hemera's std/terminal line editor (decisions/0164), the line being typed kept as the terminal's input line, below
 * what anything writes (decisions/0147), with a cursor and history, and answers each line with the line itself and
 * "echo: " and the line, which it also logs; Ctrl-C drops the line, shown with ^C after it. Its session ends with its
 * terminal connection, and so does it. Asked to stop on its lifecycle channel (decisions/0139), it ends with 0.
 *
 * With its session's powerbox (decisions/0156), three lines ask the user for something on the trusted path: "open" for
 * a file, whose first line it shows; "save" and some text for a file to write the text in, suggesting notes.txt, and
 * asking to keep it as "notes" (decisions/0158); and "list" for a directory, whose entries it names. "reopen" opens
 * what was kept as "notes" again, without asking, and shows its first line. "adduser" asks for another account, which
 * the administrator allows on the trusted path, where its name and password are typed too.
 */
package echo

import runtime from "base"
import os from "std"
import text_buffer from "std"
import unicode from "std"
import locale from "std"
import time from "std"
import terminal from "std"
import slop_os from "std/os"
import terminal as protocol from "std/os/slop_os"
import dir from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import powerbox_protocol from "../../protocols/powerbox"

/** The most bytes of a line that fit in echo's answer to it; what's past them is cut. */
LINE_BYTES :: 256
/** No channel: what box_end is without a powerbox. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

/** What echo runs with: its terminal and its session's powerbox. */
Echo :: struct {
    /** The session's terminal, opened on the terminal connection, which every line is read from and written to. */
    console : terminal.Terminal,
    /** Its session's powerbox's channel end, NONE without one; the grant's, never closed. */
    box_end : slop_os.Channel,
    /** A port bound to box_end, waited on for the powerbox's answers; unset without a powerbox. */
    box_port : slop_os.Port,
}

/**
 * Echo each line typed on the session's terminal, and answer a few commands with the session's powerbox.
 *
 * It first says how many entries the home directory has, and how numbers and dates look in the session's locale. Then
 * each line typed is answered with "echo: " and the line, and logged. With a powerbox, "open" asks the user for a file
 * and shows its first line; "save" and some text asks for a file to write the text in, suggesting notes.txt and asking
 * to keep it as "notes"; "list" asks for a directory and names its entries; "reopen" opens what was kept as "notes"
 * again without asking; "adduser" asks for another account, which the administrator allows on the trusted path
 * (Ctrl+Alt+Delete shows what the powerbox asks). Ctrl-C drops the line being typed.
 *
 * @param log The kernel's debug log. echo writes its lines through base's logger, to the events service, instead, so
 *     it's taken but not used.
 * @param session_terminal The connection to the session's terminal, which echo reads and writes for as long as it
 *     runs; when it goes, the session's over and echo ends.
 * @param home The root of the home volume of whoever's logged in, whose entries echo counts at the start. Without it,
 *     as before anyone's logged in, nothing's said of a home directory.
 * @param powerbox The session's powerbox, which the commands open, save, list, reopen and adduser ask. Without it,
 *     each of them says there's no powerbox to ask.
 * @return 0 when it's asked to stop on its lifecycle channel; 2 if the terminal couldn't be opened or a port for the
 *     powerbox couldn't be made; 3 when its terminal goes.
 */

main :: fn(log: slop_os.DebugLog?, session_terminal: os.Channel[protocol.Terminal], home: os.Channel[dir.Dir]?,
    powerbox: os.Channel[powerbox_protocol.Powerbox]?) -> int {
    echo := Echo.{console = terminal.open(session_terminal) or_return 2, box_end = NONE}
    match powerbox {
        case Some(given) => {
            echo.box_end = given.end
            echo.box_port = os.port_for(slop_os.startup_block().budget, given.end) or_return 2
        }
        case None => {}
    }
    match home {
        case Some(root) => greet(&echo, root)
        case None => {}
    }
    show_locale(&echo)
    editor := terminal.LineEditor.{}
    defer terminal.free_editor(&editor)
    loop {
        match terminal.read_line(&editor, &echo.console, "") {
            case Line(line) => {
                defer runtime.free_array(bit_cast[u8[]](line))
                answer(&echo, line)
            }
            case Interrupted => {}
            case Other(packet) => {}
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
 * Show a number and a date as the session's locale writes them, the last day of 2026 for the date, and log the
 * locale's name.
 *
 * @param echo The program's state, whose terminal the line is written to.
 */
show_locale :: fn(echo: ptr[mut Echo]) {
    storage : u8[96]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "Numbers here look like ")
    locale.append_fixed(&line, 123456789, 2)
    text_buffer.append(&line, ", and dates like ")
    locale.append_date(&line, time.DateTime.{year = 2026, month = 12, day = 31})
    text_buffer.append(&line, ".")
    _ = terminal.write_line(&echo.console, text_buffer.as_string(&line))
    current :: locale.current()
    runtime.log_info("its locale is %", if current.name.count > 0 { current.name } else { "neutral" })
}

/**
 * Say how many entries the home directory has, on the terminal and in the log.
 *
 * Nothing's said if the directory can't be opened or listed.
 *
 * @param echo The program's state, whose terminal the line is written to.
 * @param root The home volume's root, which stays the grant's: the directory opened on it is closed, not the root.
 */
greet :: fn(echo: ptr[mut Echo], root: os.Channel[dir.Dir]) {
    directory, error :: os.directory_on(root.end)
    if error != null {
        return void
    }
    defer os.close_directory(directory)
    count := cast[usize](0)
    match os.list_directory_in(directory, "") {
        case Ok(listing) => {
            count = listing.count
            os.free_directory_listing(listing)
        }
        case Error(failure) => return void
    }
    storage : u8[64]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "Your home directory has ")
    text_buffer.append_unsigned(&line, cast[u64](count))
    text_buffer.append(&line, if count == 1 { " entry." } else { " entries." })
    _ = terminal.write_line(&echo.console, text_buffer.as_string(&line))
    runtime.log_info("home has % %", count, if count == 1 { "entry" } else { "entries" })
}

/**
 * Answer a line: "echo: " and the line written, the line logged, then the command it names, if any, done.
 *
 * @param echo The program's state: the answer's written on its terminal, and a command's asked of its powerbox,
 *     as command does.
 * @param line The line typed, which stays the caller's; an empty line isn't answered. Only as much of it as fits
 *     LINE_BYTES is in the answer.
 */
answer :: fn(echo: ptr[mut Echo], line: string) {
    if line.count == 0 {
        return void
    }
    runtime.log_info("read %", line)
    storage : u8[LINE_BYTES + 8]
    answered := text_buffer.make(storage)
    text_buffer.append(&answered, "echo: ")
    text_buffer.append(&answered, line)
    say(echo, text_buffer.as_string(&answered))
    command(echo, line)
}

/**
 * Do what a line asks of the powerbox, if it's one of its commands: open, reopen, adduser, save and its text, or list.
 *
 * @param echo The program's state, whose powerbox is asked, waiting for its answer, and whose terminal shows the
 *     outcome; without a powerbox, a command only says there's none.
 * @param line The line typed; one that's none of the commands, or "save " without text, does nothing.
 */
command :: fn(echo: ptr[mut Echo], line: string) {
    if line == "open" {
        open_chosen(echo)
    }
    else if line == "reopen" {
        reopen_kept(echo)
    }
    else if line == "adduser" {
        add_user(echo)
    }
    else if line.count > 5 && line[0..<5] == "save " {
        save_chosen(echo, line[5..<line.count])
    }
    else if line == "list" {
        list_chosen(echo)
    }
}

/**
 * Ask the powerbox for a file to read, which the user chooses on the trusted path, and show its first line.
 *
 * @param echo The program's state, whose powerbox is asked and whose terminal shows the line or the refusal.
 */
open_chosen :: fn(echo: ptr[mut Echo]) {
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestFile(powerbox_protocol.FileRequest.{
        purpose = os.append(&out, string_bytes("to show what's in it")), suggested = os.append(&out, string_bytes("")), write = false})
    into := os.Incoming.{}
    if !ask_box(echo, &out, &into, true) {
        return void
    }
    show_first_line(echo, &into)
}

/**
 * Ask the powerbox to open what was kept as "notes" again, read only and without asking the user, and show its first
 * line.
 *
 * @param echo The program's state, whose powerbox is asked and whose terminal shows the line or the refusal.
 */
reopen_kept :: fn(echo: ptr[mut Echo]) {
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .Reopen(powerbox_protocol.Reopening.{key = os.append(&out, string_bytes("notes")), kind = .File, write = false})
    into := os.Incoming.{}
    if !ask_box(echo, &out, &into, false) {
        return void
    }
    show_first_line(echo, &into)
}

/**
 * Show the first line of the file the powerbox's answer gives, or say that it gave nothing.
 *
 * Only the file's first 200 bytes are read, so a longer first line is cut there. The file is closed after.
 *
 * @param echo The program's state, whose terminal shows the line.
 * @param into The powerbox's answer: GrantedReadOnlyFile for a file to read; any other answer is a refusal.
 */
show_first_line :: fn(echo: ptr[mut Echo], into: ptr[mut os.Incoming]) {
    match os.message_of[powerbox_protocol.Response](into)^ {
        case GrantedReadOnlyFile(given) => {
            file, error :: os.file_on(given.end, false)
            if error != null {
                say(echo, "The file couldn't be read.")
                return void
            }
            buffer : u8[200]
            read :: os.read(file, buffer[0..<buffer.count]) or_else 0
            os.close(file)
            count :: if read <= buffer.count { read } else { buffer.count }
            first := count
            for byte, i in buffer {
                if i >= count {
                    break
                }
                if byte == 0x0a {
                    first = i
                    break
                }
            }
            storage : u8[256]
            line := text_buffer.make(storage)
            text_buffer.append(&line, "It says: ")
            if first > 0 && first <= buffer.count {
                text_buffer.append(&line, string_of(&buffer[0], first))
            }
            say(echo, text_buffer.as_string(&line))
            runtime.log_info("read a file the powerbox gave")
        }
        case _ => refused(echo)
    }
}

/**
 * Ask the powerbox for a file to write, which the user chooses on the trusted path, notes.txt suggested and kept as
 * "notes" for reopen, and write text in it.
 *
 * @param echo The program's state, whose powerbox is asked and whose terminal says whether it was saved.
 * @param text The text written, from the file's start; the file is closed after.
 */
save_chosen :: fn(echo: ptr[mut Echo], text: string) {
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestFile(powerbox_protocol.FileRequest.{
        purpose = os.append(&out, string_bytes("to save a line in it")), suggested = os.append(&out, string_bytes("notes.txt")), write = true,
        keep = os.append(&out, string_bytes("notes"))})
    into := os.Incoming.{}
    if !ask_box(echo, &out, &into, true) {
        return void
    }
    match os.message_of[powerbox_protocol.Response](&into)^ {
        case GrantedFile(given) => {
            file, error :: os.file_on(given.end, true)
            if error != null {
                say(echo, "The file couldn't be written.")
                return void
            }
            written :: os.write(file, text)
            os.close(file)
            say(echo, if written == null { "Saved." } else { "The file couldn't be written." })
            runtime.log_info("saved a line in a file the powerbox gave")
        }
        case _ => refused(echo)
    }
}

/**
 * Ask the powerbox for a directory to read, which the user chooses on the trusted path, and name its entries.
 *
 * The entries are listed one request at a time, until the directory answers something other than an entry; names past
 * the line's room are cut. The directory's channel is closed after.
 *
 * @param echo The program's state, whose powerbox is asked and whose terminal shows the entries or the refusal.
 */
list_chosen :: fn(echo: ptr[mut Echo]) {
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestDirectory(powerbox_protocol.DirectoryRequest.{
        purpose = os.append(&out, string_bytes("to list what's in it")), write = false})
    into := os.Incoming.{}
    if !ask_box(echo, &out, &into, true) {
        return void
    }
    match os.message_of[powerbox_protocol.Response](&into)^ {
        case GrantedReadOnlyDirectory(given) => {
            defer slop_os.handle_close(cast[slop_os.Handle](given.end))
            port :: os.port_for(slop_os.startup_block().budget, given.end) or_return void
            defer slop_os.handle_close(cast[slop_os.Handle](port))
            storage : u8[256]
            line := text_buffer.make(storage)
            names_storage : u8[200]
            names := text_buffer.make(names_storage)
            count := cast[u64](0)
            cursor := cast[u64](0)
            loop {
                asking := os.Outgoing.{}
                os.begin[read_only_dir.Request](&asking)^ = .List(cursor)
                if read_only_dir.send_request(given.end, port, &asking) is_some {
                    break
                }
                listed := os.Incoming.{}
                match read_only_dir.receive_response(given.end, port, &listed, true) {
                    case Received => {}
                    case _ => break
                }
                match os.message_of[read_only_dir.Response](&listed)^ {
                    case Listed(entry) => {
                        name :: os.items(&listed, entry.name)
                        if count > 0 {
                            text_buffer.append(&names, ", ")
                        }
                        if name.count > 0 {
                            text_buffer.append(&names, string_of(&name[0], name.count))
                        }
                        count += 1
                        cursor = entry.next
                    }
                    case _ => break
                }
            }
            text_buffer.append(&line, "It has ")
            text_buffer.append_unsigned(&line, count)
            text_buffer.append(&line, if count == 1 { " entry" } else { " entries" })
            text_buffer.append(&line, if count > 0 { ": " } else { "." })
            text_buffer.append(&line, text_buffer.as_string(&names))
            say(echo, text_buffer.as_string(&line))
            runtime.log_info("listed a directory the powerbox gave")
        }
        case _ => refused(echo)
    }
}

/**
 * Ask the powerbox for another account, made once the administrator allows it on the trusted path, where its name and
 * password are typed too, and say the new account's name.
 *
 * @param echo The program's state, whose powerbox is asked and whose terminal shows the account's name or the refusal.
 */
add_user :: fn(echo: ptr[mut Echo]) {
    out := os.Outgoing.{}
    request :: os.begin[powerbox_protocol.Request](&out)
    request^ = .RequestAccount(powerbox_protocol.AccountRequest.{purpose = os.append(&out, string_bytes("to let someone else use this computer"))})
    into := os.Incoming.{}
    if !ask_box(echo, &out, &into, true) {
        return void
    }
    match os.message_of[powerbox_protocol.Response](&into)^ {
        case AccountMade(made) => {
            name :: os.items(&into, made)
            storage : u8[96]
            line := text_buffer.make(storage)
            text_buffer.append(&line, "Made the account ")
            if name.count > 0 {
                text_buffer.append(&line, string_of(&name[0], name.count))
            }
            text_buffer.append(&line, ".")
            say(echo, text_buffer.as_string(&line))
            runtime.log_info("the powerbox made an account")
        }
        case _ => refused(echo)
    }
}

/**
 * Send a request to the powerbox and wait for its answer, which waits for the user if it asks them.
 *
 * @param echo The program's state, whose powerbox is asked; without one, it says there's no powerbox to ask.
 * @param out The request, put together by the caller.
 * @param into Where the answer is received, for the caller to read when this returns true.
 * @param asks_user Whether the request asks the user, so the terminal first says how to see what's asked.
 * @return True with the answer in into; false without a powerbox, or if the request couldn't be sent or the answer
 *     received, each said on the terminal.
 */
ask_box :: fn(echo: ptr[mut Echo], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming], asks_user: bool) -> bool {
    if echo.box_end == NONE {
        say(echo, "There's no powerbox to ask.")
        return false
    }
    if asks_user {
        say(echo, "Asked the powerbox; Ctrl+Alt+Delete shows what it asks.")
    }
    if powerbox_protocol.send_request(echo.box_end, echo.box_port, out) != null {
        refused(echo)
        return false
    }
    loop {
        match powerbox_protocol.receive_response(echo.box_end, echo.box_port, into, true) {
            case Received => return true
            case Failed(error) => {
                refused(echo)
                return false
            }
            case _ => continue
        }
    }
}

/**
 * Say on the terminal, and in the log, that the powerbox gave nothing.
 *
 * @param echo The program's state, whose terminal it's said on.
 */
refused :: fn(echo: ptr[mut Echo]) {
    say(echo, "The powerbox gave nothing.")
    runtime.log_info("the powerbox gave nothing")
}

/**
 * Write a line on the terminal, ignoring a failure: a terminal that's gone is noticed when the next line is read.
 *
 * @param echo The program's state, whose terminal it's written on.
 * @param text The line, without its line feed.
 */
say :: fn(echo: ptr[mut Echo], text: string) {
    _ = terminal.write_line(&echo.console, text)
}
