/*
 * The system's configuration (decisions/0044, 0058, 0067, 0068): the services it starts at boot, a
 * compile-time value compiled into the root task and the supervisor. Each service names its entry, whose
 * parameters are what it's given, each the grant of its name: so the wiring is checked when it's compiled
 * (check_wiring, below), every os.Channel[P] a service takes needing a service, or the root task, that serves P
 * with an os.Listener[P].
 */
package system_config

import compiler from "base"
import runtime from "base"
import text_buffer from "std"
import os from "std"
import clock_service from "../services/clock"
import events_service from "../services/events_service"
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
    Service.{name = "supervisor", boot_set = true, module = "supervisor.elf", starter = .RootTask, by_manager = true, budget = 96 * MIB,
        entry = type_of(supervisor.main)},
    // Every program's log records but the root task's and what it starts, first, so each is given a ring for them (decisions/0093)
    Service.{name = "events", boot_set = true, module = "events_service.elf", starter = .Supervisor, by_manager = true, budget = 8 * MIB,
        entry = type_of(events_service.main)},
    // The real-time clock's driver, next, so everything after it is given the clock page it keeps (decisions/0093)
    Service.{name = "clock", boot_set = true, module = "clock.elf", starter = .Supervisor, by_manager = true, budget = 1 * MIB,
        entry = type_of(clock_service.main)},
    Service.{name = "console", module = "console.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(console.main), cpu = INTERACTIVE_CPU},
    Service.{name = "hello", module = "hello.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(hello.main)},
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
    type_of(test_cpu_budgets.main), type_of(test_io_ports.main), type_of(test_pager.main)]

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
 * Every os.Channel[P] a service takes, or an optional one, has a server: a service taking an os.Listener[P], the
 * root task, which serves ROOT_TASK_SERVES, the supervisor, which serves SUPERVISOR_SERVES, or the storage manager,
 * which serves STORAGE_MANAGER_SERVES. One without fails the build, saying which.
 */
check_wiring :: fn() {
    for each in SERVICES {
        for input in cast[ptr[compiler.TypeInfoFunction]](type_info_of(each.entry)).input {
            held :: held_type(input.type)
            if !is_named(held, "Channel[") {
                continue
            }
            served := false
            tag :: os.end_tag(held)
            for server in SERVICES {
                for offered in cast[ptr[compiler.TypeInfoFunction]](type_info_of(server.entry)).input {
                    served = served || (is_named(offered.type, "Listener[") && os.end_tag(offered.type) == tag)
                }
            }
            for offered in ROOT_TASK_SERVES {
                served = served || os.end_tag(type_info_of(offered)) == tag
            }
            for offered in SUPERVISOR_SERVES {
                served = served || os.end_tag(type_info_of(offered)) == tag
            }
            for offered in STORAGE_MANAGER_SERVES {
                served = served || os.end_tag(type_info_of(offered)) == tag
            }
            if !served {
                storage : u8[160]
                message := text_buffer.make(storage)
                text_buffer.append_format(&message, "system_config: %'s % has no service that serves it", each.name, input.name)
                runtime.assert(false, text_buffer.as_string(&message))
            }
        }
    }
}

#run check_wiring()

// What an optional holds, or the type itself.
held_type :: fn(type: ptr[compiler.TypeInfo]) -> ptr[compiler.TypeInfo] {
    if type.variant == .UNION {
        optional :: cast[ptr[compiler.TypeInfoUnion]](type)
        if optional.variants.count != 0 && optional.variants[0].types.count == 1 {
            return optional.variants[0].types[0]
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
