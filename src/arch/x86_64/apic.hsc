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
TIMER_VECTOR : u8 : 32
RESCHEDULE_VECTOR : u8 : 33
TLB_FLUSH_VECTOR : u8 : 34
STOP_VECTOR : u8 : 35
FIRST_DEVICE_VECTOR : u32 : 48
DEVICE_VECTOR_COUNT : u32 : 192
SPURIOUS_VECTOR : u8 : 255

IA32_APIC_BASE : u32 : 0x1b
APIC_BASE_X2APIC_ENABLE : u64 : 1 << 10
APIC_BASE_ENABLE : u64 : 1 << 11
IA32_TSC_DEADLINE : u32 : 0x6e0

X2APIC_EOI : u32 : 0x80b
X2APIC_SPURIOUS : u32 : 0x80f
// In-request registers, 8 of them, 32 vectors each
X2APIC_IRR_0 : u32 : 0x820
X2APIC_ICR : u32 : 0x830
X2APIC_LVT_TIMER : u32 : 0x832
X2APIC_TIMER_INITIAL_COUNT : u32 : 0x838
X2APIC_TIMER_CURRENT_COUNT : u32 : 0x839
X2APIC_TIMER_DIVIDE : u32 : 0x83e

SPURIOUS_APIC_ENABLE : u64 : 1 << 8
LVT_MASKED : u64 : 1 << 16
LVT_TIMER_ONE_SHOT : u64 : 0 << 17
LVT_TIMER_TSC_DEADLINE : u64 : 2 << 17
// Divide configuration 1011b: divide by 1
TIMER_DIVIDE_BY_1 : u64 : 0xb

// PIT channel 2, for measuring the TSC when nothing else gives its frequency
//SPEC: Intel 8254 datasheet; port 0x61 bits 0 (gate), 1 (speaker) and 5 (channel 2 output)
PIT_FREQUENCY : u64 : 1193182
PIT_CHANNEL_2 : u16 : 0x42
PIT_COMMAND : u16 : 0x43
PIT_GATE_PORT : u16 : 0x61
// Channel 2, low then high byte, mode 0 (interrupt on terminal count), binary
PIT_CHANNEL_2_MODE_0 : u8 : 0xb0
// How long calibration measures, in parts of a second: 10 ms
CALIBRATION_DIVISOR : u64 : 100

/*
 * Turn on x2APIC mode and software-enable the local APIC, with spurious interrupts on
 * SPURIOUS_VECTOR. Limine already enables x2APIC mode where the CPU has it.
 */
//TODO(claude): xAPIC through its memory-mapped registers when there's no x2APIC, once the kernel maps device memory (M2)
enable_local_apic :: fn() {
    base :: x86_64.rdmsr(IA32_APIC_BASE)
    x86_64.wrmsr(IA32_APIC_BASE, base | APIC_BASE_ENABLE | APIC_BASE_X2APIC_ENABLE)
    x86_64.wrmsr(X2APIC_SPURIOUS, SPURIOUS_APIC_ENABLE | cast[u64](SPURIOUS_VECTOR))
}

// Acknowledge the interrupt being handled. The local APIC knows which one it is.
end_of_interrupt :: fn(id: arch_interface.InterruptId) {
    x86_64.wrmsr(X2APIC_EOI, 0)
}

device_interrupt_range :: fn() -> (first: arch_interface.InterruptId, count: u32) {
    return cast[arch_interface.InterruptId](FIRST_DEVICE_VECTOR), DEVICE_VECTOR_COUNT
}

send_ipi :: fn(cpu_hardware_id: u64, kind: arch_interface.IpiKind) {
    vector :: match kind {
        case .Reschedule => RESCHEDULE_VECTOR
        case .TlbFlush => TLB_FLUSH_VECTOR
        case .Stop => STOP_VECTOR
    }
    // Fixed delivery, physical destination, edge triggered
    x86_64.wrmsr(X2APIC_ICR, (cpu_hardware_id << 32) | cast[u64](vector))
}

// Whether an interrupt is waiting in the local APIC's in-request registers.
interrupt_pending :: fn() -> bool {
    for i in 0..<8 {
        if x86_64.rdmsr(X2APIC_IRR_0 + cast[u32](i)) != 0 {
            return true
        }
    }
    return false
}

/*
 * The message a device sends to raise id on a CPU: the local APIC's address with the destination
 * in bits 12-19, and the vector, fixed delivery, edge triggered.
 */
//SPEC: Intel SDM Vol. 3A §11.11 (message signalled interrupts)
//TODO(claude): destinations above 255 need interrupt remapping through the IOMMU (M7)
msi_message :: fn(cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    return arch_interface.MsiMessage.{
        address = 0xfee00000 | ((cpu_hardware_id & 0xff) << 12),
        data = cast[u32](id) & 0xff,
    }
}

// Timer

/*
 * The counter is the TSC. Its frequency is hint if the bootloader measured it, otherwise from
 * CPUID leaf 0x15, otherwise measured against the PIT. Deadlines use TSC-deadline mode where the
 * CPU has it, otherwise the local APIC timer counting down, measured against the TSC.
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

counter :: fn() -> u64 {
    return x86_64.rdtsc()
}

// Raise a timer interrupt once counter() reaches value.
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

cancel_deadline :: fn() {
    if current_cpu().timer.tsc_deadline {
        x86_64.wrmsr(IA32_TSC_DEADLINE, 0)
        return void
    }
    x86_64.wrmsr(X2APIC_TIMER_INITIAL_COUNT, 0)
}

// value × numerator / denominator, without overflowing in between for frequencies below 2^32.
scale :: fn(value, numerator, denominator: u64) -> u64 {
    return value / denominator * numerator + value % denominator * numerator / denominator
}

/*
 * The TSC's frequency from CPUID leaf 0x15: the crystal clock's frequency times the ratio of the
 * TSC to it. Null when the CPU doesn't report the crystal's frequency.
 */
//SPEC: Intel SDM Vol. 2A, CPUID leaf 15H
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

// The TSC's frequency, by counting its ticks while the PIT counts down 10 ms.
measure_tsc_frequency :: fn() -> u64 {
    start, end :: time_pit_interval()
    return (end - start) * CALIBRATION_DIVISOR
}

/*
 * TSC values when PIT channel 2 starts counting down 10 ms, and when it reaches zero.
 * The gate is turned off and on again to start the count, with the speaker kept off.
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

// The local APIC timer's frequency, by letting it count down for 10 ms of TSC time.
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
