/**
 * The NVMe driver (roadmap 20b, decisions/0201): an NVM Express controller's first namespace as the block protocol for
 * its clients, who arrive on its listener, as virtio-blk's are. The controller is set up through its admin queue,
 * polled, as only starting it uses it: its namespace identified, then one I/O completion queue, whose interrupt is
 * MSI-X entry 0, and one I/O submission queue. Each connection's buffer is DMA memory of its own, made at its first
 * GetBuffer, which the controller reads and writes directly, its pages named by a PRP list where a transfer spans more
 * than two. Up to SLOTS requests are in flight across the clients, each a command whose identifier is its slot,
 * answered with its client's tag as the controller completes it; one past that is answered Busy.
 *
 * A namespace whose blocks are larger than block.BLOCK_BYTES serves its blocks as BLOCK_BYTES ones: a transfer has to
 * start and end on one of the namespace's, or it's OutOfRange.
 *
 * SPEC: NVM Express Base Specification 2.0 (registers §3.1, starting the controller §3.5.1, queues §4.1, the admin
 * commands Identify, Create I/O Completion Queue and Create I/O Submission Queue §5); NVM Command Set 1.0 (Read,
 * Write, Flush, and Identify Namespace).
 */
package nvme

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import driver_kit from "../../driver_kit"
import service_kit from "../../libraries/service_kit"
import pci from "../../pci"
import block from "../../protocols/block"

/** The bytes of a page, and of the controller's memory pages, which CC.MPS is set to: 4096. */
PAGE : u64 : 4096
/** The bytes of each connection's buffer, 64 KiB, which a transfer's data has to fit. */
BUFFER_BYTES : u64 : 64 * 1024
/** How many requests may be in flight at once, across every client: 16; one more is answered Busy. */
SLOTS :: 16
/** The port key the controller's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** How many entries each queue has: the admin queues' and the I/O queues', each a page or less. */
QUEUE_ENTRIES : u32 : 64
/** The bytes of a submission queue entry, and a completion queue entry. */
SUBMISSION_BYTES : u64 : 64
COMPLETION_BYTES : u64 : 16
/** How long a wait for the controller may take, in polls, before it's taken as having failed. */
SPINS : u64 : 50_000_000

// Registers, from BAR 0 (§3.1)
/** CAP: what the controller can do; its timeout (TO, bits 31:24, in 500 ms) and doorbell stride (DSTRD, 35:32). */
CAP : u64 : 0x00
/** CC: its configuration; EN (bit 0) starts it. */
CC : u64 : 0x14
/** CSTS: its status; RDY (bit 0) says it's started, CFS (bit 1) that it failed. */
CSTS : u64 : 0x1c
/** AQA: the admin queues' sizes, each less one. */
AQA : u64 : 0x24
/** ASQ and ACQ: the admin submission and completion queues' addresses. */
ASQ : u64 : 0x28
ACQ : u64 : 0x30
/** Where the doorbells start, each queue's submission tail and completion head, DSTRD apart. */
DOORBELLS : u64 : 0x1000
/** CC's EN, and its entry sizes: IOSQES 6 (64 bytes, bits 19:16) and IOCQES 4 (16 bytes, bits 23:20); MPS 0, 4 KiB. */
CC_ENABLE : u32 : 1
CC_ENTRY_SIZES : u32 : (6 << 16) | (4 << 20)
/** CSTS's RDY and CFS. */
CSTS_READY : u32 : 1
CSTS_FATAL : u32 : 1 << 1

// Commands' opcodes
/** Admin: Identify, Create I/O Completion Queue, Create I/O Submission Queue. */
ADMIN_IDENTIFY : u8 : 0x06
ADMIN_CREATE_COMPLETION : u8 : 0x05
ADMIN_CREATE_SUBMISSION : u8 : 0x01
/** NVM: Flush, Write, Read. */
NVM_FLUSH : u8 : 0x00
NVM_WRITE : u8 : 0x01
NVM_READ : u8 : 0x02
/** Identify's CNS: a namespace (0), the controller (1). */
IDENTIFY_NAMESPACE : u32 : 0
IDENTIFY_CONTROLLER : u32 : 1
/** The namespace served: the first. */
NAMESPACE : u32 : 1
/** The I/O queue pair's ID. */
IO_QUEUE : u16 : 1

/** Where in the driver's DMA memory each thing is, in pages. */
ADMIN_SUBMISSIONS_PAGE : u64 : 0
ADMIN_COMPLETIONS_PAGE : u64 : 1
IO_SUBMISSIONS_PAGE : u64 : 2
IO_COMPLETIONS_PAGE : u64 : 3
/** The page Identify writes into. */
IDENTIFY_PAGE : u64 : 4
/** The slots' PRP lists, a page each. */
PRP_LISTS_PAGE : u64 : 5
/** The driver's DMA memory's pages. */
MEMORY_PAGES : u64 : PRP_LISTS_PAGE + cast[u64](SLOTS)

/** A submission queue entry (§4.2): the command's dwords, as the controller reads them. */
Command :: struct #packed {
    /** CDW0: the opcode (bits 7:0) and the command identifier (bits 31:16). */
    dword0 : u32le,
    /** The namespace. */
    namespace : u32le,
    reserved : u64le,
    /** The metadata pointer, unused. */
    metadata : u64le,
    /** PRP entry 1 and 2: the data's first page, and its second or a PRP list. */
    prp1 : u64le,
    prp2 : u64le,
    /** CDW10 to CDW15, the command's own. */
    dword10 : u32le,
    dword11 : u32le,
    dword12 : u32le,
    dword13 : u32le,
    dword14 : u32le,
    dword15 : u32le,
}

#assert size_of(Command) == 64

/** A completion queue entry (§4.6). */
Completion :: struct #packed {
    /** The command's own result. */
    result : u32le,
    reserved : u32le,
    /** Where the submission queue's head is now (bits 15:0) and which queue (31:16). */
    head : u32le,
    /** The command identifier (bits 15:0), the phase tag (bit 16) and the status (bits 31:17). */
    status : u32le,
}

#assert size_of(Completion) == 16

/** A queue, as the driver keeps it: where its entries are, and its index. */
Queue :: struct {
    /** Where its entries are, through the driver's mapping. */
    entries : u64,
    /** Where they are to the controller. */
    device : u64,
    /** A submission queue's tail, or a completion queue's head, as the driver last wrote its doorbell. */
    index : u32,
    /** A completion queue's phase tag: the one an entry the controller has written has now. */
    phase : u32,
    /** Its doorbell's address, through the driver's mapping of BAR 0. */
    doorbell : u64,
}

/** A request in flight: whose, and its tag. */
Slot :: struct {
    /** Whether the slot holds a request in flight. */
    used : bool,
    /** The client that asked, by its index. */
    client : usize,
    /** The client's tag, given back in its Finished. */
    tag : u64,
    /** The client's place's generation when it was asked, so it's answered only if the same client's still there. */
    generation : u32,
    /** The buffer the controller reads or writes for it, kept until it's done though its client goes. */
    memory : slop_os.Memory,
}

/** A connection's buffer, once it has one: the memory, and where it is to the controller. */
Buffer :: struct {
    /** The buffer's DMA memory, BUFFER_BYTES of it, the driver's; NO_HANDLE before the first GetBuffer. */
    memory : slop_os.Memory,
    /** Where it is to the controller. */
    device : u64,
}

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** The DMA domain the controller is attached to, which every buffer is made in. */
    domain : slop_os.DmaDomain,
    /** Where BAR 0, the controller's registers, is mapped. */
    registers : u64,
    /** The bytes between doorbells: 4 << CAP.DSTRD. */
    stride : u64,
    /** Where the driver's DMA memory is, through its mapping, and to the controller. */
    memory : u64,
    memory_device : u64,
    /** The admin queues, and the I/O queues. */
    admin_submissions : Queue,
    admin_completions : Queue,
    io_submissions : Queue,
    io_completions : Queue,
    /** The namespace's size, in block.BLOCK_BYTES blocks. */
    block_count : u64,
    /** How many BLOCK_BYTES blocks one of the namespace's is: 1, or more for a larger block. */
    per_block : u64,
    /** Whether the controller has a volatile write cache, which Flush writes back; without one, Flush is Done at once. */
    flushes : bool,
    /** The requests in flight, each the command whose identifier is its index. */
    slots : Slot[SLOTS],
    /** Each client's buffer, by its index. */
    buffers : Buffer[service_kit.MAX_CLIENTS],
    /** Each client's place's generation, by its index, moved on as a client leaves it. */
    generations : u32[service_kit.MAX_CLIENTS],
    /** The one port its interrupt and its clients are bound to. */
    port : slop_os.Port,
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
}

/**
 * Drive an NVM Express controller's first namespace as a disk, the block protocol, for the clients that connect to it.
 *
 * It starts the controller and serves the block protocol on its listener and each connection made through it, until
 * the system stops. It's started by the supervisor, for a controller the platform service gave it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The controller, for its MSI-X.
 * @param config The controller's 4 KiB of configuration space, mapped to find its MSI-X and turn bus mastering on.
 * @param bar0 BAR 0's memory, its registers, which it has to have.
 * @param bar1 BAR 1's memory, if the controller has it, as the upper half of a 64-bit BAR 0 has none.
 * @param bar2 BAR 2's memory, if it has it.
 * @param bar3 BAR 3's memory, if it has it.
 * @param bar4 BAR 4's memory, if it has it, where its MSI-X table may be.
 * @param bar5 BAR 5's memory, if it has it.
 * @param domain The DMA domain the controller is attached to, which its queues and every connection's buffer are made
 *     in.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had, 2 if config or BAR 0 couldn't be
 *     mapped, 3 if its DMA memory couldn't be made or mapped, 4 if the controller didn't stop or start, 5 if an admin
 *     command failed or the namespace has no blocks, 6 if no port could be made, 7 if its MSI-X couldn't be set up,
 *     9 if the listener couldn't be bound.
 */
main :: fn(
    log : slop_os.DebugLog?,
    device : slop_os.Device,
    config : slop_os.Memory,
    bar0 : slop_os.Memory?,
    bar1 : slop_os.Memory?,
    bar2 : slop_os.Memory?,
    bar3 : slop_os.Memory?,
    bar4 : slop_os.Memory?,
    bar5 : slop_os.Memory?,
    domain : slop_os.DmaDomain,
    clients : os.Listener[block.Block]
) -> int {
    startup :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.domain = domain
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    if bars[0] == 0 {
        return 2
    }
    driver.registers = bars[0]
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER)

    // The queues, Identify's page and the slots' PRP lists
    bytes :: MEMORY_PAGES * PAGE
    memory :: slop_os.dma_memory_create(domain, startup.budget, bytes, 0) or_return 3
    pages :: runtime.reserve_addresses(cast[usize](bytes)) or_return 3
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, startup.space, pages, 0, bytes, read_write) or_return 3
    driver.memory = pages
    driver.memory_device = slop_os.memory_device_address(memory) or_return 3

    capabilities :: read_u64(driver, CAP)
    driver.stride = cast[u64](4) << ((capabilities >> 32) & 0xf)
    // CAP.TO, in 500 ms units, at most what SPINS allows
    if !start_controller(driver) {
        return 4
    }
    if !identify(driver) {
        return 5
    }

    driver.port = slop_os.port_create(startup.budget) or_return 6
    _ = service_kit.watch_stop(driver.port)
    msix := pci.find_msix(config_at, bars) or_return 7
    irq :: slop_os.irq_create_msi(device, startup.budget) or_return 7
    message :: slop_os.irq_message(irq) or_return 7
    if !pci.set_msix_entry(&msix, 0, message.address, message.data) {
        return 7
    }
    pci.enable_msix(config_at, &msix)
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent)
        or_return 7
    if !create_io_queues(driver) {
        return 5
    }

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    runtime.log_info(
        "serving % blocks, % bytes each on the namespace%",
        driver.block_count,
        driver.per_block * block.BLOCK_BYTES,
        if driver.flushes { ", with a write cache" } else { "" }
    )
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(driver, i, &into)
            i += 1
        }
        while i < driver.clients.count
        finish(driver)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Stop the controller, set its admin queues, and start it again (§3.5.1).
 *
 * @param driver The driver, whose admin queues are set from its memory.
 * @return True once CSTS.RDY says it's started; false if it didn't stop or start within SPINS polls, or says it failed.
 */
start_controller :: fn(driver : ptr[mut Driver]) -> bool {
    write_u32(driver, CC, read_u32(driver, CC) & ~CC_ENABLE)
    if !wait_ready(driver, false) {
        return false
    }
    driver.admin_submissions = make_queue(driver, ADMIN_SUBMISSIONS_PAGE, 0, false)
    driver.admin_completions = make_queue(driver, ADMIN_COMPLETIONS_PAGE, 0, true)
    write_u32(driver, AQA, ((QUEUE_ENTRIES - 1) << 16) | (QUEUE_ENTRIES - 1))
    write_u64(driver, ASQ, driver.admin_submissions.device)
    write_u64(driver, ACQ, driver.admin_completions.device)
    write_u32(driver, CC, CC_ENTRY_SIZES | CC_ENABLE)
    return wait_ready(driver, true)
}

/**
 * Wait for CSTS.RDY to be what's wanted.
 *
 * @param driver The driver, whose registers are read.
 * @param ready Whether it's waited to say it's started, or stopped.
 * @return True once it is; false after SPINS polls, or once CSTS.CFS says the controller failed.
 */
wait_ready :: fn(driver : ptr[Driver], ready : bool) -> bool {
    for spin in 0..<SPINS {
        status :: read_u32(driver, CSTS)
        if status == ~cast[u32](0) || (ready && status & CSTS_FATAL != 0) {
            return false
        }
        if (status & CSTS_READY != 0) == ready {
            return true
        }
        intrinsics.spin_hint()
    }
    return false
}

/**
 * Make a queue's state, its entries in the driver's memory.
 *
 * @param driver The driver, for its memory and doorbells.
 * @param page Which of its memory's pages the entries are in.
 * @param id The queue's ID, 0 for the admin queues.
 * @param completions Whether it's a completion queue, whose doorbell is its head's, or a submission queue.
 * @return The queue, its index 0 and a completion queue's phase 1.
 */
make_queue :: fn(driver : ptr[Driver], page : u64, id : u16, completions : bool) -> Queue {
    side :: if completions { cast[u64](1) } else { cast[u64](0) }
    doorbell :: DOORBELLS + (2 * cast[u64](id) + side) * driver.stride
    return Queue.{
        entries = driver.memory + page * PAGE,
        device = driver.memory_device + page * PAGE,
        index = 0,
        phase = 1,
        doorbell = driver.registers + doorbell,
    }
}

/**
 * Identify the controller, for its write cache, and the namespace, for its size and block size.
 *
 * @param driver The driver, whose block_count, per_block and flushes are set.
 * @return True if both were identified and the namespace has blocks no smaller than BLOCK_BYTES; false otherwise.
 */
identify :: fn(driver : ptr[mut Driver]) -> bool {
    data :: driver.memory + IDENTIFY_PAGE * PAGE
    data_device :: driver.memory_device + IDENTIFY_PAGE * PAGE
    if !admin(driver, ADMIN_IDENTIFY, 0, data_device, IDENTIFY_CONTROLLER, 0) {
        return false
    }
    // VWC, byte 525: bit 0, a volatile write cache
    driver.flushes = intrinsics.volatile_load_u8(cast[ptr[u8]](data + 525)) & 1 != 0
    if !admin(driver, ADMIN_IDENTIFY, NAMESPACE, data_device, IDENTIFY_NAMESPACE, 0) {
        return false
    }
    // NSZE (bytes 0 to 7), FLBAS (byte 26, its format in bits 3:0) and that LBA format (from byte 128, 4 bytes each,
    // its LBADS, the block size's log 2, in bits 23:16)
    blocks :: intrinsics.volatile_load_u64(cast[ptr[u64]](data))
    format :: cast[u64](intrinsics.volatile_load_u8(cast[ptr[u8]](data + 26)) & 0xf)
    shift :: (intrinsics.volatile_load_u32(cast[ptr[u32]](data + 128 + format * 4)) >> 16) & 0xff
    if blocks == 0 || shift < 9 || shift > 16 {
        return false
    }
    driver.per_block = cast[u64](1) << cast[u64](shift - 9)
    driver.block_count = blocks * driver.per_block
    return true
}

/**
 * Make the I/O completion queue, its interrupt MSI-X entry 0, and the I/O submission queue sending to it.
 *
 * @param driver The driver, whose I/O queues are set.
 * @return True if the controller made both; false if an admin command failed.
 */
create_io_queues :: fn(driver : ptr[mut Driver]) -> bool {
    driver.io_completions = make_queue(driver, IO_COMPLETIONS_PAGE, IO_QUEUE, true)
    driver.io_submissions = make_queue(driver, IO_SUBMISSIONS_PAGE, IO_QUEUE, false)
    size :: (QUEUE_ENTRIES - 1) << 16
    // CDW11: physically contiguous (bit 0), interrupts on (bit 1), vector 0 (bits 31:16)
    if !admin(driver, ADMIN_CREATE_COMPLETION, 0, driver.io_completions.device, size | cast[u32](IO_QUEUE), 0b11) {
        return false
    }
    // CDW11: physically contiguous, the completion queue it sends to (bits 31:16)
    return admin(
        driver, ADMIN_CREATE_SUBMISSION, 0, driver.io_submissions.device, size | cast[u32](IO_QUEUE),
        (cast[u32](IO_QUEUE) << 16) | 1
    )
}

/**
 * Run an admin command and wait for it, polling the admin completion queue.
 *
 * @param driver The driver, whose admin queues are used.
 * @param opcode The command's opcode.
 * @param namespace The namespace it's about, or 0.
 * @param prp1 Its data's or queue's address to the controller, one page.
 * @param dword10 Its CDW10.
 * @param dword11 Its CDW11.
 * @return True if it completed with a success status within SPINS polls.
 */
admin :: fn(driver : ptr[mut Driver], opcode : u8, namespace : u32, prp1 : u64, dword10 : u32, dword11 : u32) -> bool {
    command := Command.{}
    command.dword0 = cast[u32le](cast[u32](opcode))
    command.namespace = cast[u32le](namespace)
    command.prp1 = cast[u64le](prp1)
    command.dword10 = cast[u32le](dword10)
    command.dword11 = cast[u32le](dword11)
    submit(&driver.admin_submissions, &command)
    for spin in 0..<SPINS {
        match take_completion(&driver.admin_completions) {
            case Some(done) => return status_of(done) == 0
            case None => intrinsics.spin_hint()
        }
    }
    return false
}

/**
 * Put a command on a submission queue and ring its doorbell.
 *
 * @param queue The submission queue, whose tail moves past the command; the caller keeps fewer than QUEUE_ENTRIES
 *     in flight on it.
 * @param command The command.
 */
submit :: fn(queue : ptr[mut Queue], command : ptr[Command]) {
    at :: queue.entries + cast[u64](queue.index) * SUBMISSION_BYTES
    cast[ptr[mut Command]](at)^ = command^
    queue.index = (queue.index + 1) % QUEUE_ENTRIES
    driver_kit.before_device_write()
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](queue.doorbell), queue.index)
}

/**
 * Take the next completion the controller has written, if there is one, and ring the queue's head doorbell.
 *
 * @param queue The completion queue, whose head moves past it, and whose phase flips as it wraps.
 * @return The completion, copied; null if the next entry's phase tag isn't the current phase yet.
 */
take_completion :: fn(queue : ptr[mut Queue]) -> Completion? {
    at :: queue.entries + cast[u64](queue.index) * COMPLETION_BYTES
    status :: intrinsics.volatile_load_u32(cast[ptr[u32]](at + 12))
    if (status >> 16) & 1 != queue.phase {
        return null
    }
    intrinsics.fence_acquire()
    taken :: cast[ptr[Completion]](at)^
    queue.index += 1
    if queue.index == QUEUE_ENTRIES {
        queue.index = 0
        queue.phase = queue.phase ~ 1
    }
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](queue.doorbell), queue.index)
    return taken
}

/**
 * A completion's status: its status code type and code, without its phase tag.
 *
 * @param done The completion.
 * @return 0 for success; anything else is a failure.
 */
status_of :: fn(done : Completion) -> u32 {
    return (cast[u32](done.status) >> 17) & 0x7fff
}

/**
 * Answer, or start, every request a client has sent, until there are none left, or it's gone; as virtio-blk does.
 *
 * @param driver The driver, whose slots, buffers and clients change.
 * @param index Which client, by its index; one past them, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each.
 */
serve :: fn(driver : ptr[mut Driver], index : usize, into : ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match block.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = block.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&driver.clients, index)
                // Its buffer goes with it, now or once the controller's done with what it was asked with it
                if index < driver.buffers.count {
                    driver.generations[index] += 1
                    old :: driver.buffers[index].memory
                    driver.buffers[index] = Buffer.{memory = cast[slop_os.Memory](slop_os.NO_HANDLE)}
                    release_buffer(driver, old)
                }
                return void
            }
        }
        match os.message_of[block.Request](into)^ {
            case Read(transfer) => answer(driver, end, start(driver, index, transfer, false))
            case Write(transfer) => answer(driver, end, start(driver, index, transfer, true))
            case Flush(tag) => answer(driver, end, start_flush(driver, index, tag))
            case Describe => answer(
                driver,
                end,
                .Described(
                    block.Info.{
                        block_count = driver.block_count,
                        buffer_bytes = BUFFER_BYTES,
                        read_only = false,
                        flushes = driver.flushes,
                    }
                )
            )
            case GetBuffer => answer(driver, end, buffer_for(driver, index))
            case Connect(connection) => {
                if !service_kit.add_client(&driver.clients, driver.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Send a client an answer, if there is one now; one that can't be sent is dropped.
 *
 * @param driver The driver, whose port is waited on while end's ring is full.
 * @param end The client's channel end, one the driver's clients keep.
 * @param response The answer; null for a request in flight, answered when the controller completes it.
 */
answer :: fn(driver : ptr[mut Driver], end : slop_os.Channel, response : block.Response?) {
    given :: response or_return void
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = given
    _ = block.send_response(end, driver.port, &out)
}

/**
 * Make a Finished answer.
 *
 * @param tag The client's tag, given back as it is.
 * @param status How it went.
 * @return Finished with tag and status; never null.
 */
finished :: fn(tag : u64, status : block.Status) -> block.Response? {
    return block.Response.Finished(block.Completion.{tag = tag, status = status})
}

/**
 * Send a Read or a Write to the controller: the namespace's blocks, its data the client's buffer at the transfer's
 * offset, named by PRP 1 and 2, or PRP 1 and the slot's PRP list.
 *
 * @param driver The driver, a slot of whose is taken when the command's sent.
 * @param client The asking client, by its index.
 * @param transfer The blocks, and where in the client's buffer.
 * @param writes True for a Write, false for a Read.
 * @return Null when it's sent, answered when the controller completes it; Finished now with OutOfRange for a client
 *     without a buffer, a count of 0, blocks past the disk or not on the namespace's own, bytes past the buffer, or an
 *     offset not on a 4-byte boundary, which PRP entries need; Busy with every slot taken.
 */
start :: fn(driver : ptr[mut Driver], client : usize, transfer : block.Transfer, writes : bool) -> block.Response? {
    if client >= driver.buffers.count || cast[slop_os.Handle](driver.buffers[client].memory) == slop_os.NO_HANDLE {
        return finished(transfer.tag, .OutOfRange)
    }
    bytes :: cast[u64](transfer.count) * block.BLOCK_BYTES
    if transfer.count == 0
        || transfer.first > driver.block_count
        || cast[u64](transfer.count) > driver.block_count - transfer.first
        || cast[u64](transfer.offset) > BUFFER_BYTES
        || bytes > BUFFER_BYTES - cast[u64](transfer.offset)
        || transfer.offset % 4 != 0
        || transfer.first % driver.per_block != 0
        || cast[u64](transfer.count) % driver.per_block != 0 {
        return finished(transfer.tag, .OutOfRange)
    }
    slot :: free_slot(driver) or_return finished(transfer.tag, .Busy)
    data :: driver.buffers[client].device + cast[u64](transfer.offset)
    command := Command.{}
    command.dword0 = cast[u32le](cast[u32](if writes { NVM_WRITE } else { NVM_READ }) | (cast[u32](slot) << 16))
    command.namespace = cast[u32le](NAMESPACE)
    command.prp1 = cast[u64le](data)
    command.prp2 = cast[u64le](second_prp(driver, slot, data, bytes))
    first :: transfer.first / driver.per_block
    command.dword10 = cast[u32le](cast[u32](first))
    command.dword11 = cast[u32le](cast[u32](first >> 32))
    // CDW12: the namespace's blocks, less one
    command.dword12 = cast[u32le](cast[u32](cast[u64](transfer.count) / driver.per_block - 1))
    return send_slot(driver, slot, client, transfer.tag, &command)
}

/**
 * PRP entry 2 for data at an address: nothing for one page, the second page for two, and otherwise the slot's PRP
 * list, filled with every page after the first.
 *
 * @param driver The driver, whose slot's PRP list is written.
 * @param slot The slot, below SLOTS.
 * @param data The data's address to the controller, 4-byte aligned.
 * @param bytes How many bytes, at most BUFFER_BYTES.
 * @return PRP entry 2's value.
 */
second_prp :: fn(driver : ptr[mut Driver], slot : usize, data : u64, bytes : u64) -> u64 {
    first_page :: data & ~(PAGE - 1)
    last_page :: (data + bytes - 1) & ~(PAGE - 1)
    if last_page == first_page {
        return 0
    }
    if last_page == first_page + PAGE {
        return last_page
    }
    list :: driver.memory + (PRP_LISTS_PAGE + cast[u64](slot)) * PAGE
    at := cast[u64](0)
    page := first_page + PAGE
    loop {
        if page > last_page || at >= PAGE / 8 {
            break
        }
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](list + at * 8), page)
        at += 1
        page += PAGE
    }
    return driver.memory_device + (PRP_LISTS_PAGE + cast[u64](slot)) * PAGE
}

/**
 * Send a Flush, where the controller has a write cache.
 *
 * @param driver The driver.
 * @param client The asking client, by its index.
 * @param tag The client's tag.
 * @return Null when it's sent; Finished now with Done without a write cache, whose writes are durable, or Busy with
 *     every slot taken.
 */
start_flush :: fn(driver : ptr[mut Driver], client : usize, tag : u64) -> block.Response? {
    if !driver.flushes {
        return finished(tag, .Done)
    }
    slot :: free_slot(driver) or_return finished(tag, .Busy)
    command := Command.{}
    command.dword0 = cast[u32le](cast[u32](NVM_FLUSH) | (cast[u32](slot) << 16))
    command.namespace = cast[u32le](NAMESPACE)
    return send_slot(driver, slot, client, tag, &command)
}

/**
 * Note a request in a slot and submit its command.
 *
 * @param driver The driver, whose I/O submission queue takes the command.
 * @param slot The slot, free, which is the command's identifier.
 * @param client The asking client, by its index.
 * @param tag The client's tag.
 * @param command The command.
 * @return Null, as it's answered when the controller completes it.
 */
send_slot :: fn(
    driver : ptr[mut Driver],
    slot : usize,
    client : usize,
    tag : u64,
    command : ptr[Command]
) -> block.Response? {
    if slot >= driver.slots.count {
        return finished(tag, .Busy)
    }
    generation :: if client < driver.generations.count { driver.generations[client] } else { cast[u32](0) }
    memory :: if client < driver.buffers.count { driver.buffers[client].memory } else { cast[slop_os.Memory](slop_os.NO_HANDLE) }
    driver.slots[slot] = Slot.{used = true, client = client, tag = tag, generation = generation, memory = memory}
    submit(&driver.io_submissions, command)
    return null
}

/**
 * Close a buffer its client left, unless the controller still has commands with it, the last of which closes it.
 *
 * @param driver The driver, whose slots are looked through.
 * @param memory The buffer's memory; NO_HANDLE is nothing to close.
 */
release_buffer :: fn(driver : ptr[Driver], memory : slop_os.Memory) {
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        return void
    }
    for slot in driver.slots {
        if slot.used && slot.memory == memory {
            return void
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
}

/**
 * Find a slot not in use.
 *
 * @param driver The driver.
 * @return The lowest free slot's index; null if all SLOTS are in flight.
 */
free_slot :: fn(driver : ptr[Driver]) -> usize? {
    for slot, i in driver.slots {
        if !slot.used {
            return i
        }
    }
    return null
}

/**
 * Answer every command the controller has completed to its client, Done for a success status and DeviceError
 * otherwise, and free its slot; a left client's isn't answered, and its last lets its buffer go.
 *
 * @param driver The driver, its I/O completion queue taken from and its slots freed.
 */
finish :: fn(driver : ptr[mut Driver]) {
    loop {
        done :: take_completion(&driver.io_completions) or_break
        index :: cast[usize](cast[u32](done.status) & 0xffff)
        if index >= driver.slots.count || !driver.slots[index].used {
            continue
        }
        slot :: &driver.slots[index]
        slot.used = false
        current :: slot.client < driver.generations.count && driver.generations[slot.client] == slot.generation
        if current && slot.client < driver.clients.ends.count {
            end :: driver.clients.ends[slot.client]
            if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
                answer(
                    driver,
                    end,
                    finished(slot.tag, if status_of(done) == 0 { block.Status.Done } else { block.Status.DeviceError })
                )
            }
        }
        if !current {
            release_buffer(driver, slot.memory)
        }
    }
}

/**
 * Give a client a window onto its buffer, the buffer made at its first ask; as virtio-blk does.
 *
 * @param driver The driver, whose buffer for the client is made in its DMA domain the first time.
 * @param client The asking client, by its index.
 * @return Buffer with a new window onto all of the buffer; Unsupported if the client's index is past them, or the
 *     buffer or window couldn't be made.
 */
buffer_for :: fn(driver : ptr[mut Driver], client : usize) -> block.Response? {
    startup :: slop_os.startup_block()
    if client >= driver.buffers.count {
        return block.Response.Unsupported
    }
    if cast[slop_os.Handle](driver.buffers[client].memory) == slop_os.NO_HANDLE {
        memory :: slop_os.dma_memory_create(driver.domain, startup.budget, BUFFER_BYTES, 0)
            or_return block.Response.Unsupported
        address :: slop_os.memory_device_address(memory) or_return block.Response.Unsupported
        driver.buffers[client] = Buffer.{memory = memory, device = address}
    }
    window :: slop_os.memory_create_window(driver.buffers[client].memory, startup.budget, 0, BUFFER_BYTES)
        or_return block.Response.Unsupported
    return block.Response.Buffer(window)
}

/**
 * Read a 32-bit register, BAR 0's.
 *
 * @param driver The driver, whose registers are mapped.
 * @param offset The register's offset.
 * @return Its value.
 */
read_u32 :: fn(driver : ptr[Driver], offset : u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](driver.registers + offset))
}

/**
 * Read a 64-bit register as two 32-bit reads, low then high, as the specification allows.
 *
 * @param driver The driver, whose registers are mapped.
 * @param offset The register's offset, 8-byte aligned.
 * @return Its value.
 */
read_u64 :: fn(driver : ptr[Driver], offset : u64) -> u64 {
    return cast[u64](read_u32(driver, offset)) | (cast[u64](read_u32(driver, offset + 4)) << 32)
}

/**
 * Write a 32-bit register.
 *
 * @param driver The driver, whose registers are mapped.
 * @param offset The register's offset.
 * @param value What's written.
 */
write_u32 :: fn(driver : ptr[Driver], offset : u64, value : u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](driver.registers + offset), value)
}

/**
 * Write a 64-bit register as two 32-bit writes, low then high.
 *
 * @param driver The driver, whose registers are mapped.
 * @param offset The register's offset, 8-byte aligned.
 * @param value What's written.
 */
write_u64 :: fn(driver : ptr[Driver], offset : u64, value : u64) {
    write_u32(driver, offset, cast[u32](value))
    write_u32(driver, offset + 4, cast[u32](value >> 32))
}
