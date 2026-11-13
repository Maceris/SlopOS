/*
 * The virtio-pci transport (decisions/0070, 0074): a modern (virtio 1.x) device behind PCIe, its registers found
 * through its vendor capabilities in BARs its driver has mapped, its features negotiated (VERSION_1 always,
 * ACCESS_PLATFORM where offered), its interrupts through MSI-X, one vector per queue, and split virtqueues in DMA
 * memory, each descriptor reused only once the device has given back the chain it was in.
 *
 * Every field the device shares is little-endian, so the rings are laid out with u16le, u32le and u64le, and the
 * registers are reached with volatile loads and stores, swapped through those types, so it's right on any target.
 */
/**
 * The virtio-pci transport, for drivers of modern virtio devices: finding a device's registers, negotiating its
 * features, its MSI-X vectors, and split virtqueues.
 *
 * SPEC: Virtual I/O Device (VIRTIO) Version 1.2, §2.7 (split virtqueues), §4.1 (virtio over PCI), §3.1 (initialization)
 * SPEC: PCI Express Base Specification 5.0, §7.7.2 (MSI-X)
 */
package virtio

import intrinsics from "base"
import pci from "../pci"

// ---- The vendor capability, and the configuration structures it points at (virtio 1.2 §4.1.4)

/** The PCI capability ID of a vendor-specific capability, which virtio's configuration structures are. */
CAPABILITY_VENDOR : u8 : 0x09
/** The PCI capability ID of MSI-X (PCIe 5.0 §7.7.2). */
CAPABILITY_MSIX : u8 : 0x11
/** A virtio capability's cfg_type for the common configuration, the registers below. */
CONFIG_COMMON : u8 : 1
/** A virtio capability's cfg_type for the notification area, which queues are notified through. */
CONFIG_NOTIFY : u8 : 2
/** A virtio capability's cfg_type for the ISR status byte. */
CONFIG_ISR : u8 : 3
/** A virtio capability's cfg_type for the device-specific configuration. */
CONFIG_DEVICE : u8 : 4

// ---- The common configuration's registers, as byte offsets into it (virtio 1.2 §4.1.4.3)

/** Which 32 bits of the device's features DEVICE_FEATURE shows: 0 for bits 0 to 31, 1 for 32 to 63. A u32. */
DEVICE_FEATURE_SELECT : u64 : 0x00
/** The device's features, the 32 bits DEVICE_FEATURE_SELECT chose; read only. A u32. */
DEVICE_FEATURE : u64 : 0x04
/** Which 32 bits of the driver's features DRIVER_FEATURE takes: 0 for bits 0 to 31, 1 for 32 to 63. A u32. */
DRIVER_FEATURE_SELECT : u64 : 0x08
/** The features the driver accepts, the 32 bits DRIVER_FEATURE_SELECT chose. A u32. */
DRIVER_FEATURE : u64 : 0x0c
/** The MSI-X vector configuration changes are reported to, NO_VECTOR for none. A u16. */
CONFIG_MSIX_VECTOR : u64 : 0x10
/** How many queues the device has; read only. A u16. */
NUM_QUEUES : u64 : 0x12
/** The device status, the STATUS_ bits; writing 0 resets the device. A u8. */
DEVICE_STATUS : u64 : 0x14
/** Which queue the QUEUE_ registers are of. A u16. */
QUEUE_SELECT : u64 : 0x16
/**
 * The selected queue's size in descriptors: read, its largest, 0 for no queue; written, the size the driver uses. A
 * u16.
 */
QUEUE_SIZE : u64 : 0x18
/** The MSI-X vector the selected queue's interrupts go to, read back as NO_VECTOR if the device refused it. A u16. */
QUEUE_MSIX_VECTOR : u64 : 0x1a
/** Whether the selected queue is enabled; the driver writes 1 once it's set up. A u16. */
QUEUE_ENABLE : u64 : 0x1c
/**
 * The selected queue's notification offset, in notify_multiplier units into the notification area; read only. A u16.
 */
QUEUE_NOTIFY_OFF : u64 : 0x1e
/** The device address of the selected queue's descriptor table. A u64. */
QUEUE_DESC : u64 : 0x20
/** The device address of the selected queue's driver (available) ring. A u64. */
QUEUE_DRIVER : u64 : 0x28
/** The device address of the selected queue's device (used) ring. A u64. */
QUEUE_DEVICE : u64 : 0x30

// ---- Device status bits (virtio 1.2 §2.1) and features (§6)

/** Device status: the guest has noticed the device. */
STATUS_ACKNOWLEDGE : u8 : 1
/** Device status: the guest knows how to drive the device. */
STATUS_DRIVER : u8 : 2
/** Device status: the driver is set up and ready to drive the device. */
STATUS_DRIVER_OK : u8 : 4
/** Device status: the driver has acknowledged the features it understands, and feature negotiation is done. */
STATUS_FEATURES_OK : u8 : 8
/** Device status: something went wrong, and the driver has given up on the device. */
STATUS_FAILED : u8 : 128
/** The feature bit of a modern device, compliant with virtio 1.x, which this transport needs. */
FEATURE_VERSION_1 : u64 : 1 << 32
/**
 * The device's DMA goes through the platform's IOMMU, as its device addresses are I/O virtual addresses
 * (decisions/0079).
 */
FEATURE_ACCESS_PLATFORM : u64 : 1 << 33
/** An MSI-X vector register's value for no vector. */
NO_VECTOR : u16 : 0xffff

// ---- Split virtqueues (virtio 1.2 §2.7)

/** A descriptor's flag: another descriptor follows in its chain, at its next. */
DESCRIPTOR_NEXT : u16 : 1
/** A descriptor's flag: the device writes the buffer, rather than reading it. */
DESCRIPTOR_WRITE : u16 : 2

/**
 * The most descriptors a queue is set up with, 256: its descriptors, driver ring and device ring take two pages
 * (queue_bytes), and its free descriptors are FREE_WORDS u64s' bits.
 */
MAX_QUEUE_SIZE :: 256
/** How many u64s a queue's free descriptors take, a bit each: 4, for MAX_QUEUE_SIZE. */
FREE_WORDS :: 4
/** The bytes of a page, which one queue of up to 128 descriptors fits: 4096. */
QUEUE_PAGE : u64 : 4096
/** What offer and offer_chain give when there aren't enough free descriptors. */
NO_DESCRIPTOR : u16 : 0xffff
/** The most buffers one chain has: 4. */
MAX_CHAIN :: 4

/** A descriptor in a split virtqueue's table, as the device reads it (virtio 1.2 §2.7.5). */
Descriptor :: struct #packed {
    /** The buffer's device address. */
    address : u64le,
    /** The buffer's length in bytes. */
    length : u32le,
    /** DESCRIPTOR_NEXT and DESCRIPTOR_WRITE, or'd. */
    flags : u16le,
    /** With DESCRIPTOR_NEXT, the index of the next descriptor in the chain. */
    next : u16le,
}

#assert size_of(Descriptor) == 16

/** An element of a split virtqueue's device (used) ring, as the device writes it (virtio 1.2 §2.7.8). */
UsedElement :: struct #packed {
    /** The index of the first descriptor of the chain the device has finished with. */
    id : u32le,
    /** How many bytes the device wrote into the chain's buffers. */
    length : u32le,
}

#assert size_of(UsedElement) == 8

/** A device's registers, through its BARs as its driver mapped them. */
Transport :: struct {
    /** Where the device's PCIe configuration space is mapped in the driver's address space. */
    config : u64,
    /** Where the common configuration is mapped, the registers above. */
    common : u64,
    /** Where the notification area is mapped; a queue's notify address is in it. */
    notify : u64,
    /** How many bytes apart queues' notify addresses are, per unit of QUEUE_NOTIFY_OFF. */
    notify_multiplier : u32,
    /** Where the ISR status byte is mapped, 0 if the device has none. */
    isr : u64,
    /** Where the device-specific configuration is mapped, 0 if the device has none. */
    device : u64,
    /** Where the MSI-X table is mapped, its entries 16 bytes each. */
    msix_table : u64,
    /** How many entries the MSI-X table has, from 1 to 2048. */
    msix_entries : u32,
}

/**
 * A split virtqueue: its memory, where it is to the device and to the driver, and how far each ring has got.
 *
 * Its memory holds its descriptor table from its start, 16 bytes each, then the driver's ring, then, 4-byte aligned,
 * the device's ring (virtio 1.2 §2.7, alignment 16, 2 and 4).
 */
Queue :: struct {
    /** The queue's index on its device. */
    index : u16,
    /** How many descriptors it has, a power of two from 1 to MAX_QUEUE_SIZE. */
    size : u16,
    /** Where its memory is mapped in the driver's address space: descriptors, the driver's ring, the device's. */
    page : u64,
    /** Where the driver's ring is in its memory, in bytes: flags, its index, then its entries. */
    driver_ring : u64,
    /** Where the device's ring is in its memory, in bytes: flags, its index, then its elements. */
    device_ring : u64,
    /** Where its notify register is mapped, written with its index to tell the device of new buffers. */
    notify : u64,
    /** The driver ring's index: how many chains have been offered in all, wrapping at 65536. */
    next_available : u16,
    /** How many used elements have been taken in all, wrapping at 65536. */
    last_used : u16,
    /** The descriptors not in a chain the device has, a bit each, descriptor i at bit i % 64 of word i / 64. */
    free : u64[FREE_WORDS],
    /** How many chains have been added since the device was last notified. */
    unnotified : u16,
}

/** One buffer of a chain: where it is to the device, how long, and whether the device writes it (or reads it). */
Part :: struct {
    /** The buffer's device address, as slop_os.memory_device_address gives a DMA memory's. */
    address : u64,
    /** Its length in bytes. */
    length : u32,
    /** Whether the device writes it; false for one the device reads. */
    device_writes : bool,
}

/**
 * Find a device's registers from its capabilities, as its transport.
 *
 * @param config Where the device's configuration space is mapped, readable and writable.
 * @param bars Where each of its BARs is mapped, by BAR number, 0 for one that isn't mapped; a capability in an unmapped
 *     BAR is passed over.
 * @return The transport; null if it lacks the common configuration, the notification area, or MSI-X, or its MSI-X
 *     table's BAR isn't mapped.
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

/**
 * How many times start reads a device's status, spinning between, waiting for its reset to finish before giving up on
 * it: some hundreds of milliseconds at the least, far past what a working device takes.
 */
RESET_SPINS : u64 : 1 << 24

/**
 * Reset a device, tell it a driver has it, and negotiate its features (virtio 1.2 §3.1.1, steps 1 to 6).
 *
 * The features taken are those of wanted the device offers, always with VERSION_1, and with ACCESS_PLATFORM where it's
 * offered, since memory_device_address gives what the device's DMA reaches memory at. It waits, spinning, until the
 * device's reset is done, or RESET_SPINS spins have gone by without it.
 *
 * @param transport The device's transport, from open.
 * @param wanted The device-specific features the driver can use, as bits; those the device doesn't offer are left out.
 * @return The features taken, which the device accepted; null, the device marked FAILED, if its reset never finished,
 *     it isn't modern (no VERSION_1), or it refused them.
 */
start :: fn(transport: ptr[Transport], wanted: u64) -> u64? {
    common :: transport.common
    write_u8(common, DEVICE_STATUS, 0)
    spins := cast[u64](0)
    loop {
        if read_u8(common, DEVICE_STATUS) == 0 {
            break
        }
        if spins >= RESET_SPINS {
            write_u8(common, DEVICE_STATUS, STATUS_FAILED)
            return null
        }
        intrinsics.spin_hint()
        spins += 1
    }
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
    taken :: offered & (wanted | FEATURE_VERSION_1 | FEATURE_ACCESS_PLATFORM)
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

/**
 * Set an MSI-X table entry's message, unmasked, and turn MSI-X on for the function; configuration changes are then
 * reported to no vector.
 *
 * @param transport The device's transport, as open made it: the entry is written in its MSI-X table, and MSI-X turned
 *     on in its configuration space.
 * @param entry The table entry, from 0, which a queue is then set up to interrupt through.
 * @param address The message's address, as slop_os.irq_message gives it.
 * @param data The message's data, as slop_os.irq_message gives it.
 * @return True once it's set; false, nothing written, if entry is past the table's, or the MSI-X capability isn't
 *     found.
 */
set_vector :: fn(transport: ptr[Transport], entry: u32, address: u64, data: u32) -> bool {
    if entry >= transport.msix_entries {
        return false
    }
    msix :: pci.find_capability(transport.config, CAPABILITY_MSIX) or_return false
    at :: transport.msix_table + cast[u64](entry) * 16
    write_u32(at, 0, cast[u32](address))
    write_u32(at, 4, cast[u32](address >> 32))
    write_u32(at, 8, data)
    write_u32(at, 12, 0)
    control :: pci.read_u16(transport.config, msix + 2)
    // Enabled (bit 15), and the function not masked (bit 14)
    pci.write_u16(transport.config, msix + 2, (control | 0x8000) & ~cast[u16](0x4000))
    write_u16(transport.common, CONFIG_MSIX_VECTOR, NO_VECTOR)
    return true
}

/**
 * Have configuration changes interrupt through an MSI-X entry, as set_vector set it.
 *
 * @param transport The device's transport, as open made it, after set_vector.
 * @param entry The MSI-X table entry, or NO_VECTOR for none.
 * @return True if the device took it; false if it reads back NO_VECTOR, as a device that refused it gives.
 */
set_config_vector :: fn(transport: ptr[Transport], entry: u16) -> bool {
    write_u16(transport.common, CONFIG_MSIX_VECTOR, entry)
    return read_u16(transport.common, CONFIG_MSIX_VECTOR) == entry
}

/**
 * Give where a queue's device ring starts in its memory: after its descriptors and driver ring, 4-byte aligned.
 *
 * @param size The queue's size in descriptors, 1 to MAX_QUEUE_SIZE.
 * @return The offset in bytes.
 */
device_ring_at :: fn(size: u64) -> u64 {
    // The driver's ring: flags, index, an entry for each descriptor, and the used event
    driver_end :: 16 * size + 6 + 2 * size
    return (driver_end + 3) & ~cast[u64](3)
}

/**
 * Give the bytes a queue of a size takes: descriptors, the driver's ring, the device's ring.
 *
 * @param size The queue's size in descriptors, 1 to MAX_QUEUE_SIZE.
 * @return The bytes, not rounded to pages: 3334 for 128, so one page holds it; 6662 for 256.
 */
queue_bytes :: fn(size: u64) -> u64 {
    // The device's ring: flags, index, an element for each descriptor, and the available event
    return device_ring_at(size) + 6 + 8 * size
}

/**
 * Set up and enable one of a device's queues in DMA memory, its interrupts to an MSI-X entry.
 *
 * It's sized to the largest power of two that the device takes, MAX_QUEUE_SIZE allows and its memory holds
 * (queue_bytes). Done after start and before ready.
 *
 * @param transport The device's transport, as open made it, after start; its common configuration selects the queue and
 *     is written, and its notification area gives the queue's notify address.
 * @param index The queue's index on the device, from 0.
 * @param page Where the memory is mapped in the driver's address space, readable and writable, zeroed.
 * @param device_page Where the same memory is to the device, as slop_os.memory_device_address gives it, 16-byte
 *     aligned.
 * @param bytes The memory's size in bytes: QUEUE_PAGE holds 128 descriptors, twice that MAX_QUEUE_SIZE.
 * @param vector The MSI-X table entry its interrupts go to, as set_vector set; NO_VECTOR for none.
 * @return The queue, all its descriptors free; null if the device has no such queue, won't take the vector, or the
 *     memory doesn't hold a queue of one descriptor.
 */
setup_queue :: fn(transport: ptr[Transport], index: u16, page: u64, device_page: u64, bytes: u64, vector: u16) -> Queue? {
    common :: transport.common
    if index >= read_u16(common, NUM_QUEUES) {
        return null
    }
    write_u16(common, QUEUE_SELECT, index)
    largest :: cast[u64](read_u16(common, QUEUE_SIZE))
    if largest == 0 {
        return null
    }
    size := cast[u64](MAX_QUEUE_SIZE)
    loop {
        if size <= largest && queue_bytes(size) <= bytes {
            break
        }
        size /= 2
    }
    while size > 0
    if size == 0 {
        return null
    }
    device_ring :: device_ring_at(size)
    write_u16(common, QUEUE_SIZE, cast[u16](size))
    write_u64(common, QUEUE_DESC, device_page)
    write_u64(common, QUEUE_DRIVER, device_page + 16 * size)
    write_u64(common, QUEUE_DEVICE, device_page + device_ring)
    write_u16(common, QUEUE_MSIX_VECTOR, vector)
    if read_u16(common, QUEUE_MSIX_VECTOR) != vector {
        return null
    }
    notify_off :: cast[u64](read_u16(common, QUEUE_NOTIFY_OFF))
    write_u16(common, QUEUE_ENABLE, 1)
    queue := Queue.{index = index, size = cast[u16](size), page = page, driver_ring = 16 * size, device_ring = device_ring,
        notify = transport.notify + notify_off * cast[u64](transport.notify_multiplier)}
    for &word, i in queue.free {
        first :: cast[u64](i) * 64
        word^ = if size >= first + 64 { cast[u64](0xffffffffffffffff) }
            else if size > first { (cast[u64](1) << (size - first)) - 1 }
            else { cast[u64](0) }
    }
    return queue
}

/**
 * Tell the device the driver is ready (DRIVER_OK), once its queues are set up; it may use them from then on.
 *
 * @param transport The device's transport, as open made it, after start and setup_queue; its device status is written,
 *     not read back.
 */
ready :: fn(transport: ptr[Transport]) {
    write_u8(transport.common, DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK)
}

/**
 * Offer one buffer to the device, as a chain of one descriptor (offer_chain), and notify it.
 *
 * @param queue The queue, set up and ready, one of whose descriptors is taken.
 * @param device_address The buffer's device address.
 * @param length The buffer's length in bytes.
 * @param device_writes Whether the device writes it; false for one it reads.
 * @return The descriptor's index, which take_used gives back once the device's done; NO_DESCRIPTOR if none is free.
 */
offer :: fn(queue: ptr[mut Queue], device_address: u64, length: u32, device_writes: bool) -> u16 {
    return offer_chain(queue, Part.[Part.{address = device_address, length = length, device_writes = device_writes}])
}

/**
 * Offer buffers to the device as one chain, in order, each on a free descriptor, then notify it (add_chain, then
 * notify).
 *
 * @param queue The queue, set up and ready, as many of whose descriptors as there are parts are taken.
 * @param parts The buffers, 1 to MAX_CHAIN of them; the memory each names has to stay as it is until the device's done.
 * @return The first descriptor's index, which take_used gives back; NO_DESCRIPTOR, nothing offered, if there are no
 *     parts, not enough descriptors are free, or there are more than MAX_CHAIN parts.
 */
offer_chain :: fn(queue: ptr[mut Queue], parts: Part[]) -> u16 {
    id :: add_chain(queue, parts)
    notify(queue)
    return id
}

/**
 * Notify the device of the chains added since it was last notified, if there are any.
 *
 * @param queue The queue, set up and ready, whose unnotified count goes back to 0.
 */
notify :: fn(queue: ptr[mut Queue]) {
    if queue.unnotified == 0 {
        return void
    }
    queue.unnotified = 0
    // The index is where the device reads it before it's told
    intrinsics.fence_sequentially_consistent()
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](queue.notify), bit_cast[u16](cast[u16le](queue.index)))
}

/**
 * Add buffers to the device's ring as one chain, in order, each on a free descriptor, without notifying it: a driver
 * adding several notifies once after (notify).
 *
 * The descriptors are written before the driver ring's index, with fences between, so the device sees them whole.
 * They stay taken until take_used gives the chain back. A device that looks at the ring before it's notified may take
 * the chain at once.
 *
 * @param queue The queue, set up and ready, as many of whose descriptors as there are parts are taken.
 * @param parts The buffers, 1 to MAX_CHAIN of them; the memory each names has to stay as it is until the device's done.
 * @return The first descriptor's index, which take_used gives back; NO_DESCRIPTOR, nothing added, if there are no
 *     parts, not enough descriptors are free, or there are more than MAX_CHAIN parts.
 */
add_chain :: fn(queue: ptr[mut Queue], parts: Part[]) -> u16 {
    if parts.count == 0 {
        return NO_DESCRIPTOR
    }
    ids : u16[MAX_CHAIN]
    taken : usize = 0
    for &id in ids {
        if taken >= parts.count {
            break
        }
        // None free: those taken so far are given back below
        found :: first_free(queue) or_break
        id^ = found
        set_free(queue, found, false)
        taken += 1
    }
    if taken < parts.count {
        for id, i in ids {
            if i < taken {
                set_free(queue, id, true)
            }
        }
        return NO_DESCRIPTOR
    }
    for part, i in parts {
        if i >= ids.count {
            break
        }
        descriptor :: cast[ptr[mut Descriptor]](queue.page + cast[u64](ids[i]) * 16)
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
    entry :: cast[ptr[mut u16le]](queue.page + queue.driver_ring + 4 + cast[u64](queue.next_available % queue.size) * 2)
    entry^ = cast[u16le](id)
    queue.next_available += 1
    // The descriptor and entry are where the device reads them before it sees the index
    intrinsics.fence_sequentially_consistent()
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](queue.page + queue.driver_ring + 2), bit_cast[u16](cast[u16le](queue.next_available)))
    queue.unnotified += 1
    return id
}

/**
 * Tell whether a descriptor is free.
 *
 * @param queue The queue.
 * @param id The descriptor's index; one past MAX_QUEUE_SIZE counts as free.
 * @return True if it's free.
 */
is_free :: fn(queue: ptr[Queue], id: u16) -> bool {
    word :: cast[usize](id) / 64
    if word >= queue.free.count {
        return true
    }
    return queue.free[word] & (cast[u64](1) << (cast[u64](id) % 64)) != 0
}

/**
 * Mark a descriptor free or taken.
 *
 * @param queue The queue.
 * @param id The descriptor's index, below the queue's size; one past MAX_QUEUE_SIZE is passed over.
 * @param free True to mark it free, false taken.
 */
set_free :: fn(queue: ptr[mut Queue], id: u16, free: bool) {
    word :: cast[usize](id) / 64
    if word >= queue.free.count {
        return void
    }
    bit :: cast[u64](1) << (cast[u64](id) % 64)
    if free {
        queue.free[word] |= bit
    }
    else {
        queue.free[word] &= ~bit
    }
}

/** A buffer the device has finished with: its descriptor's index, and how many bytes it wrote. */
Used :: struct {
    /** The index of the chain's first descriptor, as offer or offer_chain gave it. */
    id : u16,
    /** How many bytes the device wrote into the chain's buffers, as it says; not checked against their lengths. */
    length : u32,
}

/**
 * Find the lowest free descriptor of a queue.
 *
 * @param queue The queue, which isn't changed.
 * @return Its index, below the queue's size; null if every one is in a chain the device has.
 */
first_free :: fn(queue: ptr[Queue]) -> u16? {
    for word, i in queue.free {
        if word == 0 {
            continue
        }
        for bit in cast[u64](0)..<64 {
            found :: cast[u64](i) * 64 + bit
            if found >= cast[u64](queue.size) {
                return null
            }
            if word & (cast[u64](1) << bit) != 0 {
                return cast[u16](found)
            }
        }
    }
    return null
}

/**
 * Take the next chain the device has finished with, if there's one, its descriptors free again.
 *
 * It doesn't wait: a driver waits for the queue's interrupt, then takes until there's none.
 *
 * A used element naming a descriptor that isn't the first of a chain the driver gave, out of the queue or free
 * already, is passed over (13h): the device's word alone would otherwise free a chain still in flight.
 *
 * @param queue The queue, set up, its device ring read and its finished descriptors freed.
 * @return The chain's first descriptor's index and how many bytes the device wrote; null if the device hasn't
 *     finished another.
 */
take_used :: fn(queue: ptr[mut Queue]) -> Used? {
    used_index : u16 = bit_cast[u16le](intrinsics.volatile_load_u16(cast[ptr[u16]](queue.page + queue.device_ring + 2)))
    id := cast[u32](0)
    length := cast[u32](0)
    loop {
        if used_index == queue.last_used {
            return null
        }
        // The element is read after the index that says it's there
        intrinsics.fence_sequentially_consistent()
        element :: cast[ptr[UsedElement]](queue.page + queue.device_ring + 4 + cast[u64](queue.last_used % queue.size) * 8)
        queue.last_used += 1
        id = element.id
        length = element.length
        if id < cast[u32](queue.size) && !is_free(queue, cast[u16](id)) {
            break
        }
    }
    while true
    // Each descriptor of the chain, followed through its next, free again
    at := cast[u16](id)
    for step in 0..<MAX_CHAIN {
        if cast[u64](at) >= cast[u64](queue.size) {
            break
        }
        set_free(queue, at, true)
        descriptor :: cast[ptr[Descriptor]](queue.page + cast[u64](at) * 16)
        flags : u16 = descriptor.flags
        if flags & DESCRIPTOR_NEXT == 0 {
            break
        }
        next : u16 = descriptor.next
        at = next
    }
    return Used.{id = cast[u16](id), length = length}
}

/**
 * Read the ISR status byte, which reading clears: bit 0 for a queue's interrupt, bit 1 for a configuration change.
 *
 * @param transport The device's transport, as open made it; its ISR status byte is read, which clears it.
 * @return The status; 0 if the device has no ISR status.
 */
interrupt_status :: fn(transport: ptr[Transport]) -> u8 {
    return if transport.isr == 0 { cast[u8](0) } else { intrinsics.volatile_load_u8(cast[ptr[u8]](transport.isr)) }
}

/**
 * Read a device's 8-bit register, with one volatile load.
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes.
 * @return The register's value as the device gives it at the load; never cached, nor merged with other volatile
 *     accesses.
 */
read_u8 :: fn(base: u64, offset: u64) -> u8 {
    return intrinsics.volatile_load_u8(cast[ptr[u8]](base + offset))
}

/**
 * Read a device's 16-bit register, little-endian whatever the target, with one volatile load.
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes, 2-byte aligned.
 * @return The register's value, read as little-endian and given in the CPU's order.
 */
read_u16 :: fn(base: u64, offset: u64) -> u16 {
    return bit_cast[u16le](intrinsics.volatile_load_u16(cast[ptr[u16]](base + offset)))
}

/**
 * Read a device's 32-bit register, little-endian whatever the target, with one volatile load.
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes, 4-byte aligned.
 * @return The register's value, read as little-endian and given in the CPU's order.
 */
read_u32 :: fn(base: u64, offset: u64) -> u32 {
    return bit_cast[u32le](intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset)))
}

/**
 * Write a device's 8-bit register, with one volatile store.
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes.
 * @param value What's written.
 */
write_u8 :: fn(base: u64, offset: u64, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](base + offset), value)
}

/**
 * Write a device's 16-bit register, little-endian whatever the target, with one volatile store.
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes, 2-byte aligned.
 * @param value What's written.
 */
write_u16 :: fn(base: u64, offset: u64, value: u16) {
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](base + offset), bit_cast[u16](cast[u16le](value)))
}

/**
 * Write a device's 32-bit register, little-endian whatever the target, with one volatile store.
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes, 4-byte aligned.
 * @param value What's written.
 */
write_u32 :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), bit_cast[u32](cast[u32le](value)))
}

/**
 * Write a device's 64-bit register as two 32-bit halves, low first, as the transport allows (virtio 1.2 §4.1.3.1).
 *
 * @param base Where the register block is mapped.
 * @param offset The register's offset in bytes, 8-byte aligned.
 * @param value What's written.
 */
write_u64 :: fn(base: u64, offset: u64, value: u64) {
    write_u32(base, offset, cast[u32](value))
    write_u32(base, offset + 4, cast[u32](value >> 32))
}
