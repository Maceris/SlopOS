# 0167: 11a4, Time Zones, as Built

Status: accepted
Date: 2026-11-02
Related: `0164` (zones on the system volume), `0152` (locale), `../roadmap.md` M11 (TZif, RFC 8536)

## Context
`0164`: time zones are TZif files on the system volume's `zoneinfo/`, which Hemera's `std/time` reads.

## Decision
- **Hemera's `std/time`** (`zones.hsc`): `parse_zone` reads TZif data, version 2 and later's 64-bit block when the file
  has one, else version 1's: the transitions, the local time type each starts, the types (offset, daylight saving,
  abbreviation), and the footer's POSIX TZ rule. `offset_of` gives the offset, whether it's daylight saving time and
  the abbreviation at an instant: the last transition's type at or before it, the first type before any, and after the
  last, the footer's rule; `local` gives the local date and time. `parse_rule` and `rule_offset` read and apply a rule
  alone: names alphabetic or in angle brackets, offsets west of UTC as POSIX writes them, `Jn`, `n` and `Mm.w.d` dates
  with times up to 167 hours, the United States' rules when a rule names daylight saving time without dates, and
  southern zones whose daylight saving time spans the year's turn. Leap seconds are ignored, as POSIX time ignores
  them.
- **The zone files**: `boot.py` copies 46 common zones from Python's `tzdata` package (2025c here) to the system
  volume's `zoneinfo/`; without the package it says how to install it.
- **Tests**: Hemera's `time_zones` scenario, with London's and Sydney's TZif data built in: offsets from the table and
  from the footer, either side of a change, in 2100, local time, a rule alone, and data that isn't TZif refused; on
  SlopOS, disk_check reads London and Sydney from the system volume.

## Consequences
- A program reads a zone through a `Dir` it's given on `zoneinfo/`; the user's zone comes with their settings, as their
  locale does (`0152`), when something needs it (the shell's dates, 11c).
- More zones are more names in `boot.py`'s list, or the whole of tzdata once the image builder copies a tree quickly.
