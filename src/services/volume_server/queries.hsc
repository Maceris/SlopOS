package volume_server

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import files from "std:os/slop_os/files"
import query from "std:os/slop_os/query"
import slopfs from "../../slopfs"

/*
 * Queries (decisions/0201's 20j): a predicate over the volume's indexes, answered beneath a directory, a file at a
 * time from a cursor, through dir's Query; and live queries, each on a connection of its own (query's protocol),
 * which answer the files that match, then each one added, changed or gone as commits change them.
 *
 * A live query keeps the files it's answered as matching, up to MAX_MEMBERS, and the files each commit changed, up to
 * MAX_PENDING, which it looks at again a Next at a time. Past MAX_PENDING, or when a commit changed more files than
 * the volume noted, or moved a directory, it can't tell what changed, so it begins again: Resync, then every file
 * that matches Matched once more. Past MAX_MEMBERS it ends, answering NoSpace.
 */

/** The most live queries the server keeps at once; one more is refused with NoSpace. */
MAX_LIVE :: 8
/** The most files a live query keeps as matching; past them, it ends (NoSpace). */
MAX_MEMBERS :: 1024
/** The most files changed since its last answer a live query keeps to look at; past them, it begins again. */
MAX_PENDING :: 256

/** Where a live query is in what it answers. */
LivePhase :: enum {
    /** Answering the files that match, from a walk of its index: Matched, then Current once the walk's done. */
    Walking,
    /** Answering what each commit changes: Added, Changed and Gone. */
    Following,
    /** Ended, past MAX_MEMBERS: every Next is answered NoSpace. */
    Ended,
}

/** A live query's state, from slopfs.make, freed when its connection's dropped. */
LiveState :: struct {
    /** Its predicate, planned, which holds its constants. */
    plan : slopfs.Plan,
    /** The directory it's beneath. */
    directory : u64,
    /** Where it is. */
    phase : LivePhase,
    /** Where its walk is, while it's Walking. */
    cursor : slopfs.QueryCursor,
    /** The files it's answered as matching, and not as gone since: the first member_count. */
    members : u64[MAX_MEMBERS],
    /** How many of members are used. */
    member_count : usize,
    /** The files commits changed that it's yet to look at again: the first pending_count, each once. */
    pending : u64[MAX_PENDING],
    /** How many of pending are used. */
    pending_count : usize,
    /** Whether it has to begin again, its next answer Resync. */
    resync : bool,
    /** Whether a Next is waiting for an answer. */
    asked : bool,
}

/** A live query's slot in the server. */
Live :: struct {
    /** Its state; null for a slot no live query has. */
    state : ptr[mut LiveState]?,
    /** Its connection's slot, a LiveQuery's. */
    connection : usize,
}

/**
 * Plan a predicate from a request: its terms checked and copied, its texts with them, and planned over the volume's
 * indexes.
 *
 * @param volume The volume whose indexes it's planned over, only read.
 * @param into The request, which the predicate's terms and texts are read from.
 * @param predicate The predicate's Relatives, as the request has them.
 * @param plan Where it's planned; filled whatever happens, and good only if null is given back.
 * @return Null once it's planned; WrongType if the terms don't hold together, there are none or past MAX_TERMS, a
 *     kind or comparison isn't one, a text isn't within the texts, or it names indexes of more than one type;
 *     NotFound for an index that isn't there; or why the volume couldn't be read.
 */
plan_of :: fn(
    volume : ptr[mut slopfs.Volume],
    into : ptr[os.Incoming],
    predicate : query.Predicate,
    plan : ptr[mut slopfs.Plan]
) -> files.FileError? {
    terms :: os.items(into, predicate.terms)
    texts :: os.items(into, predicate.texts)
    plan^ = slopfs.Plan.{}
    if terms.count == 0 || terms.count > plan.terms.count {
        return files.FileError.WrongType
    }
    for term, i in terms {
        if i >= plan.terms.count {
            return files.FileError.WrongType
        }
        made := slopfs.Term.{index = cast[u64](term.index), number = term.number}
        made.kind = term_kind(term.kind) or_return files.FileError.WrongType
        if made.kind == .Compare {
            made.comparison = comparison_of(term.comparison) or_return files.FileError.WrongType
            start :: cast[u64](term.text_offset)
            end :: start + cast[u64](term.text_count)
            if end > cast[u64](texts.count) {
                return files.FileError.WrongType
            }
            text :: slopfs.part(texts, cast[usize](start), cast[usize](end))
            kept :: if text.count < made.text.count { text.count } else { made.text.count }
            slopfs.copy_bytes(made.text, 0, slopfs.part(text, 0, kept))
            made.text_bytes = kept
        }
        plan.terms[i] = made
    }
    plan.count = terms.count
    match slopfs.plan_query(volume, plan) {
        case Ok => return null
        case Error(error) => return file_error(error)
    }
}

/**
 * Get the TermKind a term's kind holds.
 *
 * @param kind The term's kind, as a client sent it.
 * @return Its TermKind; null for a value that isn't one.
 */
term_kind :: fn(kind : u32) -> slopfs.TermKind? {
    return if kind == cast[u32](query.TermKind.Compare) {
        slopfs.TermKind.Compare
    }
    else if kind == cast[u32](query.TermKind.And) {
        slopfs.TermKind.And
    }
    else if kind == cast[u32](query.TermKind.Or) {
        slopfs.TermKind.Or
    }
    else if kind == cast[u32](query.TermKind.Not) { slopfs.TermKind.Not } else { cast[slopfs.TermKind?](null) }
}

/**
 * Get the Comparison a term's comparison holds.
 *
 * @param comparison The term's comparison, as a client sent it.
 * @return Its Comparison, the same value in slopfs's; null for a value that isn't one, 1 to 6.
 */
comparison_of :: fn(comparison : u32) -> slopfs.Comparison? {
    if comparison < 1 || comparison > 6 {
        return null
    }
    return cast[slopfs.Comparison](comparison)
}

/**
 * Answer a Query: the first file beneath a directory, from a cursor, the predicate holds for.
 *
 * @param server The server, whose volume is read.
 * @param directory The directory object it's beneath.
 * @param into The request, which the predicate is read from.
 * @param ask The request's predicate and cursor.
 * @param out The answer being built, which the file's path is appended to.
 * @return Matched with the file, its path from the directory (empty past 16 levels beneath it) and the cursor after
 *     it; End past the last; Failed as plan_of says, NoMemory without the memory for the plan, or why the volume
 *     couldn't be read.
 */
query_answer :: fn(
    server : ptr[mut Server],
    directory : u64,
    into : ptr[os.Incoming],
    ask : query.Ask,
    out : ptr[mut os.Outgoing]
) -> dir.Response {
    volume :: server.volume
    plan :: slopfs.make(slopfs.Plan) or_return .Failed(.NoMemory)
    defer runtime.free(plan)
    match plan_of(volume, into, ask.predicate, plan) {
        case Some(error) => return .Failed(error)
        case None => {}
    }
    cursor :: slopfs.QueryCursor.{phase = walk_phase(ask.cursor.phase), key = ask.cursor.key, skip = ask.cursor.skip}
    match slopfs.query_next(volume, plan, directory, cursor) {
        case Ok(found) => {
            match found {
                case Some(file) => {
                    path : u8[files.PATH_BYTES]
                    length :: path_to(server, directory, file.file, path)
                    return .Matched(
                        query.Match.{
                            name = os.append(out, slopfs.part(path, 0, length)),
                            file = file.file,
                            next = query.Cursor.{
                                phase = cast[u32](file.next.phase),
                                key = file.next.key,
                                skip = file.next.skip,
                            },
                        }
                    )
                }
                case None => return .End
            }
        }
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Get the walk's phase a cursor's phase holds.
 *
 * @param phase A cursor's phase, as a client gave it back.
 * @return Its phase; Done for a value that isn't one, so a cursor that's been tampered with finds nothing.
 */
walk_phase :: fn(phase : u32) -> slopfs.WalkPhase {
    if phase == cast[u32](slopfs.WalkPhase.Buckets) {
        return .Buckets
    }
    return if phase == cast[u32](slopfs.WalkPhase.Spills) { .Spills } else { .Done }
}

/**
 * Answer a LiveQuery: the predicate planned, and a live query begun on a connection of its own.
 *
 * @param server The server, which keeps the live query in one of its lives and a LiveQuery connection.
 * @param directory The directory object it's beneath.
 * @param into The request, which the predicate is read from.
 * @param predicate The request's predicate.
 * @param name The asking connection's name, the new one's.
 * @return Live with the connection's other end, which the caller sends; Failed as plan_of says, NoMemory without the
 *     memory for its state, or NoSpace without a slot or a channel.
 */
live_query :: fn(
    server : ptr[mut Server],
    directory : u64,
    into : ptr[os.Incoming],
    predicate : query.Predicate,
    name : string
) -> dir.Response {
    free := server.lives.count
    for live, i in server.lives {
        if live.state is_none {
            free = i
            break
        }
    }
    if free >= server.lives.count {
        return .Failed(.NoSpace)
    }
    state :: slopfs.make(LiveState) or_return .Failed(.NoMemory)
    state^ = LiveState.{directory = directory}
    match plan_of(server.volume, into, predicate, &state.plan) {
        case Some(error) => {
            runtime.free(state)
            return .Failed(error)
        }
        case None => {}
    }
    startup :: slop_os.startup_block()
    made :: os.channel_for[query.Query](startup.budget, 0)
    if made is_error {
        runtime.free(state)
        return .Failed(.NoSpace)
    }
    pair :: made or_return .Failed(.NoSpace)
    match add(server, .LiveQuery, pair.a, directory, true, name) {
        case Some(slot) => {
            if slot < server.connections.count {
                server.connections[slot].live = free
            }
            server.lives[free] = Live.{state = state, connection = slot}
            return .Live(os.Channel[query.Query].{end = pair.b})
        }
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            runtime.free(state)
            return .Failed(.NoSpace)
        }
    }
}

/**
 * Serve a live query's connection: each Next answered with its next event, at once or once a commit makes one. A
 * connection whose end fails is dropped.
 *
 * @param server The server; once its handled is set, no further request is read.
 * @param index The connection's slot, a LiveQuery; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_live :: fn(server : ptr[mut Server], index : usize, into : ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        if server.handled {
            return void
        }
        match query.receive_request(end, server.port, into, false) {
            case Received => received(server, index)
            case Empty => return void
            case Unsupported => {
                _ = query.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        live :: server.connections[index].live
        if live >= server.lives.count {
            continue
        }
        match server.lives[live].state {
            case Some(found) => {
                found.asked = true
                answer_live(server, live)
            }
            case None => {}
        }
    }
}

/**
 * Answer a live query's waiting Next, if it has one and there's an event for it: sent on its connection, and the
 * query no longer asked.
 *
 * @param server The server, whose volume is read.
 * @param live The live query's slot in the server's lives; a free one is left alone.
 */
answer_live :: fn(server : ptr[mut Server], live : usize) {
    if live >= server.lives.count {
        return void
    }
    state :: server.lives[live].state or_return void
    connection :: server.lives[live].connection
    if !state.asked || connection >= server.connections.count {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[query.Response](&out)
    match next_event(server, state, &out) {
        case Some(answer) => response^ = answer
        case None => return void
    }
    state.asked = false
    _ = query.send_response(server.connections[connection].end, server.port, &out)
}

/**
 * Work out a live query's next event, if it has one now.
 *
 * @param server The server, whose volume is read.
 * @param state The live query, whose phase, members, pending and cursor move on with the event.
 * @param out The answer being built, which an event's path is appended to.
 * @return The answer: Resync, Matched, Current, Added, Changed or Gone; Failed with NoSpace once it's ended, or why
 *     the volume couldn't be read; null if there's nothing to answer until a commit changes something.
 */
next_event :: fn(server : ptr[mut Server], state : ptr[mut LiveState], out : ptr[mut os.Outgoing]) -> query.Response? {
    volume :: server.volume
    if state.phase == .Ended {
        return query.Response.Failed(.NoSpace)
    }
    if state.resync {
        state.resync = false
        state.member_count = 0
        state.pending_count = 0
        state.phase = .Walking
        state.cursor = slopfs.QueryCursor.{}
        return query.Response.Event(query.Event.{kind = .Resync})
    }
    if state.phase == .Walking {
        match slopfs.query_next(volume, &state.plan, state.directory, state.cursor) {
            case Ok(found) => {
                match found {
                    case Some(file) => {
                        state.cursor = file.next
                        if !add_member(state, file.file) {
                            state.phase = .Ended
                            return query.Response.Failed(.NoSpace)
                        }
                        return event_of(server, state, .Matched, file.file, out)
                    }
                    case None => {
                        state.phase = .Following
                        return query.Response.Event(query.Event.{kind = .Current})
                    }
                }
            }
            case Error(error) => return query.Response.Failed(file_error(error))
        }
    }
    loop {
        count :: state.pending_count
        if count == 0 || count > state.pending.count {
            return null
        }
        last :: count - 1
        file :: state.pending[last]
        state.pending_count = last
        matches := false
        match slopfs.query_matches(volume, &state.plan, state.directory, file) {
            case Ok(holds) => matches = holds
            case Error(error) => return query.Response.Failed(file_error(error))
        }
        member :: member_at(state, file)
        match member {
            case Some(at) => {
                if matches {
                    return event_of(server, state, .Changed, file, out)
                }
                remove_member(state, at)
                return event_of(server, state, .Gone, file, out)
            }
            case None => {
                if matches {
                    if !add_member(state, file) {
                        state.phase = .Ended
                        return query.Response.Failed(.NoSpace)
                    }
                    return event_of(server, state, .Added, file, out)
                }
            }
        }
    }
}

/**
 * Make a live query's event of a file, with its path beneath the query's directory as it is now.
 *
 * @param server The server, whose volume is read.
 * @param state The live query.
 * @param kind What happened.
 * @param file The file.
 * @param out The answer being built, which the path is appended to.
 * @return The event; its path empty for a file no longer beneath the directory, or past 16 levels beneath it.
 */
event_of :: fn(
    server : ptr[mut Server],
    state : ptr[LiveState],
    kind : query.EventKind,
    file : u64,
    out : ptr[mut os.Outgoing]
) -> query.Response {
    path : u8[files.PATH_BYTES]
    length :: path_to(server, state.directory, file, path)
    return query.Response.Event(
        query.Event.{kind = kind, file = file, name = os.append(out, slopfs.part(path, 0, length))}
    )
}

/**
 * Find a file among a live query's members.
 *
 * @param state The live query, only read.
 * @param file The file.
 * @return Its place among the members; null if it isn't one.
 */
member_at :: fn(state : ptr[LiveState], file : u64) -> usize? {
    for member, i in state.members {
        if i >= state.member_count {
            break
        }
        if member == file {
            return i
        }
    }
    return null
}

/**
 * Add a file to a live query's members, unless it's one already.
 *
 * @param state The live query.
 * @param file The file.
 * @return False if there are MAX_MEMBERS already; true once it's one.
 */
add_member :: fn(state : ptr[mut LiveState], file : u64) -> bool {
    if member_at(state, file) is_some {
        return true
    }
    count :: state.member_count
    if count >= state.members.count {
        return false
    }
    state.members[count] = file
    state.member_count = count + 1
    return true
}

/**
 * Take a file out of a live query's members, the last put in its place.
 *
 * @param state The live query.
 * @param at The file's place among them, as member_at found it; past them, nothing's done.
 */
remove_member :: fn(state : ptr[mut LiveState], at : usize) {
    count :: state.member_count
    if at >= count || count > state.members.count {
        return void
    }
    last :: count - 1
    state.members[at] = state.members[last]
    state.member_count = last
}

/**
 * Note what a commit changed for every live query, and answer those waiting that now have an event.
 *
 * @param server The server, whose committed changes, as commit kept them, are given to each live query: each file
 *     to look at again, or, past what a query keeps, or when the commit's changes weren't all kept or moved a
 *     directory, a Resync.
 */
feed_lives :: fn(server : ptr[mut Server]) {
    for live, i in server.lives {
        state :: live.state or_continue
        if server.committed_all {
            state.resync = true
        }
        else {
            for j in 0..<server.committed_count {
                if j >= server.committed.count {
                    break
                }
                if !add_pending(state, server.committed[j]) {
                    state.resync = true
                    break
                }
            }
        }
        answer_live(server, i)
    }
}

/**
 * Add a file to those a live query has to look at again, unless it's among them already.
 *
 * @param state The live query.
 * @param file The file.
 * @return False if there are MAX_PENDING already; true once it's among them.
 */
add_pending :: fn(state : ptr[mut LiveState], file : u64) -> bool {
    for each, i in state.pending {
        if i >= state.pending_count {
            break
        }
        if each == file {
            return true
        }
    }
    count :: state.pending_count
    if count >= state.pending.count {
        return false
    }
    state.pending[count] = file
    state.pending_count = count + 1
    return true
}

/**
 * Keep what the volume's about to commit changed, for the live queries, if there are any.
 *
 * @param server The server, whose committed list and committed_all are set from its volume's noted changes, which
 *     write_volume is about to index and forget; with no live query, they're left empty.
 */
keep_committed :: fn(server : ptr[mut Server]) {
    server.committed_count = 0
    server.committed_all = false
    any := false
    for live in server.lives {
        any = any || (live.state is_some)
    }
    if !any {
        return void
    }
    indexing :: &server.volume.indexing
    server.committed_all = indexing.overflowed || indexing.moved
    for object, i in indexing.changed {
        if i >= indexing.count || i >= server.committed.count {
            break
        }
        server.committed[i] = object
        server.committed_count = i + 1
    }
}

/**
 * Let go of a live query, as its connection's dropped.
 *
 * @param server The server, whose live slot is freed.
 * @param live The slot; a free one, or one past them, is left alone.
 */
end_live :: fn(server : ptr[mut Server], live : usize) {
    if live >= server.lives.count {
        return void
    }
    match server.lives[live].state {
        case Some(state) => runtime.free(state)
        case None => {}
    }
    server.lives[live] = Live.{}
}
