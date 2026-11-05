/**
 * The framebuffer back end's tests, a test program (tools/unit_tests.py, decisions/0175). Over a buffer standing in for
 * a 1024x640 framebuffer of 32-bit pixels, the grid is centered, the status line drawn inverse, a letter drawn in its
 * colour on the default background, the cursor inverse, only rows that changed drawn again, and colours from the
 * palette, the cube and RGB. On 800x600, too small for 80 by 24 cells of 12x24, the 8x16 font fits them all.
 */
package glyph_screen_test

import runtime from "base"
import testing from "std"
import slop_os from "std/os"
import terminal from "std/os/slop_os"
import glyph_screen from ".."
import screen from "../../screen"

/** The width of the framebuffer the tests stand a buffer in for, in pixels. */
WIDTH : u32 : 1024
/** The height of the framebuffer the tests stand a buffer in for, in pixels. */
HEIGHT : u32 : 640

/** A buffer standing in for a framebuffer, and a canvas over it. */
Framebuffer :: struct {
    /** The pixels, WIDTH * HEIGHT of them, from the context's allocator, which free_framebuffer gives back. */
    pixels : mut u32[],
    /** The first pixel's address, for make_canvas. */
    address : u64,
    /** The canvas over the pixels, WIDTH by HEIGHT. */
    canvas : glyph_screen.Canvas,
}

/**
 * Make a buffer standing in for a WIDTH by HEIGHT framebuffer, blue in the low byte and red in the third as OVMF's
 * framebuffers are, and a canvas over it.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The framebuffer, which the caller frees with free_framebuffer; Error if it couldn't be allocated or the
 *     canvas made, the failure recorded.
 */
framebuffer :: fn(t: ptr[mut testing.T]) -> Result[Framebuffer, testing.Stopped] {
    pixels, error :: runtime.new_array(u32, cast[usize](WIDTH * HEIGHT))
    if error != null || pixels.count == 0 {
        testing.fail(t, "the stand-in framebuffer is allocated")
        return .Error(.Failed)
    }
    address :: cast[u64](cast[usize](&pixels[0]))
    layout :: slop_os.FramebufferLayout.{width = WIDTH, height = HEIGHT, pitch = WIDTH * 4, bits_per_pixel = 32, red_size = 8,
        red_shift = 16, green_size = 8, green_shift = 8, blue_size = 8, blue_shift = 0}
    match glyph_screen.make_canvas(address, layout) {
        case Some(canvas) => return .Ok(Framebuffer.{pixels = pixels, address = address, canvas = canvas})
        case None => {
            runtime.free_array(pixels)
            testing.fail(t, "a canvas fits 1024x640 pixels of 32 bits")
            return .Error(.Failed)
        }
    }
}

/**
 * Give back a framebuffer framebuffer made.
 *
 * @param made The framebuffer, whose pixels aren't used after.
 */
free_framebuffer :: fn(made: Framebuffer) {
    runtime.free_array(made.pixels)
}

the_grid_is_centered #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: framebuffer(t)?
    defer free_framebuffer(made)
    // 12x24 glyphs: 960 by 576 pixels, centered
    testing.expect_eq(t, made.canvas.left, 32, "(1024 - 80 * 12) / 2 pixels to the left of the grid")
    testing.expect_eq(t, made.canvas.top, 32, "(640 - 24 * 24) / 2 pixels above it")
    testing.expect_eq(t, made.canvas.columns, 80, "12-pixel glyphs fit 80 columns")
    testing.expect_eq(t, made.canvas.rows, 24, "24-pixel glyphs fit 24 rows")
    return .Ok
}

cells_are_drawn_in_their_colours_and_only_when_they_change #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made := framebuffer(t)?
    defer free_framebuffer(made)
    pixels :: made.pixels
    canvas := made.canvas
    model := runtime.new(screen.Screen)
    defer runtime.free(model)
    screen.set_status(model, " status")
    red :: terminal.Style.{foreground = terminal.palette(1)}
    screen.put(model, string_bytes("H"), 1, red)
    glyph_screen.draw(&canvas, model, true)
    testing.expect_eq(t, pixel(pixels, canvas.left + 79 * 12 + 1, canvas.top + 1), 0xaaaaaa,
        "the status line is inverse, so its blank cells are the default foreground")
    testing.expect(t, lit(pixels, canvas.left, canvas.top + 24, 0xaa0000) > 0, "the H, on row 1, is drawn in red")
    testing.expect(t, lit(pixels, canvas.left, canvas.top + 24, 0x000000) > 0, "on the default background")
    testing.expect(t, lit(pixels, canvas.left + 12, canvas.top + 24, 0xaaaaaa) >= 12 * 24 / 2,
        "the cursor, after the H, is inverse: mostly the default foreground")
    // Rows that didn't change aren't drawn again
    marked :: cast[usize]((canvas.top + 48) * WIDTH + canvas.left)
    if marked < pixels.count {
        pixels[marked] = 0x123456
    }
    glyph_screen.draw(&canvas, model, true)
    testing.expect_eq(t, pixel(pixels, canvas.left, canvas.top + 48), 0x123456, "row 2 didn't change, so it isn't drawn again")
    return .Ok
}

colours_come_from_the_palette_the_cube_and_rgb #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    cube, cube_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.palette(196)})
    grey, grey_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.palette(244)})
    chosen, chosen_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.rgb(1, 2, 3), attributes = terminal.INVERSE})
    bright, bright_back :: glyph_screen.colors_of(terminal.Style.{foreground = terminal.palette(1), attributes = terminal.BOLD})
    testing.expect_eq(t, cube, 0xff0000, "196 is the colour cube's pure red")
    testing.expect_eq(t, grey, 0x808080, "244 is the grey ramp's 0x80")
    testing.expect_eq(t, chosen, 0x000000, "inverse, the foreground is the default background")
    testing.expect_eq(t, chosen_back, 0x010203, "and the background the RGB foreground")
    testing.expect_eq(t, bright, 0xff5555, "bold makes palette red its bright one")
    return .Ok
}

a_small_framebuffer_takes_the_small_font #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    made :: framebuffer(t)?
    defer free_framebuffer(made)
    small_layout :: slop_os.FramebufferLayout.{width = 800, height = 600, pitch = 800 * 4, bits_per_pixel = 32, red_size = 8,
        red_shift = 16, green_size = 8, green_shift = 8, blue_size = 8, blue_shift = 0}
    small :: testing.require_some(t, glyph_screen.make_canvas(made.address, small_layout), "a canvas fits 800x600 pixels")?
    testing.expect_eq(t, small.font.width, 8, "80 by 24 cells of 12x24 don't fit 800x600, so the 8x16 font is used")
    testing.expect_eq(t, small.columns, 80, "8-pixel glyphs fit 80 columns")
    testing.expect_eq(t, small.rows, 24, "16-pixel glyphs fit 24 rows")
    testing.expect_eq(t, small.left, 80, "(800 - 80 * 8) / 2 pixels to the left of the grid")
    testing.expect_eq(t, small.top, 108, "(600 - 24 * 16) / 2 pixels above it")
    return .Ok
}

/**
 * Read a pixel of the buffer standing in for the framebuffer, WIDTH pixels to a row.
 *
 * @param pixels The pixels the test drew into, only read, one u32 each in the test's layout, the first row first.
 * @param x The pixel's column, from 0.
 * @param y The pixel's row, from 0.
 * @return The pixel, as 0xRRGGBB in the test's layout; 0xffffffff, which no drawn pixel is, past the buffer's end.
 */
pixel :: fn(pixels: u32[], x: u32, y: u32) -> u32 {
    at :: cast[usize](y * WIDTH + x)
    return if at < pixels.count { pixels[at] } else { cast[u32](0xffffffff) }
}

/**
 * Count the pixels of a 12x24 cell that are one colour.
 *
 * @param pixels The buffer standing in for the framebuffer, WIDTH pixels to a row.
 * @param x The cell's left column, in pixels.
 * @param y The cell's top row, in pixels.
 * @param color The colour, as the pixel holds it.
 * @return How many of the cell's 288 pixels are that colour; pixels past the buffer's end aren't.
 */
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
