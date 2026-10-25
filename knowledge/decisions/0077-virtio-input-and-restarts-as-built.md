# 0077: virtio-input, Connectors and Driver Restarts as Built

Status: accepted
Date: 2026-10-25
Related: `0017` (supervision and reconnection), `0070` (the plan for M7), `0074` (drivers' bundles), `0075` (drivers
that listen), `0076` (virtio-blk), `../../docs/specs/programs.md`, `../roadmap.md` M7 and M9

## Context
M7's last stage (7f): virtio-input and its `input` device-class protocol, and the supervisor restarting a driver that
crashes (`0070`). `0017` has clients of a restarted service reconnect; until now the supervisor gave them connections
straight to a driver, which would go with it. Asked here: what an input event is (SlopOS's own typed events, rather
than evdev's triples passed through, or text); what uses the keyboard in 7f (the console, through a US keymap, tested
by boot.py typing through QEMU's machine protocol); what a restart does with the device (the platform service
reissues it, rather than the supervisor keeping the device's handles, or the driver's ending reset nothing); and how
clients reconnect (they redial a connector the supervisor serves, rather than the supervisor handing them new
connections, or clients going without).

## Decision
As asked, built:
- **The `input` protocol** (`src/protocols/input`): an `Event` is a kind (`Key`, `Motion`, `Position`, `Button`,
  `Wheel`), whether it's pressed, a code and x and y; a key by its USB HID usage (page 7), a button from 0 for the
  left. `Read` with the most to take, held until there's at least one, is answered with `Events` (up to 32); `Connect`.
  Every client sees every event from when it connected. A Relative's elements are plain data, so `Event` stores its
  kind as an `EventKind`'s `u8` and pressed as 0 or 1, read through `kind_of` and `is_pressed`, made with `event_of`.
- **`virtio_input`** (`src/drivers/virtio_input`): the event queue's 32 buffers always offered; evdev keys 0 to 127 to
  HID usages by a table, `BTN_LEFT` to `BTN_TASK` as buttons, `REL_X`/`REL_Y` as motion, `REL_WHEEL` as the wheel,
  `ABS_X`/`ABS_Y` as a position with both axes; `SYN` and the rest dropped. Events wait in a ring of 64, each client
  its own place in it; one a whole ring behind skips to the oldest.
- **The console** takes the first keyboard as well as the first serial line: shift, letters, digits, punctuation, space,
  Enter and Backspace, for a US layout, into the same line its serial input goes to.
- **Connectors** (`src/protocols/connector`): `Dial`, answered with `Dialed` and a new connection to what the connector
  reaches, or `Unavailable`. The supervisor serves every connector, one channel each, and dials through the current
  listener of what it reaches with that protocol's `Connect`; `connector.dial[P]` retries every 100 ms while it's
  unavailable, up to 50 times, and checks the connection speaks `P`. The console has connectors to the first serial
  line and keyboard, hello one to the console, the disk check one to the first disk. `system_config`'s wiring check
  counts the supervisor as connectors' server (`SUPERVISOR_SERVES`).
- **Restarts**: the supervisor watches what it started; a driver that ends other than by exiting with 0 is started
  again, up to 3 times in a minute: the platform service's new `Reissue`, with the device's address, gives the one that
  claimed it a new bundle (its old objects were the driver's, and went with it), and the driver is launched with it
  and a new listener in the same place among what's started, reported to the root task as started again.
- **Tests**: boot.py adds a virtio keyboard and types on it through QMP (`--keyboard-input`), and types its i-th
  console line at the console's i-th banner; `test_restart` has the supervisor kill the console's driver once the
  console has dialed it and had half a second to show its banner, and report everything started only once the driver
  is back and dialed again. Both run on both architectures: the console echoes what's typed on the keyboard, and the
  line typed after the restart.
- **Found on the way, fixed**:
  - A channel raises `SIGNAL_READABLE` only for a reader that has found it empty, so the supervisor reads each
    connector once when it's made, as servers read their clients before they wait; until then no Dial woke it.
  - The process manager's `Load` took 12 grants, and the supervisor now has 13: it takes 16.
  - Killing a running process takes its memory while its threads may still run on another CPU, which then fault;
    the kernel no longer reports a fault in a thread of a process being destroyed.
  - Hemera: an untyped string constant's `.count` was refused, though it could be indexed (the compiler fix, with a
    test in `string_cases`).

## Alternatives considered
- **evdev passed through**: no table in the driver, but every client would know Linux's codes, and no other driver's.
- **Text from the driver**: a keymap in every keyboard driver, and nothing for a pointer.
- **The supervisor keeping the device's handles**: no Reissue, but a driver's objects outliving it, holding DMA memory
  and MSIs the next driver makes anew anyway.
- **The supervisor handing out new connections**: it would need every client's channel to push them on, and a client
  mid-request couldn't tell which connection answered.

## Consequences
- M7 is complete. M9's events service and the supervisor's wider restart policy (`0017`) build on connectors: a
  restarted service other than a driver is reached the same way, once the supervisor restarts it.
- A client's request in flight when its driver dies is lost; the client learns from its connection's end, and asks
  again on the new one. The block protocol's tags make that safe for reads; a write in flight may or may not have
  happened, which M8's storage stack has to allow for.
- M10's terminal service replaces the console's keymap with layouts of its own.
