package kernel

import intrinsics from "base"
import runtime from "base"
import text_buffer from "std"
import console from "console"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * The kernel's logger: one line per message on the architecture's early console, prefixed with
 * its level, and with the source location for warnings and worse. Lines from different CPUs don't
 * mix, since writing a line holds the kernel's console lock.
 *
 * Messages are written as they are, without their parameters.
 */
//HEMERA(gap): any values carry no type information yet, so parameters can't be formatted. Kernel
//code formats numbers into the message itself, with text_buffer, until they can.
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
    write_log_line("trace", format_string, params.count, null)
}

log_debug : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("debug", format_string, params.count, null)
}

log_info : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("info", format_string, params.count, null)
}

log_warn : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("warn", format_string, params.count, location)
}

log_error : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("error", format_string, params.count, location)
}

log_fatal : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    write_log_line("fatal", format_string, params.count, location)
}

write_log_line :: fn(level: string, message: string, parameter_count: usize, location: runtime.SourceCodeLocation?) {
    storage : u8[256]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "[")
    text_buffer.append(&line, level)
    text_buffer.append(&line, "] ")
    text_buffer.append(&line, message)
    if parameter_count > 0 {
        text_buffer.append(&line, " (")
        text_buffer.append_unsigned(&line, cast[u64](parameter_count))
        text_buffer.append(&line, " values not shown)")
    }
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
    lock(&kernel.console_lock)
    arch.early_console_write(text)
    if kernel.has_framebuffer_console {
        console.write(&kernel.framebuffer_console, text)
    }
    unlock(&kernel.console_lock)
}

/*
 * A failed assertion stops the kernel: it reports where, with a stack trace, and stops every CPU.
 */
kernel_assertion_handler : runtime.AssertionHandler : fn(location: runtime.SourceCodeLocation, message: string) #never_returns {
    storage : u8[256]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "assertion failed: ")
    text_buffer.append(&line, message)
    append_location(&line, location)
    runtime.log_fatal(text_buffer.as_string(&line))
    // From where the assertion failed (runtime.assert, or the function it was inlined into)
    log_stack_trace()
    stop(.AssertionFailed)
}
