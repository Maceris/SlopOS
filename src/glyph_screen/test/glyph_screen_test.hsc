/**
 * The framebuffer back end's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or
 * the number of the first check that failed. Over a buffer standing in for a 1024x640 framebuffer of 32-bit pixels, the
 * grid is centered, the status line drawn inverse, a letter drawn in its colour on the default background, the cursor
 * inverse, only rows that changed drawn again, and colours from the palette, the cube and RGB. On 800x600, too small
 * for 80 by 24 cells of 12x24, the 8x16 font fits them all.
 */
package glyph_screen_test

import runtime from "base"
import slop_os from "std/os"
import terminal from "std/os/slop_os"
import glyph_screen from ".."
import screen from "../../screen"

WIDTH : u32 : 1024
HEIGHT : u32 : 640

main :: fn() -> int {
    pixels, error :: runtime.new_array(u32, cast[usize](WIDTH * HEIGHT))
    if error != null || pixels.count == 0 {
        return 1
    }
    // Blue in the low byte, red in the third, as OVMF's framebuffers are
    layout :: slop_os.FramebufferLayout.{width = WIDTH, height = HEIGHT, pitch = WIDTH * 4, bits_per_pixel = 32, red_size = 8,
        red_shift = 16, green_size = 8, green_shift = 8, blue_size = 8, blue_shift = 0}
    canvas := glyph_screen.make_canvas(cast[u64](cast[usize](&pixels[0])), layout) or_return 2
    // 12x24 glyphs: 960 by 576 pixels, centered
    if canvas.left != 32 || canvas.top != 32 || canvas.columns != 80 || canvas.rows != 24 {
        return 3
    }
    model := runtime.new(screen.Screen)
    screen.set_status(model, " status")
    red :: terminal.Style.{foreground = terminal.palette(1)}
    screen.put(model, string_bytes("H"), 1, red)
    glyph_screen.draw(&canvas, model, true)
    // The status line's row: inverse, so the default foreground behind its blank cells
    if pixel(pixels, canvas.left + 79 * 12 + 1, canvas.top + 1) != 0xaaaaaa {
        return 4
    }
    // The H, on row 1: some pixels red, the rest the background
    if lit(pixels, canvas.left, canvas.top + 24, 0xaa0000) == 0 || lit(pixels, canvas.left, canvas.top + 24, 0x000000) == 0 {
        return 5
    }
    // The cursor, after the H: inverse, so mostly the default foreground
    if lit(pixels, canvas.left + 12, canvas.top + 24, 0xaaaaaa) < 12 * 24 / 2 {
        return 6
    }
    // Rows that didn't change aren't drawn again
    marked :: cast[usize]((canvas.top + 48) * WIDTH + canvas.left)
    if marked < pixels.count {
        pixels[marked] = 0x123456
    }
    glyph_screen.draw(&canvas, model, true)
    if pixel(pixels, canvas.left, canvas.top + 48) != 0x123456 {
        return 7
    }
    // Colours: the cube, a grey, RGB, bold's bright one, and inverse
    cube, cube_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.palette(196)})
    grey, grey_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.palette(244)})
    chosen, chosen_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.rgb(1, 2, 3), attributes = terminal.INVERSE})
    bright, bright_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.palette(1), attributes = terminal.BOLD})
    if cube != 0xff0000 || grey != 0x808080 || chosen != 0x000000 || chosen_back != 0x010203 || bright != 0xff5555 {
        return 8
    }
    small_layout :: slop_os.FramebufferLayout.{width = 800, height = 600, pitch = 800 * 4, bits_per_pixel = 32, red_size = 8,
        red_shift = 16, green_size = 8, green_shift = 8, blue_size = 8, blue_shift = 0}
    small := glyph_screen.make_canvas(cast[u64](cast[usize](&pixels[0])), small_layout) or_return 9
    if small.font.width != 8 || small.columns != 80 || small.rows != 24 || small.left != 80 || small.top != 108 {
        return 10
    }
    return 0
}

pixel :: fn(pixels: u32[], x: u32, y: u32) -> u32 {
    at :: cast[usize](y * WIDTH + x)
    return if at < pixels.count { pixels[at] } else { cast[u32](0xffffffff) }
}

/** How many pixels of the cell whose top left is at x and y are color. */
lit :: fn(pixels: u32[], x: u32, y: u32, color: u32) -> u32 {
    count : u32 = 0
    for row in 0..<cast[u32](24) {
        for column in 0..<cast[u32](12) {
            if pixel(pixels, x + column, y + row) == color {
                count += 1
            }
        }
    }
    return count
}
