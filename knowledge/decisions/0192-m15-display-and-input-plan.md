# 0192: M15, Display and Input, Planned

Status: accepted, chosen with the project's owner (2026-11-13); not started
Date: 2026-11-13
Related: `0018` (the powerbox), `0043` (the trusted path), `0037` (budgets), `0072` (the milestones' order), `0136` to
`0161` (M10's console, input and sessions), `0189` (float math and linear algebra, for the canvas), `0191` (M14),
`../design/display.md`, `../design/console-and-sessions.md`, `../roadmap.md` M15

## Context
M14 is done, and M15 is next. `design/display.md` proposed its shape on 2026-10-24: virtio-gpu in 2D mode, a
compositor in software, surfaces with explicit sync and buffer descriptions from the first version, capabilities in
the GUI through the powerbox, an identity band and a trusted layer, a 2D canvas and fonts in Hemera's `std`, and a
small UI library. Left open: the UI library's API, how windows are arranged, which programs, and the typeface.

The project's owner has written a UI library before, in Java (the Ikala project's Ikala-Graphics, MIT): a line-by-line
port of Dear ImGui with a retained layer of their own on top, which lays a tree out, Clay-like, then replays each node
as immediate calls at its rectangle. A survey of it (2026-11-13) found what's below under *Lessons taken*.

## Decision
Chosen with the project's owner:
- **The UI library's API is immediate mode, with a tree each frame.** A program describes its UI from its state every
  frame (`if ui.button("Save") { save() }`): no callbacks, no widget objects to keep in step with the program's data,
  which suits Hemera, without a garbage collector or closures. But the calls don't draw as they go: they build the
  frame's tree, which is then laid out, then drawn. So layout can size a widget by what comes after it; the draw list
  is compared with the last frame's, which gives the damage a software compositor needs; and the tree, with stable
  IDs, is what the Accessibility capability reads (`display.md` §4). State a widget keeps (focus, scroll, an open
  section, the text being edited) is the library's, by ID, between frames. Frames are run only when something
  happens: input, a timer, a change of the program's.
- **Floating windows**: overlapping, moved and resized with the pointer; the identity band the compositor draws on
  each (`display.md` §5) is its title bar, which the client can't draw over.
- **Programs**: a terminal emulator speaking the terminal protocol; the typed-data viewer; a launcher, which also
  switches between windows; and login, the lock screen and the powerbox's chooser and prompts in the GUI's trusted
  layer.
- **Typeface: Noto Sans and Noto Sans Mono** (SIL Open Font License), for their coverage of most scripts. The files are
  downloaded with the owner's say-so when the canvas stage needs them, and kept with their licence.

Proposed, for the stages to settle as they're built:
- **Where things live**: the canvas, the font rasterizer, text layout and the UI library's core in Hemera's `std`
  (`std/canvas`, `std/fonts`, `std/ui`), which know nothing of SlopOS, so they're tested hosted, on Windows and Linux,
  against reference images; the widgets that speak SlopOS's protocols (forms from manifests, the powerbox's chooser) in
  SlopOS.
- **Input**: the pointer from virtio-input's tablet (absolute) and mouse (relative), through the input service, which
  gives the seat to the compositor or the terminal service, and keeps the secure attention key before either.
- **The compositor** composites in software, with SIMD (`0189`'s vectors), on a budget of its own at a high priority;
  the pointer through virtio-gpu's cursor queue, so moving it needs no composite. The console stays the terminal
  service's, and the secure attention key's screen and the text console are kept for when the GUI can't run.
- **Clipboard** as `display.md` §4 has it: copy offers typed data; paste is the compositor's, on the user's gesture,
  to the focused client. Screen capture, global shortcuts, input injection, accessibility and clipboard history are
  powerbox capabilities, the protocol's from the first version; which of them M15 builds past the protocol is settled
  in its stages, Accessibility among them, since the tree's there.

## Lessons taken from Ikala-Graphics
- **Sizing as Clay's**: each axis `Fixed`, `Fit(min, max)` or `Grow(weight, min, max)`; lengths in units, a percentage
  of the parent, or the font's em; laid out one axis at a time, widths first, so text can wrap to its width before
  heights are known: a fit pass bottom-up, a size pass top-down, then positions. Grow shares space in rounds, each round
  sharing all of it or pinning a child at its minimum or maximum. Justify, align, gaps and padding.
- **Text wrapping from the start.** Ikala's retained layer was ordered for wrapped text but measured one line only, so
  its labels never wrapped; here text is measured with its wrap width from the first version.
- **Hashes mixed**: IDs hashed with a mixing finalizer and an ID stack, never derived by adding to a parent's (Ikala's
  `table1` and `table2` collided until mixed); a loop's items keyed explicitly, by index by default, a duplicate key
  told apart and reported.
- **IDs made at compile time where they can be** (the owner's note, 2026-11-13): Hemera runs code at compile time
  as Java and C can't, so a widget's ID from a literal label, or from its call site (`#caller_location`), is hashed
  when the program's compiled, a constant; a loop's key is mixed into it at run time, one integer mix; only a label
  built at run time is hashed at run time. Far less hashing per frame than Dear ImGui's, which hashes every label every
  frame.
- **Liveness, not collection**: each frame marks the IDs it saw; interaction state (active, focused, dragged) and kept
  widget state of an ID not seen is dropped, which the tree makes exact by comparing ID sets between frames.
- **One heavy text state**: only the focused text field has an editing state (cursor, selection, undo); every other is
  its program's text.
- **Fire, then handle**: a widget's event is a record the frame returns, handled by the program after the frame, never
  a callback during it.
- **No allocation per frame**: arenas and per-frame scratch from the start, text measured by ranges, styles cached;
  Ikala's main performance work was taking allocation out of its render loop.
- **Lists of many items** virtualized with fixed-size rows or cells, since items never made can't be measured.
- **Selectors over the tree** (Ikala's `ui/automation`, paths over IDs and text, as `about//text=Close`) for driving the
  UI in tests, the same tree the accessibility protocol gives.

Ikala's immediate core is Dear ImGui's, under its MIT licence; nothing of it is copied. Its retained layer, draw format
and atlas are the owner's own.

## Stages
- **15a, the canvas and fonts** in Hemera's `std`: paths (lines, quadratic and cubic curves), non-zero and even-odd
  fills, strokes with joins, caps and dashes, solid and gradient paints, images with filtering, clips and transforms,
  rasterized on the CPU with coverage anti-aliasing and SIMD, reporting its damage; a TrueType rasterizer (quadratic
  outlines, `cmap`, `hmtx`, `kern` and `GPOS` pair kerning), glyphs cached; text laid out in lines, wrapped to a width.
  Tests: hosted, against reference images and known metrics.
- **15b, the display and the pointer**: virtio-gpu in 2D mode and the `display` protocol (modes, scanout buffers,
  damaged rectangles, the cursor queue); on real hardware's firmware framebuffer the same protocol, one mode, the
  cursor drawn by the compositor; virtio-input's tablet and mouse through the input service. Boot tests on both
  architectures.
- **15c, the compositor and surfaces**: the `surface` protocol as `display.md` §3 has it (fences, buffer
  descriptions, colour space, present modes, presentation feedback, subsurfaces); floating windows with the identity
  band as their title bar; focus on the user's gesture; the seat's hand-over with the terminal service; copy and paste.
  Boot tests: two clients that can't see each other's pixels or input, a window moved and raised, paste on the gesture.
- **15d, the UI library** in `std/ui`: the immediate API with its tree each frame, Clay's layout, state by ID with
  liveness, events returned after the frame, damage by comparing draw lists, a text field (cursor, selection, undo,
  clipboard), lists virtualized, a theme, the tree's selectors for tests and its export for accessibility. Tests:
  hosted, frames driven by synthetic input and compared to reference images; selectors.
- **15e, the programs**: the terminal emulator, the launcher (starting installed programs, switching windows), the
  typed-data viewer, and forms from manifests. Boot tests through the pointer and keyboard.
- **15f, the trusted layer**: login, the lock screen and the powerbox's chooser and prompts drawn by the trusted
  services above every client; the secure attention key bringing it forward; the GUI's capabilities through the
  powerbox. Boot tests: a client can't draw over the band or the layer; a prompt answered there.
- **15g, a security review and the full suites**, with the input-to-photon latency test (`display.md` *Also
  proposed*).

## As Built: 15a
- **`std/fonts`**, a TrueType reader over a font's bytes, which it never copies: the table directory, `head`, `hhea`,
  `maxp`, `hmtx`, `loca` and `glyf`; `cmap` formats 4 and 12, the Unicode subtable preferred; glyphs' outlines as
  moves, lines and quadratic curves, composites to a depth of 8 with their offsets and scales; pair kerning from
  `GPOS`'s `kern` feature (lookup types 2 and 9, pair formats 1 and 2) or else the old `kern` table. Layout: a line's
  height, a string measured with its kerning, and text wrapped to a width at line breaks and spaces, a word wider than
  the width split between its characters.
  Every read is bounds-checked; a bad font gives no glyphs, never a fault. CFF outlines (`.otf`) aren't read: Noto
  Sans and Noto Sans Mono are TrueType, and they're what M15 ships.
- **`std/canvas`**, drawing into a BGRA premultiplied image: paths of lines, quadratic and cubic curves, rectangles,
  ellipses and rounded rectangles; curves flattened to within a quarter pixel; rasterized by accumulating each edge's
  signed area and coverage into cells, summed along a row (font-rs's method), non-zero or even-odd. Strokes are
  polygons, each segment's quad with miter, round or bevel joins and butt, round or square caps, then filled non-zero;
  dashes of up to 16 entries with an offset, walked at most 2^20 steps a stroke. Paints: solid, linear and radial
  gradients of up to 8 stops interpolated premultiplied; images drawn nearest or bilinear through the inverse
  transform. A stack of saved states (transform, clip rectangle); the damage, the union of what was drawn, taken by the
  caller. Blending is one 4-lane vector a pixel. Text from a glyph cache of 1024 masks at a quarter-pixel's steps, in a
  4 MB pool cleared when full; a transform that isn't a translation draws text as paths.
- Where the plan differed: reference images became measured properties (a fill's coverage summed is its area, exact
  for rectangles, within 1% for a circle at a quarter pixel's flattening; strokes' areas by cap; the cache's text
  against the same glyphs drawn as paths), which don't need images kept in the tree. The metrics are checked against a
  second reader of the fonts in Python, apart from `std/fonts`.
- **Tests:** hosted scenarios `fonts` (7) and `canvas` (7) on Windows and Linux, with property tests for any bytes as a
  font, a changed font, and any path, curve, stroke, dash and transform drawn (huge and NaN coordinates included);
  fuzz targets `font_bytes`, `font_changed` and `canvas_paths` in `tools/fuzz.py`. The fuzzed path test found strokes
  with dashes along huge paths making pieces without end; they're capped.

## As Built: 15b
- **The `display` protocol** (`src/protocols/display`): one client, the compositor, of a screen of one mode.
  - `Describe` gives its size, stride, format (XRGB8888), how many scanout buffers, its cursor plane's size and its
    refresh rate where known.
  - `GetBuffer` gives a read-write window onto a scanout buffer (DMA memory the device reads) or the cursor's
    (64 by 64, ARGB8888 not premultiplied).
  - `Present` shows a buffer with what in it changed since that buffer was last presented, buffer age as other systems
    have it. It's answered once shown, which frees the buffer shown before.
  - `SetCursor` and `MoveCursor` aren't answered, so moving the pointer never waits.
- **`virtio_gpu`** drives a virtio GPU in 2D mode.
  - It shows the first scanout at the size the device prefers (QEMU's 1280 by 800), up to 1920 by 1200.
  - Each of two buffers is a device resource backed by the driver's DMA memory: a present copies the damage
    (`TRANSFER_TO_HOST_2D`), switches the scanout if it's another buffer, and flushes.
  - The cursor is a resource of its own, moved through the cursor queue with 16 commands in flight; a move with none
    free waits for one, so the last position always lands.
  - Control commands go one at a time, each waited for, up to a second.
- **Input**: the `input` protocol's `Describe` gives a device's absolute axes' ranges, which `virtio_input` reads from
  the device's configuration (`VIRTIO_INPUT_CFG_ABS_INFO`), so a tablet's positions can be scaled to the screen.
- **`test_display`**, started with `test_display` on the command line, is given connectors to the display and the
  input devices.
  - It draws a scene with `std/canvas` into the buffer that isn't shown and presents it.
  - It shows an arrow on the cursor plane and moves it with the tablet.
  - It draws a click's mark into the other buffer.
- Where the plan differed:
  - **The firmware framebuffer as a `display`** moved to 15c. It's the terminal service's console until the
    compositor takes the screen over, which is 15c's hand-over.
  - **The pointer through the input service** moved to 15c too, with the seat's hand-over. Until then a client
    reads the input devices itself, as `test_display` does.
  - On x86-64 OVMF's GOP can be the virtio GPU itself, which the terminal service then draws its console on until
    `virtio_gpu` takes the device. That conflict is also 15c's.
- **Tests:**
  - A boot test on both architectures (`--display`): QEMU's tablet clicks the screen's middle through the machine
    protocol, and the GPU's screen is taken (`screendump`) and checked for the scene's colours and the click's mark.
    Then the power button ends the run.
  - The `display` protocol's validators are among those fuzzed.

## As Built: 15c
- **The `surface` protocol** (`src/protocols/surface`), as `display.md` §3 has it from its first version.
  - Buffers are described by format, modifier and up to three planes; surfaces have a colour space and a scale (in
    120ths); submissions carry FIFO or mailbox and a target time; subsurfaces are in the protocol.
  - Events come through a held Read: Configure, focus, the pointer, buttons, wheels, keys with text, Released, Presented
    and Paste. `Copy` offers typed data with a text form.
  - M15 implements the simplest case of each: XRGB8888 or premultiplied ARGB8888, linear, one plane, sRGB, scale 1.
    `CreateSubsurface` is answered `Refused(Unsupported)`; fences aren't sent, a submitted buffer being ready.
- **The seat lent** (`seat` protocol):
  - The reader (the terminal service) `Lend`s the seat at start, after setup or login, and when its secure attention
    screen closes.
  - While it's lent, keys and the pointer go to the other client that reads, the compositor. With no compositor,
    keys go to the terminal service as before.
  - The secure attention key, or a new keyboard's first key, takes the seat back, dropping what waited for the
    borrower.
  - The pointer reaches the seat as `PointerMotion`, `PointerPosition` (spread to 0..65535 from the device's axes),
    `Button` and `Wheel`, only ever to a borrower.
- **The compositor** (`src/services/compositor`) is started with `gui` or `test_compositor` on the command line and a
  display.
  - It composites in software into the display's buffer that isn't shown, over this frame's damage and the last's,
    and presents it.
  - Windows float, cascaded as they're made. Each has an identity band the client can't draw on: its title in Noto
    Sans (`assets/fonts`, with OFL.txt), the focused one's blue, and a close box.
  - A press raises and focuses a window; a drag of its band moves it; the close box sends CloseRequested.
  - Keys go to the focused window; the pointer goes to the window it's over, in that window's units, with a button's
    release to the window its press went to.
  - Ctrl+Shift+V pastes what was last copied, as text, into the focused window; the compositor sees the gesture,
    never a client.
  - A buffer replaced is released once a frame without it is shown, and each submission's frame gets a Presented.
- **Tests:** a boot test on both architectures (`--compositor`). test_compositor connects twice, two clients with a
  window each. Then through QEMU's machine protocol:
  - a key goes only to B, which is focused;
  - a click on A raises it;
  - a drag of B's band moves it;
  - Ctrl+Shift+V pastes A's copy into B.
  The screen is then checked for both windows where they ended up, their bands focused and not. The `surface`
  protocol's validators are fuzzed with the rest.
- Where the plan differed, for the end of M15:
  - **The identity band shows the client's title, not the program's name and connection label.** A client's name
    has to come from whoever connects it, the session manager starting GUI programs, which is 15e.
  - **The firmware framebuffer as a display, and a console that hands the screen over, aren't built.** On QEMU
    the console and the GUI are on different devices; on hardware with one framebuffer they'd share it. This needs
    the console to give its framebuffer up while the seat is lent, and is left for a decision.
  - **Copy offers typed data, but only its text is pasted** (at most 128 bytes); pasting typed data is the
    typed-data viewer's, 15e.
  - `MAX_PARAMETERS` in the system records went from 256 to 320, as the services' parameters outgrew it.

## As Built: 15d
- **`std/ui`**, in Hemera's `std`, knowing nothing of SlopOS. A program describes its UI each frame between `begin`
  (with that frame's `Input`) and `end`, which gives the frame's damage. The frame's events (Clicked, Toggled,
  Changed, Submitted, Copied, Focused) are read after it; `paint` draws a region of the frame on a `std/canvas` canvas.
- **The tree and layout as Clay's.**
  - Boxes are sized per axis `Fit`, `Grow` (by weight, with a least and a most, in rounds), `Fixed` or `Percent`.
  - Rows and columns have padding, gaps and alignment, laid out widths first, so text is wrapped to its width before
    heights are found. Text's least width is its longest word.
  - Scroll areas clip their children and scroll them by a kept offset, turned by the wheel over them.
- **IDs**: a label's hash (FNV-1a, finalized) mixed with the parent's ID and an explicit key, never added. Two of one
  ID under a parent are told apart and reported. `ui.key("Save")` runs at compile time (`#run`) for a constant.
  Widgets hash their labels at run time, a short loop each; making every literal label's hash a compile-time constant
  needs the compiler to fold a call on a constant argument, left for later.
- **State by ID with liveness.** Each frame keeps every node's place and scroll in a table rebuilt from that frame's
  IDs, so a widget not drawn loses its state. Only the focused text field has an editing state: its cursor,
  selection, and up to 32 edits to undo and redo.
- **Input is resolved against what the last frame showed.** Its widgets' visible rectangles, inside their clips, are
  hit-tested with this frame's pointer, so hovering and pressing take effect in the frame the pointer moves, with no
  frame of lag.
  - A press focuses what takes focus; Tab and Shift+Tab move focus through the last frame's focusable widgets; Enter
    activates a focused button or check box.
- **Widgets**: labels, buttons, check boxes, scroll areas, virtualized lists (only the rows shown are made, the rest
  stood in for by space above and below), and a one-line text field. The field takes typed and pasted text, arrows,
  Home and End with Shift selecting, Backspace and Delete by whole UTF-8 characters, and select all, copy, cut, undo
  and redo.
- **Damage**: the frame's draw list (fills, edges, lines of text, clips) is compared with the last frame's by command;
  what differs, where it is and where it was, is the damage. An unchanged frame has none.
- **Selectors and accessibility**: `find` takes paths over names and roles (`//text=Save`, `list//role=listitem`),
  and `middle_of` gives where to point. `accessible` gives the tree as a reader of the screen would get it: role,
  name, place, focus and checked.
- **Tests:** a hosted scenario `ui` (11) on Windows and Linux. Frames are driven by synthetic input, checking each
  feature above, and frames are painted and their pixels checked. A property test takes any input across frames,
  also the fuzz target `ui_input`.
- Where the plan differed: frames are checked by measured layout and painted pixels rather than reference images, as
  15a did. A multi-line text field is left for 15e's programs, which have none yet.

## Settled during M15 (2026-11-13)
Chosen with the project's owner after 15d:
- **GUI login makes sessions.** The GUI's login, in the trusted layer (15f's), comes before the programs (15e's): a
  login there makes a session, as the console's does, whose programs are given a connection to the compositor. The
  terminal emulator is one of them: it serves the terminal protocol to a shell it starts in its session.
- **The launcher lists the installed bundles' programs** by their manifests, as the shell finds them, and starts them
  in its session through the session's programs connection.
- **The console yields the firmware framebuffer while the seat's lent.** On a machine with one framebuffer the
  terminal service gives it to a framebuffer display driver for the compositor while the seat's lent, and takes it
  back, redrawing, on the secure attention key.

## As Built so far: 15e and 15f (in progress)
Built, compiled for both architectures, and tested as far as the compositor's boot test reaches:
- **`src/gui_kit`**: a window on the compositor for a std/ui program.
  - It opens on a connector or on a connection, with two buffers of its own memory, and turns the compositor's events
    into std/ui's input. Keys are also kept raw, for a terminal.
  - A frame is painted into the buffer the compositor isn't reading, over what that buffer missed, and submitted with
    its damage. Copied text is offered to be pasted.
  - When neither buffer's been released within 200 ms it paints the one given longest ago, rather than stall.
- **`src/gui_programs`**: a GUI program's entry and grants (log, its own compositor connection, home, process manager,
  programs). A bundle whose manifest hashes as that entry's type is a GUI program.
- **The launcher** (`src/apps/launcher`): a GUI session's first program. It lists the bundle store's GUI programs,
  itself left out, and starts the one chosen with its own compositor connection (`Connect`), process manager
  connection and finding-only programs connection.
- **The terminal window** (`src/apps/terminal_window`): it serves the terminal protocol to a shell it finds and
  launches, keeping output in `src/screen`'s grid and drawing it in Noto Sans Mono. The window's keys, Ctrl+C as
  Interrupt, and pastes go to the reader. Colours are kept in the cells but drawn plain.
- **GUI sessions**: the session protocol's `StartGui`. The session manager now opens a session (`open_session`)
  apart from starting its first program, and is given its own connector to the compositor, dialed for each GUI
  session's launcher. The supervisor starts the compositor before the session manager when `gui` is on.
- **The trusted layer**: the compositor's second listener, which only trusted services get. Its clients' windows
  are centred, have no band, are drawn above every client's, and get the keyboard and pointer while one is shown.
- **The greeter** (`src/services/greeter`): the GUI's login in the trusted layer: name, password (std/ui's new
  secret field) and Log in. The account service opens the home; `StartGui` makes the session; the window's hidden
  until the session's first program ends. The session's powerbox prompts are refused for now.
- **The seat**: `Borrow` names the compositor the borrower outright, rather than taking whichever client reads second,
  which broke once the compositor started before the terminal service. The console's login screen lends the seat too,
  as the GUI's login is the trusted path's as well. The input service logs lending and borrowing.
- **Fixed on the way**:
  - virtio_gpu waits up to 10 s for a command, as an emulated device under load takes seconds.
  - The compositor releases replaced buffers even when a present fails.
  - Its `deliver` could send all the waiting text with fewer events.
  - The supervisor's budget went from 320 to 352 MiB, its connectors from 16 to 32. The compositor's budget is
    12 MiB, virtio_gpu's 20 MiB, the greeter's 6 MiB.

**Not yet working, for the next session:** the GUI login boot test (`GuiLoginTest` in `tools/boot.py`; its entry is out
of `boot_tests.py` until it passes).
- Keys reach the greeter's window through the compositor, but after a few frames the greeter gets no more events, so
  the login is never submitted. The same form passes in std/ui's hosted test (`fills_a_form_by_keyboard`).
- Suspected: the greeter's held Read is lost between gui_kit and the compositor, or the compositor blocks sending to
  it. Next step: instrument the compositor's serve and deliver for the trusted client.

**Still to build:** the typed-data viewer; forms from manifests; the powerbox's prompts in the trusted layer; the console
yielding the firmware framebuffer while the seat's lent; and 15g's review and full suites.
