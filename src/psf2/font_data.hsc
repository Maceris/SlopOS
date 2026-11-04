package psf2

/**
 * The consoles' font, Spleen 12x24 (third_party/spleen, BSD 2-clause): a PSF2 file's bytes, in the program's image,
 * for parse_font.
 */
FONT_DATA :: #file_data("../../third_party/spleen/spleen-12x24.psfu")
/**
 * The consoles' small font, Spleen 8x16 (third_party/spleen, BSD 2-clause), for a framebuffer too small for 80 by 24
 * cells of the 12x24 one: a PSF2 file's bytes, in the program's image.
 */
SMALL_FONT_DATA :: #file_data("../../third_party/spleen/spleen-8x16.psfu")
