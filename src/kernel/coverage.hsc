package kernel

import intrinsics from "base:intrinsics"
import slop_os from "std:os/slop_os"

/**
 * Take the kernel's coverage counters into the caller's buffer, and zero them (decisions/0186, He): only in a kernel
 * built with them (the build's coverage=on), for the system call fuzzer. The counters are bumped by every CPU without
 * synchronization, so a take is a snapshot of approximately the code run since the last.
 *
 * @param thread The calling thread, whose address space the counters are copied into.
 * @param log The kernel's debug log, with RIGHT_DEBUG_LOG_TRACE, as the trace needs: the counters show what every
 *     process's calls ran in the kernel.
 * @param counters Where they go; as many as it holds, the first ones only if it's shorter than the kernel's.
 * @return How many counters the kernel has.
 * @error InvalidHandle The log isn't a handle in the caller's table.
 * @error ObjectGone The log was destroyed.
 * @error WrongKind Not the debug log's handle.
 * @error MissingRight The handle lacks RIGHT_DEBUG_LOG_TRACE.
 * @error BadBuffer counters isn't the caller's to write.
 * @error NotCounted The kernel wasn't built with coverage counters.
 */
sys_coverage_take :: fn(
    thread : ptr[mut Thread],
    log : slop_os.DebugLog,
    counters : slop_os.UserBuffer
) -> Result[u64, slop_os.CoverageError] {
    _ = object_of[slop_os.CoverageError](
        process_of(thread),
        cast[slop_os.Handle](log),
        .DebugLog,
        slop_os.RIGHT_DEBUG_LOG_TRACE
    )?
    counted :: intrinsics.coverage_counters()
    if counted.count == 0 {
        return .Error(.NotCounted)
    }
    count :: if counters.count < cast[u64](counted.count) { counters.count } else { cast[u64](counted.count) }
    if count > 0
        && !copy_to_user(
            per_cpu().kernel,
            thread.space,
            counters.address,
            cast[u64](cast[uintptr](&counted[0])),
            count
        ) {
        return .Error(.BadBuffer)
    }
    intrinsics.mem_zero(cast[mut rawptr](&counted[0]), counted.count)
    return .Ok(cast[u64](counted.count))
}
