/*
 * test_exits (decisions/0068, 0098): how a program ends when it can't start, seen by whoever started it. Two copies of
 * the program, each watched until it ends:
 * - one launched through the process manager as if its entry took nothing, given no grants, ends with
 *   EXIT_MISSING_GRANT (126), as its real entry requires its debug log;
 * - one built with the process builder directly, its startup block saying an ABI version that isn't the kernel's,
 *   ends with EXIT_WRONG_ABI (125) before its entry runs.
 * What both had comes back to its budget.
 */
package test_exits

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"
import process_builder from "../../process_builder"
import random_stream from "../../random_stream"

NAME :: "test_exits"
COPY_BUDGET : u64 : 4 << 20
WATCH_KEY : u64 : 1
// The second copy's: a binding keeps its key after it fires
BUILT_KEY : u64 : 2

// An entry that takes nothing, which the copy's isn't.
takes_nothing :: fn() -> int {
    return 0
}

NoGrants :: struct {}

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    executable :: program or_return 100
    loader :: manager or_return 101
    manager_port :: os.port_for(block.budget, loader.end) or_return 102
    port :: slop_os.port_create(block.budget) or_return 103
    results : u64[4]

    // Launched with nothing, though its entry requires its log
    launched :: os.launch(loader, manager_port, "test_exits without grants", executable, COPY_BUDGET, takes_nothing, NoGrants.{},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}) or_return 104
    results[0] = ended_with(port)
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    results[1] = if test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))

    // Built here, its startup block saying another ABI version
    budget :: slop_os.memory_budget_create(block.budget, COPY_BUDGET) or_return 105
    process :: slop_os.process_create(budget) or_return 106
    space :: slop_os.address_space_create(budget) or_return 107
    slop_os.port_bind(port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, BUILT_KEY, .Once) or_return 108
    size :: slop_os.memory_size(executable) or_return 109
    address :: runtime.reserve_addresses(cast[usize](size)) or_return 109
    slop_os.memory_map(executable, block.space, address, 0, size, slop_os.PROTECTION_READ) or_return 109
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    stream := random_stream.make(block.seed)
    seed : u8[32]
    random_stream.fill(&stream, seed)
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    no_grants : process_builder.Grant[1]
    thread :: process_builder.build(target, file, view_of(&no_grants[0], 0), seed, &stream, null, slop_os.ABI_VERSION + 1)
        or_return 110
    results[2] = ended_with(port)
    _ = slop_os.memory_unmap(block.space, address)
    _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    _ = slop_os.handle_close(cast[slop_os.Handle](process))
    results[3] = if test_kit.wait_for_budget(budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))

    expected :: u64.[cast[u64](slop_os.EXIT_MISSING_GRANT), 1, cast[u64](slop_os.EXIT_WRONG_ABI), 1]
    failed :: test_kit.check(log, NAME, results, expected)
    if failed == 0 {
        log_line.write(log, "%: a copy missing a grant it requires ended with 126, one told another ABI version with 125", NAME)
    }
    return failed
}

// How the process watched on port ended: its code, once it has.
ended_with :: fn(port: slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
