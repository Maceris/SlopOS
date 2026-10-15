/*
 * The boot adapter for the Limine boot protocol (L0, docs/specs/boot_info.md, Limine): the kernel's
 * entry point. It sets up a carrier block and the boot context, turns Limine's responses into a
 * BootInfo, and calls the portable kernel entry.
 */
package limine_boot

import intrinsics from "base"
import runtime from "base"
import boot_info from "../../boot_info"
import kernel from "../../kernel"

#if TARGET_ARCH == .x86_64 {
    import arch from "../../arch/x86_64"
}

/*
 * A logger for the boot context, writing straight to the architecture's early console. Only the
 * boot CPU runs while it's in use, so it needs no lock.
 */
EARLY_LOGGER :: runtime.Logger.{
    data = null,
    trace = early_log,
    debug = early_log,
    info = early_log,
    warn = early_log,
    error = early_log,
    fatal = early_log,
    name = "early",
}

//HEMERA(gap): any values carry no type information yet, so parameters can't be formatted
early_log : runtime.LogFunction : fn(format_string: string, params: any..., location := #caller_location) {
    arch.early_console_write("[boot] ")
    arch.early_console_write(format_string)
    arch.early_console_write("\n")
}

/*
 * Where Limine enters the kernel, on the boot CPU's boot stack, with interrupts disabled. It runs
 * without a carrier block or a context, so the first thing it does is set both up.
 */
kernel_entry :: fn() #never_returns {
    /*
     * The carrier block lives on the boot stack, which stays in use until the kernel goes idle.
     * Limine gives every CPU a stack of BOOT_STACK_SIZE bytes (the stack size request), and this
     * runs at its very start, so its lowest address is less than BOOT_STACK_SIZE below this local.
     */
    //HEMERA(gap): no way to read the stack pointer, so the limit is worked out from a local's
    //address, leaving BOOT_STACK_SLACK for what Limine and this frame already use. This function has
    //no context yet, so it can't call a function to do it either.
    carrier : runtime.CarrierBlock
    carrier.stack_limit = cast[rawptr](cast[u64](&carrier) - BOOT_STACK_SIZE + BOOT_STACK_SLACK + runtime.STACK_GUARD)
    carrier.native_stack_limit = carrier.stack_limit
    intrinsics.set_carrier(&carrier)
    push_context boot from runtime.MINIMAL_CONTEXT {
        push_context early (logger = &EARLY_LOGGER, log_level = .INFO) {
            arch.early_console_init()
            info : boot_info.BootInfo
            build_boot_info(&info)
            kernel.boot(&info)
        }
    }
}

BOOT_STACK_SLACK :: 4096
