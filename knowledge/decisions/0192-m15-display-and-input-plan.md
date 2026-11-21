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
- **15g, catching up, finishing, and making it fast** (added 2026-11-14, with the project's owner):
  - Catch up with the compiler's changes made meanwhile for its LSP and formatter.
  - Fix the failing boot tests: the GUI login's first, and any the compiler's changes broke.
  - Finish 15e's and 15f's open items (below, *As Built so far*).
  - Profile the boot tests and M15's code (the compositor, the canvas, std/ui, the GPU driver) and optimize what the
    profiles show.
  - Profile and optimize the compiler on SlopOS: its checks (`hemera --check`, the editor's) and its builds. A full
    build of SlopOS's programs takes about 67 s; the aim is a couple of seconds.
- **15h, a security review and the full suites**, with the input-to-photon latency test (`display.md` *Also
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

**Still to build:** the typed-data viewer; forms from manifests; the powerbox's prompts in the trusted layer; the console
yielding the firmware framebuffer while the seat's lent (all 15g's, built there); and 15h's review and full suites.

## As Built so far: 15g (in progress)
The boot tests pass again, all 291, with the GUI login's back among them.
- **The GUI login**: a GUI session's launcher now starts the terminal window, whose shell runs. What it took:
  - Surface connections have 8 KiB rings (`surface.RING_BYTES`), as one Input of 32 events didn't fit in 1 KiB.
  - The compositor and the input service halve what they send when it's TooBig, rather than retrying it forever.
  - gui_kit queues keys and typed text in the order they came, and hands std/ui a frame's keys, then its text, so
    text typed before a Tab lands in the field it was typed in.
  - The launcher asks the session manager what each program's entry is (`EntryOf`, from its bundle's record) instead
    of being given every program's executable and manifest to hash.
  - Budgets: the supervisor's 368 MiB, the session manager's 64 MiB, the launcher's 32 MiB; a program it starts
    gets 24 MiB, and the terminal window's shell 16 MiB.
  - A program the launcher starts is given a duplicate of its log. Base's logger doesn't use it (it writes only to an
    events ring, which such a program hasn't), so the terminal window and the viewer write their lines to it with
    log_line, as the first services do (`gui_kit.log_to`). Since then, GUI programs are the session's, with rings
    (below).
  - The greeter logs whom it logs in and each refusal, and exits with a code of its own for each way it ends.
- **A typing test** (`src/tests/test_gui`, `--gui-typing`): a std/ui window filled in twice, by Tab and by Shift+Tab.
- **The shell gets manifests alone** (`ManifestOf`), for viewing a typed file, help and completion. It used to be
  given each program's executable too, and each one given holds one of the bundle store's 64 objects open until it's
  closed. The running programs' executables hold most of them, so looking through every program ran out past the
  38th once M15's services came. So, chosen with the project's owner, the store keeps at most 16 objects' files open
  (`MAX_FILES`), opened as their pages are read and the one read from longest ago closed for another: an object open,
  or held, costs no connection to the volume server. Its objects went from 64 to 256, and the volume server's
  connections from 64 to 256 on their own terms. `store_files=N` keeps fewer, which the store's boot test sets to 2.
- **The compiler's changes**: the formatter moved test_debug.hsc's lines, so the debugger tests' line numbers moved;
  the AArch64 debug files outgrew 64 MiB, so a disk with them has 96 MiB more for them.
- **Building faster** (`--time-phases`, x86-64 programs, 24 logical processors): 55 s became 34 s.
  - `os.launch` took the program's entry as a function, `acpi_service.main`, though it only uses its type, so the
    supervisor and the root task each had every service's whole program generated, for LLVM to spend 30 s
    simplifying away: 61 MB of LLVM IR for a 340 KB root task. It takes `type_of(acpi_service.main)` now, which the
    compiler makes a compile-time type, so nothing in it is reached, by a build or a check. The supervisor's work fell
    from 70 s to 18 s, the root task's from 73 s to 14 s; the boot suite from 22.8 to 13.8 minutes.
  - The build adds the longest targets first (the bootloader, then the services), as they're started in that order.
  - What's left of a build from nothing is ~400 s of processor time across 94 targets: LLVM's optimizing (~240 s,
    mostly simplifying each whole program, std and all) and checking (resolving and checking ~150 s, parsing ~45 s,
    compile-time code ~25 s, summed over threads; std checked again for each target). More jobs don't help.
  - So the compiler has a build cache (Hemera's docs/compilation.md, The Build Cache), chosen with the project's
    owner over sharing checked std between targets. A program generated as before takes its outputs from the cache
    rather than being optimized and linked: a build after nothing changed went from 34 s to 11 s, into any folder. A
    build package's target whose files, and the files its compile-time code read through std, are as they were isn't
    checked at all: what its checks wrote (manifests, docs, system.records) is written again and its outputs copied.
    A build of the programs after nothing changed takes about 1 s; after an edit to hello, 5 s, as the four targets
    that import it are checked again (two of them, the root task and the supervisor, take ~3 s each to check). The
    outputs match a build without the cache byte for byte.
  - `hemera --check src/build` took 17 s cold and 6 s after, 5.3 s of it the build package's compile-time code
    loading each of the 24 test folders' packages (`compiler.load_package`, a check of each as a program of its own)
    only to see whether it has a main of its own. Hemera's new `compiler.declares` parses a package's files without
    checking them for a name; with it the check after takes 0.8 s.
  - The boot tests build into a new folder each run, whose path is in the build's settings, so their targets are
    checked each time, but their programs come from the cache.
  - `-O0` crashes LLVM's instruction selection (an `insertvalue` in SelectionDAG), probably on a large constant.
  - The editor (hemera-lsp, `hemera.root` set to `src/build`): opening the first file checks every target, ~18 s, the
    compiler peaking near 9 GB, with a 16 MB name index. Then a save checks the targets that read the file. A
    service's file is read by its program, the root task and the supervisor, the last two ~3 s each, so a save's
    diagnostics took ~5 s. hemera-lsp checks the target that reads the fewest files first now, and shows what it
    finds: ~1.5 s from a save to its diagnostics, the others' following. What's left is about a second of checking the
    program (~0.55 s), writing its 3 MB index (~0.2 s, over half of it std's declarations, which barely change), and
    the server reading and merging that index (~0.4 s); a save soon after another waits for the last one's others.
- **Outputs out of the sources**: the build package's outputs go in the repository's `build/` folder by default, which
  git ignores, and `hemera --check src/build` writes nothing (the compiler's `compiler.checking()`, and it makes an
  output's folder as it builds into it).
- **Forms from manifests** (`src/forms`): a program's parameters as a form, a field each for those the shell takes
  from an argument, by the shell's own rules (`shell_language`'s `parameters.hsc`, moved there from the shell): a
  check box for a bool, a text field for the rest, read as the shell reads a bare word or a quoted string, a list's
  as typed. Those the shell gives without asking aren't asked for. What's filled in becomes a command line.
  - The launcher lists the commands as well as the GUI programs, with a find field over both. A command clicked shows
    its form; Run, or Enter in a field, starts a terminal window (`GuiGrants.open`, the GUI entry's new parameter)
    whose shell runs that line alone, and which a key closes once it's done.
  - The launcher gives each program it starts the session's home (it's given the session's now). The session manager
    starts them now (*GUI programs are the session's programs*, below).
- **The typed-data viewer** (`src/apps/viewer`): the session's home listed, folders first, and a file shown as the
  shell's view shows it: a typed file's value by its type's schema, found among the programs' manifests and written
  as the shell writes values; text as text; other bytes in hexadecimal. Only the lines on screen are made each frame.
  A path typed and Enter shows that file; Escape goes back, and from the listing closes it.
- **The powerbox's prompts in the trusted layer** (the greeter's `prompts.hsc`): what a GUI session's powerbox asks is
  drawn in a window of the trusted layer, made from the greeter's connection so it's trusted too. A file or a folder
  is chosen over the home given, read only; for a file to write, a new file's name comes first, the program's
  suggestion to start, and Enter makes it. Debugging and the network are allowed or refused. What needs the
  administrator's password, or the account service, is refused, and logged as the console's.
- **The console yields the framebuffer** (decided earlier): with `gui` and no display's driver, the supervisor starts
  the framebuffer display (`src/services/framebuffer_display`), the display protocol over the firmware's
  framebuffer, with two scanout buffers of its own and no cursor plane. The terminal service lends it the framebuffer
  with the seat (the `screen` protocol) and takes it back on the secure attention key, drawing the console whole
  again. A frame presented while it isn't lent is kept, and drawn whole when it's lent again. A terminal service
  started again isn't given a connection to it; the display stops drawing when the first one goes.
- **Boot tests**: the GUI login's now also runs two forms, views the typed file the second made, and chooses a file in a
  prompt in the trusted layer, before the terminal; a new one draws the GUI on the framebuffer and gives it back.
- **Tests that wait on what happens, not for a time** (chosen with the project's owner): the GUI drivers in
  `tools/boot.py` send keys once the line that says they'll land is seen, the compositor focusing the window or the
  program saying it's drawn what takes them, each wait looking only at what came after what it waits on, and print
  how long each step took (shown under a test that passes). The GUI login went from a 400 s settle to about 60 s:
  the old runs that took that long were stalled steps, hidden by the fixed pauses. Taking the pauses out found:
  - std/ui moves focus for all of a frame's Tabs before it acts on Enter, so gui_kit ends a frame's keys at a Tab or
    an Enter, and the rest wait for the next frame.
  - gui_kit's wait waited while a frame was due, so a program woken only by input (the viewer, the launcher once no
    program it started runs) drew nothing more, and what was typed after waited unseen.
  - A send that waits while its ring's full drops the port's packets, the end's own Readable among them, so a message
    that came meanwhile woke nothing again: gui_kit's wait reads once before it waits (Hemera's std says so now).
  - A Read for events that couldn't be sent, its ring full, left a window that heard nothing more: gui_kit, and
    test_compositor, keep whether one's held and send it again.
  - The compositor left the keyboard with a window hidden (the greeter's prompt, once answered) or gave it to a
    hidden one when another went; it goes to the topmost window shown now. A client that doesn't read, and so has its
    events dropped, is logged.
  - The launcher kept no hold of the programs it started, so their budgets never came back and a second terminal
    window couldn't start; it holds each one's process and budget until it ends.
  - The viewer took ~9 s to find a typed file's type among the programs' manifests, and sometimes, under load, past
    180 s. Hashing the types took a couple of milliseconds a program; asking took 200 ms, as the session manager read
    the store's root, then the program's bundle, for each List and ManifestOf. It keeps the root's entries for as long
    as the root's the same, and each bundle's references (a bundle never changes, its hash naming its bytes): 40 to
    90 ms a program, the whole ~4 s, and the GUI login passed three times running among the others.
  - Timed a program at a time, that was the bundle store: List took 20 to 35 ms and ManifestOf 45, of which parsing
    and hashing the manifest took under 2. The store read its root file for every Root, which every List, launch and
    lookup asks, and an object's file for every Read. It keeps the root's hash now (only it writes the file), and the
    objects Read gives up to 64 KiB, 512 KiB of them, forgotten under pressure and by a collection: List 0.3 ms,
    ManifestOf 18 (each manifest's first read), and viewing the typed file ~1.7 s.
  - Timed a frame at a time in the GUI login test: laying out took 1 to 4 ms, presenting under 1, and pixels the
    rest. The compositor drew 75 ms a frame on average, 263 for the whole screen, and a client painted 50 to 150 ms:
    std/canvas filled every rectangle, backgrounds among them, by rasterizing it as a path and blending each pixel,
    and the compositor copied a window a byte at a time. std/canvas now fills a rectangle along the image's axes from
    its coverage, writing runs an opaque paint covers whole at once, and the compositor copies a row at once
    (std/memory's new copy, with no rawptr): 2 to 4 ms drawn, 5 to 12 painted.
  - Then waiting for a buffer was most of a frame, often the whole 200 ms: a frame that changed nothing (a pointer's
    motion, a Presented) still waited for the other buffer to paint what it had missed. gui_kit skips a frame without
    damage; the other buffer catches up at the next frame that changes something. The GUI login test went from ~50 s
    to ~39 s.
  - The console's typed input waits too: its one-second pauses (`\p`) are gone, and `tools/boot.py`'s waits look for
    what the console shows after where the last one ended: the shell's next empty prompt (`\>`, its cursor just past
    it), a line with some text (`\u{...}`), the status line's (`\s{...}`, `\S{...}`), a serial line (`\l{...}`), and
    the secure attention key's own screen after the key. A wait still waiting, or run out, fails the run, saying
    what came after the last. Taking the pauses out found:
    - A program's input line sent before its first Read wasn't drawn, as only the input's owner's is and a Read made
      the owner, so a session's first prompt showed only once a key was typed: the line takes the input as a Read
      does now. A line sent while another still owned it, as the shell's prompt is once a program it gave the
      terminal to has ended but isn't seen gone yet, is kept for when the sender's Read makes it the owner.
    - Keys that came while the trusted path's screen was up reached the program if one of them closed it: the Enter
      that allowed a request was the debugger's too. What comes while a screen's up is dropped, whichever key closes
      it.
    - The shell read what a program said of its progress only when its port woke it, which it doesn't wait on while
      it reads the program's output, so a foreground program's progress showed only at its end. It reads it as it
      attends to the programs now, every 50 ms, and draws the line only when it's changed.
    - The session manager's wait for a program to end, as it ends a session's, takes packets from its port and acts
      only on programs' ends, so a client's request that came meanwhile, the terminal service's List for the secure
      attention key's screen among them, could go unread while the main loop waited with nothing to wake it: the
      trusted path hung, until a test's settle ended the run. The main loop reads every client again first now.
- **GUI programs are the session's programs** (chosen with the project's owner over handing the launcher the
  session's locale, CPU budget and rings to pass on): the launcher starts nothing itself. It asks the session manager
  on the session's own programs connection (`programs`' new `Start`: a name, a home connection, and what to open), and
  each GUI program is one of the session's, with its log ring, lifecycle channel, locale and CPU budget, listed and
  ended by the trusted path and reported when it crashes, as the console shell's first program is. What the launcher
  and its ended port did to get budgets back is gone.
  - Only the session's own connection, in a session started with `StartGui`, may `Start`; a finding connection is
    refused, and the home it sent closed. So scripts can't start anything they couldn't before.
  - `Start` of the terminal window starts it and a shell, both the session's: the window serves one end of a new
    terminal channel (`GuiGrants.terminal`, a new parameter of the GUI entry) and the shell has the other, as the
    console's first shell has the session's terminal. The shell is given what that shell is (its CPU budget, data
    directory and network) and a programs connection that answers what the session's own does of its session
    (`Running`, `Install` and the rest) but doesn't start programs (a finder marked `shell`), since `launch_shell`
    used to give every shell the session's one connection, taking it from the launcher.
  - The GUI entry lost its process manager connection, which no GUI program uses now.
  - The session's first program is marked so (`Program.first`), rather than being any program that isn't the
    powerbox or an installation, so a GUI program ending doesn't end the session's `Wait`.
  - Budgets: the launcher's 16 MiB, each GUI program's 16 MiB, the terminal window's shell 16 MiB, all split off the
    session manager's, now 96 MiB, and so the supervisor's 400 MiB; it keeps up to 48 programs and 32 finding
    connections, across its sessions.
- **Left open, for the project's owner**:
  - The GUI's elevation (accounts, shutdown, traces, keys) is still only the console's.

## As Built: 15h
- **The input-to-photon latency** (`display.md` *Also proposed*): virtio_input stamps each event with when it took it
  from the device (`input.Event.time_ns`; `input.MAX_EVENTS` is 16 now, as 32 of the larger events don't fit half a
  default ring), the input service carries a key's into `seat.Event.time_ns`, and the compositor into the surface's
  Key, whose `time_ns` said only a Presented's time before. gui_kit measures from the earliest key a frame took to that
  frame's Presented, the display's answer to its present; test_gui logs the median and the slowest, and the typing
  test refuses a slowest past 250 ms. Measured: 8 to 18 ms median, 26 to 31 ms slowest, both architectures.
- **The security review** (independent reads of the display stack, the GUI's trusted path and sessions, and Hemera's
  std/fonts, canvas and ui) found, and these were fixed:
  - High: the compositor mapped whatever memory a client gave for a buffer. Paged memory, the client its pager, could
    stop it whenever a page wasn't there, every window with it; memory the client still owned could be destroyed
    under the mapping, a fault it can't catch. The kernel's new `memory_kind` says what memory is, and a buffer is
    anonymous memory by its owning handle (`memory_holders`) or Unsupported. Only what the image uses is mapped.
  - High: closing a GUI session's launcher left its terminal windows and their shells running for whoever logged in
    next. The greeter ends the session (EndSession) before showing the login window again.
  - High: the greeter's password field kept undo steps, so Ctrl+Z after the next login window came up brought back the
    last password but for its last character. A secret field keeps no undo and wipes the copies its edits make;
    stop_editing wipes what undo kept; the greeter drops the window's focus and editing after each try.
  - High: a composite glyph could name the next many times through eight levels, a hang or gigabytes: at most 256
    components and 2^18 points a glyph. Medium: GPOS kern features naming lookups over and over took billions of steps
    to open (at most 4096 indices); NaN or infinite points reached float-to-int casts in the rasterizer, near-endless
    loops (edges with a NaN end dropped, coordinates clamped to 2^24, text sizes checked); a stroke's dashes and round
    joins could make gigabytes of polygons (at most 2^22 points).
  - The powerbox's prompts in the trusted layer kept the last ask's focus, so the next Enter typed elsewhere could
    answer a new ask: focus is dropped for each. A debugging or network ask now shows what it'd grant (the program,
    the rules), apart from the program's own words. A new file's name is one name, no / or control characters, and
    the home's `grants` folder, the powerbox's kept grants, isn't offered.
  - A program's powerbox name is a plain name (letters, digits, _ - .), so it can't reach outside `grants/<name>`.
  - The compositor takes at most 32 of a client's requests a pass, so one can't starve the others or the trusted
    layer; a window takes focus only the first time it's shown, not each time it's shown again; only the focused
    window's client copies. A session holds at most half of the session manager's finding connections. The
    framebuffer display checks the firmware's pitch and sizes. A form's values go bare only as letters, digits and
    _ . / : + @ -, and not as a keyword; anything else is quoted.
- **Left open, for the project's owner**:
  - A program's powerbox name is still what the shell, or any program with a finding connection, says it is, so a
    program can ask as another and Reopen what the user let that one keep. Naming it by the program the session
    manager or the shell actually launched needs the launch to say so; the shell launches programs itself.
  - A new window still takes focus when it's first shown, with no gesture: a client can make windows to take the
    keyboard. Activation tokens (`display.md` *Also proposed*) would close it.
  - Clients and windows are shared: one client can take all 16 of the compositor's client places (Connect) or
    windows, and the trusted layer's next prompt connection is refused. Places per client, and some kept for the
    trusted listener, are needed.
  - The session manager and the powerbox wait on each other with no deadline (powerbox_for; the powerbox's locate and
    attach), so a program racing both could hang every session. Asynchronous requests, as the SSH service's became,
    would fix it.
  - A prompt can be asked as often as a program likes, and shows at once; it ignores no input just after it's shown.
  - Float-to-int casts of NaN, infinities and out-of-range values are LLVM's poison: Hemera could define them, as
    saturating (`fptosi.sat`, NaN to 0), at some cost in the canvas's per-pixel code.
  - Lower: the terminal service draws the console even if TakeBack wasn't delivered; a dropped Borrow could make the
    compositor the seat's reader; the viewer's decode of a hostile typed file has no total budget; the terminal
    window draws the input line without safe_text; a wheel and a release can reach a client's window while the
    trusted layer's shown.
