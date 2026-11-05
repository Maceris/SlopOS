/**
 * test_io_ports (roadmap 9a, decisions/0093): ranges of I/O ports, made with the platform capability.
 * On x86-64:
 * - the RTC's two ports, 0x70 and 0x71, as a range: its status register A read through them says its divider runs
 *   its 32.768 kHz clock (DV = 010);
 * - a port past the range, and a width that isn't 1, 2 or 4, are refused;
 * - a range past the last port is refused.
 * On AArch64, which has no ports, every range is refused.
 * What the ranges charged their budget comes back.
 */
package test_io_ports

import compiler from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_io_ports"
/** The RTC's first port, its index register; its data register is the next. */
RTC_PORTS : u32 : 0x70
/** The index of the RTC's status register A, written to the index port to read it through the data port. */
RTC_STATUS_A : u32 : 0x0a

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
    /** The platform capability, which makes port ranges; none if main wasn't given it. */
    platform : slop_os.Platform?,
}

/**
 * Check ranges of I/O ports: on x86-64, the RTC read through one, and ports and widths outside it refused, as is a
 * range past the last port; on AArch64, every range refused. Then what the ranges charged their budget comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the platform capability, or the budget couldn't be made.
 */
port_ranges_reach_only_their_ports #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    hardware :: testing.require_some(t, given.platform, "the root task grants the platform capability, which makes port ranges")?
    memory :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the ranges")?
    #if TARGET_ARCH == .x86_64 {
        rtc :: testing.require_ok(t, slop_os.io_ports_create(hardware, memory, RTC_PORTS, 2), "the platform capability makes a range of the RTC's two ports")?
        // Register A, its divider in bits 4 to 6
        selected :: slop_os.io_port_write(rtc, 0, 1, RTC_STATUS_A)
        testing.expect_ok(t, selected, "the range's first port, the RTC's index register, can be written")
        status :: slop_os.io_port_read(rtc, 1, 1)
        testing.expect_ok(t, status, "the range's second port, the RTC's data register, can be read")
        testing.expect_eq(t, (status or_else 0) & 0x70, 0x20, "register A's divider is 010, running the RTC's 32.768 kHz clock, so the read reached the RTC")
        past :: slop_os.io_port_read(rtc, 2, 1)
        testing.expect_error(t, past, slop_os.DeviceError.InvalidArgument, "a port past the range's end is outside it")
        odd_width :: slop_os.io_port_read(rtc, 0, 3)
        testing.expect_error(t, odd_width, slop_os.DeviceError.InvalidArgument, "a port is read 1, 2 or 4 bytes wide, never 3")
        past_last :: slop_os.io_ports_create(hardware, memory, 0xffff, 2)
        testing.expect_error(t, past_last, slop_os.DeviceError.InvalidArgument, "a range can't run past the last port, 0xffff")
        _ = slop_os.handle_close(cast[slop_os.Handle](rtc))
    }
    #else {
        refused :: slop_os.io_ports_create(hardware, memory, RTC_PORTS, 2)
        testing.expect_error(t, refused, slop_os.DeviceError.InvalidArgument, "AArch64 has no I/O ports, so every range is refused")
    }
    testing.expect(t, test_kit.wait_for_budget(memory, 0, 1_000_000_000), "the budget is back to nothing once the ranges are closed")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform The platform capability, which makes port ranges; without it the test fails.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log, platform = platform}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
