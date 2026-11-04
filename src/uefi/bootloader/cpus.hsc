package bootloader

import intrinsics from "base"
import uefi from "std/os"
import boot_protocol from "../../boot_protocol"

#if TARGET_ARCH == .x86_64 {
    import x86_64 from "base/intrinsics"
}

/*
 * The other CPUs (boot_protocol.Cpu): listed by the firmware's MP services before the boot services are left, each
 * given a stack, then started once they're left, one at a time, by INIT and two SIPIs to a trampoline below 1 MiB,
 * which takes it from real mode to long mode on the bootloader's page tables and parks it on its mailbox. Hemera has no
 * assembler, so the trampoline is its machine code, with the few addresses it needs written in.
 */
#if TARGET_ARCH == .x86_64 {
    // Where the trampoline's data is, from its page's start
    /** The GDT's offset in bytes in the trampoline's page: its three descriptors, 8 bytes each. */
    GDT_AT : u64 : 0x100
    /** The GDT pointer's offset, which lgdt loads: a 16-bit limit, then the GDT's 32-bit physical address. */
    GDT_POINTER_AT : u64 : 0x118
    /** The offset of the page tables' root, a 32-bit physical address, which the trampoline loads into CR3. */
    PAGE_TABLE_AT : u64 : 0x120
    /** The offset of the mailbox's address, 64 bits: the starting CPU's boot_protocol.Cpu in the handoff. */
    MAILBOX_AT : u64 : 0x130
    /** The offset of the acknowledgement, 32 bits, which the CPU sets to 1 once it's in long mode on its stack. */
    ACKNOWLEDGED_AT : u64 : 0x138
    // Where in the code the far jump's offset, and the absolute addresses of the mailbox and the acknowledgement, go
    /** The offset of the far jump's 32-bit target in the code, which gets the long-mode code's physical address. */
    LONG_JUMP_OFFSET_AT : u64 : 0x3a
    /** The offset of the long-mode code, where the far jump goes. */
    LONG_MODE_AT : u64 : 0x40
    /** The offset of the 32-bit absolute address in the instruction that loads the mailbox's address. */
    MAILBOX_LOAD_AT : u64 : 0x52
    /** The offset of the 32-bit absolute address in the instruction that stores the acknowledgement. */
    ACKNOWLEDGE_STORE_AT : u64 : 0x5d

    /**
     * The x86-64 trampoline's machine code, copied to the start of its page, with its addresses written in after.
     *
     * Real mode, 16-bit: the GDT loaded, PAE on, CR3 the page tables, EFER.LME on, then protection and paging at
     * once, and a far jump into the 64-bit code segment. Long mode: the data segments loaded, the mailbox's address
     * and its stack taken, the bootloader told it's there, then a wait for the mailbox's goto_address, and a jump to
     * it with its argument in rdi and a zero return address.
     */
    TRAMPOLINE :: u8.[
        // 0x00: cli; cld; mov ax, cs; mov ds, ax; lgdt [0x118]
        0xfa, 0xfc, 0x8c, 0xc8, 0x8e, 0xd8, 0x0f, 0x01, 0x16, 0x18, 0x01,
        // 0x0b: mov eax, cr4; or eax, 0x20; mov cr4, eax
        0x0f, 0x20, 0xe0, 0x66, 0x83, 0xc8, 0x20, 0x0f, 0x22, 0xe0,
        // 0x15: mov eax, [0x120]; mov cr3, eax
        0x66, 0xa1, 0x20, 0x01, 0x0f, 0x22, 0xd8,
        // 0x1c: mov ecx, 0xc0000080; rdmsr; or eax, 0x100; wrmsr
        0x66, 0xb9, 0x80, 0x00, 0x00, 0xc0, 0x0f, 0x32, 0x66, 0x0d, 0x00, 0x01, 0x00, 0x00, 0x0f, 0x30,
        // 0x2c: mov eax, cr0; or eax, 0x80000001; mov cr0, eax
        0x0f, 0x20, 0xc0, 0x66, 0x0d, 0x01, 0x00, 0x00, 0x80, 0x0f, 0x22, 0xc0,
        // 0x38: jmp far dword 0x08:<long mode>
        0x66, 0xea, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00,
        // 0x40: mov ax, 0x10; mov ds, ax; mov es, ax; mov ss, ax; mov fs, ax; mov gs, ax
        0x66, 0xb8, 0x10, 0x00, 0x8e, 0xd8, 0x8e, 0xc0, 0x8e, 0xd0, 0x8e, 0xe0, 0x8e, 0xe8,
        // 0x4e: mov rsi, [<mailbox pointer>]
        0x48, 0x8b, 0x34, 0x25, 0x00, 0x00, 0x00, 0x00,
        // 0x56: mov rsp, [rsi + 8]
        0x48, 0x8b, 0x66, 0x08,
        // 0x5a: mov dword [<acknowledged>], 1
        0xc7, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        // 0x65: mov rax, [rsi]; test rax, rax; jnz +4; pause; jmp -12
        0x48, 0x8b, 0x06, 0x48, 0x85, 0xc0, 0x75, 0x04, 0xf3, 0x90, 0xeb, 0xf4,
        // 0x71: mov rdi, [rsi + 16]; push 0; jmp rax
        0x48, 0x8b, 0x7e, 0x10, 0x6a, 0x00, 0xff, 0xe0,
    ]

    /**
     * The trampoline's GDT: null, then 64-bit code (selector 0x08), then data (selector 0x10), flat, ring 0 (Intel SDM,
     * volume 3, segment descriptors).
     */
    GDT :: u64.[0, 0x00af9a000000ffff, 0x00cf92000000ffff]

    // IA32_APIC_BASE and its x2APIC bit, and x2APIC's ICR
    /** IA32_APIC_BASE's MSR number: the local APIC's base address and its enable bits. */
    APIC_BASE_MSR : u32 : 0x1b
    /** IA32_APIC_BASE's EXTD bit, bit 10: the local APIC is in x2APIC mode. */
    X2APIC_ENABLED : u64 : 1 << 10
    /** x2APIC's interrupt command register's MSR number, written whole, the destination in its high 32 bits. */
    X2APIC_ICR : u32 : 0x830
    // xAPIC's ICR, its low and high halves, and the delivery status bit
    /** xAPIC's interrupt command register's low half, its offset in bytes from the local APIC's base. */
    ICR_LOW : u64 : 0x300
    /** xAPIC's interrupt command register's high half, whose bits 31 to 24 are the destination APIC ID. */
    ICR_HIGH : u64 : 0x310
    /** The ICR's delivery status bit, bit 12: the IPI hasn't been accepted yet. xAPIC only. */
    DELIVERY_PENDING : u32 : 1 << 12
    /** An ICR command: INIT delivery, level assert, physical destination. */
    INIT_ASSERT : u32 : 0x4500
    /** An ICR command: start-up delivery, level assert; its low byte is the trampoline's page number below 1 MiB. */
    STARTUP : u32 : 0x4600

    /** What starting the other CPUs needs, made before the boot services are left. */
    Starting :: struct {
        /** The trampoline page's physical address, 4096-aligned and below 0xa0000, so a SIPI's vector can name it. */
        trampoline : u64,
        /** How many TSC ticks a microsecond is, measured against the firmware's Stall; at least 1. */
        ticks_per_microsecond : u64,
    }

    /**
     * Prepare to start the other CPUs: list them in the handoff, give each a stack, and write the trampoline.
     *
     * Every CPU the firmware's MP services know of and say is enabled goes into the handoff, the boot CPU first, each
     * other one with a stack of BOOT_STACK_SIZE bytes in loader-data pages; the boot CPU alone if the firmware has no
     * MP services. The trampoline's page goes below 1 MiB, and the TSC's speed is measured, for the waits starting them
     * takes, over a 10 ms Stall. Boot services have to be running.
     *
     * @param handoff The handoff, whose cpus and cpu_count are written; CPUs past what cpus holds are left out.
     * @param tables The page tables the trampoline loads, its root below 4 GiB, mapping the trampoline and the handoff
     *     where they are and the stacks in the direct map.
     * @param direct_map_offset The direct map's offset, which each stack_top is a virtual address in.
     * @return What start_cpus needs; null if boot services are gone, a stack couldn't be had, or there's no room for
     *     the trampoline below 1 MiB.
     */
    prepare_cpus :: fn(handoff: ptr[mut boot_protocol.Handoff], tables: ptr[PageTables], direct_map_offset: u64) -> Starting? {
        page_table :: tables.root
        services :: uefi.boot_services() or_return null
        handoff.cpu_count = 1
        handoff.cpus[0] = boot_protocol.Cpu.{hardware_id = boot_cpu_id()}
        match uefi.locate[uefi.MpServices](uefi.MP_SERVICES_GUID) {
            case Some(mp) => {
                count := cast[usize](0)
                enabled := cast[usize](0)
                if mp.get_number_of_processors(mp, &count, &enabled) == uefi.SUCCESS {
                    for i in cast[usize](0)..<count {
                        info := uefi.ProcessorInfo.{}
                        if mp.get_processor_info(mp, i, &info) != uefi.SUCCESS || info.status & uefi.PROCESSOR_ENABLED == 0
                            || info.status & uefi.PROCESSOR_BOOT != 0 || handoff.cpu_count >= cast[u64](handoff.cpus.count) {
                            continue
                        }
                        stack :: allocate_pages(LOADER_DATA, boot_protocol.BOOT_STACK_SIZE) or_return null
                        at :: cast[usize](handoff.cpu_count)
                        if at < handoff.cpus.count {
                            handoff.cpus[at] = boot_protocol.Cpu.{hardware_id = info.id,
                                stack_top = direct_map_offset + stack + boot_protocol.BOOT_STACK_SIZE}
                            handoff.cpu_count += 1
                        }
                    }
                }
            }
            case None => {}
        }
        trampoline : u64 = 0x9f000
        if services.allocate_pages(cast[u32](uefi.AllocateKind.MaxAddress), LOADER_DATA, 1, &trampoline) != uefi.SUCCESS {
            return null
        }
        // The code, its GDT and pointer, and the addresses it needs
        for byte, i in TRAMPOLINE {
            cast[ptr[mut u8]](cast[rawptr](trampoline + cast[u64](i)))^ = byte
        }
        for entry, i in GDT {
            cast[ptr[mut u64]](cast[rawptr](trampoline + GDT_AT + cast[u64](i) * 8))^ = entry
        }
        cast[ptr[mut u16]](cast[rawptr](trampoline + GDT_POINTER_AT))^ = cast[u16](GDT.count * 8 - 1)
        cast[ptr[mut u32]](cast[rawptr](trampoline + GDT_POINTER_AT + 2))^ = cast[u32](trampoline + GDT_AT)
        cast[ptr[mut u32]](cast[rawptr](trampoline + PAGE_TABLE_AT))^ = cast[u32](page_table)
        cast[ptr[mut u32]](cast[rawptr](trampoline + LONG_JUMP_OFFSET_AT))^ = cast[u32](trampoline + LONG_MODE_AT)
        cast[ptr[mut u32]](cast[rawptr](trampoline + MAILBOX_LOAD_AT))^ = cast[u32](trampoline + MAILBOX_AT)
        cast[ptr[mut u32]](cast[rawptr](trampoline + ACKNOWLEDGE_STORE_AT))^ = cast[u32](trampoline + ACKNOWLEDGED_AT)
        // The TSC against the firmware's Stall
        before :: x86_64.rdtsc()
        _ = services.stall(10000)
        ticks :: (x86_64.rdtsc() - before) / 10000
        return Starting.{trampoline = trampoline, ticks_per_microsecond = if ticks == 0 { cast[u64](1000) } else { ticks }}
    }

    /**
     * Start every CPU but the boot CPU, after the boot services are left, one at a time.
     *
     * For each: its mailbox's address in the trampoline, INIT, 10 ms, a SIPI, 200 µs, another, then up to 100 ms for it
     * to say it's in long mode. One that doesn't is left out of the handoff, the CPUs after it moved down. Each started
     * CPU waits on its mailbox, its boot_protocol.Cpu in the handoff, for a goto_address. Runs with interrupts off on
     * the boot CPU, with the firmware's page tables still loaded.
     *
     * @param handoff The handoff, whose cpus are those prepare_cpus listed; cpu_count becomes how many are running,
     *     the boot CPU included.
     * @param starting What prepare_cpus made.
     */
    start_cpus :: fn(handoff: ptr[mut boot_protocol.Handoff], starting: Starting) {
        started := cast[u64](1)
        for i in cast[u64](1)..<handoff.cpu_count {
            if i >= cast[u64](handoff.cpus.count) {
                break
            }
            cpu :: handoff.cpus[cast[usize](i)]
            slot :: cast[usize](started)
            if slot >= handoff.cpus.count {
                break
            }
            handoff.cpus[slot] = cpu
            mailbox :: cast[u64](cast[rawptr](&handoff.cpus[slot]))
            acknowledged :: cast[ptr[mut u32]](cast[rawptr](starting.trampoline + ACKNOWLEDGED_AT))
            acknowledged^ = 0
            cast[ptr[mut u64]](cast[rawptr](starting.trampoline + MAILBOX_AT))^ = mailbox
            send_ipi(cpu.hardware_id, INIT_ASSERT)
            wait_microseconds(starting, 10000)
            vector :: cast[u32](starting.trampoline >> 12)
            send_ipi(cpu.hardware_id, STARTUP | vector)
            wait_microseconds(starting, 200)
            send_ipi(cpu.hardware_id, STARTUP | vector)
            for wait in 0..<1000 {
                if intrinsics_load(acknowledged) != 0 {
                    break
                }
                wait_microseconds(starting, 100)
            }
            if intrinsics_load(acknowledged) != 0 {
                started += 1
            }
        }
        handoff.cpu_count = started
    }

    /**
     * Load a 32-bit word that another CPU writes, without the compiler keeping or merging it.
     *
     * @param address The word's address, identity-mapped.
     * @return The word as it is in memory now.
     */
    intrinsics_load :: fn(address: ptr[u32]) -> u32 {
        return intrinsics.volatile_load_u32(address)
    }

    /**
     * Send an IPI to a CPU through the boot CPU's local APIC, x2APIC's or xAPIC's, as the firmware left it.
     *
     * With xAPIC it waits, up to 100000 reads, for the IPI to be accepted; with x2APIC it doesn't wait. The local
     * APIC's registers have to be identity-mapped.
     *
     * @param apic_id The destination CPU's local APIC ID; in xAPIC mode only its low 8 bits count.
     * @param command The ICR's low 32 bits: INIT_ASSERT, or STARTUP with the trampoline's page number.
     */
    send_ipi :: fn(apic_id: u64, command: u32) {
        base :: x86_64.rdmsr(APIC_BASE_MSR)
        if base & X2APIC_ENABLED != 0 {
            x86_64.wrmsr(X2APIC_ICR, (apic_id << 32) | cast[u64](command))
            return void
        }
        registers :: base & 0xfffff000
        cast[ptr[mut u32]](cast[rawptr](registers + ICR_HIGH))^ = cast[u32](apic_id << 24)
        cast[ptr[mut u32]](cast[rawptr](registers + ICR_LOW))^ = command
        for i in 0..<100000 {
            if cast[ptr[u32]](cast[rawptr](registers + ICR_LOW))^ & DELIVERY_PENDING == 0 {
                break
            }
        }
    }

    /**
     * Wait by spinning on the TSC.
     *
     * @param starting What prepare_cpus made, with the TSC's speed.
     * @param microseconds How long to wait, in microseconds, as near as the measured speed allows.
     */
    wait_microseconds :: fn(starting: Starting, microseconds: u64) {
        until :: x86_64.rdtsc() + microseconds * starting.ticks_per_microsecond
        loop {
            if x86_64.rdtsc() >= until {
                break
            }
            x86_64.pause()
        }
    }
}
#else {
    import aarch64 from "base/intrinsics"
    import devicetree from "../../devicetree"

    /*
     * AArch64's: the CPUs from the device tree's cpu nodes, each started by PSCI's CPU_ON, through the conduit its psci
     * node names, at the trampoline, its mailbox's address in x0, at EL1 with its MMU off. The trampoline loads the
     * boot CPU's memory attributes, translation control, tables and system control, turning its MMU on, takes its
     * stack, and waits on its mailbox as x86-64's does. Its words are its instructions, then the registers' values
     * from DATA_AT.
     */

    /**
     * The offset in bytes in the trampoline's page of the values it loads, 8 bytes each: MAIR_EL1, TCR_EL1, TTBR0_EL1,
     * TTBR1_EL1 and SCTLR_EL1.
     */
    DATA_AT : u64 : 0x80
    /** PSCI's CPU_ON function ID, its SMC64 one (Arm Power State Coordination Interface specification). */
    PSCI_CPU_ON : u64 : 0xc4000003

    /** The AArch64 trampoline's instructions, copied to the start of its page, with its data at DATA_AT. */
    TRAMPOLINE :: u32.[
        0x10000409, // adr x9, data
        0xf9400121, // ldr x1, [x9]
        0xf9400522, // ldr x2, [x9, #8]
        0xf9400923, // ldr x3, [x9, #16]
        0xf9400d24, // ldr x4, [x9, #24]
        0xd518a201, // msr mair_el1, x1
        0xd5182042, // msr tcr_el1, x2
        0xd5182003, // msr ttbr0_el1, x3
        0xd5182024, // msr ttbr1_el1, x4
        0xd5033fdf, // isb
        0xd508871f, // tlbi vmalle1
        0xd503379f, // dsb nsh
        0xd5033fdf, // isb
        0xf9401125, // ldr x5, [x9, #32]
        0xd5181005, // msr sctlr_el1, x5
        0xd5033fdf, // isb
        0xf9400406, // ldr x6, [x0, #8]
        0x910000df, // mov sp, x6
        0xf9400007, // 0x48: ldr x7, [x0]
        0xb5000067, // cbnz x7, 0x58
        0xd503203f, // yield
        0x17fffffd, // b 0x48
        0xf9400801, // 0x58: ldr x1, [x0, #16]
        0xaa0103e0, // mov x0, x1
        0xaa1f03fd, // mov x29, xzr
        0xaa1f03fe, // mov x30, xzr
        0xd61f00e0, // br x7
    ]

    /** What starting the other CPUs needs, made before the boot services are left. */
    Starting :: struct {
        /** The trampoline page's physical address, 4096-aligned, where CPU_ON starts each CPU. */
        trampoline : u64,
        /** PSCI's conduit: true for SMC, false for HVC, as the psci node's method says, HVC without one. */
        smc : bool,
    }

    /**
     * Prepare to start the other CPUs: list them in the handoff, give each a stack, and write the trampoline.
     *
     * The CPUs come from the device tree's cpu nodes, and PSCI's conduit from its psci node, "arm,psci-1.0" or
     * "arm,psci-0.2"; without a device tree or a psci node, the boot CPU alone is listed. The trampoline's data holds
     * the boot CPU's SCTLR_EL1 as it is now, with the bootloader's MAIR, TCR and roots. Boot services have to be
     * running.
     *
     * @param handoff The handoff, whose cpus and cpu_count are written, each CPU but the boot CPU with a stack of
     *     BOOT_STACK_SIZE bytes; CPUs past what cpus holds are left out.
     * @param tables The page tables the trampoline loads, mapping the trampoline and the handoff where they are and
     *     the stacks in the direct map.
     * @param direct_map_offset The direct map's offset, which each stack_top is a virtual address in.
     * @return What start_cpus needs; null if a page for the trampoline or a stack couldn't be had.
     */
    prepare_cpus :: fn(handoff: ptr[mut boot_protocol.Handoff], tables: ptr[PageTables], direct_map_offset: u64) -> Starting? {
        handoff.cpu_count = 1
        handoff.cpus[0] = boot_protocol.Cpu.{hardware_id = boot_cpu_id()}
        trampoline :: allocate_pages(LOADER_DATA, 4096) or_return null
        for word, i in TRAMPOLINE {
            cast[ptr[mut u32]](cast[rawptr](trampoline + cast[u64](i) * 4))^ = word
        }
        data :: trampoline + DATA_AT
        values :: u64.[MAIR_VALUE, tcr_value(), tables.low_root, tables.root, aarch64.read_system_register(.SCTLR_EL1)]
        for value, i in values {
            cast[ptr[mut u64]](cast[rawptr](data + cast[u64](i) * 8))^ = value
        }
        starting := Starting.{trampoline = trampoline}
        // The other CPUs, and PSCI's conduit, from the device tree; the boot CPU alone without one
        address :: cast[u64](uefi.configuration_table(uefi.DEVICE_TREE_GUID) or_else null)
        tree := devicetree.open(address) or_return starting
        psci := devicetree.find_compatible(&tree, "arm,psci-1.0")
        if psci is_none {
            psci = devicetree.find_compatible(&tree, "arm,psci-0.2")
        }
        match psci {
            case Some(node) => {
                found := node
                match devicetree.property(&tree, &found, "method") {
                    case Some(method) => starting.smc = devicetree.lists(method, "smc")
                    case None => {}
                }
            }
            case None => return starting
        }
        ids : u64[boot_protocol.MAX_CPUS]
        count :: devicetree.cpus(&tree, ids)
        boot :: handoff.cpus[0].hardware_id
        for id, i in ids {
            if i >= count || handoff.cpu_count >= cast[u64](handoff.cpus.count) {
                break
            }
            if id == boot {
                continue
            }
            stack :: allocate_pages(LOADER_DATA, boot_protocol.BOOT_STACK_SIZE) or_return null
            at :: cast[usize](handoff.cpu_count)
            if at < handoff.cpus.count {
                handoff.cpus[at] = boot_protocol.Cpu.{hardware_id = id, stack_top = direct_map_offset + stack + boot_protocol.BOOT_STACK_SIZE}
                handoff.cpu_count += 1
            }
        }
        return starting
    }

    /**
     * Start every CPU but the boot CPU, after the boot services are left, by PSCI's CPU_ON.
     *
     * What each reads with its MMU off, the trampoline and its mailbox, is cleaned to the point of coherency first.
     * One PSCI won't start is left out of the handoff, the CPUs after it moved down. CPU_ON returns once the CPU is
     * started, not once it's waiting on its mailbox. Runs on the boot CPU, interrupts masked.
     *
     * @param handoff The handoff, whose cpus are those prepare_cpus listed; cpu_count becomes how many PSCI started,
     *     the boot CPU included.
     * @param starting What prepare_cpus made.
     */
    start_cpus :: fn(handoff: ptr[mut boot_protocol.Handoff], starting: Starting) {
        clean(starting.trampoline, 4096)
        started := cast[u64](1)
        for i in cast[u64](1)..<handoff.cpu_count {
            if i >= cast[u64](handoff.cpus.count) {
                break
            }
            cpu :: handoff.cpus[cast[usize](i)]
            slot :: cast[usize](started)
            if slot >= handoff.cpus.count {
                break
            }
            handoff.cpus[slot] = cpu
            mailbox :: cast[u64](cast[rawptr](&handoff.cpus[slot]))
            clean(mailbox, cast[u64](size_of(boot_protocol.Cpu)))
            result :: if starting.smc { aarch64.smc(PSCI_CPU_ON, cpu.hardware_id, starting.trampoline, mailbox) }
                else { aarch64.hvc(PSCI_CPU_ON, cpu.hardware_id, starting.trampoline, mailbox) }
            if result == 0 {
                started += 1
            }
        }
        handoff.cpu_count = started
    }

    /**
     * Clean memory to the point of coherency, a 64-byte line at a time, for a CPU whose caches are off, then wait for
     * it with a full-system DSB.
     *
     * @param address The memory's address, identity-mapped; it needn't be line-aligned.
     * @param size How many bytes, each line they touch cleaned.
     */
    clean :: fn(address: u64, size: u64) {
        line := address & ~cast[u64](63)
        loop {
            if line >= address + size {
                break
            }
            aarch64.dc_cvac(cast[rawptr](line))
            line += 64
        }
        aarch64.dsb(.SY)
    }
}
