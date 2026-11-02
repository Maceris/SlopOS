/*
 * The account service (decisions/0141, roadmap 10b): every account's record, one file each on the accounts volume, a
 * plain volume of the system container it has the storage manager make the first time; and each account's home
 * volume, sealed by a secret only its record holds, wrapped by a key from the password and by one from the recovery
 * code (account_records). It serves the accounts protocol: the first account made is the administrator, who alone can
 * have others made (CreateBy, decisions/0158); a home volume is opened with its password, through the storage manager,
 * and only its root leaves the service.
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

ACCOUNTS_VOLUME :: "accounts"
HOME_PREFIX :: "home-"
RECORD_SUFFIX :: ".account"
// A record's path's room: its name, and the longer suffix
PATH_BYTES :: account_records.MAX_NAME_BYTES + 8
// A home volume's name's room: "home-" and the account's name
HOME_NAME_BYTES :: account_records.MAX_NAME_BYTES + 5
NEW_SUFFIX :: ".new"
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]

// The accounts whose wrong attempts are counted at once; the one counted longest ago gives way to a new one
TRACKED :: 32
ACCOUNT_FREE_FAILURES : u32 : 2
CLIENT_FREE_FAILURES : u32 : 4
SECOND : u64 : 1000000000
MAX_WAIT : u64 : 300 * SECOND

// Wrong attempts in a row, and when the next is heard.
Failures :: struct {
    count : u32,
    next : u64,
}

Tracked :: struct {
    name : u8[account_records.MAX_NAME_BYTES],
    name_bytes : usize,
    failures : Failures,
    used : u64,
}

Service :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    manager : slop_os.Channel,
    manager_port : slop_os.Port,
    container : u32,
    // The accounts volume's root: a connection for its files, and one for Sync
    store : os.Directory,
    store_end : slop_os.Channel,
    store_port : slop_os.Port,
    count : u32,
    tracked : Tracked[TRACKED],
    clients : Failures[service_kit.MAX_CLIENTS],
}

main :: fn(log: slop_os.DebugLog?, storage_service: os.Channel[connector.Connector]?, clients: os.Listener[accounts.Accounts]) -> int {
    block :: slop_os.startup_block()
    service := Service.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)}
    service.port = slop_os.port_create(block.budget) or_return 1
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
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/*
 * The accounts volume, opened, or made the first time, on the first SlopOS container the storage manager has; and how
 * many accounts it holds.
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

// Every request client index has sent, until there are none left, or it's gone.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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
            case CreateBy(elevated) => {
                administrator :: os.items(into, elevated.administrator.name)
                response^ = limited(service, index, administrator) or_else create_by(service, index, administrator,
                    os.items(into, elevated.administrator.password), os.items(into, elevated.creation.name), os.items(into, elevated.creation.password),
                    elevated.creation.now)
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
    }
}

// The first account, the administrator, made with its home volume; its recovery code, shown once.
create :: fn(service: ptr[mut Service], name: u8[], password: u8[], now: u64) -> accounts.Response {
    if service.count > 0 {
        return .Refused
    }
    return made_account(service, name, password, now, true)
}

/*
 * Another account, which the administrator allows: their name and password checked as a login's are, and counted
 * against them when they're wrong or aren't the administrator's; then the account made as the first is, not an
 * administrator.
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

// An account made with its home volume, the administrator or not; its recovery code, shown once.
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

// The account's home volume opened with its password, its root answered.
open_home :: fn(service: ptr[mut Service], client: usize, name: u8[], password: u8[], out: ptr[mut os.Outgoing]) -> accounts.Response {
    record := read_record(service, name) or_else dummy_record()
    home := account_records.unlock_home(&record, password) or_return failed(service, client, name)
    defer account_records.zero_key(&home)
    succeeded(service, client, name)
    return match open_volume_with(service, name, &home) {
        case OpenedFiles(root) => .OpenedHome(root)
        case _ => .Failed
    }
}

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

replace_password #constant_time :: fn(service: ptr[mut Service], record: ptr[mut account_records.AccountRecord], home: ptr[crypto.Key256], password: u8[]) -> accounts.Response {
    if !account_records.set_password(record, home, password, account_records.PASSWORD_ARGON2) || !write_record(service, record) {
        return .Failed
    }
    return .Done
}

/*
 * What a name that isn't an account's is checked against, so a wrong name takes as long as a wrong password: the
 * parameters an account's have, and nothing that opens.
 */
dummy_record :: fn() -> account_records.AccountRecord {
    parameters :: account_records.PASSWORD_ARGON2
    return account_records.AccountRecord.{version = cast[u32le](account_records.RECORD_VERSION), memory_kib = cast[u32le](parameters.memory_kib),
        passes = cast[u32le](parameters.passes), lanes = cast[u32le](parameters.lanes)}
}

// Whether the account, or the client, must wait for its next attempt: how long, as the answer.
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

// A wrong attempt counted against the account and the client: WrongCredentials.
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

// A right one: the account's count and the client's start again.
succeeded :: fn(service: ptr[mut Service], client: usize, name: u8[]) {
    if client < service.clients.count {
        service.clients[client] = Failures.{}
    }
    match tracked_of(service, name, false) {
        case Some(tracked) => tracked.failures = Failures.{}
        case None => {}
    }
}

// What's counted for a name; with add, a place made for it if there's none.
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

// The account's home volume made, sealed by its secret.
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

// The account's home volume opened with its secret.
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

// "home-" and the account's name, appended to out.
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

open_volume :: fn(service: ptr[mut Service], name: string, passphrase: u8[]) -> storage.Response {
    out := os.Outgoing.{}
    opening :: os.begin[storage.Request](&out)
    opening^ = .OpenVolume(storage.VolumeAt.{partition = service.container, name = os.append(&out, string_bytes(name)),
        passphrase = os.append(&out, passphrase)})
    return ask_storage(service, &out)
}

// One request to the storage manager, and its answer, waited for.
ask_storage :: fn(service: ptr[mut Service], out: ptr[mut os.Outgoing]) -> storage.Response {
    if storage.send_request(service.manager, service.manager_port, out) is_some {
        return .Failed
    }
    into := os.Incoming.{}
    loop {
        match storage.receive_response(service.manager, service.manager_port, &into, true) {
            case Received => return os.message_of[storage.Response](&into)^
            case Failed(error) => return .Failed
            case _ => continue
        }
    }
}

// An account's record, from its file, if it has one.
read_record :: fn(service: ptr[mut Service], name: u8[]) -> account_records.AccountRecord? {
    if !account_records.valid_name(name) {
        return null
    }
    path : u8[PATH_BYTES]
    text :: path_of(name, RECORD_SUFFIX, &path)
    contents :: os.read_entire_file_in(service.store, text) or_return null
    defer runtime.free_array(bit_cast[u8[]](contents))
    if contents.count != size_of(account_records.AccountRecord) {
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
    if cast[u32](record.version) != account_records.RECORD_VERSION || !same(account_records.name_of(&record), name) {
        return null
    }
    return record
}

// A record written to a new file, moved over its last, and synced.
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
            case _ => continue
        }
    }
}

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

// When something's made, in nanoseconds since 1970; 0 if the time can't be read.
now_of :: fn() -> u64 {
    return match time.now() {
        case Ok(now) => cast[u64](now.seconds) * SECOND + cast[u64](now.nanos)
        case Error(error) => 0
    }
}

zero_code #constant_time :: fn(code: ptr[mut account_records.RecoveryCode]) {
    for i in cast[usize](0)..<16 {
        code[i] = 0
    }
}

// A message received, zeroed where it was.
wipe :: fn(into: ptr[mut os.Incoming]) {
    for i in 0..<into.words.count {
        into.words[i] = 0
    }
}

// A message sent, zeroed where it was built.
wipe_out :: fn(out: ptr[mut os.Outgoing]) {
    for i in 0..<out.words.count {
        out.words[i] = 0
    }
}

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

// An account's name, as text.
text_of :: fn(name: u8[]) -> string {
    return if name.count == 0 { "" } else { string_of(&name[0], name.count) }
}
