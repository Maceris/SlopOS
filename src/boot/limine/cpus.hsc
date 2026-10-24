package limine_boot

import intrinsics from "base"
import runtime from "base"
import boot_info from "../../boot_info"

/*
 * Starting the other CPUs (docs/specs/boot_info.md, CPUs). Limine parks each one until its
 * MpInfo's goto_address is written, then jumps there with the MpInfo's address as the argument.
 */

/*
 * What start_cpu leaves for a CPU it starts, carved with BootInfo, one per CPU. A BootCpu's
 * boot_handle points at its StartingCpu, and the MpInfo's extra_argument points back at it once
 * the CPU is started.
 */
StartingCpu :: struct {
    info : ptr[mut MpInfo],
    // Set by start_cpu, before the CPU reads them.
    carrier : ptr[mut runtime.CarrierBlock],
    entry : boot_info.CpuEntry,
}

// Starts cpu at cpu_entry, which loads carrier and calls entry. Doesn't wait for it.
start_cpu : boot_info.StartCpu : fn(cpu: ptr[boot_info.BootCpu], carrier #escaping : ptr[mut runtime.CarrierBlock], entry: boot_info.CpuEntry) {
    starting :: cast[ptr[mut StartingCpu]](cpu.boot_handle)
    starting.carrier = carrier
    starting.entry = entry
    starting.info.extra_argument = cast[u64](starting)
    // The write that starts it, after everything it reads
    intrinsics.atomic_store_u64_release(&starting.info.goto_address, cast[u64](cpu_entry))
}

/*
 * Where Limine starts a CPU, on that CPU's boot stack, with interrupts disabled. Like
 * kernel_entry, it has no carrier block or context yet: it sets carrier.stack_limit for its boot
 * stack, loads the carrier block start_cpu was given, pushes the boot context, and calls the
 * kernel's entry.
 */
cpu_entry #calling_convention(.c) #no_context :: fn(info: ptr[MpInfo]) #never_returns {
    starting :: cast[ptr[StartingCpu]](info.extra_argument)
    carrier :: starting.carrier
    // The stack's lowest address, as in kernel_entry
    stack :: cast[u64](intrinsics.stack_pointer())
    carrier.stack_limit = cast[rawptr](stack - BOOT_STACK_SIZE + BOOT_STACK_SLACK + runtime.STACK_GUARD)
    carrier.native_stack_limit = carrier.stack_limit
    intrinsics.set_carrier(carrier)
    push_context boot from runtime.MINIMAL_CONTEXT {
        push_context early (logger = &EARLY_LOGGER, log_level = .INFO) {
            starting.entry()
        }
    }
}

// Every CPU, the boot CPU first. Each one's boot_handle is its StartingCpu, for start_cpu.
cpus :: fn(mp: ptr[MpResponse], cpus: mut boot_info.BootCpu[], starting #escaping : mut StartingCpu[]) -> boot_info.BootCpu[] {
    count : usize = 1
    for cpu in pointers(mp.cpus, mp.cpu_count) {
        index := count
        if cpu.lapic_id == mp.bsp_lapic_id {
            index = 0
        }
        else {
            count += 1
        }
        runtime.assert(index < cpus.count && index < starting.count, "cpus needs room for every CPU")
        starting[index].info = cast[ptr[mut MpInfo]](cpu)
        cpus[index] = boot_info.BootCpu.{cast[u64](cpu.lapic_id), cast[rawptr](&starting[index])}
    }
    return cpus
}
