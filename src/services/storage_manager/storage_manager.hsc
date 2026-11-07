/**
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
 * to the volume server that asked. A link leads only into a volume being served, unlocked; into its own too, as the
 * powerbox keeps a grant of a file in the home it's kept in (decisions/0158), which the volume server answers while it
 * waits, as it does any other.
 *
 * Automatic snapshots (decisions/0179): every hour, each writable volume served, unlocked, gets a snapshot, and those
 * older than a day, its automatic ones and those a dir's Snapshot took, are deleted (automatic_snapshots).
 */
package storage_manager

import runtime from "base"
import log_line from "../../log_line"
import strings from "std"
import time from "std"
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
import service_kit from "../../libraries/service_kit"
import container from "../../protocols/container"
import links from "../../protocols/links"
import volume_protocol from "../../protocols/volume"
import container_service from "../container_service"
import fat_server from "../fat_server"
import partition_server from "../partition_server"
import volume_server from "../volume_server"

/** How often each writable volume served gets an automatic snapshot, in nanoseconds: an hour (decisions/0179). */
SNAPSHOT_EVERY : u64 : 3600 * 1000000000
/** How long automatic snapshots, and those a dir's Snapshot took, are kept, in nanoseconds: a day. */
SNAPSHOTS_KEPT : u64 : 24 * SNAPSHOT_EVERY
/** The start of an automatic snapshot's name, before the seconds since 1970 it was taken at. */
AUTOMATIC_PREFIX :: "auto-"
/** The start of the name of a snapshot a dir's Snapshot took (volume_server's ASKED_PREFIX), deleted on the same terms. */
ASKED_PREFIX :: "asked-"

/** The most disks it holds: one connector each, disk0 to disk3. */
MAX_DISKS :: 4
/** The most partitions it lists, across every disk; those past it aren't served. */
MAX_PARTITIONS :: 32
/** A partition server's memory budget, in bytes. */
PARTITION_SERVER_BUDGET : u64 : 2 * 1024 * 1024
/** A FAT server's memory budget, in bytes. */
FAT_SERVER_BUDGET : u64 : 2 * 1024 * 1024
/** A container service's memory budget, in bytes. */
CONTAINER_SERVICE_BUDGET : u64 : 4 * 1024 * 1024
/** A plain volume's server's memory budget, in bytes. */
VOLUME_SERVER_BUDGET : u64 : 6 * 1024 * 1024
/**
 * An encrypted volume's server's memory budget, in bytes: Argon2id's memory, for a passphrase whose parameters ask for
 * up to 8 MiB, on top.
 */
SEALED_VOLUME_SERVER_BUDGET : u64 : VOLUME_SERVER_BUDGET + 8 * 1024 * 1024
/** The most volumes served at once, across every container; a place a volume server that ended left is used again. */
MAX_VOLUMES :: 8
/** The longest volume name, in bytes, "volume@snapshot" included. */
VOLUME_NAME_BYTES :: 64
/** The keys volume servers' links connections are bound to the port with, plus their place in served. */
LINKS_KEY : u64 : 1000
/**
 * The key its connection to the process manager is bound to the port with, watched for its other end closing, and
 * dialed again when it does (decisions/0140).
 */
MANAGER_KEY : u64 : 900
/** The key a partition server is watched under from its launch, plus its disk's index. */
PARTITION_SERVER_KEY : u64 : 2000
/** The key a FAT server is watched under from its launch, plus its partition's index. */
FAT_SERVER_KEY : u64 : 3000
/** The key a container service is watched under from its launch, plus its partition's index. */
CONTAINER_KEY : u64 : 4000
/** The key a volume server is watched under from its launch, plus its place in served. */
VOLUME_KEY : u64 : 5000
/** How often a server is started again in RESTART_WINDOW before it's left ended (decisions/0077). */
RESTARTS : u32 : 3
/** The window RESTARTS are counted in, in nanoseconds: a minute. */
RESTART_WINDOW : u64 : 60_000_000_000
/** A SlopOS container's partition type, "SLOPOS CONTAINER" in ASCII (decisions/0088). */
CONTAINER_TYPE :: u8.[0x53, 0x4c, 0x4f, 0x50, 0x4f, 0x53, 0x20, 0x43, 0x4f, 0x4e, 0x54, 0x41, 0x49, 0x4e, 0x45, 0x52]
/** The volume a container's files are, as OpenFiles serves them (decisions/0089). */
SYSTEM_VOLUME :: "system"
/** The EFI system partition's GPT type, C12A7328-F81F-11D2-BA4B-00A0C93EC93B, as its bytes are on the disk. */
ESP_TYPE :: u8.[0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b]
/** A basic data partition's GPT type, EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, as its bytes are on the disk. */
BASIC_DATA_TYPE :: u8.[0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7]

/** What a FAT server is given (fat_server.main). */
FatServerGrants :: struct {
    /** A copy of the storage manager's debug log; none if it couldn't be duplicated. */
    log : slop_os.DebugLog?,
    /** A block connection narrowed to the FAT partition, from its disk's partition server. */
    partition : os.Channel[block.Block],
    /** The listener for connections to the volume's root; the storage manager keeps the other end. */
    clients : os.Listener[dir.Dir],
}

/** What a container service is given (container_service.main). */
ContainerServiceGrants :: struct {
    /** A copy of the storage manager's debug log; none if it couldn't be duplicated. */
    log : slop_os.DebugLog?,
    /** A block connection narrowed to the container's partition, from its disk's partition server. */
    partition : os.Channel[block.Block],
    /** The listener for the storage manager's container connections; it keeps the other end. */
    clients : os.Listener[container.Container],
}

/** What a volume server is given (volume_server.main). */
VolumeServerGrants :: struct {
    /** A copy of the storage manager's debug log; none if it couldn't be duplicated. */
    log : slop_os.DebugLog?,
    /** A connection to the container service for this one volume, or snapshot. */
    volume : os.Channel[container.Container],
    /** The listener for connections to the volume's root; the storage manager keeps the other end. */
    clients : os.Listener[dir.Dir],
    /** The listener the storage manager speaks the volume protocol on: Unlock, Commit, Rotate, and links' requests. */
    control : os.Listener[volume_protocol.Volume],
    /** The volume server's links connection to the storage manager, which knows it's this volume's. */
    stored_links : os.Channel[links.Links],
}

/**
 * A volume being served: the partition it's on, its name, its volume server's listener and the end the storage manager
 * speaks the volume protocol on, with a port for each, and whether it's encrypted and unlocked yet; the volume by its
 * container and ID, and the end its volume server's stored links are asked on.
 */
Served :: struct {
    /** The index of the container's partition. */
    partition : usize,
    /** The container's ID, as the container service describes it. */
    container : u8[16],
    /** The volume's ID in its container. */
    id : u64,
    /** The volume server's links connection, the storage manager's end; NO_HANDLE once it's gone. */
    links : slop_os.Channel,
    /** The volume's name, name_bytes of it, or "volume@snapshot" for a snapshot's. */
    name : u8[VOLUME_NAME_BYTES],
    /** How many of name's bytes are its. */
    name_bytes : usize,
    /** The volume server's root listener's other end, which each client's connection to the root is made through. */
    root : Disk,
    /** The end the volume protocol is spoken on, to the volume server. */
    control : Disk,
    /** Whether the volume is encrypted, and so opened only with its passphrase. */
    encrypted : bool,
    /** Whether an encrypted volume has been unlocked since its volume server started. */
    unlocked : bool,
    /** Whether it's a snapshot's, "volume@snapshot", whose root is read only. */
    read_only : bool,
    /** Its volume server's process and budget. */
    running : Running,
    /** Whether its volume server has ended, so another can be served in its place. */
    gone : bool,
}

/**
 * A server the storage manager started: its process and its budget, which it keeps until the server ends, so what it
 * had comes back then; and how many times it's been started again in the window since restarts_since, and whether it
 * has ended since it was last started.
 */
Running :: struct {
    /** The server's process, the storage manager's handle; NO_HANDLE once it's let go of. */
    process : slop_os.Process,
    /** The server's budget, the storage manager's handle, closed once it ends so what it had comes back. */
    budget : slop_os.MemoryBudget,
    /** How many times it's been started again since restarts_since. */
    restarts : u32,
    /** When the restart window began, in nanoseconds of the monotonic clock. */
    restarts_since : u64,
    /** Whether it has ended since it was last started. */
    ended : bool,
}

/** A connector to a disk, which may not be given. */
DiskConnector :: os.Channel[connector.Connector]?

/** What a partition server is given (partition_server.main). */
PartitionServerGrants :: struct {
    /** A copy of the storage manager's debug log; none if it couldn't be duplicated. */
    log : slop_os.DebugLog?,
    /** A block connection to the whole disk, dialed through its connector. */
    disk : os.Channel[block.Block],
    /** The listener for the storage manager's partitions connection; it keeps the other end. */
    clients : os.Listener[partitions.Partitions],
    /** A read-only copy of the kernel's command line, for faulty_block in robustness builds (decisions/0112). */
    command_line : slop_os.Memory?,
}

/** An end a server is spoken to on, and a port bound to it; both NO_HANDLE when there's none. */
Disk :: struct {
    /** The end, the storage manager's own. */
    end : slop_os.Channel,
    /** A port bound to end, waited on for its answers. */
    port : slop_os.Port,
}

/** The storage manager's state, kept on main's stack for as long as it runs. */
Manager :: struct {
    /** The debug log it, and the servers it starts, say what they're doing in; NO_HANDLE for none. */
    log : slop_os.DebugLog,
    /** The port clients, links connections, the process manager's connection and started servers are bound to. */
    port : slop_os.Port,
    /** The kernel's command line, if it was given, for the partition servers; NO_HANDLE otherwise. */
    command_line : slop_os.Memory,
    /** Each disk's partition server's end; NO_HANDLE while it isn't running. */
    disks : Disk[MAX_DISKS],
    /** How many disks have a partition server started. */
    disk_count : usize,
    /** Each disk's connector, kept to dial its driver again for a restarted partition server. */
    connectors : Disk[MAX_DISKS],
    /** Each disk's partition server's process. */
    disk_running : Running[MAX_DISKS],
    /** The partition server's module, launched for each disk. */
    partition_server_module : slop_os.Memory,
    /** Each partition's FAT server's process, by partition index. */
    files_running : Running[MAX_PARTITIONS],
    /** Each partition's container service's process, by partition index. */
    containers_running : Running[MAX_PARTITIONS],
    /** Every disk's partitions, listed once at start, by one index. */
    partitions : storage.Partition[MAX_PARTITIONS],
    /** How many of partitions are listed. */
    partition_count : usize,
    /** Each partition's FAT server, its listener's end and a port for it, NO_HANDLE until it's started. */
    files : Disk[MAX_PARTITIONS],
    /** Each container's service, its listener's end and a port for it, NO_HANDLE until it's started. */
    containers : Disk[MAX_PARTITIONS],
    /** The volumes served, and places volume servers that ended left. */
    served : Served[MAX_VOLUMES],
    /** How many of served have been used. */
    served_count : usize,
    /** The connection to the process manager, which servers are launched through; dialed again when it closes. */
    manager : os.Channel[process_manager.ProcessManager],
    /** A port bound to manager, waited on for its answers. */
    manager_port : slop_os.Port,
    /** The connector the process manager's dialed through. */
    manager_connector : slop_os.Channel,
    /** A port bound to manager_connector. */
    connector_port : slop_os.Port,
    /** The FAT server's module. */
    fat_server_module : slop_os.Memory,
    /** The container service's module. */
    container_service_module : slop_os.Memory,
    /** The volume server's module. */
    volume_server_module : slop_os.Memory,
    /** The clients' ends: the listener's, and connections arrived as Connects. */
    clients : service_kit.Clients,
    /**
     * test_storage_restart on the kernel's command line: the first disk's partition server killed once it's listed its
     * partitions, and TestRestart taken.
     */
    test_restart : bool,
    /** How many times a partition server was started, which a test waits on. */
    partition_server_starts : u64,
    /** Whether a wait took the port's packets meant for the main loop, whose clients are read again before it waits. */
    serve_again : bool,
    /** How often automatic snapshots are taken, in nanoseconds: SNAPSHOT_EVERY, or test_snapshot_seconds's. */
    snapshot_every : u64,
    /** How long they're kept, in nanoseconds: SNAPSHOTS_KEPT, or ten times test_snapshot_seconds's. */
    snapshots_kept : u64,
    /** When the next automatic snapshots are taken, in nanoseconds of the monotonic clock. */
    next_snapshots : u64,
}

/**
 * Hold every disk, start a partition server for each, and serve their partitions: block connections narrowed to one,
 * FAT partitions' files, and a SlopOS container's volumes, each through a server of its own started as it's first
 * asked for.
 *
 * Runs until it's stopped. Servers that end are started again, up to RESTARTS times in RESTART_WINDOW.
 *
 * @param log The debug log it, and the servers it starts, say what they're doing in; without one, nothing's said.
 * @param manager A connector to the process manager, which servers are launched through; dialed again whenever the
 *     connection closes.
 * @param partition_server_module The partition server's module, launched for each disk.
 * @param fat_server_module The FAT server's module.
 * @param container_service_module The container service's module.
 * @param volume_server_module The volume server's module.
 * @param disk0 A connector to the first disk's driver; without it, there's no such disk.
 * @param disk1 A connector to the second disk's driver; without it, there's no such disk.
 * @param disk2 A connector to the third disk's driver; without it, there's no such disk.
 * @param disk3 A connector to the fourth disk's driver; without it, there's no such disk.
 * @param clients The listener its clients' connections arrive on; more arrive as Connects on those.
 * @param command_line The kernel's command line, for test_storage_restart and the partition servers' faulty_block;
 *     without it, neither is asked for.
 * @return 1 if its port couldn't be made or the process manager couldn't be dialed, and 2 if clients couldn't be
 *     added. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, manager: os.Channel[connector.Connector], partition_server_module: slop_os.Memory,
    fat_server_module: slop_os.Memory, container_service_module: slop_os.Memory, volume_server_module: slop_os.Memory,
    disk0: os.Channel[connector.Connector]?, disk1: os.Channel[connector.Connector]?,
    disk2: os.Channel[connector.Connector]?, disk3: os.Channel[connector.Connector]?, clients: os.Listener[storage.Storage],
    command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    state := Manager.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), manager_connector = manager.end, fat_server_module = fat_server_module,
        container_service_module = container_service_module, volume_server_module = volume_server_module,
        partition_server_module = partition_server_module}
    state.snapshot_every = SNAPSHOT_EVERY
    state.snapshots_kept = SNAPSHOTS_KEPT
    match command_line {
        case Some(memory) => {
            words :: service_kit.text_of(startup, memory) or_else ""
            state.test_restart = service_kit.has_word(words, "test_storage_restart")
            // test_snapshot_seconds=N: automatic snapshots every N seconds, kept 10 N, for tests
            seconds :: service_kit.number_of(service_kit.word_after(words, "test_snapshot_seconds=") or_else "") or_else 0
            if seconds > 0 {
                state.snapshot_every = seconds * 1000000000
                state.snapshots_kept = 10 * state.snapshot_every
            }
            state.command_line = memory
        }
        case None => {}
    }
    state.next_snapshots = (slop_os.clock_monotonic() or_else 0) + state.snapshot_every
    state.port = slop_os.port_create(startup.budget) or_return 1
    state.connector_port = os.port_for(startup.budget, state.manager_connector) or_return 1
    if !dial_manager(&state) {
        return 1
    }

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
        // Automatic snapshots, and those too old let go of (decisions/0179)
        if (slop_os.clock_monotonic() or_else 0) >= state.next_snapshots {
            automatic_snapshots(&state)
            state.next_snapshots = (slop_os.clock_monotonic() or_else 0) + state.snapshot_every
            continue
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(state.port, packets, state.next_snapshots) or_else 0
        for packet, i in packets {
            if i < cast[usize](taken) && packet.kind == .Signal && packet.key >= PARTITION_SERVER_KEY {
                ended(&state, packet.key)
            }
            if i < cast[usize](taken) && packet.kind == .Signal && packet.key == MANAGER_KEY {
                _ = dial_manager(&state)
            }
        }
    }
}

/**
 * Dial the process manager through its connector, in place of a connection that's gone, as when the root task starts
 * the process manager again, and watch the new one for its other end closing.
 *
 * @param state The storage manager's state, whose manager and manager_port are replaced.
 * @return Whether there's a connection; false if it couldn't be dialed, or a port for it made.
 */
dial_manager :: fn(state: ptr[mut Manager]) -> bool {
    again :: cast[slop_os.Handle](state.manager.end) != slop_os.NO_HANDLE
    if again {
        _ = slop_os.handle_close(cast[slop_os.Handle](state.manager.end))
        _ = slop_os.handle_close(cast[slop_os.Handle](state.manager_port))
    }
    state.manager = connector.dial[process_manager.ProcessManager](state.manager_connector, state.connector_port) or_return false
    state.manager_port = os.port_for(slop_os.startup_block().budget, state.manager.end) or_return false
    _ = slop_os.port_bind(state.port, cast[slop_os.Handle](state.manager.end), slop_os.SIGNAL_PEER_CLOSED, MANAGER_KEY, .Once)
    if again {
        runtime.log_info("dialed the process manager again")
    }
    return true
}

/**
 * Kill a disk's partition server, for tests, and handle servers' ends on the port until it's started again, or won't
 * be. Other packets that arrive meanwhile are dropped; clients are read again after.
 *
 * @param state The storage manager's state.
 * @param index Which disk, counted from 0 in the order disks were found; one at MAX_DISKS or past is refused before
 *     anything's killed. It isn't checked against disk_count; callers pass a disk that was found.
 * @return Whether it was started again; false for a disk past MAX_DISKS, or one that's ended RESTARTS times.
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

/**
 * Start a disk's partition server, with a block connection dialed again through its connector, watched from its
 * launch under PARTITION_SERVER_KEY plus the disk's index.
 *
 * @param state The storage manager's state, whose disks, disk_running and partition_server_starts are set.
 * @param index Which disk, counted from 0, whose connector in connectors is dialed and whose disks and disk_running
 *     slots are set; one at MAX_DISKS or past gives false with nothing done.
 * @return Whether it started; false if the driver couldn't be dialed, a channel or a port for it made, or the launch
 *     failed. The port is made before the launch, so a server that's launched is always kept.
 */
start_partition_server :: fn(state: ptr[mut Manager], index: usize) -> bool {
    startup :: slop_os.startup_block()
    if index >= MAX_DISKS {
        return false
    }
    dialing :: state.connectors[index]
    disk :: connector.dial[block.Block](dialing.end, dialing.port) or_return false
    pair :: os.channel_for[partitions.Partitions](startup.budget, 0) or_return false
    // The port first: one that couldn't be made after the launch would leave a server running unrecorded
    server_port :: match os.port_for(startup.budget, pair.b) {
        case Some(made) => made
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return false
        }
    }
    grants := PartitionServerGrants.{log = duplicate_log(state.log), disk = disk, clients = os.Listener[partitions.Partitions].{end = pair.a},
        command_line = command_line_copy(state)}
    match os.launch(state.manager, state.manager_port, "partition_server", state.partition_server_module, PARTITION_SERVER_BUDGET,
        partition_server.main, grants, watched(state, PARTITION_SERVER_KEY + cast[u64](index))) {
        case Ok(launched) => keep(&state.disk_running[index], launched)
        case Error(error) => {
            runtime.log_info("no partition server for disk %: %", index, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](server_port))
            return false
        }
    }
    state.disks[index] = Disk.{end = pair.b, port = server_port}
    state.partition_server_starts += 1
    return true
}

/**
 * Make the options for a launch watched from its start, and given the wall clock's page, as a FAT server's times need.
 *
 * @param state The storage manager's state.
 * @param key The key the server's end is signalled under on the storage manager's port.
 * @return The options, with a read-only copy of the clock page the storage manager was given, if it was and it could
 *     be duplicated.
 */
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

/**
 * Keep what a launch gave while the server runs.
 *
 * @param running Where it's kept, its restarts left as they were.
 * @param launched The launched process's handle and its budget's, which move to running.
 */
keep :: fn(running: ptr[mut Running], launched: os.Launched) {
    running.process = launched.process
    running.budget = launched.budget
    running.ended = false
}

/**
 * Let go of a server that ended: close its process's and its budget's handles, so what its budget had comes back.
 *
 * @param running The server, marked ended.
 */
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

/**
 * Kill a server that's running; what its ending tears down is the caller's to let go of.
 *
 * @param running The server; one already let go of is left alone.
 */
kill_running :: fn(running: ptr[Running]) {
    if cast[slop_os.Handle](running.process) != slop_os.NO_HANDLE {
        _ = slop_os.process_kill(running.process)
    }
}

/**
 * Tell whether a server may be started: one that ended, up to RESTARTS times in RESTART_WINDOW, as the supervisor
 * starts its drivers again (decisions/0077); one that hasn't ended, always.
 *
 * @param running The server, whose restarts is counted, and its window begun again once it's past.
 * @return Whether it may be started.
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

/**
 * Handle a server it started having ended, by its key.
 *
 * A partition server is started again at once, once everything served from its disk is killed, since each holds a
 * connection it narrowed; a FAT server, a container service or a volume server is let go, and started again the next
 * time it's asked for. A container service's volume servers go with it, and an encrypted volume served again is
 * locked until its passphrase is given again.
 *
 * @param state The storage manager's state.
 * @param key The key the server was watched under, PARTITION_SERVER_KEY or above, which is unbound.
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

/**
 * Let go of a FAT server that ended, or was killed, and close its listener's end, so the next request starts another.
 *
 * @param state The storage manager's state.
 * @param index Its partition's index; one past MAX_PARTITIONS is ignored.
 */
files_gone :: fn(state: ptr[mut Manager], index: usize) {
    if index >= MAX_PARTITIONS {
        return void
    }
    let_go(&state.files_running[index])
    close_disk(&state.files[index])
    runtime.log_info("the FAT server for partition % ended", index)
}

/**
 * Let go of a container service that ended, or was killed, close its listener's end, and kill its volume servers.
 *
 * @param state The storage manager's state.
 * @param index Its partition's index; one past MAX_PARTITIONS is ignored.
 */
container_gone :: fn(state: ptr[mut Manager], index: usize) {
    if index >= MAX_PARTITIONS {
        return void
    }
    let_go(&state.containers_running[index])
    close_disk(&state.containers[index])
    runtime.log_info("the container service for partition % ended", index)
    kill_volumes(state, index)
}

/**
 * Kill every volume server serving a volume of a partition, and let go of each.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 */
kill_volumes :: fn(state: ptr[mut Manager], index: usize) {
    for i in 0..<state.served_count {
        if i < state.served.count && state.served[i].partition == index && !state.served[i].gone {
            _ = slop_os.port_unbind(state.port, VOLUME_KEY + cast[u64](i))
            kill_running(&state.served[i].running)
            volume_gone(state, i)
        }
    }
}

/**
 * Let go of a volume server that ended: close its ends, and free its place in served for the next; an encrypted
 * volume is locked again.
 *
 * @param state The storage manager's state.
 * @param slot Its place in served, taken modulo MAX_VOLUMES.
 */
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

/**
 * Close an end a server is spoken to on, and its port, those that are open.
 *
 * @param disk The end and its port, both NO_HANDLE afterwards.
 */
close_disk :: fn(disk: ptr[mut Disk]) {
    for each in slop_os.Handle.[cast[slop_os.Handle](disk.end), cast[slop_os.Handle](disk.port)] {
        if each != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(each)
        }
    }
    disk.end = cast[slop_os.Channel](slop_os.NO_HANDLE)
    disk.port = cast[slop_os.Port](slop_os.NO_HANDLE)
}

/**
 * List a disk's partitions, from 0 until its partition server has no more, each added to the partitions and logged.
 *
 * @param state The storage manager's state.
 * @param disk The disk's index. Listing stops once MAX_PARTITIONS are listed, from every disk.
 */
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

/**
 * Answer a client's requests, until it has none, or it's gone.
 *
 * A request for a partition that isn't listed, or isn't a container where one is wanted, is answered NoPartition.
 * Connect adds a client, with no answer. A client whose end fails is dropped. A request that starts a server, or asks
 * one, waits for it, so every client waits meanwhile.
 *
 * @param state The storage manager's state.
 * @param index The client's index in state.clients; one past them, or one dropped, is left alone.
 * @param into Where each request is read into, reused.
 */
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
            case _ => {
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
            case CreateVolume(creation) => {
                if is_container(state, creation.partition) {
                    response = create_volume(state, cast[usize](creation.partition), os.items(into, creation.name),
                        os.items(into, creation.passphrase), creation.cipher, creation.now)
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
            case CommitAll => response = if committed_all(state) { storage.Response.Done } else { storage.Response.Failed }
        }
        made^ = response
        _ = storage.send_response(end, state.port, &reply)
    }
}

/**
 * Make a connection to the root of a partition's files: a FAT volume's, from its FAT server, started the first time
 * with a connection narrowed to the partition and nothing else; or a container's system volume's.
 *
 * @param state The storage manager's state.
 * @param index The partition's place in the storage manager's list of partitions, from every disk; one past it, or
 *     past files, gives null.
 * @return The connection, which the caller owns and passes on; null for a partition of another kind, an encrypted
 *     system volume, or if the server can't be started or connected to.
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
        // The port first: one that couldn't be made after the launch would leave a server running unrecorded
        port :: match os.port_for(startup.budget, pair.b) {
            case Some(made) => made
            case None => {
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                _ = slop_os.handle_close(cast[slop_os.Handle](narrowed.end))
                return null
            }
        }
        grants := FatServerGrants.{log = duplicate_log(state.log), partition = narrowed, clients = os.Listener[dir.Dir].{end = pair.a}}
        match os.launch(state.manager, state.manager_port, "fat_server", state.fat_server_module, FAT_SERVER_BUDGET, fat_server.main, grants,
            watched(state, FAT_SERVER_KEY + cast[u64](index))) {
            case Ok(launched) => keep(&state.files_running[index], launched)
            case Error(error) => {
                runtime.log_info("no FAT server for disk % partition %: %", partition.disk, partition.index, error)
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                _ = slop_os.handle_close(cast[slop_os.Handle](port))
                return null
            }
        }
        state.files[index] = Disk.{end = pair.b, port = port}
        runtime.log_info("started a FAT server for disk % partition %", partition.disk, partition.index)
    }
    server :: state.files[index]
    return dir.connect(server.end, server.port, startup.budget)
}

/**
 * Find a container's service, or start it the first time, with a connection narrowed to its partition and nothing
 * else, watched under CONTAINER_KEY plus the partition's index.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @return Its listener's end and a port for it, the storage manager's own; null if it may not be started again, its
 *     partition couldn't be opened, a channel or port couldn't be made, or the launch failed. The port is made before
 *     the launch, so a service that's launched is always kept.
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
    // The port first: one that couldn't be made after the launch would leave a service running unrecorded
    port :: match os.port_for(startup.budget, listener.b) {
        case Some(made) => made
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](listener.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](listener.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](narrowed.end))
            return null
        }
    }
    grants := ContainerServiceGrants.{log = duplicate_log(state.log), partition = narrowed,
        clients = os.Listener[container.Container].{end = listener.a}}
    match os.launch(state.manager, state.manager_port, "container_service", state.container_service_module, CONTAINER_SERVICE_BUDGET,
        container_service.main, grants, watched(state, CONTAINER_KEY + cast[u64](index))) {
        case Ok(launched) => keep(&state.containers_running[index], launched)
        case Error(error) => {
            runtime.log_info("no container service for disk % partition %: %", partition.disk, partition.index, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](listener.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
            return null
        }
    }
    runtime.log_info("started a container service for disk % partition %", partition.disk, partition.index)
    state.containers[index] = Disk.{end = listener.b, port = port}
    return state.containers[index]
}

/**
 * Find a volume being served by its name.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @param name The volume's name, or "volume@snapshot".
 * @return Its place in served, good while the storage manager runs; null if it isn't served, or its server's gone.
 */
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

/**
 * Tell whether two byte arrays hold the same bytes.
 *
 * @param a One array's bytes, read only.
 * @param b The other's bytes, read only; a different count is never the same.
 * @return Whether they're as long as each other, with the same bytes.
 */
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

/**
 * Open a container's volume's root: its volume server started the first time, with a connection to the container
 * service for that volume and nothing else, and for an encrypted volume, unlocked with its passphrase.
 *
 * An encrypted volume being served is opened again only with its passphrase, which its volume server checks; one whose
 * passphrase was wrong stays served, locked, waiting for the right one.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @param name The volume's name, or "volume@snapshot" for a snapshot's, read only; 1 to VOLUME_NAME_BYTES bytes.
 * @param passphrase The passphrase, for an encrypted volume.
 * @param given Whether a passphrase was given; without one, an encrypted volume is Locked.
 * @return OpenedFiles with a new connection to its root, or OpenedReadOnlyFiles for a snapshot's, which the caller
 *     owns; Locked, WrongKey, NoVolume if the container service hasn't it, or Failed if a name, a place in served, the
 *     container service, a channel or the launch couldn't be had.
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
    /*
     * The ports and the links binding first: any of them failing after the launch would leave a server running
     * unrecorded, which the next open would launch again on the same volume
     */
    root_port :: os.port_for(startup.budget, pair.b) or_return .Failed
    control_port :: os.port_for(startup.budget, control.b) or_return .Failed
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(state.port, cast[slop_os.Handle](stored_links.b), signals, LINKS_KEY + cast[u64](slot), .Persistent) is_error {
        return .Failed
    }
    launched_volume := Running.{}
    match os.launch(state.manager, state.manager_port, "volume_server", state.volume_server_module, budget, volume_server.main, volume_grants,
        watched(state, VOLUME_KEY + cast[u64](slot))) {
        case Ok(launched) => keep(&launched_volume, launched)
        case Error(error) => {
            runtime.log_info("no volume server for the % volume: %", string_of(&name[0], name.count), error)
            _ = slop_os.port_unbind(state.port, LINKS_KEY + cast[u64](slot))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](control.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](stored_links.b))
            _ = slop_os.handle_close(cast[slop_os.Handle](root_port))
            _ = slop_os.handle_close(cast[slop_os.Handle](control_port))
            return .Failed
        }
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

/**
 * Make a new volume on a container (decisions/0141): registered by the container service with nothing in it, durable,
 * then opened, its volume server making its keys from the passphrase if the cipher seals it.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @param name The volume's name, 1 to VOLUME_NAME_BYTES bytes, without '@'.
 * @param passphrase The passphrase it's sealed with; given exactly when cipher seals it.
 * @param cipher slopfs.Cipher's value; 0 for none.
 * @param now When it's made, as the client says.
 * @return What opening it answers: OpenedFiles with its root, which the caller owns, or why not; AlreadyExists for a
 *     name taken, or Failed for arguments that don't agree or a container that couldn't make it.
 */
create_volume :: fn(state: ptr[mut Manager], index: usize, name: u8[], passphrase: u8[], cipher: u8, now: u64) -> storage.Response {
    sealed :: cipher != 0
    if sealed != (passphrase.count > 0) || name.count == 0 || name.count > VOLUME_NAME_BYTES || is_snapshot(name) {
        return .Failed
    }
    service :: container_of(state, index) or_return .Failed
    out := os.Outgoing.{}
    request :: os.begin[container.Request](&out)
    request^ = .CreateVolume(container.VolumeCreation.{name = os.append(&out, name), cipher = cipher, now = now})
    match ask_container(service.end, service.port, &out) {
        case Created(_) => runtime.log_info("made the % volume", string_of(&name[0], name.count))
        case AlreadyExists => return .AlreadyExists
        case _ => return .Failed
    }
    return volume_of(state, index, name, passphrase, sealed)
}

/**
 * Tell whether a name is a snapshot's, "volume@snapshot".
 *
 * @param name A volume's name as a client gave it, any bytes.
 * @return Whether it has an '@' in it.
 */
is_snapshot :: fn(name: u8[]) -> bool {
    for byte in name {
        if byte == cast[u8]('@') {
            return true
        }
    }
    return false
}

/**
 * Make a new connection to a served volume's root.
 *
 * @param served A served volume, read; the connection is made through its root's end, a read_only_dir for a snapshot's.
 * @return OpenedFiles with a dir connection, or OpenedReadOnlyFiles with a snapshot's read_only_dir, which the caller
 *     owns; Failed if it couldn't be made.
 */
root_of :: fn(served: ptr[Served]) -> storage.Response {
    startup :: slop_os.startup_block()
    if served.read_only {
        root :: read_only_dir.connect(served.root.end, served.root.port, startup.budget) or_return .Failed
        return .OpenedReadOnlyFiles(root)
    }
    root :: dir.connect(served.root.end, served.root.port, startup.budget) or_return .Failed
    return .OpenedFiles(root)
}

/**
 * Ask a served volume's server to unlock it with a passphrase, or, unlocked already, to check it.
 *
 * @param served A served, encrypted volume, whose volume server is asked on its control connection, waited for; served
 *     isn't changed.
 * @param passphrase The passphrase's bytes, copied into the request; not kept.
 * @return The volume server's answer: Unlocked, WrongKey, or another failure; Failed if it couldn't be asked.
 */
unlock :: fn(served: ptr[Served], passphrase: u8[]) -> volume_protocol.Response {
    out := os.Outgoing.{}
    request :: os.begin[volume_protocol.Request](&out)
    request^ = .Unlock(os.append(&out, passphrase))
    return ask_volume(served, &out)
}

/**
 * Send one request to a volume server, on the volume protocol, and wait for its answer.
 *
 * @param served A served volume, whose control connection carries the request and is waited on, so nothing else is
 *     served meanwhile.
 * @param out The request; its handles are moved out when it's sent.
 * @return The answer, a copy, whose handles the caller owns; Failed if it couldn't be sent or the connection failed.
 */
ask_volume :: fn(served: ptr[Served], out: ptr[mut os.Outgoing]) -> volume_protocol.Response {
    if volume_protocol.send_request(served.control.end, served.control.port, out) is_some {
        return .Failed
    }
    into := os.Incoming.{}
    loop {
        match volume_protocol.receive_response(served.control.end, served.control.port, &into, true) {
            case Received => return os.message_of[volume_protocol.Response](&into)^
            case Failed(error) => return .Failed
            case _ => return .Failed
        }
    }
}

/**
 * Start a new key generation for a served, unlocked volume, sealing what's written from now on.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @param name The volume's name in the container; matched byte for byte against the volumes being served, so
 *     one that's not served now gives NoVolume.
 * @return Rotated with the new generation's number; NoVolume if it isn't served, NotEncrypted, Locked if it hasn't
 *     been unlocked, or Failed.
 */
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

/**
 * Send one request to a container service, and wait for its answer.
 *
 * @param end A connection to a container service, kept, with no other request in flight, so the next answer is this
 *     one's.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @return The answer, a copy, whose handles the caller owns; its Relatives point into a message that's gone, so they
 *     aren't read. Unsupported if it couldn't be sent or the connection failed.
 */
ask_container :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing]) -> container.Response {
    if container.send_request(end, port, out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match container.receive_response(end, port, &into, true) {
            case Received => return os.message_of[container.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Send one request to a disk's partition server, and wait for its answer.
 *
 * @param state The storage manager's state.
 * @param disk Which disk's server to ask, counted from 0; one at disk_count or past gives Unsupported, unsent.
 * @param request The request, sent as it is: Describe or Open, of a partition by its index on the disk.
 * @return The answer, a copy, whose handles the caller owns; Unsupported for a disk with no partition server, or if it
 *     couldn't be asked.
 */
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
            case _ => return .Unsupported
        }
    }
}

/**
 * Make a copy of the debug log to give a server.
 *
 * @param log The storage manager's debug log.
 * @return A new handle to it, to write, duplicate and transfer, which the caller gives away; null if there's no log or
 *     it couldn't be duplicated.
 */
duplicate_log :: fn(log: slop_os.DebugLog) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](log), rights) {
        case Ok(copy) => return cast[slop_os.DebugLog](copy)
        case Error(error) => return null
    }
}

/**
 * Make a read-only copy of the kernel's command line, to give a partition server.
 *
 * @param state The storage manager's state.
 * @return A new handle to it, to read and transfer, which the caller gives away; null without a command line, or if it
 *     couldn't be duplicated.
 */
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

/**
 * Tell whether a partition holds a SlopOS container.
 *
 * @param state The storage manager's state.
 * @param partition The partition's place in the list of partitions, from every disk, as a client gives it; any value
 *     is safe, and one past the list gives false.
 * @return Whether it's listed and its type is CONTAINER_TYPE.
 */
is_container :: fn(state: ptr[Manager], partition: u32) -> bool {
    index :: cast[usize](partition)
    return index < state.partition_count && index < state.partitions.count && state.partitions[index].info.type_guid == CONTAINER_TYPE
}

/**
 * Take a snapshot of a container's volume: what its server has waiting committed first, if it's being served and
 * unlocked, so the snapshot holds everything written to it so far.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @param volume The volume's name in the container; if a served volume has it, that server commits first. The
 *     container service looks it up, and answers NoVolume if no volume has it.
 * @param snapshot The new snapshot's name, passed on as it is; one the volume already has is answered AlreadyExists.
 * @param now When it's taken, as the client says.
 * @return Done once it's durable; Failed if the volume server didn't commit, or the container's answer, as
 *     to_container gives it.
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

/**
 * Have every writable volume being served, unlocked, commit what's changed, as before a shutdown (decisions/0180).
 *
 * @param state The storage manager's state, whose served volumes' servers are each asked, and waited for.
 * @return Whether each committed; false if any couldn't, the rest asked all the same.
 */
committed_all :: fn(state: ptr[mut Manager]) -> bool {
    all := true
    for i in 0..<state.served_count {
        if i >= state.served.count {
            break
        }
        served :: &state.served[i]
        if served.gone || served.read_only || (served.encrypted && !served.unlocked) {
            continue
        }
        out := os.Outgoing.{}
        request :: os.begin[volume_protocol.Request](&out)
        request^ = .Commit
        match ask_volume(served, &out) {
            case Committed => {}
            case _ => all = false
        }
    }
    return all
}

/**
 * Take an automatic snapshot of each writable volume served, unlocked, named auto- and the seconds since 1970, and
 * delete its automatic snapshots, and those a dir's Snapshot took, older than snapshots_kept (decisions/0179). Others,
 * an administrator's or an update's, are left. Without a wall clock nothing's done, as their ages couldn't be told.
 *
 * A snapshot a volume server is serving through OpenSnapshot when it's deleted reads nothing more from then on.
 *
 * @param state The storage manager's state, whose served volumes are snapshotted, each committed first.
 */
automatic_snapshots :: fn(state: ptr[mut Manager]) {
    now :: match time.now() {
        case Ok(instant) => cast[u64](instant.seconds) * 1000000000 + cast[u64](instant.nanos)
        case Error(error) => return void
    }
    taken : u32 = 0
    deleted : u32 = 0
    for i in 0..<state.served_count {
        if i >= state.served.count {
            break
        }
        served :: state.served[i]
        if served.gone || served.read_only || (served.encrypted && !served.unlocked) || served.name_bytes == 0 || served.name_bytes > served.name.count {
            continue
        }
        volume :: served.name[0..<served.name_bytes]
        name :: strings.format("%1%2", AUTOMATIC_PREFIX, now / 1000000000) or_continue
        if take_snapshot(state, served.partition, volume, string_bytes(name), now) == .Done {
            taken += 1
        }
        strings.free_string(name)
        deleted += delete_old_snapshots(state, served.partition, volume, now)
    }
    if taken > 0 || deleted > 0 {
        runtime.log_info("automatic snapshots: % taken, % deleted", taken, deleted)
    }
}

/**
 * Delete a volume's automatic snapshots, and those a dir's Snapshot took, taken before snapshots_kept ago.
 *
 * @param state The storage manager's state, whose container service is asked.
 * @param index The container's partition's index.
 * @param volume The volume's name.
 * @param now The wall clock's time, in nanoseconds since 1970.
 * @return How many were deleted; those the container wouldn't delete, as one a clone keeps, are left.
 */
delete_old_snapshots :: fn(state: ptr[mut Manager], index: usize, volume: u8[], now: u64) -> u32 {
    service :: container_of(state, index) or_return 0
    // Their names first, oldest first, as deleting one moves the others' places
    old : string[..]
    defer {
        for each in old {
            strings.free_string(each)
        }
        runtime.array_free(&old)
    }
    place := cast[u64](0)
    loop {
        out := os.Outgoing.{}
        request :: os.begin[container.Request](&out)
        request^ = .SnapshotAt(container.SnapshotIndex.{volume = os.append(&out, volume), index = place})
        if container.send_request(service.end, service.port, &out) is_some {
            break
        }
        into := os.Incoming.{}
        match container.receive_response(service.end, service.port, &into, true) {
            case Received => {}
            case _ => break
        }
        info :: match os.message_of[container.Response](&into)^ {
            case Snapshot(found) => found
            case _ => break
        }
        place += 1
        name :: os.items(&into, info.name)
        if info.created + state.snapshots_kept < now && (has_prefix(name, AUTOMATIC_PREFIX) || has_prefix(name, ASKED_PREFIX)) && name.count > 0 {
            copy :: strings.clone(string_of(&name[0], name.count)) or_continue
            runtime.array_add(&old, copy)
        }
    }
    deleted : u32 = 0
    for each in old {
        out := os.Outgoing.{}
        request :: os.begin[container.Request](&out)
        request^ = .DeleteSnapshot(container.SnapshotNamed.{volume = os.append(&out, volume), snapshot = os.append(&out, string_bytes(each))})
        if to_container(state, index, &out, null) == .Done {
            deleted += 1
        }
    }
    return deleted
}

/**
 * Tell whether a name starts with a prefix.
 *
 * @param name The name's bytes.
 * @param prefix The prefix, compared byte for byte.
 * @return Whether name is at least as long, and its first bytes are prefix's.
 */
has_prefix :: fn(name: u8[], prefix: string) -> bool {
    if name.count < prefix.count {
        return false
    }
    for byte, i in string_bytes(prefix) {
        if i < name.count && name[i] != byte {
            return false
        }
    }
    return true
}

/**
 * Send a request to a container's service, starting it if it isn't running, and give its answer as the storage
 * protocol has it.
 *
 * @param state The storage manager's state.
 * @param index The container's partition's index.
 * @param out The request, built by the caller; its handles are moved out when it's sent.
 * @param answer The reply being built, which a snapshot's name is copied into; null when the answer can't be one.
 * @return Done, NoVolume, NoSnapshot, AlreadyExists, InUse, NoMore, Used or Snapshot as the container answers; Failed
 *     for any other answer, a Snapshot without a reply to copy its name into, or a service that couldn't be had.
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
            case _ => return .Failed
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

/**
 * Answer a volume server's requests on its links connection, until it has none, or it's gone; one gone is closed.
 *
 * Each is answered after the volume it's for answers, so a volume server's link into its own volume is answered
 * while it waits, as any other is.
 *
 * @param state The storage manager's state.
 * @param index The volume's place in served.
 * @param into Where each request is read into, reused.
 */
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
            case _ => {
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

/**
 * Find the volume being served that a link is to or from, to issue or open links.
 *
 * @param state The storage manager's state.
 * @param container The volume's container's ID.
 * @param id The volume's ID in its container.
 * @return Its place in served: not a snapshot, and unlocked if it's encrypted; null if there's none, which a link
 *     calls Unavailable.
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

/**
 * Have a grant a volume claimed issued to it, by the volume the grant is from.
 *
 * @param state The storage manager's state.
 * @param index The claiming volume's place in served, which says whose it is.
 * @param claim The claim: the grant's volume and its ticket.
 * @return Issued with the link's number; Failed with the issuing volume's refusal, or Unavailable if it isn't served,
 *     unlocked, or couldn't be asked.
 */
issue :: fn(state: ptr[mut Manager], index: usize, claim: grant.Claim) -> links.Response {
    if index >= state.served.count {
        return .Failed(.Unavailable)
    }
    asking :: &state.served[index]
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

/**
 * Open what a link a volume holds leads to, and a path beneath it, by the volume it leads into, which checks it issued
 * the link to that volume.
 *
 * @param state The storage manager's state.
 * @param index The holding volume's place in served.
 * @param resolving The link: the volume it leads into, its number, and how it's opened.
 * @param path The path beneath what it leads to; empty for that itself.
 * @return The connection opened, a file's or a directory's, read only or not, which goes back to the volume server
 *     that asked; Failed with the volume's refusal, or Unavailable if it isn't served, unlocked, or couldn't be asked.
 */
resolve :: fn(state: ptr[mut Manager], index: usize, resolving: links.Resolving, path: u8[]) -> links.Response {
    if index >= state.served.count {
        return .Failed(.Unavailable)
    }
    asking :: &state.served[index]
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
