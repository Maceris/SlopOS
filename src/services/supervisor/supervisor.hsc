/*
 * The supervisor (decisions/0017, 0058, 0067, 0068, 0074): it starts the services system_config gives it through the
 * process manager, with std/os's launch, each in a process of its own that it owns and pays for from its budget, and
 * tells the root task as each starts and ends, and once all have. A driver's service names the devices it takes: the
 * supervisor claims each from the platform service and starts a driver for it, with what it holds of it
 * (platform.PciDevice). Drivers start first, since services need them: a driver that serves clients is given a
 * listener whose other end the supervisor keeps, and connects them through (decisions/0075). The console service is
 * given the first serial line, hello the console, and the disk check, if there's a disk, the first disk
 * (decisions/0076). Restarting them comes with 7f.
 */
package supervisor

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import block from "../../protocols/block"
import console_log from "../../protocols/console_log"
import entropy from "../../protocols/entropy"
import platform from "../../protocols/platform"
import serial from "../../protocols/serial"
import supervision from "../../protocols/supervision"
import system_config from "../../system_config"
import hello from "../../apps/hello"
import console from "../console"
import disk_check from "../disk_check"
import virtio_blk from "../../drivers/virtio_blk"
import virtio_console from "../../drivers/virtio_console"
import virtio_rng from "../../drivers/virtio_rng"

MAX_STARTED :: 16

// What hello is given (hello.main).
HelloGrants :: struct {
    log : slop_os.DebugLog?,
    manager : os.Channel[process_manager.ProcessManager]?,
    console : os.Channel[console_log.ConsoleLog]?,
}

// What the console service is given (console.main).
ConsoleGrants :: struct {
    log : slop_os.DebugLog?,
    serial_line : os.Channel[serial.Serial]?,
    clients : os.Listener[console_log.ConsoleLog],
}

// What a virtio console's driver is given (virtio_console.main): its device, and a listener for its clients.
VirtioConsoleGrants :: struct {
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
    clients : os.Listener[serial.Serial],
}

// What the disk check is given (disk_check.main).
DiskCheckGrants :: struct {
    log : slop_os.DebugLog?,
    disk : os.Channel[block.Block]?,
}

// What a virtio block device's driver is given (virtio_blk.main): its device, and a listener for its clients.
VirtioBlkGrants :: struct {
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
    clients : os.Listener[block.Block],
}

// The modules of what the supervisor starts, besides hello.
Modules :: struct {
    console : slop_os.Memory?,
    disk_check : slop_os.Memory?,
    virtio_blk : slop_os.Memory?,
    virtio_console : slop_os.Memory?,
    virtio_rng : slop_os.Memory?,
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

Started :: struct {
    name : string,
    process : slop_os.Process,
}

Supervisor :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    root : slop_os.Channel,
    root_port : slop_os.Port,
    // What it started, which its port watches under their indexes
    started : Started[MAX_STARTED],
    started_count : usize,
    port : slop_os.Port,
    // The first serial line's driver's listener, and the console service's, which the supervisor connects clients
    // through; NO_HANDLE without
    serial_listener : slop_os.Channel,
    console_listener : slop_os.Channel,
    // The first disk's driver's listener, likewise
    block_listener : slop_os.Channel,
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager], root: os.Channel[supervision.Supervision],
    hello_module: slop_os.Memory, platform_service: os.Channel[platform.Platform]?, entropy_service: os.Channel[entropy.Entropy]?,
    console_module: slop_os.Memory?, disk_check_module: slop_os.Memory?, virtio_blk_module: slop_os.Memory?,
    virtio_console_module: slop_os.Memory?, virtio_rng_module: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    none :: cast[slop_os.Channel](slop_os.NO_HANDLE)
    supervisor := Supervisor.{block = startup, manager = manager, root = root.end, serial_listener = none, console_listener = none,
        block_listener = none}
    modules :: Modules.{console = console_module, disk_check = disk_check_module, virtio_blk = virtio_blk_module,
        virtio_console = virtio_console_module, virtio_rng = virtio_rng_module}
    supervisor.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    supervisor.manager_port = os.port_for(startup.budget, manager.end) or_return 1
    supervisor.root_port = os.port_for(startup.budget, root.end) or_return 2
    supervisor.port = slop_os.port_create(startup.budget) or_return 3
    // Each driver, for every device it takes
    match platform_service {
        case Some(platform_end) => {
            platform_port :: os.port_for(startup.budget, platform_end.end) or_return 4
            for each in system_config.SERVICES {
                if !system_config.is_driver(each) || each.starter != system_config.Starter.Supervisor {
                    continue
                }
                wanted :: each.devices
                loop {
                    device :: claim(&supervisor, platform_end.end, platform_port, wanted) or_break
                    if each.name == "virtio_rng" {
                        start_virtio_rng(&supervisor, each, device, modules.virtio_rng, entropy_service)
                    }
                    else if each.name == "virtio_console" {
                        start_virtio_console(&supervisor, each, device, modules.virtio_console)
                    }
                    else if each.name == "virtio_blk" {
                        start_virtio_blk(&supervisor, each, device, modules.virtio_blk)
                    }
                    else {
                        close_device(&device)
                    }
                }
            }
        }
        case None => {}
    }
    // Then the services that use them
    start_console(&supervisor, modules.console)
    start_hello(&supervisor, hello_module)
    start_disk_check(&supervisor, modules.disk_check)
    log_line.write(supervisor.log, "supervisor: started % services", supervisor.started_count)
    tell_root(&supervisor, .AllStarted(cast[u32](supervisor.started_count)))
    loop {
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(supervisor.port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            index :: cast[usize](packet.key)
            if packet.kind == .Signal && index < supervisor.started_count && index < supervisor.started.count {
                name :: supervisor.started[index].name
                log_line.write(supervisor.log, "supervisor: % ended", name)
                tell_root(&supervisor, .Ended(report_of(name, packet.data[1])))
            }
        }
    }
}

start_hello :: fn(supervisor: ptr[mut Supervisor], module: slop_os.Memory) {
    service :: system_config.service("hello") or_return void
    grants := HelloGrants.{log = duplicate_log(supervisor)}
    grants.manager = process_manager.connect(supervisor.manager.end, supervisor.manager_port, supervisor.block.budget)
    if cast[slop_os.Handle](supervisor.console_listener) != slop_os.NO_HANDLE {
        port :: os.port_for(supervisor.block.budget, supervisor.console_listener) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        grants.console = console_log.connect(supervisor.console_listener, port, supervisor.block.budget)
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module, service.budget, hello.main, grants) {
        case Ok(launched) => started(supervisor, service.name, launched.process)
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// A driver for a virtio entropy device, with what it holds of it; the device's handles go to it, or are closed.
start_virtio_rng :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service, device: platform.PciDevice, module: slop_os.Memory?,
    entropy_service: os.Channel[entropy.Entropy]?) {
    grants := VirtioRngGrants.{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5)}
    match entropy_service {
        case Some(service_end) => {
            entropy_port :: os.port_for(supervisor.block.budget, service_end.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
            grants.entropy_service = entropy.connect(service_end.end, entropy_port, supervisor.block.budget)
        }
        case None => {}
    }
    executable :: module or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    // By its constant name, which outlives the service's copy
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, virtio_rng.main, grants) {
        case Ok(launched) => started(supervisor, "virtio_rng", launched.process)
        case Error(error) => failed(supervisor, service.name, error)
    }
}

/*
 * A driver for a virtio console, with what it holds of it and a listener for its clients, whose other end the
 * supervisor keeps if it's the first serial line.
 */
start_virtio_console :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service, device: platform.PciDevice, module: slop_os.Memory?) {
    pair := slop_os.ChannelPair.{}
    match os.channel_for[serial.Serial](supervisor.block.budget, 0) {
        case Ok(made) => pair = made
        case Error(error) => {
            close_device(&device)
            return void
        }
    }
    grants := VirtioConsoleGrants.{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5), clients = os.Listener[serial.Serial].{end = pair.a}}
    executable :: module or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, virtio_console.main, grants) {
        case Ok(launched) => {
            started(supervisor, "virtio_console", launched.process)
            if cast[slop_os.Handle](supervisor.serial_listener) == slop_os.NO_HANDLE {
                supervisor.serial_listener = pair.b
            }
        }
        case Error(error) => failed(supervisor, service.name, error)
    }
}

/*
 * A driver for a virtio block device, with what it holds of it and a listener for its clients, whose other end the
 * supervisor keeps if it's the first disk.
 */
start_virtio_blk :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service, device: platform.PciDevice, module: slop_os.Memory?) {
    pair := slop_os.ChannelPair.{}
    match os.channel_for[block.Block](supervisor.block.budget, 0) {
        case Ok(made) => pair = made
        case Error(error) => {
            close_device(&device)
            return void
        }
    }
    grants := VirtioBlkGrants.{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5), clients = os.Listener[block.Block].{end = pair.a}}
    executable :: module or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, virtio_blk.main, grants) {
        case Ok(launched) => {
            started(supervisor, "virtio_blk", launched.process)
            if cast[slop_os.Handle](supervisor.block_listener) == slop_os.NO_HANDLE {
                supervisor.block_listener = pair.b
            }
        }
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// The disk check, given the first disk, if there is one.
start_disk_check :: fn(supervisor: ptr[mut Supervisor], module: slop_os.Memory?) {
    if cast[slop_os.Handle](supervisor.block_listener) == slop_os.NO_HANDLE {
        return void
    }
    service :: system_config.service("disk_check") or_return void
    executable :: module or_return void
    port :: os.port_for(supervisor.block.budget, supervisor.block_listener) or_return void
    grants := DiskCheckGrants.{log = duplicate_log(supervisor), disk = block.connect(supervisor.block_listener, port, supervisor.block.budget)}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, disk_check.main, grants) {
        case Ok(launched) => started(supervisor, "disk_check", launched.process)
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// The console service, given the first serial line if there's one, and a listener for its clients.
start_console :: fn(supervisor: ptr[mut Supervisor], module: slop_os.Memory?) {
    service :: system_config.service("console") or_return void
    executable :: module or_return void
    pair :: os.channel_for[console_log.ConsoleLog](supervisor.block.budget, 0) or_return void
    grants := ConsoleGrants.{log = duplicate_log(supervisor), clients = os.Listener[console_log.ConsoleLog].{end = pair.a}}
    if cast[slop_os.Handle](supervisor.serial_listener) != slop_os.NO_HANDLE {
        port :: os.port_for(supervisor.block.budget, supervisor.serial_listener) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        grants.serial_line = serial.connect(supervisor.serial_listener, port, supervisor.block.budget)
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, executable, service.budget, console.main, grants) {
        case Ok(launched) => {
            started(supervisor, "console", launched.process)
            supervisor.console_listener = pair.b
        }
        case Error(error) => failed(supervisor, service.name, error)
    }
}

// The next device wanted matches, claimed from the platform service, or null once there are none.
claim :: fn(supervisor: ptr[mut Supervisor], end: slop_os.Channel, port: slop_os.Port, wanted: platform.DeviceMatch) -> platform.PciDevice? {
    out := os.Outgoing.{}
    request :: os.begin[platform.Request](&out)
    request^ = .Claim(wanted)
    if platform.send_request(end, port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match platform.receive_response(end, port, &into, true) {
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

// A service started: watched until it ends, and reported.
started :: fn(supervisor: ptr[mut Supervisor], name #escaping : string, process: slop_os.Process) {
    index :: supervisor.started_count
    if index < supervisor.started.count {
        supervisor.started[index] = Started.{name = name, process = process}
        supervisor.started_count = index + 1
        _ = slop_os.port_bind(supervisor.port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, cast[u64](index), .Once)
    }
    tell_root(supervisor, .Started(report_of(name, 0)))
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
