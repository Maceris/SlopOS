/*
 * The storage manager (roadmap 8a, decisions/0085, 0086): it holds every disk, through connectors the supervisor gives
 * it, and starts a partition server for each through the process manager, giving it that disk's block connection and
 * nothing else. It lists each disk's partitions, and serves the storage protocol: every partition, by one index, and
 * block connections narrowed to one, which the partition server makes. A FAT partition's files (an EFI system
 * partition's, or a basic data partition's) are served by a FAT server, started the first time they're asked for with
 * a connection narrowed to that partition and nothing else (decisions/0087); each client gets a connection of its own
 * to its root. A SlopOS container's partition gets a container service, holding only that partition, and its system
 * volume a volume server, holding only a connection to the container service for that volume (decisions/0089); its
 * files are the system volume's. Any of a container's volumes is served by name, the same way; an encrypted one's
 * volume server is given room for Argon2id and the passphrase it's opened with, which it unwraps the volume's keys with
 * and checks each time it's opened again (roadmap 8e). The keys never leave it.
 *
 * Stored links (roadmap 8f): each volume server has a connection of its own here, the links protocol, so what it asks
 * is known to be its volume's. A grant it claimed is issued to its volume by the volume the grant is from, and a link
 * it holds is opened by the volume the link leads into, which checks what it issued; the connection opened goes back
 * to the volume server that asked. A link leads only into a volume being served, unlocked, and not into its own.
 */
package storage_manager

import runtime from "base"
import log_line from "../../log_line"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import dir from "std/os/slop_os"
import grant from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import partitions from "../../protocols/partitions"
import storage from "../../protocols/storage"
import service_kit from "../../service_kit"
import container from "../../protocols/container"
import links from "../../protocols/links"
import volume_protocol from "../../protocols/volume"
import container_service from "../container_service"
import fat_server from "../fat_server"
import partition_server from "../partition_server"
import volume_server from "../volume_server"

MAX_DISKS :: 4
MAX_PARTITIONS :: 32
PARTITION_SERVER_BUDGET : u64 : 2 * 1024 * 1024
FAT_SERVER_BUDGET : u64 : 2 * 1024 * 1024
CONTAINER_SERVICE_BUDGET : u64 : 4 * 1024 * 1024
VOLUME_SERVER_BUDGET : u64 : 6 * 1024 * 1024
// An encrypted volume's: Argon2id's memory, for a passphrase whose parameters ask for up to 8 MiB, on top
SEALED_VOLUME_SERVER_BUDGET : u64 : VOLUME_SERVER_BUDGET + 8 * 1024 * 1024
MAX_VOLUMES :: 8
VOLUME_NAME_BYTES :: 64
// The keys volume servers' links connections are bound to the port with, after the clients'
LINKS_KEY : u64 : 1000
// The keys the servers it starts are watched under from their launch: partition servers by disk, FAT servers and
// container services by partition, volume servers by their place in served
PARTITION_SERVER_KEY : u64 : 2000
FAT_SERVER_KEY : u64 : 3000
CONTAINER_KEY : u64 : 4000
VOLUME_KEY : u64 : 5000
// How often a server is started again in RESTART_WINDOW before it's left ended (decisions/0077)
RESTARTS : u32 : 3
RESTART_WINDOW : u64 : 60_000_000_000
// A SlopOS container's partition type, "SLOPOS CONTAINER" in ASCII, and the volume its files are (decisions/0088, 0089)
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]
SYSTEM_VOLUME :: "system"
// The GPT types whose partitions hold FAT volumes, as their bytes are on the disk: the EFI system partition
// (C12A7328-F81F-11D2-BA4B-00A0C93EC93B) and a basic data partition (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
ESP_TYPE :: u8.[0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b]
BASIC_DATA_TYPE :: u8.[0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7]

// What a FAT server is given (fat_server.main).
FatServerGrants :: struct {
    log : slop_os.DebugLog?,
    partition : os.Channel[block.Block],
    clients : os.Listener[dir.Dir],
}

// What a container service is given (container_service.main).
ContainerServiceGrants :: struct {
    log : slop_os.DebugLog?,
    partition : os.Channel[block.Block],
    clients : os.Listener[container.Container],
}

// What a volume server is given (volume_server.main).
VolumeServerGrants :: struct {
    log : slop_os.DebugLog?,
    volume : os.Channel[container.Container],
    clients : os.Listener[dir.Dir],
    control : os.Listener[volume_protocol.Volume],
    stored_links : os.Channel[links.Links],
}

/*
 * A volume being served: the partition it's on, its name, its volume server's listener and the end the storage manager
 * speaks the volume protocol on, with a port for each, and whether it's encrypted and unlocked yet; the volume by its
 * container and ID, and the end its volume server's stored links are asked on.
 */
Served :: struct {
    partition : usize,
    container : u8[16],
    id : u64,
    links : slop_os.Channel,
    name : u8[VOLUME_NAME_BYTES],
    name_bytes : usize,
    root : Disk,
    control : Disk,
    encrypted : bool,
    unlocked : bool,
    // A snapshot's, "volume@snapshot", whose root is read only
    read_only : bool,
    // Its volume server's process; and whether it's ended, so another can be served in its place
    running : Running,
    gone : bool,
}

/*
 * A server the storage manager started: its process and its budget, which it keeps until the server ends, so what it
 * had comes back then; and how many times it's been started again in the window since restarts_since, and whether it
 * has ended since it was last started.
 */
Running :: struct {
    process : slop_os.Process,
    budget : slop_os.MemoryBudget,
    restarts : u32,
    restarts_since : u64,
    ended : bool,
}

// A connector to a disk, which may not be given
DiskConnector :: os.Channel[connector.Connector]?

// What a partition server is given (partition_server.main).
PartitionServerGrants :: struct {
    log : slop_os.DebugLog?,
    disk : os.Channel[block.Block],
    clients : os.Listener[partitions.Partitions],
    // The kernel's command line, for faulty_block, which a robustness build reads (decisions/0112)
    command_line : slop_os.Memory?,
}

// A disk's partition server: the end it's spoken to on, and a port for that end.
Disk :: struct {
    end : slop_os.Channel,
    port : slop_os.Port,
}

Manager :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // The kernel's command line, if it was given, for the partition servers
    command_line : slop_os.Memory,
    disks : Disk[MAX_DISKS],
    disk_count : usize,
    // Each disk's connector, kept to dial its driver again for a restarted partition server, and its partition server
    connectors : Disk[MAX_DISKS],
    disk_running : Running[MAX_DISKS],
    partition_server_module : slop_os.Memory,
    // Each partition's FAT server and container service, as files and containers have their listeners
    files_running : Running[MAX_PARTITIONS],
    containers_running : Running[MAX_PARTITIONS],
    partitions : storage.Partition[MAX_PARTITIONS],
    partition_count : usize,
    // Each partition's FAT server, its listener's end and a port for it, NO_HANDLE until it's started
    files : Disk[MAX_PARTITIONS],
    // Each container's service, the same way, and the volumes being served
    containers : Disk[MAX_PARTITIONS],
    served : Served[MAX_VOLUMES],
    served_count : usize,
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    fat_server_module : slop_os.Memory,
    container_service_module : slop_os.Memory,
    volume_server_module : slop_os.Memory,
    clients : service_kit.Clients,
    // test_storage_restart on the kernel's command line: the first disk's partition server killed once it's listed its
    // partitions, and TestRestart taken
    test_restart : bool,
    // How many times a partition server was started, which a test waits on; and whether a wait took the port's packets
    // meant for the main loop, whose clients are read again before it waits
    partition_server_starts : u64,
    serve_again : bool,
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager], partition_server_module: slop_os.Memory,
    fat_server_module: slop_os.Memory, container_service_module: slop_os.Memory, volume_server_module: slop_os.Memory,
    disk0: os.Channel[connector.Connector]?, disk1: os.Channel[connector.Connector]?,
    disk2: os.Channel[connector.Connector]?, disk3: os.Channel[connector.Connector]?, clients: os.Listener[storage.Storage],
    command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    state := Manager.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), manager = manager, fat_server_module = fat_server_module,
        container_service_module = container_service_module, volume_server_module = volume_server_module,
        partition_server_module = partition_server_module}
    match command_line {
        case Some(memory) => {
            state.test_restart = service_kit.has_word(service_kit.text_of(startup, memory) or_else "", "test_storage_restart")
            state.command_line = memory
        }
        case None => {}
    }
    state.port = slop_os.port_create(startup.budget) or_return 1
    manager_port :: os.port_for(startup.budget, manager.end) or_return 1
    state.manager_port = manager_port

    // A partition server for each disk, and its partitions
    for maybe in DiskConnector.[disk0, disk1, disk2, disk3] {
        dialing :: maybe or_continue
        dial_port :: os.port_for(startup.budget, dialing.end) or_continue
        index :: state.disk_count
        if index >= MAX_DISKS {
            break
        }
        state.connectors[index] = Disk.{end = dialing.end, port = dial_port}
        if !start_partition_server(&state, index) {
            continue
        }
        state.disk_count = index + 1
        list_partitions(&state, index)
    }
    // test_storage_restart: the first disk's partition server killed, and waited for until it's started again
    if state.test_restart && state.disk_count > 0 {
        _ = kill_and_restart(&state, 0)
    }
    runtime.log_info("serving % partitions on % disks", state.partition_count, state.disk_count)

    if !service_kit.add_client(&state.clients, state.port, clients.end) {
        return 2
    }
    into := os.Incoming.{}
    loop {
        // Clients that connect meanwhile are read in the same pass, as a channel wakes its reader only once it's found empty
        with {
            i : usize = 0
        }
        loop {
            serve_client(&state, i, &into)
            i += 1
        }
        while i < state.clients.count
        for i in 0..<state.served_count {
            serve_links(&state, i, &into)
        }
        if state.serve_again {
            state.serve_again = false
            continue
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(state.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i < cast[usize](taken) && packet.kind == .Signal && packet.key >= PARTITION_SERVER_KEY {
                ended(&state, packet.key)
            }
        }
    }
}

/*
 * For tests: a disk's partition server killed, and what arrives on the port handled until it's started again, or not
 * to be; whether it was.
 */
kill_and_restart :: fn(state: ptr[mut Manager], index: usize) -> bool {
    if index >= MAX_DISKS {
        return false
    }
    runtime.log_info("test_storage_restart: killing the partition server for disk %", index)
    starts :: state.partition_server_starts
    _ = slop_os.process_kill(state.disk_running[index].process)
    // What else arrives meanwhile is read once this is done
    state.serve_again = true
    loop {
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(state.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i < cast[usize](taken) && packet.kind == .Signal && packet.key >= PARTITION_SERVER_KEY {
                ended(state, packet.key)
            }
        }
    }
    while state.partition_server_starts == starts && !(state.disk_running[index].ended && state.disk_running[index].restarts >= RESTARTS)
    return state.partition_server_starts != starts
}

/*
 * A disk's partition server, with a block connection dialed again through its connector, watched from its launch:
 * whether it started.
 */
start_partition_server :: fn(state: ptr[mut Manager], index: usize) -> bool {
    startup :: slop_os.startup_block()
    if index >= MAX_DISKS {
        return false
    }
    dialing :: state.connectors[index]
    disk :: connector.dial[block.Block](dialing.end, dialing.port) or_return false
    pair :: os.channel_for[partitions.Partitions](startup.budget, 0) or_return false
    grants := PartitionServerGrants.{log = duplicate_log(state.log), disk = disk, clients = os.Listener[partitions.Partitions].{end = pair.a},
        command_line = command_line_copy(state)}
    match os.launch(state.manager, state.manager_port, "partition_server", state.partition_server_module, PARTITION_SERVER_BUDGET,
        partition_server.main, grants, watched(state, PARTITION_SERVER_KEY + cast[u64](index))) {
        case Ok(launched) => keep(&state.disk_running[index], launched)
        case Error(error) => {
            runtime.log_info("no partition server for disk %: %", index, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return false
        }
    }
    server_port :: os.port_for(startup.budget, pair.b) or_return false
    state.disks[index] = Disk.{end = pair.b, port = server_port}
    state.partition_server_starts += 1
    return true
}

// A launch watched from its start under key, on the storage manager's port.
watched :: fn(state: ptr[Manager], key: u64) -> os.LaunchOptions {
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = state.port, key = key}}
    // The clock page the storage manager was given, so its servers have the wall clock too, as a FAT server's times need
    clock :: runtime.os_entry_grant("clock", "Memory", "", false)
    if clock != 0 {
        rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
        match slop_os.handle_duplicate(cast[slop_os.Handle](clock), rights) {
            case Ok(copy) => options.clock = cast[slop_os.Memory](copy)
            case Error(error) => {}
        }
    }
    return options
}

// What a launch gave, kept while the server runs.
keep :: fn(running: ptr[mut Running], launched: os.Launched) {
    running.process = launched.process
    running.budget = launched.budget
    running.ended = false
}

// A server that ended let go of: its process's and its budget's handles closed, so its budget comes back.
let_go :: fn(running: ptr[mut Running]) {
    for each in slop_os.Handle.[cast[slop_os.Handle](running.process), cast[slop_os.Handle](running.budget)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
    running.process = cast[slop_os.Process](slop_os.NO_HANDLE)
    running.budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    running.ended = true
}

// A server that's running killed, so its end tears it down.
kill_running :: fn(running: ptr[Running]) {
    if cast[slop_os.Handle](running.process) != slop_os.NO_HANDLE {
        _ = slop_os.process_kill(running.process)
    }
}

/*
 * Whether a server that ended may be started again: up to RESTARTS times in RESTART_WINDOW, as the supervisor starts
 * its drivers again (decisions/0077). One that hasn't ended may always be started.
 */
may_start :: fn(running: ptr[mut Running]) -> bool {
    if !running.ended {
        return true
    }
    now :: slop_os.clock_monotonic() or_else 0
    if now - running.restarts_since > RESTART_WINDOW {
        running.restarts = 0
        running.restarts_since = now
    }
    if running.restarts >= RESTARTS {
        return false
    }
    running.restarts += 1
    return true
}

/*
 * A server it started has ended, by its key. A partition server is started again at once, once everything served from
 * its disk is killed, since each holds a connection it narrowed; a FAT server, a container service or a volume server
 * is let go, and started again the next time it's asked for. A container service's volume servers go with it, and an
 * encrypted volume served again is locked until its passphrase is given again.
 */
ended :: fn(state: ptr[mut Manager], key: u64) {
    _ = slop_os.port_unbind(state.port, key)
    if key >= VOLUME_KEY {
        slot :: cast[usize](key - VOLUME_KEY)
        if slot < state.served_count && slot < state.served.count {
            volume_gone(state, slot)
        }
        return void
    }
    if key >= CONTAINER_KEY {
        container_gone(state, cast[usize](key - CONTAINER_KEY))
        return void
    }
    if key >= FAT_SERVER_KEY {
        files_gone(state, cast[usize](key - FAT_SERVER_KEY))
        return void
    }
    index :: cast[usize](key - PARTITION_SERVER_KEY)
    if index >= MAX_DISKS {
        return void
    }
    let_go(&state.disk_running[index])
    close_disk(&state.disks[index])
    runtime.log_info("the partition server for disk % ended", index)
    // What's served from its partitions held connections it narrowed: gone now, so a client asking again meanwhile
    // finds nothing it was served before, and has it started again
    for partition, i in state.partitions {
        if i < state.partition_count && cast[usize](partition.disk) == index && i < MAX_PARTITIONS {
            if cast[slop_os.Handle](state.files_running[i].process) != slop_os.NO_HANDLE {
                _ = slop_os.port_unbind(state.port, FAT_SERVER_KEY + cast[u64](i))
                kill_running(&state.files_running[i])
                files_gone(state, i)
            }
            if cast[slop_os.Handle](state.containers_running[i].process) != slop_os.NO_HANDLE {
                _ = slop_os.port_unbind(state.port, CONTAINER_KEY + cast[u64](i))
                kill_running(&state.containers_running[i])
                container_gone(state, i)
            }
        }
    }
    if may_start(&state.disk_running[index]) && start_partition_server(state, index) {
        runtime.log_info("restarted the partition server for disk %", index)
    }
    else {
        runtime.log_info("the partition server for disk % isn't started again", index)
    }
}

// A FAT server that ended, or was killed: let go of, and its slot freed for the next request to start another.
files_gone :: fn(state: ptr[mut Manager], index: usize) {
    if index >= MAX_PARTITIONS {
        return void
    }
    let_go(&state.files_running[index])
    close_disk(&state.files[index])
    runtime.log_info("the FAT server for partition % ended", index)
}

// A container service that ended, or was killed, and its volume servers with it.
container_gone :: fn(state: ptr[mut Manager], index: usize) {
    if index >= MAX_PARTITIONS {
        return void
    }
    let_go(&state.containers_running[index])
    close_disk(&state.containers[index])
    runtime.log_info("the container service for partition % ended", index)
    kill_volumes(state, index)
}

// Every volume server serving a volume of the partition at index killed, and gone now.
kill_volumes :: fn(state: ptr[mut Manager], index: usize) {
    for i in 0..<state.served_count {
        if i < state.served.count && state.served[i].partition == index && !state.served[i].gone {
            _ = slop_os.port_unbind(state.port, VOLUME_KEY + cast[u64](i))
            kill_running(&state.served[i].running)
            volume_gone(state, i)
        }
    }
}

// A volume server that ended: its ends closed, and its place in served free for the next.
volume_gone :: fn(state: ptr[mut Manager], slot: usize) {
    served :: &state.served[slot % MAX_VOLUMES]
    let_go(&served.running)
    close_disk(&served.root)
    close_disk(&served.control)
    if cast[slop_os.Handle](served.links) != slop_os.NO_HANDLE {
        _ = slop_os.port_unbind(state.port, LINKS_KEY + cast[u64](slot))
        _ = slop_os.handle_close(cast[slop_os.Handle](served.links))
        served.links = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
    served.gone = true
    served.unlocked = false
    count :: if served.name_bytes < served.name.count { served.name_bytes } else { served.name.count }
    runtime.log_info("the volume server for the % volume ended", if count > 0 { string_of(&served.name[0], count) } else { "" })
}

close_disk :: fn(disk: ptr[mut Disk]) {
    for each in slop_os.Handle.[cast[slop_os.Handle](disk.end), cast[slop_os.Handle](disk.port)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
    disk.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    disk.port = cast[slop_os.Port](slop_os.NO_HANDLE)
}

// A disk's partitions, from 0 until its partition server has no more, each logged.
list_partitions :: fn(state: ptr[mut Manager], disk: usize) {
    for index in 0..<cast[u32](MAX_PARTITIONS) {
        match ask(state, disk, .Describe(index)) {
            case Described(info) => {
                slot :: state.partition_count
                if slot >= state.partitions.count {
                    return void
                }
                state.partitions[slot] = storage.Partition.{disk = cast[u32](disk), index = index, info = info}
                state.partition_count = slot + 1
                described := info
                runtime.log_info("disk % partition %: %, % blocks from %", disk, index, partitions.name_of(&described),
                    info.count, info.first)
            }
            case _ => return void
        }
    }
}

// A client's requests, until it has none.
serve_client :: fn(state: ptr[mut Manager], index: usize, into: ptr[mut os.Incoming]) {
    if index >= state.clients.ends.count {
        return void
    }
    end :: state.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match storage.receive_request(end, state.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = storage.answer_unsupported(end, state.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(&state.clients, index)
                return void
            }
        }
        response : storage.Response = .NoPartition
        // Begun first, so a snapshot's name can go in it
        reply := os.Outgoing.{}
        made :: os.begin[storage.Response](&reply)
        match os.message_of[storage.Request](into)^ {
            case Describe(which) => {
                if cast[usize](which) < state.partition_count && cast[usize](which) < state.partitions.count {
                    response = .Described(state.partitions[cast[usize](which)])
                }
            }
            case Open(which) => {
                if cast[usize](which) < state.partition_count && cast[usize](which) < state.partitions.count {
                    partition :: state.partitions[cast[usize](which)]
                    match ask(state, cast[usize](partition.disk), .Open(partition.index)) {
                        case Opened(connection) => response = .Opened(connection)
                        case _ => {}
                    }
                }
            }
            case OpenVolume(at) => {
                if cast[usize](at.partition) < state.partition_count && cast[usize](at.partition) < state.partitions.count
                    && state.partitions[cast[usize](at.partition)].info.type_guid == CONTAINER_TYPE {
                    passphrase :: os.items(into, at.passphrase)
                    response = volume_of(state, cast[usize](at.partition), os.items(into, at.name), passphrase, passphrase.count > 0)
                }
            }
            case Rotate(named) => {
                if cast[usize](named.partition) < state.partition_count {
                    response = rotate(state, cast[usize](named.partition), os.items(into, named.name))
                }
            }
            case TakeSnapshot(of) => {
                if is_container(state, of.partition) {
                    response = take_snapshot(state, cast[usize](of.partition), os.items(into, of.volume), os.items(into, of.snapshot), of.now)
                }
            }
            case DeleteSnapshot(of) => {
                if is_container(state, of.partition) {
                    out := os.Outgoing.{}
                    request :: os.begin[container.Request](&out)
                    request^ = .DeleteSnapshot(container.SnapshotNamed.{volume = os.append(&out, os.items(into, of.volume)),
                        snapshot = os.append(&out, os.items(into, of.snapshot))})
                    response = to_container(state, cast[usize](of.partition), &out, null)
                }
            }
            case SnapshotAt(at) => {
                if is_container(state, at.partition) {
                    out := os.Outgoing.{}
                    request :: os.begin[container.Request](&out)
                    request^ = .SnapshotAt(container.SnapshotIndex.{volume = os.append(&out, os.items(into, at.volume)), index = at.index})
                    response = to_container(state, cast[usize](at.partition), &out, &reply)
                }
            }
            case SetQuota(quota) => {
                if is_container(state, quota.partition) {
                    out := os.Outgoing.{}
                    request :: os.begin[container.Request](&out)
                    request^ = .SetQuota(container.QuotaOf.{volume = os.append(&out, os.items(into, quota.volume)), blocks = quota.blocks})
                    response = to_container(state, cast[usize](quota.partition), &out, null)
                }
            }
            case Usage(named) => {
                if is_container(state, named.partition) {
                    out := os.Outgoing.{}
                    request :: os.begin[container.Request](&out)
                    request^ = .Usage(os.append(&out, os.items(into, named.name)))
                    response = to_container(state, cast[usize](named.partition), &out, null)
                }
            }
            case Clone(of) => {
                if is_container(state, of.partition) {
                    out := os.Outgoing.{}
                    request :: os.begin[container.Request](&out)
                    request^ = .Clone(container.Cloning.{volume = os.append(&out, os.items(into, of.volume)),
                        snapshot = os.append(&out, os.items(into, of.snapshot)), name = os.append(&out, os.items(into, of.name)), now = of.now})
                    response = to_container(state, cast[usize](of.partition), &out, null)
                }
            }
            case OpenFiles(which) => {
                if cast[usize](which) < state.partition_count && cast[usize](which) < state.partitions.count {
                    match files_of(state, cast[usize](which)) {
                        case Some(root) => response = .OpenedFiles(root)
                        case None => response = .NoFiles
                    }
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(&state.clients, state.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
            case TestRestart(disk) => {
                if !state.test_restart {
                    response = .Unsupported
                }
                else if cast[usize](disk) < state.disk_count && kill_and_restart(state, cast[usize](disk)) {
                    response = .Done
                }
            }
        }
        made^ = response
        _ = storage.send_response(end, state.port, &reply)
    }
}

/*
 * A connection to the root of the FAT volume on a partition, from its FAT server, started the first time with a
 * connection narrowed to the partition: null for a partition of another kind, or if the server can't be started.
 */
files_of :: fn(state: ptr[mut Manager], index: usize) -> os.Channel[dir.Dir]? {
    if index >= state.partitions.count || index >= state.files.count {
        return null
    }
    startup :: slop_os.startup_block()
    if cast[slop_os.Handle](state.files[index].end) == slop_os.NO_HANDLE {
        partition :: state.partitions[index]
        if partition.info.type_guid == CONTAINER_TYPE {
            return match volume_of(state, index, cast[u8[]](SYSTEM_VOLUME), u8.[], false) {
                case OpenedFiles(root) => root
                case _ => null
            }
        }
        if partition.info.type_guid != ESP_TYPE && partition.info.type_guid != BASIC_DATA_TYPE {
            return null
        }
        if !may_start(&state.files_running[index]) {
            return null
        }
        narrowed := os.Channel[block.Block].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
        match ask(state, cast[usize](partition.disk), .Open(partition.index)) {
            case Opened(connection) => narrowed = connection
            case _ => return null
        }
        pair :: os.channel_for[dir.Dir](startup.budget, 0) or_return null
        grants := FatServerGrants.{log = duplicate_log(state.log), partition = narrowed, clients = os.Listener[dir.Dir].{end = pair.a}}
        match os.launch(state.manager, state.manager_port, "fat_server", state.fat_server_module, FAT_SERVER_BUDGET, fat_server.main, grants,
            watched(state, FAT_SERVER_KEY + cast[u64](index))) {
            case Ok(launched) => keep(&state.files_running[index], launched)
            case Error(error) => {
                runtime.log_info("no FAT server for disk % partition %: %", partition.disk, partition.index, error)
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                return null
            }
        }
        port :: os.port_for(startup.budget, pair.b) or_return null
        state.files[index] = Disk.{end = pair.b, port = port}
        runtime.log_info("started a FAT server for disk % partition %", partition.disk, partition.index)
    }
    server :: state.files[index]
    return dir.connect(server.end, server.port, startup.budget)
}

/*
 * A container's service, started the first time with a connection narrowed to its partition and nothing else: its
 * listener's end and a port for it, or null.
 */
container_of :: fn(state: ptr[mut Manager], index: usize) -> Disk? {
    if index >= state.partitions.count || index >= state.containers.count {
        return null
    }
    if cast[slop_os.Handle](state.containers[index].end) != slop_os.NO_HANDLE {
        return state.containers[index]
    }
    startup :: slop_os.startup_block()
    partition :: state.partitions[index]
    if !may_start(&state.containers_running[index]) {
        return null
    }
    narrowed := os.Channel[block.Block].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask(state, cast[usize](partition.disk), .Open(partition.index)) {
        case Opened(connection) => narrowed = connection
        case _ => return null
    }
    listener :: os.channel_for[container.Container](startup.budget, 0) or_return null
    grants := ContainerServiceGrants.{log = duplicate_log(state.log), partition = narrowed,
        clients = os.Listener[container.Container].{end = listener.a}}
    match os.launch(state.manager, state.manager_port, "container_service", state.container_service_module, CONTAINER_SERVICE_BUDGET,
        container_service.main, grants, watched(state, CONTAINER_KEY + cast[u64](index))) {
        case Ok(launched) => keep(&state.containers_running[index], launched)
        case Error(error) => {
            runtime.log_info("no container service for disk % partition %: %", partition.disk, partition.index, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](listener.b))
            return null
        }
    }
    runtime.log_info("started a container service for disk % partition %", partition.disk, partition.index)
    port :: os.port_for(startup.budget, listener.b) or_return null
    state.containers[index] = Disk.{end = listener.b, port = port}
    return state.containers[index]
}

// The volume being served on the partition at index with a name, if it is.
served_volume :: fn(state: ptr[mut Manager], index: usize, name: u8[]) -> ptr[mut Served]? {
    for i in 0..<state.served_count {
        if i < state.served.count {
            each :: &state.served[i]
            if !each.gone && each.partition == index && each.name_bytes == name.count && each.name_bytes <= each.name.count
                && same_bytes(each.name[0..<each.name_bytes], name) {
                return each
            }
        }
    }
    return null
}

same_bytes :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && byte != b[i] {
            return false
        }
    }
    return true
}

/*
 * The root of the container's volume on the partition at index named name: its volume server started the first time,
 * with a connection to the container service for that volume and nothing else, and for an encrypted volume, unlocked
 * with passphrase, which given says there is. An encrypted volume being served is opened again only with its
 * passphrase, which its volume server checks.
 */
volume_of :: fn(state: ptr[mut Manager], index: usize, name: u8[], passphrase: u8[], given: bool) -> storage.Response {
    startup :: slop_os.startup_block()
    match served_volume(state, index, name) {
        case Some(served) => {
            if served.encrypted {
                if !given {
                    return .Locked
                }
                answer :: unlock(served, passphrase)
                if answer != .Unlocked {
                    return if answer == .WrongKey { .WrongKey } else { .Failed }
                }
                served.unlocked = true
            }
            return root_of(served)
        }
        case None => {}
    }
    // A place a volume server that ended left, or the next
    slot := state.served_count
    for i in 0..<state.served_count {
        if i < state.served.count && state.served[i].gone {
            slot = i
            break
        }
    }
    if slot >= state.served.count || name.count == 0 || name.count > VOLUME_NAME_BYTES {
        return .Failed
    }
    service :: container_of(state, index) or_return .Failed
    volume := os.Channel[container.Container].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    out := os.Outgoing.{}
    request :: os.begin[container.Request](&out)
    request^ = .OpenVolume(os.append(&out, name))
    match ask_container(service.end, service.port, &out) {
        case OpenedVolume(made) => volume = made
        case _ => return .NoVolume
    }
    // Whether it's encrypted, which needs its passphrase, and room for Argon2id's memory; and which volume it is
    encrypted := false
    identity := container.Described.{}
    volume_port :: os.port_for(startup.budget, volume.end) or_return .Failed
    asking := os.Outgoing.{}
    describe :: os.begin[container.Request](&asking)
    describe^ = .Describe
    match ask_container(volume.end, volume_port, &asking) {
        case Described(described) => {
            encrypted = described.record.cipher != 0
            identity = described
        }
        case _ => {}
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](volume_port))
    if encrypted && !given {
        _ = slop_os.handle_close(cast[slop_os.Handle](volume.end))
        return .Locked
    }
    pair :: os.channel_for[dir.Dir](startup.budget, 0) or_return .Failed
    control :: os.channel_for[volume_protocol.Volume](startup.budget, 0) or_return .Failed
    stored_links :: os.channel_for[links.Links](startup.budget, 0) or_return .Failed
    volume_grants := VolumeServerGrants.{log = duplicate_log(state.log), volume = volume, clients = os.Listener[dir.Dir].{end = pair.a},
        control = os.Listener[volume_protocol.Volume].{end = control.a}, stored_links = os.Channel[links.Links].{end = stored_links.a}}
    budget :: if encrypted { SEALED_VOLUME_SERVER_BUDGET } else { VOLUME_SERVER_BUDGET }
    launched_volume := Running.{}
    match os.launch(state.manager, state.manager_port, "volume_server", state.volume_server_module, budget, volume_server.main, volume_grants,
        watched(state, VOLUME_KEY + cast[u64](slot))) {
        case Ok(launched) => keep(&launched_volume, launched)
        case Error(error) => {
            runtime.log_info("no volume server for the % volume: %", string_of(&name[0], name.count), error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](control.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](stored_links.b))
            return .Failed
        }
    }
    root_port :: os.port_for(startup.budget, pair.b) or_return .Failed
    control_port :: os.port_for(startup.budget, control.b) or_return .Failed
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(state.port, cast[slop_os.Handle](stored_links.b), signals, LINKS_KEY + cast[u64](slot), .Persistent) is_error {
        return .Failed
    }
    served := Served.{partition = index, container = identity.container, id = identity.id, links = stored_links.b, name_bytes = name.count,
        root = Disk.{end = pair.b, port = root_port}, control = Disk.{end = control.b, port = control_port}, encrypted = encrypted,
        read_only = is_snapshot(name), running = launched_volume}
    for byte, i in name {
        if i < served.name.count {
            served.name[i] = byte
        }
    }
    state.served[slot] = served
    if slot == state.served_count {
        state.served_count = slot + 1
    }
    runtime.log_info("started a volume server for the % volume%", string_of(&name[0], name.count),
        if encrypted { ", encrypted" } else { "" })
    if encrypted {
        // A wrong passphrase leaves it waiting, locked, for the next
        answer :: unlock(&state.served[slot], passphrase)
        if answer != .Unlocked {
            return if answer == .WrongKey { .WrongKey } else { .Failed }
        }
        state.served[slot].unlocked = true
    }
    return root_of(&state.served[slot])
}

// Whether a name is a snapshot's, "volume@snapshot".
is_snapshot :: fn(name: u8[]) -> bool {
    for byte in name {
        if byte == cast[u8]('@') {
            return true
        }
    }
    return false
}

// A new connection to a served volume's root: a dir, or a snapshot's read_only_dir.
root_of :: fn(served: ptr[Served]) -> storage.Response {
    startup :: slop_os.startup_block()
    if served.read_only {
        root :: read_only_dir.connect(served.root.end, served.root.port, startup.budget) or_return .Failed
        return .OpenedReadOnlyFiles(root)
    }
    root :: dir.connect(served.root.end, served.root.port, startup.budget) or_return .Failed
    return .OpenedFiles(root)
}

// A served volume's server asked to unlock it, or check, with passphrase.
unlock :: fn(served: ptr[Served], passphrase: u8[]) -> volume_protocol.Response {
    out := os.Outgoing.{}
    request :: os.begin[volume_protocol.Request](&out)
    request^ = .Unlock(os.append(&out, passphrase))
    return ask_volume(served, &out)
}

// One request to a volume server, on the volume protocol, and its answer, waited for.
ask_volume :: fn(served: ptr[Served], out: ptr[mut os.Outgoing]) -> volume_protocol.Response {
    if volume_protocol.send_request(served.control.end, served.control.port, out) is_some {
        return .Failed
    }
    into := os.Incoming.{}
    loop {
        match volume_protocol.receive_response(served.control.end, served.control.port, &into, true) {
            case Received => return os.message_of[volume_protocol.Response](&into)^
            case Failed(error) => return .Failed
            case _ => continue
        }
    }
}

// A new key generation for a served, unlocked volume.
rotate :: fn(state: ptr[mut Manager], index: usize, name: u8[]) -> storage.Response {
    served :: served_volume(state, index, name) or_return .NoVolume
    if !served.encrypted {
        return .NotEncrypted
    }
    if !served.unlocked {
        return .Locked
    }
    out := os.Outgoing.{}
    request :: os.begin[volume_protocol.Request](&out)
    request^ = .Rotate
    return match ask_volume(served, &out) {
        case Rotated(generation) => .Rotated(generation)
        case NotEncrypted => .NotEncrypted
        case _ => .Failed
    }
}

// One request to a container service, sent from out, and its answer, waited for.
ask_container :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing]) -> container.Response {
    if container.send_request(end, port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match container.receive_response(end, port, &into, true) {
            case Received => return os.message_of[container.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// One request to a disk's partition server, and its answer, waited for.
ask :: fn(state: ptr[mut Manager], disk: usize, request: partitions.Request) -> partitions.Response {
    if disk >= state.disk_count || disk >= state.disks.count {
        return .Unsupported
    }
    server :: state.disks[disk]
    out := os.Outgoing.{}
    made :: os.begin[partitions.Request](&out)
    made^ = request
    if partitions.send_request(server.end, server.port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match partitions.receive_response(server.end, server.port, &into, true) {
            case Received => return os.message_of[partitions.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

duplicate_log :: fn(log: slop_os.DebugLog) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](log), rights) {
        case Ok(copy) => return cast[slop_os.DebugLog](copy)
        case Error(error) => return null
    }
}

// A read-only copy of the kernel's command line, to give a partition server, or null without one.
command_line_copy :: fn(state: ptr[Manager]) -> slop_os.Memory? {
    if cast[slop_os.Handle](state.command_line) == slop_os.NO_HANDLE {
        return null
    }
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](state.command_line), rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

// Snapshots and clones (roadmap 8e)

// Whether the partition at an index holds a SlopOS container.
is_container :: fn(state: ptr[Manager], partition: u32) -> bool {
    index :: cast[usize](partition)
    return index < state.partition_count && index < state.partitions.count && state.partitions[index].info.type_guid == CONTAINER_TYPE
}

/*
 * A snapshot of a container's volume: what its server has waiting committed first, if it's being served, so the
 * snapshot holds everything written to it so far.
 */
take_snapshot :: fn(state: ptr[mut Manager], index: usize, volume: u8[], snapshot: u8[], now: u64) -> storage.Response {
    match served_volume(state, index, volume) {
        case Some(served) => {
            if !served.encrypted || served.unlocked {
                out := os.Outgoing.{}
                request :: os.begin[volume_protocol.Request](&out)
                request^ = .Commit
                match ask_volume(served, &out) {
                    case Committed => {}
                    case _ => return .Failed
                }
            }
        }
        case None => {}
    }
    out := os.Outgoing.{}
    request :: os.begin[container.Request](&out)
    request^ = .TakeSnapshot(container.SnapshotNamed.{volume = os.append(&out, volume), snapshot = os.append(&out, snapshot), now = now})
    return to_container(state, index, &out, null)
}

/*
 * A request to a container's service, from out, and its answer as the storage protocol has it; a snapshot's name,
 * if it's one, is copied into answer, the reply being built.
 */
to_container :: fn(state: ptr[mut Manager], index: usize, out: ptr[mut os.Outgoing], answer: ptr[mut os.Outgoing]?) -> storage.Response {
    service :: container_of(state, index) or_return .Failed
    if container.send_request(service.end, service.port, out) is_some {
        return .Failed
    }
    into := os.Incoming.{}
    loop {
        match container.receive_response(service.end, service.port, &into, true) {
            case Received => break
            case Failed(error) => return .Failed
            case _ => continue
        }
    }
    return match os.message_of[container.Response](&into)^ {
        case Done => .Done
        case NoVolume => .NoVolume
        case NoSnapshot => .NoSnapshot
        case AlreadyExists => .AlreadyExists
        case InUse => .InUse
        case NoMore => .NoMore
        case Used(usage) => .Used(usage)
        case Snapshot(info) => match answer {
            case Some(reply) => .Snapshot(container.SnapshotInfo.{name = os.append(reply, os.items(&into, info.name)),
                transaction = info.transaction, created = info.created})
            case None => .Failed
        }
        case _ => .Failed
    }
}

// Stored links (roadmap 8f)

// A volume server's requests on its links connection, until it has none.
serve_links :: fn(state: ptr[mut Manager], index: usize, into: ptr[mut os.Incoming]) {
    if index >= state.served_count || index >= state.served.count {
        return void
    }
    end :: state.served[index].links
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match links.receive_request(end, state.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = links.answer_unsupported(end, state.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                state.served[index].links = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
        }
        reply := os.Outgoing.{}
        made :: os.begin[links.Response](&reply)
        match os.message_of[links.Request](into)^ {
            case Issue(claim) => made^ = issue(state, index, claim)
            case Resolve(resolving) => made^ = resolve(state, index, resolving, os.items(into, resolving.path))
        }
        _ = links.send_response(end, state.port, &reply)
    }
}

/*
 * The volume being served as container's volume id, to issue or open links: not a snapshot, and unlocked if it's
 * encrypted; null if there's none, which a link calls Unavailable.
 */
linked_volume :: fn(state: ptr[mut Manager], container: u8[16], id: u64) -> ptr[mut Served]? {
    for i in 0..<state.served_count {
        if i < state.served.count {
            each :: &state.served[i]
            if !each.gone && each.id == id && each.container == container && !each.read_only && (!each.encrypted || each.unlocked) {
                return each
            }
        }
    }
    return null
}

// A grant the volume served at index claimed, issued to it by the volume the grant is from.
issue :: fn(state: ptr[mut Manager], index: usize, claim: grant.Claim) -> links.Response {
    if index >= state.served.count {
        return .Failed(.Unavailable)
    }
    asking :: &state.served[index]
    // A link within one volume, which its own names already reach
    if claim.container == asking.container && claim.volume == asking.id {
        return .Failed(.InvalidPath)
    }
    target :: linked_volume(state, claim.container, claim.volume) or_return .Failed(.Unavailable)
    out := os.Outgoing.{}
    request :: os.begin[volume_protocol.Request](&out)
    request^ = .IssueTo(volume_protocol.IssueTo.{ticket = claim.ticket, recipient_container = asking.container, recipient = asking.id})
    return match ask_volume(target, &out) {
        case Issued(number) => links.Response.Issued(number)
        case Refused(error) => links.Response.Failed(error)
        case _ => links.Response.Failed(.Unavailable)
    }
}

// What a link held by the volume served at index leads to, and path beneath it, opened by the volume it leads into.
resolve :: fn(state: ptr[mut Manager], index: usize, resolving: links.Resolving, path: u8[]) -> links.Response {
    if index >= state.served.count {
        return .Failed(.Unavailable)
    }
    asking :: &state.served[index]
    if resolving.container == asking.container && resolving.volume == asking.id {
        return .Failed(.Unavailable)
    }
    target :: linked_volume(state, resolving.container, resolving.volume) or_return .Failed(.Unavailable)
    out := os.Outgoing.{}
    request :: os.begin[volume_protocol.Request](&out)
    request^ = .OpenIssued(volume_protocol.OpenIssued.{number = resolving.number, recipient_container = asking.container,
        recipient = asking.id, path = os.append(&out, path), opening = resolving.opening})
    return match ask_volume(target, &out) {
        case OpenedFile(made) => links.Response.OpenedFile(made)
        case OpenedReadOnlyFile(made) => links.Response.OpenedReadOnlyFile(made)
        case OpenedDirectory(made) => links.Response.OpenedDirectory(made)
        case OpenedReadOnlyDirectory(made) => links.Response.OpenedReadOnlyDirectory(made)
        case Refused(error) => links.Response.Failed(error)
        case _ => links.Response.Failed(.Unavailable)
    }
}
