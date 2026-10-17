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
}
