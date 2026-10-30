/*
 * test_msi_dma (decisions/0073): a driver for QEMU's edu device, a PCIe function with a DMA engine and an MSI, given
 * the platform capability and the firmware tables' copy as the root task would give the platform service:
 * - the copy is read-only, starts with its header, and has the tables this machine's firmware gives: ACPI's RSDP,
 *   FADT, DSDT and MCFG on x86-64, the device tree on AArch64;
 * - the PCIe configuration space, through ECAM where the MCFG or the device tree says (src/pci), has edu on bus 0;
 * - a Device for it, a second for its address refused, and one without the platform capability; an MSI for it,
 *   whose message is programmed into edu's MSI capability, then edu raises it, and the IRQ's packet arrives; moved to
 *   the other CPU (irq_set_cpu, decisions/0099), its message programmed again, it arrives again, and a CPU that isn't
 *   one is refused; 31 more fit, and no more;
 * - DMA memory in a domain the device is attached to, below a limit: edu copies a page of it into its buffer and
 *   back into the next page, and says it's done with its MSI; ordinary memory has no device address;
 * - closing the device destroys its IRQs, and closing the domain leaves its memory without a device address; what
 *   it all charged its budget comes back.
 */
package test_msi_dma

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import pci from "../../pci"
import test_kit from "../../test_kit"

NAME :: "test_msi_dma"
PAGE : u64 : 4096
// Bus 0's configuration space through ECAM: 32 devices of 8 functions, 4 KiB each
BUS_BYTES : u64 : 1 << 20
EDU_ID : u32 : 0x11e81234
EDU_REGISTERS : u64 : 1 << 20
// edu's registers: its ID, the interrupt it raises and acknowledges, and its DMA engine
EDU_IDENTIFICATION : u64 : 0x00
EDU_LIVENESS : u64 : 0x04
EDU_INTERRUPT_RAISE : u64 : 0x60
EDU_INTERRUPT_ACK : u64 : 0x64
EDU_DMA_SOURCE : u64 : 0x80
EDU_DMA_DESTINATION : u64 : 0x88
EDU_DMA_COUNT : u64 : 0x90
EDU_DMA_COMMAND : u64 : 0x98
// Its own buffer, as its DMA engine addresses it
EDU_BUFFER : u64 : 0x40000
DMA_START : u64 : 1
DMA_TO_RAM : u64 : 2
DMA_INTERRUPT : u64 : 4
// The interrupt status a finished DMA raises
DMA_DONE_STATUS : u32 : 0x100
// Configuration space: the command register's memory space and bus master bits, the capability list, MSI's ID
CONFIG_COMMAND : u64 : 0x04
COMMAND_MEMORY : u16 : 1 << 1
COMMAND_BUS_MASTER : u16 : 1 << 2
CONFIG_STATUS : u64 : 0x06
STATUS_CAPABILITIES : u16 : 1 << 4
CONFIG_BAR0 : u64 : 0x10
CONFIG_CAPABILITIES : u64 : 0x34
CAPABILITY_MSI : u8 : 0x05
MSI_ENABLE : u16 : 1
MSI_64_BIT : u16 : 1 << 7
IRQ_KEY : u64 : 3
// DMA below 4 GiB: where both machines' RAM is
DMA_LIMIT : u64 : 1 << 32

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    space :: block.space
    hardware :: platform or_return 100
    tables_memory :: firmware or_return 100
    budget :: slop_os.memory_budget_create(block.budget, 4 << 20) or_return 102
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    results : u64[35]

    // The firmware tables' copy: read-only, its header, its tables
    tables_size :: slop_os.memory_size(tables_memory) or_return 103
    tables_at :: runtime.reserve_addresses(cast[usize](tables_size)) or_return 103
    results[0] = test_kit.tag_of(slop_os.memory_map(tables_memory, space, tables_at, 0, tables_size, read_write))
    slop_os.memory_map(tables_memory, space, tables_at, 0, tables_size, read) or_return 103
    header :: cast[ptr[slop_os.FirmwareTables]](tables_at)
    results[1] = if header.magic == slop_os.FIRMWARE_MAGIC { cast[u64](1) } else { cast[u64](0) }
    results[2] = if tables_right(tables_at) { cast[u64](1) } else { cast[u64](0) }
    host := pci.find_host(tables_at, tables_size) or_return 104
    log_line.write(log, "%: % firmware tables, ECAM at %", NAME, header.count, cast[rawptr](host.ecam))

    // edu, on bus 0
    config_memory :: slop_os.memory_create_physical(hardware, budget, host.ecam, BUS_BYTES, .Device) or_return 104
    config_at :: runtime.reserve_addresses(cast[usize](BUS_BYTES)) or_return 104
    slop_os.memory_map(config_memory, space, config_at, 0, BUS_BYTES, read_write) or_return 104
    slot := cast[u64](32)
    for device in 0..<32 {
        if intrinsics.volatile_load_u32(cast[ptr[u32]](config_at + cast[u64](device) << 15)) == EDU_ID {
            slot = cast[u64](device)
            break
        }
    }
    if slot == 32 {
        log_line.write(log, "%: no edu device on bus 0", NAME)
        return 105
    }
    config :: config_at + slot << 15
    bar :: cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](config + CONFIG_BAR0))) & ~cast[u64](0xf)
    if bar == 0 {
        log_line.write(log, "%: edu's registers weren't given an address", NAME)
        return 105
    }
    command :: cast[ptr[mut u16]](config + CONFIG_COMMAND)
    intrinsics.volatile_store_u16(command, intrinsics.volatile_load_u16(command) | COMMAND_MEMORY | COMMAND_BUS_MASTER)
    registers_memory :: slop_os.memory_create_physical(hardware, budget, bar, EDU_REGISTERS, .Device) or_return 106
    edu :: runtime.reserve_addresses(cast[usize](EDU_REGISTERS)) or_return 106
    slop_os.memory_map(registers_memory, space, edu, 0, EDU_REGISTERS, read_write) or_return 106
    results[3] = cast[u64](read_edu(edu, EDU_IDENTIFICATION) & 0xff)
    write_edu(edu, EDU_LIVENESS, 0x12345678)
    results[4] = cast[u64](read_edu(edu, EDU_LIVENESS))

    // Its Device, a second at its address, and one without the platform capability
    address :: slop_os.device_address(0, 0, cast[u8](slot), 0)
    config_physical :: host.ecam + slot << 15
    made :: slop_os.device_create(hardware, budget, address, pci.msi_source(&host, address), config_physical)
    results[5] = test_kit.tag_of(made)
    device :: made or_else test_kit.handle_at[slop_os.Device](0)
    results[6] = test_kit.tag_of(slop_os.device_create(hardware, budget, address, pci.msi_source(&host, address), config_physical))
    not_platform :: test_kit.handle_at[slop_os.Platform](cast[u64](cast[u32](budget)))
    results[7] = test_kit.tag_of(slop_os.device_create(not_platform, budget, slop_os.device_address(0, 0, 31, 7), 0xffff,
        config_physical))
    // Configuration space not on a page
    results[28] = test_kit.tag_of(slop_os.device_create(hardware, budget, slop_os.device_address(0, 0, 31, 7), 0xffff,
        config_physical + 4))

    // Its MSI: the message into edu's MSI capability, then edu raises it
    irq_made :: slop_os.irq_create_msi(device, budget)
    results[8] = test_kit.tag_of(irq_made)
    irq :: irq_made or_else test_kit.handle_at[slop_os.Irq](0)
    message :: slop_os.irq_message(irq) or_else slop_os.MsiMessage.{}
    results[9] = if message.address != 0 { cast[u64](1) } else { cast[u64](0) }
    results[10] = if program_msi(config, message) { cast[u64](1) } else { cast[u64](0) }
    port :: slop_os.port_create(budget) or_return 107
    results[11] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent))
    write_edu(edu, EDU_INTERRUPT_RAISE, 1)
    results[12] = if wait_for_interrupt(port) { cast[u64](1) } else { cast[u64](0) }
    write_edu(edu, EDU_INTERRUPT_ACK, 1)
    // Moved to the other CPU, then raised again; and to a CPU that isn't one
    results[32] = test_kit.tag_of(slop_os.irq_set_cpu(irq, 1))
    moved :: slop_os.irq_message(irq) or_else slop_os.MsiMessage.{}
    _ = program_msi(config, moved)
    write_edu(edu, EDU_INTERRUPT_RAISE, 1)
    results[33] = if wait_for_interrupt(port) { cast[u64](1) } else { cast[u64](0) }
    write_edu(edu, EDU_INTERRUPT_ACK, 1)
    results[34] = test_kit.tag_of(slop_os.irq_set_cpu(irq, 64))
    // 31 more, and no more
    more : slop_os.Irq[31]
    fitted := cast[u64](0)
    for &extra in more {
        match slop_os.irq_create_msi(device, budget) {
            case Ok(made_one) => {
                extra^ = made_one
                fitted += 1
            }
            case Error(error) => {}
        }
    }
    results[13] = fitted
    results[14] = test_kit.tag_of(slop_os.irq_create_msi(device, budget))
    for extra in more {
        _ = slop_os.handle_close(cast[slop_os.Handle](extra))
    }

    // DMA: a domain the device is attached to, memory in it below the limit, and none whose limit is below its size
    domain :: slop_os.dma_domain_create(hardware, budget, slop_os.DMA_DOMAIN_TRUSTED) or_return 108
    results[15] = test_kit.tag_of(slop_os.device_attach(hardware, device, domain))
    results[16] = test_kit.tag_of(slop_os.dma_memory_create(domain, budget, 2 * PAGE, PAGE))
    dma_made :: slop_os.dma_memory_create(domain, budget, 2 * PAGE, DMA_LIMIT)
    results[17] = test_kit.tag_of(dma_made)
    dma :: dma_made or_else test_kit.handle_at[slop_os.Memory](0)
    device_address :: slop_os.memory_device_address(dma) or_else 0
    results[18] = if device_address != 0 && device_address + 2 * PAGE <= DMA_LIMIT && device_address % PAGE == 0 { cast[u64](1) } else { cast[u64](0) }
    results[19] = test_kit.tag_of(slop_os.memory_device_address(registers_memory))
    dma_at :: runtime.reserve_addresses(cast[usize](2 * PAGE)) or_return 109
    slop_os.memory_map(dma, space, dma_at, 0, 2 * PAGE, read_write) or_return 109
    for i in 0..<PAGE / 8 {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](dma_at + i * 8), 0x0101010101010101 * (i % 251) + i)
    }
    // Into edu's buffer, waited for; then back into the next page, with its MSI when it's done
    write_edu_u64(edu, EDU_DMA_SOURCE, device_address)
    write_edu_u64(edu, EDU_DMA_DESTINATION, EDU_BUFFER)
    write_edu_u64(edu, EDU_DMA_COUNT, PAGE)
    write_edu_u64(edu, EDU_DMA_COMMAND, DMA_START)
    results[20] = if wait_for_dma(edu) { cast[u64](1) } else { cast[u64](0) }
    write_edu_u64(edu, EDU_DMA_SOURCE, EDU_BUFFER)
    write_edu_u64(edu, EDU_DMA_DESTINATION, device_address + PAGE)
    write_edu_u64(edu, EDU_DMA_COUNT, PAGE)
    write_edu_u64(edu, EDU_DMA_COMMAND, DMA_START | DMA_TO_RAM | DMA_INTERRUPT)
    results[21] = if wait_for_interrupt(port) { cast[u64](1) } else { cast[u64](0) }
    results[22] = if read_edu(edu, 0x24) & DMA_DONE_STATUS != 0 { cast[u64](1) } else { cast[u64](0) }
    write_edu(edu, EDU_INTERRUPT_ACK, DMA_DONE_STATUS)
    same := cast[u64](1)
    for i in 0..<PAGE / 8 {
        if intrinsics.volatile_load_u64(cast[ptr[u64]](dma_at + PAGE + i * 8)) != intrinsics.volatile_load_u64(cast[ptr[u64]](dma_at + i * 8)) {
            same = 0
        }
    }
    results[23] = same

    /*
     * edu quiet again; closing the device destroys its IRQ and turns its DMA off, and closing the domain takes its
     * memory's device address
     */
    stop_msi(config)
    results[24] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](device)))
    results[29] = if intrinsics.volatile_load_u16(command) & COMMAND_BUS_MASTER == 0 { cast[u64](1) } else { cast[u64](2) }
    results[25] = test_kit.tag_of(slop_os.handle_info(cast[slop_os.Handle](irq)))
    results[26] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](domain)))
    results[27] = test_kit.tag_of(slop_os.memory_device_address(dma))
    expected :: u64.[
        test_kit.tag(slop_os.MemoryError.MissingRight), 1, 1,
        0xed, ~cast[u64](0x12345678) & 0xffffffff,
        0, test_kit.tag(slop_os.DeviceError.DeviceExists), test_kit.tag(slop_os.DeviceError.WrongKind),
        0, 1, 1, 0, 1, 31, test_kit.tag(slop_os.DeviceError.TooManyVectors),
        0, test_kit.tag(slop_os.DeviceError.InvalidSize), 0, 1, test_kit.tag(slop_os.DeviceError.NotDmaMemory),
        1, 1, 1, 1,
        0, test_kit.tag(slop_os.HandleError.ObjectGone), 0, test_kit.tag(slop_os.DeviceError.NotDmaMemory),
        test_kit.tag(slop_os.DeviceError.BadAddress), 1, 0, 0,
        0, 1, test_kit.tag(slop_os.DeviceError.InvalidArgument),
    ]
    failed := test_kit.check(log, NAME, results, expected)
    if failed != 0 {
        return failed
    }
    _ = slop_os.memory_unmap(space, dma_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](dma))
    _ = slop_os.memory_unmap(space, edu)
    _ = slop_os.handle_close(cast[slop_os.Handle](registers_memory))
    _ = slop_os.memory_unmap(space, config_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](config_memory))
    _ = slop_os.handle_close(cast[slop_os.Handle](irq))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    if !test_kit.wait_for_budget(budget, 0, 1_000_000_000) {
        log_line.write(log, "%: its budget still has % bytes charged", NAME, test_kit.used(budget))
        return 30
    }
    log_line.write(log, "%: edu took its MSI and copied a page through DMA memory, and its device took its IRQs with it", NAME)
    return 0
}

// Whether the firmware tables' copy has what this machine's firmware gives: ACPI's RSDP, FADT, DSDT and MCFG, or a device tree.
tables_right :: fn(tables: u64) -> bool {
    header :: cast[ptr[slop_os.FirmwareTables]](tables)
    entries :: view_of(cast[ptr[slop_os.FirmwareTable]](tables + cast[u64](size_of(slop_os.FirmwareTables))), cast[usize](header.count))
    seen := cast[u32](0)
    for &entry in entries {
        name :: pci.signature_of(entry)
        seen |= if name == "RSDP" { cast[u32](1) } else if name == "FACP" { cast[u32](2) } else if name == "DSDT" { cast[u32](4) }
            else if name == "MCFG" { cast[u32](8) } else if name == "DTB " { cast[u32](16) } else { cast[u32](0) }
    }
    #if TARGET_ARCH == .x86_64 {
        return header.kind == .Acpi && seen == 15
    }
    #else {
        return header.kind == .DeviceTree && seen == 16
    }
}

// The message into the function's MSI capability, one vector, enabled: whether it has one.
program_msi :: fn(config: u64, message: slop_os.MsiMessage) -> bool {
    capability :: find_msi(config) or_return false
    control :: cast[ptr[mut u16]](config + capability + 2)
    wide :: intrinsics.volatile_load_u16(control) & MSI_64_BIT != 0
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](config + capability + 4), cast[u32](message.address))
    if wide {
        intrinsics.volatile_store_u32(cast[ptr[mut u32]](config + capability + 8), cast[u32](message.address >> 32))
        intrinsics.volatile_store_u16(cast[ptr[mut u16]](config + capability + 12), cast[u16](message.data))
    }
    else {
        intrinsics.volatile_store_u16(cast[ptr[mut u16]](config + capability + 8), cast[u16](message.data))
    }
    // One vector (MME 0), enabled
    intrinsics.volatile_store_u16(control, (intrinsics.volatile_load_u16(control) & ~cast[u16](0x70)) | MSI_ENABLE)
    return true
}

stop_msi :: fn(config: u64) {
    capability :: find_msi(config) or_return void
    control :: cast[ptr[mut u16]](config + capability + 2)
    intrinsics.volatile_store_u16(control, intrinsics.volatile_load_u16(control) & ~MSI_ENABLE)
}

// Where the function's MSI capability is in its configuration space, if it has one.
find_msi :: fn(config: u64) -> u64? {
    if intrinsics.volatile_load_u16(cast[ptr[u16]](config + CONFIG_STATUS)) & STATUS_CAPABILITIES == 0 {
        return null
    }
    at := cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](config + CONFIG_CAPABILITIES))) & 0xfc
    for step in 0..<48 {
        if at == 0 {
            return null
        }
        if intrinsics.volatile_load_u8(cast[ptr[u8]](config + at)) == CAPABILITY_MSI {
            return at
        }
        at = cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](config + at + 1))) & 0xfc
    }
    return null
}

// Whether an Irq packet for the key arrives within a second.
wait_for_interrupt :: fn(port: slop_os.Port) -> bool {
    packets : slop_os.Packet[1]
    waited :: slop_os.port_wait(port, packets, test_kit.clock_now() + 1_000_000_000) or_else 0
    return waited == 1 && packets[0].key == IRQ_KEY && packets[0].kind == .Irq && packets[0].data[0] >= 1
}

// Whether edu's DMA is done within a second.
wait_for_dma :: fn(edu: u64) -> bool {
    started :: test_kit.clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(cast[ptr[u64]](edu + EDU_DMA_COMMAND)) & DMA_START != 0 && test_kit.clock_now() < started + 1_000_000_000
    return intrinsics.volatile_load_u64(cast[ptr[u64]](edu + EDU_DMA_COMMAND)) & DMA_START == 0
}

read_edu :: fn(edu: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](edu + offset))
}

write_edu :: fn(edu: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](edu + offset), value)
}

write_edu_u64 :: fn(edu: u64, offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](edu + offset), value)
}
