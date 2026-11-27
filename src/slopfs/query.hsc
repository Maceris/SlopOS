package slopfs

import runtime from "base:runtime"

/*
 * Queries over a volume's indexes (decisions/0201's 20j): a predicate, comparisons of indexed fields with constants
 * combined with and, or and not, written in postfix, answered with the files beneath a directory it holds for.
 *
 * Every index a predicate names has to be of one schema, and the files it's asked of are that schema's indexed ones:
 * those in the first index it names, or the one that bounds it. A comparison at its top, or one arm of an and at its
 * top, bounds the keys walked to its own range of that index; anything else walks the whole of the first index named.
 * Each file walked is then tested against the whole predicate, from its records of the indexes (IndexedRecord), so
 * nothing of it is read, and a text's comparisons see its first INDEX_TEXT_BYTES bytes alone.
 */

/** The most terms a predicate has. */
MAX_TERMS :: 32

/** How a field is compared with a constant. */
Comparison :: enum #backed_by(u32) {
    /** The field is the constant. */
    Equal = 1,
    /** The field isn't the constant. */
    NotEqual = 2,
    /** The field is less than the constant. */
    Less = 3,
    /** The field is at most the constant. */
    LessOrEqual = 4,
    /** The field is more than the constant. */
    Greater = 5,
    /** The field is at least the constant. */
    GreaterOrEqual = 6,
}

/** What a predicate's term is, in postfix order. */
TermKind :: enum #backed_by(u32) {
    /** A comparison of an index's field with a constant, pushed. */
    Compare = 1,
    /** The two terms before, popped, both holding; pushed. */
    And = 2,
    /** The two terms before, popped, either holding; pushed. */
    Or = 3,
    /** The term before, popped, not holding; pushed. */
    Not = 4,
}

/** One of a predicate's terms, with its constant. */
Term :: struct {
    /** What it is. */
    kind : TermKind,
    /** A comparison's: how its field is compared. */
    comparison : Comparison,
    /** A comparison's: the index whose field it compares, by number. */
    index : u64,
    /**
     * A comparison's constant, for an integer or a bool field: an unsigned value as it is, a signed one's two's
     * complement bits, a bool 0 or 1.
     */
    number : u64,
    /** A comparison's constant, for a text field: its first text_bytes bytes, compared byte by byte. */
    text : u8[INDEX_TEXT_BYTES],
    /** How many of text's bytes are the constant's, 0 to INDEX_TEXT_BYTES. */
    text_bytes : usize,
    /** A comparison's field's kind and its constant's key, which plan_query works out. */
    field : FieldKind,
    /** A comparison's constant as a key of its index, which plan_query works out. */
    key : u64,
}

/**
 * A predicate, planned: its terms, whose constants it holds, the schema its files are of, and the keys walked. From
 * make, the caller's to free with runtime.free; it holds nothing else of anyone's.
 */
Plan :: struct {
    /** The terms, in postfix order, the first count of them; the caller fills them before plan_query. */
    terms : Term[MAX_TERMS],
    /** How many of terms are the predicate's, 1 to MAX_TERMS. */
    count : usize,
    /** The schema hash every index it names is of, which plan_query works out. */
    schema : u8[32],
    /** The index walked, by number, which plan_query works out. */
    walk : u64,
    /** The least key of it walked. */
    low : u64,
    /** The greatest key of it walked. */
    high : u64,
}

/** Where a query's walk is: in the walked index's buckets, its spilled records, or done. */
WalkPhase :: enum #backed_by(u32) {
    /** In the buckets, from key and the skip'th file of its bucket. */
    Buckets = 0,
    /** In the spilled records, from the file key names. */
    Spills = 1,
    /** Done: no file is left. */
    Done = 2,
}

/** Where to go on from in a query's walk: opaque to a client, who only gives it back. All zeros is its start. */
QueryCursor :: struct {
    /** Its phase. */
    phase : WalkPhase,
    /** In the buckets, the key walked from; in the spilled records, the file. */
    key : u64,
    /** In the buckets, how many of key's bucket's files are done. */
    skip : u64,
}

/** A file a query found, and where to go on from. */
QueryFound :: struct {
    /** The file's ID. */
    file : u64,
    /** The cursor after it. */
    next : QueryCursor,
}

/**
 * Plan a predicate: check that its terms hold together and the indexes they name are of one schema, work out each
 * constant's key, and choose the keys walked.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param plan The predicate's terms and count, as the caller filled them; its schema, walk and keys are set, and each
 *     comparison's field and key.
 * @error NotIndexable The terms don't hold together in postfix (one left at the end), name indexes of more than one
 *     schema, give a text for a field that isn't text or a number for one that is, or a bool past 1; or there are
 *     none, or more than MAX_TERMS.
 * @error NotFound A comparison names an index the volume hasn't.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A declaration or a node couldn't be read or didn't check out.
 */
plan_query :: fn(volume : ptr[mut Volume], plan : ptr[mut Plan]) -> Result[void, Error] {
    count :: plan.count
    if count == 0 || count > plan.terms.count {
        return .Error(.NotIndexable)
    }
    // Each term's arms, as places among the terms, for choosing what bounds the walk
    left : usize[MAX_TERMS]
    right : usize[MAX_TERMS]
    stack : usize[MAX_TERMS]
    depth : usize = 0
    walk := cast[u64](0)
    for i in 0..<count {
        if i >= plan.terms.count || i >= left.count || i >= right.count {
            return .Error(.NotIndexable)
        }
        term :: &plan.terms[i]
        if term.kind == .Compare {
            record :: index_record(volume, term.index)? or_return .Error(.NotFound)
            if walk == 0 {
                walk = term.index
                plan.schema = record.schema
            }
            else if record.schema != plan.schema {
                return .Error(.NotIndexable)
            }
            field :: field_kind_of(cast[u32](record.kind)) or_return .Error(.NotIndexable)
            term.field = field
            if field == .Text {
                if term.text_bytes > term.text.count {
                    return .Error(.NotIndexable)
                }
                term.key = text_key(part(term.text, 0, term.text_bytes))
            }
            else if term.text_bytes != 0 || (field == .Bool && term.number > 1) {
                return .Error(.NotIndexable)
            }
            else if field == .Signed {
                term.key = term.number ~ (cast[u64](1) << 63)
            }
            else {
                term.key = term.number
            }
            if depth >= stack.count {
                return .Error(.NotIndexable)
            }
            stack[depth] = i
            depth += 1
            continue
        }
        arms :: if term.kind == .Not { cast[usize](1) } else { cast[usize](2) }
        if depth < arms || depth > stack.count {
            return .Error(.NotIndexable)
        }
        first :: depth - arms
        last :: depth - 1
        if first >= stack.count || last >= stack.count {
            return .Error(.NotIndexable)
        }
        left[i] = stack[first]
        right[i] = stack[last]
        stack[first] = i
        depth = first + 1
    }
    if depth != 1 || walk == 0 {
        return .Error(.NotIndexable)
    }
    plan.walk = walk
    plan.low = 0
    plan.high = 0xffffffffffffffff
    // A comparison at the top, or one arm of an and there, bounds the walk to its own index's range
    top :: count - 1
    if top < plan.terms.count && top < left.count && top < right.count {
        bounded := top
        arm :: left[top]
        if plan.terms[top].kind == .And && arm < plan.terms.count {
            bounded = if bounds(&plan.terms[arm]) { arm } else { right[top] }
        }
        if bounded < plan.terms.count && bounds(&plan.terms[bounded]) {
            term :: &plan.terms[bounded]
            plan.walk = term.index
            comparison :: term.comparison
            if comparison == .Equal || comparison == .Less || comparison == .LessOrEqual {
                plan.high = term.key
            }
            if comparison == .Equal || comparison == .Greater || comparison == .GreaterOrEqual {
                plan.low = term.key
            }
        }
    }
    return .Ok
}

/**
 * Tell whether a term bounds the keys of its index a query walks: a comparison but for NotEqual.
 *
 * @param term The term, only read.
 * @return True for a Compare whose comparison isn't NotEqual.
 */
bounds :: fn(term : ptr[Term]) -> bool {
    return term.kind == .Compare && term.comparison != .NotEqual
}

/**
 * Get the FieldKind a declaration's kind holds.
 *
 * @param kind A declaration's kind, as stored.
 * @return Its FieldKind; null for a value that isn't one.
 */
field_kind_of :: fn(kind : u32) -> FieldKind? {
    if kind == cast[u32](FieldKind.Unsigned) {
        return FieldKind.Unsigned
    }
    if kind == cast[u32](FieldKind.Signed) {
        return FieldKind.Signed
    }
    if kind == cast[u32](FieldKind.Bool) {
        return FieldKind.Bool
    }
    return if kind == cast[u32](FieldKind.Text) { FieldKind.Text } else { cast[FieldKind?](null) }
}

/**
 * Tell whether a file is one a planned query answers beneath a directory: a file of its schema with a name, in the
 * index it walks, beneath the directory, for which the predicate holds.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param plan The query, from plan_query.
 * @param directory The directory it's asked beneath.
 * @param file The object's ID; one that isn't there, or isn't such a file, isn't answered.
 * @return Whether it's answered.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out, or the parents loop.
 */
query_matches :: fn(volume : ptr[mut Volume], plan : ptr[Plan], directory : u64, file : u64) -> Result[bool, Error] {
    record := ObjectRecord.{}
    match get_object(volume, file) {
        case Ok(found) => record = found
        case Error(error) => {
            if error == .NotFound {
                return .Ok(false)
            }
            return .Error(error)
        }
    }
    if kind_of_record(&record) != .File || record.schema != plan.schema || (is_orphan(volume, file)?) {
        return .Ok(false)
    }
    if !(tree_has(volume.nodes, &volume.tree, key_of(file, .IndexedBy, plan.walk))?) {
        return .Ok(false)
    }
    match is_beneath(volume, cast[u64](record.parent), directory) {
        case Ok(beneath) => {
            if !beneath {
                return .Ok(false)
            }
        }
        case Error(error) => {
            if error == .NotFound {
                return .Ok(false)
            }
            return .Error(error)
        }
    }
    return holds(volume, plan, file)
}

/**
 * Evaluate a planned predicate for a file, from its records of the indexes it names.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param plan The query, from plan_query.
 * @param file The file's ID; a comparison of an index it isn't in doesn't hold.
 * @return Whether the predicate holds.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
holds :: fn(volume : ptr[mut Volume], plan : ptr[Plan], file : u64) -> Result[bool, Error] {
    keyed :: make(Keyed)?
    defer runtime.free(keyed)
    stack : bool[MAX_TERMS]
    depth : usize = 0
    for i in 0..<plan.count {
        if i >= plan.terms.count {
            return .Error(.NotIndexable)
        }
        term :: &plan.terms[i]
        value := false
        if term.kind == .Compare {
            if indexed_key(volume, file, term.index, keyed)? {
                order :: if term.field == .Text {
                    compare_texts(part(keyed.text, 0, keyed.text_bytes), part(term.text, 0, term.text_bytes))
                }
                else {
                    compare_numbers(keyed.key, term.key)
                }
                value = compared(order, term.comparison)
            }
        }
        else {
            arms :: if term.kind == .Not { cast[usize](1) } else { cast[usize](2) }
            if depth < arms {
                return .Error(.NotIndexable)
            }
            first :: depth - arms
            last :: depth - 1
            if first >= stack.count || last >= stack.count {
                return .Error(.NotIndexable)
            }
            a :: stack[first]
            b :: stack[last]
            value = if term.kind == .Not { !a } else if term.kind == .And { a && b } else { a || b }
            depth = first
        }
        if depth >= stack.count {
            return .Error(.NotIndexable)
        }
        stack[depth] = value
        depth += 1
    }
    return .Ok(depth == 1 && stack[0])
}

/**
 * Compare two numbers.
 *
 * @param a One number.
 * @param b The other.
 * @return -1 if a is less than b, 1 if more, 0 if they're equal.
 */
compare_numbers :: fn(a : u64, b : u64) -> int {
    return if a < b { -1 } else if a > b { 1 } else { 0 }
}

/**
 * Compare two texts byte by byte, a shorter one before a longer one it starts.
 *
 * @param a One text's bytes.
 * @param b The other's.
 * @return -1 if a is before b, 1 if after, 0 if they're the same.
 */
compare_texts :: fn(a : u8[], b : u8[]) -> int {
    for byte, i in a {
        if i >= b.count {
            return 1
        }
        if byte != b[i] {
            return if byte < b[i] { -1 } else { 1 }
        }
    }
    return if a.count < b.count { -1 } else { 0 }
}

/**
 * Tell whether an order satisfies a comparison.
 *
 * @param order How the field compares with the constant: -1, 0 or 1.
 * @param comparison The comparison.
 * @return Whether it holds.
 */
compared :: fn(order : int, comparison : Comparison) -> bool {
    return match comparison {
        case .Equal => order == 0
        case .NotEqual => order != 0
        case .Less => order < 0
        case .LessOrEqual => order <= 0
        case .Greater => order > 0
        case .GreaterOrEqual => order >= 0
    }
}

/**
 * Find the next file a planned query answers beneath a directory, from a cursor: its walk's buckets in key order, then
 * its spilled records in order of file.
 *
 * A file changed between one call and the next may be answered again, or not at all, as its key moves past the cursor
 * or before it. Each call walks as far as it must to find one, which may be the whole index.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param plan The query, from plan_query.
 * @param directory The directory it's asked beneath.
 * @param cursor Where to go on from: all zeros to start, or a QueryFound's next.
 * @return The file found and the cursor after it; null past the last.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out, or a directory's parents loop.
 */
query_next :: fn(
    volume : ptr[mut Volume],
    plan : ptr[Plan],
    directory : u64,
    cursor : QueryCursor
) -> Result[QueryFound?, Error] {
    at := cursor
    object :: INDEX_OBJECT_BASE | plan.walk
    if at.phase == .Buckets {
        bucket :: make(Bucket)?
        defer runtime.free(bucket)
        if at.key < plan.low {
            at.key = plan.low
            at.skip = 0
        }
        loop {
            found :: tree_next(volume.nodes, &volume.tree, key_of(object, .IndexEntry, at.key), bucket_bytes(bucket))?
                or_break
            if found.key.object != object
                || found.key.kind != cast[u8](RecordKind.IndexEntry)
                || found.key.offset > plan.high {
                break
            }
            if found.key.offset != at.key {
                at.skip = 0
            }
            at.key = found.key.offset
            bucket.count = files_in(found.bytes)?
            for each, i in bucket.files {
                if i >= bucket.count {
                    break
                }
                if cast[u64](i) < at.skip {
                    continue
                }
                file :: cast[u64](each)
                if query_matches(volume, plan, directory, file)? {
                    return .Ok(
                        QueryFound.{
                            file = file,
                            next = QueryCursor.{phase = .Buckets, key = at.key, skip = cast[u64](i) + 1},
                        }
                    )
                }
            }
            if at.key == 0xffffffffffffffff {
                break
            }
            at.key += 1
            at.skip = 0
        }
        at = QueryCursor.{phase = .Spills}
    }
    if at.phase == .Spills {
        value : u64le
        loop {
            found :: tree_next(
                volume.nodes,
                &volume.tree,
                key_of(object, .IndexSpill, at.key),
                view_of(cast[ptr[mut u8]](&value), 8)
            )? or_break
            if found.key.object != object || found.key.kind != cast[u8](RecordKind.IndexSpill) {
                break
            }
            file :: found.key.offset
            key :: cast[u64](value)
            if found.bytes == 8 && key >= plan.low && key <= plan.high && (query_matches(volume, plan, directory, file)?) {
                next := QueryCursor.{phase = .Spills, key = file + 1}
                if file == 0xffffffffffffffff {
                    next = QueryCursor.{phase = .Done}
                }
                return .Ok(QueryFound.{file = file, next = next})
            }
            if file == 0xffffffffffffffff {
                break
            }
            at.key = file + 1
        }
    }
    return .Ok(null)
}
