package hello

import runtime from "base"
import slop_os from "std/os"
import log_line from "../../log_line"

/*
 * The first SlopOS program (roadmap M6): it fills memory from its heap and says whether that worked
 * through its debug log, if it's given one. Given a connection to the process manager, it then waits
 * for the manager to be gone and says it's still running, which shows a program outlives the manager
 * that loaded it (decisions/0067). It ends with 0 if the heap worked.
 */
main :: fn() -> int {
    block :: slop_os.startup_block()
    log :: cast[slop_os.DebugLog](slop_os.find_grant(block, "debug_log", .DebugLog) or_else slop_os.NO_HANDLE)
    code :: fill_heap()
    log_line.write(log, "hello: heap %", if code == 0 { "working" } else { "broken" })
    match slop_os.find_grant(block, "process_manager", .Channel) {
        case Some(manager) => {
            port :: slop_os.port_create(block.budget) or_return 3
            slop_os.port_bind(port, manager, slop_os.SIGNAL_PEER_CLOSED, 0, .Once) or_return 4
            packets : slop_os.Packet[1]
            _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_return 5
            log_line.write(log, "hello: still running after the process manager ended")
        }
        case None => {}
    }
    return code
}

// 0 if memory from the heap holds what's written to it.
fill_heap :: fn() -> int {
    values, error :: runtime.new_array(u64, 1000)
    if error != null {
        return 1
    }
    defer runtime.free_array(values)
    for &value, i in values {
        value^ = cast[u64](i) * 3
    }
    total : u64 = 0
    for value in values {
        total += value
    }
    // 3 × (0 + 1 + ... + 999)
    return if total == 1498500 { 0 } else { 2 }
}
