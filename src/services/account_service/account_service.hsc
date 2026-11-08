/**
 * The account service (decisions/0141, roadmap 10b): every account's record, one file each on the accounts volume, a
 * plain volume of the system container it has the storage manager make the first time; and each account's home
 * volume, sealed by a secret only its record holds, wrapped by a key from the password and by one from the recovery
 * code (account_records). It serves the accounts protocol: the first account made is the administrator, who alone can
 * have others made (CreateBy, decisions/0158); a home volume is opened with its password, through the storage manager,
 * and only its root leaves the service.
 *
 * Shared volumes (decisions/0158): a share's record, <name>.share beside the accounts', names its volume,
 * shared-<name>, and its members, the owner first, each with the volume's random secret sealed to their public key.
 * Opening a home opens what its account shares too: its secret key unsealed with the home's secret, each share's secret
 * with that, the volume opened, and a link shared/<name> made in the home if the one there doesn't open. A share's
 * secret is kept in memory once it's opened, as the storage manager keeps volumes unlocked, so the owner can add and
 * remove members. Removing one revokes every link into the volume and starts its next key generation; the owner's link
 * is made again by the trusted path, and the other members' at their next login. A record from before key pairs gets
 * them at its account's next login.
 *
 * Its budget holds Argon2id's 64 MiB for one password at a time, which is how requests are served. A wrong password
 * or recovery code counts against its account and against the client that sent it: from the third in a row for an
 * account, or the fifth for a client, the next is heard only after a wait that doubles from a second, up to five
 * minutes. What counts is kept in memory, so a restart forgets it.
 */
package account_service

import compiler from "base"
import runtime from "base"
import crypto from "std"
import os from "std"
import strings from "std"
import time from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import account_records from "../../account_records"
import accounts from "../../protocols/accounts"
import connector from "../../protocols/connector"
import storage from "../../protocols/storage"
import slopfs from "../../slopfs"
import service_kit from "../../libraries/service_kit"

/** The name of the plain volume the accounts' and shares' records are kept on. */
ACCOUNTS_VOLUME :: "accounts"
/** What an account's home volume's name starts with, its account's name after it. */
HOME_PREFIX :: "home-"
/** What a shared volume's name starts with, its share's name after it. */
SHARED_PREFIX :: "shared-"
/** The directory in a home that its account's links to shared volumes are in, each named after its share. */
SHARED_DIRECTORY :: "shared"
/** What an account's record's file name ends with, its account's name before it. */
RECORD_SUFFIX :: ".account"
/** What a share's record's file name ends with, its share's name before it. */
SHARE_SUFFIX :: ".share"
/**
 * The most shares whose secrets are kept, once opened; past them, a share's isn't kept, so its owner can't change it.
 */
MAX_OPENED_SHARES :: 16
/** A record's path's room: its name, and the longer suffix. */
PATH_BYTES :: account_records.MAX_NAME_BYTES + 8
/** A home volume's name's room: "home-" and the account's name. */
HOME_NAME_BYTES :: account_records.MAX_NAME_BYTES + 5
/** What a record's file is first written as, its name before it, then renamed over the last one. */
NEW_SUFFIX :: ".new"
/**
 * What a share's next record's file name ends with (decisions/0181's F5): its members left, sealed a new secret, kept
 * while its volume is given a new key, then renamed over its record.
 */
NEXT_SUFFIX :: ".next"
/** The partition type of a SlopOS container, "SLOPOS CONTAINER", which the accounts volume is put on. */
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]

/** The accounts whose wrong attempts are counted at once; the one counted longest ago gives way to a new one. */
TRACKED :: 32
/** How many wrong attempts in a row an account has before it waits: the third waits. */
ACCOUNT_FREE_FAILURES : u32 : 2
/** How many wrong attempts in a row a client has before it waits: the fifth waits. */
CLIENT_FREE_FAILURES : u32 : 4
/** A second, in nanoseconds: the first wait. */
SECOND : u64 : 1000000000
/** The longest wait, in nanoseconds: five minutes. */
MAX_WAIT : u64 : 300 * SECOND

/** Wrong attempts in a row, and when the next is heard. */
Failures :: struct {
    /** How many wrong attempts in a row; 0 again after a right one. */
    count : u32,
    /** When the next attempt is heard, on the monotonic clock, in nanoseconds; 0 or past for now. */
    next : u64,
}

/** An account name's wrong attempts, counted. */
Tracked :: struct {
    /** The name, the first name_bytes bytes; it needn't be an account's, as a wrong name counts too. */
    name : u8[account_records.MAX_NAME_BYTES],
    /** How many of name's bytes are the name. */
    name_bytes : usize,
    /** Its wrong attempts in a row. */
    failures : Failures,
    /** When it was first counted, on the monotonic clock; 0 for a place not in use. The oldest gives way first. */
    used : u64,
}

/** The account service's state. */
Service :: struct {
    /** The debug log it writes its lines to, or NO_HANDLE without one. */
    log : slop_os.DebugLog,
    /** The port every client is bound to. */
    port : slop_os.Port,
    /** Its connection to the storage manager, which every volume is made and opened through. */
    manager : slop_os.Channel,
    /** A port bound to manager, waited on for its answers. */
    manager_port : slop_os.Port,
    /** The partition index of the SlopOS container the volumes are on. */
    container : u32,
    /** The accounts volume's root, opened for its files. */
    store : os.Directory,
    /** The accounts volume's root's own connection, for Sync. */
    store_end : slop_os.Channel,
    /** A port bound to store_end. */
    store_port : slop_os.Port,
    /** How many accounts there are: records counted at the start, and those made since. */
    count : u32,
    /** The account names whose wrong attempts are counted. */
    tracked : Tracked[TRACKED],
    /** Each client's wrong attempts, by client index; started again when the index is given to a new client. */
    clients : Failures[service_kit.MAX_CLIENTS],
    /** The shares whose secrets are kept, opened at a member's login or made by their owner. */
    opened : OpenedShare[MAX_OPENED_SHARES],
}

/** A share's secret, kept once it's opened. */
OpenedShare :: struct {
    /** The share's name, the first name_bytes bytes. */
    name : u8[account_records.MAX_NAME_BYTES],
    /** How many of name's bytes are the name: 0 for a place not in use. */
    name_bytes : usize,
    /** The share's secret, which its volume is opened with; kept, not wiped, for as long as the service runs. */
    secret : crypto.Key256,
}

/**
 * Serve the accounts protocol: make accounts, open their home volumes with their passwords, change and recover
 * passwords, and share volumes between accounts.
 *
 * It finds the first SlopOS container the storage manager has and opens its accounts volume, making it the first
 * time, then serves its clients for as long as it runs. Passwords and recovery codes are wiped from each request once
 * it's answered, and a home volume's secret never leaves the service, only its root. Wrong passwords and recovery
 * codes are rate limited per account and per client.
 *
 * @param log The debug log it writes its lines to: that it's serving and how many accounts, each account made, and
 *     what went wrong. Without one, it writes nothing.
 * @param storage_service A connection to the storage manager's connector, dialed for the storage protocol, which
 *     every volume is made and opened through. Without it, the service can't run.
 * @param clients Where connections to the service arrive; a client may connect others with Connect.
 * @return Only on failure, since it serves until it's ended: 1 if its port couldn't be made; 2 without the storage
 *     manager or if dialing it failed; 3 if the accounts volume couldn't be found, made or read; 4 if the listener
 *     couldn't be served.
 */
main :: fn(log: slop_os.DebugLog?, storage_service: os.Channel[connector.Connector]?, clients: os.Listener[accounts.Accounts]) -> int {
    block :: slop_os.startup_block()
    service := Service.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)}
    service.port = slop_os.port_create(block.budget) or_return 1
    _ = service_kit.watch_stop(service.port)
    dialing :: storage_service or_else os.Channel[connector.Connector].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    if cast[slop_os.Handle](dialing.end) == slop_os.NO_HANDLE {
        log_line.write(service.log, "account_service: no storage manager")
        return 2
    }
    dial_port :: os.port_for(block.budget, dialing.end) or_return 2
    manager :: connector.dial[storage.Storage](dialing.end, dial_port) or_return 2
    service.manager = manager.end
    service.manager_port = os.port_for(block.budget, manager.end) or_return 2
    if !open_store(&service) {
        return 3
    }
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, service.port, clients.end) {
        return 4
    }
    log_line.write(service.log, "account_service: serving % account%", service.count, if service.count == 1 { "" } else { "s" })
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(&service, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Open the accounts volume, or make it the first time, on the first SlopOS container the storage manager has, and
 * count the accounts it holds.
 *
 * Only the first 64 partitions are looked at. The accounts volume is plain: what's on it is sealed record by record.
 *
 * @param service The service, whose container, store, store_end, store_port and count are set.
 * @return True once it's open and counted; false, with why logged for some, if there's no container, or the volume
 *     couldn't be opened, made, connected to or listed.
 */
open_store :: fn(service: ptr[mut Service]) -> bool {
    block :: slop_os.startup_block()
    found := cast[u32](0xffffffff)
    for index in 0..<cast[u32](64) {
        out := os.Outgoing.{}
        describing :: os.begin[storage.Request](&out)
        describing^ = .Describe(index)
        match ask_storage(service, &out) {
            case Described(described) => {
                if described.info.type_guid == CONTAINER_TYPE {
                    found = index
                    break
                }
            }
            case _ => break
        }
    }
    if found == 0xffffffff {
        log_line.write(service.log, "account_service: no SlopOS container")
        return false
    }
    service.container = found
    root := os.Channel[dir.Dir].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match open_volume(service, ACCOUNTS_VOLUME, u8.[]) {
        case OpenedFiles(opened) => root = opened
        case NoVolume => {
            out := os.Outgoing.{}
            creating :: os.begin[storage.Request](&out)
            creating^ = .CreateVolume(storage.NewVolume.{partition = found, name = os.append(&out, string_bytes(ACCOUNTS_VOLUME)),
                passphrase = os.append(&out, u8.[]), cipher = cast[u8](slopfs.Cipher.None), now = now_of()})
            match ask_storage(service, &out) {
                case OpenedFiles(opened) => root = opened
                case _ => {
                    log_line.write(service.log, "account_service: couldn't make the accounts volume")
                    return false
                }
            }
            log_line.write(service.log, "account_service: made the accounts volume")
        }
        case _ => {
            log_line.write(service.log, "account_service: couldn't open the accounts volume")
            return false
        }
    }
    service.store_end = root.end
    service.store_port = os.port_for(block.budget, root.end) or_return false
    files :: dir.connect(root.end, service.store_port, block.budget) or_return false
    directory, error :: os.directory_on(files.end)
    if error != null {
        return false
    }
    service.store = directory
    match os.list_directory_in(service.store, "") {
        case Ok(listing) => {
            for entry in listing {
                if !entry.is_directory && strings.ends_with(entry.name, RECORD_SUFFIX) {
                    service.count += 1
                }
            }
            os.free_directory_listing(listing)
        }
        case Error(error) => return false
    }
    return true
}

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * Each request's message is wiped once it's answered, the passwords and recovery codes in it among it. Requests with a
 * password or recovery code are answered RateLimited while the account or the client must wait. A client that's gone
 * is dropped, and its count of wrong attempts with it.
 *
 * @param service The service, whose port each client's end is bound to; a client's count of wrong attempts
 *     starts again when it's dropped or added, and its requests make accounts, rewrite records and open volumes.
 * @param connected The clients; a Connect adds one, whose count of wrong attempts starts at 0.
 * @param index The client's index; one past the clients, or dropped, is passed over.
 * @param into Where each request is received, reused from one to the next.
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
        match accounts.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = accounts.answer_unsupported(end, service.port)
                continue
            }
            case _ => {
                service_kit.drop_client(connected, index)
                if index < service.clients.count {
                    service.clients[index] = Failures.{}
                }
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[accounts.Response](&out)
        response^ = .Failed
        match os.message_of[accounts.Request](into)^ {
            case Describe => response^ = .Described(accounts.Status.{accounts = service.count})
            case Create(creation) => response^ = create(service, os.items(into, creation.name), os.items(into, creation.password), creation.now)
            case Share(asked) => response^ = share(service, os.items(into, asked.owner), os.items(into, asked.name), os.items(into, asked.member))
            case Unshare(asked) => response^ = unshare(service, os.items(into, asked.owner), os.items(into, asked.name), os.items(into, asked.member))
            case CreateBy(elevated) => {
                administrator :: os.items(into, elevated.administrator.name)
                response^ = limited(service, index, administrator) or_else create_by(service, index, administrator,
                    os.items(into, elevated.administrator.password), os.items(into, elevated.creation.name), os.items(into, elevated.creation.password),
                    elevated.creation.now)
            }
            case CheckAdministrator(credentials) => {
                administrator :: os.items(into, credentials.name)
                response^ = limited(service, index, administrator) or_else check_administrator(service, index, administrator,
                    os.items(into, credentials.password))
            }
            case OpenHome(credentials) => {
                name :: os.items(into, credentials.name)
                response^ = limited(service, index, name) or_else open_home(service, index, name, os.items(into, credentials.password), &out)
            }
            case ChangePassword(change) => {
                name :: os.items(into, change.name)
                response^ = limited(service, index, name)
                    or_else change_password(service, index, name, os.items(into, change.password), os.items(into, change.new_password))
            }
            case Recover(recovery) => {
                name :: os.items(into, recovery.name)
                response^ = limited(service, index, name)
                    or_else recover(service, index, name, os.items(into, recovery.code), os.items(into, recovery.new_password))
            }
            case Connect(connection) => {
                match service_kit.add_client_index(connected, service.port, connection.end) {
                    case Some(added) => {
                        if added < service.clients.count {
                            service.clients[added] = Failures.{}
                        }
                    }
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        // What the request held, its passwords among it, gone before the next
        wipe(into)
        _ = accounts.send_response(end, service.port, &out)
        // And what the answer held, a new recovery code's text among it
        wipe_out(&out)
    }
}

/**
 * Make the first account, the administrator, with its home volume.
 *
 * @param service The service, whose count of accounts has to be 0 for the account to be made, and is 1 after.
 * @param name The account's name, valid_name's.
 * @param password Its password, held to password_problem's rules.
 * @param now When it's made, as the client says, kept in the record.
 * @return Created with its recovery code's text, shown once; Refused once there's an account already; or as
 *     made_account answers.
 */
create :: fn(service: ptr[mut Service], name: u8[], password: u8[], now: u64) -> accounts.Response {
    if service.count > 0 {
        return .Refused
    }
    return made_account(service, name, password, now, true)
}

/**
 * Make another account, which the administrator allows: their name and password checked as a login's are, and counted
 * against them when they're wrong or aren't the administrator's; then the account made as the first is, not an
 * administrator.
 *
 * A name that isn't an account's takes as long as a wrong password (dummy_record).
 *
 * @param service The service, whose administrator's record is read, whose counts of wrong attempts change, and
 *     through which the account is made.
 * @param client The client index of who asked, which a wrong attempt counts against.
 * @param administrator The administrator's account name.
 * @param administrator_password The administrator's password; the home secret it unseals is wiped at once.
 * @param name The new account's name; NameRefused unless it's valid_name's, AlreadyExists if it's an account's.
 * @param password The new account's password, held to password_problem's rules; read only.
 * @param now When it's made, as the client says, kept in the record and not interpreted.
 * @return Created with the new account's recovery code's text, shown once; WrongCredentials for a wrong name or
 *     password, or an account that isn't the administrator's; or as made_account answers.
 */
create_by :: fn(service: ptr[mut Service], client: usize, administrator: u8[], administrator_password: u8[], name: u8[], password: u8[],
    now: u64) -> accounts.Response {
    record := read_record(service, administrator) or_else dummy_record()
    home := account_records.unlock_home(&record, administrator_password) or_return failed(service, client, administrator)
    account_records.zero_key(&home)
    if !account_records.is_administrator(&record) {
        return failed(service, client, administrator)
    }
    succeeded(service, client, administrator)
    return made_account(service, name, password, now, false)
}

/**
 * Check an administrator's name and password, for an act elevation allows (decisions/0182): they have to open the
 * administrator's home, as create_by's do. A name that isn't an account's takes as long as a wrong password.
 *
 * @param service The service, whose administrator's record is read, and whose counts of wrong attempts change.
 * @param client The client index of who asked, which a wrong attempt counts against.
 * @param administrator The administrator's account name.
 * @param password Their password; the home secret it unseals is wiped at once.
 * @return Done; WrongCredentials for a wrong name or password, or an account that isn't the administrator's.
 */
check_administrator :: fn(service: ptr[mut Service], client: usize, administrator: u8[], password: u8[]) -> accounts.Response {
    record := read_record(service, administrator) or_else dummy_record()
    home := account_records.unlock_home(&record, password) or_return failed(service, client, administrator)
    account_records.zero_key(&home)
    if !account_records.is_administrator(&record) {
        return failed(service, client, administrator)
    }
    succeeded(service, client, administrator)
    return .Done
}

/**
 * Make an account with its home volume, sealed by a new random secret, the administrator or not.
 *
 * The home's secret and the recovery code are wiped before it returns; the code's text goes in the answer.
 *
 * @param service The service, whose count grows by one.
 * @param name The new account's name, checked with valid_name and that no account has it; it names the record
 *     and the home volume.
 * @param password The new account's password, read only, checked with password_problem against the name; only
 *     the key it makes is kept, sealing the home's secret.
 * @param now When it's made, kept in the record.
 * @param administrator Whether it's the administrator.
 * @return Created with its recovery code's text, shown once; NameRefused for a name that isn't valid_name's;
 *     PasswordRefused with the PasswordProblem; AlreadyExists for a name that's an account's; Failed if the record or
 *     the home volume couldn't be made or written, which may leave a home volume without a record.
 */
made_account :: fn(service: ptr[mut Service], name: u8[], password: u8[], now: u64, administrator: bool) -> accounts.Response {
    if !account_records.valid_name(name) {
        return .NameRefused
    }
    match account_records.password_problem(name, password) {
        case Some(problem) => return .PasswordRefused(cast[u8](problem))
        case None => {}
    }
    if read_record(service, name) is_some {
        return .AlreadyExists
    }
    home := account_records.random_key()
    defer account_records.zero_key(&home)
    code := account_records.new_recovery_code()
    defer zero_code(&code)
    record := account_records.new_record(name, administrator, now, password, account_records.PASSWORD_ARGON2, &home, &code)
        or_return .Failed
    if !make_home(service, name, &home) || !write_record(service, &record) {
        return .Failed
    }
    service.count += 1
    log_line.write(service.log, "account_service: made the account %, %", text_of(name), if administrator { "the administrator" } else { "as the administrator allowed" })
    return .Created(accounts.RecoveryText.{text = account_records.recovery_text(&code)})
}

/**
 * Open an account's home volume with its password, and what it shares (join_shares).
 *
 * A name that isn't an account's takes as long as a wrong password (dummy_record). The home's secret is wiped before
 * it returns.
 *
 * @param service The service, whose record for name is read, whose counts of wrong attempts change, and through
 *     whose storage manager the home and its shares are opened.
 * @param client The client index of who asked, which a wrong attempt counts against.
 * @param name The account's name; one that isn't an account's is tried against dummy_record and counted as wrong.
 * @param password Its password, read only; the request holding it is wiped once it's answered.
 * @param out The answer being built; unused, as the answer carries only the root.
 * @return OpenedHome with the home volume's root, whose end moves to the client; WrongCredentials for a wrong name or
 *     password; Failed if the volume couldn't be opened.
 */
open_home :: fn(service: ptr[mut Service], client: usize, name: u8[], password: u8[], out: ptr[mut os.Outgoing]) -> accounts.Response {
    record := read_record(service, name) or_else dummy_record()
    home := account_records.unlock_home(&record, password) or_return failed(service, client, name)
    defer account_records.zero_key(&home)
    succeeded(service, client, name)
    return match open_volume_with(service, name, &home) {
        case OpenedFiles(root) => {
            join_shares(service, &record, &home, root.end)
            accounts.Response.OpenedHome(root)
        }
        case _ => .Failed
    }
}

/**
 * Open what an account shares, as its home is opened: its key pair made first if its record's from before them; then
 * each share it's a member of, its secret unsealed and kept, its volume opened, and its link in the home made if the
 * one there doesn't open.
 *
 * Nothing's answered: a share that can't be opened or linked is passed over. Its secret key is wiped before it
 * returns.
 *
 * @param service The service: its accounts volume is listed for shares' records, a record given keys is written
 *     there, each share's secret is kept, and each share's volume opened through its storage manager.
 * @param record The account's record, given a key pair and written if it has none.
 * @param home The home volume's secret, read only.
 * @param root The home volume's root, which stays the caller's; the links are made in it.
 */
join_shares #constant_time :: fn(service: ptr[mut Service], record: ptr[mut account_records.AccountRecord], home: ptr[crypto.Key256], root: slop_os.Channel) {
    if !account_records.has_keys(record) {
        if !account_records.set_keys(record, home) || !write_record(service, record) {
            return void
        }
        log_line.write(service.log, "account_service: % has a key pair now", text_of(account_records.name_of(record)))
    }
    key := account_records.secret_key(record, home) or_return void
    defer zero_x25519(&key)
    name :: account_records.name_of(record)
    listed :: os.list_directory_in(service.store, "") or_return void
    defer os.free_directory_listing(listed)
    for entry in listed {
        stem :: share_stem(string_bytes(entry.name)) or_continue
        join_share(service, record, &key, root, stem)
    }
}

/**
 * Join one share an account may be a member of: its secret unsealed from its record, its volume opened and linked in
 * the account's home, and the secret kept.
 *
 * A share whose volume a crash left between two keys (unshare) is settled here: if its record's secret opens it, the
 * next record kept beside it never took and is dropped; if not, the next record's does, and it's put in place.
 *
 * @param service The service: the share's records are read, and the next one put in place or dropped, on its
 *     accounts volume; its volume opened through its storage manager; its secret kept.
 * @param record The account's record, with keys.
 * @param key The account's secret key, read only.
 * @param root The home volume's root, which stays the caller's; the link is made in it.
 * @param name The share's name, from its record's file name.
 */
join_share #constant_time :: fn(service: ptr[mut Service], record: ptr[account_records.AccountRecord], key: ptr[crypto.X25519SecretKey],
    root: slop_os.Channel, name: u8[]) {

    share := read_share(service, name) or_return void
    who :: account_records.name_of(record)
    secret := member_secret(&share, who, key, record) or_return void
    defer account_records.zero_key(&secret)
    match open_shared(service, name, &secret) {
        case OpenedFiles(shared) => {
            // A new key never given before a crash: the next record kept for it goes
            if read_share_from(service, name, NEXT_SUFFIX) is_some {
                drop_next(service, name)
            }
            keep_secret(service, name, &secret)
            linked(service, root, name, who, shared.end)
            return void
        }
        case _ => {}
    }
    // A new key given before a crash, its record not in place yet: the next record's secret opens it
    next := read_share_from(service, name, NEXT_SUFFIX) or_return void
    next_secret := member_secret(&next, who, key, record) or_return void
    defer account_records.zero_key(&next_secret)
    match open_shared(service, name, &next_secret) {
        case OpenedFiles(shared) => {
            if promote_next(service, name) {
                log_line.write(service.log, "account_service: % has its new volume key's record in place", text_of(name))
            }
            keep_secret(service, name, &next_secret)
            linked(service, root, name, who, shared.end)
        }
        case _ => {}
    }
}

/**
 * Unseal a share's secret for one of its members.
 *
 * @param share The share's record, only read.
 * @param name The member's account name.
 * @param key The member's secret key, read only.
 * @param record The member's account record, whose public key the secret was sealed to.
 * @return The secret, for the caller to wipe; null if they aren't a member, or it doesn't unseal.
 */
member_secret #constant_time :: fn(share: ptr[account_records.ShareRecord], name: u8[], key: ptr[crypto.X25519SecretKey],
    record: ptr[account_records.AccountRecord]) -> crypto.Key256? {

    for &member, i in share.members {
        if i >= cast[usize](cast[u32](share.member_count)) {
            break
        }
        if same(account_records.member_name(member), name) {
            return account_records.open_share(key, record.public_key, &member.sealed, account_records.share_name(share))
        }
    }
    return null
}

/**
 * Link a share's volume into a member's home, and log it.
 *
 * @param service The service, which logs.
 * @param root The home volume's root, which stays the caller's.
 * @param name The share's name, the link's.
 * @param who The member's account name, for the log.
 * @param shared The share's volume's root, closed here.
 */
linked :: fn(service: ptr[mut Service], root: slop_os.Channel, name: u8[], who: u8[], shared: slop_os.Channel) {
    if link_share(root, name, shared) {
        log_line.write(service.log, "account_service: % joined %", text_of(who), text_of(name))
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](shared))
}

/**
 * Share a shared volume with a member, for its owner: made the first time, sealed by a new random secret, its owner
 * its first member; then the member added, the secret sealed to their public key, so they needn't be logged in.
 *
 * The owner isn't authenticated here: whoever sends Share is trusted to have checked who the owner is. An existing
 * share's secret has to be kept already, from the owner's login or its making.
 *
 * @param service The service: the share's record is read and written on its accounts volume, the volume made
 *     through its storage manager the first time, and the share's secret kept.
 * @param owner The owner's account name; of an existing share, it has to be the first member's.
 * @param name The share's name, valid_name's.
 * @param member The member's account name, not the owner's.
 * @return Shared with a grant of the volume's root, to write, for the owner's link; NameRefused for a bad name;
 *     AlreadyExists if the member is the owner or a member already; Refused if the owner has no account, the share
 *     is someone else's, or its secret isn't kept; NoSuchAccount if the member has no account, or either has no key
 *     pair yet; Failed if the volume couldn't be made, the share is full, or the record couldn't be written.
 */
share :: fn(service: ptr[mut Service], owner: u8[], name: u8[], member: u8[]) -> accounts.Response {
    if !account_records.valid_name(name) {
        return .NameRefused
    }
    if same(owner, member) {
        return .AlreadyExists
    }
    owner_record := read_record(service, owner) or_return .Refused
    member_record := read_record(service, member) or_return .NoSuchAccount
    if !account_records.has_keys(&owner_record) || !account_records.has_keys(&member_record) {
        return .NoSuchAccount
    }
    record := account_records.ShareRecord.{}
    secret := account_records.random_key()
    defer account_records.zero_key(&secret)
    match read_share(service, name) {
        case Some(found) => {
            record = found
            if cast[u32](record.member_count) == 0 || !same(account_records.member_name(&record.members[0]), owner) {
                return .Refused
            }
            for &each, i in record.members {
                if i < cast[usize](cast[u32](record.member_count)) && same(account_records.member_name(each), member) {
                    return .AlreadyExists
                }
            }
            if !kept_secret(service, name, &secret) {
                return .Refused
            }
        }
        case None => {
            if !make_shared(service, name, &secret) {
                return .Failed
            }
            record = account_records.ShareRecord.{version = cast[u32le](account_records.SHARE_VERSION), name_bytes = cast[u32le](cast[u32](name.count))}
            for byte, i in name {
                if i < record.name.count {
                    record.name[i] = byte
                }
            }
            if !add_member(&record, owner, &owner_record, &secret) {
                return .Failed
            }
            keep_secret(service, name, &secret)
            log_line.write(service.log, "account_service: made the shared volume %, %'s", text_of(name), text_of(owner))
        }
    }
    if !add_member(&record, member, &member_record, &secret) || !write_share(service, &record) {
        return .Failed
    }
    log_line.write(service.log, "account_service: shared % with %", text_of(name), text_of(member))
    return root_grant(service, name, &secret)
}

/**
 * Take a member out of a shared volume, for its owner (decisions/0181's F5): the members left sealed a new secret, the
 * volume given a new volume key wrapped by it, every link into it revoked, and what was written before sealed again
 * with the new key in the background, so nothing on the disk opens with what the member had once it's done.
 *
 * In an order a crash can't break: the members left's record is written beside the share's and synced, then the
 * volume's key changed, which its server commits, then the record renamed over the share's and synced. A crash
 * between leaves the old record opening the volume and the next one dropped, or the next one opening it and put in
 * place, by the next member to log in (join_share). The owner isn't authenticated here, as with share. The other
 * members' links are made again at their next login.
 *
 * @param service The service: the share's records are written on its accounts volume, Rekey sent to its storage
 *     manager, and the new secret kept.
 * @param owner The owner's account name, which has to be the share's first member's; it isn't authenticated.
 * @param name The share's name; Refused if it has no record.
 * @param member The member's account name; the owner can't be taken out.
 * @return Shared with a grant of the volume's root, to write, for the owner's link; Refused if there's no such share,
 *     it's someone else's, or its secret isn't kept; NoSuchAccount if the member isn't one; Failed if a member left
 *     has no key pair, a record couldn't be written or synced, or the volume couldn't take a new key or be opened,
 *     the member then still in it.
 */
unshare #constant_time :: fn(service: ptr[mut Service], owner: u8[], name: u8[], member: u8[]) -> accounts.Response {
    record := read_share(service, name) or_return .Refused
    count :: cast[usize](cast[u32](record.member_count))
    if count == 0 || !same(account_records.member_name(&record.members[0]), owner) {
        return .Refused
    }
    // Its owner's opened it since the service started
    secret : crypto.Key256
    defer account_records.zero_key(&secret)
    if !kept_secret(service, name, &secret) {
        return .Refused
    }
    found := count
    for &each, i in record.members {
        if i > 0 && i < count && same(account_records.member_name(each), member) {
            found = i
        }
    }
    if found >= count {
        return .NoSuchAccount
    }
    // The members left, each sealed the new secret
    next_secret := account_records.random_key()
    defer account_records.zero_key(&next_secret)
    next := account_records.ShareRecord.{version = record.version, name_bytes = record.name_bytes, name = record.name}
    for &each, i in record.members {
        if i >= count || i == found {
            continue
        }
        left := read_record(service, account_records.member_name(each)) or_return .Failed
        if !account_records.has_keys(&left) || !add_member(&next, account_records.member_name(each), &left, &next_secret) {
            return .Failed
        }
    }
    // Durable before the volume's key changes
    if !write_share_as(service, &next, NEXT_SUFFIX) || !sync_store(service) {
        return .Failed
    }
    out := os.Outgoing.{}
    rekeying :: os.begin[storage.Request](&out)
    passphrase := compiler.declassify(next_secret)
    rekeying^ = .Rekey(storage.VolumeRekeyed.{partition = service.container, name = shared_name(&out, name),
        passphrase = os.append(&out, passphrase[0..<32])})
    for i in cast[usize](0)..<32 {
        passphrase[i] = 0
    }
    answered :: ask_storage(service, &out)
    wipe_out(&out)
    generation := cast[u32](0)
    match answered {
        case Rotated(floor) => generation = floor
        case _ => {
            drop_next(service, name)
            log_line.write(service.log, "account_service: % couldn't be given a new volume key, so % is still in it", text_of(name), text_of(member))
            return .Failed
        }
    }
    keep_secret(service, name, &next_secret)
    if !promote_next(service, name) {
        return .Failed
    }
    revoked := cast[u64](0)
    match open_shared(service, name, &next_secret) {
        case OpenedFiles(root) => {
            revoked = revoke_all(root.end)
            _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
        }
        case _ => return .Failed
    }
    log_line.write(service.log, "account_service: took % out of %, revoked % links into it, and gave it a new volume key, sealing with key generation %",
        text_of(member), text_of(name), revoked, generation)
    return root_grant(service, name, &next_secret)
}

/**
 * Add a member to a share's record, the share's secret sealed to their public key.
 *
 * @param record The share's record, whose share name the seal is bound to.
 * @param member The member's account name.
 * @param member_record Their account's record, whose public key is sealed to.
 * @param secret The share's secret, read only.
 * @return True once they're in the record; false if it's full, the name's too long, or the seal failed.
 */
add_member #constant_time :: fn(record: ptr[mut account_records.ShareRecord], member: u8[], member_record: ptr[account_records.AccountRecord],
    secret: ptr[crypto.Key256]) -> bool {
    at :: cast[usize](cast[u32](record.member_count))
    if at >= record.members.count || member.count > account_records.MAX_NAME_BYTES {
        return false
    }
    sealed :: account_records.seal_share(secret, member_record.public_key, account_records.share_name(record)) or_return false
    made := account_records.ShareMember.{name_bytes = cast[u32le](cast[u32](member.count)), sealed = sealed}
    for byte, i in member {
        if i < made.name.count {
            made.name[i] = byte
        }
    }
    record.members[at] = made
    record.member_count = cast[u32le](cast[u32](at + 1))
    return true
}

/**
 * Grant a shared volume's root, to write, for its owner's link.
 *
 * @param service The service, through whose storage manager the volume is opened; the root it answers with is
 *     closed before this returns.
 * @param name The share's name; the volume is shared-<name>.
 * @param secret The share's secret, which its volume is opened with.
 * @return Shared with the grant, which moves to the client; Failed if the volume couldn't be opened or granted.
 */
root_grant #constant_time :: fn(service: ptr[mut Service], name: u8[], secret: ptr[crypto.Key256]) -> accounts.Response {
    root :: match open_shared(service, name, secret) {
        case OpenedFiles(opened) => opened.end
        case _ => return .Failed
    }
    defer slop_os.handle_close(cast[slop_os.Handle](root))
    port :: os.port_for(slop_os.startup_block().budget, root) or_return .Failed
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Grant(dir.GrantOf.{write = true})
    return match ask_directory(root, port, &out) {
        case Granted(given) => .Shared(given)
        case _ => .Failed
    }
}

/**
 * Make a link shared/<name> in a home to a shared volume, unless the one there opens.
 *
 * A link there that doesn't open, as after a member's removal revoked it, is removed and made again.
 *
 * @param root The home volume's root, which stays the caller's.
 * @param name The share's name, as its record has it, which names the link, shared/<name>; it isn't checked here,
 *     and what of the path doesn't fit is cut (share_path).
 * @param shared The shared volume's root, which stays the caller's; the link grants it to write.
 * @return True if it made a link; false if the one there opens, or a link couldn't be made.
 */
link_share :: fn(root: slop_os.Channel, name: u8[], shared: slop_os.Channel) -> bool {
    budget :: slop_os.startup_block().budget
    port :: os.port_for(budget, root) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    path_storage : u8[PATH_BYTES + 8]
    path :: share_path(name, &path_storage)
    out := os.Outgoing.{}
    trying :: os.begin[dir.Request](&out)
    trying^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, path)})
    match ask_directory(root, port, &out) {
        case OpenedDirectory(opened) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](opened.end))
            return false
        }
        case _ => {}
    }
    out = os.Outgoing.{}
    making :: os.begin[dir.Request](&out)
    making^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, string_bytes(SHARED_DIRECTORY)), create = true})
    match ask_directory(root, port, &out) {
        case OpenedDirectory(opened) => _ = slop_os.handle_close(cast[slop_os.Handle](opened.end))
        case _ => return false
    }
    out = os.Outgoing.{}
    removing :: os.begin[dir.Request](&out)
    removing^ = .Remove(os.append(&out, path))
    _ = ask_directory(root, port, &out)
    shared_port :: os.port_for(budget, shared) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](shared_port))
    out = os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Grant(dir.GrantOf.{write = true})
    given :: match ask_directory(shared, shared_port, &out) {
        case Granted(made) => made
        case _ => return false
    }
    out = os.Outgoing.{}
    linking :: os.begin[dir.Request](&out)
    linking^ = .Link(dir.LinkTo.{path = os.append(&out, path), grant = given})
    return match ask_directory(root, port, &out) {
        case Done => true
        case _ => false
    }
}

/**
 * Revoke every link a shared volume has issued.
 *
 * Only the first 64 links listed are revoked.
 *
 * @param root The shared volume's root, which stays the caller's.
 * @return How many were revoked.
 */
revoke_all :: fn(root: slop_os.Channel) -> u64 {
    port :: os.port_for(slop_os.startup_block().budget, root) or_return 0
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    numbers : u64[64]
    count : usize = 0
    cursor := cast[u64](0)
    loop {
        if count >= numbers.count {
            break
        }
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Links(cursor)
        match ask_directory(root, port, &out) {
            case Issued(link) => {
                numbers[count] = link.number
                count += 1
                cursor = link.next
            }
            case _ => break
        }
    }
    revoked := cast[u64](0)
    for number, i in numbers {
        if i >= count {
            break
        }
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Revoke(number)
        match ask_directory(root, port, &out) {
            case Done => revoked += 1
            case _ => {}
        }
    }
    return revoked
}

/**
 * Send one request on a directory connection, and wait for its answer.
 *
 * @param end The directory connection the request is sent on, and the answer waited for on with no deadline; the
 *     caller's, not closed.
 * @param port A port bound to it.
 * @param out The request, put together by the caller.
 * @return The answer, whose handles are the caller's; Unsupported if it couldn't be sent or answered.
 */
ask_directory :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(end, port, &into, true) {
            case Received => return os.message_of[dir.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Write a share's link's path in a home: shared/<name>.
 *
 * @param name The share's name, written after "shared/" as it is; not checked to be valid_name's.
 * @param storage Where the path is written; what doesn't fit is cut.
 * @return The path, a view of storage, good as long as it is.
 */
share_path :: fn(name: u8[], storage: ptr[mut u8[PATH_BYTES + 8]]) -> u8[] {
    count : usize = 0
    for byte in string_bytes(SHARED_DIRECTORY) {
        if count < storage.count {
            storage^[count] = byte
            count += 1
        }
    }
    if count < storage.count {
        storage^[count] = cast[u8]('/')
        count += 1
    }
    for byte in name {
        if count < storage.count {
            storage^[count] = byte
            count += 1
        }
    }
    return if count <= storage.count { storage^[0..<count] } else { storage^[0..<0] }
}

/**
 * Keep a share's secret in memory, in place of one kept before for its name.
 *
 * It's kept for as long as the service runs; once MAX_OPENED_SHARES are kept, a new one isn't.
 *
 * @param service The service, whose opened shares take the secret: the place with the name, or else the first
 *     free one.
 * @param name The share's name, copied; one longer than MAX_NAME_BYTES isn't kept.
 * @param secret The secret, copied; the caller wipes its own.
 */
keep_secret #constant_time :: fn(service: ptr[mut Service], name: u8[], secret: ptr[crypto.Key256]) {
    free := service.opened.count
    for &each, i in service.opened {
        if each.name_bytes == name.count && each.name_bytes <= each.name.count && same(each.name[0..<each.name_bytes], name) {
            each.secret = secret^
            return void
        }
        if each.name_bytes == 0 && free == service.opened.count {
            free = i
        }
    }
    if free >= service.opened.count || name.count > account_records.MAX_NAME_BYTES {
        return void
    }
    made := OpenedShare.{name_bytes = name.count, secret = secret^}
    for byte, i in name {
        if i < made.name.count {
            made.name[i] = byte
        }
    }
    service.opened[free] = made
}

/**
 * Find a share's secret, if it's been kept.
 *
 * @param service The service, whose opened shares are searched, not changed.
 * @param name The share's name, compared bytewise with each kept one's.
 * @param secret Where the secret is copied, for the caller to wipe; untouched if it isn't kept.
 * @return True if it's kept.
 */
kept_secret #constant_time :: fn(service: ptr[mut Service], name: u8[], secret: ptr[mut crypto.Key256]) -> bool {
    for &each in service.opened {
        if each.name_bytes == name.count && each.name_bytes <= each.name.count && same(each.name[0..<each.name_bytes], name) {
            secret^ = each.secret
            return true
        }
    }
    return false
}

/**
 * Make a new shared volume, shared-<name>, encrypted, sealed by a secret.
 *
 * The secret goes to the storage manager as the volume's passphrase; the copies made to send it are wiped.
 *
 * @param service The service, whose storage manager makes the volume on its container; the root it answers with
 *     is closed.
 * @param name The share's name; the volume is shared-<name>, what doesn't fit cut.
 * @param secret The share's secret, read only.
 * @return True once it's made; false if the storage manager refused.
 */
make_shared #constant_time :: fn(service: ptr[mut Service], name: u8[], secret: ptr[crypto.Key256]) -> bool {
    out := os.Outgoing.{}
    creating :: os.begin[storage.Request](&out)
    passphrase := compiler.declassify(secret^)
    creating^ = .CreateVolume(storage.NewVolume.{partition = service.container, name = shared_name(&out, name),
        passphrase = os.append(&out, passphrase[0..<32]), cipher = cast[u8](slopfs.Cipher.Aes256Gcm), now = now_of()})
    for i in cast[usize](0)..<32 {
        passphrase[i] = 0
    }
    made :: ask_storage(service, &out)
    wipe_out(&out)
    return match made {
        case OpenedFiles(root) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
            true
        }
        case _ => false
    }
}

/**
 * Open a shared volume with its secret.
 *
 * The copies of the secret made to send it are wiped.
 *
 * @param service The service, whose storage manager opens the volume on its container.
 * @param name The share's name; the volume is shared-<name>, what doesn't fit cut.
 * @param secret The share's secret, read only.
 * @return The storage manager's answer: OpenedFiles with the volume's root, the caller's to close, or another.
 */
open_shared #constant_time :: fn(service: ptr[mut Service], name: u8[], secret: ptr[crypto.Key256]) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    passphrase := compiler.declassify(secret^)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = service.container, name = shared_name(&out, name),
        passphrase = os.append(&out, passphrase[0..<32])})
    for i in cast[usize](0)..<32 {
        passphrase[i] = 0
    }
    opened :: ask_storage(service, &out)
    wipe_out(&out)
    return opened
}

/**
 * Append a shared volume's name, "shared-" and the share's name, to a message.
 *
 * @param out The message being built, whose items the volume's name is appended to.
 * @param name The share's name; what doesn't fit is cut.
 * @return Where it is in the message.
 */
shared_name :: fn(out: ptr[mut os.Outgoing], name: u8[]) -> slop_os.Relative[u8] {
    bytes : u8[HOME_NAME_BYTES + 2]
    count : usize = 0
    for character in SHARED_PREFIX {
        if count < bytes.count {
            bytes[count] = cast[u8](character)
            count += 1
        }
    }
    for byte in name {
        if count < bytes.count {
            bytes[count] = byte
            count += 1
        }
    }
    return os.append(out, if count <= bytes.count { bytes[0..<count] } else { bytes[0..<0] })
}

/**
 * Read a share's record from its file.
 *
 * @param service The service, from whose accounts volume the record's file, <name>.share, is read.
 * @param name The share's name, which the record read has to have too.
 * @return The record; null for a name that isn't valid_name's, no file, or one that isn't a record of this version,
 *     of this name, with at most MAX_MEMBERS members.
 */
read_share :: fn(service: ptr[mut Service], name: u8[]) -> account_records.ShareRecord? {
    return read_share_from(service, name, SHARE_SUFFIX)
}

/**
 * Read a share's record from a file of its name and a suffix.
 *
 * @param service The service, from whose accounts volume the file, <name><suffix>, is read.
 * @param name The share's name, which the record read has to have too.
 * @param suffix SHARE_SUFFIX for its record, or NEXT_SUFFIX for the next one, kept while its volume takes a new key.
 * @return The record; null for a name that isn't valid_name's, no file, or one that isn't a record of this version,
 *     of this name, with at most MAX_MEMBERS members.
 */
read_share_from :: fn(service: ptr[mut Service], name: u8[], suffix: string) -> account_records.ShareRecord? {
    if !account_records.valid_name(name) {
        return null
    }
    path : u8[PATH_BYTES]
    text :: path_of(name, suffix, &path)
    contents :: os.read_entire_file_in(service.store, text) or_return null
    defer runtime.free_array(bit_cast[u8[]](contents))
    if contents.count != size_of(account_records.ShareRecord) {
        return null
    }
    record := account_records.ShareRecord.{}
    view :: view_of(cast[ptr[mut u8]](&record), size_of(account_records.ShareRecord))
    for byte, i in string_bytes(contents) {
        if i < view.count {
            view[i] = byte
        }
    }
    if cast[u32](record.version) != account_records.SHARE_VERSION || !same(account_records.share_name(&record), name)
        || cast[u32](record.member_count) > cast[u32](account_records.MAX_MEMBERS) {
        return null
    }
    return record
}

/**
 * Write a share's record: to a new file, then moved over its last, so a write that stops leaves the old one whole.
 *
 * Unlike an account's record, it isn't synced.
 *
 * @param service The service, on whose accounts volume <name>.new is written, then renamed over <name>.share.
 * @param record The share's record, read only; its name names the file, and all of it is written as it's laid out.
 * @return True once it's in place.
 */
write_share :: fn(service: ptr[mut Service], record: ptr[account_records.ShareRecord]) -> bool {
    return write_share_as(service, record, SHARE_SUFFIX)
}

/**
 * Write a share's record as a file of its name and a suffix: to a new file, then moved over the last, so a write that
 * stops leaves the old one whole. Not synced.
 *
 * @param service The service, on whose accounts volume <name>.new is written, then renamed over <name><suffix>.
 * @param record The share's record, read only; its name names the file, and all of it is written as it's laid out.
 * @param suffix SHARE_SUFFIX for its record, or NEXT_SUFFIX for the next one.
 * @return True once it's in place.
 */
write_share_as :: fn(service: ptr[mut Service], record: ptr[account_records.ShareRecord], suffix: string) -> bool {
    name :: account_records.share_name(record)
    fresh : u8[PATH_BYTES]
    kept : u8[PATH_BYTES]
    fresh_path :: path_of(name, NEW_SUFFIX, &fresh)
    kept_path :: path_of(name, suffix, &kept)
    contents :: string_of(cast[ptr[u8]](record), size_of(account_records.ShareRecord))
    if os.write_entire_file_in(service.store, fresh_path, contents) is_some {
        return false
    }
    return os.rename_in(service.store, fresh_path, kept_path) is_none
}

/**
 * Put a share's next record in place of its record, once its volume's taken the new key the next one's secret is,
 * and sync it.
 *
 * @param service The service, on whose accounts volume <name>.next is renamed over <name>.share, and synced.
 * @param name The share's name.
 * @return True once it's in place and synced.
 */
promote_next :: fn(service: ptr[mut Service], name: u8[]) -> bool {
    next : u8[PATH_BYTES]
    kept : u8[PATH_BYTES]
    if os.rename_in(service.store, path_of(name, NEXT_SUFFIX, &next), path_of(name, SHARE_SUFFIX, &kept)) is_some {
        return false
    }
    return sync_store(service)
}

/**
 * Delete a share's next record, its volume not given the key the next one's secret is.
 *
 * @param service The service, on whose accounts volume <name>.next is deleted, if it's there.
 * @param name The share's name.
 */
drop_next :: fn(service: ptr[mut Service], name: u8[]) {
    next : u8[PATH_BYTES]
    _ = os.remove_in(service.store, path_of(name, NEXT_SUFFIX, &next), false)
}

/**
 * Find a share's name from its record's file name.
 *
 * @param file A file's name in the service's store, as its listing gives it; only read.
 * @return The name without ".share", a view of file; null if it isn't a share's record's.
 */
share_stem :: fn(file: u8[]) -> u8[]? {
    suffix :: string_bytes(SHARE_SUFFIX)
    if file.count <= suffix.count {
        return null
    }
    stem :: file.count - suffix.count
    for byte, i in suffix {
        at :: stem + i
        if at >= file.count || file[at] != byte {
            return null
        }
    }
    return if stem <= file.count { file[0..<stem] } else { null }
}

/**
 * Wipe an X25519 secret key, every byte zeroed.
 *
 * @param key The key, all 32 bytes overwritten with zeros in place.
 */
zero_x25519 #constant_time :: fn(key: ptr[mut crypto.X25519SecretKey]) {
    for i in cast[usize](0)..<32 {
        key[i] = 0
    }
}

/**
 * Change an account's password, given the one it has.
 *
 * The new password is checked first, so a refused one costs no Argon2id. The home's secret is wiped before it returns.
 *
 * @param service The service, whose record for name is read and rewritten, and whose counts of wrong attempts
 *     change.
 * @param client The client index of who asked, which a wrong attempt counts against.
 * @param name The account's name; one that isn't an account's is tried against dummy_record and counted as wrong.
 * @param password Its password now, read only, which has to unseal the home's secret.
 * @param new_password The new password, held to password_problem's rules.
 * @return Done once it's changed; PasswordRefused with the PasswordProblem; WrongCredentials for a wrong name or
 *     password; Failed if it couldn't be sealed or written.
 */
change_password :: fn(service: ptr[mut Service], client: usize, name: u8[], password: u8[], new_password: u8[]) -> accounts.Response {
    match account_records.password_problem(name, new_password) {
        case Some(problem) => return .PasswordRefused(cast[u8](problem))
        case None => {}
    }
    record := read_record(service, name) or_else dummy_record()
    home := account_records.unlock_home(&record, password) or_return failed(service, client, name)
    defer account_records.zero_key(&home)
    succeeded(service, client, name)
    return replace_password(service, &record, &home, new_password)
}

/**
 * Give an account a new password with its recovery code, for when the password's forgotten.
 *
 * The recovery code stays the same. It and the home's secret are wiped before it returns.
 *
 * @param service The service, whose record for name is read and rewritten, and whose counts of wrong attempts
 *     change; it logs a recovery.
 * @param client The client index of who asked, which a wrong attempt counts against.
 * @param name The account's name; one that isn't an account's is tried against dummy_record and counted as wrong.
 * @param typed The recovery code as typed, as parse_recovery reads it; one that can't be read counts as wrong.
 * @param new_password The new password, held to password_problem's rules.
 * @return Done once it's changed; PasswordRefused with the PasswordProblem; WrongCredentials for a wrong name or
 *     code; Failed if it couldn't be sealed or written.
 */
recover :: fn(service: ptr[mut Service], client: usize, name: u8[], typed: u8[], new_password: u8[]) -> accounts.Response {
    match account_records.password_problem(name, new_password) {
        case Some(problem) => return .PasswordRefused(cast[u8](problem))
        case None => {}
    }
    code := account_records.parse_recovery(typed) or_return failed(service, client, name)
    defer zero_code(&code)
    record := read_record(service, name) or_else dummy_record()
    home := account_records.recover_home(&record, &code) or_return failed(service, client, name)
    defer account_records.zero_key(&home)
    succeeded(service, client, name)
    log_line.write(service.log, "account_service: % recovered with its recovery code", text_of(name))
    return replace_password(service, &record, &home, new_password)
}

/**
 * Seal a home's secret by a new password, with PASSWORD_ARGON2, and write the record.
 *
 * @param service The service, on whose accounts volume the record is written and synced.
 * @param record The account's record, whose parameters, salt and wrap are written; if sealing fails it may be half
 *     changed, and it isn't written.
 * @param home The home volume's secret, read only.
 * @param password The new password, checked with password_problem already; read only.
 * @return Done once it's written; Failed if it couldn't be sealed or written.
 */
replace_password #constant_time :: fn(service: ptr[mut Service], record: ptr[mut account_records.AccountRecord], home: ptr[crypto.Key256], password: u8[]) -> accounts.Response {
    if !account_records.set_password(record, home, password, account_records.PASSWORD_ARGON2) || !write_record(service, record) {
        return .Failed
    }
    return .Done
}

/**
 * Make what a name that isn't an account's is checked against, so a wrong name takes as long as a wrong password: the
 * parameters an account's have, and nothing that opens.
 *
 * @return The record, which no password or recovery code opens.
 */
dummy_record :: fn() -> account_records.AccountRecord {
    parameters :: account_records.PASSWORD_ARGON2
    return account_records.AccountRecord.{version = cast[u32le](account_records.RECORD_VERSION), memory_kib = cast[u32le](parameters.memory_kib),
        passes = cast[u32le](parameters.passes), lanes = cast[u32le](parameters.lanes)}
}

/**
 * Tell whether the account, or the client, must wait for its next attempt.
 *
 * @param service The service, whose counts for the client and the name are read, not changed.
 * @param client The client index of who asked; past the clients, only the account's wait counts.
 * @param name The account name asked about; one not tracked has no wait.
 * @return RateLimited with how long the longer of the two waits is, in nanoseconds; null if neither must wait.
 */
limited :: fn(service: ptr[mut Service], client: usize, name: u8[]) -> accounts.Response? {
    now :: slop_os.clock_monotonic() or_else 0
    wait := cast[u64](0)
    if client < service.clients.count && service.clients[client].next > now {
        wait = service.clients[client].next - now
    }
    match tracked_of(service, name, false) {
        case Some(tracked) => {
            if tracked.failures.next > now && tracked.failures.next - now > wait {
                wait = tracked.failures.next - now
            }
        }
        case None => {}
    }
    return if wait > 0 { accounts.Response.RateLimited(wait) } else { null }
}

/**
 * Count a wrong attempt against the account and the client.
 *
 * @param service The service, whose counts for the client and the name each go up by one, past the free ones
 *     setting when the next attempt is heard.
 * @param client The client index of who asked; past the clients, only the name's counted.
 * @param name The account name tried, counted even if it's no account's; a place is made for it if needed.
 * @return WrongCredentials, the answer to give.
 */
failed :: fn(service: ptr[mut Service], client: usize, name: u8[]) -> accounts.Response {
    now :: slop_os.clock_monotonic() or_else 0
    if client < service.clients.count {
        count(&service.clients[client], CLIENT_FREE_FAILURES, now)
    }
    match tracked_of(service, name, true) {
        case Some(tracked) => count(&tracked.failures, ACCOUNT_FREE_FAILURES, now)
        case None => {}
    }
    return .WrongCredentials
}

/**
 * Count a wrong attempt, and once past the free ones, set when the next is heard: a second after this one, doubling
 * with each after it, up to MAX_WAIT.
 *
 * @param failures What's counted.
 * @param free How many wrong attempts in a row are free.
 * @param now The monotonic clock now, in nanoseconds.
 */
count :: fn(failures: ptr[mut Failures], free: u32, now: u64) {
    failures.count += 1
    if failures.count > free {
        doublings :: failures.count - free - 1
        wait := SECOND
        for i in 0..<doublings {
            if wait >= MAX_WAIT {
                break
            }
            wait = wait * 2
        }
        failures.next = now + (if wait > MAX_WAIT { MAX_WAIT } else { wait })
    }
}

/**
 * Start the account's count of wrong attempts and the client's again, after a right one.
 *
 * @param service The service, whose counts for the client and, if it's tracked, the name start again at 0.
 * @param client The client index of who asked; past the clients, only the name's count starts again.
 * @param name The account's name; if it isn't tracked, nothing's changed for it.
 */
succeeded :: fn(service: ptr[mut Service], client: usize, name: u8[]) {
    if client < service.clients.count {
        service.clients[client] = Failures.{}
    }
    match tracked_of(service, name, false) {
        case Some(tracked) => tracked.failures = Failures.{}
        case None => {}
    }
}

/**
 * Find what's counted for an account name.
 *
 * @param service The service, whose tracked names are searched and, with add, a place replaced: one not in use,
 *     or else the one counted longest ago.
 * @param name The account name, compared bytewise; it needn't be an account's. One longer than MAX_NAME_BYTES is
 *     never tracked.
 * @param add Whether to make a place for it if there's none, in place of the one counted longest ago.
 * @return What's counted for it, in service; null if there's none and add is false, or the name's too long.
 */
tracked_of :: fn(service: ptr[mut Service], name: u8[], add: bool) -> ptr[mut Tracked]? {
    if name.count > account_records.MAX_NAME_BYTES {
        return null
    }
    oldest : usize = 0
    for i in 0..<service.tracked.count {
        each :: &service.tracked[i]
        if each.name_bytes == name.count && each.name_bytes <= each.name.count && same(each.name[0..<each.name_bytes], name) && each.used != 0 {
            return each
        }
        if each.used < service.tracked[oldest].used {
            oldest = i
        }
    }
    if !add || oldest >= service.tracked.count {
        return null
    }
    made := Tracked.{name_bytes = name.count, used = slop_os.clock_monotonic() or_else 1}
    for byte, i in name {
        if i < made.name.count {
            made.name[i] = byte
        }
    }
    service.tracked[oldest] = made
    return &service.tracked[oldest]
}

/**
 * Make an account's home volume, encrypted, sealed by its secret.
 *
 * The secret goes to the storage manager as the volume's passphrase; the copies made to send it are wiped.
 *
 * @param service The service, whose storage manager makes the volume on its container; the root it answers with
 *     is closed.
 * @param name The account's name; the volume is home-<name>, what doesn't fit cut.
 * @param home The home volume's secret, read only.
 * @return True once it's made; false if the storage manager refused.
 */
make_home #constant_time :: fn(service: ptr[mut Service], name: u8[], home: ptr[crypto.Key256]) -> bool {
    out := os.Outgoing.{}
    creating :: os.begin[storage.Request](&out)
    // Only the storage manager and the volume server see it, which unwraps the volume's key with it
    passphrase := compiler.declassify(home^)
    creating^ = .CreateVolume(storage.NewVolume.{partition = service.container, name = home_name(&out, name),
        passphrase = os.append(&out, passphrase[0..<32]), cipher = cast[u8](slopfs.Cipher.Aes256Gcm), now = now_of()})
    for i in cast[usize](0)..<32 {
        passphrase[i] = 0
    }
    made :: ask_storage(service, &out)
    wipe_out(&out)
    return match made {
        case OpenedFiles(root) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](root.end))
            true
        }
        case _ => false
    }
}

/**
 * Open an account's home volume with its secret.
 *
 * The copies of the secret made to send it are wiped.
 *
 * @param service The service, whose storage manager opens the volume on its container.
 * @param name The account's name; the volume is home-<name>, what doesn't fit cut.
 * @param home The home volume's secret, read only.
 * @return The storage manager's answer: OpenedFiles with the volume's root, or another.
 */
open_volume_with #constant_time :: fn(service: ptr[mut Service], name: u8[], home: ptr[crypto.Key256]) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    passphrase := compiler.declassify(home^)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = service.container, name = home_name(&out, name),
        passphrase = os.append(&out, passphrase[0..<32])})
    for i in cast[usize](0)..<32 {
        passphrase[i] = 0
    }
    opened :: ask_storage(service, &out)
    wipe_out(&out)
    return opened
}

/**
 * Append a home volume's name, "home-" and the account's name, to a message.
 *
 * @param out The message being built, whose items the volume's name is appended to.
 * @param name The account's name; what doesn't fit is cut.
 * @return Where it is in the message.
 */
home_name :: fn(out: ptr[mut os.Outgoing], name: u8[]) -> slop_os.Relative[u8] {
    bytes : u8[HOME_NAME_BYTES]
    count : usize = 0
    for character in HOME_PREFIX {
        if count < bytes.count {
            bytes[count] = cast[u8](character)
            count += 1
        }
    }
    for byte in name {
        if count < bytes.count {
            bytes[count] = byte
            count += 1
        }
    }
    if count > bytes.count {
        return os.append(out, bytes[0..<0])
    }
    return os.append(out, bytes[0..<count])
}

/**
 * Open a volume on the container through the storage manager.
 *
 * @param service The service, whose storage manager opens the volume on its container, which has to be set.
 * @param name The volume's name as the storage manager knows it: ACCOUNTS_VOLUME, from open_store.
 * @param passphrase Its passphrase; empty for a plain volume.
 * @return The storage manager's answer: OpenedFiles with its root, NoVolume if there's none of that name, or another.
 */
open_volume :: fn(service: ptr[mut Service], name: string, passphrase: u8[]) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = service.container, name = os.append(&out, string_bytes(name)),
        passphrase = os.append(&out, passphrase)})
    return ask_storage(service, &out)
}

/**
 * Send one request to the storage manager, and wait for its answer.
 *
 * @param service The service, on whose storage manager connection the request is sent and the answer waited for,
 *     with no deadline.
 * @param out The request, put together by the caller, who wipes it if it holds a secret.
 * @return The answer, whose handles are the caller's; Failed if it couldn't be sent or answered.
 */
ask_storage :: fn(service: ptr[mut Service], out: ptr[mut os.Outgoing]) -> storage.Response {
    if storage.send_request(service.manager, service.manager_port, out) is_some {
        return .Failed
    }
    into := os.Incoming.{}
    loop {
        match storage.receive_response(service.manager, service.manager_port, &into, true) {
            case Received => return os.message_of[storage.Response](&into)^
            case Failed(error) => return .Failed
            case _ => return .Failed
        }
    }
}

/**
 * Read an account's record from its file.
 *
 * A record from before key pairs, version 1, is read too, made version 2 without them; its next login adds them.
 *
 * @param service The service, from whose accounts volume the record's file, <name>.account, is read.
 * @param name The account's name, which the record read has to have too.
 * @return The record; null for a name that isn't valid_name's, no file, or one that isn't a record of a known size and
 *     version, of this name.
 */
read_record :: fn(service: ptr[mut Service], name: u8[]) -> account_records.AccountRecord? {
    if !account_records.valid_name(name) {
        return null
    }
    path : u8[PATH_BYTES]
    text :: path_of(name, RECORD_SUFFIX, &path)
    contents :: os.read_entire_file_in(service.store, text) or_return null
    defer runtime.free_array(bit_cast[u8[]](contents))
    // One from before key pairs is the same without them, which its next login adds
    if contents.count != size_of(account_records.AccountRecord) && contents.count != account_records.RECORD_V1_BYTES {
        return null
    }
    record := account_records.AccountRecord.{}
    bytes :: string_bytes(contents)
    view :: view_of(cast[ptr[mut u8]](&record), size_of(account_records.AccountRecord))
    for byte, i in bytes {
        if i < view.count {
            view[i] = byte
        }
    }
    expected :: if contents.count == account_records.RECORD_V1_BYTES { cast[u32](1) } else { account_records.RECORD_VERSION }
    if cast[u32](record.version) != expected || !same(account_records.name_of(&record), name) {
        return null
    }
    record.version = cast[u32le](account_records.RECORD_VERSION)
    return record
}

/**
 * Write an account's record: to a new file, moved over its last, so a write that stops leaves the old one whole, and
 * the accounts volume synced.
 *
 * @param service The service, on whose accounts volume <name>.new is written, then renamed over <name>.account,
 *     and the volume synced.
 * @param record The account's record, read only; its name names the file, and all of it is written as it's laid
 *     out.
 * @return True once it's in place and synced.
 */
write_record :: fn(service: ptr[mut Service], record: ptr[account_records.AccountRecord]) -> bool {
    name :: account_records.name_of(record)
    fresh : u8[PATH_BYTES]
    kept : u8[PATH_BYTES]
    fresh_path :: path_of(name, NEW_SUFFIX, &fresh)
    kept_path :: path_of(name, RECORD_SUFFIX, &kept)
    contents :: string_of(cast[ptr[u8]](record), size_of(account_records.AccountRecord))
    if os.write_entire_file_in(service.store, fresh_path, contents) is_some {
        return false
    }
    if os.rename_in(service.store, fresh_path, kept_path) is_some {
        return false
    }
    return sync_store(service)
}

/**
 * Make what's been written on the accounts volume durable: a Sync on its root's own connection.
 *
 * @param service The service, whose accounts volume's root is asked, the answer waited for.
 * @return True once it's synced; false if it couldn't be asked, or didn't answer Done.
 */
sync_store :: fn(service: ptr[mut Service]) -> bool {
    out := os.Outgoing.{}
    syncing :: os.begin[dir.Request](&out)
    syncing^ = .Sync
    if dir.send_request(service.store_end, service.store_port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(service.store_end, service.store_port, &into, true) {
            case Received => return os.message_of[dir.Response](&into)^ == .Done
            case Failed(error) => return false
            case _ => return false
        }
    }
}

/**
 * Write a record's file name: a name and a suffix.
 *
 * @param name The account's or share's name.
 * @param suffix The suffix: RECORD_SUFFIX, SHARE_SUFFIX or NEW_SUFFIX.
 * @param into Where it's written; what doesn't fit is cut.
 * @return The file name, a view of into, good as long as it is.
 */
path_of :: fn(name: u8[], suffix: string, into: ptr[mut u8[PATH_BYTES]]) -> string {
    count : usize = 0
    for byte in name {
        if count < into.count {
            into[count] = byte
            count += 1
        }
    }
    for character in suffix {
        if count < into.count {
            into[count] = cast[u8](character)
            count += 1
        }
    }
    return string_of(&into[0], count)
}

/**
 * Read the wall clock, for when a volume's made.
 *
 * @return Nanoseconds since 1970; 0 if the time can't be read.
 */
now_of :: fn() -> u64 {
    return match time.now() {
        case Ok(now) => cast[u64](now.seconds) * SECOND + cast[u64](now.nanos)
        case Error(error) => 0
    }
}

/**
 * Wipe a recovery code, every byte zeroed.
 *
 * @param code The recovery code, all 16 bytes overwritten with zeros in place.
 */
zero_code #constant_time :: fn(code: ptr[mut account_records.RecoveryCode]) {
    for i in cast[usize](0)..<16 {
        code[i] = 0
    }
}

/**
 * Wipe a message received, zeroed where it was, so the passwords in it are gone.
 *
 * @param into The message received, every word of it zeroed in place; it can receive the next after.
 */
wipe :: fn(into: ptr[mut os.Incoming]) {
    for i in 0..<into.words.count {
        into.words[i] = 0
    }
}

/**
 * Wipe a message sent, zeroed where it was built, so the secret in it is gone.
 *
 * @param out The message built, every word of it zeroed in place, once it's been sent.
 */
wipe_out :: fn(out: ptr[mut os.Outgoing]) {
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
}

/**
 * Compare two byte strings; not in constant time, so only for names.
 *
 * @param a A byte string, read only; may be empty.
 * @param b The byte string it's compared with, read only; may be empty.
 * @return True if they're the same bytes.
 */
same :: fn(a: u8[], b: u8[]) -> bool {
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
 * View an account's name as text, for the log.
 *
 * @param name The name's bytes, not checked to be UTF-8; the text returned is a view of them.
 * @return It as text, a view of name; empty for none.
 */
text_of :: fn(name: u8[]) -> string {
    return if name.count == 0 { "" } else { string_of(&name[0], name.count) }
}
