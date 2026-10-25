/*
 * What drivers share (decisions/0074, 0075): mapping what they're given of their device, its configuration space and
 * its BARs, into their own address space.
 */
package driver_kit

import runtime from "base"
import slop_os from "std/os"

// Device memory mapped read/write, as it is: where, or null.
map_device :: fn(memory: slop_os.Memory) -> u64? {
    block :: slop_os.startup_block()
    size :: slop_os.memory_size(memory) or_return null
    at :: runtime.reserve_addresses(cast[usize](size)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    match slop_os.memory_map(memory, block.space, at, 0, size, read_write) {
        case Ok => return at
        case Error(error) => return null
    }
}

// A device's BARs, those it has mapped: where each is, or 0 for one it hasn't.
map_bars :: fn(bar0: slop_os.Memory?, bar1: slop_os.Memory?, bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?,
    bar5: slop_os.Memory?) -> u64[6] {
    return u64.[map_bar(bar0), map_bar(bar1), map_bar(bar2), map_bar(bar3), map_bar(bar4), map_bar(bar5)]
}

map_bar :: fn(bar: slop_os.Memory?) -> u64 {
    memory :: bar or_return 0
    return map_device(memory) or_else 0
}
