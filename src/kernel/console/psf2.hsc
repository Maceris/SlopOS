/*
 * The kernel's framebuffer console: text drawn with a PSF2 font on a linear RGB framebuffer
 * (roadmap M1). It needs no allocator.
 */
package console

//SPEC: PSF2 font format, as documented with the Linux kbd package (psffontformat, "PSF2")

PSF2_MAGIC :: u8.[0x72, 0xb5, 0x4a, 0x86]
PSF2_HEADER_SIZE :: 32
// The font has a table mapping Unicode code points to its glyphs.
PSF2_HAS_UNICODE_TABLE : u32 : 1
// In the Unicode table: starts a sequence of code points drawn as one glyph, and ends a glyph's entry.
PSF2_SEQUENCE_START : u8 : 0xfe
PSF2_GLYPH_END : u8 : 0xff
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
}

NO_GLYPH : u16 : 0xffff

read_u32 :: fn(bytes: u8[], offset: usize) -> u32 {
    return cast[u32](bytes[offset])
        | (cast[u32](bytes[offset + 1]) << 8)
        | (cast[u32](bytes[offset + 2]) << 16)
        | (cast[u32](bytes[offset + 3]) << 24)
}

/*
 * Fill font from a PSF2 file's bytes, which it keeps referring to.
 *
 * Fonts are filled in place rather than returned, since copying a Font's quick table around makes
 * the compiler's output much larger.
 */
//HEMERA(friction): LLVM copes badly with large values copied whole (generated as first-class
//aggregates); a Result[Font, FontError] took minutes to optimize
parse_font :: fn(font: ptr[mut Font], bytes: u8[]) -> FontError? {
    if bytes.count < PSF2_HEADER_SIZE {
        return FontError.Truncated
    }
    for byte, i in PSF2_MAGIC {
        if bytes[i] != byte {
            return FontError.BadMagic
        }
    }
    if read_u32(bytes, 4) != 0 {
        return FontError.UnsupportedVersion
    }
    header_size :: cast[usize](read_u32(bytes, 8))
    flags :: read_u32(bytes, 12)
    font.glyph_count = read_u32(bytes, 16)
    font.bytes_per_glyph = read_u32(bytes, 20)
    font.height = read_u32(bytes, 24)
    font.width = read_u32(bytes, 28)
    font.bytes_per_row = (font.width + 7) / 8
    if font.glyph_count == 0 || font.width == 0 || font.bytes_per_glyph != font.bytes_per_row * font.height {
        return FontError.BadGlyphSize
    }
    glyphs_end :: header_size + cast[usize](font.glyph_count) * cast[usize](font.bytes_per_glyph)
    if header_size < PSF2_HEADER_SIZE || glyphs_end > bytes.count {
        return FontError.Truncated
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
    return null
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
        // Single code points come first in a glyph's entry; sequences after 0xfe are skipped
        in_sequence := false
        loop {
            byte :: font.unicode_table[at]
            if byte == PSF2_SEQUENCE_START {
                in_sequence = true
                at += 1
                continue
            }
            code_point, length :: decode_utf8(font.unicode_table, at)
            if !in_sequence && code_point < QUICK_CODE_POINTS && font.quick[code_point] == NO_GLYPH {
                font.quick[code_point] = cast[u16](glyph)
            }
            at += length
        }
        while at < font.unicode_table.count && font.unicode_table[at] != PSF2_GLYPH_END
        at += 1
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
        byte :: font.unicode_table[at]
        if byte == PSF2_GLYPH_END {
            glyph += 1
            in_sequence = false
            at += 1
            continue
        }
        if byte == PSF2_SEQUENCE_START {
            in_sequence = true
            at += 1
            continue
        }
        found, length :: decode_utf8(font.unicode_table, at)
        if !in_sequence && found == code_point {
            return cast[u16](glyph)
        }
        at += length
    }
    while at < font.unicode_table.count && glyph < font.glyph_count
    return NO_GLYPH
}

// The rows of a glyph.
glyph_rows :: fn(font: ptr[Font], glyph: u16) -> u8[] {
    start :: cast[usize](glyph) * cast[usize](font.bytes_per_glyph)
    return font.glyphs[start..<start + cast[usize](font.bytes_per_glyph)]
}

/*
 * The code point encoded in UTF-8 at bytes[at], and how many bytes it takes. A malformed or cut-off
 * sequence decodes as U+FFFD, one byte long, so decoding always moves on.
 */
//SPEC: RFC 3629 (UTF-8), section 3
decode_utf8 :: fn(bytes: u8[], at: usize) -> (u32, usize) {
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
        next :: cast[u32](bytes[at + i])
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
