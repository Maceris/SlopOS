/*
 * The storage manager (roadmap 8a, decisions/0085, 0086): it holds every disk, through connectors the supervisor gives
 * it, and starts a partition server for each through the process manager, giving it that disk's block connection and
 * nothing else. It lists each disk's partitions, and serves the storage protocol: every partition, by one index, and
 * block connections narrowed to one, which the partition server makes. A FAT partition's files (an EFI system
 * partition's, or a basic data partition's) are served by a FAT server, started the first time they're asked for with
 * a connection narrowed to that partition and nothing else (decisions/0087); each client gets a connection of its own
 * to its root. A SlopOS container's partition gets a container service, holding only that partition, and its system
 * volume a volume server, holding only a connection to the container service for that volume (decisions/0089); its
 * files are the system volume's.
 */
package storage_manager

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import dir from "std/os/slop_os"
import log_line from "../../log_line"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import partitions from "../../protocols/partitions"
import storage from "../../protocols/storage"
import service_kit from "../../service_kit"
import container from "../../protocols/container"
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
}

// A connector to a disk, which may not be given
DiskConnector :: os.Channel[connector.Connector]?

// What a partition server is given (partition_server.main).
PartitionServerGrants :: struct {
    log : slop_os.DebugLog?,
    disk : os.Channel[block.Block],
    clients : os.Listener[partitions.Partitions],
}

// A disk's partition server: the end it's spoken to on, and a port for that end.
Disk :: struct {
    end : slop_os.Channel,
    port : slop_os.Port,
}

Manager :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    disks : Disk[MAX_DISKS],
    disk_count : usize,
    partitions : storage.Partition[MAX_PARTITIONS],
    partition_count : usize,
    // Each partition's FAT server, its listener's end and a port for it, NO_HANDLE until it's started
    files : Disk[MAX_PARTITIONS],
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    fat_server_module : slop_os.Memory,
    container_service_module : slop_os.Memory,
    volume_server_module : slop_os.Memory,
    clients : service_kit.Clients,
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager], partition_server_module: slop_os.Memory,
    fat_server_module: slop_os.Memory, container_service_module: slop_os.Memory, volume_server_module: slop_os.Memory,
    disk0: os.Channel[connector.Connector]?, disk1: os.Channel[connector.Connector]?,
    disk2: os.Channel[connector.Connector]?, disk3: os.Channel[connector.Connector]?, clients: os.Listener[storage.Storage]) -> int {
    startup :: slop_os.startup_block()
    state := Manager.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), manager = manager, fat_server_module = fat_server_module,
        container_service_module = container_service_module, volume_server_module = volume_server_module}
    state.port = slop_os.port_create(startup.budget) or_return 1
    manager_port :: os.port_for(startup.budget, manager.end) or_return 1
    state.manager_port = manager_port

    // A partition server for each disk, and its partitions
    for maybe in DiskConnector.[disk0, disk1, disk2, disk3] {
        dialing :: maybe or_continue
        dial_port :: os.port_for(startup.budget, dialing.end) or_continue
        disk :: connector.dial[block.Block](dialing.end, dial_port) or_continue
        pair :: os.channel_for[partitions.Partitions](startup.budget, 0) or_continue
        grants := PartitionServerGrants.{log = duplicate_log(state.log), disk = disk, clients = os.Listener[partitions.Partitions].{end = pair.a}}
        match os.launch(manager, manager_port, "partition_server", partition_server_module, PARTITION_SERVER_BUDGET, partition_server.main, grants) {
            case Ok(launched) => {}
            case Error(error) => {
                log_line.write(state.log, "storage: no partition server for disk %: %", state.disk_count, error)
                continue
            }
        }
        if state.disk_count >= state.disks.count {
            break
        }
        server_port :: os.port_for(startup.budget, pair.b) or_continue
        index :: state.disk_count
        if index >= state.disks.count {
            break
        }
        state.disks[index] = Disk.{end = pair.b, port = server_port}
        state.disk_count = index + 1
        list_partitions(&state, index)
    }
    log_line.write(state.log, "storage: serving % partitions on % disks", state.partition_count, state.disk_count)

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
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(state.port, packets, slop_os.NO_DEADLINE)
    }
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
                log_line.write(state.log, "storage: disk % partition %: %, % blocks from %", disk, index, partitions.name_of(&described),
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
        }
        out := os.Outgoing.{}
        made :: os.begin[storage.Response](&out)
        made^ = response
        _ = storage.send_response(end, state.port, &out)
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
            return system_volume_of(state, index)
        }
        if partition.info.type_guid != ESP_TYPE && partition.info.type_guid != BASIC_DATA_TYPE {
            return null
        }
        narrowed := os.Channel[block.Block].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
        match ask(state, cast[usize](partition.disk), .Open(partition.index)) {
            case Opened(connection) => narrowed = connection
            case _ => return null
        }
        pair :: os.channel_for[dir.Dir](startup.budget, 0) or_return null
        grants := FatServerGrants.{log = duplicate_log(state.log), partition = narrowed, clients = os.Listener[dir.Dir].{end = pair.a}}
        match os.launch(state.manager, state.manager_port, "fat_server", state.fat_server_module, FAT_SERVER_BUDGET, fat_server.main, grants) {
            case Ok(launched) => {}
            case Error(error) => {
                log_line.write(state.log, "storage: no FAT server for disk % partition %: %", partition.disk, partition.index, error)
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                return null
            }
        }
        port :: os.port_for(startup.budget, pair.b) or_return null
        state.files[index] = Disk.{end = pair.b, port = port}
        log_line.write(state.log, "storage: started a FAT server for disk % partition %", partition.disk, partition.index)
    }
    server :: state.files[index]
    return dir.connect(server.end, server.port, startup.budget)
}

/*
 * The system volume's root, on a container's partition, started the first time: a container service with a connection
 * narrowed to the partition, and a volume server with a connection to it for the system volume.
 */
system_volume_of :: fn(state: ptr[mut Manager], index: usize) -> os.Channel[dir.Dir]? {
    if index >= state.partitions.count || index >= state.files.count {
        return null
    }
    startup :: slop_os.startup_block()
    partition :: state.partitions[index]
    narrowed := os.Channel[block.Block].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask(state, cast[usize](partition.disk), .Open(partition.index)) {
        case Opened(connection) => narrowed = connection
        case _ => return null
    }
    listener :: os.channel_for[container.Container](startup.budget, 0) or_return null
    grants := ContainerServiceGrants.{log = duplicate_log(state.log), partition = narrowed,
        clients = os.Listener[container.Container].{end = listener.a}}
    match os.launch(state.manager, state.manager_port, "container_service", state.container_service_module, CONTAINER_SERVICE_BUDGET,
        container_service.main, grants) {
        case Ok(launched) => {}
        case Error(error) => {
            log_line.write(state.log, "storage: no container service for disk % partition %: %", partition.disk, partition.index, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](listener.b))
            return null
        }
    }
    log_line.write(state.log, "storage: started a container service for disk % partition %", partition.disk, partition.index)
    listener_port :: os.port_for(startup.budget, listener.b) or_return null
    volume := os.Channel[container.Container].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    out := os.Outgoing.{}
    request :: os.begin[container.Request](&out)
    request^ = .OpenVolume(os.append(&out, view_of(cast[ptr[u8]](SYSTEM_VOLUME.data), SYSTEM_VOLUME.count)))
    match ask_container(listener.b, listener_port, &out) {
        case OpenedVolume(made) => volume = made
        case _ => {
            log_line.write(state.log, "storage: no % volume in the container on disk % partition %", SYSTEM_VOLUME, partition.disk,
                partition.index)
            return null
        }
    }
    pair :: os.channel_for[dir.Dir](startup.budget, 0) or_return null
    volume_grants := VolumeServerGrants.{log = duplicate_log(state.log), volume = volume, clients = os.Listener[dir.Dir].{end = pair.a}}
    match os.launch(state.manager, state.manager_port, "volume_server", state.volume_server_module, VOLUME_SERVER_BUDGET,
        volume_server.main, volume_grants) {
        case Ok(launched) => {}
        case Error(error) => {
            log_line.write(state.log, "storage: no volume server for the % volume: %", SYSTEM_VOLUME, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
    }
    port :: os.port_for(startup.budget, pair.b) or_return null
    state.files[index] = Disk.{end = pair.b, port = port}
    log_line.write(state.log, "storage: started a volume server for the % volume", SYSTEM_VOLUME)
    return dir.connect(pair.b, port, startup.budget)
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
