package volume_server

import os from "std:os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import slopfs from "../../slopfs"

/*
 * Indexes (decisions/0201's 20i): declared, dropped and listed through dir, on the whole volume, which slopfs keeps
 * in the volume's tree (src/slopfs/index.hsc), each file's entries made again as its changes commit. A connection
 * reached through a stored link changes none of them.
 */

/**
 * Answer a DeclareIndex: the index declared and built, durable with the volume's next commit.
 *
 * @param server The server, whose volume's tree takes the index.
 * @param index The asking connection's slot; one reached through a link is refused.
 * @param schema The schema's bytes, from the request; only read.
 * @param field The field's name's bytes, from the request; only read.
 * @return Declared with its number; Failed with ReadOnly through a link, WrongType for a schema or field it can't be
 *     of, NoSpace when the volume keeps as many as it can, or why the volume couldn't be read or changed.
 */
declared :: fn(server : ptr[mut Server], index : usize, schema : u8[], field : u8[]) -> dir.Response {
    if index >= server.connections.count || server.connections[index].linked {
        return .Failed(.ReadOnly)
    }
    name :: if field.count == 0 { "" } else { string_of(&field[0], field.count) }
    match slopfs.declare_index(server.volume, schema, name) {
        case Ok(number) => return .Declared(cast[u32](number))
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Answer a DropIndex: the index and its records taken out, durable with the volume's next commit.
 *
 * @param server The server, whose volume's tree loses the index.
 * @param index The asking connection's slot; one reached through a link is refused.
 * @param number The index's number.
 * @return Done; Failed with ReadOnly through a link, NotFound for no such index, or why the volume couldn't be read
 *     or changed.
 */
dropped :: fn(server : ptr[mut Server], index : usize, number : u32) -> dir.Response {
    if index >= server.connections.count || server.connections[index].linked {
        return .Failed(.ReadOnly)
    }
    match slopfs.drop_index(server.volume, cast[u64](number)) {
        case Ok => return .Done
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Answer an Indexes: the volume's index at or after a cursor.
 *
 * @param volume The volume, or a snapshot's, only read.
 * @param cursor The least number the index may have: 0 for the first, or the last answer's next.
 * @param out The answer being built, which the field's name is appended to.
 * @return IndexListed, its next the number after it; End past the last; Failed if the declarations couldn't be read.
 */
index_listed :: fn(volume : ptr[mut slopfs.Volume], cursor : u32, out : ptr[mut os.Outgoing]) -> dir.Response {
    match slopfs.next_index(volume, cast[u64](cursor)) {
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
