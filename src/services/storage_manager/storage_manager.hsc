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
 */
package storage_manager

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import dir from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import log_line from "../../log_line"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import partitions from "../../protocols/partitions"
import storage from "../../protocols/storage"
import service_kit from "../../service_kit"
import container from "../../protocols/container"
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
}

/*
 * A volume being served: the partition it's on, its name, its volume server's listener and the end the storage manager
 * speaks the volume protocol on, with a port for each, and whether it's encrypted and unlocked yet.
 */
Served :: struct {
    partition : usize,
    name : u8[VOLUME_NAME_BYTES],
    name_bytes : usize,
    root : Disk,
    control : Disk,
    encrypted : bool,
    unlocked : bool,
    // A snapshot's, "volume@snapshot", whose root is read only
    read_only : bool,
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
            return match volume_of(state, index, view_of(cast[ptr[u8]](SYSTEM_VOLUME.data), SYSTEM_VOLUME.count), u8.[], false) {
                case OpenedFiles(root) => root
                case _ => null
            }
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
    port :: os.port_for(startup.budget, listener.b) or_return null
    state.containers[index] = Disk.{end = listener.b, port = port}
    return state.containers[index]
}

// The volume being served on the partition at index with a name, if it is.
served_volume :: fn(state: ptr[mut Manager], index: usize, name: u8[]) -> ptr[mut Served]? {
    for i in 0..<state.served_count {
        if i < state.served.count {
            each :: &state.served[i]
            if each.partition == index && each.name_bytes == name.count && each.name_bytes <= each.name.count
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
    if state.served_count >= state.served.count || name.count == 0 || name.count > VOLUME_NAME_BYTES {
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
    // Whether it's encrypted, which needs its passphrase, and room for Argon2id's memory
    encrypted := false
    volume_port :: os.port_for(startup.budget, volume.end) or_return .Failed
    asking := os.Outgoing.{}
    describe :: os.begin[container.Request](&asking)
    describe^ = .Describe
    match ask_container(volume.end, volume_port, &asking) {
        case Described(described) => encrypted = described.record.cipher != 0
        case _ => {}
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](volume_port))
    if encrypted && !given {
        _ = slop_os.handle_close(cast[slop_os.Handle](volume.end))
        return .Locked
    }
    pair :: os.channel_for[dir.Dir](startup.budget, 0) or_return .Failed
    control :: os.channel_for[volume_protocol.Volume](startup.budget, 0) or_return .Failed
    volume_grants := VolumeServerGrants.{log = duplicate_log(state.log), volume = volume, clients = os.Listener[dir.Dir].{end = pair.a},
        control = os.Listener[volume_protocol.Volume].{end = control.a}}
    budget :: if encrypted { SEALED_VOLUME_SERVER_BUDGET } else { VOLUME_SERVER_BUDGET }
    match os.launch(state.manager, state.manager_port, "volume_server", state.volume_server_module, budget, volume_server.main, volume_grants) {
        case Ok(launched) => {}
        case Error(error) => {
            log_line.write(state.log, "storage: no volume server for the % volume: %", string_of(&name[0], name.count), error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](control.b))
            return .Failed
        }
    }
    root_port :: os.port_for(startup.budget, pair.b) or_return .Failed
    control_port :: os.port_for(startup.budget, control.b) or_return .Failed
    slot :: state.served_count
    if slot >= state.served.count {
        return .Failed
    }
    served := Served.{partition = index, name_bytes = name.count, root = Disk.{end = pair.b, port = root_port},
        control = Disk.{end = control.b, port = control_port}, encrypted = encrypted, read_only = is_snapshot(name)}
    for byte, i in name {
        if i < served.name.count {
            served.name[i] = byte
        }
    }
    state.served[slot] = served
    state.served_count = slot + 1
    log_line.write(state.log, "storage: started a volume server for the % volume%", string_of(&name[0], name.count),
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
        case Snapshot(info) => match answer {
            case Some(reply) => .Snapshot(container.SnapshotInfo.{name = os.append(reply, os.items(&into, info.name)),
                transaction = info.transaction, created = info.created})
            case None => .Failed
        }
        case _ => .Failed
    }
}
