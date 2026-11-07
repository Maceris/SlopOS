package slopfs

import runtime from "base"
import crypto from "std"

/*
 * A volume (design/storage.md §3): one tree of its objects, each directory's entries and each file's chunks, keyed
 * (object, kind, offset). A directory's entries are found by a hash of their names keyed per volume, so names chosen
 * in advance can't fill one bucket; those that hash alike share a record. Names are UTF-8 bytes without '/' or NUL,
 * compared exactly. There are no hard links, so each object has one parent, and no symbolic links; a stored link
 * (links.hsc) leads into another volume, and only a volume server follows it.
 *
 * A file's bytes are in chunks of 64 KiB, each an extent of up to 16 blocks written anew whenever it changes, the
 * first held in its record while the file is at most 2 KiB. Chunks that were never written read as zeros.
 */

/**
 * A volume open: the nodes its tree changes in and the device it's on, the container's own in this process or, in a
 * volume server, its own (decisions/0089), and what its record holds.
 *
 * It's from make, freed with free_volume (close_volume, or unmount, for one among the container's open volumes). Its
 * fields are this package's to keep, but now and history_bytes, which its user sets.
 */
Volume :: struct {
    /** The transaction's nodes its tree changes in, the container's or its volume server's, not the volume's. */
    nodes : ptr[mut Nodes],
    /** The device its file chunks are read from and written to. */
    device : Device,
    /** Its ID in the container. */
    id : u64,
    /** Its tree, with its keys if it's encrypted, which it owns. */
    tree : Tree,
    /** The ID its next object gets. */
    next_object : u64,
    /** The key its names are hashed with. */
    hash_key : u8[32],
    /** When it was made, as its maker said. */
    created : u64,
    /** Its name, UTF-8, its first name_bytes used. */
    name : u8[VOLUME_NAME_BYTES],
    /** How many bytes of name are used. */
    name_bytes : u16,
    /** Whether its tree or its record changed since the last commit. */
    dirty : bool,
    /** The time it is, as its user says, for the records it writes: objects' times and links issued. */
    now : u64,
    /** A data write failed, so its commits are refused, every one after it (decisions/0112). */
    failed : bool,
    /*
     * The chunks failed writes were for, each a file and the chunk's index, which reads are refused, since what's
     * there isn't what was written; past MAX_FAILED_CHUNKS, every chunk's.
     */
    /** The chunks failed writes were for, and not written whole since; the first failed_count are used. */
    failed_chunks : FailedChunk[MAX_FAILED_CHUNKS],
    /** How many of failed_chunks are used; past MAX_FAILED_CHUNKS, some weren't kept, so every chunk is refused. */
    failed_count : u32,
    /** The bytes of change history it keeps (history.hsc), or 0 for none. */
    history_bytes : u64,
    /** Its record as it was opened, for what the volume doesn't change: a clone's origin, whose keys it uses. */
    opened : VolumeRecord,
}

/** The most failed writes a volume remembers by their chunks; past it, every chunk read is refused. */
MAX_FAILED_CHUNKS :: 32

/** A file's chunk a failed write was for. */
FailedChunk :: struct {
    /** The file's object ID. */
    file : u64,
    /** The chunk's index, its byte offset / CHUNK_BYTES. */
    index : u64,
}

/**
 * Tell whether a failed write was for a file's chunk, so it can't be read (decisions/0112).
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The file's object ID.
 * @param index The chunk's index in the file, its byte offset / CHUNK_BYTES; matched exactly against those noted,
 *     not checked against the file's size.
 * @return True if a failed write was for it, not written since, or more than MAX_FAILED_CHUNKS failed writes were.
 */
chunk_failed :: fn(volume: ptr[Volume], file: u64, index: u64) -> bool {
    if volume.failed_count > MAX_FAILED_CHUNKS {
        return true
    }
    for each, i in volume.failed_chunks {
        if i < cast[usize](volume.failed_count) && each.file == file && each.index == index {
            return true
        }
    }
    return false
}

/**
 * Note that a write of a file's chunk failed, or succeeded, so it's whole again.
 *
 * @param volume The volume; once more than MAX_FAILED_CHUNKS have failed, nothing more is noted.
 * @param file The file's object ID.
 * @param index The chunk's index in the file, its byte offset / CHUNK_BYTES, noted or forgotten as given; not
 *     checked against the file's size.
 * @param failed True if the write failed, so the chunk is remembered; false if it succeeded, so it's forgotten.
 */
note_chunk :: fn(volume: ptr[mut Volume], file: u64, index: u64, failed: bool) {
    if volume.failed_count > MAX_FAILED_CHUNKS {
        return void
    }
    for i in cast[usize](0)..<volume.failed_chunks.count {
        if i < cast[usize](volume.failed_count) && volume.failed_chunks[i].file == file && volume.failed_chunks[i].index == index {
            if !failed {
                last :: cast[usize](volume.failed_count) - 1
                if last < volume.failed_chunks.count {
                    volume.failed_chunks[i] = volume.failed_chunks[last]
                }
                volume.failed_count -= 1
            }
            return void
        }
    }
    if !failed {
        return void
    }
    at :: cast[usize](volume.failed_count)
    if at < volume.failed_chunks.count {
        volume.failed_chunks[at] = FailedChunk.{file = file, index = index}
    }
    volume.failed_count += 1
}

/** What an object is, from its record. */
Info :: struct {
    /** Its object ID. */
    object : u64,
    /** What kind of object it is. */
    kind : ObjectKind,
    /** Its parent directory; the root's is itself. */
    parent : u64,
    /** A file's size in bytes; 0 for a directory or a link. */
    size : u64,
    /** When it was made, as the volume's user gave the time. */
    created : u64,
    /** When its contents last changed, as the volume's user gave the time. */
    modified : u64,
    /** The transaction it last changed in. */
    changed : u64,
    /** A typed file's schema hash, all zeros for bytes alone (decisions/0046, 0108). */
    schema : u8[32],
}

/** An entry list gives: its name's bytes in the caller's buffer, what it names, and the cursor after it. */
Listed :: struct {
    /** How many bytes the name has; as many as fit were copied into the caller's buffer. */
    name_bytes : usize,
    /** The object it names. */
    object : u64,
    /** The object's kind, as the entry says. */
    kind : ObjectKind,
    /** The cursor to list the next entry from. */
    next : u64,
}

/** A volume's ID, as a type of its own. */
VolumeId :: struct {
    /** The ID. */
    id : u64,
}

/**
 * Make a new volume, with its root directory, open in the container's own process.
 *
 * It's on the disk once it's committed. Its name isn't checked against the container's other volumes'.
 *
 * @param container The container, which has to outlive the volume, and which keeps it among its open ones.
 * @param name Its name, 1 to VOLUME_NAME_BYTES bytes.
 * @param hash_key The key its names hash with, random, so names can't be chosen to collide.
 * @param now When it's made, as its maker says: its time, and its root's.
 * @return The volume, the container's, freed by close_volume or unmount.
 * @error InvalidName The name is empty or too long.
 * @error OutOfMemory No memory for the volume or a node.
 * @error NoSpace No free extent for its root's node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
create_volume :: fn(container #escaping : ptr[mut Container], name: string, hash_key: u8[32], now: u64) -> Result[ptr[mut Volume], Error] {
    return create_keyed_volume(container, name, hash_key, now, null)
}

/**
 * Make a new encrypted volume, as create_volume makes one, its keys kept in the container's volumes tree.
 *
 * Its volume key is new and wrapped by a passphrase through Argon2id, and its first key generation's with it. The
 * key records are put before the volume is made, so a failure after them (as for a bad name) leaves them under the
 * ID the next volume gets.
 *
 * @param container The container, which has to outlive the volume, and which keeps it among its open ones.
 * @param name Its name, 1 to VOLUME_NAME_BYTES bytes.
 * @param hash_key The key its names hash with, random.
 * @param now When it's made, as its maker says.
 * @param cipher The cipher its blocks are sealed with; None makes a volume that isn't encrypted, as create_volume does.
 * @param passphrase The passphrase its volume key is wrapped by, secret.
 * @param parameters Argon2id's parameters: DEFAULT_PASSPHRASE, as a rule.
 * @return The volume, the container's, freed by close_volume or unmount.
 * @error InvalidName The name is empty or too long.
 * @error WrongKey The volume key couldn't be wrapped: Argon2id couldn't run with the parameters.
 * @error OutOfMemory No memory for the keys, the volume or a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt The first generation couldn't be made, or a node couldn't be read or didn't check out.
 */
create_sealed_volume :: fn(container #escaping : ptr[mut Container], name: string, hash_key: u8[32], now: u64, cipher: Cipher,
    passphrase: u8[], parameters: crypto.Argon2Parameters) -> Result[ptr[mut Volume], Error] {

    if cipher == .None {
        return create_volume(container, name, hash_key, now)
    }
    // The name checked before any key record is put under the next volume's ID, so a bad one leaves none behind
    if name.count == 0 || name.count > VOLUME_NAME_BYTES {
        return .Error(.InvalidName)
    }
    id :: container.next_volume
    keys :: new_keys(cipher)?
    keys.volume_key = random_key()
    match make_first_keys(container, id, keys, passphrase, parameters) {
        case Ok => {}
        case Error(error) => {
            free_keys(keys)
            return .Error(error)
        }
    }
    return create_keyed_volume(container, name, hash_key, now, keys)
}

/**
 * Put an encrypted volume's first wrap and generation records in the container's volumes tree.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID the volume is about to get, the container's next_volume: the key records are put under it and
 *     the wrap and generation are bound to it, so the volume has to be made with it. Not checked.
 * @param keys Its keys, its volume key made; the first generation is started in them.
 * @param passphrase The passphrase the volume key is wrapped by.
 * @param parameters Argon2id's parameters.
 * @error WrongKey The volume key couldn't be wrapped.
 * @error Corrupt The first generation couldn't be made, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 */
make_first_keys :: fn(container: ptr[mut Container], id: u64, keys: ptr[mut Keys], passphrase: u8[],
    parameters: crypto.Argon2Parameters) -> Result[void, Error] {

    wrap := wrap_with_passphrase(&keys.volume_key, passphrase, parameters, container.id, id) or_return .Error(.WrongKey)
    put_wrap(container, id, 0, &wrap)?
    generation := start_generation(keys, container.nodes.transaction, container.id, id) or_return .Error(.Corrupt)
    put_generation(container, id, keys.current, &generation)?
    return .Ok
}

/**
 * Make a new volume, encrypted with keys or not, with its root directory, open in the container's own process.
 *
 * @param container The container, which keeps the volume among its open ones.
 * @param name Its name, 1 to VOLUME_NAME_BYTES bytes.
 * @param hash_key The key its names hash with.
 * @param now When it's made.
 * @param keys Its keys, which it then owns, freed with it, or here on an error; null for a volume that isn't
 *     encrypted.
 * @return The volume, the container's.
 * @error InvalidName The name is empty or too long.
 * @error OutOfMemory No memory for the volume, its place among the open ones, or a node.
 * @error NoSpace No free extent for its root's node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
create_keyed_volume :: fn(container #escaping : ptr[mut Container], name: string, hash_key: u8[32], now: u64,
    keys #escaping : ptr[mut Keys]?) -> Result[ptr[mut Volume], Error] {

    if name.count == 0 || name.count > VOLUME_NAME_BYTES {
        match keys {
            case Some(given) => free_keys(given)
            case None => {}
        }
        return .Error(.InvalidName)
    }
    volume :: match make(Volume) {
        case Ok(made) => made
        case Error(error) => {
            match keys {
                case Some(given) => free_keys(given)
                case None => {}
            }
            return .Error(error)
        }
    }
    volume^ = Volume.{nodes = &container.nodes, device = container.device, id = container.next_volume, next_object = ROOT_OBJECT + 1,
        hash_key = hash_key, created = now, name_bytes = cast[u16](name.count), dirty = true, now = now}
    volume.tree = Tree.{kind = .Volume, owner = volume.id, keys = keys}
    for character, i in name {
        if i < volume.name.count {
            volume.name[i] = cast[u8](character)
        }
    }
    container.next_volume += 1
    root := ObjectRecord.{kind = cast[u32le](cast[u32](ObjectKind.Directory)), parent = cast[u64le](ROOT_OBJECT),
        created = cast[u64le](now), modified = cast[u64le](now), changed = cast[u64le](container.nodes.transaction)}
    match put_object(volume, ROOT_OBJECT, &root) {
        case Ok => {}
        case Error(error) => {
            free_volume(volume)
            return .Error(error)
        }
    }
    if runtime.array_try_add(&container.open, volume) != null {
        free_volume(volume)
        return .Error(.OutOfMemory)
    }
    return .Ok(volume)
}

/**
 * Open a volume that isn't encrypted in the container's own process: the one open already, or one from its record.
 *
 * @param container The container, which keeps the volume among its open ones.
 * @param id The ID of the volume in the container; an open one with it is returned as it is, and one with no record
 *     in the volumes tree is NotFound.
 * @return The volume, the container's, freed by close_volume or unmount.
 * @error NotFound The volume, or an origin of a clone's, isn't there.
 * @error Locked The volume is encrypted.
 * @error TooLarge The volume's lineage is longer than MAX_LINEAGE.
 * @error OutOfMemory No memory for the volume or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
open_volume :: fn(container #escaping : ptr[mut Container], id: u64) -> Result[ptr[mut Volume], Error] {
    for volume in container.open {
        if volume.id == id {
            return .Ok(volume)
        }
    }
    value : u8[224]
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .VolumeEntry, 0), value)? or_return .Error(.NotFound)
    if bytes != size_of(VolumeRecord) {
        return .Error(.Corrupt)
    }
    record :: cast[ptr[VolumeRecord]](&value[0])
    if record.cipher != cast[u8](Cipher.None) {
        return .Error(.Locked)
    }
    lineage :: lineage_of(container, record)?
    volume :: attach_volume(&container.nodes, container.device, id, record^, null)?
    volume.tree.lineage = lineage
    if runtime.array_try_add(&container.open, volume) != null {
        free_volume(volume)
        return .Error(.OutOfMemory)
    }
    return .Ok(volume)
}

/**
 * Open an encrypted volume in the container's own process: the one open already, or one from its record, unlocked
 * with a passphrase. A volume that isn't encrypted is opened as open_volume opens it, the passphrase unused.
 *
 * @param container The container, which keeps the volume among its open ones.
 * @param id The ID of the volume in the container; an open one with it is returned as it is, and one with no record
 *     in the volumes tree is NotFound.
 * @param passphrase The passphrase, secret; not checked for a volume open already.
 * @return The volume, the container's, freed by close_volume or unmount.
 * @error NotFound The volume, or an origin of a clone's, isn't there.
 * @error WrongKey The passphrase unwraps none of its key records.
 * @error TooLarge The volume's lineage is longer than MAX_LINEAGE.
 * @error OutOfMemory No memory for the keys, the volume or a node.
 * @error Corrupt A record or a node didn't check out, the cipher isn't one, or a generation doesn't open.
 */
open_sealed_volume :: fn(container #escaping : ptr[mut Container], id: u64, passphrase: u8[]) -> Result[ptr[mut Volume], Error] {
    for volume in container.open {
        if volume.id == id {
            return .Ok(volume)
        }
    }
    record :: volume_record(container, id)?
    if record.cipher == cast[u8](Cipher.None) {
        return open_volume(container, id)
    }
    lineage :: lineage_of(container, &record)?
    // A clone's keys are its origin's
    key_owner :: key_owner_of(id, &record)
    wraps : WrapRecord[..]
    defer runtime.array_free(&wraps)
    volume_wraps(container, key_owner, &wraps)?
    generations : NumberedGeneration[..]
    defer runtime.array_free(&generations)
    volume_generations(container, key_owner, &generations)?
    keys :: new_keys(.None)?
    match unlock(container.id, key_owner, record, wraps, generations, passphrase, keys) {
        case Ok => {}
        case Error(error) => {
            free_keys(keys)
            return .Error(error)
        }
    }
    volume :: match attach_volume(&container.nodes, container.device, id, record, keys) {
        case Ok(made) => made
        case Error(error) => {
            free_keys(keys)
            return .Error(error)
        }
    }
    volume.tree.lineage = lineage
    if runtime.array_try_add(&container.open, volume) != null {
        free_volume(volume)
        return .Error(.OutOfMemory)
    }
    return .Ok(volume)
}

/**
 * Make a volume from its record: as open_volume opens one in the container's own process, and as a volume server
 * opens its own (decisions/0089).
 *
 * Nothing is read; it isn't put among any container's open volumes. Its lineage is empty until the caller sets it.
 *
 * @param nodes The transaction's nodes its tree changes in, which have to outlive the volume.
 * @param device The device its chunks are on, whose context has to outlive the volume.
 * @param id The volume's ID in its container, which it and its tree's nodes are owned by; not checked against
 *     record, which doesn't hold it.
 * @param record Its record, as it is now.
 * @param keys Its keys, which it then owns, freed with it; null for a volume that isn't encrypted. On an error, they
 *     aren't freed here.
 * @return The volume, the caller's to free with free_volume.
 * @error OutOfMemory No memory for it.
 */
attach_volume :: fn(nodes #escaping : ptr[mut Nodes], device #escaping : Device, id: u64, record: VolumeRecord,
    keys #escaping : ptr[mut Keys]?) -> Result[ptr[mut Volume], Error] {

    volume :: make(Volume)?
    volume^ = Volume.{nodes = nodes, device = device, id = id, next_object = cast[u64](record.next_object), hash_key = record.hash_key,
        created = cast[u64](record.created), name = record.name, name_bytes = cast[u16](record.name_bytes)}
    volume.tree = Tree.{root = record.root, kind = .Volume, owner = id, keys = keys}
    volume.opened = record
    return .Ok(volume)
}

/**
 * Make a volume's record as it is now: its root as it was last written, its cipher and newest key generation, and
 * the rest.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @return The record, a copy; what the volume doesn't change, as a clone's origin, as it was opened.
 */
record_of :: fn(volume: ptr[Volume]) -> VolumeRecord {
    record := volume.opened
    record.root = volume.tree.root
    record.next_object = cast[u64le](volume.next_object)
    record.hash_key = volume.hash_key
    record.created = cast[u64le](volume.created)
    record.name_bytes = cast[u16le](volume.name_bytes)
    record.name = volume.name
    match volume.tree.keys {
        case Some(keys) => {
            record.cipher = cast[u8](keys.cipher)
            record.generation = cast[u32le](keys.current)
        }
        case None => {}
    }
    return record
}

/**
 * Write a volume's dirty nodes, children first, and make its record as it then is: what a volume server gives the
 * container service to commit (decisions/0089), once the writes have finished.
 *
 * Nothing is flushed: the record names nodes that are durable only after the commit's flush.
 *
 * @param volume The volume; it's no longer dirty once this succeeds.
 * @return The record, its root's seal set.
 * @error Failed A data write failed since the volume was opened (or forget was last called).
 * @error DeviceError A node couldn't be written.
 * @error OutOfMemory No memory to seal an encrypted node in.
 * @error Corrupt An encrypted node couldn't be sealed.
 */
write_volume :: fn(volume: ptr[mut Volume]) -> Result[VolumeRecord, Error] {
    if volume.failed {
        return .Error(.Failed)
    }
    tree_write(volume.nodes, &volume.tree)?
    volume.dirty = false
    return .Ok(record_of(volume))
}

/**
 * Find the next volume in the container, by ID, for walking them in order.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param at The ID to look from.
 * @return The ID of the first object at or after at with a record in the volumes tree, which is a volume's ID as a
 *     rule; null after the last.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
next_volume_id :: fn(container: ptr[mut Container], at: u64) -> Result[u64?, Error] {
    value : u8[1]
    found :: tree_next(&container.nodes, &container.volumes, key_of(at, .VolumeEntry, 0), value)? or_return .Ok(null)
    return .Ok(found.key.object)
}

/**
 * Close a volume open in the container's own process, freeing it.
 *
 * What it changed since its last commit isn't lost at once: its dirty nodes stay the container's, and the next
 * commit writes them, though its record isn't updated to name them.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume's ID; one that isn't open is no error, and nothing's done.
 */
close_volume :: fn(container: ptr[mut Container], id: u64) {
    for volume, i in container.open {
        if volume.id == id {
            runtime.array_remove(&container.open, i)
            free_volume(volume)
            return void
        }
    }
}

/**
 * Free a volume's memory, its keys with it, zeroed.
 *
 * @param volume The volume; it may not be used again. One among a container's open ones has to be taken out of them
 *     first (close_volume does both).
 */
free_volume :: fn(volume: ptr[mut Volume]) {
    match volume.tree.keys {
        case Some(keys) => free_keys(keys)
        case None => {}
    }
    runtime.free(volume)
}

/**
 * Register a new volume in the container with nothing in it yet (decisions/0141): its record, with no root and no
 * keys, which the volume server that serves it first fills, making the keys of one with a cipher and writing its
 * root.
 *
 * It's how the container service makes a volume, without holding what opens it. The record is durable with the
 * container's next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param name Its name, 1 to VOLUME_NAME_BYTES bytes, which no volume in the container has.
 * @param hash_key The key its names hash with, random.
 * @param now When it's made.
 * @param cipher Its cipher; for any but None, its record names generation 1, which first_keys starts.
 * @return Its ID, a new one.
 * @error InvalidName The name is empty or too long.
 * @error AlreadyExists A volume in the container has the name.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error NotFound A volume found by its ID isn't there to read.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
register_volume :: fn(container: ptr[mut Container], name: u8[], hash_key: u8[32], now: u64, cipher: Cipher) -> Result[u64, Error] {
    if name.count == 0 || name.count > VOLUME_NAME_BYTES {
        return .Error(.InvalidName)
    }
    found :: find_volume(container, string_of(&name[0], name.count))?
    if found is_some {
        return .Error(.AlreadyExists)
    }
    id :: container.next_volume
    record := VolumeRecord.{next_object = cast[u64le](ROOT_OBJECT + 1), hash_key = hash_key, created = cast[u64le](now),
        name_bytes = cast[u16le](cast[u16](name.count)), cipher = cast[u8](cipher)}
    // A sealed one's first generation, which first_keys starts, is 1
    if cipher != .None {
        record.generation = cast[u32le](1)
    }
    for byte, i in name {
        if i < record.name.count {
            record.name[i] = byte
        }
    }
    put_volume_record(container, id, &record)?
    container.next_volume += 1
    return .Ok(id)
}

/**
 * Tell whether a volume's record is one register_volume made that no volume server has filled yet.
 *
 * @param record The volume's record, as volume_record read it.
 * @return True if it has no root and its next object is still the first after the root's.
 */
is_unfilled :: fn(record: ptr[VolumeRecord]) -> bool {
    return cast[u64](record.root.address) == 0 && cast[u64](record.next_object) == ROOT_OBJECT + 1
}

/** A new sealed volume's first keys' records, made apart from its container, for the container service to keep. */
FirstKeys :: struct {
    /** Its volume key wrapped by its passphrase, to keep at KeyWrap index 0. */
    wrap : WrapRecord,
    /** Its first generation's key wrapped by its volume key. */
    generation : GenerationRecord,
    /** The first generation's number, 1 for keys with none before. */
    number : u32,
}

/**
 * Make the keys of a volume register_volume made with a cipher, in its volume server: its volume key made, and
 * wrapped by a passphrase through Argon2id, and its first generation started.
 *
 * What's returned is what the container service is given to keep, which opens nothing without the passphrase.
 *
 * @param keys The volume's keys, from new_keys with its cipher; its volume key is made and its first generation added.
 * @param passphrase The passphrase, secret.
 * @param parameters Argon2id's parameters: MADE_PASSPHRASE, as a rule.
 * @param container The ID of the container the volume is in, from its superblock; bound into the wrap and the
 *     generation, so unlocking has to give the same.
 * @param id The ID register_volume gave the volume; bound into the wrap and the generation, so they open only for
 *     it (or a clone of it). Not checked.
 * @param transaction The transaction the first generation begins in.
 * @return The records to keep.
 * @error WrongKey The volume key couldn't be wrapped: Argon2id couldn't run with the parameters.
 * @error Corrupt The first generation couldn't be wrapped, or kept for want of memory.
 */
first_keys :: fn(keys: ptr[mut Keys], passphrase: u8[], parameters: crypto.Argon2Parameters, container: u8[16], id: u64,
    transaction: u64) -> Result[FirstKeys, Error] {

    keys.volume_key = random_key()
    wrap :: wrap_with_passphrase(&keys.volume_key, passphrase, parameters, container, id) or_return .Error(.WrongKey)
    generation :: start_generation(keys, transaction, container, id) or_return .Error(.Corrupt)
    return .Ok(FirstKeys.{wrap = wrap, generation = generation, number = keys.current})
}

/**
 * Give a volume register_volume made its root directory, as create_volume gives one, written with its next commit.
 *
 * @param volume The volume, unfilled.
 * @param now When the root is made.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for the root's node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
fill_volume :: fn(volume: ptr[mut Volume], now: u64) -> Result[void, Error] {
    root := ObjectRecord.{kind = cast[u32le](cast[u32](ObjectKind.Directory)), parent = cast[u64le](ROOT_OBJECT),
        created = cast[u64le](now), modified = cast[u64le](now), changed = cast[u64le](volume.nodes.transaction)}
    put_object(volume, ROOT_OBJECT, &root)?
    volume.dirty = true
    return .Ok
}

/**
 * Put a volume's record in the container's volumes tree, durable with the container's next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume's ID, the key the record goes under, replacing any there; not checked, so a new one makes
 *     a volume of it.
 * @param record The record, copied.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
put_volume_record :: fn(container: ptr[mut Container], id: u64, record: ptr[VolumeRecord]) -> Result[void, Error] {
    tree_put(&container.nodes, &container.volumes, key_of(id, .VolumeEntry, 0), view_of(cast[ptr[u8]](record), size_of(VolumeRecord)))?
    return .Ok
}

/**
 * Read a volume's record from the container's volumes tree, as this transaction has it.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume's ID, the key its record is under; one with none is NotFound.
 * @return The record, a copy.
 * @error NotFound No volume has the ID.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
volume_record :: fn(container: ptr[mut Container], id: u64) -> Result[VolumeRecord, Error] {
    record := VolumeRecord.{}
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .VolumeEntry, 0),
        view_of(cast[ptr[mut u8]](&record), size_of(VolumeRecord)))? or_return .Error(.NotFound)
    if bytes != size_of(VolumeRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

/**
 * Find a volume in the container by its name.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param name The name, compared byte for byte.
 * @return The volume's ID; null if no volume has the name.
 * @error NotFound A volume found by its ID isn't there to read.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
find_volume :: fn(container: ptr[mut Container], name: string) -> Result[u64?, Error] {
    at : u64 = 0
    loop {
        id :: next_volume_id(container, at)? or_return .Ok(null)
        record :: volume_record(container, id)?
        length :: cast[usize](cast[u16](record.name_bytes))
        if length == name.count && length <= record.name.count && same_bytes(record.name[0..<length], name) {
            return .Ok(id)
        }
        if id == 0xffffffffffffffff {
            return .Ok(null)
        }
        at = id + 1
    }
}

// Objects' records.

/**
 * Read an object's record.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The ID of an object in the volume; one with no record is NotFound.
 * @return The record, a copy.
 * @error NotFound No object has the ID.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
get_object :: fn(volume: ptr[mut Volume], object: u64) -> Result[ObjectRecord, Error] {
    record := ObjectRecord.{}
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(object, .Object, 0),
        view_of(cast[ptr[mut u8]](&record), size_of(ObjectRecord)))? or_return .Error(.NotFound)
    if bytes != size_of(ObjectRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

/**
 * Put an object's record, durable with the volume's next commit.
 *
 * @param volume The volume, marked dirty.
 * @param object The ID of the object whose record it is, replacing any there; not checked, so a new ID makes a new
 *     object, which the caller has to have taken from next_object.
 * @param record The record, copied.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
put_object :: fn(volume: ptr[mut Volume], object: u64, record: ptr[ObjectRecord]) -> Result[void, Error] {
    volume.dirty = true
    tree_put(volume.nodes, &volume.tree, key_of(object, .Object, 0), view_of(cast[ptr[u8]](record), size_of(ObjectRecord)))?
    return .Ok
}

/**
 * Get an object's kind from its record.
 *
 * @param record The object's record, as get_object read it.
 * @return Its kind, as kind_of reads it.
 */
kind_of_record :: fn(record: ptr[ObjectRecord]) -> ObjectKind {
    return kind_of(cast[u32](record.kind))
}

/**
 * Get the ObjectKind a kind field holds.
 *
 * @param kind A kind field's value, from an object's record or an entry's head, as stored; any value is taken.
 * @return Directory or Link for theirs; File for any other value, 1 included.
 */
kind_of :: fn(kind: u32) -> ObjectKind {
    if kind == cast[u32](ObjectKind.Directory) {
        return .Directory
    }
    return if kind == cast[u32](ObjectKind.Link) { .Link } else { .File }
}

/**
 * Get what an object is.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The ID of an object in the volume; one with no record is NotFound.
 * @return What its record says.
 * @error NotFound No object has the ID.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
info :: fn(volume: ptr[mut Volume], object: u64) -> Result[Info, Error] {
    record :: get_object(volume, object)?
    return .Ok(Info.{object = object, kind = kind_of_record(&record), parent = cast[u64](record.parent), size = cast[u64](record.size),
        created = cast[u64](record.created), modified = cast[u64](record.modified), changed = cast[u64](record.changed),
        schema = record.schema})
}

/**
 * Make a file typed (decisions/0046, 0108): its schema hash kept in its record, durable with the next commit.
 *
 * Only a new file's is given one; this doesn't check that it's new, or a file, and changes no time.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The ID of the file, as a rule new; one with no record is NotFound, and its kind isn't checked.
 * @param schema The schema hash; all zeros makes it plain bytes again.
 * @error NotFound No object has the ID.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 */
set_schema :: fn(volume: ptr[mut Volume], object: u64, schema: u8[32]) -> Result[void, Error] {
    record := get_object(volume, object)?
    record.schema = schema
    put_object(volume, object, &record)?
    return .Ok
}

/**
 * Read the record of an object that has to be a directory.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The ID of the object, which has to be a directory; one with no record is NotFound.
 * @return The directory's record, a copy.
 * @error NotFound No object has the ID.
 * @error NotADirectory It's a file.
 * @error IsALink It's a stored link.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
directory_record :: fn(volume: ptr[mut Volume], object: u64) -> Result[ObjectRecord, Error] {
    record :: get_object(volume, object)?
    kind :: kind_of_record(&record)
    if kind == .Link {
        return .Error(.IsALink)
    }
    if kind != .Directory {
        return .Error(.NotADirectory)
    }
    return .Ok(record)
}

/**
 * Mark an object changed now: its modified time the volume's now, its changed transaction this one, and its record
 * put.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The ID record is put under, the object's own; not checked, nor read, so record has to be its.
 * @param record Its record, as the caller has it, updated and put.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
touch :: fn(volume: ptr[mut Volume], object: u64, record: ptr[mut ObjectRecord]) -> Result[void, Error] {
    record.modified = cast[u64le](volume.now)
    record.changed = cast[u64le](volume.nodes.transaction)
    return put_object(volume, object, record)
}

// Names.

/**
 * Tell whether a name can name something: not empty, not too long, not "." or "..", no '/', and UTF-8 with nothing
 * that can't be seen (decisions/0097, 0108).
 *
 * Nothing that can't be seen means no C0 or C1 controls (NUL among them), no bidirectional controls, and none of
 * Unicode's default ignorable code points, which UTS #39 counts as invisible. Names are compared byte for byte
 * (0046), so these are what would let two names look the same, or one look like another.
 *
 * @param name The name's bytes, as given.
 * @return True if it can; false if it's empty, longer than NAME_BYTES, "." or "..", or has '/', bytes that aren't
 *     UTF-8, or a code point that isn't visible.
 */
name_holds :: fn(name: string) -> bool {
    if name.count == 0 || name.count > NAME_BYTES || name == "." || name == ".." {
        return false
    }
    bytes :: string_bytes(name)
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        point, length :: decode_utf8(bytes, at)
        if length == 0 || point == cast[u32]('/') || !visible(point) {
            return false
        }
        at += length
    }
    return true
}

/**
 * Decode the UTF-8 code point at an offset in bytes.
 *
 * @param bytes The bytes, any; they aren't trusted to be UTF-8.
 * @param at The byte offset of the code point's first byte.
 * @return point The code point; 0 when length is.
 * @return length Its length in bytes, 1 to 4; 0 at the end, or for bytes that aren't UTF-8, an overlong form, a
 *     surrogate or past 0x10ffff.
 */
decode_utf8 :: fn(bytes: u8[], at: usize) -> (point: u32, length: usize) {
    if at >= bytes.count {
        return 0, 0
    }
    first :: cast[u32](bytes[at])
    length : usize = 0
    point := cast[u32](0)
    smallest := cast[u32](0)
    if first < 0x80 {
        return first, 1
    }
    else if first & 0xe0 == 0xc0 {
        length = 2
        point = first & 0x1f
        smallest = 0x80
    }
    else if first & 0xf0 == 0xe0 {
        length = 3
        point = first & 0x0f
        smallest = 0x800
    }
    else if first & 0xf8 == 0xf0 {
        length = 4
        point = first & 0x07
        smallest = 0x10000
    }
    else {
        return 0, 0
    }
    if at + length > bytes.count {
        return 0, 0
    }
    for i in 1..<length {
        if at + i >= bytes.count {
            return 0, 0
        }
        next :: cast[u32](bytes[at + i])
        if next & 0xc0 != 0x80 {
            return 0, 0
        }
        point = (point << 6) | (next & 0x3f)
    }
    if point < smallest || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff) {
        return 0, 0
    }
    return point, length
}

/**
 * Tell whether a code point shows: not a control, a bidirectional control, or a default ignorable
 * (DerivedCoreProperties).
 *
 * @param point The code point, as decode_utf8 gave it.
 * @return True if it shows; false for U+0000 to U+001F, U+007F to U+009F, and the ranges in INVISIBLE.
 */
visible :: fn(point: u32) -> bool {
    if point < 0x20 || (point >= 0x7f && point <= 0x9f) {
        return false
    }
    for i in 0..<INVISIBLE.count / 2 {
        low :: 2 * i
        if low + 1 < INVISIBLE.count && point >= INVISIBLE[low] && point <= INVISIBLE[low + 1] {
            return false
        }
    }
    return true
}

/** Unicode's Default_Ignorable_Code_Point ranges (Unicode 15.1), the bidirectional controls among them: low, high. */
INVISIBLE :: u32.[
    0x00ad, 0x00ad, 0x034f, 0x034f, 0x061c, 0x061c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b, 0x180f, 0x200b, 0x200f,
    0x202a, 0x202e, 0x2060, 0x206f, 0x3164, 0x3164, 0xfe00, 0xfe0f, 0xfeff, 0xfeff, 0xffa0, 0xffa0, 0xfff0, 0xfff8,
    0x1bca0, 0x1bca3, 0x1d173, 0x1d17a, 0xe0000, 0xe0fff,
]

/** The bits a name's hash has: 56, so a list cursor holds it with a place among those alike in its low 8. */
HASH_MASK : u64 : 0x00ffffffffffffff

/**
 * Hash a name, keyed by the volume's key: BLAKE3, its first 7 bytes, little-endian.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param name The name's bytes, hashed as they are.
 * @return The hash, 0 to HASH_MASK.
 */
hash_name :: fn(volume: ptr[Volume], name: string) -> u64 {
    hasher := crypto.blake3_start_keyed(crypto.as_secret(volume.hash_key)) or_return 0
    crypto.blake3_update(&hasher, string_bytes(name))
    digest : u8[8]
    crypto.blake3_finish(&hasher, digest)
    hash : u64 = 0
    for byte, i in digest {
        if i < 7 {
            hash = hash | cast[u64](byte) << cast[u64](i * 8)
        }
    }
    return hash
}

/**
 * A directory's entries whose names hash alike, as stored: one after another, each a head and its name. The record's
 * value is copied into a buffer of MAX_VALUE_BYTES.
 */
EntryList :: struct {
    /** The record's value. */
    bytes : u8[4096],
    /** How many of bytes are used; 0 for no record. */
    count : usize,
}

/** The entry named name in a list: where it starts, and its head. */
EntryAt :: struct {
    /** Its head's byte offset in the list. */
    at : usize,
    /** Its head, a copy. */
    head : EntryHead,
}

/**
 * Read the head of the entry at an offset in a list.
 *
 * @param list The list, as get_entries filled it.
 * @param at The entry's byte offset.
 * @return The head, a copy; null if it doesn't fit in the list's used bytes.
 */
entry_head :: fn(list: ptr[EntryList], at: usize) -> EntryHead? {
    if at + size_of(EntryHead) > list.count || at >= list.bytes.count {
        return null
    }
    return cast[ptr[EntryHead]](&list.bytes[at])^
}

/**
 * Step from an entry in a list to the next.
 *
 * @param list The list, as get_entries filled it.
 * @param at The entry's byte offset.
 * @return The next entry's offset, which may be the list's end; null if the entry doesn't hold together.
 */
next_entry_at :: fn(list: ptr[EntryList], at: usize) -> usize? {
    head :: entry_head(list, at) or_return null
    next :: at + size_of(EntryHead) + cast[usize](cast[u16](head.name_bytes))
    return if next <= list.count { next } else { null }
}

/**
 * Get an entry's name in a list.
 *
 * @param list The list, as get_entries filled it.
 * @param at The entry's byte offset.
 * @param head The entry's head, as entry_head read it at at; its name_bytes says how many bytes the name has.
 * @return The name's bytes, a view into the list, good until it changes; empty if they don't fit in the list.
 */
entry_name :: fn(list: ptr[EntryList], at: usize, head: ptr[EntryHead]) -> u8[] {
    start :: at + size_of(EntryHead)
    count :: cast[usize](cast[u16](head.name_bytes))
    if start + count > list.count || start >= list.bytes.count {
        return list.bytes[0..<0]
    }
    return view_of(&list.bytes[start], count)
}

/**
 * Tell whether bytes are a string's.
 *
 * @param a The bytes, as a list's name holds them.
 * @param b The string, as a caller's name.
 * @return True if they're the same length and byte for byte alike.
 */
same_bytes :: fn(a: u8[], b: string) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && cast[u8](b[i]) != byte {
            return false
        }
    }
    return true
}

/**
 * Find an entry in a list by its name, compared byte for byte.
 *
 * @param list The list, as get_entries filled it.
 * @param name The name looked for.
 * @return Where it is and its head; null if no entry has it, or the list stops holding together before one does.
 */
find_in_list :: fn(list: ptr[EntryList], name: string) -> EntryAt? {
    at : usize = 0
    loop {
        head :: entry_head(list, at) or_return null
        if same_bytes(entry_name(list, at, &head), name) {
            return EntryAt.{at = at, head = head}
        }
        at = next_entry_at(list, at) or_return null
    }
    while at < list.count
    return null
}

/**
 * Read a directory's entries whose names have a hash.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory; not checked to be one or to be there, so none read means no entries.
 * @param hash The names' hash.
 * @param list Where they go; its count is 0 if there are none.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
get_entries :: fn(volume: ptr[mut Volume], directory: u64, hash: u64, list: ptr[mut EntryList]) -> Result[void, Error] {
    list.count = tree_get(volume.nodes, &volume.tree, key_of(directory, .Entry, hash), list.bytes)? or_else 0
    return .Ok
}

/**
 * Put a directory's entries whose names have a hash, or take their record out when there are none.
 *
 * @param volume The volume, marked dirty.
 * @param directory The ID of the directory whose entries they are; not checked to be one or to be there.
 * @param hash The names' hash.
 * @param list The entries, all of them for the hash, their count what's used.
 * @error TooLarge The list's count is past its buffer.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
put_entries :: fn(volume: ptr[mut Volume], directory: u64, hash: u64, list: ptr[EntryList]) -> Result[void, Error] {
    volume.dirty = true
    key :: key_of(directory, .Entry, hash)
    if list.count == 0 {
        tree_delete(volume.nodes, &volume.tree, key)?
        return .Ok
    }
    if list.count > list.bytes.count {
        return .Error(.TooLarge)
    }
    tree_put(volume.nodes, &volume.tree, key, list.bytes[0..<list.count])?
    return .Ok
}

/**
 * Look up the object a name names in a directory.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory looked in; it's read first, so one that isn't there, or isn't a
 *     directory, is an error.
 * @param name The name, compared byte for byte.
 * @return The object's ID; null if nothing has the name.
 * @error NotFound The directory isn't there.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error InvalidName The name can't name anything (name_holds).
 * @error OutOfMemory No memory for the list or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
lookup :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[u64?, Error] {
    directory_record(volume, directory)?
    if !name_holds(name) {
        return .Error(.InvalidName)
    }
    list :: make(EntryList)?
    defer runtime.free(list)
    get_entries(volume, directory, hash_name(volume, name), list)?
    found :: find_in_list(list, name) or_return .Ok(null)
    return .Ok(cast[u64](found.head.object))
}

/**
 * Add an entry to a directory, naming an object. The object's record and the directory's aren't touched.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory's ID, not checked to be one.
 * @param name The name, which the caller has checked holds.
 * @param object The object it names.
 * @param kind The object's kind, kept in the entry so listing needn't read its record; not checked against it.
 * @error AlreadyExists The directory has an entry of the name.
 * @error TooLarge The entries whose names hash alike with it have no room for it in one record.
 * @error OutOfMemory No memory for the list or a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
add_entry :: fn(volume: ptr[mut Volume], directory: u64, name: string, object: u64, kind: ObjectKind) -> Result[void, Error] {
    hash :: hash_name(volume, name)
    list :: make(EntryList)?
    defer runtime.free(list)
    get_entries(volume, directory, hash, list)?
    if find_in_list(list, name) is_some {
        return .Error(.AlreadyExists)
    }
    if list.count + size_of(EntryHead) + name.count > list.bytes.count {
        return .Error(.TooLarge)
    }
    head := EntryHead.{object = cast[u64le](object), kind = cast[u32le](cast[u32](kind)), name_bytes = cast[u16le](cast[u16](name.count))}
    copy_bytes(list.bytes, list.count, view_of(cast[ptr[mut u8]](&head), size_of(EntryHead)))
    copy_bytes(list.bytes, list.count + size_of(EntryHead), string_bytes(name))
    list.count += size_of(EntryHead) + name.count
    put_entries(volume, directory, hash, list)?
    return .Ok
}

/**
 * Take an entry out of a directory. The object it named is left as it is.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory; not checked to be one or to be there, so its name isn't found.
 * @param name The name, compared byte for byte.
 * @error NotFound The directory has no entry of the name.
 * @error OutOfMemory No memory for the list or a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
remove_entry :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[void, Error] {
    hash :: hash_name(volume, name)
    list :: make(EntryList)?
    defer runtime.free(list)
    get_entries(volume, directory, hash, list)?
    found :: find_in_list(list, name) or_return .Error(.NotFound)
    length :: size_of(EntryHead) + cast[usize](cast[u16](found.head.name_bytes))
    for i in found.at..<list.count - length {
        j :: i + length
        if j < list.bytes.count && i < list.bytes.count {
            list.bytes[i] = list.bytes[j]
        }
    }
    list.count -= length
    put_entries(volume, directory, hash, list)?
    return .Ok
}

// Paths: components with '/' between them, each a name, resolved beneath a directory, so nothing leads above it.

/**
 * Resolve a path beneath a directory to its object, each component looked up in the one before. Links aren't
 * followed: one before the last component is IsALink.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory the path starts at.
 * @param path The path: names separated by single '/', none empty, no leading or trailing '/'.
 * @return The object at its end.
 * @error InvalidName A component can't name anything: empty, ".", "..", or too long.
 * @error NotFound A component isn't there.
 * @error NotADirectory A component before the last is a file.
 * @error IsALink A component before the last is a stored link.
 * @error OutOfMemory No memory for a list or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
resolve :: fn(volume: ptr[mut Volume], directory: u64, path: string) -> Result[u64, Error] {
    at := directory
    start : usize = 0
    for i in 0..<path.count + 1 {
        if i < path.count && path[i] != '/' {
            continue
        }
        if start > i {
            return .Error(.InvalidName)
        }
        component :: path[start..<i]
        start = i + 1
        at = lookup(volume, at, component)? or_return .Error(.NotFound)
    }
    return .Ok(at)
}

/** Where a path's last component goes: the directory holding it, and its name. */
Leaf :: struct {
    /** The directory's ID. */
    directory : u64,
    /** The last component, a view into the path, good as long as it is; not checked to hold. */
    name : string,
}

/**
 * Find where a path's last component goes: the directory its components before it lead to, and its name.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory the path starts at.
 * @param path The path: names separated by single '/'; its last component isn't looked up.
 * @return The directory and the name; a path without '/' is directory and the whole path.
 * @error InvalidName A component before the last can't name anything.
 * @error NotFound A component before the last isn't there.
 * @error NotADirectory A component before the last is a file.
 * @error IsALink A component before the last is a stored link.
 * @error OutOfMemory No memory for a list or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
leaf_of :: fn(volume: ptr[mut Volume], directory: u64, path: string) -> Result[Leaf, Error] {
    last := path.count
    for character, i in path {
        if character == '/' {
            last = i
        }
    }
    if last == path.count {
        return .Ok(Leaf.{directory = directory, name = path})
    }
    if last + 1 > path.count {
        return .Error(.InvalidName)
    }
    parent :: resolve(volume, directory, path[0..<last])?
    directory_record(volume, parent)?
    return .Ok(Leaf.{directory = parent, name = path[last + 1..<path.count]})
}

/**
 * Make a new, empty file, directory or link object, named in a directory.
 *
 * Its times are the volume's now; the directory is touched and a Created change noted. It's durable with the
 * volume's next commit.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory the object is named in; it's read first, so one that isn't there, or
 *     isn't a directory, is an error. It becomes the object's parent.
 * @param name The name, which name_holds and the directory doesn't have.
 * @param kind What it is; a Link's record is create_link's to put.
 * @return The new object's ID.
 * @error NotFound The directory isn't there.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error InvalidName The name can't name anything (name_holds).
 * @error AlreadyExists The directory has something of the name.
 * @error TooLarge The entries whose names hash alike with it have no room for it.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
create :: fn(volume: ptr[mut Volume], directory: u64, name: string, kind: ObjectKind) -> Result[u64, Error] {
    parent := directory_record(volume, directory)?
    if !name_holds(name) {
        return .Error(.InvalidName)
    }
    object :: volume.next_object
    add_entry(volume, directory, name, object, kind)?
    volume.next_object += 1
    record := ObjectRecord.{kind = cast[u32le](cast[u32](kind)), parent = cast[u64le](directory), created = cast[u64le](volume.now),
        modified = cast[u64le](volume.now), changed = cast[u64le](volume.nodes.transaction)}
    put_object(volume, object, &record)?
    touch(volume, directory, &parent)?
    note_change(volume, .Created, object, directory, name)?
    return .Ok(object)
}

/**
 * Tell whether a directory has nothing in it.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory; not checked to be one or to be there, either of which reads as empty.
 * @return True if it has no entries.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
is_empty :: fn(volume: ptr[mut Volume], directory: u64) -> Result[bool, Error] {
    value : u8[1]
    found :: tree_next(volume.nodes, &volume.tree, key_of(directory, .Entry, 0), value)? or_return .Ok(true)
    return .Ok(found.key.object != directory || found.key.kind != cast[u8](RecordKind.Entry))
}

/**
 * Remove what a name names in a directory, a file, a link or an empty directory, with its chunks.
 *
 * Its blocks are given back, free once the volume's next commit is durable (or held by a snapshot). The directory is
 * touched and a Removed change noted.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory the name is in; it's read first, so one that isn't there, or isn't a
 *     directory, is an error.
 * @param name The name, compared byte for byte.
 * @error NotFound The directory, or anything of the name in it, isn't there.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error InvalidName The name can't name anything.
 * @error DirectoryNotEmpty The name names a directory with something in it.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
remove :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[void, Error] {
    parent := directory_record(volume, directory)?
    object :: lookup(volume, directory, name)? or_return .Error(.NotFound)
    record :: get_object(volume, object)?
    if kind_of_record(&record) == .Directory && !(is_empty(volume, object)?) {
        return .Error(.DirectoryNotEmpty)
    }
    remove_entry(volume, directory, name)?
    destroy(volume, object)?
    touch(volume, directory, &parent)?
    note_change(volume, .Removed, object, directory, name)?
    return .Ok
}

/**
 * Destroy an object: its chunks and record taken out, its blocks given back, and a link's record.
 *
 * Its name, if it has one, is the caller's to take out.
 *
 * @param volume The volume, marked dirty.
 * @param object The ID of the object; not checked, and its kind not read: whatever link and chunk records it has
 *     go, and its own record, if there.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A chunk found can't be taken out, or a node couldn't be read or didn't check out.
 */
destroy :: fn(volume: ptr[mut Volume], object: u64) -> Result[void, Error] {
    _ = tree_delete(volume.nodes, &volume.tree, key_of(object, .Link, 0))?
    loop {
        extent := ExtentRecord.{}
        found :: tree_next(volume.nodes, &volume.tree, key_of(object, .Extent, 0),
            view_of(cast[ptr[mut u8]](&extent), size_of(ExtentRecord)))? or_break
        if found.key.object != object || found.key.kind != cast[u8](RecordKind.Extent) {
            break
        }
        drop_chunk(volume, found.key, &extent)?
    }
    tree_delete(volume.nodes, &volume.tree, key_of(object, .Object, 0))?
    volume.dirty = true
    return .Ok
}

/**
 * Take a chunk's record out, and give its blocks back if it had any.
 *
 * One a search found but deleting doesn't is a damaged tree's, and Corrupt, so the loops that drop chunks one by one
 * always end.
 *
 * @param volume The volume, marked dirty.
 * @param key The chunk's key, as a search found it.
 * @param extent The chunk's record, as the search that found key read it; its blocks, if it has any, are given back
 *     once the record is taken out.
 * @error Corrupt The record wasn't there to take out, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node's copy.
 */
drop_chunk :: fn(volume: ptr[mut Volume], key: Key, extent: ptr[ExtentRecord]) -> Result[void, Error] {
    if !(tree_delete(volume.nodes, &volume.tree, key)?) {
        return .Error(.Corrupt)
    }
    release_extent(volume, extent)
    volume.dirty = true
    return .Ok
}

/**
 * Give back a chunk's blocks, if it's in blocks; an inline chunk has none.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param extent The chunk's record; only a Blocks one's pointer is read, its blocks released under the volume's ID
 *     with their birth transaction.
 */
release_extent :: fn(volume: ptr[mut Volume], extent: ptr[ExtentRecord]) {
    if cast[u32](extent.kind) == cast[u32](ExtentKind.Blocks) {
        nodes :: volume.nodes
        nodes.release(nodes.space, cast[u64](extent.pointer.address), cast[u64](cast[u32](extent.pointer.blocks)), volume.id,
            cast[u64](extent.pointer.birth))
    }
}

/** The most directories deep a volume goes, so walking up from one ends even where a damaged volume loops. */
MAX_DEPTH : u64 : 4096

/**
 * Tell whether a directory is another, or beneath it, by following parents.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory to start at.
 * @param ancestor The directory looked for.
 * @return True if directory is ancestor or beneath it; false once the root is reached without it.
 * @error NotFound A parent on the way isn't there.
 * @error Corrupt The parents go MAX_DEPTH deep without reaching the root, as a loop does, or a record or a node
 *     couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
is_beneath :: fn(volume: ptr[mut Volume], directory: u64, ancestor: u64) -> Result[bool, Error] {
    at := directory
    for step in 0..<MAX_DEPTH {
        if at == ancestor {
            return .Ok(true)
        }
        if at == ROOT_OBJECT {
            return .Ok(false)
        }
        record :: get_object(volume, at)?
        at = cast[u64](record.parent)
    }
    return .Error(.Corrupt)
}

/**
 * Move what a name names in one directory to a name in another, or the same, replacing a file there.
 *
 * It's all in the volume's transaction, so a commit makes all of it durable or none. A file replaced is destroyed, and
 * a Removed change noted for it; the object moved is touched, as are both directories, and MovedOut and MovedIn
 * changes noted. Moving something to the name it has already does nothing.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param from The directory it's in.
 * @param from_name Its name there.
 * @param to The directory it goes to.
 * @param to_name Its name there.
 * @error NotFound A directory, or anything of from_name in from, isn't there.
 * @error NotADirectory A directory is a file.
 * @error IsALink A directory is a stored link.
 * @error InvalidName A name can't name anything, or a directory would go beneath itself.
 * @error AlreadyExists Something of to_name is in to, and it, or what's moved, is a directory.
 * @error TooLarge The entries in to whose names hash alike with to_name have no room for it.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out, or the parents loop.
 */
rename :: fn(volume: ptr[mut Volume], from: u64, from_name: string, to: u64, to_name: string) -> Result[void, Error] {
    from_record := directory_record(volume, from)?
    directory_record(volume, to)?
    if !name_holds(to_name) {
        return .Error(.InvalidName)
    }
    object :: lookup(volume, from, from_name)? or_return .Error(.NotFound)
    record := get_object(volume, object)?
    kind :: kind_of_record(&record)
    if kind == .Directory {
        beneath :: is_beneath(volume, to, object)?
        if beneath {
            return .Error(.InvalidName)
        }
    }
    existing :: lookup(volume, to, to_name)?
    match existing {
        case Some(there) => {
            if there == object {
                return .Ok
            }
            replaced :: get_object(volume, there)?
            if kind_of_record(&replaced) == .Directory || kind == .Directory {
                return .Error(.AlreadyExists)
            }
            remove_entry(volume, to, to_name)?
            destroy(volume, there)?
            note_change(volume, .Removed, there, to, to_name)?
        }
        case None => {}
    }
    remove_entry(volume, from, from_name)?
    add_entry(volume, to, to_name, object, kind)?
    record.parent = cast[u64le](to)
    touch(volume, object, &record)?
    from_record = get_object(volume, from)?
    touch(volume, from, &from_record)?
    if to != from {
        to_record := get_object(volume, to)?
        touch(volume, to, &to_record)?
    }
    note_change(volume, .MovedOut, object, from, from_name)?
    note_change(volume, .MovedIn, object, to, to_name)?
    return .Ok
}

/**
 * List the entry at or after a cursor in a directory.
 *
 * A cursor is a name's hash and its place among those alike, so it stays good while the directory changes: entries
 * added or removed elsewhere don't make it skip or repeat others, though ones that hash alike with it may.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The ID of the directory listed; it's read first, so one that isn't there, or isn't a directory,
 *     is an error.
 * @param cursor Where to list from: 0 for the first entry, or a Listed's next.
 * @param name Where the entry's name is copied, as much as fits.
 * @return The entry and the cursor after it; null after the last.
 * @error NotFound The directory isn't there.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error OutOfMemory No memory for the list or a node.
 * @error Corrupt A record's hash is past HASH_MASK, or a record or a node couldn't be read or didn't check out.
 */
list :: fn(volume: ptr[mut Volume], directory: u64, cursor: u64, name: mut u8[]) -> Result[Listed?, Error] {
    directory_record(volume, directory)?
    entries :: make(EntryList)?
    defer runtime.free(entries)
    hash := cursor >> 8
    skip := cast[usize](cursor & 0xff)
    loop {
        found :: tree_next(volume.nodes, &volume.tree, key_of(directory, .Entry, hash), entries.bytes)? or_return .Ok(null)
        if found.key.object != directory || found.key.kind != cast[u8](RecordKind.Entry) {
            return .Ok(null)
        }
        // A hash past 56 bits isn't one a name makes, and its cursor wouldn't hold it
        if found.key.offset > HASH_MASK {
            return .Error(.Corrupt)
        }
        if found.key.offset != hash {
            skip = 0
        }
        hash = found.key.offset
        entries.count = found.bytes
        at : usize = 0
        for index in 0..<256 {
            head :: entry_head(entries, at) or_break
            if cast[usize](index) >= skip {
                text :: entry_name(entries, at, &head)
                copy_bytes(name, 0, text)
                return .Ok(Listed.{name_bytes = text.count, object = cast[u64](head.object), kind = kind_of(cast[u32](head.kind)),
                    next = hash << 8 | cast[u64](index + 1)})
            }
            at = next_entry_at(entries, at) or_break
        }
        if hash >= HASH_MASK {
            return .Ok(null)
        }
        hash += 1
        skip = 0
    }
}

// Files' bytes.

/**
 * Get part of some bytes.
 *
 * @param bytes The bytes, viewed, not copied.
 * @param start The part's first byte.
 * @param end The byte after its last.
 * @return The part, a view into bytes; empty where start..end isn't inside them.
 */
part :: fn(bytes: u8[], start: usize, end: usize) -> u8[] {
    if start <= end && end <= bytes.count {
        return bytes[start..<end]
    }
    return bytes[0..<0]
}

/**
 * Get part of some bytes, to write to.
 *
 * @param bytes The bytes, viewed, not copied.
 * @param start The part's first byte.
 * @param end The byte after its last.
 * @return The part, a view into bytes; empty where start..end isn't inside them.
 */
mut_part :: fn(bytes: mut u8[], start: usize, end: usize) -> mut u8[] {
    if start <= end && end <= bytes.count {
        return bytes[start..<end]
    }
    return bytes[0..<0]
}

/** A record's value, in memory of its own, from make. */
ValueBuffer :: struct {
    /** The value's bytes, MAX_VALUE_BYTES of them. */
    bytes : u8[4096],
}

/** A chunk, in memory of its own, from make. */
ChunkBuffer :: struct {
    /** The chunk's bytes, CHUNK_BYTES of them. */
    bytes : u8[65536],
}

/**
 * Read a file's chunk.
 *
 * Nothing is changed. A chunk in blocks is checked by its seal, or opened with the volume's keys.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The ID of the file; not checked to be one or to be there, so a chunk of none reads as not there.
 * @param index The chunk's index, its byte offset / CHUNK_BYTES.
 * @param buffer Where it goes, CHUNK_BYTES of it: its bytes that were written, then zeros.
 * @return How many of its bytes were written, 0 to CHUNK_BYTES; 0 for a chunk that isn't there.
 * @error DeviceError A failed write was for the chunk (decisions/0112), or its blocks couldn't be read.
 * @error Corrupt Its record doesn't hold together, its seal doesn't hold, or a node couldn't be read or didn't
 *     check out.
 * @error OutOfMemory No memory for a buffer or a node.
 */
read_chunk :: fn(volume: ptr[mut Volume], file: u64, index: u64, buffer: mut u8[]) -> Result[usize, Error] {
    // What a failed write should have changed isn't given as if it hadn't (decisions/0112)
    if chunk_failed(volume, file, index) {
        return .Error(.DeviceError)
    }
    for i in 0..<buffer.count {
        buffer[i] = 0
    }
    value :: make(ValueBuffer)?
    defer runtime.free(value)
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(file, .Extent, index * CHUNK_BYTES), value.bytes)? or_return .Ok(0)
    if bytes < size_of(ExtentRecord) && bytes < cast[usize](INLINE_HEAD) {
        return .Error(.Corrupt)
    }
    extent :: cast[ptr[ExtentRecord]](&value.bytes[0])
    used :: cast[usize](cast[u32](extent.bytes))
    if used > buffer.count {
        return .Error(.Corrupt)
    }
    if cast[u32](extent.kind) == cast[u32](ExtentKind.Inline) {
        if cast[usize](INLINE_HEAD) + used > bytes {
            return .Error(.Corrupt)
        }
        copy_bytes(buffer, 0, part(value.bytes, cast[usize](INLINE_HEAD), cast[usize](INLINE_HEAD) + used))
        return .Ok(used)
    }
    if bytes != size_of(ExtentRecord) || cast[u32](extent.kind) != cast[u32](ExtentKind.Blocks) {
        return .Error(.Corrupt)
    }
    blocks :: cast[u64](cast[u32](extent.pointer.blocks))
    length :: cast[usize](blocks * BLOCK_BYTES)
    if blocks == 0 || length > buffer.count || cast[u64](used) > blocks * BLOCK_BYTES {
        return .Error(.Corrupt)
    }
    device :: volume.device
    match volume.tree.keys {
        case Some(keys) => {
            sealed :: make(ChunkBuffer)?
            defer runtime.free(sealed)
            if !device.read(device.context, cast[u64](extent.pointer.address), blocks, sealed.bytes) {
                return .Error(.DeviceError)
            }
            if length > buffer.count {
                return .Error(.Corrupt)
            }
            if !open_block(keys, owner_at(&volume.tree, cast[u64](extent.pointer.birth)), &extent.pointer, part(sealed.bytes, 0, length),
                buffer[0..<length]) {
                return .Error(.Corrupt)
            }
        }
        case None => {
            if !device.read(device.context, cast[u64](extent.pointer.address), blocks, buffer) {
                return .Error(.DeviceError)
            }
            seal : Seal
            crypto.blake3(buffer[0..<length], seal)
            if seal != extent.pointer.seal {
                return .Error(.Corrupt)
            }
        }
    }
    return .Ok(used)
}

/**
 * Write a file's chunk anew: in its record, or in new blocks, sealed, and the blocks it had given back.
 *
 * Blocks are written at once, not flushed; the record naming them is durable with the volume's next commit. A write
 * the device fails marks the volume failed and the chunk unreadable, gives the new blocks back and keeps the old
 * record.
 *
 * @param volume The volume, marked dirty.
 * @param file The ID of the file; not checked to be one or to be there. Its size isn't changed: that's the
 *     caller's.
 * @param index The chunk's index in the file, its byte offset / CHUNK_BYTES; one held inline has to be 0.
 * @param buffer The chunk's bytes, at least used rounded up to whole blocks, zeros past used.
 * @param used How many of its bytes were written, 0 to CHUNK_BYTES (at most INLINE_BYTES inline).
 * @param inline True to hold it in its record, as a small file's first chunk is; false for blocks.
 * @error NoSpace No free extent for its blocks, or a quota or the reserve refuses them, or none for a node.
 * @error DeviceError The device couldn't write its blocks.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt It couldn't be sealed, or a node couldn't be read or didn't check out.
 */
write_chunk :: fn(volume: ptr[mut Volume], file: u64, index: u64, buffer: mut u8[], used: usize, inline: bool) -> Result[void, Error] {
    key :: key_of(file, .Extent, index * CHUNK_BYTES)
    old := ExtentRecord.{}
    had :: tree_get(volume.nodes, &volume.tree, key, view_of(cast[ptr[mut u8]](&old), size_of(ExtentRecord)))?
    volume.dirty = true
    if inline {
        value :: make(ValueBuffer)?
        defer runtime.free(value)
        head :: cast[ptr[mut ExtentRecord]](&value.bytes[0])
        head.kind = cast[u32le](cast[u32](ExtentKind.Inline))
        head.bytes = cast[u32le](cast[u32](used))
        copy_bytes(value.bytes, cast[usize](INLINE_HEAD), part(buffer, 0, used))
        tree_put(volume.nodes, &volume.tree, key, part(value.bytes, 0, cast[usize](INLINE_HEAD) + used))?
        note_chunk(volume, file, index, false)
    }
    else {
        blocks :: (cast[u64](used) + BLOCK_BYTES - 1) / BLOCK_BYTES
        length :: cast[usize](blocks * BLOCK_BYTES)
        // Checked before blocks are taken, so this failure has none to give back
        if length > buffer.count {
            return .Error(.Corrupt)
        }
        nodes :: volume.nodes
        address :: nodes.allocate(nodes.space, blocks, volume.id, true) or_return .Error(.NoSpace)
        device :: volume.device
        extent := ExtentRecord.{kind = cast[u32le](cast[u32](ExtentKind.Blocks)), bytes = cast[u32le](cast[u32](used))}
        extent.pointer = BlockPointer.{address = cast[u64le](address), birth = cast[u64le](nodes.transaction),
            blocks = cast[u32le](cast[u32](blocks))}
        // Encrypted, what's written is sealed, and the pointer takes its seal and generation
        written := part(buffer, 0, length)
        sealed : ptr[mut ChunkBuffer]? = null
        match volume.tree.keys {
            case Some(keys) => {
                made :: match make(ChunkBuffer) {
                    case Ok(chunk) => chunk
                    case Error(error) => {
                        nodes.release(nodes.space, address, blocks, volume.id, nodes.transaction)
                        return .Error(error)
                    }
                }
                sealed = made
                if !seal_block(keys, volume.id, &extent.pointer, part(buffer, 0, length), mut_part(made.bytes, 0, length)) {
                    runtime.free(made)
                    nodes.release(nodes.space, address, blocks, volume.id, nodes.transaction)
                    return .Error(.Corrupt)
                }
                written = part(made.bytes, 0, length)
            }
            case None => crypto.blake3(part(buffer, 0, length), extent.pointer.seal)
        }
        wrote :: device.write(device.context, address, blocks, written)
        match sealed {
            case Some(made) => runtime.free(made)
            case None => {}
        }
        if !wrote {
            volume.failed = true
            note_chunk(volume, file, index, true)
            nodes.release(nodes.space, address, blocks, volume.id, nodes.transaction)
            return .Error(.DeviceError)
        }
        note_chunk(volume, file, index, false)
        tree_put(nodes, &volume.tree, key, view_of(cast[ptr[mut u8]](&extent), size_of(ExtentRecord)))?
    }
    if had is_some {
        release_extent(volume, &old)
    }
    return .Ok
}

/**
 * Read the record of an object that has to be a file.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The ID of the object, which has to be a file; one with no record is NotFound.
 * @return The file's record, a copy.
 * @error NotFound No object has the ID.
 * @error IsADirectory It's a directory.
 * @error IsALink It's a stored link.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
file_record :: fn(volume: ptr[mut Volume], object: u64) -> Result[ObjectRecord, Error] {
    record :: get_object(volume, object)?
    kind :: kind_of_record(&record)
    if kind == .Link {
        return .Error(.IsALink)
    }
    if kind != .File {
        return .Error(.IsADirectory)
    }
    return .Ok(record)
}

/**
 * Read bytes of a file. Nothing is changed.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The ID of the file; its record is read first, so one that isn't there, or isn't a file, is
 *     an error.
 * @param offset The byte offset to read from; at or past the file's size, nothing is read.
 * @param into Where the bytes go; at most its count are read.
 * @return How many were read: fewer than into holds only at the file's end, 0 at or past it. Bytes never written
 *     read as zeros.
 * @error NotFound No object has the ID.
 * @error IsADirectory It's a directory.
 * @error IsALink It's a stored link.
 * @error DeviceError A chunk a failed write was for, or one whose blocks couldn't be read.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A chunk's record or seal, or a node, doesn't check out.
 */
read :: fn(volume: ptr[mut Volume], file: u64, offset: u64, into: mut u8[]) -> Result[usize, Error] {
    record :: file_record(volume, file)?
    size :: cast[u64](record.size)
    if offset >= size {
        return .Ok(0)
    }
    end :: if size - offset < cast[u64](into.count) { size } else { offset + cast[u64](into.count) }
    chunk :: make(ChunkBuffer)?
    defer runtime.free(chunk)
    at := offset
    loop {
        index :: at / CHUNK_BYTES
        read_chunk(volume, file, index, chunk.bytes)?
        start :: at - index * CHUNK_BYTES
        stop :: if end < (index + 1) * CHUNK_BYTES { end - index * CHUNK_BYTES } else { CHUNK_BYTES }
        copy_bytes(into, cast[usize](at - offset), part(chunk.bytes, cast[usize](start), cast[usize](stop)))
        at = index * CHUNK_BYTES + stop
    }
    while at < end
    return .Ok(cast[usize](end - offset))
}

/**
 * Write bytes into a file, growing it if they end past its size.
 *
 * Each chunk they touch is written anew, whole; a file past INLINE_BYTES has its first chunk moved out of its record.
 * The file is touched and a Written change noted (one for writes in one transaction). The chunks' blocks are written
 * at once; the records naming them are durable with the volume's next commit, so a crash before it leaves the file
 * as that commit had it.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The ID of the file; its record is read first, so one that isn't there, or isn't a file, is
 *     an error.
 * @param offset The byte offset to write at; past the file's end, the gap reads as zeros.
 * @param from The bytes, copied; none writes nothing but the time and the change.
 * @error NotFound No object has the ID.
 * @error IsADirectory It's a directory.
 * @error IsALink It's a stored link.
 * @error TooLarge The bytes would end past 2^64 - 1.
 * @error NoSpace No free extent, or a quota or the reserve refuses one; chunks written before it stay written.
 * @error DeviceError A chunk couldn't be read or written; the volume is failed after a write fails.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A chunk or a node doesn't check out.
 */
write :: fn(volume: ptr[mut Volume], file: u64, offset: u64, from: u8[]) -> Result[void, Error] {
    record := file_record(volume, file)?
    end :: offset + cast[u64](from.count)
    if end < offset {
        return .Error(.TooLarge)
    }
    size :: if end > cast[u64](record.size) { end } else { cast[u64](record.size) }
    inline :: size <= INLINE_BYTES
    chunk :: make(ChunkBuffer)?
    defer runtime.free(chunk)
    at := offset
    loop {
        index :: at / CHUNK_BYTES
        used := read_chunk(volume, file, index, chunk.bytes)?
        start :: at - index * CHUNK_BYTES
        stop :: if end < (index + 1) * CHUNK_BYTES { end - index * CHUNK_BYTES } else { CHUNK_BYTES }
        copy_bytes(chunk.bytes, cast[usize](start), part(from, cast[usize](at - offset), cast[usize](at - offset + stop - start)))
        if cast[usize](stop) > used {
            used = cast[usize](stop)
        }
        write_chunk(volume, file, index, chunk.bytes, used, inline && index == 0)?
        at = index * CHUNK_BYTES + stop
    }
    while at < end
    // A first chunk held in the record, moved to blocks once the file's past what a record holds
    if !inline {
        move_inline(volume, file, chunk.bytes)?
    }
    record.size = cast[u64le](size)
    touch(volume, file, &record)?
    note_change(volume, .Written, file, cast[u64](record.parent), "")?
    return .Ok
}

/**
 * Move a file's first chunk to blocks, if it's in its record.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The ID of the file; not checked to be one or to be there, so one with no inline first chunk is left
 *     as it is.
 * @param chunk A buffer of CHUNK_BYTES to read it into, overwritten.
 * @error NoSpace No free extent, or a quota or the reserve refuses one.
 * @error DeviceError The chunk couldn't be read or written.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt The chunk or a node doesn't check out.
 */
move_inline :: fn(volume: ptr[mut Volume], file: u64, chunk: mut u8[]) -> Result[void, Error] {
    head := ExtentRecord.{}
    had :: tree_get(volume.nodes, &volume.tree, key_of(file, .Extent, 0), view_of(cast[ptr[mut u8]](&head), size_of(ExtentRecord)))?
    if (had is_none) || cast[u32](head.kind) != cast[u32](ExtentKind.Inline) {
        return .Ok
    }
    used :: read_chunk(volume, file, 0, chunk)?
    return write_chunk(volume, file, 0, chunk, used, false)
}

/**
 * Make a file a size: shorter, the chunks past it dropped and the last one cut, so what's past the end reads as zeros
 * if it grows again; longer, zeros after its end, without writing them.
 *
 * The file is touched and a Written change noted. It's durable with the volume's next commit.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The ID of the file; its record is read first, so one that isn't there, or isn't a file, is
 *     an error.
 * @param size The new size in bytes.
 * @error NotFound No object has the ID.
 * @error IsADirectory It's a directory.
 * @error IsALink It's a stored link.
 * @error NoSpace No free extent for the cut chunk, or a node.
 * @error DeviceError The cut chunk couldn't be read or written.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A chunk or a node doesn't check out.
 */
set_size :: fn(volume: ptr[mut Volume], file: u64, size: u64) -> Result[void, Error] {
    record := file_record(volume, file)?
    old :: cast[u64](record.size)
    if size < old {
        // Its memory before any of the file is cut
        chunk :: make(ChunkBuffer)?
        defer runtime.free(chunk)
        loop {
            extent := ExtentRecord.{}
            found :: tree_next(volume.nodes, &volume.tree, key_of(file, .Extent, size),
                view_of(cast[ptr[mut u8]](&extent), size_of(ExtentRecord)))? or_break
            if found.key.object != file || found.key.kind != cast[u8](RecordKind.Extent) {
                break
            }
            drop_chunk(volume, found.key, &extent)?
        }
        if size % CHUNK_BYTES != 0 {
            index :: size / CHUNK_BYTES
            used := read_chunk(volume, file, index, chunk.bytes)?
            cut :: cast[usize](size - index * CHUNK_BYTES)
            if used > cut {
                for i in cut..<chunk.bytes.count {
                    chunk.bytes[i] = 0
                }
                inline :: is_inline(volume, file)?
                write_chunk(volume, file, index, chunk.bytes, cut, index == 0 && size <= INLINE_BYTES && inline)?
            }
        }
    }
    record.size = cast[u64le](size)
    touch(volume, file, &record)?
    note_change(volume, .Written, file, cast[u64](record.parent), "")?
    return .Ok
}

/**
 * Tell whether a file's first chunk is held in its record.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The ID of the file; not checked to be one or to be there, either of which is false.
 * @return True if its first chunk's record is inline.
 * @error OutOfMemory No memory to read a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
is_inline :: fn(volume: ptr[mut Volume], file: u64) -> Result[bool, Error] {
    head := ExtentRecord.{}
    had :: tree_get(volume.nodes, &volume.tree, key_of(file, .Extent, 0), view_of(cast[ptr[mut u8]](&head), size_of(ExtentRecord)))?
    return .Ok((had is_some) && cast[u32](head.kind) == cast[u32](ExtentKind.Inline))
}

// An encrypted volume's keys, in the container's volumes tree beside its record (keys.hsc).

/**
 * Put one of a volume's key wrap records, durable with the container's next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param index Which wrap, from 0.
 * @param record The record, copied.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
put_wrap :: fn(container: ptr[mut Container], id: u64, index: u64, record: ptr[WrapRecord]) -> Result[void, Error] {
    tree_put(&container.nodes, &container.volumes, key_of(id, .KeyWrap, index), view_of(cast[ptr[u8]](record), size_of(WrapRecord)))?
    return .Ok
}

/**
 * Put one of a volume's key generation records, durable with the container's next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param number The generation's number, from 1.
 * @param record The record, copied.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
put_generation :: fn(container: ptr[mut Container], id: u64, number: u32, record: ptr[GenerationRecord]) -> Result[void, Error] {
    tree_put(&container.nodes, &container.volumes, key_of(id, .KeyGeneration, cast[u64](number)),
        view_of(cast[ptr[u8]](record), size_of(GenerationRecord)))?
    return .Ok
}

/** A generation's record and its number. */
NumberedGeneration :: struct {
    /** The generation's number, from 1. */
    number : u32,
    /** Its record. */
    record : GenerationRecord,
}

/**
 * List a volume's key wrap records, each way its key is wrapped, by index.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param found Where they're added, with context's allocator; the caller's to free, even on an error.
 * @error Corrupt A record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for the list or a node.
 */
volume_wraps :: fn(container: ptr[mut Container], id: u64, found: ptr[mut WrapRecord[..]]) -> Result[void, Error] {
    record := WrapRecord.{}
    at := key_of(id, .KeyWrap, 0)
    loop {
        item :: tree_next(&container.nodes, &container.volumes, at, view_of(cast[ptr[mut u8]](&record), size_of(WrapRecord)))? or_break
        if item.key.object != id || item.key.kind != cast[u8](RecordKind.KeyWrap) {
            break
        }
        if item.bytes != size_of(WrapRecord) {
            return .Error(.Corrupt)
        }
        if runtime.array_try_add(found, record) != null {
            return .Error(.OutOfMemory)
        }
        at = key_after(item.key) or_break
    }
    return .Ok
}

/**
 * List a volume's key generation records, oldest first.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param found Where they're added, with context's allocator; the caller's to free, even on an error.
 * @error Corrupt A record is the wrong size or numbered 0 or past a u32, or a node couldn't be read or didn't
 *     check out.
 * @error OutOfMemory No memory for the list or a node.
 */
volume_generations :: fn(container: ptr[mut Container], id: u64, found: ptr[mut NumberedGeneration[..]]) -> Result[void, Error] {
    record := GenerationRecord.{}
    at := key_of(id, .KeyGeneration, 0)
    loop {
        item :: tree_next(&container.nodes, &container.volumes, at, view_of(cast[ptr[mut u8]](&record), size_of(GenerationRecord)))? or_break
        if item.key.object != id || item.key.kind != cast[u8](RecordKind.KeyGeneration) {
            break
        }
        if item.bytes != size_of(GenerationRecord) || item.key.offset == 0 || item.key.offset > 0xffffffff {
            return .Error(.Corrupt)
        }
        if runtime.array_try_add(found, NumberedGeneration.{number = cast[u32](item.key.offset), record = record}) != null {
            return .Error(.OutOfMemory)
        }
        at = key_after(item.key) or_break
    }
    return .Ok
}

/**
 * Unlock an encrypted volume's keys into new keys: its volume key unwrapped with a passphrase from its wrap records,
 * and each generation's with that.
 *
 * @param container The ID of the container the volume is in, from its superblock, as the wraps and generations
 *     were bound to; any other opens none of them.
 * @param id The volume whose key records they are, its own or a clone's origin's.
 * @param record The volume's record: its cipher and newest generation.
 * @param wraps Its wrap records; the first the passphrase opens is used.
 * @param generations Its generation records.
 * @param passphrase The passphrase, secret.
 * @param keys The keys, new, filled in here; on an error, they're for free_keys, holding what was unwrapped.
 * @error Corrupt The record's cipher isn't one, a generation doesn't open with the volume key, or the record's
 *     newest generation isn't among them.
 * @error WrongKey The passphrase opens none of the wrap records.
 * @error OutOfMemory No memory to keep a generation's key.
 */
unlock :: fn(container: u8[16], id: u64, record: VolumeRecord, wraps: WrapRecord[], generations: NumberedGeneration[],
    passphrase: u8[], keys: ptr[mut Keys]) -> Result[void, Error] {

    cipher :: record.cipher
    if cipher != cast[u8](Cipher.ChaCha20Poly1305) && cipher != cast[u8](Cipher.Aes256Gcm) {
        return .Error(.Corrupt)
    }
    keys.cipher = if cipher == cast[u8](Cipher.Aes256Gcm) { .Aes256Gcm } else { .ChaCha20Poly1305 }
    unwrapped := false
    for wrap in wraps {
        candidate := wrap
        key := unwrap_with_passphrase(&candidate, passphrase, container, id) or_continue
        keys.volume_key = key
        zero_key(&key)
        unwrapped = true
        break
    }
    if !unwrapped {
        return .Error(.WrongKey)
    }
    for each in generations {
        wrapped := each.record
        generation := unwrap_generation(&keys.volume_key, each.number, &wrapped, container, id) or_return .Error(.Corrupt)
        added :: runtime.array_try_add(&keys.generations, generation)
        zero_key(&generation.key)
        if added != null {
            return .Error(.OutOfMemory)
        }
    }
    keys.current = cast[u32](record.generation)
    if generation_key(keys, keys.current) is_none {
        return .Error(.Corrupt)
    }
    return .Ok
}

/**
 * Start a new key generation for an encrypted volume open in the container's own process, sealing what's written
 * from now on; what was written before keeps its own (decisions/0042).
 *
 * It's numbered after the newest of the volume's key records, which a clone shares with its origin, and its record is
 * put with them; the volume's record names it with the volume's next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param volume The volume; its keys gain the generation, current from now on.
 * @return The new generation's number.
 * @error Locked The volume isn't encrypted, so it has no keys.
 * @error NotFound The volume's record isn't there.
 * @error Corrupt The generation couldn't be made, or a record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 */
rotate :: fn(container: ptr[mut Container], volume: ptr[mut Volume]) -> Result[u32, Error] {
    keys :: volume.tree.keys or_return .Error(.Locked)
    committed :: volume_record(container, volume.id)?
    key_owner :: key_owner_of(volume.id, &committed)
    // Numbered after the newest of the key records', which a clone shares with its origin
    newest :: newest_generation(container, key_owner)?
    // What's sealed with until now, restored if the new generation can't be kept, so nothing's sealed with a key no
    // record holds
    previous :: keys.current
    keys.current = newest
    record := match start_generation(keys, container.nodes.transaction, container.id, key_owner) {
        case Some(made) => made
        case None => {
            keys.current = previous
            return .Error(.Corrupt)
        }
    }
    match put_generation(container, key_owner, keys.current, &record) {
        case Ok => {}
        case Error(error) => {
            drop_generation(keys, previous)
            return .Error(error)
        }
    }
    volume.dirty = true
    return .Ok(keys.current)
}

/**
 * Find the newest generation in a volume's key records.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param key_owner The ID of the volume whose key records they are.
 * @return Its number; 0 if there are none.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for the list or a node.
 */
newest_generation :: fn(container: ptr[mut Container], key_owner: u64) -> Result[u32, Error] {
    generations : NumberedGeneration[..]
    defer runtime.array_free(&generations)
    volume_generations(container, key_owner, &generations)?
    newest : u32 = 0
    for each in generations {
        if each.number > newest {
            newest = each.number
        }
    }
    return .Ok(newest)
}

/**
 * Read one of a volume's key wrap records.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param index Which, from 0.
 * @return The record; null if there's none of the index.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
volume_wrap :: fn(container: ptr[mut Container], id: u64, index: u64) -> Result[WrapRecord?, Error] {
    record := WrapRecord.{}
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .KeyWrap, index),
        view_of(cast[ptr[mut u8]](&record), size_of(WrapRecord)))? or_return .Ok(null)
    if bytes != size_of(WrapRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

/**
 * Read one of a volume's key generation records.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param number The generation's number, from 1.
 * @return The record; null if there's none of the number.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
volume_generation :: fn(container: ptr[mut Container], id: u64, number: u32) -> Result[GenerationRecord?, Error] {
    record := GenerationRecord.{}
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .KeyGeneration, cast[u64](number)),
        view_of(cast[ptr[mut u8]](&record), size_of(GenerationRecord)))? or_return .Ok(null)
    if bytes != size_of(GenerationRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

/**
 * Keep a new key generation's record, made by the volume's server, with an encrypted volume's key records (a clone's
 * origin's, for a clone), and name it in the volume's record. Both are durable with the next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume, whose record names the generation; it's read, so one that isn't there is
 *     NotFound, and the generation is kept with its key owner's records.
 * @param number The generation's number, which has to be one after the newest in its key records.
 * @param generation The generation's record, copied.
 * @error NotFound The volume isn't there, isn't encrypted, or the number isn't the next.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 */
add_generation :: fn(container: ptr[mut Container], id: u64, number: u32, generation: ptr[GenerationRecord]) -> Result[void, Error] {
    record := volume_record(container, id)?
    key_owner :: key_owner_of(id, &record)
    if record.cipher == cast[u8](Cipher.None) || number != newest_generation(container, key_owner)? + 1 {
        return .Error(.NotFound)
    }
    put_generation(container, key_owner, number, generation)?
    record.generation = cast[u32le](number)
    put_volume_record(container, id, &record)?
    return .Ok
}

// A new volume key, its floor and the generations it outlives (keys.hsc, reseal.hsc, decisions/0181's F5)

/**
 * Read the first of a volume's key generation records numbered at least a number, so its generations are listed
 * across the gaps deleting old ones leaves.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @param number The least number wanted, from 1.
 * @return The generation and its number; null if there's none at or past number.
 * @error Corrupt A record is the wrong size or numbered past a u32, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
generation_from :: fn(container: ptr[mut Container], id: u64, number: u32) -> Result[NumberedGeneration?, Error] {
    record := GenerationRecord.{}
    item :: tree_next(&container.nodes, &container.volumes, key_of(id, .KeyGeneration, cast[u64](number)),
        view_of(cast[ptr[mut u8]](&record), size_of(GenerationRecord)))? or_return .Ok(null)
    if item.key.object != id || item.key.kind != cast[u8](RecordKind.KeyGeneration) {
        return .Ok(null)
    }
    if item.bytes != size_of(GenerationRecord) || item.key.offset == 0 || item.key.offset > 0xffffffff {
        return .Error(.Corrupt)
    }
    return .Ok(NumberedGeneration.{number = cast[u32](item.key.offset), record = record})
}

/**
 * Read a volume's key floor.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @return Its floor; null if it has none: it's kept its first volume key, or deleted what its floor outlived.
 * @error Corrupt The record is the wrong size, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory to read a node.
 */
key_floor :: fn(container: ptr[mut Container], id: u64) -> Result[KeyFloorRecord?, Error] {
    record := KeyFloorRecord.{}
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .KeyFloor, 0),
        view_of(cast[ptr[mut u8]](&record), size_of(KeyFloorRecord)))? or_return .Ok(null)
    if bytes != size_of(KeyFloorRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

/**
 * Keep a volume's keys made again under a new volume key (keys.hsc's rekey) in place of its key records: every wrap
 * deleted and the new one kept, every generation's record replaced by its new one, the new generation added, named
 * in the volume's record, and its floor kept, Sealing. All durable together with the next commit, so a crash leaves
 * the old records or the new, never some of each.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume, an encrypted one whose key records are its own (not a clone).
 * @param wrap The new volume key's wrap, kept at index 0.
 * @param generations Every generation the volume's records hold, wrapped again, exactly those numbers.
 * @param number The new generation's number, the one after the newest.
 * @param added The new generation's record.
 * @error NotFound The volume isn't there, isn't encrypted, is a clone, or generations or number don't match its records.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 */
replace_keys :: fn(container: ptr[mut Container], id: u64, wrap: ptr[WrapRecord], generations: NumberedGeneration[], number: u32,
    added: ptr[GenerationRecord]) -> Result[void, Error] {

    record := volume_record(container, id)?
    if record.cipher == cast[u8](Cipher.None) || key_owner_of(id, &record) != id {
        return .Error(.NotFound)
    }
    // Every generation there is, and only those, so none is left wrapped by the old volume key
    existing : NumberedGeneration[..]
    defer runtime.array_free(&existing)
    volume_generations(container, id, &existing)?
    if existing.count != generations.count {
        return .Error(.NotFound)
    }
    newest : u32 = 0
    for each in existing {
        matched := false
        for given in generations {
            if given.number == each.number {
                matched = true
            }
        }
        if !matched {
            return .Error(.NotFound)
        }
        if each.number > newest {
            newest = each.number
        }
    }
    if number != newest + 1 {
        return .Error(.NotFound)
    }
    // Every wrap there was goes: none of them opens the new volume key
    wraps : WrapRecord[..]
    defer runtime.array_free(&wraps)
    volume_wraps(container, id, &wraps)?
    for i in 0..<wraps.count {
        _ = tree_delete(&container.nodes, &container.volumes, key_of(id, .KeyWrap, cast[u64](i)))?
    }
    put_wrap(container, id, 0, wrap)?
    for each in generations {
        kept := each.record
        put_generation(container, id, each.number, &kept)?
    }
    put_generation(container, id, number, added)?
    record.generation = cast[u32le](number)
    put_volume_record(container, id, &record)?
    floor := KeyFloorRecord.{floor = cast[u32le](number), state = cast[u32le](cast[u32](FloorState.Sealing))}
    tree_put(&container.nodes, &container.volumes, key_of(id, .KeyFloor, 0), view_of(cast[ptr[u8]](&floor), size_of(KeyFloorRecord)))?
    return .Ok
}

/**
 * Say a volume's live tree is sealed with its floor or later, as its server's sealing again found once it was
 * committed: its floor Sealed, as of the container's last durable transaction, durable with the next commit.
 *
 * @param container The container, mounted, the volume's last step of sealing again committed.
 * @param id The ID of the volume whose key records they are.
 * @param floor The floor it was sealed again to, which has to be its record's, still Sealing.
 * @return True once it's Sealed; false if it has no floor, another, or one Sealed already.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 * @error NoSpace No free extent for a node.
 */
sealed_again :: fn(container: ptr[mut Container], id: u64, floor: u32) -> Result[bool, Error] {
    record := key_floor(container, id)? or_return .Ok(false)
    if cast[u32](record.floor) != floor || cast[u32](record.state) != cast[u32](FloorState.Sealing) {
        return .Ok(false)
    }
    record.state = cast[u32le](cast[u32](FloorState.Sealed))
    // The volume's last commit, durable before this, is at or before the container's last
    record.sealed = cast[u64le](if container.nodes.transaction > 0 { container.nodes.transaction - 1 } else { cast[u64](0) })
    tree_put(&container.nodes, &container.volumes, key_of(id, .KeyFloor, 0), view_of(cast[ptr[u8]](&record), size_of(KeyFloorRecord)))?
    return .Ok(true)
}

/**
 * Delete the key generations a volume's floor outlived, once nothing the volume reads can need them: its live tree
 * sealed again, no snapshot of it older than that, and no clone of it, which reads its blocks as they were. Its floor
 * goes with them. Durable with the next commit.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The ID of the volume whose key records they are.
 * @return The floor, once the generations before it are deleted, for the volume's keys to forget them too; null if
 *     there's no floor, it isn't Sealed, or a snapshot or a clone may still need them, nothing changed.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 */
drop_old_generations :: fn(container: ptr[mut Container], id: u64) -> Result[u32?, Error] {
    floor :: key_floor(container, id)? or_return .Ok(null)
    if cast[u32](floor.state) != cast[u32](FloorState.Sealed) {
        return .Ok(null)
    }
    // A snapshot taken before the tree was sealed again may hold blocks sealed with what would go
    snapshots : NumberedSnapshot[..]
    defer runtime.array_free(&snapshots)
    snapshot_records(container, id, &snapshots)?
    for each in snapshots {
        if cast[u64](each.record.transaction) < cast[u64](floor.sealed) {
            return .Ok(null)
        }
    }
    // A clone reads its origin's blocks as they were when it was made
    at := cast[u64](1)
    loop {
        other :: next_volume_id(container, at)? or_break
        if other != id {
            match volume_record(container, other) {
                case Ok(record) => if cast[u64](record.key_owner) == id {
                    return .Ok(null)
                }
                case Error(error) => {}
            }
        }
        at = other + 1
    }
    generations : NumberedGeneration[..]
    defer runtime.array_free(&generations)
    volume_generations(container, id, &generations)?
    for each in generations {
        if each.number < cast[u32](floor.floor) {
            _ = tree_delete(&container.nodes, &container.volumes, key_of(id, .KeyGeneration, cast[u64](each.number)))?
        }
    }
    _ = tree_delete(&container.nodes, &container.volumes, key_of(id, .KeyFloor, 0))?
    return .Ok(cast[u32](floor.floor))
}

/**
 * Give an encrypted volume open in the container's own process a new volume key, wrapped by a new passphrase, as its
 * server does (decisions/0181's F5): its keys made again, its records replaced, and its keys taking them; what's
 * written from now on is sealed with the new generation, its floor, and what was written before is sealed again by
 * reseal_step.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param volume The volume, unlocked, its key records its own; its keys take the new volume key and generation.
 * @param passphrase The new passphrase, secret; the old one opens it no more once this is committed.
 * @param parameters Argon2id's parameters for it.
 * @return The new generation's number, its floor.
 * @error Locked The volume isn't encrypted.
 * @error NotFound The volume's record isn't there, or it's a clone.
 * @error Corrupt The keys couldn't be made again, or a record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a list or a node.
 * @error NoSpace No free extent for a node.
 */
rekey_volume :: fn(container: ptr[mut Container], volume: ptr[mut Volume], passphrase: u8[], parameters: crypto.Argon2Parameters) -> Result[u32, Error] {
    keys :: volume.tree.keys or_return .Error(.Locked)
    generations : NumberedGeneration[..]
    defer runtime.array_free(&generations)
    volume_generations(container, volume.id, &generations)?
    made := Rekeyed.{}
    defer free_rekeyed(&made)
    if !rekey(keys, generations, passphrase, parameters, container.nodes.transaction, container.id, volume.id, &made) {
        return .Error(.Corrupt)
    }
    replace_keys(container, volume.id, &made.wrap, made.generations, made.added.number, &made.record)?
    apply_rekey(keys, &made)
    volume.dirty = true
    return .Ok(made.added.number)
}
