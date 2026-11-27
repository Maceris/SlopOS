package volume_server

import os from "std:os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import slopfs from "../../slopfs"

/*
 * Indexes (decisions/0201's 20i): declared, dropped and listed through dir, on the whole volume, which slopfs keeps
 * in the volume's tree (src/slopfs/index.hsc), each file's entries made again as its changes commit. They're the
 * volume's own, so only a connection to its root may declare, drop or list them: not one beneath it, which would see
 * or change what's kept of every directory's files, nor one reached through a stored link, nor one read only.
 * Queries, which answer only what's beneath their directory, are asked of any.
 */

/**
 * Tell whether a connection may declare, drop and list the volume's indexes: a dir connection, not a transaction's,
 * to the live volume's root, writable and not reached through a stored link.
 *
 * @param server The server, only read.
 * @param index The connection's slot; one past them may not.
 * @return Whether it may.
 */
on_root :: fn(server : ptr[Server], index : usize) -> bool {
    if index >= server.connections.count {
        return false
    }
    connection :: &server.connections[index]
    return connection.kind == .Dir
        && connection.object == slopfs.ROOT_OBJECT
        && !connection.read_only
        && !connection.linked
        && connection.past == 0
}

/**
 * Answer a DeclareIndex: the index declared and built, durable with the volume's next commit.
 *
 * It's built from every file of its type in this request (slopfs.declare_index), however many there are; the live
 * queries of its type then begin again (indexes_changed), as a file not holding its field drops out of the type's
 * other indexes.
 *
 * @param server The server, whose volume's tree takes the index.
 * @param index The asking connection's slot; one that isn't on the volume's root (on_root) is refused.
 * @param schema The schema's bytes, from the request; only read.
 * @param field The field's name's bytes, from the request; only read.
 * @return Declared with its number; Failed with ReadOnly from a connection that isn't on the root, WrongType for a
 *     schema or field it can't be of, NoSpace when the volume keeps as many as it can, NoMemory without the memory
 *     for the schema's hash or a node, or why the volume couldn't be read or changed.
 */
declared :: fn(server : ptr[mut Server], index : usize, schema : u8[], field : u8[]) -> dir.Response {
    if !on_root(server, index) {
        return .Failed(.ReadOnly)
    }
    name :: if field.count == 0 { "" } else { string_of(&field[0], field.count) }
    match slopfs.declare_index(server.volume, schema, name) {
        case Ok(number) => {
            match slopfs.index_record(server.volume, number) {
                case Ok(found) => {
                    match found {
                        case Some(record) => indexes_changed(server, record.schema, 0)
                        case None => {}
                    }
                }
                case Error(error) => {}
            }
            return .Declared(cast[u32](number))
        }
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Answer a DropIndex: the index and its records taken out, durable with the volume's next commit.
 *
 * The files of its type are indexed again by the type's other indexes in this request (slopfs.drop_index); the live
 * queries naming it end, and the others of its type begin again (indexes_changed).
 *
 * @param server The server, whose volume's tree loses the index.
 * @param index The asking connection's slot; one that isn't on the volume's root (on_root) is refused.
 * @param number The index's number.
 * @return Done; Failed with ReadOnly from a connection that isn't on the root, NotFound for no such index, or why the
 *     volume couldn't be read or changed.
 */
dropped :: fn(server : ptr[mut Server], index : usize, number : u32) -> dir.Response {
    if !on_root(server, index) {
        return .Failed(.ReadOnly)
    }
    record := slopfs.IndexRecord.{}
    match slopfs.index_record(server.volume, cast[u64](number)) {
        case Ok(found) => {
            match found {
                case Some(declared) => record = declared
                case None => return .Failed(.NotFound)
            }
        }
        case Error(error) => return .Failed(file_error(error))
    }
    match slopfs.drop_index(server.volume, cast[u64](number)) {
        case Ok => {
            indexes_changed(server, record.schema, cast[u64](number))
            return .Done
        }
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Answer an Indexes: the volume's index at or after a cursor.
 *
 * @param server The server, whose volume is only read.
 * @param index The asking connection's slot; one that isn't on the volume's root (on_root) is refused, as the list
 *     says what every directory's files are indexed by.
 * @param cursor The least number the index may have: 0 for the first, or the last answer's next.
 * @param out The answer being built, which the field's name is appended to.
 * @return IndexListed, its next the number after it; End past the last; Failed with ReadOnly from a connection that
 *     isn't on the root, or why the declarations couldn't be read.
 */
index_listed :: fn(server : ptr[mut Server], index : usize, cursor : u32, out : ptr[mut os.Outgoing]) -> dir.Response {
    if !on_root(server, index) {
        return .Failed(.ReadOnly)
    }
    match slopfs.next_index(server.volume, cast[u64](cursor)) {
        case Ok(found) => {
            listed :: found or_return .End
            record :: listed.record
            count :: cast[usize](cast[u16](record.field_bytes))
            return .IndexListed(
                files.Index.{
                    number = cast[u32](listed.number),
                    kind = indexed_kind(slopfs.field_kind_of(cast[u32](record.kind)) or_else .Unsigned),
                    schema = record.schema,
                    field = os.append(out, slopfs.part(record.field, 0, count)),
                    next = cast[u32](listed.number) + 1,
                }
            )
        }
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Give the dir protocol's kind of an indexed field for slopfs's.
 *
 * @param kind The field's kind, as slopfs keeps it.
 * @return The same kind, as files names it.
 */
indexed_kind :: fn(kind : slopfs.FieldKind) -> files.IndexedKind {
    return match kind {
        case .Unsigned => files.IndexedKind.Unsigned
        case .Signed => files.IndexedKind.Signed
        case .Bool => files.IndexedKind.Bool
        case .Text => files.IndexedKind.Text
    }
}
