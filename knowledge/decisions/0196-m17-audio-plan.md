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

## As Built: 17b, std/audio
In Hemera (`std/audio`, Freestanding; its hosted scenario `audio`, 10 tests):
- **Formats**: `SampleFormat` (16-, 24- in 3 bytes, 32-bit integers, 32-bit floats, little-endian) and `Format`
  (sample, rate, channels, at most 8); `decode` to floats at full scale 1, `encode` back, clipped, rounded to the
  nearest, NaN as silence.
- **Mixing**: `mix` adds with a gain and doesn't clip, so streams add in any order; `scale`; `clip` says how many it
  clipped; `remix` between channel counts (one into each, several averaged into one, the others copied or silent).
- **Resampling**: a `Resampler`, ~33 KiB of the caller's, a 64-tap Kaiser-windowed (beta 8) sinc of 128 phases
  interpolated, cutting off at 0.9 of the lower rate's half; any two rates, a block at a time, 32 frames' delay.
  Measured: a 1 kHz tone from 44.1 to 48 kHz keeps its level within 1% with no third harmonic or image above
  1/1000; a 23 kHz tone from 48 to 44.1 kHz folds back under 1/1000; a 10 kHz one keeps its level; blocks of 7 frames
  give what one block does.
- **WAV**: `read_wav` from anyone's bytes (PCM 16, 24 and 32 bits, float 32, either as WAVE_FORMAT_EXTENSIBLE; other
  chunks skipped, odd ones padded; a data chunk past the file taken as far as it goes), `write_wav`. Fuzzed:
  `tools/fuzz.py wav`, 2.5 million inputs in 30 s, nothing found.

## As Built: 17c, virtio-sound and the audio protocol
- **The `audio` protocol** (`src/protocols/audio`): a stream in the system's format, 48 kHz stereo 32-bit floats,
  through a ring of 8 periods of 240 frames (5 ms each, 40 ms in all) in memory the client reaches through a window
  (`GetBuffer`), 16 KiB as windows are whole pages. `Play(period)` is answered with `Played` once the device has taken
  it, with the device's latency and the underruns so far; `Stop`. One client plays at a time, the latest to ask for
  the ring. It's among the protocols whose messages are fuzzed.
- **`virtio_sound`** (virtio's device 25, PCI 0x1059): the control, event and transmit queues on one MSI-X vector; the
  first output stream that takes 48 kHz stereo, as floats if it can (QEMU's does) or else 16-bit integers; each period
  encoded from the ring into the device's memory with std/audio, clipped and NaN silent, the ring itself never the
  device's to see; `PCM_START` once half the ring is given; running dry while playing, or the device's xrun event,
  counted as an underrun. Started by the supervisor for each such device, as `Speaks.Audio`, the first `first_audio`.
- **`test_sound`**, started with `test_sound` on the command line, plays a second of a 1 kHz tone at half scale,
  every period kept given. `boot.py --audio-tone=HZ` adds the device with QEMU's `wav` backend writing into the run's
  folder, read as it was left, its sizes still 0 since a run ends through the exit device before QEMU closes it, and
  checks at least 0.9 s of the tone at half scale within 0.05, harmonics under 4% of it; gaps of 2 ms or more are said.
  Measured on both architectures: 200 periods played, 0.99 s at 0.499 of full scale, no harmonics, no gaps, the device
  at most 35 ms behind; the one underrun counted is the ring running out at the end.
- **Found on the way**: windows are whole pages; `give` is a Hemera keyword; and once, the compiler crashed in
  `get_base_type` laying a struct out, then built the same sources three times cleanly, a race left to look into.

## As Built: 17d, the audio service
- **The `sound` protocol** (`src/protocols/sound`): a connection is a stream in a format of its own, a std/audio
  sample format, 8 to 192 kHz, 1 to 8 channels (`Open`); a ring of 8 periods of about 5 ms each at its rate
  (`period_frames`), reached through `GetBuffer`; `Play` answered `Played` once the period's mixed in, with the
  stream's underruns; `SetVolume`, 0 to 1000; `Stop` drops what's queued.
- **The service, `audio`** (`src/services/audio_service`): each period given is decoded, remixed to stereo and
  resampled to 48 kHz into the stream's carry, which the mix takes 240 frames of a period; each stream scaled by its
  volume, added, the sum clipped once and given to the driver. A period is due every 5 ms by the system's clock; one
  mixed more than a period after it's due is missed; with the driver's ring full the mix waits, its time moved on,
  uncounted, as the device is behind. A stream that's run out is silence, its own underrun. 100 ms of nothing to mix
  stops the device, and what was mixed is said: periods, missed, the latest, each mix's worst and average time, and
  the device's runs out. Started by the supervisor when there's a sound device (`Speaks.Sound`), on its own budget,
  `AUDIO_CPU`: priority 240, 3 ms of every 5.
- **The budget**: with 1 ms of every 5 it ran out under TCG on x86-64, where a period's mix takes 0.6 ms on average and
  up to 2, so it missed 81 of 224 periods, 27 ms late, the device running out 132 times; with 3 ms, none in six runs on
  either architecture, at most 3.8 ms late. 3 ms is an emulator's; on hardware a twentieth would do, and a budget's
  share is checked against its parent's when it's split, so it leaves the rest that much less room (17e, 17h).
- **The test**: `test_sound` plays two streams through the service, a second each: 1 kHz at 48 kHz stereo floats and
  1.5 kHz at 44.1 kHz mono 16-bit integers, a quarter of full scale each. `boot.py --audio-tone=HZ:LEVEL`, repeated,
  checks each: 1000 Hz at 0.250 and 1500 Hz at 0.249, harmonics 0, on both architectures.

## As Built: 17e, the soft real-time goal measured
- **The load, `test_spinner`** (`src/tests/test_spinner`): a spinner flat out on each of 4 threads, more than the boot
  tests' CPUs, until the system shuts down. Each gives up its CPU budget (`thread_use_cpu_budget` with no handle), so
  it runs in the background band under every budget, and takes no share of its own: the root's two CPUs are already
  allotted whole, and a share of a twentieth left `virtio_gpu` with none. Started by the supervisor with
  `test_sound_load` on the kernel's command line; `test_sound` then plays three seconds of each stream. Its first form
  ran the spinners inside `test_sound` on its own budget, which starved the client: its streams ran out 233 and 249
  times and the 3 s took 8.7. Its four 256 KiB stacks need a budget of 4 MiB; with 1 the process took a write fault.
- **The driver's own share**, `SOUND_DRIVER_CPU`: priority 245, just above the service, 0.5 ms of every 5, taken from
  the service's, which is 2.5 ms now. On the default budget the driver fell into the background band with the
  spinners once that was spent, and the device ran out 76 to 130 times while the mix missed nothing.
- **The service's counts** are lines of their own: `missed M of N periods mixed`, `the device ran out K times`.
- **Under KVM** (`boot.py --audio-none`, QEMU's `none` backend, which takes what it's given at the host's pace): with
  every CPU busy, 0 of 625 periods missed, the latest 0.7 ms late, each mix at most 0.5 ms and 0.09 on average, the
  device never running out, the client's streams 1 and 0 underruns. The test holds both counts to 0. It ends by the
  root task's settle, 15 s, since its QEMU is on the KVM host, out of `--end-when-done`'s reach.
- **The host's floor**: the KVM host is a 2-core VM, and the guest's two CPUs flat out take both, leaving QEMU's own
  loop, which paces the `none` backend, to wait its turn. About one run in three the device ran out (47 times, the
  mix 0 missed) or one period was missed; each passed booted again alone. The plan's zero is met where the host keeps
  the pace; a third core on the KVM host would take the floor away.
- **Under TCG** the guest doesn't keep the host's pace with every CPU busy, so the plan's zero on both architectures
  isn't held there: 0 to 2 periods of about 1,500 missed, the device's underruns 0 to 185, the mix each at most 1.2 ms
  and 0.27 on average. The emulator's test plays under the load and says both counts; the KVM test holds them.

## Chosen with the owner after 17e (2026-11-23)
- **Zero missed, under KVM only.** The first answer's zero under TCG on both architectures isn't held with every CPU
  busy, so it is replaced: the KVM test holds both the service's missed periods and the device's underruns to zero,
  and the emulators' tests play under the load and say both counts.
- **The KVM host has 4 cores**, so QEMU's own loop isn't starved by a guest keeping its two CPUs busy.
- **The microphone's indicator** shows in the trusted layer and the console's status line in 17f. A mark on each
  holding program's windows waits for M18, which knows which windows are whose.
