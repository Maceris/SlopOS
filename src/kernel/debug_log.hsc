package kernel

import runtime from "base"
import slop_os from "std/os"
import text_buffer from "std"

/*
 * Debug logs (decisions/0058, 0060): lines a program writes in the kernel's log, for reporting before
 * there's a console (M7). It's an object like any, so a program writes lines only if it's given one: the
 * root task gets the first, and can pass handles to it on.
 */

DebugLog :: struct #align(16) {
    header : ObjectHeader,
}

// A debug log owned by process, charged to the root budget: an owning handle to it.
create_debug_log :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) -> slop_os.Handle? {
    object :: new_object(kernel, .DebugLog, kernel.root_budget, 0) or_return null
    match adopt(cast[u64](process), object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return null
        }
    }
    return handle_for(kernel, process, object, .DebugLog, true)
}

destroy_debug_log :: fn(kernel: ptr[mut Kernel], log: ptr[mut DebugLog]) {
}

release_debug_log :: fn(kernel: ptr[mut Kernel], log: ptr[mut DebugLog]) {
}

/*
 * A line in the kernel's log, its first DEBUG_LOG_LINE bytes, after "[user] ": anything that isn't
 * printable ASCII written as '?', so a program can't write past its line or move the cursor.
 */
sys_debug_log :: fn(thread: ptr[mut Thread], log: slop_os.DebugLog, text: slop_os.UserBuffer) -> Result[void, slop_os.HandleError] {
    kernel :: per_cpu().kernel
    _ = object_of[slop_os.HandleError](process_of(thread), cast[slop_os.Handle](log), .DebugLog, slop_os.RIGHT_DEBUG_LOG_WRITE)?
    bytes : u8[slop_os.DEBUG_LOG_LINE]
    count :: min_u64(text.count, slop_os.DEBUG_LOG_LINE)
    if count > 0 && !copy_from_user(kernel, thread.space, text.address, cast[u64](&bytes[0]), count) {
        return .Error(.BadBuffer)
    }
    storage : u8[slop_os.DEBUG_LOG_LINE + 16]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "[user] ")
    for byte, i in bytes {
        if cast[u64](i) >= count {
            break
        }
        text_buffer.append_byte(&line, if byte >= 0x20 && byte < 0x7f { byte } else { cast[u8]('?') })
    }
    text_buffer.append(&line, "\n")
    write_console(text_buffer.as_string(&line))
    return .Ok
}
