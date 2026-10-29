/*
 * The root task (decisions/0012, 0060, 0067, 0068): the one process the kernel starts, given everything. It
 * splits its budget and starts the services system_config gives it: the entropy service and the process
 * manager with its own loader (src/process_builder), since the manager needs both, then the supervisor
 * through the manager, with std/os's launch. It owns each, serves the supervisor's reports, and watches
 * them. A working system's root task never ends; restarting the supervisor comes later.
 *
 * Words on the kernel's command line are for boot tests, and end it with 0 if what they test works:
 * - test_services, once the supervisor has started all of its services;
 * - test_outlive_manager, which kills the process manager once the supervisor reports hello started, and
 *   ends once hello has, after it said it's still running;
 * - test_program=<name>, which launches the test program src/tests/<name> in place of the supervisor, and
 *   ends once it has, with 0 if it ended with 0 and its budget is back to nothing (decisions/0069).
 */
package root_task

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import entropy from "../../protocols/entropy"
import platform_protocol from "../../protocols/platform"
import scheduler_protocol from "../../protocols/scheduler"
import supervision from "../../protocols/supervision"
import random_stream from "../../random_stream"
import service_kit from "../../service_kit"
import system_config from "../../system_config"
import platform from "../platform"
import scheduler from "../scheduler"
import supervisor from "../supervisor"
import test_kit from "../../test_kit"
import test_syscalls from "../../tests/test_syscalls"

MAX_STARTED :: 8
// The port's key for the supervisor's reports; a started service's is its index.
SUPERVISOR_KEY : u64 : 1000

// What the supervisor is given (supervisor.main).
SupervisorGrants :: struct {
    log : slop_os.DebugLog?,
    manager : os.Channel[process_manager.ProcessManager],
    root : os.Channel[supervision.Supervision],
    hello_module : slop_os.Memory?,
    platform_service : os.Channel[platform_protocol.Platform]?,
    entropy_service : os.Channel[entropy.Entropy]?,
    console_module : slop_os.Memory?,
    disk_check_module : slop_os.Memory?,
    virtio_blk_module : slop_os.Memory?,
    virtio_console_module : slop_os.Memory?,
    virtio_input_module : slop_os.Memory?,
    virtio_rng_module : slop_os.Memory?,
    edu_dma_module : slop_os.Memory?,
    storage_manager_module : slop_os.Memory?,
    partition_server_module : slop_os.Memory?,
    fat_server_module : slop_os.Memory?,
    container_service_module : slop_os.Memory?,
    volume_server_module : slop_os.Memory?,
    command_line : slop_os.Memory?,
    scheduler : os.Channel[scheduler_protocol.Scheduler]?,
    clock_module : slop_os.Memory?,
}

// What the scheduler service is given (scheduler.main).
SchedulerGrants :: struct {
    log : slop_os.DebugLog?,
    cpu_budget : slop_os.CpuBudget,
    clients : os.Listener[scheduler_protocol.Scheduler],
}

// What the platform service is given (platform.main).
PlatformGrants :: struct {
    log : slop_os.DebugLog?,
    platform : slop_os.Platform,
    firmware : slop_os.Memory,
    clients : os.Listener[platform_protocol.Platform],
    command_line : slop_os.Memory?,
}

// How long test_services waits once everything has started, for drivers to come up, in nanoseconds
SETTLE_NANOSECONDS : u64 : 1_000_000_000

// What a test program is given: every test's entry takes these (src/tests, test_kit).
TestGrants :: struct {
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    firmware : slop_os.Memory?,
    // A connection to the manager, and the program's own module, for a test that launches copies of itself
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    // What a copy is given by the test that launched it; never by the root task
    peer : slop_os.Channel?,
    // The root CPU budget, for the test of CPU budgets (decisions/0093)
    cpu_budget : slop_os.CpuBudget?,
}

// A test program's memory budget.
TEST_BUDGET : u64 : 32 * 1024 * 1024

// A service the root task started, and owns.
Started :: struct {
    name : string,
    process : slop_os.Process,
}

Root :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    stream : random_stream.Stream,
    // Its ends of the entropy service's and the process manager's listeners, through which it connects
    // services to them, and the manager's also its own connection; and the ports their answers wake
    entropy : slop_os.Channel,
    entropy_port : slop_os.Port,
    manager : slop_os.Channel,
    manager_port : slop_os.Port,
    // Its end of the supervisor's reports
    supervision : slop_os.Channel,
    // Its end of the scheduler service's listener, and the port its answers wake, or NO_HANDLE without one
    scheduler : slop_os.Channel,
    scheduler_port : slop_os.Port,
    started : Started[MAX_STARTED],
    started_count : usize,
}

main :: fn(platform: slop_os.Platform, debug_log: slop_os.DebugLog, command_line: slop_os.Memory, cpu_budget: slop_os.CpuBudget) -> int {
    block :: slop_os.startup_block()
    root := Root.{block = block, log = debug_log, scheduler = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    log_line.write(root.log, "root task: started, with % grants", block.grant_count)
    words :: service_kit.text_of(block, command_line) or_return 4
    test_services :: service_kit.has_word(words, "test_services")
    test_outlive_manager :: service_kit.has_word(words, "test_outlive_manager")
    root.stream = random_stream.make(block.seed)

    // The listeners the root task connects services through, its own connection to the manager among them
    entropy_pair :: os.channel_for[entropy.Entropy](block.budget, 0) or_return 5
    root.entropy = entropy_pair.b
    root.entropy_port = os.port_for(block.budget, root.entropy) or_return 5
    manager_pair :: os.channel_for[process_manager.ProcessManager](block.budget, process_manager.RING_BYTES) or_return 5
    root.manager = manager_pair.b
    root.manager_port = os.port_for(block.budget, root.manager) or_return 5
    supervision_pair :: os.channel_for[supervision.Supervision](block.budget, 0) or_return 5
    root.supervision = supervision_pair.a

    // The entropy service, and the process manager, with a connection of its own to it
    entropy_grants :: process_builder.Grant.[
        process_builder.grant("log", cast[slop_os.Handle](duplicate_log(&root) or_return 6)),
        process_builder.grant("clients", cast[slop_os.Handle](entropy_pair.a)),
    ]
    start_itself(&root, "entropy", entropy_grants) or_return 7
    manager_entropy :: entropy.connect(root.entropy, root.entropy_port, block.budget) or_return 6
    manager_grants :: process_builder.Grant.[
        process_builder.grant("log", cast[slop_os.Handle](duplicate_log(&root) or_return 6)),
        process_builder.grant("entropy", cast[slop_os.Handle](manager_entropy.end)),
        process_builder.grant("clients", cast[slop_os.Handle](manager_pair.a)),
    ]
    start_itself(&root, "process_manager", manager_grants) or_return 7

    match service_kit.word_after(words, "test_program=") {
        case Some(name) => return run_test(&root, name, platform, cpu_budget)
        case None => {}
    }

    module_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    start_scheduler(&root, cpu_budget)
    platform_connection :: start_platform(&root, platform, command_line, module_rights)

    // The supervisor, through the manager, with a connection of its own
    service :: system_config.service("supervisor") or_return 8
    module :: find_module(block, service.module) or_return 8
    grants := SupervisorGrants.{
        log = duplicate_log(&root),
        manager = process_manager.connect(root.manager, root.manager_port, block.budget) or_return 9,
        root = os.Channel[supervision.Supervision].{end = supervision_pair.b},
        hello_module = module_copy(block, "hello", module_rights),
        platform_service = platform_connection,
        entropy_service = entropy.connect(root.entropy, root.entropy_port, block.budget),
        console_module = module_copy(block, "console", module_rights),
        disk_check_module = module_copy(block, "disk_check", module_rights),
        virtio_blk_module = module_copy(block, "virtio_blk", module_rights),
        virtio_console_module = module_copy(block, "virtio_console", module_rights),
        virtio_input_module = module_copy(block, "virtio_input", module_rights),
        virtio_rng_module = module_copy(block, "virtio_rng", module_rights),
        edu_dma_module = module_copy(block, "edu_dma", module_rights),
        storage_manager_module = module_copy(block, "storage_manager", module_rights),
        partition_server_module = module_copy(block, "partition_server", module_rights),
        fat_server_module = module_copy(block, "fat_server", module_rights),
        container_service_module = module_copy(block, "container_service", module_rights),
        volume_server_module = module_copy(block, "volume_server", module_rights),
        scheduler = connect_scheduler(&root),
        clock_module = module_copy(block, "clock", module_rights),
    }
    match slop_os.handle_duplicate(cast[slop_os.Handle](command_line), module_rights) {
        case Ok(copy) => grants.command_line = cast[slop_os.Memory](copy)
        case Error(error) => {}
    }
    match os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, supervisor.main, grants,
        os.LaunchOptions.{cpu_budget = budget_for(&root, service.name)}) {
        case Ok(launched) => {
            remember(&root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
        }
        case Error(error) => {
            log_line.write(root.log, "root task: % didn't start: %", service.name, error)
            return 10
        }
    }

    // Then it watches
    port :: slop_os.port_create(block.budget) or_return 11
    for &started, i in root.started {
        if i >= root.started_count {
            break
        }
        _ = slop_os.port_bind(port, cast[slop_os.Handle](started.process), slop_os.SIGNAL_TERMINATED, cast[u64](i), .Once)
    }
    supervisor_signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    _ = slop_os.port_bind(port, cast[slop_os.Handle](root.supervision), supervisor_signals, SUPERVISOR_KEY, .Persistent)
    into := os.Incoming.{}
    loop {
        loop {
            if cast[slop_os.Handle](root.supervision) == slop_os.NO_HANDLE {
                break
            }
            match supervision.receive_request(root.supervision, port, &into, false) {
                case Received => {}
                case Empty => break
                case Failed(error) => {
                    // Gone, which it stays: its end is closed, so its signal doesn't wake the port again
                    log_line.write(root.log, "root task: the supervisor's channel is gone (%)", error)
                    _ = slop_os.handle_close(cast[slop_os.Handle](root.supervision))
                    root.supervision = cast[slop_os.Channel](slop_os.NO_HANDLE)
                    break
                }
                case _ => continue
            }
            match os.message_of[supervision.Request](&into)^ {
                case Started(report) => {
                    named := report
                    name :: service_kit.text_of_label(&named.name)
                    log_line.write(root.log, "root task: the supervisor started %", name)
                    if test_outlive_manager && name == "hello" {
                        kill(&root, "process_manager")
                    }
                }
                case Ended(report) => {
                    named := report
                    name :: service_kit.text_of_label(&named.name)
                    log_line.write(root.log, "root task: the supervisor's % ended with %", name, report.code)
                    if test_outlive_manager && name == "hello" {
                        return if report.code == 0 { 0 } else { 12 }
                    }
                }
                case Failed(report) => {
                    named := report
                    name :: service_kit.text_of_label(&named.name)
                    log_line.write(root.log, "root task: the supervisor's % didn't start (%)", name, report.code)
                    if test_services || test_outlive_manager {
                        return 13
                    }
                }
                case AllStarted(count) => {
                    log_line.write(root.log, "root task: the supervisor started all % of its services", count)
                    if test_services {
                        // Drivers come up by themselves once they've started
                        settle :: (slop_os.clock_monotonic() or_else 0) + SETTLE_NANOSECONDS
                        loop {
                            waited : slop_os.Packet[1]
                            if (slop_os.port_wait(port, waited, settle) or_else 0) == 0 {
                                break
                            }
                        }
                        return 0
                    }
                }
            }
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            key :: cast[usize](packet.key)
            if packet.kind == .Signal && key < root.started_count && key < root.started.count {
                name :: root.started[key].name
                ended :: packet.data[1]
                if ended == slop_os.EXIT_KILLED {
                    log_line.write(root.log, "root task: % was killed", name)
                }
                else {
                    log_line.write(root.log, "root task: % ended with %", name, ended)
                }
            }
        }
    }
}

/*
 * A service system_config names, loaded by the root task itself into a process of its own, with a budget
 * split off the root task's, a seed drawn from its stream, and grants: its process, which it remembers, or
 * null after saying why.
 */
start_itself :: fn(root: ptr[mut Root], name #escaping : string, grants: process_builder.Grant[]) -> slop_os.Process? {
    block :: root.block
    why :: start_with_loader(root, name, grants)
    match why {
        case Ok(process) => {
            remember(root, name, process)
            log_line.write(root.log, "root task: started %", name)
            return process
        }
        case Error(failure) => {
            log_line.write(root.log, "root task: % didn't start: %", name, failure)
            return null
        }
    }
}

start_with_loader :: fn(root: ptr[mut Root], name: string, grants: process_builder.Grant[]) -> Result[slop_os.Process, string] {
    block :: root.block
    service :: system_config.service(name) or_return .Error("system_config doesn't have it")
    budget :: slop_os.memory_budget_create(block.budget, service.budget) or_return .Error("no budget")
    process :: slop_os.process_create(budget) or_return .Error("no process")
    space :: slop_os.address_space_create(budget) or_return .Error("no address space")
    module :: find_module(block, service.module) or_return .Error("its module isn't there")
    size :: slop_os.memory_size(cast[slop_os.Memory](module)) or_return .Error("its module has no size")
    address :: runtime.reserve_addresses(cast[usize](size)) or_return .Error("no room to read its module")
    slop_os.memory_map(cast[slop_os.Memory](module), block.space, address, 0, size, slop_os.PROTECTION_READ) or_return .Error("its module doesn't map")
    defer _ = slop_os.memory_unmap(block.space, address)
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    // Its seed, drawn from the root task's stream, so the two never share one
    seed : u8[32]
    random_stream.fill(&root.stream, seed)
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    match process_builder.build(target, file, grants, seed, &root.stream) {
        case Ok(thread) => return .Ok(process)
        case Error(error) => return .Error("its loader failed")
    }
}

/*
 * The test program name, launched through the manager with TestGrants, and watched until it ends: 0 if it
 * ended with 0, and its budget, once its grace period has passed, is back to nothing.
 */
run_test :: fn(root: ptr[mut Root], name: string, platform: slop_os.Platform, cpu_budget: slop_os.CpuBudget) -> int {
    block :: root.block
    module_storage : u8[slop_os.GRANT_LABEL_SIZE]
    module_name := text_buffer.make(module_storage)
    text_buffer.append(&module_name, name)
    text_buffer.append(&module_name, ".elf")
    module :: find_module(block, text_buffer.as_string(&module_name)) or_return 20
    grants := TestGrants.{log = duplicate_log(root) or_return 21}
    module_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(module, module_rights) {
        case Ok(copy) => grants.program = cast[slop_os.Memory](copy)
        case Error(error) => {}
    }
    match process_manager.connect(root.manager, root.manager_port, block.budget) {
        case Some(connection) => grants.manager = connection
        case None => {}
    }
    // Only the test of CPU budgets is given the root one
    if name == "test_cpu_budgets" {
        budget_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER)
            | cast[u32](slop_os.RIGHT_CPU_BUDGET_SPLIT) | cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND))
        match slop_os.handle_duplicate(cast[slop_os.Handle](cpu_budget), budget_rights) {
            case Ok(copy) => grants.cpu_budget = cast[slop_os.CpuBudget](copy)
            case Error(error) => {}
        }
    }
    // Only the devices tests are given the hardware, and the firmware tables that describe it
    if name == "test_devices" || name == "test_msi_dma" || name == "test_io_ports" {
        platform_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
        match slop_os.handle_duplicate(cast[slop_os.Handle](platform), platform_rights) {
            case Ok(copy) => grants.platform = cast[slop_os.Platform](copy)
            case Error(error) => {}
        }
        match slop_os.find_grant(block, "test_device", .Memory) {
            case Some(device) => grants.test_device = cast[slop_os.Memory](device)
            case None => {}
        }
        match slop_os.find_grant(block, "firmware", .Memory) {
            case Some(firmware) => {
                match slop_os.handle_duplicate(firmware, module_rights) {
                    case Ok(copy) => grants.firmware = cast[slop_os.Memory](copy)
                    case Error(error) => {}
                }
            }
            case None => {}
        }
    }
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    // Every test's entry has the same type, test_syscalls.main's (system_config checks it); its end watched from before it starts
    port :: slop_os.port_create(block.budget) or_return 23
    launched := os.Launched.{}
    match os.launch(manager, root.manager_port, name, cast[slop_os.Memory](module), TEST_BUDGET, test_syscalls.main, grants,
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = 0}}) {
        case Ok(made) => launched = made
        case Error(error) => {
            log_line.write(root.log, "root task: % didn't start: %", name, error)
            return 22
        }
    }
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_return 23
    code :: packets[0].data[1]
    emptied :: test_kit.wait_for_budget(launched.budget, 0, 2_000_000_000)
    left :: test_kit.used(launched.budget)
    if emptied {
        log_line.write(root.log, "root task: % ended with %, and its budget is back to nothing", name, code)
    }
    else {
        log_line.write(root.log, "root task: % ended with %, and its budget still has % bytes charged", name, code, left)
    }
    return if code == 0 && emptied { 0 } else if code != 0 { 24 } else { 25 }
}

/*
 * The platform service, through the manager, with the hardware and the firmware tables that describe it: a connection
 * to it, for the supervisor, or null without the tables or if it didn't start.
 */
start_platform :: fn(root: ptr[mut Root], platform_capability: slop_os.Platform, command_line: slop_os.Memory, rights: slop_os.Rights)
    -> os.Channel[platform_protocol.Platform]? {
    block :: root.block
    firmware :: slop_os.find_grant(block, "firmware", .Memory) or_return null
    service :: system_config.service("platform") or_return null
    module :: find_module(block, service.module) or_return null
    pair :: os.channel_for[platform_protocol.Platform](block.budget, 0) or_return null
    port :: os.port_for(block.budget, pair.b) or_return null
    capability_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    grants := PlatformGrants.{
        log = duplicate_log(root),
        platform = cast[slop_os.Platform](slop_os.handle_duplicate(cast[slop_os.Handle](platform_capability), capability_rights) or_return null),
        firmware = cast[slop_os.Memory](slop_os.handle_duplicate(firmware, rights) or_return null),
        clients = os.Listener[platform_protocol.Platform].{end = pair.a},
    }
    match slop_os.handle_duplicate(cast[slop_os.Handle](command_line), rights) {
        case Ok(copy) => grants.command_line = cast[slop_os.Memory](copy)
        case Error(error) => {}
    }
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    match os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, platform.main, grants,
        os.LaunchOptions.{cpu_budget = budget_for(root, service.name)}) {
        case Ok(launched) => {
            remember(root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
            return platform_protocol.connect(pair.b, port, block.budget)
        }
        case Error(error) => {
            log_line.write(root.log, "root task: % didn't start: %", service.name, error)
            return null
        }
    }
}

// A copy of the module a service is started from, for whoever starts it, or null.
/*
 * The scheduler service, through the manager, with the root CPU budget to split (decisions/0093): every service the
 * root task starts after it, and every one the supervisor does, runs on a budget it splits. Without it, they run on
 * the root's, as before.
 */
start_scheduler :: fn(root: ptr[mut Root], cpu_budget: slop_os.CpuBudget) {
    block :: root.block
    service :: system_config.service("scheduler") or_return void
    module :: find_module(block, service.module) or_return void
    pair :: os.channel_for[scheduler_protocol.Scheduler](block.budget, 0) or_return void
    port :: os.port_for(block.budget, pair.b) or_return void
    budget_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER)
        | cast[u32](slop_os.RIGHT_CPU_BUDGET_SPLIT) | cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND))
    grants :: SchedulerGrants.{
        log = duplicate_log(root),
        cpu_budget = cast[slop_os.CpuBudget](slop_os.handle_duplicate(cast[slop_os.Handle](cpu_budget), budget_rights) or_return void),
        clients = os.Listener[scheduler_protocol.Scheduler].{end = pair.a},
    }
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    match os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, scheduler.main, grants) {
        case Ok(launched) => {
            remember(root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
            root.scheduler = pair.b
            root.scheduler_port = port
        }
        case Error(error) => log_line.write(root.log, "root task: % didn't start: %", service.name, error)
    }
}

// The CPU budget the scheduler service gives the service named name, or null to run it on the root's.
budget_for :: fn(root: ptr[mut Root], name: string) -> slop_os.CpuBudget? {
    if cast[slop_os.Handle](root.scheduler) == slop_os.NO_HANDLE {
        return null
    }
    return scheduler_protocol.budget_for(root.scheduler, root.scheduler_port, name)
}

// A connection of its own to the scheduler service, or null without one.
connect_scheduler :: fn(root: ptr[mut Root]) -> os.Channel[scheduler_protocol.Scheduler]? {
    if cast[slop_os.Handle](root.scheduler) == slop_os.NO_HANDLE {
        return null
    }
    return scheduler_protocol.connect(root.scheduler, root.scheduler_port, root.block.budget)
}

module_copy :: fn(block: ptr[slop_os.StartupBlock], name: string, rights: slop_os.Rights) -> slop_os.Memory? {
    service :: system_config.service(name) or_return null
    module :: find_module(block, service.module) or_return null
    match slop_os.handle_duplicate(module, rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

// A service started, by its name, which is a constant's.
remember :: fn(root: ptr[mut Root], name #escaping : string, process: slop_os.Process) {
    index :: root.started_count
    if index < root.started.count {
        root.started[index] = Started.{name = name, process = process}
        root.started_count = index + 1
    }
}

// A copy of the root task's debug log, to give a service.
duplicate_log :: fn(root: ptr[mut Root]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

// A started service killed, by name.
kill :: fn(root: ptr[mut Root], name: string) {
    for &started, i in root.started {
        if i < root.started_count && started.name == name {
            log_line.write(root.log, "root task: killing %", name)
            _ = slop_os.process_kill(started.process)
        }
    }
}

// The boot module's grant, "module:<module>".
find_module :: fn(block: ptr[slop_os.StartupBlock], module: string) -> slop_os.Handle? {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "module:")
    text_buffer.append(&label, module)
    return slop_os.find_grant(block, text_buffer.as_string(&label), .Memory)
}

