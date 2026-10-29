/*
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

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_io_ports"
RTC_PORTS : u32 : 0x70
RTC_STATUS_A : u32 : 0x0a

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    hardware :: platform or_return 100
    memory :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    invalid :: test_kit.tag(slop_os.DeviceError.InvalidArgument)
    #if TARGET_ARCH == .x86_64 {
        results : u64[8]
        ports :: slop_os.io_ports_create(hardware, memory, RTC_PORTS, 2)
        results[0] = test_kit.tag_of(ports)
        rtc :: ports or_else test_kit.handle_at[slop_os.IoPortRange](0)
        // Register A, its divider in bits 4 to 6
        results[1] = test_kit.tag_of(slop_os.io_port_write(rtc, 0, 1, RTC_STATUS_A))
        status :: slop_os.io_port_read(rtc, 1, 1)
        results[2] = test_kit.tag_of(status)
        results[3] = cast[u64]((status or_else 0) & 0x70)
        results[4] = test_kit.tag_of(slop_os.io_port_read(rtc, 2, 1))
        results[5] = test_kit.tag_of(slop_os.io_port_read(rtc, 0, 3))
        results[6] = test_kit.tag_of(slop_os.io_ports_create(hardware, memory, 0xffff, 2))
        _ = slop_os.handle_close(cast[slop_os.Handle](rtc))
        results[7] = if test_kit.wait_for_budget(memory, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
        expected :: u64.[0, 0, 0, 0x20, invalid, invalid, invalid, 1]
        failed :: test_kit.check(log, NAME, results, expected)
        if failed == 0 {
            log_line.write(log, "%: the RTC's status read through its ports, and ports outside them refused", NAME)
        }
        return failed
    }
    #else {
        results : u64[2]
        results[0] = test_kit.tag_of(slop_os.io_ports_create(hardware, memory, RTC_PORTS, 2))
        results[1] = if test_kit.wait_for_budget(memory, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
        failed :: test_kit.check(log, NAME, results, u64.[invalid, 1])
        if failed == 0 {
            log_line.write(log, "%: no ports here, and every range refused", NAME)
        }
        return failed
    }
}
