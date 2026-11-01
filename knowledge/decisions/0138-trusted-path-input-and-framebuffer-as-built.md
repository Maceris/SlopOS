# 0138: 10a2, the Input Service, the Status Line, the Secure Attention Key and the Framebuffer, as Built

Status: accepted
Date: 2026-11-01
Related: `0136` (M10's plan), `0137` (10a1), `0043` (the trusted path), `0077` (input devices),
`../design/console-and-sessions.md` §2, §3, `../../docs/specs/programs.md`

## Context
`0136`'s 10a2: the input service owning keyboards and the seat, keymaps, new keyboards accepted by a code, the secure
attention key on both kinds of console, the status line, and the framebuffer back end. Chosen with the owner as 10a2
started: the serial line's secure attention key is Ctrl+Alt+Delete as a terminal sends it, since the console's virtio
serial line can't carry a BREAK; the console is one terminal shown on the framebuffer and the serial line alike; and
the keyboards there when the input service starts are accepted, one found later waiting for its code (SlopOS has no
hotplug yet, so a test option makes every keyboard new). And, when 80 by 24 cells of the 12×24 font didn't fit AArch64's
800×600 framebuffer, Spleen's 8×16 for framebuffers that small.

## Decision
- **The screen model** (`src/screen`): the console's cells, 80 by 24, each a grapheme cluster made safe and its style;
  grids for the program's lines, a screen of its own, and the terminal service's own panel; the cursor in each; the
  status line's cells; which rows changed. The serial line still streams lines as they come, and the model is what
  everything is drawn again from.
- **The status line** is the top row, only the terminal service's: `SlopOS │ console │ no session`, and a new
  keyboard's code while one waits. On the serial line the rows below it are the ones that scroll (DECSTBM), and the
  status line is drawn between a saved and a restored cursor (DECSC, DECRC), which is how `boot.py` leaves it out.
- **The secure attention key**, Ctrl+Alt+Delete, from the input service as its own event, or on the serial line as
  CSI 3;7~, brings up the terminal service's panel over the program's screen. Every key goes to it and none reaches a
  program, the keys that came with it included, until Esc or Enter, when the program's rows are drawn again from the
  model. What it lists and does is 10a3's (the session's programs, ending them) and 10c's (login).
- **The input service** (`src/services/input_service`, the `seat` protocol): up to four keyboards through connectors,
  typed through a keymap (`src/keymaps`, the US layout as a table, so another is a table more), keys with their usage,
  modifiers and text; Ctrl+Alt+Delete from any keyboard, accepted or not, is `SecureAttention` and never a key. A new
  keyboard's first key makes a random six-digit code, shown on the status line; nothing it types goes anywhere until
  that code and Enter are typed on it. Ctrl-C stays the terminal service's to turn into `Interrupt`.
- **The framebuffer**: the kernel describes the first framebuffer in its own `FB  ` firmware table
  (`slop_os.FramebufferLayout`, in Hemera's `std/os/slop_os`); the platform service gives it out on `ClaimFramebuffer`,
  as write-combining device memory and a page holding its layout; making that memory takes the framebuffer from the
  kernel's console. The supervisor claims it each time it starts the terminal service, which draws the model there
  (`src/glyph_screen`): each cell's first code point's glyph in its style's colours (the 16 VGA colours, the 256 cube
  and greys, 24-bit; bold brightens, dim halves, inverse swaps), the grid centered, only changed rows drawn, the cursor
  inverse.
- **Fonts** (`src/psf2`, out of the kernel's console): PSF1 as well as PSF2, since Spleen's 8×16 release is PSF1. The
  terminal service draws with 12×24 where 80 by 24 of those fit, and 8×16 where they don't.
- **Budgets**: the input service and echo have 2 MiB. With 1 MiB, the input service's first log record with a number
  ran out of heap writing that type's schema, and `base`'s logger ended it with an assertion; a task to make the
  logger drop the record instead is filed for Hemera.
- **Tests**: the secure attention key on the serial line, a new keyboard accepted by its code (and what was typed
  before it not shown), and the console on the framebuffer, checked from QEMU's screendump (a status line's band as
  wide as the console, text below it); `test_settle=<seconds>` keeps a `test_services` boot up long enough.

## Alternatives considered
- **A UART driver for a real BREAK**: more work, and the kernel's log shares that line.
- **Two terminals**, the screen with its keyboard and the serial line: each with its own reader, before sessions give
  them owners.
- **Remembering accepted keyboards** in the config store: a device identity to trust, for no hotplug yet.
- **Clipping a narrow framebuffer**, or asking QEMU for a larger one: real 800×600 screens would still clip.

## Consequences
- Every x86-64 boot draws the console on OVMF's framebuffer, and the kernel's framebuffer log stops there once the
  terminal service starts; AArch64's `virt` has a framebuffer only with `ramfb`.
- 10a3 fills the panel: the session's programs, not responding ones marked, ended from there.
