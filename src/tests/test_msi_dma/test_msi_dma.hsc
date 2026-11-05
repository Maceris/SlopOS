/**
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

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import pci from "../../pci"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_msi_dma"
/** A page, in bytes. */
PAGE : u64 : 4096
/** Bus 0's configuration space through ECAM, in bytes: 32 devices of 8 functions, 4 KiB each. */
BUS_BYTES : u64 : 1 << 20
/** edu's vendor and device ID, as its configuration space's first word reads. */
EDU_ID : u32 : 0x11e81234
/** The size of edu's registers, its BAR 0, in bytes: 1 MiB. */
EDU_REGISTERS : u64 : 1 << 20
/** The offset of edu's identification register, whose low byte is 0xed. */
EDU_IDENTIFICATION : u64 : 0x00
/** The offset of edu's liveness register, which reads back the inverse of what's written. */
EDU_LIVENESS : u64 : 0x04
/** The offset of the register that raises edu's interrupt, with the status written. */
EDU_INTERRUPT_RAISE : u64 : 0x60
/** The offset of the register that acknowledges edu's interrupt, clearing the status written. */
EDU_INTERRUPT_ACK : u64 : 0x64
/** The offset of edu's DMA source address. */
EDU_DMA_SOURCE : u64 : 0x80
/** The offset of edu's DMA destination address. */
EDU_DMA_DESTINATION : u64 : 0x88
/** The offset of edu's DMA transfer count, in bytes. */
EDU_DMA_COUNT : u64 : 0x90
/** The offset of edu's DMA command register, DMA_* bits. */
EDU_DMA_COMMAND : u64 : 0x98
/** edu's own buffer, as its DMA engine addresses it. */
EDU_BUFFER : u64 : 0x40000
/** The DMA command's bit that starts a transfer; edu clears it once the transfer's done. */
DMA_START : u64 : 1
/** The DMA command's bit for a transfer from edu's buffer to RAM, rather than from RAM. */
DMA_TO_RAM : u64 : 2
/** The DMA command's bit that raises edu's interrupt when the transfer's done. */
DMA_INTERRUPT : u64 : 4
/** The interrupt status a finished DMA raises. */
DMA_DONE_STATUS : u32 : 0x100
/** The offset of the configuration space's command register. */
CONFIG_COMMAND : u64 : 0x04
/** The command register's memory space bit, which lets the function's BARs answer. */
COMMAND_MEMORY : u16 : 1 << 1
/** The command register's bus master bit, which lets the function do DMA and raise MSIs. */
COMMAND_BUS_MASTER : u16 : 1 << 2
/** The offset of the configuration space's status register. */
CONFIG_STATUS : u64 : 0x06
/** The status register's bit saying the function has a capability list. */
STATUS_CAPABILITIES : u16 : 1 << 4
/** The offset of the configuration space's BAR 0. */
CONFIG_BAR0 : u64 : 0x10
/** The offset of the configuration space's capabilities pointer. */
CONFIG_CAPABILITIES : u64 : 0x34
/** The MSI capability's ID. */
CAPABILITY_MSI : u8 : 0x05
/** The MSI capability's control bit that enables it. */
MSI_ENABLE : u16 : 1
/** The MSI capability's control bit saying its address is 64 bits. */
MSI_64_BIT : u16 : 1 << 7
/** The key the MSI's binding queues its packets under. */
IRQ_KEY : u64 : 3
/** The limit DMA memory is made below: 4 GiB, below which both machines' RAM is. */
DMA_LIMIT : u64 : 1 << 32

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, which the tables' count and ECAM's address are logged to. */
    log : slop_os.DebugLog,
    /** The platform capability, which makes devices, device memory and DMA domains; none if main wasn't given it. */
    platform : slop_os.Platform?,
    /** The firmware tables' read-only copy, which says where ECAM is; none if main wasn't given it. */
    firmware : slop_os.Memory?,
}

/** The firmware tables' copy, mapped read-only, as map_tables maps it. */
Tables :: struct {
    /** Where it's mapped, starting with its slop_os.FirmwareTables header. */
    at : u64,
    /** Its size, in bytes. */
    size : u64,
}

/**
 * Map the firmware tables' copy read-only, at addresses reserved for it, which it stays mapped at.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param memory The copy's memory, from the firmware grant.
 * @return Where it's mapped, and its size; Error(Failed), recorded, if its size couldn't be read, no addresses were
 *     left, or it couldn't be mapped.
 */
map_tables :: fn(t: ptr[mut testing.T], memory: slop_os.Memory) -> Result[Tables, testing.Stopped] {
    block :: slop_os.startup_block()
    size :: testing.require_ok(t, slop_os.memory_size(memory), "the tables' copy's size can be read")?
    at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](size)), "addresses to map the tables at")?
    testing.require_ok(t, slop_os.memory_map(memory, block.space, at, 0, size, slop_os.PROTECTION_READ), "the tables' copy maps read-only")?
    return .Ok(Tables.{at = at, size = size})
}

/**
 * Check that the firmware tables' copy can't be mapped writable, starts with its header, and has the tables this
 * machine's firmware gives: ACPI's RSDP, FADT, DSDT and MCFG on x86-64, the device tree on AArch64.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the copy, or it couldn't be mapped read-only.
 */
the_firmware_tables_copy_is_read_only_and_whole #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    tables_memory :: testing.require_some(t, given.firmware, "the root task grants the firmware tables' copy")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    size :: slop_os.memory_size(tables_memory) or_else 0
    writable_at :: runtime.reserve_addresses(cast[usize](size)) or_else 0
    writable :: slop_os.memory_map(tables_memory, block.space, writable_at, 0, size, read_write)
    testing.expect_error(t, writable, slop_os.MemoryError.MissingRight, "the firmware tables' copy is given read-only, so it can't be mapped writable")
    tables :: map_tables(t, tables_memory)?
    header :: cast[ptr[slop_os.FirmwareTables]](tables.at)
    testing.expect_eq(t, header.magic, slop_os.FIRMWARE_MAGIC, "the copy starts with its header, whose magic says what it is")
    testing.expect(t, tables_right(tables.at), "the copy has the tables this machine's firmware gives, and no others")
    return .Ok
}

/**
 * Check a driver's view of QEMU's edu device, a PCIe function: its configuration space through ECAM, where the tables
 * say, has edu on bus 0; a Device for it, but not a second at its address, nor one without the platform capability,
 * nor one whose configuration space isn't on a page; an MSI, programmed into edu, which edu raises and whose packet
 * arrives, moved to the other CPU and arriving again, but not to a CPU that isn't one; 31 more MSIs, and no more; DMA
 * memory in a domain the device is attached to, below a limit, which edu copies a page of through its buffer, saying
 * it's done with its MSI, while ordinary memory has no device address; closing the device destroys its IRQs and turns
 * its bus mastering off, and closing the domain leaves its memory without a device address; and what it all charged
 * its budget comes back. The tables' count and ECAM's address are logged, as "% firmware tables, ECAM at %".
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the platform capability or the tables' copy, or the budget,
 *     the tables' mapping, ECAM, edu's registers, the device, its MSI, the port, the domain or the DMA memory couldn't
 *     be found, made or mapped.
 */
edu_takes_its_msi_and_copies_a_page_through_dma #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    space :: block.space
    hardware :: testing.require_some(t, given.platform, "the root task grants the platform capability")?
    tables_memory :: testing.require_some(t, given.firmware, "the root task grants the firmware tables' copy")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 4 << 20), "a budget for the driver's objects")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    tables :: map_tables(t, tables_memory)?
    header :: cast[ptr[slop_os.FirmwareTables]](tables.at)
    host := testing.require_some(t, pci.find_host(tables.at, tables.size), "the tables say where ECAM is")?
    log_line.write(given.log, "%: % firmware tables, ECAM at %{#018x}", NAME, header.count, host.ecam)

    // edu, on bus 0
    config_memory :: testing.require_ok(t, slop_os.memory_create_physical(hardware, budget, host.ecam, BUS_BYTES, .Device), "device memory over bus 0's configuration space")?
    config_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](BUS_BYTES)), "addresses to map bus 0's configuration space at")?
    testing.require_ok(t, slop_os.memory_map(config_memory, space, config_at, 0, BUS_BYTES, read_write), "bus 0's configuration space maps")?
    slot := cast[u64](32)
    for device in 0..<32 {
        if intrinsics.volatile_load_u32(cast[ptr[u32]](config_at + cast[u64](device) << 15)) == EDU_ID {
            slot = cast[u64](device)
            break
        }
    }
    testing.require(t, slot != 32, "edu, added to QEMU's command line, is on bus 0")?
    config :: config_at + slot << 15
    bar :: cast[u64](intrinsics.volatile_load_u32(cast[ptr[u32]](config + CONFIG_BAR0))) & ~cast[u64](0xf)
    testing.require(t, bar != 0, "the firmware gave edu's registers an address")?
    command :: cast[ptr[mut u16]](config + CONFIG_COMMAND)
    intrinsics.volatile_store_u16(command, intrinsics.volatile_load_u16(command) | COMMAND_MEMORY | COMMAND_BUS_MASTER)
    registers_memory :: testing.require_ok(t, slop_os.memory_create_physical(hardware, budget, bar, EDU_REGISTERS, .Device), "device memory over edu's registers")?
    edu :: testing.require_some(t, runtime.reserve_addresses(cast[usize](EDU_REGISTERS)), "addresses to map edu's registers at")?
    testing.require_ok(t, slop_os.memory_map(registers_memory, space, edu, 0, EDU_REGISTERS, read_write), "edu's registers map")?
    testing.expect_eq(t, read_edu(edu, EDU_IDENTIFICATION) & 0xff, 0xed, "edu's identification register says it's edu")
    write_edu(edu, EDU_LIVENESS, 0x12345678)
    testing.expect_eq(t, read_edu(edu, EDU_LIVENESS), ~cast[u32](0x12345678), "edu's liveness register reads back the inverse of what was written")

    // Its Device, a second at its address, and one without the platform capability
    address :: slop_os.device_address(0, 0, cast[u8](slot), 0)
    config_physical :: host.ecam + slot << 15
    device :: testing.require_ok(t, slop_os.device_create(hardware, budget, address, pci.msi_source(&host, address), config_physical), "a Device is made for edu")?
    second :: slop_os.device_create(hardware, budget, address, pci.msi_source(&host, address), config_physical)
    testing.expect_error(t, second, slop_os.DeviceError.DeviceExists, "a function has one Device at a time")
    not_platform :: test_kit.handle_at[slop_os.Platform](cast[u64](cast[u32](budget)))
    without :: slop_os.device_create(not_platform, budget, slop_os.device_address(0, 0, 31, 7), 0xffff, config_physical)
    testing.expect_error(t, without, slop_os.DeviceError.WrongKind, "only the platform capability makes Devices")
    // Configuration space not on a page
    off_page :: slop_os.device_create(hardware, budget, slop_os.device_address(0, 0, 31, 7), 0xffff, config_physical + 4)
    testing.expect_error(t, off_page, slop_os.DeviceError.BadAddress, "a function's configuration space is on a page of its own")

    // Its MSI: the message into edu's MSI capability, then edu raises it
    irq :: testing.require_ok(t, slop_os.irq_create_msi(device, budget), "an MSI is made for edu's Device")?
    message :: slop_os.irq_message(irq) or_else slop_os.MsiMessage.{}
    testing.expect_ne(t, message.address, 0, "an MSI's message says where the device writes to raise it")
    testing.expect(t, program_msi(config, message), "edu has an MSI capability, which the message is programmed into")
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port for the MSI's packets")?
    bound :: slop_os.port_bind(port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent)
    testing.expect_ok(t, bound, "the MSI binds to the port")
    write_edu(edu, EDU_INTERRUPT_RAISE, 1)
    testing.expect(t, wait_for_interrupt(port), "edu raising its MSI queues an Irq packet within a second")
    write_edu(edu, EDU_INTERRUPT_ACK, 1)
    // Moved to the other CPU, then raised again; and to a CPU that isn't one
    moved_ok :: slop_os.irq_set_cpu(irq, 1)
    testing.expect_ok(t, moved_ok, "an MSI can be moved to another CPU")
    moved :: slop_os.irq_message(irq) or_else slop_os.MsiMessage.{}
    _ = program_msi(config, moved)
    write_edu(edu, EDU_INTERRUPT_RAISE, 1)
    testing.expect(t, wait_for_interrupt(port), "an MSI moved to another CPU, its message programmed again, arrives there")
    write_edu(edu, EDU_INTERRUPT_ACK, 1)
    no_cpu :: slop_os.irq_set_cpu(irq, 64)
    testing.expect_error(t, no_cpu, slop_os.DeviceError.InvalidArgument, "an MSI can't be moved to a CPU that isn't one")
    // 31 more, and no more
    more : slop_os.Irq[31]
    fitted := cast[u64](0)
    for &extra in more {
        made_one :: slop_os.irq_create_msi(device, budget)
        if made_one is_ok {
            extra^ = made_one or_else test_kit.handle_at[slop_os.Irq](0)
            fitted += 1
        }
    }
    testing.expect_eq(t, fitted, 31, "a device has 32 MSI vectors, so 31 more fit")
    too_many :: slop_os.irq_create_msi(device, budget)
    testing.expect_error(t, too_many, slop_os.DeviceError.TooManyVectors, "a device's MSIs stop at 32")
    for extra in more {
        _ = slop_os.handle_close(cast[slop_os.Handle](extra))
    }

    // DMA: a domain the device is attached to, memory in it below the limit, and none whose limit is below its size
    domain :: testing.require_ok(t, slop_os.dma_domain_create(hardware, budget, slop_os.DMA_DOMAIN_TRUSTED), "a DMA domain")?
    attached :: slop_os.device_attach(hardware, device, domain)
    testing.expect_ok(t, attached, "the device attaches to the domain")
    below_size :: slop_os.dma_memory_create(domain, budget, 2 * PAGE, PAGE)
    testing.expect_error(t, below_size, slop_os.DeviceError.InvalidSize, "DMA memory can't be made below a limit smaller than itself")
    dma :: testing.require_ok(t, slop_os.dma_memory_create(domain, budget, 2 * PAGE, DMA_LIMIT), "DMA memory is made in the domain, below the limit")?
    device_address :: slop_os.memory_device_address(dma) or_else 0
    testing.expect(t, device_address != 0 && device_address + 2 * PAGE <= DMA_LIMIT && device_address % PAGE == 0, "DMA memory has a page-aligned device address, below its limit")
    ordinary :: slop_os.memory_device_address(registers_memory)
    testing.expect_error(t, ordinary, slop_os.DeviceError.NotDmaMemory, "memory that isn't DMA memory has no device address")
    dma_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](2 * PAGE)), "addresses to map the DMA memory at")?
    testing.require_ok(t, slop_os.memory_map(dma, space, dma_at, 0, 2 * PAGE, read_write), "the DMA memory maps")?
    for i in 0..<PAGE / 8 {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](dma_at + i * 8), 0x0101010101010101 * (i % 251) + i)
    }
    // Into edu's buffer, waited for; then back into the next page, with its MSI when it's done
    write_edu_u64(edu, EDU_DMA_SOURCE, device_address)
    write_edu_u64(edu, EDU_DMA_DESTINATION, EDU_BUFFER)
    write_edu_u64(edu, EDU_DMA_COUNT, PAGE)
    write_edu_u64(edu, EDU_DMA_COMMAND, DMA_START)
    testing.expect(t, wait_for_dma(edu), "edu's DMA from the DMA memory into its buffer finishes within a second")
    write_edu_u64(edu, EDU_DMA_SOURCE, EDU_BUFFER)
    write_edu_u64(edu, EDU_DMA_DESTINATION, device_address + PAGE)
    write_edu_u64(edu, EDU_DMA_COUNT, PAGE)
    write_edu_u64(edu, EDU_DMA_COMMAND, DMA_START | DMA_TO_RAM | DMA_INTERRUPT)
    testing.expect(t, wait_for_interrupt(port), "edu's DMA back into the next page says it's done with its MSI")
    testing.expect(t, read_edu(edu, 0x24) & DMA_DONE_STATUS != 0, "edu's interrupt status says it was the DMA")
    write_edu(edu, EDU_INTERRUPT_ACK, DMA_DONE_STATUS)
    same := true
    for i in 0..<PAGE / 8 {
        if intrinsics.volatile_load_u64(cast[ptr[u64]](dma_at + PAGE + i * 8)) != intrinsics.volatile_load_u64(cast[ptr[u64]](dma_at + i * 8)) {
            same = false
        }
    }
    testing.expect(t, same, "the page edu copied there and back reads as the first")

    /*
     * edu quiet again; closing the device destroys its IRQ and turns its DMA off, and closing the domain takes its
     * memory's device address
     */
    stop_msi(config)
    device_closed :: slop_os.handle_close(cast[slop_os.Handle](device))
    testing.expect_ok(t, device_closed, "the device closes")
    testing.expect_eq(t, intrinsics.volatile_load_u16(command) & COMMAND_BUS_MASTER, 0, "closing a device turns its bus mastering off, so it can't do DMA")
    irq_gone :: slop_os.handle_info(cast[slop_os.Handle](irq))
    testing.expect_error(t, irq_gone, slop_os.HandleError.ObjectGone, "closing a device destroys its IRQs")
    domain_closed :: slop_os.handle_close(cast[slop_os.Handle](domain))
    testing.expect_ok(t, domain_closed, "the domain closes")
    address_gone :: slop_os.memory_device_address(dma)
    testing.expect_error(t, address_gone, slop_os.DeviceError.NotDmaMemory, "closing a domain leaves its memory without a device address")
    _ = slop_os.memory_unmap(space, dma_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](dma))
    _ = slop_os.memory_unmap(space, edu)
    _ = slop_os.handle_close(cast[slop_os.Handle](registers_memory))
    _ = slop_os.memory_unmap(space, config_at)
    _ = slop_os.handle_close(cast[slop_os.Handle](config_memory))
    _ = slop_os.handle_close(cast[slop_os.Handle](irq))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "the budget is back to nothing once the driver's objects are closed")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform The platform capability, which makes devices, device memory and DMA domains; without it the tests
 *     that need it fail.
 * @param test_device Not used.
 * @param firmware The firmware tables' read-only copy, which says where ECAM is; without it the tests fail.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log, platform = platform, firmware = firmware}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Tell whether the firmware tables' copy has what this machine's firmware gives.
 *
 * @param tables Where the copy is mapped, starting with its slop_os.FirmwareTables header.
 * @return True if, on x86-64, it's ACPI's and has the RSDP, FADT, DSDT and MCFG, or, on AArch64, it's a device
 *     tree's and has the DTB, and nothing else counted; false otherwise.
 */
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

/**
 * Program an MSI's message into a function's MSI capability, one vector, and enable it.
 *
 * @param config Where the function's configuration space is mapped.
 * @param message The message, as irq_message gives it; a 32-bit capability takes only its address's low half.
 * @return True if the function has an MSI capability, now programmed; false if it hasn't, and nothing's written.
 */
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

/**
 * Disable a function's MSI, if it has one, so it raises nothing more.
 *
 * @param config Where the function's configuration space is mapped.
 */
stop_msi :: fn(config: u64) {
    capability :: find_msi(config) or_return void
    control :: cast[ptr[mut u16]](config + capability + 2)
    intrinsics.volatile_store_u16(control, intrinsics.volatile_load_u16(control) & ~MSI_ENABLE)
}

/**
 * Find a function's MSI capability in its configuration space.
 *
 * @param config Where the function's configuration space is mapped.
 * @return Its offset in the configuration space, or null if the function has no capability list, the list has no
 *     MSI, or it's longer than 48, as a looping one would be.
 */
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

/**
 * Wait up to a second for the MSI's packet.
 *
 * @param port The port the MSI is bound to, under IRQ_KEY.
 * @return True if the first packet to arrive is an Irq packet for IRQ_KEY counting at least one interrupt; false if
 *     none arrived within a second, or another did.
 */
wait_for_interrupt :: fn(port: slop_os.Port) -> bool {
    packets : slop_os.Packet[1]
    waited :: slop_os.port_wait(port, packets, test_kit.clock_now() + 1_000_000_000) or_else 0
    return waited == 1 && packets[0].key == IRQ_KEY && packets[0].kind == .Irq && packets[0].data[0] >= 1
}

/**
 * Wait up to a second, spinning, for edu's DMA to finish.
 *
 * @param edu Where edu's registers are mapped.
 * @return True if DMA_START is clear, so the transfer's done; false if it's still set after a second.
 */
wait_for_dma :: fn(edu: u64) -> bool {
    started :: test_kit.clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(cast[ptr[u64]](edu + EDU_DMA_COMMAND)) & DMA_START != 0 && test_kit.clock_now() < started + 1_000_000_000
    return intrinsics.volatile_load_u64(cast[ptr[u64]](edu + EDU_DMA_COMMAND)) & DMA_START == 0
}

/**
 * Read one of edu's 32-bit registers.
 *
 * @param edu Where edu's registers are mapped.
 * @param offset The register's offset, an EDU_* constant.
 * @return The 32 bits read, by one volatile load at edu plus offset, as edu gives them; nothing is checked.
 */
read_edu :: fn(edu: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](edu + offset))
}

/**
 * Write one of edu's 32-bit registers.
 *
 * @param edu Where edu's registers are mapped.
 * @param offset The register's offset, an EDU_* constant.
 * @param value What's written.
 */
write_edu :: fn(edu: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](edu + offset), value)
}

/**
 * Write one of edu's 64-bit registers, its DMA engine's.
 *
 * @param edu Where edu's registers are mapped.
 * @param offset The register's offset, an EDU_DMA_* constant.
 * @param value What's written.
 */
write_edu_u64 :: fn(edu: u64, offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](edu + offset), value)
}
