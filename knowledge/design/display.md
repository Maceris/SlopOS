# Display, Input and Audio

Status: **proposed** 2026-10-24, for roadmap M15 and M16. Builds on `../decisions/0018` (the powerbox's GUI front
end), `0043` (the trusted path), `0037` and `scheduling.md` (soft real-time), `console-and-sessions.md` (the input
service and the secure attention key) and `../problems-and-directions.md` §15. The choices still to make are at the
end and in `../open-questions.md`, *Display and audio*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Any client can read every keystroke and every other window's pixels, and inject input | X11 | Clients see only their own surfaces and get input only when focused (§3) |
| Isolation first, then years without screen sharing, global shortcuts, colour pickers or clipboard managers, until portals were added | Wayland | Capture, global shortcuts, input injection and clipboard history are powerbox capabilities from the start (§4) |
| Any app reads the clipboard whenever it likes (exposed by iOS 14's paste notices) | Every desktop and phone | Paste delivers the clipboard to the focused client on the user's gesture only (§4) |
| Apps draw lookalike system dialogs and fake address bars | Every GUI | A band on every window drawn by the compositor, naming its program; a layer only the trusted services draw on (§5) |
| Accessibility is a separate bus added later, with access to everything | AT-SPI, UI Automation | Accessibility is a capability with its own protocol, granted to the assistive program (§4) |
| Audio glitches under load because the mixer competes with everything else | Desktop Linux before PipeWire's real-time scheduling, others | The mixer has a budget of short periods at high priority (`0037`), and that is measured (§7) |
| The microphone or camera is in use without the user knowing | Desktops before indicators | Capture is a powerbox capability, shown on the trusted path while held (§7) |

## 2. Processes

```
 clients ── Surface ──► compositor ── display ──► virtio-gpu driver
                            ▲
 input devices ── input ──► input service (seat, secure attention key) ──► compositor or terminal service
```

- **virtio-gpu** in 2D mode speaks the `display` protocol: modes, scanout buffers in shared memory, flushes of damaged
  rectangles, and a vsync event where the device gives one.
- **The input service** (M10) owns the seat: it routes keyboard and pointer events to whichever of the terminal
  service and the compositor has the seat, and recognizes the secure attention key before either.
- **The compositor** composites clients' surfaces in software, with SIMD (AVX2 on x86-64-v3, NEON on AArch64), and owns
  the GUI's trusted path. GPU acceleration is out of scope.

## 3. Surfaces

- A client creates a surface by giving the compositor a memory object it draws into; it submits a frame with its
  damage, and the compositor answers when the buffer can be reused and when the frame was shown (presentation
  feedback, so animation can pace itself).
- Input reaches a surface only while it has focus or the pointer is over it, and only events for it.
- The compositor runs on a budget of its own at a high priority (`0037`), so a busy client can't make the pointer
  stutter.

## 4. Capabilities in the GUI

Each is asked for through the powerbox and granted by the user on the trusted path:

| Capability | Gives |
|---|---|
| `ScreenCapture` (a window, or the screen) | Frames of what was chosen |
| `GlobalShortcut(keys)` | Those keys while the client isn't focused |
| `InputInjection` | Synthetic input, for remote desktops and automation |
| `Accessibility` | The accessibility tree of every surface, and acting on it |
| `ClipboardHistory` | Every copy, for a clipboard manager |

- **Copy** offers typed data (a schema hash and representations); **paste** is a gesture the compositor sees (the
  key, the menu item) and answers by delivering the clipboard to the focused client. Drag and drop is the same, on
  drop.

## 5. The Trusted Path in the GUI

- **The identity band**: every window has a strip drawn by the compositor with the program's name and its
  connection's label (`0014`), which the client can't draw over or style.
- **The trusted layer**: the powerbox's dialogs (the file chooser, permission prompts), login and the lock screen
  are drawn in a layer above every client's, by those services' own surfaces, and the secure attention key brings it
  forward.
- Prompts for capture and the microphone stay visible in the trusted layer while the capability is held.

## 6. Text and the UI Library

- **Fonts:** a TrueType rasterizer (quadratic outlines, hinting off, anti-aliased coverage), OpenType's `cmap`,
  `hmtx` and `kern`/`GPOS` pair kerning; CFF outlines later.
- **Shaping:** Latin and other scripts without complex shaping first; bidirectional text (UAX #9) and complex scripts
  later, documented as missing.
- **The UI library** lays out and draws the widgets the first programs need, and generates a form from a manifest,
  as the shell generates a command line from one (`shell.md` §8).
- **Programs:** a terminal emulator speaking the terminal protocol (`console-and-sessions.md` §2), the typed-data
  viewer, a launcher, the powerbox's chooser.

## 7. Audio (M16)

- **virtio-sound** and an `audio` device-class protocol: streams of PCM frames through shared rings, with their
  formats and rates in `Features`.
- **The audio service** mixes clients' streams into the device's, on a budget with a short period (a few
  milliseconds) at a high priority, and with lending (`0037`) so a client pays for its stream's mixing.
- **Measured:** a boot test plays a stream while every CPU runs budgets of lower priority flat out, and counts
  underruns, which must be zero; that's the soft real-time goal of `scheduling.md` made a test.
- **Capture** is a powerbox capability, shown on the trusted path while held.

## Also Proposed (`lessons.md` §8, 2026-10-30)

Decided when M15 and M16 are planned:
- The lock screen in the trusted layer, so a crashed locker leaves the screen locked.
- Focus moving only on the user's gesture or with an activation token from the focused client.
- Notifications as a capability per installation, rate-limited and listed with the session's grants.
- Surfaces declaring a scale from the first protocol version; the UI library laying out in logical units.
- A boot test of input-to-photon latency, as the audio test counts underruns.
- Fonts and images decoded in processes holding nothing else (§9.4).

## 8. Open Questions

- Whether the identity band is always on, or only on windows that ask for input (a video player full screen).
- How much of the UI library belongs in Hemera's `std` (fonts and rasterizing are general-purpose) and how much in
  SlopOS.
- Whether text and fonts come earlier, for the framebuffer console's Unicode coverage in M10.
