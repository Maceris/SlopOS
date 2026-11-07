/**
 * What the first services share (decisions/0067, 0071, 0074): a set of clients, each an end bound to the service's
 * port under its index, grants' labels as text, and the words of the kernel's command line.
 *
 * A typed library (decisions/0121, 0124), service_kit.library, whose text every service shares: its #export functions
 * are called through it.
 */
package service_kit

import compiler from "base"
import runtime from "base"
import slop_os from "std/os"
import system_records from "../../system_records"

/**
 * The second build, service_kit_plus.library (decisions/0122): the build's setting service_kit_build=plus, one export
 * more, which substitution's test puts in this build's place.
 */
PLUS :: #run compiler.target_setting("service_kit_build", default = "") == "plus"

#if PLUS {
    /**
     * Tell which build of the library this is, the export only the plus build has.
     *
     * @return "plus", static text.
     */
    build_name #export :: fn() -> string {
        return "plus"
    }
}

/** The most clients one service serves at once: 16. */
MAX_CLIENTS :: 16

/** A service's clients: an end each, bound to its port under its index, NO_HANDLE once it's closed. */
Clients :: struct {
    /** Each client's end, by its index, the service's own; NO_HANDLE for a place freed by drop_client. */
    ends : slop_os.Channel[MAX_CLIENTS],
    /** How many places have been used, from the first, freed ones included: 0 to MAX_CLIENTS. */
    count : usize,
}

/**
 * Add a client, bound to a port, in the place of one that went away if there is one, so a service has room for
 * MAX_CLIENTS at once rather than in its life.
 *
 * @param clients The service's clients, changed: end goes in the first freed place, or the next unused one, count
 *     growing then.
 * @param port The service's port, which the end is bound to, persistently, for readable and peer-closed, under the
 *     client's index as its key; a binding left under that key is undone first.
 * @param end The client's end, which the clients keep when it's added; not closed when it isn't.
 * @return True once it's added; false if there's no room, or it can't be bound.
 */
add_client #export :: fn(clients: ptr[mut Clients], port: slop_os.Port, end: slop_os.Channel) -> bool {
    return add_client_index(clients, port, end) is_some
}

/**
 * Add a client as add_client does, giving where it went, for state a service keeps per client.
 *
 * @param clients The service's clients, changed: end goes in the first freed place, or the next unused one, count
 *     growing then; unchanged if it isn't added.
 * @param port The service's port, which the end is bound to under the client's index.
 * @param end The client's end, which the clients keep when it's added; not closed when it isn't.
 * @return The client's index, 0 to MAX_CLIENTS - 1, the lowest freed place or the next; null if there's no room, or
 *     it can't be bound.
 */
add_client_index #export :: fn(clients: ptr[mut Clients], port: slop_os.Port, end: slop_os.Channel) -> usize? {
    index := clients.count
    for i in cast[usize](0)..<clients.count {
        if i < clients.ends.count && cast[slop_os.Handle](clients.ends[i]) == slop_os.NO_HANDLE {
            index = i
            break
        }
    }
    if index >= clients.ends.count {
        return null
    }
    // The binding the one before had, if it's still there
    _ = slop_os.port_unbind(port, cast[u64](index))
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(port, cast[slop_os.Handle](end), signals, cast[u64](index), .Persistent) is_error {
        return null
    }
    clients.ends[index] = end
    if index == clients.count {
        clients.count = index + 1
    }
    return index
}

/**
 * Let go of a client that went away: close its end, and free its place for the next client.
 *
 * Its port binding is left, undone when its place is next used; count doesn't shrink.
 *
 * @param clients The service's clients, changed: the end at index is closed and its place set to NO_HANDLE, which
 *     add_client then reuses.
 * @param index The client's index; one past MAX_CLIENTS is nothing.
 */
drop_client #export :: fn(clients: ptr[mut Clients], index: usize) {
    if index < clients.ends.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](clients.ends[index]))
        clients.ends[index] = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
}

/**
 * Give a grant's label as text, without its padding.
 *
 * @param label The label, padded with zeros to GRANT_LABEL_SIZE bytes.
 * @return Its bytes up to the first zero, all of them if there's none: a view into label, good while it is.
 */
text_of_label #export :: fn(label: ptr[u8[slop_os.GRANT_LABEL_SIZE]]) -> string {
    count : usize = 0
    for byte in label^ {
        if byte == 0 {
            break
        }
        count += 1
    }
    return string_of(&label^[0], count)
}

/**
 * Map text in memory, like the kernel's command line, read-only, and give it as text.
 *
 * The mapping isn't undone, nor its addresses given back, so the text stays good for the process's life.
 *
 * @param block The process's startup block, whose address space it's mapped into.
 * @param memory The memory holding the text, which stays the caller's.
 * @return Its bytes up to its first zero, all of them if there's none; null if its size couldn't be read, or it
 *     couldn't be mapped.
 */
text_of #export :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Memory) -> string? {
    size :: slop_os.memory_size(memory) or_return null
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    if slop_os.memory_map(memory, block.space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return null
    }
    count : usize = 0
    for byte in view_of(cast[ptr[u8]](address), cast[usize](size)) {
        if byte == 0 {
            break
        }
        count += 1
    }
    return string_of(cast[ptr[u8]](address), count)
}

/**
 * Read the system configuration from memory, as the build wrote it into the boot set as system.records
 * (decisions/0110): copied out of it, and checked with system_records.check, as the build checked it.
 *
 * The memory is mapped only while it's copied.
 *
 * @param block The process's startup block, whose address space it's mapped into.
 * @param memory The memory holding the records, which stays the caller's.
 * @return The copy, from context's allocator, the caller's to free; or, as the error, why not: a Problem whose
 *     service is MAX_SERVICES when it can't be read, is too small, or can't be copied without memory, or
 *     system_records.check's when it doesn't check.
 */
read_records #export :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Memory) -> Result[ptr[mut system_records.SystemRecords], system_records.Problem] {
    unreadable :: system_records.Problem.{reason = "can't be read", service = system_records.MAX_SERVICES}
    size :: slop_os.memory_size(memory) or_return .Error(unreadable)
    if size < cast[u64](size_of(system_records.SystemRecords)) {
        return .Error(system_records.Problem.{reason = "is too small to be system records", service = system_records.MAX_SERVICES})
    }
    address :: runtime.reserve_addresses(cast[usize](size)) or_return .Error(unreadable)
    if slop_os.memory_map(memory, block.space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return .Error(unreadable)
    }
    made, error :: runtime.new_aligned(system_records.SystemRecords, align_of(system_records.SystemRecords))
    if error == null {
        made^ = cast[ptr[system_records.SystemRecords]](address)^
    }
    _ = slop_os.memory_unmap(block.space, address)
    if error != null {
        return .Error(system_records.Problem.{reason = "can't be copied without memory", service = system_records.MAX_SERVICES})
    }
    match system_records.check(made) {
        case Some(problem) => {
            runtime.free(made)
            return .Error(problem)
        }
        case None => return .Ok(made)
    }
}

/**
 * Find a word of text that starts with a prefix, and give what follows it, as for "name=value" on a command line.
 *
 * @param text The words, which single spaces separate.
 * @param prefix What the word starts with.
 * @return The rest of the first word that starts with prefix, a view into text, empty if the word is just prefix;
 *     null if no word does.
 */
word_after #export :: fn(text: string, prefix: string) -> string? {
    start : usize = 0
    for character, i in text {
        if character == ' ' {
            match word_from(text, start, i, prefix) {
                case Some(found) => return found
                case None => {}
            }
            start = i + 1
        }
    }
    return word_from(text, start, text.count, prefix)
}

/**
 * Read a decimal number.
 *
 * @param text The number's digits, nothing else: no sign, no spaces.
 * @return Its value; null if text is empty, isn't all digits, or has more than 19 of them, which a u64 may not hold.
 */
number_of #export :: fn(text: string) -> u64? {
    if text.count == 0 || text.count > 19 {
        return null
    }
    value : u64 = 0
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}

/**
 * Give what follows a prefix in a word of text, if it starts with it.
 *
 * @param text The whole text, as the kernel's command line, which the word is in.
 * @param start Where the word starts, in bytes.
 * @param end Where the word ends, in bytes, at most text's count.
 * @param prefix What the word has to start with.
 * @return The rest of the word after prefix, a view into text; null if it doesn't start with it, or start and end
 *     aren't a range of text.
 */
word_from :: fn(text: string, start: usize, end: usize, prefix: string) -> string? {
    if end < start || end > text.count {
        return null
    }
    word :: text[start..<end]
    if word.count < prefix.count || word[0..<prefix.count] != prefix {
        return null
    }
    return word[prefix.count..<word.count]
}

/**
 * Tell whether a word is one of the words of text, as a flag on a command line.
 *
 * @param text The words, which single spaces separate.
 * @param word The word, compared whole and exactly.
 * @return True if one of text's words is word.
 */
has_word #export :: fn(text: string, word: string) -> bool {
    start : usize = 0
    for character, i in text {
        if character == ' ' {
            if is_word_at(text, start, i, word) {
                return true
            }
            start = i + 1
        }
    }
    return is_word_at(text, start, text.count, word)
}

/**
 * Tell whether a part of text is a word.
 *
 * @param text The whole text, as the kernel's command line, which the part is in.
 * @param start Where the part starts, in bytes.
 * @param end Where it ends, in bytes, at most text's count.
 * @param word The word, compared whole and exactly.
 * @return True if text's bytes from start to end are word's; false otherwise, or if start and end aren't a range of
 *     text.
 */
is_word_at :: fn(text: string, start: usize, end: usize, word: string) -> bool {
    if end < start || end > text.count {
        return false
    }
    return text[start..<end] == word
}

/** A page, in bytes: how much read_pages reads at a time. */
READ_PIECE : u64 : 4096

/**
 * Read memory another process owns into bytes of this one's, a page at a time, through memory_read (decisions/0098):
 * its owner gone is a failure, never a fault.
 *
 * A page at a time, so paged memory read under pressure gets on: memory_read waits for each page its pager hasn't
 * supplied and is made again from its start, and a read of many pages whose first ones are given back meanwhile could
 * wait for ever.
 *
 * @param memory The memory, which needs RIGHT_MEMORY_READ; any kind memory_read reads.
 * @param offset Where in it to start, in bytes.
 * @param into Where the bytes go, all of it filled, from offset on; what was read before a failure stays.
 * @return True once into is filled; false if a read failed: the memory gone, its pager gone, or the range past its end.
 */
read_pages :: fn(memory: slop_os.Memory, offset: u64, into: mut u8[]) -> bool {
    done := cast[usize](0)
    loop {
        if done >= into.count {
            return true
        }
        at :: offset + cast[u64](done)
        // To the next page's start, so each read is one page of the memory
        room :: cast[usize](READ_PIECE - at % READ_PIECE)
        end :: if into.count - done < room { into.count } else { done + room }
        if done > end || end > into.count {
            return false
        }
        if slop_os.memory_read(memory, at, into[done..<end]) is_error {
            return false
        }
        done = end
    }
}
