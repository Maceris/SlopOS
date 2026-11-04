/**
 * A line in the kernel's log, formatted, through a debug log handle (decisions/0060): how the first
 * services report before there's a console (M7).
 *
 *     log_line.write(log, "supervisor: % started", name)
 */
package log_line

import slop_os from "std/os"
import text_buffer from "std"

/**
 * Write a formatted line in the kernel's log.
 *
 * The line is formatted into 200 bytes on the stack, so it needs no allocator; what doesn't fit is dropped, as the
 * kernel drops what's past DEBUG_LOG_LINE anyway. Failing to write it is ignored: there's nowhere else to report it.
 *
 * @param log The debug log, which needs RIGHT_DEBUG_LOG_WRITE; with an invalid one, nothing is written.
 * @param format The line, without its line break, each % replaced by the next value, as std's text_buffer
 *     append_format formats it.
 * @param values The values for format's placeholders, in order.
 */
write :: fn(log: slop_os.DebugLog, format: string, values: any...) {
    storage : u8[200]
    line := text_buffer.make(storage)
    text_buffer.append_format(&line, format, values)
    text :: text_buffer.as_string(&line)
    _ = slop_os.debug_log(log, string_bytes(text))
}
