/*
 * An account's public keys (decisions/0191, 14c), which log in as it over SSH: kept as text, one OpenSSH key line to a
 * line, as authorized_keys has them, but only the key's kind, its blob and a comment, without options. A line's added
 * once its key's read (std/ssh's parse_key_line) and written again in that form, its comment cut to printable ASCII;
 * one's removed by its key's fingerprint, SHA256:..., as ssh-keygen -l shows it.
 */
package account_records

import ssh from "std"

/** The most keys an account has. */
MAX_KEYS :: 16
/** The most bytes of a key's line, an RSA key's of 8192 bits with a comment among them. */
KEY_LINE_BYTES :: 2048
/** The most bytes of an account's keys' text: MAX_KEYS lines, each with its line break. */
KEYS_TEXT_BYTES :: MAX_KEYS * (KEY_LINE_BYTES + 1)
/** The most bytes of a key's comment kept. */
COMMENT_BYTES :: 100

/** What adding a key came to. */
KeyAdded :: union {
    /** It's added: the keys' text, with its line last, is this long. */
    Added(usize),
    /** The line isn't a key std/ssh reads, or it's longer than KEY_LINE_BYTES. */
    NotAKey,
    /** The account has the key already, whatever its comment. */
    AlreadyThere,
    /** The account has MAX_KEYS keys, or the text wouldn't fit. */
    Full,
}

/**
 * Add a key to an account's keys.
 *
 * @param keys The account's keys' text now, lines as this file writes them; empty for none.
 * @param line The key's line, as authorized_keys or a .pub file has it: its kind, its blob in base64, and a comment
 *     if it has one; without options. Spaces and a line break at its end are ignored.
 * @param into Where the keys' text with it goes; KEYS_TEXT_BYTES is room enough. It mustn't be keys.
 * @return Added with the new text's length, or why it isn't.
 */
add_key :: fn(keys: u8[], line: u8[], into: mut u8[]) -> KeyAdded {
    if line.count > KEY_LINE_BYTES {
        return .NotAKey
    }
    key :: ssh.parse_key_line(line) or_return .NotAKey
    if has_key(keys, ssh.blob_of(&key)) {
        return .AlreadyThere
    }
    if key_count(keys) >= MAX_KEYS {
        return .Full
    }
    comment : u8[COMMENT_BYTES]
    comment_count :: comment_of(line, comment[0..<COMMENT_BYTES])
    written : u8[KEY_LINE_BYTES]
    length :: ssh.key_line(&key, string_of(&comment[0], comment_count), written[0..<KEY_LINE_BYTES])
    if length == 0 {
        return .NotAKey
    }
    at := cast[usize](0)
    reading := cast[usize](0)
    loop {
        each :: next_line(keys, &reading) or_break
        at = put(into, at, each)
    }
    while true
    at = put(into, at, ssh.range(written[0..<KEY_LINE_BYTES], 0, length))
    if at > into.count {
        return .Full
    }
    return .Added(at)
}

/**
 * Remove a key from an account's keys, by its fingerprint.
 *
 * @param keys The account's keys' text now.
 * @param fingerprint The key's fingerprint, SHA256: and 43 characters of base64, as key_fingerprint gives it.
 * @param into Where the keys' text without it goes; keys.count is room enough. It mustn't be keys.
 * @return The new text's length; null if no key has that fingerprint.
 */
remove_key :: fn(keys: u8[], fingerprint: u8[], into: mut u8[]) -> usize? {
    found := false
    at := cast[usize](0)
    reading := cast[usize](0)
    loop {
        each :: next_line(keys, &reading) or_break
        if !found && line_has_fingerprint(each, fingerprint) {
            found = true
        }
        else {
            at = put(into, at, each)
        }
    }
    while true
    return if found && at <= into.count { at } else { null }
}

/**
 * Tell whether an account's keys have a key.
 *
 * @param keys The account's keys' text.
 * @param blob The key's blob, as SSH sends it.
 * @return True if one of its lines is that key.
 */
has_key :: fn(keys: u8[], blob: u8[]) -> bool {
    reading := cast[usize](0)
    loop {
        each :: next_line(keys, &reading) or_break
        key :: ssh.parse_key_line(each) or_continue
        if ssh.same(ssh.blob_of(&key), blob) {
            return true
        }
    }
    while true
    return false
}

/** Tell whether an account's keys have the key of a line; false if the line isn't a key's. */
has_key_line :: fn(keys: u8[], line: u8[]) -> bool {
    key :: ssh.parse_key_line(line) or_return false
    return has_key(keys, ssh.blob_of(&key))
}

/** How many keys an account's keys' text has: its lines that aren't empty. */
key_count :: fn(keys: u8[]) -> usize {
    count := cast[usize](0)
    reading := cast[usize](0)
    loop {
        _ = next_line(keys, &reading) or_break
        count += 1
    }
    while true
    return count
}

/**
 * A key line's key's fingerprint.
 *
 * @param line The line.
 * @return Its fingerprint, SHA256: and 43 characters of base64, 50 bytes; null if it isn't a key's line.
 */
key_fingerprint :: fn(line: u8[]) -> u8[50]? {
    key :: ssh.parse_key_line(line) or_return null
    return ssh.fingerprint(ssh.blob_of(&key))
}

/** Whether a line is a key whose fingerprint is the one given. */
line_has_fingerprint :: fn(line: u8[], fingerprint: u8[]) -> bool {
    printed :: key_fingerprint(line) or_return false
    return ssh.same(printed[0..<50], fingerprint)
}

/**
 * The next line of a keys' text that isn't empty, without its line break and the blanks at its ends.
 *
 * @param keys The text.
 * @param at Where to look from, 0 at first; moved past the line.
 * @return The line, a view of the text; null after the last.
 */
next_line :: fn(keys: u8[], at: ptr[mut usize]) -> u8[]? {
    loop {
        if at^ >= keys.count {
            return null
        }
        start :: at^
        end := start
        loop {
            end += 1
        }
        while end < keys.count && ssh.byte_at(keys, end) != 0x0a
        at^ = end + 1
        line :: trimmed(ssh.range(keys, start, end))
        if line.count > 0 {
            return line
        }
    }
    while true
    return null
}

/** A line without the blanks at its ends. */
trimmed :: fn(line: u8[]) -> u8[] {
    start := cast[usize](0)
    end := line.count
    loop {
        start += 1
    }
    while start < end && is_blank(ssh.byte_at(line, start))
    loop {
        end -= 1
    }
    while end > start && is_blank(ssh.byte_at(line, end - 1))
    return ssh.range(line, start, end)
}

/** Whether a byte is a space, a tab, a carriage return or a line break. */
is_blank :: fn(byte: u8) -> bool {
    return byte == 0x20 || byte == 0x09 || byte == 0x0d || byte == 0x0a
}

/**
 * A key line's comment: what's after its kind and blob, trimmed, its bytes outside printable ASCII left out, and cut
 * at COMMENT_BYTES.
 *
 * @param line The line.
 * @param into Where it goes.
 * @return Its length.
 */
comment_of :: fn(line: u8[], into: mut u8[]) -> usize {
    text :: trimmed(line)
    // Past two words and the blanks after each
    at := cast[usize](0)
    for word in 0..<2 {
        loop {
            at += 1
        }
        while at < text.count && !is_blank(ssh.byte_at(text, at))
        loop {
            at += 1
        }
        while at < text.count && is_blank(ssh.byte_at(text, at))
    }
    count := cast[usize](0)
    for byte in ssh.range(text, at, text.count) {
        if byte >= 0x20 && byte < 0x7f && count < into.count {
            into[count] = byte
            count += 1
        }
    }
    return count
}

/** Put a line and a line break into a text at an offset, as far as it fits; where the next goes, counting all of it. */
put :: fn(into: mut u8[], at: usize, line: u8[]) -> usize {
    for byte, i in line {
        if at + i < into.count {
            into[at + i] = byte
        }
    }
    end :: at + line.count
    if end < into.count {
        into[end] = 0x0a
    }
    return end + 1
}

/** The first count bytes of a view, or all of it if count's past its end. */
part :: fn(view: u8[], count: usize) -> u8[] {
    return if count <= view.count { view[0..<count] } else { view }
}
