package kernel

import robustness from "../robustness"

/**
 * The options the kernel's command line sets: words separated by spaces, each field named for its word. Unknown words
 * are ignored, so a command line written for a newer kernel still boots an older one. A flag absent is false.
 */
Options :: struct {
    /**
     * test_exit: when the kernel stops, ask the emulator to exit with the reason's code
     * (arch_interface.test_exit). For tests that boot the kernel; never on real hardware.
     */
    test_exit : bool,
    /**
     * test_fault: once booted, run an invalid instruction instead of going idle, so a test can
     * check that kernel faults are reported and stop the kernel.
     */
    test_fault : bool,
    /** test_assert: once booted, fail an assertion, so a test can check that assertions stop the kernel. */
    test_assert : bool,
    /** test_nmi: once booted, raise an NMI, so a test can check that the kernel resumes after one. */
    test_nmi : bool,
    /**
     * test_lockup: CPU 1 spins with interrupts off once booted, which lockup detection catches (decisions/0183); not on
     * the boot after its panic, which has its record.
     */
    test_lockup : bool,
    /**
     * test_lockup_lock: test_lockup, CPU 1 holding a lock as it stops, which CPU 0 then waits for at a tick, so its
     * wait for the lock is what catches it.
     */
    test_lockup_lock : bool,
    /**
     * test_tamper: once the boot CPU has gone idle, return through a tampered return address in the kernel, which its
     * signed returns or shadow stack refuse, stopping it with the fault named (decisions/0186, Hd); skipped, said so,
     * where the CPU has neither.
     */
    test_tamper : bool,
    /**
     * test_branch: once the boot CPU has gone idle, branch into the middle of a kernel function, which its landing
     * pads refuse, stopping it with the fault named (decisions/0186, Hd); skipped, said so, where the CPU has none.
     */
    test_branch : bool,
    /**
     * test_shadow_write: once the boot CPU has gone idle, write to its kernel shadow stack with an ordinary store, which
     * its pages refuse, stopping the kernel with a page fault (decisions/0186, Hd); skipped, said so, where it has none.
     */
    test_shadow_write : bool,
    /** trace_boot: the trace is on from the kernel's start, for a boot's timeline (decisions/0183, tracing.hsc). */
    trace_boot : bool,
    /** test_fibers: once booted, run two fibers taking turns, to check fibers suspend and resume. */
    test_fibers : bool,
    /** test_segments: once booted, run a fiber that grows onto more stack segments (a morestack kernel). */
    test_segments : bool,
    /** test_pool: once booted, run two fiber pools on CPUs 1 to 5 (needs 6 CPUs). */
    test_pool : bool,
    /**
     * test_write_code: once booted, write to the kernel's own code, so a test can check that its
     * page tables keep code read-only (W^X).
     */
    test_write_code : bool,
    /** test_heap: once booted, allocate, resize and free blocks of many sizes from the kernel heap. */
    test_heap : bool,
    /**
     * no_kaslr: lay out the kernel's own regions, like the kernel window, at the same addresses on
     * every boot (decisions/0021). The bootloader's configuration does the same for the image and the
     * direct map.
     */
    no_kaslr : bool,
    /** test_clock: once booted, check the monotonic clock keeps time with the counter. */
    test_clock : bool,
    /** test_shootdown: once booted, change a mapping every CPU has used, and check they all see the change. */
    test_shootdown : bool,
    /**
     * test_binding_reuse: once booted, unbind and bind one binding slot again and again while the other CPUs read it
     * without a lock, and check every read is whole.
     */
    test_binding_reuse : bool,
    /**
     * test_ownership_race: once booted, move objects from one process's owned list to another's while another CPU
     * destroys them, and check they end on neither list, and the lists whole.
     */
    test_ownership_race : bool,
    /**
     * test_tickless: once booted, count the timer interrupts of the CPUs other than the boot CPU, idle
     * (decisions/0128).
     */
    test_tickless : bool,
    /** test_ioapic: once booted, route the emulator's test device through its interrupt controller. */
    test_ioapic : bool,
    /**
     * test_device: grant the root task what the firmware tables say of the emulator's test device, and run the
     * device while an IRQ for its line exists, for the test_devices program (decisions/0069).
     */
    test_device : bool,
    /**
     * panic_reset: when the kernel stops for a fault, reset the machine rather than halt, so the boot after keeps its
     * panic record (boot_info.PanicRecord, decisions/0134); before test_exit.
     */
    panic_reset : bool,
    /**
     * test_power: when the root task ends with a power action asked for (power_end_with), do it even under test_exit,
     * rather than asking the emulator to exit, so a test sees the machine turned off or reset (decisions/0182).
     */
    test_power : bool,
    /**
     * test_panic_once: once booted, fail an assertion, unless the bootloader handed over the record of the last one.
     */
    test_panic_once : bool,
    /** no_root_task: don't start the root task from the first boot module (root_task.hsc). */
    no_root_task : bool,
    /**
     * kernel_reserve=<MiB>: how much of the memory free at boot the kernel keeps out of the root budget, for its own
     * allocations (decisions/0098), in MiB; 0, no such word, or a value that isn't a decimal number for the default,
     * a sixteenth of it and at least 8 MiB.
     */
    kernel_reserve_mib : u64,
    /**
     * fail=<point>:<n>, fail=any:<n> or fail=count: fault injection (robustness.hsc, decisions/0096), in a kernel built
     * with robustness=on only. Any other kernel ignores the word.
     */
    fail : robustness.FailSpec,
}

/**
 * Parse the kernel's command line into its options.
 *
 * Callable before the kernel has any state; it allocates nothing.
 *
 * @param command_line The words, separated by single spaces; the bootloader's string, read only while this runs.
 * @return The options the words set, every other one false or 0. A word given twice is applied twice, so the last
 *     kernel_reserve= or fail= wins.
 */
parse_command_line :: fn(command_line: string) -> Options {
    options : Options
    with {
        start : usize = 0
    }
    loop {
        end := start
        loop {
            end += 1
        }
        while end < command_line.count && command_line[end] != ' '
        if end > start {
            apply_option(&options, command_line[start..<end])
        }
        start = end + 1
    }
    while start < command_line.count
    return options
}

/**
 * Set the option a command line word names; a word that names none is ignored.
 *
 * @param options The options being parsed into; only the word's field changes.
 * @param word One word, without spaces. A flag's word has to match exactly; kernel_reserve= and fail= need a value
 *     after the =, and fail= is read only in a kernel built with robustness=on, its value ignored if fail_of can't
 *     parse it.
 */
apply_option :: fn(options: ptr[mut Options], word: string) {
    if word == "test_exit" {
        options.test_exit = true
    }
    if word == "test_fault" {
        options.test_fault = true
    }
    if word == "test_assert" {
        options.test_assert = true
    }
    if word == "test_nmi" {
        options.test_nmi = true
    }
    if word == "test_lockup" {
        options.test_lockup = true
    }
    if word == "test_lockup_lock" {
        options.test_lockup = true
        options.test_lockup_lock = true
    }
    if word == "test_tamper" {
        options.test_tamper = true
    }
    if word == "test_branch" {
        options.test_branch = true
    }
    if word == "test_shadow_write" {
        options.test_shadow_write = true
    }
    if word == "trace_boot" {
        options.trace_boot = true
    }
    if word == "test_fibers" {
        options.test_fibers = true
    }
    if word == "test_segments" {
        options.test_segments = true
    }
    if word == "test_pool" {
        options.test_pool = true
    }
    if word == "test_write_code" {
        options.test_write_code = true
    }
    if word == "test_heap" {
        options.test_heap = true
    }
    if word == "panic_reset" {
        options.panic_reset = true
    }
    if word == "test_power" {
        options.test_power = true
    }
    if word == "test_panic_once" {
        options.test_panic_once = true
    }
    if word == "no_root_task" {
        options.no_root_task = true
    }
    if word == "no_kaslr" {
        options.no_kaslr = true
    }
    if word == "test_clock" {
        options.test_clock = true
    }
    if word == "test_shootdown" {
        options.test_shootdown = true
    }
    if word == "test_binding_reuse" {
        options.test_binding_reuse = true
    }
    if word == "test_ownership_race" {
        options.test_ownership_race = true
    }
    if word == "test_tickless" {
        options.test_tickless = true
    }
    if word == "test_ioapic" {
        options.test_ioapic = true
    }
    if word == "test_device" {
        options.test_device = true
    }
    prefix :: "kernel_reserve="
    if word.count > prefix.count && word[0..<prefix.count] == prefix {
        options.kernel_reserve_mib = number_of(word[prefix.count..<word.count])
    }
    #if robustness.ON {
        fail :: "fail="
        if word.count > fail.count && word[0..<fail.count] == fail {
            match robustness.fail_of(word[fail.count..<word.count]) {
                case Some(spec) => options.fail = spec
                case None => {}
            }
        }
    }
}

/**
 * Read a decimal number.
 *
 * @param text The digits, with no sign or spaces.
 * @return Its value, or 0 if any character isn't a digit; a value past u64's range wraps around.
 */
number_of :: fn(text: string) -> u64 {
    value : u64 = 0
    for character in text {
        if character < '0' || character > '9' {
            return 0
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}
