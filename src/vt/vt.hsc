/**
 * The VT adapter (decisions/0136, design/console-and-sessions.md §2): the terminal protocol turned into ECMA-48's
 * bytes for a byte-stream device, the serial line now and an SSH client's terminal in M14, and that device's bytes
 * turned back into typed input. It's the only place escape sequences exist: text reaches it already made safe
 * (safe_text), so what a program prints can't become a sequence. Output appends to a TextBuffer; input goes through a
 * Decoder, which keeps what a chunk of bytes cut short for the next.
 */
package vt

import text_buffer from "std"
import terminal from "std/os/slop_os"

/** ESC, which starts every escape sequence. */
ESCAPE : u8 : 0x1b
/** A byte to slice empty, for keys that type nothing. */
NO_TEXT :: u8.[0]

// USB HID usages (page 7) of the keys a byte stream can send.
/** The HID usage of A; B to Z follow it. */
USAGE_A : u16 : 0x04
/** The HID usage of Enter. */
USAGE_ENTER : u16 : 0x28
/** The HID usage of Escape. */
USAGE_ESCAPE : u16 : 0x29
/** The HID usage of Backspace. */
USAGE_BACKSPACE : u16 : 0x2a
/** The HID usage of Tab. */
USAGE_TAB : u16 : 0x2b
/** The HID usage of F1; F2 to F12 follow it. */
USAGE_F1 : u16 : 0x3a
/** The HID usage of F5. */
USAGE_F5 : u16 : 0x3e
/** The HID usage of Insert. */
USAGE_INSERT : u16 : 0x49
/** The HID usage of Home. */
USAGE_HOME : u16 : 0x4a
/** The HID usage of Page Up. */
USAGE_PAGE_UP : u16 : 0x4b
/** The HID usage of Delete (forward). */
USAGE_DELETE : u16 : 0x4c
/** The HID usage of End. */
USAGE_END : u16 : 0x4d
/** The HID usage of Page Down. */
USAGE_PAGE_DOWN : u16 : 0x4e
/** The HID usage of the right arrow. */
USAGE_RIGHT : u16 : 0x4f
/** The HID usage of the left arrow. */
USAGE_LEFT : u16 : 0x50
/** The HID usage of the down arrow. */
USAGE_DOWN : u16 : 0x51
/** The HID usage of the up arrow. */
USAGE_UP : u16 : 0x52

// Output.

/**
 * Append CSI: ESC [.
 *
 * @param out The text appended to; what doesn't fit its storage is dropped, as text_buffer drops it.
 */
append_csi :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('['))
}

/**
 * Append the SGR sequence for a style, from the default: reset, then each attribute and colour the style has.
 *
 * @param out The text appended to.
 * @param style The style: bold, dim, italic, underline, inverse and strikethrough, and its two colours, each left out
 *     when it's the default.
 */
append_style :: fn(out: ptr[mut text_buffer.TextBuffer], style: terminal.Style) {
    append_csi(out)
    text_buffer.append_byte(out, cast[u8]('0'))
    attributes :: u8.[terminal.BOLD, terminal.DIM, terminal.ITALIC, terminal.UNDERLINE, terminal.INVERSE, terminal.STRIKETHROUGH]
    codes :: u8.[1, 2, 3, 4, 7, 9]
    for attribute, i in attributes {
        if style.attributes & attribute != 0 && i < codes.count {
            text_buffer.append_byte(out, cast[u8](';'))
            text_buffer.append_unsigned(out, cast[u64](codes[i]))
        }
    }
    append_color(out, style.foreground, 30)
    append_color(out, style.background, 40)
    text_buffer.append_byte(out, cast[u8]('m'))
}

/**
 * Append a colour's SGR parameters, after a ';': the 8 colours as base and on, their bright ones as base + 60 and on,
 * the rest of the 256 as base + 8;5;n, and RGB as base + 8;2;r;g;b.
 *
 * @param out The text appended to.
 * @param color The colour; nothing's appended for the default.
 * @param base 30 for the foreground, 40 for the background.
 */
append_color :: fn(out: ptr[mut text_buffer.TextBuffer], color: terminal.Color, base: u64) {
    match terminal.color_kind(color) {
        case .Default => return void
        case .Palette => {
            text_buffer.append_byte(out, cast[u8](';'))
            if color.index < 8 {
                text_buffer.append_unsigned(out, base + cast[u64](color.index))
            }
            else if color.index < 16 {
                // The bright ones, 90 and 100 on
                text_buffer.append_unsigned(out, base + 60 + cast[u64](color.index - 8))
            }
            else {
                text_buffer.append_unsigned(out, base + 8)
                text_buffer.append(out, ";5;")
                text_buffer.append_unsigned(out, cast[u64](color.index))
            }
        }
        case .Rgb => {
            text_buffer.append_byte(out, cast[u8](';'))
            text_buffer.append_unsigned(out, base + 8)
            text_buffer.append(out, ";2;")
            text_buffer.append_unsigned(out, cast[u64](color.red))
            text_buffer.append_byte(out, cast[u8](';'))
            text_buffer.append_unsigned(out, cast[u64](color.green))
            text_buffer.append_byte(out, cast[u8](';'))
            text_buffer.append_unsigned(out, cast[u64](color.blue))
        }
    }
}

/**
 * Append CUP, which moves the cursor.
 *
 * @param out The text appended to.
 * @param row The row, from 0; CUP's own count from 1.
 * @param column The column, from 0.
 */
append_move :: fn(out: ptr[mut text_buffer.TextBuffer], row: u16, column: u16) {
    append_csi(out)
    text_buffer.append_unsigned(out, cast[u64](row) + 1)
    text_buffer.append_byte(out, cast[u8](';'))
    text_buffer.append_unsigned(out, cast[u64](column) + 1)
    text_buffer.append_byte(out, cast[u8]('H'))
}

/**
 * Append CHA, which moves the cursor to a column on its line.
 *
 * @param out The text appended to.
 * @param column The column, from 0.
 */
append_column :: fn(out: ptr[mut text_buffer.TextBuffer], column: u16) {
    append_csi(out)
    text_buffer.append_unsigned(out, cast[u64](column) + 1)
    text_buffer.append_byte(out, cast[u8]('G'))
}

/**
 * Append EL, which clears the cursor's line from the cursor to its end.
 *
 * @param out The text appended to.
 */
append_clear_to_end :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    append_csi(out)
    text_buffer.append_byte(out, cast[u8]('K'))
}

/**
 * Append ED, which clears the screen from the cursor to its end.
 *
 * @param out The text appended to.
 */
append_clear_below :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    append_csi(out)
    text_buffer.append_byte(out, cast[u8]('J'))
}

/**
 * Append ED and CUP, which clear the whole screen and put the cursor at its top left.
 *
 * @param out The text appended to.
 */
append_clear_screen :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    append_csi(out)
    text_buffer.append(out, "2J")
    append_move(out, 0, 0)
}

/**
 * Append DECSTBM, which sets the rows that scroll; the terminal puts the cursor at the top left.
 *
 * @param out The text appended to.
 * @param first The first row that scrolls, from 0.
 * @param last The last row that scrolls, from 0, included; not before first.
 */
append_margins :: fn(out: ptr[mut text_buffer.TextBuffer], first: u16, last: u16) {
    append_csi(out)
    text_buffer.append_unsigned(out, cast[u64](first) + 1)
    text_buffer.append_byte(out, cast[u8](';'))
    text_buffer.append_unsigned(out, cast[u64](last) + 1)
    text_buffer.append_byte(out, cast[u8]('r'))
}

/**
 * Append what moves rows up or down: their margins set (DECSTBM), then SU or SD.
 *
 * The margins stay as set, for the caller to put back, and the cursor is left at the top left.
 *
 * @param out The text appended to.
 * @param first The first row moved, from 0.
 * @param last The last row moved, from 0, included.
 * @param lines How many rows they're moved up, or down when negative. 0 is sent as SU's 0, which a terminal takes as
 *     1.
 */
append_scroll :: fn(out: ptr[mut text_buffer.TextBuffer], first: u16, last: u16, lines: i16) {
    append_margins(out, first, last)
    append_csi(out)
    if lines >= 0 {
        text_buffer.append_unsigned(out, cast[u64](lines))
        text_buffer.append_byte(out, cast[u8]('S'))
    }
    else {
        text_buffer.append_unsigned(out, cast[u64](-cast[i32](lines)))
        text_buffer.append_byte(out, cast[u8]('T'))
    }
}

/**
 * Append DECSC, which saves the cursor and its style, for DECRC (append_restore_cursor) to put back.
 *
 * @param out The text appended to.
 */
append_save_cursor :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('7'))
}

/**
 * Append DECRC, which puts back the cursor and its style as DECSC (append_save_cursor) saved them.
 *
 * @param out The text appended to.
 */
append_restore_cursor :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('8'))
}

/**
 * Append DECTCEM, which shows or hides the cursor.
 *
 * @param out The text appended to.
 * @param shown True to show the cursor, false to hide it.
 */
append_cursor_shown :: fn(out: ptr[mut text_buffer.TextBuffer], shown: bool) {
    append_csi(out)
    text_buffer.append(out, if shown { "?25h" } else { "?25l" })
}

/**
 * Append what enters the alternate screen, a program's own, and clears it, or leaves it for the lines as they were.
 *
 * @param out The text appended to.
 * @param entered True to enter it, cleared, with the cursor at its top left; false to leave it.
 */
append_alternate_screen :: fn(out: ptr[mut text_buffer.TextBuffer], entered: bool) {
    append_csi(out)
    text_buffer.append(out, if entered { "?1049h" } else { "?1049l" })
    if entered {
        append_clear_screen(out)
    }
}

/**
 * Append OSC 8, which makes what follows a link, or stops linking.
 *
 * @param out The text appended to.
 * @param target The link's target, a URI; empty to stop linking. Only its printable ASCII, without spaces, is kept,
 *     so it can't end the sequence early or hide another in it.
 */
append_link :: fn(out: ptr[mut text_buffer.TextBuffer], target: u8[]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append(out, "]8;;")
    for byte in target {
        if byte > 0x20 && byte < 0x7f {
            text_buffer.append_byte(out, byte)
        }
    }
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('\\'))
}

/**
 * Append BEL, which rings the terminal's bell.
 *
 * @param out The text appended to.
 */
append_bell :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, 0x07)
}

/**
 * Append a line break: CR LF.
 *
 * @param out The text appended to.
 */
append_line_break :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, 0x0d)
    text_buffer.append_byte(out, 0x0a)
}

// Input.

/** Where a Decoder is in the bytes: outside a sequence, or how far into one. */
DecoderState :: enum #backed_by(u8) {
    /** Outside a sequence: bytes are keys, text, or a code point's bytes. */
    Ground = 0,
    /** After ESC. */
    Escape = 1,
    /** After ESC [, gathering parameters. */
    Csi = 2,
    /** After ESC O. */
    Ss3 = 3,
}

/** The most parameters of a CSI sequence a Decoder keeps; any after them are dropped. */
MAX_PARAMETERS :: 4

/**
 * Turns a byte stream's input into events: keys (with their text, modifiers and HID usage where there's one), pastes
 * between bracketed paste's markers, and Ctrl-C as an Interrupt.
 */
Decoder :: struct {
    /** Where it is in the bytes: outside a sequence, or how far into one. */
    state : DecoderState,
    /** The CSI sequence's parameters so far, 0 for one not given; a digit past 100000 is dropped. */
    parameters : u32[MAX_PARAMETERS],
    /** How many parameters the CSI sequence has so far: 0 before any digit or ';'. */
    parameter_count : usize,
    /** A private marker after CSI, like '?' or '<', or 0; a sequence with one is ignored. */
    private : u8,
    /** Whether it's between bracketed paste's start and end markers, so bytes are pasted text, not keys. */
    pasting : bool,
    /** Where the paste's text so far starts in decoded's text. */
    paste_start : usize,
    /** Whether a CR was the last byte, so an LF right after it is the same line break. */
    after_return : bool,
    /** A UTF-8 code point's bytes so far. */
    partial : u8[4],
    /** How many of partial's bytes there are so far. */
    partial_count : usize,
    /** How many bytes the code point being gathered takes, 2 to 4; 0 when none is. */
    partial_needed : usize,
}

/** What a Decoder made of some bytes: events, and the text they hold ranges of. */
Decoded :: struct {
    /** The events, the first count of them, in the order the bytes came. */
    events : terminal.Event[terminal.MAX_EVENTS],
    /** How many of events there are, at most MAX_EVENTS; events past them are dropped. */
    count : usize,
    /** The text the events' text_start and text_bytes are ranges of. */
    text : u8[terminal.MAX_EVENT_TEXT],
    /** How many of text's bytes are in use, at most MAX_EVENT_TEXT. */
    text_count : usize,
}

/**
 * Decode bytes from the device into events.
 *
 * A sequence or code point cut short by the bytes' end waits in the decoder for the next bytes. A key whose text
 * doesn't fit in what's left of decoded's text, or any event past MAX_EVENTS, is dropped, so a caller resets decoded
 * after taking each chunk's events.
 *
 * @param decoder The decoder, which keeps its place between chunks.
 * @param bytes The bytes, as they came from the device.
 * @param decoded Where the events and their text are added, after what's there already.
 */
feed :: fn(decoder: ptr[mut Decoder], bytes: u8[], decoded: ptr[mut Decoded]) {
    for byte in bytes {
        feed_byte(decoder, byte, decoded)
    }
}

/**
 * Finish what's arrived for now: an ESC that nothing followed is the Escape key, since a sequence arrives whole, and
 * a paste still open is given as far as it's come, to go on in another Paste event.
 *
 * @param decoder The decoder: from Escape it goes back to Ground; while pasting, its paste goes on, paste_start moved
 *     past the text given. A sequence or code point it's partway through stays, for the next bytes.
 * @param decoded Where the Escape key or the Paste event is added, after what's there already; dropped if there's no
 *     room.
 */
finish :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded]) {
    if decoder.state == .Escape {
        key(decoded, USAGE_ESCAPE, 0, NO_TEXT[0..<0])
        decoder.state = .Ground
    }
    if decoder.pasting {
        give_paste(decoder, decoded)
    }
}

/**
 * Decode one byte, by where the decoder is in the bytes.
 *
 * @param decoder The decoder, whose state moves on.
 * @param byte Any byte from the device: in Escape, '[' starts a CSI sequence, 'O' an SS3 one, another ESC is the Escape
 *     key, and anything else is that key with Alt; in Csi or Ss3 it goes on with that sequence; in Ground it's decoded
 *     as ground does.
 * @param decoded Where any event it finishes is added.
 */
feed_byte :: fn(decoder: ptr[mut Decoder], byte: u8, decoded: ptr[mut Decoded]) {
    match decoder.state {
        case .Ground => ground(decoder, byte, decoded)
        case .Escape => {
            if byte == cast[u8]('[') {
                decoder.state = .Csi
                decoder.parameter_count = 0
                decoder.parameters = u32.[0, 0, 0, 0]
                decoder.private = 0
            }
            else if byte == cast[u8]('O') {
                decoder.state = .Ss3
            }
            else if byte == ESCAPE {
                // Escape, then another sequence's start
                key(decoded, USAGE_ESCAPE, 0, NO_TEXT[0..<0])
            }
            else {
                // Alt and the key
                decoder.state = .Ground
                ground_with(decoder, byte, decoded, terminal.ALT)
            }
        }
        case .Csi => csi(decoder, byte, decoded)
        case .Ss3 => {
            decoder.state = .Ground
            code :: ss3_key(byte)
            if code != 0 {
                key(decoded, code, 0, NO_TEXT[0..<0])
            }
        }
    }
}

/**
 * Decode a byte outside a sequence, without modifiers.
 *
 * @param decoder The decoder, in Ground: an ESC moves it to Escape, and it can start or go on gathering a code point or
 *     a paste's text.
 * @param byte Any byte, decoded as ground_with does with no modifiers.
 * @param decoded Where any event it makes is added.
 */
ground :: fn(decoder: ptr[mut Decoder], byte: u8, decoded: ptr[mut Decoded]) {
    ground_with(decoder, byte, decoded, 0)
}

/**
 * Decode a byte outside a sequence, with modifiers already known (Alt, after an ESC).
 *
 * In a paste, every byte but ESC is pasted text. Otherwise CR, or an LF not right after one, is Enter typing a line
 * feed; DEL and BS are Backspace; Tab types a tab; ETX is an Interrupt; other C0 bytes are Ctrl and a letter, or
 * nothing; ASCII types itself; and a UTF-8 code point's bytes are gathered to type it. A byte that can't start UTF-8
 * is dropped.
 *
 * @param decoder The decoder, in Ground: after_return is set by a CR and cleared by anything else, an ESC moves it to
 *     Escape, a UTF-8 lead byte starts gathering a code point in partial, and while pasting the byte goes to the
 *     paste's text.
 * @param byte Any byte: in a paste, ESC or pasted text; while a code point's being gathered, its next byte
 *     (continue_code_point); otherwise CR or LF, DEL or BS, Tab, ETX, another C0 byte, ASCII, or a UTF-8 lead byte, as
 *     above. A continuation byte or one from 0xf8 up, which starts nothing, is dropped.
 * @param decoded Where any event it makes is added.
 * @param modifiers The modifiers (terminal.SHIFT, ALT, CONTROL, META) the key it makes has.
 */
ground_with :: fn(decoder: ptr[mut Decoder], byte: u8, decoded: ptr[mut Decoded], modifiers: u8) {
    was_return :: decoder.after_return
    decoder.after_return = false
    if decoder.pasting {
        if byte == ESCAPE {
            decoder.state = .Escape
            return void
        }
        add_text(decoder, decoded, byte)
        return void
    }
    if decoder.partial_needed > 0 {
        continue_code_point(decoder, byte, decoded, modifiers)
        return void
    }
    if byte == ESCAPE {
        decoder.state = .Escape
        return void
    }
    if byte == 0x0d {
        decoder.after_return = true
        key(decoded, USAGE_ENTER, modifiers, u8.[0x0a])
        return void
    }
    if byte == 0x0a {
        if !was_return {
            key(decoded, USAGE_ENTER, modifiers, u8.[0x0a])
        }
        return void
    }
    if byte == 0x7f || byte == 0x08 {
        key(decoded, USAGE_BACKSPACE, modifiers, NO_TEXT[0..<0])
        return void
    }
    if byte == 0x09 {
        key(decoded, USAGE_TAB, modifiers, u8.[0x09])
        return void
    }
    if byte == 0x03 {
        event(decoded, terminal.event_of(.Interrupt))
        return void
    }
    if byte < 0x20 {
        // Ctrl and a letter: 0x01 is Ctrl-A; the rest of C0 has no key
        if byte >= 0x01 && byte <= 0x1a {
            key(decoded, USAGE_A + cast[u16](byte - 1), modifiers | terminal.CONTROL, NO_TEXT[0..<0])
        }
        return void
    }
    if byte < 0x80 {
        key(decoded, ascii_usage(byte), modifiers, u8.[byte])
        return void
    }
    // A code point's first byte; anything else that isn't UTF-8 is dropped
    needed :: if byte & 0xe0 == 0xc0 { cast[usize](2) } else if byte & 0xf0 == 0xe0 { cast[usize](3) } else if byte & 0xf8 == 0xf0 { cast[usize](4) } else { cast[usize](0) }
    if needed == 0 {
        return void
    }
    decoder.partial[0] = byte
    decoder.partial_count = 1
    decoder.partial_needed = needed
}

/**
 * Add a byte to the code point being gathered, typing it once it's whole.
 *
 * A byte that can't continue it drops what was gathered, and is decoded on its own.
 *
 * @param decoder The decoder, gathering a code point.
 * @param byte Any byte: a continuation byte (10xxxxxx) is added to partial, and anything else drops what was gathered
 *     and is decoded again by ground_with.
 * @param decoded Where the key, once the code point is whole, is added; it has no HID usage.
 * @param modifiers The modifiers the key has.
 */
continue_code_point :: fn(decoder: ptr[mut Decoder], byte: u8, decoded: ptr[mut Decoded], modifiers: u8) {
    if byte & 0xc0 != 0x80 || decoder.partial_count >= decoder.partial.count {
        // Cut short: dropped, and this byte starts again
        decoder.partial_needed = 0
        ground_with(decoder, byte, decoded, modifiers)
        return void
    }
    decoder.partial[decoder.partial_count] = byte
    decoder.partial_count += 1
    if decoder.partial_count == decoder.partial_needed && decoder.partial_count <= decoder.partial.count {
        key(decoded, 0, modifiers, decoder.partial[0..<decoder.partial_count])
        decoder.partial_needed = 0
    }
}

/**
 * Decode a byte of a CSI sequence: a parameter's digit, a ';', a private marker, or the final byte, which ends it.
 *
 * Final bytes make the keys of CSI n ~ and of the arrows, Home, End and F1 to F4, with xterm's modifier parameter;
 * 200 ~ and 201 ~ start and end a bracketed paste. A sequence with a private marker is ignored, as is any key in a
 * paste.
 *
 * @param decoder The decoder, in a CSI sequence.
 * @param byte Any byte: '0' to '9' add a digit to the current parameter, ';' starts the next, '?', '<', '>' and '=' set
 *     the private marker, other bytes below 0x40 or past 0x7e are ignored, and 0x40 to 0x7e is the final byte, which
 *     returns the decoder to Ground.
 * @param decoded Where any event it makes is added.
 */
csi :: fn(decoder: ptr[mut Decoder], byte: u8, decoded: ptr[mut Decoded]) {
    if byte >= cast[u8]('0') && byte <= cast[u8]('9') {
        if decoder.parameter_count == 0 {
            decoder.parameter_count = 1
        }
        index :: decoder.parameter_count - 1
        if index < decoder.parameters.count && decoder.parameters[index] < 100000 {
            decoder.parameters[index] = decoder.parameters[index] * 10 + cast[u32](byte - cast[u8]('0'))
        }
        return void
    }
    if byte == cast[u8](';') {
        decoder.parameter_count = if decoder.parameter_count == 0 { cast[usize](2) } else { decoder.parameter_count + 1 }
        return void
    }
    if byte == cast[u8]('?') || byte == cast[u8]('<') || byte == cast[u8]('>') || byte == cast[u8]('=') {
        decoder.private = byte
        return void
    }
    if byte < 0x40 || byte > 0x7e {
        // Intermediate bytes: nothing this decoder reads uses them
        return void
    }
    decoder.state = .Ground
    first :: decoder.parameters[0]
    modifiers :: modifiers_of(if decoder.parameter_count >= 2 { decoder.parameters[1] } else { cast[u32](1) })
    if decoder.private != 0 {
        return void
    }
    if byte == cast[u8]('~') {
        if first == 200 {
            decoder.pasting = true
            decoder.paste_start = decoded.text_count
            return void
        }
        if first == 201 {
            give_paste(decoder, decoded)
            decoder.pasting = false
            return void
        }
        code :: tilde_key(first)
        if code != 0 && !decoder.pasting {
            key(decoded, code, modifiers, NO_TEXT[0..<0])
        }
        return void
    }
    if decoder.pasting {
        return void
    }
    code :: ss3_key(byte)
    if code != 0 {
        key(decoded, code, modifiers, NO_TEXT[0..<0])
    }
}

/**
 * Find the key of the byte after ESC O, or of a CSI's final byte for the same keys.
 *
 * @param byte The byte: A to D for the arrows, H and F for Home and End, P to S for F1 to F4.
 * @return The key's HID usage; 0 for any other byte.
 */
ss3_key :: fn(byte: u8) -> u16 {
    return if byte == cast[u8]('A') { USAGE_UP } else if byte == cast[u8]('B') { USAGE_DOWN }
        else if byte == cast[u8]('C') { USAGE_RIGHT } else if byte == cast[u8]('D') { USAGE_LEFT }
        else if byte == cast[u8]('H') { USAGE_HOME } else if byte == cast[u8]('F') { USAGE_END }
        else if byte >= cast[u8]('P') && byte <= cast[u8]('S') { USAGE_F1 + cast[u16](byte - cast[u8]('P')) }
        else { cast[u16](0) }
}

/**
 * Find the key of CSI n ~.
 *
 * @param number n: 1 or 7 Home, 2 Insert, 3 Delete, 4 or 8 End, 5 Page Up, 6 Page Down, 11 to 15 F1 to F5, 17 to 21
 *     F6 to F10, 23 and 24 F11 and F12.
 * @return The key's HID usage; 0 for any other number.
 */
tilde_key :: fn(number: u32) -> u16 {
    return if number == 1 || number == 7 { USAGE_HOME } else if number == 2 { USAGE_INSERT } else if number == 3 { USAGE_DELETE }
        else if number == 4 || number == 8 { USAGE_END } else if number == 5 { USAGE_PAGE_UP } else if number == 6 { USAGE_PAGE_DOWN }
        else if number >= 11 && number <= 15 { USAGE_F1 + cast[u16](number - 11) }
        else if number >= 17 && number <= 21 { USAGE_F5 + 1 + cast[u16](number - 17) }
        else if number >= 23 && number <= 24 { USAGE_F5 + 6 + cast[u16](number - 23) }
        else { cast[u16](0) }
}

/**
 * Find the modifiers xterm's modifier parameter gives.
 *
 * @param parameter The parameter: 1 plus Shift 1, Alt 2, Ctrl 4, Meta 8. 0 or 1 is none.
 * @return The modifiers, as terminal.SHIFT, ALT, CONTROL and META's bits.
 */
modifiers_of :: fn(parameter: u32) -> u8 {
    if parameter < 2 {
        return 0
    }
    bits :: parameter - 1
    modifiers := cast[u8](0)
    if bits & 1 != 0 {
        modifiers |= terminal.SHIFT
    }
    if bits & 2 != 0 {
        modifiers |= terminal.ALT
    }
    if bits & 4 != 0 {
        modifiers |= terminal.CONTROL
    }
    if bits & 8 != 0 {
        modifiers |= terminal.META
    }
    return modifiers
}

/**
 * Find an ASCII character's key: letters, of either case, digits and space.
 *
 * @param byte Any byte: a letter of either case, a digit or a space has a usage; anything else, past 0x7f included,
 *     gives 0.
 * @return Its key's HID usage; 0 for the rest, known by their text.
 */
ascii_usage :: fn(byte: u8) -> u16 {
    if byte >= cast[u8]('a') && byte <= cast[u8]('z') {
        return USAGE_A + cast[u16](byte - cast[u8]('a'))
    }
    if byte >= cast[u8]('A') && byte <= cast[u8]('Z') {
        return USAGE_A + cast[u16](byte - cast[u8]('A'))
    }
    if byte >= cast[u8]('1') && byte <= cast[u8]('9') {
        return 0x1e + cast[u16](byte - cast[u8]('1'))
    }
    if byte == cast[u8]('0') {
        return 0x27
    }
    if byte == cast[u8](' ') {
        return 0x2c
    }
    return 0
}

/**
 * Add a Key event, typing text.
 *
 * @param decoded Where it's added, its text with it; the event is dropped if its text doesn't fit what's left of
 *     decoded's text, or there's no room for another event.
 * @param code The key's HID usage, or 0 for a key known only by its text.
 * @param modifiers Its modifiers, as terminal.SHIFT, ALT, CONTROL and META's bits.
 * @param text What it types, copied; empty for a key that types nothing.
 */
key :: fn(decoded: ptr[mut Decoded], code: u16, modifiers: u8, text: u8[]) {
    start :: decoded.text_count
    if text.count > decoded.text.count - start {
        return void
    }
    for byte in text {
        add_byte(decoded, byte)
    }
    event(decoded, terminal.Event.{kind = cast[u8](terminal.EventKind.Key), code = code, modifiers = modifiers, text_start = cast[u32](start), text_bytes = cast[u32](text.count)})
}

/**
 * Add an event, if there's room for one.
 *
 * @param decoded Where it's added; it's dropped past MAX_EVENTS.
 * @param made The event, whose text, if any, is already in decoded's.
 */
event :: fn(decoded: ptr[mut Decoded], made: terminal.Event) {
    if decoded.count < decoded.events.count {
        decoded.events[decoded.count] = made
        decoded.count += 1
    }
}

/**
 * Add a byte to the events' text, if there's room for it.
 *
 * @param decoded Where it's added; it's dropped past MAX_EVENT_TEXT.
 * @param byte The byte, copied to the end of decoded's text, which text_count counts.
 */
add_byte :: fn(decoded: ptr[mut Decoded], byte: u8) {
    if decoded.text_count < decoded.text.count {
        decoded.text[decoded.text_count] = byte
        decoded.text_count += 1
    }
}

/**
 * Add a pasted byte to the paste's text; a paste that fills the text is given so far, as a Paste event.
 *
 * @param decoder The decoder, pasting.
 * @param decoded Where the text, and the event when it's full, are added.
 * @param byte The byte. When the text is full, this byte isn't added, and nor is any after it until decoded is reset.
 */
add_text :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded], byte: u8) {
    if decoded.text_count >= decoded.text.count {
        give_paste(decoder, decoded)
        return void
    }
    add_byte(decoded, byte)
}

/**
 * Give the paste so far as a Paste event, if it has any text, and start the paste's next part after it.
 *
 * @param decoder The decoder, pasting.
 * @param decoded Where the event is added, its text already there from paste_start on.
 */
give_paste :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded]) {
    if decoded.text_count > decoder.paste_start {
        event(decoded, terminal.Event.{kind = cast[u8](terminal.EventKind.Paste), text_start = cast[u32](decoder.paste_start),
            text_bytes = cast[u32](decoded.text_count - decoder.paste_start)})
    }
    decoder.paste_start = decoded.text_count
}

/**
 * Empty decoded for the next bytes, once its events have been taken; a paste going on carries on from its start.
 *
 * @param decoder The decoder, which keeps its place in a sequence or code point.
 * @param decoded The events and text, emptied.
 */
reset :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded]) {
    decoded.count = 0
    decoded.text_count = 0
    decoder.paste_start = 0
}
