package shell_language

import runtime from "base:runtime"
import schema from "std:schema"

/*
 * A program's parameters, by their manifest's types (design/shell.md §3, decisions/0170): what each is given, for the
 * shell's calls and for a form made from a manifest (decisions/0192, 15g).
 */

/** What a parameter is given: a value written for it, or a grant of one of the kinds the shell can make. */
Giving :: enum {
    /** A value, written from its argument as the entry reads it. */
    Value,
    /** A connection to the shell's terminal, without an argument. */
    Terminal,
    /** A directory beneath the shell's home, from a path. */
    Dir,
    /**
     * The shell's directory, without an argument, for a Dir named here (decisions/0179); or, from --here, a directory
     * beneath its home, as Dir is.
     */
    Here,
    /** A file to read and write beneath the shell's home, from a path; made if it isn't there. */
    File,
    /** A file only to read beneath the shell's home, from a path. */
    ReadOnlyFile,
    /** A pipeline's records: the Stream[T] named input, which reads what comes before it. */
    Input,
    /** A pipeline's records: the Sink[T] named output, which writes for what comes after it, or for the shell. */
    Output,
    /**
     * A connection to the session's powerbox, without an argument, made by the session manager under the program's
     * name (decisions/0181, F4): what it's given through it, the user chooses on the trusted path.
     */
    Powerbox,
    /**
     * A connection to the network, without an argument (decisions/0188, 13c): a copy of the session's, allowing what
     * it does; more is the powerbox's to give.
     */
    Network,
    /** A grant the shell doesn't make: a parameter that's optional goes without it. */
    Other,
}

/**
 * Find an optional's Some type, if the type at a place is an optional: a union of None and Some(T), not a pointer's.
 *
 * @param manifest The program's manifest, only read.
 * @param place The type's place among the manifest's types, taken as it is: an alias isn't followed.
 * @return The place of T; null if the type isn't such an optional.
 */
some_of :: fn(manifest : ptr[schema.Schema], place : usize) -> usize? {
    type :: schema.type_in(manifest, place) or_return null
    if type.kind != .Union || type.null_is_none || type.variants.count != 2 {
        return null
    }
    for variant in type.variants {
        if variant.name == "Some" && variant.held.count == 1 {
            for held in variant.held {
                return held.type
            }
        }
    }
    return null
}

/**
 * Tell what a parameter of the type at a place is given: a grant if it's a handle's type, by its name, or a value.
 *
 * @param manifest The program's manifest, only read.
 * @param place The type's place among the manifest's types, an optional's Some type already taken.
 * @return Input for a Stream, Output for a Sink, Terminal, Dir, File, ReadOnlyFile, Powerbox or Network for a Channel
 *     of those protocols, Other for any other handle or a type not in the manifest, and Value for anything else. A Dir
 *     is Dir whatever its name; the shell makes one named here its Here.
 */
giving_of :: fn(manifest : ptr[schema.Schema], place : usize) -> Giving {
    type :: schema.type_in(manifest, place) or_return Giving.Other
    if type.size != 4 || (type.kind != .Struct && type.kind != .Alias) {
        return .Value
    }
    kind := type.name
    inner := ""
    for character, i in type.name {
        if character == '[' {
            kind = slice(type.name, 0, i)
            inner = slice(type.name, i + 1, type.name.count - 1)
            break
        }
    }
    // Hosted, as the package's tests are, no type's a handle's
    handle := false
    #if OS == .SlopOS && (TARGET_ARCH == .x86_64 || TARGET_ARCH == .arm64) {
        handle = runtime.slop_os_kind_of(kind) != 0
    }
    if !handle {
        return .Value
    }
    // The protocol's own name, without its package
    for character, i in inner {
        if character == '.' {
            inner = slice(inner, i + 1, inner.count)
        }
    }
    if kind == "Stream" {
        return .Input
    }
    if kind == "Sink" {
        return .Output
    }
    if kind == "Channel" {
        if inner == "Terminal" {
            return .Terminal
        }
        if inner == "Dir" {
            return .Dir
        }
        if inner == "File" {
            return .File
        }
        if inner == "ReadOnlyFile" {
            return .ReadOnlyFile
        }
        if inner == "Powerbox" {
            return .Powerbox
        }
        if inner == "Network" {
            return .Network
        }
    }
    return .Other
}

/**
 * Find the type of the records a Stream[T] or Sink[T] reads or writes: its records member's elements'.
 *
 * @param manifest The program's manifest, only read.
 * @param place The Stream's or Sink's type's place among the manifest's types.
 * @return The records' type's place; schema.NOWHERE if the type has no records member that's an array.
 */
records_of :: fn(manifest : ptr[schema.Schema], place : usize) -> usize {
    type :: schema.type_in(manifest, place) or_return schema.NOWHERE
    for member in type.members {
        if member.name == "records" {
            records :: schema.type_in(manifest, member.type) or_return schema.NOWHERE
            if records.kind == .Array {
                return records.base
            }
        }
    }
    return schema.NOWHERE
}
