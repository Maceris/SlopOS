/**
 * test_exits (decisions/0068, 0098): how a program ends when it can't start, seen by whoever started it. Copies of
 * the program, each watched until it ends:
 * - one launched through the process manager as if its entry took nothing, given no grants, ends with
 *   EXIT_MISSING_GRANT (126), as its real entry requires its debug log;
 * - two built with the process builder directly: one whose startup block says an ABI version earlier than the
 *   program's ends with EXIT_WRONG_ABI (125) before its entry runs; one whose says a later one starts, and ends as the
 *   first does, its entry finding no grants.
 * Three copies in all, then.
 * What each had comes back to its budget. And a launch refused, its watch's key still the first copy's, gives back
 * what it made for the copy, so its starter's budget is charged no more than before.
 */
package test_exits

import compiler from "base:compiler"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import process_manager from "std:os/slop_os/process_manager"
import testing from "std:testing"
import process_builder from "../../process_builder"
import random_stream from "../../random_stream"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_exits"
/** Each copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 << 20
/** The key the first copy's watch queues its end under, which the refused launch asks for again. */
WATCH_KEY : u64 : 1
/** The key the second copy's watch queues its end under: its own, as a binding keeps its key after it fires. */
BUILT_KEY : u64 : 2

/**
 * Stand for an entry that takes nothing, which the copy's isn't, so the launch gives it no grants.
 *
 * @return 0, though it never runs: the copy runs main.
 */
takes_nothing :: fn() -> int {
    return 0
}

/** The grants of an entry that takes nothing: none. */
NoGrants :: struct {}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
    /** The process manager, which launches the first copy; none if main wasn't given it. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which both copies run; none if main wasn't given it. */
    program : slop_os.Memory?,
}

/**
 * Check that a copy launched without a grant its entry requires ends with EXIT_MISSING_GRANT, and its budget comes back
 * to nothing; then that a launch refused, its watch's key still the first copy's, gives back what it made for the
 * copy, so its starter's budget is charged no more than before.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the process manager or its module, or a port or the first
 *     launch couldn't be made, or the budget couldn't be read.
 */
a_copy_missing_a_grant_ends_with_126_and_a_refused_launch_gives_back #test :: fn(
    t : ptr[mut testing.T]
) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    executable :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    loader :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    manager_port :: testing.require_some(
        t,
        os.port_for(block.budget, loader.end),
        "a port for the process manager's replies"
    )?
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for the copies' watches")?
    // Launched with nothing, though its entry requires its log
    launch :: os.launch(
        loader,
        manager_port,
        "test_exits without grants",
        executable,
        COPY_BUDGET,
        type_of(takes_nothing),
        NoGrants.{},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}
    )
    launched :: testing.require_ok(t, launch, "the process manager launches a copy as if its entry took nothing")?
    testing.expect_eq(
        t,
        ended_with(port),
        cast[u64](slop_os.EXIT_MISSING_GRANT),
        "a copy whose entry requires its debug log, given none, ends with EXIT_MISSING_GRANT before its entry runs"
    )
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    testing.expect(
        t,
        test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000),
        "the copy's budget is back to nothing once it has ended"
    )
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    // Refused: the first copy's binding keeps WATCH_KEY after it fired
    before :: testing.require_ok(t, slop_os.memory_budget_info(block.budget), "the program's budget can be read")?
    refused :: os.launch(
        loader,
        manager_port,
        "test_exits refused",
        executable,
        COPY_BUDGET,
        type_of(takes_nothing),
        NoGrants.{},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}
    ) is_error
    after :: testing.require_ok(t, slop_os.memory_budget_info(block.budget), "the program's budget can be read")?
    testing.expect(t, refused, "a launch whose watch asks for a key the port already has bound is refused")
    testing.expect_lt(
        t,
        after.used,
        before.used + COPY_BUDGET,
        "a refused launch gives back the copy's budget it made, so the starter isn't charged for it"
    )
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return .Ok
}

/**
 * Check that a copy built here with the process builder, its startup block saying an ABI version earlier than the
 * program's, as an older kernel's would, ends with EXIT_WRONG_ABI before its entry runs, and that what it had comes
 * back to its budget.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the copy couldn't be built and watched (built_with).
 */
a_copy_told_an_earlier_abi_version_ends_with_125 #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    code :: built_with(t, slop_os.ABI_VERSION - 1)?
    testing.expect_eq(
        t,
        code,
        cast[u64](slop_os.EXIT_WRONG_ABI),
        "a copy told an ABI version earlier than its own ends with EXIT_WRONG_ABI before its entry runs"
    )
    return .Ok
}

/**
 * Check that a copy built here with the process builder, its startup block saying a later ABI version than the
 * program's, as a newer kernel's would, is started: it gets past the version's check to its entry, which, given no
 * grants, ends it with EXIT_MISSING_GRANT, and what it had comes back to its budget.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the copy couldn't be built and watched (built_with).
 */
a_copy_told_a_later_abi_version_starts #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    code :: built_with(t, slop_os.ABI_VERSION + 1)?
    testing.expect_eq(
        t,
        code,
        cast[u64](slop_os.EXIT_MISSING_GRANT),
        "a copy told a later ABI version than its own starts, and ends as its entry finds no grants"
    )
    return .Ok
}

/**
 * Build a copy of the program with the process builder, given no grants, its startup block saying an ABI version, wait
 * for it to end, and check that what it had comes back to its budget.
 *
 * @param t The test's state.
 * @param abi_version The version its startup block says.
 * @return How it ended, its exit code, or 0xffff if waiting for it failed; Error if main wasn't given its module, or
 *     the port, the copy's budget, process or address space, its watch, or the module's mapping couldn't be made, or
 *     the copy couldn't be built.
 */
built_with :: fn(t : ptr[mut testing.T], abi_version : u32) -> Result[u64, testing.Stopped] {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    executable :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for the copy's watch")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, COPY_BUDGET), "a budget for the copy")?
    process :: testing.require_ok(t, slop_os.process_create(budget), "a process for the copy")?
    space :: testing.require_ok(t, slop_os.address_space_create(budget), "an address space for the copy")?
    watched :: slop_os.port_bind(port, BUILT_KEY, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, .Once)
    testing.require_ok(t, watched, "the copy's end is watched")?
    size :: testing.require_ok(t, slop_os.memory_size(executable), "the module's size can be read")?
    address :: testing.require_some(t, runtime.reserve_addresses(cast[usize](size)), "addresses to map the module at")?
    mapped :: slop_os.memory_map(executable, block.space, address, 0, size, slop_os.PROTECTION_READ)
    testing.require_ok(t, mapped, "the module is mapped to be read")?
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    stream := random_stream.make(block.seed)
    seed : u8[32]
    random_stream.fill(&stream, seed)
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    no_grants : process_builder.Grant[1]
    built :: process_builder.build(target, file, view_of(&no_grants[0], 0), seed, &stream, abi_version)
    testing.require_ok(t, built, "the process builder builds the copy, its startup block saying the version given")?
    code :: ended_with(port)
    _ = slop_os.memory_unmap(block.space, address)
    // The build gave the copy's thread's ID in its own process, not a handle of this one's, so there's nothing to close
    _ = slop_os.handle_close(cast[slop_os.Handle](process))
    testing.expect(
        t,
        test_kit.wait_for_budget(budget, 0, 1_000_000_000),
        "the copy's budget is back to nothing once it has ended"
    )
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return .Ok(code)
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches the first copy; without it the tests fail.
 * @param program The test's own module, which both copies run; without it the tests fail.
 * @param peer Not used: the copies never get as far as their entry.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    firmware : slop_os.Memory?,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    peer : slop_os.Channel?,
    cpu_budget : slop_os.CpuBudget?
) -> int {
    given :: Given.{log = log, manager = manager, program = program}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Wait for a watched process to end, and tell how.
 *
 * @param port The port its watch, for SIGNAL_TERMINATED, queues on; nothing else may be bound to it.
 * @return The process's exit code, or 0xffff if the wait failed.
 */
ended_with :: fn(port : slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
