/**
 * PSF fonts (roadmap M1, decisions/0138): glyphs found by code point, for the kernel's framebuffer console and the
 * terminal service's. PSF2, and PSF1, whose glyphs are 8 pixels wide and whose Unicode table holds 16-bit code points
 * rather than UTF-8. It needs no allocator.
 */
package psf2

import runtime from "base"

//SPEC: PSF1 and PSF2 font formats, as documented with the Linux kbd package (psffontformat)

/** The first four bytes of a PSF2 file. */
PSF2_MAGIC :: u8.[0x72, 0xb5, 0x4a, 0x86]
/** The bytes of a PSF2 header as this reads it; a file's own header size can be larger, never smaller. */
PSF2_HEADER_SIZE :: 32
/** A PSF2 header's flag: the font has a table mapping Unicode code points to its glyphs. */
PSF2_HAS_UNICODE_TABLE : u32 : 1
/** In PSF2's Unicode table: the byte that starts a sequence of code points drawn as one glyph. */
PSF2_SEQUENCE_START : u8 : 0xfe
/** In PSF2's Unicode table: the byte that ends a glyph's entry. */
PSF2_GLYPH_END : u8 : 0xff
/** The first two bytes of a PSF1 file. */
PSF1_MAGIC :: u8.[0x36, 0x04]
/** The bytes of a PSF1 header: its magic, its mode and its glyphs' height. */
PSF1_HEADER_SIZE :: 4
/** PSF1's mode bit for 512 glyphs rather than 256. */
PSF1_MODE_512 : u8 : 1
/** PSF1's mode bits for a Unicode table after the glyphs: either of the two says so. */
PSF1_MODE_HAS_TABLE : u8 : 6
/** In PSF1's Unicode table, whose entries are 16 bits: the entry that starts a sequence. */
PSF1_SEQUENCE_START : u32 : 0xfffe
/** In PSF1's Unicode table: the entry that ends a glyph's entry. */
PSF1_GLYPH_END : u32 : 0xffff
/** How many code points are looked up in a table built once, instead of searching the Unicode table. */
QUICK_CODE_POINTS :: 256

/** Why a font's bytes couldn't be read as a font. */
FontError :: enum {
    /** Shorter than its header says it is, or than a header. */
    Truncated,
    /** Neither a PSF1 nor a PSF2 file: its first bytes are neither's magic. */
    BadMagic,
    /** A PSF2 file of a version other than 0, the only one there is. */
    UnsupportedVersion,
    /** A glyph's size doesn't match its width and height, or it has no glyphs, or no width or height. */
    BadGlyphSize,
}

/**
 * A PSF1 or PSF2 font, parsed: views of its file's bytes, and a table of its first code points' glyphs.
 *
 * Its views refer to the bytes it was parsed from, which have to outlive it.
 */
Font :: struct {
    /** Every glyph's rows, top first, each row padded to whole bytes, the leftmost pixel in the highest bit. */
    glyphs : u8[],
    /** How many glyphs the font has: at least 1; 256 or 512 for PSF1. */
    glyph_count : u32,
    /** The bytes of one glyph: bytes_per_row times height. */
    bytes_per_glyph : u32,
    /** The bytes of one glyph's row: its width in pixels, rounded up to whole bytes. */
    bytes_per_row : u32,
    /** A glyph's width in pixels, at least 1; 8 for PSF1. */
    width : u32,
    /** A glyph's height in pixels, at least 1. */
    height : u32,
    /** The Unicode table, empty when the font has none: then glyph i is code point i. */
    unicode_table : u8[],
    /** Glyph indexes of the first QUICK_CODE_POINTS code points; NO_GLYPH where the font has none. */
    quick : u16[QUICK_CODE_POINTS],
    /** What's drawn for a code point the font doesn't have: its glyph for '?', or glyph 0 without one. */
    replacement : u16,
    /** Whether it's a PSF1 font, whose Unicode table's entries are 16 bits, not UTF-8. */
    psf1 : bool,
}

/** What's next in a Unicode table: a code point, a sequence's start, or a glyph's end. */
TableEntry :: enum {
    /** A code point the glyph is drawn for, on its own or, after SequenceStart, as part of a sequence. */
    Point,
    /** The start of a sequence of code points drawn together as the glyph; single code points come before any. */
    SequenceStart,
    /** The end of the glyph's entry, or of the table; the next entry is the next glyph's. */
    GlyphEnd,
}

/** No glyph: what glyph_index gives for a code point the font doesn't have. */
NO_GLYPH : u16 : 0xffff

/**
 * Read a little-endian u32 from bytes.
 *
 * @param bytes The bytes read from.
 * @param offset Where the u32 starts, in bytes; all four have to be in bytes, or this asserts.
 * @return The four bytes at offset as one value, the first byte its lowest.
 */
read_u32 :: fn(bytes: u8[], offset: usize) -> u32 {
    runtime.assert(offset < bytes.count && offset + 4 <= bytes.count, "read_u32 reads four bytes that are there")
    return cast[u32](bytes[offset])
        | (cast[u32](bytes[offset + 1]) << 8)
        | (cast[u32](bytes[offset + 2]) << 16)
        | (cast[u32](bytes[offset + 3]) << 24)
}

/**
 * Parse a font from a PSF1 or PSF2 file's bytes.
 *
 * It needs no allocator: the font refers to bytes, whose glyphs and Unicode table it views, and builds its quick table
 * in itself.
 *
 * @param bytes The file's bytes, which the font keeps referring to, so they have to outlive it, like a #file_data.
 * @return The font, PSF1 or PSF2 as the bytes' magic says: views of the bytes' glyphs and Unicode table (empty without
 *     one), its quick table filled, and its replacement the glyph for '?', or glyph 0 without one.
 * @error Truncated The bytes end before the header or the glyphs it counts, or a PSF2 header says it's shorter than a
 *     header.
 * @error BadMagic The bytes are neither a PSF1 nor a PSF2 file.
 * @error UnsupportedVersion A PSF2 file of a version other than 0.
 * @error BadGlyphSize No glyphs, a width or height of 0, or a glyph size that doesn't match them.
 */
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

/**
 * Parse a PSF1 font: 256 or 512 glyphs 8 pixels wide and as tall as its header says, and maybe a Unicode table after
 * them.
 *
 * @param bytes The file's bytes, its magic already checked; the font keeps referring to them.
 * @return The font, 256 or 512 glyphs 8 pixels wide: views of the bytes' glyphs and of the rest of the bytes after them
 *     as its Unicode table when the mode says it has one, its quick table filled, and its replacement the glyph for
 *     '?', or 0.
 * @error Truncated The bytes end before the header or the glyphs.
 * @error BadGlyphSize The header gives a height of 0.
 */
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

/**
 * Read the Unicode table's entry at a byte offset.
 *
 * @param font The font whose table it reads: 16-bit entries for PSF1, UTF-8 and marker bytes for PSF2.
 * @param at The entry's offset in the table, in bytes. Past the table's end, the entry is GlyphEnd.
 * @return What the entry is; GlyphEnd at the table's end, and for a PSF1 entry cut off by it.
 * @return Its code point if it's a Point, else 0. Malformed UTF-8 is U+FFFD.
 * @return How many bytes it takes, at least 1, so reading always moves on: 2 for PSF1, 1 to 4 for PSF2.
 */
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

/**
 * Fill the font's quick table from its Unicode table, or with glyph i for code point i without one.
 *
 * Only single code points count; a code point the table gives more than one glyph is the first one's.
 *
 * @param font The font, whose quick field is written; its glyphs and Unicode table have to be set already.
 */
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

/**
 * Find the glyph for a code point: from the quick table, or by searching the Unicode table.
 *
 * Code points of QUICK_CODE_POINTS and up take a search of the table, as long as the table is.
 *
 * @param font The font, parsed.
 * @param code_point The code point; a sequence's code points aren't found, only single ones.
 * @return The glyph's index, below the font's glyph_count; NO_GLYPH if the font doesn't have it.
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

/**
 * Find the rows of a glyph's pixels.
 *
 * @param font The font, parsed.
 * @param glyph The glyph's index, as glyph_index gives it.
 * @return Its rows, top first, each bytes_per_row bytes, the leftmost pixel in the highest bit: a view of the font's
 *     bytes, good as long as they are. Empty for a glyph the font doesn't have, like NO_GLYPH.
 */
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

/**
 * Decode the code point encoded in UTF-8 at a byte offset.
 *
 * SPEC: RFC 3629 (UTF-8), section 3
 *
 * @param bytes The bytes decoded from.
 * @param at Where the code point starts, in bytes.
 * @return The code point; U+FFFD for a malformed, overlong or cut-off sequence, a surrogate, a value past U+10FFFF,
 *     or an offset past the end.
 * @return How many bytes it takes: 1 to 4, and 1 for U+FFFD put in a malformed sequence's place, so decoding always
 *     moves on.
 */
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

/** U+FFFD, what a malformed UTF-8 sequence decodes as. */
REPLACEMENT_CHARACTER : u32 : 0xfffd
