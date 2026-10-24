package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import maps from "std"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * IRQs and the platform capability (roadmap M5, decisions/0039, 0055).
 *
 * The platform capability is the authority over the machine's hardware: registering interrupt
 * controllers, making IRQs for their lines and device memory. The kernel makes one at boot for the
 * root task, which gives it to the platform service; until they exist, tests get it.
 *
 * An IRQ is one controller line, routed to a CPU the kernel picks and unmasked when it's made. Each
 * interrupt bumps the count in its port binding's packet, queuing it if it isn't (PortBind, one binding
 * per IRQ). A level-triggered line is masked when its interrupt arrives, until the driver acknowledges it
 * (IrqAck). Destroying the IRQ masks the line and forgets its route.
 *
 * Lock order: an IRQ's lock, then a port's.
 */

// The platform capability: an object with nothing in it but its kind.
Platform :: struct #align(16) {
    header : ObjectHeader,
}

Irq :: struct #align(16) {
    header : ObjectHeader,
    // Held for its binding.
    lock : concurrency.SpinLock,
    controller : u32,
    line : u32,
    // Where it's routed: the CPU's index, and the route's slot among its device interrupts.
    cpu : u32,
    slot : u32,
    trigger : arch_interface.Trigger,
    // Its port binding, and that binding's generation, which changes once the port drops it.
    binding : u64,
    binding_generation : u32,
    /*
     * A message-signaled IRQ's (devices.hsc), whose line is its event: its Device, and its neighbors among the
     * device's IRQs, under the device's lock, and whether it's there; its device's MSI source, and its message.
     */
    msi : bool,
    device : u64,
    device_next : u64,
    device_previous : u64,
    in_device : bool,
    msi_source : u32,
    message : arch_interface.MsiMessage,
}

/*
 * An IRQ for controller's line, owned by owner (a Process's address), charged to budget: routed to the
 * next CPU in turn, then unmasked.
 */
create_irq :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, controller: u32, line: u32, trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity) -> Result[ptr[mut Irq], slop_os.DeviceError] {
    object := cast[u64](0)
    match new_object(kernel, .Irq, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    irq :: cast[ptr[mut Irq]](object)
    irq.controller = controller
    irq.line = line
    irq.trigger = trigger
    irq.slot = cast[u32](MAX_DEVICE_INTERRUPTS)
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    cpu :: intrinsics.interlocked_increment_u32(&kernel.next_irq_cpu) % online
    first, count :: arch.device_interrupt_range()
    match route_line(kernel, controller, line, cpu, trigger, polarity, object) {
        case Ok(id) => {
            irq.cpu = cpu
            irq.slot = cast[u32](id) - cast[u32](first)
        }
        case Error(error) => {
            release_object(kernel, object)
            return .Error(match error {
                case .NoSuchController => slop_os.DeviceError.NoSuchController
                case .NoSuchLine => slop_os.DeviceError.NoSuchLine
                case .LineInUse => slop_os.DeviceError.LineInUse
                case _ => slop_os.DeviceError.NoFreeInterrupt
            })
        }
    }
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    unmask_line(kernel, controller, line)
    // The test device runs while its line has an IRQ
    if kernel.options.test_device && line == arch.test_device().line {
        arch.test_device_interrupts(true)
    }
    return .Ok(irq)
}

// The platform capability holds nothing.
destroy_platform :: fn(kernel: ptr[mut Kernel], platform: ptr[mut Platform]) {
}

release_platform :: fn(kernel: ptr[mut Kernel], platform: ptr[mut Platform]) {
}

release_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
}

// Destroying an IRQ: its line masked, or its event no longer delivered; its route forgotten, its binding dropped.
destroy_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    if irq.msi {
        destroy_msi_irq(kernel, irq)
    }
    else if cast[usize](irq.slot) < MAX_DEVICE_INTERRUPTS {
        if kernel.options.test_device && irq.line == arch.test_device().line {
            arch.test_device_interrupts(false)
        }
        mask_line(kernel, irq.controller, irq.line)
        unroute(kernel, irq.cpu, irq.slot)
    }
    concurrency.lock(&irq.lock)
    binding :: irq.binding
    generation :: irq.binding_generation
    irq.binding = 0
    concurrency.unlock(&irq.lock)
    if binding != 0 {
        drop_binding(kernel, binding, generation)
    }
}

// A level-triggered line, unmasked once its driver has dealt with the interrupt.
irq_ack :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    if irq.trigger == .Level {
        unmask_line(kernel, irq.controller, irq.line)
    }
}

// An interrupt for irq: its binding's count goes up, and its packet is queued if it wasn't.
deliver_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    concurrency.lock(&irq.lock)
    defer concurrency.unlock(&irq.lock)
    if irq.binding == 0 {
        return void
    }
    binding :: cast[ptr[mut Binding]](irq.binding)
    port :: cast[ptr[mut Port]](intrinsics.atomic_load_u64(&binding.port))
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    // A binding the port dropped is no longer this one
    if binding.generation != irq.binding_generation || binding.port != cast[u64](port) || is_dying(cast[u64](port)) || !binding.armed {
        return void
    }
    binding.data += 1
    if binding.once {
        binding.armed = false
    }
    queue_binding(kernel, port, binding)
}

/*
 * Bind irq to port under key: an Irq packet for each interrupt. One binding per IRQ; binding it to the
 * same key again arms it again (BindMode.Once).
 */
irq_bind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], irq: ptr[mut Irq], key: u64, mode: slop_os.BindMode) -> slop_os.PortError? {
    concurrency.lock(&irq.lock)
    defer concurrency.unlock(&irq.lock)
    if is_dying(cast[u64](irq)) {
        return slop_os.PortError.ObjectGone
    }
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if is_dying(cast[u64](port)) {
        return slop_os.PortError.ObjectGone
    }
    binding := cast[ptr[mut Binding]](0)
    match maps.map_get(&port.bindings, key) {
        case Some(address) => {
            existing :: cast[ptr[mut Binding]](address)
            if existing.kind != .Irq || existing.object != cast[u64](irq) || existing.object_generation != irq.header.generation {
                return slop_os.PortError.KeyInUse
            }
            binding = existing
        }
        case None => {
            // Bound elsewhere already, by a binding its port hasn't dropped
            if irq.binding != 0 && cast[ptr[Binding]](irq.binding).generation == irq.binding_generation {
                return slop_os.PortError.TooManyBindings
            }
            binding = new_binding(kernel, port, key, .Irq) or_return binding_failure(port)
            binding.object = cast[u64](irq)
            binding.object_generation = irq.header.generation
            irq.binding = cast[u64](binding)
            irq.binding_generation = binding.generation
        }
    }
    binding.once = mode == .Once
    binding.armed = true
    return null
}

// Drop a binding from its port, if it's still the one with generation.
drop_binding :: fn(kernel: ptr[mut Kernel], address: u64, generation: u32) {
    binding :: cast[ptr[mut Binding]](address)
    port :: cast[ptr[mut Port]](intrinsics.atomic_load_u64(&binding.port))
    concurrency.lock(&port.lock)
    if binding.generation == generation && binding.port == cast[u64](port) && !is_dying(cast[u64](port)) {
        _ = maps.map_remove(&port.bindings, binding.key)
        free_binding(kernel, port, binding)
    }
    concurrency.unlock(&port.lock)
}

// The controller kind a call names, if the kernel has one by that kind.
controller_kind :: fn(kind: u32) -> arch_interface.ControllerKind? {
    if kind == cast[u32](slop_os.ControllerKind.IoApic) {
        return arch_interface.ControllerKind.IoApic
    }
    if kind == cast[u32](slop_os.ControllerKind.GicDistributor) {
        return arch_interface.ControllerKind.GicDistributor
    }
    if kind == cast[u32](slop_os.ControllerKind.Plic) {
        return arch_interface.ControllerKind.Plic
    }
    return null
}

// Whether size bytes at physical touch RAM the kernel owns.
overlaps_kernel_ram :: fn(kernel: ptr[Kernel], physical: u64, size: u64) -> bool {
    for range in kernel.ram {
        if overlaps(physical, size, cast[u64](range.base), range.size) {
            return true
        }
    }
    return false
}
