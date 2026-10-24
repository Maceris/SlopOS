/*
 * A line in the kernel's log, formatted, through a debug log handle (decisions/0060): how the first
 * services report before there's a console (M7).
 *
 *     log_line.write(log, "supervisor: % started", name)
 */
package log_line

import slop_os from "std/os"
import text_buffer from "std"

write :: fn(log: slop_os.DebugLog, format: string, values: any...) {
    storage : u8[200]
    line := text_buffer.make(storage)
    text_buffer.append_format(&line, format, values)
    text :: text_buffer.as_string(&line)
    _ = slop_os.debug_log(log, view_of(cast[ptr[u8]](text.data), text.count))
}
