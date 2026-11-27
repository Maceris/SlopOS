package slopfs

import runtime from "base:runtime"
import schema from "std:schema"

/*
 * A volume's indexes (decisions/0201's 20i): each one a typed file's field, declared by its schema and the field's
 * name, kept in the volume's own tree beside what it indexes, so a commit makes a file's change and its index's
 * together, forget undoes both, and a snapshot or a clone has the indexes its tree had.
 *
 * An index's records: its declaration, (0, IndexDecl, number); each value's bucket, (INDEX_OBJECT_BASE | number,
 * IndexEntry, key), the files whose value has that key, up to BUCKET_FILES of them in order of ID, so a walk can go on
 * from the last one it answered whatever's taken out meanwhile, each one past those spilled to a record of its own,
 * (INDEX_OBJECT_BASE | number, IndexSpill, file); and for each file indexed, (file, IndexedBy,
 * number), its key and a text's bytes, so the file's old entry is found when it changes, and a query's predicate is
 * evaluated without reading the file. A key orders as the value does: an unsigned integer as it is, a signed one with
 * its sign bit flipped, a bool as 0 or 1, and a text by its first 8 bytes, big-endian, zeros after its end.
 *
 * Every object a transaction changes is noted (note_indexed), and at commit, before the tree is written, each one is
 * indexed again (index_changes): its old entries taken out, and if it's still a file with a name, of a schema an
 * index is declared for, whose value holds every indexed field, its new ones put in. A file whose value doesn't hold
 * one, as a typed file emptied and not yet written again does, isn't indexed until it does. An object destroyed is
 * taken out of every index then and there (destroy), so one gone is never left in a bucket, however many changed.
 */

/** The bit an index's own records' object has, so they're kept apart from, and after, every object's. */
INDEX_OBJECT_BASE : u64 : 1 << 63
/** The most indexes a volume has: they're numbered 1 to this. */
MAX_INDEXES : u64 : 64
/** The most bytes in an indexed field's name. */
INDEX_FIELD_BYTES :: 64
/** The most bytes of a text value an index keeps, and a query compares: the rest of a longer one isn't seen. */
INDEX_TEXT_BYTES :: 255
/** The most files a bucket names, MAX_VALUE_BYTES of their IDs; a file past them is spilled to a record of its own. */
BUCKET_FILES :: 512
/**
 * The most objects noted changed between commits; past them, every file is indexed again at commit, those destroyed
 * having been taken out of the indexes as they were.
 */
MAX_CHANGED :: 1024

/** What an indexed field holds, and so how its key is made. */
FieldKind :: enum #backed_by(u32) {
    /** An unsigned integer of 1, 2, 4 or 8 bytes: its key is its value. */
    Unsigned = 1,
    /** A signed integer of 1, 2, 4 or 8 bytes: its key is its value, sign-extended, with its sign bit flipped. */
    Signed = 2,
    /** A bool, one byte of 0 or 1: its key is that. */
    Bool = 3,
    /** Text, a Relative of bytes from the value's start: its key is its first 8 bytes, big-endian. */
    Text = 4,
}

/** An index's declaration, keyed (0, IndexDecl, number), little-endian. */
IndexRecord :: struct #packed {
    /** The schema hash of the files it indexes: a typed file's ObjectRecord.schema. */
    schema : u8[32],
    /** The field's offset in bytes from the value's start. */
    offset : u32le,
    /** The field's size in bytes: 1, 2, 4 or 8 for an integer, 1 for a bool, 8 for a text's Relative. */
    size : u32le,
    /** The field's FieldKind. */
    kind : u32le,
    /** The size in bytes of the value's fixed part, its root struct's: a value smaller isn't one, and isn't indexed. */
    fixed : u32le,
    /** 1 for an integer stored big-endian; 0 for one little-endian (or native, little on every SlopOS machine). */
    big_endian : u8,
    /** Reserved; zero. */
    reserved : u8,
    /** How many of field's bytes are the field's name, 1 to INDEX_FIELD_BYTES. */
    field_bytes : u16le,
    /** The field's name, UTF-8, its first field_bytes used. */
    field : u8[INDEX_FIELD_BYTES],
    /** Reserved; zero. */
    reserved1 : u32le,
}

#assert size_of(IndexRecord) == 120

/** A file's record of an index it's in, keyed (file, IndexedBy, number), little-endian; a text's bytes follow it. */
IndexedRecord :: struct #packed {
    /** The file's key in the index. */
    key : u64le,
    /** 1 if the file's in a record of its own, its bucket being full; 0 if it's in its key's bucket. */
    spilled : u8,
    /** Reserved; zero. */
    reserved : u8,
    /** How many bytes of a text value follow, 0 to INDEX_TEXT_BYTES; 0 for any other kind. */
    text_bytes : u16le,
    /** Reserved; zero. */
    reserved1 : u32le,
}

#assert size_of(IndexedRecord) == 16

/**
 * The objects changed since a volume's last commit, to index again when it next commits: a set, each object once.
 *
 * It's the volume's own (Volume.indexing), and forget empties it with what it forgets.
 */
Indexing :: struct {
    /** The objects noted, the first count of them. */
    changed : u64[MAX_CHANGED],
    /** How many of changed are noted. */
    count #at_most(changed.count) : usize,
    /** More than MAX_CHANGED were noted, so some weren't kept: every file is indexed again at commit. */
    overflowed : bool,
    /** A directory was moved since the last commit, so what's beneath it may now be beneath another. */
    moved : bool,
}

/** An index's declaration, with its number. */
NumberedIndex :: struct {
    /** Its number, 1 to MAX_INDEXES. */
    number : u64,
    /** Its declaration, a copy. */
    record : IndexRecord,
}

/** Every index a volume declares, read at once; from make. */
IndexSet :: struct {
    /** Each index, the first count of them, by number. */
    indexes : NumberedIndex[MAX_INDEXES],
    /** How many of indexes are read, 0 to MAX_INDEXES. */
    count : usize,
}

/** A field's key in a file's value, and a text's bytes, as they're kept for it. */
Keyed :: struct {
    /** The key, which orders as the value does. */
    key : u64,
    /** How many of text's bytes are the text's, 0 to INDEX_TEXT_BYTES; 0 for a field that isn't text. */
    text_bytes : usize,
    /** A text's first bytes. */
    text : u8[INDEX_TEXT_BYTES],
}

/** A bucket's file IDs, as its record holds them; from make. */
Bucket :: struct {
    /** The files, the first count of them, in order of ID, least first, each once. */
    files : u64le[BUCKET_FILES],
    /** How many of files are used, 0 to BUCKET_FILES. */
    count : usize,
}

/** A file's record of an index, with a text's bytes after it, as it's read; from make. */
IndexedValue :: struct {
    /** The record and what follows it, as stored. */
    bytes : u8[INDEXED_VALUE_BYTES],
}

/** The most bytes of a file's record of an index: its IndexedRecord and INDEX_TEXT_BYTES of text. */
INDEXED_VALUE_BYTES :: 271

#assert INDEXED_VALUE_BYTES == size_of(IndexedRecord) + INDEX_TEXT_BYTES

// Noting changes

/**
 * Note that an object changed, so its index entries are made again at the volume's next commit.
 *
 * Noting it twice keeps it once; past MAX_CHANGED objects, the volume is marked to index every file again instead.
 *
 * @param volume The volume whose indexing notes it.
 * @param object The object's ID; one that's gone by the commit has its entries taken out.
 */
note_indexed :: fn(volume : ptr[mut Volume], object : u64) {
    indexing :: &volume.indexing
    for i in 0..<indexing.count {
        if i < indexing.changed.count && indexing.changed[i] == object {
            return void
        }
    }
    count :: indexing.count
    if count < indexing.changed.count {
        indexing.changed[count] = object
        indexing.count = count + 1
        return void
    }
    indexing.overflowed = true
}

/**
 * Forget every change noted, as forget does with the changes themselves.
 *
 * @param volume The volume, whose indexing is emptied.
 */
forget_indexed :: fn(volume : ptr[mut Volume]) {
    volume.indexing.count = 0
    volume.indexing.overflowed = false
    volume.indexing.moved = false
}

/**
 * Index again every object changed since the last commit, as write_volume does before it writes the tree: each one's
 * old entries taken out and its new ones put in, or every file's, if more changed than were kept.
 *
 * The objects noted are forgotten once it's done; on an error, they're kept, so a later call does them again, and
 * what's half done is either finished then or forgotten with the rest of the transaction.
 *
 * @param volume The volume, whose indexes change with it in its transaction.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error NoSpace No free extent for a node.
 * @error DeviceError A changed file's value couldn't be read, so its entries couldn't be made.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
index_changes :: fn(volume : ptr[mut Volume]) -> Result[void, Error] {
    if volume.indexing.count == 0 && !volume.indexing.overflowed {
        return .Ok
    }
    set :: make(IndexSet)?
    defer runtime.free(set)
    read_indexes(volume, set)?
    if set.count != 0 {
        if volume.indexing.overflowed {
            at := cast[u64](1)
            loop {
                object :: next_object_from(volume, at)? or_break
                reindex(volume, set, object)?
                at = object + 1
            }
        }
        else {
            for i in 0..<volume.indexing.count {
                if i < volume.indexing.changed.count {
                    reindex(volume, set, volume.indexing.changed[i])?
                }
            }
        }
    }
    volume.indexing.count = 0
    volume.indexing.overflowed = false
    volume.indexing.moved = false
    return .Ok
}

// Declaring

/**
 * Declare an index of a typed file's field, and build it from every file of its schema there is now; durable with the
 * volume's next commit.
 *
 * The schema is read from its bytes and its hash worked out from them (schema.hash_rooted), so the index is of the
 * files whose schema hash that is, laid out as the bytes say. Declaring one there is already gives its number again.
 *
 * Building it walks every object of the volume, and indexes each one of the schema again by every index of it, all
 * in this call: a file that doesn't hold the new index's field drops out of the schema's other indexes too, as a file
 * is in all of its schema's indexes or none.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param schema_bytes A schema's bytes, as schema.write writes them, of a struct; only read, and not kept.
 * @param field The name of one of the struct's own members: an integer of 1 to 8 bytes, signed or not, a bool, or
 *     text, a Relative of bytes.
 * @return The index's number, 1 to MAX_INDEXES.
 * @error NotIndexable The bytes aren't a schema, its type isn't a struct, it has no member of the name, or the
 *     member's of a type an index can't hold; or the name's empty or past INDEX_FIELD_BYTES.
 * @error TooLarge The volume has MAX_INDEXES already.
 * @error OutOfMemory No memory for a buffer or a node, or for working out the schema's hash; the schema's own reading
 *     fails context.assertion_handler.
 * @error DeviceError A file of the schema couldn't be read.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
declare_index :: fn(volume : ptr[mut Volume], schema_bytes : u8[], field : string) -> Result[u64, Error] {
    if field.count == 0 || field.count > INDEX_FIELD_BYTES {
        return .Error(.NotIndexable)
    }
    record := field_of(schema_bytes, field)?
    set :: make(IndexSet)?
    defer runtime.free(set)
    read_indexes(volume, set)?
    used : bool[MAX_INDEXES]
    for i in 0..<set.count {
        if i >= set.indexes.count {
            break
        }
        each :: &set.indexes[i]
        if each.record.schema == record.schema && same_field(&each.record, field) {
            return .Ok(each.number)
        }
        slot :: cast[usize](each.number - 1)
        if slot < used.count {
            used[slot] = true
        }
    }
    number := cast[u64](0)
    for taken, i in used {
        if !taken {
            number = cast[u64](i) + 1
            break
        }
    }
    taken :: set.count
    if number == 0 || taken >= set.indexes.count {
        return .Error(.TooLarge)
    }
    tree_put(
        volume.nodes,
        &volume.tree,
        key_of(0, .IndexDecl, number),
        view_of(cast[ptr[u8]](&record), size_of(IndexRecord))
    )?
    volume.dirty = true
    // Built from what's there: every file of its schema indexed again, by every index of it
    set.indexes[taken] = NumberedIndex.{number = number, record = record}
    set.count = taken + 1
    at := cast[u64](1)
    loop {
        object :: next_object_from(volume, at)? or_break
        at = object + 1
        found :: get_object(volume, object)?
        if found.schema == record.schema {
            reindex(volume, set, object)?
        }
    }
    return .Ok(number)
}

/**
 * Read a schema's bytes, and make the declaration of an index of one of its root struct's fields.
 *
 * @param schema_bytes The schema's bytes; only read, and not kept.
 * @param field The member's name, 1 to INDEX_FIELD_BYTES bytes.
 * @return The declaration: the schema's hash, and the field's offset, size, kind and name.
 * @error NotIndexable The bytes aren't a schema, its type isn't a struct, it has no member of the name, or the
 *     member's of a type an index can't hold, or doesn't fit in the struct.
 * @error OutOfMemory The schema's hash couldn't be worked out, which hash_rooted gives as all zeros.
 */
field_of :: fn(schema_bytes : u8[], field : string) -> Result[IndexRecord, Error] {
    parsed := schema.parse(schema_bytes) or_return .Error(.NotIndexable)
    defer schema.free(&parsed)
    root :: schema.type_in(&parsed, schema.unaliased_place(&parsed, 0)) or_return .Error(.NotIndexable)
    if root.kind != .Struct || root.is_union {
        return .Error(.NotIndexable)
    }
    for member in root.members {
        if member.name != field {
            continue
        }
        type :: schema.type_in(&parsed, schema.unaliased_place(&parsed, member.type)) or_return .Error(.NotIndexable)
        record := IndexRecord.{
            schema = schema.hash_rooted(&parsed, 0),
            offset = cast[u32le](cast[u32](member.offset)),
            fixed = cast[u32le](cast[u32](root.size)),
            field_bytes = cast[u16le](cast[u16](field.count)),
        }
        copy_bytes(record.field, 0, string_bytes(field))
        size := cast[u64](0)
        if type.kind == .Integer && (type.size == 1 || type.size == 2 || type.size == 4 || type.size == 8) {
            record.kind = cast[u32le](cast[u32](if type.is_signed { FieldKind.Signed } else { FieldKind.Unsigned }))
            record.big_endian = if type.endianness == 2 { cast[u8](1) } else { cast[u8](0) }
            size = type.size
        }
        else if type.kind == .Boolean && type.size == 1 {
            record.kind = cast[u32le](cast[u32](FieldKind.Bool))
            size = 1
        }
        else if is_text(&parsed, type) {
            record.kind = cast[u32le](cast[u32](FieldKind.Text))
            size = 8
        }
        else {
            return .Error(.NotIndexable)
        }
        if member.offset + size > root.size || root.size > 0xffffffff {
            return .Error(.NotIndexable)
        }
        record.size = cast[u32le](cast[u32](size))
        // An untyped file's hash is all zeros, as hash_rooted's is when it hasn't the memory to write the schema
        if all_zero(record.schema) {
            return .Error(.OutOfMemory)
        }
        return .Ok(record)
    }
    return .Error(.NotIndexable)
}

/**
 * Tell whether a schema's type is text as a typed file holds it: a Relative of bytes, its offset and count each a
 * 4-byte integer at 0 and 4, its elements bytes or one-byte characters.
 *
 * @param parsed The schema the type is one of, only read.
 * @param type The type, a struct as a Relative is.
 * @return Whether it's a struct named Relative[...] of 8 bytes laid out so, of one-byte elements.
 */
is_text :: fn(parsed : ptr[schema.Schema], type : ptr[schema.Type]) -> bool {
    if type.kind != .Struct || type.size != 8 || !starts_with_bytes(type.name, "Relative[") {
        return false
    }
    offset_holds := false
    count_holds := false
    elements_hold := false
    for member in type.members {
        held :: schema.type_in(parsed, schema.unaliased_place(parsed, member.type)) or_return false
        if member.name == "offset" {
            offset_holds = member.offset == 0 && held.kind == .Integer && held.size == 4
        }
        else if member.name == "count" {
            count_holds = member.offset == 4 && held.kind == .Integer && held.size == 4
        }
        else if member.name == "elements" && held.kind == .Array {
            element :: schema.type_in(parsed, schema.unaliased_place(parsed, held.base)) or_return false
            elements_hold = (element.kind == .Integer || element.kind == .Char) && element.size == 1
        }
    }
    return offset_holds && count_holds && elements_hold
}

/**
 * Tell whether text starts with a prefix, byte for byte.
 *
 * @param text The text looked at.
 * @param prefix The prefix looked for.
 * @return True if text is at least as long and its first bytes are prefix's.
 */
starts_with_bytes :: fn(text : string, prefix : string) -> bool {
    if text.count < prefix.count {
        return false
    }
    for i in 0..<prefix.count {
        if i < text.count && text[i] != prefix[i] {
            return false
        }
    }
    return true
}

/**
 * Tell whether a declaration is of a field of a name.
 *
 * @param record The declaration, only read; a field_bytes past its field is taken as its whole field.
 * @param field The name.
 * @return Whether its name's bytes are field's.
 */
same_field :: fn(record : ptr[IndexRecord], field : string) -> bool {
    count :: cast[usize](cast[u16](record.field_bytes))
    if count != field.count || count > record.field.count {
        return false
    }
    return same_bytes(record.field[0..<count], field)
}

/**
 * Take an index out: its declaration, every bucket and spilled entry, and every file's record of it; durable with the
 * volume's next commit. Its number may be given to the next index declared.
 *
 * Every file of its schema is then indexed again by the schema's other indexes, all in this call, as one that didn't
 * hold the dropped index's field was in none of them and may now be in all.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param number The index's number.
 * @error NotFound No index has the number.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error NoSpace No free extent for a node's copy.
 * @error DeviceError A file of the schema couldn't be read.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
drop_index :: fn(volume : ptr[mut Volume], number : u64) -> Result[void, Error] {
    dropped :: index_record(volume, number)? or_return .Error(.NotFound)
    if !(tree_delete(volume.nodes, &volume.tree, key_of(0, .IndexDecl, number))?) {
        return .Error(.NotFound)
    }
    volume.dirty = true
    bucket :: make(Bucket)?
    defer runtime.free(bucket)
    object :: INDEX_OBJECT_BASE | number
    loop {
        found :: tree_next(volume.nodes, &volume.tree, key_of(object, .IndexEntry, 0), bucket_bytes(bucket))? or_break
        if found.key.object != object || found.key.kind != cast[u8](RecordKind.IndexEntry) {
            break
        }
        bucket.count = files_in(found.bytes)?
        for each, i in bucket.files {
            if i < bucket.count {
                _ = tree_delete(volume.nodes, &volume.tree, key_of(cast[u64](each), .IndexedBy, number))?
            }
        }
        if !(tree_delete(volume.nodes, &volume.tree, found.key)?) {
            return .Error(.Corrupt)
        }
    }
    value : u8[8]
    loop {
        found :: tree_next(volume.nodes, &volume.tree, key_of(object, .IndexSpill, 0), value)? or_break
        if found.key.object != object || found.key.kind != cast[u8](RecordKind.IndexSpill) {
            break
        }
        _ = tree_delete(volume.nodes, &volume.tree, key_of(found.key.offset, .IndexedBy, number))?
        if !(tree_delete(volume.nodes, &volume.tree, found.key)?) {
            return .Error(.Corrupt)
        }
    }
    // What the dropped field kept out of the schema's other indexes, put back in them
    set :: make(IndexSet)?
    defer runtime.free(set)
    read_indexes(volume, set)?
    of_schema := false
    for i in 0..<set.count {
        if i < set.indexes.count && set.indexes[i].record.schema == dropped.schema {
            of_schema = true
        }
    }
    if !of_schema {
        return .Ok
    }
    at := cast[u64](1)
    loop {
        object :: next_object_from(volume, at)? or_break
        at = object + 1
        found :: get_object(volume, object)?
        if found.schema == dropped.schema {
            reindex(volume, set, object)?
        }
    }
    return .Ok
}

/**
 * Find the index at or after a number, for listing them in order.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param from The least number it may have; 0 or 1 for the first.
 * @return The index and its declaration; null past the last.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A declaration isn't one, or a node couldn't be read or didn't check out.
 */
next_index :: fn(volume : ptr[mut Volume], from : u64) -> Result[NumberedIndex?, Error] {
    found := NumberedIndex.{}
    at :: tree_next(
        volume.nodes,
        &volume.tree,
        key_of(0, .IndexDecl, from),
        view_of(cast[ptr[mut u8]](&found.record), size_of(IndexRecord))
    )? or_return .Ok(null)
    if at.key.object != 0 || at.key.kind != cast[u8](RecordKind.IndexDecl) {
        return .Ok(null)
    }
    if at.bytes != size_of(IndexRecord) {
        return .Error(.Corrupt)
    }
    found.number = at.key.offset
    return .Ok(found)
}

/**
 * Read an index's declaration.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param number The index's number.
 * @return Its declaration, a copy; null if no index has the number.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt The declaration isn't one, or a node couldn't be read or didn't check out.
 */
index_record :: fn(volume : ptr[mut Volume], number : u64) -> Result[IndexRecord?, Error] {
    record := IndexRecord.{}
    bytes :: tree_get(
        volume.nodes,
        &volume.tree,
        key_of(0, .IndexDecl, number),
        view_of(cast[ptr[mut u8]](&record), size_of(IndexRecord))
    )? or_return .Ok(null)
    if bytes != size_of(IndexRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

/**
 * Read every index a volume declares.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param set Where they go, in order of number; its count is how many, at most MAX_INDEXES.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A declaration isn't one, or a node couldn't be read or didn't check out.
 */
read_indexes :: fn(volume : ptr[mut Volume], set : ptr[mut IndexSet]) -> Result[void, Error] {
    set.count = 0
    from := cast[u64](1)
    loop {
        count :: set.count
        if count >= set.indexes.count {
            break
        }
        found :: next_index(volume, from)? or_break
        set.indexes[count] = found
        set.count = count + 1
        from = found.number + 1
    }
    return .Ok
}

// Each file's entries

/**
 * Find the first object at or after an ID, by its record, for walking every object in order.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param from The least ID it may have.
 * @return Its ID; null past the last, which is before INDEX_OBJECT_BASE.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
next_object_from :: fn(volume : ptr[mut Volume], from : u64) -> Result[u64?, Error] {
    value : u8[1]
    at := from
    loop {
        if at >= INDEX_OBJECT_BASE {
            return .Ok(null)
        }
        found :: tree_next(volume.nodes, &volume.tree, key_of(at, .Object, 0), value)? or_return .Ok(null)
        object :: found.key.object
        if object >= INDEX_OBJECT_BASE {
            return .Ok(null)
        }
        if found.key.kind == cast[u8](RecordKind.Object) {
            return .Ok(object)
        }
        // A later object's other record, looked at again for its own; or this one's after it, so on to the next
        at = if object > at { object } else { object + 1 }
    }
}

/**
 * Index an object again: its old entries, if it has any, taken out, and its new ones put in, by every index of its
 * schema, if it's a file with a name whose value holds every one's field; otherwise by none.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param set Every index the volume declares.
 * @param object The object's ID; one that isn't there only has its old entries taken out.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error NoSpace No free extent for a node.
 * @error DeviceError Its value couldn't be read; its old entries are out, its new ones not yet in.
 * @error Corrupt A record or a node couldn't be read or didn't check out, or its value's chunks don't.
 */
reindex :: fn(volume : ptr[mut Volume], set : ptr[IndexSet], object : u64) -> Result[void, Error] {
    unindex(volume, object)?
    record := ObjectRecord.{}
    match get_object(volume, object) {
        case Ok(found) => record = found
        case Error(error) => {
            if error == .NotFound {
                return .Ok
            }
            return .Error(error)
        }
    }
    if kind_of_record(&record) != .File || all_zero(record.schema) || (is_orphan(volume, object)?) {
        return .Ok
    }
    keyed :: make(Keyed)?
    defer runtime.free(keyed)
    // Every field first, so the file is in all of its schema's indexes or none
    for i in 0..<set.count {
        if i < set.indexes.count && set.indexes[i].record.schema == record.schema {
            if !(key_in(volume, object, &record, &set.indexes[i].record, keyed)?) {
                return .Ok
            }
        }
    }
    for i in 0..<set.count {
        if i < set.indexes.count && set.indexes[i].record.schema == record.schema {
            if key_in(volume, object, &record, &set.indexes[i].record, keyed)? {
                enter(volume, set.indexes[i].number, object, keyed)?
            }
        }
    }
    return .Ok
}

/**
 * Tell whether 32 bytes are all zero, as an untyped file's schema hash is.
 *
 * @param bytes The bytes.
 * @return True if every one is 0.
 */
all_zero :: fn(bytes : u8[32]) -> bool {
    for byte in bytes {
        if byte != 0 {
            return false
        }
    }
    return true
}

/**
 * Work out a field's key in a typed file's value, and a text's first bytes.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The file's ID.
 * @param record The file's record, whose size bounds what's read.
 * @param index The index's declaration: where the field is, and what it holds.
 * @param into Where the key and a text's bytes go; left as it was if the field doesn't hold.
 * @return True if the value holds the field: at least its fixed part, the field within it, a bool of 0 or 1, a
 *     text empty (its key 0, wherever its Relative's offset points, as a message's empty Relative may point
 *     anywhere) or with its bytes after the fixed part and within the value; false otherwise, or if the file ends
 *     before what's read.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error DeviceError The file's chunks couldn't be read.
 * @error Corrupt A chunk's record or seal, or a node, didn't check out.
 */
key_in :: fn(
    volume : ptr[mut Volume],
    file : u64,
    record : ptr[ObjectRecord],
    index : ptr[IndexRecord],
    into : ptr[mut Keyed]
) -> Result[bool, Error] {
    size :: cast[u64](record.size)
    offset :: cast[u64](cast[u32](index.offset))
    width :: cast[u64](cast[u32](index.size))
    fixed :: cast[u64](cast[u32](index.fixed))
    if size < fixed || offset + width > fixed || width > 8 || width == 0 {
        return .Ok(false)
    }
    bytes : u8[8]
    if !(read_exactly(volume, file, offset, mut_part(bytes, 0, cast[usize](width)))?) {
        return .Ok(false)
    }
    kind :: cast[u32](index.kind)
    if kind == cast[u32](FieldKind.Bool) {
        if bytes[0] > 1 {
            return .Ok(false)
        }
        into.key = cast[u64](bytes[0])
        into.text_bytes = 0
        return .Ok(true)
    }
    if kind == cast[u32](FieldKind.Text) {
        start :: little_endian(part(bytes, 0, 4))
        count :: little_endian(part(bytes, 4, 8))
        if count == 0 {
            into.text_bytes = 0
            into.key = 0
            return .Ok(true)
        }
        if start < fixed || start + count > size {
            return .Ok(false)
        }
        take :: if count < cast[u64](into.text.count) { cast[usize](count) } else { into.text.count }
        if !(read_exactly(volume, file, start, mut_part(into.text, 0, take))?) {
            return .Ok(false)
        }
        into.text_bytes = take
        into.key = text_key(part(into.text, 0, take))
        return .Ok(true)
    }
    field :: part(bytes, 0, cast[usize](width))
    value :: if index.big_endian != 0 { big_endian(field) } else { little_endian(field) }
    into.text_bytes = 0
    if kind == cast[u32](FieldKind.Signed) {
        into.key = signed_key(value, width)
        return .Ok(true)
    }
    if kind == cast[u32](FieldKind.Unsigned) {
        into.key = value
        return .Ok(true)
    }
    return .Ok(false)
}

/**
 * Read bytes of a file, all of them or none.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The file's ID.
 * @param offset Where they start, in bytes from the file's start.
 * @param into Where they go; its whole count is read.
 * @return True if every byte was read; false if the file ends before them, or isn't a file there (NotFound,
 *     IsADirectory, IsALink).
 * @error OutOfMemory No memory for a buffer or a node.
 * @error DeviceError A chunk's blocks couldn't be read, or a failed write was for one.
 * @error Corrupt A chunk's record or seal, or a node, didn't check out.
 */
read_exactly :: fn(volume : ptr[mut Volume], file : u64, offset : u64, into : mut u8[]) -> Result[bool, Error] {
    if into.count == 0 {
        return .Ok(true)
    }
    match read(volume, file, offset, into) {
        case Ok(count) => return .Ok(count == into.count)
        case Error(error) => {
            if error == .NotFound || error == .IsADirectory || error == .IsALink {
                return .Ok(false)
            }
            return .Error(error)
        }
    }
}

/**
 * Read an unsigned number, little-endian.
 *
 * @param bytes Its bytes, 0 to 8 of them; past 8, the first 8.
 * @return The number.
 */
little_endian :: fn(bytes : u8[]) -> u64 {
    value := cast[u64](0)
    for byte, i in bytes {
        if i < 8 {
            value |= cast[u64](byte) << (8 * cast[u64](i))
        }
    }
    return value
}

/**
 * Read an unsigned number, big-endian.
 *
 * @param bytes Its bytes, 0 to 8 of them; past 8, the last 8 count.
 * @return The number.
 */
big_endian :: fn(bytes : u8[]) -> u64 {
    value := cast[u64](0)
    for byte in bytes {
        value = (value << 8) | cast[u64](byte)
    }
    return value
}

/**
 * Make a signed integer's key: sign-extended from its width, its sign bit then flipped, so keys order as the values do.
 *
 * @param value The integer's bits, in its low width bytes.
 * @param width Its size in bytes, 1 to 8.
 * @return The key.
 */
signed_key :: fn(value : u64, width : u64) -> u64 {
    bits :: width * 8
    extended := value
    if bits < 64 && ((value >> (bits - 1)) & 1) != 0 {
        extended = value | (cast[u64](0xffffffffffffffff) << bits)
    }
    return extended ~ (cast[u64](1) << 63)
}

/**
 * Make a text's key: its first 8 bytes, big-endian, zeros past its end, so keys order as the texts do, byte by byte,
 * though texts alike in their first 8 bytes share one.
 *
 * @param text The text's bytes.
 * @return The key.
 */
text_key :: fn(text : u8[]) -> u64 {
    key := cast[u64](0)
    for i in cast[usize](0)..<8 {
        byte :: if i < text.count { text[i] } else { cast[u8](0) }
        key = (key << 8) | cast[u64](byte)
    }
    return key
}

/**
 * Put a file in an index: in its key's bucket, in order of ID, or a record of its own if that's full, and its record of
 * the index.
 *
 * @param volume The volume, marked dirty.
 * @param number The index's number.
 * @param file The file's ID, which isn't in the index already.
 * @param keyed Its key and a text's bytes.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error NoSpace No free extent for a node.
 * @error Corrupt A bucket isn't one, or a node couldn't be read or didn't check out.
 */
enter :: fn(volume : ptr[mut Volume], number : u64, file : u64, keyed : ptr[Keyed]) -> Result[void, Error] {
    volume.dirty = true
    object :: INDEX_OBJECT_BASE | number
    bucket :: make(Bucket)?
    defer runtime.free(bucket)
    key :: key_of(object, .IndexEntry, keyed.key)
    bucket.count = files_in(tree_get(volume.nodes, &volume.tree, key, bucket_bytes(bucket))? or_else 0)?
    spilled := false
    count :: bucket.count
    if count < bucket.files.count {
        // In order of ID: those after it moved up one
        at := count
        loop {
            if at == 0 || at >= bucket.files.count {
                break
            }
            before :: at - 1
            if cast[u64](bucket.files[before]) <= file {
                break
            }
            bucket.files[at] = bucket.files[before]
            at = before
        }
        if at < bucket.files.count {
            bucket.files[at] = cast[u64le](file)
        }
        bucket.count = count + 1
        tree_put(volume.nodes, &volume.tree, key, part(bucket_bytes(bucket), 0, bucket.count * 8))?
    }
    else {
        spill := cast[u64le](keyed.key)
        tree_put(volume.nodes, &volume.tree, key_of(object, .IndexSpill, file), view_of(cast[ptr[u8]](&spill), 8))?
        spilled = true
    }
    value :: make(IndexedValue)?
    defer runtime.free(value)
    text :: part(keyed.text, 0, keyed.text_bytes)
    head :: cast[ptr[mut IndexedRecord]](&value.bytes[0])
    head^ = IndexedRecord.{
        key = cast[u64le](keyed.key),
        spilled = if spilled { cast[u8](1) } else { cast[u8](0) },
        text_bytes = cast[u16le](cast[u16](text.count)),
    }
    copy_bytes(value.bytes, size_of(IndexedRecord), text)
    tree_put(
        volume.nodes,
        &volume.tree,
        key_of(file, .IndexedBy, number),
        part(value.bytes, 0, size_of(IndexedRecord) + text.count)
    )?
    return .Ok
}

/**
 * Take an object out of every index it's in: out of each bucket, the rest kept in order, or its spilled record, and
 * its records of them.
 *
 * @param volume The volume, marked dirty if it was in any.
 * @param object The object's ID.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error NoSpace No free extent for a node's copy.
 * @error Corrupt A record couldn't be taken out, a bucket isn't one, or a node couldn't be read or didn't check out.
 */
unindex :: fn(volume : ptr[mut Volume], object : u64) -> Result[void, Error] {
    head := IndexedRecord.{}
    bucket :: make(Bucket)?
    defer runtime.free(bucket)
    loop {
        found :: tree_next(
            volume.nodes,
            &volume.tree,
            key_of(object, .IndexedBy, 0),
            view_of(cast[ptr[mut u8]](&head), size_of(IndexedRecord))
        )? or_break
        if found.key.object != object || found.key.kind != cast[u8](RecordKind.IndexedBy) {
            break
        }
        volume.dirty = true
        number :: found.key.offset
        index_object :: INDEX_OBJECT_BASE | number
        if found.bytes >= size_of(IndexedRecord) && head.spilled != 0 {
            _ = tree_delete(volume.nodes, &volume.tree, key_of(index_object, .IndexSpill, object))?
        }
        else if found.bytes >= size_of(IndexedRecord) {
            key :: key_of(index_object, .IndexEntry, cast[u64](head.key))
            bucket.count = files_in(tree_get(volume.nodes, &volume.tree, key, bucket_bytes(bucket))? or_else 0)?
            // Those after it moved down one, so the bucket stays in order of ID
            left := bucket.count
            at := bucket.count
            for i in 0..<bucket.count {
                if i < bucket.files.count && cast[u64](bucket.files[i]) == object {
                    at = i
                    break
                }
            }
            if at < bucket.count && left > 0 {
                left -= 1
                for i in at..<left {
                    after :: i + 1
                    if i < bucket.files.count && after < bucket.files.count {
                        bucket.files[i] = bucket.files[after]
                    }
                }
            }
            if left == 0 {
                _ = tree_delete(volume.nodes, &volume.tree, key)?
            }
            else if left != bucket.count {
                tree_put(volume.nodes, &volume.tree, key, part(bucket_bytes(bucket), 0, left * 8))?
            }
        }
        if !(tree_delete(volume.nodes, &volume.tree, found.key)?) {
            return .Error(.Corrupt)
        }
    }
    return .Ok
}

/**
 * View a bucket's files as bytes, for reading or writing its record.
 *
 * @param bucket The bucket.
 * @return Its files' bytes, all BUCKET_FILES * 8 of them, a view into it.
 */
bucket_bytes :: fn(bucket : ptr[mut Bucket]) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](&bucket.files[0]), BUCKET_FILES * 8)
}

/**
 * Count a bucket's files from its record's length.
 *
 * @param bytes The record's length in bytes, as read; 0 for no record.
 * @return How many files it names.
 * @error Corrupt The length isn't a whole number of IDs, or is past BUCKET_FILES of them.
 */
files_in :: fn(bytes : usize) -> Result[usize, Error] {
    if bytes % 8 != 0 || bytes > BUCKET_FILES * 8 {
        return .Error(.Corrupt)
    }
    return .Ok(bytes / 8)
}

/**
 * Read a file's record of an index: its key and a text's bytes.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param file The file's ID.
 * @param number The index's number.
 * @param into Where its key and text go.
 * @return True if the file is in the index; false if it isn't.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt The record isn't one, or a node couldn't be read or didn't check out.
 */
indexed_key :: fn(volume : ptr[mut Volume], file : u64, number : u64, into : ptr[mut Keyed]) -> Result[bool, Error] {
    value :: make(IndexedValue)?
    defer runtime.free(value)
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(file, .IndexedBy, number), value.bytes)? or_return .Ok(false)
    if bytes < size_of(IndexedRecord) || bytes > value.bytes.count {
        return .Error(.Corrupt)
    }
    head :: cast[ptr[IndexedRecord]](&value.bytes[0])
    count :: cast[usize](cast[u16](head.text_bytes))
    if size_of(IndexedRecord) + count != bytes || count > into.text.count {
        return .Error(.Corrupt)
    }
    into.key = cast[u64](head.key)
    copy_bytes(into.text, 0, part(value.bytes, size_of(IndexedRecord), bytes))
    into.text_bytes = count
    return .Ok(true)
}
