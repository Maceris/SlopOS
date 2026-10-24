/*
 * The root task (decisions/0012, 0060): the one process the kernel starts, given everything. For now
 * (roadmap M6, 6b) it checks what it was given and reports through its debug log, then ends with 0 if
 * everything was there, or the number of the first check that failed; the kernel stops then. From 6c it
 * starts the system's first services and stays.
 */
package root_task

import runtime from "base"
import slop_os from "std/os"
import text_buffer from "std"

main :: fn() -> int {
    block :: slop_os.startup_block()
    if block.abi_version != slop_os.ABI_VERSION || block.size != cast[u32](size_of(slop_os.StartupBlock)) {
        return 1
    }
    log_handle :: slop_os.find_grant(block, "debug_log", .DebugLog) or_return 2
    log :: cast[slop_os.DebugLog](log_handle)
    report(log, "root task: started, with % grants", block.grant_count)
    if (slop_os.find_grant(block, "platform", .Platform) is_none) {
        report(log, "root task: no platform capability")
        return 3
    }
    // A module, mapped where the runtime has room, starts as an ELF file does
    module :: slop_os.find_grant(block, "module:hello.elf", .Memory) or_return 4
    address :: runtime.reserve_addresses(4096) or_return 5
    match slop_os.memory_map(cast[slop_os.Memory](module), block.space, address, 0, 4096, slop_os.PROTECTION_READ) {
        case Ok => {}
        case Error(failure) => {
            report(log, "root task: hello.elf doesn't map: %", failure)
            return 6
        }
    }
    magic :: cast[ptr[u32]](address)^
    if magic != 0x464c457f {
        report(log, "root task: hello.elf isn't an ELF file")
        return 7
    }
    // Memory from its heap
    values, error :: runtime.new_array(u64, 10000)
    if error != null {
        report(log, "root task: no heap")
        return 8
    }
    defer runtime.free_array(values)
    for &value, i in values {
        value^ = cast[u64](i)
    }
    // A random seed, unless the machine has no random source at all
    seeded := false
    for byte in block.seed {
        seeded = seeded || byte != 0
    }
    report(log, "root task: hello.elf mapped, heap working, seeded: %", seeded)
    return 0
}

// A line in the debug log, formatted.
report :: fn(log: slop_os.DebugLog, format: string, values: any...) {
    storage : u8[200]
    line := text_buffer.make(storage)
    text_buffer.append_format(&line, format, values)
    text :: text_buffer.as_string(&line)
    _ = slop_os.debug_log(log, view_of(cast[ptr[u8]](text.data), text.count))
}
