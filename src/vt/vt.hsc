/*
 * The VT adapter (decisions/0136, design/console-and-sessions.md §2): the terminal protocol turned into ECMA-48's bytes
 * for a byte-stream device, the serial line now and an SSH client's terminal in M14, and that device's bytes turned back
 * into typed input. It's the only place escape sequences exist: text reaches it already made safe (safe_text), so what
 * a program prints can't become a sequence. Output appends to a TextBuffer; input goes through a Decoder, which keeps
 * what a chunk of bytes cut short for the next.
 */
package vt

import text_buffer from "std"
import terminal from "std/os/slop_os"

ESCAPE : u8 : 0x1b
// Sliced empty, for keys that type nothing
NO_TEXT :: u8.[0]

// USB HID usages (page 7) of the keys a byte stream can send.
USAGE_A : u16 : 0x04
USAGE_ENTER : u16 : 0x28
USAGE_ESCAPE : u16 : 0x29
USAGE_BACKSPACE : u16 : 0x2a
USAGE_TAB : u16 : 0x2b
USAGE_F1 : u16 : 0x3a
USAGE_F5 : u16 : 0x3e
USAGE_INSERT : u16 : 0x49
USAGE_HOME : u16 : 0x4a
USAGE_PAGE_UP : u16 : 0x4b
USAGE_DELETE : u16 : 0x4c
USAGE_END : u16 : 0x4d
USAGE_PAGE_DOWN : u16 : 0x4e
USAGE_RIGHT : u16 : 0x4f
USAGE_LEFT : u16 : 0x50
USAGE_DOWN : u16 : 0x51
USAGE_UP : u16 : 0x52

// Output.

// CSI: ESC [
append_csi :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('['))
}

// SGR for style, from the default: reset, then each attribute and colour style has.
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

// A colour's SGR parameters after a ';', base 30 for the foreground and 40 for the background; nothing for the default.
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

// CUP: the cursor to row and column, from 0.
append_move :: fn(out: ptr[mut text_buffer.TextBuffer], row: u16, column: u16) {
    append_csi(out)
    text_buffer.append_unsigned(out, cast[u64](row) + 1)
    text_buffer.append_byte(out, cast[u8](';'))
    text_buffer.append_unsigned(out, cast[u64](column) + 1)
    text_buffer.append_byte(out, cast[u8]('H'))
}

// CHA: the cursor to column, from 0, on its line.
append_column :: fn(out: ptr[mut text_buffer.TextBuffer], column: u16) {
    append_csi(out)
    text_buffer.append_unsigned(out, cast[u64](column) + 1)
    text_buffer.append_byte(out, cast[u8]('G'))
}

// EL: the rest of the cursor's line cleared.
append_clear_to_end :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    append_csi(out)
    text_buffer.append_byte(out, cast[u8]('K'))
}

// ED and CUP: the whole screen cleared, the cursor at its top left.
append_clear_screen :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    append_csi(out)
    text_buffer.append(out, "2J")
    append_move(out, 0, 0)
}

// DECSTBM: the rows that scroll, first to last, from 0. It puts the cursor at the top left.
append_margins :: fn(out: ptr[mut text_buffer.TextBuffer], first: u16, last: u16) {
    append_csi(out)
    text_buffer.append_unsigned(out, cast[u64](first) + 1)
    text_buffer.append_byte(out, cast[u8](';'))
    text_buffer.append_unsigned(out, cast[u64](last) + 1)
    text_buffer.append_byte(out, cast[u8]('r'))
}

// Rows first to last, from 0, moved up by lines, or down when negative: their margins set, then SU or SD. The margins
// stay as set, for the caller to put back.
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

// DECSC and DECRC: the cursor, and its style, saved and put back.
append_save_cursor :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('7'))
}

append_restore_cursor :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, ESCAPE)
    text_buffer.append_byte(out, cast[u8]('8'))
}

// DECTCEM: the cursor shown or hidden.
append_cursor_shown :: fn(out: ptr[mut text_buffer.TextBuffer], shown: bool) {
    append_csi(out)
    text_buffer.append(out, if shown { "?25h" } else { "?25l" })
}

// The alternate screen, a program's own, entered and cleared, or left for the lines as they were.
append_alternate_screen :: fn(out: ptr[mut text_buffer.TextBuffer], entered: bool) {
    append_csi(out)
    text_buffer.append(out, if entered { "?1049h" } else { "?1049l" })
    if entered {
        append_clear_screen(out)
    }
}

/*
 * OSC 8: what follows links to target, or, with an empty target, stops linking. Only the target's printable ASCII is
 * kept, so it can't end the sequence early.
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

// BEL.
append_bell :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, 0x07)
}

// A line break: CR LF.
append_line_break :: fn(out: ptr[mut text_buffer.TextBuffer]) {
    text_buffer.append_byte(out, 0x0d)
    text_buffer.append_byte(out, 0x0a)
}

// Input.

DecoderState :: enum #backed_by(u8) {
    Ground = 0,
    // After ESC
    Escape = 1,
    // After ESC [, gathering parameters
    Csi = 2,
    // After ESC O
    Ss3 = 3,
}

MAX_PARAMETERS :: 4

/*
 * Turns a byte stream's input into events: keys (with their text, modifiers and HID usage where there's one), pastes
 * between bracketed paste's markers, and Ctrl-C as an Interrupt.
 */
Decoder :: struct {
    state : DecoderState,
    parameters : u32[MAX_PARAMETERS],
    parameter_count : usize,
    // A private marker after CSI, like '?' or '<'
    private : u8,
    pasting : bool,
    // The paste's text so far, in decoded's text, from paste_start
    paste_start : usize,
    // A CR was the last byte, so an LF right after it is the same line break
    after_return : bool,
    // A code point's bytes so far, and how many it has
    partial : u8[4],
    partial_count : usize,
    partial_needed : usize,
}

// What a Decoder made of some bytes: events, and the text they hold ranges of.
Decoded :: struct {
    events : terminal.Event[terminal.MAX_EVENTS],
    count : usize,
    text : u8[terminal.MAX_EVENT_TEXT],
    text_count : usize,
}

// bytes, decoded into decoded; what doesn't fit, or a sequence cut short, waits in decoder.
feed :: fn(decoder: ptr[mut Decoder], bytes: u8[], decoded: ptr[mut Decoded]) {
    for byte in bytes {
        feed_byte(decoder, byte, decoded)
    }
}

/*
 * The end of what's arrived for now: an ESC that nothing followed is the Escape key, since a sequence arrives whole, and
 * a paste still open is given as far as it's come.
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

ground :: fn(decoder: ptr[mut Decoder], byte: u8, decoded: ptr[mut Decoded]) {
    ground_with(decoder, byte, decoded, 0)
}

// A byte outside a sequence, with modifiers already known (Alt, after an ESC).
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

// The key after ESC O, or a CSI's final byte for the same keys: the arrows, Home, End and F1 to F4.
ss3_key :: fn(byte: u8) -> u16 {
    return if byte == cast[u8]('A') { USAGE_UP } else if byte == cast[u8]('B') { USAGE_DOWN }
        else if byte == cast[u8]('C') { USAGE_RIGHT } else if byte == cast[u8]('D') { USAGE_LEFT }
        else if byte == cast[u8]('H') { USAGE_HOME } else if byte == cast[u8]('F') { USAGE_END }
        else if byte >= cast[u8]('P') && byte <= cast[u8]('S') { USAGE_F1 + cast[u16](byte - cast[u8]('P')) }
        else { cast[u16](0) }
}

// The key of CSI n ~.
tilde_key :: fn(number: u32) -> u16 {
    return if number == 1 || number == 7 { USAGE_HOME } else if number == 2 { USAGE_INSERT } else if number == 3 { USAGE_DELETE }
        else if number == 4 || number == 8 { USAGE_END } else if number == 5 { USAGE_PAGE_UP } else if number == 6 { USAGE_PAGE_DOWN }
        else if number >= 11 && number <= 15 { USAGE_F1 + cast[u16](number - 11) }
        else if number >= 17 && number <= 21 { USAGE_F5 + 1 + cast[u16](number - 17) }
        else if number >= 23 && number <= 24 { USAGE_F5 + 6 + cast[u16](number - 23) }
        else { cast[u16](0) }
}

// xterm's modifier parameter: 1 plus Shift 1, Alt 2, Ctrl 4, Meta 8.
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

// An ASCII character's key: letters, digits and space; 0 for the rest, known by their text.
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

// A Key event typing text.
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

event :: fn(decoded: ptr[mut Decoded], made: terminal.Event) {
    if decoded.count < decoded.events.count {
        decoded.events[decoded.count] = made
        decoded.count += 1
    }
}

add_byte :: fn(decoded: ptr[mut Decoded], byte: u8) {
    if decoded.text_count < decoded.text.count {
        decoded.text[decoded.text_count] = byte
        decoded.text_count += 1
    }
}

// A pasted byte; a paste that fills the text is given so far, and goes on in another.
add_text :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded], byte: u8) {
    if decoded.text_count >= decoded.text.count {
        give_paste(decoder, decoded)
        return void
    }
    add_byte(decoded, byte)
}

// The paste so far, as an event.
give_paste :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded]) {
    if decoded.text_count > decoder.paste_start {
        event(decoded, terminal.Event.{kind = cast[u8](terminal.EventKind.Paste), text_start = cast[u32](decoder.paste_start),
            text_bytes = cast[u32](decoded.text_count - decoder.paste_start)})
    }
    decoder.paste_start = decoded.text_count
}

// decoded emptied, for the next bytes; a paste going on carries on from its start.
reset :: fn(decoder: ptr[mut Decoder], decoded: ptr[mut Decoded]) {
    decoded.count = 0
    decoded.text_count = 0
    decoder.paste_start = 0
}
