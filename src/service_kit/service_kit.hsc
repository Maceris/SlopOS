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

// One more client, bound to port: false if there's no room, or it can't be bound.
add_client :: fn(clients: ptr[mut Clients], port: slop_os.Port, end: slop_os.Channel) -> bool {
    index :: clients.count
    if index >= clients.ends.count {
        return false
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(port, cast[slop_os.Handle](end), signals, cast[u64](index), .Persistent) is_error {
        return false
    }
    clients.ends[index] = end
    clients.count = index + 1
    return true
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

// What follows prefix in text's bytes from start to end, if they start with it.
word_from :: fn(text: string, start: usize, end: usize, prefix: string) -> string? {
    if end < start || end - start < prefix.count {
        return null
    }
    word :: string_of(cast[ptr[u8]](cast[u64](text.data) + cast[u64](start)), end - start)
    if string_of(cast[ptr[u8]](word.data), prefix.count) != prefix {
        return null
    }
    return string_of(cast[ptr[u8]](cast[u64](word.data) + cast[u64](prefix.count)), word.count - prefix.count)
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
    return end >= start && end - start == word.count && string_of(cast[ptr[u8]](cast[u64](text.data) + cast[u64](start)), word.count) == word
}
