package disk_check

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import time from "std"
import dir from "std/os/slop_os"

/*
 * Time zones (decisions/0164): the system volume's zoneinfo/, which the image builder copies from tzdata, read with
 * Hemera's std/time: Europe/London is GMT in January and BST in July, the summer of 2100 from its footer's rule; and
 * Australia/Sydney the other way round. Checks from 150.
 */

LONDON_ZONE :: "zoneinfo/Europe/London"
SYDNEY_ZONE :: "zoneinfo/Australia/Sydney"

check_zones :: fn(to: slop_os.DebugLog, system: os.Channel[dir.Dir]) -> int {
    buffer := new_buffer() or_return 150
    // Given back after, as disk_check's budget is small
    defer {
        _ = slop_os.memory_unmap(slop_os.startup_block().space, buffer.address)
        _ = slop_os.handle_close(cast[slop_os.Handle](buffer.memory))
    }
    port :: os.port_for(slop_os.startup_block().budget, system.end) or_return 151
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    london_bytes : u8[..]
    defer runtime.array_free(&london_bytes)
    if !read_whole(system.end, port, LONDON_ZONE, &buffer, &london_bytes) {
        return 152
    }
    london := time.parse_zone(london_bytes[0..<london_bytes.count]) or_return 153
    defer time.free_zone(&london)
    if !zone_is(&london, 2026, 1, 3600 * 0, "GMT") || !zone_is(&london, 2026, 7, 3600, "BST") || !zone_is(&london, 2100, 7, 3600, "BST") {
        return 154
    }
    sydney_bytes : u8[..]
    defer runtime.array_free(&sydney_bytes)
    if !read_whole(system.end, port, SYDNEY_ZONE, &buffer, &sydney_bytes) {
        return 155
    }
    sydney := time.parse_zone(sydney_bytes[0..<sydney_bytes.count]) or_return 156
    defer time.free_zone(&sydney)
    if !zone_is(&sydney, 2026, 1, 39600, "AEDT") || !zone_is(&sydney, 2026, 7, 36000, "AEST") {
        return 157
    }
    runtime.log_info("zones: from the system volume's zoneinfo, London is GMT in January and BST in July, Sydney AEDT and AEST")
    return 0
}

/** Whether the zone's offset and abbreviation are these at noon UTC on the 15th of the month. */
zone_is :: fn(zone: ptr[time.Zone], year: i64, month: int, offset: i32, abbreviation: string) -> bool {
    found, dst, name :: time.offset_of(zone, time.from_utc(time.DateTime.{year = year, month = month, day = 15, hour = 12}))
    return found == offset && name == abbreviation
}
