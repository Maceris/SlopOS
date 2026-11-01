/*
 * PSF fonts (roadmap M1, decisions/0138): glyphs found by code point, for the kernel's framebuffer console and the
 * terminal service's. PSF2, and PSF1, whose glyphs are 8 pixels wide and whose Unicode table holds 16-bit code points
 * rather than UTF-8. It needs no allocator.
 */
package psf2

import runtime from "base"

//SPEC: PSF1 and PSF2 font formats, as documented with the Linux kbd package (psffontformat)

PSF2_MAGIC :: u8.[0x72, 0xb5, 0x4a, 0x86]
PSF2_HEADER_SIZE :: 32
// The font has a table mapping Unicode code points to its glyphs.
PSF2_HAS_UNICODE_TABLE : u32 : 1
// In the Unicode table: starts a sequence of code points drawn as one glyph, and ends a glyph's entry.
PSF2_SEQUENCE_START : u8 : 0xfe
PSF2_GLYPH_END : u8 : 0xff
PSF1_MAGIC :: u8.[0x36, 0x04]
PSF1_HEADER_SIZE :: 4
// PSF1's mode bits: 512 glyphs rather than 256, and a Unicode table (either of two bits says so)
PSF1_MODE_512 : u8 : 1
PSF1_MODE_HAS_TABLE : u8 : 6
// In PSF1's Unicode table, 16-bit entries: a sequence's start and a glyph's end
PSF1_SEQUENCE_START : u32 : 0xfffe
PSF1_GLYPH_END : u32 : 0xffff
// How many code points are looked up in a table built once, instead of searching the Unicode table.
QUICK_CODE_POINTS :: 256

FontError :: enum {
    // Shorter than its header says it is.
    Truncated,
    BadMagic,
    UnsupportedVersion,
    // A glyph's size doesn't match its width and height, or it has no glyphs.
    BadGlyphSize,
}

Font :: struct {
    // Every glyph's rows, top first, each row padded to whole bytes, the leftmost pixel in the highest bit.
    glyphs : u8[],
    glyph_count : u32,
    bytes_per_glyph : u32,
    bytes_per_row : u32,
    width : u32,
    height : u32,
    // The Unicode table, empty when the font has none: then glyph i is code point i.
    unicode_table : u8[],
    // Glyph indexes of the first QUICK_CODE_POINTS code points; NO_GLYPH where the font has none.
    quick : u16[QUICK_CODE_POINTS],
    // What's drawn for a code point the font doesn't have.
    replacement : u16,
    // A PSF1 font, whose Unicode table's entries are 16 bits
    psf1 : bool,
}

// What's next in a Unicode table: a code point, a sequence's start, or a glyph's end.
TableEntry :: enum {
    Point,
    SequenceStart,
    GlyphEnd,
}

NO_GLYPH : u16 : 0xffff

read_u32 :: fn(bytes: u8[], offset: usize) -> u32 {
    runtime.assert(offset < bytes.count && offset + 4 <= bytes.count, "read_u32 reads four bytes that are there")
    return cast[u32](bytes[offset])
        | (cast[u32](bytes[offset + 1]) << 8)
        | (cast[u32](bytes[offset + 2]) << 16)
        | (cast[u32](bytes[offset + 3]) << 24)
}

// A font from a PSF1 or PSF2 file's bytes, which it keeps referring to.
parse_font :: fn(bytes #escaping : u8[]) -> Result[Font, FontError] {
    if bytes.count >= PSF1_HEADER_SIZE && bytes[0] == PSF1_MAGIC[0] && bytes[1] == PSF1_MAGIC[1] {
        return parse_psf1(bytes)
    }
    if bytes.count < PSF2_HEADER_SIZE {
        return .Error(.Truncated)
    }
    for byte, i in PSF2_MAGIC {
        if bytes[i] != byte {
            return .Error(.BadMagic)
        }
    }
    if read_u32(bytes, 4) != 0 {
        return .Error(.UnsupportedVersion)
    }
    parsed : Font
    font :: &parsed
    header_size :: cast[usize](read_u32(bytes, 8))
    flags :: read_u32(bytes, 12)
    font.glyph_count = read_u32(bytes, 16)
    font.bytes_per_glyph = read_u32(bytes, 20)
    font.height = read_u32(bytes, 24)
    font.width = read_u32(bytes, 28)
    font.bytes_per_row = (font.width + 7) / 8
    if font.glyph_count == 0 || font.width == 0 || font.bytes_per_glyph != font.bytes_per_row * font.height {
        return .Error(.BadGlyphSize)
    }
    glyphs_end :: header_size + cast[usize](font.glyph_count) * cast[usize](font.bytes_per_glyph)
    // The sum can't wrap for 32-bit counts, but saying so keeps the slice below proven
    if header_size < PSF2_HEADER_SIZE || glyphs_end < header_size || glyphs_end > bytes.count {
        return .Error(.Truncated)
    }
    font.glyphs = bytes[header_size..<glyphs_end]
    font.unicode_table = bytes[glyphs_end..<glyphs_end]
    if (flags & PSF2_HAS_UNICODE_TABLE) != 0 {
        font.unicode_table = bytes[glyphs_end..<bytes.count]
    }
    fill_quick_table(font)
    font.replacement = glyph_index(font, cast[u32]('?'))
    if font.replacement == NO_GLYPH {
        font.replacement = 0
    }
    return .Ok(parsed)
}

// A PSF1 font: 256 or 512 glyphs 8 pixels wide and as tall as its header says, and maybe a Unicode table after them.
parse_psf1 :: fn(bytes #escaping : u8[]) -> Result[Font, FontError] {
    if bytes.count < PSF1_HEADER_SIZE {
        return .Error(.Truncated)
    }
    parsed : Font
    font :: &parsed
    mode :: bytes[2]
    font.psf1 = true
    font.glyph_count = if mode & PSF1_MODE_512 != 0 { cast[u32](512) } else { cast[u32](256) }
    font.width = 8
    font.height = cast[u32](bytes[3])
    font.bytes_per_row = 1
    font.bytes_per_glyph = font.height
    if font.height == 0 {
        return .Error(.BadGlyphSize)
    }
    glyphs_end :: PSF1_HEADER_SIZE + cast[usize](font.glyph_count) * cast[usize](font.bytes_per_glyph)
    if glyphs_end < PSF1_HEADER_SIZE || glyphs_end > bytes.count {
        return .Error(.Truncated)
    }
    font.glyphs = bytes[PSF1_HEADER_SIZE..<glyphs_end]
    font.unicode_table = bytes[glyphs_end..<glyphs_end]
    if mode & PSF1_MODE_HAS_TABLE != 0 {
        font.unicode_table = bytes[glyphs_end..<bytes.count]
    }
    fill_quick_table(font)
    font.replacement = glyph_index(font, cast[u32]('?'))
    if font.replacement == NO_GLYPH {
        font.replacement = 0
    }
    return .Ok(parsed)
}

// The Unicode table's next entry at at: what it is, its code point if it's one, and how many bytes it takes.
table_entry :: fn(font: ptr[Font], at: usize) -> (TableEntry, u32, usize) {
    table :: font.unicode_table
    if font.psf1 {
        next :: at + 1
        if at >= table.count || next >= table.count {
            return .GlyphEnd, 0, 2
        }
        value :: cast[u32](table[at]) | (cast[u32](table[next]) << 8)
        if value == PSF1_GLYPH_END {
            return .GlyphEnd, 0, 2
        }
        if value == PSF1_SEQUENCE_START {
            return .SequenceStart, 0, 2
        }
        return .Point, value, 2
    }
    if at >= table.count || table[at] == PSF2_GLYPH_END {
        return .GlyphEnd, 0, 1
    }
    if table[at] == PSF2_SEQUENCE_START {
        return .SequenceStart, 0, 1
    }
    code_point, length :: decode_utf8(table, at)
    return .Point, code_point, length
}

// The quick table, from the Unicode table, or glyph i for code point i without one.
fill_quick_table :: fn(font: ptr[mut Font]) {
    for &entry, code_point in font.quick {
        entry^ = NO_GLYPH
        if font.unicode_table.count == 0 && code_point < cast[usize](font.glyph_count) {
            entry^ = cast[u16](code_point)
        }
    }
    if font.unicode_table.count == 0 {
        return void
    }
    with {
        glyph : u32 = 0
        at : usize = 0
    }
    loop {
        // Single code points come first in a glyph's entry; sequences after their start are skipped
        in_sequence := false
        loop {
            kind, code_point, length :: table_entry(font, at)
            at += length
            if kind == .GlyphEnd {
                break
            }
            if kind == .SequenceStart {
                in_sequence = true
                continue
            }
            if !in_sequence && code_point < QUICK_CODE_POINTS && font.quick[code_point] == NO_GLYPH {
                font.quick[code_point] = cast[u16](glyph)
            }
        }
        glyph += 1
    }
    while at < font.unicode_table.count && glyph < font.glyph_count
}

/*
 * The glyph for a code point: from the quick table, or by searching the Unicode table.
 * NO_GLYPH if the font doesn't have it.
 */
glyph_index :: fn(font: ptr[Font], code_point: u32) -> u16 {
    if code_point < QUICK_CODE_POINTS {
        return font.quick[code_point]
    }
    if font.unicode_table.count == 0 {
        return if code_point < font.glyph_count { cast[u16](code_point) } else { NO_GLYPH }
    }
    with {
        glyph : u32 = 0
        at : usize = 0
        in_sequence := false
    }
    loop {
        kind, found, length :: table_entry(font, at)
        at += length
        if kind == .GlyphEnd {
            glyph += 1
            in_sequence = false
            continue
        }
        if kind == .SequenceStart {
            in_sequence = true
            continue
        }
        if !in_sequence && found == code_point {
            return cast[u16](glyph)
        }
    }
    while at < font.unicode_table.count && glyph < font.glyph_count
    return NO_GLYPH
}

// The rows of a glyph.
glyph_rows :: fn(font: ptr[Font], glyph: u16) -> u8[] {
    glyphs :: font.glyphs
    size :: cast[usize](font.bytes_per_glyph)
    start :: cast[usize](glyph) * size
    // A glyph parse_font counted is inside glyphs; any other has no rows
    if start >= glyphs.count {
        return glyphs[0..<0]
    }
    end :: start + size
    if end > glyphs.count {
        return glyphs[0..<0]
    }
    return glyphs[start..<end]
}

/*
 * The code point encoded in UTF-8 at bytes[at], and how many bytes it takes. A malformed or cut-off
 * sequence decodes as U+FFFD, one byte long, so decoding always moves on.
 */
//SPEC: RFC 3629 (UTF-8), section 3
decode_utf8 :: fn(bytes: u8[], at: usize) -> (u32, usize) {
    if at >= bytes.count {
        return REPLACEMENT_CHARACTER, 1
    }
    first :: cast[u32](bytes[at])
    if first < 0x80 {
        return first, 1
    }
    length : usize = 0
    code_point : u32 = 0
    minimum : u32 = 0
    if (first & 0xe0) == 0xc0 {
        length = 2
        code_point = first & 0x1f
        minimum = 0x80
    }
    else if (first & 0xf0) == 0xe0 {
        length = 3
        code_point = first & 0x0f
        minimum = 0x800
    }
    else if (first & 0xf8) == 0xf0 {
        length = 4
        code_point = first & 0x07
        minimum = 0x10000
    }
    else {
        return REPLACEMENT_CHARACTER, 1
    }
    if at + length > bytes.count {
        return REPLACEMENT_CHARACTER, 1
    }
    for i in 1..<length {
        index :: at + i
        if index >= bytes.count {
            return REPLACEMENT_CHARACTER, 1
        }
        next :: cast[u32](bytes[index])
        if (next & 0xc0) != 0x80 {
            return REPLACEMENT_CHARACTER, 1
        }
        code_point = (code_point << 6) | (next & 0x3f)
    }
    // Overlong encodings, surrogates and values past U+10FFFF aren't valid UTF-8
    if code_point < minimum || code_point > 0x10ffff || (code_point >= 0xd800 && code_point <= 0xdfff) {
        return REPLACEMENT_CHARACTER, 1
    }
    return code_point, length
}

REPLACEMENT_CHARACTER : u32 : 0xfffd
