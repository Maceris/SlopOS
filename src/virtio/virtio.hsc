/*
 * The virtio-pci transport (decisions/0070, 0074): a modern (virtio 1.x) device behind PCIe, its registers found
 * through its vendor capabilities in BARs its driver has mapped, its features negotiated (VERSION_1 always), its
 * interrupts through MSI-X, one vector per queue, and split virtqueues in DMA memory, each descriptor reused only once
 * the device has given back the chain it was in.
 *
 * Every field the device shares is little-endian, so the rings are laid out with u16le, u32le and u64le, and the
 * registers are reached with volatile loads and stores, swapped through those types, so it's right on any target.
 */
//SPEC: Virtual I/O Device (VIRTIO) Version 1.2, §2.7 (split virtqueues), §4.1 (virtio over PCI), §3.1 (initialization)
//SPEC: PCI Express Base Specification 5.0, §7.7.2 (MSI-X)
package virtio

import intrinsics from "base"
import pci from "../pci"

// The vendor capability, and the configuration structures it points at
CAPABILITY_VENDOR : u8 : 0x09
CAPABILITY_MSIX : u8 : 0x11
CONFIG_COMMON : u8 : 1
CONFIG_NOTIFY : u8 : 2
CONFIG_ISR : u8 : 3
CONFIG_DEVICE : u8 : 4

// The common configuration's registers
DEVICE_FEATURE_SELECT : u64 : 0x00
DEVICE_FEATURE : u64 : 0x04
DRIVER_FEATURE_SELECT : u64 : 0x08
DRIVER_FEATURE : u64 : 0x0c
CONFIG_MSIX_VECTOR : u64 : 0x10
NUM_QUEUES : u64 : 0x12
DEVICE_STATUS : u64 : 0x14
QUEUE_SELECT : u64 : 0x16
QUEUE_SIZE : u64 : 0x18
QUEUE_MSIX_VECTOR : u64 : 0x1a
QUEUE_ENABLE : u64 : 0x1c
QUEUE_NOTIFY_OFF : u64 : 0x1e
QUEUE_DESC : u64 : 0x20
QUEUE_DRIVER : u64 : 0x28
QUEUE_DEVICE : u64 : 0x30

STATUS_ACKNOWLEDGE : u8 : 1
STATUS_DRIVER : u8 : 2
STATUS_DRIVER_OK : u8 : 4
STATUS_FEATURES_OK : u8 : 8
STATUS_FAILED : u8 : 128
FEATURE_VERSION_1 : u64 : 1 << 32
NO_VECTOR : u16 : 0xffff

// A descriptor's flags: another follows, and the device writes the buffer
DESCRIPTOR_NEXT : u16 : 1
DESCRIPTOR_WRITE : u16 : 2

// A queue of at most this many descriptors, so all of it fits one page: descriptors, the driver's ring, the device's
MAX_QUEUE_SIZE :: 64
QUEUE_PAGE : u64 : 4096
DESCRIPTORS_AT : u64 : 0
DRIVER_RING_AT : u64 : 1024
DEVICE_RING_AT : u64 : 2048
// What offer gives when there aren't enough free descriptors
NO_DESCRIPTOR : u16 : 0xffff
MAX_CHAIN :: 4

Descriptor :: struct #packed {
    address : u64le,
    length : u32le,
    flags : u16le,
    next : u16le,
}

UsedElement :: struct #packed {
    id : u32le,
    length : u32le,
}

// A device's registers, through its BARs as its driver mapped them.
Transport :: struct {
    config : u64,
    common : u64,
    notify : u64,
    notify_multiplier : u32,
    isr : u64,
    device : u64,
    msix_table : u64,
    msix_entries : u32,
}

// A split virtqueue: its page, where it is to the device and to the driver, and how far each ring has got.
Queue :: struct {
    index : u16,
    size : u16,
    page : u64,
    notify : u64,
    next_available : u16,
    last_used : u16,
    // The descriptors not in a chain the device has, a bit each
    free : u64,
}

// One buffer of a chain: where it is to the device, how long, and whether the device writes it (or reads it).
Part :: struct {
    address : u64,
    length : u32,
    device_writes : bool,
}

/*
 * The transport of a device whose configuration space is mapped at config, and each BAR at bars' address for it (0 for
 * one that isn't mapped), from its capabilities; null if it lacks one it needs.
 */
open :: fn(config: u64, bars: u64[6]) -> Transport? {
    transport := Transport.{config = config}
    found := cast[u32](0)
    with {
        at := cast[u64](0)
    }
    loop {
        at = pci.find_capability(config, CAPABILITY_VENDOR, at) or_break
        kind :: pci.read_u8(config, at + 3)
        bar :: cast[usize](pci.read_u8(config, at + 4))
        offset :: cast[u64](pci.read_u32(config, at + 8))
        base :: if bar < bars.count { bars[bar] } else { cast[u64](0) }
        if base == 0 {
            continue
        }
        if kind == CONFIG_COMMON && transport.common == 0 {
            transport.common = base + offset
            found |= 1
        }
        else if kind == CONFIG_NOTIFY && transport.notify == 0 {
            transport.notify = base + offset
            transport.notify_multiplier = pci.read_u32(config, at + 16)
            found |= 2
        }
        else if kind == CONFIG_ISR && transport.isr == 0 {
            transport.isr = base + offset
        }
        else if kind == CONFIG_DEVICE && transport.device == 0 {
            transport.device = base + offset
        }
    }
    while true
    msix :: pci.find_capability(config, CAPABILITY_MSIX) or_return null
    table :: pci.read_u32(config, msix + 4)
    table_bar :: cast[usize](table & 7)
    if table_bar >= bars.count || bars[table_bar] == 0 || found != 3 {
        return null
    }
    transport.msix_table = bars[table_bar] + cast[u64](table & ~cast[u32](7))
    transport.msix_entries = cast[u32](pci.read_u16(config, msix + 2) & 0x7ff) + 1
    return transport
}

/*
 * The device reset and told a driver has it, its features read and wanted's taken (always with VERSION_1), and those
 * accepted: the features, or null if the device refused them or isn't modern.
 */
start :: fn(transport: ptr[Transport], wanted: u64) -> u64? {
    common :: transport.common
    write_u8(common, DEVICE_STATUS, 0)
    loop {
        intrinsics.spin_hint()
    }
    while read_u8(common, DEVICE_STATUS) != 0
    write_u8(common, DEVICE_STATUS, STATUS_ACKNOWLEDGE)
    write_u8(common, DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER)
    write_u32(common, DEVICE_FEATURE_SELECT, 0)
    offered := cast[u64](read_u32(common, DEVICE_FEATURE))
    write_u32(common, DEVICE_FEATURE_SELECT, 1)
    offered |= cast[u64](read_u32(common, DEVICE_FEATURE)) << 32
    if offered & FEATURE_VERSION_1 == 0 {
        write_u8(common, DEVICE_STATUS, STATUS_FAILED)
        return null
    }
    taken :: offered & (wanted | FEATURE_VERSION_1)
    write_u32(common, DRIVER_FEATURE_SELECT, 0)
    write_u32(common, DRIVER_FEATURE, cast[u32](taken))
    write_u32(common, DRIVER_FEATURE_SELECT, 1)
    write_u32(common, DRIVER_FEATURE, cast[u32](taken >> 32))
    write_u8(common, DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK)
    if read_u8(common, DEVICE_STATUS) & STATUS_FEATURES_OK == 0 {
        write_u8(common, DEVICE_STATUS, STATUS_FAILED)
        return null
    }
    return taken
}

// MSI-X on, with entry's message, unmasked; the device's configuration changes report to no vector.
set_vector :: fn(transport: ptr[Transport], entry: u32, address: u64, data: u32) -> bool {
    if entry >= transport.msix_entries {
        return false
    }
    at :: transport.msix_table + cast[u64](entry) * 16
    write_u32(at, 0, cast[u32](address))
    write_u32(at, 4, cast[u32](address >> 32))
    write_u32(at, 8, data)
    write_u32(at, 12, 0)
    msix :: pci.find_capability(transport.config, CAPABILITY_MSIX) or_return false
    control :: pci.read_u16(transport.config, msix + 2)
    // Enabled (bit 15), and the function not masked (bit 14)
    pci.write_u16(transport.config, msix + 2, (control | 0x8000) & ~cast[u16](0x4000))
    write_u16(transport.common, CONFIG_MSIX_VECTOR, NO_VECTOR)
    return true
}

/*
 * Queue index, set up in page, a zeroed page of DMA memory at page through the driver's mapping and device_page to the
 * device, its interrupts to MSI-X entry vector: the queue, or null if the device has no such queue or won't take the
 * vector.
 */
setup_queue :: fn(transport: ptr[Transport], index: u16, page: u64, device_page: u64, vector: u16) -> Queue? {
    common :: transport.common
    if index >= read_u16(common, NUM_QUEUES) {
        return null
    }
    write_u16(common, QUEUE_SELECT, index)
    largest :: read_u16(common, QUEUE_SIZE)
    if largest == 0 {
        return null
    }
    size :: if largest < MAX_QUEUE_SIZE { largest } else { cast[u16](MAX_QUEUE_SIZE) }
    write_u16(common, QUEUE_SIZE, size)
    write_u64(common, QUEUE_DESC, device_page + DESCRIPTORS_AT)
    write_u64(common, QUEUE_DRIVER, device_page + DRIVER_RING_AT)
    write_u64(common, QUEUE_DEVICE, device_page + DEVICE_RING_AT)
    write_u16(common, QUEUE_MSIX_VECTOR, vector)
    if read_u16(common, QUEUE_MSIX_VECTOR) != vector {
        return null
    }
    notify_off :: cast[u64](read_u16(common, QUEUE_NOTIFY_OFF))
    write_u16(common, QUEUE_ENABLE, 1)
    free :: if size >= 64 { cast[u64](0xffffffffffffffff) } else { (cast[u64](1) << cast[u64](size)) - 1 }
    return Queue.{index = index, size = size, page = page, notify = transport.notify + notify_off * cast[u64](transport.notify_multiplier),
        free = free}
}

// The device told the driver is ready.
ready :: fn(transport: ptr[Transport]) {
    write_u8(transport.common, DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK)
}

// One buffer offered to the device, a chain of one descriptor (offer_chain).
offer :: fn(queue: ptr[mut Queue], device_address: u64, length: u32, device_writes: bool) -> u16 {
    return offer_chain(queue, Part.[Part.{address = device_address, length = length, device_writes = device_writes}])
}

/*
 * Buffers offered to the device as one chain, in order, each on a free descriptor; then the device told. The first
 * descriptor's index, which the device's used ring gives back; or NO_DESCRIPTOR if not enough are free.
 */
offer_chain :: fn(queue: ptr[mut Queue], parts: Part[]) -> u16 {
    ids : u16[MAX_CHAIN]
    taken : usize = 0
    for &id in ids {
        if taken >= parts.count {
            break
        }
        found :: first_free(queue) or_return NO_DESCRIPTOR
        id^ = found
        queue.free &= ~(cast[u64](1) << cast[u64](found))
        taken += 1
    }
    if taken < parts.count {
        for id, i in ids {
            if i < taken {
                queue.free |= cast[u64](1) << cast[u64](id)
            }
        }
        return NO_DESCRIPTOR
    }
    for part, i in parts {
        if i >= ids.count {
            break
        }
        descriptor :: cast[ptr[mut Descriptor]](queue.page + DESCRIPTORS_AT + cast[u64](ids[i]) * 16)
        descriptor.address = cast[u64le](part.address)
        descriptor.length = cast[u32le](part.length)
        next :: i + 1
        flags := if part.device_writes { DESCRIPTOR_WRITE } else { cast[u16](0) }
        following := cast[u16](0)
        if next < parts.count && next < ids.count {
            flags |= DESCRIPTOR_NEXT
            following = ids[next]
        }
        descriptor.flags = cast[u16le](flags)
        descriptor.next = cast[u16le](following)
    }
    id :: ids[0]
    // The driver's ring: flags, its index, then its entries
    entry :: cast[ptr[mut u16le]](queue.page + DRIVER_RING_AT + 4 + cast[u64](queue.next_available % queue.size) * 2)
    entry^ = cast[u16le](id)
    queue.next_available += 1
    // The descriptor and entry are where the device reads them before it sees the index
    intrinsics.fence_sequentially_consistent()
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](queue.page + DRIVER_RING_AT + 2), bit_cast[u16](cast[u16le](queue.next_available)))
    intrinsics.fence_sequentially_consistent()
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](queue.notify), bit_cast[u16](cast[u16le](queue.index)))
    return id
}

// A buffer the device has finished with: its descriptor's index, and how many bytes it wrote.
Used :: struct {
    id : u16,
    length : u32,
}

// The lowest free descriptor, or null.
first_free :: fn(queue: ptr[Queue]) -> u16? {
    for bit in 0..<cast[u64](queue.size) {
        if queue.free & (cast[u64](1) << bit) != 0 {
            return cast[u16](bit)
        }
    }
    return null
}

// The next chain the device has finished with, if there's one, its descriptors free again.
take_used :: fn(queue: ptr[mut Queue]) -> Used? {
    used_index : u16 = bit_cast[u16le](intrinsics.volatile_load_u16(cast[ptr[u16]](queue.page + DEVICE_RING_AT + 2)))
    if used_index == queue.last_used {
        return null
    }
    // The element is read after the index that says it's there
    intrinsics.fence_sequentially_consistent()
    element :: cast[ptr[UsedElement]](queue.page + DEVICE_RING_AT + 4 + cast[u64](queue.last_used % queue.size) * 8)
    queue.last_used += 1
    id : u32 = element.id
    length : u32 = element.length
    // Each descriptor of the chain, followed through its next, free again
    at := cast[u16](id)
    for step in 0..<MAX_CHAIN {
        if cast[u64](at) >= cast[u64](queue.size) {
            break
        }
        queue.free |= cast[u64](1) << cast[u64](at)
        descriptor :: cast[ptr[Descriptor]](queue.page + DESCRIPTORS_AT + cast[u64](at) * 16)
        flags : u16 = descriptor.flags
        if flags & DESCRIPTOR_NEXT == 0 {
            break
        }
        next : u16 = descriptor.next
        at = next
    }
    return Used.{id = cast[u16](id), length = length}
}

// The interrupt status, which reading clears.
interrupt_status :: fn(transport: ptr[Transport]) -> u8 {
    return if transport.isr == 0 { cast[u8](0) } else { intrinsics.volatile_load_u8(cast[ptr[u8]](transport.isr)) }
}

// The device's registers, little-endian whatever the target.
read_u8 :: fn(base: u64, offset: u64) -> u8 {
    return intrinsics.volatile_load_u8(cast[ptr[u8]](base + offset))
}

read_u16 :: fn(base: u64, offset: u64) -> u16 {
    return bit_cast[u16le](intrinsics.volatile_load_u16(cast[ptr[u16]](base + offset)))
}

read_u32 :: fn(base: u64, offset: u64) -> u32 {
    return bit_cast[u32le](intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset)))
}

write_u8 :: fn(base: u64, offset: u64, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](base + offset), value)
}

write_u16 :: fn(base: u64, offset: u64, value: u16) {
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](base + offset), bit_cast[u16](cast[u16le](value)))
}

write_u32 :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), bit_cast[u32](cast[u32le](value)))
}

// A 64-bit register as two 32-bit halves, low first, as the transport allows
write_u64 :: fn(base: u64, offset: u64, value: u64) {
    write_u32(base, offset, cast[u32](value))
    write_u32(base, offset + 4, cast[u32](value >> 32))
}
