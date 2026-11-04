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

/** The platform capability: an object with nothing in it but its kind. */
Platform :: struct #align(16) {
    /** The object's header; its kind is all the capability is. */
    header : ObjectHeader,
}

/**
 * An IRQ, a kernel object: one interrupt, a wired controller's line or a device's message-signaled event, routed to
 * a CPU and delivered to at most one port binding as a count of interrupts.
 */
Irq :: struct #align(16) {
    /** The object's header; first, as for every kernel object. */
    header : ObjectHeader,
    /** Held (rank Irq, before a port's) while its binding is read or changed. */
    lock : concurrency.SpinLock,
    /** The index of the wired controller whose line it is; unused for a message-signaled IRQ. */
    controller : u32,
    /** The controller's line, or for a message-signaled IRQ, its event among its device's, from 0. */
    line : u32,
    /** The index of the CPU it's routed to. */
    cpu : u32,
    /** Its route's index among that CPU's device_routes; MAX_DEVICE_INTERRUPTS until it's routed. */
    slot : u32,
    /** How its line triggers: a level-triggered line stays masked from each interrupt until it's acknowledged. */
    trigger : arch_interface.Trigger,
    /** Its port binding, as its address, or 0 for none. */
    binding : u64,
    /** The binding's generation when it was bound, which changes once the port drops it, so it isn't this one then. */
    binding_generation : u32,
    /** Whether it's message-signaled (devices.hsc), so its line is its event and it has no controller. */
    msi : bool,
    /** A message-signaled IRQ's Device, as its address. */
    device : u64,
    /** Its next neighbor among its device's IRQs, under the device's lock, 0 for none. */
    device_next : u64,
    /** Its previous neighbor among its device's IRQs, under the device's lock, 0 for none. */
    device_previous : u64,
    /** Whether it's on its device's list of IRQs. */
    in_device : bool,
    /** Its device's MSI source, as the interrupt controller knows the device (unused on x86-64). */
    msi_source : u32,
    /** The message the device writes to raise it, as the controller or the IOMMU's remapping gave it. */
    message : arch_interface.MsiMessage,
    /** The number plus one of the IOMMU that remaps it, 0 for none (translation.hsc). */
    remap_iommu : u32,
    /** Its entry's index in that IOMMU's remapping table; meaningless when remap_iommu is 0. */
    remap_index : u32,
}

/**
 * Make an IRQ for a wired controller's line: routed to the next CPU in turn that the owner's CPU budget has, then
 * unmasked.
 *
 * Once an IOMMU remaps interrupts, wired lines are blocked as a forged message would be, so none can be made. With
 * test_device on, making the IRQ for the test device's line starts its interrupts.
 *
 * @param kernel The kernel: the object comes from its Irq pool, next_irq_cpu advances, a CPU's route is made under
 *     interrupts_lock, and the controller is programmed under its lock.
 * @param owner The Process to own it, as its address, or 0 for the kernel, which routes it to any online CPU.
 * @param budget The MemoryBudget the object is charged to, as its address, or 0 for the kernel's own.
 * @param controller The wired controller's index, from register_controller.
 * @param line The controller's line, which no other IRQ may have.
 * @param trigger How the line triggers, as the firmware tables say.
 * @param polarity Whether the line is active high or low, as the firmware tables say.
 * @return The IRQ, owned by owner, routed and unmasked, with no binding yet; the caller makes a handle to it.
 * @error OutOfMemory No memory could be had for the object.
 * @error BudgetExceeded budget hadn't room for the object, or is closed.
 * @error NoController An IOMMU remaps interrupts, so wired lines are blocked.
 * @error NoSuchController No controller is registered at that index.
 * @error NoSuchLine The controller has no such line.
 * @error LineInUse Another IRQ has the line.
 * @error NoFreeInterrupt The CPU picked has no device interrupt ID free, or isn't there.
 * @error ObjectGone owner is being destroyed; the IRQ is destroyed again, its line masked and its route forgotten.
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
    // Its interrupts would be blocked as a forged message would (translation.hsc)
    if intrinsics.atomic_load_u32_acquire(&kernel.wired_lines_blocked) != 0 {
        release_object(kernel, object)
        return .Error(.NoController)
    }
    cpus :: if owner != 0 { cpus_of(kernel, cast[ptr[Process]](owner)) } else { ~cast[u64](0) }
    cpu :: next_cpu_of(kernel, &kernel.next_irq_cpu, cpus)
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

/**
 * Destroy the platform capability, as destroy_object does each kind: it holds nothing, so this does nothing.
 *
 * @param kernel Unused: the capability holds nothing of the kernel's.
 * @param platform The capability being destroyed.
 */
destroy_platform :: fn(kernel: ptr[mut Kernel], platform: ptr[mut Platform]) {
}

/**
 * Release a destroyed platform capability, as release_object does each kind: it holds nothing besides itself, so
 * this does nothing.
 *
 * @param kernel Unused: the capability holds nothing of the kernel's.
 * @param platform The destroyed capability, whose memory release_object frees after this.
 */
release_platform :: fn(kernel: ptr[mut Kernel], platform: ptr[mut Platform]) {
}

/**
 * Release a destroyed IRQ, as release_object does each kind: destroy_irq let go of everything it held, so this does
 * nothing.
 *
 * @param kernel Unused: the IRQ holds nothing of the kernel's by now.
 * @param irq The destroyed IRQ, whose memory release_object frees after this.
 */
release_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
}

/**
 * Destroy an IRQ, as destroy_object does each kind: its line masked, or its message no longer delivered; its route
 * forgotten; its binding dropped from its port.
 *
 * For the test device's line, with test_device on, the device's interrupts stop too. Takes the IRQ's lock, then the
 * port's, one after the other.
 *
 * @param kernel The kernel: the line is masked under its controller's lock, the route forgotten under
 *     interrupts_lock; called from destroy_object, on any CPU, with interrupts off.
 * @param irq The IRQ being destroyed, already dying.
 */
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
    lock_at(&irq.lock, .Irq)
    binding :: irq.binding
    generation :: irq.binding_generation
    irq.binding = 0
    unlock_at(&irq.lock, .Irq)
    if binding != 0 {
        drop_binding(kernel, binding, generation)
    }
}

/**
 * Acknowledge an IRQ's interrupt, once its driver has dealt with it: a level-triggered line is unmasked, so it can
 * interrupt again. An edge-triggered line, never masked, is left alone, as is a message-signaled IRQ.
 *
 * @param kernel The kernel, whose controller's lock is taken to unmask the line.
 * @param irq The IRQ, from a handle with the right to acknowledge it.
 */
irq_ack :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    if irq.trigger == .Level {
        unmask_line(kernel, irq.controller, irq.line)
    }
}

/**
 * Deliver an interrupt to an IRQ's binding: its count goes up, and its packet is queued if it wasn't, which wakes a
 * waiter.
 *
 * Called from handle_device_interrupt, with interrupts disabled. Nothing happens without a binding, when the port
 * dropped it, or when it's a once binding not armed again; the interrupt is lost then. Takes the IRQ's lock, then its
 * port's.
 *
 * @param kernel The kernel, passed to queue_binding, which may wake a thread waiting on the port. Runs in
 *     interrupt context, on the CPU the IRQ is routed to.
 * @param irq The IRQ the interrupt is for.
 */
deliver_irq :: fn(kernel: ptr[mut Kernel], irq: ptr[mut Irq]) {
    lock_at(&irq.lock, .Irq)
    defer unlock_at(&irq.lock, .Irq)
    if irq.binding == 0 {
        return void
    }
    binding :: cast[ptr[mut Binding]](irq.binding)
    // A binding the port dropped is no longer this one
    port :: lock_bound_port(binding, irq.binding_generation) or_return void
    defer unlock_at(&port.lock, .Port)
    if !binding.armed {
        return void
    }
    binding.data += 1
    if binding.once {
        binding.armed = false
    }
    queue_binding(kernel, port, binding)
}

/**
 * Bind an IRQ to a port under a key, so its interrupts come as an Irq packet, counting them.
 *
 * An IRQ has one binding. Binding it to the same port and key again arms it again, as a once binding is after each
 * packet (BindMode.Once), and changes its mode. Takes the IRQ's lock, then the port's.
 *
 * @param kernel The kernel, whose pool the binding comes from.
 * @param port The port, which is charged for the binding.
 * @param irq The IRQ, not dying; its lock is taken, so the caller holds none of rank Irq or above.
 * @param key The key its packets carry, which no other binding on the port may have.
 * @param mode Once, for one packet and then none until it's bound again, or each interrupt's.
 * @return Null once bound and armed; ObjectGone if the IRQ or the port is being destroyed; KeyInUse if the key is
 *     another binding's; TooManyBindings if the IRQ is bound under another key or port; BudgetExceeded or
 *     OutOfMemory if the binding couldn't be made.
 */
irq_bind :: fn(kernel: ptr[mut Kernel], port: ptr[mut Port], irq: ptr[mut Irq], key: u64, mode: slop_os.BindMode) -> slop_os.PortError? {
    lock_at(&irq.lock, .Irq)
    defer unlock_at(&irq.lock, .Irq)
    if is_dying(cast[u64](irq)) {
        return slop_os.PortError.ObjectGone
    }
    lock_at(&port.lock, .Port)
    defer unlock_at(&port.lock, .Port)
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

/**
 * Drop a binding from its port, freeing it, if it's still the one with a generation; otherwise the port dropped it
 * already, and nothing is done. Takes the port's lock.
 *
 * @param kernel The kernel, whose pool the binding goes back to.
 * @param address The binding, as its address, kept by its object.
 * @param generation The binding's generation when its object took it.
 */
drop_binding :: fn(kernel: ptr[mut Kernel], address: u64, generation: u32) {
    binding :: cast[ptr[mut Binding]](address)
    port :: lock_bound_port(binding, generation) or_return void
    _ = maps.map_remove(&port.bindings, binding.key)
    free_binding(kernel, port, binding)
    unlock_at(&port.lock, .Port)
}

/**
 * Find the kernel's controller kind a system call names.
 *
 * @param kind A slop_os.ControllerKind, as a call's raw value.
 * @return The kind, or null for a value that's no kind the kernel knows (whether the architecture has it is checked
 *     when it's registered).
 */
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

/**
 * Tell whether physical memory touches RAM the kernel owns, so the platform service can't be given it as device
 * memory or registers.
 *
 * @param kernel The kernel, whose ram ranges are checked.
 * @param physical The physical address of the memory's start.
 * @param size The memory's size in bytes.
 * @return True if any byte of it is in one of the kernel's RAM ranges.
 */
overlaps_kernel_ram :: fn(kernel: ptr[Kernel], physical: u64, size: u64) -> bool {
    for range in kernel.ram {
        if overlaps(physical, size, cast[u64](range.base), range.size) {
            return true
        }
    }
    return false
}
