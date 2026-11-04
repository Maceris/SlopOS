/**
 * The terminal service's framebuffer back end (decisions/0138): a screen model's rows drawn on a linear framebuffer
 * with the consoles' PSF2 font (12x24, or 8x16 where 80 by 24 of those don't fit), each cell's first code point's
 * glyph in its style's colours, the status line on the top row and the program's rows below it, the 80 by 24 grid
 * centered where the framebuffer has room. It reaches the pixels only through the address it's given, so it's tested
 * over a buffer.
 */
package glyph_screen

import slop_os from "std/os"
import terminal from "std/os/slop_os"
import unicode from "std"
import psf2 from "../psf2"
import screen from "../screen"

/** The default foreground colour, as 0xRRGGBB: a text console's light grey. */
DEFAULT_FOREGROUND : u32 : 0xaaaaaa
/** The default background colour, as 0xRRGGBB: a text console's black. */
DEFAULT_BACKGROUND : u32 : 0x000000

/** The 16 colours, as 0xRRGGBB, as a VGA console has them: the 8, then their bright ones. */
PALETTE :: u32.[0x000000, 0xaa0000, 0x00aa00, 0xaa5500, 0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa,
    0x555555, 0xff5555, 0x55ff55, 0xffff55, 0x5555ff, 0xff55ff, 0x55ffff, 0xffffff]

/** A framebuffer to draw a screen on, and how the screen's grid is placed on it. */
Canvas :: struct {
    /** The address of the framebuffer's first pixel, mapped writable in the process, the caller's to keep mapped. */
    pixels : u64,
    /** The framebuffer's size, pitch and pixel format. */
    layout : slop_os.FramebufferLayout,
    /** The bytes of one pixel: 2, 3 or 4. */
    bytes_per_pixel : u32,
    /** The font cells are drawn in, viewing the font data in the program's image. */
    font : psf2.Font,
    /** The grid's left edge, in pixels from the framebuffer's: 0 when the grid's as wide as it or wider. */
    left : u32,
    /** The grid's top edge, in pixels from the framebuffer's: 0 when the grid's as tall as it or taller. */
    top : u32,
    /** How many of the grid's columns fit on the framebuffer, at most COLUMNS; the rest aren't drawn. */
    columns : u32,
    /** How many of the grid's rows, the status line's included, fit on the framebuffer, at most ROWS. */
    rows : u32,
}

/**
 * Make a canvas on a framebuffer, cleared to the default background.
 *
 * It takes the 12x24 font where 80 by 24 cells of it fit, and the 8x16 one where they don't.
 *
 * @param address The address of the framebuffer's first pixel, mapped writable; it has to stay mapped while the canvas
 *     is drawn on, and has to be the layout's height times its pitch in bytes.
 * @param layout The framebuffer's size, pitch and pixel format.
 * @return The canvas; null if a font couldn't be parsed, the pixels aren't 2, 3 or 4 bytes, or the framebuffer's too
 *     small for one cell.
 */
make_canvas :: fn(address: u64, layout: slop_os.FramebufferLayout) -> Canvas? {
    large :: match psf2.parse_font(psf2.FONT_DATA) {
        case Ok(parsed) => parsed
        case Error(error) => return null
    }
    fits :: layout.width >= cast[u32](screen.COLUMNS) * large.width && layout.height >= cast[u32](screen.ROWS) * large.height
    font :: if fits { large } else {
        match psf2.parse_font(psf2.SMALL_FONT_DATA) {
            case Ok(parsed) => parsed
            case Error(error) => return null
        }
    }
    bytes_per_pixel :: (cast[u32](layout.bits_per_pixel) + 7) / 8
    if bytes_per_pixel < 2 || bytes_per_pixel > 4 || layout.width < font.width || layout.height < font.height {
        return null
    }
    width :: cast[u32](screen.COLUMNS) * font.width
    height :: cast[u32](screen.ROWS) * font.height
    made := Canvas.{pixels = address, layout = layout, bytes_per_pixel = bytes_per_pixel, font = font,
        left = if layout.width > width { (layout.width - width) / 2 } else { cast[u32](0) },
        top = if layout.height > height { (layout.height - height) / 2 } else { cast[u32](0) },
        columns = if layout.width / font.width < cast[u32](screen.COLUMNS) { layout.width / font.width } else { cast[u32](screen.COLUMNS) },
        rows = if layout.height / font.height < cast[u32](screen.ROWS) { layout.height / font.height } else { cast[u32](screen.ROWS) }}
    clear(&made)
    return made
}

/**
 * Clear every pixel of the framebuffer to the default background, the margins around the grid included.
 *
 * @param canvas The canvas, not changed; every pixel of the framebuffer it points at is written, layout.height rows of
 *     layout.width pixels, each row a pitch after the last.
 */
clear :: fn(canvas: ptr[Canvas]) {
    color :: pixel_of(canvas, DEFAULT_BACKGROUND)
    for y in 0..<canvas.layout.height {
        line :: canvas.pixels + cast[u64](y) * cast[u64](canvas.layout.pitch)
        for x in 0..<canvas.layout.width {
            put_pixel(canvas, line + cast[u64](x) * cast[u64](canvas.bytes_per_pixel), color)
        }
    }
}

/**
 * Draw the rows of a screen that changed, and the status line if it did, and mark them drawn.
 *
 * What's drawn is what's shown: the panel while it's up, or the program's grid. The cursor is drawn inverse.
 *
 * @param canvas The canvas whose framebuffer the rows are drawn on; the canvas itself isn't changed.
 * @param model The screen, whose dirty rows are cleared and status_drawn set as they're drawn.
 * @param cursor_shown Whether the cursor is shown, drawn at the shown grid's cursor; a cell drawn with it stays inverse
 *     until its row is drawn again.
 */
draw :: fn(canvas: ptr[Canvas], model: ptr[mut screen.Screen], cursor_shown: bool) {
    if !model.status_drawn {
        draw_cells(canvas, 0, model.status_cells, null)
        model.status_drawn = true
    }
    grid :: screen.shown(model)
    for row in 0..<cast[u16](screen.PROGRAM_ROWS) {
        index :: cast[usize](row)
        if index >= grid.dirty.count || !grid.dirty[index] {
            continue
        }
        grid.dirty[index] = false
        start :: index * screen.COLUMNS
        if start + screen.COLUMNS > grid.cells.count {
            break
        }
        cursor :: if cursor_shown && grid.row == row { cast[u16?](grid.column) } else { cast[u16?](null) }
        draw_cells(canvas, cast[u32](row) + 1, grid.cells[start..<start + screen.COLUMNS], cursor)
    }
}

/**
 * Draw one row of cells, each its first code point's glyph in its style's colours.
 *
 * A code point the font doesn't have is drawn as the font's replacement, and a cluster that doesn't decode as U+FFFD.
 *
 * @param canvas The canvas whose framebuffer the cells are drawn on, at its font's size, from its left and top; it
 *     isn't changed.
 * @param row The row on the canvas: 0 for the status line, the program's rows from 1; a row past the canvas's isn't
 *     drawn.
 * @param cells The row's cells; those past the canvas's columns aren't drawn.
 * @param cursor The cursor's column, whose cell is drawn with inverse toggled; null without one on this row.
 */
draw_cells :: fn(canvas: ptr[Canvas], row: u32, cells: screen.Cell[], cursor: u16?) {
    if row >= canvas.rows {
        return void
    }
    for &cell, column in cells {
        if cast[u32](column) >= canvas.columns {
            break
        }
        style := cell.style
        match cursor {
            case Some(at) => {
                if cast[usize](at) == column {
                    style.attributes = style.attributes ~ terminal.INVERSE
                }
            }
            case None => {}
        }
        point := cast[u32](' ')
        if cell.count > 0 && cast[usize](cell.count) <= cell.bytes.count {
            first, length :: unicode.decode(cell.bytes[0..<cast[usize](cell.count)], 0)
            point = if length == 0 { unicode.REPLACEMENT } else { first }
        }
        else if cell.width == 0 && column > 0 && cells[column - 1].width == 2 {
            // The second column of a wide cluster, which the font draws as one cell: left blank in its colours
            point = cast[u32](' ')
        }
        foreground, background := colors_of(style)
        draw_glyph(canvas, glyph_for(&canvas.font, point), cast[u32](column), row, pixel_of(canvas, foreground), pixel_of(canvas, background))
    }
}

/**
 * Find a style's colours, as 0xRRGGBB: inverse swaps them, bold makes the 8 colours their bright ones and the default
 * foreground white, and dim halves the foreground.
 *
 * @param style The style: its foreground and background colours and its BOLD, DIM and INVERSE attributes; others don't
 *     change the colours.
 * @return foreground The colour a glyph's lit pixels are drawn in.
 * @return background The colour its other pixels are drawn in.
 */
colors_of :: fn(style: terminal.Style) -> (foreground: u32, background: u32) {
    foreground := rgb_of(style.foreground, DEFAULT_FOREGROUND, style.attributes & terminal.BOLD != 0)
    background := rgb_of(style.background, DEFAULT_BACKGROUND, false)
    if style.attributes & terminal.DIM != 0 {
        foreground = (foreground >> 1) & 0x7f7f7f
    }
    if style.attributes & terminal.INVERSE != 0 {
        return background, foreground
    }
    return foreground, background
}

/**
 * Find a terminal colour as 0xRRGGBB.
 *
 * Palette colours 0 to 15 are PALETTE's, 16 to 231 a 6x6x6 cube, and 232 to 255 greys, as xterm's 256 colours are.
 *
 * @param color The colour: the default, an RGB colour, or a palette index.
 * @param default What the default colour is, as 0xRRGGBB.
 * @param bright Whether bold makes it bright: palette colours 0 to 7 become 8 to 15, and DEFAULT_FOREGROUND white.
 * @return The colour, as 0xRRGGBB.
 */
rgb_of :: fn(color: terminal.Color, default: u32, bright: bool) -> u32 {
    match terminal.color_kind(color) {
        case .Default => return if bright && default == DEFAULT_FOREGROUND { cast[u32](0xffffff) } else { default }
        case .Rgb => return (cast[u32](color.red) << 16) | (cast[u32](color.green) << 8) | cast[u32](color.blue)
        case .Palette => {
            index :: cast[usize](color.index) + (if bright && color.index < 8 { cast[usize](8) } else { cast[usize](0) })
            if index < PALETTE.count {
                return PALETTE[index]
            }
            // 16 to 231, a 6x6x6 cube; 232 to 255, greys
            if index < 232 {
                cube :: cast[u32](index - 16)
                levels :: u32.[0, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
                return (levels[(cube / 36) % 6] << 16) | (levels[(cube / 6) % 6] << 8) | levels[cube % 6]
            }
            grey :: cast[u32](8 + (index - 232) * 10)
            return (grey << 16) | (grey << 8) | grey
        }
    }
}

/**
 * Find the glyph a code point's drawn with.
 *
 * @param font The font, only read: its quick table, or a search of its Unicode table for a code point past it.
 * @param point The code point, any u32; one the font has no glyph of its own for, alone rather than in a sequence, gets
 *     the replacement.
 * @return Its glyph, or the font's replacement if it hasn't one.
 */
glyph_for :: fn(font: ptr[psf2.Font], point: u32) -> u16 {
    glyph :: psf2.glyph_index(font, point)
    return if glyph == psf2.NO_GLYPH { font.replacement } else { glyph }
}

/**
 * Draw a glyph in a cell of the grid, every one of the cell's pixels written.
 *
 * @param canvas The canvas whose font, placement and framebuffer the glyph is drawn with; it isn't changed.
 * @param glyph The glyph, an index into the canvas's font; one without rows is drawn as background.
 * @param column The cell's column in the grid, from 0.
 * @param row The cell's row on the canvas, from 0 for the status line; a cell that would reach past the framebuffer
 *     isn't drawn.
 * @param foreground The glyph's lit pixels, as the framebuffer's pixel (pixel_of).
 * @param background Its other pixels, as the framebuffer's pixel.
 */
draw_glyph :: fn(canvas: ptr[Canvas], glyph: u16, column: u32, row: u32, foreground: u32, background: u32) {
    rows :: psf2.glyph_rows(&canvas.font, glyph)
    left :: canvas.left + column * canvas.font.width
    top :: canvas.top + row * canvas.font.height
    if left + canvas.font.width > canvas.layout.width || top + canvas.font.height > canvas.layout.height {
        return void
    }
    for y in 0..<canvas.font.height {
        line :: canvas.pixels + cast[u64](top + y) * cast[u64](canvas.layout.pitch)
        for x in 0..<canvas.font.width {
            at :: cast[usize](y * canvas.font.bytes_per_row + x / 8)
            lit :: at < rows.count && (rows[at] >> cast[u8](7 - x % 8)) & 1 == 1
            put_pixel(canvas, line + cast[u64](left + x) * cast[u64](canvas.bytes_per_pixel), if lit { foreground } else { background })
        }
    }
}

/**
 * Convert a colour to the framebuffer's pixel format.
 *
 * @param canvas The canvas, whose layout gives each channel's size and place.
 * @param rgb The colour, as 0xRRGGBB.
 * @return The pixel, in its low bytes_per_pixel bytes.
 */
pixel_of :: fn(canvas: ptr[Canvas], rgb: u32) -> u32 {
    layout :: &canvas.layout
    return channel((rgb >> 16) & 0xff, layout.red_size, layout.red_shift) | channel((rgb >> 8) & 0xff, layout.green_size, layout.green_shift)
        | channel(rgb & 0xff, layout.blue_size, layout.blue_shift)
}

/**
 * Place one colour channel in a pixel.
 *
 * @param value The channel's 8-bit value, 0 to 255.
 * @param size The channel's bits in the pixel: 0 for none, under 8 to keep only its highest bits.
 * @param shift The channel's lowest bit's place in the pixel.
 * @return The channel's bits, in place, for or-ing with the others.
 */
channel :: fn(value: u32, size: u8, shift: u8) -> u32 {
    if size == 0 {
        return 0
    }
    if size >= 8 {
        return value << cast[u32](shift)
    }
    return (value >> (8 - cast[u32](size))) << cast[u32](shift)
}

/**
 * Write a pixel's bytes, lowest first.
 *
 * @param canvas The canvas, whose bytes_per_pixel says how many bytes are written.
 * @param address The pixel's address in the framebuffer, which has to be mapped writable.
 * @param value The pixel, as pixel_of makes it.
 */
put_pixel :: fn(canvas: ptr[Canvas], address: u64, value: u32) {
    if canvas.bytes_per_pixel == 4 {
        cast[ptr[mut u32]](address)^ = value
        return void
    }
    for i in 0..<canvas.bytes_per_pixel {
        cast[ptr[mut u8]](address + cast[u64](i))^ = cast[u8]((value >> (i * 8)) & 0xff)
    }
}
