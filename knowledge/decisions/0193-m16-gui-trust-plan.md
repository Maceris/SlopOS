# 0193: M16, Trust in the GUI, Planned

Status: accepted, chosen with the project's owner (2026-11-21); built 2026-11-22, 16b as the simpler fix, its full fix
M18 (`0195`)
Date: 2026-11-21
Related: `0192` (M15, its security review and *Settled after M15*), `0181` (the powerbox's names), `0185` (debugging
and elevation), `0191` (the SSH service's asynchronous requests), `0186` (H, the fuzzers), `../design/display.md`
(*Also proposed*: activation tokens), `../roadmap.md`

## Context
M15 built the GUI, and its security review (0192, *As Built: 15h*) fixed what was high but left what needed a
decision. The project's owner settled those on 2026-11-21 (0192, *Settled after M15*), and asked for what needed
investigating to be investigated first, then for the rest planned together as a milestone. This is that plan. It
comes before audio, now M17, as audio's programs would be GUI programs and would inherit what's open here.

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
**M16**, before audio, which becomes M17 (the owner chose a number over a lettered milestone): what 0192 settled,
the compiler's fixes, and the flaky tests found, in seven stages, with a security review and the full suites at the
end.

## Stages
- **16a, Hemera's fixes.**
  - Float-to-int casts saturate (out of range to the type's least or most, NaN to 0, as `fptosi.sat`), documented in
    `operators.md`, with an explicit unchecked conversion (an intrinsic) for code that proves its range; the canvas's
    hot paths moved to it where they already clamp.
  - An `if`'s or `match`'s branches typed together, an untyped constant taking the others' type; std/ui's casts gone.
  - A struct or array literal assigned to a place lowered as stores into it, so `-O0` builds every SlopOS target; a
    hosted test builds the reproduction at `-O0`, and SlopOS's build at `-O0` is run once a stage.
- **16b, names from the launch.**
  - The process manager records what each process was launched from (its installation's name and bundle), and the
    session manager, for its programs, knows it too.
  - A powerbox connection is named by that: the shell asks for a child's with the child's process handle, not a name,
    and the powerbox's kept grants are under that name, so a program can't ask as another.
  - The identity band shows the program's name first, then its title: the session manager names each GUI program's
    compositor connection as it starts it, and the compositor draws the name in a style a title can't imitate.
- **16c, no service waiting on another that waits on it.**
  - The session manager and the powerbox send their requests to each other and take the answers as they come, keyed
    by request, as the SSH service does with the account service (0191): Serve, locate and attach.
  - The supervisor's start of a service whose grants come from one being started again: waited for in order rather
    than retried with BadGrants, and its budget given back whole (the chaos test's findings).
- **16d, the compositor's places and focus.**
  - A client and the connections it makes hold at most 4 connections and 8 windows; 4 of each are kept for the
    trusted listener's clients.
  - Activation tokens: the compositor gives one for a user's gesture (a click, a key), the launcher hands the one for
    the click that started a program to it, and the focused client may pass one on. A new window takes focus only
    with a token not yet used and under a few seconds old; otherwise it's shown unfocused, its band marked as wanting
    attention.
- **16e, the trusted layer's prompts and elevation.**
  - A prompt ignores input for about 400 ms after it's shown, and keys already held down when it appeared.
  - A program asks at most a few times a minute (3, refused asks counting double); the rest are refused unasked and
    logged.
  - The administrator asked in the GUI's trusted layer, as the console's elevation screen asks: accounts, shutting
    down and restarting, traces, and keys. The name and password in a secret field, nothing kept to undo.
- **16f, shared fonts and typed paste.**
  - Fonts as read-only objects from the bundle store, mapped by each GUI program, rather than embedded in each;
    std/fonts reads them where they're mapped, as it reads any bytes.
  - Paste offers the copy's typed data to a client that takes it (the viewer, a typed field), its text to the rest.
- **16g, a security review and the full suites**: the review of what M16 changed (names, tokens, places, the asynchronous
  requests, elevation in the GUI); the fuzz targets, the canvas's widened to transforms, infinities and the fast
  paths; the boot suite run three times, for the flaky tests; HemeraTest, the Linux tests and the unit tests.

## Alternatives
- **Fold all of this into audio's milestone**: audio would wait on GUI work it doesn't need, and the review of each would be
  harder.
- **Only the security items, the features later** (shared fonts, typed paste, GUI elevation): smaller, but GUI
  elevation is what keeps a GUI user from needing the console, and the fonts' memory is felt with every GUI program.
- **Compile-time constant folding for UI IDs**: a compiler feature for microseconds a frame; not taken (above).

## As Built: 16a
- **Float-to-int casts saturate** (Hemera's `docs/operators.md`): LLVM's `fptosi.sat` and `fptoui.sat`, so past the
  type's range it's the type's least or most, an infinity too, and NaN is 0; vectors lane by lane; at compile time as
  at run time, since compile-time code is generated the same way. `intrinsics.to_integer_unchecked[T](x)` is the
  plain conversion. The canvas's scenario took 15.5 s against 15.2 before, within its noise; its per-pixel `channel`,
  which clamped by hand, is the cast alone now, as the cast clamps the same way.
- **Branches find their type together** (`docs/control_flow.md`): an untyped constant in an `if`'s branch or a
  `match`'s arm takes the type another gives, wherever it's written; alone, the widest's. std/ui's four
  `cast[u64](0)` are gone.
- **`-O0` builds every SlopOS target**: storing a large literal a part at a time (memset and the parts) left the
  `insertvalue` chain it had been built as unused, which `-O2` deletes and `-O0`'s instruction selection still visited;
  it's taken away now. Every target builds at `-O0` in 24 s.
- Tests: hosted `float_casts` and `large_literals`, each optimized and at `-O0`, on Windows and both Linux
  architectures; a front-end scenario of branches' types. HemeraTest 299 of 299.

## As Built so far: 16b
- **The identity band names the program** (the surface protocol's `Name`): a connection's client named only by its
  first request, from whoever dialed the compositor; the session manager names each GUI program's connection, the
  launcher's among them, before the program has it. A second `Name`, or one after another request, is refused and
  logged; a connection a client makes with `Connect` has its name, while one made on a listener is its dialer's to
  name. The band draws the name dark on a light box, which no title can draw, then the title.
  `boot.py` keeps a run's screenshots where `SLOPOS_SAVE_SCREENS` says, which showed it.
- **Waiting on a decision**: naming a powerbox by the launch. Nothing tells the session manager which program a process
  runs: the shell makes the process and the process manager loads it, its name "for the log only", and no system
  call says whether two handles are one object. Either the session manager launches every program, as it does GUI
  programs (`Start`), or the kernel identifies objects and the process manager says what it loaded where. The owner
  chose the second (2026-11-21): a system call saying whether two handles are one object, and the process manager
  recording what it loaded into each process; the rate limit to be keyed by it too.

## As Built: 16b, the powerbox's names
- **`handle_same`**, the kernel's: whether two handles in the caller's table are to one object, any kinds, no right
  needed (std's `slop_os.handle_same`, appended to the system calls). `test_memory` checks it.
- **Working the owner's choice through found it doesn't hold alone** (2026-11-21): a name settled after the load needs
  proof the child alone holds its connection, as a launcher could copy the handle first, and the launcher keeps the
  child's process with every right, so it can intercept and steer the child named for what it runs. With the owner
  (2026-11-22): the full fix is a milestone of its own, M18 (`0195`), and 16b does the simpler one now.
- **Only shells name a powerbox's connections.** The session's own connection, a GUI shell's (`Finder.shell`), and the
  finding connections they make for their scripts' shells (`Connect`, passing on `Finder.names`) may ask `Powerbox`
  under a name; a GUI program's finding connection, the launcher's, a terminal window's, the viewer's, is refused,
  and it's logged. So each program has the one connection it was started with, named by the shell from the program
  it found, and can't ask under name after name, which the powerbox's limits, per name and the session's (16e, 16g),
  now count honestly; shells are trusted, as they control what they start.
- **Tests**: `test_finders`, in the installations' boot test, has a GUI program's kind of finding connection ask for a
  connection as files, which is refused. The scripts', chooser's, grants' and GUI login's tests pass as they did.

## As Built so far: 16c
- **The session manager and the powerbox stop waiting on each other**: the session manager sends `Serve` and gives the
  program its end at once, the powerbox's answers taken as they come; the powerbox sends `Locate` and `Attach` and
  goes on, its debugger's request waiting (others answered Busy), the answers taken in its main loop, which the
  session manager's connection now wakes.
- **The chaos test's restarts**: not reproduced yet. `os.launch` says why now, `NoCpuBudget` and `ProgramGone` apart
  from `BadGrants`, so the next failure names its cause; the supervisor's CPU budgets, asked of the scheduler service
  at each launch, are the likelier.

## As Built: 16d
- **Places**: a client, with the connections it makes by `Connect`, holds at most 4 connections and 8 windows; past
  them, a `Connect` is refused (its end closed) and a `CreateWindow` answered `Refused`, each logged. The compositor
  keeps 4 connections and 4 windows of its whole for the trusted listener's clients, the greeter and its prompt, which
  an ordinary client can't take.
- **Activation tokens** (the surface protocol's `Activation`, answered `Token`): the compositor gives the focused
  client a token for its last gesture, a click or a key, at most 2 s old; it's good for 5 s and once. The launcher
  hands the token for the click or Enter that started a program to it, through the session manager's `Start`, and
  gui_kit's `open_on` sends it with the first window. A first window with a good token, or shown when nothing's
  focused, takes focus; the trusted layer's always does; any other's shown unfocused, its band amber and "wants
  attention" logged, until it's clicked.
- Tests: the compositor test's B opens without a token and is clicked to focus; A makes four more connections, the
  last refused.

## As Built: 16e
- **The prompt's input guard**: for 400 ms after the prompt window's shown, what comes is dropped, and then "the
  prompt takes input" is logged, which the boot tests wait for. Keys held through it can't be told apart, as the
  compositor sends no releases; the 400 ms is the guard.
- **Asks rate-limited**: the powerbox keeps each program's credit by its name, 3 asks, refilled at 3 a minute; a
  refusal by the user costs one more, and an ask the user grants gives its one back, so a run of wanted asks (the
  chooser test's) isn't cut short. Past it, the ask's refused without the user and "asked too often" logged. The
  session manager's own connection, without a name, isn't limited. (Names are still the program's own until 16b's
  identity is settled.)
- **Elevation in the GUI** (the greeter's `elevation.hsc`): adding or removing one of the user's keys is Allow or
  Refuse, the key's fingerprint shown; a list's answered at once. A shutdown, a restart, a trace, the system's log, or
  another's program debugged takes the administrator's name and password, checked by the account service; an account
  takes those and the new account's name and password twice, then shows its recovery code once. The greeter has a
  power connection of its own for them (the supervisor's `GREETER_POWER`), the trusted path's like the console's, and
  the supervisor logs which asked. Every password's wiped once it's sent, the request's words too, and every field
  when the ask's done. The shell has `add-account`, as the console's echo has `adduser`.
- Tests: the GUI login test lists the keys, has bob's account made in the prompt, and shuts down from the GUI
  terminal's shell, a wrong password refused first.

## As Built: 16f
- **Shared fonts**: Noto Sans and Noto Sans Mono are objects in the bundle store, under their files' names
  (gui_programs' `FONTS`), put there by the store builder beside the programs. The session manager, and the supervisor
  for the greeter and test_gui, get each once and give every GUI program a read-only copy of the handle, beside its
  entry's grants (Hemera's `os.LaunchOptions.extra`, labels `font_sans` and `font_mono`); gui_kit maps them, and opens
  no window without them, which it logs. The store's paged memory is one object however many map it, so the fonts'
  pages are shared, and each GUI program's image is about 820 KB smaller (the viewer's 1.3 MB). A font got again when
  a copy can't be made, as after the store's restarted. The compositor still builds Noto Sans in, for its bands.
  test_gui's test boots from the disk now, as GUI programs need the store.
- **Typed paste**: a copy's typed data (its schema's hash and bytes, at most 1 MiB) is copied by the compositor to
  memory of its own, from anonymous memory the copier's handle owns only, so it can't change once copied, nor stall
  the compositor on a pager. A paste with typed data says so (`Paste`'s code 1), and only that client may take it
  (`TakePaste`), once, within 5 s, as a read-only handle; another client that takes the slot can't. gui_kit has
  `offer_typed` and `take_paste`. The viewer copies a typed value it shows with Ctrl+C, typed and as text, and shows a
  typed paste's value as it shows a typed file's.
- Tests: the compositor test's A copies typed data, which B takes once; the GUI login test copies a typed file's value
  in the viewer and pastes it back.

## As Built: 16g, the review
A review of M16's changes, by a reader who hadn't written them, found nothing high; what it found, and what's done:
- **The rate limit keyed by a name the program chooses** (medium-high): a program names its own powerbox connection,
  and can make more, so it could ask under name after name, keeping the user answering, or ask as the shell and spend
  the shell's credit. Now the session's asks are limited as a whole too, 6 in a row then 6 a minute, refusals double
  and grants given back, so no set of names keeps the user answering; at worst a program spends the session's asks
  for a minute. Keying the limit by who a program is, not what it says, waits on 16b's identity.
- **An activation token taken when a window was made, its focus when it's first shown** (medium): a window made with
  a token and shown minutes later took the keys. Now the token's time is kept, and it's good at first show only
  within its 5 s.
- **A key added on one click** (medium): a prompt in the GUI appears when a program asks, not when the user does, as on
  the console, so a click meant for something else could land on Allow once the 400 ms are past. Adding a key takes
  the user's own password now (the account service's OpenHome, its home closed at once). Removing one is still Allow.
  No boot test types it yet: the GUI's shell can't write a key's file without the editor, which says nothing to wait
  on.
- **A client's place reused** (low): its gesture's token could be asked for by the next client in its place, and the
  connections it made counted against that client. Both are let go of with it now.
- **The places kept for the trusted** (low): the listeners' places weren't counted, so 2 were kept, not 4; they are now.
- Left as they are, and why:
  - A launch whose request to the process manager couldn't be sent leaks its font handles: `ManagerGone` is both
    "not sent" and "sent, not answered", and closing a sent handle could close another's. Two handles a failed
    launch; a distinct error would need os.launch's errors split again. Wrong, found 2026-11-23 (`0197`, N3):
    `send` takes a message's handles out of the caller's table whether it's sent or not, so none leak.
  - Keys typed into the greeter pass through gui_kit's and the compositor's queues, which aren't zeroed. None is
    reachable by an untrusted program.
  - ListKeys answers without asking, as on the console: public keys, and their comments.
  - The greeter's fonts are the bundle store's memory, so without the store there's no GUI login; the store is what
    every GUI program's loaded from already.
- **Keys lost in a prompt**, found by the GUI login test failing once in a while: while something was asked the
  greeter waited on its hidden login window's port, and took the prompt window's input only every 50 ms, so typing
  fast filled the compositor's 64 events kept for it, and the rest were dropped ("isn't reading"). It waits on the
  prompt window's port while something's asked now. What the prompt says under its fields is logged too.
- **The canvas's fuzz target widened** (`draws_anything`, Hemera's canvas scenario): any transform, rotations and raw
  matrices of huge, NaN and infinite entries among them; clips, saved and restored; the fast paths (clear, fill_rect,
  fill_box); images, gradients, shapes and strokes of any join, cap and dashes; what's damaged on the image.

## As Built: 16g, the full suites
Run 2026-11-21: the boot suite three times, HemeraTest (299 passed), the Linux tests (83 of 83 on x86-64, 81 of 81 on
AArch64), the unit tests (25 of 25) and every fuzz target for 60 s (25, nothing found).
- **The session's asks, empty at the start**: the boot suite's runs failed the powerbox's tests, 2 to 4 a run, the
  first ask refused unasked ("the session's asked too often"). The session's credit started at zero, refilled for the
  clock's time since boot, a few seconds' worth when the session began, not full. It starts full now; the 16 tests
  that ask, on both architectures, passed after.
- **The system call fuzzer** failed once among the others, a fault of its own (a write to an unmapped address), and
  passed alone with the same seed: something its run depends on is timing. Not M16's; left to look into.
- Left: 16b's powerbox names, which wait on the owner's choice (*As Built so far: 16b*), and the chaos test's
  restarts, not reproduced in the three runs.
