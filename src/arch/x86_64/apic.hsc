package arch_x86_64

import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * The local APIC in x2APIC mode, through MSRs, and its timer.
 *
 * Every vector the kernel uses. Device interrupts get 48 to 239 (docs/specs/arch_interface.md, x86-64).
 */
//SPEC: Intel SDM Vol. 3A §11 (APIC), §11.12 (x2APIC), Table 11-6 (x2APIC MSR addresses)
/** The vector of the local APIC timer's interrupt, the first one past the 32 the CPU reserves for exceptions. */
TIMER_VECTOR : u8 : 32
/** The vector of the reschedule IPI (arch_interface.IpiKind.Reschedule). */
RESCHEDULE_VECTOR : u8 : 33
/** The vector of the TLB-flush IPI (arch_interface.IpiKind.TlbFlush). */
TLB_FLUSH_VECTOR : u8 : 34
/** The vector of the stop IPI (arch_interface.IpiKind.Stop), sent on panic or shutdown. */
STOP_VECTOR : u8 : 35
/** The first vector given to devices, the first of device_interrupt_range. */
FIRST_DEVICE_VECTOR : u32 : 48
/** How many vectors devices get, from FIRST_DEVICE_VECTOR: 48 to 239. */
DEVICE_VECTOR_COUNT : u32 : 192
/** The vector the local APIC raises for a spurious interrupt, which needs no end of interrupt. */
SPURIOUS_VECTOR : u8 : 255

/** The IA32_APIC_BASE MSR's number: the local APIC's base address and its enable bits. */
IA32_APIC_BASE : u32 : 0x1b
/** IA32_APIC_BASE bit 10 (EXTD): x2APIC mode, with the registers reached as MSRs. */
APIC_BASE_X2APIC_ENABLE : u64 : 1 << 10
/** IA32_APIC_BASE bit 11 (EN): the local APIC globally enabled. */
APIC_BASE_ENABLE : u64 : 1 << 11
/** The IA32_TSC_DEADLINE MSR's number: the TSC value at which the timer fires in TSC-deadline mode, 0 to disarm it. */
IA32_TSC_DEADLINE : u32 : 0x6e0

/** The x2APIC's local APIC ID register (MSR 0x802): the CPU's 32-bit x2APIC ID, its hardware ID. */
X2APIC_ID : u32 : 0x802
/** The x2APIC's end-of-interrupt register (MSR 0x80b), written with 0 to end the interrupt in service. */
X2APIC_EOI : u32 : 0x80b
/** The x2APIC's spurious-interrupt vector register (MSR 0x80f): the software enable and the spurious vector. */
X2APIC_SPURIOUS : u32 : 0x80f
/** The first of the x2APIC's 8 interrupt request registers (MSRs 0x820 to 0x827), 32 vectors each. */
X2APIC_IRR_0 : u32 : 0x820
/** The x2APIC's interrupt command register (MSR 0x830), 64 bits: the destination in bits 32-63, the rest below. */
X2APIC_ICR : u32 : 0x830
/** The x2APIC's local vector table entry for the timer (MSR 0x832): its vector, mask and mode. */
X2APIC_LVT_TIMER : u32 : 0x832
/** The x2APIC timer's initial count register (MSR 0x838): writing it starts a count-down, 0 stops it. */
X2APIC_TIMER_INITIAL_COUNT : u32 : 0x838
/** The x2APIC timer's current count register (MSR 0x839), read-only. */
X2APIC_TIMER_CURRENT_COUNT : u32 : 0x839
/** The x2APIC timer's divide configuration register (MSR 0x83e). */
X2APIC_TIMER_DIVIDE : u32 : 0x83e

/** Spurious-interrupt vector register bit 8: the local APIC software-enabled. */
SPURIOUS_APIC_ENABLE : u64 : 1 << 8
/** Local vector table entry bit 16: the interrupt masked. */
LVT_MASKED : u64 : 1 << 16
/** Delivery mode 100b in the interrupt command register's bits 8-10: an NMI, whose vector is ignored. */
ICR_DELIVERY_NMI : u64 : 4 << 8
/** Timer mode 00b in the timer's LVT entry, bits 17-18: one-shot, counting down from the initial count once. */
LVT_TIMER_ONE_SHOT : u64 : 0 << 17
/** Timer mode 10b in the timer's LVT entry, bits 17-18: TSC-deadline, firing when the TSC reaches IA32_TSC_DEADLINE. */
LVT_TIMER_TSC_DEADLINE : u64 : 2 << 17
/** Divide configuration 1011b: the timer counts at the bus clock divided by 1. */
TIMER_DIVIDE_BY_1 : u64 : 0xb

// PIT channel 2, for measuring the TSC when nothing else gives its frequency
//SPEC: Intel 8254 datasheet; port 0x61 bits 0 (gate), 1 (speaker) and 5 (channel 2 output)
/** The PIT's input clock, in Hz: how fast its counters count down. */
PIT_FREQUENCY : u64 : 1193182
/** The I/O port of PIT channel 2's counter. */
PIT_CHANNEL_2 : u16 : 0x42
/** The I/O port of the PIT's mode and command register. */
PIT_COMMAND : u16 : 0x43
/** The I/O port whose bit 0 gates PIT channel 2, bit 1 drives the speaker, and bit 5 reads channel 2's output. */
PIT_GATE_PORT : u16 : 0x61
/** The PIT command for channel 2, low then high byte, mode 0 (interrupt on terminal count), binary. */
PIT_CHANNEL_2_MODE_0 : u8 : 0xb0
/** How long calibration measures, in parts of a second: 100, so 10 ms. */
CALIBRATION_DIVISOR : u64 : 100

//TODO(claude): xAPIC through its memory-mapped registers when there's no x2APIC: the kernel window can map them, but init_cpu would need them mapped first (testable with QEMU's -cpu max,-x2apic)
/**
 * Turn on x2APIC mode and software-enable the calling CPU's local APIC, with spurious interrupts on SPURIOUS_VECTOR.
 *
 * The CPU has to support x2APIC: there's no fallback to the memory-mapped xAPIC yet. IA32_APIC_BASE's other bits are
 * kept as they were.
 */
enable_local_apic :: fn() {
    base :: x86_64.rdmsr(IA32_APIC_BASE)
    x86_64.wrmsr(IA32_APIC_BASE, base | APIC_BASE_ENABLE | APIC_BASE_X2APIC_ENABLE)
    x86_64.wrmsr(X2APIC_SPURIOUS, SPURIOUS_APIC_ENABLE | cast[u64](SPURIOUS_VECTOR))
}

/**
 * Acknowledge the interrupt being handled on the calling CPU.
 *
 * @param id The interrupt, which isn't used: the local APIC ends the highest-priority one in service, which it knows.
 */
end_of_interrupt :: fn(id: arch_interface.InterruptId) {
    x86_64.wrmsr(X2APIC_EOI, 0)
}

/**
 * Give the interrupt IDs the kernel may give to devices.
 *
 * @return first FIRST_DEVICE_VECTOR, 48, the first vector past the timer's and the IPIs'.
 * @return count DEVICE_VECTOR_COUNT, 192, so devices get 48 to 239, below the spurious vector.
 */
device_interrupt_range :: fn() -> (first: arch_interface.InterruptId, count: u32) {
    return cast[arch_interface.InterruptId](FIRST_DEVICE_VECTOR), DEVICE_VECTOR_COUNT
}

/**
 * Send an IPI to one CPU: fixed delivery, physical destination, edge triggered.
 *
 * @param cpu_hardware_id The target CPU's x2APIC ID, all 32 bits of it.
 * @param kind What it's for, which picks its vector: RESCHEDULE_VECTOR, TLB_FLUSH_VECTOR or STOP_VECTOR.
 */
send_ipi :: fn(cpu_hardware_id: u64, kind: arch_interface.IpiKind) {
    vector :: match kind {
        case .Reschedule => RESCHEDULE_VECTOR
        case .TlbFlush => TLB_FLUSH_VECTOR
        case .Stop => STOP_VECTOR
    }
    // Fixed delivery, physical destination, edge triggered
    x86_64.wrmsr(X2APIC_ICR, (cpu_hardware_id << 32) | cast[u64](vector))
}

/**
 * Raise an NMI on the calling CPU, for tests of the critical-event entry.
 *
 * It's sent to the CPU's own x2APIC ID, read from X2APIC_ID: the self shorthand only takes fixed delivery.
 */
test_nmi :: fn() {
    self :: x86_64.rdmsr(X2APIC_ID)
    x86_64.wrmsr(X2APIC_ICR, (self << 32) | ICR_DELIVERY_NMI)
}

/**
 * Tell whether an interrupt is waiting in the calling CPU's local APIC, for preemption points.
 *
 * @return True if any bit of the 8 interrupt request registers is set: an interrupt accepted but not yet delivered,
 *     which interrupts being disabled holds back. False if none is.
 */
interrupt_pending :: fn() -> bool {
    for i in 0..<8 {
        if x86_64.rdmsr(X2APIC_IRR_0 + cast[u32](i)) != 0 {
            return true
        }
    }
    return false
}

/**
 * Give the bytes of memory the interrupt controller keeps for each device's MSIs.
 *
 * @return 0, never null: MSIs go straight to the local APICs, which take them and keep nothing per device.
 */
msi_device_memory :: fn() -> u64? {
    return 0
}

/**
 * Give the bytes of memory the interrupt controller needs for MSIs at all.
 *
 * @return 0: the local APICs need none.
 */
msi_controller_memory :: fn() -> u64 {
    return 0
}

/**
 * Set up MSIs, which needs nothing on x86-64: this does nothing.
 *
 * @param memory The memory msi_controller_memory asked for, none, so not used.
 */
init_msi :: fn(memory: arch_interface.PhysicalAddress) {
}

/**
 * Add a device's MSIs, which needs nothing on x86-64: this does nothing.
 *
 * @param source The device's source, unused on x86-64.
 * @param memory The memory msi_device_memory asked for, none, so not used.
 * @param events How many MSIs the device has, not used.
 */
add_msi_device :: fn(source: u32, memory: arch_interface.PhysicalAddress, events: u32) {
}

/**
 * Forget a device's MSIs, which needs nothing on x86-64: this does nothing.
 *
 * @param source The device's source, unused on x86-64.
 */
remove_msi_device :: fn(source: u32) {
}

//SPEC: Intel SDM Vol. 3A §11.11 (message signalled interrupts)
//TODO(claude): destinations above 255 need interrupt remapping through the IOMMU (after M7)
/**
 * Make the message a device sends to raise id on a CPU.
 *
 * The address is the local APICs' range, 0xfee00000, with the destination in bits 12-19; the data is the vector,
 * with fixed delivery, edge triggered. Nothing is kept, so no state changes.
 *
 * @param source The device's source, not used on x86-64.
 * @param event The device's event, not used on x86-64.
 * @param cpu_hardware_id The target CPU's x2APIC ID. Only its low 8 bits are used, so a CPU whose ID is above 255
 *     can't be reached: another CPU, the one with the low 8 bits, gets the interrupt.
 * @param id The vector to raise, of which only the low 8 bits are used; one of device_interrupt_range's.
 * @return The address and data the device's driver programs into its MSI or MSI-X registers.
 */
route_msi :: fn(source: u32, event: u32, cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    return arch_interface.MsiMessage.{
        address = 0xfee00000 | ((cpu_hardware_id & 0xff) << 12),
        data = cast[u32](id) & 0xff,
    }
}

/**
 * Make the message a device sends to raise id on another CPU, as route_msi makes it.
 *
 * Nothing is kept, so the device's driver has to program the new message for the move to take effect.
 *
 * @param source The device's source, not used on x86-64.
 * @param event The device's event, not used on x86-64.
 * @param cpu_hardware_id The new target CPU's x2APIC ID, of which only the low 8 bits are used, as in route_msi.
 * @param id The vector to raise, of which only the low 8 bits are used.
 * @return The new address and data.
 */
move_msi :: fn(source: u32, event: u32, cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    return route_msi(source, event, cpu_hardware_id, id)
}

/**
 * Stop delivering a device's event, which needs nothing on x86-64: this does nothing.
 *
 * The device stops sending the message once its driver stops asking for it.
 *
 * @param source The device's source, not used.
 * @param event The device's event, not used.
 */
unroute_msi :: fn(source: u32, event: u32) {
}

/**
 * Give the page devices write their MSIs to as memory, for an IOMMU to map.
 *
 * @return Null: MSIs are writes to the interrupt range, which VT-d takes as interrupts, not DMA it translates.
 */
msi_doorbell :: fn() -> arch_interface.PhysicalAddress? {
    return null
}

// Timer

/**
 * Calibrate the calling CPU's counter and set up its timer, disarmed.
 *
 * The counter is the TSC. Its frequency is hint if the bootloader measured it, otherwise from CPUID leaf 0x15,
 * otherwise measured against the PIT, which busy-waits 10 ms. Deadlines use TSC-deadline mode where the CPU has it,
 * otherwise the local APIC timer counting down at the bus clock, whose frequency is measured against the TSC, another
 * 10 ms. The choice is kept in the CPU's TimerState, so it's called on each CPU, after init_cpu.
 *
 * @param hint The TSC's frequency in Hz as the bootloader measured it (BootInfo.counter_frequency_hint), or null if
 *     it didn't.
 * @return The TSC's frequency in Hz, the rate counter() counts at.
 */
init_timer :: fn(hint: u64?) -> u64 {
    timer :: &current_cpu().timer
    timer.tsc_frequency = hint or_else (tsc_frequency_from_cpuid() or_else measure_tsc_frequency())
    features :: detect_features()
    timer.tsc_deadline = has(&features, .X86TscDeadline)
    if timer.tsc_deadline {
        // The LVT entry has to be in TSC-deadline mode before IA32_TSC_DEADLINE is written
        x86_64.wrmsr(X2APIC_LVT_TIMER, LVT_TIMER_TSC_DEADLINE | cast[u64](TIMER_VECTOR))
        x86_64.wrmsr(IA32_TSC_DEADLINE, 0)
    }
    else {
        x86_64.wrmsr(X2APIC_TIMER_DIVIDE, TIMER_DIVIDE_BY_1)
        timer.apic_frequency = measure_apic_timer_frequency(timer.tsc_frequency)
        x86_64.wrmsr(X2APIC_LVT_TIMER, LVT_TIMER_ONE_SHOT | cast[u64](TIMER_VECTOR))
    }
    return timer.tsc_frequency
}

/**
 * Read the counter deadlines are given in.
 *
 * @return The calling CPU's TSC, counting at the frequency init_timer returned.
 */
counter :: fn() -> u64 {
    return x86_64.rdtsc()
}

/**
 * Raise a timer interrupt on the calling CPU once counter() reaches value, replacing any deadline set before.
 *
 * In TSC-deadline mode the deadline is exact; a value of 0 disarms it, as cancel_deadline does. Otherwise the local
 * APIC timer counts down the time left, scaled to its ticks: at least one tick, so a deadline already past fires at
 * once, and at most 2^32 - 1, so a deadline further away fires early, and the caller has to check the counter and set
 * it again.
 *
 * @param value The TSC value to fire at.
 */
set_deadline :: fn(value: u64) {
    timer :: &current_cpu().timer
    if timer.tsc_deadline {
        x86_64.wrmsr(IA32_TSC_DEADLINE, value)
        return void
    }
    now :: x86_64.rdtsc()
    ticks := cast[u64](1)
    if value > now {
        ticks = scale(value - now, timer.apic_frequency, timer.tsc_frequency)
    }
    // An initial count of 0 stops the timer, and it's only 32 bits wide
    if ticks == 0 {
        ticks = 1
    }
    if ticks > 0xffffffff {
        ticks = 0xffffffff
    }
    x86_64.wrmsr(X2APIC_TIMER_INITIAL_COUNT, ticks)
}

/** Disarm the calling CPU's timer, so the deadline set last doesn't fire; one already raised may still be pending. */
cancel_deadline :: fn() {
    if current_cpu().timer.tsc_deadline {
        x86_64.wrmsr(IA32_TSC_DEADLINE, 0)
        return void
    }
    x86_64.wrmsr(X2APIC_TIMER_INITIAL_COUNT, 0)
}

/**
 * Compute value × numerator / denominator, rounded down, without overflowing in between.
 *
 * @param value The amount to scale, like a count of TSC ticks.
 * @param numerator The rate to scale to, below 2^32 for the product in between not to overflow.
 * @param denominator The rate to scale from, not 0, below 2^32 for the same reason.
 * @return The scaled value, rounded down; it overflows only if the result itself doesn't fit in 64 bits.
 */
scale :: fn(value, numerator, denominator: u64) -> u64 {
    return value / denominator * numerator + value % denominator * numerator / denominator
}

//SPEC: Intel SDM Vol. 2A, CPUID leaf 15H
/**
 * Read the TSC's frequency from CPUID leaf 0x15: the crystal clock's frequency times the ratio of the TSC to it.
 *
 * @return The frequency in Hz, rounded down, or null when the CPU has no leaf 0x15 or doesn't report the crystal's
 *     frequency or the ratio (any of them 0).
 */
tsc_frequency_from_cpuid :: fn() -> u64? {
    if x86_64.cpuid(0).eax < 0x15 {
        return null
    }
    leaf :: x86_64.cpuid(0x15)
    if leaf.eax == 0 || leaf.ebx == 0 || leaf.ecx == 0 {
        return null
    }
    return cast[u64](leaf.ecx) * cast[u64](leaf.ebx) / cast[u64](leaf.eax)
}

/**
 * Measure the TSC's frequency by counting its ticks while PIT channel 2 counts down 10 ms.
 *
 * It busy-waits those 10 ms, and an interrupt or SMI in between makes the result too high.
 *
 * @return The frequency in Hz, to within the PIT's and the TSC's resolution over 10 ms.
 */
measure_tsc_frequency :: fn() -> u64 {
    start, end :: time_pit_interval()
    return (end - start) * CALIBRATION_DIVISOR
}

/**
 * Time PIT channel 2 counting down 10 ms, in TSC ticks, busy-waiting until it's done.
 *
 * The gate is turned off and on again to start the count, with the speaker kept off.
 *
 * @return The TSC when the count started.
 * @return The TSC once channel 2's output said it reached zero.
 */
time_pit_interval :: fn() -> (u64, u64) {
    count :: PIT_FREQUENCY / CALIBRATION_DIVISOR
    gate :: x86_64.in_u8(PIT_GATE_PORT) & 0xfc
    x86_64.out_u8(PIT_GATE_PORT, gate)
    x86_64.out_u8(PIT_COMMAND, PIT_CHANNEL_2_MODE_0)
    x86_64.out_u8(PIT_CHANNEL_2, cast[u8](count & 0xff))
    x86_64.out_u8(PIT_CHANNEL_2, cast[u8](count >> 8))
    x86_64.out_u8(PIT_GATE_PORT, gate | 1)
    start :: x86_64.rdtsc()
    loop {
        x86_64.pause()
    }
    while (x86_64.in_u8(PIT_GATE_PORT) & 0x20) == 0
    return start, x86_64.rdtsc()
}

/**
 * Measure the calling CPU's local APIC timer frequency by letting it count down for 10 ms of TSC time.
 *
 * The timer's LVT entry is left masked and the timer stopped, with whatever divide configuration was set before,
 * which the result is for.
 *
 * @param tsc_frequency The TSC's frequency in Hz, at least 100 for the wait to be more than nothing.
 * @return The timer's frequency in ticks per second, at the divide configuration it had.
 */
measure_apic_timer_frequency :: fn(tsc_frequency: u64) -> u64 {
    x86_64.wrmsr(X2APIC_LVT_TIMER, LVT_MASKED | cast[u64](TIMER_VECTOR))
    x86_64.wrmsr(X2APIC_TIMER_INITIAL_COUNT, 0xffffffff)
    start :: x86_64.rdtsc()
    loop {
        x86_64.pause()
    }
    while x86_64.rdtsc() - start < tsc_frequency / CALIBRATION_DIVISOR
    remaining :: x86_64.rdmsr(X2APIC_TIMER_CURRENT_COUNT)
    x86_64.wrmsr(X2APIC_TIMER_INITIAL_COUNT, 0)
    return (0xffffffff - remaining) * CALIBRATION_DIVISOR
}
