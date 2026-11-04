package supervisor

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import accounts from "../../protocols/accounts"

/*
 * test_accounts (decisions/0141): the account service, on a disk with no accounts yet, refuses a common password and a
 * name an account can't have, makes the administrator and shows its recovery code, and refuses a second account; it
 * refuses a wrong password, and after three, hears the next only after a wait; it opens the administrator's home
 * volume, which takes a file; the recovery code replaces the password, after which the old one is refused and the new
 * one opens the home volume, the file still there.
 */

/** The name test_accounts gives the administrator it makes. */
TEST_NAME :: "admin"
/** The administrator's first password: long, and not a common one. */
TEST_PASSWORD :: "correct horse battery staple"
/** The password the recovery code replaces the first with. */
TEST_NEW_PASSWORD :: "a different long passphrase"
/** The file written to the administrator's home volume, and looked for there after the recovery. */
TEST_FILE :: "welcome.txt"
/** What TEST_FILE holds. */
TEST_TEXT :: "Written to the administrator's home volume"
/** How long test_accounts waits after three wrong passwords, in nanoseconds: 1.5 s, past the wait they make. */
TEST_WAIT : u64 : 1500000000
/**
 * How often an answer from the account service is looked for while the supervisor handles what else arrives, in
 * nanoseconds: 10 ms.
 */
ANSWER_POLL : u64 : 10000000

/**
 * Run test_accounts, logging whether it passed or where it failed.
 *
 * @param supervisor The supervisor, which needs a running account service on a disk with no accounts yet.
 */
check_accounts :: fn(supervisor: ptr[mut Supervisor]) {
    match accounts_failure(supervisor) {
        case Some(what) => log_line.write(supervisor.log, "supervisor: test_accounts: failed at %", what)
        case None => log_line.write(supervisor.log, "supervisor: test_accounts: made the administrator alone, limited wrong passwords, opened its home, recovered it")
    }
}

/**
 * Run test_accounts' steps in order, stopping at the first that fails.
 *
 * The account service is asked through a connection of the supervisor's own; meanwhile the supervisor handles what
 * else arrives, as the account service dials the storage manager through a connector it serves. The test makes the
 * administrator, so it changes the disk for good.
 *
 * @param supervisor The supervisor, which needs a running account service on a disk with no accounts yet; its port is
 *     handled while each answer is waited for, and its budget pays for the connection, which is left open.
 * @return What failed, in words, as "connecting" or "a wrong password"; null if every step passed.
 */
accounts_failure :: fn(supervisor: ptr[mut Supervisor]) -> string? {
    connection :: accounts_connection(supervisor) or_return "connecting"
    port :: os.port_for(supervisor.block.budget, connection.end) or_return "connecting"
    end :: connection.end
    match ask_accounts(supervisor, end, port, .Describe) {
        case Described(status) => {
            if status.accounts != 0 {
                return "an account already there"
            }
        }
        case _ => return "Describe"
    }
    match create(supervisor, end, port, TEST_NAME, "password") {
        case PasswordRefused(problem) => {
            if problem != 3 {
                return "a common password, refused as something else"
            }
        }
        case _ => return "a common password"
    }
    match create(supervisor, end, port, "Admin", TEST_PASSWORD) {
        case NameRefused => {}
        case _ => return "a capitalized name"
    }
    code : u8[accounts.RECOVERY_TEXT_BYTES]
    match create(supervisor, end, port, TEST_NAME, TEST_PASSWORD) {
        case Created(shown) => code = shown.text
        case _ => return "making the administrator"
    }
    if code[5] != cast[u8]('-') || code[23] != cast[u8]('-') {
        return "the recovery code's form"
    }
    match create(supervisor, end, port, "second", TEST_PASSWORD) {
        case Refused => {}
        case _ => return "a second account"
    }
    // Three wrong passwords, then a wait
    for i in 0..<3 {
        match open_home(supervisor, end, port, TEST_NAME, "not the password at all") {
            case WrongCredentials => {}
            case _ => return "a wrong password"
        }
    }
    match open_home(supervisor, end, port, TEST_NAME, TEST_PASSWORD) {
        case RateLimited(wait) => {}
        case _ => return "the attempt after three wrong ones"
    }
    pause(supervisor, TEST_WAIT)
    home := match open_home(supervisor, end, port, TEST_NAME, TEST_PASSWORD) {
        case OpenedHome(root) => root
        case _ => return "opening the home volume"
    }
    if !write_file(home, TEST_FILE, TEST_TEXT) {
        return "writing to the home volume"
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](home.end))
    // The recovery code, typed in lowercase, replaces the password
    for byte, i in code {
        if byte >= cast[u8]('A') && byte <= cast[u8]('Z') {
            code[i] = byte + 32
        }
    }
    out := os.Outgoing.{}
    recovering :: os.begin[accounts.Request](&out)
    recovering^ = .Recover(accounts.Recovery.{name = bytes_of(&out, TEST_NAME), code = os.append(&out, code[0..<accounts.RECOVERY_TEXT_BYTES]),
        new_password = bytes_of(&out, TEST_NEW_PASSWORD)})
    match send_accounts(supervisor, end, port, &out) {
        case Done => {}
        case _ => return "recovering with the recovery code"
    }
    match open_home(supervisor, end, port, TEST_NAME, TEST_PASSWORD) {
        case WrongCredentials => {}
        case _ => return "the password the recovery code replaced"
    }
    home_again := match open_home(supervisor, end, port, TEST_NAME, TEST_NEW_PASSWORD) {
        case OpenedHome(root) => root
        case _ => return "opening the home volume with the new password"
    }
    if !holds_file(home_again, TEST_FILE, TEST_TEXT) {
        return "the home volume's file"
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](home_again.end))
    return null
}

/**
 * Make a new connection to the account service, through its listener.
 *
 * @param supervisor The supervisor, whose entries are searched for the account service's listener, and whose budget
 *     pays for the connection; nothing in it changes.
 * @return The connection, which moves to the caller; null, and logged, if the account service isn't running, or the
 *     Connect failed.
 */
accounts_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[accounts.Accounts]? {
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.name == "accounts" && entry.running && cast[slop_os.Handle](entry.listener) != slop_os.NO_HANDLE {
            port :: os.port_for(supervisor.block.budget, entry.listener) or_return null
            defer slop_os.handle_close(cast[slop_os.Handle](port))
            return accounts.connect(entry.listener, port, supervisor.block.budget)
        }
    }
    log_line.write(supervisor.log, "supervisor: test_accounts: no account service")
    return null
}

/**
 * Ask the account service to create an account, and wait for its answer.
 *
 * @param supervisor The supervisor, which handles what else arrives meanwhile.
 * @param end A connection to the account service.
 * @param port The port its answers wake.
 * @param name The account's name.
 * @param password Its password.
 * @return The answer: Created with the recovery code, or PasswordRefused, NameRefused, AlreadyExists or Refused;
 *     Failed if it couldn't be asked, or the service failed.
 */
create :: fn(supervisor: ptr[mut Supervisor], end: slop_os.Channel, port: slop_os.Port, name: string, password: string) -> accounts.Response {
    out := os.Outgoing.{}
    creating :: os.begin[accounts.Request](&out)
    creating^ = .Create(accounts.Creation.{name = bytes_of(&out, name), password = bytes_of(&out, password), now = 1})
    return send_accounts(supervisor, end, port, &out)
}

/**
 * Ask the account service to open an account's home volume, and wait for its answer.
 *
 * @param supervisor The supervisor, which handles what else arrives meanwhile.
 * @param end A connection to the account service.
 * @param port The port its answers wake.
 * @param name The account's name.
 * @param password The password to try.
 * @return The answer: OpenedHome with the volume's root, which moves to the caller, WrongCredentials or RateLimited;
 *     Failed if it couldn't be asked, or the service failed.
 */
open_home :: fn(supervisor: ptr[mut Supervisor], end: slop_os.Channel, port: slop_os.Port, name: string, password: string) -> accounts.Response {
    out := os.Outgoing.{}
    opening :: os.begin[accounts.Request](&out)
    opening^ = .OpenHome(accounts.Credentials.{name = bytes_of(&out, name), password = bytes_of(&out, password)})
    return send_accounts(supervisor, end, port, &out)
}

/**
 * Send a request that carries no bytes to the account service, and wait for its answer.
 *
 * @param supervisor The supervisor, which handles what else arrives meanwhile.
 * @param end A connection to the account service.
 * @param port The port its answers wake.
 * @param request The request, as Describe.
 * @return The answer; Failed if it couldn't be asked.
 */
ask_accounts :: fn(supervisor: ptr[mut Supervisor], end: slop_os.Channel, port: slop_os.Port, request: accounts.Request) -> accounts.Response {
    out := os.Outgoing.{}
    made :: os.begin[accounts.Request](&out)
    made^ = request
    return send_accounts(supervisor, end, port, &out)
}

/**
 * Send one request to the account service, and wait for its answer while the supervisor goes on with what it does.
 *
 * The account service dials the storage manager through a connector the supervisor serves, so the supervisor's port is
 * handled every ANSWER_POLL until the answer comes.
 *
 * @param supervisor The supervisor, whose port is handled every ANSWER_POLL while the answer is waited for, so its
 *     entries and connectors may change meanwhile.
 * @param end A connection to the account service.
 * @param port The port its answers wake.
 * @param out The request, built with os.begin and its bytes appended; it's sent as it is.
 * @return The answer; Failed if it couldn't be sent or the connection failed.
 */
send_accounts :: fn(supervisor: ptr[mut Supervisor], end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing]) -> accounts.Response {
    if accounts.send_request(end, port, out) is_some {
        return .Failed
    }
    into := os.Incoming.{}
    loop {
        match accounts.receive_response(end, port, &into, false) {
            case Received => return os.message_of[accounts.Response](&into)^
            case Failed(error) => return .Failed
            case Empty => wait_and_handle_until(supervisor, (slop_os.clock_monotonic() or_else 0) + ANSWER_POLL)
            case _ => continue
        }
    }
}

/**
 * Write a file at the root of a directory connection, through std's files, on a connection of its own.
 *
 * @param root The directory, which stays the caller's.
 * @param path The file's path in it.
 * @param text What the file holds, replacing what it held.
 * @return True if it was written whole; false otherwise.
 */
write_file :: fn(root: os.Channel[dir.Dir], path: string, text: string) -> bool {
    files :: second_root(root) or_return false
    defer os.close_directory(files)
    return os.write_entire_file_in(files, path, text) is_none
}

/**
 * Tell whether a file at the root of a directory connection holds exactly a text, through std's files, on a connection
 * of its own.
 *
 * @param root The directory, which stays the caller's.
 * @param path The file's path in it.
 * @param text What it should hold.
 * @return True if it could be read and holds text exactly; false otherwise.
 */
holds_file :: fn(root: os.Channel[dir.Dir], path: string, text: string) -> bool {
    files :: second_root(root) or_return false
    defer os.close_directory(files)
    match os.read_entire_file_in(files, path) {
        case Ok(contents) => {
            same :: contents == text
            runtime.free_array(bit_cast[u8[]](contents))
            return same
        }
        case Error(error) => return false
    }
}

/**
 * Make a second connection to a directory, as std's files take one, with the dir protocol's Connect.
 *
 * @param root The directory, which stays the caller's.
 * @return The new connection as std's Directory, which the caller closes with os.close_directory; null if it couldn't
 *     be made.
 */
second_root :: fn(root: os.Channel[dir.Dir]) -> os.Directory? {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, root.end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    files :: dir.connect(root.end, port, budget) or_return null
    directory, error :: os.directory_on(files.end)
    if error != null {
        return null
    }
    return directory
}
