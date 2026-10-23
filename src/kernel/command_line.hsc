package kernel

/*
 * The kernel's command line: words separated by spaces. Unknown words are ignored, so a command
 * line written for a newer kernel still boots an older one.
 */
Options :: struct {
    /*
     * test_exit: when the kernel stops, ask the emulator to exit with the reason's code
     * (arch_interface.test_exit). For tests that boot the kernel; never on real hardware.
     */
    test_exit : bool,
    /*
     * test_fault: once booted, run an invalid instruction instead of going idle, so a test can
     * check that kernel faults are reported and stop the kernel.
     */
    test_fault : bool,
    // test_assert: once booted, fail an assertion, so a test can check that assertions stop the kernel.
    test_assert : bool,
    // test_nmi: once booted, raise an NMI, so a test can check that the kernel resumes after one.
    test_nmi : bool,
    // test_fibers: once booted, run two fibers taking turns, to check fibers suspend and resume.
    test_fibers : bool,
    // test_segments: once booted, run a fiber that grows onto more stack segments (a morestack kernel).
    test_segments : bool,
    // test_pool: once booted, run two fiber pools on CPUs 1 to 5 (needs 6 CPUs).
    test_pool : bool,
    /*
     * test_write_code: once booted, write to the kernel's own code, so a test can check that its
     * page tables keep code read-only (W^X).
     */
    test_write_code : bool,
    // test_heap: once booted, allocate, resize and free blocks of many sizes from the kernel heap.
    test_heap : bool,
    /*
     * no_kaslr: lay out the kernel's own regions, like the kernel window, at the same addresses on
     * every boot (decisions/0021). The bootloader's configuration does the same for the image and the
     * direct map.
     */
    no_kaslr : bool,
    // test_clock: once booted, check the monotonic clock keeps time with the counter.
    test_clock : bool,
    // test_shootdown: once booted, change a mapping every CPU has used, and check they all see the change.
    test_shootdown : bool,
    // test_ioapic: once booted, route the emulator's test device through its interrupt controller.
    test_ioapic : bool,
    // test_threads: once booted, run threads in user mode on every CPU, preempted by the timer (needs 2 CPUs).
    test_threads : bool,
    // test_budgets: once booted, run a thread with a CPU budget against one without (on 1 CPU).
    test_budgets : bool,
    // test_syscalls: once booted, run a thread in user mode that makes system calls on handles.
    test_syscalls : bool,
    // test_ports: once booted, run two threads in user mode that wait on a port, wake it and set its timers.
    test_ports : bool,
    // test_channels: once booted, run two processes that pass handles and messages over channels.
    test_channels : bool,
    // test_memory: once booted, run two threads in user mode that use memory budgets and memory objects.
    test_memory : bool,
}

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
    if word == "no_kaslr" {
        options.no_kaslr = true
    }
    if word == "test_clock" {
        options.test_clock = true
    }
    if word == "test_shootdown" {
        options.test_shootdown = true
    }
    if word == "test_ioapic" {
        options.test_ioapic = true
    }
    if word == "test_threads" {
        options.test_threads = true
    }
    if word == "test_budgets" {
        options.test_budgets = true
    }
    if word == "test_syscalls" {
        options.test_syscalls = true
    }
    if word == "test_ports" {
        options.test_ports = true
    }
    if word == "test_memory" {
        options.test_memory = true
    }
    if word == "test_channels" {
        options.test_channels = true
    }
}
