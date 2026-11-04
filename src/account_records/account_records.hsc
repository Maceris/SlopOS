/**
 * Accounts (decisions/0141, roadmap 10b): the rules a name and a password are held to, and an account's record, which
 * keeps its home volume's secret wrapped twice: by a key Argon2id derives from the password, and by one derived from
 * the recovery code. A wrong password is found by its wrap not opening, so nothing else of it is kept.
 *
 * Passwords follow NIST SP 800-63B: at least 8 characters, counted as code points, up to 256 bytes, no composition
 * rules; refused if they're among the most common (common_passwords.hsc, compared lowercased) or are the account's
 * name. The recovery code is 125 random bits, shown as 25 Crockford base32 characters in five groups of five.
 *
 * Shared volumes (decisions/0158): each account has an X25519 key pair, its secret key sealed by the home volume's
 * secret, so whatever opens the home (the password, the recovery code) opens it too. A shared volume's secret is
 * sealed to each member's public key (seal_share): an ephemeral key's agreement with theirs, through BLAKE3, seals it,
 * and only their secret key opens it, so a member needn't be logged in to be added. A share's record names the volume,
 * its owner, and each member with the secret sealed to them, the owner first.
 */
package account_records

import compiler from "base"
import runtime from "base"
import crypto from "std"
import random from "std"
import unicode from "std"

/** The fewest characters a password may have, counted as code points, not bytes (NIST SP 800-63B). */
MIN_PASSWORD_CHARACTERS : usize : 8
/** The most bytes a password may have; a longer one is refused, not cut. */
MAX_PASSWORD_BYTES : usize : 256
/** The most bytes an account's or a share's name may have, which is the room a record keeps for it. */
MAX_NAME_BYTES : usize : 32

/** Argon2id's parameters for a password: RFC 9106's second recommendation, 64 MiB, 3 passes, 4 lanes. */
PASSWORD_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 65536, passes = 3, lanes = 4}

/** Why a password is refused. */
PasswordProblem :: enum #backed_by(u8) {
    /** Fewer than MIN_PASSWORD_CHARACTERS code points. */
    TooShort = 1,
    /** More than MAX_PASSWORD_BYTES bytes. */
    TooLong = 2,
    /** Among the most common passwords, ignoring ASCII case. */
    Common = 3,
    /** The account's name, ignoring ASCII case. */
    IsName = 4,
}

/** A record's flag: the account is the administrator, who allows new accounts on the trusted path. */
ADMINISTRATOR : u32 : 1
/** The version of the record new_record makes: 2, with a key pair. */
RECORD_VERSION : u32 : 2
/** A record from before key pairs, version 1: the same, without its last 80 bytes, which its next login adds. */
RECORD_V1_BYTES :: 192

/**
 * An account, as the account service keeps it: its name, whether it's the administrator, and its home volume's secret
 * sealed by a key from the password (Argon2id's parameters and salt beside it) and by one from the recovery code.
 */
AccountRecord :: struct #packed {
    /** The record's version: RECORD_VERSION, or 1 for one from before key pairs. */
    version : u32le,
    /** Its flags: ADMINISTRATOR, or 0. */
    flags : u32le,
    /** How many of name's bytes are the name, 1 to MAX_NAME_BYTES. */
    name_bytes : u32le,
    /** The account's name, valid_name's, padded with zeros; every wrap is bound to all of it. */
    name : u8[MAX_NAME_BYTES],
    /** When the account was made, as its maker gave it; new_record doesn't interpret it. */
    created : u64le,
    /** Argon2id's memory for the password, in KiB. */
    memory_kib : u32le,
    /** Argon2id's passes for the password. */
    passes : u32le,
    /** Argon2id's lanes for the password. */
    lanes : u32le,
    /** Argon2id's salt for the password, random, new with each password. */
    salt : u8[16],
    /** The home volume's secret, sealed by the key from the password. */
    home_wrapped : u8[32],
    /** home_wrapped's Poly1305 tag. */
    home_tag : u8[16],
    /** The salt the recovery code's key is derived with, random, made with the record. */
    recovery_salt : u8[16],
    /** The home volume's secret, sealed by the key from the recovery code. */
    recovery_wrapped : u8[32],
    /** recovery_wrapped's Poly1305 tag. */
    recovery_tag : u8[16],
    /** Its X25519 public key, all zeros before it has one (has_keys). */
    public_key : u8[32],
    /** Its X25519 secret key, sealed by the home volume's secret. */
    private_wrapped : u8[32],
    /** private_wrapped's Poly1305 tag. */
    private_tag : u8[16],
}

#assert size_of(AccountRecord) == 272

/** A share's secret, sealed to a member: the ephemeral public key it was agreed with, and the secret, sealed. */
SealedShare :: struct #packed {
    /** The ephemeral X25519 public key the secret was agreed with, made for this seal alone. */
    ephemeral : u8[32],
    /** The share's secret, sealed by the key the agreement gives. */
    wrapped : u8[32],
    /** wrapped's Poly1305 tag. */
    tag : u8[16],
}

/** The most members a share has, its owner among them. */
MAX_MEMBERS :: 8
/** The version of a share's record. */
SHARE_VERSION : u32 : 1

/** A member of a share: their account's name and the share's secret sealed to them. */
ShareMember :: struct #packed {
    /** How many of name's bytes are the name, 1 to MAX_NAME_BYTES. */
    name_bytes : u32le,
    /** The member's account name, padded with zeros. */
    name : u8[MAX_NAME_BYTES],
    /** The share's secret, sealed to the member's public key. */
    sealed : SealedShare,
}

/**
 * A shared volume: its name, its owner's, and its members, the owner first, each with the volume's secret sealed to
 * them.
 */
ShareRecord :: struct #packed {
    /** The record's version, SHARE_VERSION. */
    version : u32le,
    /** How many of name's bytes are the share's name, 1 to MAX_NAME_BYTES. */
    name_bytes : u32le,
    /** The share's name, padded with zeros; each seal is bound to it. */
    name : u8[MAX_NAME_BYTES],
    /** How many of members are in use, from the first: 1, the owner, to MAX_MEMBERS. */
    member_count : u32le,
    /** The members, the owner first. */
    members : ShareMember[MAX_MEMBERS],
}

/** The recovery code: 125 random bits, its top 3 bits 0. */
RecoveryCode :: distinct alias u8[16] #secret

/** How many base32 symbols a recovery code is shown as: 25, of 5 bits each. */
RECOVERY_SYMBOLS : usize : 25
/** The bytes of a recovery code as it's shown: five groups of five, with a hyphen between each. */
RECOVERY_TEXT_BYTES : usize : 29
/** Crockford's base32 alphabet, each symbol's value its index: no I, L, O or U. */
CROCKFORD :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

/**
 * Tell whether a name is one an account, or a share, may have.
 *
 * @param name The name to check, as bytes, not assumed to be UTF-8; only read.
 * @return True for 1 to 32 bytes, a lowercase ASCII letter, then lowercase letters, digits, - or _; false otherwise.
 */
valid_name :: fn(name: u8[]) -> bool {
    if name.count == 0 || name.count > MAX_NAME_BYTES {
        return false
    }
    for byte, i in name {
        letter :: byte >= cast[u8]('a') && byte <= cast[u8]('z')
        other :: (byte >= cast[u8]('0') && byte <= cast[u8]('9')) || byte == cast[u8]('-') || byte == cast[u8]('_')
        if !letter && (i == 0 || !other) {
            return false
        }
    }
    return true
}

/**
 * Find what's wrong with a password for an account, if anything.
 *
 * The checks go in order: its length in bytes, its length in code points, the name, then the common list, so the
 * first problem found is the one given. Malformed UTF-8 counts a character a byte.
 *
 * @param name The account's name, compared ignoring ASCII case.
 * @param password The password, as typed; not kept, but a lowercased copy is left on the stack.
 * @return The problem, or null if the password is fine.
 */
password_problem :: fn(name: u8[], password: u8[]) -> PasswordProblem? {
    if password.count > MAX_PASSWORD_BYTES {
        return .TooLong
    }
    characters : usize = 0
    at : usize = 0
    loop {
        if at >= password.count {
            break
        }
        point, length :: unicode.decode(password, at)
        at += if length == 0 { 1 } else { length }
        characters += 1
    }
    if characters < MIN_PASSWORD_CHARACTERS {
        return .TooShort
    }
    lower : u8[MAX_PASSWORD_BYTES]
    for byte, i in password {
        if i < lower.count {
            lower[i] = ascii_lower(byte)
        }
    }
    lowered :: lower[0..<password.count]
    if lowered.count == name.count {
        same := true
        for byte, i in lowered {
            if i < name.count && byte != ascii_lower(name[i]) {
                same = false
            }
        }
        if same {
            return .IsName
        }
    }
    if is_common(lowered) {
        return .Common
    }
    return null
}

/**
 * Lowercase an ASCII letter.
 *
 * @param byte Any byte; only ASCII's A to Z are changed, so UTF-8's multibyte sequences pass through whole.
 * @return The byte, A to Z made a to z; any other byte as it was.
 */
ascii_lower :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
}

/**
 * Tell whether a password is among the most common, by binary search of COMMON_PASSWORDS.
 *
 * @param lowered The password, its ASCII letters lowercased already, as the list is.
 * @return True if it's in the list, which holds only passwords of 8 characters or more.
 */
is_common :: fn(lowered: u8[]) -> bool {
    low : usize = 0
    high : usize = COMMON_PASSWORDS.count
    loop {
        if low >= high {
            break
        }
        middle :: low + (high - low) / 2
        if middle >= COMMON_PASSWORDS.count {
            return false
        }
        order :: compare(string_bytes(COMMON_PASSWORDS[middle]), lowered)
        if order == 0 {
            return true
        }
        if order < 0 {
            low = middle + 1
        }
        else {
            high = middle
        }
    }
    return false
}

/**
 * Compare two byte strings bytewise, a shorter one before any it starts.
 *
 * @param a The byte string ordered against b, read only; may be empty.
 * @param b The byte string a is ordered against, read only; may be empty.
 * @return -1 if a comes before b, 0 if they're the same, 1 if a comes after.
 */
compare :: fn(a: u8[], b: u8[]) -> int {
    for byte, i in a {
        if i >= b.count {
            return 1
        }
        if byte != b[i] {
            return if byte < b[i] { -1 } else { 1 }
        }
    }
    return if a.count < b.count { -1 } else { 0 }
}

/**
 * Make a new account's record: its home volume's secret sealed by a key from the password, with new salt, and by one
 * from the recovery code, and a new key pair, its secret key sealed by the home volume's secret.
 *
 * The keys derived along the way are zeroed before it returns.
 *
 * @param name The account's name, copied into the record; it has to be valid_name's. Its password isn't checked here
 *     (password_problem does that).
 * @param administrator Whether the account is the administrator.
 * @param created When the account was made, kept as given.
 * @param password The password, read only; nothing of it is kept but its wrap.
 * @param parameters Argon2id's parameters for the password, kept in the record; PASSWORD_ARGON2 outside tests.
 * @param home The home volume's secret, read only; the caller keeps and wipes it.
 * @param code The recovery code, read only; the caller shows it once and wipes it.
 * @return The record; null if the name isn't valid, Argon2id couldn't have its memory, or a seal failed.
 */
new_record #constant_time :: fn(name: u8[], administrator: bool, created: u64, password: u8[], parameters: crypto.Argon2Parameters,
    home: ptr[crypto.Key256], code: ptr[RecoveryCode]) -> AccountRecord? {

    if !valid_name(name) {
        return null
    }
    record := AccountRecord.{version = cast[u32le](RECORD_VERSION), flags = cast[u32le](if administrator { ADMINISTRATOR } else { 0 }),
        name_bytes = cast[u32le](cast[u32](name.count)), created = cast[u64le](created)}
    for byte, i in name {
        if i < record.name.count {
            record.name[i] = byte
        }
    }
    random.fill(record.recovery_salt)
    recovery := recovery_key(code, &record) or_return null
    defer zero_key(&recovery)
    sealed :: seal_home(&recovery, home, &record, "recovery") or_return null
    record.recovery_wrapped = sealed.wrapped
    record.recovery_tag = sealed.tag
    if !set_password(&record, home, password, parameters) || !set_keys(&record, home) {
        return null
    }
    return record
}

/**
 * Tell whether a record has its key pair yet: one made before shared volumes gets it at its next login.
 *
 * @param record The account's record, read only; its public_key alone is looked at.
 * @return True if its public key isn't all zeros.
 */
has_keys :: fn(record: ptr[AccountRecord]) -> bool {
    for byte in record.public_key {
        if byte != 0 {
            return true
        }
    }
    return false
}

/**
 * Give a record a new X25519 key pair, its secret key sealed by the home volume's secret.
 *
 * The secret key is zeroed once it's sealed. The seal's nonce is fixed, so a record is given a key pair once under a
 * home volume's secret, never again.
 *
 * @param record The record, whose public_key, private_wrapped and private_tag are written; on failure, only some may
 *     be.
 * @param home The home volume's secret, the seal's key, read only.
 * @return True once the pair is in the record; false if the seal failed.
 */
set_keys #constant_time :: fn(record: ptr[mut AccountRecord], home: ptr[crypto.Key256]) -> bool {
    secret := random_key()
    defer zero_key(&secret)
    key : crypto.X25519SecretKey
    for i in cast[usize](0)..<32 {
        key[i] = secret[i]
    }
    public :: crypto.x25519_public_key(&key)
    for i in cast[usize](0)..<32 {
        key[i] = 0
    }
    sealed :: seal_home(home, &secret, record, "key pair") or_return false
    record.private_wrapped = sealed.wrapped
    record.private_tag = sealed.tag
    for i in cast[usize](0)..<32 {
        record.public_key[i] = public[i]
    }
    return true
}

/**
 * Unseal a record's X25519 secret key with the home volume's secret.
 *
 * @param record The account's record, read only, whose private_wrapped and private_tag are opened, bound to its name.
 * @param home The home volume's secret, read only.
 * @return The secret key, which the caller wipes once it's done with it; null if the record has none, or home isn't
 *     its secret.
 */
secret_key #constant_time :: fn(record: ptr[AccountRecord], home: ptr[crypto.Key256]) -> crypto.X25519SecretKey? {
    opened := open_home(home, record.private_wrapped, record.private_tag, record, "key pair") or_return null
    defer zero_key(&opened)
    key : crypto.X25519SecretKey
    for i in cast[usize](0)..<32 {
        key[i] = opened[i]
    }
    return key
}

/**
 * Seal a shared volume's secret to a member's X25519 public key, for them alone to open.
 *
 * A new ephemeral key pair's agreement with their key, through BLAKE3 (share_key), gives the sealing key, so they
 * needn't be logged in. The ephemeral secret key and the sealing key are zeroed before it returns.
 *
 * @param secret The share's secret, read only; the caller keeps and wipes it.
 * @param public The member's public key, from their record.
 * @param share The share's name, which the seal is bound to; at most MAX_NAME_BYTES are used.
 * @return The sealed secret, public by design, for the member's entry in the share's record; null if their key's no
 *     good (a low-order point, which X25519 refuses) or the seal failed.
 */
seal_share #constant_time :: fn(secret: ptr[crypto.Key256], public: u8[32], share: u8[]) -> SealedShare? {
    random_secret := random_key()
    defer zero_key(&random_secret)
    ephemeral : crypto.X25519SecretKey
    for i in cast[usize](0)..<32 {
        ephemeral[i] = random_secret[i]
    }
    ephemeral_public :: crypto.x25519_public_key(&ephemeral)
    theirs : crypto.X25519PublicKey
    for i in cast[usize](0)..<32 {
        theirs[i] = public[i]
    }
    agreed : crypto.SecretByte[32]
    agreed_ok :: crypto.x25519(&ephemeral, &theirs, &agreed)
    for i in cast[usize](0)..<32 {
        ephemeral[i] = 0
    }
    if !agreed_ok {
        return null
    }
    made := SealedShare.{}
    for i in cast[usize](0)..<32 {
        made.ephemeral[i] = ephemeral_public[i]
    }
    key := share_key(&agreed, made.ephemeral, public)
    defer zero_key(&key)
    nonce : crypto.Nonce96
    associated :: share_associated(share)
    plain : crypto.SecretByte[32]
    for i in cast[usize](0)..<32 {
        plain[i] = cast[crypto.SecretByte](secret[i])
    }
    tag : crypto.Tag128
    if !crypto.chacha20_poly1305_seal(&key, &nonce, plain, associated, made.wrapped, &tag) {
        return null
    }
    for i in cast[usize](0)..<16 {
        made.tag[i] = tag[i]
    }
    return compiler.declassify(made)
}

/**
 * Unseal a shared volume's secret sealed to a member, with their secret key.
 *
 * @param key The member's X25519 secret key, read only (secret_key gives it).
 * @param public The member's public key, which the sealing key is bound to.
 * @param sealed The secret as it was sealed to them.
 * @param share The share's name, which the seal is bound to.
 * @return The share's secret, which the caller wipes once it's done with it; null if it isn't theirs, or isn't this
 *     share's, or was changed.
 */
open_share #constant_time :: fn(key: ptr[crypto.X25519SecretKey], public: u8[32], sealed: ptr[SealedShare], share: u8[]) -> crypto.Key256? {
    theirs : crypto.X25519PublicKey
    for i in cast[usize](0)..<32 {
        theirs[i] = sealed.ephemeral[i]
    }
    agreed : crypto.SecretByte[32]
    if !crypto.x25519(key, &theirs, &agreed) {
        return null
    }
    opening := share_key(&agreed, sealed.ephemeral, public)
    defer zero_key(&opening)
    nonce : crypto.Nonce96
    associated :: share_associated(share)
    tag : crypto.Tag128
    for i in cast[usize](0)..<16 {
        tag[i] = sealed.tag[i]
    }
    plain : crypto.SecretByte[32]
    if !crypto.chacha20_poly1305_open(&opening, &nonce, sealed.wrapped, associated, &tag, plain) {
        return null
    }
    secret : crypto.Key256
    for i in cast[usize](0)..<32 {
        secret[i] = cast[u8](plain[i])
    }
    return secret
}

/**
 * Derive the key an X25519 agreement gives, bound to both public keys: BLAKE3, as the agreement's already uniform.
 *
 * @param agreed The agreement, read only; the caller wipes it.
 * @param ephemeral The ephemeral public key of the seal.
 * @param public The member's public key.
 * @return The key, which the caller zeroes once it's used.
 */
share_key #constant_time :: fn(agreed: ptr[crypto.SecretByte[32]], ephemeral: u8[32], public: u8[32]) -> crypto.Key256 {
    hasher := crypto.blake3_start()
    crypto.blake3_update(&hasher, string_bytes("SlopOS shared volume"))
    crypto.blake3_update_secret(&hasher, agreed^)
    crypto.blake3_update(&hasher, ephemeral)
    crypto.blake3_update(&hasher, public)
    hash : crypto.SecretByte[32]
    crypto.blake3_finish_secret(&hasher, hash)
    key : crypto.Key256
    for i in cast[usize](0)..<32 {
        key[i] = cast[u8](hash[i])
    }
    return key
}

/**
 * Make what a share's seal is bound to: that it's a share's, and the share's name.
 *
 * @param share The share's name; at most 32 bytes of it are used.
 * @return "share" padded with zeros to 16 bytes, then the name, padded with zeros.
 */
share_associated :: fn(share: u8[]) -> u8[48] {
    associated : u8[48]
    for character, i in "share" {
        if i < associated.count {
            associated[i] = cast[u8](character)
        }
    }
    for byte, i in share {
        if 16 + i < associated.count {
            associated[16 + i] = byte
        }
    }
    return associated
}

/**
 * Find the name a share's record has.
 *
 * @param record The share's record, read only; the name returned is a view of it.
 * @return The name, a view of the record's bytes, good as long as it is; empty if name_bytes is past the room for it.
 */
share_name :: fn(record: ptr[ShareRecord]) -> u8[] {
    count :: cast[usize](cast[u32](record.name_bytes))
    return if count <= record.name.count { record.name[0..<count] } else { record.name[0..<0] }
}

/**
 * Find the account name a share's member has.
 *
 * @param member The member's entry in a share's record, read only; the name returned is a view of it.
 * @return The name, a view of the member's bytes, good as long as it is; empty if name_bytes is past the room for it.
 */
member_name :: fn(member: ptr[ShareMember]) -> u8[] {
    count :: cast[usize](cast[u32](member.name_bytes))
    return if count <= member.name.count { member.name[0..<count] } else { member.name[0..<0] }
}

/**
 * Change a record's password: the home volume's secret sealed again by a key from the new password, with new
 * parameters and a new salt, so the old password no longer opens it.
 *
 * The key from the password is zeroed before it returns.
 *
 * @param record The record, whose parameters, salt, home_wrapped and home_tag are written. On failure the parameters
 *     and salt may be changed already, so neither password opens it: the caller keeps the record as it was.
 * @param home The home volume's secret, read only.
 * @param password The new password, read only; the caller checks it with password_problem first.
 * @param parameters Argon2id's parameters for it.
 * @return True once it's sealed; false if Argon2id couldn't have its memory or the seal failed.
 */
set_password #constant_time :: fn(record: ptr[mut AccountRecord], home: ptr[crypto.Key256], password: u8[], parameters: crypto.Argon2Parameters) -> bool {
    record.memory_kib = cast[u32le](parameters.memory_kib)
    record.passes = cast[u32le](parameters.passes)
    record.lanes = cast[u32le](parameters.lanes)
    random.fill(record.salt)
    key := password_key(password, record) or_return false
    defer zero_key(&key)
    sealed :: seal_home(&key, home, record, "password") or_return false
    record.home_wrapped = sealed.wrapped
    record.home_tag = sealed.tag
    return true
}

/**
 * Unseal the home volume's secret with the password.
 *
 * This is how a password is checked: nothing else of it is kept. It takes Argon2id's time and memory, by the
 * record's parameters, each time.
 *
 * @param record The account's record, only read: its salt and Argon2id parameters make the key from the password, which
 *     unseals its home_wrapped and home_tag, with its name bound in as associated data.
 * @param password The password typed, read only.
 * @return The home volume's secret, which the caller wipes once it's done with it; null if it's the wrong password,
 *     or Argon2id couldn't have its memory.
 */
unlock_home #constant_time :: fn(record: ptr[AccountRecord], password: u8[]) -> crypto.Key256? {
    key := password_key(password, record) or_return null
    defer zero_key(&key)
    return open_home(&key, record.home_wrapped, record.home_tag, record, "password")
}

/**
 * Unseal the home volume's secret with the recovery code.
 *
 * @param record The account's record, only read: its recovery_salt makes the key from the code, which unseals its
 *     recovery_wrapped and recovery_tag, with its name bound in as associated data.
 * @param code The recovery code, as parse_recovery read it, read only.
 * @return The home volume's secret, which the caller wipes once it's done with it; null if it's the wrong code.
 */
recover_home #constant_time :: fn(record: ptr[AccountRecord], code: ptr[RecoveryCode]) -> crypto.Key256? {
    key := recovery_key(code, record) or_return null
    defer zero_key(&key)
    return open_home(&key, record.recovery_wrapped, record.recovery_tag, record, "recovery")
}

/**
 * Find the name a record has.
 *
 * @param record The account's record, read only; the name returned is a view of it.
 * @return The name, a view of the record's bytes, good as long as it is; empty if name_bytes is past the room for it.
 */
name_of :: fn(record: ptr[AccountRecord]) -> u8[] {
    count :: cast[usize](cast[u32](record.name_bytes))
    return if count <= record.name.count { record.name[0..<count] } else { record.name[0..<0] }
}

/**
 * Tell whether a record's account is the administrator.
 *
 * @param record The account's record, read only; its flags alone are looked at.
 * @return True if its flags have ADMINISTRATOR.
 */
is_administrator :: fn(record: ptr[AccountRecord]) -> bool {
    return (cast[u32](record.flags) & ADMINISTRATOR) != 0
}

/** A 32-byte secret, sealed: public by design. */
Sealed :: struct {
    /** The secret, encrypted by ChaCha20. */
    wrapped : u8[32],
    /** Its Poly1305 tag. */
    tag : u8[16],
}

/**
 * Make what a wrap is bound to: what it's for and the account's name, so a wrap can't be moved to another account or
 * another use.
 *
 * @param what What it's for: "password", "recovery" or "key pair"; at most 16 bytes are used.
 * @param record The record, whose whole name field, padding included, is used.
 * @return what padded with zeros to 16 bytes, then the name field.
 */
associated_of :: fn(what: string, record: ptr[AccountRecord]) -> u8[48] {
    associated : u8[48]
    for character, i in what {
        if i < 16 {
            associated[i] = cast[u8](character)
        }
    }
    for byte, i in record.name {
        associated[16 + i] = byte
    }
    return associated
}

/**
 * Seal a 32-byte secret with ChaCha20-Poly1305, bound to an account and a use.
 *
 * The nonce is all zeros, which is safe only because each key seals once: the keys from a password or the recovery
 * code are new with their salt, and a home volume's secret seals one key pair.
 *
 * @param key The sealing key, read only.
 * @param home The secret sealed: the home volume's, or, for "key pair", the account's secret key.
 * @param record The account, whose name the seal is bound to.
 * @param what What it's for, which the seal is bound to.
 * @return The sealed secret, declassified, as it's public by design; null if the seal failed.
 */
seal_home #constant_time :: fn(key: ptr[crypto.Key256], home: ptr[crypto.Key256], record: ptr[AccountRecord], what: string) -> Sealed? {
    nonce : crypto.Nonce96
    associated :: associated_of(what, record)
    plain : crypto.SecretByte[32]
    for i in cast[usize](0)..<32 {
        plain[i] = cast[crypto.SecretByte](home[i])
    }
    sealed := Sealed.{}
    tag : crypto.Tag128
    if !crypto.chacha20_poly1305_seal(key, &nonce, plain, associated, sealed.wrapped, &tag) {
        return null
    }
    for i in cast[usize](0)..<16 {
        sealed.tag[i] = tag[i]
    }
    // What's sealed is public by design
    return compiler.declassify(sealed)
}

/**
 * Open a 32-byte secret seal_home sealed.
 *
 * @param key The key it was sealed by, read only.
 * @param wrapped The secret as seal_home sealed it: home_wrapped, recovery_wrapped or private_wrapped from a record.
 * @param stored_tag The Poly1305 tag seal_home made with wrapped, the record's field beside it.
 * @param record The account whose name the seal was bound to, read only; its whole name field, padding included, has
 *     to be as it was sealed.
 * @param what What it's for, as it was sealed.
 * @return The secret, which the caller wipes once it's done with it; null if the key's wrong or anything it's bound
 *     to differs.
 */
open_home #constant_time :: fn(key: ptr[crypto.Key256], wrapped: u8[32], stored_tag: u8[16], record: ptr[AccountRecord], what: string) -> crypto.Key256? {
    nonce : crypto.Nonce96
    associated :: associated_of(what, record)
    tag : crypto.Tag128
    for i in cast[usize](0)..<16 {
        tag[i] = stored_tag[i]
    }
    plain : crypto.SecretByte[32]
    if !crypto.chacha20_poly1305_open(key, &nonce, wrapped, associated, &tag, plain) {
        return null
    }
    home : crypto.Key256
    for i in cast[usize](0)..<32 {
        home[i] = cast[u8](plain[i])
    }
    return home
}

/**
 * Derive the key Argon2id gives a password with a record's parameters and salt.
 *
 * Argon2id's memory comes from context's allocator, and is zeroed before it's given back.
 *
 * @param password The password, read only.
 * @param record The record, whose parameters and salt are used.
 * @return The key, which the caller zeroes once it's used; null if the parameters need no memory or more than could
 *     be had, or Argon2id failed.
 */
password_key #constant_time :: fn(password: u8[], record: ptr[AccountRecord]) -> crypto.Key256? {
    parameters :: crypto.Argon2Parameters.{memory_kib = cast[u32](record.memory_kib), passes = cast[u32](record.passes),
        lanes = cast[u32](record.lanes)}
    count :: crypto.argon2_blocks_needed(parameters)
    if count == 0 {
        return null
    }
    blocks, error :: runtime.new_array(crypto.Argon2Block, count)
    if error != null {
        return null
    }
    defer runtime.free_array(blocks)
    defer zero_argon2(blocks)
    hash : crypto.SecretByte[32]
    if !crypto.argon2id(crypto.as_secret(password), record.salt, parameters, blocks, hash) {
        return null
    }
    key : crypto.Key256
    for i in cast[usize](0)..<32 {
        key[i] = cast[u8](hash[i])
    }
    return key
}

/**
 * Derive the key a recovery code gives, with a record's recovery salt: BLAKE3, since the code is random already.
 *
 * @param code The recovery code, read only.
 * @param record The record, whose recovery salt is used.
 * @return The key, which the caller zeroes once it's used; never null.
 */
recovery_key #constant_time :: fn(code: ptr[RecoveryCode], record: ptr[AccountRecord]) -> crypto.Key256? {
    hasher := crypto.blake3_start()
    crypto.blake3_update(&hasher, string_bytes("SlopOS account recovery"))
    crypto.blake3_update(&hasher, record.recovery_salt)
    secret : crypto.SecretByte[16]
    for i in cast[usize](0)..<16 {
        secret[i] = cast[crypto.SecretByte](code[i])
    }
    crypto.blake3_update_secret(&hasher, secret)
    hash : crypto.SecretByte[32]
    crypto.blake3_finish_secret(&hasher, hash)
    key : crypto.Key256
    for i in cast[usize](0)..<32 {
        key[i] = cast[u8](hash[i])
    }
    return key
}

/**
 * Wipe a key, every byte zeroed.
 *
 * @param key The key, all 32 bytes overwritten with zeros in place.
 */
zero_key #constant_time :: fn(key: ptr[mut crypto.Key256]) {
    for i in cast[usize](0)..<32 {
        key[i] = 0
    }
}

/**
 * Wipe Argon2id's memory, every block zeroed, before it's freed.
 *
 * @param blocks Argon2id's working memory, every block's 128 words overwritten with zeros in place; the caller frees
 *     it after.
 */
zero_argon2 #constant_time :: fn(blocks: mut crypto.Argon2Block[]) {
    for i in 0..<blocks.count {
        for j in cast[usize](0)..<128 {
            blocks[i][j] = 0
        }
    }
}

/**
 * Make a new random key, for a home volume's or a share's secret, or an X25519 secret key.
 *
 * @return The key, from std's random numbers, which the caller wipes once it's done with it; the bytes it was drawn
 *     into are zeroed.
 */
random_key #constant_time :: fn() -> crypto.Key256 {
    bytes : u8[32]
    random.fill(bytes)
    key : crypto.Key256
    for i in cast[usize](0)..<32 {
        key[i] = bytes[i]
        bytes[i] = 0
    }
    return key
}

/**
 * Make a new recovery code: 125 random bits, its top 3 bits 0.
 *
 * @return The code, which the caller shows once (recovery_text) and wipes; the bytes it was drawn into are zeroed.
 */
new_recovery_code #constant_time :: fn() -> RecoveryCode {
    bytes : u8[16]
    random.fill(bytes)
    bytes[0] = bytes[0] & 0x1f
    code : RecoveryCode
    for i in cast[usize](0)..<16 {
        code[i] = bytes[i]
        bytes[i] = 0
    }
    return code
}

/**
 * Write a recovery code as it's shown, once, for its owner to write down: XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.
 *
 * @param code The code; its top 3 bits are skipped.
 * @return The text, 25 Crockford base32 symbols, uppercase, in five groups of five with hyphens: declassified, as
 *     showing it to its owner is what it's for, so the caller wipes it once it's shown.
 */
recovery_text #constant_time :: fn(code: ptr[RecoveryCode]) -> u8[RECOVERY_TEXT_BYTES] {
    // Shown to its owner, which is what it's for
    shown :: compiler.declassify(code^)
    text : u8[RECOVERY_TEXT_BYTES]
    at : usize = 0
    for symbol in cast[usize](0)..<RECOVERY_SYMBOLS {
        if symbol > 0 && symbol % 5 == 0 && at < text.count {
            text[at] = cast[u8]('-')
            at += 1
        }
        // The symbol's 5 bits, from the top of the 125
        value : u8 = 0
        for bit in cast[usize](0)..<5 {
            index :: 3 + symbol * 5 + bit
            byte :: index / 8
            if byte < 16 {
                value = (value << 1) | ((shown[byte] >> cast[u8](7 - index % 8)) & 1)
            }
        }
        if at < text.count {
            text[at] = cast[u8](CROCKFORD[cast[usize](value & 0x1f)])
            at += 1
        }
    }
    return text
}

/**
 * Read a recovery code as its owner types it: 25 symbols, any case, hyphens and spaces ignored, I and L read as 1, O
 * as 0.
 *
 * @param text What was typed.
 * @return The code, which the caller wipes once it's used; null for any other character, U among them, or more or
 *     fewer than 25 symbols.
 */
parse_recovery :: fn(text: u8[]) -> RecoveryCode? {
    code : RecoveryCode
    symbols : usize = 0
    for byte in text {
        if byte == cast[u8]('-') || byte == cast[u8](' ') {
            continue
        }
        value :: symbol_value(byte) or_return null
        if symbols >= RECOVERY_SYMBOLS {
            return null
        }
        for bit in cast[usize](0)..<5 {
            index :: 3 + symbols * 5 + bit
            byte_at :: index / 8
            if byte_at < 16 && ((value >> cast[u8](4 - bit)) & 1) != 0 {
                code[byte_at] = code[byte_at] | (cast[u8](0x80) >> cast[u8](index % 8))
            }
        }
        symbols += 1
    }
    if symbols != RECOVERY_SYMBOLS {
        return null
    }
    return code
}

/**
 * Find the value of a Crockford base32 symbol.
 *
 * @param byte The symbol, in any case; I and L are read as 1, and O as 0.
 * @return Its value, 0 to 31; null for a byte that isn't a symbol.
 */
symbol_value :: fn(byte: u8) -> u8? {
    upper :: if byte >= cast[u8]('a') && byte <= cast[u8]('z') { byte - 32 } else { byte }
    if upper == cast[u8]('O') {
        return 0
    }
    if upper == cast[u8]('I') || upper == cast[u8]('L') {
        return 1
    }
    for symbol, i in CROCKFORD {
        if cast[u8](symbol) == upper {
            return cast[u8](i)
        }
    }
    return null
}
