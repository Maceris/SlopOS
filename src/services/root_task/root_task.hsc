/**
 * The root task (decisions/0012, 0060, 0067, 0068): the one process the kernel starts, given everything. It
 * splits its budget and starts the services the system configuration gives it: the entropy service and the process
 * manager with its own loader (src/process_builder), since the manager needs both, then the supervisor
 * through the manager, with std/os's launch. It owns each, serves the supervisor's reports, and watches
 * them. A working system's root task never ends; restarting the supervisor comes later.
 *
 * The system configuration is the boot set's system.records, which the build wrote from system_config (decisions/0110):
 * the root task checks it as the build did, and ends with 30 if it isn't one, before it starts anything; and gives it
 * to the scheduler service and the supervisor. It imports system_config only so the build has it to write.
 *
 * Words on the kernel's command line are for boot tests, and end it with 0 if what they test works:
 * - test_services, once the supervisor has started all of its services, and a second more, or test_settle=<seconds>;
 * - test_outlive_manager, which kills the process manager once the supervisor reports hello started, and
 *   ends once hello has, after it said it's still running;
 * - test_deadline=<seconds>, with test_program: how long the test program has to end before the root task kills it
 *   and ends with 26, so a test that waits for good, as one can when fault injection fails what it set up
 *   (decisions/0104), ends instead; none without the word.
 * - test_program=<name>, which launches the test program src/tests/<name> in place of the supervisor, and
 *   ends once it has, with 0 if it ended with 0 and its budget is back to nothing (decisions/0069).
 */
package root_task

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import strings from "std"
import text_buffer from "std"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import boot_info from "../../boot_info"
import process_builder from "../../process_builder"
import entropy from "../../protocols/entropy"
import platform_protocol from "../../protocols/platform"
import scheduler_protocol from "../../protocols/scheduler"
import supervision from "../../protocols/supervision"
import connector from "../../protocols/connector"
import concurrency from "std"
import events from "../../protocols/events"
import random_stream from "../../random_stream"
import service_kit from "../../libraries/service_kit"
import bundle from "../../bundle"
import substitution from "../../substitution"
// Only for the build, which writes system.records from the root task's program (decisions/0110)
import system_config from "../../system_config"
import system_records from "../../system_records"
import platform from "../platform"
import scheduler from "../scheduler"
import supervisor from "../supervisor"
import test_kit from "../../test_kit"
import test_syscalls from "../../tests/test_syscalls"

MAX_STARTED :: 8
/** The most typed libraries a test is given */
MAX_TEST_LIBRARIES :: 4
/** The most grants a service the root task loads itself is given, its libraries among them */
MAX_SELF_GRANTS :: 24
/** The port's key for the supervisor's reports; a started service's is its index. */
SUPERVISOR_KEY : u64 : 1000

/** What the supervisor is given (supervisor.main). */
SupervisorGrants :: struct {
    log : slop_os.DebugLog?,
    manager : os.Channel[connector.Connector],
    root : os.Channel[supervision.Supervision],
    hello_module : slop_os.Memory?,
    platform_service : os.Channel[connector.Connector]?,
    entropy_service : os.Channel[connector.Connector]?,
    terminal_module : slop_os.Memory?,
    echo_module : slop_os.Memory?,
    sessions_module : slop_os.Memory?,
    input_module : slop_os.Memory?,
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
    scheduler : os.Channel[connector.Connector]?,
    clock_module : slop_os.Memory?,
    events_module : slop_os.Memory?,
    bundle_store_module : slop_os.Memory?,
    config_module : slop_os.Memory?,
    update_module : slop_os.Memory?,
    system : slop_os.Memory,
    /**
     * The boot before's panic record's text, if it stopped for a fault, for the terminal service to show (decisions/0139)
     */
    last_panic : slop_os.Memory?,
}

/** What the scheduler service is given (scheduler.main). */
SchedulerGrants :: struct {
    log : slop_os.DebugLog?,
    cpu_budget : slop_os.CpuBudget,
    clients : os.Listener[scheduler_protocol.Scheduler],
    system : slop_os.Memory,
}

/** What the platform service is given (platform.main). */
PlatformGrants :: struct {
    log : slop_os.DebugLog?,
    platform : slop_os.Platform,
    firmware : slop_os.Memory,
    clients : os.Listener[platform_protocol.Platform],
    command_line : slop_os.Memory?,
}

/** How long test_services waits once everything has started, for drivers to come up, in nanoseconds */
SETTLE_NANOSECONDS : u64 : 1_000_000_000

/** What a test program is given: every test's entry takes these (src/tests, test_kit). */
TestGrants :: struct {
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    firmware : slop_os.Memory?,
    // A connection to the manager, and the program's own module, for a test that launches copies of itself
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    /** What a copy is given by the test that launched it; never by the root task */
    peer : slop_os.Channel?,
    /** The root CPU budget, for the test of CPU budgets (decisions/0093) */
    cpu_budget : slop_os.CpuBudget?,
}

/** A test program's memory budget. */
TEST_BUDGET : u64 : 32 * 1024 * 1024

/** A service the root task started, and owns. */
Started :: struct {
    name : string,
    process : slop_os.Process,
    // Its memory budget, where the root task made it, closed once it's ended; and its log records' ring, where it has
    // one, given back to the events service then
    budget : slop_os.MemoryBudget,
    ring : slop_os.Memory,
    // Its restarts since restarts_since, and whether it's ended for good
    restarts : u32,
    restarts_since : u64,
    done : bool,
}

/** The services the root task starts that it serves connectors to (decisions/0140), and starts again when they end. */
RootService :: enum {
    Entropy,
    ProcessManager,
    Scheduler,
    Platform,
}

/** A connector the root task serves: its end, and what it dials. */
RootConnector :: struct {
    end : slop_os.Channel,
    service : RootService,
}

MAX_CONNECTORS :: 16
// Connectors are bound to the connectors' port from here on; and the key the connector thread is woken by when one's added
CONNECTOR_KEY : u64 : 2000
NEW_CONNECTOR_KEY : u64 : 1999
// As the supervisor's: up to three times in a minute
RESTARTS : u32 : 3
RESTART_WINDOW : u64 : 60_000_000_000

Root :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    // The system configuration, checked, and the boot set's module it came from
    records : ptr[system_records.SystemRecords],
    records_module : slop_os.Memory,
    stream : random_stream.Stream,
    // Its ends of the entropy service's and the process manager's listeners, through which it connects
    // services to them, and the manager's also its own connection; and the ports their answers wake
    entropy : slop_os.Channel,
    entropy_port : slop_os.Port,
    manager : slop_os.Channel,
    manager_port : slop_os.Port,
    /** Its end of the supervisor's reports */
    supervision : slop_os.Channel,
    // Its end of the scheduler service's listener, and the port its answers wake, or NO_HANDLE without one
    scheduler : slop_os.Channel,
    scheduler_port : slop_os.Port,
    // Its end of the platform service's listener, and the port its answers wake, or NO_HANDLE without one
    platform_end : slop_os.Channel,
    platform_port : slop_os.Port,
    // What restarting its services needs again: the platform capability, the root CPU budget and the command line
    platform : slop_os.Platform,
    cpu_budget : slop_os.CpuBudget,
    command_line : slop_os.Memory,
    // The port it watches what it started on, and the one its connectors are served on, by a thread of its own
    port : slop_os.Port,
    connector_port : slop_os.Port,
    connectors : RootConnector[MAX_CONNECTORS],
    connector_count : usize,
    // Each held while its service's end of the listener is used or replaced, since that thread uses them too; and the
    // connectors' while they're added to or read
    entropy_lock : concurrency.SpinLock,
    manager_lock : concurrency.SpinLock,
    scheduler_lock : concurrency.SpinLock,
    platform_lock : concurrency.SpinLock,
    connectors_lock : concurrency.SpinLock,
    // A connection to the events service, once the supervisor gives one, for the services it starts again to log through
    events_end : slop_os.Channel,
    events_port : slop_os.Port,
    // The budget and the ring of the service started last, until its entry takes them
    launched_budget : slop_os.MemoryBudget,
    launched_ring : slop_os.Memory,
    started : Started[MAX_STARTED],
    started_count : usize,
    // The generation's substitution policy applied (decisions/0125): each library of its own the policy replaces, by
    // its name, and the substitute's memory, which every launch is given in its place
    substituted : os.LaunchLibrary[bundle.MAX_SUBSTITUTIONS],
    substituted_count : usize,
    /** What a launch is given of them: a copy of each substitute's handle */
    launch_libraries : os.LaunchLibrary[bundle.MAX_SUBSTITUTIONS],
}

main :: fn(platform: slop_os.Platform, debug_log: slop_os.DebugLog, command_line: slop_os.Memory, cpu_budget: slop_os.CpuBudget) -> int {
    block :: slop_os.startup_block()
    log_line.write(debug_log, "root task: started, with % grants", block.grant_count)
    // The system configuration, checked before anything is started from it
    records_module :: cast[slop_os.Memory](find_module(block, RECORDS_MODULE) or_else slop_os.NO_HANDLE)
    records :: match service_kit.read_records(block, records_module) {
        case Ok(read) => read
        case Error(problem) => {
            service :: if problem.service < system_records.MAX_SERVICES { problem.service } else { 0 }
            log_line.write(debug_log, "root task: % %, at service %", RECORDS_MODULE, problem.reason, service)
            return 30
        }
    }
    root :: runtime.new(Root)
    root^ = Root.{block = block, log = debug_log, records = records, records_module = records_module,
        scheduler = cast[slop_os.Channel](slop_os.NO_HANDLE), platform_end = cast[slop_os.Channel](slop_os.NO_HANDLE), events_end = cast[slop_os.Channel](slop_os.NO_HANDLE), platform = platform,
        cpu_budget = cpu_budget, command_line = command_line}
    root.port = slop_os.port_create(block.budget) or_return 11
    root.connector_port = slop_os.port_create(block.budget) or_return 11
    slop_os.port_bind_wake(root.connector_port, NEW_CONNECTOR_KEY) or_return 11
    // Its connectors served on a thread of its own (decisions/0140), so a client dialing one, as the process manager
    // dials the entropy service while the root task waits on it, is answered whatever the root task is waiting on
    node := runtime.extension_node(cast[ptr[Root]](root))
    push_context with_root (extensions = &node) {
        server :: runtime.thread_create(connector_thread)
        if !runtime.thread_start(server) {
            return 17
        }
    }
    words :: service_kit.text_of(block, command_line) or_return 4
    apply_substitutions(root)
    // The generation the bootloader booted, which it says on the command line (decisions/0113)
    if service_kit.has_word(words, "recovery") {
        log_line.write(debug_log, "root task: booted the recovery generation")
    }
    else {
        match service_kit.word_after(words, "generation=") {
            case Some(number) => log_line.write(debug_log, "root task: booted generation %", number)
            case None => {}
        }
    }
    // The boot before stopped for a fault, and its panic record's text is here (boot_info.PanicRecord, decisions/0134)
    match find_module(block, boot_info.LAST_PANIC_MODULE) {
        case Some(module) => {
            text :: service_kit.text_of(block, cast[slop_os.Memory](module)) or_else ""
            // Its first line, without where in the kernel, which the whole record on the ESP keeps
            first := text
            for character, i in text {
                if character == '\n' {
                    first = text[0..<i]
                    break
                }
            }
            for character, i in first {
                end :: i + 4
                if character == ' ' && end <= first.count && i < end {
                    if first[i..<end] == " at " {
                        first = first[0..<i]
                        break
                    }
                }
            }
            log_line.write(debug_log, "root task: the boot before stopped for a fault: %", first)
        }
        case None => {}
    }
    test_services :: service_kit.has_word(words, "test_services")
    // test_settle=<seconds>: longer, for a test that types into the console after its banner
    settle_seconds :: service_kit.number_of(service_kit.word_after(words, "test_settle=") or_else "") or_else 0
    settle_nanoseconds :: if settle_seconds > 0 { settle_seconds * 1_000_000_000 } else { SETTLE_NANOSECONDS }
    test_outlive_manager :: service_kit.has_word(words, "test_outlive_manager")
    root.stream = random_stream.make(block.seed)

    supervision_pair :: os.channel_for[supervision.Supervision](block.budget, 0) or_return 5
    root.supervision = supervision_pair.a

    // The entropy service, and the process manager, with a connector to it
    if !start_entropy(root) || !start_manager(root) {
        return 7
    }

    match service_kit.word_after(words, "test_program=") {
        case Some(name) => {
            seconds :: service_kit.number_of(service_kit.word_after(words, "test_deadline=") or_else "") or_else 0
            // test_changed_library: each library's changed build given in its place, as a substitution would (decisions/0120)
            return run_test(root, name, platform, cpu_budget, seconds, service_kit.has_word(words, "test_changed_library"))
        }
        case None => {}
    }

    module_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    // A program's module may be run too, so whoever loads it maps its code from it, shared (decisions/0124)
    program_rights :: cast[slop_os.Rights](cast[u32](module_rights) | cast[u32](slop_os.RIGHT_MEMORY_EXECUTE))
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    start_scheduler(root, cpu_budget)
    start_platform(root)

    // The supervisor, through the manager, with a connection of its own
    service :: service_of(root, "supervisor") or_return 8
    module :: find_module(block, service.module) or_return 8
    grants := SupervisorGrants.{
        log = duplicate_log(root),
        manager = connector_to(root, .ProcessManager) or_return 9,
        root = os.Channel[supervision.Supervision].{end = supervision_pair.b},
        hello_module = module_copy(root, "hello", program_rights),
        platform_service = if root.platform_end != NO_CHANNEL { connector_to(root, .Platform) } else { null },
        entropy_service = connector_to(root, .Entropy),
        terminal_module = module_copy(root, "terminal", program_rights),
        echo_module = module_copy(root, "echo", program_rights),
        sessions_module = module_copy(root, "sessions", program_rights),
        input_module = module_copy(root, "input", program_rights),
        disk_check_module = module_copy(root, "disk_check", program_rights),
        virtio_blk_module = module_copy(root, "virtio_blk", program_rights),
        virtio_console_module = module_copy(root, "virtio_console", program_rights),
        virtio_input_module = module_copy(root, "virtio_input", program_rights),
        virtio_rng_module = module_copy(root, "virtio_rng", program_rights),
        edu_dma_module = module_copy(root, "edu_dma", program_rights),
        storage_manager_module = module_copy(root, "storage_manager", program_rights),
        partition_server_module = module_copy(root, "partition_server", program_rights),
        fat_server_module = module_copy(root, "fat_server", program_rights),
        container_service_module = module_copy(root, "container_service", program_rights),
        volume_server_module = module_copy(root, "volume_server", program_rights),
        scheduler = if root.scheduler != NO_CHANNEL { connector_to(root, .Scheduler) } else { null },
        clock_module = module_copy(root, "clock", program_rights),
        events_module = module_copy(root, "events", program_rights),
        bundle_store_module = module_copy(root, "bundle_store", program_rights),
        config_module = module_copy(root, "config", program_rights),
        update_module = module_copy(root, "update", program_rights),
        system = records_copy(root) or_return 8,
    }
    match slop_os.handle_duplicate(cast[slop_os.Handle](command_line), module_rights) {
        case Ok(copy) => grants.command_line = cast[slop_os.Memory](copy)
        case Error(error) => {}
    }
    match find_module(block, boot_info.LAST_PANIC_MODULE) {
        case Some(module) => {
            match slop_os.handle_duplicate(cast[slop_os.Handle](module), module_rights) {
                case Ok(copy) => grants.last_panic = cast[slop_os.Memory](copy)
                case Error(error) => {}
            }
        }
        case None => {}
    }
    supervisor_options :: os.LaunchOptions.{cpu_budget = budget_for(root, service.name), libraries = substitutes(root)}
    concurrency.lock(&root.manager_lock)
    supervisor_launch :: os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, supervisor.main,
        grants, supervisor_options)
    concurrency.unlock(&root.manager_lock)
    match supervisor_launch {
        case Ok(launched) => {
            remember(root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
        }
        case Error(error) => {
            log_line.write(root.log, "root task: % didn't start: %", service.name, error)
            return 10
        }
    }

    // Then it watches
    port :: root.port
    for &started, i in root.started {
        if i >= root.started_count {
            break
        }
        // Without the watch it wouldn't know the process ended, and would wait for it for good
        if slop_os.port_bind(port, cast[slop_os.Handle](started.process), slop_os.SIGNAL_TERMINATED, cast[u64](i), .Once) is_error {
            log_line.write(root.log, "root task: can't watch %", started.name)
            return 14
        }
    }
    supervisor_signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(port, cast[slop_os.Handle](root.supervision), supervisor_signals, SUPERVISOR_KEY, .Persistent) is_error {
        log_line.write(root.log, "root task: can't watch the supervisor's channel")
        return 15
    }
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
                        kill(root, "process_manager")
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
                case EventsService(connection) => {
                    // The services it starts again log through it from now on
                    if root.events_end != NO_CHANNEL {
                        _ = slop_os.handle_close(cast[slop_os.Handle](root.events_end))
                        _ = slop_os.handle_close(cast[slop_os.Handle](root.events_port))
                    }
                    root.events_end = connection.end
                    root.events_port = os.port_for(block.budget, connection.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
                }
                case Healthy => log_line.write(root.log, "root task: the system is healthy")
                case Degraded(count) => log_line.write(root.log, "root task: the boot is degraded: % services the system needs aren't up", count)
                case AllStarted(count) => {
                    log_line.write(root.log, "root task: the supervisor started all % of its services", count)
                    if service_kit.has_word(words, "test_restart_root_services") && !test_root_restarts(root) {
                        return 16
                    }
                    if test_services {
                        // Drivers come up by themselves once they've started
                        settle :: (slop_os.clock_monotonic() or_else 0) + settle_nanoseconds
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
                restart(root, key)
            }
        }
    }
}

/**
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
    service :: service_of(root, name) or_return .Error("the system configuration doesn't have it")
    budget :: slop_os.memory_budget_create(block.budget, service.budget) or_return .Error("no budget")
    root.launched_budget = budget
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
    // With the root task's own libraries, as os.launch gives a launched program its launcher's (decisions/0121)
    all : process_builder.Grant[MAX_SELF_GRANTS]
    count := cast[usize](0)
    for grant in grants {
        if count >= all.count {
            return .Error("too many grants")
        }
        all[count] = grant
        count += 1
    }
    library_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_EXECUTE)
        | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    for &grant in slop_os.grants_of(block) {
        label :: slop_os.label_of(grant)
        if grant.kind != .Memory || !strings.starts_with(label, "library:") {
            continue
        }
        if count >= all.count {
            return .Error("too many grants")
        }
        given := grant.handle
        for &kept, i in root.substituted {
            if i < root.substituted_count && label.count == "library:".count + kept.name.count && strings.ends_with(label, kept.name) {
                given = cast[slop_os.Handle](kept.memory)
            }
        }
        all[count] = process_builder.grant(label, slop_os.handle_duplicate(given, library_rights) or_return .Error("a library can't be shared"))
        count += 1
    }
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    given :: if count <= all.count { all[0..<count] } else { all[0..<0] }
    match process_builder.build(target, file, given, seed, &root.stream, cast[slop_os.Memory](module)) {
        case Ok(thread) => return .Ok(process)
        case Error(error) => return .Error("its loader failed")
    }
}

/*
 * The test program name, launched through the manager with TestGrants, and watched until it ends: 0 if it
 * ended with 0, and its budget, once its grace period has passed, is back to nothing.
 */
run_test :: fn(root: ptr[mut Root], name: string, platform: slop_os.Platform, cpu_budget: slop_os.CpuBudget, seconds: u64,
    changed_libraries: bool) -> int {
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
    concurrency.lock(&root.manager_lock)
    match process_manager.connect(root.manager, root.manager_port, block.budget) {
        case Some(connection) => grants.manager = connection
        case None => {}
    }
    concurrency.unlock(&root.manager_lock)
    // Only the tests of CPU budgets are given the root one
    if name == "test_cpu_budgets" || name == "test_budgets" || name == "test_affinity" {
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
    // A test is given the root task's own libraries (os.launch, decisions/0121); with test_changed_library, each
    // library's changed build, <name>_changed.library, in its place, as a substitution would (0120)
    library_storage : os.LaunchLibrary[MAX_TEST_LIBRARIES]
    library_count := cast[usize](0)
    changed_ending :: "_changed.library"
    for &grant in slop_os.grants_of(block) {
        label :: slop_os.label_of(grant)
        if !changed_libraries || grant.kind != .Memory || !strings.starts_with(label, "library:") || !strings.ends_with(label, changed_ending)
            || library_count >= library_storage.count {
            continue
        }
        // Named as what it stands in for: its label without library: and _changed, then .library
        start :: "library:".count
        stem :: label.count - changed_ending.count
        replaced :: if start <= stem && stem <= label.count { label[start..<stem] } else { label }
        // The name from the label of the library it stands in for, which the startup block holds
        wanted_storage : u8[slop_os.GRANT_LABEL_SIZE]
        wanted := text_buffer.make(wanted_storage)
        text_buffer.append(&wanted, "library:")
        text_buffer.append(&wanted, replaced)
        text_buffer.append(&wanted, ".library")
        file := ""
        for &other in slop_os.grants_of(block) {
            other_label :: slop_os.label_of(other)
            if other_label == text_buffer.as_string(&wanted) && start <= other_label.count {
                file = other_label[start..<other_label.count]
            }
        }
        if file.count == 0 {
            continue
        }
        library_rights :: cast[slop_os.Rights](cast[u32](module_rights) | cast[u32](slop_os.RIGHT_MEMORY_EXECUTE))
        match slop_os.handle_duplicate(grant.handle, library_rights) {
            case Ok(copy) => {
                library_storage[library_count] = os.LaunchLibrary.{name = file, memory = cast[slop_os.Memory](copy)}
                library_count += 1
            }
            case Error(error) => {}
        }
    }
    // Without changed builds, the generation's substitutes
    libraries :: if library_count == 0 { substitutes(root) } else if library_count <= library_storage.count { library_storage[0..<library_count] }
        else { library_storage[0..<0] }
    launched := os.Launched.{}
    concurrency.lock(&root.manager_lock)
    test_launch :: os.launch(manager, root.manager_port, name, cast[slop_os.Memory](module), TEST_BUDGET, test_syscalls.main, grants,
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = 0}, libraries = libraries})
    concurrency.unlock(&root.manager_lock)
    match test_launch {
        case Ok(made) => launched = made
        case Error(error) => {
            log_line.write(root.log, "root task: % didn't start: %", name, error)
            return 22
        }
    }
    packets : slop_os.Packet[1]
    deadline :: if seconds == 0 { slop_os.NO_DEADLINE } else { (slop_os.clock_monotonic() or_else 0) + seconds * 1_000_000_000 }
    if (slop_os.port_wait(port, packets, deadline) or_return 23) == 0 {
        log_line.write(root.log, "root task: % didn't end within % seconds, so it's killed", name, seconds)
        _ = slop_os.process_kill(launched.process)
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_return 23
        _ = test_kit.wait_for_budget(launched.budget, 0, 2_000_000_000)
        return 26
    }
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

/**
 * The platform service, through the manager, with the hardware and the firmware tables that describe it: a connection
 * to it, for the supervisor, or null without the tables or if it didn't start.
 */
start_platform :: fn(root: ptr[mut Root]) {
    block :: root.block
    platform_capability :: root.platform
    command_line :: root.command_line
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    firmware :: slop_os.find_grant(block, "firmware", .Memory) or_return void
    service :: service_of(root, "platform") or_return void
    module :: find_module(block, service.module) or_return void
    pair :: os.channel_for[platform_protocol.Platform](block.budget, 0) or_return void
    port :: os.port_for(block.budget, pair.b) or_return void
    capability_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    grants := PlatformGrants.{
        log = duplicate_log(root),
        platform = cast[slop_os.Platform](slop_os.handle_duplicate(cast[slop_os.Handle](platform_capability), capability_rights) or_return void),
        firmware = cast[slop_os.Memory](slop_os.handle_duplicate(firmware, rights) or_return void),
        clients = os.Listener[platform_protocol.Platform].{end = pair.a},
    }
    match slop_os.handle_duplicate(cast[slop_os.Handle](command_line), rights) {
        case Ok(copy) => grants.command_line = cast[slop_os.Memory](copy)
        case Error(error) => {}
    }
    options :: launch_options(root, service.name)
    concurrency.lock(&root.manager_lock)
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    launch :: os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, platform.main, grants, options)
    concurrency.unlock(&root.manager_lock)
    match launch {
        case Ok(launched) => {
            root.launched_budget = launched.budget
            remember(root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
            concurrency.lock(&root.platform_lock)
            if root.platform_end != NO_CHANNEL {
                _ = slop_os.handle_close(cast[slop_os.Handle](root.platform_end))
                _ = slop_os.handle_close(cast[slop_os.Handle](root.platform_port))
            }
            root.platform_end = pair.b
            root.platform_port = port
            concurrency.unlock(&root.platform_lock)
        }
        case Error(error) => log_line.write(root.log, "root task: % didn't start: %", service.name, error)
    }
}

NO_CHANNEL : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

/**
 * The entropy service, by the root task's own loader, with a listener whose other end the root task keeps, to connect
 * its clients through: whether it started.
 */
start_entropy :: fn(root: ptr[mut Root]) -> bool {
    block :: root.block
    pair :: os.channel_for[entropy.Entropy](block.budget, 0) or_return false
    grants : process_builder.Grant[4]
    grants[0] = process_builder.grant("log", cast[slop_os.Handle](duplicate_log(root) or_return false))
    grants[1] = process_builder.grant("clients", cast[slop_os.Handle](pair.a))
    count :: 2 + events_grants(root, "entropy", grants[2..<4])
    start_itself(root, "entropy", if count <= grants.count { grants[0..<count] } else { grants[0..<2] }) or_return false
    port :: os.port_for(block.budget, pair.b) or_return false
    concurrency.lock(&root.entropy_lock)
    if root.entropy != NO_CHANNEL {
        _ = slop_os.handle_close(cast[slop_os.Handle](root.entropy))
        _ = slop_os.handle_close(cast[slop_os.Handle](root.entropy_port))
    }
    root.entropy = pair.b
    root.entropy_port = port
    concurrency.unlock(&root.entropy_lock)
    return true
}

/**
 * The process manager, by the root task's own loader, with a connector to the entropy service and a listener whose
 * other end is the root task's own connection to it: whether it started.
 */
start_manager :: fn(root: ptr[mut Root]) -> bool {
    block :: root.block
    pair :: os.channel_for[process_manager.ProcessManager](block.budget, process_manager.RING_BYTES) or_return false
    entropy_connector :: connector_to(root, .Entropy) or_return false
    grants : process_builder.Grant[5]
    grants[0] = process_builder.grant("log", cast[slop_os.Handle](duplicate_log(root) or_return false))
    grants[1] = process_builder.grant("entropy", cast[slop_os.Handle](entropy_connector.end))
    grants[2] = process_builder.grant("clients", cast[slop_os.Handle](pair.a))
    count :: 3 + events_grants(root, "process_manager", grants[3..<5])
    start_itself(root, "process_manager", if count <= grants.count { grants[0..<count] } else { grants[0..<3] }) or_return false
    port :: os.port_for(block.budget, pair.b) or_return false
    concurrency.lock(&root.manager_lock)
    if root.manager != NO_CHANNEL {
        _ = slop_os.handle_close(cast[slop_os.Handle](root.manager))
        _ = slop_os.handle_close(cast[slop_os.Handle](root.manager_port))
    }
    root.manager = pair.b
    root.manager_port = port
    concurrency.unlock(&root.manager_lock)
    return true
}

/**
 * A ring for the log records of the service named name, once the supervisor has given the root task a connection to the
 * events service: its grants, "events" both, into grants, the root task keeping the ring for the service's entry. How
 * many.
 */
events_grants :: fn(root: ptr[mut Root], name: string, grants: mut process_builder.Grant[]) -> usize {
    launched :: open_ring(root, name) or_return 0
    if grants.count < 2 {
        return 0
    }
    grants[0] = process_builder.grant("events", cast[slop_os.Handle](launched.ring))
    grants[1] = process_builder.grant("events", cast[slop_os.Handle](launched.doorbell))
    return 2
}

/** A ring from the events service for name, the root task keeping it and giving a copy, or null before it has one. */
open_ring :: fn(root: ptr[mut Root], name: string) -> os.LaunchEvents? {
    if root.events_end == NO_CHANNEL {
        return null
    }
    opened :: events.open(root.events_end, root.events_port, name) or_return null
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](opened.ring), rights) {
        case Ok(copy) => {
            retire_ring(root, root.launched_ring)
            root.launched_ring = opened.ring
            return os.LaunchEvents.{ring = cast[slop_os.Memory](copy), doorbell = opened.doorbell}
        }
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](opened.ring))
            _ = slop_os.handle_close(cast[slop_os.Handle](opened.doorbell))
            return null
        }
    }
}

/** A ring given back to the events service once its writer's ended, so it reads what's left; closed if it can't be. */
retire_ring :: fn(root: ptr[mut Root], ring: slop_os.Memory) {
    if cast[slop_os.Handle](ring) == slop_os.NO_HANDLE {
        return void
    }
    if root.events_end != NO_CHANNEL {
        out := os.Outgoing.{}
        request :: os.begin[events.Request](&out)
        request^ = .Retire(ring)
        into := os.Incoming.{}
        match events.ask(root.events_end, root.events_port, &out, &into) {
            case Done => return void
            case _ => {}
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](ring))
}

/**
 * What a launch through the manager is given besides its grants: its CPU budget, the libraries, a ring for its records.
 */
launch_options :: fn(root: ptr[mut Root], name: string) -> os.LaunchOptions {
    options := os.LaunchOptions.{cpu_budget = budget_for(root, name), libraries = substitutes(root)}
    options.events = open_ring(root, name)
    return options
}

/**
 * A connector to one of the root task's services (decisions/0140), served on its port: the client's end, or null if
 * there's no room. A client dials through it, and dials again when what it reached is started again.
 */
connector_to :: fn(root: ptr[mut Root], service: RootService) -> os.Channel[connector.Connector]? {
    pair :: os.channel_for[connector.Connector](root.block.budget, 0) or_return null
    concurrency.lock(&root.connectors_lock)
    defer concurrency.unlock(&root.connectors_lock)
    index :: root.connector_count
    if index >= root.connectors.count {
        return null
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(root.connector_port, cast[slop_os.Handle](pair.b), signals, CONNECTOR_KEY + cast[u64](index), .Persistent) is_error {
        return null
    }
    root.connectors[index] = RootConnector.{end = pair.b, service = service}
    root.connector_count = index + 1
    // Its first read is the connector thread's, which arms it: a channel wakes its reader only once it's found empty
    _ = slop_os.port_wake(root.connector_port, NEW_CONNECTOR_KEY, 1)
    return os.Channel[connector.Connector].{end = pair.a}
}

/**
 * The connector thread: every Dial answered, waiting on the connectors' port between them, for as long as the root task runs.
 */
connector_thread : runtime.ThreadFunction : fn(data #escaping : any) {
    found :: runtime.get_extension(Root) or_return void
    root :: cast[ptr[mut Root]](found)
    loop {
        serve_connectors(root)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(root.connector_port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Every connector's Dials, each answered with a new connection to what it reaches, or Unavailable while it's restarting.
 */
serve_connectors :: fn(root: ptr[mut Root]) {
    for i in cast[usize](0)..<MAX_CONNECTORS {
        concurrency.lock(&root.connectors_lock)
        record := RootConnector.{end = NO_CHANNEL}
        if i < root.connector_count && i < root.connectors.count {
            record = root.connectors[i]
        }
        concurrency.unlock(&root.connectors_lock)
        if record.end == NO_CHANNEL {
            continue
        }
        into := os.Incoming.{}
        loop {
            match connector.receive_request(record.end, root.connector_port, &into, false) {
                case Received => {}
                case Empty => break
                case Unsupported => {
                    _ = connector.answer_unsupported(record.end, root.connector_port)
                    continue
                }
                case Failed(error) => {
                    _ = slop_os.port_unbind(root.connector_port, CONNECTOR_KEY + cast[u64](i))
                    _ = slop_os.handle_close(cast[slop_os.Handle](record.end))
                    concurrency.lock(&root.connectors_lock)
                    if i < root.connectors.count {
                        root.connectors[i].end = NO_CHANNEL
                    }
                    concurrency.unlock(&root.connectors_lock)
                    break
                }
                case _ => continue
            }
            out := os.Outgoing.{}
            response :: os.begin[connector.Response](&out)
            match dial_service(root, record.service) {
                case Some(channel) => response^ = .Dialed(channel)
                case None => response^ = .Unavailable
            }
            _ = connector.send_response(record.end, root.connector_port, &out)
        }
    }
}

/** A new connection to one of its services, through its listener, or null while it isn't running. */
dial_service :: fn(root: ptr[mut Root], service: RootService) -> slop_os.Channel? {
    budget :: root.block.budget
    name :: name_of(service)
    for &started, i in root.started {
        if i < root.started_count && started.name == name && started.done {
            return null
        }
    }
    lock :: match service {
        case .Entropy => &root.entropy_lock
        case .ProcessManager => &root.manager_lock
        case .Scheduler => &root.scheduler_lock
        case .Platform => &root.platform_lock
    }
    concurrency.lock(lock)
    defer concurrency.unlock(lock)
    return match service {
        case .Entropy => if root.entropy == NO_CHANNEL { cast[slop_os.Channel?](null) }
            else { (entropy.connect(root.entropy, root.entropy_port, budget) or_return null).end }
        case .ProcessManager => if root.manager == NO_CHANNEL { cast[slop_os.Channel?](null) }
            else { (process_manager.connect(root.manager, root.manager_port, budget) or_return null).end }
        case .Scheduler => if root.scheduler == NO_CHANNEL { cast[slop_os.Channel?](null) }
            else { (scheduler_protocol.connect(root.scheduler, root.scheduler_port, budget) or_return null).end }
        case .Platform => if root.platform_end == NO_CHANNEL { cast[slop_os.Channel?](null) }
            else { (platform_protocol.connect(root.platform_end, root.platform_port, budget) or_return null).end }
    }
}

name_of :: fn(service: RootService) -> string {
    return match service {
        case .Entropy => "entropy"
        case .ProcessManager => "process_manager"
        case .Scheduler => "scheduler"
        case .Platform => "platform"
    }
}

/**
 * What's started at key ended: its budget closed, so what it had comes back, and its ring given back; and one of the
 * services the root task serves connectors to started again, as the supervisor starts its own again (decisions/0140), up
 * to RESTARTS times in RESTART_WINDOW, watched under the same key.
 */
restart :: fn(root: ptr[mut Root], key: usize) {
    if key >= root.started_count || key >= root.started.count {
        return void
    }
    entry :: &root.started[key]
    entry.done = true
    if cast[slop_os.Handle](entry.budget) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](entry.budget))
        entry.budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    }
    retire_ring(root, entry.ring)
    entry.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    name :: entry.name
    restarted :: name == "entropy" || name == "process_manager" || name == "scheduler" || name == "platform"
    if !restarted {
        return void
    }
    now :: slop_os.clock_monotonic() or_else 0
    if now - entry.restarts_since > RESTART_WINDOW {
        entry.restarts = 0
        entry.restarts_since = now
    }
    if entry.restarts >= RESTARTS {
        log_line.write(root.log, "root task: % ended % times in a minute, and isn't started again", name, RESTARTS + 1)
        return void
    }
    entry.restarts += 1
    old :: entry.process
    if name == "entropy" {
        _ = start_entropy(root)
    }
    else if name == "process_manager" {
        _ = start_manager(root)
    }
    else if name == "scheduler" {
        start_scheduler(root, root.cpu_budget)
    }
    else {
        start_platform(root)
    }
    if key >= root.started.count || root.started[key].process == old {
        log_line.write(root.log, "root task: % couldn't be started again", name)
        return void
    }
    if slop_os.port_bind(root.port, cast[slop_os.Handle](root.started[key].process), slop_os.SIGNAL_TERMINATED, cast[u64](key), .Once) is_error {
        log_line.write(root.log, "root task: can't watch % again", name)
    }
    log_line.write(root.log, "root task: started % again", name)
}

/**
 * test_restart_root_services: once the supervisor has started everything, each of the root task's services killed in
 * turn, the process manager's after the entropy service's and before the two it starts, which are started again
 * through it; each started again and answering through a connector before the next. Whether all four did.
 */
test_root_restarts :: fn(root: ptr[mut Root]) -> bool {
    for service in RootService.[.Entropy, .ProcessManager, .Scheduler, .Platform] {
        name :: name_of(service)
        before := cast[slop_os.Process](slop_os.NO_HANDLE)
        key := root.started.count
        for &started, i in root.started {
            if i < root.started_count && started.name == name {
                before = started.process
                key = i
            }
        }
        if key >= root.started.count {
            log_line.write(root.log, "root task: test_restart_root_services: there's no %", name)
            return false
        }
        log_line.write(root.log, "root task: test_restart_root_services: killing %", name)
        _ = slop_os.process_kill(before)
        // Its end, its restart, and the supervisor dialing it again, served meanwhile
        deadline :: (slop_os.clock_monotonic() or_else 0) + 5_000_000_000
        loop {
            watch_until(root, deadline)
        }
        while (root.started[key % root.started.count].process == before || root.started[key % root.started.count].done)
            && (slop_os.clock_monotonic() or_else 0) < deadline
        // Time for its clients to dial it again
        watch_until(root, (slop_os.clock_monotonic() or_else 0) + 500_000_000)
        connection :: dial_service(root, service) or_else NO_CHANNEL
        if connection == NO_CHANNEL || !answers(root, service, connection) {
            log_line.write(root.log, "root task: test_restart_root_services: % doesn't answer", name)
            return false
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](connection))
        log_line.write(root.log, "root task: test_restart_root_services: % answers again", name)
    }
    log_line.write(root.log, "root task: test_restart_root_services: all four started again")
    return true
}

/** Waits on the port until deadline or a packet, restarting what ended and serving connectors. */
watch_until :: fn(root: ptr[mut Root], deadline: u64) {
    packets : slop_os.Packet[8]
    taken :: slop_os.port_wait(root.port, packets, deadline) or_else 0
    for packet, i in packets {
        if i >= cast[usize](taken) {
            break
        }
        key :: cast[usize](packet.key)
        if packet.kind == .Signal && key < root.started_count && key < root.started.count {
            log_line.write(root.log, "root task: % ended", root.started[key].name)
            restart(root, key)
        }
    }
}

/** Whether a new connection to service answers a request: entropy bytes, a budget, a claim's answer, a connection. */
answers :: fn(root: ptr[mut Root], service: RootService, connection: slop_os.Channel) -> bool {
    port :: os.port_for(root.block.budget, connection) or_return false
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    match service {
        case .Entropy => {
            out := os.Outgoing.{}
            os.begin[entropy.Request](&out)^ = .Fill(16)
            if entropy.send_request(connection, port, &out) != null {
                return false
            }
            into := os.Incoming.{}
            return entropy.receive_response(connection, port, &into, true) == .Received
        }
        case .ProcessManager => {
            // It took a connection of its own; the scheduler and the platform service are launched through it next
            made :: process_manager.connect(connection, port, root.block.budget) or_return false
            _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            return true
        }
        case .Scheduler => return scheduler_protocol.budget_for(connection, port, "hello") is_some
        case .Platform => {
            out := os.Outgoing.{}
            os.begin[platform_protocol.Request](&out)^ = .ClaimClock
            if platform_protocol.send_request(connection, port, &out) != null {
                return false
            }
            into := os.Incoming.{}
            return platform_protocol.receive_response(connection, port, &into, true) == .Received
        }
    }
}

// A copy of the module a service is started from, for whoever starts it, or null.
/**
 * The scheduler service, through the manager, with the root CPU budget to split (decisions/0093): every service the
 * root task starts after it, and every one the supervisor does, runs on a budget it splits. Without it, they run on
 * the root's, as before.
 */
start_scheduler :: fn(root: ptr[mut Root], cpu_budget: slop_os.CpuBudget) {
    block :: root.block
    service :: service_of(root, "scheduler") or_return void
    module :: find_module(block, service.module) or_return void
    pair :: os.channel_for[scheduler_protocol.Scheduler](block.budget, 0) or_return void
    port :: os.port_for(block.budget, pair.b) or_return void
    budget_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER)
        | cast[u32](slop_os.RIGHT_CPU_BUDGET_SPLIT) | cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND))
    grants :: SchedulerGrants.{
        log = duplicate_log(root),
        cpu_budget = cast[slop_os.CpuBudget](slop_os.handle_duplicate(cast[slop_os.Handle](cpu_budget), budget_rights) or_return void),
        clients = os.Listener[scheduler_protocol.Scheduler].{end = pair.a},
        system = records_copy(root) or_return void,
    }
    // On the root's budget, which it splits; its own budgets, and what runs on them, go to the root's if it ends
    options := launch_options(root, service.name)
    options.cpu_budget = null
    concurrency.lock(&root.manager_lock)
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    launch :: os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, scheduler.main, grants, options)
    concurrency.unlock(&root.manager_lock)
    match launch {
        case Ok(launched) => {
            root.launched_budget = launched.budget
            remember(root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
            concurrency.lock(&root.scheduler_lock)
            if root.scheduler != NO_CHANNEL {
                _ = slop_os.handle_close(cast[slop_os.Handle](root.scheduler))
                _ = slop_os.handle_close(cast[slop_os.Handle](root.scheduler_port))
            }
            root.scheduler = pair.b
            root.scheduler_port = port
            concurrency.unlock(&root.scheduler_lock)
        }
        case Error(error) => log_line.write(root.log, "root task: % didn't start: %", service.name, error)
    }
}

/** The CPU budget the scheduler service gives the service named name, or null to run it on the root's. */
budget_for :: fn(root: ptr[mut Root], name: string) -> slop_os.CpuBudget? {
    concurrency.lock(&root.scheduler_lock)
    defer concurrency.unlock(&root.scheduler_lock)
    if cast[slop_os.Handle](root.scheduler) == slop_os.NO_HANDLE {
        return null
    }
    return scheduler_protocol.budget_for(root.scheduler, root.scheduler_port, name)
}

/** A connection of its own to the scheduler service, or null without one. */
connect_scheduler :: fn(root: ptr[mut Root]) -> os.Channel[scheduler_protocol.Scheduler]? {
    concurrency.lock(&root.scheduler_lock)
    defer concurrency.unlock(&root.scheduler_lock)
    if cast[slop_os.Handle](root.scheduler) == slop_os.NO_HANDLE {
        return null
    }
    return scheduler_protocol.connect(root.scheduler, root.scheduler_port, root.block.budget)
}

module_copy :: fn(root: ptr[Root], name: string, rights: slop_os.Rights) -> slop_os.Memory? {
    service :: service_of(root, name) or_return null
    module :: find_module(root.block, service.module) or_return null
    match slop_os.handle_duplicate(module, rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

/** A service started, by its name, which is a constant's, in its entry if it has one already, as a restart has. */
remember :: fn(root: ptr[mut Root], name #escaping : string, process: slop_os.Process) {
    for &started, i in root.started {
        if i < root.started_count && started.name == name {
            started.process = process
            started.done = false
            started.budget = root.launched_budget
            root.launched_budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
            started.ring = root.launched_ring
            root.launched_ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
            return void
        }
    }
    index :: root.started_count
    if index < root.started.count {
        root.started[index] = Started.{name = name, process = process, budget = root.launched_budget, ring = root.launched_ring}
        root.launched_budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
        root.launched_ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
        root.started_count = index + 1
    }
}

/** The boot set's module the system configuration is in. */
RECORDS_MODULE :: "system.records"

/** A service of the system configuration's: its name, its module and its memory budget. */
Service :: struct {
    name : string,
    module : string,
    budget : u64,
}

/** The service of the system configuration named name, or null. */
service_of :: fn(root: ptr[Root], name: string) -> Service? {
    record :: system_records.service_of(root.records, name) or_return null
    return Service.{name = system_records.text_of(&record.name), module = system_records.text_of(&record.module), budget = record.budget}
}

/** A read-only copy of the system configuration's module, to give a service. */
records_copy :: fn(root: ptr[Root]) -> slop_os.Memory? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.records_module), rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

/** A copy of the root task's debug log, to give a service. */
duplicate_log :: fn(root: ptr[mut Root]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

/** A started service killed, by name. */
kill :: fn(root: ptr[mut Root], name: string) {
    for &started, i in root.started {
        if i < root.started_count && started.name == name {
            log_line.write(root.log, "root task: killing %", name)
            _ = slop_os.process_kill(started.process)
        }
    }
}

/**
 * The generation's substitution policy, its boot-set file substitutions.records if it has one (decisions/0123, 0125),
 * applied: each entry whose from is one of the root task's libraries, by its file's hash, and whose to is another that
 * passes the check against it, its substitute from then on. The root task itself keeps what it was bound to.
 */
apply_substitutions :: fn(root: ptr[mut Root]) {
    module :: find_module(root.block, substitution.POLICY_FILE) or_return void
    file :: substitution.mapped(root.block, module) or_return void
    policy :: substitution.policy_of(file.bytes)
    substitution.unmap(root.block, file)
    found :: match policy {
        case Some(read) => read
        case None => {
            log_line.write(root.log, "root task: % isn't a substitution policy", substitution.POLICY_FILE)
            return void
        }
    }
    for &entry, i in found.entries {
        if cast[u64](i) >= found.count || root.substituted_count >= root.substituted.count {
            break
        }
        old :: substitution.own_library(root.block, entry.from) or_continue
        new :: substitution.own_library(root.block, entry.to) or_continue
        match substitution.check(root.block, cast[slop_os.Handle](old.memory), cast[slop_os.Handle](new.memory)) {
            case Some(why) => log_line.write(root.log, "root task: a substitution of % is refused: %", old.name, why)
            case None => {
                place :: root.substituted_count
                if place < root.substituted.count {
                    root.substituted[place] = os.LaunchLibrary.{name = old.name, memory = new.memory}
                    root.substituted_count = place + 1
                    hex_storage : u8[64]
                    log_line.write(root.log, "root task: % is substituted by %", old.name, bundle.hex(entry.to, &hex_storage))
                }
            }
        }
    }
}

/** What a launch is given in place of the root task's own libraries: a copy of each substitute's handle. */
substitutes :: fn(root: ptr[mut Root]) -> os.LaunchLibrary[] {
    library_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_EXECUTE)
        | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    given := cast[usize](0)
    for &kept, i in root.substituted {
        if i >= root.substituted_count || given >= root.launch_libraries.count {
            break
        }
        match slop_os.handle_duplicate(cast[slop_os.Handle](kept.memory), library_rights) {
            case Ok(copy) => {
                root.launch_libraries[given] = os.LaunchLibrary.{name = kept.name, memory = cast[slop_os.Memory](copy)}
                given += 1
            }
            case Error(error) => {}
        }
    }
    return if given <= root.launch_libraries.count { root.launch_libraries[0..<given] } else { root.launch_libraries[0..<0] }
}

/** The boot module's grant, "module:<module>". */
find_module :: fn(block: ptr[slop_os.StartupBlock], module: string) -> slop_os.Handle? {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "module:")
    text_buffer.append(&label, module)
    return slop_os.find_grant(block, text_buffer.as_string(&label), .Memory)
}

