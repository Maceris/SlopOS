# Spleen

The kernel's framebuffer console font: Spleen 2.2.0 by Frederic Cambus, 12×24, in PSF2 with a
Unicode table, from https://github.com/fcambus/spleen (release `spleen-2.2.0.tar.gz`), under the
BSD 2-clause license in `LICENSE`.

The kernel embeds `spleen-12x24.psfu` with `#file_data` (`src/kernel/console/font_data.hsc`).
