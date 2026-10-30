package config

import compiler from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * The config store's protocol (roadmap 9c2, decisions/0107, 0109, design/software.md §4). A connection reaches one
 * owner's value, of a type its program declares; the program's entry takes it as a Config[T]. The program declares the
 * value's type and its default, T.{}, its compile-time value; the store keeps that default, the owner's override and
 * which of T's fields it sets, and the newest MAX_VERSIONS versions, each with its author and its time. What a program
 * sees is the default with the override's fields over it (merged, here, where T is known). Next waits for the next
 * version, to apply it live. A declaration of another type, as a program's new version may make, starts the value
 * again from its default, without an override; the versions before it are kept, but can't be rolled back to. The supervisor's connection, which arrives on the service's listener, asks for the
 * connections programs are given (ValueFor).
 */

ConfigValue :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "config", major_version = 1, lending = .Server}

// A program's connection to its value of type T, as its entry takes it: one end, speaking ConfigValue.
Config :: struct[T] {
    end : slop_os.Channel,
}

// The largest value the store keeps, default or override, so either fits in a message with the other
MAX_VALUE_BYTES :: 1792
// The versions a value keeps; a write past them drops the oldest
MAX_VERSIONS :: 16

ValueFor :: struct {
    // Whose value: a service's or an installation's name; and which of its values: its entry's parameter's name
    owner : slop_os.Relative[u8],
    name : slop_os.Relative[u8],
}

Declare :: struct {
    // T's schema hash, and T.{}'s bytes
    schema : u8[32],
    default : slop_os.Relative[u8],
}

Write :: struct {
    // Which of T's fields the override sets, a bit each, in the order T declares them
    fields : u64,
    value : slop_os.Relative[u8],
}

Current :: struct {
    version : u64,
    default : slop_os.Relative[u8],
    fields : u64,
    override : slop_os.Relative[u8],
}

Version :: struct {
    version : u64,
    // Nanoseconds since 1970-01-01T00:00:00Z when it was written, 0 if the clock wasn't known
    written : i64,
    author : slop_os.Relative[u8],
    fields : u64,
}

ConfigError :: enum #backed_by(u32) {
    // Nothing declared yet: a program declares its value before anything else
    NotDeclared = 1,
    // A write, or a rollback, that isn't of the value's type
    WrongType = 2,
    TooLarge = 3,
    // No such version kept
    NotFound = 4,
    // The store couldn't keep it: its volume refused the write, or it hadn't the memory
    NotKept = 5,
    // Only the supervisor's connection asks for others
    Refused = 6,
}

Request :: union {
    // On the supervisor's connection: a connection to an owner's value, to give its program
    ValueFor(ValueFor),
    Declare(Declare),
    // The value's current version
    Read,
    // A new version, with the override given: its version
    Write(Write),
    // Answered once the value's version is past this one
    Next(u64),
    // The kept version this many back from the newest (0 for the newest), or NoMore
    History(u64),
    // A new version with the override a kept one had, if it was of the same type
    Rollback(u64),
    // On the supervisor's connection: the store's directory from now on, as when its volume server was started again
    UseDirectory(os.Channel[dir.Dir]),
}

Response :: union {
    Opened(os.Channel[ConfigValue]),
    Done,
    Current(Current),
    Written(u64),
    Kept(Version),
    NoMore,
    Failed(ConfigError),
    Unsupported,
}

// A write or a rollback makes a version each time.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Write(_) => false
        case Rollback(_) => false
        case _ => true
    }
}

#insert os.protocol_code(Request, Response)

// A request through end, and its answer, waited for on port; Unsupported if the connection's gone.
ask :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> Response {
    if send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match receive_response(end, port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
    return os.message_of[Response](into)^
}

// ---- A program's side, where T is known

// T's default, T.{}, declared as the value's type and default: the value's version, or why not.
declare :: fn[T](config: Config[T], port: slop_os.Port) -> Result[u64, ConfigError] {
    value := os.Outgoing.{}
    os.begin[T](&value)^ = T.{}
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Declare(Declare.{schema = os.schema_hash_of[T](), default = os.append(&out, os.value_bytes(&value))})
    into := os.Incoming.{}
    return match ask(config.end, port, &out, &into) {
        case Current(current) => .Ok(current.version)
        case Failed(error) => .Error(error)
        case _ => .Error(.NotKept)
    }
}

/*
 * The value as the program sees it, into value: its default with its override's fields over it, checked to be a T
 * (os.holds_value). Its version, or why not. value is read with os.typed_value[T](os.value_bytes(value)).
 */
read :: fn[T](config: Config[T], port: slop_os.Port, value: ptr[mut os.Outgoing]) -> Result[u64, ConfigError] {
    out := os.Outgoing.{}
    os.begin[Request](&out)^ = .Read
    into := os.Incoming.{}
    return answer_of[T](ask(config.end, port, &out, &into), &into, value)
}

// The value once its version is past seen, as read gives it: its version, or why not.
next :: fn[T](config: Config[T], port: slop_os.Port, seen: u64, value: ptr[mut os.Outgoing]) -> Result[u64, ConfigError] {
    out := os.Outgoing.{}
    os.begin[Request](&out)^ = .Next(seen)
    into := os.Incoming.{}
    return answer_of[T](ask(config.end, port, &out, &into), &into, value)
}

answer_of :: fn[T](response: Response, into: ptr[os.Incoming], value: ptr[mut os.Outgoing]) -> Result[u64, ConfigError] {
    match response {
        case Current(current) => {
            default :: os.items(into, current.default)
            override :: os.items(into, current.override)
            if !merge[T](default, override, current.fields, value) {
                return .Error(.WrongType)
            }
            return .Ok(current.version)
        }
        case Failed(error) => return .Error(error)
        case _ => return .Error(.NotKept)
    }
}

/*
 * A new version, whose override is value's bytes for the fields given (field_bit): checked to be a T first. Its version,
 * or why not.
 */
write :: fn[T](config: Config[T], port: slop_os.Port, value: u8[], fields: u64) -> Result[u64, ConfigError] {
    if !os.holds_value[T](value) {
        return .Error(.WrongType)
    }
    if value.count > MAX_VALUE_BYTES {
        return .Error(.TooLarge)
    }
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Write(Write.{fields = fields, value = os.append(&out, value)})
    into := os.Incoming.{}
    return match ask(config.end, port, &out, &into) {
        case Written(version) => .Ok(version)
        case Failed(error) => .Error(error)
        case _ => .Error(.NotKept)
    }
}

// A new version with the override the kept version had: its version, or why not.
roll_back :: fn[T](config: Config[T], port: slop_os.Port, version: u64) -> Result[u64, ConfigError] {
    out := os.Outgoing.{}
    os.begin[Request](&out)^ = .Rollback(version)
    into := os.Incoming.{}
    return match ask(config.end, port, &out, &into) {
        case Written(made) => .Ok(made)
        case Failed(error) => .Error(error)
        case _ => .Error(.NotKept)
    }
}

// The kept version back versions from the newest, its author into author: null past the oldest kept.
history :: fn[T](config: Config[T], port: slop_os.Port, back: u64, author: ptr[mut u8[..]]) -> Version? {
    out := os.Outgoing.{}
    os.begin[Request](&out)^ = .History(back)
    into := os.Incoming.{}
    match ask(config.end, port, &out, &into) {
        case Kept(kept) => {
            if runtime.array_try_copy(os.items(&into, kept.author), author) != null {
                return null
            }
            return kept
        }
        case _ => return null
    }
}

// The bit a write sets for T's field named name, a field T declares at its top level; 0 for none.
field_bit :: fn[T](name: string) -> u64 {
    info :: type_info_of(T)
    if info.variant != .STRUCT {
        return 0
    }
    for member, i in cast[ptr[compiler.TypeInfoStruct]](info).members {
        if member.name == name && i < 64 {
            return cast[u64](1) << cast[u64](i)
        }
    }
    return 0
}

/*
 * default with override's fields over it, field by field at T's top level, into value: each field's bytes from the
 * one it comes from, and what its Relatives hold copied after them. Whether both were Ts and it fit.
 */
merge :: fn[T](default: u8[], override: u8[], fields: u64, value: ptr[mut os.Outgoing]) -> bool {
    info :: type_info_of(T)
    if info.variant != .STRUCT || !os.holds_value[T](default) || (fields != 0 && !os.holds_value[T](override)) {
        return false
    }
    os.begin[T](value)
    for member, i in cast[ptr[compiler.TypeInfoStruct]](info).members {
        from :: if i < 64 && fields & (cast[u64](1) << cast[u64](i)) != 0 { override } else { default }
        copy(value, member.offset, from, member.offset, member.member_type.size)
        if !relocate(member.member_type, member.offset, from, value) {
            return false
        }
    }
    return true
}

// The Relatives of type, at offset in a value copied from source into value, given their items after what value holds.
relocate :: fn(type: ptr[compiler.TypeInfo], offset: usize, source: u8[], value: ptr[mut os.Outgoing]) -> bool {
    if type.variant == .ALIAS {
        return relocate(cast[ptr[compiler.TypeInfoAlias]](type).base_type, offset, source, value)
    }
    if type.variant == .ARRAY {
        array :: cast[ptr[compiler.TypeInfoArray]](type)
        count := cast[usize](1)
        for dimension in array.dimensions {
            count *= dimension.count
        }
        element_size :: if count == 0 { cast[usize](0) } else { type.size / count }
        for i in 0..<count {
            if !relocate(array.base_type, offset + i * element_size, source, value) {
                return false
            }
        }
        return true
    }
    if type.variant != .STRUCT {
        return true
    }
    structure :: cast[ptr[compiler.TypeInfoStruct]](type)
    if !os.starts_with(structure.name, "Relative[") {
        for member in structure.members {
            if !relocate(member.member_type, offset + member.offset, source, value) {
                return false
            }
        }
        return true
    }
    held := type
    for member in structure.members {
        if member.name == "elements" {
            held = cast[ptr[compiler.TypeInfoArray]](member.member_type).base_type
        }
    }
    if held == type || offset + 8 > source.count {
        return false
    }
    from_offset :: cast[usize](os.read_message(source, offset, 4))
    count :: cast[usize](os.read_message(source, offset + 4, 4))
    bytes :: count * held.size
    if from_offset > source.count || bytes > source.count - from_offset {
        return false
    }
    alignment :: os.alignment_of(held)
    start :: (cast[usize](value.used) + alignment - 1) & ~(alignment - 1)
    if start > os.MESSAGE_BYTES || bytes > os.MESSAGE_BYTES - start {
        return false
    }
    copy(value, start, source, from_offset, bytes)
    value.used = cast[u32](start + bytes)
    relative :: cast[ptr[mut slop_os.Relative[u8]]](cast[u64](&value.words[0]) + cast[u64](offset))
    relative^ = slop_os.Relative[u8].{offset = cast[u32](start), count = cast[u32](count)}
    return true
}

// count bytes of source from source_at into value at at, within both.
copy :: fn(value: ptr[mut os.Outgoing], at: usize, source: u8[], source_at: usize, count: usize) {
    words :: view_of(cast[ptr[mut u8]](&value.words[0]), os.MESSAGE_BYTES)
    for i in 0..<count {
        if at + i < words.count && source_at + i < source.count {
            words[at + i] = source[source_at + i]
        }
    }
}
