# 0196: M17, Audio, Planned

Status: accepted, chosen with the project's owner (2026-11-22); not started
Date: 2026-11-22
Related: `0072` (audio after display), `0037` (budgets, lending), `../design/scheduling.md` (soft real-time, latency),
`../design/display.md` §7 (audio), `0192` (M15), `0193` (M16), `0195` (M18, after this)

## Context
The roadmap's M17: virtio-sound and an audio service mixing clients' streams on a high-priority budget of short
periods; the soft real-time goal measured, no underruns with every CPU saturated by other budgets; the microphone as a
powerbox capability, shown on the trusted path while held. What's there (2026-11-22):
- **QEMU** has `virtio-sound-pci` on both machines, and audio backends among them `wav`, which writes what's played
  to a file the host can check, and `none`, whose capture is silence.
- **The scheduler**: budgets of any period and priority (`cpu_budget_create`), replenished by the sporadic-server rule;
  ticks at 100 Hz, but deadlines program each CPU's timer exactly, and a wake of a higher priority on another CPU is
  an IPI. The latency test `scheduling.md` asks for, a `cyclictest`, isn't built.
- **Hemera's std** has nothing for audio: no sample formats, mixing, resampling or files of sound.
- **Under TCG** a guest's CPUs run as fast as a busy host lets them, while the device plays at the host's real time:
  a boot test counting the device's underruns would count the host's load as much as SlopOS's.

## Proposal
- **17a, latency first.** A boot test in the spirit of `cyclictest`: a thread on a high-priority budget of a 2 ms
  period wakes on deadlines while every CPU runs lower-priority budgets flat out, and reports its worst and 99.9th
  percentile lateness, on both architectures; what it finds fixed (long non-preemptible sections, a missed IPI). The
  number to hold set from what it measures.
- **17b, sound in Hemera's std** (`std/audio`): sample formats (16-bit and 32-bit integers, 32-bit floats) and their
  conversions, interleaved and planar; mixing with gain and clipping, in the vector lanes; a resampler (polyphase,
  windowed sinc) between 44.1, 48 and 96 kHz; WAV files read and written. Hosted tests against known signals, and a
  fuzz target for WAV.
- **17c, virtio-sound and the `audio` device-class protocol.** The driver: the device's jacks, streams and channel
  maps, its PCM streams' rings, playback and capture. The protocol: a stream's format, rate and period, and frames
  through shared memory. A boot test plays a tone through QEMU's `wav` backend, which the host reads: its frequency,
  its level, no gaps.
- **17d, the audio service.** Clients open streams on a `sound` protocol, each a ring in shared memory and a format;
  the service converts and resamples each to the device's and mixes them, on a high-priority budget of a few
  milliseconds' period, lent by each client for its stream (`0037`). A client that falls behind is played as silence,
  its own underrun, never the others'. Volume per stream and for the session. A boot test mixes two clients' tones.
- **17e, the soft real-time goal measured.** Playback while every CPU runs lower-priority budgets flat out: the
  service's own count of periods it missed, against the guest's clock, must be zero, on both architectures; the
  device's underruns too where the host doesn't skew them (below).
- **17f, the microphone.** Capture as a powerbox capability the user grants a program, on the trusted path; while a
  program holds it, the identity band and the console's status line say so, and the user can take it back. A boot test
  captures (silence, from `none`), shows the indicator, and revokes.
- **17g, programs.** `play` and `record` in the shell, for WAV files; sound as typed data the viewer plays; the
  session's volume in the trusted layer.
- **17h, a security review and the full suites.**

## Chosen with the owner (2026-11-22)
- **Underruns under TCG**: the test that must be zero counts the audio service's own missed periods, against the
  guest's clock, on both architectures; the device's underruns are checked through KVM in the Linux VM, where the
  guest's CPUs keep the host's pace.
- **Hemera's std** has the formats, mixing, resampling and WAV (`std/audio`), as it has fonts and the canvas.
- **The device's format**: one fixed format the service mixes into, 48 kHz stereo 32-bit float.
- **17g** as proposed: the shell's `play` and `record`, sound in the viewer, and the session's volume in the trusted
  layer.

## As Built: 17a, latency
- **`test_latency`**, a test program the root task gives the root CPU budget: a thread on a budget of priority 250, a
  quarter of a CPU every 2 ms, waits for 1500 deadlines 2 ms apart on a port with nothing bound, and logs its worst,
  99.9th percentile and median lateness: with the CPUs idle, kept to the boot CPU, kept to CPU 1, and while a spinner
  on a priority-10 budget of nearly every CPU runs on each. On both architectures under TCG, and on x86-64 through KVM
  in the Linux VM (`KVM_TESTS`).
- **What it measured** (2026-11-22), in microseconds:

  | | TCG x86-64 | TCG AArch64 | KVM x86-64 |
  |---|---|---|---|
  | idle: worst, 99.9th, median | 1689, 1672, 775 | 1725, 1650, 816 | 1737 to 72008, 1518 to 70097, ~360 |
  | under load | 1596, 1585, 907 | 1537, 1520, 968 | 611 to 1508, 585 to 1484, ~277 |

- **What it says of the kernel, and what of the hosts.** Under TCG, lateness is spread evenly to about 1.7 ms, idle or
  loaded: QEMU's timers on Windows fire as the host's wakes let them. Through KVM the median is the Linux VM's own (a
  loop sleeping 2 ms in it: median 355 to 441, worst 1418 to 8619), and the idle CPU 1's worst ran to tens of
  milliseconds; kept ticking (a diagnostic `always_tick`, since removed), it still went 15 to 50 ms without its own
  ticks, so the stall is the halted virtual CPU's, under VMware, not the tickless idle's. Under load, nothing halted,
  every wake came within 1.5 ms. No kernel latency showed that the hosts don't make; neither can show the kernel's
  finer than about a millisecond.
- **So the test holds** what can fail: no wake early, and under load 999 wakes in 1000 within 5 ms, half a tick, which
  a wake that waited for a tick, its IPI missed, wouldn't make. The idle numbers are logged. The mixer's period and its
  buffer (17d) are chosen against these: at least 2 ms of slack beyond its period under TCG.
