/**
 * Accounts' public keys (decisions/0191, 14c), which log in as them over SSH: each account's in <name>.keys beside its
 * record, as account_records' authorized_keys writes them, a line each; no file is no keys. A change is written to
 * <name>.newkeys, then moved over the last, so one that stops leaves the old keys whole, and the volume's synced.
 */
package account_service

import runtime from "base"
import os from "std"
import account_records from "../../account_records"
import accounts from "../../protocols/accounts"
import compiler from "base"
import crypto from "std"
import log_line from "../../log_line"

/** What an account's keys' file name ends with, its account's name before it. */
KEYS_SUFFIX :: ".keys"
/** What a new keys file's name ends with, while it's written. */
KEYS_NEW_SUFFIX :: ".newkeys"

/**
 * List an account's keys.
 *
 * @param service The service, from whose accounts volume they're read.
 * @param name The account's name.
 * @param out The answer's message, which the keys' text is appended to.
 * @return KeysListed; NoSuchAccount for a name with no record; Failed if they couldn't be read.
 */
list_keys :: fn(service: ptr[mut Service], name: u8[], out: ptr[mut os.Outgoing]) -> accounts.Response {
    if read_record(service, name) is_none {
        return .NoSuchAccount
    }
    keys :: read_keys(service, name) or_return .Failed
    defer free_keys(keys)
    return .KeysListed(os.append(out, string_bytes(keys)))
}

/**
 * Add a key to an account's keys.
 *
 * @param service The service, on whose accounts volume they're written.
 * @param name The account's name.
 * @param line The key's line.
 * @return Done; KeyRefused for a line that isn't a key; AlreadyExists for one it has; Refused when it has
 *     account_records.MAX_KEYS; NoSuchAccount; or Failed if they couldn't be read or written.
 */
add_key :: fn(service: ptr[mut Service], name: u8[], line: u8[]) -> accounts.Response {
    if read_record(service, name) is_none {
        return .NoSuchAccount
    }
    keys :: read_keys(service, name) or_return .Failed
    defer free_keys(keys)
    into, error :: runtime.new_array(u8, account_records.KEYS_TEXT_BYTES)
    if error != null {
        return .Failed
    }
    defer runtime.free_array(into)
    match account_records.add_key(string_bytes(keys), line, into) {
        case Added(length) => {
            if length > into.count || !write_keys(service, name, into[0..<length]) {
                return .Failed
            }
            log_line.write(service.log, "account_service: added a key to %", name_text(name))
            return .Done
        }
        case NotAKey => return .KeyRefused
        case AlreadyThere => return .AlreadyExists
        case Full => return .Refused
    }
}

/**
 * Remove a key from an account's keys, by its fingerprint.
 *
 * @param service The service.
 * @param name The account's name.
 * @param fingerprint The key's fingerprint, SHA256:...
 * @return Done; NoSuchKey if none of its keys has it; NoSuchAccount; or Failed.
 */
remove_key :: fn(service: ptr[mut Service], name: u8[], fingerprint: u8[]) -> accounts.Response {
    if read_record(service, name) is_none {
        return .NoSuchAccount
    }
    keys :: read_keys(service, name) or_return .Failed
    defer free_keys(keys)
    into, error :: runtime.new_array(u8, keys.count)
    if error != null {
        return .Failed
    }
    defer runtime.free_array(into)
    length :: account_records.remove_key(string_bytes(keys), fingerprint, into) or_return .NoSuchKey
    if length > into.count || !write_keys(service, name, into[0..<length]) {
        return .Failed
    }
    log_line.write(service.log, "account_service: removed a key from %", name_text(name))
    return .Done
}

/**
 * Read an account's keys' text.
 *
 * @param service The service.
 * @param name The account's name, valid_name's.
 * @return The text, which free_keys gives back; "" when the account has no keys file; null if it couldn't be read.
 */
read_keys :: fn(service: ptr[mut Service], name: u8[]) -> string? {
    path : u8[PATH_BYTES]
    text :: path_of(name, KEYS_SUFFIX, &path)
    match os.read_entire_file_in(service.store, text) {
        case Ok(contents) => return contents
        case Error(error) => return if error == .NotFound { "" } else { null }
    }
}

/** Give back what read_keys gave. */
free_keys :: fn(keys: string) {
    if keys.count > 0 {
        runtime.free_array(bit_cast[u8[]](keys))
    }
}

/**
 * Write an account's keys: to <name>.newkeys, moved over <name>.keys, and the volume synced.
 *
 * @return True once they're in place and synced.
 */
write_keys :: fn(service: ptr[mut Service], name: u8[], keys: u8[]) -> bool {
    fresh : u8[PATH_BYTES]
    kept : u8[PATH_BYTES]
    fresh_path :: path_of(name, KEYS_NEW_SUFFIX, &fresh)
    kept_path :: path_of(name, KEYS_SUFFIX, &kept)
    contents :: if keys.count > 0 { string_of(&keys[0], keys.count) } else { "" }
    if os.write_entire_file_in(service.store, fresh_path, contents) is_some {
        return false
    }
    if os.rename_in(service.store, fresh_path, kept_path) is_some {
        return false
    }
    return sync_store(service)
}

/** A name's bytes as text, for the log. */
name_text :: fn(name: u8[]) -> string {
    return if name.count > 0 { string_of(&name[0], name.count) } else { "" }
}

/** The most homes whose secrets are kept for key logins, each unlocked since the service started. */
MAX_UNLOCKED_HOMES :: 32

/**
 * A home unlocked with its password since the service started (decisions/0042: from the first login until shutdown),
 * its secret kept so a key login can open it.
 */
UnlockedHome :: struct {
    /** The account's name, the first name_bytes bytes. */
    name : u8[account_records.MAX_NAME_BYTES],
    /** How many of name's bytes are the name: 0 for a place not in use. */
    name_bytes : usize,
    /** The home volume's secret; kept, not wiped, for as long as the service runs. */
    secret : crypto.Key256,
}

/**
 * Keep a home's secret once its password's unlocked it, for key logins; past MAX_UNLOCKED_HOMES, it isn't kept.
 *
 * @param service The service, whose unlocked homes it's added to, or whose place for the account's is written again.
 * @param name The account's name.
 * @param home The home's secret, copied.
 */
remember_home #constant_time :: fn(service: ptr[mut Service], name: u8[], home: ptr[crypto.Key256]) {
    if name.count == 0 || name.count > account_records.MAX_NAME_BYTES {
        return void
    }
    free := service.unlocked.count
    for &kept, i in service.unlocked {
        if kept.name_bytes == name.count && name.count <= kept.name.count && same(kept.name[0..<name.count], name) {
            kept.secret = home^
            return void
        }
        if kept.name_bytes == 0 && free == service.unlocked.count {
            free = i
        }
    }
    if free >= service.unlocked.count {
        return void
    }
    place :: &service.unlocked[free]
    for byte, i in name {
        if i < place.name.count {
            place.name[i] = byte
        }
    }
    place.name_bytes = name.count
    place.secret = home^
}

/**
 * Open an account's home for one of its keys, if its password has unlocked it since the service started.
 *
 * @param service The service.
 * @param name The account's name.
 * @param blob The key, as SSH sends it, its signature checked by the asker.
 * @return OpenedHome; HomeLocked for the account's key whose home isn't unlocked; WrongCredentials for no such account
 *     or a key it doesn't have; Failed if its keys or volume couldn't be read or opened.
 */
open_home_by_key :: fn(service: ptr[mut Service], name: u8[], blob: u8[]) -> accounts.Response {
    record := read_record(service, name) or_return .WrongCredentials
    keys :: read_keys(service, name) or_return .Failed
    defer free_keys(keys)
    if !account_records.has_key(string_bytes(keys), blob) {
        return .WrongCredentials
    }
    for &kept in service.unlocked {
        if kept.name_bytes == name.count && name.count > 0 && name.count <= kept.name.count && same(kept.name[0..<name.count], name) {
            return match open_volume_with(service, name, &kept.secret) {
                case OpenedFiles(root) => {
                    join_shares(service, &record, &kept.secret, root.end)
                    log_line.write(service.log, "account_service: opened %'s home for a key", name_text(name))
                    accounts.Response.OpenedHome(root)
                }
                case _ => .Failed
            }
        }
    }
    return .HomeLocked
}
