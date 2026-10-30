package kernel

import intrinsics from "base"
import robustness from "../robustness"

// Where a failure point failed from (robustness.Faults.on_fail), for a run that goes wrong after it.
log_failure :: fn() {
    log_stack_trace(1)
}

/*
 * Whether this pass through a failure point of the kernel's own fails (robustness.fails, decisions/0096): always false
 * without robustness=on, and before this CPU has the kernel's state.
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
