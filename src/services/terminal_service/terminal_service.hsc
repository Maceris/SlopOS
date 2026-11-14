/**
 * The terminal service (decisions/0136, 0137, 0138, design/console-and-sessions.md §2, §3), which replaced the
 * console service of decisions/0075 and 0077. It serves the console's terminal over the terminal protocol, keeping
 * what it shows in a screen model (src/screen): what its clients write goes into the model, a grapheme cluster at a
 * time, made safe (safe_text) so text can't become a control sequence, and is shown on the first serial line through
 * the VT adapter and, if there's one, on the framebuffer, drawn from the model (src/glyph_screen): one console, shown
 * on both. The top row is the status line, which only this service writes; programs have the rows below it.
 *
 * What's typed, on the serial line or the seat's keyboards, which the input service types through its keymap, becomes
 * typed input for the client that reads it first, except the secure attention key, Ctrl+Alt+Delete (on the serial line
 * as a terminal sends it, CSI 3;7~; from the input service as itself): that brings up this service's own screen, which
 * every key goes to until Esc or Enter leaves it, and the program's screen is drawn again from the model. A new
 * keyboard's code, which the input service makes, is shown on the status line until it's typed on it.
 *
 * The input's owner can hand it the line it's editing (InputLine, decisions/0147): kept below everything written in
 * lines, it's taken away before anything else is written, cleared, moved or scrolled, the cursor put back where the
 * output left off, and drawn again after, on the row after the output's if that one has something on it.
 *
 * First-boot setup (decisions/0148): with no accounts, which it asks the account service, its own screen asks for the
 * administrator's name and password, twice, has the account service make the account, and shows the recovery code
 * once. Every key is its own until then, as the secure attention key's screen's are. Then, and with accounts, its
 * login screen (decisions/0150) asks for a name and password, with the keyboard layout on the status line, which F2
 * changes; the account service opens the account's home volume with them, and the session manager makes the session,
 * with a terminal connection of its own and the home's root. With no account service, a boot with no accounts, the
 * session manager makes a session with no user at once.
 *
 * Several sessions (decisions/0151): each has a view of its own, which its programs write to, one shown at a time. The
 * secure attention key's screen switches to the next (S), logs in another (N), locks the console until the session's
 * user's password is typed (L), and logs out (O), the session manager ending the session's programs. A session's
 * powerbox asks the user through it (chooser.hsc, decisions/0156): the request's on the status line, and the secure
 * attention key opens the chooser instead of this screen, and G there shows what its user has let programs keep
 * (grants_view.hsc, decisions/0158); a request for another account opens the elevation screen instead (elevation.hsc),
 * and H there shares a volume with another user (share_form.hsc). P on it shuts the system down, for whoever's at the
 * console (decisions/0180), through the supervisor.
 *
 * The serial line and the input service are reached through connectors, dialed again when they go, with the banner
 * shown on each new serial line. Without a serial line it keeps the model and shows nothing.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import unicode from "std"
import terminal from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import time from "std"
import account_records from "../../account_records"
import accounts from "../../protocols/accounts"
import keymaps from "../../keymaps"
import dir from "std/os/slop_os"
import connector from "../../protocols/connector"
import seat from "../../protocols/seat"
import session from "../../protocols/session"
import power_protocol from "../../protocols/power"
import prompt from "../../protocols/prompt"
import serial from "../../protocols/serial"
import service_kit from "../../libraries/service_kit"
import safe_text from "../../safe_text"
import screen from "../../screen"
import glyph_screen from "../../glyph_screen"
import vt from "../../vt"

/** The port key the serial line's connection is bound under, above the clients'. */
SERIAL_KEY : u64 : 1000
/** The port key the input service's connection is bound under, above the clients'. */
SEAT_KEY : u64 : 1001
/** The port key the account service's connection is bound under, above the clients'. */
ACCOUNTS_KEY : u64 : 1002
/** The line shown on each new serial line before anything else. */
BANNER :: "SlopOS console"
/** No channel: what a connection or end not had is set to. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
/** The columns between tab stops: a tab is written as spaces to the next multiple of it. */
TAB_STOP : u16 : 8
/** The console's width in columns, the screen model's. */
COLUMNS : u16 : screen.COLUMNS
/** The console's height in rows, the status line's included. */
ROWS : u16 : screen.ROWS
/** The rows programs have, below the status line; a program's row 0 is the console's row 1. */
PROGRAM_ROWS : u16 : screen.PROGRAM_ROWS

/** The status line with no one logged in to the view, as before a login or with no account service. */
STATUS :: " SlopOS │ console │ no session"
/** The status line while the secure attention key's screen is up. */
STATUS_ATTENTION :: " SlopOS │ console │ secure attention"
/** The status line during first-boot setup, followed by the keyboard layout. */
STATUS_SETUP :: " SlopOS │ console │ first-boot setup"
/** The status line on the login screen, followed by the keyboard layout. */
STATUS_LOGIN :: " SlopOS │ console │ log in"
/** The status line of the session with no user, on a boot with no accounts. */
STATUS_NO_ACCOUNTS :: " SlopOS │ console │ no accounts"
/** The status line while the console is locked. */
STATUS_LOCKED :: " SlopOS │ console │ locked"

/** The bytes of output kept waiting for the serial line; what's emitted past them is dropped. */
OUTPUT_BYTES :: 16384
/** How many Writes may be sent on the serial line before one is answered, which its ring holds. */
MAX_IN_FLIGHT : u32 : 2

/** The USB HID usage of Backspace, which takes back the last cluster typed in a field. */
USAGE_BACKSPACE : u16 : 0x2a
/** The USB HID usage of F2, which changes the keyboard layout on the setup and login screens. */
USAGE_F2 : u16 : 0x3b
/** The USB HID usage of C, which with Control is an interrupt for the program. */
USAGE_C : u16 : 0x06
/** The USB HID usage of E, which ends the program chosen on the secure attention key's screen. */
USAGE_E : u16 : 0x08
/** The USB HID usage of L, which locks the console from the secure attention key's screen. */
USAGE_L : u16 : 0x0f
/** The USB HID usage of N, which logs in another session from the secure attention key's screen. */
USAGE_N : u16 : 0x11
/** The USB HID usage of O, which logs out from the secure attention key's screen. */
USAGE_O : u16 : 0x12
/** The USB HID usage of S, which switches to the next session from the secure attention key's screen. */
USAGE_S : u16 : 0x16
/** The USB HID usage of P, which shuts the system down from the secure attention key's screen (decisions/0180). */
USAGE_P : u16 : 0x13
/** The USB HID usage of R, which restarts the system from the secure attention key's screen (decisions/0182). */
USAGE_R : u16 : 0x15
/** The USB HID usage of Enter. */
USAGE_ENTER : u16 : 0x28
/** The USB HID usage of Escape. */
USAGE_ESCAPE : u16 : 0x29
/** The USB HID usage of Delete, which with Control and Alt is the secure attention key. */
USAGE_DELETE : u16 : 0x4c
/** The USB HID usage of the Down arrow. */
USAGE_DOWN : u16 : 0x51
/** The USB HID usage of the Up arrow. */
USAGE_UP : u16 : 0x52
/** The panel row the secure attention key's screen starts its list of programs on. */
PROGRAMS_ROW : u16 : 7
/** The most bytes of the boot before's panic line kept to show; a longer one is cut short. */
PANIC_TEXT :: 160
/**
 * Bytes typed on the serial line decoded at a time, so the trusted path looks at each slice's keys before the next is
 * decoded; fewer than the events held.
 */
FEED_SLICE : usize : 8
/** The most sessions' views, so the most sessions at once, the login screen's included. */
MAX_VIEWS :: 4
/** No view: a client's view when it's in none, and another_session's answer when there's no other. */
NO_VIEW : usize : 0xffffffff
/** The most bytes of the line the input's owner is editing kept; a longer line is cut short. */
INPUT_LINE_BYTES :: 512

/** Which step the trusted path's own screen is at: first-boot setup (decisions/0148), login, elevation, or sharing. */
SetupStep :: enum {
    /** None: no screen of setup's is up, and keys go to programs or the secure attention key's screen. */
    Off,
    /** The new account's name being typed. */
    Name,
    /** The new account's password being typed, checked against the rules on Enter. */
    Password,
    /** The new account's password typed again, compared on Enter. */
    Again,
    /** The account service making the account, which takes Argon2id's time; keys are ignored. */
    Making,
    /** The recovery code shown, until Enter. */
    Code,
    /** Logging in (decisions/0150): the name being typed. */
    LoginName,
    /** Logging in: the password being typed, or, while locked, the session's user's. */
    LoginPassword,
    /** Logging in: the account service opening the home and the session being made; keys are ignored. */
    LoggingIn,
    /** Elevation (decisions/0158): the administrator's name being typed, before the new account's. */
    AdminName,
    /** Elevation: the administrator's password being typed. */
    AdminPassword,
    /** Sharing a volume: its name being typed. */
    ShareName,
    /** Sharing a volume: the member's name being typed. */
    ShareMember,
    /** Sharing a volume: the account service sharing it; keys are ignored. */
    Sharing,
    /** Debugging a program of the user's own session (decisions/0185): Enter allows it, Escape refuses. */
    Confirm,
}

/** The panel row of setup's first field: the name, the password, it again, then a blank row and its message. */
SETUP_FIELDS_ROW : u16 : 6
/** The most bytes a field typed on setup's screens holds; what's typed past them is dropped. */
FIELD_BYTES :: 256
/** The most bytes of what setup's screens last said; a longer message is cut short. */
MESSAGE_BYTES :: 160

/**
 * The terminal service's state: its connections, the sessions' views, the input waiting, and the trusted path's
 * screens. There's one, made by main and kept for as long as the service runs.
 */
Service :: struct {
    /** The kernel debug log it was given, or NO_HANDLE without one. */
    log : slop_os.DebugLog,
    /** The port every connection is bound to and the service waits on: clients under their index, others by key. */
    port : slop_os.Port,
    /** The connector to the serial line, dialed again whenever the line goes; NONE without one. */
    serial_connector : slop_os.Channel,
    /** The connector to the input service, dialed again whenever it goes; NONE without one. */
    seat_connector : slop_os.Channel,
    /** The serial line's connection, bound under SERIAL_KEY; NONE while there's none. */
    line_end : slop_os.Channel,
    /** Whether a Read to the serial line is waiting for its answer, so another isn't sent. */
    line_reading : bool,
    /** The input service's connection, bound under SEAT_KEY; NONE while there's none. */
    seat_end : slop_os.Channel,
    /** Whether a Read to the input service is waiting for its answer, so another isn't sent. */
    seat_reading : bool,
    /**
     * The keys the input service gave that wait for room among the decoded input, in order, the first typed_count;
     * each one's text_start is into typed_text.
     */
    typed : seat.Event[TYPED_KEYS],
    /** How many of typed are waiting, 0 to TYPED_KEYS; keys past them are dropped. */
    typed_count : usize,
    /** The waiting keys' text, UTF-8, the first typed_text_count bytes. */
    typed_text : u8[TYPED_TEXT],
    /** How many bytes of typed_text are used, 0 to TYPED_TEXT. */
    typed_text_count : usize,
    /** What's waiting to be sent on the serial line: a ring of output_count bytes from output_start. */
    output : u8[OUTPUT_BYTES],
    /** Where in output the oldest byte waiting is, below OUTPUT_BYTES. */
    output_start : usize,
    /** How many bytes are waiting in output, 0 to OUTPUT_BYTES. */
    output_count : usize,
    /** How many Writes on the serial line haven't been answered, 0 to MAX_IN_FLIGHT. */
    in_flight : u32,
    /** The sessions' views (decisions/0151), each in use or not. */
    views : View[MAX_VIEWS],
    /**
     * The index of the view in use, which view() gives: the active one, but while another session's client is served,
     * that session's.
     */
    viewing : usize,
    /** The index of the active view, the one shown on the console. */
    active : usize,
    /** Each client's view by the client's index; NO_VIEW for a client in none, which writes to the active one. */
    client_view : usize[service_kit.MAX_CLIENTS],
    /** The framebuffer it's drawn on, mapped, valid only when has_canvas. */
    canvas : glyph_screen.Canvas,
    /** Whether there's a framebuffer to draw on; without one only the serial line shows the console. */
    has_canvas : bool,
    /** Whether the secure attention key's screen is up, which every key goes to. */
    attention : bool,
    /** A new keyboard's code, shown on the status line until it's typed on it; 0 for none. */
    waiting_code : u32,
    /** The session channel to whoever runs the console's programs (decisions/0139), the session manager; or NONE. */
    session_end : slop_os.Channel,
    /** A port of session_end's own, which its answers are waited on, apart from the service's port. */
    session_port : slop_os.Port,
    /** The programs listed for the secure attention key's screen, the first program_count. */
    programs : session.Program[session.MAX_PROGRAMS],
    /** How many of programs are used, 0 to session.MAX_PROGRAMS. */
    program_count : usize,
    /** The index in programs of the one chosen on the panel, which E ends. */
    chosen : usize,
    /** The first line of the boot before's panic record, if it stopped for a fault, the first panic_count bytes. */
    panic : u8[PANIC_TEXT],
    /** How many bytes of panic are used; 0 if the boot before didn't panic. */
    panic_count : usize,
    /** Whether the secure attention key's screen has been up since, so the status line stops pointing to it. */
    panic_seen : bool,
    /** The decoder of what's typed on the serial line, which keeps an escape sequence cut between reads. */
    decoder : vt.Decoder,
    /**
     * The input waiting for the active view's owner, decoded as terminal events, so the trusted path takes what's its
     * own before any program sees it.
     */
    decoded : vt.Decoded,
    /** The connector to the account service, dialed again whenever it goes; NONE for a boot with no accounts. */
    accounts_connector : slop_os.Channel,
    /** The account service's connection, bound under ACCOUNTS_KEY; NONE while there's none. */
    accounts_end : slop_os.Channel,
    /**
     * The supervisor's power connection, which P on the secure attention key's screen asks to shut down on
     * (decisions/0180); null without one. Nothing's waited for on it.
     */
    power : os.Channel[power_protocol.Power]?,
    /** The SSH service's public directory, read only, its host_key.pub shown on the secure attention key's screen. */
    ssh_public : os.Channel[read_only_dir.ReadOnlyDir]?,
    /** Whether a shutdown or a restart's been asked for, which the secure attention key's screen then says. */
    shutting_down : bool,
    /** Whether what was asked for is a restart rather than a shutdown; meaningful once shutting_down is set. */
    restarting : bool,
    /** The step of the trusted path's own screen: setup, login, elevation or sharing; Off for none. */
    setup : SetupStep,
    /** The field being typed, the first field_count bytes; zeroed whenever a step changes. */
    field : u8[FIELD_BYTES],
    /** How many bytes of field are used, 0 to FIELD_BYTES. */
    field_count : usize,
    /** The account name taken from a field, for setup, login, lock or elevation, the first name_count bytes. */
    name : u8[account_records.MAX_NAME_BYTES],
    /** How many bytes of name are used. */
    name_count : usize,
    /** The new account's password typed once, to compare with it again; zeroed once it's sent. */
    password : u8[FIELD_BYTES],
    /** How many bytes of password are used. */
    password_count : usize,
    /** What the screen last said, such as why something was refused, the first message_count bytes. */
    message : u8[MESSAGE_BYTES],
    /** How many bytes of message are used; 0 for nothing said. */
    message_count : usize,
    /** The recovery code of the account just made, shown once at the Code step, zeroed once it's left. */
    code : u8[accounts.RECOVERY_TEXT_BYTES],
    /** The terminal protocol's clients, each bound to port under its index. */
    connected : service_kit.Clients,
    /** The keyboard layout's name, as keymaps knows it, chosen on the login screen and given to new sessions. */
    layout : string,
    /** The view a login for another session was started from, which Escape goes back to. */
    previous : usize,
    /** Whether the login screen is unlocking the console, asking only for the session's user's password. */
    unlocking : bool,
    /** Whether the secure attention key brought up the powerbox's chooser, which keys then go to. */
    choosing : bool,
    /** The chooser's state, while choosing. */
    chooser : Chooser,
    /** Whether G brought up the grants view, which keys then go to. */
    granting : bool,
    /** The grants view's state, while granting. */
    grants : GrantsView,
    /** Whether setup's screen is elevation's, making an account a program asked for. */
    elevating : bool,
    /** The administrator's name typed on the elevation screen, the first admin_count bytes. */
    admin : u8[account_records.MAX_NAME_BYTES],
    /** How many bytes of admin are used. */
    admin_count : usize,
    /** The administrator's password typed on the elevation screen; zeroed once it's sent. */
    admin_password : u8[FIELD_BYTES],
    /** How many bytes of admin_password are used. */
    admin_password_count : usize,
    /** Whether setup's screen is the share form. */
    sharing : bool,
    /** Whether the share form's request takes a member out of the volume (Unshare), not shares it. */
    unsharing : bool,
    /** The volume's name typed on the share form, the first share_name_count bytes. */
    share_name : u8[account_records.MAX_NAME_BYTES],
    /** How many bytes of share_name are used. */
    share_name_count : usize,
}

/**
 * A session's view (decisions/0151): what it shows, its input's owner and the line that owner's editing, and whose it
 * is; one is shown at a time, and the others keep what their programs write for when they're switched to.
 */
View :: struct {
    /** Whether the view belongs to a session, or to a login screen; one not in use is free for another. */
    in_use : bool,
    /** The screen model: the status line, the program's lines or whole screen, and the trusted path's panel. */
    screen : screen.Screen,
    /** The index of the client that owns its input, the first to Read; null for none. */
    owner : usize?,
    /** How many events the owner's Read asked for, which deliver sends at most; 0 when no Read is held. */
    held : u32,
    /** The line the owner's editing (InputLine, decisions/0147), the first input_count bytes, UTF-8. */
    input : u8[INPUT_LINE_BYTES],
    /** How many bytes of input are used; 0 for no line, which isn't drawn. */
    input_count : usize,
    /** Where in input the cursor is, a byte offset, 0 to input_count. */
    input_cursor : usize,
    /** Whether the line is drawn below the output now. */
    input_drawn : bool,
    /** The program row the line starts on, while it's drawn. */
    input_row : u16,
    /** While the line's drawn, the program row the output goes on from. */
    output_row : u16,
    /** While the line's drawn, the column the output goes on from. */
    output_column : u16,
    /** The lines' scroll count when the line was drawn, so output_row is moved up by what's scrolled since. */
    output_scrolls : u64,
    /** The name of the session's user, the first user_count bytes; empty for a session with no user. */
    user : u8[account_records.MAX_NAME_BYTES],
    /** How many bytes of user are used. */
    user_count : usize,
    /** Whether a session runs in the view, made by the session manager; false on a login screen. */
    logged_in : bool,
    /** The session manager's number for the session, valid while logged_in. */
    session : u32,
    /**
     * The index of the client its session was started with, the connection its first program was given; null without
     * a session. When it goes, its first program has ended, and the session ends with it (session_left).
     */
    first_client : usize?,
    /** Its powerbox's prompt connection, bound under PROMPT_KEY plus the view's index; NONE without one. */
    prompt_end : slop_os.Channel,
    /** Whether a request from the powerbox is waiting on the user, in ask. */
    asking : bool,
    /** The powerbox's request waiting, while asking. */
    ask : Asked,
    /** A connection of its own to the session's home, for the grants view and the share form; NONE without one. */
    home_end : slop_os.Channel,
}

/**
 * Serve the console's terminal: show what programs write on the serial line and the framebuffer, give them what's
 * typed, and run the trusted path, the secure attention key's screen, first-boot setup, login, and the sessions.
 *
 * It runs until the system stops, serving its clients and the connections it dials in one loop.
 *
 * @param log The kernel debug log, for its own messages. Without one, they go nowhere.
 * @param serial_line A connector to the serial line, dialed for its connection, and again whenever it goes. Without
 *     one, nothing is shown on a serial line, and the screen model alone keeps what's written.
 * @param input A connector to the input service, which gives the seat's keyboards' keys, the secure attention key, and
 *     new keyboards' codes. Without one, only what's typed on the serial line is input.
 * @param framebuffer The framebuffer's pixels, a memory object mapped to draw the console on. Without it, or without
 *     framebuffer_layout, the console is shown on the serial line only.
 * @param framebuffer_layout A page holding the framebuffer's layout (slop_os.FramebufferLayout): its width, height and
 *     pitch. Needed with framebuffer.
 * @param programs A session channel to the session manager, which makes sessions, lists and ends their programs, and is
 *     told which session is shown. Without one, no session is made and the secure attention key's screen lists no
 *     programs.
 * @param last_panic The boot before's panic record, a memory object of text, if it stopped for a fault; its first line
 *     is shown on the secure attention key's screen and pointed to from the status line. Without one, nothing is.
 * @param accounts_service A connector to the account service, for first-boot setup, login, locking, elevation and
 *     sharing. Without one, a boot with no accounts, the session with no user is made at once.
 * @param power A connection to the supervisor, which P on the secure attention key's screen asks to shut the system
 *     down on (decisions/0180). Without one, the screen offers no P.
 * @param clients The terminal protocol's listener, which programs connect through; their Connects bring more clients.
 * @return 2 if its port couldn't be made, or 3 if the listener couldn't be added as a client; it doesn't return
 *     otherwise.
 */
main :: fn(log: slop_os.DebugLog?, serial_line: os.Channel[connector.Connector]?, input: os.Channel[connector.Connector]?,
    framebuffer: slop_os.Memory?, framebuffer_layout: slop_os.Memory?, programs: os.Channel[session.Session]?,
    last_panic: slop_os.Memory?, accounts_service: os.Channel[connector.Connector]?, power: os.Channel[power_protocol.Power]?,
    ssh_public: os.Channel[read_only_dir.ReadOnlyDir]?, clients: os.Listener[terminal.Terminal]) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    service.power = power
    service.ssh_public = ssh_public
    service.serial_connector = NONE
    service.seat_connector = NONE
    service.line_end = NONE
    service.seat_end = NONE
    service.session_end = NONE
    service.accounts_connector = NONE
    service.accounts_end = NONE
    match programs {
        case Some(found) => {
            service.session_end = found.end
            service.session_port = os.port_for(startup.budget, found.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case None => {}
    }
    keep_panic(service, last_panic)
    for i in 0..<service.client_view.count {
        service.client_view[i] = NO_VIEW
    }
    open_view(service, 0)
    service.active = 0
    service.viewing = 0
    update_status(service)
    match canvas_on(framebuffer, framebuffer_layout) {
        case Some(made) => {
            service.canvas = made
            service.has_canvas = true
        }
        case None => {}
    }
    service.port = slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(service.port)
    service.layout = keymaps.US.name
    connected :: &service.connected
    if !service_kit.add_client(connected, service.port, clients.end) {
        return 3
    }
    match serial_line {
        case Some(found) => service.serial_connector = found.end
        case None => {}
    }
    match input {
        case Some(found) => service.seat_connector = found.end
        case None => {}
    }
    match accounts_service {
        case Some(found) => service.accounts_connector = found.end
        case None => {}
    }
    dial_seat(service)
    dial_serial(service)
    dial_accounts(service)
    // A boot with no accounts has the one session with no user, at once
    if service.accounts_connector == NONE {
        start_session(service, null)
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(service, connected, i, &into)
            i += 1
        }
        while i < connected.count
        take_serial(service, &into)
        take_seat(service, &into)
        take_accounts(service, &into)
        take_prompts(service, &into)
        deliver(service, connected)
        // Keys that waited for room, decoded now that a delivery's made some, and the serial line read again if it waited
        take_typed(service)
        read_more(service)
        pump(service)
        draw_framebuffer(service)
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Make a canvas on the framebuffer: its layout page mapped read only, and its pixels mapped readable and writable, as
 * the layout says they're laid out.
 *
 * The mappings are kept for as long as the service runs; one made before a failure isn't undone.
 *
 * @param framebuffer The framebuffer's pixels, a memory object; null for no framebuffer.
 * @param layout_page A page holding its slop_os.FramebufferLayout; null for none.
 * @return The canvas; null without either memory object, if addresses or mappings couldn't be had, if the pixels'
 *     memory is smaller than pitch times height, or if glyph_screen can't draw on the layout.
 */
canvas_on :: fn(framebuffer: slop_os.Memory?, layout_page: slop_os.Memory?) -> glyph_screen.Canvas? {
    pixels :: framebuffer or_return null
    page :: layout_page or_return null
    block :: slop_os.startup_block()
    layout_at :: runtime.reserve_addresses(cast[usize](4096)) or_return null
    slop_os.memory_map(page, block.space, layout_at, 0, 4096, slop_os.PROTECTION_READ) or_return null
    layout :: cast[ptr[slop_os.FramebufferLayout]](layout_at)^
    size :: slop_os.memory_size(pixels) or_return null
    at :: runtime.reserve_addresses(cast[usize](size)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(pixels, block.space, at, 0, size, read_write) or_return null
    if cast[u64](layout.pitch) * cast[u64](layout.height) > size {
        return null
    }
    made :: glyph_screen.make_canvas(at, layout) or_return null
    runtime.log_info("drawing on the framebuffer, %x%", layout.width, layout.height)
    return made
}

/**
 * Draw what changed in the view in use on the framebuffer, if there's one, with the cursor where a program's is; the
 * cursor isn't drawn while the secure attention key's screen is up.
 *
 * @param service The service's state, from its main loop: when has_canvas, its canvas is drawn on from the view in
 *     use's screen model, whose changed rows are marked drawn; without a canvas nothing happens.
 */
draw_framebuffer :: fn(service: ptr[mut Service]) {
    if service.has_canvas {
        glyph_screen.draw(&service.canvas, &view(service).screen, !service.attention)
    }
}

/**
 * Dial the serial line through its connector, if there's one: bind its connection to the port under SERIAL_KEY, show
 * the banner, make the rows below the status line the ones that scroll, draw the status line, and hold a Read.
 *
 * It waits for the connector's answer. If the dial or the bind fails, the line stays NONE, and isn't tried again until
 * something calls this again. Writes in flight are forgotten, as the old line's are gone.
 *
 * @param service The service, its line_end NONE.
 */
dial_serial :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.serial_connector) or_return void
    line :: connector.dial[serial.Serial](service.serial_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](line.end), signals, SERIAL_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](line.end))
            return void
        }
    }
    service.line_end = line.end
    service.line_reading = false
    service.in_flight = 0
    // Firmware may have left a line unfinished on the same console
    storage : u8[96]
    shown := text_buffer.make(storage)
    vt.append_line_break(&shown)
    text_buffer.append(&shown, BANNER)
    vt.append_line_break(&shown)
    vt.append_margins(&shown, 1, ROWS - 1)
    vt.append_move(&shown, ROWS - 1, 0)
    emit(service, string_bytes(text_buffer.as_string(&shown)))
    draw_status(service)
    read_more(service)
    pump(service)
}

/**
 * Dial the input service through its connector, if there's one: bind its connection to the port under SEAT_KEY, and
 * hold a Read.
 *
 * It waits for the connector's answer. If the dial or the bind fails, the input service stays NONE.
 *
 * @param service The service, its seat_end NONE.
 */
dial_seat :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.seat_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.seat_connector) or_return void
    keys :: connector.dial[seat.Seat](service.seat_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](keys.end), signals, SEAT_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](keys.end))
            return void
        }
    }
    service.seat_end = keys.end
    service.seat_reading = false
    // Read first: the input service takes a Lend only from its reader
    read_seat(service)
    lend_seat(service)
}

/**
 * Lend the seat to the compositor, if one reads it (decisions/0192, 15c), unless the trusted path's screen or setup is
 * up: the secure attention key, or a new keyboard, brings it back.
 *
 * @param service The service; without the input service, nothing is sent.
 */
lend_seat :: fn(service: ptr[mut Service]) {
    if service.seat_end == NONE || service.attention || service.setup != .Off {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[seat.Request](&out)
    request^ = .Lend(true)
    _ = seat.send_request(service.seat_end, service.port, &out)
}

/**
 * Serve every request waiting from one client, in its own session's view.
 *
 * Writes, cursor moves, clears and scrolls go into the view's screen model, and onto the serial line if the view is
 * shown and nothing of the trusted path's is up; the line being typed is taken away first and drawn again after. A
 * Read makes the client the input's owner if there's none: it holds until the owner goes, or gives it up with
 * ReleaseInput, when a Read it holds is answered empty. An InputLine from the owner replaces the line. Describe is
 * answered at once; requests it doesn't know are answered Unsupported. A Connect's new connection is added as a client,
 * or closed if there's no room.
 *
 * A client whose connection fails is dropped, and, if it owned its view's input, the input's freed and its line
 * forgotten.
 *
 * @param service The service's state, from its main loop: the client's view is the one in use while it's served and
 *     the active one after, and its screen model, input owner and line, and the serial queue change as requests say.
 * @param connected The service's clients: a failing client is dropped from it, its end closed, and a Connect's new
 *     end added.
 * @param index The client's index in connected; one past its ends or with no end is skipped.
 * @param into Where requests are received, reused for each.
 */
serve :: fn(service: ptr[mut Service], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match terminal.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = terminal.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                service_kit.drop_client(connected, index)
                use_view_of(service, index)
                match view(service).owner {
                    case Some(owner) => {
                        if owner == index {
                            hide_input(service)
                            view(service).input_count = 0
                            view(service).owner = null
                            view(service).held = 0
                        }
                    }
                    case None => {}
                }
                session_left(service, index)
                use_active(service)
                if index < service.client_view.count {
                    service.client_view[index] = NO_VIEW
                }
                return void
            }
        }
        // Served in its own session's view, which is shown only if it's the active one
        use_view_of(service, index)
        defer use_active(service)
        request :: os.message_of[terminal.Request](into)
        // What's written, cleared, moved or scrolled goes above the line being typed
        moves_output :: match request^ {
            case Write(_) => true
            case MoveCursor(_) => true
            case Clear(_) => true
            case Scroll(_) => true
            case Screen(_) => true
            case _ => false
        }
        if moves_output {
            hide_input(service)
        }
        match request^ {
            case Write(text) => write(service, into, text)
            case MoveCursor(position) => move_cursor(service, position)
            case ShowCursor(shown) => {
                storage : u8[16]
                out := text_buffer.make(storage)
                vt.append_cursor_shown(&out, shown)
                emit_program(service, &out)
            }
            case Clear(area) => clear(service, area)
            case Scroll(scrolled) => scroll(service, scrolled)
            case Screen(whole) => use_screen(service, whole)
            case Bell => {
                storage : u8[4]
                out := text_buffer.make(storage)
                vt.append_bell(&out)
                emit_program(service, &out)
            }
            case Describe => {
                out := os.Outgoing.{}
                response :: os.begin[terminal.Response](&out)
                response^ = .Described(terminal.Features.{columns = COLUMNS, rows = PROGRAM_ROWS, colors = .Rgb,
                    attributes = terminal.BOLD | terminal.DIM | terminal.ITALIC | terminal.UNDERLINE | terminal.INVERSE | terminal.STRIKETHROUGH,
                    links = true, unicode = 17 * 256})
                _ = terminal.send_response(end, service.port, &out)
            }
            case Read(most) => {
                // The first client to read owns the input, until it goes (sessions decide this in 10c)
                owned :: match view(service).owner {
                    case Some(owner) => owner == index
                    case None => true
                }
                if owned {
                    view(service).owner = index
                    view(service).held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case InputLine(line) => {
                if is_owner(service, index) {
                    hide_input(service)
                    bytes :: os.items(into, line.text)
                    view(service).input_count = if bytes.count < view(service).input.count { bytes.count } else { view(service).input.count }
                    for byte, i in bytes {
                        if i < view(service).input.count {
                            view(service).input[i] = byte
                        }
                    }
                    view(service).input_cursor = if cast[usize](line.cursor) < view(service).input_count { cast[usize](line.cursor) } else { view(service).input_count }
                    show_input(service)
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
            // The owner gives the input up (decisions/0179, 11e5): its line taken away, a Read it holds answered empty
            case ReleaseInput => {
                if is_owner(service, index) {
                    hide_input(service)
                    view(service).input_count = 0
                    if view(service).held > 0 {
                        none : terminal.Event[1]
                        no_text : u8[1]
                        out := os.Outgoing.{}
                        answer :: os.begin[terminal.Response](&out)
                        answer^ = .Input(terminal.Events.{events = os.append(&out, none[0..<0]), text = os.append(&out, no_text[0..<0])})
                        _ = terminal.send_response(end, service.port, &out)
                    }
                    view(service).owner = null
                    view(service).held = 0
                }
            }
        }
        if moves_output {
            show_input(service)
        }
    }
}

/**
 * Tell whether a client owns the input of the view in use.
 *
 * @param service The service's state, whose view in use's input owner is compared; only read.
 * @param index The client, by its index among the service's clients, compared with the owner's; any index can be
 *     given, and one that isn't the owner's gives false.
 * @return True if it's the owner; false for any other, or when there's none.
 */
is_owner :: fn(service: ptr[mut Service], index: usize) -> bool {
    return match view(service).owner {
        case Some(owner) => owner == index
        case None => false
    }
}

/**
 * Take away the line being typed in the view in use, if it's drawn: clear its rows, and put the cursor back where the
 * output left off, its row moved up by the lines' scrolls since, or at the top if it's scrolled away.
 *
 * The line itself is kept, to be drawn again by show_input.
 *
 * @param service The service's state: the view in use's line is marked not drawn, its rows cleared in its screen
 *     model and the cursor moved back, and that's queued for the serial line if the view's shown.
 */
hide_input :: fn(service: ptr[mut Service]) {
    if !view(service).input_drawn {
        return void
    }
    view(service).input_drawn = false
    grid :: &view(service).screen.lines
    screen.clear(grid, terminal.Area.{row = view(service).input_row, columns = COLUMNS, rows = PROGRAM_ROWS})
    scrolled :: grid.scrolls - view(service).output_scrolls
    grid.row = if cast[u64](view(service).output_row) >= scrolled { view(service).output_row - cast[u16](scrolled) } else { 0 }
    grid.column = view(service).output_column
    storage : u8[32]
    out := text_buffer.make(storage)
    vt.append_move(&out, view(service).input_row + 1, 0)
    vt.append_clear_below(&out)
    vt.append_move(&out, grid.row + 1, grid.column)
    emit_program(service, &out)
}

/**
 * Draw the line being typed in the view in use below the output, if there's one and the program is on lines, not a
 * whole screen.
 *
 * It starts at the start of the row after the output's, if the output's row has something on it, and is made safe a
 * cluster at a time as written text is, a line break or tab shown as its substitute; the cursor's left where the owner
 * says. Where the output left off is kept, for hide_input. A line already drawn isn't drawn twice.
 *
 * @param service The service's state: the view in use's line is written into its screen model, where the output left
 *     off kept in the view, and queued for the serial line if the view's shown.
 */
show_input :: fn(service: ptr[mut Service]) {
    if view(service).input_drawn || view(service).input_count == 0 || view(service).screen.using_whole || view(service).input_count > view(service).input.count {
        return void
    }
    grid :: &view(service).screen.lines
    view(service).output_row = grid.row
    view(service).output_column = grid.column
    view(service).output_scrolls = grid.scrolls
    storage : u8[64]
    out := text_buffer.make(storage)
    if grid.column > 0 {
        screen.line_break(&view(service).screen)
        vt.append_line_break(&out)
        emit_program(service, &out)
    }
    first_scrolls :: grid.scrolls
    first_row :: grid.row
    plain :: terminal.Style.{}
    count :: view(service).input_count
    if count > view(service).input.count {
        return void
    }
    line :: view(service).input[0..<count]
    cursor_row := grid.row
    cursor_column := grid.column
    cursor_scrolls := grid.scrolls
    at : usize = 0
    loop {
        if at == view(service).input_cursor {
            cursor_row = grid.row
            cursor_column = grid.column
            cursor_scrolls = grid.scrolls
        }
        if at >= line.count {
            break
        }
        end :: unicode.grapheme_end(line, at)
        if end <= at || end > line.count {
            break
        }
        shown := safe_text.Shown.{}
        // A line break or tab in it is shown as its substitute, as the line is one line
        safe_text.show(line, at, end, &shown)
        if shown.count <= shown.bytes.count {
            cluster :: shown.bytes[0..<shown.count]
            wrapped :: grid.column + cast[u16](shown.columns) > COLUMNS
            screen.put(&view(service).screen, cluster, shown.columns, plain)
            text_buffer.clear(&out)
            if wrapped {
                vt.append_line_break(&out)
            }
            if cluster.count > 0 {
                text_buffer.append(&out, string_of(&cluster[0], cluster.count))
            }
            emit_program(service, &out)
        }
        at = end
    }
    // Where it starts, and the cursor, moved up by any scrolling the line itself did
    since_first :: grid.scrolls - first_scrolls
    view(service).input_row = if cast[u64](first_row) >= since_first { first_row - cast[u16](since_first) } else { 0 }
    since_cursor :: grid.scrolls - cursor_scrolls
    grid.row = if cast[u64](cursor_row) >= since_cursor { cursor_row - cast[u16](since_cursor) } else { 0 }
    grid.column = cursor_column
    text_buffer.clear(&out)
    vt.append_move(&out, grid.row + 1, grid.column)
    emit_program(service, &out)
    view(service).input_drawn = true
}

/**
 * Tell whether two styles are the same, so a style needn't be sent again.
 *
 * @param a A style, only read.
 * @param b A style compared with a, only read; the order doesn't matter.
 * @return True if their attributes, foregrounds and backgrounds are all the same.
 */
same_style :: fn(a: terminal.Style, b: terminal.Style) -> bool {
    return a.attributes == b.attributes && same_color(a.foreground, b.foreground) && same_color(a.background, b.background)
}

/**
 * Tell whether two colors are the same, field by field.
 *
 * @param a A color, only read.
 * @param b A color compared with a, only read; the order doesn't matter.
 * @return True if their kinds, indexes and red, green and blue are all the same, including those their kind doesn't
 *     use.
 */
same_color :: fn(a: terminal.Color, b: terminal.Color) -> bool {
    return a.kind == b.kind && a.index == b.index && a.red == b.red && a.green == b.green && a.blue == b.blue
}

/**
 * Take a Write: put its text, a grapheme cluster at a time, each in its run's style, made safe, into the view's screen
 * model and onto the serial line; line breaks as CR LF, tabs as spaces to the next stop.
 *
 * The style and any link are ended with it, so another client's text starts plain. Text past the last run takes the
 * last run's style; a link whose bytes run past the links given isn't started.
 *
 * @param service The service, its view in use the writer's.
 * @param into The received request, which text's items are read from.
 * @param text The Write's text, its runs of styles and their links.
 */
write :: fn(service: ptr[mut Service], into: ptr[os.Incoming], text: terminal.Text) {
    bytes :: os.items(into, text.text)
    runs :: os.items(into, text.runs)
    links :: os.items(into, text.links)
    plain :: terminal.Style.{}
    current := plain
    linked := false
    run_index : usize = 0
    run_end : usize = if runs.count > 0 { cast[usize](runs[0].bytes) } else { bytes.count }
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        end :: unicode.grapheme_end(bytes, at)
        if end <= at || end > bytes.count {
            break
        }
        // The run this cluster starts in; past the last, the last's style
        loop {
            if at < run_end || run_index + 1 >= runs.count {
                break
            }
            run_index += 1
            if run_index < runs.count {
                run_end += cast[usize](runs[run_index].bytes)
            }
        }
        storage : u8[160]
        out := text_buffer.make(storage)
        style := plain
        if run_index < runs.count {
            run :: runs[run_index]
            style = run.style
            if !same_style(run.style, current) {
                vt.append_style(&out, run.style)
                current = run.style
            }
            // A link starts or stops with its run
            wanted :: run.link_bytes > 0
            if wanted || linked {
                start :: cast[usize](run.link_start)
                stop :: start + cast[usize](run.link_bytes)
                if wanted && stop <= links.count && start <= stop {
                    vt.append_link(&out, links[start..<stop])
                }
                else if linked {
                    vt.append_link(&out, links[0..<0])
                }
                linked = wanted
            }
        }
        if safe_text.is_line_break(bytes, at, end) {
            vt.append_line_break(&out)
            screen.line_break(&view(service).screen)
        }
        else if safe_text.is_tab(bytes, at, end) {
            grid :: screen.current(&view(service).screen)
            loop {
                text_buffer.append_byte(&out, cast[u8](' '))
                screen.put(&view(service).screen, string_bytes(" "), 1, style)
            }
            while grid.column % TAB_STOP != 0 && grid.column < COLUMNS
        }
        else {
            shown := safe_text.Shown.{}
            safe_text.show(bytes, at, end, &shown)
            if shown.count <= shown.bytes.count {
                cluster :: shown.bytes[0..<shown.count]
                screen.put(&view(service).screen, cluster, shown.columns, style)
                if cluster.count > 0 {
                    text_buffer.append(&out, string_of(&cluster[0], cluster.count))
                }
            }
        }
        emit_program(service, &out)
        at = end
    }
    storage : u8[32]
    out := text_buffer.make(storage)
    if linked {
        vt.append_link(&out, links[0..<0])
    }
    if !same_style(current, plain) {
        vt.append_style(&out, plain)
    }
    emit_program(service, &out)
}

/**
 * Take a MoveCursor: anywhere on a whole screen; on lines, only along the line being written, the row ignored.
 *
 * @param service The service, its view in use the client's.
 * @param position Where, in the program's rows and columns from 0; the screen model keeps it within them.
 */
move_cursor :: fn(service: ptr[mut Service], position: terminal.Position) {
    screen.move(&view(service).screen, position.column, position.row)
    grid :: screen.current(&view(service).screen)
    storage : u8[32]
    out := text_buffer.make(storage)
    if view(service).screen.using_whole {
        vt.append_move(&out, grid.row + 1, grid.column)
    }
    else {
        vt.append_column(&out, grid.column)
    }
    emit_program(service, &out)
}

/**
 * Take a Clear: on a whole screen, blank the area's cells; on lines, blank the whole line being written, with the
 * cursor at its start, whatever the area, which is how a program redraws a line it's editing.
 *
 * @param service The service, its view in use the client's.
 * @param area The area, in the program's rows and columns; what's past the screen's edges is ignored.
 */
clear :: fn(service: ptr[mut Service], area: terminal.Area) {
    storage : u8[128]
    out := text_buffer.make(storage)
    grid :: screen.current(&view(service).screen)
    if !view(service).screen.using_whole {
        screen.clear_line_from(grid, 0)
        text_buffer.append_byte(&out, 0x0d)
        vt.append_clear_to_end(&out)
        emit_program(service, &out)
        return void
    }
    screen.clear(grid, area)
    if area.column >= COLUMNS || area.row >= PROGRAM_ROWS {
        return void
    }
    columns :: if area.columns > COLUMNS - area.column { COLUMNS - area.column } else { area.columns }
    rows :: if area.rows > PROGRAM_ROWS - area.row { PROGRAM_ROWS - area.row } else { area.rows }
    for row in area.row..<area.row + rows {
        text_buffer.clear(&out)
        vt.append_move(&out, row + 1, area.column)
        if area.column + columns >= COLUMNS {
            vt.append_clear_to_end(&out)
        }
        else {
            for i in 0..<columns {
                text_buffer.append_byte(&out, cast[u8](' '))
            }
        }
        emit_program(service, &out)
    }
}

/**
 * Take a Scroll: scroll an area of a whole screen, if it's as wide as the screen, which is what a VT can scroll. On
 * lines, or for a narrower or empty area, nothing happens.
 *
 * @param service The service, its view in use the client's.
 * @param scrolled The area, in the program's rows, and how many lines it scrolls by, as screen.scroll takes them.
 */
scroll :: fn(service: ptr[mut Service], scrolled: terminal.ScrollArea) {
    area :: scrolled.area
    if !view(service).screen.using_whole || area.column != 0 || area.columns < COLUMNS || area.row >= PROGRAM_ROWS || area.rows == 0 {
        return void
    }
    screen.scroll(&view(service).screen.whole, area.row, area.rows, scrolled.lines)
    last :: if area.rows > PROGRAM_ROWS - area.row { PROGRAM_ROWS - 1 } else { area.row + area.rows - 1 }
    storage : u8[64]
    out := text_buffer.make(storage)
    vt.append_scroll(&out, area.row + 1, last + 1, scrolled.lines)
    vt.append_margins(&out, 1, ROWS - 1)
    emit_program(service, &out)
}

/**
 * Take a Screen: switch to a whole screen of the program's own, blank, or back to the lines it left; the status line is
 * drawn again unless the secure attention key's screen is up.
 *
 * @param service The service, its view in use the client's.
 * @param whole True for a whole screen, false for lines; asking for what's in use already does nothing.
 */
use_screen :: fn(service: ptr[mut Service], whole: bool) {
    if whole == view(service).screen.using_whole {
        return void
    }
    screen.use_whole(&view(service).screen, whole)
    storage : u8[64]
    out := text_buffer.make(storage)
    vt.append_alternate_screen(&out, whole)
    if whole {
        // A new screen is blank, the status line too, so it's drawn again
        vt.append_move(&out, 1, 0)
        view(service).screen.status_dirty = true
    }
    emit_program(service, &out)
    if !service.attention {
        draw_status(service)
    }
}

/**
 * Make the view in use's status line say what's going on, and draw it.
 *
 * It names the screen that's up (secure attention, locked, elevation, sharing, setup or login with the keyboard
 * layout), or the session's user; then, first of these that applies, a new keyboard's code to type, the powerbox's
 * request waiting, or the boot before's fault not yet seen.
 *
 * @param service The service's state, which the status line's text is taken from: the view in use's status line is
 *     set and queued for the serial line, whether or not the view is shown.
 */
update_status :: fn(service: ptr[mut Service]) {
    storage : u8[160]
    status := text_buffer.make(storage)
    if service.attention {
        text_buffer.append(&status, STATUS_ATTENTION)
    }
    else if service.setup != .Off && service.unlocking {
        text_buffer.append(&status, STATUS_LOCKED)
    }
    else if service.setup != .Off && service.elevating {
        text_buffer.append(&status, STATUS_ELEVATING)
    }
    else if service.setup != .Off && service.sharing {
        text_buffer.append(&status, STATUS_SHARING)
    }
    else if service.setup != .Off {
        text_buffer.append(&status, if is_login(service.setup) { STATUS_LOGIN } else { STATUS_SETUP })
        layout :: keymaps.find(service.layout) or_else keymaps.US
        text_buffer.append(&status, " │ keyboard: ")
        text_buffer.append(&status, layout.title)
        text_buffer.append(&status, " │ F2: layout")
    }
    else if view(service).logged_in && view(service).user_count > 0 && view(service).user_count <= view(service).user.count {
        text_buffer.append(&status, " SlopOS │ console │ ")
        text_buffer.append(&status, string_of(&view(service).user[0], view(service).user_count))
    }
    else if view(service).logged_in {
        text_buffer.append(&status, STATUS_NO_ACCOUNTS)
    }
    else {
        text_buffer.append(&status, STATUS)
    }
    if service.waiting_code != 0 {
        text_buffer.append(&status, " │ a new keyboard: type ")
        text_buffer.append_unsigned(&status, cast[u64](service.waiting_code))
        text_buffer.append(&status, " and Enter on it")
    }
    else if !service.attention && service.setup == .Off && view(service).asking {
        append_asking(&status, &view(service).ask)
    }
    else if service.panic_count > 0 && !service.panic_seen {
        text_buffer.append(&status, " │ the boot before stopped: Ctrl+Alt+Delete")
    }
    screen.set_status(&view(service).screen, text_buffer.as_string(&status))
    draw_status(service)
}

/**
 * Draw the view in use's status line on the serial line's top row, inverse, with the cursor put back where it was.
 *
 * It's emitted even when the view isn't the one shown.
 *
 * @param service The service's state: the view in use's status line is queued for the serial line, and marked drawn.
 */
draw_status :: fn(service: ptr[mut Service]) {
    storage : u8[384]
    out := text_buffer.make(storage)
    vt.append_save_cursor(&out)
    vt.append_move(&out, 0, 0)
    vt.append_style(&out, terminal.Style.{attributes = terminal.INVERSE})
    status :: screen.status_text(&view(service).screen)
    if status.count > 0 {
        text_buffer.append(&out, string_of(&status[0], status.count))
    }
    vt.append_clear_to_end(&out)
    vt.append_style(&out, terminal.Style.{})
    vt.append_restore_cursor(&out)
    emit(service, string_bytes(text_buffer.as_string(&out)))
    view(service).screen.status_dirty = false
}

/**
 * Bring up the secure attention key's screen over the program's rows, with the status line saying so.
 *
 * Nothing a program writes is shown until it's left, though the screen model keeps it, and every key goes to it. If
 * the view's powerbox has a request waiting, the chooser or, for an account, the elevation screen opens instead of the
 * panel. Otherwise the session's programs are asked for, waiting for the session manager's answer, and the panel's
 * drawn. Calling it while it's up does nothing.
 *
 * @param service The service's state, from its main loop: attention and panic_seen are set, and the status line,
 *     panel, chooser or elevation screen drawn; it may wait on the session manager.
 */
enter_attention :: fn(service: ptr[mut Service]) {
    if service.attention {
        return void
    }
    service.attention = true
    service.panic_seen = true
    runtime.log_info("secure attention")
    update_status(service)
    // What's waiting for the user first: the powerbox's request
    if view(service).asking {
        if is_elevation(view(service).ask.kind) {
            enter_elevation(service)
        }
        else {
            enter_chooser(service)
        }
        return void
    }
    list_programs(service)
    service.chosen = 0
    draw_panel(service)
}

/**
 * Draw the secure attention key's panel: whose session it is, the boot before's panic if it stopped for one, the
 * session's programs with their memory in KiB, those that didn't answer a Ping marked, the chosen one inverse, and the
 * keys that do something here.
 *
 * @param service The service, its secure attention key's screen up, its programs listed.
 */
draw_panel :: fn(service: ptr[mut Service]) {
    screen.show_panel(&view(service).screen, true)
    panel :: &view(service).screen.panel
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    chosen_style :: terminal.Style.{attributes = terminal.INVERSE}
    screen.write_at(panel, 1, 2, "Secure attention", bold)
    if view(service).logged_in && view(service).user_count > 0 && view(service).user_count <= view(service).user.count {
        storage : u8[96]
        line := text_buffer.make(storage)
        text_buffer.append(&line, "Nothing is waiting for you. This is ")
        text_buffer.append(&line, string_of(&view(service).user[0], view(service).user_count))
        text_buffer.append(&line, "'s session.")
        screen.write_at(panel, 3, 2, text_buffer.as_string(&line), plain)
    }
    else {
        screen.write_at(panel, 3, 2, "Nothing is waiting for you: no prompt, and no one has logged in.", plain)
    }
    if service.panic_count > 0 && service.panic_count <= service.panic.count {
        screen.write_at(panel, 4, 2, "The boot before stopped for a fault: ", plain)
        screen.write_at(panel, 5, 4, string_of(&service.panic[0], service.panic_count), plain)
    }
    if service.session_end == NONE {
        screen.write_at(panel, PROGRAMS_ROW, 2, "No programs to show.", plain)
    }
    else {
        screen.write_at(panel, PROGRAMS_ROW, 2, if service.program_count == 0 { "No programs running on the console." }
            else { "Programs on the console:" }, plain)
    }
    for &program, i in service.programs {
        if i >= service.program_count {
            break
        }
        storage : u8[96]
        line := text_buffer.make(storage)
        text_buffer.append(&line, session.name_of(program))
        loop {
            text_buffer.append_byte(&line, cast[u8](' '))
        }
        while text_buffer.as_string(&line).count < 18
        text_buffer.append_unsigned(&line, program.memory / 1024)
        text_buffer.append(&line, " KiB of ")
        text_buffer.append_unsigned(&line, program.memory_limit / 1024)
        text_buffer.append(&line, " KiB")
        if program.responding == 0 {
            text_buffer.append(&line, "   not responding")
        }
        screen.write_at(panel, PROGRAMS_ROW + 1 + cast[u16](i), 4, text_buffer.as_string(&line), if i == service.chosen { chosen_style } else { plain })
    }
    help :: PROGRAMS_ROW + 2 + cast[u16](service.program_count)
    screen.write_at(panel, help, 2, if service.program_count > 0 { "Up and Down choose, E ends the one chosen, Esc or Enter goes back." }
        else { "Esc or Enter goes back." }, plain)
    // The sessions' keys, those that do something here
    if service.accounts_end != NONE && view(service).logged_in && view(service).user_count > 0 {
        if view(service).home_end != NONE {
            screen.write_at(panel, help + 2, 2, "G shows what you've let programs keep, H shares a volume with another user.", plain)
        }
        screen.write_at(panel, help + 1, 2, if another_session(service) != NO_VIEW { "S switches session, N logs in another, L locks, O logs out." }
            else { "N logs in another session, L locks, O logs out." }, plain)
    }
    // Shutting down and restarting, for whoever's at the console (decisions/0180, 0182)
    if service.power is_some {
        said :: if !service.shutting_down { "P shuts the system down, R restarts it." }
            else if service.restarting { "Restarting." }
            else { "Shutting down." }
        screen.write_at(panel, help + 3, 2, said, plain)
    }
    // The SSH service's host key, for a user to check before trusting it from another computer (decisions/0191)
    match ssh_host_line(service) {
        case Some(printed) => {
            storage : u8[96]
            line := text_buffer.make(storage)
            text_buffer.append(&line, "SSH host key: ")
            text_buffer.append(&line, string_of(&printed[0], 50))
            screen.write_at(panel, help + 4, 2, text_buffer.as_string(&line), plain)
        }
        case None => {}
    }
    redraw(service)
}

/**
 * Ask the supervisor to shut the system down, for P on the secure attention key's screen (decisions/0180), or restart
 * it, for R (decisions/0182), and say so on it. The answer isn't waited for: the system ends with the root task, and
 * the terminal service with it.
 *
 * @param service The service, its secure attention key's screen up; its shutting_down and restarting are set once
 *     it's asked. Without a power connection, or once either's asked, nothing's done.
 * @param restart True to restart, false to shut down.
 */
shut_down :: fn(service: ptr[mut Service], restart: bool) {
    connection :: service.power or_return void
    if service.shutting_down {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[power_protocol.Request](&out)
    request^ = if restart { power_protocol.Request.Restart } else { power_protocol.Request.ShutDown }
    port :: os.port_for(slop_os.startup_block().budget, connection.end) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if power_protocol.send_request(connection.end, port, &out) is_some {
        return void
    }
    service.shutting_down = true
    service.restarting = restart
    runtime.log_info(if restart { "restarting" } else { "shutting down" })
    draw_panel(service)
}

/**
 * Ask the session manager for the view in use's session's programs (List), wait for the answer, and keep them in
 * service.programs, as many as fit.
 *
 * None are kept without a session channel, or if it fails or answers anything but Programs.
 *
 * @param service The service's state: programs and program_count are replaced, none kept if none come back; it waits
 *     for the session manager.
 */
list_programs :: fn(service: ptr[mut Service]) {
    service.program_count = 0
    reply :: ask_session(service, .List(view(service).session)) or_return void
    into :: &reply
    match os.message_of[session.Response](into)^ {
        case Programs(given) => {
            for program in os.items(into, given) {
                if service.program_count < service.programs.count {
                    service.programs[service.program_count] = program
                    service.program_count += 1
                }
            }
        }
        case _ => {}
    }
}

/**
 * End the program chosen on the panel: ask the session manager to (End), waiting for its answer, whatever it is; then
 * list the programs again, keep the choice within them, and draw the panel.
 *
 * @param service The service, its panel up; nothing happens with no program chosen.
 */
end_chosen :: fn(service: ptr[mut Service]) {
    if service.chosen >= service.program_count || service.chosen >= service.programs.count {
        return void
    }
    program :: service.programs[service.chosen]
    runtime.log_info("ending % on the console's request", session.name_of(&program))
    _ = ask_session(service, .End(program.index))
    list_programs(service)
    if service.chosen >= service.program_count && service.chosen > 0 {
        service.chosen = service.program_count - 1
    }
    draw_panel(service)
}

/**
 * Send a request to the session manager and wait, with no deadline, for its answer.
 *
 * The wait is on the session channel's own port, so nothing else is served meanwhile.
 *
 * @param service The service's state, whose session_end and session_port the request and answer go through; the
 *     service's own port isn't served while it waits.
 * @param request The request; it carries no items or handles, as it's built without an Outgoing of the caller's.
 * @return The answer, received, for the caller to read; null without a session channel, if the request couldn't be
 *     sent, or if the channel failed.
 */
ask_session :: fn(service: ptr[mut Service], request: session.Request) -> os.Incoming? {
    if service.session_end == NONE {
        return null
    }
    out := os.Outgoing.{}
    os.begin[session.Request](&out)^ = request
    if session.send_request(service.session_end, service.session_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match session.receive_response(service.session_end, service.session_port, &into, true) {
            case Received => return into
            case Failed(error) => return null
            case _ => return null
        }
    }
}

/**
 * Keep the first line of the boot before's panic record to show, without where in the kernel (from " at " on), as the
 * root task logs it; at most PANIC_TEXT bytes.
 *
 * @param service The service's state, at its start: the line is added to panic after any bytes it already holds, up
 *     to PANIC_TEXT.
 * @param last_panic The panic record, a memory object of text, which stays the caller's; null if the boot before
 *     didn't panic, which keeps nothing, as does a record that can't be read.
 */
keep_panic :: fn(service: ptr[mut Service], last_panic: slop_os.Memory?) {
    record :: last_panic or_return void
    text :: service_kit.text_of(slop_os.startup_block(), record) or_return void
    first := text
    for character, i in text {
        if character == '\n' {
            first = text[0..<i]
            break
        }
    }
    for character, i in first {
        end :: i + 4
        if character == ' ' && end <= first.count && i < end {
            if first[i..<end] == " at " {
                first = first[0..<i]
                break
            }
        }
    }
    for byte in string_bytes(first) {
        if service.panic_count < service.panic.count {
            service.panic[service.panic_count] = byte
            service.panic_count += 1
        }
    }
    runtime.log_info("showing the boot before's fault: %", first)
}

/**
 * Leave the secure attention key's screen, and the chooser or grants view on it: draw the program's rows again from the
 * screen model, and the status line. Calling it while it isn't up does nothing.
 *
 * @param service The service's state: attention, choosing and granting are cleared, and the view in use's panel is
 *     hidden and its status line and program rows queued for the serial line.
 */
leave_attention :: fn(service: ptr[mut Service]) {
    if !service.attention {
        return void
    }
    service.attention = false
    service.choosing = false
    service.granting = false
    runtime.log_info("secure attention ended")
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
    lend_seat(service)
}

/**
 * Draw every program row of what the view in use shows, the panel or the program's, from the screen model, each up to
 * its last cell that isn't blank, then cleared to its end; and put the cursor where it is in what's shown.
 *
 * @param service The service's state: the view in use's rows are queued for the serial line, whether or not it's
 *     shown; the screen model isn't changed.
 */
redraw :: fn(service: ptr[mut Service]) {
    redraw_rows(service, 0, PROGRAM_ROWS)
}

/**
 * Draw some program rows of what the view in use shows, as redraw draws them, and put the cursor where it is.
 *
 * @param service The service's state: the view in use's rows are queued for the serial line, whether or not it's
 *     shown; the screen model isn't changed.
 * @param first The first program row drawn.
 * @param last_row The row after the last drawn; past PROGRAM_ROWS, it's PROGRAM_ROWS.
 */
redraw_rows :: fn(service: ptr[mut Service], first: u16, last_row: u16) {
    grid :: screen.shown(&view(service).screen)
    plain :: terminal.Style.{}
    for row in first..<(if last_row < PROGRAM_ROWS { last_row } else { PROGRAM_ROWS }) {
        storage : u8[2048]
        out := text_buffer.make(storage)
        vt.append_move(&out, row + 1, 0)
        current := plain
        // The row's last cell that shows something, or its style does
        last : u16 = 0
        for column in 0..<COLUMNS {
            found :: screen.cell(grid, row, column) or_break
            if found.count > 0 || !same_style(found.style, plain) {
                last = column + 1
            }
        }
        for column in 0..<last {
            cell :: screen.cell(grid, row, column) or_break
            if cell.width == 0 && cell.count == 0 && column > 0 {
                // The second column of a wide cluster, or a blank after one; blanks are spaces
                previous :: screen.cell(grid, row, column - 1) or_break
                if previous.width == 2 {
                    continue
                }
            }
            if !same_style(cell.style, current) {
                vt.append_style(&out, cell.style)
                current = cell.style
            }
            if cell.count == 0 {
                text_buffer.append_byte(&out, cast[u8](' '))
            }
            else if cast[usize](cell.count) <= cell.bytes.count {
                text_buffer.append(&out, string_of(&cell.bytes[0], cast[usize](cell.count)))
            }
        }
        vt.append_style(&out, plain)
        vt.append_clear_to_end(&out)
        emit(service, string_bytes(text_buffer.as_string(&out)))
    }
    storage : u8[32]
    out := text_buffer.make(storage)
    vt.append_move(&out, grid.row + 1, grid.column)
    emit(service, string_bytes(text_buffer.as_string(&out)))
}

/**
 * Queue a program's output for the serial line, unless the view in use isn't shown, or the secure attention key's
 * screen or setup's is up; then it's only in the screen model, and is drawn from there later.
 *
 * @param service The service's state, whose attention, setup and view in use decide whether out is queued for the
 *     serial line.
 * @param out The output, VT sequences and text; copied, so it need only last the call.
 */
emit_program :: fn(service: ptr[mut Service], out: ptr[text_buffer.TextBuffer]) {
    if !service.attention && service.setup == .Off && is_shown(service) {
        emit(service, string_bytes(text_buffer.as_string(out)))
    }
}

/**
 * Queue bytes for the serial line, to be sent by pump.
 *
 * What doesn't fit the queue's OUTPUT_BYTES is dropped. Without a serial line connector nothing is kept; while the
 * line is being dialed again, bytes are kept for it.
 *
 * @param service The service's state: the bytes go at the end of its output ring, as many as fit OUTPUT_BYTES.
 * @param bytes The bytes, copied, so they need only last the call.
 */
emit :: fn(service: ptr[mut Service], bytes: u8[]) {
    if cast[slop_os.Handle](service.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    for byte in bytes {
        if service.output_count >= service.output.count {
            return void
        }
        at :: (service.output_start + service.output_count) % service.output.count
        if at < service.output.count {
            service.output[at] = byte
        }
        service.output_count += 1
    }
}

/**
 * Send what's queued on the serial line, in Writes of at most serial.MAX_BYTES, while fewer than MAX_IN_FLIGHT are
 * unanswered; the answers aren't waited for. A Write that can't be sent stays queued.
 *
 * @param service The service; without a serial line, nothing is sent.
 */
pump :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        if service.output_count == 0 || service.in_flight >= MAX_IN_FLIGHT {
            break
        }
        chunk : u8[serial.MAX_BYTES]
        taken :: if service.output_count < chunk.count { service.output_count } else { chunk.count }
        for i in 0..<taken {
            at :: (service.output_start + i) % service.output.count
            if at < service.output.count && i < chunk.count {
                chunk[i] = service.output[at]
            }
        }
        out := os.Outgoing.{}
        request :: os.begin[serial.Request](&out)
        request^ = .Write(os.append(&out, chunk[0..<taken]))
        if serial.send_request(service.line_end, service.port, &out) != null {
            break
        }
        service.in_flight += 1
        service.output_start = (service.output_start + taken) % service.output.count
        service.output_count -= taken
    }
}

/**
 * Send the serial line another Read, held by the driver until something's typed, unless one's waiting.
 *
 * It asks for as many bytes as the decoded input has room for events, each byte at most one, up to serial.MAX_BYTES,
 * so typing faster than a client reads waits in the driver rather than being dropped here. With room for fewer than
 * FEED_SLICE, none is sent; it's asked again once a delivery makes some.
 *
 * @param service The service; without a serial line, nothing is sent.
 */
read_more :: fn(service: ptr[mut Service]) {
    if service.line_end == NONE || service.line_reading || service.decoded.count + FEED_SLICE > service.decoded.events.count {
        return void
    }
    room :: service.decoded.events.count - service.decoded.count
    out := os.Outgoing.{}
    request :: os.begin[serial.Request](&out)
    request^ = .Read(cast[u32](if room < cast[usize](serial.MAX_BYTES) { room } else { cast[usize](serial.MAX_BYTES) }))
    service.line_reading = serial.send_request(service.line_end, service.port, &out) is_none
}

/**
 * Send the input service a Read for up to seat.MAX_EVENTS events, unless one's waiting; the answer comes to take_seat.
 *
 * @param service The service; without the input service, nothing is sent.
 */
read_seat :: fn(service: ptr[mut Service]) {
    if service.seat_end == NONE || service.seat_reading {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[seat.Request](&out)
    request^ = .Read(seat.MAX_EVENTS)
    service.seat_reading = seat.send_request(service.seat_end, service.port, &out) is_none
}

/**
 * Take everything the serial line has answered: a Written frees room for another Write; Data's bytes are decoded,
 * FEED_SLICE at a time, each slice's keys screened by the trusted path before the next, and another Read is sent.
 *
 * A line that's failed is closed and dialed again, and the new one read until it's empty.
 *
 * @param service The service; without a serial line, nothing is read.
 * @param into Where answers are received, reused for each.
 */
take_serial :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match serial.receive_response(service.line_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](service.line_end))
                service.line_end = NONE
                service.line_reading = false
                runtime.log_info("its serial line went; dialing again")
                dial_serial(service)
                // Read the new one until it's empty, since only a read that finds nothing has its next answer wake the port
                if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
        }
        match os.message_of[serial.Response](into)^ {
            case Written(_) => {
                service.in_flight = if service.in_flight > 0 { service.in_flight - 1 } else { cast[u32](0) }
                pump(service)
            }
            case Data(given) => {
                service.line_reading = false
                // A slice at a time, each slice's keys looked at before the next: what the trusted path's screens take
                // is gone once they've taken it, so typing faster than events are held loses none of theirs
                bytes :: os.items(into, given)
                at : usize = 0
                loop {
                    if at >= bytes.count {
                        break
                    }
                    end :: if bytes.count - at > FEED_SLICE { at + FEED_SLICE } else { bytes.count }
                    if end > bytes.count || at > end {
                        break
                    }
                    first :: service.decoded.count
                    vt.feed(&service.decoder, bytes[at..<end], &service.decoded)
                    if end == bytes.count {
                        vt.finish(&service.decoder, &service.decoded)
                    }
                    screen_keys(service, first)
                    at = end
                }
                read_more(service)
            }
            case _ => {}
        }
    }
}

/**
 * Screen the events decoded from first on before anything reads them, giving the trusted path the keys that are its
 * own.
 *
 * While setup's screen is up every key goes to setup_key. Otherwise Ctrl+Alt+Delete brings up the secure attention
 * key's screen, and while that's up every key goes to it, the chooser or the grants view. Whatever came with the key,
 * or while one of these screens was up, is dropped, so none of it reaches a program; once the chooser answers, or a
 * session's key brings up another screen, what's left of the batch is dropped too.
 *
 * @param service The service's state, from its main loop: its decoded events from first on are screened, and dropped
 *     or left for the owner, and keys may change the trusted path's screens, as they say.
 * @param first The index in service.decoded of the first event not screened yet.
 */
screen_keys :: fn(service: ptr[mut Service], first: usize) {
    decoded :: &service.decoded
    for i in first..<decoded.count {
        if i >= decoded.events.count {
            break
        }
        event :: decoded.events[i]
        if event.kind != cast[u8](terminal.EventKind.Key) {
            continue
        }
        if service.setup != .Off {
            // Setup is the trusted path's already: the secure attention key brings up nothing over it
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            text :: if start <= end && end <= decoded.text_count && end <= decoded.text.count { decoded.text[start..<end] } else { decoded.text[0..<0] }
            setup_key(service, event, text)
            continue
        }
        if event.code == USAGE_DELETE && event.modifiers & (terminal.CONTROL | terminal.ALT) == terminal.CONTROL | terminal.ALT {
            enter_attention(service)
            continue
        }
        if !service.attention {
            continue
        }
        if service.choosing {
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            text :: if start <= end && end <= decoded.text_count && end <= decoded.text.count { decoded.text[start..<end] } else { decoded.text[0..<0] }
            chooser_key(service, event, text)
            if !service.attention {
                // Answered: what came after is the program's again, but for what's in this batch
                drop_from(service, first)
                return void
            }
            continue
        }
        if service.granting {
            grants_key(service, event)
            continue
        }
        if event.code == USAGE_ESCAPE || event.code == USAGE_ENTER {
            leave_attention(service)
        }
        else if event.code == USAGE_UP && service.chosen > 0 {
            service.chosen -= 1
            draw_panel(service)
        }
        else if event.code == USAGE_DOWN && service.chosen + 1 < service.program_count {
            service.chosen += 1
            draw_panel(service)
        }
        else if (event.code == USAGE_E || event.code == USAGE_DELETE) && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            end_chosen(service)
        }
        else if event.code == USAGE_G && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            enter_grants(service)
        }
        else if event.code == USAGE_H && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            enter_share_form(service)
        }
        else if event.code == USAGE_P && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            shut_down(service, false)
        }
        else if event.code == USAGE_R && event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 {
            shut_down(service, true)
        }
        else if event.modifiers & (terminal.CONTROL | terminal.ALT) == 0 && session_key(service, event.code) {
            // A session's key: the screen it brought up takes what comes after
            drop_from(service, first)
            return void
        }
    }
    // What came with the key, or while its screen or setup's was up, is the trusted path's, and isn't kept
    if service.attention || service.setup != .Off || attention_in(decoded, first) {
        drop_from(service, first)
    }
}

/**
 * Tell whether a Ctrl+Alt+Delete is among the decoded events from first on.
 *
 * @param decoded The decoded input, which isn't changed.
 * @param first The index of the first event looked at.
 * @return True if a Delete key event with Control and Alt is there, other modifiers allowed.
 */
attention_in :: fn(decoded: ptr[vt.Decoded], first: usize) -> bool {
    for i in first..<decoded.count {
        if i < decoded.events.count && decoded.events[i].kind == cast[u8](terminal.EventKind.Key) && decoded.events[i].code == USAGE_DELETE
            && decoded.events[i].modifiers & (terminal.CONTROL | terminal.ALT) == terminal.CONTROL | terminal.ALT {
            return true
        }
    }
    return false
}

/**
 * Take back the decoded events from first on, with their text, as if they'd never come.
 *
 * @param service The service's state, whose decoded events and text are cut back to before first.
 * @param first The index of the first event dropped; at or past the count, nothing is.
 */
drop_from :: fn(service: ptr[mut Service], first: usize) {
    decoded :: &service.decoded
    if first >= decoded.count {
        return void
    }
    text_from :: if first < decoded.events.count { cast[usize](decoded.events[first].text_start) } else { decoded.text_count }
    decoded.count = first
    if text_from <= decoded.text_count {
        decoded.text_count = text_from
    }
}

/**
 * Take everything the input service has given: each Input's events go to take_seat_event, the keys waiting are decoded
 * as room allows, and another Read is sent.
 *
 * An input service that's failed is closed and dialed again, and the new one read until it's empty.
 *
 * @param service The service; without the input service, nothing is read.
 * @param into Where answers are received, reused for each.
 */
take_seat :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.seat_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match seat.receive_response(service.seat_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](service.seat_end))
                service.seat_end = NONE
                service.seat_reading = false
                runtime.log_info("the input service went; dialing again")
                dial_seat(service)
                if cast[slop_os.Handle](service.seat_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
        }
        match os.message_of[seat.Response](into)^ {
            case Input(given) => {
                service.seat_reading = false
                text :: os.items(into, given.text)
                for event in os.items(into, given.events) {
                    take_seat_event(service, event, text)
                }
                take_typed(service)
                read_seat(service)
            }
            case _ => {}
        }
    }
}

/** The most keys from the input service kept waiting for room among the decoded input; keys past them are dropped. */
TYPED_KEYS :: 256
/** The most bytes of text the keys waiting have between them; a key whose text doesn't fit is dropped. */
TYPED_TEXT :: 1024
/** The most bytes of text one key has, which the decoded input has to have room for before a key's decoded. */
KEY_TEXT :: 8

/**
 * Take one event from the input service.
 *
 * The secure attention key, unless setup's screen is up, drops the keys waiting, which were for what was shown, and
 * brings up its screen. A new keyboard's code waiting is shown on the status line, and taken off once it's accepted. A
 * key is kept waiting, its text with it, behind any others; one that doesn't fit is dropped.
 *
 * @param service The service's state: a key goes on typed and typed_text, a keyboard's code changes waiting_code and
 *     the status line, and the secure attention key empties typed and brings up its screen.
 * @param event The event; an unknown kind is ignored.
 * @param text The Input's text, which the event's text_start and text_bytes index; read only during the call.
 */
take_seat_event :: fn(service: ptr[mut Service], event: seat.Event, text: u8[]) {
    kind :: seat.kind_of(event) or_return void
    match kind {
        case .SecureAttention => {
            if service.setup == .Off {
                // Keys typed before it are for what was shown, not the trusted path
                service.typed_count = 0
                service.typed_text_count = 0
                enter_attention(service)
            }
        }
        case .Waiting => {
            service.waiting_code = event.waiting_code
            update_status(service)
        }
        case .Accepted => {
            service.waiting_code = 0
            update_status(service)
        }
        case .Key => {
            // Kept in order behind any waiting, its text with it; past what's kept, dropped
            start :: cast[usize](event.text_start)
            end :: start + cast[usize](event.text_bytes)
            typed :: if start <= end && end <= text.count { text[start..<end] } else { text[0..<0] }
            if service.typed_count >= service.typed.count || typed.count > service.typed_text.count - service.typed_text_count {
                return void
            }
            kept := event
            kept.text_start = cast[u32](service.typed_text_count)
            for byte in typed {
                if service.typed_text_count < service.typed_text.count {
                    service.typed_text[service.typed_text_count] = byte
                    service.typed_text_count += 1
                }
            }
            if service.typed_count < service.typed.count {
                service.typed[service.typed_count] = kept
                service.typed_count += 1
            }
        }
        // The pointer's events are for the borrower, the compositor
        case _ => {}
    }
}

/**
 * Decode the keys waiting from the input service, in order, as many as the decoded input has room for, and screen
 * them for the trusted path.
 *
 * The rest wait for a delivery to make room, so a burst of typing longer than one delivery isn't lost. Ctrl+C is
 * decoded as an Interrupt event rather than a key.
 *
 * @param service The service's state: keys move from typed to its decoded events, as room allows, and those left
 *     move to typed's front; the new events are screened.
 */
take_typed :: fn(service: ptr[mut Service]) {
    decoded :: &service.decoded
    first :: decoded.count
    taken : usize = 0
    for event in service.typed {
        // Room for the event, and for its text, at most a key's
        if taken >= service.typed_count || decoded.count >= decoded.events.count || decoded.text_count + KEY_TEXT > decoded.text.count {
            break
        }
        taken += 1
        if event.code == USAGE_C && event.modifiers & terminal.CONTROL != 0 {
            vt.event(decoded, terminal.event_of(.Interrupt))
            continue
        }
        start :: cast[usize](event.text_start)
        end :: start + cast[usize](event.text_bytes)
        typed :: if start <= end && end <= service.typed_text_count && end <= service.typed_text.count { service.typed_text[start..<end] }
            else { service.typed_text[0..<0] }
        vt.key(decoded, event.code, event.modifiers, typed)
    }
    if taken == 0 {
        return void
    }
    // Those left moved to the front, their text with them
    text_from :: if taken < service.typed_count && taken < service.typed.count { cast[usize](service.typed[taken].text_start) }
        else { service.typed_text_count }
    left :: service.typed_count - taken
    for i in 0..<left {
        from :: i + taken
        if from < service.typed.count && i < service.typed.count {
            moved := service.typed[from]
            moved.text_start = if cast[usize](moved.text_start) >= text_from { moved.text_start - cast[u32](text_from) } else { 0 }
            service.typed[i] = moved
        }
    }
    text_left :: if text_from <= service.typed_text_count { service.typed_text_count - text_from } else { cast[usize](0) }
    for i in 0..<text_left {
        from :: i + text_from
        if from < service.typed_text.count && i < service.typed_text.count {
            service.typed_text[i] = service.typed_text[from]
        }
    }
    service.typed_count = left
    service.typed_text_count = text_left
    screen_keys(service, first)
}

/**
 * Deliver the input waiting to the active view's owner, once it holds a Read: as many events as it asked for, and as
 * fit its connection's ring, halved until they do, with their text; those after wait for its next Read.
 *
 * Nothing's delivered while the secure attention key's screen or setup's is up. If the answer can't be sent for any
 * reason but its size, the input stays waiting and the Read stays held.
 *
 * @param service The service's state, from its main loop: its decoded input is sent to the active view's owner and
 *     what's sent taken off, and the owner's Read is no longer held once something's sent.
 * @param connected The clients, the owner's connection among them.
 */
deliver :: fn(service: ptr[mut Service], connected: ptr[service_kit.Clients]) {
    if service.decoded.count == 0 || view(service).held == 0 || service.attention || service.setup != .Off {
        return void
    }
    owner :: view(service).owner or_return void
    if owner >= connected.ends.count {
        return void
    }
    end :: connected.ends[owner]
    decoded :: &service.decoded
    count := if decoded.count < cast[usize](view(service).held) { decoded.count } else { cast[usize](view(service).held) }
    loop {
        if count == 0 || count > decoded.events.count || decoded.text_count > decoded.text.count {
            return void
        }
        // The text up to the next event's
        text_end :: if count < decoded.count && count < decoded.events.count { cast[usize](decoded.events[count].text_start) } else { decoded.text_count }
        if text_end > decoded.text_count {
            return void
        }
        out := os.Outgoing.{}
        response :: os.begin[terminal.Response](&out)
        response^ = .Input(terminal.Events.{events = os.append(&out, decoded.events[0..<count]), text = os.append(&out, decoded.text[0..<text_end])})
        match terminal.send_response(end, service.port, &out) {
            case Some(failure) => {
                if failure != .TooBig || count == 1 {
                    return void
                }
                count /= 2
            }
            case None => break
        }
    }
    view(service).held = 0
    keep_after(service, count)
}

/**
 * Keep the decoded events after the first count, with their text, moved to the front for the next Read; with none
 * left, or text that doesn't add up, the decoder and the decoded input are reset.
 *
 * @param service The service's state, whose decoded events and text lose the first count; or its decoder and decoded
 *     input are reset.
 * @param count How many events were delivered, from the first.
 */
keep_after :: fn(service: ptr[mut Service], count: usize) {
    decoded :: &service.decoded
    if count >= decoded.count || count >= decoded.events.count {
        vt.reset(&service.decoder, decoded)
        return void
    }
    text_from :: cast[usize](decoded.events[count].text_start)
    if text_from > decoded.text_count || decoded.text_count > decoded.text.count {
        vt.reset(&service.decoder, decoded)
        return void
    }
    left :: decoded.count - count
    for i in 0..<left {
        from :: i + count
        if from < decoded.events.count && i < decoded.events.count {
            moved := decoded.events[from]
            moved.text_start = if cast[usize](moved.text_start) >= text_from { moved.text_start - cast[u32](text_from) } else { 0 }
            decoded.events[i] = moved
        }
    }
    text_left :: decoded.text_count - text_from
    for i in 0..<text_left {
        from :: i + text_from
        if from < decoded.text.count && i < decoded.text.count {
            decoded.text[i] = decoded.text[from]
        }
    }
    decoded.count = left
    decoded.text_count = text_left
}

// ---- First-boot setup (decisions/0148)

/**
 * Dial the account service through its connector, if there's one: bind its connection to the port under ACCOUNTS_KEY,
 * and ask how many accounts there are (Describe), without waiting; the answer brings up setup or the login screen.
 *
 * It waits for the connector's answer. If the dial or the bind fails, the account service stays NONE.
 *
 * @param service The service, its accounts_end NONE.
 */
dial_accounts :: fn(service: ptr[mut Service]) {
    if service.accounts_connector == NONE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.accounts_connector) or_return void
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connection :: connector.dial[accounts.Accounts](service.accounts_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(service.port, cast[slop_os.Handle](connection.end), signals, ACCOUNTS_KEY, .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
        return void
    }
    service.accounts_end = connection.end
    out := os.Outgoing.{}
    os.begin[accounts.Request](&out)^ = .Describe
    _ = accounts.send_request(service.accounts_end, service.port, &out)
}

/**
 * Take everything the account service has answered, and move the screen that asked on.
 *
 * Described brings up first-boot setup with no accounts, or the login screen, if no screen is up and no one's logged in
 * to the view. OpenedHome logs in, or unlocks. Created shows the recovery code. Refusals (wrong credentials, too many
 * tries, a password or name refused, an account that exists) say why and go back to the step to type again; while the
 * share form waits, its answers go to it.
 *
 * An account service that's failed is unbound, closed and dialed again; an account being made is asked for again from
 * its password, or for elevation, the administrator's name.
 *
 * @param service The service; without the account service, nothing is read.
 * @param into Where answers are received, reused for each.
 */
take_accounts :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if service.accounts_end == NONE {
        return void
    }
    loop {
        match accounts.receive_response(service.accounts_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                _ = slop_os.port_unbind(service.port, ACCOUNTS_KEY)
                _ = slop_os.handle_close(cast[slop_os.Handle](service.accounts_end))
                service.accounts_end = NONE
                runtime.log_info("the account service went; dialing again")
                // A step waiting on its answer would wait for good: each goes back to where it was asked from
                if service.setup == .Making {
                    say(service, "The account service stopped while it made the account. Type the password again.")
                    setup_step(service, if service.elevating { SetupStep.AdminName } else { SetupStep.Password })
                }
                else if service.setup == .LoggingIn {
                    say(service, "The account service stopped while it opened your session. Type the password again.")
                    setup_step(service, .LoginPassword)
                }
                else if service.setup == .Sharing {
                    say(service, "The account service stopped while it shared the volume. Type the volume's name again.")
                    setup_step(service, .ShareName)
                }
                dial_accounts(service)
                if service.accounts_end == NONE {
                    return void
                }
                continue
            }
        }
        // The share form's answers
        if service.sharing && service.setup == .Sharing {
            match os.message_of[accounts.Response](into)^ {
                case Shared(given) => shared(service, given)
                case NoSuchAccount => {
                    say(service, "There's no account of that name, or it hasn't logged in since it was made.")
                    setup_step(service, .ShareMember)
                }
                case AlreadyExists => {
                    say(service, if service.unsharing { "They aren't in it." } else { "That's the owner, or they're in it already." })
                    setup_step(service, .ShareMember)
                }
                case NameRefused => {
                    say(service, "That can't be a volume's name. Type another.")
                    setup_step(service, .ShareName)
                }
                case Refused => {
                    say(service, "That volume isn't yours to share, or isn't open. Type another.")
                    setup_step(service, .ShareName)
                }
                case _ => {
                    say(service, "It couldn't be shared. Type the volume's name again.")
                    setup_step(service, .ShareName)
                }
            }
            continue
        }
        match os.message_of[accounts.Response](into)^ {
            case Described(status) => {
                if service.setup == .Off && !view(service).logged_in {
                    if status.accounts == 0 {
                        enter_setup(service)
                    }
                    else {
                        enter_login(service)
                    }
                }
            }
            case OpenedHome(root) => {
                if service.unlocking {
                    _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
                    unlocked(service)
                }
                else {
                    logged_in(service, root)
                }
            }
            case WrongCredentials => {
                if service.elevating {
                    say(service, "That's not the administrator's name and password. Type them again.")
                    setup_step(service, .AdminName)
                }
                else if service.unlocking {
                    say(service, "That's not the password. Type it again.")
                    setup_step(service, .LoginPassword)
                }
                else {
                    say(service, "That name and password don't open an account. Type them again.")
                    setup_step(service, .LoginName)
                }
            }
            case RateLimited(wait) => {
                storage : u8[MESSAGE_BYTES]
                text := text_buffer.make(storage)
                text_buffer.append(&text, "Too many tries: wait ")
                text_buffer.append_unsigned(&text, (wait + 999_999_999) / 1_000_000_000)
                text_buffer.append(&text, " seconds, then type the password again.")
                say(service, text_buffer.as_string(&text))
                setup_step(service, if service.elevating { SetupStep.AdminName } else { SetupStep.LoginPassword })
            }
            case Done => {
                if service.elevating && is_power(view(service).ask.kind) {
                    power_allowed(service)
                }
                else if service.elevating && (view(service).ask.kind == .DebugOther || view(service).ask.kind == .Trace
                    || view(service).ask.kind == .SystemLog) {
                    runtime.log_info("elevation: the administrator allowed it")
                    end_elevation(service, true)
                }
            }
            case Created(shown) => {
                service.code = shown.text
                if !service.elevating {
                    runtime.log_info("first-boot setup: made the administrator's account")
                }
                say(service, "")
                setup_step(service, .Code)
            }
            case PasswordRefused(problem) => {
                say_problem(service, problem)
                setup_step(service, .Password)
            }
            case NameRefused => {
                say(service, "That name can't be an account's. Type another.")
                setup_step(service, .Name)
            }
            case AlreadyExists => {
                if service.elevating {
                    say(service, "There's an account of that name already. Type the administrator's name and password again.")
                    setup_step(service, .AdminName)
                }
                else {
                    leave_setup(service)
                }
            }
            case Refused => {
                if service.elevating {
                    end_elevation(service, false)
                }
                else {
                    leave_setup(service)
                }
            }
            case _ => {
                if service.elevating {
                    say(service, "The account couldn't be made. Type the administrator's name and password again.")
                    setup_step(service, .AdminName)
                }
                else if is_login(service.setup) {
                    say(service, "The session couldn't be opened. Type the password again.")
                    setup_step(service, .LoginPassword)
                }
                else {
                    say(service, "The account couldn't be made. Type the password again.")
                    setup_step(service, .Password)
                }
            }
        }
    }
}

/**
 * Bring up first-boot setup's screen, asking for the administrator's account's name; every key is its own until the
 * account's made and the recovery code's been seen.
 *
 * @param service The service, with no accounts yet.
 */
enter_setup :: fn(service: ptr[mut Service]) {
    runtime.log_info("first-boot setup: no accounts yet")
    service.setup = .Name
    update_status(service)
    draw_setup(service, true)
}

/**
 * End first-boot setup: zero the recovery code, and bring up the login screen.
 *
 * @param service The service's state, at setup's Code step: its recovery code is zeroed, and the login screen brought
 *     up in the view in use.
 */
leave_setup :: fn(service: ptr[mut Service]) {
    wipe(service.code[0..<service.code.count])
    runtime.log_info("first-boot setup ended")
    enter_login(service)
}

/**
 * Bring up the login screen (decisions/0150) in the view in use, asking for a name, with nothing said.
 *
 * @param service The service's state: its message is cleared, setup goes to LoginName with the field, password and
 *     name zeroed, and the screen and status line drawn.
 */
enter_login :: fn(service: ptr[mut Service]) {
    runtime.log_info("login: asking for a name and password")
    say(service, "")
    setup_step(service, .LoginName)
    update_status(service)
}

/**
 * Take the account's home, opened by the name and password typed: make the session with it, zero what was typed, and
 * close the login screen.
 *
 * If the session can't be made, it says so and asks for the password again.
 *
 * @param service The service, its login screen at LoggingIn.
 * @param root The home's root, which moves to start_session and on to the session manager.
 */
logged_in :: fn(service: ptr[mut Service], root: os.Channel[dir.Dir]) {
    name :: name_bytes(service)
    for byte, i in name {
        if i < view(service).user.count {
            view(service).user[i] = byte
        }
    }
    view(service).user_count = name.count
    if !start_session(service, root) {
        say(service, "The session couldn't be made. Type the password again.")
        setup_step(service, .LoginPassword)
        return void
    }
    runtime.log_info("logged in as %", string_of(&view(service).user[0], view(service).user_count))
    wipe(service.field[0..<service.field.count])
    wipe(service.password[0..<service.password.count])
    service.field_count = 0
    service.password_count = 0
    service.setup = .Off
    lend_seat(service)
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

/**
 * Have the session manager make a session in the view in use, and wait for its answer.
 *
 * The session gets a terminal connection of its own, which this serves as any client, writing to the view; with a
 * home, also the user's name, the keyboard layout, the home's root, and a prompt connection for its powerbox, which
 * is bound under PROMPT_KEY plus the view's index; and the view keeps a connection of its own to the home. On success
 * the view is logged in and the session manager told it's shown.
 *
 * @param service The service, the user's name in its view in use for a home.
 * @param home The home's root of the user who logged in, which moves to the session manager in the Start request; null
 *     for the session with no user of a boot with no accounts.
 * @return True if the session was made; false without a session channel, if no client could be added or a channel
 *     made, if the request couldn't be sent, or if the session manager refused.
 */
start_session :: fn(service: ptr[mut Service], home: os.Channel[dir.Dir]?) -> bool {
    if service.session_end == NONE {
        return false
    }
    budget :: slop_os.startup_block().budget
    pair :: os.channel_for[terminal.Terminal](budget, terminal.RING_BYTES) or_return false
    client :: match service_kit.add_client_index(&service.connected, service.port, pair.a) {
        case Some(added) => added
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return false
        }
    }
    // The session's programs write to its view
    if client < service.client_view.count {
        service.client_view[client] = service.viewing
    }
    // Its powerbox asks the user through its view (decisions/0156), and the grants view reads its home (0158)
    prompts := NONE
    home_copy := NONE
    out := os.Outgoing.{}
    request :: os.begin[session.Request](&out)
    match home {
        case Some(root) => {
            home_copy = another_connection(root.end) or_else NONE
            prompt_pair :: os.channel_for[prompt.Prompt](budget, 0) or_return false
            prompts = prompt_pair.a
            request^ = .Start(session.SessionStart.{user = os.append(&out, view(service).user[0..<min_count(view(service).user_count, view(service).user.count)]),
                layout = os.append(&out, string_bytes(service.layout)), home = root, terminal = os.Channel[terminal.Terminal].{end = pair.b},
                prompts = os.Channel[prompt.Prompt].{end = prompt_pair.b}})
        }
        case None => request^ = .StartWithoutUser(os.Channel[terminal.Terminal].{end = pair.b})
    }
    if session.send_request(service.session_end, service.session_port, &out) != null {
        return false
    }
    into := os.Incoming.{}
    loop {
        match session.receive_response(service.session_end, service.session_port, &into, true) {
            case Received => break
            case Failed(error) => return false
            case _ => return false
        }
    }
    started :: match os.message_of[session.Response](&into)^ {
        case Started(number) => {
            view(service).session = number
            view(service).first_client = client
            true
        }
        case _ => false
    }
    view(service).logged_in = started
    if home_copy != NONE {
        if started {
            view(service).home_end = home_copy
        }
        else {
            _ = slop_os.handle_close(cast[slop_os.Handle](home_copy))
        }
    }
    if prompts != NONE {
        signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
        if started && (slop_os.port_bind(service.port, cast[slop_os.Handle](prompts), signals, PROMPT_KEY + cast[u64](service.viewing), .Persistent) is_ok) {
            view(service).prompt_end = prompts
        }
        else {
            _ = slop_os.handle_close(cast[slop_os.Handle](prompts))
        }
    }
    if started && (home is_none) {
        runtime.log_info("a session with no user, on a boot with no accounts")
        update_status(service)
    }
    if started {
        tell_shown(service)
    }
    return started
}

/**
 * Tell the session manager which session is shown, for its memory pressure policy (decisions/0153), and wait for its
 * answer.
 *
 * @param service The service; its active view's session is told, or session.NO_SESSION for a login screen.
 */
tell_shown :: fn(service: ptr[mut Service]) {
    shown :: &service.views[service.active % service.views.count]
    _ = ask_session(service, .Shown(if shown.in_use && shown.logged_in { shown.session } else { session.NO_SESSION }))
}

/**
 * Tell whether a step is the login screen's.
 *
 * @param step Any step of the trusted path's screen, Off among them.
 * @return True for LoginName, LoginPassword and LoggingIn.
 */
is_login :: fn(step: SetupStep) -> bool {
    return step == .LoginName || step == .LoginPassword || step == .LoggingIn
}

/**
 * Change to the next keyboard layout keymaps knows: tell the input service to type through it (SetLayout, not waited
 * for), and show it on the status line. Sessions made after are given it.
 *
 * @param service The service's state: its layout becomes the next keymaps knows, after the last the first, and the
 *     input service, if connected, is told.
 */
next_layout :: fn(service: ptr[mut Service]) {
    layout :: keymaps.next(service.layout)
    service.layout = layout.name
    if service.seat_end != NONE {
        out := os.Outgoing.{}
        request :: os.begin[seat.Request](&out)
        request^ = .SetLayout(os.append(&out, string_bytes(layout.name)))
        _ = seat.send_request(service.seat_end, service.port, &out)
    }
    runtime.log_info("login: the % keyboard layout", layout.name)
    update_status(service)
}

/**
 * Go to a step of the trusted path's screen, with its field zeroed and empty, and draw the screen whole.
 *
 * Going back to a name or password step also zeroes the password kept; LoginName zeroes the name; AdminName the
 * administrator's password.
 *
 * @param service The service's state: its setup becomes step, its field and, by step, its password, name or
 *     administrator's password are zeroed, and the view in use's screen drawn whole.
 * @param step The step to go to; Off isn't passed, leaving the screen setting it directly.
 */
setup_step :: fn(service: ptr[mut Service], step: SetupStep) {
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    if step == .Name || step == .Password || step == .LoginName || step == .LoginPassword {
        wipe(service.password[0..<service.password.count])
        service.password_count = 0
    }
    if step == .LoginName {
        wipe(service.name[0..<service.name.count])
        service.name_count = 0
    }
    if step == .AdminName {
        wipe(service.admin_password[0..<service.admin_password.count])
        service.admin_password_count = 0
    }
    service.setup = step
    draw_setup(service, true)
}

/**
 * Take one key on the trusted path's own screen: text typed into the field, Backspace taking a grapheme cluster back,
 * Enter going on, F2 changing the layout.
 *
 * Escape gives up a login for another session, refuses elevation, or closes the share form; Delete on the share form's
 * member takes them out. Keys are ignored while the account service is working (Making, LoggingIn, Sharing). Text
 * typed with Control or Alt, and controls, aren't put in a field; what doesn't fit FIELD_BYTES is dropped.
 *
 * @param service The service, setup's screen up.
 * @param event The key, by its USB HID usage and modifiers.
 * @param text The text the key typed, UTF-8, possibly empty; read only during the call.
 */
setup_key :: fn(service: ptr[mut Service], event: terminal.Event, text: u8[]) {
    if service.setup == .Making || service.setup == .LoggingIn {
        return void
    }
    if event.code == USAGE_F2 {
        next_layout(service)
        return void
    }
    if event.code == USAGE_ESCAPE && service.setup == .LoginName && !service.unlocking {
        abandon_login(service)
        return void
    }
    if event.code == USAGE_ESCAPE && service.elevating && service.setup != .Making && service.setup != .Code {
        end_elevation(service, false)
        return void
    }
    if service.sharing {
        if service.setup == .Sharing {
            return void
        }
        if event.code == USAGE_ESCAPE {
            end_share_form(service)
            return void
        }
        if event.code == USAGE_DELETE && service.setup == .ShareMember {
            send_share(service, true)
            return void
        }
        if event.code == USAGE_ENTER {
            share_enter(service)
            return void
        }
    }
    if event.code == USAGE_ENTER {
        setup_enter(service)
        return void
    }
    if service.setup == .Code {
        return void
    }
    if event.code == USAGE_BACKSPACE {
        if service.field_count > 0 && service.field_count <= service.field.count {
            typed :: service.field[0..<service.field_count]
            last : usize = 0
            at : usize = 0
            loop {
                end :: unicode.grapheme_end(typed, at)
                if end <= at {
                    break
                }
                last = at
                at = end
            }
            while at < service.field_count
            if last <= service.field_count && service.field_count <= service.field.count {
                wipe(service.field[last..<service.field_count])
            }
            service.field_count = last
        }
        draw_setup(service, false)
        return void
    }
    if event.modifiers & (terminal.CONTROL | terminal.ALT) != 0 {
        return void
    }
    for byte in text {
        // Only what shows: a line break or a control isn't part of a name or password
        if byte >= 0x20 && byte != 0x7f && service.field_count < service.field.count {
            service.field[service.field_count] = byte
            service.field_count += 1
        }
    }
    draw_setup(service, false)
}

/**
 * Take Enter on the trusted path's own screen, at whatever step it's at.
 *
 * A new account's name is checked (account_records.valid_name), its password checked against the rules, the two
 * typings compared, and the account asked for; Enter on the recovery code ends setup or elevation; the
 * administrator's name and password are kept; a login's name is kept, then its password sent. An empty name, or one
 * too long, is ignored. What's refused says why and is asked for again.
 *
 * @param service The service, setup's screen up.
 */
setup_enter :: fn(service: ptr[mut Service]) {
    if service.field_count > service.field.count {
        return void
    }
    typed :: service.field[0..<service.field_count]
    match service.setup {
        case .Name => {
            if !account_records.valid_name(typed) {
                say(service, "A name is 1 to 32 letters, digits, - or _, and starts with a lowercase letter.")
                setup_step(service, .Name)
                return void
            }
            for byte, i in typed {
                if i < service.name.count {
                    service.name[i] = byte
                }
            }
            service.name_count = typed.count
            say(service, "")
            setup_step(service, .Password)
        }
        case .Password => {
            name :: name_bytes(service)
            match account_records.password_problem(name, typed) {
                case Some(problem) => {
                    say_problem(service, cast[u8](problem))
                    setup_step(service, .Password)
                    return void
                }
                case None => {}
            }
            for byte, i in typed {
                if i < service.password.count {
                    service.password[i] = byte
                }
            }
            service.password_count = typed.count
            say(service, "")
            setup_step(service, .Again)
        }
        case .Again => {
            if service.password_count > service.password.count || !same_bytes(typed, service.password[0..<service.password_count]) {
                say(service, "The two didn't match. Type the password again.")
                setup_step(service, .Password)
                return void
            }
            if service.elevating {
                make_account_by(service)
            }
            else {
                make_account(service)
            }
        }
        case .Code => {
            if service.elevating {
                end_elevation(service, true)
            }
            else {
                leave_setup(service)
            }
        }
        case .Confirm => {
            if service.elevating {
                runtime.log_info("elevation: the user allowed %", if view(service).ask.kind == .Network { "a network connection" }
                    else if view(service).ask.kind == .AddKey { "a key added" } else if view(service).ask.kind == .RemoveKey { "a key removed" }
                    else { "a debugger" })
                end_elevation(service, true)
            }
        }
        case .AdminName => {
            if typed.count == 0 || typed.count > service.admin.count {
                return void
            }
            for byte, i in typed {
                if i < service.admin.count {
                    service.admin[i] = byte
                }
            }
            service.admin_count = typed.count
            say(service, "")
            setup_step(service, .AdminPassword)
        }
        case .AdminPassword => {
            if typed.count > service.admin_password.count {
                return void
            }
            for byte, i in typed {
                if i < service.admin_password.count {
                    service.admin_password[i] = byte
                }
            }
            service.admin_password_count = typed.count
            say(service, "")
            // Shutting down, restarting or debugging another's program needs nothing more than the administrator's say
            if service.elevating && is_administrators(view(service).ask.kind) {
                check_administrator(service)
                return void
            }
            setup_step(service, .Name)
        }
        case .LoginName => {
            if typed.count == 0 || typed.count > service.name.count {
                return void
            }
            for byte, i in typed {
                if i < service.name.count {
                    service.name[i] = byte
                }
            }
            service.name_count = typed.count
            say(service, "")
            setup_step(service, .LoginPassword)
        }
        case .LoginPassword => open_home(service, typed)
        case _ => {}
    }
}

/**
 * Ask the account service to open the account's home (OpenHome) with the name kept and the password typed, without
 * waiting; the answer, to take_accounts, logs in or unlocks, or says why not.
 *
 * Once it's sent, or failed to be, the message's words and the field are zeroed. If the account service isn't there or
 * can't be asked, it says so and asks for the password again; otherwise it waits at LoggingIn.
 *
 * @param service The service, its login screen at LoginPassword.
 * @param password The password typed, a view of the service's field, which is zeroed here.
 */
open_home :: fn(service: ptr[mut Service], password: u8[]) {
    if service.accounts_end == NONE || service.name_count > service.name.count {
        say(service, "The account service isn't there. Type the password again.")
        setup_step(service, .LoginPassword)
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .OpenHome(accounts.Credentials.{name = os.append(&out, service.name[0..<service.name_count]), password = os.append(&out, password)})
    sent :: accounts.send_request(service.accounts_end, service.port, &out) == null
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    if !sent {
        say(service, "The account service couldn't be asked. Type the password again.")
        setup_step(service, .LoginPassword)
        return void
    }
    say(service, "Opening your session.")
    setup_step(service, .LoggingIn)
}

/**
 * Ask the account service to make the administrator's account (Create) with the name and password typed, without
 * waiting; the answer, to take_accounts, shows the recovery code or says why not.
 *
 * The request carries the time now in nanoseconds since the epoch (0 if the clock can't be read). Once it's sent, or
 * failed to be, the message's words and the password are zeroed. If the account service isn't there or can't be
 * asked, it says so and asks for the password again; otherwise it waits at Making.
 *
 * @param service The service, at first-boot setup, the password typed twice and matching.
 */
make_account :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE || service.name_count > service.name.count || service.password_count > service.password.count {
        say(service, "The account service isn't there. Type the password again.")
        setup_step(service, .Password)
        return void
    }
    now := cast[u64](0)
    match time.now() {
        case Ok(instant) => now = cast[u64](instant.seconds) * 1000000000 + cast[u64](instant.nanos)
        case Error(error) => {}
    }
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    request^ = .Create(accounts.Creation.{name = os.append(&out, service.name[0..<service.name_count]),
        password = os.append(&out, service.password[0..<service.password_count]), now = now})
    sent :: accounts.send_request(service.accounts_end, service.port, &out) == null
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
    wipe(service.password[0..<service.password.count])
    service.password_count = 0
    if !sent {
        say(service, "The account couldn't be asked for. Type the password again.")
        setup_step(service, .Password)
        return void
    }
    say(service, "Making the administrator's account. This takes a few seconds.")
    setup_step(service, .Making)
}

/**
 * Say why a password was refused, on the screen's message row.
 *
 * @param service The service's state, whose message is replaced, to be shown when the screen's next drawn.
 * @param problem The account_records.PasswordProblem's value: 1 too short, 2 too long, 3 too common, 4 the account's
 *     name; any other is said as a password that can't be used.
 */
say_problem :: fn(service: ptr[mut Service], problem: u8) {
    say(service, if problem == 1 { "A password needs at least 8 characters." }
        else if problem == 2 { "That password is too long: 256 bytes at most." }
        else if problem == 3 { "That password is one of the most common ones. Choose another." }
        else if problem == 4 { "A password can't be the account's name." }
        else { "That password can't be used. Choose another." })
}

/**
 * Set what the trusted path's screen says on its message row, shown when it's next drawn.
 *
 * @param service The service's state, whose message and message_count are replaced; nothing's drawn.
 * @param text The message, copied, cut short at MESSAGE_BYTES; "" says nothing.
 */
say :: fn(service: ptr[mut Service], text: string) {
    service.message_count = 0
    for byte in string_bytes(text) {
        if service.message_count < service.message.count {
            service.message[service.message_count] = byte
            service.message_count += 1
        }
    }
}

/**
 * Draw the trusted path's own screen: the elevation screen, the share form, or the login screen if one of those is up;
 * otherwise first-boot setup's.
 *
 * Setup's shows what it's for, the name, the password and it again as dots, what it last said, and once the account's
 * made, the recovery code, with the cursor at the field being typed.
 *
 * @param service The service, setup's screen up.
 * @param whole Whether to show the panel and draw all of it; false draws only the fields' rows and the message's,
 *     which is all a key changes.
 */
draw_setup :: fn(service: ptr[mut Service], whole: bool) {
    panel :: &view(service).screen.panel
    if whole {
        screen.show_panel(&view(service).screen, true)
    }
    else {
        screen.clear(panel, terminal.Area.{row = SETUP_FIELDS_ROW, columns = COLUMNS, rows = 5})
    }
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    if service.elevating {
        draw_elevation(service, whole)
        return void
    }
    if service.sharing {
        draw_share_form(service, whole)
        return void
    }
    if is_login(service.setup) {
        draw_login(service, whole)
        return void
    }
    screen.write_at(panel, 1, 2, "First-boot setup", bold)
    if service.setup == .Code {
        screen.write_at(panel, 3, 2, "The administrator's account is made. Its recovery code, shown this once:", plain)
        screen.write_at(panel, 5, 6, string_of(&service.code[0], service.code.count), bold)
        screen.write_at(panel, 7, 2, "Write it down, and keep it apart from this computer: it opens the account if", plain)
        screen.write_at(panel, 8, 2, "the password is lost.", plain)
        screen.write_at(panel, 10, 2, "Press Enter once you have.", plain)
        panel.row = 10
        panel.column = 28
        redraw(service)
        return void
    }
    name_row :: SETUP_FIELDS_ROW
    screen.write_at(panel, 3, 2, "No one has an account on this computer yet. Make the administrator's account:", plain)
    screen.write_at(panel, 4, 2, "the first, and the one that can make others.", plain)
    screen.write_at(panel, name_row, 2, "Name:", plain)
    screen.write_at(panel, name_row + 1, 2, "Password:", plain)
    screen.write_at(panel, name_row + 2, 2, "Again:", plain)
    field_column : u16 = 13
    if service.setup == .Name {
        if service.field_count <= service.field.count && service.field_count > 0 {
            screen.write_at(panel, name_row, field_column, string_of(&service.field[0], service.field_count), plain)
        }
    }
    else if service.name_count > 0 && service.name_count <= service.name.count {
        screen.write_at(panel, name_row, field_column, string_of(&service.name[0], service.name_count), plain)
    }
    if service.setup == .Again || service.setup == .Making {
        dots(panel, name_row + 1, field_column, if service.setup == .Making { 8 } else { clusters(password_bytes(service)) })
    }
    if service.setup == .Password || service.setup == .Again {
        dots(panel, if service.setup == .Password { name_row + 1 } else { name_row + 2 }, field_column,
            clusters(field_bytes(service)))
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, name_row + 4, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, name_row + 6, 2, "Enter goes on, Backspace takes back what was typed last.", plain)
    // The cursor at the end of the field being typed
    panel.row = if service.setup == .Name { name_row } else if service.setup == .Password { name_row + 1 } else { name_row + 2 }
    shown :: if service.setup == .Name { cast[u16](min_count(service.field_count, 40)) }
        else { cast[u16](min_count(clusters(field_bytes(service)), 40)) }
    panel.column = field_column + shown
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + 5)
    }
}

/**
 * Draw the login screen, or while locked, the unlock screen: the name, the password as dots, what it last said, and
 * how to change the keyboard layout, which the status line shows.
 *
 * @param service The service, its login screen up.
 * @param whole Whether to draw every row; false draws only the fields' rows and the message's. Either way the panel
 *     is expected to be shown and cleared already, as draw_setup does.
 */
draw_login :: fn(service: ptr[mut Service], whole: bool) {
    panel :: &view(service).screen.panel
    bold :: terminal.Style.{attributes = terminal.BOLD}
    plain :: terminal.Style.{}
    name_row :: SETUP_FIELDS_ROW
    field_column : u16 = 13
    if service.unlocking {
        screen.write_at(panel, 1, 2, "Locked", bold)
        screen.write_at(panel, 3, 2, "The console is locked. Type the session's password to unlock it.", plain)
    }
    else {
        screen.write_at(panel, 1, 2, "Log in", bold)
        screen.write_at(panel, 3, 2, "Type your account's name and password.", plain)
    }
    screen.write_at(panel, name_row, 2, "Name:", plain)
    screen.write_at(panel, name_row + 1, 2, "Password:", plain)
    typed :: field_bytes(service)
    if service.setup == .LoginName {
        if typed.count > 0 {
            screen.write_at(panel, name_row, field_column, string_of(&typed[0], typed.count), plain)
        }
    }
    else {
        name :: name_bytes(service)
        if name.count > 0 {
            screen.write_at(panel, name_row, field_column, string_of(&name[0], name.count), plain)
        }
        dots(panel, name_row + 1, field_column, if service.setup == .LoggingIn { 8 } else { clusters(typed) })
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, name_row + 4, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, name_row + 6, 2, "Enter goes on, Backspace takes back what was typed last, F2 changes the layout.", plain)
    if !service.unlocking && another_session(service) != NO_VIEW {
        screen.write_at(panel, name_row + 7, 2, "Esc goes back to the session you came from.", plain)
    }
    panel.row = if service.setup == .LoginName { name_row } else { name_row + 1 }
    panel.column = field_column + cast[u16](min_count(if service.setup == .LoginName { typed.count } else { clusters(typed) }, 40))
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + 5)
    }
}

/**
 * Take what's typed in the field so far.
 *
 * @param service The service's state, whose field is viewed; only read.
 * @return A view of the field's used bytes, good until it's typed in or zeroed; empty if the count is past the buffer.
 */
field_bytes :: fn(service: ptr[Service]) -> u8[] {
    return if service.field_count <= service.field.count { service.field[0..<service.field_count] } else { service.field[0..<0] }
}

/**
 * Take the account name kept.
 *
 * @param service The service's state, whose name is viewed; only read.
 * @return A view of the name's used bytes, good until it's changed or zeroed; empty if the count is past the buffer.
 */
name_bytes :: fn(service: ptr[Service]) -> u8[] {
    return if service.name_count <= service.name.count { service.name[0..<service.name_count] } else { service.name[0..<0] }
}

/**
 * Take the new account's password kept from its first typing.
 *
 * @param service The service's state, whose password is viewed; only read.
 * @return A view of the password's used bytes, good until it's zeroed; empty if the count is past the buffer.
 */
password_bytes :: fn(service: ptr[Service]) -> u8[] {
    return if service.password_count <= service.password.count { service.password[0..<service.password_count] } else { service.password[0..<0] }
}

/**
 * Write dots in a row of the panel, one for each of a password's grapheme clusters, up to 40.
 *
 * @param panel The grid the dots are written into, the trusted path's panel in a view's screen model.
 * @param row The panel row the dots go in, from 0 at the top of the program rows, below PROGRAM_ROWS.
 * @param column The column of the first dot.
 * @param count How many dots; past 40, 40.
 */
dots :: fn(panel: ptr[mut screen.Grid], row: u16, column: u16, count: usize) {
    for i in 0..<min_count(count, 40) {
        screen.write_at(panel, row, column + cast[u16](i), "•", terminal.Style.{})
    }
}

/**
 * Count the grapheme clusters in UTF-8 text, as a person counts the characters typed.
 *
 * @param bytes UTF-8 text, such as a field typed; not checked to be valid, and only read.
 * @return How many clusters, 0 for none.
 */
clusters :: fn(bytes: u8[]) -> usize {
    count : usize = 0
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        end :: unicode.grapheme_end(bytes, at)
        if end <= at {
            break
        }
        at = end
        count += 1
    }
    return count
}

/**
 * Take the smaller of two counts.
 *
 * @param a A count, any value.
 * @param b A count, any value; the order doesn't matter.
 * @return Whichever is smaller.
 */
min_count :: fn(a: usize, b: usize) -> usize {
    return if a < b { a } else { b }
}

/**
 * Tell whether two byte strings are the same, byte for byte.
 *
 * @param a Bytes compared, only read.
 * @param b Bytes compared with a, only read; the order doesn't matter.
 * @return True if they're the same length and every byte matches; it isn't constant-time.
 */
same_bytes :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

/**
 * Zero bytes, so a password or recovery code typed isn't left in memory.
 *
 * @param bytes The bytes, every one set to 0.
 */
wipe :: fn(bytes: mut u8[]) {
    for i in 0..<bytes.count {
        bytes[i] = 0
    }
}

// ---- Sessions' views (decisions/0151)

/**
 * Make a view ready for a session, in use: blank, everything else in it reset, its lines written from the bottom row
 * and scrolling up, as a serial line's are, its status line the one for no session.
 *
 * @param service The service's state, whose views[index] is overwritten; the view in use and the active one aren't
 *     changed, and nothing's drawn.
 * @param index The view's index; one past MAX_VIEWS does nothing.
 */
open_view :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.views.count {
        return void
    }
    view :: &service.views[index]
    view^ = View.{in_use = true}
    view.screen.lines.row = PROGRAM_ROWS - 1
    screen.set_status(&view.screen, STATUS)
    screen.mark_all(&view.screen.lines)
}

/**
 * Take the view in use: the session's whose client is being served, or the active one.
 *
 * @param service The service's state, whose viewing picks the view, wrapped to MAX_VIEWS.
 * @return The view, inside the service, good as long as it is.
 */
view :: fn(service: ptr[mut Service]) -> ptr[mut View] {
    return &service.views[service.viewing % service.views.count]
}

/**
 * Make the view a client writes to the one in use: its session's, or, for a client in none or a view no longer in use,
 * the active one.
 *
 * @param service The service's state, whose viewing is set; nothing's drawn.
 * @param index The client, by its index among the service's clients, whose entry in client_view picks the view; one
 *     past client_view uses the active view.
 */
use_view_of :: fn(service: ptr[mut Service], index: usize) {
    which :: if index < service.client_view.count { service.client_view[index] } else { NO_VIEW }
    service.viewing = if which < service.views.count && service.views[which].in_use { which } else { service.active }
}

/**
 * Make the active view the one in use again, once another session's client has been served.
 *
 * @param service The service's state, whose viewing is set to its active.
 */
use_active :: fn(service: ptr[mut Service]) {
    service.viewing = service.active
}

/**
 * Tell whether the view in use is the one shown.
 *
 * @param service The service's state, whose viewing and active are compared; only read.
 * @return True if it's the active view, so what's written to it goes on the console now.
 */
is_shown :: fn(service: ptr[Service]) -> bool {
    return service.viewing == service.active
}

/**
 * Do what a session key on the secure attention key's screen asks: S switches to the next session, N logs in another,
 * L locks, O logs out.
 *
 * @param service The service, its secure attention key's screen up.
 * @param code The key's USB HID usage.
 * @return True if it was one of those keys, whether or not it could be done; false for any other.
 */
session_key :: fn(service: ptr[mut Service], code: u16) -> bool {
    if code == USAGE_S {
        switch_next(service)
    }
    else if code == USAGE_N {
        log_in_another(service)
    }
    else if code == USAGE_L {
        lock(service)
    }
    else if code == USAGE_O {
        log_out(service)
    }
    else {
        return false
    }
    return true
}

/**
 * Find a logged-in view other than the active one, the next after it going round.
 *
 * @param service The service's state, whose views are looked through from after the active one; only read.
 * @return The view's index, or NO_VIEW if there's no other session.
 */
another_session :: fn(service: ptr[Service]) -> usize {
    for step in 1..<service.views.count {
        index :: (service.active + step) % service.views.count
        if service.views[index].in_use && service.views[index].logged_in {
            return index
        }
    }
    return NO_VIEW
}

/**
 * Show another view: leave the secure attention key's screen, make the view active, draw it whole from its screen
 * model, and tell the session manager it's shown, waiting for its answer.
 *
 * @param service The service's state, from its main loop: the secure attention key's screen is left, active and
 *     viewing become index, and the view drawn; it waits for the session manager.
 * @param index The view's index; one past MAX_VIEWS does nothing.
 */
switch_to :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.views.count {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    service.active = index
    service.viewing = index
    screen.show_panel(&view(service).screen, false)
    update_status(service)
    redraw(service)
    tell_shown(service)
    if view(service).user_count > 0 && view(service).user_count <= view(service).user.count {
        runtime.log_info("switched to %'s session", string_of(&view(service).user[0], view(service).user_count))
    }
}

/**
 * Show the next session's view, if there's another session; otherwise nothing changes.
 *
 * @param service The service's state, which switch_to changes when there's another session.
 */
switch_next :: fn(service: ptr[mut Service]) {
    next :: another_session(service)
    if next == NO_VIEW {
        return void
    }
    switch_to(service, next)
}

/**
 * Start a login for another session, in a free view of its own, made active with its login screen up; Escape there
 * goes back to the view it was started from.
 *
 * Nothing happens without the account service or with every view in use (MAX_VIEWS sessions).
 *
 * @param service The service, its secure attention key's screen up.
 */
log_in_another :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE {
        return void
    }
    free := NO_VIEW
    for each, i in service.views {
        if !each.in_use {
            free = i
            break
        }
    }
    if free == NO_VIEW {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    service.previous = service.active
    open_view(service, free)
    service.active = free
    service.viewing = free
    runtime.log_info("login: another session")
    tell_shown(service)
    enter_login(service)
}

/**
 * Give up a login for another session: zero the field, let its view go, and show the session it was started from, or
 * failing that another.
 *
 * Nothing happens when there's no session to go back to, as at the first login, or when the view is logged in.
 *
 * @param service The service, its login screen at LoginName.
 */
abandon_login :: fn(service: ptr[mut Service]) {
    back :: if service.previous < service.views.count && service.views[service.previous].logged_in { service.previous } else { another_session(service) }
    if back == NO_VIEW || view(service).logged_in {
        return void
    }
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    service.setup = .Off
    lend_seat(service)
    view(service).in_use = false
    switch_to(service, back)
}

/**
 * Lock the console: leave the secure attention key's screen for the unlock screen, which asks for the session's
 * user's password and has the account service check it by opening the home.
 *
 * Nothing happens unless a user is logged in to the view; a session with no user can't be locked.
 *
 * @param service The service, its secure attention key's screen up.
 */
lock :: fn(service: ptr[mut Service]) {
    if !view(service).logged_in || view(service).user_count == 0 || view(service).user_count > service.name.count {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    for byte, i in view(service).user {
        if i < view(service).user_count && i < service.name.count {
            service.name[i] = byte
        }
    }
    service.name_count = view(service).user_count
    service.unlocking = true
    runtime.log_info("locked")
    say(service, "")
    service.setup = .LoginPassword
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    update_status(service)
    draw_setup(service, true)
}

/**
 * Unlock the console, the password having opened the home: zero the field, close the unlock screen, and draw the
 * session again.
 *
 * @param service The service, its unlock screen up.
 */
unlocked :: fn(service: ptr[mut Service]) {
    service.unlocking = false
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    service.setup = .Off
    lend_seat(service)
    runtime.log_info("unlocked")
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

/**
 * Log out of the active session: have the session manager end it and its programs (EndSession, waited for), drop its
 * clients, drop its powerbox's request, close its prompt and home connections, and let its view go.
 *
 * Another session is shown if there is one; otherwise the view is opened again with the login screen up. Nothing
 * happens if no one's logged in to the view.
 *
 * @param service The service, the view in use the active one: its secure attention key's screen up, or its session's
 *     first program just ended (session_left).
 */
log_out :: fn(service: ptr[mut Service]) {
    if !view(service).logged_in {
        return void
    }
    service.attention = false
    screen.show_panel(&view(service).screen, false)
    gone :: service.active
    end_view(service)
    next :: another_session(service)
    if next != NO_VIEW {
        switch_to(service, next)
        return void
    }
    open_view(service, gone)
    service.viewing = gone
    tell_shown(service)
    enter_login(service)
}

/**
 * End the session in the view in use as log_out does when its first program has ended, its client gone (decisions/
 * 0176): logged out, the login screen shown in its place if it's the one shown, or its view let go if it isn't.
 *
 * @param service The service's state, the view in use the gone client's.
 * @param index The gone client's index; nothing happens unless it's the view's first client and a user's session runs
 *     there. The session with no user, of a boot with no accounts, has no login to go back to, so it stays.
 */
session_left :: fn(service: ptr[mut Service], index: usize) {
    first :: view(service).first_client or_return void
    if first != index || !view(service).logged_in || view(service).user_count == 0 {
        return void
    }
    runtime.log_info("its session's first program ended")
    if service.viewing == service.active {
        log_out(service)
        return void
    }
    end_view(service)
}

/**
 * End the view in use's session: have the session manager end it and its programs (EndSession, waited for), drop its
 * clients, drop its powerbox's request, close its prompt and home connections, and let the view go; what's shown next
 * is the caller's.
 *
 * @param service The service's state, its view in use one a session runs in.
 */
end_view :: fn(service: ptr[mut Service]) {
    _ = ask_session(service, .EndSession(view(service).session))
    for i in 0..<service.client_view.count {
        if service.client_view[i] == service.viewing {
            service_kit.drop_client(&service.connected, i)
            service.client_view[i] = NO_VIEW
        }
    }
    runtime.log_info("logged out")
    drop_ask(view(service))
    if view(service).prompt_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](view(service).prompt_end))
        view(service).prompt_end = NONE
    }
    if view(service).home_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](view(service).home_end))
        view(service).home_end = NONE
    }
    view(service).logged_in = false
    view(service).first_client = null
    view(service).in_use = false
}
