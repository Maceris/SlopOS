# 0196: M17, Audio, Planned

Status: proposed (2026-11-22), for the project's owner to choose from; not started
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

## Questions for the owner
- **Underruns under TCG**: count the service's missed periods against the guest's clock as the test that must be zero
  (proposed), and the device's underruns only through KVM in the Linux VM, where the guest's CPUs keep the host's
  pace; or something else.
- **What's in std**: formats, mixing, resampling and WAV in Hemera's std, as fonts and the canvas are (proposed); or in
  SlopOS.
- **The device's format**: one fixed format the service mixes into, 48 kHz stereo 32-bit float (proposed), or the
  device's best.
- **17g's scope**: the shell's `play` and `record`, the viewer, and a volume control (proposed); or fewer.
