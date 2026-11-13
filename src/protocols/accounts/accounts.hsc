package accounts

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import grant from "std/os/slop_os"

/*
 * The account service's protocol (decisions/0141, roadmap 10b): accounts made, their home volumes opened with their
 * passwords, their passwords changed, and a lost one replaced with the recovery code. A home volume's secret never
 * leaves the account service: OpenHome answers with a connection to the volume's root. A wrong password, or recovery
 * code, makes the next attempt for that account, and from that client, wait longer (RateLimited, with how long).
 *
 * Create makes only the first account, at first boot, on the trusted path, which is the administrator; it's refused
 * (Refused) once there's one. Another is made with CreateBy, which the administrator's name and password allow
 * (decisions/0158), typed on the trusted path when a program's asked the powerbox for one: wrong ones, or an account
 * that isn't the administrator's, are WrongCredentials, and count as a login's do.
 *
 * Shared volumes (decisions/0158), asked for by the trusted path for the session's user, its owner: Share makes the
 * volume the first time, and adds a member, its secret sealed to their public key; Unshare takes one out, revokes every
 * link into the volume, and starts its next key generation. Each answers with a grant of the volume's root, for the
 * owner's link to it; the members' are made, or made again, when they next log in.
 *
 * Public keys (decisions/0191, 14c), which log in as an account over SSH: ListKeys, AddKey and RemoveKey, asked for by
 * the trusted path for the session's user once they've allowed it, as sharing is. Keys are OpenSSH's lines, as
 * authorized_keys has them, without options; one's removed by its fingerprint, SHA256:..., as ssh-keygen -l shows it.
 */

/**
 * The accounts protocol, for the channels between the account service and its clients, the trusted path's, and its
 * listener: the clients send the requests, and the account service answers them.
 */
Accounts :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the account service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "accounts", major_version = 1, lending = .Server}

/** An account's name and its password. */
Credentials :: struct {
    /** The account's name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** Its password, as UTF-8 as typed; the account service wipes the request once it's answered. */
    password : slop_os.Relative[u8],
}

/** A new account, and when it's made, as the asker says. */
Creation :: struct {
    /** Its name: 1 to 32 bytes, a lowercase letter, then letters, digits, - or _. */
    name : slop_os.Relative[u8],
    /** Its password, as UTF-8 as typed, which account_records' password rules have to allow. */
    password : slop_os.Relative[u8],
    /** When it's made, as the asker says, in nanoseconds since 1970; written into its record. */
    now : u64,
}

/** Another account, made by the administrator: their name and password, and the new account. */
Elevated :: struct {
    /** The administrator's name and password, which have to open the administrator's home. */
    administrator : Credentials,
    /** The new account. */
    creation : Creation,
}

/** A shared volume, by its name, and its owner's and a member's names. */
ShareOf :: struct {
    /** The name of the account that owns the shared volume, the session's user; its first member. */
    owner : slop_os.Relative[u8],
    /** The shared volume's name, which an account's name rules hold for too. */
    name : slop_os.Relative[u8],
    /** The name of the account added or taken out. */
    member : slop_os.Relative[u8],
}

/** A password changed: the account, its password now, and the new one. */
PasswordChange :: struct {
    /** The account's name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** Its password now, which has to open its home. */
    password : slop_os.Relative[u8],
    /** The new password, which account_records' password rules have to allow. */
    new_password : slop_os.Relative[u8],
}

/** A lost password replaced: the account's recovery code, as its owner types it, and the new password. */
Recovery :: struct {
    /** The account's name, as UTF-8. */
    name : slop_os.Relative[u8],
    /** Its recovery code, as its owner types it, XXXXX-XXXXX-XXXXX-XXXXX-XXXXX. */
    code : slop_os.Relative[u8],
    /** The new password, which account_records' password rules have to allow. */
    new_password : slop_os.Relative[u8],
}

/** A key added to an account, removed from it, or logging in as it. */
KeyChange :: struct {
    /** The account's name, as UTF-8. */
    name : slop_os.Relative[u8],
    /**
     * For AddKey, the key's line, as authorized_keys or a .pub file has it, at most account_records.KEY_LINE_BYTES;
     * for RemoveKey, its fingerprint, SHA256: and 43 characters of base64; for OpenHomeByKey, its blob, as SSH sends
     * it.
     */
    key : slop_os.Relative[u8],
}

/** The bytes of the recovery code as text, XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, shown once: 29. */
RECOVERY_TEXT_BYTES :: 29

/** An account's recovery code, as text, shown once. */
RecoveryText :: struct {
    /** The code, XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, every byte of it, ASCII. */
    text : u8[RECOVERY_TEXT_BYTES],
}

/** What the account service has. */
Status :: struct {
    /** How many accounts there are; 0 before the first is made, at first boot. */
    accounts : u32,
}

/** What a client, the trusted path, asks the account service. */
Request :: union {
    /** Ask how many accounts there are. Answered with Described. */
    Describe,
    /**
     * Make the first account, the administrator, at first boot, with its home volume. Answered with Created,
     * NameRefused, PasswordRefused, AlreadyExists, Failed, or Refused once there's an account.
     */
    Create(Creation),
    /**
     * Make another account, which the administrator's name and password allow (decisions/0158). Answered as Create
     * is, or WrongCredentials when they don't open the administrator's home or the account isn't the
     * administrator's, which counts as a wrong login does, or RateLimited.
     */
    CreateBy(Elevated),
    /**
     * Check an administrator's name and password, for an act elevation allows that isn't making an account, as shutting
     * the system down (decisions/0182). Answered with Done; WrongCredentials when they don't open the administrator's
     * home or the account isn't the administrator's, which counts as a wrong login does; or RateLimited.
     */
    CheckAdministrator(Credentials),
    /**
     * Share a volume with a member, made the first time, its owner its first member, the volume's secret sealed to
     * the member's public key. Answered with Shared, NameRefused, AlreadyExists for a member already in it or the
     * owner, NoSuchAccount, Refused when the volume isn't the owner's, or Failed.
     */
    Share(ShareOf),
    /**
     * Take a member out of a shared volume: their sealed secret dropped, every link into the volume revoked, and its
     * next key generation started. Answered with Shared, NoSuchAccount for one not in it, Refused when the volume
     * isn't the owner's, or Failed.
     */
    Unshare(ShareOf),
    /**
     * Open an account's home volume with its password. Answered with OpenedHome, WrongCredentials, RateLimited, or
     * Failed.
     */
    OpenHome(Credentials),
    /**
     * Change an account's password. Answered with Done, PasswordRefused, WrongCredentials, RateLimited, or Failed.
     */
    ChangePassword(PasswordChange),
    /**
     * Replace a lost password with the account's recovery code. Answered as ChangePassword is, a wrong code being
     * WrongCredentials.
     */
    Recover(Recovery),
    /**
     * Have the account service serve another client, on the end given, which moves to it; it's closed if the service
     * already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Accounts]),
    /** List an account's public keys, by its name. Answered with KeysListed, NoSuchAccount, or Failed. */
    ListKeys(slop_os.Relative[u8]),
    /**
     * Add a public key to an account. Answered with Done; KeyRefused for a line that isn't a key; AlreadyExists for a key
     * it has, whatever its comment; Refused when it has account_records.MAX_KEYS; NoSuchAccount; or Failed.
     */
    AddKey(KeyChange),
    /** Remove a public key from an account, by its fingerprint. Answered with Done, NoSuchKey, NoSuchAccount, or Failed. */
    RemoveKey(KeyChange),
    /**
     * Open an account's home volume for one of its public keys (decisions/0042, 0191), its key as SSH sends it (its
     * blob), whose signature the asker has checked. A key can't unlock a home: it's opened only if its password has
     * since the service started. Answered with OpenedHome; HomeLocked if the key's the account's but its home hasn't
     * been unlocked; WrongCredentials for no such account or a key it doesn't have; or Failed.
     */
    OpenHomeByKey(KeyChange),
}

/** What the account service answers. */
Response :: union {
    /** Describe's answer. */
    Described(Status),
    /** Create's or CreateBy's answer: the account's made, the administrator if it's the first: its recovery code. */
    Created(RecoveryText),
    /** OpenHome's answer: a connection to the home volume's root, which moves to the client. */
    OpenedHome(os.Channel[dir.Dir]),
    /** ChangePassword's or Recover's answer: the password's replaced; CheckAdministrator's: they're the administrator's. */
    Done,
    /**
     * The answer when the password's refused, why as account_records.PasswordProblem: 1 too short, 2 too long, 3
     * common, 4 the name.
     */
    PasswordRefused(u8),
    /**
     * The answer when it's not a name an account may have: 1 to 32 bytes, a lowercase letter, then letters, digits, -
     * or _.
     */
    NameRefused,
    /** The answer when an account of that name is there already, or the member is in the shared volume already. */
    AlreadyExists,
    /** The answer when there's no such account, or the wrong password or recovery code: which isn't said. */
    WrongCredentials,
    /**
     * The answer after too many wrong attempts, for that account or from that client: the nanoseconds until the next
     * is heard.
     */
    RateLimited(u64),
    /** The answer when it's not allowed: Create once there's an account, or sharing a volume another owns. */
    Refused,
    /**
     * Share's or Unshare's answer: a grant of the shared volume's root, for its owner's link, which moves to the
     * client.
     */
    Shared(os.Channel[grant.Grant]),
    /**
     * The answer when there's no account of the member's name, or none with a key pair yet: it's made at its next
     * login.
     */
    NoSuchAccount,
    /** The answer when its records or volumes couldn't be read, written or made. */
    Failed,
    /**
     * ListKeys' answer: the account's keys, a line each, as authorized_keys has them, each ended by a line break; empty
     * for none.
     */
    KeysListed(slop_os.Relative[u8]),
    /** AddKey's answer when the line isn't a key the account service reads. */
    KeyRefused,
    /** RemoveKey's answer when no key of the account's has the fingerprint. */
    NoSuchKey,
    /** OpenHomeByKey's answer when the key's the account's, but its home hasn't been unlocked with its password yet. */
    HomeLocked,
    /** The answer to a request the account service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for Describe, CheckAdministrator, OpenHome, Connect and ListKeys; false for the rest, which make or change
 *     something.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case Create(_) => false
        case CreateBy(_) => false
        case CheckAdministrator(_) => true
        case Share(_) => false
        case Unshare(_) => false
        case OpenHome(_) => true
        case ChangePassword(_) => false
        case Recover(_) => false
        case Connect(_) => true
        case ListKeys(_) => true
        case AddKey(_) => false
        case RemoveKey(_) => false
        case OpenHomeByKey(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the account service: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the service takes the end when it next serves its listener, or closes it when it's full, which the
 * caller learns of as its end's peer gone.
 *
 * @param end The service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
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
