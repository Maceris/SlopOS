/**
 * What drivers share (decisions/0074, 0075): mapping what they're given of their device, its configuration space and
 * its BARs, into their own address space.
 */
package driver_kit

import runtime from "base"
import slop_os from "std/os"

/**
 * Map device memory read/write into the process's own address space, as it is.
 *
 * The addresses are reserved from the startup block's free range and aren't given back, even if the mapping fails.
 *
 * @param memory The device memory, such as a BAR or configuration space the driver was given, which stays the
 *     caller's; it's mapped whole, from its start.
 * @return The address it's mapped at, or null if its size couldn't be read, the free range hasn't room, or the
 *     mapping failed.
 */
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

/**
 * Map each of a device's BARs the driver was given, read/write, as map_device maps one.
 *
 * @param bar0 BAR 0's memory, or null if the driver wasn't given it.
 * @param bar1 BAR 1's memory, or null if the driver wasn't given it.
 * @param bar2 BAR 2's memory, or null if the driver wasn't given it.
 * @param bar3 BAR 3's memory, or null if the driver wasn't given it.
 * @param bar4 BAR 4's memory, or null if the driver wasn't given it.
 * @param bar5 BAR 5's memory, or null if the driver wasn't given it.
 * @return Where each BAR is mapped, in order, or 0 for one that's null or couldn't be mapped.
 */
map_bars :: fn(bar0: slop_os.Memory?, bar1: slop_os.Memory?, bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?,
    bar5: slop_os.Memory?) -> u64[6] {
    return u64.[map_bar(bar0), map_bar(bar1), map_bar(bar2), map_bar(bar3), map_bar(bar4), map_bar(bar5)]
}

/**
 * Map one BAR, if the driver was given it.
 *
 * @param bar The BAR's memory, or null if the driver wasn't given it.
 * @return Where it's mapped, or 0 if bar is null or couldn't be mapped.
 */
map_bar :: fn(bar: slop_os.Memory?) -> u64 {
    memory :: bar or_return 0
    return map_device(memory) or_else 0
}
