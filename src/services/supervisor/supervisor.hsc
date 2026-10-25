/*
 * The supervisor (decisions/0017, 0058, 0067, 0068, 0074, 0075, 0076, 0077): it starts the services system_config gives
 * it through the process manager, with std/os's launch, each in a process of its own that it owns and pays for from
 * its budget, and tells the root task as each starts and ends, and once all have.
 *
 * A driver's service names the devices it takes: the supervisor claims each from the platform service and starts a
 * driver for it, with what it holds of it (platform.PciDevice). Drivers start first, since services need them. A
 * driver that serves clients is given a listener whose other end the supervisor keeps. Clients don't get connections
 * to a driver: they get connectors (the connector protocol), channels the supervisor serves, each of which dials the
 * listener of whatever serves it now. The console service is given connectors to the first serial line and the first
 * keyboard, hello one to the console, and the disk check, if there's a disk, one to the first disk.
 *
 * A driver that ends other than by exiting with 0, killed or crashed, is started again with its device reissued by the
 * platform service, made anew, and a new listener, up to RESTARTS times in RESTART_WINDOW; its clients' connections went
 * with it, and they dial again. With test_restart on the kernel's command line, the supervisor kills the first serial
 * line's driver once everything has started and the console has dialed it and shown its banner, and says it has
 * started all only once that driver is back, and dialed again.
 */
package supervisor

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import console_log from "../../protocols/console_log"
import entropy from "../../protocols/entropy"
import input from "../../protocols/input"
import platform from "../../protocols/platform"
import serial from "../../protocols/serial"
import supervision from "../../protocols/supervision"
import service_kit from "../../service_kit"
import system_config from "../../system_config"
import hello from "../../apps/hello"
import console from "../console"
import disk_check from "../disk_check"
import virtio_blk from "../../drivers/virtio_blk"
import virtio_console from "../../drivers/virtio_console"
import virtio_input from "../../drivers/virtio_input"
import virtio_rng from "../../drivers/virtio_rng"

MAX_STARTED :: 16
MAX_CONNECTORS :: 16
// Connectors are bound to the port from here on, what it started below
CONNECTOR_KEY : u64 : 1000
RESTARTS : u32 : 3
RESTART_WINDOW : u64 : 60_000_000_000
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
NOWHERE : usize : 0xffffffffffffffff
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
}

// What hello is given (hello.main).
HelloGrants :: struct {
    log : slop_os.DebugLog?,
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
    disk : os.Channel[connector.Connector]?,
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
    hello : slop_os.Memory,
    console : slop_os.Memory?,
    disk_check : slop_os.Memory?,
    virtio_blk : slop_os.Memory?,
    virtio_console : slop_os.Memory?,
    virtio_input : slop_os.Memory?,
    virtio_rng : slop_os.Memory?,
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
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager], root: os.Channel[supervision.Supervision],
    hello_module: slop_os.Memory, platform_service: os.Channel[platform.Platform]?, entropy_service: os.Channel[entropy.Entropy]?,
    console_module: slop_os.Memory?, disk_check_module: slop_os.Memory?, virtio_blk_module: slop_os.Memory?,
    virtio_console_module: slop_os.Memory?, virtio_input_module: slop_os.Memory?, virtio_rng_module: slop_os.Memory?,
    command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    supervisor := Supervisor.{block = startup, manager = manager, root = root.end, platform_end = NONE, entropy_service = entropy_service,
        first_serial = NOWHERE, first_disk = NOWHERE, first_keyboard = NOWHERE, console = NOWHERE}
    supervisor.modules = Modules.{hello = hello_module, console = console_module, disk_check = disk_check_module, virtio_blk = virtio_blk_module,
        virtio_console = virtio_console_module, virtio_input = virtio_input_module, virtio_rng = virtio_rng_module}
    supervisor.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    supervisor.manager_port = os.port_for(startup.budget, manager.end) or_return 1
    supervisor.root_port = os.port_for(startup.budget, root.end) or_return 2
    supervisor.port = slop_os.port_create(startup.budget) or_return 3
    test_restart := false
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(startup, memory) or_else ""
            test_restart = service_kit.has_word(text, "test_restart")
        }
        case None => {}
    }

    // Each driver, for every device it takes
    match platform_service {
        case Some(platform_end) => {
            supervisor.platform_end = platform_end.end
            supervisor.platform_port = os.port_for(startup.budget, platform_end.end) or_return 4
            for each, index in system_config.SERVICES {
                if !system_config.is_driver(each) || each.starter != system_config.Starter.Supervisor {
                    continue
                }
                loop {
                    device :: request_device(&supervisor, .Claim(each.devices)) or_break
                    start_driver(&supervisor, index, device, NOWHERE)
                }
            }
        }
        case None => {}
    }
    // Then the services that use them, each with connectors to what it uses
    start_console(&supervisor)
    start_hello(&supervisor)
    start_disk_check(&supervisor)
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
    }
    for i in 0..<supervisor.connector_count {
        serve_connector(supervisor, i)
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
    tell_root(supervisor, .Ended(report_of(entry.name, code)))
    if cast[slop_os.Handle](entry.listener) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](entry.listener))
        entry.listener = NONE
    }
    if !entry.driver || code == 0 {
        return void
    }
    now :: slop_os.clock_monotonic() or_else 0
    if now - entry.restarts_since > RESTART_WINDOW {
        entry.restarts = 0
        entry.restarts_since = now
    }
    if entry.restarts >= RESTARTS {
        log_line.write(supervisor.log, "supervisor: % ended % times in a minute, and isn't started again", entry.name, RESTARTS + 1)
        return void
    }
    entry.restarts += 1
    device :: request_device(supervisor, .Reissue(entry.address)) or_return void
    start_driver(supervisor, entry.service, device, index)
    if entry.running {
        log_line.write(supervisor.log, "supervisor: restarted %", entry.name)
    }
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
    else {
        close_device(&device)
        return void
    }
    if cast[slop_os.Handle](launched) == slop_os.NO_HANDLE {
        if cast[slop_os.Handle](listener) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](listener))
        }
        return void
    }
    slot :: if again != NOWHERE { again } else { started(supervisor, name, launched) }
    if slot >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[slot]
    entry.process = launched
    entry.running = true
    entry.listener = listener
    entry.speaks = speaks
    entry.driver = true
    entry.service = index
    entry.address = device.address
    if again != NOWHERE {
        _ = slop_os.port_bind(supervisor.port, cast[slop_os.Handle](launched), slop_os.SIGNAL_TERMINATED, cast[u64](slot), .Once)
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
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, entry, grants) {
        case Ok(launched) => return launched.process
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
        virtio_rng.main, grants) {
        case Ok(launched) => return launched.process
        case Error(error) => {
            failed(supervisor, service.name, error)
            return cast[slop_os.Process](slop_os.NO_HANDLE)
        }
    }
}

module_of :: fn(supervisor: ptr[Supervisor], name: string) -> slop_os.Memory {
    modules :: &supervisor.modules
    none :: cast[slop_os.Memory](slop_os.NO_HANDLE)
    found := if name == "virtio_rng" { modules.virtio_rng } else if name == "virtio_console" { modules.virtio_console }
        else if name == "virtio_blk" { modules.virtio_blk } else if name == "virtio_input" { modules.virtio_input }
        else if name == "console" { modules.console } else if name == "disk_check" { modules.disk_check } else { cast[slop_os.Memory?](null) }
    return found or_else none
}

// The console service, with connectors to the first serial line and keyboard, and a listener for its clients.
start_console :: fn(supervisor: ptr[mut Supervisor]) {
    service :: system_config.service("console") or_return void
    pair :: os.channel_for[console_log.ConsoleLog](supervisor.block.budget, 0) or_return void
    grants := ConsoleGrants.{log = duplicate_log(supervisor), serial_line = connector_to(supervisor, supervisor.first_serial),
        keyboard = connector_to(supervisor, supervisor.first_keyboard), clients = os.Listener[console_log.ConsoleLog].{end = pair.a}}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "console"), service.budget,
        console.main, grants) {
        case Ok(launched) => {
            slot :: started(supervisor, "console", launched.process)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.started[slot].speaks = .ConsoleLog
                supervisor.console = slot
            }
        }
        case Error(error) => failed(supervisor, service.name, error)
    }
}

start_hello :: fn(supervisor: ptr[mut Supervisor]) {
    service :: system_config.service("hello") or_return void
    grants := HelloGrants.{log = duplicate_log(supervisor), console = connector_to(supervisor, supervisor.console)}
    grants.manager = process_manager.connect(supervisor.manager.end, supervisor.manager_port, supervisor.block.budget)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, supervisor.modules.hello, service.budget, hello.main, grants) {
        case Ok(launched) => _ = started(supervisor, "hello", launched.process)
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// The disk check, with a connector to the first disk, if there is one.
start_disk_check :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.first_disk == NOWHERE {
        return void
    }
    service :: system_config.service("disk_check") or_return void
    grants := DiskCheckGrants.{log = duplicate_log(supervisor), disk = connector_to(supervisor, supervisor.first_disk)}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "disk_check"), service.budget,
        disk_check.main, grants) {
        case Ok(launched) => _ = started(supervisor, "disk_check", launched.process)
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
    match slop_os.port_bind(supervisor.port, cast[slop_os.Handle](pair.b), signals, CONNECTOR_KEY + cast[u64](index), .Persistent) {
        case Ok => {}
        case Error(error) => return null
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
    port :: os.port_for(supervisor.block.budget, entry.listener) or_return null
    budget :: supervisor.block.budget
    return match entry.speaks {
        case .Serial => (serial.connect(entry.listener, port, budget) or_return null).end
        case .Block => (block.connect(entry.listener, port, budget) or_return null).end
        case .Input => (input.connect(entry.listener, port, budget) or_return null).end
        case .ConsoleLog => (console_log.connect(entry.listener, port, budget) or_return null).end
        case .Nothing => null
    }
}

// A device from the platform service, claimed or reissued, or null.
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
    supervisor.started[index] = Started.{name = name, process = process, running = true, listener = NONE}
    supervisor.started_count = index + 1
    _ = slop_os.port_bind(supervisor.port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, cast[u64](index), .Once)
    return index
}

failed :: fn(supervisor: ptr[mut Supervisor], name: string, error: os.LaunchError) {
    log_line.write(supervisor.log, "supervisor: % didn't start: %", name, error)
    tell_root(supervisor, .Failed(report_of(name, cast[u64](error) + 1)))
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
