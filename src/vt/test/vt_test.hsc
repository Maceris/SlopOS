/**
 * The VT adapter's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the number
 * of the first check that failed. Styles, moves, scrolling and links become the sequences xterm reads; typed bytes
 * become keys with their modifiers, a bracketed paste one Paste, Ctrl-C an Interrupt, and a sequence cut between two
 * reads is finished by the next. Hemera's strings have no escapes for ESC or other bytes, so here ` stands for ESC and
 * ^ before a letter for that letter's control code (^? for DEL).
 */
package vt_test

import text_buffer from "std"
import terminal from "std/os/slop_os"
import vt from ".."

/** A string's bytes with ` as ESC and ^X as Ctrl-X. */
Bytes :: struct {
    /** The bytes, the first count of them. */
    bytes : u8[256],
    /** How many of bytes there are, at most 256. */
    count : usize,
}

/**
 * Make the bytes a test string stands for: ` as ESC, ^ and a character as its control code (^? as DEL).
 *
 * @param text The string; what's past 256 bytes, once made, is dropped.
 * @return The bytes, by value, at most 256 of them: ` made ESC, ^? DEL, ^ and another character that character's low
 *     five bits, and a ^ at the string's end kept as it is.
 */
bytes_of :: fn(text: string) -> Bytes {
    made := Bytes.{}
    source :: string_bytes(text)
    i : usize = 0
    loop {
        if i >= source.count || made.count >= made.bytes.count {
            break
        }
        byte := source[i]
        i += 1
        if byte == cast[u8]('`') {
            byte = 0x1b
        }
        else if byte == cast[u8]('^') && i < source.count {
            next :: source[i]
            i += 1
            byte = if next == cast[u8]('?') { cast[u8](0x7f) } else { next & 0x1f }
        }
        made.bytes[made.count] = byte
        made.count += 1
    }
    return made
}

/**
 * View the bytes in a Bytes.
 *
 * @param made The Bytes, only read; its count is trusted only up to 256, past which the view is empty.
 * @return Its first count bytes, a view of made's, good as long as it is.
 */
view :: fn(made: ptr[Bytes]) -> u8[] {
    return if made.count <= made.bytes.count { made.bytes[0..<made.count] } else { made.bytes[0..<0] }
}

/**
 * Tell whether a text buffer holds the bytes a test string stands for.
 *
 * @param out The text buffer, only read: its whole contents are compared, not just its start.
 * @param text The test string, as bytes_of reads it.
 * @return True if out holds exactly those bytes.
 */
same :: fn(out: ptr[text_buffer.TextBuffer], text: string) -> bool {
    expected := bytes_of(text)
    return text_buffer.as_string(out) == string_of(&expected.bytes[0], expected.count)
}

/**
 * Run the VT adapter's tests.
 *
 * @return 0 if every check passed, or the number of the first check that failed.
 */
main :: fn() -> int {
    storage : u8[256]
    out := text_buffer.make(storage)

    // Bold red on a 256-colour background, then RGB on a bright one
    vt.append_style(&out, terminal.Style.{attributes = terminal.BOLD, foreground = terminal.palette(1),
        background = terminal.palette(200)})
    if !same(&out, "`[0;1;31;48;5;200m") {
        return 1
    }
    text_buffer.clear(&out)
    vt.append_style(&out, terminal.Style.{foreground = terminal.rgb(1, 2, 3),
        background = terminal.palette(9)})
    if !same(&out, "`[0;38;2;1;2;3;101m") {
        return 2
    }
    text_buffer.clear(&out)
    vt.append_move(&out, 0, 4)
    vt.append_scroll(&out, 1, 23, -2)
    if !same(&out, "`[1;5H`[2;24r`[2T") {
        return 3
    }
    // A link's target keeps only printable ASCII, so it can't end the sequence
    text_buffer.clear(&out)
    target := bytes_of("https://a.b/`]c d")
    vt.append_link(&out, view(&target))
    if !same(&out, "`]8;;https://a.b/]cd`\\") {
        return 4
    }

    // Typing: letters, Enter as CR LF once, Backspace, an arrow with Ctrl, F5, Alt-x, Ctrl-A, and Ctrl-C
    decoder := vt.Decoder.{}
    decoded := vt.Decoded.{}
    typed := bytes_of("hi\r\n^?`[1;5A`[15~`xa^A^C")
    vt.feed(&decoder, view(&typed), &decoded)
    vt.finish(&decoder, &decoded)
    if decoded.count != 10 {
        return 10
    }
    if !is_key(&decoded, 0, 0x0b, 0, "h") || !is_key(&decoded, 1, 0x0c, 0, "i") || !is_key(&decoded, 2, vt.USAGE_ENTER, 0, "\n") {
        return 11
    }
    if !is_key(&decoded, 3, vt.USAGE_BACKSPACE, 0, "") || !is_key(&decoded, 4, vt.USAGE_UP, terminal.CONTROL, "")
        || !is_key(&decoded, 5, vt.USAGE_F5, 0, "") {
        return 12
    }
    if !is_key(&decoded, 6, 0x1b, terminal.ALT, "x") || !is_key(&decoded, 7, 0x04, 0, "a")
        || !is_key(&decoded, 8, vt.USAGE_A, terminal.CONTROL, "") || decoded.events[9].kind != cast[u8](terminal.EventKind.Interrupt) {
        return 13
    }

    // A paste is one event, with no keys inside it; a lone ESC at the end is Escape
    vt.reset(&decoder, &decoded)
    pasted := bytes_of("`[200~ls\r^C`[201~`")
    vt.feed(&decoder, view(&pasted), &decoded)
    vt.finish(&decoder, &decoded)
    if decoded.count != 2 || decoded.events[0].kind != cast[u8](terminal.EventKind.Paste) || text_of(&decoded, 0) != "ls\r"
        || !is_key(&decoded, 1, vt.USAGE_ESCAPE, 0, "") {
        return 20
    }
    if decoded.text_count < 4 || decoded.text[3] != 0x03 {
        return 21
    }

    // A code point and a sequence cut between two reads
    vt.reset(&decoder, &decoded)
    vt.feed(&decoder, u8.[0xe4, 0xb8], &decoded)
    if decoded.count != 0 {
        return 30
    }
    vt.feed(&decoder, u8.[0xad, 0x1b], &decoded)
    right := bytes_of("[C")
    vt.feed(&decoder, view(&right), &decoded)
    vt.finish(&decoder, &decoded)
    if decoded.count != 2 || text_of(&decoded, 0) != "中" || !is_key(&decoded, 1, vt.USAGE_RIGHT, 0, "") {
        return 31
    }
    return 0
}

/**
 * Tell whether an event is a key with the given usage, modifiers and text.
 *
 * @param decoded The events and their text, only read; only the first count events are looked at.
 * @param index The event's index, from 0.
 * @param code The key's HID usage expected, or 0 for one known by its text.
 * @param modifiers The modifiers expected, as terminal.SHIFT, ALT, CONTROL and META's bits; they have to match exactly.
 * @param text The text expected; only its first three bytes are compared (text_of).
 * @return True if the event's there and is that key; false for an index past the events.
 */
is_key :: fn(decoded: ptr[vt.Decoded], index: usize, code: u16, modifiers: u8, text: string) -> bool {
    if index >= decoded.count || index >= decoded.events.count {
        return false
    }
    found :: decoded.events[index]
    return found.kind == cast[u8](terminal.EventKind.Key) && found.code == code && found.modifiers == modifiers && text_of(decoded, index) == text
}

/**
 * Find the first three bytes of an event's text at most, which is all the checks need.
 *
 * @param decoded The events and their text, only read; an index below MAX_EVENTS but past count reads whatever that
 *     slot holds.
 * @param index The event's index, from 0.
 * @return The text, a view of decoded's, good until it's reset; empty for an event with none or an index past them.
 */
text_of :: fn(decoded: ptr[vt.Decoded], index: usize) -> string {
    if index >= decoded.events.count {
        return ""
    }
    found :: decoded.events[index]
    start :: cast[usize](found.text_start)
    end :: start + cast[usize](if found.text_bytes > 3 { cast[u32](3) } else { found.text_bytes })
    if end > decoded.text.count || start >= end {
        return ""
    }
    return string_of(&decoded.text[start], end - start)
}
