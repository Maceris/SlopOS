/**
 * A UEFI program (roadmap B1, decisions/0131, 0132): the test of Hemera's UEFI target, which boot.py --efi runs under
 * QEMU's UEFI firmware. It adds up numbers in memory from the boot services' pool, says so through base's logger on
 * the firmware's console, and turns the machine off.
 */
package uefi_hello

import runtime from "base"
import uefi from "std/os"

main :: fn() -> int {
    numbers : int[..]
    defer runtime.array_free(&numbers)
    for i in 0..<1000 {
        runtime.array_add(&numbers, i)
    }
    sum := 0
    for number in numbers {
        sum += number
    }
    runtime.log_info("uefi_hello: Hemera on UEFI, % numbers from the pool adding up to %", numbers.count, sum)
    uefi.reset(.Shutdown)
}
