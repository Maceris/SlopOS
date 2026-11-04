package kernel

import intrinsics from "base"

/** The most frames a stack trace shows; deeper frames are left out. */
STACK_TRACE_FRAMES :: 32

/**
 * Log the current call stack as fatal lines, innermost first, at most STACK_TRACE_FRAMES of them.
 *
 * Addresses are relative to the kernel image's base, written kernel+<offset>, so traces from different boots compare,
 * whatever KASLR chose (decisions/0021); match them with the ELF's symbols. Before this CPU has the kernel's state,
 * or for an address below the image, the address is written whole. The lines have no source location, being part of
 * a fatal report already.
 *
 * @param skip How many frames to leave out after this function's own: 0 starts at the function that calls this.
 */
log_stack_trace :: fn(skip: usize = 0) {
    addresses : rawptr[STACK_TRACE_FRAMES]
    // One more for this function's own frame
    count :: intrinsics.capture_stack_trace(addresses, skip + 1)
    image_base := cast[u64](0)
    if intrinsics.carrier().program_data != null {
        image_base = per_cpu().kernel.image_base
    }
    for captured, i in addresses {
        if i >= count {
            break
        }
        address :: cast[u64](captured)
        // Part of a fatal report already, so without a source location of its own
        if image_base != 0 && address >= image_base {
            write_log_line("fatal", null, "  at kernel+%{#x}", address - image_base)
        }
        else {
            write_log_line("fatal", null, "  at %{#018x}", address)
        }
    }
}
