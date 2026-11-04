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
 * again from its default, without an override; the versions before it are kept, but can't be rolled back to. The
 * supervisor's connection, which arrives on the service's listener, asks for the connections programs are given
 * (ValueFor).
 */

/**
 * The config protocol, for the channels between the config store and the supervisor, the session manager, and each
 * program's connection to one of its values: they send the requests, and the config store answers them.
 */
ConfigValue :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the config store, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "config", major_version = 1, lending = .Server}

/**
 * A program's connection to its value of type T, as its entry takes it: one end, speaking ConfigValue.
 *
 * @tparam T The value's type, a struct the program declares; its default is T.{}.
 */
Config :: struct[T] {
    /** The program's end of the connection to its value, its own for its life. */
    end : slop_os.Channel,
}

/**
 * The largest value the store keeps, default or override, in bytes, 1792, so either fits in a message with the other.
 */
MAX_VALUE_BYTES :: 1792
/** How many versions a value keeps, 16; a write past them drops the oldest. */
MAX_VERSIONS :: 16
/**
 * The bytes of the rings a connection to a value has, 8192, so the largest message, a default and an override, fits
 * one.
 */
RING_BYTES : u32 : 8192

/** Which value ValueFor asks for: whose, and which of its values. */
ValueFor :: struct {
    /** Whose value: a service's or an installation's name, as UTF-8. */
    owner : slop_os.Relative[u8],
    /** Which of its values: its entry's parameter's name, as UTF-8. */
    name : slop_os.Relative[u8],
}

/** A value's type and its default, as its program declares them. */
Declare :: struct {
    /** T's schema hash (os.schema_hash_of). */
    schema : u8[32],
    /** T.{}'s bytes, as a message holds a T, at most MAX_VALUE_BYTES, or it's TooLarge. */
    default : slop_os.Relative[u8],
}

/** A new version's override. */
Write :: struct {
    /** Which of T's fields the override sets, a bit each, in the order T declares them (field_bit); 0 for none. */
    fields : u64,
    /** The override, a T's bytes as a message holds one, at most MAX_VALUE_BYTES, or it's TooLarge. */
    value : slop_os.Relative[u8],
}

/** A value's newest version, which its program sees merged. */
Current :: struct {
    /** Its number, from 1, growing with each version written. */
    version : u64,
    /** The declared default, a T's bytes. */
    default : slop_os.Relative[u8],
    /** Which of T's fields the override sets, a bit each, in the order T declares them. */
    fields : u64,
    /** The override, a T's bytes; only the fields fields names are taken from it. */
    override : slop_os.Relative[u8],
}

/** A kept version, as History gives it. */
Version :: struct {
    /** Its number. */
    version : u64,
    /** Nanoseconds since 1970-01-01T00:00:00Z when it was written, 0 if the clock wasn't known. */
    written : i64,
    /** Who wrote it, as UTF-8, as the store records it. */
    author : slop_os.Relative[u8],
    /** Which of T's fields its override set, a bit each, in the order T declares them. */
    fields : u64,
}

/** Why the config store didn't do what it was asked. */
ConfigError :: enum #backed_by(u32) {
    /** Nothing declared yet: a program declares its value before anything else, or its newest version can't be read. */
    NotDeclared = 1,
    /** A write, or a rollback, that isn't of the value's type; or, to a program, a value that isn't a T. */
    WrongType = 2,
    /** A default or an override larger than MAX_VALUE_BYTES. */
    TooLarge = 3,
    /** No such version kept. */
    NotFound = 4,
    /**
     * The store couldn't keep it: its volume refused the write, or it hadn't the memory; and, to a program, any
     * answer it didn't expect, as when the connection's gone.
     */
    NotKept = 5,
    /**
     * Not this connection's to ask: only the supervisor's connection asks for others, uses a directory or forgets,
     * the session manager's only for users' values, and only a value's connection reads or writes it.
     */
    Refused = 6,
}

/** What's asked of the config store. */
Request :: union {
    /**
     * On the supervisor's connection, or the session manager's for a user's installation: ask for a new connection
     * to an owner's value, to give its program. Answered with Opened, or Failed(Refused).
     */
    ValueFor(ValueFor),
    /**
     * Declare the value's type and default: the first version written the first time, and a new one when either
     * changed. Answered with Current, or Failed.
     */
    Declare(Declare),
    /** Ask for the value's newest version. Answered with Current, or Failed(NotDeclared). */
    Read,
    /**
     * Write a new version, with the override given. Answered with Written, or Failed; every Next waiting on the value
     * is answered too.
     */
    Write(Write),
    /**
     * Ask for the value once its version is past this one: answered with Current at once if it is, or a value not
     * declared, and otherwise once a version is written.
     */
    Next(u64),
    /** Ask for the kept version this many back from the newest, 0 for the newest. Answered with Kept, or NoMore. */
    History(u64),
    /**
     * Write a new version with the override, and its fields, a kept one had, by its number, if it was of the same
     * type. Answered with Written, or Failed.
     */
    Rollback(u64),
    /**
     * On the supervisor's connection: have the store use this connection to its directory from now on, as when its
     * volume server was started again; the end moves to the store. Answered with Done, or Failed.
     */
    UseDirectory(os.Channel[dir.Dir]),
    /**
     * On the supervisor's connection, or the session manager's for a user's installation: remove every value of an
     * owner's, by its name, every version, as when it's uninstalled. Answered with Done, or Failed.
     */
    Forget(slop_os.Relative[u8]),
}

/** What the config store answers. */
Response :: union {
    /** ValueFor's answer: the new connection to the value, which moves to the asker, to give the program. */
    Opened(os.Channel[ConfigValue]),
    /** UseDirectory's or Forget's answer: it's done. */
    Done,
    /** Declare's, Read's or Next's answer: the newest version. */
    Current(Current),
    /** Write's or Rollback's answer: the new version's number. */
    Written(u64),
    /** History's answer: the kept version. */
    Kept(Version),
    /** History's answer past the versions kept, or when the version can't be read. */
    NoMore,
    /** The answer when it wasn't done, and why. */
    Failed(ConfigError),
    /** The answer to a request the store doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Write and Rollback, which make a version each time; true for the rest.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Write(_) => false
        case Rollback(_) => false
        case Forget(_) => true
        case _ => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Send a request to the config store and wait for its answer.
 *
 * Responses that aren't one, unknown or invalid, are skipped while it waits.
 *
 * @param end A connection to the config store, kept by the caller.
 * @param port A port bound to end, waited on for the answer and while end's ring is full.
 * @param out The request, begun with os.begin; sent as it is, any handles in it moving to the store.
 * @param into Where the answer is received, with what it holds and any handles it brought, which are the caller's.
 * @return The answer, copied out of into, its Relatives into into; Unsupported if the request couldn't be sent or the
 *     connection's gone.
 */
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

/**
 * Declare T, and its default, T.{}, as the value's type and default, and wait for the store's answer.
 *
 * @tparam T The value's type, a struct.
 * @param config The program's connection to its value.
 * @param port A port bound to config's end.
 * @return The value's newest version's number once it's declared.
 * @error TooLarge T.{}'s bytes are more than MAX_VALUE_BYTES.
 * @error NotKept The store couldn't write the version, or the connection's gone.
 * @error Refused The connection isn't one to a value.
 */
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

/**
 * Read the value as the program sees it: its default with its override's fields over it, checked to be a T
 * (os.holds_value).
 *
 * @tparam T The value's type, as declared.
 * @param config The program's connection to its value.
 * @param port A port bound to config's end.
 * @param value Where the merged value is built, a T as a message holds one; read with
 *     os.typed_value[T](os.value_bytes(value)). Begun again by this; left partly built on an error.
 * @return The newest version's number.
 * @error NotDeclared Nothing's declared yet, or the newest version can't be read.
 * @error WrongType The default or override isn't a T, or the merged value doesn't fit a message.
 * @error NotKept The connection's gone, or the store answered something else.
 * @error Refused The connection isn't one to a value.
 */
read :: fn[T](config: Config[T], port: slop_os.Port, value: ptr[mut os.Outgoing]) -> Result[u64, ConfigError] {
    out := os.Outgoing.{}
    os.begin[Request](&out)^ = .Read
    into := os.Incoming.{}
    return answer_of[T](ask(config.end, port, &out, &into), &into, value)
}

/**
 * Wait until the value's version is past one already seen, then read it as read does: to apply it live.
 *
 * @tparam T The value's type, as declared.
 * @param config The program's connection to its value.
 * @param port A port bound to config's end, waited on, perhaps for long, until a version is written.
 * @param seen The newest version's number the program has; 0 for none, answered at once.
 * @param value Where the merged value is built, as read builds it.
 * @return The newest version's number, past seen.
 * @error NotDeclared Nothing's declared yet, or the newest version can't be read.
 * @error WrongType The default or override isn't a T, or the merged value doesn't fit a message.
 * @error NotKept The connection's gone, or the store answered something else.
 * @error Refused The connection isn't one to a value.
 */
next :: fn[T](config: Config[T], port: slop_os.Port, seen: u64, value: ptr[mut os.Outgoing]) -> Result[u64, ConfigError] {
    out := os.Outgoing.{}
    os.begin[Request](&out)^ = .Next(seen)
    into := os.Incoming.{}
    return answer_of[T](ask(config.end, port, &out, &into), &into, value)
}

/**
 * Take read's or next's answer: a Current merged into value, or why not.
 *
 * @tparam T The value's type, as declared.
 * @param response The store's answer.
 * @param into The message the answer came in, which holds a Current's default and override.
 * @param value Where the merged value is built.
 * @return A Current's version's number.
 * @error WrongType The default or override isn't a T, or the merged value doesn't fit a message.
 * @error NotKept The answer was neither a Current nor a Failed.
 * @error NotDeclared The store answered so: nothing's declared yet, or the newest version can't be read.
 * @error Refused The store answered so: the connection isn't one to a value.
 */
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

/**
 * Write a new version, whose override is value's bytes for the fields given, and wait for the store's answer.
 *
 * @tparam T The value's type, as declared.
 * @param config The connection to the value.
 * @param port A port bound to config's end.
 * @param value The override, a T's bytes as a message holds one, copied into the request.
 * @param fields Which of T's fields the override sets, the bits field_bit gives, or'd; 0 sets none.
 * @return The new version's number.
 * @error WrongType value isn't a T, checked before it's sent.
 * @error TooLarge value is more than MAX_VALUE_BYTES.
 * @error NotDeclared Nothing's declared yet.
 * @error NotKept The store couldn't write it, or the connection's gone.
 * @error Refused The connection isn't one to a value.
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

/**
 * Write a new version with the override, and its fields, a kept version had, and wait for the store's answer.
 *
 * @tparam T The value's type, as declared.
 * @param config The connection to the value.
 * @param port A port bound to config's end.
 * @param version The kept version's number, one of the newest MAX_VERSIONS.
 * @return The new version's number.
 * @error NotFound No such version is kept, or it can't be read.
 * @error WrongType The kept version is of another type, from before a declaration of a new one.
 * @error NotDeclared The newest version can't be read.
 * @error NotKept The store couldn't write it, or the connection's gone.
 * @error Refused The connection isn't one to a value.
 */
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

/**
 * Ask for a kept version, by how far back from the newest it is, and wait for the store's answer.
 *
 * @tparam T The value's type, as declared.
 * @param config The connection to the value.
 * @param port A port bound to config's end.
 * @param back How many versions back from the newest: 0 for the newest, up to MAX_VERSIONS - 1.
 * @param author Where the version's author's bytes are copied (runtime.array_try_copy), with context's allocator.
 * @return The version; its author's Relative is into the answer's message, gone once this returns, so author holds
 *     it. Null past the oldest kept, on any other answer, or if author couldn't be grown.
 */
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

/**
 * Give the bit a write sets for one of T's fields, to or into write's fields.
 *
 * @tparam T The value's type, a struct.
 * @param name The field's name, one T declares at its top level.
 * @return 1 shifted by the field's place among T's fields; 0 if T isn't a struct, has no field of that name, or it's
 *     past the 64th.
 */
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

/**
 * Merge a default with an override's fields over it, field by field at T's top level, into a value.
 *
 * Each field's bytes come from the one it's taken from, and what its Relatives hold is copied after them, the
 * Relatives made to point there.
 *
 * @tparam T The value's type, a struct.
 * @param default The default, a T's bytes as a message holds one.
 * @param override The override, a T's bytes; not looked at when fields is 0.
 * @param fields Which fields come from override, a bit each, in the order T declares them; past the 64th, none do.
 * @param value Where the merged T is built, begun again by this.
 * @return True if both were Ts and it fit a message; false otherwise, value left partly built.
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

/**
 * Copy what the Relatives in a part of a value hold, for a value copied from source into value, and point them there.
 *
 * Arrays and structs are gone into, aliases followed; each Relative found has its items appended after what value
 * holds, aligned for them.
 *
 * @param type The part's type.
 * @param offset Where the part is, in bytes, in both source and value.
 * @param source The value copied from, whose Relatives' offsets are into it.
 * @param value The value being built, whose used grows by each Relative's items.
 * @return True if every Relative's items were within source and fit value's message; false otherwise.
 */
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

/**
 * Copy bytes from source into a message being built, as many of them as are within both.
 *
 * @param value The message, whose words are written; its used isn't changed.
 * @param at Where they go, in bytes from the message's start.
 * @param source The bytes copied from.
 * @param source_at Where they come from, in bytes from source's start.
 * @param count How many bytes; those past either's end are skipped.
 */
copy :: fn(value: ptr[mut os.Outgoing], at: usize, source: u8[], source_at: usize, count: usize) {
    words :: view_of(cast[ptr[mut u8]](&value.words[0]), os.MESSAGE_BYTES)
    for i in 0..<count {
        if at + i < words.count && source_at + i < source.count {
            words[at + i] = source[source_at + i]
        }
    }
}
