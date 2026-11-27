package disk_check

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import query from "std:os/slop_os/query"
import testing from "std:testing"
import test_kit from "../../test_kit"

/*
 * Indexes and queries (decisions/0201's 20i and 20j, 0202's 21e), on the system volume, through std's typed API:
 * indexes of a typed file's fields declared on its root, and refused beneath it as NotVolumeRoot, but found and asked
 * beneath it; typed files written beneath a directory and committed, queried by a comparison, by an and of two, and by
 * an or and a not, and by a text past what an index keeps, whole; and a live query that answers what matches, then a
 * file added and one removed as each commits. What it made is taken away again, its indexes dropped and its notes and
 * their directory removed, so later commits don't index them and the next run begins as this one did.
 */

/** The directory the check's typed files go in, beneath the system volume's root. */
QUERIED :: "Queried notes"
/** How long an event of the live query is waited for, in nanoseconds: 10 s, as an emulated machine is slow. */
EVENT_WAIT : u64 : 10_000_000_000
/** Two titles alike in their first 300 bytes, past the 255 an index keeps of a text, which differ after. */
LONG_ONE :: "a long title, the same for its first 300 bytes: ................................................................................................................................................................................................................................................................ then one"
LONG_TWO :: "a long title, the same for its first 300 bytes: ................................................................................................................................................................................................................................................................ then two"
/** The names of every note the check may write in QUERIED, each removed by clean_up. */
NOTE_NAMES :: string.["one", "two", "three", "four", "long one", "long two"]

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
    // What an earlier run left, if it failed, taken away first; and what this one makes, once it's done
    clean_up(root)
    defer clean_up(root)
    made :: os.make_directory_in(root, QUERIED)
    testing.require_none(t, made, "a directory for the notes is made on the system volume")?
    opening :: os.open_directory_in(root, QUERIED)
    notes :: testing.require_ok(t, opening, "the notes' directory opens")?
    defer os.close_directory(notes)
    beneath :: os.declare_index[QueryNote](notes, "level")
    testing.expect(t, beneath is_error, "an index isn't declared from beneath the volume's root")
    testing.expect_eq(t, refusal_beneath(notes), files.FileError.NotVolumeRoot, "the refusal says it isn't the root")

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

    // Found and asked beneath the root, not on it: an or of a not, level 1 or not under 3
    found_beneath :: os.index_of[QueryNote](notes, "level")
    testing.expect_eq(t, (found_beneath or_else os.IndexFound.{}).number, level, "an index is found beneath the root")
    either := os.Predicate.{}
    defer os.free_predicate(&either)
    testing.require_none(t, os.where_number[QueryNote](notes, &either, "level", .Equal, 1), "a comparison is made beneath the root")?
    testing.require_none(t, os.where_number[QueryNote](notes, &either, "level", .Less, 3), "a second comparison is made")?
    os.negate(&either)
    os.either(&either)
    asking_either :: os.query_in(notes, &either)
    found_either := testing.require_ok(t, asking_either, "a query of an or of a not is answered")?
    defer os.free_matches(&found_either)
    testing.expect_eq(t, found_either.count, 2, "one note's level is 1, one's isn't under 3")
    testing.expect(t, has_name(&found_either, "one") && has_name(&found_either, "three"), "they're one and three")
    // A title past what an index keeps, compared whole
    testing.require_none(t, write_titled(notes, "long one", 5, LONG_ONE), "a note with a long title is written")?
    testing.require_none(t, write_titled(notes, "long two", 5, LONG_TWO), "another, alike in all an index keeps")?
    testing.require(t, synced(system.end, port), "the long notes commit")?
    long := os.Predicate.{}
    defer os.free_predicate(&long)
    testing.require_none(t, os.where_text[QueryNote](notes, &long, "title", .Equal, LONG_TWO), "a long text is compared")?
    asking_long :: os.query_in(notes, &long)
    found_long := testing.require_ok(t, asking_long, "a query of a long text is answered")?
    defer os.free_matches(&found_long)
    testing.expect_eq(t, found_long.count, 1, "only the note whose whole title is the text matches")
    testing.expect(t, has_name(&found_long, "long two"), "it's the second")
    testing.require_none(t, os.delete_file_in(notes, "long one"), "the first long note is removed")?
    testing.require_none(t, os.delete_file_in(notes, "long two"), "the second is")?
    testing.require(t, synced(system.end, port), "their removal commits")?

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
    // Its index dropped, the live query ends, its slot let go
    testing.require_none(t, os.drop_index(root, level), "the level's index is dropped")?
    ended :: os.next_live_event(&live, name, (slop_os.clock_monotonic() or_else 0) + EVENT_WAIT)
    testing.expect(t, ended is_error, "a live query whose index is dropped ends")
    return .Ok
}

/**
 * Take away what the check makes on the system volume: its indexes dropped, its notes and their directory removed,
 * each one that isn't there passed over.
 *
 * @param root A connection to the system volume's root, which stays the caller's.
 */
clean_up :: fn(root : os.Directory) {
    for field in string.["level", "title"] {
        match os.index_of[QueryNote](root, field) {
            case Ok(found) => _ = os.drop_index(root, found.number)
            case Error(error) => {}
        }
    }
    for note in NOTE_NAMES {
        path : u8[64]
        length : usize = 0
        for part in string.[QUERIED, "/", note] {
            for character in part {
                if length < path.count {
                    path[length] = cast[u8](character)
                    length += 1
                }
            }
        }
        _ = os.delete_file_in(root, string_of(&path[0], length))
    }
    _ = os.remove_directory_in(root, QUERIED)
}

/**
 * Ask a directory beneath the volume's root to drop an index, which only the root may.
 *
 * @param directory The directory, which stays the caller's.
 * @return What it was refused with; WrongType if it wasn't refused, or didn't answer.
 */
refusal_beneath :: fn(directory : os.Directory) -> files.FileError {
    state :: os.directory_of(directory)
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .DropIndex(1)
    into := os.Incoming.{}
    match ask_dir(state.end, state.port, &out, &into) {
        case Failed(failure) => return failure
        case _ => return .WrongType
    }
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
    return write_titled(directory, name, level, name)
}

/**
 * Write a typed note with a title of its own.
 *
 * @param directory The directory it's written in, which stays the caller's.
 * @param name Its name there.
 * @param level Its level.
 * @param title Its title, which may be longer than a name can be.
 * @return Null once it's written; why not, as os.write_typed_in says.
 */
write_titled :: fn(directory : os.Directory, name : string, level : i32, title : string) -> OsError? {
    out := os.Outgoing.{}
    note :: os.begin[QueryNote](&out)
    note.level = level
    note.title = os.append(&out, string_bytes(title))
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
