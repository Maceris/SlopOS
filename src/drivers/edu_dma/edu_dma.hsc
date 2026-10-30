/*
 * edu_dma (decisions/0084): a driver for QEMU's edu device that isn't trusted, and DMAs outside its domain on purpose,
 * for the test that it's stopped. It makes a page of DMA memory, which no IOMMU confining its device refuses, as it
 * isn't trusted (it says so, and ends with 0); then it has edu copy its buffer to 64 MiB past that page, where nothing
 * of its domain is mapped, and waits. The IOMMU blocks the write, the kernel raises SIGNAL_DMA_FAULT on its Device,
 * and the supervisor kills it, and starts it again, until it's ended too often.
 */
package edu_dma

import runtime from "base"
import intrinsics from "base"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import pci from "../../pci"

PAGE : u64 : 4096
// Where it writes: this far past its page, which nothing of its domain reaches
OUTSIDE : u64 : 64 << 20
// edu's DMA engine (QEMU's docs/specs/edu.rst): source, destination, count and command, and its own buffer
DMA_SOURCE : u64 : 0x80
DMA_DESTINATION : u64 : 0x88
DMA_COUNT : u64 : 0x90
DMA_COMMAND : u64 : 0x98
EDU_BUFFER : u64 : 0x40000
DMA_START : u64 : 1 << 0
DMA_TO_RAM : u64 : 1 << 1
// How long it waits to be stopped, before it says it wasn't
WAIT_NANOSECONDS : u64 : 10_000_000_000

main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain) -> int {
    block :: slop_os.startup_block()
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    config_at :: driver_kit.map_device(config) or_return 2
    edu :: driver_kit.map_bar(bar0)
    if edu == 0 {
        return 3
    }
    memory := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match slop_os.dma_memory_create(domain, block.budget, PAGE, 0) {
        case Ok(made) => memory = made
        case Error(error) => {
            if error == .Untrusted {
                runtime.log_info("no DMA memory, as no IOMMU confines its device and it isn't trusted")
                return 0
            }
            return 4
        }
    }
    address :: slop_os.memory_device_address(memory) or_return 4
    // Its memory and its DMA on
    command :: pci.read_u16(config_at, pci.COMMAND)
    pci.write_u16(config_at, pci.COMMAND, command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER)
    runtime.log_info("writing outside its domain, at %{#018x}", cast[u64](address + OUTSIDE))
    write_u64(edu, DMA_SOURCE, EDU_BUFFER)
    write_u64(edu, DMA_DESTINATION, address + OUTSIDE)
    write_u64(edu, DMA_COUNT, PAGE)
    write_u64(edu, DMA_COMMAND, DMA_START | DMA_TO_RAM)
    // Stopped meanwhile, or not
    port :: slop_os.port_create(block.budget) or_return 5
    packets : slop_os.Packet[1]
    deadline :: (slop_os.clock_monotonic() or_else 0) + WAIT_NANOSECONDS
    loop {
        now :: slop_os.clock_monotonic() or_else deadline
        if now >= deadline {
            break
        }
        match slop_os.port_wait(port, packets, deadline) {
            case Ok(taken) => {}
            case Error(error) => runtime.log_info("waiting failed: %", error)
        }
    }
    runtime.log_info("wasn't stopped")
    return 6
}

write_u64 :: fn(edu: u64, offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](edu + offset), value)
}
