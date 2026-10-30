/*
 * The system's configuration (decisions/0044, 0058, 0067, 0068): the services it starts at boot, a
 * compile-time value, which the build writes into the boot set as data (RECORDS). Each service names its entry, whose
 * parameters are what it's given, each the grant of its name: so the wiring is checked when it's compiled
 * (check_records, below), every os.Channel[P] a service takes needing a service, or the root task, that serves P
 * with an os.Listener[P]. The build writes it into the boot set as data, RECORDS, which the root task checks with the
 * same code and gives the supervisor and the scheduler service (decisions/0110).
 */
package system_config

import compiler from "base"
import runtime from "base"
import text_buffer from "std"
import os from "std"
import system_records from "../system_records"
import clock_service from "../services/clock"
import events_service from "../services/events_service"
import bundle_store_service from "../services/bundle_store_service"
import config_service from "../services/config_service"
import console from "../services/console"
import disk_check from "../services/disk_check"
import entropy from "../services/entropy"
import container_service from "../services/container_service"
import fat_server from "../services/fat_server"
import volume_server from "../services/volume_server"
import platform from "../services/platform"
import partition_server from "../services/partition_server"
import process_manager from "../services/process_manager"
import scheduler_service from "../services/scheduler"
import storage_manager from "../services/storage_manager"
import supervisor from "../services/supervisor"
import hello from "../apps/hello"
import edu_dma from "../drivers/edu_dma"
import virtio_blk from "../drivers/virtio_blk"
import virtio_console from "../drivers/virtio_console"
import virtio_input from "../drivers/virtio_input"
import virtio_rng from "../drivers/virtio_rng"
import config from "../protocols/config"
import connector from "../protocols/connector"
import links from "../protocols/links"
import platform_protocol from "../protocols/platform"
import supervision from "../protocols/supervision"
import test_channels from "../tests/test_channels"
import test_control from "../tests/test_control"
import test_devices from "../tests/test_devices"
import test_memory from "../tests/test_memory"
import test_msi_dma from "../tests/test_msi_dma"
import test_ports from "../tests/test_ports"
import test_cpu_budgets from "../tests/test_cpu_budgets"
import test_io_ports from "../tests/test_io_ports"
import test_pager from "../tests/test_pager"
import test_exits from "../tests/test_exits"
import test_budgets from "../tests/test_budgets"
import test_affinity from "../tests/test_affinity"
import test_protocols from "../tests/test_protocols"
import test_syscalls from "../tests/test_syscalls"
import test_threads from "../tests/test_threads"

// Who starts a service, and owns it: the root task, the supervisor, or the storage manager.
Starter :: enum {
    RootTask,
    Supervisor,
    StorageManager,
}

/*
 * A CPU budget the scheduler service splits off the root's (decisions/0037, 0093): time nanoseconds every period
 * nanoseconds at priority, which a service runs at while it has time, and in the background band after.
 */
CpuShare :: struct {
    priority : u32,
    period_ns : u64,
    time_ns : u64,
    // The CPUs its threads run on, and its IRQs are routed to, a bit per CPU's index; 0 for every CPU (decisions/0099)
    cpus : u64,
}

/*
 * The budget every service without one of its own runs on, at a middling priority: half a CPU, so that what has budgets
 * of its own is never kept waiting by everything else, which runs on in the background band once this is spent.
 */
DEFAULT_CPU :: CpuShare.{priority = 100, period_ns = 10_000_000, time_ns = 5_000_000}

// What talks to people runs first: a tenth of a CPU each, at a high priority
INTERACTIVE_CPU :: CpuShare.{priority = 200, period_ns = 10_000_000, time_ns = 1_000_000}

Service :: struct {
    // Its name, as the supervisor reports it, and the boot module it's started from
    name : string,
    module : string,
    starter : Starter,
    // Whether its starter asks the process manager to load it, rather than loading it itself as the root task
    // does the services the manager needs
    by_manager : bool,
    // Its memory budget, split off its starter's, in bytes
    budget : u64,
    // Its entry's type, whose parameters are what it's given
    entry : type,
    // A driver's: the devices it takes, one process each, which the supervisor claims from the platform service; all
    // zeros for a service that isn't a driver (is_driver)
    devices : platform_protocol.DeviceMatch,
    // A driver's: whether it's trusted with DMA where no IOMMU confines its device, as SlopOS's own drivers are; one
    // that isn't gets no DMA memory there (decisions/0039, 0084)
    trusted_with_dma : bool,
    /*
     * Whether it's in the boot set (decisions/0089): what reaches the system volume, loaded from Limine's modules;
     * everything else is loaded from the volume's modules folder, Limine's modules standing in where there's none.
     */
    boot_set : bool,
    // Its CPU budget, which the scheduler service splits off the root's; None for the default (DEFAULT_CPU)
    cpu : CpuShare?,
    /*
     * Whether its starter leaves it ended when it ends other than by exiting with 0, rather than starting it again, as
     * the supervisor does everything else it starts, up to three times a minute (decisions/0077, 0093)
     */
    not_restarted : bool,
}

// Whether a service is a driver, with devices it takes.
is_driver :: fn(service: Service) -> bool {
    return service.devices.vendor != 0 || service.devices.device != 0 || service.devices.class != 0
}

MIB : u64 : 1024 * 1024

/*
 * In the order they start. The entropy service comes first, since the process manager draws from it, and the
 * supervisor's budget pays for what it starts too. The platform service starts before the supervisor, which claims
 * devices from it for the drivers, and starts them first: the console service needs a serial line, and hello the
 * console.
 */
SERVICES :: Service.[
    Service.{name = "entropy", boot_set = true, module = "entropy.elf", starter = .RootTask, by_manager = false, budget = 2 * MIB,
        entry = type_of(entropy.main)},
    Service.{name = "process_manager", boot_set = true, module = "process_manager.elf", starter = .RootTask, by_manager = false, budget = 8 * MIB,
        entry = type_of(process_manager.main)},
    // Before what the root task starts through the manager, which it puts on their budgets (decisions/0093)
    Service.{name = "scheduler", boot_set = true, module = "scheduler.elf", starter = .RootTask, by_manager = true, budget = 1 * MIB,
        entry = type_of(scheduler_service.main)},
    Service.{name = "platform", boot_set = true, module = "platform.elf", starter = .RootTask, by_manager = true, budget = 8 * MIB,
        entry = type_of(platform.main)},
    Service.{name = "supervisor", boot_set = true, module = "supervisor.elf", starter = .RootTask, by_manager = true, budget = 128 * MIB,
        entry = type_of(supervisor.main)},
    // Every program's log records but the root task's and what it starts, first, so each is given a ring for them (decisions/0093)
    Service.{name = "events", boot_set = true, module = "events_service.elf", starter = .Supervisor, by_manager = true, budget = 8 * MIB,
        entry = type_of(events_service.main)},
    // The real-time clock's driver, next, so everything after it is given the clock page it keeps (decisions/0093).
    // Its stack, image, heap chunks and events ring come to about 1 MiB, before the page tables its space needs
    Service.{name = "clock", boot_set = true, module = "clock.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(clock_service.main)},
    Service.{name = "console", module = "console.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(console.main), cpu = INTERACTIVE_CPU},
    Service.{name = "hello", module = "hello.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(hello.main)},
    // Objects by their hashes, on the system volume, paged into whoever reads them (decisions/0094)
    Service.{name = "bundle_store", boot_set = true, module = "bundle_store_service.elf", starter = .Supervisor, by_manager = true,
        budget = 16 * MIB, entry = type_of(bundle_store_service.main)},
    // Programs' settings, on the system volume, each reached through a connection the supervisor gives (decisions/0109)
    Service.{name = "config", module = "config_service.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(config_service.main)},
    // Every disk's, and a partition server for each, which holds only its disk (decisions/0086)
    Service.{name = "storage_manager", boot_set = true, module = "storage_manager.elf", starter = .Supervisor, by_manager = true, budget = 64 * MIB,
        entry = type_of(storage_manager.main)},
    Service.{name = "partition_server", boot_set = true, module = "partition_server.elf", starter = .StorageManager, by_manager = true, budget = 2 * MIB,
        entry = type_of(partition_server.main)},
    // For each FAT partition whose files are asked for, which holds only its partition (decisions/0087)
    Service.{name = "fat_server", boot_set = true, module = "fat_server.elf", starter = .StorageManager, by_manager = true, budget = 2 * MIB,
        entry = type_of(fat_server.main)},
    // For each SlopOS container, holding only its partition, and for its system volume (decisions/0089)
    Service.{name = "container_service", boot_set = true, module = "container_service.elf", starter = .StorageManager, by_manager = true,
        budget = 4 * MIB, entry = type_of(container_service.main)},
    Service.{name = "volume_server", boot_set = true, module = "volume_server.elf", starter = .StorageManager, by_manager = true, budget = 6 * MIB,
        entry = type_of(volume_server.main)},
    // Started only when there's a disk
    // Its checks write to the disks, once a boot
    Service.{name = "disk_check", module = "disk_check.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(disk_check.main), not_restarted = true},
    // A modern virtio entropy device (virtio's device ID 4, as PCI device 0x1040 + 4)
    Service.{name = "virtio_rng", module = "virtio_rng.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(virtio_rng.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1af4, device = 0x1044,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = true},
    // A modern virtio block device (virtio's device ID 2); its buffers are its clients' DMA memory, in its budget
    Service.{name = "virtio_blk", boot_set = true, module = "virtio_blk.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(virtio_blk.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1af4, device = 0x1042,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = true},
    // A modern virtio console (virtio's device ID 3)
    Service.{name = "virtio_console", module = "virtio_console.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(virtio_console.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1af4, device = 0x1043,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = true, cpu = INTERACTIVE_CPU},
    // A modern virtio input device (virtio's device ID 18), a keyboard, mouse or tablet
    Service.{name = "virtio_input", module = "virtio_input.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(virtio_input.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1af4, device = 0x1052,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = true, cpu = INTERACTIVE_CPU},
    // QEMU's edu device, for the test that a driver that DMAs outside its domain is stopped: not trusted
    Service.{name = "edu_dma", module = "edu_dma.elf", starter = .Supervisor, by_manager = true, budget = 1 * MIB,
        entry = type_of(edu_dma.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1234, device = 0x11e8,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = false},
]

/*
 * The test programs (src/tests, decisions/0069), which the root task runs with test_program=<name>, launching
 * each as test_syscalls': so every one's entry has to be the same.
 */
TEST_ENTRIES :: type.[type_of(test_channels.main), type_of(test_control.main), type_of(test_devices.main), type_of(test_memory.main),
    type_of(test_msi_dma.main), type_of(test_ports.main), type_of(test_protocols.main), type_of(test_syscalls.main), type_of(test_threads.main),
    type_of(test_cpu_budgets.main), type_of(test_io_ports.main), type_of(test_pager.main), type_of(test_exits.main), type_of(test_budgets.main),
    type_of(test_affinity.main)]

#assert same_test_entries()

same_test_entries :: fn() -> bool {
    for entry in TEST_ENTRIES {
        if entry != type_of(test_syscalls.main) {
            return false
        }
    }
    return true
}

// What the root task serves itself: the supervisor's reports.
ROOT_TASK_SERVES :: type.[os.Listener[supervision.Supervision]]

// What the supervisor serves itself: connectors, which dial what it started (decisions/0077).
SUPERVISOR_SERVES :: type.[os.Listener[connector.Connector]]

// What the storage manager serves itself: each volume server's stored links, on a connection it makes for each (roadmap 8f).
STORAGE_MANAGER_SERVES :: type.[os.Listener[links.Links]]

// The service named name.
service :: fn(name: string) -> Service? {
    for each in SERVICES {
        if each.name == name {
            return each
        }
    }
    return null
}

/*
 * SERVICES as data (decisions/0110): what the build writes into the boot set as system.records, which the root task
 * checks at boot, and gives the supervisor and the scheduler service. Each entry's parameters are recorded with their
 * kinds and their protocols' tags, an os.Channel[P], an os.Listener[P] or a config.Config[T]; and what the root task,
 * the supervisor and the storage manager serve themselves.
 */
RECORDS :: #run make_records()

make_records :: fn() -> system_records.SystemRecords {
    made := system_records.SystemRecords.{magic = system_records.MAGIC}
    made.default_cpu = system_records.CpuRecord.{has = 1, priority = DEFAULT_CPU.priority, period_ns = DEFAULT_CPU.period_ns,
        time_ns = DEFAULT_CPU.time_ns, cpus = DEFAULT_CPU.cpus}
    for offered in ROOT_TASK_SERVES {
        serve(&made, os.end_tag(type_info_of(offered)), system_records.SERVED_BY_ROOT_TASK)
    }
    for offered in SUPERVISOR_SERVES {
        serve(&made, os.end_tag(type_info_of(offered)), system_records.SERVED_BY_SUPERVISOR)
    }
    for offered in STORAGE_MANAGER_SERVES {
        serve(&made, os.end_tag(type_info_of(offered)), system_records.SERVED_BY_STORAGE_MANAGER)
    }
    for each, i in SERVICES {
        if i >= made.services.count {
            made.magic = 0
            break
        }
        record :: &made.services[i]
        fits := system_records.set_name(&record.name, each.name) && system_records.set_name(&record.module, each.module)
        record.starter = cast[u8](each.starter)
        record.by_manager = if each.by_manager { 1 } else { 0 }
        record.trusted_with_dma = if each.trusted_with_dma { 1 } else { 0 }
        record.boot_set = if each.boot_set { 1 } else { 0 }
        record.not_restarted = if each.not_restarted { 1 } else { 0 }
        record.budget = each.budget
        record.vendor = each.devices.vendor
        record.device = each.devices.device
        record.class = each.devices.class
        match each.cpu {
            case Some(share) => record.cpu = system_records.CpuRecord.{has = 1, priority = share.priority, period_ns = share.period_ns,
                time_ns = share.time_ns, cpus = share.cpus}
            case None => {}
        }
        record.first_parameter = made.parameter_count
        for input in cast[ptr[compiler.TypeInfoFunction]](type_info_of(each.entry)).input {
            at :: cast[usize](made.parameter_count)
            if at >= made.parameters.count {
                made.magic = 0
                break
            }
            parameter :: &made.parameters[at]
            fits = fits && system_records.set_name(&parameter.name, input.name)
            held :: held_type(input.type)
            parameter.optional = if held != input.type { 1 } else { 0 }
            if is_named(held, "Channel[") {
                parameter.kind = system_records.KIND_CHANNEL
                parameter.tag = os.end_tag(held)
            }
            else if is_named(held, "Listener[") {
                parameter.kind = system_records.KIND_LISTENER
                parameter.tag = os.end_tag(held)
            }
            else if is_named(held, "Config[") {
                // A Config[T] is a channel to the config store's values (decisions/0109)
                parameter.kind = system_records.KIND_CONFIG
                parameter.tag = os.end_tag(type_info_of(os.Channel[config.ConfigValue]))
            }
            made.parameter_count += 1
            record.parameter_count += 1
        }
        if !fits {
            made.magic = 0
        }
        made.service_count += 1
    }
    return made
}

serve :: fn(records: ptr[mut system_records.SystemRecords], tag: u64, by: u8) {
    at :: cast[usize](records.served_count)
    if at >= records.served.count || at >= records.served_by.count {
        records.magic = 0
        return void
    }
    records.served[at] = tag
    records.served_by[at] = by
    records.served_count += 1
}

/*
 * RECORDS checked with system_records.check, as the root task checks them at boot: every os.Channel[P] and
 * config.Config[T] a service takes has a server, and the rest is well formed. One that isn't fails the build, saying
 * which.
 */
check_records :: fn() {
    match system_records.check(&RECORDS) {
        case Some(problem) => {
            storage : u8[200]
            message := text_buffer.make(storage)
            name :: if cast[usize](problem.service) < SERVICES.count { SERVICES[cast[usize](problem.service)].name } else { "the configuration" }
            text_buffer.append_format(&message, "system_config: % %", name, problem.reason)
            runtime.assert(false, text_buffer.as_string(&message))
        }
        case None => {}
    }
}

#run check_records()

// What an optional holds, or the type itself.
held_type :: fn(type: ptr[compiler.TypeInfo]) -> ptr[compiler.TypeInfo] {
    if type.variant == .UNION {
        optional :: cast[ptr[compiler.TypeInfoUnion]](type)
        for variant in optional.variants {
            if variant.name == "Some" && variant.types.count == 1 {
                return variant.types[0]
            }
        }
    }
    return type
}

// Whether type is a struct whose name starts with prefix, like an instance of Channel.
is_named :: fn(type: ptr[compiler.TypeInfo], prefix: string) -> bool {
    if type.variant != .STRUCT {
        return false
    }
    name :: cast[ptr[compiler.TypeInfoStruct]](type).name
    return os.starts_with(name, prefix)
}
