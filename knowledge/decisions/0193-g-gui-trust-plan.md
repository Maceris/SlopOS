# 0193: G, Trust in the GUI, Planned

Status: proposed, for the project's owner (2026-11-21)
Date: 2026-11-21
Related: `0192` (M15, its security review and *Settled after M15*), `0181` (the powerbox's names), `0185` (debugging
and elevation), `0191` (the SSH service's asynchronous requests), `0186` (H, the fuzzers), `../design/display.md`
(*Also proposed*: activation tokens), `../roadmap.md`

## Context
M15 built the GUI, and its security review (0192, *As Built: 15h*) fixed what was high but left what needed a
decision. The project's owner settled those on 2026-11-21 (0192, *Settled after M15*), and asked for what needed
investigating to be investigated first, then for the rest planned together as a milestone. This is that plan. It
comes before M16 (audio), as audio's programs would be GUI programs and would inherit what's open here.

## What the investigation found
- **The compiler's M15 items:**
  - *An assignment's right side runs first*: already settled. `docs/operators.md` says so, and the compiler warns of
    the one shape that bites, a call on each side given the same `&out` (W4003, with a front-end test). Nothing to do.
  - *`-O0` crashes LLVM*: three SlopOS targets (ssh, ssh_service, volume_server) crash at `-O0`, two in instruction
    selection's `insertvalue`, one in the DAG combiner. A twenty-line program reproduces it: a struct literal holding a
    64 KiB array, assigned through a pointer into an array's element (`holder.bigs[i] = Big.{count = 1}`). Hemera builds
    the literal as one aggregate value and stores it whole; LLVM's selection DAG flattens it to 65,564 operands, past
    the 65,535 a node holds. At `-O2`, SROA turns it into stores first, so only `-O0` sees it. Fix: lower a literal
    assigned to a place as stores into the place (zeroing what it doesn't name), never as a whole value past a size.
  - *The "ID-alias bug"* is a type inference bug, not an alias one: an untyped constant in the first branch of an
    `if` or `match` expression is fixed as `int` before the other branches are seen, so
    `if c { 0 } else { id }` is an error where `if c { id } else { 0 }` isn't. std/ui writes `cast[u64](0)` for it.
    Fix: an if's or match's branches find their type together, an untyped constant taking the others'.
  - *Compile-time UI IDs*: not worth a compiler feature. `ui.key("Save")` is already a compile-time constant
    (`#run`); widgets hash their labels as they're drawn, a short loop per label, microseconds a frame. With the
    inference fix, std/ui's casts go; nothing else is needed.
- **The flaky tests**, soaked: 10 rounds of the memory and restart tests among load, then the whole boot suite three
  times. Neither the AArch64 large-page test nor the storage manager's crash recurred (and a crash now logs where).
  Two others failed once each, among the others, passing alone:
  - *Kills services at random* (AArch64): accounts and the terminal service failed to start again with BadGrants
    for as long as the test ran, as what grants them was itself being started again, and the supervisor's budget was
    ~600 KB more after than before. A real ordering problem in starting a service again while what it's granted from
    is down.
  - *Boots degraded*: QEMU ended without the kernel's exit code, 9 s in, just after the test killed hello.

## Decision
A lettered milestone, **G**, between M15 and M16: what 0192 settled, the compiler's fixes, and the flaky tests
found, in seven stages, with a security review and the full suites at the end.

## Stages
- **Ga, Hemera's fixes.**
  - Float-to-int casts saturate (out of range to the type's least or most, NaN to 0, as `fptosi.sat`), documented in
    `operators.md`, with an explicit unchecked conversion (an intrinsic) for code that proves its range; the canvas's
    hot paths moved to it where they already clamp.
  - An `if`'s or `match`'s branches typed together, an untyped constant taking the others' type; std/ui's casts gone.
  - A struct or array literal assigned to a place lowered as stores into it, so `-O0` builds every SlopOS target; a
    hosted test builds the reproduction at `-O0`, and SlopOS's build at `-O0` is run once a stage.
- **Gb, names from the launch.**
  - The process manager records what each process was launched from (its installation's name and bundle), and the
    session manager, for its programs, knows it too.
  - A powerbox connection is named by that: the shell asks for a child's with the child's process handle, not a name,
    and the powerbox's kept grants are under that name, so a program can't ask as another.
  - The identity band shows the program's name first, then its title: the session manager names each GUI program's
    compositor connection as it starts it, and the compositor draws the name in a style a title can't imitate.
- **Gc, no service waiting on another that waits on it.**
  - The session manager and the powerbox send their requests to each other and take the answers as they come, keyed
    by request, as the SSH service does with the account service (0191): Serve, locate and attach.
  - The supervisor's start of a service whose grants come from one being started again: waited for in order rather
    than retried with BadGrants, and its budget given back whole (the chaos test's findings).
- **Gd, the compositor's places and focus.**
  - A client and the connections it makes hold at most 4 connections and 8 windows; 4 of each are kept for the
    trusted listener's clients.
  - Activation tokens: the compositor gives one for a user's gesture (a click, a key), the launcher hands the one for
    the click that started a program to it, and the focused client may pass one on. A new window takes focus only
    with a token not yet used and under a few seconds old; otherwise it's shown unfocused, its band marked as wanting
    attention.
- **Ge, the trusted layer's prompts and elevation.**
  - A prompt ignores input for about 400 ms after it's shown, and keys already held down when it appeared.
  - A program asks at most a few times a minute (3, refused asks counting double); the rest are refused unasked and
    logged.
  - The administrator asked in the GUI's trusted layer, as the console's elevation screen asks: accounts, shutting
    down and restarting, traces, and keys. The name and password in a secret field, nothing kept to undo.
- **Gf, shared fonts and typed paste.**
  - Fonts as read-only objects from the bundle store, mapped by each GUI program, rather than embedded in each;
    std/fonts reads them where they're mapped, as it reads any bytes.
  - Paste offers the copy's typed data to a client that takes it (the viewer, a typed field), its text to the rest.
- **Gg, a security review and the full suites**: the review of what G changed (names, tokens, places, the asynchronous
  requests, elevation in the GUI); the fuzz targets, the canvas's widened to transforms, infinities and the fast
  paths; the boot suite run three times, for the flaky tests; HemeraTest, the Linux tests and the unit tests.

## Alternatives
- **Fold all of this into M16**: audio would wait on GUI work it doesn't need, and the review of each would be
  harder.
- **Only the security items, the features later** (shared fonts, typed paste, GUI elevation): smaller, but GUI
  elevation is what keeps a GUI user from needing the console, and the fonts' memory is felt with every GUI program.
- **Compile-time constant folding for UI IDs**: a compiler feature for microseconds a frame; not taken (above).
