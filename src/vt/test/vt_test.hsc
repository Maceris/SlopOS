/**
 * The VT adapter's tests, a test program (tools/unit_tests.py, decisions/0175). Styles, moves, scrolling and links
 * become the sequences xterm reads; typed bytes become keys with their modifiers, a bracketed paste one Paste, Ctrl-C an
 * Interrupt, and a sequence cut between two reads is finished by the next. Hemera's strings have no escapes for ESC or
 * other bytes, so here ` stands for ESC and ^ before a letter for that letter's control code (^? for DEL).
 */
package vt_test

import testing from "std"
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
 * Check that a text buffer holds the bytes a test string stands for, reporting both if it doesn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param out The text buffer, only read: its whole contents are compared, not just its start.
 * @param text The test string, as bytes_of reads it.
 * @param message Why out should hold them, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_same :: fn(t: ptr[mut testing.T], out: ptr[text_buffer.TextBuffer], text: string, message: string, location := #caller_location) {
    expected := bytes_of(text)
    wanted :: string_of(&expected.bytes[0], expected.count)
    written :: text_buffer.as_string(out)
    testing.expect_eq(t, written, wanted, message, location)
}

styles_become_sgr_sequences #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    storage : u8[256]
    out := text_buffer.make(storage)
    vt.append_style(&out, terminal.Style.{attributes = terminal.BOLD, foreground = terminal.palette(1),
        background = terminal.palette(200)})
    expect_same(t, &out, "`[0;1;31;48;5;200m", "bold, red from the 8 colours, and a 256-colour background, after a reset")
    text_buffer.clear(&out)
    vt.append_style(&out, terminal.Style.{foreground = terminal.rgb(1, 2, 3),
        background = terminal.palette(9)})
    expect_same(t, &out, "`[0;38;2;1;2;3;101m", "an RGB foreground, and bright red's own background code")
    return .Ok
}

moves_and_scrolling_become_their_sequences #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    storage : u8[256]
    out := text_buffer.make(storage)
    vt.append_move(&out, 0, 4)
    vt.append_scroll(&out, 1, 23, -2)
    expect_same(t, &out, "`[1;5H`[2;24r`[2T", "CUP and DECSTBM count from 1; scrolling down two is SD 2")
    return .Ok
}

a_links_target_keeps_only_printable_ascii #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    storage : u8[256]
    out := text_buffer.make(storage)
    target := bytes_of("https://a.b/`]c d")
    vt.append_link(&out, view(&target))
    expect_same(t, &out, "`]8;;https://a.b/]cd`\\", "ESC and space are dropped, so the target can't end the OSC 8 early")
    return .Ok
}

typed_bytes_become_keys_with_their_modifiers #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    // Typing: letters, Enter as CR LF once, Backspace, an arrow with Ctrl, F5, Alt-x, Ctrl-A, and Ctrl-C
    decoder := vt.Decoder.{}
    decoded := vt.Decoded.{}
    typed := bytes_of("hi\r\n^?`[1;5A`[15~`xa^A^C")
    vt.feed(&decoder, view(&typed), &decoded)
    vt.finish(&decoder, &decoded)
    testing.require_eq(t, decoded.count, 10, "two letters, Enter, Backspace, Ctrl-Up, F5, Alt-x, a, Ctrl-A and Ctrl-C")?
    expect_key(t, &decoded, 0, 0x0b, 0, "h", "h is usage 0x0b")
    expect_key(t, &decoded, 1, 0x0c, 0, "i", "i is usage 0x0c")
    expect_key(t, &decoded, 2, vt.USAGE_ENTER, 0, "\n", "CR LF is one Enter, typing a newline")
    expect_key(t, &decoded, 3, vt.USAGE_BACKSPACE, 0, "", "DEL is Backspace")
    expect_key(t, &decoded, 4, vt.USAGE_UP, terminal.CONTROL, "", "CSI 1;5A is Up with modifier 5, Ctrl")
    expect_key(t, &decoded, 5, vt.USAGE_F5, 0, "", "CSI 15~ is F5")
    expect_key(t, &decoded, 6, 0x1b, terminal.ALT, "x", "ESC before a letter is Alt with it")
    expect_key(t, &decoded, 7, 0x04, 0, "a", "a is usage 0x04")
    expect_key(t, &decoded, 8, vt.USAGE_A, terminal.CONTROL, "", "0x01 is Ctrl-A")
    testing.expect_eq(t, decoded.events[9].kind, cast[u8](terminal.EventKind.Interrupt), "Ctrl-C interrupts, not a key")
    return .Ok
}

a_bracketed_paste_is_one_event #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    // A paste is one event, with no keys inside it; a lone ESC at the end is Escape
    decoder := vt.Decoder.{}
    decoded := vt.Decoded.{}
    pasted := bytes_of("`[200~ls\r^C`[201~`")
    vt.feed(&decoder, view(&pasted), &decoded)
    vt.finish(&decoder, &decoded)
    testing.require_eq(t, decoded.count, 2, "the paste, and the ESC after it")?
    testing.expect_eq(t, decoded.events[0].kind, cast[u8](terminal.EventKind.Paste), "what's between 200~ and 201~ is pasted")
    testing.expect_eq(t, text_of(&decoded, 0), "ls\r", "its text as it was, CR and all")
    expect_key(t, &decoded, 1, vt.USAGE_ESCAPE, 0, "", "a lone ESC at the end, with nothing to follow, is Escape")
    if decoded.text_count < 4 {
        testing.fail(t, "the paste's text holds its Ctrl-C, its fourth byte")
        return .Ok
    }
    testing.expect_eq(t, decoded.text[3], 0x03, "Ctrl-C inside a paste is text, not an interrupt")
    return .Ok
}

a_sequence_cut_between_reads_is_finished_by_the_next #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    decoder := vt.Decoder.{}
    decoded := vt.Decoded.{}
    vt.feed(&decoder, u8.[0xe4, 0xb8], &decoded)
    testing.expect_eq(t, decoded.count, 0, "two bytes of a three-byte code point are no event yet")
    vt.feed(&decoder, u8.[0xad, 0x1b], &decoded)
    right := bytes_of("[C")
    vt.feed(&decoder, view(&right), &decoded)
    vt.finish(&decoder, &decoded)
    testing.require_eq(t, decoded.count, 2, "the code point, and the arrow cut after its ESC")?
    testing.expect_eq(t, text_of(&decoded, 0), "中", "the code point's last byte finishes it")
    expect_key(t, &decoded, 1, vt.USAGE_RIGHT, 0, "", "ESC, then [C in the next read, is Right")
    return .Ok
}

/**
 * Check that an event is a key with the given usage, modifiers and text, reporting what differs if it isn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param decoded The events and their text, only read; only the first count events are looked at.
 * @param index The event's index, from 0; past the events, it's a failure.
 * @param code The key's HID usage expected, or 0 for one known by its text.
 * @param modifiers The modifiers expected, as terminal.SHIFT, ALT, CONTROL and META's bits; they have to match exactly.
 * @param text The text expected; only its first three bytes are compared (text_of).
 * @param message Why it should be that key, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 */
expect_key :: fn(t: ptr[mut testing.T], decoded: ptr[vt.Decoded], index: usize, code: u16, modifiers: u8, text: string, message: string,
        location := #caller_location) {
    if index >= decoded.count || index >= decoded.events.count {
        testing.record(t, message, "the event isn't there", location)
        return void
    }
    found :: decoded.events[index]
    testing.expect_eq(t, found.kind, cast[u8](terminal.EventKind.Key), message, location)
    testing.expect_eq(t, found.code, code, message, location)
    testing.expect_eq(t, found.modifiers, modifiers, message, location)
    testing.expect_eq(t, text_of(decoded, index), text, message, location)
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
