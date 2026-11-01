/*
 * Text as a terminal shows it (decisions/0136, design/console-and-sessions.md §2): a grapheme cluster at a time, with
 * whatever wouldn't show, or would change how the text around it shows, replaced by a visible substitute. C0 controls
 * become their Control Pictures (U+2400 on), DEL U+2421; bytes that aren't UTF-8 become U+FFFD; C1 controls,
 * bidirectional controls and the other default ignorables become their code point written out, as ⟨U+202E⟩. Two
 * default ignorables are kept where they're how a cluster shows: a variation selector after what it varies, and a ZWJ
 * inside an emoji ZWJ sequence. Line breaks and tabs are the caller's (is_line_break, is_tab).
 */
package safe_text

import unicode from "std"

// The most bytes one cluster may have: longer ones (a base and dozens of marks) show as U+FFFD.
MAX_CLUSTER_BYTES :: 32

// A cluster made safe: the bytes to show, and the columns they take.
Shown :: struct {
    bytes : u8[MAX_CLUSTER_BYTES + 16],
    count : usize,
    columns : usize,
}

// Whether the cluster at at is a line break: LF, CR LF, or a lone CR.
is_line_break :: fn(text: u8[], at: usize, end: usize) -> bool {
    return at < text.count && (text[at] == 0x0a || text[at] == 0x0d) && end - at <= 2
}

is_tab :: fn(text: u8[], at: usize, end: usize) -> bool {
    return at < text.count && text[at] == 0x09 && end == at + 1
}

/*
 * The cluster text[at..<end] made safe to show, into shown. Each code point that wouldn't show becomes its substitute,
 * and the columns are counted from what's shown.
 */
show :: fn(text: u8[], at: usize, end: usize, shown: ptr[mut Shown]) {
    shown.count = 0
    shown.columns = 0
    if end <= at || end > text.count {
        return void
    }
    if end - at > MAX_CLUSTER_BYTES {
        append_point(shown, unicode.REPLACEMENT)
        shown.columns = 1
        return void
    }
    first, first_length :: unicode.decode(text, at)
    pictographic :: first_length != 0 && unicode.is_extended_pictographic(first)
    kept_any := false
    position := at
    loop {
        point, length :: unicode.decode(text, position)
        if length == 0 {
            append_point(shown, unicode.REPLACEMENT)
            position += 1
            continue
        }
        next :: position + length
        if unicode.is_control(point) {
            append_point(shown, if point < 0x20 { 0x2400 + point } else if point == 0x7f { cast[u32](0x2421) } else { cast[u32](0) })
            if point >= 0x80 {
                append_written_out(shown, point)
            }
        }
        else if unicode.is_default_ignorable(point) && !(kept_any && kept_in_cluster(point, pictographic, next < end)) {
            append_written_out(shown, point)
        }
        else {
            if position < next && next <= text.count {
                for byte in text[position..<next] {
                    append_byte(shown, byte)
                }
            }
            if !unicode.is_default_ignorable(point) {
                kept_any = true
            }
        }
        position = next
    }
    while position < end
    // The columns of what's shown, a cluster at a time, since substitutes are clusters of their own
    if shown.count <= shown.bytes.count {
        shown.columns = unicode.text_width(shown.bytes[0..<shown.count])
    }
}

// Whether a default ignorable, after something shown in its cluster, is part of how the cluster shows.
kept_in_cluster :: fn(point: u32, pictographic: bool, more_after: bool) -> bool {
    // Variation selectors, standard and supplementary
    if (point >= 0xfe00 && point <= 0xfe0f) || (point >= 0xe0100 && point <= 0xe01ef) {
        return true
    }
    // A ZWJ between pictographs
    return point == 0x200d && pictographic && more_after
}

append_byte :: fn(shown: ptr[mut Shown], byte: u8) {
    if shown.count < shown.bytes.count {
        shown.bytes[shown.count] = byte
        shown.count += 1
    }
}

append_point :: fn(shown: ptr[mut Shown], point: u32) {
    if point == 0 {
        return void
    }
    encoded : u8[4]
    length :: unicode.encode(point, encoded)
    if length <= encoded.count {
        for byte in encoded[0..<length] {
            append_byte(shown, byte)
        }
    }
}

HEX_DIGITS :: "0123456789ABCDEF"

// ⟨U+XXXX⟩, with at least four uppercase digits
append_written_out :: fn(shown: ptr[mut Shown], point: u32) {
    append_point(shown, 0x27e8)
    append_byte(shown, cast[u8]('U'))
    append_byte(shown, cast[u8]('+'))
    digits : usize = if point > 0xfffff { cast[usize](6) } else if point > 0xffff { cast[usize](5) } else { cast[usize](4) }
    for i in 0..<digits {
        shift :: cast[u32](4 * (digits - 1 - i))
        digit :: cast[usize]((point >> shift) & 0xf)
        if digit < HEX_DIGITS.count {
            append_byte(shown, cast[u8](HEX_DIGITS[digit]))
        }
    }
    append_point(shown, 0x27e9)
}
