package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Wired interrupts (roadmap M3, decisions/0039): interrupt controllers the platform service registers,
 * like I/O APICs, and their lines routed to device interrupt IDs on a CPU. The kernel maps a
 * controller's registers, routes and masks its lines, and takes the interrupts, masking a
 * level-triggered line until it's acknowledged.
 *
 * Each CPU has its own device interrupt IDs (arch.device_interrupt_range), each routed from at most
 * one line, recorded in its PerCpu. A route made for an IRQ (irqs.hsc) delivers its interrupts to the
 * IRQ's port binding; a line has at most one IRQ.
 */

MAX_CONTROLLERS :: 8
// Device interrupt IDs a CPU keeps routes for: at least as many as any architecture has.
MAX_DEVICE_INTERRUPTS :: 256
// Bytes of registers mapped for each controller: a GICv3 distributor's, which an I/O APIC's 4 KiB fit in.
CONTROLLER_REGISTERS_SIZE : u64 : 64 * 1024

InterruptError :: enum {
    // This architecture doesn't have that kind of controller.
    UnsupportedKind,
    // The registers aren't a controller of that kind.
    NotFound,
    TooManyControllers,
    // No room for the registers in the kernel window, or memory for its page tables.
    NoMapping,
    NoSuchController,
    NoSuchLine,
    NoSuchCpu,
    // Every device interrupt ID on that CPU is taken.
    NoFreeInterrupt,
    // An IRQ has the line already.
    LineInUse,
}

WiredController :: struct {
    // Held while its registers are used: each one is reached through a select register.
    lock : concurrency.SpinLock,
    controller : arch.InterruptController,
    kind : arch_interface.ControllerKind,
    // In the kernel window, and where they are.
    registers : u64,
    physical : u64,
    lines : u32,
}

// Where one of a CPU's device interrupt IDs comes from.
DeviceRoute :: struct {
    used : bool,
    controller : u32,
    line : u32,
    trigger : arch_interface.Trigger,
    // Interrupts that arrived.
    count : u64,
    // The Irq object it's for (irqs.hsc), 0 for one the kernel routed for itself.
    irq : u64,
}

/*
 * Map a controller's registers and set it up with every line masked: its index, for routing its
 * lines. kind and registers come from the firmware tables, through the platform service.
 */
register_controller :: fn(kernel: ptr[mut Kernel], kind: arch_interface.ControllerKind, registers: boot_info.PhysicalAddress)
    -> Result[u32, InterruptError] {
    // Registered already: the same one
    for index in 0..<cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.controller_count)) {
        if index < MAX_CONTROLLERS && kernel.controllers[index].physical == cast[u64](registers) && kernel.controllers[index].kind == kind {
            return .Ok(cast[u32](index))
        }
    }
    mapped := cast[u64](0)
    match map_device(kernel, registers, CONTROLLER_REGISTERS_SIZE) {
        case Ok(address) => mapped = address
        case Error(error) => return .Error(.NoMapping)
    }
    controller : arch.InterruptController
    lines := cast[u32](0)
    match arch.init_interrupt_controller(&controller, kind, cast[arch_interface.VirtualAddress](mapped)) {
        case Ok(count) => lines = count
        case Error(error) => {
            unmap_device(kernel, mapped, CONTROLLER_REGISTERS_SIZE)
            return .Error(if error == .UnsupportedKind { InterruptError.UnsupportedKind } else { InterruptError.NotFound })
        }
    }
    concurrency.lock(&kernel.interrupts_lock)
    index :: kernel.controller_count
    if cast[usize](index) >= MAX_CONTROLLERS {
        concurrency.unlock(&kernel.interrupts_lock)
        unmap_device(kernel, mapped, CONTROLLER_REGISTERS_SIZE)
        return .Error(.TooManyControllers)
    }
    kernel.controllers[index] = WiredController.{controller = controller, kind = kind, registers = mapped, physical = cast[u64](registers), lines = lines}
    intrinsics.atomic_store_u32_release(&kernel.controller_count, index + 1)
    concurrency.unlock(&kernel.interrupts_lock)
    return .Ok(index)
}

/*
 * Route a controller's line to a free device interrupt ID on the CPU with index cpu_index, still
 * masked: the ID.
 */
route_line :: fn(
    kernel: ptr[mut Kernel],
    controller_index: u32,
    line: u32,
    cpu_index: u32,
    trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity,
    irq: u64 = 0,
) -> Result[arch_interface.InterruptId, InterruptError] {
    wired :: controller_at(kernel, controller_index) or_return .Error(.NoSuchController)
    if line >= wired.lines {
        return .Error(.NoSuchLine)
    }
    cpus :: kernel.cpus
    per_cpus :: kernel.per_cpus
    if cast[usize](cpu_index) >= cpus.count || cast[usize](cpu_index) >= per_cpus.count || per_cpus[cpu_index] == 0 {
        return .Error(.NoSuchCpu)
    }
    cpu :: cast[ptr[mut PerCpu]](per_cpus[cpu_index])
    first, count :: arch.device_interrupt_range()
    runtime.assert(cast[usize](count) <= MAX_DEVICE_INTERRUPTS, "MAX_DEVICE_INTERRUPTS covers every architecture's device interrupt IDs")
    slot : usize = MAX_DEVICE_INTERRUPTS
    concurrency.lock(&kernel.interrupts_lock)
    // A line an IRQ has is routed for nothing else
    if irq != 0 && line_has_irq(kernel, controller_index, line) {
        concurrency.unlock(&kernel.interrupts_lock)
        return .Error(.LineInUse)
    }
    for i in 0..<cast[usize](count) {
        if !cpu.device_routes[i].used {
            slot = i
            break
        }
    }
    if slot < MAX_DEVICE_INTERRUPTS {
        cpu.device_routes[slot] = DeviceRoute.{used = true, controller = controller_index, line = line, trigger = trigger, count = 0, irq = irq}
    }
    concurrency.unlock(&kernel.interrupts_lock)
    if slot == MAX_DEVICE_INTERRUPTS {
        return .Error(.NoFreeInterrupt)
    }
    id :: cast[arch_interface.InterruptId](cast[u32](first) + cast[u32](slot))
    concurrency.lock(&wired.lock)
    arch.route_wired(&wired.controller, line, cpus[cpu_index].hardware_id, id, trigger, polarity)
    concurrency.unlock(&wired.lock)
    return .Ok(id)
}

mask_line :: fn(kernel: ptr[mut Kernel], controller_index: u32, line: u32) {
    wired :: controller_at(kernel, controller_index) or_return void
    runtime.assert(line < wired.lines, "mask_line takes one of the controller's lines")
    concurrency.lock(&wired.lock)
    arch.mask_wired(&wired.controller, line)
    concurrency.unlock(&wired.lock)
}

unmask_line :: fn(kernel: ptr[mut Kernel], controller_index: u32, line: u32) {
    wired :: controller_at(kernel, controller_index) or_return void
    runtime.assert(line < wired.lines, "unmask_line takes one of the controller's lines")
    concurrency.lock(&wired.lock)
    arch.unmask_wired(&wired.controller, line)
    concurrency.unlock(&wired.lock)
}

// Whether an IRQ has controller_index's line, on any CPU. Takes interrupts_lock as held.
line_has_irq :: fn(kernel: ptr[Kernel], controller_index: u32, line: u32) -> bool {
    for address in kernel.per_cpus {
        if address != 0 {
            routes :: &cast[ptr[PerCpu]](address).device_routes
            for route in routes^ {
                if route.used && route.irq != 0 && route.controller == controller_index && route.line == line {
                    return true
                }
            }
        }
    }
    return false
}

// Forget the route at slot on the CPU with index cpu_index, an IRQ's being destroyed.
unroute :: fn(kernel: ptr[mut Kernel], cpu_index: u32, slot: u32) {
    per_cpus :: kernel.per_cpus
    if cast[usize](cpu_index) >= per_cpus.count || per_cpus[cpu_index] == 0 || cast[usize](slot) >= MAX_DEVICE_INTERRUPTS {
        return void
    }
    cpu :: cast[ptr[mut PerCpu]](per_cpus[cpu_index])
    concurrency.lock(&kernel.interrupts_lock)
    cpu.device_routes[slot] = DeviceRoute.{}
    concurrency.unlock(&kernel.interrupts_lock)
}

controller_at :: fn(kernel: ptr[mut Kernel], index: u32) -> ptr[mut WiredController]? {
    if index >= intrinsics.atomic_load_u32_acquire(&kernel.controller_count) || cast[usize](index) >= MAX_CONTROLLERS {
        return null
    }
    return &kernel.controllers[index]
}

/*
 * A device interrupt on this CPU, from idle or user mode. A level-triggered line stays masked until
 * it's acknowledged; the interrupt is acknowledged to the local controller either way.
 */
handle_device_interrupt :: fn(id: arch_interface.InterruptId) {
    cpu :: per_cpu()
    kernel :: cpu.kernel
    first, count :: arch.device_interrupt_range()
    slot :: cast[usize](cast[u32](id) - cast[u32](first))
    if cast[u32](id) < cast[u32](first) || slot >= cast[usize](count) || slot >= MAX_DEVICE_INTERRUPTS || !cpu.device_routes[slot].used {
        runtime.log_warn("device interrupt % arrived, routed from nothing", cast[u32](id))
        arch.end_of_interrupt(id)
        return void
    }
    route :: &cpu.device_routes[slot]
    if route.trigger == .Level {
        mask_line(kernel, route.controller, route.line)
    }
    route.count += 1
    arch.end_of_interrupt(id)
    // An IRQ's: a packet for its driver
    if route.irq != 0 {
        deliver_irq(kernel, cast[ptr[mut Irq]](route.irq))
    }
    if kernel.options.test_ioapic {
        test_device_interrupt(kernel, route)
    }
}
