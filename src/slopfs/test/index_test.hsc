package slopfs_test

import runtime from "base:runtime"
import memory from "std:memory"
import schema from "std:schema"
import testing from "std:testing"
import slopfs from ".."

/*
 * Indexes and queries (index.hsc, query.hsc, decisions/0201's 20i and 20j), on a volume apart and on one in its
 * container: an index declared by a schema's bytes and a field, built from the typed files there are, kept with
 * writes, renames, removals and replacements as each commits, forgotten with what forget forgets, and kept in a
 * snapshot as its tree had it; and queries over them, bounded by an index's range or walking it, through and, or and
 * not, beneath a directory, a bounded number of files a step, going on from a cursor that a removal doesn't move.
 * What an index keeps is looked at record by record too (index_records), so a removal or a drop is seen to leave
 * nothing behind. Texts longer than an index's records keep are compared by their whole values, and indexes that
 * can't be made at a commit leave it to be forgotten whole (decisions/0202's 21e).
 */

/** Where a typed file's text is, from its value's start, as a message's Relative is; it names its elements' type. */
Relative :: struct[T] {
    /** Where the elements start, in bytes from the value's start. */
    offset : u32,
    /** How many elements. */
    count : u32,
    /** Holds nothing; it names T. */
    elements : T[0],
}

/** The typed files the tests index: a value whose fields are each kind an index holds, and one that isn't. */
Task :: struct {
    /** An unsigned field. */
    size : u64,
    /** A signed field. */
    level : i32,
    /** A bool field. */
    done : bool,
    /** A text field, its bytes after the value's fixed part. */
    name : Relative[u8],
    /** A field no index can be of. */
    weight : f32,
}

/** How many bytes a Task's value takes, its fixed part and its name, at most. */
VALUE_BYTES :: 1024

/** A Task's value as a typed file holds it. */
Value :: struct {
    /** Its bytes, the first count of them. */
    bytes : u8[VALUE_BYTES],
    /** How many of bytes are the value's. */
    count : usize,
}

/**
 * Make a Task's value whose name's Relative is as given, not followed by the name's bytes.
 *
 * @param size Its size field.
 * @param offset The name's Relative's offset, in bytes from the value's start.
 * @param count The name's Relative's count.
 * @return The value: its fixed part alone.
 */
task_with_name_at :: fn(size : u64, offset : u32, count : u32) -> Value {
    made := Value.{}
    fixed :: size_of(Task)
    task := Task.{size = size}
    task.name.offset = offset
    task.name.count = count
    slopfs.copy_bytes(made.bytes, 0, view_of(cast[ptr[u8]](&task), fixed))
    made.count = fixed
    return made
}

/**
 * Make a Task's value: its fixed part, then its name's bytes.
 *
 * @param size Its size field.
 * @param level Its level field.
 * @param done Its done field.
 * @param name Its name; past what VALUE_BYTES leaves, it's cut.
 * @return The value.
 */
task_value :: fn(size : u64, level : i32, done : bool, name : string) -> Value {
    made := Value.{}
    fixed :: size_of(Task)
    room :: VALUE_BYTES - fixed
    count :: if name.count < room { name.count } else { room }
    task := Task.{size = size, level = level, done = done, weight = 1.5}
    task.name.offset = cast[u32](fixed)
    task.name.count = cast[u32](count)
    slopfs.copy_bytes(made.bytes, 0, view_of(cast[ptr[u8]](&task), fixed))
    slopfs.copy_bytes(made.bytes, fixed, slopfs.part(string_bytes(name), 0, count))
    made.count = fixed + count
    return made
}

/** Task's schema's bytes and hash, as a client declaring an index would give them. */
Schema :: struct {
    /** The schema's bytes, freed by free_schema. */
    bytes : u8[..],
    /** Its hash, a typed file of Task's. */
    hash : u8[32],
}

/**
 * Write Task's schema.
 *
 * @return Its bytes and hash; the caller frees the bytes with free_schema.
 */
task_schema :: fn() -> Schema {
    made := Schema.{hash = schema.hash(type_info_of(Task))}
    schema.write(type_info_of(Task), &made.bytes)
    return made
}

/**
 * Give back a schema's bytes.
 *
 * @param made The schema, from task_schema.
 */
free_schema :: fn(made : ptr[mut Schema]) {
    runtime.array_free(&made.bytes)
}

/**
 * Make a typed file of Task's, or write one again, whole: emptied, then its value written, as a typed write is.
 *
 * @param volume The volume.
 * @param directory The directory it's in.
 * @param name Its name there.
 * @param hash Task's schema hash, which a new file is given.
 * @param value Its value.
 * @return The file's ID; or why it couldn't be made or written.
 */
write_task :: fn(
    volume : ptr[mut slopfs.Volume],
    directory : u64,
    name : string,
    hash : u8[32],
    value : Value
) -> Result[u64, slopfs.Error] {
    file := slopfs.lookup(volume, directory, name)? or_else 0
    if file == 0 {
        file = slopfs.create(volume, directory, name, .File)?
        slopfs.set_schema(volume, file, hash)?
    }
    slopfs.set_size(volume, file, 0)?
    slopfs.write(volume, file, 0, slopfs.part(value.bytes, 0, value.count))?
    return .Ok(file)
}

/**
 * Make a comparison term.
 *
 * @param index The index's number.
 * @param comparison How its field is compared.
 * @param number The constant, for an integer or a bool.
 * @return The term.
 */
compare :: fn(index : u64, comparison : slopfs.Comparison, number : u64) -> slopfs.Term {
    return slopfs.Term.{kind = .Compare, comparison = comparison, index = index, number = number}
}

/**
 * Make a comparison of a text field.
 *
 * @param index The index's number.
 * @param comparison How its field is compared.
 * @param text The constant.
 * @return The term.
 */
compare_text :: fn(index : u64, comparison : slopfs.Comparison, text : string) -> slopfs.Term {
    term := slopfs.Term.{kind = .Compare, comparison = comparison, index = index}
    slopfs.copy_bytes(term.text, 0, string_bytes(text))
    term.text_bytes = if text.count < term.text.count { text.count } else { term.text.count }
    return term
}

/**
 * Make a term that joins or turns those before it.
 *
 * @param kind And, Or or Not.
 * @return The term.
 */
join :: fn(kind : slopfs.TermKind) -> slopfs.Term {
    return slopfs.Term.{kind = kind}
}

/**
 * Plan a query.
 *
 * @param volume The volume.
 * @param terms The predicate's terms, in postfix order.
 * @return The plan, from slopfs.make, the caller's to free with runtime.free; or why it couldn't be planned.
 */
planned :: fn(volume : ptr[mut slopfs.Volume], terms : slopfs.Term[]) -> Result[ptr[mut slopfs.Plan], slopfs.Error] {
    plan :: slopfs.make(slopfs.Plan)?
    for term, i in terms {
        if i < plan.terms.count {
            plan.terms[i] = term
        }
    }
    plan.count = terms.count
    match slopfs.plan_query(volume, plan) {
        case Ok => return .Ok(plan)
        case Error(error) => {
            runtime.free(plan)
            return .Error(error)
        }
    }
}

/**
 * Run a query beneath a directory, every file it finds counted, looking at up to a limit of files a step.
 *
 * @param volume The volume.
 * @param directory The directory it's asked beneath.
 * @param terms The predicate's terms, in postfix order.
 * @param limit The most files a step looks at, as query_next takes it.
 * @return How many files it found, each step that found none not counted; or why it couldn't be planned or run.
 */
run_limited :: fn(
    volume : ptr[mut slopfs.Volume],
    directory : u64,
    terms : slopfs.Term[],
    limit : u64
) -> Result[u64, slopfs.Error] {
    plan :: planned(volume, terms)?
    defer runtime.free(plan)
    count := cast[u64](0)
    cursor := slopfs.QueryCursor.{}
    loop {
        found :: slopfs.query_next(volume, plan, directory, cursor, limit)? or_break
        if found.file != 0 {
            count += 1
        }
        cursor = found.next
    }
    return .Ok(count)
}

/**
 * Run a query beneath a directory, every file it finds counted, as a server's request steps do.
 *
 * @param volume The volume.
 * @param directory The directory it's asked beneath.
 * @param terms The predicate's terms, in postfix order.
 * @return How many files it found; or why it couldn't be planned or run.
 */
run_query :: fn(volume : ptr[mut slopfs.Volume], directory : u64, terms : slopfs.Term[]) -> Result[u64, slopfs.Error] {
    return run_limited(volume, directory, terms, slopfs.QUERY_LOOKS)
}

/** What an index keeps, counted record by record. */
IndexRecords :: struct {
    /** Its buckets. */
    buckets : u64,
    /** The files its buckets name, all of them. */
    bucket_files : u64,
    /** Whether every bucket's files are in order of ID, each once. */
    ordered : bool,
    /** Its spilled records. */
    spills : u64,
    /** The files' records of it, (file, IndexedBy, number), of every object, there or not. */
    indexed_by : u64,
}

/**
 * Count what an index keeps in a volume's tree, whether its declaration is there or not.
 *
 * @param volume The volume, only read.
 * @param number The index's number.
 * @return Its buckets, their files, its spilled records and the files' records of it; or why the tree couldn't be
 *     read.
 */
index_records :: fn(volume : ptr[mut slopfs.Volume], number : u64) -> Result[IndexRecords, slopfs.Error] {
    counted := IndexRecords.{ordered = true}
    bucket :: slopfs.make(slopfs.Bucket)?
    defer runtime.free(bucket)
    object :: slopfs.INDEX_OBJECT_BASE | number
    key := cast[u64](0)
    loop {
        found :: slopfs.tree_next(
            volume.nodes,
            &volume.tree,
            slopfs.key_of(object, .IndexEntry, key),
            slopfs.bucket_bytes(bucket)
        )? or_break
        if found.key.object != object || found.key.kind != cast[u8](slopfs.RecordKind.IndexEntry) {
            break
        }
        counted.buckets += 1
        files :: slopfs.files_in(found.bytes)?
        counted.bucket_files += cast[u64](files)
        for i in 1..<files {
            before :: i - 1
            if i < bucket.files.count && before < bucket.files.count {
                if cast[u64](bucket.files[before]) >= cast[u64](bucket.files[i]) {
                    counted.ordered = false
                }
            }
        }
        if found.key.offset == 0xffffffffffffffff {
            break
        }
        key = found.key.offset + 1
    }
    value : u8[8]
    file := cast[u64](0)
    loop {
        found :: slopfs.tree_next(volume.nodes, &volume.tree, slopfs.key_of(object, .IndexSpill, file), value)?
            or_break
        if found.key.object != object || found.key.kind != cast[u8](slopfs.RecordKind.IndexSpill) {
            break
        }
        counted.spills += 1
        file = found.key.offset + 1
    }
    // Every object's (IndexedBy, number) record, by the tree's keys, so one left by a file that's gone is counted
    at := cast[u64](1)
    scratch : u8[1]
    loop {
        if at >= slopfs.INDEX_OBJECT_BASE {
            break
        }
        found :: slopfs.tree_next(volume.nodes, &volume.tree, slopfs.key_of(at, .IndexedBy, number), scratch)?
            or_break
        owner :: found.key.object
        if owner >= slopfs.INDEX_OBJECT_BASE {
            break
        }
        if owner == at {
            if found.key.kind == cast[u8](slopfs.RecordKind.IndexedBy) && found.key.offset == number {
                counted.indexed_by += 1
            }
            at = owner + 1
        }
        else {
            at = owner
        }
    }
    return .Ok(counted)
}

/**
 * Count what an index keeps, failing the test if the tree can't be read.
 *
 * @param t The test's state.
 * @param volume The volume.
 * @param number The index's number.
 * @return What it keeps; Error(Failed), recorded, if the tree couldn't be read.
 */
records_of :: fn(
    t : ptr[mut testing.T],
    volume : ptr[mut slopfs.Volume],
    number : u64
) -> Result[IndexRecords, testing.Stopped] {
    return testing.require_ok(t, index_records(volume, number), "an index's records are read")
}

/**
 * Write a Task's value as a file's new value, whole.
 *
 * @param volume The volume.
 * @param file The file, a typed one of Task's.
 * @param value Its value.
 * @return Done; or why it couldn't be written.
 */
rewrite :: fn(volume : ptr[mut slopfs.Volume], file : u64, value : Value) -> Result[void, slopfs.Error] {
    slopfs.set_size(volume, file, 0)?
    slopfs.write(volume, file, 0, slopfs.part(value.bytes, 0, value.count))?
    return .Ok
}

/**
 * Get the error a declaration failed with.
 *
 * @param result What declare_index gave.
 * @return Its error; null if it worked.
 */
failed_with :: fn(result : Result[u64, slopfs.Error]) -> slopfs.Error? {
    match result {
        case Ok(number) => return null
        case Error(error) => return error
    }
}

/**
 * Count the files a query finds beneath a directory.
 *
 * @param volume The volume.
 * @param directory The directory.
 * @param terms The predicate's terms.
 * @return How many; 0xffffffff if the query failed.
 */
count_of :: fn(volume : ptr[mut slopfs.Volume], directory : u64, terms : slopfs.Term[]) -> u64 {
    match run_query(volume, directory, terms) {
        case Ok(found) => return found
        case Error(error) => return 0xffffffff
    }
}

an_index_is_built_from_what_is_there_and_refuses_what_it_cant_hold #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    for i in 0..<6 {
        text : u8[16]
        length :: name_of_number(text, i)
        name :: string_of(&text[0], length)
        writing :: write_task(volume, root, name, task.hash, task_value(cast[u64](i * 10), cast[i32](i) - 3, i % 2 == 0, name))
        require_done(t, writing, "a typed file is made and written")?
    }
    // An untyped file, and one of another type, aren't indexed
    making_plain :: slopfs.create(volume, root, "plain", .File)
    plain :: testing.require_ok(t, making_plain, "a plain file is made")?
    writing_plain :: slopfs.write(volume, plain, 0, slopfs.part(task_value(5, 0, true, "x").bytes, 0, 40))
    require_done(t, writing_plain, "a plain file is written with a Task's bytes")?
    testing.require(t, commit_apart(kept.made), "the files commit")?

    declaring :: slopfs.declare_index(volume, task.bytes, "level")
    level :: testing.require_ok(t, declaring, "an index of a signed field is declared")?
    again :: slopfs.declare_index(volume, task.bytes, "level")
    testing.expect_eq(t, again or_else 0, level, "declaring it again gives its number again")
    by_name :: slopfs.declare_index(volume, task.bytes, "name")
    name_index :: testing.require_ok(t, by_name, "an index of a text field is declared")?
    testing.expect_ne(t, name_index, level, "a second index has a number of its own")
    not_indexable : slopfs.Error? = slopfs.Error.NotIndexable
    floating :: slopfs.declare_index(volume, task.bytes, "weight")
    testing.expect_eq(t, failed_with(floating), not_indexable, "a float field can't be indexed")
    missing :: slopfs.declare_index(volume, task.bytes, "nothing")
    testing.expect_eq(t, failed_with(missing), not_indexable, "a field that isn't there can't be")
    broken :: slopfs.declare_index(volume, slopfs.part(task.bytes, 0, 10), "level")
    testing.expect_eq(t, failed_with(broken), not_indexable, "bytes that aren't a schema can't be")
    testing.require(t, commit_apart(kept.made), "the indexes commit")?

    // Built from what was there: levels -3 to 2, names file-0 to file-5
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(level, .Equal, 0)]), 1, "one file has level 0")
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare(level, .Less, cast[u64](cast[i64](-1)))]),
        2,
        "negative levels order before -1 as signed numbers do: -3 and -2"
    )
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare(level, .GreaterOrEqual, cast[u64](cast[i64](-1)))]),
        4,
        "-1 and up: -1, 0, 1, 2"
    )
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare(level, .NotEqual, 0)]),
        5,
        "not equal walks the whole index: every typed file but one, and no plain file"
    )
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare_text(name_index, .Equal, "file-3")]),
        1,
        "a text is found by its whole value"
    )
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare_text(name_index, .Greater, "file-3")]),
        2,
        "texts order byte by byte: file-4 and file-5"
    )
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare_text(name_index, .Equal, "file-")]),
        0,
        "a text that starts another isn't equal to it"
    )
    // and, or and not, across two indexes of one schema
    testing.expect_eq(
        t,
        count_of(
            volume,
            root,
            slopfs.Term.[
                compare(level, .GreaterOrEqual, 0),
                compare_text(name_index, .NotEqual, "file-4"),
                join(.And)
            ]
        ),
        2,
        "level at least 0 and not named file-4: file-3 and file-5"
    )
    testing.expect_eq(
        t,
        count_of(
            volume,
            root,
            slopfs.Term.[
                compare(level, .Equal, cast[u64](cast[i64](-3))),
                compare(level, .Equal, 2),
                join(.Or),
                join(.Not)
            ]
        ),
        4,
        "not either end: the four between"
    )
    malformed :: run_query(volume, root, slopfs.Term.[compare(level, .Equal, 0), join(.And)])
    testing.expect(t, malformed is_error, "an and with one arm doesn't hold together")
    unknown :: run_query(volume, root, slopfs.Term.[compare(99, .Equal, 0)])
    testing.expect(t, unknown is_error, "an index that isn't there can't be asked")
    text_for_number :: run_query(volume, root, slopfs.Term.[compare_text(level, .Equal, "3")])
    testing.expect(t, text_for_number is_error, "a text isn't compared with a number's field")
    return .Ok
}

an_index_follows_writes_renames_removals_and_replacements_as_they_commit #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "size")
    size :: testing.require_ok(t, declaring, "an index of an unsigned field is declared on an empty volume")?
    making_sub :: slopfs.create(volume, root, "sub", .Directory)
    sub :: testing.require_ok(t, making_sub, "a directory is made")?
    making :: write_task(volume, sub, "a", task.hash, task_value(7, 0, false, "a"))
    a :: testing.require_ok(t, making, "a typed file is made in it")?
    seven :: slopfs.Term.[compare(size, .Equal, 7)]
    testing.expect_eq(t, count_of(volume, root, seven), 0, "a file isn't indexed until its transaction commits")
    testing.require(t, commit_apart(kept.made), "the file commits")?
    testing.expect_eq(t, count_of(volume, root, seven), 1, "committed, it's indexed")
    testing.expect_eq(t, count_of(volume, sub, seven), 1, "and found beneath its own directory")

    // Written again: its old entry gone with the commit
    rewriting :: write_task(volume, sub, "a", task.hash, task_value(8, 0, false, "a"))
    require_done(t, rewriting, "the file is written again")?
    testing.require(t, commit_apart(kept.made), "the write commits")?
    testing.expect_eq(t, count_of(volume, root, seven), 0, "its old value isn't found")
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 8)]), 1, "its new one is")
    // Emptied and not yet written again, as a typed write half done is: not indexed until it holds a value
    emptying :: slopfs.set_size(volume, a, 4)
    require_done(t, emptying, "the file is cut short of a value")?
    testing.require(t, commit_apart(kept.made), "the half-done write commits")?
    everything :: slopfs.Term.[compare(size, .GreaterOrEqual, 0)]
    testing.expect_eq(t, count_of(volume, root, everything), 0, "a value cut short isn't indexed")
    finishing :: write_task(volume, sub, "a", task.hash, task_value(8, 0, false, "a"))
    require_done(t, finishing, "the file is written whole again")?
    testing.require(t, commit_apart(kept.made), "the finished write commits")?
    testing.expect_eq(t, count_of(volume, root, everything), 1, "a value written whole is indexed again")

    // Renamed out of sub: found beneath the root, not beneath sub
    renaming :: slopfs.rename(volume, sub, "a", root, "b")
    require_done(t, renaming, "the file is moved to the root")?
    testing.require(t, commit_apart(kept.made), "the rename commits")?
    testing.expect_eq(t, count_of(volume, root, everything), 1, "moved, it's still found beneath the root")
    testing.expect_eq(t, count_of(volume, sub, everything), 0, "but not beneath where it was")
    // Replaced whole: the replacement indexed, the file it replaced not
    orphaning :: slopfs.create_orphan(volume, root)
    replacement :: testing.require_ok(t, orphaning, "an orphan is made to replace it")?
    typing :: slopfs.set_schema(volume, replacement, task.hash)
    require_done(t, typing, "the replacement is typed")?
    filling :: slopfs.write(volume, replacement, 0, slopfs.part(task_value(9, 0, false, "b").bytes, 0, size_of(Task) + 1))
    require_done(t, filling, "the replacement is written")?
    testing.require(t, commit_apart(kept.made), "the replacement, not yet installed, commits")?
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 9)]), 0, "an orphan isn't found")
    installing :: slopfs.install(volume, root, "b", replacement)
    replaced :: testing.require_ok(t, installing, "the replacement is installed")?
    testing.require(t, commit_apart(kept.made), "the install commits")?
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 9)]), 1, "installed, it's found")
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 8)]), 0, "what it replaced isn't")
    releasing :: slopfs.release_orphan(volume, replaced or_else 0)
    require_done(t, releasing, "the replaced file is given back")?
    // Removed: gone from the index, its bucket and its record of it with it
    removing :: slopfs.remove(volume, root, "b")
    require_done(t, removing, "the file is removed")?
    testing.require(t, commit_apart(kept.made), "the removal commits")?
    testing.expect_eq(t, count_of(volume, root, everything), 0, "a file removed isn't found")
    removed :: records_of(t, volume, size)?
    testing.expect_eq(t, removed.buckets, 0, "a removed file's bucket, its only one, goes with it")
    testing.expect_eq(t, removed.indexed_by, 0, "and so does its record of the index")
    // Dropped, the index's records all go, and its number can't be asked
    for i in 0..<3 {
        text : u8[16]
        length :: name_of_number(text, i)
        name :: string_of(&text[0], length)
        writing :: write_task(volume, root, name, task.hash, task_value(cast[u64](i), 0, false, "x"))
        require_done(t, writing, "files are made for the index to hold when it's dropped")?
    }
    testing.require(t, commit_apart(kept.made), "the files commit")?
    held :: records_of(t, volume, size)?
    testing.expect_eq(t, held.indexed_by, 3, "each file has a record of the index")
    testing.expect_eq(t, held.bucket_files, 3, "and is in a bucket")
    dropping :: slopfs.drop_index(volume, size)
    require_done(t, dropping, "the index is dropped")?
    testing.expect(t, run_query(volume, root, everything) is_error, "a dropped index can't be asked")
    dropped :: records_of(t, volume, size)?
    testing.expect_eq(t, dropped.buckets + dropped.spills + dropped.indexed_by, 0, "a dropped index leaves no record")
    testing.expect(t, commit_apart(kept.made), "the dropped index commits")
    return .Ok
}

a_bucket_stays_in_order_so_a_walk_goes_on_past_a_removal_a_step_at_a_time #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "size")
    size :: testing.require_ok(t, declaring, "an index is declared")?
    // Ten files of one key, made in an order their IDs aren't, then written again in another, and two of another key
    files : u64[10]
    for i in 0..<10 {
        text : u8[16]
        length :: name_of_number(text, i)
        writing :: write_task(volume, root, string_of(&text[0], length), task.hash, task_value(5, 0, false, "x"))
        made :: testing.require_ok(t, writing, "a file of one key is made")?
        if cast[usize](i) < files.count {
            files[cast[usize](i)] = made
        }
    }
    testing.require(t, commit_apart(kept.made), "the files commit")?
    for i in 0..<10 {
        at :: cast[usize](9 - i)
        if at < files.count {
            require_done(t, rewrite(volume, files[at], task_value(5, 0, false, "x")), "a file is written again")?
        }
    }
    for i in 10..<12 {
        text : u8[16]
        length :: name_of_number(text, i)
        writing :: write_task(volume, root, string_of(&text[0], length), task.hash, task_value(6, 0, false, "x"))
        require_done(t, writing, "a file of another key is made")?
    }
    testing.require(t, commit_apart(kept.made), "the writes commit")?
    held :: records_of(t, volume, size)?
    testing.expect(t, held.ordered, "a bucket's files are in order of ID, however they were put in")
    testing.expect_eq(t, held.bucket_files, 12, "each file is in its key's bucket once")
    five :: slopfs.Term.[compare(size, .Equal, 5)]
    testing.expect_eq(
        t,
        run_limited(volume, root, five, 1) or_else 0,
        10,
        "a walk a file at a step finds what a whole one does, going on from where each step got to"
    )
    six :: slopfs.Term.[compare(size, .Equal, 6)]
    testing.expect_eq(
        t,
        run_limited(volume, root, six, 1) or_else 0,
        2,
        "a step looks at files before the range walked not at all"
    )

    // Three answered, then the first of them removed: the walk goes on from the third, missing none
    planning :: planned(volume, five)
    plan :: testing.require_ok(t, planning, "the query is planned")?
    defer runtime.free(plan)
    cursor := slopfs.QueryCursor.{}
    answered := cast[u64](0)
    first := cast[u64](0)
    loop {
        if answered == 3 {
            break
        }
        stepping :: slopfs.query_next(volume, plan, root, cursor, slopfs.QUERY_LOOKS)
        step :: testing.require_ok(t, stepping, "the walk steps")?
        found :: testing.require_some(t, step, "the walk finds the first three")?
        if answered == 0 {
            first = found.file
        }
        answered += 1
        cursor = found.next
    }
    testing.require(t, first == files[0], "the first file answered is the least ID")?
    removing :: slopfs.remove(volume, root, "file-0")
    require_done(t, removing, "the first file answered is removed")?
    testing.require(t, commit_apart(kept.made), "the removal commits")?
    rest := cast[u64](0)
    loop {
        stepping :: slopfs.query_next(volume, plan, root, cursor, slopfs.QUERY_LOOKS)
        step :: testing.require_ok(t, stepping, "the walk goes on")?
        found :: step or_break
        if found.file != 0 {
            rest += 1
        }
        cursor = found.next
    }
    testing.expect_eq(t, rest, 7, "the seven after the third are each found, none passed over for the removal")
    after :: records_of(t, volume, size)?
    testing.expect(t, after.ordered, "the bucket stays in order once a file's taken out")
    testing.expect_eq(t, after.bucket_files, 11, "and the removed file's gone from it")
    return .Ok
}

a_file_is_in_all_its_types_indexes_or_none_as_they_are_declared_and_dropped #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "size")
    size :: testing.require_ok(t, declaring, "an index of the size is declared")?
    good :: write_task(volume, root, "good", task.hash, task_value(1, 0, false, "good"))
    require_done(t, good, "a file whose every field holds is made")?
    // An empty text's Relative may point anywhere, as a message's may: it's indexed as empty
    empty :: write_task(volume, root, "empty", task.hash, task_with_name_at(2, 0, 0))
    require_done(t, empty, "a file with an empty name pointing before the value's end is made")?
    broken :: write_task(volume, root, "broken", task.hash, task_with_name_at(3, 1000, 4))
    require_done(t, broken, "a file whose name points past its value is made")?
    testing.require(t, commit_apart(kept.made), "the files commit")?
    everything :: slopfs.Term.[compare(size, .GreaterOrEqual, 0)]
    testing.expect_eq(t, count_of(volume, root, everything), 3, "all three are indexed by the size alone")

    by_name :: slopfs.declare_index(volume, task.bytes, "name")
    name :: testing.require_ok(t, by_name, "an index of the name is declared")?
    testing.expect_eq(t, count_of(volume, root, everything), 2, "the file whose name doesn't hold leaves the size's")
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare_text(name, .Equal, "")]),
        1,
        "the empty name is found as empty"
    )
    testing.expect_eq(t, (records_of(t, volume, size)?).indexed_by, 2, "two files have a record of the size's index")
    testing.require(t, commit_apart(kept.made), "the name's index commits")?

    dropping :: slopfs.drop_index(volume, name)
    require_done(t, dropping, "the name's index is dropped")?
    testing.expect_eq(t, count_of(volume, root, everything), 3, "dropped, the file it kept out is in the size's again")
    testing.expect_eq(t, (records_of(t, volume, size)?).indexed_by, 3, "with a record of it")
    testing.expect(t, commit_apart(kept.made), "the drop commits")
    return .Ok
}

a_bucket_full_of_one_value_spills_and_every_file_is_still_found #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    volume.history_bytes = 0
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "done")
    done :: testing.require_ok(t, declaring, "an index of a bool field is declared")?
    total :: slopfs.MAX_CHANGED + 40
    for i in 0..<total {
        text : u8[16]
        length :: name_of_number(text, cast[int](i))
        writing :: write_task(volume, root, string_of(&text[0], length), task.hash, task_value(0, 0, true, "x"))
        require_done(t, writing, "more files than a bucket holds, or the changes noted, are made, all done")?
    }
    // More changed than are noted, so every file is indexed again, past the bucket into records of their own
    testing.require(t, commit_apart(kept.made), "the files commit")?
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare(done, .Equal, 1)]),
        cast[u64](total),
        "every file is found, those past the bucket's room in records of their own"
    )
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(done, .Equal, 0)]), 0, "none isn't done")
    // One spilled and one in the bucket written again: each found under its new value, once
    for i in 0..<2 {
        text : u8[16]
        length :: name_of_number(text, if i == 0 { 1 } else { cast[int](total) - 1 })
        writing :: write_task(volume, root, string_of(&text[0], length), task.hash, task_value(0, 0, false, "x"))
        require_done(t, writing, "a file in the bucket and one spilled are written again")?
    }
    testing.require(t, commit_apart(kept.made), "the writes commit")?
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(done, .Equal, 0)]), 2, "both are found undone")
    testing.expect_eq(
        t,
        count_of(volume, root, slopfs.Term.[compare(done, .Equal, 1)]),
        cast[u64](total) - 2,
        "and neither is found done"
    )
    // Every file removed at once, past the changes noted: none is left in a bucket, a spilled record or a record of it
    for i in 0..<total {
        text : u8[16]
        length :: name_of_number(text, cast[int](i))
        removing :: slopfs.remove(volume, root, string_of(&text[0], length))
        require_done(t, removing, "every file is removed")?
    }
    testing.require(t, commit_apart(kept.made), "the removals commit")?
    left :: records_of(t, volume, done)?
    testing.expect_eq(t, left.buckets, 0, "no bucket is left")
    testing.expect_eq(t, left.spills, 0, "no spilled record is left")
    testing.expect_eq(t, left.indexed_by, 0, "no file's record of the index is left")
    return .Ok
}

an_index_forgets_with_its_transaction_and_a_snapshot_keeps_its_own #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    device :: formatted(t, BLOCKS, 0x60)?
    defer free_device(device)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    defer slopfs.unmount(container)
    creating :: create_test_volume(container, "indexed", false)
    volume :: testing.require_ok(t, creating, "a new container has room for a volume")?
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "size")
    size :: testing.require_ok(t, declaring, "an index is declared")?
    making :: write_task(volume, root, "a", task.hash, task_value(1, 0, false, "a"))
    require_done(t, making, "a typed file is made")?
    require_commit(t, container, "the index and the file commit")?
    one :: slopfs.Term.[compare(size, .Equal, 1)]
    two :: slopfs.Term.[compare(size, .Equal, 2)]

    // Forgotten: the write and its index entry both, the change noted with it
    committed :: slopfs.record_of(volume)
    rewriting :: write_task(volume, root, "a", task.hash, task_value(2, 0, false, "a"))
    require_done(t, rewriting, "the file is written again")?
    undone : slopfs.Change[..]
    defer runtime.array_free(&undone)
    slopfs.abandon_volume(container, volume.id, &undone)
    slopfs.forget(volume, committed)
    testing.expect_eq(t, volume.indexing.count, 0, "forgetting the changes forgets that they're to be indexed")
    require_commit(t, container, "a volume with its changes forgotten commits")?
    testing.expect_eq(t, count_of(volume, root, one), 1, "the file's old value is found, as it is")
    testing.expect_eq(t, count_of(volume, root, two), 0, "its forgotten one isn't")

    // A snapshot keeps the index as its tree had it
    taking :: slopfs.take_snapshot(container, volume.id, name_bytes("then"), 10)
    require_done(t, taking, "a snapshot is taken")?
    require_commit(t, container, "the snapshot commits")?
    changing :: write_task(volume, root, "a", task.hash, task_value(2, 0, false, "a"))
    require_done(t, changing, "the file is written after the snapshot")?
    require_commit(t, container, "the write after the snapshot commits")?
    testing.expect_eq(t, count_of(volume, root, two), 1, "the volume finds the file's new value")
    opening :: slopfs.open_snapshot(container, volume.id, name_bytes("then"), null)
    then :: testing.require_ok(t, opening, "the snapshot opens")?
    defer slopfs.free_volume(then)
    testing.expect_eq(t, count_of(then, root, one), 1, "the snapshot finds the value the file had when it was taken")
    testing.expect_eq(t, count_of(then, root, two), 0, "and not the one it was given after")
    return .Ok
}

/**
 * Make a text of a run of one byte then a word, as long as asked.
 *
 * @param count How long it is, at least the word's length.
 * @param tail The word it ends with; its bytes go last.
 * @return The text, on the heap, the caller's to give back with runtime.free_array of its bytes; empty without the
 *     memory.
 */
long_text :: fn(count : usize, tail : string) -> string {
    made, error :: runtime.new_array(u8, count)
    if error != null || made.count == 0 {
        return ""
    }
    for i in 0..<made.count {
        made[i] = cast[u8]('x')
    }
    for byte, i in string_bytes(tail) {
        at :: count - tail.count + i
        if at < made.count {
            made[at] = byte
        }
    }
    return string_of(&made[0], made.count)
}

/**
 * Count the files a text comparison finds, its constant kept whole in the plan as a server keeps one longer than an
 * index's records do.
 *
 * @param volume The volume.
 * @param index The text index's number.
 * @param comparison How the field is compared.
 * @param text The constant, whole.
 * @return How many files beneath the root it finds; or why it couldn't be planned or run.
 */
count_long :: fn(
    volume : ptr[mut slopfs.Volume],
    index : u64,
    comparison : slopfs.Comparison,
    text : string
) -> Result[u64, slopfs.Error] {
    plan :: slopfs.make(slopfs.Plan)?
    defer runtime.free(plan)
    plan.terms[0] = compare_text(index, comparison, text)
    if text.count > slopfs.INDEX_TEXT_BYTES {
        slopfs.copy_bytes(plan.texts, 0, string_bytes(text))
        plan.texts_used = text.count
        plan.terms[0].whole_offset = 0
        plan.terms[0].whole_bytes = text.count
    }
    plan.count = 1
    slopfs.plan_query(volume, plan)?
    count := cast[u64](0)
    cursor := slopfs.QueryCursor.{}
    loop {
        found :: slopfs.query_next(volume, plan, slopfs.ROOT_OBJECT, cursor, slopfs.QUERY_LOOKS)? or_break
        if found.file != 0 {
            count += 1
        }
        cursor = found.next
    }
    return .Ok(count)
}

a_long_text_is_compared_by_its_whole_value_past_what_an_index_keeps #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    kept :: kept_volume(t)?
    defer free_kept(kept)
    volume :: kept.made.volume
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "name")
    name :: testing.require_ok(t, declaring, "an index of a text field is declared")?
    /*
     * Three texts alike in their first 600 bytes, so in all an index's record keeps: x's then apple, x's then berry,
     * and more x's then apple, which orders after both; and one shorter than a record keeps, x's then apple
     */
    apple :: long_text(650, "apple")
    berry :: long_text(650, "berry")
    longer :: long_text(690, "apple")
    short :: long_text(200, "apple")
    names :: string.[apple, berry, longer, short]
    defer {
        for text in names {
            if text.count > 0 {
                runtime.free_array(view_of(cast[ptr[mut u8]](&text[0]), text.count))
            }
        }
    }
    testing.require(t, apple.count > 0 && berry.count > 0 && longer.count > 0 && short.count > 0, "the texts are made")?
    for text, i in names {
        file_name : u8[16]
        length :: name_of_number(file_name, cast[int](i))
        writing :: write_task(volume, root, string_of(&file_name[0], length), task.hash, task_value(1, 0, false, text))
        require_done(t, writing, "a typed file with a long name is made")?
    }
    testing.require(t, commit_apart(kept.made), "the files commit")?
    testing.expect_eq(t, count_long(volume, name, .Equal, apple) or_else 99, 1, "= finds only the text that's the same whole")
    testing.expect_eq(t, count_long(volume, name, .NotEqual, apple) or_else 99, 3, "≠ finds the other three")
    testing.expect_eq(t, count_long(volume, name, .Equal, longer) or_else 99, 1, "a longer text with the same start isn't the same")
    testing.expect_eq(t, count_long(volume, name, .Less, berry) or_else 99, 2, "< orders by what's past the kept bytes")
    testing.expect_eq(t, count_long(volume, name, .Greater, apple) or_else 99, 2, "> finds berry and the longer apple")
    testing.expect_eq(t, count_long(volume, name, .GreaterOrEqual, longer) or_else 99, 1, ">= of the longest finds it alone")
    testing.expect_eq(t, count_long(volume, name, .Equal, short) or_else 99, 1, "a text shorter than what's kept is exact as before")
    // A constant past what's kept, but the plan not told it whole: compared by its first bytes, as all four start so
    cut :: count_of(volume, root, slopfs.Term.[compare_text(name, .Less, apple)])
    testing.expect_eq(t, cut, 1, "without the whole constant, only the short text is before its first bytes")
    return .Ok
}

an_index_that_cant_be_made_at_commit_leaves_the_changes_to_be_forgotten_whole #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    device :: formatted(t, BLOCKS, 0x61)?
    defer free_device(device)
    mounting :: slopfs.mount(device)
    container :: testing.require_ok(t, mounting, "a formatted disk mounts")?
    defer slopfs.unmount(container)
    creating :: create_test_volume(container, "unindexed", false)
    volume :: testing.require_ok(t, creating, "a new container has room for a volume")?
    root :: slopfs.ROOT_OBJECT
    task := task_schema()
    defer free_schema(&task)
    declaring :: slopfs.declare_index(volume, task.bytes, "size")
    size :: testing.require_ok(t, declaring, "an index is declared")?
    making :: write_task(volume, root, "a", task.hash, task_value(1, 0, false, "a"))
    require_done(t, making, "a typed file is made")?
    require_commit(t, container, "the index and the file commit")?
    committed :: slopfs.record_of(volume)

    /*
     * Written again, with a file made beside it, then indexed with each of its allocations failing in turn, as one
     * without the memory: the indexing fails and the volume isn't failed; gone back to the last commit, as a volume
     * server does, the writes and their half-made entries are all forgotten, until one with every allocation it needs
     */
    failures := 0
    for fail_at in cast[u64](1)..<200 {
        rewriting :: write_task(volume, root, "a", task.hash, task_value(2, 0, false, "a"))
        require_done(t, rewriting, "the file is written again")?
        making_b :: write_task(volume, root, "b", task.hash, task_value(3, 0, false, "b"))
        require_done(t, making_b, "another typed file is made")?
        failing :: testing.require_some(t, memory.make_failing(fail_at), "a failing allocator is made")?
        indexing : Result[void, slopfs.Error] = .Ok
        push_context failing_context (allocator = memory.failing_allocator(failing)) {
            indexing = slopfs.index_changes(volume)
        }
        failed :: failing.failed
        memory.free_failing(failing)
        if !failed {
            testing.require(t, indexing is_ok, "indexing with every allocation it asks for succeeds")?
            undone : slopfs.Change[..]
            defer runtime.array_free(&undone)
            slopfs.abandon_volume(container, volume.id, &undone)
            slopfs.forget(volume, committed)
            break
        }
        testing.require(t, indexing is_error, "indexing fails when an allocation it needs fails")?
        testing.expect(t, !volume.failed, "a failed index update doesn't fail the volume")
        failures += 1
        undone : slopfs.Change[..]
        defer runtime.array_free(&undone)
        slopfs.abandon_volume(container, volume.id, &undone)
        slopfs.forget(volume, committed)
        testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 1)]), 1, "the file's committed value is found")
        testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 2)]), 0, "its forgotten write isn't")
        testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 3)]), 0, "nor the file made with it")
        gone :: match slopfs.lookup(volume, root, "b") {
            case Ok(found) => found is_none
            case Error(error) => false
        }
        testing.expect(t, gone, "the file made since the commit is gone")
    }
    testing.expect(t, failures > 0, "indexing asks for memory, so a failed allocation fails it")
    require_commit(t, container, "the volume commits after going back")?
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 1)]), 1, "the committed value is still found")
    // And the next change is indexed as it commits
    again :: write_task(volume, root, "a", task.hash, task_value(4, 0, false, "a"))
    require_done(t, again, "the file is written once more")?
    require_commit(t, container, "the write commits, indexed")?
    testing.expect_eq(t, count_of(volume, root, slopfs.Term.[compare(size, .Equal, 4)]), 1, "its new value is found")
    return .Ok
}
