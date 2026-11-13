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
