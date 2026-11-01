# Spleen

The consoles' fonts: Spleen by Frederic Cambus, in PSF2 with a Unicode table, from
https://github.com/fcambus/spleen, under the BSD 2-clause license in `LICENSE`: `spleen-12x24.psfu` from
release 2.2.0 (`spleen-2.2.0.tar.gz`), and `spleen-8x16.psfu` from release 2.1.0 (`spleen-2.1.0.tar.gz`).

`src/psf2/font_data.hsc` embeds both with `#file_data`: the kernel's framebuffer console draws with 12×24, and the
terminal service with 12×24 where 80 by 24 cells of it fit the framebuffer, and 8×16 where they don't.
