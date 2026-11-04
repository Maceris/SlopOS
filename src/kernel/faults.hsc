package kernel

import intrinsics from "base"
import robustness from "../robustness"

/**
 * Log where a failure point failed from, as a stack trace: the kernel's robustness.Faults.on_fail.
 *
 * Called by robustness.fails on the pass that fails, so a run that goes wrong after it shows which caller took the
 * injected failure. The trace starts at the caller of robustness.fails.
 */
log_failure :: fn() {
    log_stack_trace(1)
}

/**
 * Count a pass through one of the kernel's own failure points, and tell whether it fails (robustness.fails,
 * decisions/0096).
 *
 * Callable from any CPU and context; counting is atomic.
 *
 * @param point The failure point being passed through.
 * @return True if fail= on the command line asked for this pass to fail, which the caller treats as the resource
 *     running out; false otherwise, always without robustness=on, and before this CPU has the kernel's state, when
 *     the pass isn't counted.
 */
fails :: fn(point: robustness.Point) -> bool {
    #if robustness.ON {
        if intrinsics.carrier().program_data == null {
            return false
        }
        return robustness.fails(&per_cpu().kernel.frames.faults, point)
    }
    #else {
        return false
    }
}
