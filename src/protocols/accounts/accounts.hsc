package accounts

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * The account service's protocol (decisions/0141, roadmap 10b): accounts made, their home volumes opened with their
 * passwords, their passwords changed, and a lost one replaced with the recovery code. A home volume's secret never
 * leaves the account service: OpenHome answers with a connection to the volume's root. A wrong password, or recovery
 * code, makes the next attempt for that account, and from that client, wait longer (RateLimited, with how long).
 *
 * Until 10c gives the administrator's session authority, Create is refused (Refused) once there's an account: the
 * first is made at first boot, on the trusted path, and is the administrator.
 */

Accounts :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "accounts", major_version = 1, lending = .Server}

// An account's name and its password.
Credentials :: struct {
    name : slop_os.Relative[u8],
    password : slop_os.Relative[u8],
}

// A new account, and when it's made, as the asker says.
Creation :: struct {
    name : slop_os.Relative[u8],
    password : slop_os.Relative[u8],
    now : u64,
}

PasswordChange :: struct {
    name : slop_os.Relative[u8],
    password : slop_os.Relative[u8],
    new_password : slop_os.Relative[u8],
}

// A lost password replaced: the account's recovery code, as its owner types it, and the new password.
Recovery :: struct {
    name : slop_os.Relative[u8],
    code : slop_os.Relative[u8],
    new_password : slop_os.Relative[u8],
}

// The recovery code, XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, shown once.
RECOVERY_TEXT_BYTES :: 29

RecoveryText :: struct {
    text : u8[RECOVERY_TEXT_BYTES],
}

Status :: struct {
    accounts : u32,
}

Request :: union {
    Describe,
    Create(Creation),
    OpenHome(Credentials),
    ChangePassword(PasswordChange),
    Recover(Recovery),
    // Serve another client, on its end
    Connect(os.Channel[Accounts]),
}

Response :: union {
    Described(Status),
    // The account's made, the administrator if it's the first: its recovery code, shown once
    Created(RecoveryText),
    OpenedHome(os.Channel[dir.Dir]),
    Done,
    // Why the password's refused, as account_records.PasswordProblem: 1 too short, 2 too long, 3 common, 4 the name
    PasswordRefused(u8),
    // Not a name an account may have: 1 to 32 bytes, a lowercase letter, then letters, digits, - or _
    NameRefused,
    AlreadyExists,
    // No such account, or the wrong password or recovery code: which isn't said
    WrongCredentials,
    // Too many wrong attempts: the nanoseconds until the next is heard
    RateLimited(u64),
    // Not allowed: Create once there's an account
    Refused,
    Failed,
    Unsupported,
}

is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case Create(_) => false
        case OpenHome(_) => true
        case ChangePassword(_) => false
        case Recover(_) => false
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the account service listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Accounts]? {
    pair :: os.channel_for[Accounts](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Accounts].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Accounts].{end = pair.b}
    }
}
