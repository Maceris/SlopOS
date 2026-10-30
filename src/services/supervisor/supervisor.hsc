/*
 * The supervisor (decisions/0017, 0058, 0067, 0068, 0074, 0075, 0076, 0077): it starts the services system_config gives
 * it through the process manager, with std/os's launch, each in a process of its own that it owns and pays for from
 * its budget, and tells the root task as each starts and ends, and once all have. Each runs on the CPU budget the
 * scheduler service gives it (decisions/0093), and is watched from its launch.
 *
 * A driver's service names the devices it takes: the supervisor claims each from the platform service and starts a
 * driver for it, with what it holds of it (platform.PciDevice). Drivers start first, since services need them. A
 * driver that serves clients is given a listener whose other end the supervisor keeps. Clients don't get connections
 * to a driver: they get connectors (the connector protocol), channels the supervisor serves, each of which dials the
 * listener of whatever serves it now. The console service is given connectors to the first serial line and the first
 * keyboard, hello one to the console, and the disk check, if there's a disk, one to the first disk.
 *
 * Whatever it starts that ends other than by exiting with 0, killed or crashed, is started again, up to RESTARTS times
 * in RESTART_WINDOW, unless system_config says it's not_restarted (decisions/0093): a driver with its device reissued by
 * the platform service, made anew, and anything with a new listener; its clients' connections went with it, and they
 * dial again through their connectors. A restarted events service is given the system volume's events directory again;
 * a restarted storage manager starts its servers anew as it's asked for them, its encrypted volumes locked again, as
 * their volume servers went with it, and the supervisor asks it for the system volume again. With test_restart_services
 * on the kernel's command line, once everything has started it kills the events service, the clock service, and the
 * storage manager if there's one, one at a time, and checks each works once it's back. A driver whose device's DMA an IOMMU blocks (SIGNAL_DMA_FAULT, on a handle to its
 * Device the supervisor keeps) is killed, and so started again in the same way (decisions/0084). With test_dma_fault
 * on the kernel's command line, the supervisor says it has started all only once edu_dma has ended for good. With test_restart on the kernel's command line, the supervisor kills the first serial
 * line's driver once everything has started and the console has dialed it and shown its banner, and says it has
 * started all only once that driver is back, and dialed again.
 *
 * The clock service (decisions/0093), the real-time clock's driver, is started first, with the real-time clock the
 * platform service gives and the clock page, which the supervisor makes: the clock service writes the time on it, and
 * everything started after it is given it read-only, as its grant "clock", which base's runtime reads the wall clock
 * from. The supervisor holds the connection that sets the time; with test_clock on the kernel's command line, it sets
 * it to TEST_CLOCK_TIME before it starts anything else. Like a driver, the clock service is started again if it ends
 * other than by exiting with 0, with the real-time clock given again.
 *
 * The events service (decisions/0093) is started before anything else: everything after it is given a ring for its log
 * records, which the supervisor asks the events service for under the service's name, as its grants "events". Once the
 * storage manager has given the system volume, the events service keeps records in its "events" directory. With
 * test_events on the kernel's command line, a query waits for hello's first record from before hello starts, and once
 * everything has, records of hello's and the clock service's are read back from the system volume.
 *
 * The bundle store (decisions/0094) is started once the storage manager has given the system volume, with its "store"
 * directory, made if it isn't there; the supervisor keeps the other end of its listener. With test_store on the kernel's
 * command line, once everything has started, the supervisor puts hello's program in it and reads it back as paged
 * memory, is refused one whose bytes don't have the hash given, and sees an object kept while it's pinned and
 * collected once it isn't.
 *
 * The storage manager (decisions/0086, 0087), started when there's a disk, is given connectors to every disk's driver,
 * the process manager, and the partition server's and FAT server's modules; the disk check a connector to it, and the
 * first EFI system partition's root, which it asks the storage manager for, as its working directory.
 */
package supervisor

import runtime from "base"
import os from "std"
import text_buffer from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import log_line from "../../log_line"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import console_log from "../../protocols/console_log"
import entropy from "../../protocols/entropy"
import input from "../../protocols/input"
import platform from "../../protocols/platform"
import scheduler_protocol from "../../protocols/scheduler"
import serial from "../../protocols/serial"
import storage from "../../protocols/storage"
import supervision from "../../protocols/supervision"
import clock_setting from "../../protocols/clock_setting"
import events from "../../protocols/events"
import bundle_store from "../../protocols/bundle_store"
import bundle from "../../bundle"
import schema from "std"
import service_kit from "../../service_kit"
import system_config from "../../system_config"
import hello from "../../apps/hello"
import clock_service from "../clock"
import events_service from "../events_service"
import bundle_store_service from "../bundle_store_service"
import console from "../console"
import disk_check from "../disk_check"
import storage_manager from "../storage_manager"
import edu_dma from "../../drivers/edu_dma"
import virtio_blk from "../../drivers/virtio_blk"
import virtio_console from "../../drivers/virtio_console"
import virtio_input from "../../drivers/virtio_input"
import virtio_rng from "../../drivers/virtio_rng"

MAX_STARTED :: 24
MAX_CONNECTORS :: 16
// Connectors are bound to the port from here on, what it started below
CONNECTOR_KEY : u64 : 1000
// Drivers' devices are bound from here on, for their DMA faults, each by its index in what it started
FAULT_KEY : u64 : 2000
// The key of a connection of its own to the storage manager, while it waits on one
STORAGE_KEY : u64 : 3000
/*
 * The system volume's connection is watched for its other end closing under this key plus its generation, a number of
 * opens, so a close of one already replaced is told apart
 */
SYSTEM_KEY : u64 : 4000
SYSTEM_GENERATIONS : u64 : 1000
// The timer a lost system volume is opened again on, and how soon after it's tried and fails
SYSTEM_RETRY_KEY : u64 : 5000
SYSTEM_RETRY : u64 : 100_000_000
RESTARTS : u32 : 3
// How long a restart waits for its service's budget to come back, and what it leaves for the launch itself
RESTART_BUDGET_WAIT : u64 : 2_000_000_000
RESTART_BUDGET_SPARE : u64 : 256 * 1024
RESTART_WINDOW : u64 : 60_000_000_000
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
NOWHERE : usize : 0xffffffffffffffff
PAGE : u64 : 4096
// What test_clock sets the time to: 2030-01-02T03:04:05Z, in nanoseconds since 1970
TEST_CLOCK_TIME : i64 : 1_893_553_445_000_000_000
// How long test_restart waits once the console has dialed its serial line, for its banner to be shown, before it kills
// the line's driver, and once it's dialed it again, before it says everything has started
TEST_RESTART_PAUSE : u64 : 500_000_000

// Which protocol a listener speaks, so a connector dials it with that protocol's Connect.
Speaks :: enum {
    Nothing,
    Serial,
    Block,
    Input,
    ConsoleLog,
    Storage,
}

// What the clock service is given (clock.main): the real-time clock, its ports or its registers, and the clock page to write.
ClockGrants :: struct {
    rtc_ports : slop_os.IoPortRange?,
    rtc_registers : slop_os.Memory?,
    clock_page : slop_os.Memory,
    clients : os.Listener[clock_setting.ClockSetting],
}

// What the events service is given (events_service.main).
EventsGrants :: struct {
    log : slop_os.DebugLog?,
    clients : os.Listener[events.Events],
}

// What the bundle store is given (bundle_store_service.main).
StoreGrants :: struct {
    store : os.Channel[dir.Dir],
    clients : os.Listener[bundle_store.BundleStore],
}

// What hello is given (hello.main).
HelloGrants :: struct {
    manager : os.Channel[process_manager.ProcessManager]?,
    console : os.Channel[connector.Connector]?,
}

// What the console service is given (console.main).
ConsoleGrants :: struct {
    log : slop_os.DebugLog?,
    serial_line : os.Channel[connector.Connector]?,
    keyboard : os.Channel[connector.Connector]?,
    clients : os.Listener[console_log.ConsoleLog],
}

// What the disk check is given (disk_check.main).
DiskCheckGrants :: struct {
    log : slop_os.DebugLog?,
    storage : os.Channel[connector.Connector]?,
    working_directory : os.Channel[dir.Dir]?,
    system : os.Channel[dir.Dir]?,
}

MaybeConnector :: os.Channel[connector.Connector]?

// What the storage manager is given (storage_manager.main): connectors to up to four disks.
StorageGrants :: struct {
    log : slop_os.DebugLog?,
    manager : os.Channel[process_manager.ProcessManager],
    partition_server_module : slop_os.Memory,
    fat_server_module : slop_os.Memory,
    container_service_module : slop_os.Memory,
    volume_server_module : slop_os.Memory,
    disk0 : os.Channel[connector.Connector]?,
    disk1 : os.Channel[connector.Connector]?,
    disk2 : os.Channel[connector.Connector]?,
    disk3 : os.Channel[connector.Connector]?,
    clients : os.Listener[storage.Storage],
    command_line : slop_os.Memory?,
}

// What a virtio-rng driver is given (virtio_rng.main): its device, and a connection to the entropy service.
VirtioRngGrants :: struct {
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
    entropy_service : os.Channel[entropy.Entropy]?,
}

// What a driver that's given only its device is given (edu_dma.main).
DeviceGrants :: struct {
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
}

// What a driver that serves clients is given (virtio_console.main, virtio_blk.main, virtio_input.main): its device, and a
// listener for them.
ServingGrants :: struct[P] {
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
    clients : os.Listener[P],
}

// The modules of what the supervisor starts.
Modules :: struct {
    events : slop_os.Memory?,
    bundle_store : slop_os.Memory?,
    clock : slop_os.Memory?,
    hello : slop_os.Memory?,
    console : slop_os.Memory?,
    disk_check : slop_os.Memory?,
    virtio_blk : slop_os.Memory?,
    virtio_console : slop_os.Memory?,
    virtio_input : slop_os.Memory?,
    virtio_rng : slop_os.Memory?,
    edu_dma : slop_os.Memory?,
    storage_manager : slop_os.Memory?,
    partition_server : slop_os.Memory?,
    fat_server : slop_os.Memory?,
    container_service : slop_os.Memory?,
    volume_server : slop_os.Memory?,
}

// Something it started.
Started :: struct {
    name : string,
    process : slop_os.Process,
    running : bool,
    // The listener its clients are connected through, and what it speaks; NONE and Nothing without
    listener : slop_os.Channel,
    speaks : Speaks,
    // A driver's: its service, by index in SERVICES, and its device's address; its restarts since restarts_since
    driver : bool,
    service : usize,
    address : u32,
    restarts : u32,
    restarts_since : u64,
    // A driver's: a handle to its Device, which the port watches for its DMA faults; NO_HANDLE without
    watch : slop_os.Handle,
    // The clock service, a driver whose device is the real-time clock
    clock : bool,
    // Its program's budget, closed once it's ended, so what it had comes back; and its ring for its log records, which
    // the supervisor owns, given back to the events service once it's ended
    budget : slop_os.MemoryBudget,
    ring : slop_os.Memory,
    // Ended, and not to be started again
    done : bool,
}

// A connector the supervisor serves: its end, what it dials, by index in started, and how many times it has.
Connector :: struct {
    end : slop_os.Channel,
    target : usize,
    dials : u32,
}

Supervisor :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    root : slop_os.Channel,
    root_port : slop_os.Port,
    platform_end : slop_os.Channel,
    platform_port : slop_os.Port,
    entropy_service : os.Channel[entropy.Entropy]?,
    // Its connection to the scheduler service, and the port its answers wake, or NONE without one
    scheduler_end : slop_os.Channel,
    scheduler_port : slop_os.Port,
    // The clock page, NO_HANDLE without; and its end of the clock service's listener, which sets the time, NONE without
    clock_page : slop_os.Memory,
    clock_setting : slop_os.Channel,
    clock_setting_port : slop_os.Port,
    // The budget of the program launched last, and its ring, until its entry takes them
    launched_budget : slop_os.MemoryBudget,
    launched_ring : slop_os.Memory,
    // Its end of the events service's listener, NONE without
    events_end : slop_os.Channel,
    events_port : slop_os.Port,
    // The storage manager's place in started, NOWHERE without one; and how many times the system volume was opened
    storage_slot : usize,
    system_generation : u64,
    // Its connection closed, and it's to be opened again; and whether it's being opened, which waits on the port meanwhile
    system_lost : bool,
    system_opening : bool,
    // The kernel's command line, to give on to the storage manager, which reads its test words
    command_line : slop_os.Memory?,
    // Its end of the bundle store's listener, NONE without
    store_end : slop_os.Channel,
    store_port : slop_os.Port,
    // The entry in started a restart is launching into, whose key its process is watched under; NOWHERE otherwise
    relaunching : usize,
    modules : Modules,
    // What it started, which its port watches under their indexes
    started : Started[MAX_STARTED],
    started_count : usize,
    connectors : Connector[MAX_CONNECTORS],
    connector_count : usize,
    port : slop_os.Port,
    // The first of each that a driver serves, by index in started, or NOWHERE
    first_serial : usize,
    first_disk : usize,
    first_keyboard : usize,
    console : usize,
    // The system volume's root, once the storage manager has given it, where programs outside the boot set come from
    system : slop_os.Channel,
    system_port : slop_os.Port,
    // Programs read from the system volume, by their services' places in system_config.SERVICES
    loaded : Loaded[MAX_LOADED],
}

// A program read from the system volume, if it's been read.
Loaded :: struct {
    module : slop_os.Memory?,
}

MAX_LOADED :: 32

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager], root: os.Channel[supervision.Supervision],
    hello_module: slop_os.Memory?, platform_service: os.Channel[platform.Platform]?, entropy_service: os.Channel[entropy.Entropy]?,
    console_module: slop_os.Memory?, disk_check_module: slop_os.Memory?, virtio_blk_module: slop_os.Memory?,
    virtio_console_module: slop_os.Memory?, virtio_input_module: slop_os.Memory?, virtio_rng_module: slop_os.Memory?,
    edu_dma_module: slop_os.Memory?, storage_manager_module: slop_os.Memory?, partition_server_module: slop_os.Memory?,
    fat_server_module: slop_os.Memory?, container_service_module: slop_os.Memory?, volume_server_module: slop_os.Memory?,
    command_line: slop_os.Memory?, scheduler: os.Channel[scheduler_protocol.Scheduler]?, clock_module: slop_os.Memory?,
    events_module: slop_os.Memory?, bundle_store_module: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    supervisor := Supervisor.{block = startup, manager = manager, root = root.end, platform_end = NONE, entropy_service = entropy_service,
        first_serial = NOWHERE, first_disk = NOWHERE, first_keyboard = NOWHERE, console = NOWHERE, system = NONE, scheduler_end = NONE, clock_page = cast[slop_os.Memory](slop_os.NO_HANDLE), clock_setting = NONE,
        events_end = NONE, store_end = NONE, relaunching = NOWHERE, storage_slot = NOWHERE, launched_ring = cast[slop_os.Memory](slop_os.NO_HANDLE), launched_budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)}
    supervisor.modules = Modules.{events = events_module, bundle_store = bundle_store_module, clock = clock_module, hello = hello_module, console = console_module, disk_check = disk_check_module, virtio_blk = virtio_blk_module,
        virtio_console = virtio_console_module, virtio_input = virtio_input_module, virtio_rng = virtio_rng_module, edu_dma = edu_dma_module,
        storage_manager = storage_manager_module, partition_server = partition_server_module, fat_server = fat_server_module,
        container_service = container_service_module, volume_server = volume_server_module}
    supervisor.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    supervisor.manager_port = os.port_for(startup.budget, manager.end) or_return 1
    supervisor.root_port = os.port_for(startup.budget, root.end) or_return 2
    supervisor.port = slop_os.port_create(startup.budget) or_return 3
    match scheduler {
        case Some(connection) => match os.port_for(startup.budget, connection.end) {
            case Some(port) => {
                supervisor.scheduler_end = connection.end
                supervisor.scheduler_port = port
            }
            case None => {}
        }
        case None => {}
    }
    test_restart := false
    test_dma_fault := false
    test_clock := false
    test_events := false
    test_restart_services := false
    test_store := false
    supervisor.command_line = command_line
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(startup, memory) or_else ""
            test_restart = service_kit.has_word(text, "test_restart")
            test_dma_fault = service_kit.has_word(text, "test_dma_fault")
            test_clock = service_kit.has_word(text, "test_clock")
            test_events = service_kit.has_word(text, "test_events")
            test_restart_services = service_kit.has_word(text, "test_restart_services")
            test_store = service_kit.has_word(text, "test_store")
        }
        case None => {}
    }

    // The boot set's drivers, for every device each takes, and the storage manager, which reaches the system volume
    match platform_service {
        case Some(platform_end) => {
            supervisor.platform_end = platform_end.end
            supervisor.platform_port = os.port_for(startup.budget, platform_end.end) or_return 4
        }
        case None => {}
    }
    // The events service first, so everything after it has a ring for its records; then the clock, so everything after
    // it reads the time from its page
    start_events(&supervisor, NOWHERE)
    supervisor.clock_page = slop_os.memory_create(startup.budget, PAGE) or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    start_clock(&supervisor, NOWHERE)
    if test_clock && supervisor.clock_setting != NONE {
        if !clock_setting.set(supervisor.clock_setting, supervisor.clock_setting_port, TEST_CLOCK_TIME) {
            log_line.write(supervisor.log, "supervisor: test_clock: the clock service didn't set the time")
        }
    }
    start_drivers(&supervisor, true)
    storage_slot :: start_storage(&supervisor, NOWHERE)
    supervisor.storage_slot = storage_slot
    if storage_slot != NOWHERE {
        open_system(&supervisor, storage_slot)
    }
    // A query for hello's first record, held from before hello starts, on a connection of its own
    waiting := Waiting.{end = NONE}
    if test_events {
        waiting = wait_for_hello(&supervisor)
    }
    // Then every other driver, and the services that use them, each with connectors to what it uses
    start_drivers(&supervisor, false)
    start_console(&supervisor, NOWHERE)
    start_hello(&supervisor, NOWHERE)
    start_disk_check(&supervisor, storage_slot)
    serial_line :: supervisor.first_serial
    if test_restart && serial_line < supervisor.started.count {
        // Once the console has its connection, which the driver's end takes with it
        loop {
            wait_and_handle(&supervisor)
        }
        while dials_of(&supervisor, serial_line) == 0
        // And has had time to show its banner through it
        pause(&supervisor, TEST_RESTART_PAUSE)
        if serial_line < supervisor.started.count {
            killed :: supervisor.started[serial_line]
            log_line.write(supervisor.log, "supervisor: test_restart: killing %", killed.name)
            _ = slop_os.process_kill(killed.process)
            // Not running from here, though its end arrives on the port later
            supervisor.started[serial_line].running = false
        }
        // Back once it's been started again, and the console has dialed it again
        loop {
            wait_and_handle(&supervisor)
        }
        while !is_running(&supervisor, serial_line) || dials_of(&supervisor, serial_line) < 2
        // And has had time to show its banner again, and echo what's typed after it, before the root task's last second
        pause(&supervisor, TEST_RESTART_PAUSE)
    }
    // The disk check is done once it's checked, which it reports before everything has started
    loop {
        wait_and_handle(&supervisor)
    }
    while !ended_for_good(&supervisor, "disk_check")
    if test_dma_fault {
        // Until edu_dma has ended for good: refused DMA memory and ended with 0, or killed too often
        loop {
            wait_and_handle(&supervisor)
        }
        while !ended_for_good(&supervisor, "edu_dma")
    }
    if test_events {
        check_events(&supervisor, waiting)
    }
    if test_store {
        check_store(&supervisor)
    }
    if test_restart_services {
        restart_services(&supervisor, storage_slot)
    }
    log_line.write(supervisor.log, "supervisor: started % services", supervisor.started_count)
    tell_root(&supervisor, .AllStarted(cast[u32](supervisor.started_count)))
    loop {
        wait_and_handle(&supervisor)
    }
}

/*
 * What arrives on the port: something it started ending, and connectors' Dials. Every connector is read until it's
 * empty, as each is once it's made, since only a read that finds nothing has a channel's next message wake the port.
 */
wait_and_handle :: fn(supervisor: ptr[mut Supervisor]) {
    packets : slop_os.Packet[8]
    taken :: slop_os.port_wait(supervisor.port, packets, slop_os.NO_DEADLINE) or_else 0
    for packet, i in packets {
        if i >= cast[usize](taken) {
            break
        }
        index :: cast[usize](packet.key)
        if packet.kind == .Signal && index < supervisor.started_count && index < supervisor.started.count {
            ended(supervisor, index, packet.data[1])
        }
        // The system volume's server ended, and its storage manager is still there: opened again through it
        if packet.kind == .Signal && packet.key >= SYSTEM_KEY && packet.key < SYSTEM_KEY + SYSTEM_GENERATIONS
            && packet.key - SYSTEM_KEY == supervisor.system_generation % SYSTEM_GENERATIONS && is_running(supervisor, supervisor.storage_slot) {
            log_line.write(supervisor.log, "supervisor: the system volume's connection closed; opening it again")
            supervisor.system_lost = true
        }
        faulted :: cast[usize](packet.key - FAULT_KEY)
        if packet.kind == .Signal && packet.key >= FAULT_KEY && faulted < supervisor.started_count && faulted < supervisor.started.count {
            dma_fault(supervisor, faulted, packet.data[1])
        }
    }
    for i in 0..<supervisor.connector_count {
        serve_connector(supervisor, i)
    }
    // Opened again once the storage manager serves it again, tried again a little later until then
    if supervisor.system_lost && !supervisor.system_opening && is_running(supervisor, supervisor.storage_slot) {
        supervisor.system_lost = false
        reopened_from :: supervisor.system_generation
        open_system(supervisor, supervisor.storage_slot)
        if supervisor.system_generation == reopened_from {
            supervisor.system_lost = true
            _ = slop_os.port_set_timer(supervisor.port, SYSTEM_RETRY_KEY, (slop_os.clock_monotonic() or_else 0) + SYSTEM_RETRY)
        }
    }
}

// Something it started has ended with code: a driver that crashed or was killed, started again while it may be.
ended :: fn(supervisor: ptr[mut Supervisor], index: usize, code: u64) {
    if index >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[index]
    entry.running = false
    log_line.write(supervisor.log, "supervisor: % ended", entry.name)
    if cast[slop_os.Handle](entry.budget) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](entry.budget))
        entry.budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    }
    retire_ring(supervisor, entry.ring)
    entry.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    tell_root(supervisor, .Ended(report_of(entry.name, code)))
    if cast[slop_os.Handle](entry.listener) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](entry.listener))
        entry.listener = NONE
    }
    if cast[slop_os.Handle](entry.watch) != slop_os.NO_HANDLE {
        _ = slop_os.port_unbind(supervisor.port, FAULT_KEY + cast[u64](index))
        _ = slop_os.handle_close(entry.watch)
        entry.watch = slop_os.NO_HANDLE
    }
    not_restarted := true
    budget : u64 = 0
    match system_config.service(entry.name) {
        case Some(service) => {
            not_restarted = service.not_restarted
            budget = service.budget
        }
        case None => {}
    }
    if code == 0 || not_restarted {
        entry.done = true
        return void
    }
    now :: slop_os.clock_monotonic() or_else 0
    if now - entry.restarts_since > RESTART_WINDOW {
        entry.restarts = 0
        entry.restarts_since = now
    }
    if entry.restarts >= RESTARTS {
        log_line.write(supervisor.log, "supervisor: % ended % times in a minute, and isn't started again", entry.name, RESTARTS + 1)
        entry.done = true
        return void
    }
    entry.restarts += 1
    wait_for_budget(supervisor, budget)
    // The last process's binding still has the key, though it fired: the next is watched under it from its launch
    _ = slop_os.port_unbind(supervisor.port, cast[u64](index))
    if !entry.driver || entry.clock {
        supervisor.relaunching = index
        if entry.clock {
            start_clock(supervisor, index)
        }
        else {
            restart_service(supervisor, index)
        }
        supervisor.relaunching = NOWHERE
        if entry.running {
            log_line.write(supervisor.log, "supervisor: restarted %", entry.name)
        }
        return void
    }
    device :: request_device(supervisor, .Reissue(entry.address)) or_return void
    supervisor.relaunching = index
    start_driver(supervisor, entry.service, device, index)
    supervisor.relaunching = NOWHERE
    if entry.running {
        log_line.write(supervisor.log, "supervisor: restarted %", entry.name)
    }
}

/*
 * Until the supervisor's budget has bytes to split off, or RESTART_BUDGET_WAIT has passed: what the last process had
 * comes back once its subtree is gone and a grace period has passed, and a big service's budget can't be split off
 * twice.
 */
wait_for_budget :: fn(supervisor: ptr[mut Supervisor], bytes: u64) {
    give_up :: (slop_os.clock_monotonic() or_else 0) + RESTART_BUDGET_WAIT
    loop {
        info :: slop_os.memory_budget_info(supervisor.block.budget) or_return void
        if info.used <= info.limit && info.limit - info.used >= bytes + RESTART_BUDGET_SPARE {
            return void
        }
        if (slop_os.clock_monotonic() or_else 0) >= give_up {
            return void
        }
        pause(supervisor, 10_000_000)
    }
}

// A service that isn't a driver, started again into its entry at index, as it was started.
restart_service :: fn(supervisor: ptr[mut Supervisor], index: usize) {
    name :: supervisor.started[index % supervisor.started.count].name
    if name == "events" {
        start_events(supervisor, index)
        adopt_rings(supervisor, index)
        store_events(supervisor)
    }
    else if name == "console" {
        start_console(supervisor, index)
    }
    else if name == "hello" {
        start_hello(supervisor, index)
    }
    else if name == "bundle_store" {
        start_store(supervisor, index)
    }
    else if name == "storage_manager" {
        if start_storage(supervisor, index) != NOWHERE {
            open_system(supervisor, index)
        }
    }
}

/*
 * What's started under name, into its entry at again if that isn't NOWHERE, a restart, or a new one: its index, or
 * MAX_STARTED if there's no room for it.
 */
place :: fn(supervisor: ptr[mut Supervisor], name #escaping : string, process: slop_os.Process, again: usize) -> usize {
    if again == NOWHERE {
        return started(supervisor, name, process)
    }
    if again >= supervisor.started.count {
        return MAX_STARTED
    }
    entry :: &supervisor.started[again]
    entry.process = process
    entry.budget = take_budget(supervisor)
    entry.ring = take_ring(supervisor)
    entry.running = true
    entry.done = false
    tell_root(supervisor, .Started(report_of(name, 0)))
    return again
}

/*
 * The storage manager at storage_slot's SlopOS container's system volume, where programs outside the boot set come
 * from, given to the events service to keep records in, and to the bundle store, started the first time. Its
 * connection is watched, and opened again when it closes, as when the volume's server is started again (decisions/0098).
 */
open_system :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize) {
    if supervisor.system_opening {
        return void
    }
    supervisor.system_opening = true
    defer supervisor.system_opening = false
    match files_of_type(supervisor, storage_slot, storage_manager.CONTAINER_TYPE) {
        case Some(root) => {
            if supervisor.system != NONE {
                _ = slop_os.port_unbind(supervisor.port, SYSTEM_KEY + supervisor.system_generation % SYSTEM_GENERATIONS)
                _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.system))
                _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.system_port))
            }
            supervisor.system_generation += 1
            supervisor.system = root.end
            supervisor.system_port = os.port_for(supervisor.block.budget, root.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
            _ = slop_os.port_bind(supervisor.port, cast[slop_os.Handle](root.end), slop_os.SIGNAL_PEER_CLOSED,
                SYSTEM_KEY + supervisor.system_generation % SYSTEM_GENERATIONS, .Once)
            store_events(supervisor)
            if supervisor.store_end == NONE {
                start_store(supervisor, NOWHERE)
            }
            else {
                match system_directory(supervisor, "store") {
                    case Some(directory) => _ = store_request(supervisor, .UseDirectory(directory))
                    case None => {}
                }
            }
        }
        case None => {}
    }
}

/*
 * test_restart_services: the events service, the clock service and the storage manager, if it was started, each killed
 * and checked once it's back: the events service by a record of the clock service's, started again after it, the clock
 * service by setting the time, and the storage manager by giving the system volume again.
 */
restart_services :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize) {
    if !kill_and_wait(supervisor, "events") {
        return void
    }
    if !kill_and_wait(supervisor, "clock") {
        return void
    }
    if supervisor.clock_setting != NONE && clock_setting.set(supervisor.clock_setting, supervisor.clock_setting_port, TEST_CLOCK_TIME) {
        log_line.write(supervisor.log, "supervisor: test_restart_services: the clock service, started again, set the time")
    }
    if supervisor.events_end != NONE {
        out := os.Outgoing.{}
        request :: os.begin[events.Request](&out)
        request^ = .Query(events.QueryOf.{source = bytes_of(&out, "clock"), from = 1, level = 0, wait = true})
        into := os.Incoming.{}
        match events.ask(supervisor.events_end, supervisor.events_port, &out, &into) {
            case Found(found) => log_line.write(supervisor.log,
                "supervisor: test_restart_services: the events service, started again, has the clock service's record %: %", found.number,
                text_of_items(os.items(&into, found.text)))
            case _ => log_line.write(supervisor.log, "supervisor: test_restart_services: the events service has no record of the clock service")
        }
    }
    if storage_slot == NOWHERE {
        return void
    }
    // The first disk's partition server killed, so the system volume's server goes with it, and is served again
    reopened_from :: supervisor.system_generation
    match ask_storage_once(supervisor, storage_slot, .TestRestart(0)) {
        case Done => {
            loop {
                wait_and_handle(supervisor)
            }
            while supervisor.system_generation == reopened_from
            manifest_read := false
            match stored_hash(supervisor, "hello", 1) {
                case Some(manifest) => {
                    match mapped_object(supervisor, manifest) {
                        case Some(object) => {
                            manifest_read = object.bytes.count >= 4 && object.bytes[0] == 0x48 && object.bytes[1] == 0x53
                            unmap_object(supervisor, object)
                        }
                        case None => {}
                    }
                }
                case None => {}
            }
            log_line.write(supervisor.log, "supervisor: test_restart_services: the system volume, served again after disk 0's partition server was, %",
                if manifest_read { "and the bundle store reads through it" } else { "but the bundle store can't read through it" })
        }
        case _ => log_line.write(supervisor.log, "supervisor: test_restart_services: the storage manager didn't restart disk 0's partition server")
    }
    old_generation :: supervisor.system_generation
    restarted :: kill_and_wait(supervisor, "storage_manager")
    // The system volume opened again through the new one, once it serves it
    if restarted {
        loop {
            if supervisor.system_generation != old_generation {
                break
            }
            wait_and_handle(supervisor)
        }
    }
    if restarted && supervisor.system != NONE {
        log_line.write(supervisor.log, "supervisor: test_restart_services: the storage manager, started again, gave the system volume")
    }
}

// What's started under name killed, and waited for until it's been started again: whether it has.
kill_and_wait :: fn(supervisor: ptr[mut Supervisor], name: string) -> bool {
    index := NOWHERE
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.name == name && entry.running {
            index = i
        }
    }
    if index >= supervisor.started.count {
        return false
    }
    restarts :: supervisor.started[index].restarts
    log_line.write(supervisor.log, "supervisor: test_restart_services: killing %", name)
    _ = slop_os.process_kill(supervisor.started[index].process)
    // Not running from here, though its end arrives on the port later
    supervisor.started[index].running = false
    loop {
        wait_and_handle(supervisor)
    }
    while !supervisor.started[index].done && !(supervisor.started[index].running && supervisor.started[index].restarts > restarts)
    return supervisor.started[index].running
}

// A driver whose device's DMA an IOMMU blocked, at address: killed, if it's running, and so started again as one that crashed.
dma_fault :: fn(supervisor: ptr[mut Supervisor], index: usize, address: u64) {
    entry :: &supervisor.started[index % supervisor.started.count]
    if !entry.running {
        return void
    }
    log_line.write(supervisor.log, "supervisor: %'s DMA was blocked, at %; killing it", entry.name, cast[rawptr](address))
    _ = slop_os.process_kill(entry.process)
    // Not running from here, though its end arrives on the port later
    entry.running = false
}

// Whether what's named name was started and has ended for good, or wasn't started.
ended_for_good :: fn(supervisor: ptr[Supervisor], name: string) -> bool {
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.name == name {
            return entry.done
        }
    }
    return true
}

/*
 * A driver for a device, the service at index in SERVICES, with what it holds of the device; into the started entry
 * again, a restart, unless again is NOWHERE. The device's handles go to it, or are closed.
 */
start_driver :: fn(supervisor: ptr[mut Supervisor], index: usize, device: platform.PciDevice, again: usize) {
    if index >= system_config.SERVICES.count {
        close_device(&device)
        return void
    }
    service :: system_config.SERVICES[index]
    // A handle of its own to the device, for its DMA faults, which goes stale once the device does
    watch :: slop_os.handle_duplicate(cast[slop_os.Handle](device.device), cast[slop_os.Rights](0)) or_else slop_os.NO_HANDLE
    launched := cast[slop_os.Process](slop_os.NO_HANDLE)
    listener := NONE
    speaks := Speaks.Nothing
    // Each by its constant name, which outlives the service's copy
    name := ""
    if service.name == "virtio_rng" {
        name = "virtio_rng"
        launched = launch_virtio_rng(supervisor, service, device)
    }
    else if service.name == "virtio_console" {
        name = "virtio_console"
        speaks = .Serial
        pair :: listener_for[serial.Serial](supervisor, &device) or_return void
        listener = pair.b
        launched = launch_serving[serial.Serial](supervisor, service, device, pair.a, virtio_console.main)
    }
    else if service.name == "virtio_blk" {
        name = "virtio_blk"
        speaks = .Block
        pair :: listener_for[block.Block](supervisor, &device) or_return void
        listener = pair.b
        launched = launch_serving[block.Block](supervisor, service, device, pair.a, virtio_blk.main)
    }
    else if service.name == "virtio_input" {
        name = "virtio_input"
        speaks = .Input
        pair :: listener_for[input.Input](supervisor, &device) or_return void
        listener = pair.b
        launched = launch_serving[input.Input](supervisor, service, device, pair.a, virtio_input.main)
    }
    else if service.name == "edu_dma" {
        name = "edu_dma"
        launched = launch_device_only(supervisor, service, device, edu_dma.main)
    }
    else {
        close_device(&device)
        if watch != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(watch)
        }
        return void
    }
    if cast[slop_os.Handle](launched) == slop_os.NO_HANDLE {
        if cast[slop_os.Handle](listener) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](listener))
        }
        if watch != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(watch)
        }
        return void
    }
    slot :: if again != NOWHERE { again } else { started(supervisor, name, launched) }
    if slot >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[slot]
    entry.process = launched
    if again != NOWHERE {
        entry.budget = take_budget(supervisor)
        entry.ring = take_ring(supervisor)
    }
    entry.running = true
    entry.listener = listener
    entry.speaks = speaks
    entry.driver = true
    entry.service = index
    entry.address = device.address
    entry.done = false
    entry.watch = watch
    if watch != slop_os.NO_HANDLE {
        _ = slop_os.port_bind(supervisor.port, watch, slop_os.SIGNAL_DMA_FAULT, FAULT_KEY + cast[u64](slot), .Persistent)
    }
    if again != NOWHERE {
        tell_root(supervisor, .Started(report_of(name, 0)))
    }
    // The first of each kind is what the services are given
    if speaks == .Serial && supervisor.first_serial == NOWHERE {
        supervisor.first_serial = slot
    }
    if speaks == .Block && supervisor.first_disk == NOWHERE {
        supervisor.first_disk = slot
    }
    if speaks == .Input && supervisor.first_keyboard == NOWHERE {
        supervisor.first_keyboard = slot
    }
}

// A channel for a driver's listener, or null with the device closed.
listener_for :: fn[P](supervisor: ptr[mut Supervisor], device: ptr[platform.PciDevice]) -> slop_os.ChannelPair? {
    match os.channel_for[P](supervisor.block.budget, 0) {
        case Ok(made) => return made
        case Error(error) => {
            close_device(device)
            return null
        }
    }
}

// A driver that serves clients of P, launched with its device and the listener's end: its process, or NO_HANDLE.
launch_serving :: fn[P](supervisor: ptr[mut Supervisor], service: system_config.Service, device: platform.PciDevice,
    end: slop_os.Channel, entry: (fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?,
    bar1: slop_os.Memory?, bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?,
    domain: slop_os.DmaDomain, clients: os.Listener[P]) -> int)) -> slop_os.Process {
    grants := ServingGrants[P].{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5), clients = os.Listener[P].{end = end}}
    executable :: module_of(supervisor, service.name)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, entry, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => return kept(supervisor, launched)
        case Error(error) => {
            failed(supervisor, service.name, error)
            return cast[slop_os.Process](slop_os.NO_HANDLE)
        }
    }
}

// A driver given only its device: its process, or NO_HANDLE.
launch_device_only :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service, device: platform.PciDevice,
    entry: (fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain) -> int))
    -> slop_os.Process {
    grants := DeviceGrants.{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5)}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        entry, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => return kept(supervisor, launched)
        case Error(error) => {
            failed(supervisor, service.name, error)
            return cast[slop_os.Process](slop_os.NO_HANDLE)
        }
    }
}

// A driver for a virtio entropy device, with a connection of its own to the entropy service: its process, or NO_HANDLE.
launch_virtio_rng :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service, device: platform.PciDevice) -> slop_os.Process {
    grants := VirtioRngGrants.{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5)}
    match supervisor.entropy_service {
        case Some(service_end) => {
            entropy_port :: os.port_for(supervisor.block.budget, service_end.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
            grants.entropy_service = entropy.connect(service_end.end, entropy_port, supervisor.block.budget)
        }
        case None => {}
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        virtio_rng.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => return kept(supervisor, launched)
        case Error(error) => {
            failed(supervisor, service.name, error)
            return cast[slop_os.Process](slop_os.NO_HANDLE)
        }
    }
}

/*
 * A service's program: one outside the boot set from the system volume, read once and kept, once the storage manager
 * has given it; otherwise, or where it isn't there, Limine's module.
 */
/*
 * What launching the service named name does beyond its grants: watch its end, run it on the CPU budget the scheduler
 * service gives it, and give it the clock page, read-only, and a ring for its log records.
 */
options_for :: fn(supervisor: ptr[mut Supervisor], name: string) -> os.LaunchOptions {
    options := os.LaunchOptions.{}
    if supervisor.scheduler_end != NONE {
        options.cpu_budget = scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, name)
    }
    // Its end watched from before it starts, under the key of the entry it's to have: one that ends at once is seen to
    options.watch = os.LaunchWatch.{port = supervisor.port, key = cast[u64](next_slot(supervisor))}
    if cast[slop_os.Handle](supervisor.clock_page) != slop_os.NO_HANDLE {
        rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
        match slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.clock_page), rights) {
            case Ok(copy) => options.clock = cast[slop_os.Memory](copy)
            case Error(error) => {}
        }
    }
    // A ring for its records, which the supervisor keeps, giving the program a handle to it that doesn't own it
    if supervisor.events_end != NONE {
        match events.open(supervisor.events_end, supervisor.events_port, name) {
            case Some(opened) => {
                rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE)
                    | cast[u32](slop_os.RIGHT_TRANSFER))
                match slop_os.handle_duplicate(cast[slop_os.Handle](opened.ring), rights) {
                    case Ok(copy) => {
                        retire_ring(supervisor, supervisor.launched_ring)
                        supervisor.launched_ring = opened.ring
                        options.events = os.LaunchEvents.{ring = cast[slop_os.Memory](copy), doorbell = opened.doorbell}
                    }
                    case Error(error) => {
                        _ = slop_os.handle_close(cast[slop_os.Handle](opened.ring))
                        _ = slop_os.handle_close(cast[slop_os.Handle](opened.doorbell))
                    }
                }
            }
            case None => {}
        }
    }
    return options
}

/*
 * A ring a program that's ended had, given back to the events service, which reads its last records and closes it; or
 * closed, without one.
 */
retire_ring :: fn(supervisor: ptr[mut Supervisor], ring: slop_os.Memory) {
    if cast[slop_os.Handle](ring) == slop_os.NO_HANDLE {
        return void
    }
    if supervisor.events_end != NONE {
        out := os.Outgoing.{}
        request :: os.begin[events.Request](&out)
        request^ = .Retire(ring)
        into := os.Incoming.{}
        match events.ask(supervisor.events_end, supervisor.events_port, &out, &into) {
            case Done => return void
            case _ => {}
        }
    }
    // Not taken, if it wasn't sent
    _ = slop_os.handle_close(cast[slop_os.Handle](ring))
}

/*
 * The rings of what's still running given to an events service started again into its entry at events_slot, as the
 * last one's went with it, so it reads their records from where that one stopped.
 */
adopt_rings :: fn(supervisor: ptr[mut Supervisor], events_slot: usize) {
    if supervisor.events_end == NONE {
        return void
    }
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    for entry, i in supervisor.started {
        if i != events_slot && entry.running && cast[slop_os.Handle](entry.ring) != slop_os.NO_HANDLE {
            match slop_os.handle_duplicate(cast[slop_os.Handle](entry.ring), rights) {
                case Ok(copy) => {
                    out := os.Outgoing.{}
                    request :: os.begin[events.Request](&out)
                    request^ = .Adopt(events.AdoptOf.{source = bytes_of(&out, entry.name), ring = cast[slop_os.Memory](copy)})
                    into := os.Incoming.{}
                    _ = events.ask(supervisor.events_end, supervisor.events_port, &out, &into)
                }
                case Error(error) => {}
            }
        }
    }
}

// The ring kept for the program launched last, for its entry.
take_ring :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.Memory {
    ring :: supervisor.launched_ring
    supervisor.launched_ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    return ring
}

// The events service, with a listener whose other end the supervisor keeps; into its entry at again, unless that's NOWHERE.
start_events :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: system_config.service("events") or_return void
    // The last one's end, which went with it
    if supervisor.events_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.events_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.events_port))
        supervisor.events_end = NONE
    }
    pair :: os.channel_for[events.Events](supervisor.block.budget, 0) or_return void
    grants := EventsGrants.{log = duplicate_log(supervisor), clients = os.Listener[events.Events].{end = pair.a}}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        events_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            _ = place(supervisor, "events", kept(supervisor, launched), again)
            supervisor.events_end = pair.b
            supervisor.events_port = os.port_for(supervisor.block.budget, pair.b) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/*
 * The bundle store, with the system volume's "store" directory, made if it isn't there, and a listener whose other end
 * the supervisor keeps; into its entry at again, unless that's NOWHERE.
 */
start_store :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: system_config.service("bundle_store") or_return void
    directory :: system_directory(supervisor, "store") or_return void
    if supervisor.store_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.store_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.store_port))
        supervisor.store_end = NONE
    }
    pair :: os.channel_for[bundle_store.BundleStore](supervisor.block.budget, 0) or_return void
    grants := StoreGrants.{store = directory, clients = os.Listener[bundle_store.BundleStore].{end = pair.a}}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        bundle_store_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            _ = place(supervisor, "bundle_store", kept(supervisor, launched), again)
            supervisor.store_end = pair.b
            supervisor.store_port = os.port_for(supervisor.block.budget, pair.b) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

// A directory of the system volume's root, made if it isn't there, or null.
system_directory :: fn(supervisor: ptr[mut Supervisor], name: string) -> os.Channel[dir.Dir]? {
    if supervisor.system == NONE {
        return null
    }
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, name), create = true})
    if dir.send_request(supervisor.system, supervisor.system_port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(supervisor.system, supervisor.system_port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => continue
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case OpenedDirectory(opened) => opened
        case _ => null
    }
}

/*
 * test_store, once everything has started: hello's program put in the bundle store and read back as paged memory,
 * whole; one whose bytes don't have the hash given refused; and the program kept while it's pinned, and collected once
 * it isn't.
 */
check_store :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.store_end == NONE {
        log_line.write(supervisor.log, "supervisor: test_store: no bundle store")
        return void
    }
    module :: module_of(supervisor, "hello")
    size :: slop_os.memory_size(module) or_else 0
    address :: map_in(supervisor, module, size, slop_os.PROTECTION_READ)
    if address == 0 {
        log_line.write(supervisor.log, "supervisor: test_store: hello's program couldn't be read")
        return void
    }
    program :: view_of(cast[ptr[u8]](address), cast[usize](size))
    hash :: bundle.hash_of(program)
    put :: put_object(supervisor, hash, program)
    wrong := hash
    wrong.bytes[0] = wrong.bytes[0] ~ 1
    refused :: !put_object(supervisor, wrong, program)
    // Read back through paged memory, every byte
    read_back := false
    match store_request(supervisor, .Get(hash)) {
        case Got(object) => {
            mapped :: map_in(supervisor, object.memory, (object.size + 4095) & ~cast[u64](4095), slop_os.PROTECTION_READ)
            if mapped != 0 && object.size == size {
                read_back = true
                for byte, i in program {
                    if cast[ptr[u8]](cast[rawptr](mapped + cast[u64](i)))^ != byte {
                        read_back = false
                        break
                    }
                }
                _ = slop_os.memory_unmap(supervisor.block.space, mapped)
            }
            _ = slop_os.handle_close(cast[slop_os.Handle](object.memory))
        }
        case _ => {}
    }
    _ = slop_os.memory_unmap(supervisor.block.space, address)
    // Another object, never read, kept while it's pinned and collected once it isn't
    other :: "an object only a pin keeps"
    other_bytes :: view_of(cast[ptr[u8]](other.data), other.count)
    other_hash :: bundle.hash_of(other_bytes)
    _ = put_object(supervisor, other_hash, other_bytes)
    pin_out := os.Outgoing.{}
    pin :: os.begin[bundle_store.Request](&pin_out)
    pin^ = .Pin(bundle_store.PinOf.{name = bytes_of(&pin_out, "test"), hash = other_hash})
    pin_into := os.Incoming.{}
    _ = bundle_store.ask(supervisor.store_end, supervisor.store_port, &pin_out, &pin_into)
    while_pinned :: collected(supervisor)
    unpin_out := os.Outgoing.{}
    unpin :: os.begin[bundle_store.Request](&unpin_out)
    unpin^ = .Unpin(bytes_of(&unpin_out, "test"))
    unpin_into := os.Incoming.{}
    _ = bundle_store.ask(supervisor.store_end, supervisor.store_port, &unpin_out, &unpin_into)
    once_unpinned :: collected(supervisor)
    log_line.write(supervisor.log, "supervisor: test_store: put hello's program, read it back % as paged memory, a wrong hash %; a pinned object kept (% collected), and collected once unpinned (%)",
        if put && read_back { "whole" } else { "not whole" }, if refused { "refused" } else { "taken" }, while_pinned, once_unpinned)
    // The manifest the build wrote for hello is the schema of its entry's type, as it's worked out here
    expected :: bundle.Hash.{bytes = schema.hash(type_info_of(type_of(hello.main)))}
    manifest :: stored_hash(supervisor, "hello", 1)
    matches :: match manifest {
        case Some(stored) => bundle.same(stored, expected)
        case None => false
    }
    log_line.write(supervisor.log, "supervisor: test_store: hello's bundle's manifest % its entry's schema", if matches { "is" } else { "isn't" })
}

// What the bundle store's Collect removed, or 99 if it didn't answer.
collected :: fn(supervisor: ptr[mut Supervisor]) -> u64 {
    return match store_request(supervisor, .Collect) {
        case Collected(count) => count
        case _ => cast[u64](99)
    }
}

// Memory mapped in the supervisor's space, size bytes of it: where, or 0.
map_in :: fn(supervisor: ptr[mut Supervisor], memory: slop_os.Memory, size: u64, protection: slop_os.Protection) -> u64 {
    if size == 0 {
        return 0
    }
    address :: runtime.reserve_addresses(cast[usize](size)) or_return 0
    if slop_os.memory_map(memory, supervisor.block.space, address, 0, size, protection) is_error {
        return 0
    }
    return address
}

// An object put in the bundle store from a copy of bytes: whether it took it.
put_object :: fn(supervisor: ptr[mut Supervisor], hash: bundle.Hash, bytes: u8[]) -> bool {
    size :: (cast[u64](bytes.count) + 4095) & ~cast[u64](4095)
    data :: slop_os.memory_create(supervisor.block.budget, if size == 0 { cast[u64](4096) } else { size }) or_return false
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    address :: map_in(supervisor, data, size, read_write)
    if address == 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](data))
        return false
    }
    for byte, i in bytes {
        cast[ptr[mut u8]](cast[rawptr](address + cast[u64](i)))^ = byte
    }
    _ = slop_os.memory_unmap(supervisor.block.space, address)
    return match store_request(supervisor, .Put(bundle_store.PutOf.{hash = hash, size = cast[u64](bytes.count), data = data})) {
        case Done => true
        case _ => false
    }
}

store_request :: fn(supervisor: ptr[mut Supervisor], request: bundle_store.Request) -> bundle_store.Response {
    out := os.Outgoing.{}
    made :: os.begin[bundle_store.Request](&out)
    made^ = request
    into := os.Incoming.{}
    return bundle_store.ask(supervisor.store_end, supervisor.store_port, &out, &into)
}

// The system volume's "events" directory, made if it isn't there, given to the events service to keep records in.
store_events :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.events_end == NONE || supervisor.system == NONE {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[dir.Request](&out)
    request^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "events"), create = true})
    if dir.send_request(supervisor.system, supervisor.system_port, &out) is_some {
        return void
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(supervisor.system, supervisor.system_port, &into, true) {
            case Received => break
            case Failed(error) => return void
            case _ => continue
        }
    }
    directory :: match os.message_of[dir.Response](&into)^ {
        case OpenedDirectory(opened) => opened
        case _ => {
            log_line.write(supervisor.log, "supervisor: no events directory on the system volume")
            return void
        }
    }
    storing := os.Outgoing.{}
    store :: os.begin[events.Request](&storing)
    store^ = .Store(directory)
    answer := os.Incoming.{}
    _ = events.ask(supervisor.events_end, supervisor.events_port, &storing, &answer)
}

// A connection of the supervisor's own to the events service, and the port its answers wake, NONE without one.
Waiting :: struct {
    end : slop_os.Channel,
    port : slop_os.Port,
}

// test_events: a connection of the supervisor's own to the events service, on which a query for hello's first record waits.
wait_for_hello :: fn(supervisor: ptr[mut Supervisor]) -> Waiting {
    if supervisor.events_end == NONE {
        return Waiting.{end = NONE}
    }
    pair :: os.channel_for[events.Events](supervisor.block.budget, 0) or_return Waiting.{end = NONE}
    connecting := os.Outgoing.{}
    connect :: os.begin[events.Request](&connecting)
    connect^ = .Connect(os.Channel[events.Events].{end = pair.a})
    if events.send_request(supervisor.events_end, supervisor.events_port, &connecting) is_some {
        return Waiting.{end = NONE}
    }
    port :: os.port_for(supervisor.block.budget, pair.b) or_return Waiting.{end = NONE}
    out := os.Outgoing.{}
    request :: os.begin[events.Request](&out)
    request^ = .Query(events.QueryOf.{source = bytes_of(&out, "hello"), from = 0, level = 0, wait = true})
    if events.send_request(pair.b, port, &out) is_some {
        return Waiting.{end = NONE}
    }
    return Waiting.{end = pair.b, port = port}
}

/*
 * test_events, once everything has started: the held query's answer, and hello's first record and the clock service's
 * second, read back from where the events service stores them.
 */
check_events :: fn(supervisor: ptr[mut Supervisor], waiting: Waiting) {
    if waiting.end != NONE {
        into := os.Incoming.{}
        loop {
            match events.receive_response(waiting.end, waiting.port, &into, true) {
                case Received => break
                case Failed(error) => break
                case _ => continue
            }
        }
        match os.message_of[events.Response](&into)^ {
            case Found(found) => log_line.write(supervisor.log, "supervisor: test_events: the waiting query got hello's record %: %",
                found.number, text_of_items(os.items(&into, found.text)))
            case _ => log_line.write(supervisor.log, "supervisor: test_events: the waiting query got no record")
        }
    }
    // The clock service's second: its first says when it started
    for source, i in string.["hello", "clock"] {
        out := os.Outgoing.{}
        request :: os.begin[events.Request](&out)
        request^ = .Query(events.QueryOf.{source = bytes_of(&out, source), from = cast[u64](i), level = 0})
        into := os.Incoming.{}
        match events.ask(supervisor.events_end, supervisor.events_port, &out, &into) {
            case Found(found) => log_line.write(supervisor.log, "supervisor: test_events: %'s record % read back%: %", source, found.number,
                if found.stored { " from the system volume" } else { " from memory" }, text_of_items(os.items(&into, found.text)))
            case _ => log_line.write(supervisor.log, "supervisor: test_events: no record of %", source)
        }
    }
}

bytes_of :: fn(out: ptr[mut os.Outgoing], text: string) -> slop_os.Relative[u8] {
    return os.append(out, view_of(cast[ptr[u8]](text.data), text.count))
}

text_of_items :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

// The entry in started the program launched next is to have: the one a restart is launching into, or the next.
next_slot :: fn(supervisor: ptr[Supervisor]) -> usize {
    return if supervisor.relaunching != NOWHERE { supervisor.relaunching } else { supervisor.started_count }
}

/*
 * The clock service, with the real-time clock the platform service gives, the clock page to write, and a listener whose
 * other end sets the time; into the started entry again, a restart, unless again is NOWHERE.
 */
start_clock :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: system_config.service("clock") or_return void
    if cast[slop_os.Handle](supervisor.clock_page) == slop_os.NO_HANDLE {
        return void
    }
    rtc := platform.RealTimeClock.{}
    match request_clock(supervisor) {
        case Some(claimed) => rtc = claimed
        case None => {
            log_line.write(supervisor.log, "supervisor: no real-time clock, so no clock service")
            return void
        }
    }
    pair :: os.channel_for[clock_setting.ClockSetting](supervisor.block.budget, 0) or_return void
    page_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    page :: slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.clock_page), page_rights) or_return void
    grants := ClockGrants.{clock_page = cast[slop_os.Memory](page),
        clients = os.Listener[clock_setting.ClockSetting].{end = pair.a}}
    if cast[slop_os.Handle](rtc.ports) != slop_os.NO_HANDLE {
        grants.rtc_ports = rtc.ports
    }
    if cast[slop_os.Handle](rtc.registers) != slop_os.NO_HANDLE {
        grants.rtc_registers = rtc.registers
    }
    // The clock service doesn't read the time from the page it writes
    options := options_for(supervisor, service.name)
    match options.clock {
        case Some(copy) => _ = slop_os.handle_close(cast[slop_os.Handle](copy))
        case None => {}
    }
    options.clock = null
    launched := cast[slop_os.Process](slop_os.NO_HANDLE)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        clock_service.main, grants, options) {
        case Ok(made) => launched = kept(supervisor, made)
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return void
        }
    }
    // Its setting end, the last one gone with the last process
    if supervisor.clock_setting != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.clock_setting))
    }
    supervisor.clock_setting = pair.b
    supervisor.clock_setting_port = os.port_for(supervisor.block.budget, pair.b) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    slot :: place(supervisor, "clock", launched, again)
    if slot >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[slot]
    entry.driver = true
    entry.clock = true
}

module_of :: fn(supervisor: ptr[mut Supervisor], name: string) -> slop_os.Memory {
    service :: system_config.service(name)
    match service {
        case Some(found) => {
            if !found.boot_set && cast[slop_os.Handle](supervisor.system) != slop_os.NO_HANDLE {
                match loaded_module(supervisor, found) {
                    case Some(module) => return module
                    case None => {}
                }
            }
        }
        case None => {}
    }
    modules :: &supervisor.modules
    none :: cast[slop_os.Memory](slop_os.NO_HANDLE)
    found := if name == "virtio_rng" { modules.virtio_rng } else if name == "virtio_console" { modules.virtio_console }
        else if name == "virtio_blk" { modules.virtio_blk } else if name == "virtio_input" { modules.virtio_input }
        else if name == "edu_dma" { modules.edu_dma } else if name == "storage_manager" { modules.storage_manager }
        else if name == "console" { modules.console } else if name == "disk_check" { modules.disk_check }
        else if name == "hello" { modules.hello } else if name == "clock" { modules.clock }
        else if name == "events" { modules.events } else if name == "bundle_store" { modules.bundle_store }
        else { cast[slop_os.Memory?](null) }
    return found or_else none
}

/*
 * The program a service's module names: from the bundle store, the program of the bundle its boot root names after the
 * service, as paged memory, which processes running it share; or, without one, read from the system volume's modules
 * folder. Got already, or now.
 */
loaded_module :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service) -> slop_os.Memory? {
    place := system_config.SERVICES.count
    for each, i in system_config.SERVICES {
        if each.name == service.name {
            place = i
        }
    }
    loaded :: &supervisor.loaded
    if place >= loaded.count {
        return null
    }
    match loaded[place].module {
        case Some(module) => return module
        case None => {}
    }
    from_store :: stored_program(supervisor, service.module)
    module :: from_store or_else (read_module(supervisor, service.module) or_return null)
    if place < loaded.count {
        loaded[place] = Loaded.{module = module}
    }
    log_line.write(supervisor.log, "supervisor: % from the %", service.name, if from_store is_some { "bundle store" } else { "system volume" })
    return module
}

/*
 * The program the bundle store's boot root names after a module, without its extension, as the store gives it: paged
 * memory, read and execute only. Null without a store, a root, or a bundle of that name.
 */
stored_program :: fn(supervisor: ptr[mut Supervisor], module: string) -> slop_os.Memory? {
    name := module
    for character, i in module {
        if character == '.' {
            name = string_of(cast[ptr[u8]](module.data), i)
            break
        }
    }
    program :: stored_hash(supervisor, name, 0) or_return null
    return match store_request(supervisor, .Get(program)) {
        case Got(object) => object.memory
        case _ => null
    }
}

/*
 * What the bundle the store's boot root names name refers to, by its place: 0 its program, 1 its manifest. Null without
 * a store, a root, or a bundle of that name.
 */
stored_hash :: fn(supervisor: ptr[mut Supervisor], name: string, which: usize) -> bundle.Hash? {
    if supervisor.store_end == NONE {
        return null
    }
    root :: match store_request(supervisor, .Root) {
        case Rooted(hash) => hash
        case _ => return null
    }
    found := bundle.Hash.{}
    have := false
    root_object :: mapped_object(supervisor, root) or_return null
    names : string[..]
    defer runtime.array_free(&names)
    bundles : bundle.Hash[..]
    defer runtime.array_free(&bundles)
    if bundle.root_entries(root_object.bytes, &names, &bundles) {
        for entry_name, i in names {
            if entry_name == name && i < bundles.count {
                match mapped_object(supervisor, bundles[i]) {
                    case Some(record) => {
                        referred : bundle.Hash[..]
                        if bundle.bundle_refers(record.bytes, &referred) && which < referred.count {
                            found = referred[which]
                            have = true
                        }
                        runtime.array_free(&referred)
                        unmap_object(supervisor, record)
                    }
                    case None => {}
                }
                break
            }
        }
    }
    unmap_object(supervisor, root_object)
    return if have { found } else { null }
}

// An object of the bundle store's, mapped to read: its memory, where, and its bytes.
MappedObject :: struct {
    memory : slop_os.Memory,
    address : u64,
    bytes : u8[],
}

mapped_object :: fn(supervisor: ptr[mut Supervisor], hash: bundle.Hash) -> MappedObject? {
    object :: match store_request(supervisor, .Get(hash)) {
        case Got(got) => got
        case _ => return null
    }
    address :: map_in(supervisor, object.memory, (object.size + 4095) & ~cast[u64](4095), slop_os.PROTECTION_READ)
    if address == 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](object.memory))
        return null
    }
    return MappedObject.{memory = object.memory, address = address, bytes = view_of(cast[ptr[u8]](address), cast[usize](object.size))}
}

unmap_object :: fn(supervisor: ptr[mut Supervisor], object: MappedObject) {
    _ = slop_os.memory_unmap(supervisor.block.space, object.address)
    _ = slop_os.handle_close(cast[slop_os.Handle](object.memory))
}

/*
 * modules/<module> on the system volume, read whole into a memory object of its own: given to the volume server as the
 * read's buffer, so the file comes straight into it.
 */
read_module :: fn(supervisor: ptr[mut Supervisor], module: string) -> slop_os.Memory? {
    path_storage : u8[256]
    path := text_buffer.make(path_storage)
    text_buffer.append(&path, "modules/")
    text_buffer.append(&path, module)
    into := os.Incoming.{}
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    text :: text_buffer.as_string(&path)
    opening^ = .OpenReadOnlyFile(os.append(&out, view_of(cast[ptr[u8]](text.data), text.count)))
    opened := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_system_dir(supervisor.system, supervisor.system_port, &out, &into) {
        case OpenedReadOnlyFile(made) => opened = made.end
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](opened))
    budget :: supervisor.block.budget
    port :: os.port_for(budget, opened) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out = os.Outgoing.{}
    describing :: os.begin[read_only_file.Request](&out)
    describing^ = .Info
    size := cast[u64](0)
    match ask_system_file(opened, port, &out, &into) {
        case Described(info) => size = info.size
        case _ => return null
    }
    if size == 0 || size > MAX_MODULE_BYTES {
        return null
    }
    pages :: (size + 4095) / 4096 * 4096
    memory :: slop_os.memory_create(budget, pages) or_return null
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    given :: slop_os.handle_duplicate(cast[slop_os.Handle](memory), rights) or_return null
    for request in read_only_file.Request.[.UseBuffer(cast[slop_os.Memory](given)),
        .Read(files.Transfer.{offset = 0, count = cast[u32](size), buffer_offset = 0})] {
        out = os.Outgoing.{}
        made :: os.begin[read_only_file.Request](&out)
        made^ = request
        match ask_system_file(opened, port, &out, &into) {
            case Done => {}
            case Transferred(count) => {
                if cast[u64](count) != size {
                    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                    return null
                }
            }
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                return null
            }
        }
    }
    return memory
}

// The most bytes a program read from the system volume may be.
MAX_MODULE_BYTES : u64 : 8 << 20

// One request to the system volume's server on its dir connection, and its answer, waited for.
ask_system_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// One request on a program's file connection, and its answer, waited for.
ask_system_file :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_file.Response {
    if read_only_file.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_file.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_file.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// Every driver the supervisor starts, in the boot set or out of it, for every device it takes.
start_drivers :: fn(supervisor: ptr[mut Supervisor], boot_set: bool) {
    if cast[slop_os.Handle](supervisor.platform_end) == slop_os.NO_HANDLE {
        return void
    }
    for each, index in system_config.SERVICES {
        if !system_config.is_driver(each) || each.starter != system_config.Starter.Supervisor || each.boot_set != boot_set {
            continue
        }
        loop {
            device :: request_device(supervisor, .Claim(platform.Wanted.{devices = each.devices, trusted = each.trusted_with_dma})) or_break
            start_driver(supervisor, index, device, NOWHERE)
        }
    }
}

/*
 * The console service, with connectors to the first serial line and keyboard, and a listener for its clients; into its
 * entry at again, unless that's NOWHERE.
 */
start_console :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: system_config.service("console") or_return void
    pair :: os.channel_for[console_log.ConsoleLog](supervisor.block.budget, 0) or_return void
    grants := ConsoleGrants.{log = duplicate_log(supervisor), serial_line = connector_to(supervisor, supervisor.first_serial),
        keyboard = connector_to(supervisor, supervisor.first_keyboard), clients = os.Listener[console_log.ConsoleLog].{end = pair.a}}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "console"), service.budget,
        console.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            slot :: place(supervisor, "console", kept(supervisor, launched), again)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.started[slot].speaks = .ConsoleLog
                supervisor.console = slot
            }
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

// hello, with a connector to the console and a connection to the process manager; into its entry at again, unless that's NOWHERE.
start_hello :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: system_config.service("hello") or_return void
    grants := HelloGrants.{console = connector_to(supervisor, supervisor.console)}
    grants.manager = process_manager.connect(supervisor.manager.end, supervisor.manager_port, supervisor.block.budget)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "hello"), service.budget, hello.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => _ = place(supervisor, "hello", kept(supervisor, launched), again)
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// The disk check, with a connector to the first disk, if there is one.
/*
 * The storage manager, when there's a disk, with a connector to each of the first four disks' drivers, a connection
 * to the process manager and the partition server's module: its index in what's started, or NOWHERE; into its entry at
 * again, unless that's NOWHERE.
 */
start_storage :: fn(supervisor: ptr[mut Supervisor], again: usize) -> usize {
    if supervisor.first_disk == NOWHERE {
        return NOWHERE
    }
    service :: system_config.service("storage_manager") or_return NOWHERE
    module :: supervisor.modules.partition_server or_return NOWHERE
    fat_module :: supervisor.modules.fat_server or_return NOWHERE
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    partition_server := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](module), rights) or_return NOWHERE)
    fat_server := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](fat_module), rights) or_return NOWHERE)
    container_module :: supervisor.modules.container_service or_return NOWHERE
    volume_module :: supervisor.modules.volume_server or_return NOWHERE
    container_service := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](container_module), rights) or_return NOWHERE)
    volume_server := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](volume_module), rights) or_return NOWHERE)
    manager :: process_manager.connect(supervisor.manager.end, supervisor.manager_port, supervisor.block.budget) or_return NOWHERE
    pair :: os.channel_for[storage.Storage](supervisor.block.budget, 0) or_return NOWHERE
    disks : MaybeConnector[4]
    found : usize = 0
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.speaks == .Block && found < disks.count {
            disks[found] = connector_to(supervisor, i)
            found += 1
        }
    }
    grants := StorageGrants.{log = duplicate_log(supervisor), manager = manager, partition_server_module = partition_server,
        fat_server_module = fat_server, container_service_module = container_service, volume_server_module = volume_server, disk0 = disks[0],
        disk1 = disks[1], disk2 = disks[2], disk3 = disks[3], clients = os.Listener[storage.Storage].{end = pair.a}}
    match supervisor.command_line {
        case Some(text) => {
            text_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
            match slop_os.handle_duplicate(cast[slop_os.Handle](text), text_rights) {
                case Ok(copy) => grants.command_line = cast[slop_os.Memory](copy)
                case Error(error) => {}
            }
        }
        case None => {}
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "storage_manager"), service.budget,
        storage_manager.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            slot :: place(supervisor, "storage_manager", kept(supervisor, launched), again)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.started[slot].speaks = .Storage
            }
            return slot
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            return NOWHERE
        }
    }
}

/*
 * The files of the first partition of a type the storage manager at storage_slot has, through a connection of the
 * supervisor's own: an EFI system partition's root, or a SlopOS container's system volume's. It's waited for on the
 * supervisor's port, which goes on handling what arrives, connectors' Dials among it, as the storage manager dials its
 * disks through them before it answers.
 */
files_of_type :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize, kind: u8[16]) -> os.Channel[dir.Dir]? {
    end :: dial(supervisor, storage_slot) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](end))
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(supervisor.port, cast[slop_os.Handle](end), signals, STORAGE_KEY, .Persistent) is_error {
        return null
    }
    defer slop_os.port_unbind(supervisor.port, STORAGE_KEY)
    for index in 0..<cast[u32](32) {
        match ask_storage(supervisor, end, .Describe(index)) {
            case Described(partition) => {
                if partition.info.type_guid != kind {
                    continue
                }
                match ask_storage(supervisor, end, .OpenFiles(index)) {
                    case OpenedFiles(root) => return root
                    case _ => return null
                }
            }
            case _ => return null
        }
    }
    return null
}

// One request to the storage manager on a connection of its own, and its answer, handling the rest meanwhile.
ask_storage_once :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize, request: storage.Request) -> storage.Response {
    end :: dial(supervisor, storage_slot) or_return .Unsupported
    defer slop_os.handle_close(cast[slop_os.Handle](end))
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(supervisor.port, cast[slop_os.Handle](end), signals, STORAGE_KEY, .Persistent) is_error {
        return .Unsupported
    }
    defer slop_os.port_unbind(supervisor.port, STORAGE_KEY)
    return ask_storage(supervisor, end, request)
}

// One request to the storage manager on end, bound to the supervisor's port, and its answer, handling the rest meanwhile.
ask_storage :: fn(supervisor: ptr[mut Supervisor], end: slop_os.Channel, request: storage.Request) -> storage.Response {
    out := os.Outgoing.{}
    made :: os.begin[storage.Request](&out)
    made^ = request
    if storage.send_request(end, supervisor.port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match storage.receive_response(end, supervisor.port, &into, false) {
            case Received => return os.message_of[storage.Response](&into)^
            case Empty => wait_and_handle(supervisor)
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

// The disk check, given a connector to the storage manager at storage, when there's a disk.
start_disk_check :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize) {
    if supervisor.first_disk == NOWHERE || storage_slot == NOWHERE {
        return void
    }
    service :: system_config.service("disk_check") or_return void
    grants := DiskCheckGrants.{log = duplicate_log(supervisor), storage = connector_to(supervisor, storage_slot),
        working_directory = files_of_type(supervisor, storage_slot, storage_manager.ESP_TYPE),
        system = files_of_type(supervisor, storage_slot, storage_manager.CONTAINER_TYPE)}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "disk_check"), service.budget,
        disk_check.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => _ = started(supervisor, "disk_check", kept(supervisor, launched))
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// A connector to what's started at target, which the supervisor serves; null if target is NOWHERE.
connector_to :: fn(supervisor: ptr[mut Supervisor], target: usize) -> os.Channel[connector.Connector]? {
    index :: supervisor.connector_count
    if target == NOWHERE || index >= supervisor.connectors.count {
        return null
    }
    pair :: os.channel_for[connector.Connector](supervisor.block.budget, 0) or_return null
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(supervisor.port, cast[slop_os.Handle](pair.b), signals, CONNECTOR_KEY + cast[u64](index), .Persistent) is_error {
        return null
    }
    supervisor.connectors[index] = Connector.{end = pair.b, target = target}
    supervisor.connector_count = index + 1
    serve_connector(supervisor, index)
    return os.Channel[connector.Connector].{end = pair.a}
}

// Every Dial on a connector: a connection to its target's listener, if it's running.
serve_connector :: fn(supervisor: ptr[mut Supervisor], index: usize) {
    if index >= supervisor.connectors.count {
        return void
    }
    record :: supervisor.connectors[index]
    if cast[slop_os.Handle](record.end) == slop_os.NO_HANDLE {
        return void
    }
    into := os.Incoming.{}
    loop {
        match connector.receive_request(record.end, supervisor.port, &into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = connector.answer_unsupported(record.end, supervisor.port)
                continue
            }
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](record.end))
                supervisor.connectors[index].end = NONE
                return void
            }
            case _ => continue
        }
        out := os.Outgoing.{}
        response :: os.begin[connector.Response](&out)
        match dial(supervisor, record.target) {
            case Some(channel) => {
                response^ = .Dialed(channel)
                supervisor.connectors[index].dials += 1
            }
            case None => response^ = .Unavailable
        }
        _ = connector.send_response(record.end, supervisor.port, &out)
    }
}

// test_restart's waits, for the console to show what it's sent, in nanoseconds.
pause :: fn(supervisor: ptr[mut Supervisor], nanoseconds: u64) {
    waiter :: slop_os.port_create(supervisor.block.budget) or_return void
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, (slop_os.clock_monotonic() or_else 0) + nanoseconds)
    _ = slop_os.handle_close(cast[slop_os.Handle](waiter))
}

// How many times connectors to what's started at target have dialed it.
dials_of :: fn(supervisor: ptr[Supervisor], target: usize) -> u32 {
    dials : u32 = 0
    for each, i in supervisor.connectors {
        if i < supervisor.connector_count && each.target == target {
            dials += each.dials
        }
    }
    return dials
}

// Whether what's started at index is running now.
is_running :: fn(supervisor: ptr[Supervisor], index: usize) -> bool {
    return index < supervisor.started.count && supervisor.started[index].running
}

// A new connection to what's started at target, through its listener with its protocol's Connect, if it's running.
dial :: fn(supervisor: ptr[mut Supervisor], target: usize) -> slop_os.Channel? {
    if target >= supervisor.started.count || !supervisor.started[target].running {
        return null
    }
    entry :: supervisor.started[target]
    if cast[slop_os.Handle](entry.listener) == slop_os.NO_HANDLE {
        return null
    }
    // A port of its own for the Connect, closed after it, which takes its binding to the listener with it: an end has
    // room for only a few bindings
    port :: os.port_for(supervisor.block.budget, entry.listener) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    budget :: supervisor.block.budget
    return match entry.speaks {
        case .Serial => (serial.connect(entry.listener, port, budget) or_return null).end
        case .Block => (block.connect(entry.listener, port, budget) or_return null).end
        case .Input => (input.connect(entry.listener, port, budget) or_return null).end
        case .ConsoleLog => (console_log.connect(entry.listener, port, budget) or_return null).end
        case .Storage => (storage.connect(entry.listener, port, budget) or_return null).end
        case .Nothing => null
    }
}

// A device from the platform service, claimed or reissued, or null.
// The real-time clock, claimed from the platform service, made anew each time; or null if there's none.
request_clock :: fn(supervisor: ptr[mut Supervisor]) -> platform.RealTimeClock? {
    if cast[slop_os.Handle](supervisor.platform_end) == slop_os.NO_HANDLE {
        return null
    }
    out := os.Outgoing.{}
    made :: os.begin[platform.Request](&out)
    made^ = .ClaimClock
    if platform.send_request(supervisor.platform_end, supervisor.platform_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match platform.receive_response(supervisor.platform_end, supervisor.platform_port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => continue
        }
    }
    return match os.message_of[platform.Response](&into)^ {
        case ClaimedClock(clock) => clock
        case _ => null
    }
}

request_device :: fn(supervisor: ptr[mut Supervisor], request: platform.Request) -> platform.PciDevice? {
    if cast[slop_os.Handle](supervisor.platform_end) == slop_os.NO_HANDLE {
        return null
    }
    out := os.Outgoing.{}
    made :: os.begin[platform.Request](&out)
    made^ = request
    if platform.send_request(supervisor.platform_end, supervisor.platform_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match platform.receive_response(supervisor.platform_end, supervisor.platform_port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => continue
        }
    }
    return match os.message_of[platform.Response](&into)^ {
        case Claimed(device) => device
        case _ => null
    }
}

optional :: fn(memory: slop_os.Memory) -> slop_os.Memory? {
    return if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE { null } else { memory }
}

// A device no driver takes, given back by closing what it held.
close_device :: fn(device: ptr[platform.PciDevice]) {
    for handle in slop_os.Handle.[cast[slop_os.Handle](device.device), cast[slop_os.Handle](device.config),
        cast[slop_os.Handle](device.domain), cast[slop_os.Handle](device.bar0), cast[slop_os.Handle](device.bar1),
        cast[slop_os.Handle](device.bar2), cast[slop_os.Handle](device.bar3), cast[slop_os.Handle](device.bar4),
        cast[slop_os.Handle](device.bar5)] {
        if handle != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(handle)
        }
    }
}

// Something started: watched until it ends, and reported; its index, or MAX_STARTED if there's no room for it.
started :: fn(supervisor: ptr[mut Supervisor], name #escaping : string, process: slop_os.Process) -> usize {
    index :: supervisor.started_count
    tell_root(supervisor, .Started(report_of(name, 0)))
    if index >= supervisor.started.count {
        return MAX_STARTED
    }
    supervisor.started[index] = Started.{name = name, process = process, running = true, listener = NONE, budget = take_budget(supervisor),
        ring = take_ring(supervisor)}
    supervisor.started_count = index + 1
    return index
}

failed :: fn(supervisor: ptr[mut Supervisor], name: string, error: os.LaunchError) {
    // Its end was watched under the key of the entry it didn't get, which the next launch is watched under
    _ = slop_os.port_unbind(supervisor.port, cast[u64](next_slot(supervisor)))
    log_line.write(supervisor.log, "supervisor: % didn't start: %", name, error)
    tell_root(supervisor, .Failed(report_of(name, cast[u64](error) + 1)))
}

/*
 * A launched program's process, its budget's handle kept for the entry it's placed in (take_budget): the budget lasts
 * as long as a handle to it, and goes back to the supervisor's once the entry's is closed as the program ends.
 */
kept :: fn(supervisor: ptr[mut Supervisor], launched: os.Launched) -> slop_os.Process {
    supervisor.launched_budget = launched.budget
    return launched.process
}

// The budget kept for the program launched last, for its entry.
take_budget :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.MemoryBudget {
    budget :: supervisor.launched_budget
    supervisor.launched_budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    return budget
}

// A copy of the supervisor's debug log, to give a service.
duplicate_log :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

// A report to the root task.
tell_root :: fn(supervisor: ptr[mut Supervisor], report: supervision.Request) {
    out := os.Outgoing.{}
    request :: os.begin[supervision.Request](&out)
    request^ = report
    _ = supervision.send_request(supervisor.root, supervisor.root_port, &out)
}

report_of :: fn(name: string, code: u64) -> supervision.Report {
    return supervision.Report.{name = os.label_from(name), code = code}
}
