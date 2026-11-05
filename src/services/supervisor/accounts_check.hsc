package supervisor

import compiler from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import accounts from "../../protocols/accounts"
import test_kit from "../../test_kit"

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

/** The name the tests' lines in the supervisor's log start with, after which the report's own follow. */
ACCOUNTS_TEST_NAME :: "supervisor: test_accounts"

/**
 * What test_accounts' tests share, which each reaches through test_kit.given: the supervisor, and the connection to
 * the account service and the recovery code, which the first test makes for those after it.
 */
AccountsGiven :: struct {
    /**
     * The supervisor's address, as a word rather than a pointer: test_kit.run keeps this struct on the heap, which
     * mayn't hold a pointer it can't tell isn't into the stack. The supervisor outlives the tests, which run inside
     * check_accounts.
     */
    supervisor_at : u64,
    /** A connection to the account service, the supervisor's own; NO_HANDLE until the first test has made it. */
    end : slop_os.Channel,
    /** The port end's answers wake; NO_HANDLE until the first test has made it. */
    port : slop_os.Port,
    /** The administrator's recovery code, as the account service showed it, valid once has_code is set. */
    code : u8[accounts.RECOVERY_TEXT_BYTES],
    /** Whether the first test made the administrator and kept its code. */
    has_code : bool,
}

/**
 * Run test_accounts' tests in order, reporting each to the supervisor's log as "supervisor: test_accounts: <line>".
 *
 * The account service is asked through a connection of the supervisor's own; meanwhile the supervisor handles what
 * else arrives, as the account service dials the storage manager through a connector it serves. The tests make the
 * administrator, so they change the disk for good.
 *
 * @param supervisor The supervisor, which needs a running account service on a disk with no accounts yet; its port is
 *     handled while each answer is waited for, and its budget pays for the connection, which is left open.
 */
check_accounts :: fn(supervisor: ptr[mut Supervisor]) {
    shared :: AccountsGiven.{supervisor_at = cast[u64](supervisor), end = cast[slop_os.Channel](slop_os.NO_HANDLE),
        port = cast[slop_os.Port](slop_os.NO_HANDLE)}
    _ = test_kit.run(supervisor.log, ACCOUNTS_TEST_NAME, #insert testing.tests_of(compiler.load_package(".")), shared)
}

/**
 * Find the supervisor from what test_accounts' tests share.
 *
 * @param shared What the tests share, from test_kit.given.
 * @return The supervisor, which check_accounts was given, good while the tests run.
 */
supervisor_of :: fn(shared: ptr[AccountsGiven]) -> ptr[mut Supervisor] {
    return cast[ptr[mut Supervisor]](shared.supervisor_at)
}

/**
 * Check that the account service, with no accounts yet, refuses a common password and a name an account can't have,
 * makes the administrator, showing its recovery code, and refuses a second account.
 *
 * @param t The test's state.
 * @return Ok once it's run, the connection and the recovery code kept for the tests after; Error if the account
 *     service couldn't be connected to or described, or didn't make the administrator.
 */
makes_the_administrator_alone #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shared :: test_kit.given(t, AccountsGiven)?
    supervisor :: supervisor_of(shared)
    connected :: accounts_connection(supervisor)
    connection :: testing.require_some(t, connected, "the account service is running, and takes a connection through its listener")?
    bound :: os.port_for(supervisor.block.budget, connection.end)
    port :: testing.require_some(t, bound, "the supervisor's budget has room for a port")?
    shared.end = connection.end
    shared.port = port
    end :: connection.end
    match ask_accounts(supervisor, end, port, .Describe) {
        case Described(status) => testing.require_eq(t, status.accounts, 0, "the test boots a disk with no accounts yet")?
        case _ => return failed_step(t, "the account service describes itself when asked")
    }
    match create(supervisor, end, port, TEST_NAME, "password") {
        case PasswordRefused(problem) => testing.expect_eq(t, problem, 3, "a common password is refused as common, problem 3")
        case _ => testing.fail(t, "an account isn't made with a common password")
    }
    match create(supervisor, end, port, "Admin", TEST_PASSWORD) {
        case NameRefused => {}
        case _ => testing.fail(t, "an account isn't made with a name with a capital letter, which no account name has")
    }
    match create(supervisor, end, port, TEST_NAME, TEST_PASSWORD) {
        case Created(shown) => shared.code = shown.text
        case _ => return failed_step(t, "the first account is made, the administrator, with a valid name and a long, uncommon password")
    }
    shared.has_code = true
    testing.expect_eq(t, shared.code[5], cast[u8]('-'), "a recovery code is shown in groups, a dash after the fifth character")
    testing.expect_eq(t, shared.code[23], cast[u8]('-'), "a recovery code is shown in groups, a dash after the 23rd character")
    match create(supervisor, end, port, "second", TEST_PASSWORD) {
        case Refused => {}
        case _ => testing.fail(t, "a second account isn't made at first-boot setup: only the administrator, alone")
    }
    return .Ok
}

/**
 * Check that the account service refuses a wrong password, and after three hears the next only after a wait.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the first test made no connection.
 */
limits_wrong_passwords #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shared :: test_kit.given(t, AccountsGiven)?
    supervisor :: supervisor_of(shared)
    testing.require_ne(t, shared.end, cast[slop_os.Channel](slop_os.NO_HANDLE), "the first test connected to the account service")?
    for i in 0..<3 {
        match open_home(supervisor, shared.end, shared.port, TEST_NAME, "not the password at all") {
            case WrongCredentials => {}
            case _ => testing.fail(t, "a wrong password opens nothing, refused as wrong credentials")
        }
    }
    match open_home(supervisor, shared.end, shared.port, TEST_NAME, TEST_PASSWORD) {
        case RateLimited(wait) => {}
        case _ => testing.fail(t, "after three wrong passwords, even the right one isn't heard until a wait is over")
    }
    pause(supervisor, TEST_WAIT)
    return .Ok
}

/**
 * Check that the administrator's home volume opens with its password, once the wait is over, and takes a file.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the first test made no connection, or the home volume didn't open.
 */
opens_the_administrators_home #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shared :: test_kit.given(t, AccountsGiven)?
    supervisor :: supervisor_of(shared)
    testing.require_ne(t, shared.end, cast[slop_os.Channel](slop_os.NO_HANDLE), "the first test connected to the account service")?
    home := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_home(supervisor, shared.end, shared.port, TEST_NAME, TEST_PASSWORD) {
        case OpenedHome(root) => home = root
        case _ => return failed_step(t, "the administrator's home volume opens with its password, the wait for wrong ones over")
    }
    testing.expect(t, write_file(home, TEST_FILE, TEST_TEXT), "the administrator's home volume takes a file")
    _ = slop_os.handle_close(cast[slop_os.Handle](home.end))
    return .Ok
}

/**
 * Check that the recovery code, typed in lowercase, replaces the administrator's password, after which the old one is
 * refused and the new one opens the home volume, the file still there.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the first test kept no recovery code, or the new password opened nothing.
 */
recovers_the_administrator_with_its_recovery_code #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shared :: test_kit.given(t, AccountsGiven)?
    supervisor :: supervisor_of(shared)
    testing.require(t, shared.has_code, "the first test made the administrator and kept its recovery code")?
    // The recovery code, typed in lowercase, replaces the password
    code := shared.code
    for byte, i in code {
        if byte >= cast[u8]('A') && byte <= cast[u8]('Z') {
            code[i] = byte + 32
        }
    }
    out := os.Outgoing.{}
    recovering :: os.begin[accounts.Request](&out)
    recovering^ = .Recover(accounts.Recovery.{name = bytes_of(&out, TEST_NAME), code = os.append(&out, code[0..<accounts.RECOVERY_TEXT_BYTES]),
        new_password = bytes_of(&out, TEST_NEW_PASSWORD)})
    match send_accounts(supervisor, shared.end, shared.port, &out) {
        case Done => {}
        case _ => return failed_step(t, "the recovery code, typed in lowercase, replaces the password: it's read ignoring case")
    }
    match open_home(supervisor, shared.end, shared.port, TEST_NAME, TEST_PASSWORD) {
        case WrongCredentials => {}
        case _ => testing.fail(t, "the password the recovery code replaced opens nothing")
    }
    home := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_home(supervisor, shared.end, shared.port, TEST_NAME, TEST_NEW_PASSWORD) {
        case OpenedHome(root) => home = root
        case _ => return failed_step(t, "the new password the recovery code set opens the home volume")
    }
    testing.expect(t, holds_file(home, TEST_FILE, TEST_TEXT), "recovering an account keeps its home volume, the file written to it still there")
    _ = slop_os.handle_close(cast[slop_os.Handle](home.end))
    return .Ok
}

/**
 * Record a failure for a step whose answer wasn't the one it should have been, and stop the test there.
 *
 * @param t The test's state, which the failure is recorded in.
 * @param message What the step should have done, and why it should have.
 * @param location Where the step is; the caller's own.
 * @return Error(Failed), for the test to return.
 */
failed_step :: fn(t: ptr[mut testing.T], message: string, location := #caller_location) -> testing.Outcome {
    testing.fail(t, message, location)
    return .Error(.Failed)
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
 * @param name The name to create, copied into the request; the service refuses one that isn't valid_name's, or
 *     that's an account's already.
 * @param password The new account's password, copied into the request; the service refuses one with a
 *     PasswordProblem, such as a common one.
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
 * @param name The account to open, copied into the request; one that isn't an account's answers
 *     WrongCredentials, as a wrong password does.
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
