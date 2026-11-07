package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import strings from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * "Did you mean" (decisions/0179, design/lessons.md §4): a path that isn't there, whose last name matches an entry
 * of its directory once both are compared without ASCII case and with spaces at their ends dropped, is answered with
 * that entry's name, the bytes it's stored with, as a name typed from a Mac's NFD or with a trailing space looks the
 * same and isn't. Unicode normalization and case folding wait for std to have them.
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
 * Tell whether two names are the same once folded: ASCII letters compared without case, and spaces at either end
 * dropped.
 *
 * @param a One name, UTF-8.
 * @param b The other.
 * @return Whether what's left of them has the same bytes, but for ASCII case; false if either is only spaces.
 */
folded_same :: fn(a: string, b: string) -> bool {
    left :: trimmed(a)
    right :: trimmed(b)
    if left.count != right.count || left.count == 0 {
        return false
    }
    others :: string_bytes(right)
    for character, i in string_bytes(left) {
        if i < others.count && lower(character) != lower(others[i]) {
            return false
        }
    }
    return true
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

/**
 * Give an ASCII letter in lower case.
 *
 * @param byte A byte of UTF-8.
 * @return It in lower case for A to Z; itself otherwise.
 */
lower :: fn(byte: u8) -> u8 {
    return if byte >= cast[u8]('A') && byte <= cast[u8]('Z') { byte + 32 } else { byte }
}
