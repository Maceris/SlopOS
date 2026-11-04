package console

import boot_info from "../../boot_info"
import psf2 from "../../psf2"

/**
 * A text console on a framebuffer: a grid of character cells, written left to right and top to
 * bottom, scrolling up a line when the bottom is full. Not synchronized: the kernel writes to it
 * holding its console lock.
 */
Console :: struct {
    /** The virtual address of the framebuffer's first pixel, in the direct map. */
    pixels : u64,
    /** The framebuffer's visible width, in pixels. */
    width : u32,
    /** The framebuffer's visible height, in pixels. */
    height : u32,
    /** Bytes from the start of one pixel row to the start of the next. */
    pitch : u32,
    /** The bytes one pixel takes: 2, 3 or 4. */
    bytes_per_pixel : u32,
    /** The text's pixel value, in the framebuffer's layout: light grey. */
    foreground : u32,
    /** The background's pixel value, in the framebuffer's layout: black. */
    background : u32,
    /** The built-in font (psf2.FONT_DATA), parsed; its views are of the kernel image, so they stay good. */
    font : psf2.Font,
    /** How many character cells fit across: the width over the font's width, at least 1. */
    columns : u32,
    /** How many lines of cells fit down: the height over the font's height, at least 1. */
    rows : u32,
    /** The cell the next character goes in, from 0; it may equal columns, when the next one starts a new line. */
    column : u32,
    /** The line being written, from 0 to rows - 1. */
    row : u32,
}

/** Why a console couldn't be made on a framebuffer. */
ConsoleError :: union {
    /** The built-in font didn't parse, for the reason given. */
    Font(psf2.FontError),
    /** Pixels that aren't 2, 3 or 4 bytes, or a framebuffer too small for one character. */
    UnsupportedFramebuffer,
}

// Light grey on black, like a text-mode console.
/** The text color's red, of 0 to 255. */
FOREGROUND_RED : u32 : 0xaa
/** The text color's green, of 0 to 255. */
FOREGROUND_GREEN : u32 : 0xaa
/** The text color's blue, of 0 to 255. */
FOREGROUND_BLUE : u32 : 0xaa

/**
 * Make a console on a framebuffer, cleared to black, its cursor at the top left.
 *
 * Every visible pixel is written, so the framebuffer has to be mapped writable at direct_map_offset plus its physical
 * address, for pitch times height bytes, for as long as the console is used.
 *
 * @param framebuffer The framebuffer, as the boot information describes it; read only while this runs.
 * @param direct_map_offset What's added to a physical address to reach it through the direct map.
 * @return The console, which refers to the framebuffer's memory through the direct map, and to the font in the
 *     kernel image.
 * @error Font The built-in font didn't parse.
 * @error UnsupportedFramebuffer Pixels that aren't 2, 3 or 4 bytes, or a framebuffer narrower or shorter than one
 *     character; nothing is written to it.
 */
make_console :: fn(framebuffer: ptr[boot_info.Framebuffer], direct_map_offset: u64) -> Result[Console, ConsoleError] {
    made : Console
    console :: &made
    match psf2.parse_font(psf2.FONT_DATA) {
        case Ok(font) => console.font = font
        case Error(error) => return .Error(.Font(error))
    }
    font :: &console.font
    bytes_per_pixel :: (cast[u32](framebuffer.bits_per_pixel) + 7) / 8
    if bytes_per_pixel < 2 || bytes_per_pixel > 4 || framebuffer.width < font.width || framebuffer.height < font.height {
        return .Error(.UnsupportedFramebuffer)
    }
    console.pixels = direct_map_offset + cast[u64](framebuffer.memory.base)
    console.width = framebuffer.width
    console.height = framebuffer.height
    console.pitch = framebuffer.pitch
    console.bytes_per_pixel = bytes_per_pixel
    console.columns = framebuffer.width / font.width
    console.rows = framebuffer.height / font.height
    console.column = 0
    console.row = 0
    console.foreground = pixel_value(framebuffer, FOREGROUND_RED, FOREGROUND_GREEN, FOREGROUND_BLUE)
    console.background = pixel_value(framebuffer, 0, 0, 0)
    fill_rows(console, 0, console.height)
    return .Ok(made)
}

/**
 * Make the pixel value of a color, in the framebuffer's layout.
 *
 * @param framebuffer The framebuffer, whose channels say where each color's bits go.
 * @param red The color's red, 0 to 255.
 * @param green The color's green, 0 to 255.
 * @param blue The color's blue, 0 to 255.
 * @return The pixel's value, its bytes lowest first in memory: each channel's highest bits, as many as the
 *     framebuffer has for it, shifted to its place.
 */
pixel_value :: fn(framebuffer: ptr[boot_info.Framebuffer], red, green, blue: u32) -> u32 {
    return channel(framebuffer.red, red) | channel(framebuffer.green, green) | channel(framebuffer.blue, blue)
}

/**
 * Place one 8-bit color in a pixel value.
 *
 * @param where Where the color's bits are in a pixel. With no bits, the color is left out; with 8 or more, all 8 go
 *     in at the bottom of the channel's bits.
 * @param value The color, 0 to 255.
 * @return The color's bits, shifted to their place, with every other bit 0.
 */
channel :: fn(where: boot_info.ColorChannel, value: u32) -> u32 {
    if where.size == 0 {
        return 0
    }
    if where.size >= 8 {
        return value << cast[u32](where.shift)
    }
    return (value >> (8 - cast[u32](where.size))) << cast[u32](where.shift)
}

/**
 * Write text at the cursor, wrapping at the right edge and scrolling at the bottom.
 *
 * A line feed starts a new line, and a carriage return goes back to the line's start; every other code point is
 * drawn, as the font's replacement glyph if it has none. Not synchronized: the caller holds the kernel's console lock.
 *
 * @param console The console, whose cursor moves past the text.
 * @param text UTF-8 text; a malformed sequence is drawn as U+FFFD, one byte at a time. Empty text draws U+FFFD.
 */
write :: fn(console: ptr[mut Console], text: string) {
    bytes :: bit_cast[u8[]](text)
    with {
        at : usize = 0
    }
    loop {
        code_point, length :: decode_utf8(bytes, at)
        at += length
        if code_point == cast[u32]('\n') {
            new_line(console)
            continue
        }
        if code_point == cast[u32]('\r') {
            console.column = 0
            continue
        }
        if console.column >= console.columns {
            new_line(console)
        }
        draw_glyph(console, glyph_for(&console.font, code_point), console.column, console.row)
        console.column += 1
    }
    while at < bytes.count
}

/**
 * Find the glyph a code point is drawn with.
 *
 * @param font The console's parsed PSF font, whose views are of the built-in font data in the kernel image, so it
 *     stays valid for the kernel's life.
 * @param code_point The Unicode code point to draw, as decode_utf8 gives it; U+FFFD for a malformed sequence.
 * @return Its glyph's index, or the font's replacement glyph when it has none.
 */
glyph_for :: fn(font: ptr[psf2.Font], code_point: u32) -> u16 {
    glyph :: psf2.glyph_index(font, code_point)
    if glyph == psf2.NO_GLYPH {
        return font.replacement
    }
    return glyph
}

/**
 * Move the cursor to the next line's start, scrolling everything up a line from the bottom.
 *
 * @param console The console, whose cursor moves.
 */
new_line :: fn(console: ptr[mut Console]) {
    console.column = 0
    if console.row + 1 < console.rows {
        console.row += 1
        return void
    }
    scroll(console)
}

/**
 * Move every line of text up one, by copying the framebuffer's pixels, and clear the bottom line.
 *
 * Pixel rows below the last whole line of text are left alone.
 *
 * @param console The console; its cursor isn't moved.
 */
//TODO(claude): scroll a copy in normal memory once there's a frame allocator (M2): reading the
//framebuffer is slow, since it's mapped write-combining
scroll :: fn(console: ptr[mut Console]) {
    line_bytes :: cast[u64](console.pitch) * cast[u64](console.font.height)
    text_bytes :: line_bytes * cast[u64](console.rows)
    copy_bytes(console.pixels, console.pixels + line_bytes, text_bytes - line_bytes)
    fill_rows(console, (console.rows - 1) * console.font.height, console.font.height)
}

/**
 * Copy bytes down in memory, 8 at a time while both addresses are 8-byte aligned, then a byte at a time.
 *
 * It copies forward, so overlapping ranges are safe only when target is below source. The first 8 bytes are copied
 * whole before anything is checked, so count has to be at least 8, and both addresses are best 8-byte aligned.
 *
 * @param target The virtual address copied to, below source.
 * @param source The virtual address copied from.
 * @param count How many bytes to copy, at least 8.
 */
copy_bytes :: fn(target, source, count: u64) {
    done : u64 = 0
    loop {
        cast[ptr[mut u64]](target + done)^ = cast[ptr[u64]](source + done)^
        done += 8
    }
    while done + 8 <= count && (target & 7) == 0 && (source & 7) == 0
    loop {
        cast[ptr[mut u8]](target + done)^ = cast[ptr[u8]](source + done)^
        done += 1
    }
    while done < count
}

/**
 * Fill pixel rows with the background color, across the visible width.
 *
 * @param console The console, which isn't changed; its pixels are.
 * @param first The first pixel row filled, from the top.
 * @param count How many pixel rows are filled; first plus count can be at most the height.
 */
fill_rows :: fn(console: ptr[Console], first, count: u32) {
    for y in first..<first + count {
        row :: console.pixels + cast[u64](y) * cast[u64](console.pitch)
        for x in 0..<console.width {
            put_pixel(console, row + cast[u64](x) * cast[u64](console.bytes_per_pixel), console.background)
        }
    }
}

/**
 * Draw a glyph in a character cell, its lit pixels in the foreground and the rest in the background.
 *
 * @param console The console, which isn't changed; its pixels are.
 * @param glyph The glyph's index in the console's font; one the font doesn't have is drawn as background.
 * @param column The cell's column, below the console's columns.
 * @param row The cell's row, below the console's rows.
 */
draw_glyph :: fn(console: ptr[Console], glyph: u16, column, row: u32) {
    rows :: psf2.glyph_rows(&console.font, glyph)
    left :: column * console.font.width
    top :: row * console.font.height
    for y in 0..<console.font.height {
        line :: console.pixels + cast[u64](top + y) * cast[u64](console.pitch)
        for x in 0..<console.font.width {
            // Inside the glyph's rows for a font parse_font accepted
            at :: cast[usize](y * console.font.bytes_per_row + x / 8)
            if at >= rows.count {
                continue
            }
            byte :: rows[at]
            lit :: (byte >> cast[u8](7 - x % 8)) & 1 == 1
            color :: if lit { console.foreground } else { console.background }
            put_pixel(console, line + cast[u64](left + x) * cast[u64](console.bytes_per_pixel), color)
        }
    }
}

/**
 * Write a pixel's bytes, lowest first: one 32-bit store for 4-byte pixels, otherwise byte by byte.
 *
 * @param console The console, for its bytes per pixel.
 * @param address The pixel's virtual address, in the direct map.
 * @param value The pixel's value, as pixel_value makes it; bits past the pixel's bytes are dropped.
 */
put_pixel :: fn(console: ptr[Console], address: u64, value: u32) {
    if console.bytes_per_pixel == 4 {
        cast[ptr[mut u32]](address)^ = value
        return void
    }
    for i in 0..<console.bytes_per_pixel {
        cast[ptr[mut u8]](address + cast[u64](i))^ = cast[u8]((value >> (i * 8)) & 0xff)
    }
}
