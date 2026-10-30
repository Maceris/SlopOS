package slopfs

import compiler from "base"
import runtime from "base"
import crypto from "std"
import random from "std"

/*
 * Encryption (roadmap 8e, design/storage.md §5, decisions/0042): an encrypted volume's every block, its tree's nodes
 * and its files' chunks, sealed with an AEAD. The volume has a random volume key, kept only wrapped: by a passphrase
 * through Argon2id now, by accounts' credentials from M10. Each key generation has a random key of its own, wrapped by
 * the volume key; new blocks are sealed with the newest, and a block's pointer names the one it was sealed with, so
 * starting a generation re-encrypts nothing (decisions/0042).
 *
 * A block's key is derived from its generation's key, the transaction it was written in and a salt chosen at random
 * for that transaction; its nonce counts the blocks the transaction has sealed. A crash that reuses a transaction's
 * number reuses no nonce, since the salt is new. Its address, transaction and owner are its associated data, so a
 * block read from another place, time or volume doesn't open. The seal in its pointer holds the tag, the salt and
 * the count: the format's 32 bytes, as a BLAKE3 seal's are.
 */

Cipher :: enum #backed_by(u8) {
    // Sealed with BLAKE3 alone, as the system volume is
    None = 0,
    ChaCha20Poly1305 = 1,
    // Fast where the CPU has AES instructions, and readable anywhere (decisions/0019)
    Aes256Gcm = 2,
}

// One key generation's key.
GenerationKey :: struct {
    number : u32,
    key : crypto.Key256,
}

/*
 * An unlocked volume's keys: its cipher, its volume key (for wrapping new generations), every generation's key, the
 * newest's number, and the transaction sealing now, with its salt, how many blocks it has sealed and its key.
 */
Keys :: struct {
    cipher : Cipher,
    volume_key : crypto.Key256,
    generations : GenerationKey[..],
    current : u32,
    transaction : u64,
    salt : u8[8],
    sealed : u32,
    block_key : crypto.Key256,
}

// What the volume key is wrapped by.
WrapKind :: enum #backed_by(u32) {
    Passphrase = 1,
}

/*
 * The volume key wrapped, keyed (volume, KeyWrap, index) in the container's volumes tree: for a passphrase, Argon2id's
 * parameters and salt, and the key sealed with what it derives.
 */
WrapRecord :: struct #packed {
    kind : u32le,
    memory_kib : u32le,
    passes : u32le,
    lanes : u32le,
    salt : u8[16],
    wrapped : u8[32],
    tag : u8[16],
}

#assert size_of(WrapRecord) == 80

// A generation's key wrapped by the volume key, keyed (volume, KeyGeneration, number): the transaction it began in.
GenerationRecord :: struct #packed {
    began : u64le,
    wrapped : u8[32],
    tag : u8[16],
}

#assert size_of(GenerationRecord) == 56

// A block's seal on an encrypted volume: its tag, its transaction's salt and its count in the transaction.
SEAL_SALT : usize : 16
SEAL_COUNT : usize : 24

// Argon2id's parameters for a passphrase, unless they're given (RFC 9106's second choice, with less memory).
DEFAULT_PASSPHRASE :: crypto.Argon2Parameters.{memory_kib = 65536, passes = 3, lanes = 1}

new_keys :: fn(cipher: Cipher) -> Result[ptr[mut Keys], Error] {
    keys :: make(Keys)?
    keys^ = Keys.{cipher = cipher}
    return .Ok(keys)
}

zero_key #constant_time :: fn(key: ptr[mut crypto.Key256]) {
    for i in cast[usize](0)..<32 {
        key[i] = 0
    }
}

// Keys' memory given back, the keys in it zeroed first.
free_keys :: fn(keys: ptr[mut Keys]) {
    zero_key(&keys.volume_key)
    zero_key(&keys.block_key)
    for i in 0..<keys.generations.count {
        if i < keys.generations.count {
            zero_key(&keys.generations[i].key)
        }
    }
    runtime.array_free(&keys.generations)
    runtime.free(keys)
}

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

generation_key :: fn(keys: ptr[Keys], number: u32) -> ptr[crypto.Key256]? {
    for i in 0..<keys.generations.count {
        if i < keys.generations.count && keys.generations[i].number == number {
            return &keys.generations[i].key
        }
    }
    return null
}

put_u64 :: fn(into: mut u8[], at: usize, value: u64) {
    for i in cast[usize](0)..<8 {
        j :: at + i
        if j < into.count {
            into[j] = cast[u8](value >> (8 * cast[u64](i)))
        }
    }
}

put_u32 :: fn(into: mut u8[], at: usize, value: u32) {
    for i in cast[usize](0)..<4 {
        j :: at + i
        if j < into.count {
            into[j] = cast[u8](value >> (8 * cast[u32](i)))
        }
    }
}

get_u32 :: fn(from: u8[], at: usize) -> u32 {
    value : u32 = 0
    for i in cast[usize](0)..<4 {
        j :: at + i
        if j < from.count {
            value = value | (cast[u32](from[j]) << (8 * cast[u32](i)))
        }
    }
    return value
}

BLOCK_KEY_CONTEXT :: "slopfs block key"

// The key a transaction's blocks are sealed with: its generation's key, keyed BLAKE3 of the transaction and salt.
derive_block_key #constant_time :: fn(generation: ptr[crypto.Key256], transaction: u64, salt: u8[]) -> crypto.Key256 {
    key_bytes : crypto.SecretByte[32]
    for i in cast[usize](0)..<32 {
        key_bytes[i] = cast[crypto.SecretByte](generation[i])
    }
    derived : crypto.Key256
    // A key of 32 bytes always starts one
    match crypto.blake3_start_keyed(key_bytes) {
        case Some(started) => {
            hasher := started
            crypto.blake3_update_secret(&hasher, crypto.as_secret(string_bytes(BLOCK_KEY_CONTEXT)))
            transaction_bytes : u8[8]
            put_u64(transaction_bytes, 0, transaction)
            crypto.blake3_update_secret(&hasher, crypto.as_secret(transaction_bytes))
            crypto.blake3_update_secret(&hasher, crypto.as_secret(salt))
            output : crypto.SecretByte[32]
            crypto.blake3_finish_secret(&hasher, output)
            for i in cast[usize](0)..<32 {
                derived[i] = cast[u8](output[i])
            }
        }
        case None => {}
    }
    return derived
}

// A block's associated data: where it is, when it was written and whose it is.
associated_of :: fn(pointer: ptr[BlockPointer], owner: u64) -> u8[24] {
    associated : u8[24]
    put_u64(associated, 0, cast[u64](pointer.address))
    put_u64(associated, 8, cast[u64](pointer.birth))
    put_u64(associated, 16, owner)
    return associated
}

nonce_of :: fn(count: u32) -> crypto.Nonce96 {
    nonce : crypto.Nonce96
    nonce[0] = cast[u8](count)
    nonce[1] = cast[u8](count >> 8)
    nonce[2] = cast[u8](count >> 16)
    nonce[3] = cast[u8](count >> 24)
    return nonce
}

aead_seal #constant_time :: fn(cipher: Cipher, key: ptr[crypto.Key256], nonce: ptr[crypto.Nonce96], plain: crypto.SecretByte[],
    associated: u8[], sealed: mut u8[], tag: ptr[mut crypto.Tag128]) -> bool {

    if cipher == .Aes256Gcm {
        return crypto.aes256_gcm_seal(key, nonce, plain, associated, sealed, tag)
    }
    return crypto.chacha20_poly1305_seal(key, nonce, plain, associated, sealed, tag)
}

aead_open #constant_time :: fn(cipher: Cipher, key: ptr[crypto.Key256], nonce: ptr[crypto.Nonce96], sealed: u8[], associated: u8[],
    tag: ptr[crypto.Tag128], plain: mut crypto.SecretByte[]) -> bool {

    if cipher == .Aes256Gcm {
        return crypto.aes256_gcm_open(key, nonce, sealed, associated, tag, plain)
    }
    return crypto.chacha20_poly1305_open(key, nonce, sealed, associated, tag, plain)
}

/*
 * plain sealed into sealed, of the same count, for the block pointer names, which owner's tree holds: its generation
 * and seal set. pointer's address and birth are where and when it's written.
 */
seal_block #constant_time :: fn(keys: ptr[mut Keys], owner: u64, pointer: ptr[mut BlockPointer], plain: u8[], sealed: mut u8[]) -> bool {
    birth :: cast[u64](pointer.birth)
    generation :: generation_key(keys, keys.current) or_return false
    if keys.transaction != birth || keys.sealed == 0xffffffff {
        keys.transaction = birth
        random.fill(keys.salt)
        keys.sealed = 0
        keys.block_key = derive_block_key(generation, birth, keys.salt)
    }
    count :: keys.sealed
    keys.sealed += 1
    pointer.generation = cast[u32le](keys.current)
    nonce :: nonce_of(count)
    associated :: associated_of(pointer, owner)
    tag : crypto.Tag128
    // A volume's bytes are its clients', public to the volume server that holds them
    if !aead_seal(keys.cipher, &keys.block_key, &nonce, crypto.as_secret(plain), associated, sealed, &tag) {
        return false
    }
    seal : Seal
    for i in cast[usize](0)..<16 {
        seal[i] = tag[i]
    }
    for i in cast[usize](0)..<8 {
        seal[SEAL_SALT + i] = keys.salt[i]
    }
    put_u32(seal, SEAL_COUNT, count)
    pointer.seal = seal
    return true
}

// sealed opened into plain, of the same count, if pointer's seal holds for it, where it says and whose it is.
open_block #constant_time :: fn(keys: ptr[Keys], owner: u64, pointer: ptr[BlockPointer], sealed: u8[], plain: mut u8[]) -> bool {
    generation :: generation_key(keys, cast[u32](pointer.generation)) or_return false
    seal :: pointer.seal
    key := derive_block_key(generation, cast[u64](pointer.birth), seal[SEAL_SALT..<SEAL_SALT + 8])
    defer zero_key(&key)
    nonce :: nonce_of(get_u32(seal, SEAL_COUNT))
    associated :: associated_of(pointer, owner)
    tag : crypto.Tag128
    for i in cast[usize](0)..<16 {
        tag[i] = seal[i]
    }
    // Opened in place: what's opened is the volume's, which its server hands its clients
    opened :: view_of(cast[ptr[mut crypto.SecretByte]](plain.data), plain.count)
    return aead_open(keys.cipher, &key, &nonce, sealed, associated, &tag, opened)
}

// Wrapping: the volume key's and each generation's associated data, naming the container and volume they're for.
wrap_associated :: fn(what: string, container: u8[16], volume: u64) -> u8[48] {
    associated : u8[48]
    for character, i in what {
        if i < 24 {
            associated[i] = cast[u8](character)
        }
    }
    for i in cast[usize](0)..<16 {
        associated[24 + i] = container[i]
    }
    put_u64(associated, 40, volume)
    return associated
}

/*
 * The key Argon2id derives from a passphrase with a wrap record's parameters and salt: None if it couldn't. Its
 * memory, which held what the passphrase made, is zeroed before it's given back.
 */
passphrase_key #constant_time :: fn(passphrase: u8[], record: ptr[WrapRecord]) -> crypto.Key256? {
    parameters :: crypto.Argon2Parameters.{memory_kib = cast[u32](record.memory_kib), passes = cast[u32](record.passes),
        lanes = cast[u32](record.lanes)}
    count :: crypto.argon2_blocks_needed(parameters)
    memory, error :: runtime.new_array_aligned(u8, count * size_of(crypto.Argon2Block), align_of(crypto.Argon2Block))
    if error != null {
        return null
    }
    defer runtime.free_array_aligned(memory, align_of(crypto.Argon2Block))
    blocks :: view_of(cast[ptr[mut crypto.Argon2Block]](memory.data), count)
    defer zero_argon2(blocks)
    hash : crypto.SecretByte[32]
    if !crypto.argon2id(crypto.as_secret(passphrase), record.salt, parameters, blocks, hash) {
        return null
    }
    key : crypto.Key256
    for i in cast[usize](0)..<32 {
        key[i] = cast[u8](hash[i])
    }
    return key
}

zero_argon2 #constant_time :: fn(blocks: mut crypto.Argon2Block[]) {
    for i in 0..<blocks.count {
        for j in cast[usize](0)..<128 {
            blocks[i][j] = 0
        }
    }
}

// The volume key wrapped by a passphrase, with Argon2id's parameters and a new salt.
wrap_with_passphrase #constant_time :: fn(volume_key: ptr[crypto.Key256], passphrase: u8[], parameters: crypto.Argon2Parameters,
    container: u8[16], volume: u64) -> WrapRecord? {

    record := WrapRecord.{kind = cast[u32le](cast[u32](WrapKind.Passphrase)), memory_kib = cast[u32le](parameters.memory_kib),
        passes = cast[u32le](parameters.passes), lanes = cast[u32le](parameters.lanes)}
    random.fill(record.salt)
    wrapping := passphrase_key(passphrase, &record) or_return null
    defer zero_key(&wrapping)
    // The wrapping key is new with each salt, so one nonce is enough
    nonce :: nonce_of(0)
    associated :: wrap_associated("slopfs volume key", container, volume)
    plain : crypto.SecretByte[32]
    for i in cast[usize](0)..<32 {
        plain[i] = cast[crypto.SecretByte](volume_key[i])
    }
    tag : crypto.Tag128
    if !crypto.chacha20_poly1305_seal(&wrapping, &nonce, plain, associated, record.wrapped, &tag) {
        return null
    }
    for i in cast[usize](0)..<16 {
        record.tag[i] = tag[i]
    }
    // What's wrapped is sealed, public by design
    return compiler.declassify(record)
}

// The volume key a passphrase unwraps from record: None if it's the wrong passphrase.
unwrap_with_passphrase #constant_time :: fn(record: ptr[WrapRecord], passphrase: u8[], container: u8[16], volume: u64) -> crypto.Key256? {
    if cast[u32](record.kind) != cast[u32](WrapKind.Passphrase) {
        return null
    }
    wrapping := passphrase_key(passphrase, record) or_return null
    defer zero_key(&wrapping)
    nonce :: nonce_of(0)
    associated :: wrap_associated("slopfs volume key", container, volume)
    tag : crypto.Tag128
    for i in cast[usize](0)..<16 {
        tag[i] = record.tag[i]
    }
    plain : crypto.SecretByte[32]
    if !crypto.chacha20_poly1305_open(&wrapping, &nonce, record.wrapped, associated, &tag, plain) {
        return null
    }
    key : crypto.Key256
    for i in cast[usize](0)..<32 {
        key[i] = cast[u8](plain[i])
    }
    return key
}

// A generation's key wrapped by the volume key, its number the nonce, since each is wrapped once.
wrap_generation #constant_time :: fn(volume_key: ptr[crypto.Key256], generation: ptr[GenerationKey], began: u64, container: u8[16],
    volume: u64) -> GenerationRecord? {

    record := GenerationRecord.{began = cast[u64le](began)}
    nonce :: nonce_of(generation.number)
    associated :: wrap_associated("slopfs generation", container, volume)
    plain : crypto.SecretByte[32]
    for i in cast[usize](0)..<32 {
        plain[i] = cast[crypto.SecretByte](generation.key[i])
    }
    tag : crypto.Tag128
    if !crypto.chacha20_poly1305_seal(volume_key, &nonce, plain, associated, record.wrapped, &tag) {
        return null
    }
    for i in cast[usize](0)..<16 {
        record.tag[i] = tag[i]
    }
    return compiler.declassify(record)
}

// A generation's key unwrapped by the volume key: None if it doesn't open.
unwrap_generation #constant_time :: fn(volume_key: ptr[crypto.Key256], number: u32, record: ptr[GenerationRecord], container: u8[16],
    volume: u64) -> GenerationKey? {

    nonce :: nonce_of(number)
    associated :: wrap_associated("slopfs generation", container, volume)
    tag : crypto.Tag128
    for i in cast[usize](0)..<16 {
        tag[i] = record.tag[i]
    }
    plain : crypto.SecretByte[32]
    if !crypto.chacha20_poly1305_open(volume_key, &nonce, record.wrapped, associated, &tag, plain) {
        return null
    }
    generation := GenerationKey.{number = number}
    for i in cast[usize](0)..<32 {
        generation.key[i] = cast[u8](plain[i])
    }
    return generation
}

/*
 * A new generation for keys, numbered after its newest, which seals what's written from now on: its key, and the
 * record of it wrapped, to keep where the volume's keys are kept.
 */
start_generation #constant_time :: fn(keys: ptr[mut Keys], began: u64, container: u8[16], volume: u64) -> GenerationRecord? {
    generation := GenerationKey.{number = keys.current + 1, key = random_key()}
    record :: wrap_generation(&keys.volume_key, &generation, began, container, volume) or_return null
    if runtime.array_try_add(&keys.generations, generation) != null {
        zero_key(&generation.key)
        return null
    }
    keys.current = generation.number
    // The next block sealed derives its transaction's key from the new generation
    keys.transaction = 0
    return record
}

// The newest generation forgotten, previous sealing again: one start_generation made that couldn't be kept.
drop_generation :: fn(keys: ptr[mut Keys], previous: u32) {
    last :: keys.generations.count
    if last > 0 && last - 1 < keys.generations.count && keys.generations[last - 1].number == keys.current {
        zero_key(&keys.generations[last - 1].key)
        runtime.array_remove(&keys.generations, last - 1)
    }
    keys.current = previous
    keys.transaction = 0
}
