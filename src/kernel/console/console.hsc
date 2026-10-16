package console

import boot_info from "../../boot_info"

/*
 * A text console on a framebuffer: a grid of character cells, written left to right and top to
 * bottom, scrolling up a line when the bottom is full. Not synchronized: the kernel writes to it
 * holding its console lock.
 */
Console :: struct {
    // The framebuffer's first pixel, in the direct map.
    pixels : u64,
    width : u32,
    height : u32,
    pitch : u32,
    bytes_per_pixel : u32,
    foreground : u32,
    background : u32,
    font : Font,
    columns : u32,
    rows : u32,
    column : u32,
    row : u32,
}

ConsoleError :: union {
    Font(FontError),
    // Pixels that aren't 2, 3 or 4 bytes, or a framebuffer too small for one character.
    UnsupportedFramebuffer,
}

// Light grey on black, like a text-mode console.
FOREGROUND_RED : u32 : 0xaa
FOREGROUND_GREEN : u32 : 0xaa
FOREGROUND_BLUE : u32 : 0xaa

/*
 * A console on framebuffer, which is mapped at direct_map_offset plus its physical address,
 * cleared to black.
 */
make_console :: fn(framebuffer: ptr[boot_info.Framebuffer], direct_map_offset: u64) -> Result[Console, ConsoleError] {
    made : Console
    console :: &made
    match parse_font(FONT_DATA) {
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

/*
 * The pixel value of a color given as 8-bit channels, in the framebuffer's layout: each channel
 * keeps its highest bits, shifted to its place.
 */
pixel_value :: fn(framebuffer: ptr[boot_info.Framebuffer], red, green, blue: u32) -> u32 {
    return channel(framebuffer.red, red) | channel(framebuffer.green, green) | channel(framebuffer.blue, blue)
}

channel :: fn(where: boot_info.ColorChannel, value: u32) -> u32 {
    if where.size == 0 {
        return 0
    }
    if where.size >= 8 {
        return value << cast[u32](where.shift)
    }
    return (value >> (8 - cast[u32](where.size))) << cast[u32](where.shift)
}

// Write UTF-8 text: a line feed starts a new line, a carriage return goes back to the line's start.
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

glyph_for :: fn(font: ptr[Font], code_point: u32) -> u16 {
    glyph :: glyph_index(font, code_point)
    if glyph == NO_GLYPH {
        return font.replacement
    }
    return glyph
}

// Move to the next line's start, scrolling up a line from the bottom.
new_line :: fn(console: ptr[mut Console]) {
    console.column = 0
    if console.row + 1 < console.rows {
        console.row += 1
        return void
    }
    scroll(console)
}

/*
 * Move every line up one, by copying the framebuffer's pixels, and clear the bottom line.
 */
//TODO(claude): scroll a copy in normal memory once there's a frame allocator (M2): reading the
//framebuffer is slow, since it's mapped write-combining
scroll :: fn(console: ptr[mut Console]) {
    line_bytes :: cast[u64](console.pitch) * cast[u64](console.font.height)
    text_bytes :: line_bytes * cast[u64](console.rows)
    copy_bytes(console.pixels, console.pixels + line_bytes, text_bytes - line_bytes)
    fill_rows(console, (console.rows - 1) * console.font.height, console.font.height)
}

// Copy count bytes from source down to target, which is below it, 8 bytes at a time where they line up.
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

// Fill count pixel rows from first with the background.
fill_rows :: fn(console: ptr[Console], first, count: u32) {
    for y in first..<first + count {
        row :: console.pixels + cast[u64](y) * cast[u64](console.pitch)
        for x in 0..<console.width {
            put_pixel(console, row + cast[u64](x) * cast[u64](console.bytes_per_pixel), console.background)
        }
    }
}

draw_glyph :: fn(console: ptr[Console], glyph: u16, column, row: u32) {
    rows :: glyph_rows(&console.font, glyph)
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

// Write a pixel's bytes, lowest first.
put_pixel :: fn(console: ptr[Console], address: u64, value: u32) {
    if console.bytes_per_pixel == 4 {
        cast[ptr[mut u32]](address)^ = value
        return void
    }
    for i in 0..<console.bytes_per_pixel {
        cast[ptr[mut u8]](address + cast[u64](i))^ = cast[u8]((value >> (i * 8)) & 0xff)
    }
}
