/*
 * The virtio-rng driver (decisions/0074): a virtio entropy device's one queue, through the virtio-pci transport
 * (src/virtio), its interrupts through one MSI-X vector. It offers itself to the entropy service as a source
 * (entropy.AddSource), on a channel of the rng protocol, and answers each Read with what the device gives: a buffer
 * offered to the device, its MSI awaited, and the bytes it wrote sent back.
 */
package virtio_rng

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import log_line from "../../log_line"
import pci from "../../pci"
import entropy from "../../protocols/entropy"
import rng from "../../protocols/rng"
import virtio from "../../virtio"

PAGE : u64 : 4096
IRQ_KEY : u64 : 1
REQUESTS_KEY : u64 : 2
// The longest the device may take to fill a buffer before a Read is answered with what there is
FILL_NANOSECONDS : u64 : 1_000_000_000

Driver :: struct {
    log : slop_os.DebugLog,
    transport : virtio.Transport,
    queue : virtio.Queue,
    // The page the device writes into: through the driver's mapping, and where it is to the device
    buffer : u64,
    buffer_device : u64,
    port : slop_os.Port,
}

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
    log_line.write(driver.log, "virtio_rng: serving, a source of the entropy service's")
    serve(&driver, pair.b)
    return 0
}

// Every Read on end, until its other end is gone.
serve :: fn(driver: ptr[mut Driver], end: slop_os.Channel) {
    into := os.Incoming.{}
    loop {
        match rng.receive_request(end, driver.port, &into, false) {
            case Received => {}
            case Empty => {
                packets : slop_os.Packet[4]
                _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
                continue
            }
            case Unsupported => {
                _ = rng.answer_unsupported(end, driver.port)
                continue
            }
            case Failed(error) => return void
            case _ => continue
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

// count bytes from the device into the buffer: how many it wrote, waiting for its MSI.
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
