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

/** The AEAD a volume's blocks are sealed with, as its record's cipher byte holds it. */
Cipher :: enum #backed_by(u8) {
    /** Sealed with BLAKE3 alone, as the system volume is: checked, not encrypted. */
    None = 0,
    /** ChaCha20-Poly1305, fast anywhere without AES instructions. */
    ChaCha20Poly1305 = 1,
    /** AES-256-GCM, fast where the CPU has AES instructions, and readable anywhere (decisions/0019). */
    Aes256Gcm = 2,
}

/** One key generation's key. */
GenerationKey :: struct {
    /** The generation's number, from 1. */
    number : u32,
    /** Its key, secret: zeroed when it's let go of. */
    key : crypto.Key256,
}

/**
 * An unlocked volume's keys: its cipher, its volume key (for wrapping new generations), every generation's key, the
 * newest's number, and the transaction sealing now, with its salt, how many blocks it has sealed and its key.
 *
 * It's from new_keys, freed, its keys zeroed, by free_keys or by the volume it's given to.
 */
Keys :: struct {
    /** The AEAD blocks are sealed with. */
    cipher : Cipher,
    /** The volume key, which wraps each generation's key; secret. */
    volume_key : crypto.Key256,
    /** Every generation's key unwrapped, from context's allocator. */
    generations : GenerationKey[..],
    /** The newest generation's number, which new blocks are sealed with; 0 before there's one. */
    current : u32,
    /** The transaction the block key is derived for; 0 when it has to be derived again before the next seal. */
    transaction : u64,
    /** The random salt chosen for the transaction sealing now. */
    salt : u8[8],
    /** How many blocks have been sealed with the block key, the next one's nonce. */
    sealed : u32,
    /** The block key derived from the current generation's key, the transaction and the salt; secret. */
    block_key : crypto.Key256,
}

/** What the volume key is wrapped by. */
WrapKind :: enum #backed_by(u32) {
    /** A passphrase, through Argon2id. */
    Passphrase = 1,
}

/**
 * The volume key wrapped, keyed (volume, KeyWrap, index) in the container's volumes tree: for a passphrase, Argon2id's
 * parameters and salt, and the key sealed with what it derives. Little-endian.
 */
WrapRecord :: struct #packed {
    /** Its WrapKind. */
    kind : u32le,
    /** Argon2id's memory, in KiB. */
    memory_kib : u32le,
    /** Argon2id's passes over its memory. */
    passes : u32le,
    /** Argon2id's lanes. */
    lanes : u32le,
    /** Argon2id's salt, random, new with each wrap. */
    salt : u8[16],
    /** The volume key, sealed with ChaCha20-Poly1305 under the key Argon2id derives, nonce 0. */
    wrapped : u8[32],
    /** The seal's tag. */
    tag : u8[16],
}

#assert size_of(WrapRecord) == 80

/** A generation's key wrapped by the volume key, keyed (volume, KeyGeneration, number). */
GenerationRecord :: struct #packed {
    /** The transaction the generation began in. */
    began : u64le,
    /** The generation's key, sealed with ChaCha20-Poly1305 under the volume key, the generation's number its nonce. */
    wrapped : u8[32],
    /** The seal's tag. */
    tag : u8[16],
}

#assert size_of(GenerationRecord) == 56

/*
 * A block's seal on an encrypted volume: its tag in bytes 0 to 15, its transaction's salt in 16 to 23 and its count
 * in the transaction, little-endian, in 24 to 27.
 */
/** Where a block's seal holds its transaction's salt, 8 bytes. */
SEAL_SALT : usize : 16
/** Where a block's seal holds its count in its transaction, a little-endian u32, its nonce. */
SEAL_COUNT : usize : 24

/** Argon2id's parameters for a passphrase, unless they're given (RFC 9106's second choice, with less memory). */
DEFAULT_PASSPHRASE :: crypto.Argon2Parameters.{memory_kib = 65536, passes = 3, lanes = 1}
/**
 * Argon2id's parameters for a volume made at run time (decisions/0141), wrapped by its volume server inside the 8 MiB
 * its budget has for Argon2id: its passphrase is a random secret the account service keeps, which hashes the password
 * it's kept by itself.
 */
MADE_PASSPHRASE :: crypto.Argon2Parameters.{memory_kib = 4096, passes = 3, lanes = 1}

/**
 * Make an empty set of keys for a cipher: no volume key, no generation.
 *
 * @param cipher The cipher the keys seal with; None for keys unlock fills in.
 * @return The keys, from make, the caller's to free with free_keys.
 * @error OutOfMemory No memory for them.
 */
new_keys :: fn(cipher: Cipher) -> Result[ptr[mut Keys], Error] {
    keys :: make(Keys)?
    keys^ = Keys.{cipher = cipher}
    return .Ok(keys)
}

/**
 * Zero a key, in constant time.
 *
 * @param key The key, all zero once this returns.
 */
zero_key #constant_time :: fn(key: ptr[mut crypto.Key256]) {
    for i in cast[usize](0)..<32 {
        key[i] = 0
    }
}

/**
 * Free keys' memory, the keys in it zeroed first.
 *
 * @param keys The keys, from new_keys; they may not be used again.
 */
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

/**
 * Make a random key, from the system's random source.
 *
 * @return The key; the bytes it was made in are zeroed.
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
 * Find a generation's key.
 *
 * @param keys The keys, unlocked or being filled in.
 * @param number Which generation, from 1, as a block pointer's generation or keys.current names it; any number may
 *     be asked for.
 * @return The key, inside keys, good until keys' generations change; null if it has no generation of the number.
 */
generation_key :: fn(keys: ptr[Keys], number: u32) -> ptr[crypto.Key256]? {
    for i in 0..<keys.generations.count {
        if i < keys.generations.count && keys.generations[i].number == number {
            return &keys.generations[i].key
        }
    }
    return null
}

/**
 * Put a little-endian u64 into a buffer, each byte only if it's within it.
 *
 * @param into The bytes written to, as associated data or a hash's input.
 * @param at Its first byte's offset.
 * @param value The value, any u64, written low byte first.
 */
put_u64 :: fn(into: mut u8[], at: usize, value: u64) {
    for i in cast[usize](0)..<8 {
        j :: at + i
        if j < into.count {
            into[j] = cast[u8](value >> (8 * cast[u64](i)))
        }
    }
}

/**
 * Put a little-endian u32 into a buffer, each byte only if it's within it.
 *
 * @param into The bytes written to, as a seal's count.
 * @param at Its first byte's offset.
 * @param value The value, any u32, written low byte first.
 */
put_u32 :: fn(into: mut u8[], at: usize, value: u32) {
    for i in cast[usize](0)..<4 {
        j :: at + i
        if j < into.count {
            into[j] = cast[u8](value >> (8 * cast[u32](i)))
        }
    }
}

/**
 * Get a little-endian u32 from a buffer.
 *
 * @param from The bytes read from, as a seal's count.
 * @param at Its first byte's offset.
 * @return The value, any byte past the buffer's end taken as 0.
 */
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

/** What a block key's BLAKE3 starts with, so it's derived for nothing else. */
BLOCK_KEY_CONTEXT :: "slopfs block key"

/**
 * Derive the key a transaction's blocks are sealed with: BLAKE3, keyed with the generation's key, of
 * BLOCK_KEY_CONTEXT, the transaction (little-endian) and the salt.
 *
 * @param generation The key of the generation sealing the blocks, secret, used as BLAKE3's key; not changed.
 * @param transaction The transaction the blocks are written in.
 * @param salt The transaction's salt, 8 random bytes.
 * @return The block key, secret; the caller zeroes it when done.
 */
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

/**
 * Make a block's associated data, so a block read from another place, time or volume doesn't open.
 *
 * @param pointer The block's pointer: its address and birth.
 * @param owner The volume whose tree holds it, who wrote it.
 * @return Its address, birth and owner, each a little-endian u64.
 */
associated_of :: fn(pointer: ptr[BlockPointer], owner: u64) -> u8[24] {
    associated : u8[24]
    put_u64(associated, 0, cast[u64](pointer.address))
    put_u64(associated, 8, cast[u64](pointer.birth))
    put_u64(associated, 16, owner)
    return associated
}

/**
 * Make a nonce from a count.
 *
 * @param count The count: a block's in its transaction, or a generation's number.
 * @return The count, little-endian, in the nonce's first 4 bytes, the rest zero.
 */
nonce_of :: fn(count: u32) -> crypto.Nonce96 {
    nonce : crypto.Nonce96
    nonce[0] = cast[u8](count)
    nonce[1] = cast[u8](count >> 8)
    nonce[2] = cast[u8](count >> 16)
    nonce[3] = cast[u8](count >> 24)
    return nonce
}

/**
 * Seal bytes with a cipher's AEAD.
 *
 * @param cipher The cipher: Aes256Gcm, or ChaCha20-Poly1305 for any other.
 * @param key The key, secret, 32 bytes.
 * @param nonce The nonce, never used twice with the key.
 * @param plain The bytes to seal.
 * @param associated The associated data, checked, not sealed.
 * @param sealed Where the sealed bytes go, as many as plain.
 * @param tag Where the tag goes.
 * @return True if it was sealed; false if the AEAD refused, as for buffers that don't match.
 */
aead_seal #constant_time :: fn(cipher: Cipher, key: ptr[crypto.Key256], nonce: ptr[crypto.Nonce96], plain: crypto.SecretByte[],
    associated: u8[], sealed: mut u8[], tag: ptr[mut crypto.Tag128]) -> bool {

    if cipher == .Aes256Gcm {
        return crypto.aes256_gcm_seal(key, nonce, plain, associated, sealed, tag)
    }
    return crypto.chacha20_poly1305_seal(key, nonce, plain, associated, sealed, tag)
}

/**
 * Open bytes sealed with a cipher's AEAD.
 *
 * @param cipher The cipher: Aes256Gcm, or ChaCha20-Poly1305 for any other.
 * @param key The key they were sealed with, secret.
 * @param nonce The nonce they were sealed with.
 * @param sealed The sealed bytes, as read from the device.
 * @param associated The associated data they were sealed with.
 * @param tag Their tag.
 * @param plain Where the opened bytes go, as many as sealed.
 * @return True if the tag holds and they were opened; false if it doesn't, what's in plain then not to be used.
 */
aead_open #constant_time :: fn(cipher: Cipher, key: ptr[crypto.Key256], nonce: ptr[crypto.Nonce96], sealed: u8[], associated: u8[],
    tag: ptr[crypto.Tag128], plain: mut crypto.SecretByte[]) -> bool {

    if cipher == .Aes256Gcm {
        return crypto.aes256_gcm_open(key, nonce, sealed, associated, tag, plain)
    }
    return crypto.chacha20_poly1305_open(key, nonce, sealed, associated, tag, plain)
}

/**
 * Seal a block's bytes for where and when its pointer says it's written, setting the pointer's generation and seal.
 *
 * The block key is derived again, with a new salt, for each new transaction, and after 2^32 - 1 blocks in one, so no
 * nonce is used twice even when a crash reuses a transaction's number.
 *
 * @param keys The volume's keys; their block key, salt and count advance.
 * @param owner The volume whose tree holds the block.
 * @param pointer The block's pointer, its address and birth set; its generation and seal are set here.
 * @param plain The bytes to seal, as they are in memory; any length the AEAD takes, as many as sealed has room for.
 * @param sealed Where the sealed bytes go, as many as plain.
 * @return True if it was sealed; false if the keys have no current generation or the AEAD refused.
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

/**
 * Open a block's sealed bytes, if its pointer's seal holds for them, where it says and whose it is.
 *
 * @param keys The volume's keys, only read: the cipher, and the key of the generation the pointer names.
 * @param owner The volume whose tree holds the block, who wrote it.
 * @param pointer The pointer the block was reached by: its generation, birth and seal (tag, salt and count) open it,
 *     and its address and birth are associated data.
 * @param sealed The block's bytes as read.
 * @param plain Where the opened bytes go, as many as sealed.
 * @return True if they were opened; false if the keys have no key for the pointer's generation, or the seal doesn't
 *     hold: the block is damaged, misplaced, or another volume's.
 */
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

/**
 * Make the associated data a wrapped key is sealed with, naming what it is and the container and volume it's for.
 *
 * @param what What's wrapped: "slopfs volume key" or "slopfs generation"; up to 24 bytes kept.
 * @param container The container's 16-byte ID, from its superblock, so a record copied to another container doesn't
 *     open.
 * @param volume The volume's ID, whose key records they are.
 * @return The data: what, zero-padded to 24 bytes, the container's ID and the volume's, little-endian.
 */
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

/**
 * Derive a key from a passphrase with Argon2id, with a wrap record's parameters and salt.
 *
 * Its memory, which held what the passphrase made, is zeroed before it's given back.
 *
 * @param passphrase The passphrase, secret.
 * @param record The wrap record, its parameters and salt.
 * @return The key, secret; the caller zeroes it when done. Null if Argon2id's memory couldn't be had, or it refused
 *     the parameters.
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

/**
 * Zero Argon2id's memory, in constant time.
 *
 * @param blocks Argon2id's working memory, each block's every word set to 0.
 */
zero_argon2 #constant_time :: fn(blocks: mut crypto.Argon2Block[]) {
    for i in 0..<blocks.count {
        for j in cast[usize](0)..<128 {
            blocks[i][j] = 0
        }
    }
}

/**
 * Wrap the volume key with a passphrase, with Argon2id's parameters and a new random salt.
 *
 * @param volume_key The volume key to wrap, secret; it isn't changed.
 * @param passphrase The passphrase, secret.
 * @param parameters Argon2id's parameters: DEFAULT_PASSPHRASE, MADE_PASSPHRASE or the caller's.
 * @param container The 16-byte ID of the container the record goes in, from its superblock; it's associated data.
 * @param volume The volume's ID, whose key records it goes in.
 * @return The wrap record, public; null if Argon2id couldn't run or the seal failed.
 */
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

/**
 * Unwrap the volume key from a wrap record with a passphrase.
 *
 * @param record The wrap record, as read from the volumes tree.
 * @param passphrase The passphrase, secret.
 * @param container The container's ID, as it was wrapped for.
 * @param volume The ID of the volume whose key records it's in, as it was wrapped for.
 * @return The volume key, secret; the caller zeroes it when done. Null if the record isn't a passphrase's, Argon2id
 *     couldn't run, or the passphrase is the wrong one.
 */
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

/**
 * Wrap a generation's key with the volume key, its number the nonce, since each is wrapped once.
 *
 * @param volume_key The volume key that wraps it, secret.
 * @param generation The generation, its number and key; the number is the nonce, so each is wrapped once.
 * @param began The transaction it begins in.
 * @param container The 16-byte ID of the container the record goes in, from its superblock; it's associated data.
 * @param volume The ID of the volume whose key records it goes in.
 * @return The generation's record, public; null if the seal failed.
 */
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

/**
 * Unwrap a generation's key with the volume key.
 *
 * @param volume_key The volume key it was wrapped with, secret.
 * @param number The generation's number, its record's key's offset.
 * @param record The generation's record, as read from the volumes tree: its wrapped key and tag; only read.
 * @param container The container's ID, as it was wrapped for.
 * @param volume The ID of the volume whose key records it's in, as it was wrapped for.
 * @return The generation's key, secret; null if it doesn't open, as with the wrong volume key or a damaged record.
 */
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

/**
 * Start a new generation, numbered after the newest, which seals what's written from now on.
 *
 * Nothing already written is sealed again (decisions/0042).
 *
 * @param keys The volume's keys, its volume key unwrapped; the new generation's key is added and made current.
 * @param began The transaction it begins in.
 * @param container The 16-byte ID of the container the record goes in, from its superblock; it's associated data.
 * @param volume The ID of the volume whose key records it goes in.
 * @return The generation's record, to keep where the volume's keys are kept; null, with keys unchanged, if it
 *     couldn't be wrapped or there wasn't the memory to keep it.
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

/**
 * Forget the newest generation, one start_generation made whose record couldn't be kept, so the one before seals
 * again.
 *
 * @param keys The volume's keys; the newest generation's key is zeroed and dropped.
 * @param previous The number of the generation current before it.
 */
drop_generation :: fn(keys: ptr[mut Keys], previous: u32) {
    last :: keys.generations.count
    if last > 0 && last - 1 < keys.generations.count && keys.generations[last - 1].number == keys.current {
        zero_key(&keys.generations[last - 1].key)
        runtime.array_remove(&keys.generations, last - 1)
    }
    keys.current = previous
    keys.transaction = 0
}
