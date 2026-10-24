package kernel

import intrinsics from "base"
import runtime from "base"
import text_buffer from "std"
import console from "console"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * The kernel's logger: one line per message on the architecture's early console, prefixed with
 * its level, and with the source location for warnings and worse. Lines from different CPUs don't
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

log_trace : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("trace", null, format_string, params)
}

log_debug : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("debug", null, format_string, params)
}

log_info : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("info", null, format_string, params)
}

log_warn : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("warn", location, format_string, params)
}

log_error : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("error", location, format_string, params)
}

log_fatal : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("fatal", location, format_string, params)
}

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
}

append_location :: fn(line: ptr[mut text_buffer.TextBuffer], location: runtime.SourceCodeLocation) {
    text_buffer.append(line, " at ")
    text_buffer.append(line, location.file_path)
    text_buffer.append(line, ":")
    text_buffer.append_unsigned(line, cast[u64](location.line))
}

/*
 * Write text to the early console and the framebuffer console, holding the console lock once the
 * CPU has a PerCpu. Before that, only the boot CPU runs.
 */
write_console :: fn(text: string) {
    if intrinsics.carrier().program_data == null {
        arch.early_console_write(text)
        return void
    }
    kernel :: per_cpu().kernel
    concurrency.lock(&kernel.console_lock)
    arch.early_console_write(text)
    if kernel.has_framebuffer_console {
        console.write(&kernel.framebuffer_console, text)
    }
    concurrency.unlock(&kernel.console_lock)
}

/*
 * A failed assertion stops the kernel: it reports where, with a stack trace, and stops every CPU.
 */
kernel_assertion_handler : runtime.AssertionHandler : fn(location: runtime.SourceCodeLocation, message: string) #never_returns {
    write_log_line("fatal", location, "assertion failed: %", message)
    // From where the assertion failed (runtime.assert, or the function it was inlined into)
    log_stack_trace()
    stop(.AssertionFailed)
}
