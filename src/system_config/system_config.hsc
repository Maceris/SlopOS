/**
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
import read_only_dir from "std/os/slop_os"
import system_records from "../system_records"
import clock_service from "../services/clock"
import acpi_service from "../services/acpi_service"
import power_button from "../drivers/power_button"
import i6300esb from "../drivers/i6300esb"
import events_service from "../services/events_service"
import bundle_store_service from "../services/bundle_store_service"
import config_service from "../services/config_service"
import update_service from "../services/update_service"
import terminal_service from "../services/terminal_service"
import echo from "../apps/echo"
import session_manager from "../services/session_manager"
import input_service from "../services/input_service"
import disk_check from "../services/disk_check"
import account_service from "../services/account_service"
import entropy from "../services/entropy"
import container_service from "../services/container_service"
import fat_server from "../services/fat_server"
import volume_server from "../services/volume_server"
import platform from "../services/platform"
import partition_server from "../services/partition_server"
import process_manager from "../services/process_manager"
import scheduler_service from "../services/scheduler"
import storage_manager from "../services/storage_manager"
import network_service from "../services/network_service"
import supervisor from "../services/supervisor"
import hello from "../apps/hello"
import edu_dma from "../drivers/edu_dma"
import virtio_blk from "../drivers/virtio_blk"
import virtio_console from "../drivers/virtio_console"
import virtio_gpu from "../drivers/virtio_gpu"
import compositor from "../services/compositor"
import virtio_input from "../drivers/virtio_input"
import virtio_net from "../drivers/virtio_net"
import virtio_rng from "../drivers/virtio_rng"
import config from "../protocols/config"
import connector from "../protocols/connector"
import links from "../protocols/links"
import platform_protocol from "../protocols/platform"
import supervision from "../protocols/supervision"
import session from "../protocols/session"
import power from "../protocols/power"
import powerbox from "../protocols/powerbox"
import test_channels from "../tests/test_channels"
import test_compositor from "../tests/test_compositor"
import test_display from "../tests/test_display"
import test_network from "../tests/test_network"
import ssh_service from "../services/ssh_service"
import test_control from "../tests/test_control"
import test_devices from "../tests/test_devices"
import test_memory from "../tests/test_memory"
import test_msi_dma from "../tests/test_msi_dma"
import test_ports from "../tests/test_ports"
import test_cpu_budgets from "../tests/test_cpu_budgets"
import test_io_ports from "../tests/test_io_ports"
import test_pager from "../tests/test_pager"
import test_exits from "../tests/test_exits"
import test_perf from "../tests/test_perf"
import test_budgets from "../tests/test_budgets"
import test_affinity from "../tests/test_affinity"
import test_libraries from "../tests/test_libraries"
import test_protocols from "../tests/test_protocols"
import test_syscalls from "../tests/test_syscalls"
import test_threads from "../tests/test_threads"

/** Who starts a service, and owns it: the root task, the supervisor, or the storage manager. */
Starter :: enum {
    /** The root task, which starts what the supervisor needs, itself or through the process manager. */
    RootTask,
    /** The supervisor, which starts the rest of the services and the drivers, and restarts them. */
    Supervisor,
    /** The storage manager, which starts a server for each disk, partition, container and volume as it needs one. */
    StorageManager,
}

/**
 * A CPU budget the scheduler service splits off the root's (decisions/0037, 0093): time nanoseconds every period
 * nanoseconds at priority, which a service runs at while it has time, and in the background band after.
 */
CpuShare :: struct {
    /** Its priority while it has time; higher runs first. */
    priority : u32,
    /** Its period, in nanoseconds, which its time is given again each of. */
    period_ns : u64,
    /** Its time each period, in nanoseconds, at most period_ns. */
    time_ns : u64,
    /**
     * The CPUs its threads run on, and its IRQs are routed to, a bit per CPU's index; 0 for every CPU
     * (decisions/0099).
     */
    cpus : u64,
}

/**
 * The services the system is healthy without, by name (decisions/0113, 0115): the test devices' drivers, and the disk
 * check, whose checks expect a disk as the image builder made it, not as a boot before left it; and remote login, which
 * runs only when it's enabled.
 *
 * An os.Channel[P] a service takes is required, and an optional one optional. What isn't late, and is started, has to
 * be up within its deadline, DEFAULT_DEADLINE_MS from boot unless it has its own, or the boot is degraded.
 */
LATE :: string.["edu_dma", "virtio_input", "disk_check", "ssh"]

/**
 * The system's installations (decisions/0113, 0117): each a name, which names its data directory and its
 * configuration's owner, and the program it runs, a bundle in the store's boot root whose entry the supervisor was
 * built with (counter_app's). At run time they're the config store's value "installations" of owner "system", these its
 * default.
 */
Installation :: struct {
    /** Its name, which names its data directory and its configuration's owner. */
    name : string,
    /** The program it runs, a bundle's name in the store's boot root. */
    program : string,
}

/** The default installations: counter, running counter. */
INSTALLATIONS :: Installation.[Installation.{name = "counter", program = "counter"}]
/** How long a service has to be up, from boot, in milliseconds, unless it has its own deadline: 120 s. */
DEFAULT_DEADLINE_MS : u32 : 120_000

/**
 * The budget every service without one of its own runs on, at a middling priority: four tenths of a CPU, so that what
 * has budgets of its own is never kept waiting by everything else, which runs on in the background band once this is
 * spent.
 */
DEFAULT_CPU :: CpuShare.{priority = 100, period_ns = 10_000_000, time_ns = 4_000_000}

/**
 * What the session manager splits a budget for each session off (decisions/0187): a tenth of a CPU, taken from the
 * default's, at a priority between the default's and the interactive services', so that people's programs aren't kept
 * waiting by services in the background, nor keep what talks to them waiting.
 */
SESSIONS_CPU :: CpuShare.{priority = 150, period_ns = 10_000_000, time_ns = 1_000_000}

/** What talks to people runs first: a tenth of a CPU each, at a high priority. */
INTERACTIVE_CPU :: CpuShare.{priority = 200, period_ns = 10_000_000, time_ns = 1_000_000}

/**
 * The trusted path, the input and terminal services (decisions/0097, 0139): above everything people run, so the secure
 * attention key always answers; a tenth of a CPU each of their own, which they lend to no server.
 */
TRUSTED_PATH_CPU :: CpuShare.{priority = 250, period_ns = 10_000_000, time_ns = 1_000_000}

/** A service the system starts: what it is, who starts it, what it's given, and how it's run. */
Service :: struct {
    /** Its name, as the supervisor reports it, at most a grant label's bytes. */
    name : string,
    /** The boot module, or the system volume's module, it's started from, like "entropy.elf". */
    module : string,
    /** Who starts it, and owns it. */
    starter : Starter,
    /**
     * Whether its starter asks the process manager to load it, rather than loading it itself as the root task
     * does the services the manager needs.
     */
    by_manager : bool,
    /** Its memory budget, split off its starter's, in bytes. */
    budget : u64,
    /** Its entry's type, whose parameters are what it's given, each the grant of its name. */
    entry : type,
    /**
     * A driver's: the devices it takes, one process each, which the supervisor claims from the platform service; all
     * zeros for a service that isn't a driver (is_driver).
     */
    devices : platform_protocol.DeviceMatch,
    /**
     * A driver's: whether it's trusted with DMA where no IOMMU confines its device, as SlopOS's own drivers are; one
     * that isn't gets no DMA memory there (decisions/0039, 0084).
     */
    trusted_with_dma : bool,
    /**
     * Whether it's in the boot set (decisions/0089): what reaches the system volume, loaded by the bootloader as
     * modules; everything else is loaded from the volume's modules folder, the modules standing in where there's none.
     */
    boot_set : bool,
    /** Its CPU budget, which the scheduler service splits off the root's; None for the default (DEFAULT_CPU). */
    cpu : CpuShare?,
    /**
     * Whether it splits its CPU budget for others, as the session manager does for each session (decisions/0187):
     * its starter is given the budget with the right to split it, as well as the copy it's put on. Only with a cpu.
     */
    cpu_splits : bool,
    /**
     * Whether its starter leaves it ended when it ends other than by exiting with 0, rather than starting it again, as
     * the supervisor does everything else it starts, up to three times a minute (decisions/0077, 0093).
     */
    not_restarted : bool,
    /** How long it has to be up, from boot, in milliseconds (decisions/0115); 0 for DEFAULT_DEADLINE_MS. */
    deadline_ms : u32,
    /**
     * The bytes of its records the events service keeps (decisions/0185, 12g), beyond or short of its default for the
     * system's services; 0 for that default.
     */
    events_budget : u64,
}

/**
 * Tell whether a service is a driver, with devices it takes.
 *
 * @param service The service, as SERVICES has it.
 * @return True if any of its devices' vendor, device and class isn't 0.
 */
is_driver :: fn(service: Service) -> bool {
    return service.devices.vendor != 0 || service.devices.device != 0 || service.devices.class != 0
}

/** The bytes of a MiB: 1048576. */
MIB : u64 : 1024 * 1024

/**
 * The services the system starts, in the order they start. The entropy service comes first, since the process manager
 * draws from it, and the supervisor's budget pays for what it starts too. The platform service starts before the
 * supervisor, which claims devices from it for the drivers, and starts them first: the input service needs keyboards,
 * the terminal service a serial line and the input service, and hello and echo the terminal service.
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
    Service.{name = "supervisor", boot_set = true, module = "supervisor.elf", starter = .RootTask, by_manager = true, budget = 320 * MIB,
        entry = type_of(supervisor.main)},
    // Every program's log records but the root task's and what it starts, first, so each is given a ring for them (decisions/0093)
    Service.{name = "events", boot_set = true, module = "events_service.elf", starter = .Supervisor, by_manager = true, budget = 8 * MIB,
        entry = type_of(events_service.main)},
    /*
     * The real-time clock's driver, next, so everything after it is given the clock page it keeps (decisions/0093).
     * Its stack, image, heap chunks and events ring come to about 1 MiB, before the page tables its space needs; and
     * for NTS (decisions/0188, 13g), TLS's state, some 300 KiB, the trust anchors, up to 256 KiB, and a trust store's
     * file read, as much again
     */
    Service.{name = "clock", boot_set = true, module = "clock.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(clock_service.main)},
    /*
     * The firmware's AML, where there's ACPI (decisions/0182, P3): its interpreter's namespace takes up to 4 MiB, an
     * evaluation 1 MiB, and the tables are copied in
     */
    Service.{name = "acpi", boot_set = true, module = "acpi_service.elf", starter = .Supervisor, by_manager = true, budget = 12 * MIB,
        entry = type_of(acpi_service.main)},
    // The power button where a GPIO controller's pin is wired to it, as on AArch64's virt (decisions/0182, P3)
    Service.{name = "power_button", boot_set = true, module = "power_button.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(power_button.main)},
    // The seat's keyboards, the console's terminal, and its reader until sessions (decisions/0136)
    Service.{name = "input", module = "input_service.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(input_service.main), cpu = TRUSTED_PATH_CPU},
    Service.{name = "terminal", module = "terminal_service.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(terminal_service.main), cpu = TRUSTED_PATH_CPU},
    /*
     * Each session, made once someone's logged in, its powerbox, its first program, echo, and its installations, their
     * budgets split off this one's (decisions/0150, 0153, 0156)
     */
    Service.{name = "sessions", module = "session_manager.elf", starter = .Supervisor, by_manager = true, budget = 48 * MIB,
        entry = type_of(session_manager.main), cpu = SESSIONS_CPU, cpu_splits = true},
    Service.{name = "echo", module = "echo.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(echo.main), cpu = INTERACTIVE_CPU},
    Service.{name = "hello", module = "hello.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        events_budget = 2 * MIB, entry = type_of(hello.main)},
    // The network stack (decisions/0188), over the first NIC; started only when there's one
    Service.{name = "network", module = "network_service.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(network_service.main)},
    // The compositor (decisions/0192, 15c), started with gui or test_compositor on the kernel's command line and a display:
    // its clients' windows, mapped, and the frame's canvas in its budget
    Service.{name = "compositor", module = "compositor.elf", starter = .Supervisor, by_manager = true, budget = 32 * MIB,
        entry = type_of(compositor.main), cpu = INTERACTIVE_CPU},
    // The compositor's test client (decisions/0192, 15c), started only with test_compositor on the kernel's command line
    Service.{name = "test_compositor", module = "test_compositor.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(test_compositor.main), not_restarted = true},
    // The display's test client (decisions/0192, 15b), started only with test_display on the kernel's command line
    Service.{name = "test_display", module = "test_display.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(test_display.main), not_restarted = true},
    // The network's test client (decisions/0188, 13c), started only with test_network on the kernel's command line;
    // room for TLS's state, some 300 KiB a connection, and trust anchors (13f)
    Service.{name = "test_network", module = "test_network.elf", starter = .Supervisor, by_manager = true, budget = 8 * MIB,
        entry = type_of(test_network.main), not_restarted = true},
    // Objects by their hashes, on the system volume, paged into whoever reads them (decisions/0094)
    Service.{name = "bundle_store", boot_set = true, module = "bundle_store_service.elf", starter = .Supervisor, by_manager = true,
        budget = 16 * MIB, entry = type_of(bundle_store_service.main)},
    // Programs' settings, on the system volume, each reached through a connection the supervisor gives (decisions/0109)
    Service.{name = "config", module = "config_service.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(config_service.main)},
    // What writes generations onto the ESP, told each boot's assessment by the supervisor (decisions/0116)
    Service.{name = "update", module = "update_service.elf", starter = .Supervisor, by_manager = true, budget = 8 * MIB,
        entry = type_of(update_service.main)},
    /*
     * Every disk's, and a partition server for each, which holds only its disk (decisions/0086); room for the volume
     * servers it starts, three sealed ones among them (decisions/0141)
     */
    Service.{name = "storage_manager", boot_set = true, module = "storage_manager.elf", starter = .Supervisor, by_manager = true, budget = 96 * MIB,
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
    /*
     * Every account, on its own volume, and each one's home volume (decisions/0141): Argon2id's 64 MiB for one password
     * at a time, on top; started only when there's a disk
     */
    Service.{name = "accounts", module = "account_service.elf", starter = .Supervisor, by_manager = true, budget = 72 * MIB,
        entry = type_of(account_service.main)},
    /*
     * Started only when there's a disk
     * Its checks write to the disks, once a boot
     */
    Service.{name = "disk_check", module = "disk_check.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(disk_check.main), not_restarted = true},
    // A modern virtio entropy device (virtio's device ID 4, as PCI device 0x1040 + 4)
    // The hardware watchdog, Intel's 6300ESB, as QEMU has it (decisions/0182, P5): the supervisor its one client
    Service.{name = "i6300esb", module = "i6300esb.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(i6300esb.main), devices = platform_protocol.DeviceMatch.{vendor = 0x8086, device = 0x25ab,
        class = platform_protocol.ANY_CLASS}},
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
    // A modern virtio GPU (virtio's device ID 16) in 2D mode; its two scanout buffers, up to 1920 by 1200, in its budget
    Service.{name = "virtio_gpu", module = "virtio_gpu.elf", starter = .Supervisor, by_manager = true, budget = 24 * MIB,
        entry = type_of(virtio_gpu.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1af4, device = 0x1050,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = true, cpu = INTERACTIVE_CPU},
    // A modern virtio network device (virtio's device ID 1); its queues, headers and the frames' buffer in its budget
    Service.{name = "virtio_net", module = "virtio_net.elf", starter = .Supervisor, by_manager = true, budget = 4 * MIB,
        entry = type_of(virtio_net.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1af4, device = 0x1041,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = true},
    // QEMU's edu device, for the test that a driver that DMAs outside its domain is stopped: not trusted
    Service.{name = "edu_dma", module = "edu_dma.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(edu_dma.main), devices = platform_protocol.DeviceMatch.{vendor = 0x1234, device = 0x11e8,
        class = platform_protocol.ANY_CLASS}, trusted_with_dma = false},
    /*
     * Remote login (decisions/0191, 14d), started whenever there's a network; it runs only when the system configuration
     * enables it, or ssh is on the kernel's command line. Each connection's state is some 900 KiB, made as it comes
     */
    Service.{name = "ssh", module = "ssh_service.elf", starter = .Supervisor, by_manager = true, budget = 12 * MIB,
        entry = type_of(ssh_service.main), not_restarted = true},
]

/**
 * The test programs (src/tests, decisions/0069), which the root task runs with test_program=<name>, launching
 * each as test_syscalls': so every one's entry has to be the same.
 */
TEST_ENTRIES :: type.[type_of(test_channels.main), type_of(test_control.main), type_of(test_devices.main), type_of(test_memory.main),
    type_of(test_msi_dma.main), type_of(test_ports.main), type_of(test_protocols.main), type_of(test_syscalls.main), type_of(test_threads.main),
    type_of(test_cpu_budgets.main), type_of(test_io_ports.main), type_of(test_pager.main), type_of(test_exits.main), type_of(test_perf.main), type_of(test_budgets.main),
    type_of(test_affinity.main), type_of(test_libraries.main)]

#assert same_test_entries()

/**
 * Tell whether every test program's entry is test_syscalls', as the root task launches them all as it.
 *
 * @return True if every one of TEST_ENTRIES is the same type.
 */
same_test_entries :: fn() -> bool {
    for entry in TEST_ENTRIES {
        if entry != type_of(test_syscalls.main) {
            return false
        }
    }
    return true
}

/** What the root task serves itself: the supervisor's reports. */
ROOT_TASK_SERVES :: type.[os.Listener[supervision.Supervision]]

/**
 * What the supervisor serves itself: connectors, which dial what it started (decisions/0077), and the session of the
 * console's programs, to the terminal service (decisions/0139); power, which the terminal service asks to shut down on
 * (decisions/0180); and the trust store, the system volume's directory of roots, read only (decisions/0188, 13f).
 */
SUPERVISOR_SERVES :: type.[os.Listener[connector.Connector], os.Listener[session.Session], os.Listener[power.Power],
    os.Listener[read_only_dir.ReadOnlyDir]]

/**
 * What the storage manager serves itself: each volume server's stored links, on a connection it makes for each
 * (roadmap 8f).
 */
STORAGE_MANAGER_SERVES :: type.[os.Listener[links.Links]]

/**
 * What the session manager serves, through the powerbox it starts in each session: its programs' connections to it
 * (decisions/0156).
 */
SESSION_MANAGER_SERVES :: type.[os.Listener[powerbox.Powerbox]]

/**
 * Find a service by its name.
 *
 * @param name The service's name, compared exactly.
 * @return A copy of its entry in SERVICES; null if there's none of that name.
 */
service :: fn(name: string) -> Service? {
    for each in SERVICES {
        if each.name == name {
            return each
        }
    }
    return null
}

/**
 * SERVICES as data (decisions/0110): what the build writes into the boot set as system.records, which the root task
 * checks at boot, and gives the supervisor and the scheduler service. Each entry's parameters are recorded with their
 * kinds and their protocols' tags, an os.Channel[P], an os.Listener[P] or a config.Config[T]; and what the root task,
 * the supervisor and the storage manager serve themselves.
 */
RECORDS :: #run make_records()

/**
 * Make SERVICES, INSTALLATIONS and what each starter serves itself into system records, at compile time.
 *
 * @return The records; their magic is 0, so they don't check, when there are more services, parameters, served
 *     protocols or installations than they hold, or a name doesn't fit. Installations past what they hold are dropped.
 */
make_records :: fn() -> system_records.SystemRecords {
    made := system_records.SystemRecords.{magic = system_records.MAGIC, default_deadline_ms = DEFAULT_DEADLINE_MS}
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
    for offered in SESSION_MANAGER_SERVES {
        serve(&made, os.end_tag(type_info_of(offered)), system_records.SERVED_BY_SESSION_MANAGER)
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
        record.late = if is_late(each.name) { 1 } else { 0 }
        record.deadline_ms = each.deadline_ms
        record.events_budget = each.events_budget
        record.budget = each.budget
        record.vendor = each.devices.vendor
        record.device = each.devices.device
        record.class = each.devices.class
        match each.cpu {
            case Some(share) => record.cpu = system_records.CpuRecord.{has = 1, priority = share.priority, period_ns = share.period_ns,
                time_ns = share.time_ns, cpus = share.cpus, splits = if each.cpu_splits { 1 } else { 0 }}
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
    for each, i in INSTALLATIONS {
        if i < made.installations.entries.count {
            entry :: &made.installations.entries[i]
            if !system_records.set_name(&entry.name, each.name) || !system_records.set_name(&entry.program, each.program) {
                made.magic = 0
            }
            made.installations.count += 1
        }
    }
    return made
}

/**
 * Tell whether a service is one the system is healthy without.
 *
 * @param name The service's name as it's declared, compared exactly with each LATE name.
 * @return True if LATE has it.
 */
is_late :: fn(name: string) -> bool {
    for each in LATE {
        if each == name {
            return true
        }
    }
    return false
}

/**
 * Record a protocol a starter serves itself.
 *
 * @param records The records being made; their magic is set to 0 when there's no room for another.
 * @param tag The protocol's channel end tag (os.end_tag), an os.Listener[P]'s.
 * @param by Who serves it, one of system_records' SERVED_BY_ values.
 */
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

/**
 * Check RECORDS with system_records.check, at compile time, as the root task checks them at boot: every
 * os.Channel[P] and config.Config[T] a service takes has a server, and the rest is well formed.
 *
 * Records that don't check fail the build, with an assertion naming the service and what's wrong.
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

/**
 * Give what an optional holds, for a parameter that may be left out.
 *
 * @param type The parameter's type's descriptor.
 * @return The type its Some holds, for a union with one; type itself otherwise.
 */
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

/**
 * Tell whether a type is a struct whose name starts with a prefix, like an instance of Channel.
 *
 * @param type The descriptor of any type, as held_type gives it for a parameter; one that isn't a struct, an alias
 *     included, is never named.
 * @param prefix What its name starts with, as "Channel[".
 * @return True for a struct whose name does.
 */
is_named :: fn(type: ptr[compiler.TypeInfo], prefix: string) -> bool {
    if type.variant != .STRUCT {
        return false
    }
    name :: cast[ptr[compiler.TypeInfoStruct]](type).name
    return os.starts_with(name, prefix)
}
