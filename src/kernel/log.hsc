package kernel

import intrinsics from "base"
import runtime from "base"
import text_buffer from "std"
import console from "console"
import concurrency from "std"
import boot_info from "../boot_info"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/**
 * The kernel's logger: one line per message on the architecture's early console and the framebuffer console,
 * prefixed with its level, and with the source location for warnings and worse. Lines from different CPUs don't
 * mix, since writing a line holds the kernel's console lock.
 *
 * Each % in the message is replaced by the next parameter (std's text_buffer.append_format).
 */
KERNEL_LOGGER :: runtime.Logger.{
    data = null,
    trace = log_trace,
    debug = log_debug,
    info = log_info,
    warn = log_warn,
    error = log_error,
    fatal = log_fatal,
    name = "kernel",
}

/**
 * Log a trace line: the kernel logger's trace function.
 *
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 * @param location Where the call was made from, not written for this level.
 */
log_trace : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("trace", null, format_string, params)
}

/**
 * Log a debug line: the kernel logger's debug function.
 *
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 * @param location Where the call was made from, not written for this level.
 */
log_debug : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("debug", null, format_string, params)
}

/**
 * Log a info line: the kernel logger's info function.
 *
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 * @param location Where the call was made from, not written for this level.
 */
log_info : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("info", null, format_string, params)
}

/**
 * Log a warn line: the kernel logger's warn function.
 *
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 * @param location Where the call was made from, written after the message.
 */
log_warn : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("warn", location, format_string, params)
}

/**
 * Log a error line: the kernel logger's error function.
 *
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 * @param location Where the call was made from, written after the message.
 */
log_error : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("error", location, format_string, params)
}

/**
 * Log a fatal line: the kernel logger's fatal function. It doesn't stop the kernel; the line is also kept in the panic
 * record, once there's a kernel with one.
 *
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 * @param location Where the call was made from, written after the message.
 */
log_fatal : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("fatal", location, format_string, params)
}

/**
 * Write one line of the log: "[level] ", the message, the location if there is one, and a line feed.
 *
 * The line is built on the stack, at most 256 bytes; a longer one is cut short and ends in "...". Callable from any
 * context, before the kernel has state too. A fatal line also goes in the panic record.
 *
 * @param level The level's name, as written in the brackets; "fatal" is what puts it in the panic record.
 * @param location Where the line was logged from, written as " at <file>:<line>"; null for none.
 * @param format_string The message, each % in it replaced by the next parameter (text_buffer.append_format).
 * @param params The values that replace the message's %, in order.
 */
write_log_line :: fn(level: string, location: runtime.SourceCodeLocation?, format_string: string, params: any...) {
    storage : u8[256]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "[")
    text_buffer.append(&line, level)
    text_buffer.append(&line, "] ")
    text_buffer.append_format(&line, format_string, params)
    match location {
        case Some(where) => append_location(&line, where)
        case None => {}
    }
    if line.truncated {
        text_buffer.append(&line, "...")
    }
    text_buffer.append(&line, "\n")
    write_console(text_buffer.as_string(&line))
    if level == "fatal" {
        keep_in_panic_record(text_buffer.as_string(&line))
    }
}

/**
 * Keep a fatal line in the panic record, so the next boot can report it (decisions/0134).
 *
 * Nothing is kept before this CPU has the kernel's state, or when there's no panic record. Takes the console lock
 * while it adds, so lines from different CPUs don't mix.
 *
 * @param text The line, as much of it kept as the record has room for.
 */
keep_in_panic_record :: fn(text: string) {
    if intrinsics.carrier().program_data == null {
        return void
    }
    kernel :: per_cpu().kernel
    if kernel.panic_record != 0 {
        lock_at(&kernel.console_lock, .Console)
        boot_info.panic_record_add(cast[ptr[mut boot_info.PanicRecord]](kernel.panic_record), text)
        unlock_at(&kernel.console_lock, .Console)
    }
}

/**
 * Append " at <file>:<line>" to a log line.
 *
 * @param line The line being built; truncated, as a text buffer is, if it's full.
 * @param location The source location written.
 */
append_location :: fn(line: ptr[mut text_buffer.TextBuffer], location: runtime.SourceCodeLocation) {
    text_buffer.append(line, " at ")
    text_buffer.append(line, location.file_path)
    text_buffer.append(line, ":")
    text_buffer.append_unsigned(line, cast[u64](location.line))
}

/**
 * Write text to the early console, and to the framebuffer console once there is one.
 *
 * Once this CPU has a PerCpu it holds the console lock (LockRank Console) while it writes, so writes from different
 * CPUs don't mix; the caller mustn't hold it already. Before that, only the boot CPU runs, and the text goes to the
 * early console alone, unlocked.
 *
 * @param text The text, UTF-8, written as it is; line feeds start new lines.
 */
write_console :: fn(text: string) {
    if intrinsics.carrier().program_data == null {
        arch.early_console_write(text)
        return void
    }
    kernel :: per_cpu().kernel
    lock_at(&kernel.console_lock, .Console)
    arch.early_console_write(text)
    if kernel.has_framebuffer_console {
        console.write(&kernel.framebuffer_console, text)
    }
    unlock_at(&kernel.console_lock, .Console)
}

/**
 * Stop the kernel at a failed assertion: the kernel's assertion handler.
 *
 * Logs a fatal line with the message and where, and a stack trace from where the assertion failed, then stops every
 * CPU with AssertionFailed.
 *
 * @param location Where the assertion failed.
 * @param message What the assertion says, logged after "assertion failed: ".
 */
kernel_assertion_handler : runtime.AssertionHandler : fn(location: runtime.SourceCodeLocation, message: string) #never_returns {
    write_log_line("fatal", location, "assertion failed: %", message)
    // From where the assertion failed (runtime.assert, or the function it was inlined into)
    log_stack_trace()
    stop(.AssertionFailed)
}
