/**
 * The virtio-rng driver (decisions/0074): a virtio entropy device's one queue, through the virtio-pci transport
 * (src/virtio), its interrupts through one MSI-X vector. It offers itself to the entropy service as a source
 * (entropy.AddSource), on a channel of the rng protocol, and answers each Read with what the device gives: a buffer
 * offered to the device, its MSI awaited, and the bytes it wrote sent back.
 */
package virtio_rng

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import service_kit from "../../libraries/service_kit"
import driver_kit from "../../driver_kit"
import pci from "../../pci"
import entropy from "../../protocols/entropy"
import rng from "../../protocols/rng"
import virtio from "../../virtio"

/** The bytes of a page: 4096. */
PAGE : u64 : 4096
/** The port key the device's interrupt is bound with. */
IRQ_KEY : u64 : 1
/** The port key the rng channel's end is bound with, for the entropy service's Reads. */
REQUESTS_KEY : u64 : 2
/**
 * The longest the device may take to fill a buffer, in nanoseconds, 1 s, before a Read is answered with what there is.
 */
FILL_NANOSECONDS : u64 : 1_000_000_000

/** The driver's state, main's for its life. */
Driver :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log. */
    log : slop_os.DebugLog,
    /** The device's registers. */
    transport : virtio.Transport,
    /** The device's one queue, requestq, which buffers are offered on to fill. */
    queue : virtio.Queue,
    /** Where the page the device writes into is, through the driver's mapping. */
    buffer : u64,
    /** Where the same page is to the device, its device address. */
    buffer_device : u64,
    /** The one port its interrupt and its channel are bound to. */
    port : slop_os.Port,
}

/**
 * Drive a virtio entropy device, and offer it to the entropy service as a source of random bytes.
 *
 * It sets the device up, makes a channel of the rng protocol, sends one end to the entropy service in an AddSource,
 * and answers each Read on the other until the entropy service lets go of it. It's started by the supervisor, for a
 * device the platform service gave it, with what its driver holds of it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The device, for its MSI.
 * @param config The device's 4 KiB of configuration space, mapped to find its capabilities and turn bus mastering on.
 * @param bar0 BAR 0's memory, if the device has it; each BAR given is mapped, for the virtio structures in it.
 * @param bar1 BAR 1's memory, if the device has it.
 * @param bar2 BAR 2's memory, if the device has it.
 * @param bar3 BAR 3's memory, if the device has it.
 * @param bar4 BAR 4's memory, if the device has it.
 * @param bar5 BAR 5's memory, if the device has it.
 * @param domain The DMA domain the device is attached to, which its queue and buffer are made in.
 * @param entropy_service A connection to the entropy service, to offer the device to; without one, the driver's end
 *     is closed, and it serves no one.
 * @return 0 once the entropy service has let go of it; 2 if config couldn't be mapped, 3 if the device isn't a virtio
 *     one it can drive, 4 if it refused its features, 5 if no port could be made, 6 if its MSI couldn't be set up, 7 if
 *     its DMA memory couldn't be made or mapped, 8 if its queue couldn't be set up, 9 if its channel couldn't be made,
 *     10 if the AddSource couldn't be sent.
 */
main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    entropy_service: os.Channel[entropy.Entropy]?) -> int {
    block :: slop_os.startup_block()
    driver := Driver.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)}
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    driver.transport = virtio.open(config_at, bars) or_return 3
    _ = virtio.start(&driver.transport, 0) or_return 4

    // Its interrupts, one vector, to the driver's port
    driver.port = slop_os.port_create(block.budget) or_return 5
    irq :: slop_os.irq_create_msi(device, block.budget) or_return 6
    message :: slop_os.irq_message(irq) or_return 6
    if !virtio.set_vector(&driver.transport, 0, message.address, message.data) {
        return 6
    }
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent) or_return 6

    // Its queue and the buffer the device fills, in DMA memory
    memory :: slop_os.dma_memory_create(domain, block.budget, 2 * PAGE, 0) or_return 7
    pages :: runtime.reserve_addresses(cast[usize](2 * PAGE)) or_return 7
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, block.space, pages, 0, 2 * PAGE, read_write) or_return 7
    device_address :: slop_os.memory_device_address(memory) or_return 7
    driver.queue = virtio.setup_queue(&driver.transport, 0, pages, device_address, 0) or_return 8
    driver.buffer = pages + PAGE
    driver.buffer_device = device_address + PAGE
    virtio.ready(&driver.transport)

    // Bus mastering on, for its DMA and its MSIs
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)

    // A source of the entropy service's, on a channel of its own
    pair :: os.channel_for[rng.Rng](block.budget, 0) or_return 9
    slop_os.port_bind(driver.port, cast[slop_os.Handle](pair.b), cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE)
        | cast[u32](slop_os.SIGNAL_PEER_CLOSED)), REQUESTS_KEY, .Persistent) or_return 9
    match entropy_service {
        case Some(service) => {
            entropy_port :: os.port_for(block.budget, service.end) or_return 10
            out := os.Outgoing.{}
            request :: os.begin[entropy.Request](&out)
            request^ = .AddSource(os.Channel[rng.Rng].{end = pair.a})
            if entropy.send_request(service.end, entropy_port, &out) != null {
                return 10
            }
        }
        case None => _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
    }
    runtime.log_info("serving, a source of the entropy service's")
    _ = service_kit.watch_stop(driver.port)
    serve(&driver, pair.b)
    return 0
}

/**
 * Answer every Read on a channel, until its other end is gone, or the driver's asked to stop.
 *
 * Each Read is answered with Bytes, as many as the device gave, up to the count asked and rng.MAX_BYTES; an unknown
 * request is answered Unsupported, and anything else is skipped. It waits on the driver's port between them.
 *
 * @param driver The driver, its queue set up and ready.
 * @param end The driver's end of the rng channel, bound to its port, kept by the caller.
 */
serve :: fn(driver: ptr[mut Driver], end: slop_os.Channel) {
    into := os.Incoming.{}
    loop {
        match rng.receive_request(end, driver.port, &into, false) {
            case Received => {}
            case Empty => {
                // Asked to stop, as the system shuts down (decisions/0182)
                if service_kit.stopping() {
                    return void
                }
                packets : slop_os.Packet[4]
                _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
                continue
            }
            case Unsupported => {
                _ = rng.answer_unsupported(end, driver.port)
                continue
            }
            case Failed(error) => return void
            case _ => return void
        }
        match os.message_of[rng.Request](&into)^ {
            case Read(count) => {
                wanted :: if count < rng.MAX_BYTES { count } else { rng.MAX_BYTES }
                given :: fill(driver, wanted)
                out := os.Outgoing.{}
                response :: os.begin[rng.Response](&out)
                response^ = .Bytes(os.append(&out, view_of(cast[ptr[u8]](driver.buffer), cast[usize](given))))
                _ = rng.send_response(end, driver.port, &out)
            }
        }
    }
}

/**
 * Have the device fill the buffer with random bytes, and wait for it, at most FILL_NANOSECONDS.
 *
 * @param driver The driver, its queue set up and ready.
 * @param count How many bytes to ask for, at most the buffer's page.
 * @return How many bytes the device wrote at the buffer's start, at most count; 0 if it didn't finish in time, or no
 *     descriptor was free. A buffer the device finishes late is taken by the next fill instead.
 */
fill :: fn(driver: ptr[mut Driver], count: u32) -> u32 {
    _ = virtio.offer(&driver.queue, driver.buffer_device, count, true)
    deadline :: (slop_os.clock_monotonic() or_else 0) + FILL_NANOSECONDS
    loop {
        match virtio.take_used(&driver.queue) {
            case Some(used) => return if used.length < count { used.length } else { count }
            case None => {}
        }
        packets : slop_os.Packet[4]
        waited :: slop_os.port_wait(driver.port, packets, deadline) or_else 0
        if waited == 0 {
            return 0
        }
    }
}
