/*
 * What the first services share (decisions/0067, 0071, 0074): a set of clients, each an end bound to the service's
 * port under its index, grants' labels as text, and the words of the kernel's command line.
 */
package service_kit

import runtime from "base"
import slop_os from "std/os"

// The most clients one service serves.
MAX_CLIENTS :: 16

// A service's clients: an end each, bound to its port under its index, NO_HANDLE once it's closed.
Clients :: struct {
    ends : slop_os.Channel[MAX_CLIENTS],
    count : usize,
}

/*
 * One more client, bound to port, in the place of one that went away if there is one, so a service has room for
 * MAX_CLIENTS at once rather than in its life: false if there's no room, or it can't be bound.
 */
add_client :: fn(clients: ptr[mut Clients], port: slop_os.Port, end: slop_os.Channel) -> bool {
    return add_client_index(clients, port, end) is_some
}

// add_client's, giving where the client went, for state a service keeps per client.
add_client_index :: fn(clients: ptr[mut Clients], port: slop_os.Port, end: slop_os.Channel) -> usize? {
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

// A client that went away, closed.
drop_client :: fn(clients: ptr[mut Clients], index: usize) {
    if index < clients.ends.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](clients.ends[index]))
        clients.ends[index] = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
}

// A label's text, without its padding.
text_of_label :: fn(label: ptr[u8[slop_os.GRANT_LABEL_SIZE]]) -> string {
    count : usize = 0
    for byte in label^ {
        if byte == 0 {
            break
        }
        count += 1
    }
    return string_of(&label^[0], count)
}

// Text in memory, like the kernel's command line: its bytes up to its first zero, mapped read-only.
text_of :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Memory) -> string? {
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

// What follows prefix in the word of text that starts with it, or null.
word_after :: fn(text: string, prefix: string) -> string? {
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

// A decimal number, or null if text isn't one or it's too big for a u64.
number_of :: fn(text: string) -> u64? {
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

// What follows prefix in text's bytes from start to end, if they start with it.
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

// Whether word is one of the words of text, which spaces separate.
has_word :: fn(text: string, word: string) -> bool {
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

// Whether text's bytes from start to end are word.
is_word_at :: fn(text: string, start: usize, end: usize, word: string) -> bool {
    if end < start || end > text.count {
        return false
    }
    return text[start..<end] == word
}
