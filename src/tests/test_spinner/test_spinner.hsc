/**
 * test_spinner (decisions/0196, 17e): load, a spinner flat out on each of SPINNERS threads, each with no CPU budget, in
 * the background band under every budget, until the system shuts down. Started by the supervisor with test_sound_load
 * on the kernel's command line, so the audio service and its clients are measured with every CPU busy: they keep their
 * time, and what has spent its own shares the background band with the spinners. Its four stacks take a MiB of its
 * budget of four.
 */
package test_spinner

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import slop_os from "std:os/slop_os"
import service_kit from "../../libraries/service_kit"

/** How many spinners: more than the CPUs the boot tests give, so each is busy. */
SPINNERS : usize : 4

/**
 * Spin, flat out, with no CPU budget, until the process ends.
 *
 * @param data Nothing.
 */
spin :: fn(data #escaping : any) {
    // Off the default budget, which the main thread keeps, and on to the background band
    _ = slop_os.thread_use_cpu_budget(cast[slop_os.CpuBudget](slop_os.NO_HANDLE))
    loop {
        intrinsics.spin_hint()
    }
}

/**
 * Start the spinners, then wait to be asked to stop, as the system shuts down.
 *
 * @param log The debug log, where how many started is said.
 * @return 0 once asked to stop; 2 without a port.
 */
main :: fn(log : slop_os.DebugLog?) -> int {
    startup :: slop_os.startup_block()
    port :: slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(port)
    started := cast[usize](0)
    for i in 0..<SPINNERS {
        if runtime.thread_start(runtime.thread_create(spin)) {
            started += 1
        }
    }
    runtime.log_info("% spinners started, in the background band", started)
    loop {
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[2]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}
