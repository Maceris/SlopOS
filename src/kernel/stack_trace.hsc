package kernel

import intrinsics from "base"
import text_buffer from "std"

// How many frames a stack trace shows.
STACK_TRACE_FRAMES :: 32

/*
 * Log the current call stack, innermost first, starting with the caller of the function that calls
 * this (and skip more). Addresses are relative to the kernel image's base, so traces from different
 * boots compare, whatever KASLR chose (decisions/0021); match them with the ELF's symbols.
 */
log_stack_trace :: fn(skip: usize = 0) {
    addresses : rawptr[STACK_TRACE_FRAMES]
    // One more for this function's own frame
    count :: intrinsics.capture_stack_trace(addresses, skip + 1)
    image_base := cast[u64](0)
    if intrinsics.carrier().program_data != null {
        image_base = per_cpu().kernel.image_base
    }
    storage : u8[64]
    line := text_buffer.make(storage)
    for i in 0..<count {
        text_buffer.clear(&line)
        text_buffer.append(&line, "  at ")
        address :: cast[u64](addresses[i])
        if image_base != 0 && address >= image_base {
            text_buffer.append(&line, "kernel+0x")
            text_buffer.append_unsigned(&line, address - image_base, 16)
        }
        else {
            text_buffer.append_address(&line, address)
        }
        // Part of a fatal report already, so without a source location of its own
        write_log_line("fatal", text_buffer.as_string(&line), 0, #caller_location, false)
    }
}
