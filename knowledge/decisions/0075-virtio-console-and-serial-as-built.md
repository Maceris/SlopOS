# 0075: virtio-console and the Serial Protocol as Built

Status: accepted
Date: 2026-10-24
Related: `0070` (the plan for M7), `0074` (7c: the platform service, drivers' bundles), `../design/console-and-sessions.md`
(M10's terminal service), `../../docs/specs/programs.md`, `../roadmap.md` M7

## Context
M7's fourth stage (7d): virtio-console and the `serial` device-class protocol (`0070`). The terminal service and its
VT adapter, which a serial line is for, come in M10. Asked here: what uses the console until then (a small console
service, which services log lines to and which echoes what's typed, rather than a test program only, or the kernel's
log forwarded); the protocol's shape (a Write, and a Read the driver holds until bytes arrive, rather than input
pushed unasked); and how clients reach a driver the supervisor starts per device (the driver listens and the
supervisor connects them, rather than the platform service keeping a directory).

## Decision
As asked, built:
- **The `serial` protocol** (`src/protocols/serial`): `Write(bytes)`, answered with `Written(count)`; `Read(most)`,
  answered with `Data(bytes)` once at least one byte has arrived, held by the driver until then; `Features`, answered
  with `Line(speed)` (0 for a virtual console); `Connect`. At most 256 bytes a message, so one fits the default 1 KiB
  ring.
- **Drivers that serve clients** take `clients: Listener[P]`. The supervisor makes the channel when it launches the
  driver and keeps the other end, through which it connects the services that use the driver; `system_config`'s
  wiring check sees the driver as `P`'s server as it does any service with a listener. The supervisor now starts the
  drivers first, then the services that need them.
- **`virtio_console`** (`src/drivers/virtio_console`): its device's first port, without multiport, its receive queue
  always holding four 256-byte buffers, whose bytes wait in its input until a held Read takes them; its transmit queue
  sending one buffer at a time, waited for; one MSI-X vector for both. The BAR mapping drivers share moved to
  `src/driver_kit`.
- **The console service** (`src/services/console`) and its `console_log` protocol (`Line`, answered with nothing;
  `Connect`): given the first serial line, it shows a line break and its banner, `SlopOS console`, then each client's
  lines, and keeps a Read outstanding, writing each line typed into it to its debug log and echoing it back. hello is
  its first client, given a connection by the supervisor.
- **Testing the console**: QEMU's file backend can't be typed into on Windows, so `tools/boot.py` links a virtio
  console to a TCP socket on the loopback (`--console-input`, `--expect-console-line`): it connects, waits for the
  banner, types its lines, and checks what the console shows. The boot test sees hello's line and the echo on both
  architectures. On AArch64, the firmware uses the same console first, which is why the banner starts after a line
  break.

## Alternatives considered
- **A test program only**: the least to replace in M10, but the console would do nothing at boot.
- **Forwarding the kernel's log**: useful without a serial port, but the kernel's lines would go through user space twice.
- **Pushed input**: lower latency, but the protocol would need messages no one asked for, which generated code doesn't
  model yet.
- **A directory in the platform service**: several consoles and hot-plug later, but it makes the platform service a
  name service too.

## Consequences
- M10's terminal service takes the console service's place, and the VT adapter speaks `serial` the same way.
- One serial line is used, the first a driver offers; a second virtio console gets a driver, with no clients.
- A client's Writes are sent in order, one at a time, so a slow line holds up the driver's other clients.
