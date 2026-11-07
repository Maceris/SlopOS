package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import strings from "std"
import unicode from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * "Did you mean" (decisions/0179, 0181's F2, design/lessons.md §4): a path that isn't there, whose last name matches
 * an entry of its directory once both are compared without case, however their accents were written, and with spaces
 * at their ends dropped, is answered with that entry's name, the bytes it's stored with, as a name typed from a Mac's
 * NFD, in other case or with a trailing space looks the same and isn't.
 */

/**
 * Find the entry a path that isn't there was probably meant to be: in the path's directory, the one entry whose name
 * matches its last name once both are folded (folded_same), and isn't the same bytes.
 *
 * @param shell The shell, whose home the directory is opened beneath.
 * @param given The path, as written, that isn't there.
 * @return The path meant, the directory part as given and the entry's name as stored, on the heap, never freed; null if
 *     no entry matches, more than one does, or the directory couldn't be opened or listed.
 */
meant_path :: fn(shell: ptr[mut Shell], given: string) -> string? {
    split := given.count
    loop {
        if split == 0 || slice_of(given, split - 1, split) == "/" {
            break
        }
        split -= 1
    }
    directory :: slice_of(given, 0, split)
    typed :: slice_of(given, split, given.count)
    if typed.count == 0 {
        return null
    }
    // A copy, as opening keeps the path it's given
    place :: strings.clone(if directory.count > 0 { directory } else { "." }) or_return null
    defer runtime.free_array(bit_cast[u8[]](place))
    handle :: match opened_beneath_home(shell, place, .Dir) {
        case Ok(opened) => opened
        case Error(problem) => return null
    }
    end :: cast[slop_os.Channel](handle)
    defer slop_os.handle_close(handle)
    port :: os.port_for(slop_os.startup_block().budget, end) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    found : string? = null
    cursor := cast[u64](0)
    loop {
        asking := os.Outgoing.{}
        os.begin[dir.Request](&asking)^ = .List(cursor)
        if dir.send_request(end, port, &asking) is_some {
            return null
        }
        listed := os.Incoming.{}
        if !received(dir.receive_response(end, port, &listed, true)) {
            return null
        }
        match os.message_of[dir.Response](&listed)^ {
            case Listed(entry) => {
                bytes :: os.items(&listed, entry.name)
                name :: if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
                if name != typed && folded_same(name, typed) {
                    if found is_some {
                        return null
                    }
                    found = message("%1%2", directory, name)
                }
                cursor = entry.next
            }
            case End => return found
            case _ => return null
        }
    }
}

/**
 * Tell whether two names are the same once folded: spaces at either end dropped, then compared by canonical caseless
 * matching (the Unicode Standard, 3.13: NFD, full case folding, NFD again), so case doesn't count, and neither does
 * whether an accent was written composed or after its letter.
 *
 * @param a One name, UTF-8.
 * @param b The other.
 * @return Whether their keys (caseless_key) have the same bytes; false if either is only spaces, or too long to fold
 *     (past MAX_FOLDED bytes).
 */
folded_same :: fn(a: string, b: string) -> bool {
    left :: trimmed(a)
    right :: trimmed(b)
    if left.count == 0 || right.count == 0 {
        return false
    }
    left_key :: caseless_key(left) or_return false
    right_key :: caseless_key(right) or_return false
    return left_key == right_key
}

/** The most bytes of a name folded for "did you mean"; a longer one isn't compared. */
MAX_FOLDED :: 128

/**
 * Make a name's canonical caseless key: NFD, full case folding, NFD again.
 *
 * @param name The name, UTF-8, at most MAX_FOLDED bytes.
 * @return The key, on the heap, never freed; null for a longer name.
 */
caseless_key :: fn(name: string) -> string? {
    bytes :: string_bytes(name)
    if bytes.count > MAX_FOLDED {
        return null
    }
    // Each step at most triples the bytes, so room for the last is 27 times the name
    scratch : u32[MAX_FOLDED * 9 * unicode.SCRATCH_PER_BYTE]
    first : u8[MAX_FOLDED * 3]
    second : u8[MAX_FOLDED * 9]
    last : u8[MAX_FOLDED * 27]
    a :: unicode.normalize(bytes, .NFD, scratch[0..<scratch.count], first[0..<first.count]) or_return null
    if a > first.count {
        return null
    }
    b :: unicode.case_fold(first[0..<a], scratch[0..<scratch.count], second[0..<second.count]) or_return null
    if b > second.count {
        return null
    }
    c :: unicode.normalize(second[0..<b], .NFD, scratch[0..<scratch.count], last[0..<last.count]) or_return null
    if c > last.count || c == 0 {
        return ""
    }
    return strings.clone(string_of(&last[0], c)) or_return null
}

/**
 * Drop the spaces at a name's ends.
 *
 * @param name The name.
 * @return A view of it without spaces at its start or end; empty for one that's only spaces.
 */
trimmed :: fn(name: string) -> string {
    start : usize = 0
    end := name.count
    loop {
        if start >= end || slice_of(name, start, start + 1) != " " {
            break
        }
        start += 1
    }
    loop {
        if end <= start || slice_of(name, end - 1, end) != " " {
            break
        }
        end -= 1
    }
    return slice_of(name, start, end)
}
