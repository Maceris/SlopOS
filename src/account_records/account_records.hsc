/*
 * Accounts (decisions/0141, roadmap 10b): the rules a name and a password are held to, and an account's record, which
 * keeps its home volume's secret wrapped twice: by a key Argon2id derives from the password, and by one derived from
 * the recovery code. A wrong password is found by its wrap not opening, so nothing else of it is kept.
 *
 * Passwords follow NIST SP 800-63B: at least 8 characters, counted as code points, up to 256 bytes, no composition
 * rules; refused if they're among the most common (common_passwords.hsc, compared lowercased) or are the account's
 * name. The recovery code is 125 random bits, shown as 25 Crockford base32 characters in five groups of five.
 *
 * Shared volumes (decisions/0158): each account has an X25519 key pair, its secret key sealed by the home volume's
 * secret, so whatever opens the home (the password, the recovery code) opens it too. A shared volume's secret is sealed
 * to each member's public key (seal_share): an ephemeral key's agreement with theirs, through BLAKE3, seals it, and only
 * their secret key opens it, so a member needn't be logged in to be added. A share's record names the volume, its owner,
 * and each member with the secret sealed to them, the owner first.
 */
package account_records

import compiler from "base"
import runtime from "base"
import crypto from "std"
import random from "std"
import unicode from "std"

MIN_PASSWORD_CHARACTERS : usize : 8
MAX_PASSWORD_BYTES : usize : 256
MAX_NAME_BYTES : usize : 32

// Argon2id's parameters for a password: RFC 9106's second recommendation, 64 MiB, 3 passes, 4 lanes.
PASSWORD_ARGON2 :: crypto.Argon2Parameters.{memory_kib = 65536, passes = 3, lanes = 4}

// Why a password is refused.
PasswordProblem :: enum #backed_by(u8) {
    TooShort = 1,
    TooLong = 2,
    // Among the most common passwords
    Common = 3,
    // The account's name, ignoring ASCII case
    IsName = 4,
}

ADMINISTRATOR : u32 : 1
RECORD_VERSION : u32 : 2
// A record from before key pairs: the same, without its last 80 bytes, which its next login adds
RECORD_V1_BYTES :: 192

/*
 * An account, as the account service keeps it: its name, whether it's the administrator, and its home volume's secret
 * sealed by a key from the password (Argon2id's parameters and salt beside it) and by one from the recovery code.
 */
AccountRecord :: struct #packed {
    version : u32le,
    flags : u32le,
    name_bytes : u32le,
    name : u8[MAX_NAME_BYTES],
    created : u64le,
    memory_kib : u32le,
    passes : u32le,
    lanes : u32le,
    salt : u8[16],
    home_wrapped : u8[32],
    home_tag : u8[16],
    recovery_salt : u8[16],
    recovery_wrapped : u8[32],
    recovery_tag : u8[16],
    // Its X25519 public key, all zeros before it has one, and its secret key sealed by the home volume's secret
    public_key : u8[32],
    private_wrapped : u8[32],
    private_tag : u8[16],
}

#assert size_of(AccountRecord) == 272

// A share's secret, sealed to a member: the ephemeral public key it was agreed with, and the secret, sealed.
SealedShare :: struct #packed {
    ephemeral : u8[32],
    wrapped : u8[32],
    tag : u8[16],
}

MAX_MEMBERS :: 8
SHARE_VERSION : u32 : 1

ShareMember :: struct #packed {
    name_bytes : u32le,
    name : u8[MAX_NAME_BYTES],
    sealed : SealedShare,
}

// A shared volume: its name, its owner's, and its members, the owner first, each with the volume's secret sealed to them.
ShareRecord :: struct #packed {
    version : u32le,
    name_bytes : u32le,
    name : u8[MAX_NAME_BYTES],
    member_count : u32le,
    members : ShareMember[MAX_MEMBERS],
}

// The recovery code: 125 random bits, its top 3 bits 0.
RecoveryCode :: distinct alias u8[16] #secret

RECOVERY_SYMBOLS : usize : 25
// Five groups of five, with a hyphen between each
RECOVERY_TEXT_BYTES : usize : 29
CROCKFORD :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// Whether a name is one an account may have: 1 to 32 bytes, a lowercase ASCII letter, then letters, digits, - or _.
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

// What's wrong with a password for the account named name, if anything.
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

ascii_lower :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
}

// Whether a lowercased password is among the most common, by binary search.
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

// a's order against b's, bytewise: below 0, 0 or above.
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

/*
 * A new account's record: home, its home volume's secret, sealed by a key from password with parameters and a new
 * salt, and by one from code. None if Argon2id couldn't have its memory.
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

// Whether a record has its key pair yet: one made before shared volumes gets it at its next login.
has_keys :: fn(record: ptr[AccountRecord]) -> bool {
    for byte in record.public_key {
        if byte != 0 {
            return true
        }
    }
    return false
}

// A new X25519 key pair for record, its secret key sealed by home, the home volume's secret.
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

// record's X25519 secret key, unsealed with home, the home volume's secret; None if it has none.
secret_key #constant_time :: fn(record: ptr[AccountRecord], home: ptr[crypto.Key256]) -> crypto.X25519SecretKey? {
    opened := open_home(home, record.private_wrapped, record.private_tag, record, "key pair") or_return null
    defer zero_key(&opened)
    key : crypto.X25519SecretKey
    for i in cast[usize](0)..<32 {
        key[i] = opened[i]
    }
    return key
}

// secret, a shared volume's, sealed to public, a member's X25519 public key, for the share named share; None if their key's no good.
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

// A shared volume's secret, unsealed with a member's secret key and their public key; None if it isn't theirs.
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

// The key an agreement gives, bound to both public keys: BLAKE3, as the agreement's already uniform.
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

// What a share's seal is bound to: that it's a share's, and the share's name.
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

// The name a share's record has, and a member's.
share_name :: fn(record: ptr[ShareRecord]) -> u8[] {
    count :: cast[usize](cast[u32](record.name_bytes))
    return if count <= record.name.count { record.name[0..<count] } else { record.name[0..<0] }
}

member_name :: fn(member: ptr[ShareMember]) -> u8[] {
    count :: cast[usize](cast[u32](member.name_bytes))
    return if count <= member.name.count { member.name[0..<count] } else { member.name[0..<0] }
}

// record's password changed: home sealed again by a key from password, with parameters and a new salt.
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

// The home volume's secret, unsealed with the password: None if it's the wrong one, or Argon2id couldn't have its memory.
unlock_home #constant_time :: fn(record: ptr[AccountRecord], password: u8[]) -> crypto.Key256? {
    key := password_key(password, record) or_return null
    defer zero_key(&key)
    return open_home(&key, record.home_wrapped, record.home_tag, record, "password")
}

// The home volume's secret, unsealed with the recovery code: None if it's the wrong one.
recover_home #constant_time :: fn(record: ptr[AccountRecord], code: ptr[RecoveryCode]) -> crypto.Key256? {
    key := recovery_key(code, record) or_return null
    defer zero_key(&key)
    return open_home(&key, record.recovery_wrapped, record.recovery_tag, record, "recovery")
}

// The name a record has.
name_of :: fn(record: ptr[AccountRecord]) -> u8[] {
    count :: cast[usize](cast[u32](record.name_bytes))
    return if count <= record.name.count { record.name[0..<count] } else { record.name[0..<0] }
}

is_administrator :: fn(record: ptr[AccountRecord]) -> bool {
    return (cast[u32](record.flags) & ADMINISTRATOR) != 0
}

Sealed :: struct {
    wrapped : u8[32],
    tag : u8[16],
}

// What a wrap is bound to: what it's for and the account's name.
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

// home sealed by key, a key used once, since each is new with its salt.
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

/*
 * The key Argon2id derives from a password with a record's parameters and salt: None if it couldn't have its memory,
 * which is zeroed before it's given back.
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

// The key a recovery code gives, with a record's recovery salt: BLAKE3, since the code is random already.
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

zero_key #constant_time :: fn(key: ptr[mut crypto.Key256]) {
    for i in cast[usize](0)..<32 {
        key[i] = 0
    }
}

zero_argon2 #constant_time :: fn(blocks: mut crypto.Argon2Block[]) {
    for i in 0..<blocks.count {
        for j in cast[usize](0)..<128 {
            blocks[i][j] = 0
        }
    }
}

// A new random key, for a home volume's secret.
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

// A new recovery code.
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

// A recovery code as it's shown, once, for its owner to write down: XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.
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

// A recovery code as its owner types it: 25 symbols, any case, hyphens and spaces ignored, I and L read as 1, O as 0.
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
