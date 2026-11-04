/**
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

/** The bytes of a page, and of its DMA memory: 4096. */
PAGE : u64 : 4096
/** Where it writes: this far past its page, 64 MiB, which nothing of its domain reaches. */
OUTSIDE : u64 : 64 << 20

// ---- edu's DMA engine (QEMU's docs/specs/edu.rst): its registers in BAR 0, and its own buffer

/** The DMA source address register, a u64 at this offset in BAR 0. */
DMA_SOURCE : u64 : 0x80
/** The DMA destination address register, a u64. */
DMA_DESTINATION : u64 : 0x88
/** The DMA transfer count register, in bytes, a u64. */
DMA_COUNT : u64 : 0x90
/** The DMA command register, a u64: DMA_START and DMA_TO_RAM. */
DMA_COMMAND : u64 : 0x98
/** Where edu's own 4 KiB buffer is, as a DMA address on the device's side. */
EDU_BUFFER : u64 : 0x40000
/** The command bit that starts a transfer. */
DMA_START : u64 : 1 << 0
/** The command bit for a transfer from edu's buffer to RAM; without it, from RAM to the buffer. */
DMA_TO_RAM : u64 : 1 << 1
/** How long it waits to be stopped, in nanoseconds, 10 s, before it says it wasn't. */
WAIT_NANOSECONDS : u64 : 10_000_000_000

/** The edu device's DMA reach, 2^28 bytes: 28 bits of address, its dma_mask. */
EDU_DMA_LIMIT : u64 : 1 << 28

/**
 * Have QEMU's edu device DMA outside its domain, to test that the IOMMU stops it and the supervisor kills it.
 *
 * It's started by the supervisor, untrusted, for an edu device the platform service gave it, with what its driver
 * holds of it. It's meant to be killed while it waits; if it isn't within WAIT_NANOSECONDS, it says so and ends.
 *
 * @param log The debug log it was given; its lines go through base's logger, not to it.
 * @param device The device, which the kernel raises SIGNAL_DMA_FAULT on when the IOMMU blocks its write.
 * @param config The device's 4 KiB of configuration space, mapped to turn its memory and bus mastering on.
 * @param bar0 BAR 0's memory, edu's registers; without it, it ends with 3.
 * @param bar1 BAR 1's memory, if the device has it; not used.
 * @param bar2 BAR 2's memory, if the device has it; not used.
 * @param bar3 BAR 3's memory, if the device has it; not used.
 * @param bar4 BAR 4's memory, if the device has it; not used.
 * @param bar5 BAR 5's memory, if the device has it; not used.
 * @param domain The DMA domain the device is attached to, which its page is made in.
 * @return 0 when no IOMMU confines its device, so it gets no DMA memory, as it isn't trusted; 2 if config couldn't be
 *     mapped, 3 if BAR 0 couldn't, 4 if its DMA memory couldn't be made or placed, 5 if no port could be made to wait
 *     on, 6 if it wasn't stopped in time. Killed, it returns nothing.
 */
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
    // Where the device reaches: QEMU's edu device addresses 28 bits (its dma_mask), which R2's high addresses are past
    match slop_os.dma_memory_create(domain, block.budget, PAGE, EDU_DMA_LIMIT) {
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

/**
 * Write one of edu's 64-bit registers, with one volatile store.
 *
 * @param edu Where BAR 0 is mapped.
 * @param offset The register's offset in bytes, 8-byte aligned.
 * @param value What's written.
 */
write_u64 :: fn(edu: u64, offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](edu + offset), value)
}
