package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import testing from "std"
import time from "std"
import time_zones from "std"
import test_kit from "../../test_kit"

/*
 * Time zones (decisions/0164): the system volume's zoneinfo/, which the image builder copies from tzdata, read with
 * Hemera's std/time: Europe/London is GMT in January and BST in July, the summer of 2100 from its footer's rule; and
 * Australia/Sydney the other way round.
 */

/** London's zone file, relative to the system volume's root. */
LONDON_ZONE :: "zoneinfo/Europe/London"
/** Sydney's zone file, relative to the system volume's root. */
SYDNEY_ZONE :: "zoneinfo/Australia/Sydney"

/**
 * Check time zones read from the system volume's zoneinfo/ with std's time_zones.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the buffer or a port couldn't be made, or a zone's file couldn't be read or
 *     parsed.
 */
time_zones_read_from_the_system_volume #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    system :: system_of(t, given)?
    buffer :: buffer_of(t, given)?
    bound :: os.port_for(slop_os.startup_block().budget, system.end)
    port :: testing.require_some(t, bound, "the budget has room for a port")?
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    london_bytes : u8[..]
    defer runtime.array_free(&london_bytes)
    testing.require(t, read_whole(system.end, port, LONDON_ZONE, buffer, &london_bytes),
        "the image builder copies tzdata's zoneinfo to the system volume, London's among it")?
    london_parsed :: time_zones.parse_zone(london_bytes[0..<london_bytes.count])
    london := testing.require_ok(t, london_parsed, "a zoneinfo file from tzdata parses")?
    defer time_zones.free_zone(&london)
    expect_zone(t, &london, 2026, 1, 0, "GMT", "London keeps GMT in January")
    expect_zone(t, &london, 2026, 7, 3600, "BST", "London keeps BST in July, by its transitions")
    expect_zone(t, &london, 2100, 7, 3600, "BST", "London keeps BST in July 2100 too, past its transitions, by its footer's rule")
    sydney_bytes : u8[..]
    defer runtime.array_free(&sydney_bytes)
    testing.require(t, read_whole(system.end, port, SYDNEY_ZONE, buffer, &sydney_bytes),
        "the image builder copies tzdata's zoneinfo to the system volume, Sydney's among it")?
    sydney_parsed :: time_zones.parse_zone(sydney_bytes[0..<sydney_bytes.count])
    sydney := testing.require_ok(t, sydney_parsed, "a zoneinfo file from tzdata parses")?
    defer time_zones.free_zone(&sydney)
    expect_zone(t, &sydney, 2026, 1, 39600, "AEDT", "Sydney keeps daylight time in January, its summer")
    expect_zone(t, &sydney, 2026, 7, 36000, "AEST", "Sydney keeps standard time in July, its winter")
    return .Ok
}

/**
 * Check a zone's offset and abbreviation at noon UTC on the 15th of a month.
 *
 * @param t The test's state, which a failure is recorded in for each that differs.
 * @param zone The zone asked, parsed from a zoneinfo file by time_zones.parse_zone; only read.
 * @param year The year, in the Gregorian calendar, as 2026; the instant asked is in it.
 * @param month The month, 1 for January to 12.
 * @param offset The offset from UTC expected, in seconds east.
 * @param abbreviation The abbreviation expected, as "BST".
 * @param message Why the zone keeps them then, for whoever reads a failure.
 * @param location Where the test asked, which a failure is recorded at: the caller's own.
 */
expect_zone :: fn(t: ptr[mut testing.T], zone: ptr[time_zones.Zone], year: i64, month: int, offset: i32, abbreviation: string, message: string,
    location := #caller_location) {
    found, dst, name :: time_zones.offset_of(zone, time.from_utc(time.DateTime.{year = year, month = month, day = 15, hour = 12}))
    testing.expect_eq(t, found, offset, message, location)
    testing.expect_eq(t, name, abbreviation, message, location)
}
