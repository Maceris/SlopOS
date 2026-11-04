package kernel

import runtime from "base"
import slop_os from "std/os"
import text_buffer from "std"

/*
 * Debug logs (decisions/0058, 0060): lines a program writes in the kernel's log, for reporting before
 * there's a console (M7). It's an object like any, so a program writes lines only if it's given one: the
 * root task gets the first, and can pass handles to it on.
 */

/**
 * A debug log object: the right to write lines in the kernel's log. It holds nothing but its header, since the lines
 * go straight to the console.
 */
DebugLog :: struct #align(16) {
    /** The object's header, shared by every kind of kernel object. */
    header : ObjectHeader,
}

/**
 * Make a debug log owned by a process, charged to the root budget, and give the process an owning handle to it.
 *
 * @param kernel The kernel, whose root budget pays for the object.
 * @param process The process that owns the log and gets the handle.
 * @return The owning handle, in the process's table. Null if the object couldn't be made, or the process is going away
 *     (the object is destroyed again); or if the handle couldn't be installed, when the object stays owned by the
 *     process, without a handle, until the process is destroyed.
 */
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

/**
 * Destroy a debug log's state, at destroy_object: nothing to do, as it has none.
 *
 * @param kernel The kernel destroying it, as destroy_object passes it for every kind; unused, as a log holds nothing
 *     of the kernel's.
 * @param log The log being destroyed, already dying; its memory stays its kind's until the grace period passes.
 */
destroy_debug_log :: fn(kernel: ptr[mut Kernel], log: ptr[mut DebugLog]) {
}

/**
 * Release a debug log's memory-held state, at release_object: nothing to do, as it has none.
 *
 * @param kernel The kernel releasing it, as release_object passes it for every kind; unused, as a log holds nothing
 *     of the kernel's.
 * @param log The log, destroyed and past its grace period; release_object frees its slot after this returns.
 */
release_debug_log :: fn(kernel: ptr[mut Kernel], log: ptr[mut DebugLog]) {
}

/**
 * Write a line in the kernel's log for a thread's process (the debug_log system call).
 *
 * The line is "[user] " and the text's first DEBUG_LOG_LINE bytes, anything that isn't printable ASCII written as
 * '?', so a program can't write past its line or move the cursor. It goes to the early console and the framebuffer
 * console under the console lock, so it doesn't mix with other lines.
 *
 * @param thread The calling thread, whose process's handle table holds the log and whose space holds the text.
 * @param log A handle to a debug log, with RIGHT_DEBUG_LOG_WRITE.
 * @param text The line, in the thread's address space; bytes past DEBUG_LOG_LINE are dropped, and an empty one writes
 *     an empty line.
 * @error InvalidHandle The handle isn't one in the process's table.
 * @error WrongKind The handle isn't to a debug log.
 * @error MissingRight The handle lacks RIGHT_DEBUG_LOG_WRITE.
 * @error ObjectGone The log is being destroyed.
 * @error BadBuffer The text isn't readable in the thread's address space; nothing is written.
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
