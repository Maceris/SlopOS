/**
 * test_latency (decisions/0196, 17a; design/scheduling.md, Latency): how late a thread on a high-priority budget of a
 * short period wakes for its deadlines, as an audio mixer would, with the CPUs idle, kept to each CPU, and with every
 * CPU running threads of a lower-priority budget flat out. Each run logs its worst, 99.9th percentile and median
 * lateness, in microseconds.
 *
 * What's held to is what an emulator can show of the kernel: under load, 999 wakes in 1000 within LOADED_BOUND, as a
 * wake that waited for a tick, its IPI missed, wouldn't be. The idle runs are logged, not held to: an emulator's idle
 * CPU wakes as its host lets it, to about 1.7 ms under TCG on Windows, and a guest of KVM in a VM can stall tens of
 * milliseconds while halted, its own ticks not coming either.
 */
package test_latency

import compiler from "base:compiler"
import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import process_manager from "std:os/slop_os/process_manager"
import testing from "std:testing"
import test_kit from "../../test_kit"
import log_line from "../../log_line"

NAME :: "test_latency"
/** A millisecond, in nanoseconds. */
MILLISECOND : u64 : 1_000_000
/** The waking thread's period, as a mixer's: 2 ms. */
PERIOD : u64 : 2 * MILLISECOND
/** Its time each period: a quarter of it, far more than a wake takes. */
WAKER_TIME : u64 : PERIOD / 4
/** Its priority, under the root's 255. */
WAKER_PRIORITY : u32 : 250
/** The spinners' priority, far under the waker's. */
SPINNER_PRIORITY : u32 : 10
/** How late 999 wakes in 1000 may be under load: half a tick, so a wake that waited for one fails. */
LOADED_BOUND : u64 : 5 * MILLISECOND
/** How many deadlines each run waits for: 3 seconds of them. */
WAKES : usize : 1500
/** The most CPUs spinners are started for. */
MAX_SPINNERS : usize : 16
/** A whole CPU, in the millionths shares are counted in. */
WHOLE_CPU : u64 : 1_000_000

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, where each run's numbers go. */
    log : slop_os.DebugLog,
    /** The root CPU budget, split for the waker and the spinners; none if main wasn't given it. */
    cpu_budget : slop_os.CpuBudget?,
}

/** What the spinners share: their budget, and whether they're to stop. */
Spinning :: struct {
    /** The budget each spinner runs on. */
    budget : slop_os.CpuBudget,
    /** Set to 1 once they're to stop, read and written atomically. */
    stop : u64,
    /** How many have started spinning, counted atomically. */
    started : u64,
}

/** One run's lateness: its worst, 99.9th percentile and median, in nanoseconds, and whether any wake came early. */
Lateness :: struct {
    worst : u64,
    high : u64,
    median : u64,
    early : bool,
}

/**
 * Spin on the spinners' budget until told to stop.
 *
 * @param data The Spinning, shared with the test.
 */
spin :: fn(data #escaping : any) {
    // An any holds where its value is: here, the Spinning's address
    spinning :: cast[ptr[ptr[mut Spinning]]](data.data)^
    _ = slop_os.thread_use_cpu_budget(spinning.budget)
    _ = intrinsics.interlocked_exchange_add_u64(&spinning.started, 1)
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.atomic_load_u64_acquire(&spinning.stop) == 0
}

/**
 * Wake for WAKES deadlines a PERIOD apart, on the calling thread's budget, each waited for on a port with nothing bound
 * to it, and say how late each wake was.
 *
 * @param late Where each wake's lateness goes, in nanoseconds, WAKES of them.
 * @return Whether every wait could be made; false without a port.
 */
measure :: fn(late : mut u64[]) -> bool {
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    packets : slop_os.Packet[1]
    start :: slop_os.clock_monotonic() or_return false
    for i in 0..<late.count {
        deadline :: start + cast[u64](i + 1) * PERIOD
        _ = slop_os.port_wait(port, packets, deadline)
        now :: slop_os.clock_monotonic() or_else deadline
        late[i] = if now >= deadline { now - deadline } else { ~cast[u64](0) }
    }
    return true
}

/**
 * Sort lateness, and take its worst, 99.9th percentile and median.
 *
 * @param late Each wake's lateness, sorted in place; ~0 for one that came early.
 * @return Its numbers.
 */
summed :: fn(late : mut u64[]) -> Lateness {
    for i in 1..<late.count {
        held :: late[i]
        at := i
        loop {
            if at == 0 || late[at - 1] <= held {
                break
            }
            late[at] = late[at - 1]
            at -= 1
        }
        late[at] = held
    }
    if late.count == 0 {
        return Lateness.{}
    }
    last :: late.count - 1
    high :: (late.count * 999) / 1000
    middle :: late.count / 2
    if last >= late.count || high >= late.count || middle >= late.count {
        return Lateness.{}
    }
    return Lateness.{
        worst = late[last],
        high = late[high],
        median = late[middle],
        early = late[last] == ~cast[u64](0),
    }
}

/**
 * Run the waker on a high-priority budget of PERIOD split off the root, measure, and log the numbers.
 *
 * @param t The test's state.
 * @param given What main was given.
 * @param what What the run is, for its log line, as "idle" or "under load".
 * @param cpus The CPUs the waker's kept to, a bit for each, as cpu_budget_set_cpus takes them; 0 for any.
 * @return Its numbers; an error if the budget couldn't be made or the waits couldn't be.
 */
run :: fn(t : ptr[mut testing.T], given : ptr[Given], what : string, cpus : u64 = 0) -> Result[Lateness, testing.Stopped] {
    root :: testing.require_some(t, given.cpu_budget, "the root task grants the root CPU budget")?
    block :: slop_os.startup_block()
    waking :: testing.require_ok(
        t,
        slop_os.cpu_budget_create(root, block.budget, WAKER_PRIORITY, PERIOD, WAKER_TIME),
        "the waker's budget, a quarter of a CPU every 2 ms at priority 250"
    )?
    defer slop_os.handle_close(cast[slop_os.Handle](waking))
    if cpus != 0 {
        testing.require_ok(t, slop_os.cpu_budget_set_cpus(waking, u64.[cpus]), "the waker's budget is kept to its CPUs")?
    }
    testing.require_ok(t, slop_os.thread_use_cpu_budget(waking), "the waker runs on its budget")?
    late, made :: runtime.new_array(u64, WAKES)
    if made != null {
        _ = slop_os.thread_use_cpu_budget(cast[slop_os.CpuBudget](slop_os.NO_HANDLE))
        testing.fail(t, "no memory for the wakes")
        return .Error(.Failed)
    }
    defer runtime.free_array(late)
    measured :: measure(late)
    _ = slop_os.thread_use_cpu_budget(cast[slop_os.CpuBudget](slop_os.NO_HANDLE))
    testing.require(t, measured, "each wait could be made")?
    numbers :: summed(late)
    log_line.write(
        given.log,
        "%: %, % wakes every 2 ms: worst % us, 99.9th % us, median % us",
        NAME,
        what,
        WAKES,
        numbers.worst / 1000,
        numbers.high / 1000,
        numbers.median / 1000
    )
    return .Ok(numbers)
}

/**
 * Say how late the waker wakes with the CPUs idle, on any CPU, kept to the boot CPU, which always ticks, and kept to
 * CPU 1, which stops ticking while it's idle (decisions/0128): never before its deadline; how late is logged, not held
 * to, as an emulator's host decides it.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the root budget, or a budget couldn't be made.
 */
wakes_for_its_deadlines_with_the_cpus_idle #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    numbers :: run(t, given, "idle")?
    testing.expect(t, !numbers.early, "no wake comes before its deadline")
    on_boot_cpu :: run(t, given, "idle on CPU 0", 1)?
    testing.expect(t, !on_boot_cpu.early, "nor on the boot CPU")
    on_cpu_1 :: run(t, given, "idle on CPU 1", 2)?
    testing.expect(t, !on_cpu_1.early, "nor on a CPU that stops ticking while it's idle")
    return .Ok
}

/**
 * Check how late the waker wakes while a spinner on a lower-priority budget runs on every CPU, which its priority
 * preempts: never before its deadline, and 999 wakes in 1000 within LOADED_BOUND.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the root budget, or a budget or a spinner couldn't be made.
 */
wakes_for_its_deadlines_with_every_cpu_busy #test :: fn(t : ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    root :: testing.require_some(t, given.cpu_budget, "the root task grants the root CPU budget")?
    whole :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    cpus :: cast[usize](whole.share / WHOLE_CPU)
    block :: slop_os.startup_block()
    // Every CPU's time but the waker's and a little, so the split fits; past it, the spinners run in the background
    spare :: whole.share - WHOLE_CPU / 2
    spinner_time :: (10 * MILLISECOND * spare) / WHOLE_CPU
    // On the heap, as the spinners' threads have it
    spinning :: runtime.new(Spinning)
    defer runtime.free(spinning)
    spinning.budget = testing.require_ok(
        t,
        slop_os.cpu_budget_create(root, block.budget, SPINNER_PRIORITY, 10 * MILLISECOND, spinner_time),
        "the spinners' budget, nearly every CPU at priority 10"
    )?
    defer slop_os.handle_close(cast[slop_os.Handle](spinning.budget))
    count :: if cpus > MAX_SPINNERS { MAX_SPINNERS } else { cpus }
    threads : ptr[mut runtime.Thread][MAX_SPINNERS]
    started := cast[usize](0)
    for i in 0..<count {
        if i < threads.count {
            threads[i] = runtime.thread_create(spin, spinning)
            if runtime.thread_start(threads[i]) {
                started += 1
            }
        }
    }
    testing.expect_eq(t, started, count, "a spinner for each CPU")
    // Each spinning before the waker starts
    deadline :: (slop_os.clock_monotonic() or_else 0) + 5_000 * MILLISECOND
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.atomic_load_u64_acquire(&spinning.started) < cast[u64](started)
        && (slop_os.clock_monotonic() or_else deadline) < deadline
    numbers :: run(t, given, "under load")
    intrinsics.atomic_store_u64_release(&spinning.stop, 1)
    for i in 0..<started {
        if i < threads.count {
            runtime.thread_join(threads[i])
        }
    }
    measured :: numbers?
    testing.expect(t, !measured.early, "no wake comes before its deadline")
    testing.expect_lt(t, measured.high, LOADED_BOUND, "999 wakes in 1000 come within half a tick, the spinners preempted")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test and each run's numbers are reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget The root CPU budget, which the tests split; without it they fail.
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
    given :: Given.{log = log, cpu_budget = cpu_budget}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
