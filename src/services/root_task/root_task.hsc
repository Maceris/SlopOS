/**
 * The root task (decisions/0012, 0060, 0067, 0068): the one process the kernel starts, given everything. It
 * splits its budget and starts the services the system configuration gives it: the entropy service and the process
 * manager with its own loader (src/process_builder), since the manager needs both, then the supervisor
 * through the manager, with std/os's launch. It owns each, serves the supervisor's reports, and watches
 * them. A working system's root task ends only when the person at the console asks for it to shut down, which the
 * supervisor passes on (decisions/0180), ending everything; restarting the supervisor comes later.
 *
 * The system configuration is the boot set's system.records, which the build wrote from system_config
 * (decisions/0110): the root task checks it as the build did, and ends with 30 if it isn't one, before it starts
 * anything; and gives it to the scheduler service and the supervisor. It imports system_config only so the build has
 * it to write.
 *
 * Words on the kernel's command line are for boot tests, and end it with 0 if what they test works:
 * - test_services, once the supervisor has started all of its services, and a second more, or test_settle=<seconds>,
 *   or sooner if a shutdown's asked for meanwhile;
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

/**
 * The most services the root task starts and watches itself: the entropy service, the process manager, the
 * scheduler, the platform service and the supervisor, with room to spare. One started past this many isn't watched.
 */
MAX_STARTED :: 8
/** The most typed libraries a test is given in place of the root task's own, with test_changed_library. */
MAX_TEST_LIBRARIES :: 4
/**
 * The most grants a service the root task loads itself is given, its libraries among them; past this many, the
 * service isn't started.
 */
MAX_SELF_GRANTS :: 24
/** The port's key for the supervisor's reports; a started service's is its index in Root.started, below it. */
SUPERVISOR_KEY : u64 : 1000

/**
 * What the supervisor is given: one field for each of supervisor.main's parameters, by its name.
 *
 * Each module is a handle to a boot-set module, readable, executable, duplicable and transferable, that the supervisor
 * starts the service of that name from; it's None when the system configuration has no such service or the boot set
 * no such module. Every handle moves to the supervisor once it's launched.
 */
SupervisorGrants :: struct {
    /** A copy of the root task's debug log, writable; None if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the process manager, served by the root task, which the supervisor launches services through. */
    manager : os.Channel[connector.Connector],
    /** The supervisor's end of the channel its reports go to the root task on: what started, ended and failed. */
    root : os.Channel[supervision.Supervision],
    /** The hello program's module. */
    hello_module : slop_os.Memory?,
    /** A connector to the platform service; None when it didn't start, or there was no room for the connector. */
    platform_service : os.Channel[connector.Connector]?,
    /** A connector to the entropy service; None when there was no room for the connector. */
    entropy_service : os.Channel[connector.Connector]?,
    /** The terminal service's module. */
    terminal_module : slop_os.Memory?,
    /** The echo program's module. */
    echo_module : slop_os.Memory?,
    /** The sessions service's module. */
    sessions_module : slop_os.Memory?,
    /** The input service's module. */
    input_module : slop_os.Memory?,
    /** The disk check program's module. */
    disk_check_module : slop_os.Memory?,
    /** The virtio block driver's module. */
    virtio_blk_module : slop_os.Memory?,
    /** The virtio console driver's module. */
    virtio_console_module : slop_os.Memory?,
    /** The virtio input driver's module. */
    virtio_input_module : slop_os.Memory?,
    /** The virtio RNG driver's module. */
    virtio_rng_module : slop_os.Memory?,
    /** The edu DMA test device's driver's module. */
    edu_dma_module : slop_os.Memory?,
    /** The storage manager's module. */
    storage_manager_module : slop_os.Memory?,
    /** The partition server's module. */
    partition_server_module : slop_os.Memory?,
    /** The FAT server's module. */
    fat_server_module : slop_os.Memory?,
    /** The container service's module. */
    container_service_module : slop_os.Memory?,
    /** The volume server's module. */
    volume_server_module : slop_os.Memory?,
    /** A read-only copy of the kernel's command line; None if it couldn't be copied. */
    command_line : slop_os.Memory?,
    /** A connector to the scheduler service; None when it didn't start, or there was no room for the connector. */
    scheduler : os.Channel[connector.Connector]?,
    /** The clock service's module. */
    clock_module : slop_os.Memory?,
    /** The ACPI service's module. */
    acpi_module : slop_os.Memory?,
    /** The GPIO power button's driver's module. */
    power_button_module : slop_os.Memory?,
    /** The events service's module. */
    events_module : slop_os.Memory?,
    /** The bundle store's module. */
    bundle_store_module : slop_os.Memory?,
    /** The config store's module. */
    config_module : slop_os.Memory?,
    /** The update service's module. */
    update_module : slop_os.Memory?,
    /** A read-only copy of the system configuration's module, system.records, which the supervisor checks again. */
    system : slop_os.Memory,
    /**
     * The boot before's panic record's text, read-only, if it stopped for a fault, for the terminal service to show
     * (decisions/0139); None when it didn't.
     */
    last_panic : slop_os.Memory?,
}

/** What the scheduler service is given: one field for each of scheduler.main's parameters, by its name. */
SchedulerGrants :: struct {
    /** A copy of the root task's debug log, writable; None if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A copy of the root CPU budget, which may be split and bound, to split the services' budgets off. */
    cpu_budget : slop_os.CpuBudget,
    /** The listener's end clients connect through; the root task keeps the other, to connect them. */
    clients : os.Listener[scheduler_protocol.Scheduler],
    /** A read-only copy of the system configuration's module, which says each service's CPU share. */
    system : slop_os.Memory,
}

/** What the platform service is given: one field for each of platform.main's parameters, by its name. */
PlatformGrants :: struct {
    /** A copy of the root task's debug log, writable; None if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A copy of the platform capability, the hardware's, which the service hands out pieces of. */
    platform : slop_os.Platform,
    /** A read-only copy of the firmware tables that describe the hardware. */
    firmware : slop_os.Memory,
    /** The listener's end clients connect through; the root task keeps the other, to connect them. */
    clients : os.Listener[platform_protocol.Platform],
    /** A read-only copy of the kernel's command line; None if it couldn't be copied. */
    command_line : slop_os.Memory?,
}

/**
 * How long test_services waits once everything has started, for drivers to come up, in nanoseconds: a second, unless
 * test_settle says otherwise.
 */
SETTLE_NANOSECONDS : u64 : 1_000_000_000

/**
 * What a test program is given: every test's entry takes these (src/tests, test_kit). Every handle moves to the test
 * once it's launched.
 */
TestGrants :: struct {
    /** A copy of the root task's debug log, writable, where the test says what it found. */
    log : slop_os.DebugLog,
    /** A copy of the platform capability, for the devices tests only; None for the others. */
    platform : slop_os.Platform?,
    /** The boot set's test device grant, moved, for the devices tests only; None for the others or without one. */
    test_device : slop_os.Memory?,
    /** A read-only copy of the firmware tables, for the devices tests only; None for the others or without them. */
    firmware : slop_os.Memory?,
    /** A connection to the process manager, for a test that launches copies of itself; None if it couldn't connect. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, read-only, for a test that launches copies of itself; None if it couldn't be copied. */
    program : slop_os.Memory?,
    /** What a copy is given by the test that launched it; never by the root task, so None from it. */
    peer : slop_os.Channel?,
    /**
     * A copy of the root CPU budget, which may be split and bound, for the tests of CPU budgets (decisions/0093):
     * test_cpu_budgets, test_budgets and test_affinity; None for the others.
     */
    cpu_budget : slop_os.CpuBudget?,
}

/** A test program's memory budget, in bytes: 32 MiB. */
TEST_BUDGET : u64 : 32 * 1024 * 1024

/** A service the root task started, and owns. */
Started :: struct {
    /** Its name, the system configuration's, a constant's or a view of the configuration, kept for good. */
    name : string,
    /** Its process, the root task's own, watched for its end under its index in Root.started. */
    process : slop_os.Process,
    /**
     * Its memory budget, where the root task made it, closed once it's ended, so what it had comes back; NO_HANDLE
     * then, or when the root task didn't make it.
     */
    budget : slop_os.MemoryBudget,
    /** Its log records' ring, where it has one, given back to the events service once it's ended; else NO_HANDLE. */
    ring : slop_os.Memory,
    /** How many times it's been started again since restarts_since: 0 to RESTARTS. */
    restarts : u32,
    /** When the current window of restarts began, in nanoseconds of the monotonic clock; 0 before the first. */
    restarts_since : u64,
    /** Whether it's ended and not been started again, so it isn't dialed. */
    done : bool,
}

/** The services the root task starts that it serves connectors to (decisions/0140), and starts again when they end. */
RootService :: enum {
    /** The entropy service, which the root task loads itself. */
    Entropy,
    /** The process manager, which the root task loads itself. */
    ProcessManager,
    /** The scheduler service, launched through the process manager. */
    Scheduler,
    /** The platform service, launched through the process manager. */
    Platform,
}

/** A connector the root task serves: its end, and what it dials. */
RootConnector :: struct {
    /** The root task's end, bound to the connectors' port; NO_HANDLE once its client has gone. */
    end : slop_os.Channel,
    /** Which service each Dial on it is answered with a connection to. */
    service : RootService,
}

/** The most connectors the root task serves in its life; a closed one's place isn't reused. */
MAX_CONNECTORS :: 16
/** The connectors' port key of the first connector, the one at index i bound with CONNECTOR_KEY + i. */
CONNECTOR_KEY : u64 : 2000
/** The connectors' port key the connector thread is woken with when a connector's added, so it arms the new one. */
NEW_CONNECTOR_KEY : u64 : 1999
/** How many times a service is started again within RESTART_WINDOW, as the supervisor's: three. */
RESTARTS : u32 : 3
/** The window RESTARTS counts within, in nanoseconds: a minute. */
RESTART_WINDOW : u64 : 60_000_000_000

/**
 * The root task's state, made on the heap by main and kept for good; the connector thread reaches it through
 * context's extensions.
 */
Root :: struct {
    /** The root task's startup block, for its budget, its space and its grants. */
    block : ptr[slop_os.StartupBlock],
    /** The kernel's debug log, which the root task writes to and copies to what it starts. */
    log : slop_os.DebugLog,
    /** The system configuration, checked, copied to the heap and kept for good. */
    records : ptr[system_records.SystemRecords],
    /** The boot set's module the configuration came from, copied read-only to the scheduler and the supervisor. */
    records_module : slop_os.Memory,
    /** The stream each service the root task loads itself gets its seed from, and the placing of its parts. */
    stream : random_stream.Stream,
    /** Where the builder stages each service the root task loads, kept so restarting them doesn't use up its addresses. */
    staging : process_builder.Staging,
    /**
     * Its end of the entropy service's listener, through which it connects services to it; NO_HANDLE before it's
     * started. Held under entropy_lock.
     */
    entropy : slop_os.Channel,
    /** A port bound to entropy alone, waited on for its answers. */
    entropy_port : slop_os.Port,
    /**
     * Its end of the process manager's listener, through which it connects services to it, and its own connection,
     * which it launches through; NO_HANDLE before it's started. Held under manager_lock.
     */
    manager : slop_os.Channel,
    /** A port bound to manager alone, waited on for its answers. */
    manager_port : slop_os.Port,
    /** Its end of the supervisor's reports, bound to port; NO_HANDLE once the supervisor's end is gone. */
    supervision : slop_os.Channel,
    /**
     * Its end of the scheduler service's listener, or NO_HANDLE without one, when it didn't start. Held under
     * scheduler_lock.
     */
    scheduler : slop_os.Channel,
    /** A port bound to scheduler alone, waited on for its answers. */
    scheduler_port : slop_os.Port,
    /**
     * Its end of the platform service's listener, or NO_HANDLE without one, when it didn't start. Held under
     * platform_lock.
     */
    platform_end : slop_os.Channel,
    /** A port bound to platform_end alone, waited on for its answers. */
    platform_port : slop_os.Port,
    /** The platform capability, the kernel's grant, kept to give the platform service a copy when it's restarted. */
    platform : slop_os.Platform,
    /** The root CPU budget, the kernel's grant, kept to give the scheduler a copy when it's restarted. */
    cpu_budget : slop_os.CpuBudget,
    /** The kernel's command line, kept to give the platform service a copy when it's restarted. */
    command_line : slop_os.Memory,
    /** The port the root task watches what it started on, and the supervisor's reports. */
    port : slop_os.Port,
    /** The port its connectors are served on, by the connector thread. */
    connector_port : slop_os.Port,
    /** The connectors it serves, in the order they were made. Held under connectors_lock. */
    connectors : RootConnector[MAX_CONNECTORS],
    /** How many of connectors have been used, from the first: 0 to MAX_CONNECTORS. */
    connector_count : usize,
    /** Held while entropy and entropy_port are used or replaced, since the connector thread uses them too. */
    entropy_lock : concurrency.SpinLock,
    /** Held while manager and manager_port are used or replaced, since the connector thread uses them too. */
    manager_lock : concurrency.SpinLock,
    /** Held while scheduler and scheduler_port are used or replaced, since the connector thread uses them too. */
    scheduler_lock : concurrency.SpinLock,
    /** Held while platform_end and platform_port are used or replaced, since the connector thread uses them too. */
    platform_lock : concurrency.SpinLock,
    /** Held while connectors and connector_count are added to or read. */
    connectors_lock : concurrency.SpinLock,
    /**
     * A connection to the events service, once the supervisor gives one, for the services it starts again to log
     * through; NO_HANDLE before then, and replaced by a newer one.
     */
    events_end : slop_os.Channel,
    /** A port bound to events_end alone, or NO_HANDLE if none could be made. */
    events_port : slop_os.Port,
    /** The budget of the service started last, until remember moves it to its entry; NO_HANDLE otherwise. */
    launched_budget : slop_os.MemoryBudget,
    /** The log records' ring of the service started last, until remember moves it to its entry; NO_HANDLE otherwise. */
    launched_ring : slop_os.Memory,
    /** The services it started, each in its place for good, a restart taking the same place. */
    started : Started[MAX_STARTED],
    /** How many of started are in use, from the first: 0 to MAX_STARTED. */
    started_count : usize,
    /**
     * The generation's substitution policy applied (decisions/0125): each library of its own the policy replaces, by
     * its name, and the substitute's memory, the root task's own, which every launch is given a copy of in its place.
     */
    substituted : os.LaunchLibrary[bundle.MAX_SUBSTITUTIONS],
    /** How many of substituted are in use, from the first. */
    substituted_count : usize,
    /**
     * What the last launch was given of them: a copy of each substitute's handle, made again by substitutes for each
     * launch, which moves them to the program.
     */
    launch_libraries : os.LaunchLibrary[bundle.MAX_SUBSTITUTIONS],
}

/**
 * Start the system: the services the system configuration gives the root task, then the supervisor, which starts the
 * rest; then watch them for good.
 *
 * The kernel starts this program, and only it. It checks the boot set's system configuration first, then starts the
 * entropy service and the process manager with its own loader, the scheduler and the platform service through the
 * manager, and the supervisor last. It serves connectors to its four services on a thread of its own, starts each
 * again when it ends (RESTARTS in RESTART_WINDOW), and logs the supervisor's reports. Words on the command line run
 * boot tests instead, as the package says.
 *
 * @param platform The platform capability, the hardware's, from the kernel; kept, and copied to the platform service
 *     and to the devices tests.
 * @param debug_log The kernel's debug log, which the root task writes to and copies to everything it starts.
 * @param command_line The kernel's command line, read for the boot tests' words and the generation booted, and copied
 *     read-only to the platform service and the supervisor.
 * @param cpu_budget The root CPU budget, from the kernel; kept, and copied to the scheduler service to split, and to
 *     the tests of CPU budgets.
 * @return Nothing in a working system, which runs for good. A failure starting it: 30 when the system configuration
 *     isn't one, 11 when no port can be made, 17 when the connector thread can't start, 4 when the command line can't
 *     be read, 5 when the supervisor's channel can't be made, 7 when the entropy service or the process manager
 *     doesn't start, 8 when the supervisor's service, module or configuration copy is missing, 9 when there's no
 *     connector to the manager for it, 10 when it doesn't start, and 14 or 15 when what was started, or the
 *     supervisor's channel, can't be watched. A boot test's: 0 when it passed; with test_outlive_manager, 12 when
 *     hello ended with another code; with test_services or test_outlive_manager, 13 when the supervisor reported a
 *     service didn't start; with test_restart_root_services, 16 when a service didn't answer once started again; and
 *     with test_program, what run_test returns.
 */
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
        log = tracing_log(root),
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
        acpi_module = module_copy(root, "acpi", program_rights),
        power_button_module = module_copy(root, "power_button", program_rights),
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
    // With test_services, when it ends once the supervisor's started everything; 0 until then, and without it
    settle_at := cast[u64](0)
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
                // A message that breaks the protocol's rules ends the channel, as its going would (decisions/0177)
                case _ => {
                    log_line.write(root.log, "root task: the supervisor sent what isn't the protocol, so its channel's closed")
                    _ = slop_os.handle_close(cast[slop_os.Handle](root.supervision))
                    root.supervision = cast[slop_os.Channel](slop_os.NO_HANDLE)
                    break
                }
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
                        // Drivers come up by themselves once they've started; a shutdown asked for ends it sooner
                        settle_at = (slop_os.clock_monotonic() or_else 0) + settle_nanoseconds
                    }
                }
                case ShutDown => {
                    log_line.write(root.log, "root task: shutting down, as the console asked")
                    // Turned off once it's ended (decisions/0182); where the kernel can't yet, it halts, as before
                    match slop_os.power_end_with(root.platform, .Off) {
                        case Error(.NoPowerOff) => log_line.write(root.log, "root task: the machine can't be turned off yet, so it halts")
                        case _ => {}
                    }
                    return 0
                }
                case Restart => {
                    log_line.write(root.log, "root task: restarting, as the console asked")
                    _ = slop_os.power_end_with(root.platform, .Restart)
                    return 0
                }
            }
        }
        if settle_at != 0 && (slop_os.clock_monotonic() or_else 0) >= settle_at {
            return 0
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(port, packets, if settle_at != 0 { settle_at } else { slop_os.NO_DEADLINE }) or_else 0
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
 * Load a service the system configuration names with the root task's own loader, and remember it, to watch.
 *
 * The service gets a process of its own, a memory budget of the configuration's size split off the root task's, a
 * seed drawn from the root task's stream, and grants. Whether it starts or not is logged.
 *
 * @param root The root task, which remembers the service under name.
 * @param name The service's name, kept for good in its entry, so a constant's or the configuration's.
 * @param grants Its grants, besides the root task's libraries, which are added; their handles are the program's once
 *     it's started, and the caller's still if it isn't.
 * @return Its process, the root task's to watch; null when it didn't start.
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

/**
 * Load a service the system configuration names with the root task's own loader: start_itself's work, without the
 * remembering or the logging.
 *
 * Its budget is left in root.launched_budget for remember to take, once it's started. It's given the root task's
 * libraries too, each a copy, with the generation's substitute in place of one the policy replaces (decisions/0121,
 * 0125). When it can't be started, its budget, process and address space are destroyed, and launched_budget is left
 * as it was, so a later remember doesn't take a stale budget.
 *
 * @param root The root task, whose stream is drawn from and whose launched_budget is set once it's started.
 * @param name The service's name in the system configuration.
 * @param grants Its grants, besides the libraries; their handles are the program's once it's started, and the
 *     caller's still if it isn't.
 * @return Its process, started; or why not, a phrase to log after its name: the configuration doesn't have it, no
 *     budget, process or address space could be made, its module isn't there or can't be read, there are more than
 *     MAX_SELF_GRANTS grants, a library can't be shared, or the loader failed.
 */
start_with_loader :: fn(root: ptr[mut Root], name: string, grants: process_builder.Grant[]) -> Result[slop_os.Process, string] {
    service :: service_of(root, name) or_return .Error("the system configuration doesn't have it")
    // With its first thread's shadow stack's on top, where the CPU gives one (decisions/0186)
    budget :: slop_os.memory_budget_create(root.block.budget, service.budget + slop_os.shadow_stacks_budget(1)) or_return .Error("no budget")
    process :: match slop_os.process_create(budget) {
        case Ok(made) => made
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](budget))
            return .Error("no process")
        }
    }
    space :: match slop_os.address_space_create(budget) {
        case Ok(made) => made
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](process))
            _ = slop_os.handle_close(cast[slop_os.Handle](budget))
            return .Error("no address space")
        }
    }
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    match load_with_loader(root, service, target, grants) {
        case Some(why) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](space))
            _ = slop_os.handle_close(cast[slop_os.Handle](process))
            _ = slop_os.handle_close(cast[slop_os.Handle](budget))
            return .Error(why)
        }
        case None => {
            root.launched_budget = budget
            return .Ok(process)
        }
    }
}

/**
 * Load a service's program into a process made for it, with the root task's loader, and start its first thread.
 *
 * @param root The root task, whose stream is drawn from, whose libraries are given, and whose staging is used.
 * @param service The service, as the system configuration has it: its module is loaded.
 * @param target The process, address space and budget made for it, which the caller destroys if this fails.
 * @param grants Its grants, besides the libraries, as start_with_loader takes them.
 * @return Null once its first thread is started; or why not, a phrase as start_with_loader gives.
 */
load_with_loader :: fn(root: ptr[mut Root], service: Service, target: process_builder.Target, grants: process_builder.Grant[]) -> string? {
    block :: root.block
    module :: find_module(block, service.module) or_return "its module isn't there"
    size :: slop_os.memory_size(cast[slop_os.Memory](module)) or_return "its module has no size"
    address :: runtime.reserve_addresses(cast[usize](size)) or_return "no room to read its module"
    slop_os.memory_map(cast[slop_os.Memory](module), block.space, address, 0, size, slop_os.PROTECTION_READ) or_return "its module doesn't map"
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
            return "too many grants"
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
            return "too many grants"
        }
        given := grant.handle
        for &kept, i in root.substituted {
            if i < root.substituted_count && label.count == "library:".count + kept.name.count && strings.ends_with(label, kept.name) {
                given = cast[slop_os.Handle](kept.memory)
            }
        }
        all[count] = process_builder.grant(label, slop_os.handle_duplicate(given, library_rights) or_return "a library can't be shared")
        count += 1
    }
    given :: if count <= all.count { all[0..<count] } else { all[0..<0] }
    match process_builder.build(target, file, given, seed, &root.stream, slop_os.ABI_VERSION, &root.staging) {
        case Ok(thread) => return null
        case Error(error) => return "its loader failed"
    }
}

/**
 * Run the test program named on the command line in place of the supervisor, and tell how it went.
 *
 * The test is launched through the manager with TestGrants, a budget of TEST_BUDGET and the root task's libraries, or
 * with changed_libraries their changed builds, and waited for; then its budget is waited for, up to two seconds, to
 * come back to nothing, as what it had is freed after a grace period.
 *
 * @param root The root task, launching through its manager connection.
 * @param name The test's name, its module <name>.elf in the boot set.
 * @param platform The platform capability, copied for the devices tests: test_devices, test_msi_dma and test_io_ports.
 * @param cpu_budget The root CPU budget, copied for the tests of CPU budgets.
 * @param seconds How long the test has to end before it's killed, in seconds; 0 for no limit.
 * @param changed_libraries Whether each library's changed build, <name>_changed.library, is given in its place, as a
 *     substitution would (decisions/0120); otherwise the generation's substitutes are.
 * @return 0 when it ended with 0 and its budget came back to nothing; 24 when it ended with another code, 25 when its
 *     budget didn't come back to nothing, 26 when it was killed for not ending in time; 20 when its module isn't
 *     there, 21 when there's no copy of the log for it, 22 when it didn't start, 23 when its end can't be waited for.
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
 * Start the platform service through the manager, with the hardware and the firmware tables that describe it, and
 * remember it, to watch.
 *
 * Once it's started, the root task's end of its listener replaces root.platform_end, the old one closed, so its
 * connector dials the new one. Without the firmware tables, the service in the configuration or its module, nothing is
 * started; a launch that fails is logged, and root.platform_end is left as it was.
 *
 * @param root The root task, which keeps its listener's end and remembers it.
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

/** A channel that's no channel, NO_HANDLE: what a Root field holds before, or without, what it's for. */
NO_CHANNEL : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

/**
 * Start the entropy service with the root task's own loader, with a listener whose other end the root task keeps, to
 * connect its clients through.
 *
 * Once it's started, that end replaces root.entropy, the old one closed, so its connector dials the new one. It's
 * given a ring for its log records once the root task has a connection to the events service.
 *
 * @param root The root task, which keeps its listener's end and remembers it.
 * @return Whether it started and its listener's end could be watched; false leaves root.entropy as it was.
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
 * Start the process manager with the root task's own loader, with a connector to the entropy service and a listener
 * whose other end is the root task's own connection to it.
 *
 * Once it's started, that end replaces root.manager, the old one closed, so launches and its connector use the new
 * one. It's given a ring for its log records once the root task has a connection to the events service.
 *
 * @param root The root task, which keeps its listener's end and remembers it.
 * @return Whether it started and its listener's end could be watched; false when there's no room for its entropy
 *     connector, no log copy, or it didn't start, leaving root.manager as it was.
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
 * Open a ring for the log records of a service the root task loads itself, and put its grants into grants.
 *
 * Nothing's opened before the supervisor has given the root task a connection to the events service. The root task
 * keeps a handle to the ring, in root.launched_ring, for the service's entry.
 *
 * @param root The root task, whose events connection is used.
 * @param name The service's name, which the events service labels its records with.
 * @param grants Where the ring's and the doorbell's grants go, both labeled "events"; two places are needed.
 * @return How many grants were put: 2, or 0 without a connection to the events service, when it didn't give a ring,
 *     or with fewer than two places.
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

/**
 * Open a ring for a service's log records through the events service, keeping the ring and giving a copy.
 *
 * The ring's handle replaces root.launched_ring, whose old one, not yet taken by an entry, is retired.
 *
 * @param root The root task, whose events connection is used.
 * @param name The service's name, which the events service labels its records with.
 * @return The ring's copy, readable, writable and transferable, and the doorbell, both for the service; null before
 *     the root task has a connection to the events service, when it didn't give a ring, or the ring couldn't be
 *     copied, what it gave then closed.
 */
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

/**
 * Give a ring back to the events service once its writer's ended, so it reads what's left, and wait for its answer.
 *
 * @param root The root task, whose events connection is used.
 * @param ring The ring, which moves: to the events service, or closed when there's no connection to it or it doesn't
 *     answer Done. NO_HANDLE is nothing to give.
 */
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
 * Make what a launch through the manager is given besides its grants: its CPU budget, the libraries, a ring for its
 * records.
 *
 * @param root The root task, which asks the scheduler service and the events service, and copies its substitutes.
 * @param name The service's name, which its CPU budget is asked for by, and its ring labeled with.
 * @return The options, whose handles move to the program with the launch: a CPU budget, or null to run on the
 *     root's; the substitutes' copies; and a ring, or null without the events service.
 */
launch_options :: fn(root: ptr[mut Root], name: string) -> os.LaunchOptions {
    options := os.LaunchOptions.{cpu_budget = budget_for(root, name), libraries = substitutes(root)}
    options.events = open_ring(root, name)
    return options
}

/**
 * Make a connector to one of the root task's services (decisions/0140), served by the connector thread.
 *
 * A client dials through it, and dials again when what it reached is started again. The connector thread is woken to
 * arm the new one.
 *
 * @param root The root task, which keeps the connector's other end.
 * @param service What each Dial on it reaches.
 * @return The client's end, to give away; null when the channel can't be made, MAX_CONNECTORS have been made, or it
 *     can't be bound to the connectors' port.
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
 * Answer every connector's Dials, waiting on the connectors' port between them, for as long as the root task runs.
 *
 * It runs on a thread of its own (decisions/0140), so a client dialing, as the process manager dials the entropy
 * service while the root task waits on it, is answered whatever the root task is waiting on. It finds the Root in its
 * context's extensions, and returns at once without one.
 *
 * @param data Unused; the Root comes from the context.
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
 * Answer every Dial on every connector, each with a new connection to what it reaches, or Unavailable while it isn't
 * running.
 *
 * A connector whose client's gone is unbound and closed, its place left empty. A request it doesn't know is answered
 * Unsupported.
 *
 * @param root The root task, whose connectors are read under connectors_lock.
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
                case _ => {
                    _ = slop_os.port_unbind(root.connector_port, CONNECTOR_KEY + cast[u64](i))
                    _ = slop_os.handle_close(cast[slop_os.Handle](record.end))
                    concurrency.lock(&root.connectors_lock)
                    if i < root.connectors.count {
                        root.connectors[i].end = NO_CHANNEL
                    }
                    concurrency.unlock(&root.connectors_lock)
                    break
                }
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

/**
 * Connect to one of the root task's services through its listener, under the service's lock.
 *
 * @param root The root task, whose listener's end of the service is used.
 * @param service Which service.
 * @return The new connection, the caller's to give or close; null while the service has ended and isn't started
 *     again, without its listener, or when it didn't take the connection.
 */
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

/**
 * Name one of the root task's services.
 *
 * @param service Which service.
 * @return Its name in the system configuration, which its entry in Root.started has too.
 */
name_of :: fn(service: RootService) -> string {
    return match service {
        case .Entropy => "entropy"
        case .ProcessManager => "process_manager"
        case .Scheduler => "scheduler"
        case .Platform => "platform"
    }
}

/**
 * Clean up after a service the root task started that ended, and start it again if it's one it serves connectors to.
 *
 * Its budget is closed, so what it had comes back, and its ring given back. One of the four services is started
 * again, as the supervisor starts its own again (decisions/0140), up to RESTARTS times in RESTART_WINDOW, and watched
 * under the same key; the supervisor isn't. Whether it's started again is logged.
 *
 * @param root The root task, whose entry for the service is updated.
 * @param key The service's index in root.started, its watch's key; one out of range is ignored.
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
 * Kill each of the root task's services in turn and check it's started again, for test_restart_root_services.
 *
 * Run once the supervisor has started everything. The process manager is killed after the entropy service and before
 * the two it launches, which are started again through it. Each has up to five seconds to be started again, then half
 * a second for its clients to dial it again, and has to answer a request through a new connection before the next is
 * killed.
 *
 * @param root The root task, which restarts each as it would in a working system.
 * @return Whether all four were started again and answered; false at the first that wasn't or didn't, which is logged.
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

/**
 * Wait on the root task's port until a packet comes or the deadline passes, and restart what ended.
 *
 * The supervisor's reports wake it too, but aren't read here.
 *
 * @param root The root task's state: its port is waited on, and an entry of started whose process ended is
 *     restarted, as restart does.
 * @param deadline When to stop waiting, in nanoseconds of the monotonic clock.
 */
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

/**
 * Tell whether a new connection to a service answers a request: entropy bytes, a budget, a claim's answer, a
 * connection.
 *
 * @param root The root task, whose budget pays for a port, closed after.
 * @param service Which service the connection is to, which says what's asked.
 * @param connection The connection, which stays the caller's.
 * @return Whether it answered; false when sending or receiving failed. Any answer counts, a refusal too, but for the
 *     scheduler's, which has to give a budget for hello.
 */
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

/**
 * Start the scheduler service through the manager, with the root CPU budget to split (decisions/0093), and remember
 * it, to watch.
 *
 * Every service the root task starts after it, and every one the supervisor does, runs on a budget it splits; without
 * it, they run on the root's, as before. It runs on the root's itself, so its budgets, and what runs on them, go to the
 * root's if it ends. Once it's started, its listener's end replaces root.scheduler, the old one closed; without the
 * service in the configuration or its module nothing is started, and a launch that fails is logged.
 *
 * @param root The root task, which keeps its listener's end and remembers it.
 * @param cpu_budget The root CPU budget, which stays the caller's; the service is given a copy.
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

/**
 * Ask the scheduler service for a service's CPU budget, under scheduler_lock.
 *
 * @param root The root task, whose listener's end of the scheduler is used.
 * @param name The service's name, which the scheduler looks its share up by.
 * @return A bind-only budget, the caller's to give with a launch; null to run it on the root's, without the scheduler
 *     or when it gave none.
 */
budget_for :: fn(root: ptr[mut Root], name: string) -> slop_os.CpuBudget? {
    concurrency.lock(&root.scheduler_lock)
    defer concurrency.unlock(&root.scheduler_lock)
    if cast[slop_os.Handle](root.scheduler) == slop_os.NO_HANDLE {
        return null
    }
    return scheduler_protocol.budget_for(root.scheduler, root.scheduler_port, name)
}

/**
 * Connect to the scheduler service, under scheduler_lock.
 *
 * @param root The root task, whose listener's end of the scheduler is used.
 * @return A connection, the caller's own; null without the scheduler, or when it didn't take the connection.
 */
connect_scheduler :: fn(root: ptr[mut Root]) -> os.Channel[scheduler_protocol.Scheduler]? {
    concurrency.lock(&root.scheduler_lock)
    defer concurrency.unlock(&root.scheduler_lock)
    if cast[slop_os.Handle](root.scheduler) == slop_os.NO_HANDLE {
        return null
    }
    return scheduler_protocol.connect(root.scheduler, root.scheduler_port, root.block.budget)
}

/**
 * Copy the boot-set module a service is started from, for whoever starts it.
 *
 * @param root The root task, whose system configuration names the module.
 * @param name The service's name in the system configuration.
 * @param rights The copy's rights, which the root task's handle has to have.
 * @return The copy, the caller's to give away; null when the configuration has no such service, the boot set no such
 *     module, or it can't be copied.
 */
module_copy :: fn(root: ptr[Root], name: string, rights: slop_os.Rights) -> slop_os.Memory? {
    service :: service_of(root, name) or_return null
    module :: find_module(root.block, service.module) or_return null
    match slop_os.handle_duplicate(module, rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

/**
 * Remember a service started, to watch it, in its entry if it has one already, as a restart has.
 *
 * The entry takes root.launched_budget and root.launched_ring, which are left NO_HANDLE. A new service past
 * MAX_STARTED isn't remembered, and isn't watched.
 *
 * @param root The root task's state: started gains or updates the entry, and launched_budget and launched_ring move
 *     to it.
 * @param name The service's name, kept for good, so a constant's or the configuration's.
 * @param process Its process, which moves to the entry.
 */
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

/** A service of the system configuration's, as the root task starts it. */
Service :: struct {
    /** Its name, a view of the root task's copy of the configuration, kept for good. */
    name : string,
    /** Its module's name in the boot set, without "module:", a view of the configuration too. */
    module : string,
    /** Its memory budget, in bytes, split off the starter's. */
    budget : u64,
}

/**
 * Find a service of the system configuration's.
 *
 * @param root The root task, whose system configuration is read.
 * @param name The service's name, compared exactly.
 * @return The service, its strings views of the configuration; null when it has none of that name.
 */
service_of :: fn(root: ptr[Root], name: string) -> Service? {
    record :: system_records.service_of(root.records, name) or_return null
    return Service.{name = system_records.text_of(&record.name), module = system_records.text_of(&record.module), budget = record.budget}
}

/**
 * Copy the system configuration's module read-only, to give a service.
 *
 * @param root The root task, which keeps its own handle.
 * @return The copy, readable and transferable, the caller's to give away; null if it can't be copied.
 */
records_copy :: fn(root: ptr[Root]) -> slop_os.Memory? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.records_module), rights) {
        case Ok(copy) => return cast[slop_os.Memory](copy)
        case Error(error) => return null
    }
}

/**
 * Copy the root task's debug log, to give a service.
 *
 * @param root The root task, which keeps its own handle.
 * @return The copy, writable, duplicable and transferable, the caller's to give away; null if it can't be copied.
 */
duplicate_log :: fn(root: ptr[mut Root]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

/**
 * Copy the root task's debug log for the supervisor, which may trace with it too (RIGHT_DEBUG_LOG_TRACE,
 * decisions/0183): the system's tracing is the supervisor's to give, as an administrator asks.
 *
 * @param root The root task, which keeps its own handle.
 * @return The copy, writable, tracing, duplicable and transferable, the caller's to give away; null if it can't be
 *     copied.
 */
tracing_log :: fn(root: ptr[mut Root]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DEBUG_LOG_TRACE)
        | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

/**
 * Kill a service the root task started, for test_outlive_manager.
 *
 * Its end comes to the root task's port as any service's would, so the four it serves connectors to are started
 * again.
 *
 * @param root The root task's state, whose started entries are searched; only read, the restarts coming later through
 *     its port.
 * @param name The service's name; every entry of that name is killed, and none is nothing.
 */
kill :: fn(root: ptr[mut Root], name: string) {
    for &started, i in root.started {
        if i < root.started_count && started.name == name {
            log_line.write(root.log, "root task: killing %", name)
            _ = slop_os.process_kill(started.process)
        }
    }
}

/**
 * Apply the generation's substitution policy, its boot-set file substitutions.records if it has one (decisions/0123,
 * 0125).
 *
 * Each entry whose from is one of the root task's libraries, by its file's hash, and whose to is another that passes
 * the check against it, gives its substitute from then on, up to bundle.MAX_SUBSTITUTIONS; each one refused is
 * logged, and a file that isn't a policy is logged and applies nothing. The root task itself keeps what it was bound
 * to.
 *
 * @param root The root task, whose substituted are added to.
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

/**
 * Copy each substitute's handle, for a launch to give in place of the root task's own libraries.
 *
 * @param root The root task, whose launch_libraries are made again, overwriting the last call's.
 * @return The copies, a view of root.launch_libraries, good until the next call; the handles move to the program with
 *     the launch. A substitute that can't be copied is left out, and the program gets the root task's own library.
 */
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

/**
 * Find a boot-set module among the root task's grants.
 *
 * @param block The startup block whose grants are searched.
 * @param module The module's name, looked up as the grant "module:<module>", a memory grant.
 * @return The grant's handle, the root task's own still; null when there's no such grant.
 */
find_module :: fn(block: ptr[slop_os.StartupBlock], module: string) -> slop_os.Handle? {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "module:")
    text_buffer.append(&label, module)
    return slop_os.find_grant(block, text_buffer.as_string(&label), .Memory)
}

