package disk_check

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import query from "std:os/slop_os/query"
import testing from "std:testing"
import test_kit from "../../test_kit"

/*
 * Indexes and queries (decisions/0201's 20i and 20j), on the system volume, through std's typed API: indexes of a
 * typed file's fields declared, typed files written beneath a directory and committed, queried by a comparison and by
 * an and of two, and a live query that answers what matches, then a file added and one removed as each commits.
 */

/** The directory the check's typed files go in, beneath the system volume's root. */
QUERIED :: "Queried notes"
/** How long an event of the live query is waited for, in nanoseconds: 10 s, as an emulated machine is slow. */
EVENT_WAIT : u64 : 10_000_000_000

/** The typed files the check writes and asks after: a level, whether it's done, and a title. */
QueryNote :: struct {
    /** Its level, which an index is declared of. */
    level : i32,
    /** Whether it's done, which isn't indexed. */
    done : bool,
    /** Its title, UTF-8, which an index is declared of. */
    title : slop_os.Relative[u8],
}

/**
 * Check indexes, queries and a live query on the system volume.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the system volume wasn't given, a port or a directory couldn't be had, an index
 *     couldn't be declared, a file written, or the live query opened.
 */
indexes_answer_queries_and_live_queries_follow_commits #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    bound :: os.port_for(slop_os.startup_block().budget, system.end)
    port :: testing.require_some(t, bound, "the budget has room for a port")?
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    connected :: second_connection(system, port)
    root :: testing.require_some(t, connected, "the system volume takes a second connection to its root")?
    defer os.close_directory(root)
    made :: os.make_directory_in(root, QUERIED)
    testing.require_none(t, made, "a directory for the notes is made on the system volume")?
    opening :: os.open_directory_in(root, QUERIED)
    notes :: testing.require_ok(t, opening, "the notes' directory opens")?
    defer os.close_directory(notes)

    declaring_level :: os.declare_index[QueryNote](root, "level")
    level :: testing.require_ok(t, declaring_level, "an index of a typed file's integer field is declared")?
    again :: os.declare_index[QueryNote](root, "level")
    testing.expect_eq(t, again or_else 0, level, "declaring it again gives the index declared")
    declaring_title :: os.declare_index[QueryNote](root, "title")
    testing.require_ok(t, declaring_title, "an index of a typed file's text field is declared")?
    refused :: os.declare_index[QueryNote](root, "done ")
    testing.expect(t, refused is_error, "a field the type hasn't can't be indexed")
    for each in NoteOf.[NoteOf.{"one", 1}, NoteOf.{"two", 2}, NoteOf.{"three", 3}] {
        testing.require_none(t, write_note(notes, each.name, each.level), "a typed note is written")?
    }
    testing.require(t, synced(system.end, port), "the notes commit, and their index entries with them")?

    // Queried: by a comparison, then by an and of two indexes
    at_least_two := os.Predicate.{}
    defer os.free_predicate(&at_least_two)
    testing.require_none(
        t,
        os.where_number[QueryNote](root, &at_least_two, "level", .GreaterOrEqual, 2),
        "a comparison of an indexed field is made"
    )?
    asking :: os.query_in(notes, &at_least_two)
    found := testing.require_ok(t, asking, "a query of the notes is answered")?
    defer os.free_matches(&found)
    testing.expect_eq(t, found.count, 2, "two notes have a level of at least 2")
    testing.expect(t, has_name(&found, "two") && has_name(&found, "three"), "they're named relative to the directory")
    both := os.Predicate.{}
    defer os.free_predicate(&both)
    testing.require_none(
        t,
        os.where_number[QueryNote](root, &both, "level", .Greater, 1),
        "a comparison of the level is made"
    )?
    testing.require_none(
        t,
        os.where_text[QueryNote](root, &both, "title", .NotEqual, "two"),
        "a comparison of the title is made"
    )?
    os.both(&both)
    asking_both :: os.query_in(root, &both)
    found_both := testing.require_ok(t, asking_both, "a query of two indexes is answered beneath the root")?
    defer os.free_matches(&found_both)
    testing.expect_eq(t, found_both.count, 1, "one note's level is past 1 and its title isn't two")
    testing.expect(
        t,
        has_name(&found_both, "Queried notes/three"),
        "beneath the root, its name is its path from the root"
    )

    // Live: what matches, then a note added and one removed, as each commits
    opening_live :: os.open_live_query(notes, &at_least_two)
    live := testing.require_ok(t, opening_live, "a live query is opened")?
    defer os.close_live_query(&live)
    name : u8[256]
    matched := 0
    loop {
        event :: next_event(t, &live, name)?
        if event.kind == .Current {
            break
        }
        testing.expect_eq(t, event.kind, query.EventKind.Matched, "a live query first answers what matches")
        matched += 1
    }
    testing.expect_eq(t, matched, 2, "the live query matches the two notes the query found")
    testing.require_none(t, write_note(notes, "four", 4), "a note that matches is written")?
    testing.require(t, synced(system.end, port), "the new note commits")?
    added :: next_event(t, &live, name)?
    testing.expect_eq(t, added.kind, query.EventKind.Added, "a note committed that matches is Added")
    shown :: if added.name_bytes <= name.count { added.name_bytes } else { cast[usize](0) }
    testing.expect(t, same_text(view_of(&name[0], shown), "four"), "the note added is named as it's written")
    testing.require_none(t, os.delete_file_in(notes, "two"), "a note that matched is removed")?
    testing.require(t, synced(system.end, port), "the removal commits")?
    gone :: next_event(t, &live, name)?
    testing.expect_eq(t, gone.kind, query.EventKind.Gone, "a note that matched and is removed is Gone")
    testing.expect_eq(t, gone.name_bytes, 0, "a note that's gone has no name")
    return .Ok
}

/** A note to write: its name and level. */
NoteOf :: struct {
    /** Its name, in the notes' directory, and its title. */
    name : string,
    /** Its level. */
    level : i32,
}

/**
 * Write a typed note.
 *
 * @param directory The directory it's written in, which stays the caller's.
 * @param name Its name there, and its title.
 * @param level Its level.
 * @return Null once it's written; why not, as os.write_typed_in says.
 */
write_note :: fn(directory : os.Directory, name : string, level : i32) -> OsError? {
    out := os.Outgoing.{}
    note :: os.begin[QueryNote](&out)
    note.level = level
    note.title = os.append(&out, string_bytes(name))
    return os.write_typed_in[QueryNote](directory, name, os.value_bytes(&out))
}

/**
 * Commit everything changed on a volume, with a Sync.
 *
 * @param end A dir connection to the volume, kept by the caller.
 * @param port A port bound to end.
 * @return Whether it answered Done.
 */
synced :: fn(end : slop_os.Channel, port : slop_os.Port) -> bool {
    into := os.Incoming.{}
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Sync
    match ask_dir(end, port, &out, &into) {
        case Done => return true
        case _ => return false
    }
}

/**
 * Wait for a live query's next event, failing the test if none comes in EVENT_WAIT.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param live The live query.
 * @param name Where the event's file's name goes.
 * @return The event; Error(Failed), the failure recorded, if none came or the query failed.
 */
next_event :: fn(
    t : ptr[mut testing.T],
    live : ptr[mut os.LiveQuery],
    name : mut u8[]
) -> Result[os.LiveEvent, testing.Stopped] {
    deadline :: (slop_os.clock_monotonic() or_else 0) + EVENT_WAIT
    waiting :: os.next_live_event(live, name, deadline)
    event :: testing.require_ok(t, waiting, "a live query answers its next event")?
    return testing.require_some(t, event, "a live query's next event comes within 10 seconds")
}

/**
 * Tell whether a query found a file of a name.
 *
 * @param found What query_in found, only read.
 * @param name The name looked for.
 * @return Whether one of them has it, byte for byte.
 */
has_name :: fn(found : ptr[os.QueryMatch[..]], name : string) -> bool {
    for each in found^ {
        if each.name == name {
            return true
        }
    }
    return false
}
