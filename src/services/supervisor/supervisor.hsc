/**
 * The supervisor (decisions/0017, 0058, 0067, 0068, 0074, 0075, 0076, 0077): it starts the services the system
 * configuration gives it through the process manager, with std/os's launch, each in a process of its own that it owns
 * and pays for from its budget, and tells the root task as each starts and ends, and once all have. Each runs on the
 * CPU budget the scheduler service gives it (decisions/0093), and is watched from its launch.
 *
 * A driver's service names the devices it takes: the supervisor claims each from the platform service and starts a
 * driver for it, with what it holds of it (platform.PciDevice). Drivers start first, since services need them. A
 * driver that serves clients is given a listener whose other end the supervisor keeps. Clients don't get connections
 * to a driver: they get connectors (the connector protocol), channels the supervisor serves, each of which dials the
 * listener of whatever serves it now. The input service is given connectors to the first four input devices, the
 * terminal service one to the first serial line and one to the input service, hello and echo one each to the terminal
 * service, and the disk check, if there's a disk, one to the first disk.
 *
 * Whatever it starts that ends other than by exiting with 0, killed or crashed, is started again, up to RESTARTS times
 * in RESTART_WINDOW, unless the system configuration says it's not_restarted (decisions/0093): a driver with its
 * device reissued by the platform service, made anew, and anything with a new listener; its clients' connections went
 * with it, and they dial again through their connectors. A restarted events service is given the system volume's
 * events directory again; a restarted storage manager starts its servers anew as it's asked for them, its encrypted
 * volumes locked again, as their volume servers went with it, and the supervisor asks it for the system volume again.
 * With test_restart_services on the kernel's command line, once everything has started it kills the events service,
 * the clock service, and the storage manager if there's one, one at a time, and checks each works once it's back. A
 * driver whose device's DMA an IOMMU blocks (SIGNAL_DMA_FAULT, on a handle to its Device the supervisor keeps) is
 * killed, and so started again in the same way (decisions/0084). With test_dma_fault on the kernel's command line, the
 * supervisor says it has started all only once edu_dma has ended for good. With test_restart on the kernel's command
 * line, the supervisor kills the first serial line's driver once everything has started and the terminal service has
 * dialed it and shown its banner, and says it has started all only once that driver is back, and dialed again.
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
 * directory, made if it isn't there; the supervisor keeps the other end of its listener. With test_store on the
 * kernel's command line, once everything has started, the supervisor puts hello's program in it and reads it back as
 * paged memory, is refused one whose bytes don't have the hash given, and sees an object kept while it's pinned and
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
import terminal from "std/os/slop_os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import log_line from "../../log_line"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
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
import config_protocol from "../../protocols/config"
import power_protocol from "../../protocols/power"
import trace from "../../protocols/trace"
import bundle from "../../bundle"
import schema from "std"
import service_kit from "../../libraries/service_kit"
import substitution from "../../substitution"
import system_records from "../../system_records"
import hello from "../../apps/hello"
import clock_service from "../clock"
import acpi_service from "../acpi_service"
import power_button from "../../drivers/power_button"
import events_service from "../events_service"
import bundle_store_service from "../bundle_store_service"
import config_service from "../config_service"
import update_service from "../update_service"
import update_protocol from "../../protocols/update"
import strings from "std"
import terminal_service from "../terminal_service"
import account_service from "../account_service"
import accounts from "../../protocols/accounts"
import input_service from "../input_service"
import seat from "../../protocols/seat"
import session from "../../protocols/session"
import lifecycle from "std/os/slop_os"
import session_manager from "../session_manager"
import disk_check from "../disk_check"
import storage_manager from "../storage_manager"
import edu_dma from "../../drivers/edu_dma"
import virtio_blk from "../../drivers/virtio_blk"
import virtio_console from "../../drivers/virtio_console"
import virtio_input from "../../drivers/virtio_input"
import virtio_rng from "../../drivers/virtio_rng"
import i6300esb from "../../drivers/i6300esb"
import watchdog from "../../protocols/watchdog"

/**
 * The most programs the supervisor keeps an entry for in Supervisor.started: drivers, services and the disk check. A
 * restart reuses its program's entry. A program launched past this many runs, and is reported to the root task, but
 * its end isn't handled, and it isn't started again.
 */
MAX_STARTED :: 24
/**
 * The most connectors the supervisor serves, over its whole life: a connector's place isn't reused once its other end
 * is gone, and connector_to makes none past this many.
 */
MAX_CONNECTORS :: 16
/**
 * The port key of the supervisor's end of connector i is this plus i, 0 to MAX_CONNECTORS - 1: bound for readable and
 * peer-closed. Below it, keys 0 to MAX_STARTED - 1 are what it started, each by its index in Supervisor.started.
 */
CONNECTOR_KEY : u64 : 1000
/**
 * The port key of a driver's Device, watched for SIGNAL_DMA_FAULT, is this plus the driver's index in
 * Supervisor.started.
 */
FAULT_KEY : u64 : 2000
/**
 * The port key a connection of the supervisor's own to the storage manager is bound under while a request on it waits,
 * so its answer, or its closing, wakes the supervisor's port; one such connection at a time.
 */
STORAGE_KEY : u64 : 3000
/**
 * The port key the system volume's root connection is watched under, for its other end closing, is this plus its
 * generation modulo SYSTEM_GENERATIONS, so a close of a connection already replaced is told apart from the current
 * one's.
 */
SYSTEM_KEY : u64 : 4000
/** How many generations of the system volume's connection get keys of their own before the keys are reused. */
SYSTEM_GENERATIONS : u64 : 1000
/** The port key of the timer that tries again to open a lost system volume. */
SYSTEM_RETRY_KEY : u64 : 5000
/** The port key of the supervisor's end of the terminal service's power connection (decisions/0180). */
POWER_KEY : u64 : 6000
/** The terminal service's power connection's slot, under POWER_KEY + it. */
CONSOLE_POWER : u32 : 0
/** The ACPI service's power connection's slot. */
ACPI_POWER : u32 : 1
/** The GPIO power button's driver's power connection's slot. */
GPIO_POWER : u32 : 2
/** How long after a failed try to open a lost system volume again the next is made, in nanoseconds: 100 ms. */
SYSTEM_RETRY : u64 : 100_000_000
/**
 * The port key the supervisor's connections to the root task's services are watched under, for their other ends
 * closing (decisions/0140), is this plus 0 for the process manager's, 1 for the platform service's, and 2 for the
 * scheduler service's, by RootService's order; such a close dials the connection again.
 */
ROOT_SERVICE_KEY : u64 : 7000
/** The port key of the timer that tries again to start what ended and didn't start again (retry_restarts). */
RESTART_RETRY_KEY : u64 : 8000
/** How long after a restart's launch failed the next try is made, in nanoseconds: 250 ms. */
RESTART_RETRY : u64 : 250_000_000
/**
 * How many times in a row a restart whose launch fails is tried again (retry_restarts), RESTART_RETRY apart: 10 s of
 * them, long enough for the storage a program is read from to come back, its disk's driver started again as well as
 * the bundle store. They aren't restarts, which count a program's ends: none ended.
 */
RESTART_RETRIES : u32 : 40
/**
 * The target of a connector the supervisor serves to the process manager, which it dials through the root task's
 * connector rather than a listener of its own; not an index in Supervisor.started.
 */
MANAGER_TARGET :: MAX_STARTED + 1
/**
 * How many times a program that ends other than with 0 is started again within RESTART_WINDOW; the next time it ends
 * in the window, it's done for good.
 */
RESTARTS : u32 : 3
/**
 * The longest a restart waits for the supervisor's memory budget to have room for the program's budget, in
 * nanoseconds: 2 s. Once it's passed, the launch is tried anyway.
 */
RESTART_BUDGET_WAIT : u64 : 2_000_000_000
/** The bytes of the supervisor's budget a restart leaves free beyond the program's budget, for the launch itself. */
RESTART_BUDGET_SPARE : u64 : 256 * 1024
/**
 * The window RESTARTS counts restarts in, in nanoseconds: 60 s, counted from the first restart in it; a program that
 * ends after it's passed starts a new window.
 */
RESTART_WINDOW : u64 : 60_000_000_000
/** No channel: a channel field that holds nothing, as NO_HANDLE does for any handle. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
/** No index in Supervisor.started: what isn't started, or a start that's new rather than a restart. */
NOWHERE : usize : 0xffffffffffffffff
/** The size of a page, in bytes; the clock page is one. */
PAGE : u64 : 4096
/** What test_clock sets the time to: 2030-01-02T03:04:05Z, in nanoseconds since 1970. */
TEST_CLOCK_TIME : i64 : 1_893_553_445_000_000_000
/**
 * How long test_restart waits, in nanoseconds (500 ms): once the console has dialed its serial line, for its banner
 * to be shown, before it kills the line's driver; and once it has dialed it again, before it says everything has
 * started.
 */
TEST_RESTART_PAUSE : u64 : 500_000_000

/** Which protocol a listener speaks, so a connector dials it with that protocol's Connect. */
Speaks :: enum {
    /** No listener: nothing dials it, and a Dial to it is answered Unavailable. */
    Nothing,
    /** A serial line's driver: the serial protocol. */
    Serial,
    /** A disk's driver: the block protocol. */
    Block,
    /** An input device's driver: the input protocol. */
    Input,
    /** The terminal service: the terminal protocol. */
    Terminal,
    /** The input service: the seat protocol. */
    Seat,
    /** The storage manager: the storage protocol. */
    Storage,
    /** The account service: the accounts protocol. */
    Accounts,
}

/**
 * What the clock service is given (clock.main): the real-time clock, its ports or its registers, and the clock page to
 * write. Every handle in it moves to the clock service at its launch.
 */
ClockGrants :: struct {
    /** The real-time clock's I/O ports, as the platform service claimed them; null where it's memory-mapped. */
    rtc_ports : slop_os.IoPortRange?,
    /** The real-time clock's registers, as the platform service claimed them; null where it has I/O ports. */
    rtc_registers : slop_os.Memory?,
    /** A handle to the clock page, readable and writable, which the clock service writes the time on. */
    clock_page : slop_os.Memory,
    /** The listener the supervisor sets the time through; the supervisor keeps its other end. */
    clients : os.Listener[clock_setting.ClockSetting],
}

/** What the ACPI service is given (acpi_service.main); its handles move to it at its launch. */
AcpiGrants :: struct {
    /** A connection to the platform service of its own, on which it claims ACPI. */
    platform_service : os.Channel[platform.Platform],
    /** The button's power connection, which it says the power button was pressed on; null if it couldn't be made. */
    power : os.Channel[power_protocol.Power]?,
}

/** What the GPIO power button's driver is given (power_button.main); its handles move to it at its launch. */
PowerButtonGrants :: struct {
    /** A connection to the platform service of its own, on which it claims the button. */
    platform_service : os.Channel[platform.Platform],
    /** Its power connection, which it says the button was pressed on; null if it couldn't be made. */
    power : os.Channel[power_protocol.Power]?,
}

/** What the events service is given (events_service.main); its handles move to the service at its launch. */
EventsGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** The listener for its clients; the supervisor keeps its other end, and asks for rings and connections on it. */
    clients : os.Listener[events.Events],
}

/** What the bundle store is given (bundle_store_service.main); its handles move to the store at its launch. */
StoreGrants :: struct {
    /** The system volume's "store" directory, lent the store's CPU budget if the scheduler service gave one. */
    store : os.Channel[dir.Dir],
    /** The listener for its clients; the supervisor keeps its other end. */
    clients : os.Listener[bundle_store.BundleStore],
    /** A copy of the kernel's command line, for its test's store_objects=N; null without one. */
    command_line : slop_os.Memory?,
}

/** What the config store is given (config_service.main); its handles move to the store at its launch. */
ConfigGrants :: struct {
    /** The system volume's "config" directory, lent the store's CPU budget if the scheduler service gave one. */
    store : os.Channel[dir.Dir],
    /** The listener for the admin connection, any owner's values; the supervisor keeps its other end. */
    admin : os.Listener[config_protocol.ConfigValue],
    /**
     * The listener for users' values (decisions/0152), whose other end the supervisor keeps for the session manager;
     * null if it couldn't be made.
     */
    users : os.Listener[config_protocol.ConfigValue]?,
}

/** What the update service is given (update_service.main); its handles move to the service at its launch. */
UpdateGrants :: struct {
    /** The root of the first EFI system partition the storage manager has. */
    esp : os.Channel[dir.Dir],
    /** The system volume's "updates" directory, lent the service's CPU budget if the scheduler service gave one. */
    updates : os.Channel[dir.Dir],
    /** A connection of its own to the bundle store. */
    store : os.Channel[bundle_store.BundleStore],
    /** The listener for its clients; the supervisor keeps its other end, and tells it how the boot went on it. */
    clients : os.Listener[update_protocol.Update],
}

/** What hello is given (hello.main); its handles move to hello at its launch. */
HelloGrants :: struct {
    /** A connection of its own to the process manager, or null if it couldn't be made. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** A connector to the terminal service, or null without one. */
    console : os.Channel[connector.Connector]?,
    /** A connection of its own to the entropy service, or null without one. */
    entropy_service : os.Channel[entropy.Entropy]?,
    /** A connection to its "settings" value in the config store, or null without a config store. */
    settings : config_protocol.Config[hello.HelloSettings]?,
}

/**
 * What echo was given (echo.main) when the supervisor started it. Nothing here uses it now: the session manager starts
 * echo in each session, with grants of its own.
 */
EchoGrants :: struct {
    /** A connector to the console echo reads and writes. */
    console : os.Channel[connector.Connector],
}

/** What the input service is given (input_service.main); its handles move to the service at its launch. */
InputGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the first input device's driver, in the order started; null without one. */
    keyboard0 : os.Channel[connector.Connector]?,
    /** A connector to the second input device's driver; null without one. */
    keyboard1 : os.Channel[connector.Connector]?,
    /** A connector to the third input device's driver; null without one. */
    keyboard2 : os.Channel[connector.Connector]?,
    /** A connector to the fourth input device's driver; null without one. */
    keyboard3 : os.Channel[connector.Connector]?,
    /** The listener for its client, the terminal service; the supervisor keeps its other end and dials it. */
    clients : os.Listener[seat.Seat],
    /** A read-only copy of the kernel's command line, for test_new_keyboards; null without one. */
    command_line : slop_os.Memory?,
}

/** What the terminal service is given (terminal_service.main); its handles move to the service at its launch. */
TerminalGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the first serial line's driver; null without one. */
    serial_line : os.Channel[connector.Connector]?,
    /** A connector to the input service; null without one. */
    input : os.Channel[connector.Connector]?,
    /** The first framebuffer's pixels, claimed anew for each start; null without a framebuffer. */
    framebuffer : slop_os.Memory?,
    /** The framebuffer's layout page, claimed with its pixels; null without a framebuffer. */
    framebuffer_layout : slop_os.Memory?,
    /** A connection to the session manager (decisions/0150); null if it isn't running. */
    programs : os.Channel[session.Session]?,
    /** A read-only copy of the boot before's panic record, to show; null if there's none. */
    last_panic : slop_os.Memory?,
    /** A connector to the account service, for first-boot setup (decisions/0148); null without one. */
    accounts_service : os.Channel[connector.Connector]?,
    /** A connection to the supervisor, to ask for the system to shut down (decisions/0180); null if none could be made. */
    power : os.Channel[power_protocol.Power]?,
    /** The listener for its clients; the supervisor keeps its other end, and dials it for connectors to it. */
    clients : os.Listener[terminal.Terminal],
}

/** What the account service is given (account_service.main); its handles move to the service at its launch. */
AccountGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the storage manager; null if it couldn't be made. */
    storage_service : os.Channel[connector.Connector]?,
    /** The listener for its clients; the supervisor keeps its other end, and dials it for connectors to it. */
    clients : os.Listener[accounts.Accounts],
}

/** What the session manager is given (session_manager.main); its handles move to it at its launch. */
SessionGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the process manager, which the supervisor dials through the root task's. */
    manager : os.Channel[connector.Connector],
    /** A copy of echo's program, readable and duplicable, which it starts in each session; null without one. */
    echo_module : slop_os.Memory?,
    /** A connection of its own to the events service, to open rings for what it starts; null without one. */
    events_service : os.Channel[events.Events]?,
    /** The config store's connection for users' values (decisions/0152); null without a config store. */
    settings : os.Channel[config_protocol.ConfigValue]?,
    /** A connection of its own to the bundle store; null without one. */
    store : os.Channel[bundle_store.BundleStore]?,
    /** The system volume's "apps" directory, made if it isn't there; null without a system volume. */
    apps : os.Channel[dir.Dir]?,
    /** A connection to the system's installations in the config store (0153); null without a config store. */
    installation_list : config_protocol.Config[system_records.Installations]?,
    /** A read-only copy of the kernel's command line; null without one. */
    command_line : slop_os.Memory?,
    /** The listener for its client, the terminal service; the supervisor keeps its other end. */
    clients : os.Listener[session.Session],
    /**
     * Its CPU budget with the right to split it, for each session's budget (decisions/0187); null without the
     * scheduler service, or one that doesn't give it.
     */
    cpu_budget : slop_os.CpuBudget?,
}

/** What the disk check is given (disk_check.main); its handles move to it at its launch. */
DiskCheckGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the storage manager; null if it couldn't be made. */
    storage : os.Channel[connector.Connector]?,
    /** The first EFI system partition's root, its working directory; null if there's none. */
    working_directory : os.Channel[dir.Dir]?,
    /** The SlopOS container's system volume's root; null if there's none. */
    system : os.Channel[dir.Dir]?,
}

/** A connector, or null where there's nothing to connect to: one of a service's optional grants. */
MaybeConnector :: os.Channel[connector.Connector]?

/**
 * What the storage manager is given (storage_manager.main): connectors to up to four disks, and the modules of the
 * servers it starts. Its handles move to it at its launch.
 */
StorageGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** A connector to the process manager, which the supervisor dials through the root task's. */
    manager : os.Channel[connector.Connector],
    /** A copy of the partition server's module, readable and duplicable. */
    partition_server_module : slop_os.Memory,
    /** A copy of the FAT server's module, readable and duplicable. */
    fat_server_module : slop_os.Memory,
    /** A copy of the container service's module, readable and duplicable. */
    container_service_module : slop_os.Memory,
    /** A copy of the volume server's module, readable and duplicable. */
    volume_server_module : slop_os.Memory,
    /** A connector to the first disk's driver, in the order started; null without one. */
    disk0 : os.Channel[connector.Connector]?,
    /** A connector to the second disk's driver; null without one. */
    disk1 : os.Channel[connector.Connector]?,
    /** A connector to the third disk's driver; null without one. */
    disk2 : os.Channel[connector.Connector]?,
    /** A connector to the fourth disk's driver; null without one. */
    disk3 : os.Channel[connector.Connector]?,
    /** The listener for its clients; the supervisor keeps its other end, and dials it for connectors to it. */
    clients : os.Listener[storage.Storage],
    /**
     * A copy of the kernel's command line, readable and duplicable, for its test words and the partition servers it
     * starts (decisions/0112); null without one.
     */
    command_line : slop_os.Memory?,
}

/**
 * What a virtio-rng driver is given (virtio_rng.main): its device, as the platform service claimed it, and a connection
 * to the entropy service. Its handles move to the driver at its launch.
 */
VirtioRngGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** The device. */
    device : slop_os.Device,
    /** The device's PCI configuration space. */
    config : slop_os.Memory,
    /** The device's BAR 0, or null if it has none. */
    bar0 : slop_os.Memory?,
    /** The device's BAR 1, or null if it has none. */
    bar1 : slop_os.Memory?,
    /** The device's BAR 2, or null if it has none. */
    bar2 : slop_os.Memory?,
    /** The device's BAR 3, or null if it has none. */
    bar3 : slop_os.Memory?,
    /** The device's BAR 4, or null if it has none. */
    bar4 : slop_os.Memory?,
    /** The device's BAR 5, or null if it has none. */
    bar5 : slop_os.Memory?,
    /** The DMA domain the device's DMA goes through. */
    domain : slop_os.DmaDomain,
    /** A connection of its own to the entropy service, to give what it reads to; null without one. */
    entropy_service : os.Channel[entropy.Entropy]?,
}

/**
 * What a driver that's given only its device is given (edu_dma.main), as the platform service claimed it. Its handles
 * move to the driver at its launch.
 */
DeviceGrants :: struct {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** The device. */
    device : slop_os.Device,
    /** The device's PCI configuration space. */
    config : slop_os.Memory,
    /** The device's BAR 0, or null if it has none. */
    bar0 : slop_os.Memory?,
    /** The device's BAR 1, or null if it has none. */
    bar1 : slop_os.Memory?,
    /** The device's BAR 2, or null if it has none. */
    bar2 : slop_os.Memory?,
    /** The device's BAR 3, or null if it has none. */
    bar3 : slop_os.Memory?,
    /** The device's BAR 4, or null if it has none. */
    bar4 : slop_os.Memory?,
    /** The device's BAR 5, or null if it has none. */
    bar5 : slop_os.Memory?,
    /** The DMA domain the device's DMA goes through. */
    domain : slop_os.DmaDomain,
}

/**
 * What a driver that serves clients is given (virtio_console.main, virtio_blk.main, virtio_input.main): its device, as
 * the platform service claimed it, and a listener for them. Its handles move to the driver at its launch.
 *
 * @tparam P The protocol the driver serves its clients.
 */
ServingGrants :: struct[P] {
    /** A copy of the supervisor's debug log, or null if it couldn't be copied. */
    log : slop_os.DebugLog?,
    /** The device. */
    device : slop_os.Device,
    /** The device's PCI configuration space. */
    config : slop_os.Memory,
    /** The device's BAR 0, or null if it has none. */
    bar0 : slop_os.Memory?,
    /** The device's BAR 1, or null if it has none. */
    bar1 : slop_os.Memory?,
    /** The device's BAR 2, or null if it has none. */
    bar2 : slop_os.Memory?,
    /** The device's BAR 3, or null if it has none. */
    bar3 : slop_os.Memory?,
    /** The device's BAR 4, or null if it has none. */
    bar4 : slop_os.Memory?,
    /** The device's BAR 5, or null if it has none. */
    bar5 : slop_os.Memory?,
    /** The DMA domain the device's DMA goes through. */
    domain : slop_os.DmaDomain,
    /** The listener for its clients; the supervisor keeps its other end, and dials it for connectors to it. */
    clients : os.Listener[P],
}

/**
 * The bootloader's modules of what the supervisor starts, as the root task granted them, each null if it wasn't
 * granted. The supervisor keeps them for its life; a program in the boot set, or one the system volume doesn't have,
 * is launched from its module here.
 */
Modules :: struct {
    /** The events service's module. */
    events : slop_os.Memory?,
    /** The bundle store's module. */
    bundle_store : slop_os.Memory?,
    /** The config store's module. */
    config : slop_os.Memory?,
    /** The update service's module. */
    update : slop_os.Memory?,
    /** The clock service's module. */
    clock : slop_os.Memory?,
    /** The ACPI service's module. */
    acpi : slop_os.Memory?,
    /** The GPIO power button's driver's module. */
    power_button : slop_os.Memory?,
    /** hello's module. */
    hello : slop_os.Memory?,
    /** The terminal service's module. */
    terminal : slop_os.Memory?,
    /** The session manager's module. */
    sessions : slop_os.Memory?,
    /** echo's module, a copy of which the session manager is given. */
    echo : slop_os.Memory?,
    /** The input service's module. */
    input : slop_os.Memory?,
    /** The disk check's module. */
    disk_check : slop_os.Memory?,
    /** The virtio block driver's module. */
    virtio_blk : slop_os.Memory?,
    /** The virtio console driver's module. */
    virtio_console : slop_os.Memory?,
    /** The virtio input driver's module. */
    virtio_input : slop_os.Memory?,
    /** The virtio entropy driver's module. */
    virtio_rng : slop_os.Memory?,
    /** The edu DMA test device's driver's module. */
    edu_dma : slop_os.Memory?,
    /** The storage manager's module. */
    storage_manager : slop_os.Memory?,
    /** The partition server's module, a copy of which the storage manager is given. */
    partition_server : slop_os.Memory?,
    /** The FAT server's module, a copy of which the storage manager is given. */
    fat_server : slop_os.Memory?,
    /** The container service's module, a copy of which the storage manager is given. */
    container_service : slop_os.Memory?,
    /** The volume server's module, a copy of which the storage manager is given. */
    volume_server : slop_os.Memory?,
}

/** Something it started: an entry of Supervisor.started, kept, and reused when it's started again. */
Started :: struct {
    /**
     * The name it was started under, which the system configuration knows it by; it outlives the entry, as a constant
     * or the system records' copy.
     */
    name : string,
    /** Its process, which the supervisor owns; its end is watched on the port under the entry's index. */
    process : slop_os.Process,
    /** Whether it's running: false from when it's killed or its end arrives until it's started again. */
    running : bool,
    /** The listener its clients are connected through, the supervisor's end; NONE without one. */
    listener : slop_os.Channel,
    /** The protocol its listener speaks, so a connector dials it with that protocol's Connect; Nothing without one. */
    speaks : Speaks,
    /** Whether it's a driver, started again with its device reissued; the clock service is one too. */
    driver : bool,
    /** A driver's service, by its index in the system configuration's services. */
    service : usize,
    /** A driver's device's PCI address, which the platform service reissues it by. */
    address : u32,
    /** How many times it's been started again since restarts_since, 0 to RESTARTS. */
    restarts : u32,
    /** When its RESTART_WINDOW began, in nanoseconds of the monotonic clock. */
    restarts_since : u64,
    /**
     * A driver's: a handle to its Device, with no rights, which the port watches for its DMA faults under FAULT_KEY
     * plus the entry's index; NO_HANDLE without one.
     */
    watch : slop_os.Handle,
    /** Whether it's the clock service, a driver whose device is the real-time clock, started again with start_clock. */
    clock : bool,
    /** Whether it's the ACPI service, started again with start_acpi, with a platform connection of its own. */
    acpi : bool,
    /** The lifecycle end it was last pinged on for the watchdog (watchdog.hsc); NONE before, or once answered. */
    pinged : slop_os.Channel,
    /** Whether it's the GPIO power button's driver, started again with start_power_button. */
    power_button : bool,
    /**
     * Its program's memory budget, the supervisor's handle, closed once it's ended so what it had comes back;
     * NO_HANDLE once closed.
     */
    budget : slop_os.MemoryBudget,
    /**
     * Its ring for its log records, which the supervisor owns, given back to the events service once it's ended;
     * NO_HANDLE without one.
     */
    ring : slop_os.Memory,
    /** Whether it's ended and isn't to be started again. */
    done : bool,
    /**
     * Its faults' intercept and address space (crashes.hsc), the supervisor's, closed once it's ended; null without
     * them.
     */
    faults : os.LaunchedFaults?,
    /** Where its image is in its address space, for its crash reports. */
    image : u64,
    /** The code it last ended with, 0 while it hasn't. */
    code : u64,
    /** The supervisor's end of its lifecycle channel (decisions/0139), closed once it's ended; NONE without one. */
    lifecycle : slop_os.Channel,
    /** Whether it's one of the console's programs, which the trusted path lists and may end; hello is one. */
    console : bool,
    /**
     * Whether it was ended on request, as the trusted path may end a console program, and so isn't started again once
     * it ends; cleared when it's started again. Nothing in the supervisor sets it yet.
     */
    ended_on_request : bool,
    /**
     * Whether it was being started again and its launch failed, so it's tried again once RESTART_RETRY_KEY's timer
     * fires (retry_restarts); cleared as it's tried.
     */
    retry : bool,
    /** How many times in a row its restart's launch has been tried again, up to RESTART_RETRIES; 0 once it starts. */
    retries : u32,
}

/** The most services a boot's assessment notes missing, besides those that ended for good; more aren't noted. */
MAX_MISSING :: 16

/** A service the system needs that isn't up (decisions/0115): which, why, and the code that says more, or 0. */
Missing :: struct {
    /** The service's name, as the system records keep it. */
    name : string,
    /** Why it isn't up, in words, as "didn't start" or "ended for good"; a constant. */
    reason : string,
    /** The code that says more: the code it ended with, or a launch error plus one; 0 for none. */
    code : u64,
}

/** A connector the supervisor serves: its end, what it dials, by index in started, and how many times it has. */
Connector :: struct {
    /** The supervisor's end, bound to its port under CONNECTOR_KEY plus its index; NONE once its client's gone. */
    end : slop_os.Channel,
    /** What it dials: an index in Supervisor.started, or MANAGER_TARGET for the process manager. */
    target : usize,
    /** How many Dials it has answered with a connection. */
    dials : u32,
}

/**
 * The supervisor's state: its connections, what it started, the connectors it serves, and what the boot has found.
 *
 * Handles in it are the supervisor's own, closed when they're replaced; a channel field is NONE, and another handle
 * NO_HANDLE, while it holds nothing. A port field is made for the channel field it's named after, alone.
 */
Supervisor :: struct {
    /** The startup block, for the supervisor's budget, address space and grants; valid for the process's life. */
    block : ptr[slop_os.StartupBlock],
    /** The kernel debug log it writes to, or NO_HANDLE without one; copies of it are given to what it starts. */
    log : slop_os.DebugLog,
    /** Its connection to the process manager, which launches what it starts, dialed through manager_connector. */
    manager : os.Channel[process_manager.ProcessManager],
    /** The port manager's answers wake. */
    manager_port : slop_os.Port,
    /** Its end of the supervision channel to the root task, which it reports what it starts and ends on. */
    root : slop_os.Channel,
    /** The port root's sends wait on. */
    root_port : slop_os.Port,
    /** Its connection to the platform service, which devices, the clock and the framebuffer are claimed from. */
    platform_end : slop_os.Channel,
    /** The port platform_end's answers wake. */
    platform_port : slop_os.Port,
    /** The root task's connector to the process manager (decisions/0140), through which manager is dialed again. */
    manager_connector : slop_os.Channel,
    /** The root task's connector to the platform service, through which platform_end is dialed; NONE without one. */
    platform_connector : slop_os.Channel,
    /** The root task's connector to the scheduler service, through which scheduler_end is dialed; NONE without one. */
    scheduler_connector : slop_os.Channel,
    /** The root task's connector to the entropy service, dialed for each program given a connection to it. */
    entropy_connector : slop_os.Channel,
    /** Its connection to the scheduler service, which gives each program its CPU budget; NONE without one. */
    scheduler_end : slop_os.Channel,
    /** The port scheduler_end's answers wake. */
    scheduler_port : slop_os.Port,
    /** The clock page, one page the clock service writes the time on; NO_HANDLE if it couldn't be made. */
    clock_page : slop_os.Memory,
    /** Its end of the clock service's listener, which sets the time; NONE without a clock service. */
    clock_setting : slop_os.Channel,
    /** The port clock_setting's answers wake. */
    clock_setting_port : slop_os.Port,
    /**
     * The memory budget of the program launched last, from kept until its entry takes it (take_budget); NO_HANDLE
     * between.
     */
    launched_budget : slop_os.MemoryBudget,
    /** The log ring of the program launched last, from options_for until its entry takes it; NO_HANDLE between. */
    launched_ring : slop_os.Memory,
    /** Whether test_trace is on, so the trace is drained as each service starts (tracing.hsc). */
    tracing : bool,
    /** When each thread first ran, as the trace showed it, for test_trace's boot timeline. */
    first_runs : FirstRun[..],
    /** Its end of the trace connection an administrator was allowed (system_trace.hsc); NONE without one. */
    trace_end : slop_os.Channel,
    /** When the trace under way ends, in nanoseconds of the monotonic clock; 0 with none under way. */
    trace_until : u64,
    /** Each thread's counts in the trace under way. */
    trace_counts : ThreadCount[..],
    /** How many events the trace under way has had. */
    trace_events : u64,
    /** The faults' intercept of the program launched last, from kept until its entry takes it; null between. */
    launched_faults : os.LaunchedFaults?,
    /** Where the image of the program launched last is, from kept until its entry takes it. */
    launched_image : u64,
    /** The lifecycle channel's end of the program launched last, until its entry takes it; NONE between. */
    launched_lifecycle : slop_os.Channel,
    /** The boot before's panic record, read-only, for the terminal service to show; null if there's none. */
    last_panic : slop_os.Memory?,
    /** Its end of the events service's listener; NONE without an events service. */
    events_end : slop_os.Channel,
    /** The port events_end's answers wake. */
    events_port : slop_os.Port,
    /** The storage manager's index in started; NOWHERE without one. */
    storage_slot : usize,
    /**
     * How many times the system volume has been opened; its connection is watched under SYSTEM_KEY plus this modulo
     * SYSTEM_GENERATIONS.
     */
    system_generation : u64,
    /** Whether the system volume's connection closed, and it's to be opened again. */
    system_lost : bool,
    /**
     * Its end of the terminal service's power connection (decisions/0180), bound under POWER_KEY, replaced each time the
     * terminal service starts; null before it has, or once the terminal service's end is gone.
     */
    power : slop_os.Channel?,
    /**
     * Its ends of the power connections of what brings the power button (decisions/0182): the ACPI service's, bound
     * under POWER_KEY + ACPI_POWER, and the GPIO button's driver's, under POWER_KEY + GPIO_POWER; NONE before one's
     * started, or once it's gone. Each is replaced when what it's for starts again.
     */
    buttons : slop_os.Channel[2],
    /** Whether a shutdown's been asked for, so it's done once. */
    shutting_down : bool,
    /** Whether the system volume is being opened, which handles what arrives on the port meanwhile. */
    system_opening : bool,
    /** The kernel's command line, to give on to services that read their test words; null without one. */
    command_line : slop_os.Memory?,
    /** Its end of the bundle store's listener; NONE without a bundle store. */
    store_end : slop_os.Channel,
    /** The port store_end's answers wake. */
    store_port : slop_os.Port,
    /** Its end of the config store's admin listener, for any owner's values; NONE without a config store. */
    config_end : slop_os.Channel,
    /** Its connection to the system's installations in the config store; NONE until it's made. */
    installations_end : slop_os.Channel,
    /** The port installations_end's answers wake. */
    installations_port : slop_os.Port,
    /** Its end of the update service's listener; NONE without an update service. */
    update_end : slop_os.Channel,
    /** Whether it booted as the recovery generation (decisions/0118): the boot set, drivers and console only. */
    recovery : bool,
    /** The port update_end's answers wake. */
    update_port : slop_os.Port,
    /** The generation booted, as the command line's generation= says (decisions/0114); 0 for none. */
    generation : u64,
    /**
     * The store root the generation booted with, as the command line's store_root= says (decisions/0116); null for the
     * store's own.
     */
    boot_root : bundle.Hash?,
    /**
     * test_ignore_stop=NAME: the service a shutdown doesn't ask to stop, as if it ignored the asking, so it's killed
     * and named (decisions/0182, P4); empty for none.
     */
    ignore_stop : string,
    /** The hardware watchdog's listener, from its driver's start, for arming it (watchdog.hsc); NONE without one. */
    watchdog_listener : slop_os.Channel,
    /** The connection to the hardware watchdog's driver, once armed; NONE before. */
    watchdog_end : slop_os.Channel,
    /** A port bound to watchdog_end alone. */
    watchdog_port : slop_os.Port,
    /** The seconds the watchdog's armed for: watchdog= on the command line, or 60 for development, 30 otherwise. */
    watchdog_seconds : u32,
    /** When the watchdog's next reset, in the monotonic clock's nanoseconds. */
    next_pet : u64,
    /** Whether the supervisor's in its steady loop, after its start, where the watchdog's armed and reset. */
    steady : bool,
    /** test_watchdog_hang: the watchdog isn't reset once armed, so it resets the machine. */
    watchdog_hang : bool,
    /** The port config_end's answers wake. */
    config_port : slop_os.Port,
    /** The index in started a restart is launching into, whose key its process is watched under; NOWHERE otherwise. */
    relaunching : usize,
    /** The bootloader's modules of what it starts. */
    modules : Modules,
    /** What it started, by index, its port watching each one's end under its index; started_count are in use. */
    started : Started[MAX_STARTED],
    /** How many of started are in use, from the first: 0 to MAX_STARTED. */
    started_count : usize,
    /** The connectors it serves; connector_count are in use. */
    connectors : Connector[MAX_CONNECTORS],
    /** How many of connectors are in use, from the first: 0 to MAX_CONNECTORS. */
    connector_count : usize,
    /** The port it waits on: what it started ending, connectors' Dials, DMA faults, and its connections' closes. */
    port : slop_os.Port,
    /** The first serial line's driver, by index in started; NOWHERE without one. */
    first_serial : usize,
    /** The first disk's driver, by index in started; NOWHERE without one. */
    first_disk : usize,
    /** The first input device's driver, by index in started; NOWHERE without one. */
    first_keyboard : usize,
    /** The terminal service, by index in started; NOWHERE until it's started. */
    terminal : usize,
    /** The input service, by index in started; NOWHERE until it's started. */
    input : usize,
    /**
     * The account service, by index in started, for the terminal service's first-boot setup (decisions/0148); NOWHERE
     * until it's started.
     */
    accounts : usize,
    /** The session manager, by index in started; NOWHERE until it's started. */
    sessions : usize,
    /**
     * Its end of the config store's listener for users' values, kept for the session manager, which it's given to;
     * NONE once given, or without one.
     */
    config_users : slop_os.Channel,
    /**
     * The system volume's root, once the storage manager has given it, where programs outside the boot set come from;
     * NONE until then.
     */
    system : slop_os.Channel,
    /** The port system's answers wake. */
    system_port : slop_os.Port,
    /**
     * Programs read from the bundle store or the system volume, by their services' places in the system
     * configuration.
     */
    loaded : Loaded[MAX_LOADED],
    /**
     * The system configuration: the boot set's, which the root task gives it, with the config store's override once
     * it's read (decisions/0110). Allocated for the process's life.
     */
    records : ptr[mut system_records.SystemRecords],
    /** The boot set's, as the root task gave it, which an override is applied to; allocated for the process's life. */
    boot_records : ptr[system_records.SystemRecords],
    /**
     * What a boot's assessment finds missing besides what ended for good: what didn't start, was skipped, or was
     * late; missing_count are in use.
     */
    missing : Missing[MAX_MISSING],
    /** How many of missing are in use, from the first: 0 to MAX_MISSING. */
    missing_count : usize,
    /** When it started, in nanoseconds of the monotonic clock, from which each service's deadline counts. */
    started_at : u64,
    /** Its connection to the system configuration's override in the config store; NONE until it's made. */
    overrides_end : slop_os.Channel,
    /** The port overrides_end's answers wake. */
    overrides_port : slop_os.Port,
    /** Its connection to the substitution policy in the config store (decisions/0122); NONE until it's made. */
    substitutions_end : slop_os.Channel,
    /** The port substitutions_end's answers wake. */
    substitutions_port : slop_os.Port,
}

/**
 * A service of the system configuration's, as the supervisor starts it: its record's fields, read out. Its strings
 * view the system records, which last for the process's life.
 */
Service :: struct {
    /** Its name, which the supervisor knows it by. */
    name : string,
    /** Its program's module's name, as the system volume's modules folder and the bundle store know it. */
    module : string,
    /** Who starts it: system_records.STARTER_SUPERVISOR for what the supervisor starts. */
    starter : u8,
    /** Its memory budget, in bytes, split off from the supervisor's at its launch. */
    budget : u64,
    /** The devices a driver takes, by vendor, device and class; all 0 for a service that isn't a driver. */
    devices : platform.DeviceMatch,
    /** Whether a driver's device is trusted with DMA, as the platform service is asked to claim it. */
    trusted_with_dma : bool,
    /** Whether it's in the boot set, run from its bootloader module rather than the system volume. */
    boot_set : bool,
    /** Whether it isn't started again when it ends (decisions/0093). */
    not_restarted : bool,
}

/**
 * Read the system configuration's service at an index.
 *
 * @param supervisor The supervisor, whose current records, the boot set's or the override's, are read.
 * @param index The service's place in the system configuration, from 0.
 * @return The service, or null if index is past the configuration's services.
 */
service_at :: fn(supervisor: ptr[Supervisor], index: usize) -> Service? {
    records :: supervisor.records
    if index >= cast[usize](records.service_count) || index >= records.services.count {
        return null
    }
    record :: &records.services[index]
    return Service.{name = system_records.text_of(&record.name), module = system_records.text_of(&record.module), starter = record.starter,
        budget = record.budget, devices = platform.DeviceMatch.{vendor = record.vendor, device = record.device, class = record.class},
        trusted_with_dma = record.trusted_with_dma == 1, boot_set = record.boot_set == 1, not_restarted = record.not_restarted == 1}
}

/**
 * Find the system configuration's service of a name.
 *
 * @param supervisor The supervisor, whose current records are read.
 * @param name The service's name, as in the system configuration.
 * @return The service, or null if there's none of that name.
 */
service_named :: fn(supervisor: ptr[Supervisor], name: string) -> Service? {
    return service_at(supervisor, system_records.index_of(supervisor.records, name))
}

/**
 * Tell whether a service is a driver, with devices it takes.
 *
 * @param service The service, as service_at reads it.
 * @return True if its device match names a vendor, a device or a class; false if all three are 0.
 */
is_driver :: fn(service: Service) -> bool {
    return service.devices.vendor != 0 || service.devices.device != 0 || service.devices.class != 0
}

/** A program read from the bundle store or the system volume, if it's been read. */
Loaded :: struct {
    /**
     * The program, the supervisor's handle, kept to launch it from again; null until it's read, and again once a live
     * update has replaced it.
     */
    module : slop_os.Memory?,
    /**
     * Whether module came from the bundle store, as its paged memory, which ends with the store: so it's read again
     * once the store is started again (forget_stored).
     */
    from_store : bool,
}

/** The most services whose programs the supervisor keeps read, by their places in the system configuration. */
MAX_LOADED :: 32

/**
 * Start and supervise the system's services: the supervisor, which the root task starts.
 *
 * It starts the events service, the clock service, the boot set's drivers and the storage manager, then every other
 * driver and the services that use them, each with what it needs, and starts again whatever ends badly. Words on the
 * kernel's command line turn on its tests (test_restart, test_dma_fault, test_clock, test_events,
 * test_restart_services, test_store, test_system_config, test_degraded, test_substitution, test_lending,
 * test_unassessed, test_accounts, test_crash, test_trace), skip the disk check (no_disk_check), boot the recovery generation (recovery), and
 * say the generation booted (generation=, store_root=). Once everything has started it assesses the boot, tells the
 * update service and the root task, and then serves its connectors for good.
 *
 * Each module grant is a program it starts: without one, that program isn't started, or, outside the boot set, comes
 * from the system volume only.
 *
 * @param log The kernel debug log, which it writes to and gives copies of to what it starts; without one, nothing is
 *     logged.
 * @param manager The root task's connector to the process manager, through which every program is launched; it's
 *     dialed again whenever the process manager is started again.
 * @param root The supervision channel to the root task, which is told each program that starts, ends or fails, the
 *     boot's assessment, and once everything has started.
 * @param hello_module hello's program.
 * @param platform_service The root task's connector to the platform service, which devices, the real-time clock and
 *     the framebuffer are claimed from; without one, no driver, clock service or framebuffer.
 * @param entropy_service The root task's connector to the entropy service, dialed for hello and entropy drivers;
 *     without one, they get no connection to it.
 * @param terminal_module The terminal service's program.
 * @param echo_module echo's program, which the session manager starts in each session.
 * @param sessions_module The session manager's program.
 * @param input_module The input service's program.
 * @param disk_check_module The disk check's program.
 * @param virtio_blk_module The virtio block driver's program.
 * @param virtio_console_module The virtio console driver's program.
 * @param virtio_input_module The virtio input driver's program.
 * @param virtio_rng_module The virtio entropy driver's program.
 * @param edu_dma_module The edu DMA test device's driver's program.
 * @param storage_manager_module The storage manager's program; without it, or any of the four server modules below,
 *     there's no storage manager, and so no system volume.
 * @param partition_server_module The partition server's program, given on to the storage manager.
 * @param fat_server_module The FAT server's program, given on to the storage manager.
 * @param container_service_module The container service's program, given on to the storage manager.
 * @param volume_server_module The volume server's program, given on to the storage manager.
 * @param command_line The kernel's command line, read for the words above and given on to services that read their
 *     own; without one, no tests run and the generation is taken as 0.
 * @param scheduler The root task's connector to the scheduler service, which gives each program its CPU budget;
 *     without one, programs run on no budget of their own, and nothing is lent.
 * @param clock_module The clock service's program.
 * @param events_module The events service's program.
 * @param bundle_store_module The bundle store's program.
 * @param config_module The config store's program.
 * @param system The system configuration, as the root task checked it; it's checked again.
 * @param update_module The update service's program.
 * @param last_panic The boot before's panic record, given on to the terminal service to show; null if there's none.
 * @param acpi_module The ACPI service's program.
 * @param power_button_module The GPIO power button's driver's program.
 * @return Only if it can't start: 10 if the system configuration doesn't check, 99 if it can't be copied, 2 if no port
 *     can be made for root, 3 if the supervisor's port can't be made, and 1 if the process manager can't be dialed.
 *     Otherwise it never returns.
 */
main :: fn(log: slop_os.DebugLog?, manager: os.Channel[connector.Connector], root: os.Channel[supervision.Supervision],
    hello_module: slop_os.Memory?, platform_service: os.Channel[connector.Connector]?, entropy_service: os.Channel[connector.Connector]?,
    terminal_module: slop_os.Memory?, echo_module: slop_os.Memory?, sessions_module: slop_os.Memory?, input_module: slop_os.Memory?, disk_check_module: slop_os.Memory?, virtio_blk_module: slop_os.Memory?,
    virtio_console_module: slop_os.Memory?, virtio_input_module: slop_os.Memory?, virtio_rng_module: slop_os.Memory?,
    edu_dma_module: slop_os.Memory?, storage_manager_module: slop_os.Memory?, partition_server_module: slop_os.Memory?,
    fat_server_module: slop_os.Memory?, container_service_module: slop_os.Memory?, volume_server_module: slop_os.Memory?,
    command_line: slop_os.Memory?, scheduler: os.Channel[connector.Connector]?, clock_module: slop_os.Memory?,
    events_module: slop_os.Memory?, bundle_store_module: slop_os.Memory?, config_module: slop_os.Memory?, system: slop_os.Memory,
    update_module: slop_os.Memory?, last_panic: slop_os.Memory?, acpi_module: slop_os.Memory?, power_button_module: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    // The system configuration, which the root task checked, checked again
    records :: match service_kit.read_records(startup, system) {
        case Ok(read) => read
        case Error(problem) => {
            log_line.write(log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), "supervisor: the system configuration %", problem.reason)
            return 10
        }
    }
    boot_records, boot_error :: runtime.new_aligned(system_records.SystemRecords, align_of(system_records.SystemRecords))
    if boot_error != null {
        return 99
    }
    boot_records^ = records^
    supervisor := Supervisor.{block = startup, records = records, boot_records = boot_records, overrides_end = NONE, substitutions_end = NONE, manager_connector = manager.end, root = root.end, platform_end = NONE,
        platform_connector = NONE, scheduler_connector = NONE, entropy_connector = NONE,
        first_serial = NOWHERE, first_disk = NOWHERE, first_keyboard = NOWHERE, terminal = NOWHERE, input = NOWHERE, accounts = NOWHERE, sessions = NOWHERE, config_users = NONE, system = NONE, scheduler_end = NONE, clock_page = cast[slop_os.Memory](slop_os.NO_HANDLE), clock_setting = NONE,
        events_end = NONE, store_end = NONE, config_end = NONE, installations_end = NONE, update_end = NONE, relaunching = NOWHERE, storage_slot = NOWHERE, launched_ring = cast[slop_os.Memory](slop_os.NO_HANDLE), launched_budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE),
        launched_lifecycle = NONE, last_panic = last_panic, trace_end = NONE}
    supervisor.modules = Modules.{events = events_module, bundle_store = bundle_store_module, config = config_module, update = update_module, clock = clock_module, acpi = acpi_module, power_button = power_button_module, hello = hello_module, terminal = terminal_module, echo = echo_module, sessions = sessions_module, input = input_module, disk_check = disk_check_module, virtio_blk = virtio_blk_module,
        virtio_console = virtio_console_module, virtio_input = virtio_input_module, virtio_rng = virtio_rng_module, edu_dma = edu_dma_module,
        storage_manager = storage_manager_module, partition_server = partition_server_module, fat_server = fat_server_module,
        container_service = container_service_module, volume_server = volume_server_module}
    supervisor.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    supervisor.root_port = os.port_for(startup.budget, root.end) or_return 2
    supervisor.port = slop_os.port_create(startup.budget) or_return 3
    match entropy_service {
        case Some(found) => supervisor.entropy_connector = found.end
        case None => {}
    }
    match scheduler {
        case Some(found) => supervisor.scheduler_connector = found.end
        case None => {}
    }
    match platform_service {
        case Some(found) => supervisor.platform_connector = found.end
        case None => {}
    }
    // Its connections to the root task's services, dialed through their connectors
    if !dial_root_service(&supervisor, 0) {
        return 1
    }
    _ = dial_root_service(&supervisor, 1)
    _ = dial_root_service(&supervisor, 2)

    test_restart := false
    test_dma_fault := false
    test_clock := false
    test_events := false
    test_restart_services := false
    test_chaos := cast[u64](0)
    test_chaos_seed := cast[u64](0)
    test_store := false
    test_system_config := false
    test_degraded := false
    test_crash := false
    test_trace := false
    test_substitution := false
    test_lending := false
    // A boot that never tells the update service how it went, as one that hangs or resets before it's assessed would
    test_unassessed := false
    test_accounts := false
    // For tests that don't need the disk check, which the boot's assessment otherwise waits for
    no_disk_check := false
    supervisor.started_at = slop_os.clock_monotonic() or_else 0
    supervisor.command_line = command_line
    match command_line {
        case Some(memory) => {
            text :: service_kit.text_of(startup, memory) or_else ""
            test_restart = service_kit.has_word(text, "test_restart")
            test_dma_fault = service_kit.has_word(text, "test_dma_fault")
            test_clock = service_kit.has_word(text, "test_clock")
            test_events = service_kit.has_word(text, "test_events")
            test_restart_services = service_kit.has_word(text, "test_restart_services")
            // test_chaos=N: N services and drivers killed at random once everything's started (chaos.hsc)
            test_chaos = service_kit.number_of(service_kit.word_after(text, "test_chaos=") or_else "") or_else 0
            test_chaos_seed = service_kit.number_of(service_kit.word_after(text, "test_chaos_seed=") or_else "") or_else 0
            test_store = service_kit.has_word(text, "test_store")
            test_system_config = service_kit.has_word(text, "test_system_config")
            test_degraded = service_kit.has_word(text, "test_degraded")
            test_crash = service_kit.has_word(text, "test_crash")
            test_trace = service_kit.has_word(text, "test_trace")
            if test_trace {
                // The trace on, if the kernel's trace_boot hasn't already, and drained as each service starts
                supervisor.tracing = slop_os.trace_set(supervisor.log, true) is_ok
            }
            test_substitution = service_kit.has_word(text, "test_substitution")
            test_lending = service_kit.has_word(text, "test_lending")
            test_unassessed = service_kit.has_word(text, "test_unassessed")
            test_accounts = service_kit.has_word(text, "test_accounts")
            no_disk_check = service_kit.has_word(text, "no_disk_check")
            supervisor.recovery = service_kit.has_word(text, "recovery")
            // The generation booted, and its store root, as the bootloader says on the command line (decisions/0114, 0116)
            supervisor.generation = service_kit.number_of(service_kit.word_after(text, "generation=") or_else "") or_else 0
            supervisor.boot_root = bundle.from_hex(service_kit.word_after(text, "store_root=") or_else "")
            supervisor.ignore_stop = service_kit.word_after(text, "test_ignore_stop=") or_else ""
            // The watchdog's timeout (decisions/0182, P5): watchdog=N, or longer for development, where a debugger pauses
            supervisor.watchdog_seconds = cast[u32](service_kit.number_of(service_kit.word_after(text, "watchdog=") or_else "")
                or_else (if service_kit.has_word(text, "development") { cast[u64](60) } else { cast[u64](30) }))
            supervisor.watchdog_hang = service_kit.has_word(text, "test_watchdog_hang")
        }
        case None => {}
    }

    // The boot set's drivers, for every device each takes, and the storage manager, which reaches the system volume
    // The events service first, so everything after it has a ring for its records; then the clock, so everything after
    // it reads the time from its page
    start_events(&supervisor, NOWHERE)
    supervisor.clock_page = slop_os.memory_create(startup.budget, PAGE) or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    start_clock(&supervisor, NOWHERE)
    start_acpi(&supervisor, NOWHERE)
    start_power_button(&supervisor, NOWHERE)
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
        // The smallest budget for the clock service's records, which check_events makes it pass, so its oldest are dropped
        if !events.set_budget(supervisor.events_end, supervisor.events_port, "clock", events.MIN_BUDGET) {
            log_line.write(supervisor.log, "supervisor: test_events: the clock service's budget wasn't set")
        }
    }
    // Then every other driver, and the services that use them, each with connectors to what it uses
    start_drivers(&supervisor, false)
    // The account service before the terminal service, which sets up the first account if there's none (decisions/0148)
    if !supervisor.recovery {
        start_accounts(&supervisor, storage_slot, NOWHERE)
    }
    start_input(&supervisor, NOWHERE)
    // The session manager before the terminal service, which asks it to make sessions (decisions/0150)
    start_sessions(&supervisor, NOWHERE)
    start_terminal(&supervisor, NOWHERE)
    // The recovery generation starts nothing more than the boot set, the drivers and the console
    if supervisor.recovery {
        log_line.write(supervisor.log, "supervisor: recovery: the boot set, the drivers and the console only")
    }
    else {
        start_hello(&supervisor, NOWHERE)
        if !no_disk_check {
            start_disk_check(&supervisor, storage_slot)
        }
    }
    serial_line :: supervisor.first_serial
    if test_restart && serial_line < supervisor.started.count {
        // Once the terminal service has its connection, which the driver's end takes with it
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
        // Back once it's been started again, and the terminal service has dialed it again
        loop {
            wait_and_handle(&supervisor)
        }
        while !is_running(&supervisor, serial_line) || dials_of(&supervisor, serial_line) < 2
        // And has had time to show its banner again, and echo what's typed after it, before the root task's last second
        pause(&supervisor, TEST_RESTART_PAUSE)
    }
    // The disk check is done once it's checked, which it reports before everything has started, or by its deadline
    disk_check_by :: deadline_of(&supervisor, "disk_check")
    loop {
        if no_disk_check {
            break
        }
        wait_and_handle_until(&supervisor, disk_check_by)
    }
    while !ended_for_good(&supervisor, "disk_check") && (slop_os.clock_monotonic() or_else 0) < disk_check_by
    if !no_disk_check && !ended_for_good(&supervisor, "disk_check") {
        note_missing(&supervisor, "disk_check", "not done by its deadline", 0)
    }
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
    if test_accounts {
        check_accounts(&supervisor)
    }
    if test_system_config {
        check_system_config(&supervisor)
    }
    if test_substitution {
        check_substitution(&supervisor)
    }
    if test_lending {
        check_lending(&supervisor)
    }
    if test_restart_services {
        restart_services(&supervisor, storage_slot)
    }
    if test_degraded {
        // hello, killed until it isn't started again, which leaves the boot degraded
        loop {
            if !kill_and_wait(&supervisor, "hello", "test_degraded") {
                break
            }
        }
    }
    log_line.write(supervisor.log, "supervisor: started % services", supervisor.started_count)
    // A benchmark (decisions/0112): the time since the kernel's clock started, a boot's to everything started
    log_line.write(supervisor.log, "supervisor: perf: boot_to_healthy %", slop_os.clock_monotonic() or_else 0)
    // Assessed first, which the root task hears before it's told everything has started
    healthy :: assess(&supervisor)
    if test_unassessed {
        log_line.write(supervisor.log, "supervisor: test_unassessed: the update service isn't told how the boot went")
    }
    else {
        match tell_update(&supervisor, healthy) {
            case Live(live) => apply_live(&supervisor, live)
            case _ => {}
        }
    }
    // The substitution policy the config store asks for, staged as the next generation if it's new (decisions/0125)
    if healthy {
        _ = ask_substitute(&supervisor, read_substitutions(&supervisor))
    }
    tell_root(&supervisor, .AllStarted(cast[u32](supervisor.started_count)))
    // The boot's timeline and a traced exchange, once everything has started (tracing.hsc)
    if test_trace {
        check_trace(&supervisor)
    }
    // A crash once everything has started, of a service that runs for good (crashes.hsc)
    if test_crash {
        _ = crash_and_wait(&supervisor, "update")
    }
    // Chaos once everything has started, so sessions run and programs work meanwhile (chaos.hsc)
    if test_chaos > 0 {
        run_chaos(&supervisor, test_chaos, test_chaos_seed)
    }
    // The watchdog armed now, the start done, and reset from here while the services answer (watchdog.hsc)
    supervisor.steady = true
    arm_watchdog(&supervisor)
    loop {
        wait_and_handle_until(&supervisor, trace_deadline(&supervisor, if supervisor.watchdog_end != NONE { supervisor.next_pet } else { slop_os.NO_DEADLINE }))
        serve_trace(&supervisor)
        tend_watchdog(&supervisor)
    }
}

/**
 * Wait for what arrives on the supervisor's port, with no deadline, and handle it, as wait_and_handle_until does.
 *
 * @param supervisor The supervisor, whose port is waited on for as long as it takes; its entries, connectors and
 *     connections change as wait_and_handle_until's do.
 */
wait_and_handle :: fn(supervisor: ptr[mut Supervisor]) {
    wait_and_handle_until(supervisor, slop_os.NO_DEADLINE)
}

/**
 * Wait for what arrives on the supervisor's port, up to 8 packets, and handle it.
 *
 * Handled are something it started ending, which is started again as it may be; the system volume's connection
 * closing, so it's opened again; one of the root task's services' connections closing, so it's dialed again; a
 * driver's DMA fault, which kills it; and every connector's Dials. Every connector is read until it's empty, as each is
 * once it's made, since only a read that finds nothing has a channel's next message wake the port. A lost system
 * volume is opened again here, or a timer of SYSTEM_RETRY set to try again; and restarts whose launch failed are
 * tried again once their timer fires (retry_restarts).
 *
 * @param supervisor The supervisor, whose port is waited on; what arrives may let go of, start again or kill its
 *     entries, dial its connections to the root task's services again, open its system volume again, and answer its
 *     connectors' Dials.
 * @param deadline The latest to wait until, in nanoseconds of the monotonic clock, or slop_os.NO_DEADLINE; once it
 *     passes, the connectors are still read.
 */
wait_and_handle_until :: fn(supervisor: ptr[mut Supervisor], deadline: u64) {
    packets : slop_os.Packet[8]
    taken :: slop_os.port_wait(supervisor.port, packets, deadline) or_else 0
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
        // One of the root task's services was started again: its connection dialed again
        if packet.kind == .Signal && packet.key >= ROOT_SERVICE_KEY && packet.key < ROOT_SERVICE_KEY + 3 {
            _ = dial_root_service(supervisor, cast[usize](packet.key - ROOT_SERVICE_KEY))
        }
        if packet.kind == .Stop && packet.key >= CRASH_KEY && packet.key < CRASH_KEY + cast[u64](MAX_STARTED) {
            crashed(supervisor, cast[usize](packet.key - CRASH_KEY))
        }
        faulted :: cast[usize](packet.key - FAULT_KEY)
        if packet.kind == .Signal && packet.key >= FAULT_KEY && faulted < supervisor.started_count && faulted < supervisor.started.count {
            dma_fault(supervisor, faulted, packet.data[1])
        }
        if packet.key == RESTART_RETRY_KEY {
            retry_restarts(supervisor)
        }
    }
    serve_power(supervisor)
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

/**
 * Handle the end of something it started: let go of what it held, tell the root task, and start it again if it may be.
 *
 * Its budget is closed, its log ring given back to the events service, its lifecycle channel, listener and DMA watch
 * closed. It's done for good if it ended with 0, is not_restarted, was ended on request, or has ended RESTARTS times
 * already in RESTART_WINDOW; otherwise, once the supervisor's budget has room for it (wait_for_budget), it's started
 * again into the same entry: a driver with its device reissued by the platform service, the clock service and other
 * services as they were started. Its clients' connectors dial the new one.
 *
 * @param supervisor The supervisor, whose entry at index is let go of and may be launched into again, relaunching
 *     being index meanwhile; its port isn't handled while it waits for budget.
 * @param index Its index in started; out of range does nothing.
 * @param code The code it ended with, from its process's end: 0 for success, otherwise its exit code or the kernel's
 *     for a crash or a kill.
 */
ended :: fn(supervisor: ptr[mut Supervisor], index: usize, code: u64) {
    if index >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[index]
    entry.running = false
    entry.code = code
    log_line.write(supervisor.log, "supervisor: % ended", entry.name)
    if cast[slop_os.Handle](entry.budget) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](entry.budget))
        entry.budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    }
    retire_ring(supervisor, entry.ring)
    entry.ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    forget_faults(entry)
    if entry.lifecycle != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](entry.lifecycle))
        entry.lifecycle = NONE
    }
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
    match service_named(supervisor, entry.name) {
        case Some(service) => {
            not_restarted = service.not_restarted
            budget = service.budget
        }
        case None => {}
    }
    if code == 0 || not_restarted || entry.ended_on_request {
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
    start_again(supervisor, index, budget)
}

/**
 * Start an entry that ended again, as it was started, once the supervisor's budget has room for it (wait_for_budget):
 * a driver with its device reissued by the platform service, the clock service and other services as they were
 * started. One that isn't running after is tried again later (retry_later): its launch failed, or what it's started
 * with couldn't be had yet, as the bundle store's directory while the system volume is opened again.
 *
 * @param supervisor The supervisor, whose entry at index is launched into, relaunching being index meanwhile, or
 *     marked to be tried again; its port isn't handled while it waits for budget.
 * @param index Its index in started; out of range does nothing.
 * @param budget The program's budget, in bytes, as the system configuration has it; 0 waits for none.
 */
start_again :: fn(supervisor: ptr[mut Supervisor], index: usize, budget: u64) {
    if index >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[index]
    wait_for_budget(supervisor, budget)
    // The last process's binding still has the key, though it fired: the next is watched under it from its launch
    _ = slop_os.port_unbind(supervisor.port, cast[u64](index))
    if !entry.driver || entry.clock || entry.acpi || entry.power_button {
        supervisor.relaunching = index
        if entry.clock {
            start_clock(supervisor, index)
        }
        else if entry.acpi {
            start_acpi(supervisor, index)
        }
        else if entry.power_button {
            start_power_button(supervisor, index)
        }
        else {
            restart_service(supervisor, index)
        }
        supervisor.relaunching = NOWHERE
    }
    else {
        match request_device(supervisor, .Reissue(entry.address)) {
            case Some(device) => {
                supervisor.relaunching = index
                start_driver(supervisor, entry.service, device, index)
                supervisor.relaunching = NOWHERE
            }
            case None => {}
        }
    }
    if entry.running {
        entry.retries = 0
        log_line.write(supervisor.log, "supervisor: restarted %", entry.name)
        return void
    }
    // Not launched, and failed hasn't said why: what it needed wasn't there
    if entry.retry || entry.done {
        return void
    }
    if retry_later(supervisor, index) {
        log_line.write(supervisor.log, "supervisor: % couldn't be started again yet; trying again", entry.name)
        return void
    }
    log_line.write(supervisor.log, "supervisor: % couldn't be started again, and isn't tried again", entry.name)
    entry.done = true
    note_missing(supervisor, entry.name, "didn't start", 0)
    tell_root(supervisor, .Failed(report_of(entry.name, 0)))
}

/**
 * Mark an entry that wasn't started again to be tried again RESTART_RETRY later (retry_restarts), if it hasn't been
 * RESTART_RETRIES times in a row already.
 *
 * @param supervisor The supervisor, whose entry is marked retry and a timer set under RESTART_RETRY_KEY.
 * @param index Its index in started; out of range does nothing.
 * @return Whether it'll be tried again; false if index is out of range or it's had its RESTART_RETRIES.
 */
retry_later :: fn(supervisor: ptr[mut Supervisor], index: usize) -> bool {
    if index >= supervisor.started_count || index >= supervisor.started.count || supervisor.started[index].retries >= RESTART_RETRIES {
        return false
    }
    supervisor.started[index].retry = true
    _ = slop_os.port_set_timer(supervisor.port, RESTART_RETRY_KEY, (slop_os.clock_monotonic() or_else 0) + RESTART_RETRY)
    return true
}

/**
 * Try again to start every entry whose restart's launch failed (Started.retry), as ended would; each try counts in
 * its retries, so failed gives up on one once it's had RESTART_RETRIES.
 *
 * @param supervisor The supervisor, whose entries marked retry are cleared, their retries grown by one, and started
 *     again.
 */
retry_restarts :: fn(supervisor: ptr[mut Supervisor]) {
    for i in 0..<supervisor.started_count {
        if i >= supervisor.started.count {
            break
        }
        entry :: &supervisor.started[i]
        if !entry.retry || entry.running || entry.done {
            continue
        }
        entry.retry = false
        budget : u64 = 0
        match service_named(supervisor, entry.name) {
            case Some(service) => budget = service.budget
            case None => {}
        }
        entry.retries += 1
        start_again(supervisor, i, budget)
    }
}

/**
 * Wait until the supervisor's memory budget has room to split off a program's budget, or RESTART_BUDGET_WAIT has
 * passed.
 *
 * What the last process had comes back once its subtree is gone and a grace period has passed, and a big service's
 * budget can't be split off twice. It looks every 10 ms, without handling what arrives on the port meanwhile.
 *
 * @param supervisor The supervisor, whose memory budget, from its startup block, is looked at; nothing in it changes.
 * @param bytes The program's budget, in bytes; room for RESTART_BUDGET_SPARE more is waited for too.
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

/**
 * Start a service that isn't a driver again, into its entry, as it was started.
 *
 * A restarted events service is given the running programs' rings and the events directory again; a restarted storage
 * manager is asked for the system volume again. A name it doesn't know is left ended.
 *
 * @param supervisor The supervisor, which is to have set relaunching to index, so the launch is watched under it; the
 *     service's start function replaces the connection kept to it.
 * @param index Its index in started, whose entry has ended and whose name says which service it is; it's taken modulo
 *     MAX_STARTED.
 */
restart_service :: fn(supervisor: ptr[mut Supervisor], index: usize) {
    name :: supervisor.started[index % supervisor.started.count].name
    if name == "events" {
        start_events(supervisor, index)
        adopt_rings(supervisor, index)
        store_events(supervisor)
    }
    else if name == "terminal" {
        start_terminal(supervisor, index)
    }
    else if name == "accounts" {
        start_accounts(supervisor, supervisor.storage_slot, index)
    }
    else if name == "sessions" {
        start_sessions(supervisor, index)
    }
    else if name == "input" {
        start_input(supervisor, index)
    }
    else if name == "hello" {
        start_hello(supervisor, index)
    }
    else if name == "bundle_store" {
        start_store(supervisor, index)
    }
    else if name == "config" {
        start_config(supervisor, index)
    }
    else if name == "update" {
        start_update(supervisor, index)
    }
    else if name == "storage_manager" {
        if start_storage(supervisor, index) != NOWHERE {
            open_system(supervisor, index)
        }
    }
}

/**
 * Record a program just launched, in a new entry or, for a restart, its old one, and tell the root task it started.
 *
 * The entry takes the budget, ring, lifecycle channel and faults' intercept kept for the program launched last, and is
 * marked running.
 *
 * @param supervisor The supervisor, whose launched_budget, launched_ring and launched_lifecycle move to the entry, and
 *     whose started_count grows by one for a new one.
 * @param name The name it's started under, which has to outlive the entry: a constant, or the system records' copy.
 * @param process Its process, which the entry takes.
 * @param again The entry a restart launches into, or NOWHERE for a new one.
 * @return Its index in started, or MAX_STARTED if there's no room for a new one, or again is out of range; then it
 *     runs, but isn't kept.
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
    entry.lifecycle = take_lifecycle(supervisor)
    entry.faults = take_faults(supervisor)
    entry.image = supervisor.launched_image
    entry.running = true
    entry.done = false
    drain_trace(supervisor)
    entry.ended_on_request = false
    tell_root(supervisor, .Started(report_of(name, 0)))
    return again
}

/**
 * Open the system volume: the SlopOS container's, from the storage manager, where programs outside the boot set come
 * from.
 *
 * It replaces the connection before it, if any, adding one to system_generation, and is watched, and opened again when
 * it closes, as when the volume's server is started again (decisions/0098). It's given to the events service to keep
 * records in, and its directories to the bundle store and the config store; the bundle store, the config store, whose
 * override is then read, and the update service are started the first time. Without a system volume, the bundle store
 * and the config store are noted missing, if they hadn't started. A call while one is opening does nothing. Meanwhile
 * the supervisor's port is handled.
 *
 * @param supervisor The supervisor, whose system, system_port and system_generation are replaced; its port is handled
 *     while the storage manager is asked, and the bundle store, config store and update service may be started.
 * @param storage_slot The storage manager's index in started; if it isn't running, there's no system volume.
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
            if slop_os.port_bind(supervisor.port, cast[slop_os.Handle](root.end), slop_os.SIGNAL_PEER_CLOSED,
                SYSTEM_KEY + supervisor.system_generation % SYSTEM_GENERATIONS, .Once) is_error {
                log_line.write(supervisor.log, "supervisor: can't watch the system volume's root for its end")
            }
            store_events(supervisor)
            if supervisor.store_end == NONE {
                start_store(supervisor, NOWHERE)
            }
            else {
                match lent_directory(supervisor, "store", "bundle_store") {
                    case Some(directory) => _ = store_request(supervisor, .UseDirectory(directory))
                    case None => {}
                }
            }
            if supervisor.config_end == NONE {
                start_config(supervisor, NOWHERE)
                read_overrides(supervisor)
            }
            if supervisor.update_end == NONE && !supervisor.recovery {
                start_update(supervisor, NOWHERE)
            }
            else {
                match lent_directory(supervisor, "config", "config") {
                    case Some(directory) => _ = config_request(supervisor, .UseDirectory(directory))
                    case None => {}
                }
            }
        }
        // What needs the system volume can't start without it, if it hadn't started before
        case None => {
            if supervisor.store_end == NONE {
                note_missing(supervisor, "bundle_store", "skipped: the storage manager gave no system volume", 0)
            }
            if supervisor.config_end == NONE {
                note_missing(supervisor, "config", "skipped: the storage manager gave no system volume", 0)
            }
        }
    }
}

/**
 * Assess the boot (decisions/0115), once everything has started: healthy if every service the system needs, any that
 * isn't late, is up, or degraded.
 *
 * Every entry that ended for good with a code that isn't 0 is noted missing, with what was noted already. A healthy
 * boot is said to the root task as Healthy. A degraded one is logged, said to the root task as Degraded with how many
 * are missing, and its record, a line of each one's name and reason, written to the system volume as boot/degraded,
 * if there's one.
 *
 * @param supervisor The supervisor, once everything has started: its missing grows by each entry that ended for good,
 *     up to MAX_MISSING, and its system volume, if any, is written to.
 * @return True if the boot is healthy; false if it's degraded.
 */
assess :: fn(supervisor: ptr[mut Supervisor]) -> bool {
    for i in cast[usize](0)..<supervisor.started_count {
        if i < supervisor.started.count {
            entry :: supervisor.started[i]
            if entry.done && entry.code != 0 {
                note_missing(supervisor, entry.name, "ended for good", entry.code)
            }
        }
    }
    if supervisor.missing_count == 0 {
        log_line.write(supervisor.log, "supervisor: healthy: every service the system needs is up")
        tell_root(supervisor, .Healthy)
        return true
    }
    record : u8[..]
    defer runtime.array_free(&record)
    for i in cast[usize](0)..<supervisor.missing_count {
        if i < supervisor.missing.count {
            each :: supervisor.missing[i]
            log_line.write(supervisor.log, "supervisor: degraded: % %, %", each.name, each.reason, each.code)
            for text in string.[each.name, ": ", each.reason, "\n"] {
                for character in text {
                    _ = runtime.array_try_add(&record, cast[u8](character))
                }
            }
        }
    }
    match system_directory(supervisor, "boot") {
        case Some(boot) => {
            directory, error :: os.directory_on(boot.end)
            if error == null {
                if os.write_entire_file_in(directory, "degraded", bit_cast[string](record[0..<record.count])) != null {
                    log_line.write(supervisor.log, "supervisor: the degraded boot's record couldn't be written")
                }
                os.close_directory(directory)
            }
        }
        case None => {}
    }
    tell_root(supervisor, .Degraded(cast[u32](supervisor.missing_count)))
    return false
}

/**
 * Start the update service, when there's an ESP and the bundle store.
 *
 * It's given the ESP's root, the system volume's "updates" directory, a connection to the store, and a listener whose
 * other end the supervisor keeps, replacing the last one's. Without any of them it isn't started, and nothing is said.
 *
 * @param supervisor The supervisor, which needs a bundle store, a storage manager and a system volume; its update_end
 *     and update_port are replaced once it's launched, and NONE if it can't be.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_update :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    if supervisor.store_end == NONE || supervisor.storage_slot == NOWHERE {
        return void
    }
    service :: service_named(supervisor, "update") or_return void
    esp :: files_of_type(supervisor, supervisor.storage_slot, storage_manager.ESP_TYPE) or_return void
    updates :: lent_directory(supervisor, "updates", "update") or_return void
    store :: store_connection(supervisor) or_return void
    if supervisor.update_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.update_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.update_port))
        supervisor.update_end = NONE
    }
    pair :: os.channel_for[update_protocol.Update](supervisor.block.budget, update_protocol.RING_BYTES) or_return void
    grants := UpdateGrants.{esp = esp, updates = updates, store = store,
        clients = os.Listener[update_protocol.Update].{end = pair.a}}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        update_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            _ = place(supervisor, "update", kept(supervisor, launched), again)
            supervisor.update_end = pair.b
            supervisor.update_port = os.port_for(supervisor.block.budget, pair.b) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/*
 * Installations (decisions/0113, 0117): the session manager runs them, in each session (0153); the supervisor keeps the
 * system's list, written to the config store from the build's the first time.
 */

/**
 * Make a connection to the system's installations list in the config store, for the session manager, writing the
 * build's list there first if it has none yet.
 *
 * @param supervisor The supervisor, which needs a config store; its installations connection is made and kept the
 *     first time, and its port isn't handled while the store answers.
 * @return A new connection to the list, which moves to the caller; null without the config store, or if it refused.
 */
installations_for_sessions :: fn(supervisor: ptr[mut Supervisor]) -> config_protocol.Config[system_records.Installations]? {
    settings :: installations_connection(supervisor) or_return null
    value := os.Outgoing.{}
    stored := system_records.Installations.{}
    if config_protocol.read(settings, supervisor.installations_port, &value) is_ok {
        stored = os.typed_value[system_records.Installations](os.value_bytes(&value))^
    }
    if stored.set == 0 {
        _ = write_installations(supervisor, supervisor.boot_records.installations)
    }
    return config_for[system_records.Installations](supervisor, "system", "installations")
}

/**
 * Make a new connection to the bundle store, its one end sent to the store with Connect, which takes it without
 * answering.
 *
 * @param supervisor The supervisor, whose bundle store connection the Connect is sent on, and whose budget pays for the
 *     new channel; nothing in it changes.
 * @return The other end, which moves to the caller; null without a bundle store, or if the Connect couldn't be sent.
 */
store_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[bundle_store.BundleStore]? {
    if supervisor.store_end == NONE {
        return null
    }
    pair :: os.channel_for[bundle_store.BundleStore](supervisor.block.budget, 0) or_return null
    connecting := os.Outgoing.{}
    os.begin[bundle_store.Request](&connecting)^ = .Connect(os.Channel[bundle_store.BundleStore].{end = pair.a})
    if bundle_store.send_request(supervisor.store_end, supervisor.store_port, &connecting) is_some {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return os.Channel[bundle_store.BundleStore].{end = pair.b}
}

/**
 * Copy the kernel's command line, read-only and transferable, for a service that reads its test words.
 *
 * @param supervisor The supervisor, whose command line is copied; its own handle stays as it is.
 * @return The copy, which moves to the caller; null without a command line, or if it couldn't be copied.
 */
command_line_copy :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.Memory? {
    text :: supervisor.command_line or_return null
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    return match slop_os.handle_duplicate(cast[slop_os.Handle](text), rights) {
        case Ok(copy) => cast[slop_os.Memory](copy)
        case Error(error) => null
    }
}

/**
 * Write the system's installations to the config store, marked as set, so they're not written from the build's again.
 *
 * @param supervisor The supervisor, whose installations connection is made and kept the first time; it waits for the
 *     store's answer without handling its port.
 * @param list The installations; its set field is set to 1 before it's checked and written.
 * @return True if the list checked and the store kept it; false without a config store, if it doesn't check, or if
 *     the store refused it.
 */
write_installations :: fn(supervisor: ptr[mut Supervisor], list: system_records.Installations) -> bool {
    settings :: installations_connection(supervisor) or_return false
    written := list
    written.set = 1
    if system_records.installations_check(&written) is_some {
        return false
    }
    value := os.Outgoing.{}
    os.begin[system_records.Installations](&value)^ = written
    fields :: config_protocol.field_bit[system_records.Installations]("count") | config_protocol.field_bit[system_records.Installations]("set")
        | config_protocol.field_bit[system_records.Installations]("entries")
    return config_protocol.write(settings, supervisor.installations_port, os.value_bytes(&value), fields) is_ok
}

/**
 * Get the supervisor's connection to the system's installations, made and declared the first time, and kept.
 *
 * @param supervisor The supervisor, whose installations_end and installations_port are set the first time it's
 *     declared, and left NONE if it isn't.
 * @return The connection, which stays the supervisor's; null without a config store, or if it couldn't be declared.
 */
installations_connection :: fn(supervisor: ptr[mut Supervisor]) -> config_protocol.Config[system_records.Installations]? {
    if supervisor.installations_end != NONE {
        return config_protocol.Config[system_records.Installations].{end = supervisor.installations_end}
    }
    settings :: config_for[system_records.Installations](supervisor, "system", "installations") or_return null
    port :: os.port_for(supervisor.block.budget, settings.end) or_return null
    if config_protocol.declare(settings, port) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](settings.end))
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
        return null
    }
    supervisor.installations_end = settings.end
    supervisor.installations_port = port
    return settings
}

/**
 * Tell the update service how the boot went, as Booted with the generation booted, and wait for it to act on it.
 *
 * @param supervisor The supervisor, whose generation is told on its update service connection; its port isn't
 *     handled while it waits.
 * @param healthy Whether the boot is healthy, so the generation is made permanent, or rolled back for the next boot.
 * @return Its answer: Live with a generation to apply live, another answer, or Unsupported without an update service.
 */
tell_update :: fn(supervisor: ptr[mut Supervisor], healthy: bool) -> update_protocol.Response {
    if supervisor.update_end == NONE {
        return .Unsupported
    }
    out := os.Outgoing.{}
    os.begin[update_protocol.Request](&out)^ = .Booted(update_protocol.Booted.{generation = supervisor.generation, healthy = healthy})
    into := os.Incoming.{}
    return update_protocol.ask(supervisor.update_end, supervisor.update_port, &out, &into)
}

/**
 * Apply a generation that changes only services live (decisions/0123, 0126).
 *
 * Its store root is the supervisor's from now on, and each running service outside the boot set whose bundle's program
 * changed is killed, its program read again, and waited for until it's started again from the new one; its clients
 * redial through their connectors. Then the update service is told the generation booted, healthy if every one of them
 * came back, so it's made permanent, or rolled back for the next boot.
 *
 * @param supervisor The supervisor, whose boot_root and generation become the live generation's, whose loaded programs
 *     of the changed services are closed and forgotten, and whose port is handled while they're started again.
 * @param live The generation, as the update service's Live answer gave it: its number and its store root.
 */
apply_live :: fn(supervisor: ptr[mut Supervisor], live: update_protocol.LiveOf) {
    old_root :: supervisor.boot_root
    restarted := cast[u64](0)
    healthy := true
    for entry, i in supervisor.started {
        if i >= supervisor.started_count || !entry.running || entry.driver {
            continue
        }
        service :: service_named(supervisor, entry.name) or_continue
        if service.boot_set {
            continue
        }
        name :: program_name(service.module)
        supervisor.boot_root = old_root
        before :: stored_hash(supervisor, name, 0)
        supervisor.boot_root = live.store_root
        after :: stored_hash(supervisor, name, 0)
        if (before is_none) || (after is_none) || bundle.same(before or_else bundle.Hash.{}, after or_else bundle.Hash.{}) {
            continue
        }
        // Read again from the new bundle when it's started again
        place :: system_records.index_of(supervisor.records, service.name)
        if place < supervisor.loaded.count {
            match supervisor.loaded[place].module {
                case Some(module) => _ = slop_os.handle_close(cast[slop_os.Handle](module))
                case None => {}
            }
            supervisor.loaded[place] = Loaded.{}
        }
        healthy = kill_and_wait(supervisor, entry.name, "a live update") && healthy
        restarted += 1
    }
    supervisor.boot_root = live.store_root
    supervisor.generation = live.generation
    log_line.write(supervisor.log, "supervisor: generation % applied live, % services started again from their new bundles",
        live.generation, restarted)
    _ = tell_update(supervisor, healthy)
}

/**
 * Take a module's name without its extension, as the store's boot root names its bundle.
 *
 * @param module The module's name, as "hello.program".
 * @return A view of module up to its first '.', or the whole of it without one.
 */
program_name :: fn(module: string) -> string {
    for character, i in module {
        if character == '.' {
            return module[0..<i]
        }
    }
    return module
}

/**
 * Note a service the system needs as missing, for the boot's assessment.
 *
 * Nothing is noted for a service the system configuration doesn't have, one that's late, one noted already, or once
 * MAX_MISSING are.
 *
 * @param supervisor The supervisor, whose missing and missing_count may grow by one; its records are read.
 * @param name The service's name; the system records' copy of it is kept, which outlives the caller's.
 * @param reason Why it's missing, in words, kept as it is, so it has to outlive the assessment: a constant.
 * @param code The code that says more, kept as it is: the code it ended with, a launch error plus one, or 0 for none.
 */
note_missing :: fn(supervisor: ptr[mut Supervisor], name: string, reason #escaping : string, code: u64) {
    // Its name as the system records keep it, which outlives the caller's
    service :: system_records.service_of(supervisor.records, name) or_return void
    if service.late == 1 {
        return void
    }
    kept :: system_records.text_of(&service.name)
    for i in cast[usize](0)..<supervisor.missing_count {
        if i < supervisor.missing.count && supervisor.missing[i].name == name {
            return void
        }
    }
    at :: supervisor.missing_count
    if at < supervisor.missing.count {
        supervisor.missing[at] = Missing.{name = kept, reason = reason, code = code}
        supervisor.missing_count = at + 1
    }
}

/**
 * Work out when a service has to be up by, counting from when the supervisor started.
 *
 * @param supervisor The supervisor, whose records give the deadline and whose started_at it counts from; nothing in it
 *     changes.
 * @param name The service's name, as the system configuration has it.
 * @return The deadline, in nanoseconds of the monotonic clock; slop_os.NO_DEADLINE if the system configuration doesn't
 *     have the service.
 */
deadline_of :: fn(supervisor: ptr[Supervisor], name: string) -> u64 {
    service :: system_records.service_of(supervisor.records, name) or_return slop_os.NO_DEADLINE
    return supervisor.started_at + system_records.deadline_of(supervisor.records, service)
}

/**
 * Run test_restart_services: kill the events service, the clock service and the storage manager, if it was started,
 * each in turn, and check each once it's back, logging what's found.
 *
 * The events service is checked by a record of the clock service's, started again after it; the clock service by
 * setting the time; and the storage manager by giving the system volume again. Before the storage manager, the first
 * disk's partition server is restarted through it, and the bundle store read through the system volume served again.
 * It stops if the events service or the clock service doesn't come back.
 *
 * @param supervisor The supervisor, whose events service, clock service and storage manager are killed and started
 *     again into their entries; its port is handled while it waits, and its system volume connection is replaced.
 * @param storage_slot The storage manager's index in started, or NOWHERE without one, which skips its part.
 */
restart_services :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize) {
    if !kill_and_wait(supervisor, "events", "test_restart_services") {
        return void
    }
    if !kill_and_wait(supervisor, "clock", "test_restart_services") {
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
                    match stored_object(supervisor, manifest) {
                        case Some(object) => {
                            manifest_read = object.bytes.count >= 4 && object.bytes[0] == 0x48 && object.bytes[1] == 0x53
                            let_go_of_object(object)
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
    restarted :: kill_and_wait(supervisor, "storage_manager", "test_restart_services")
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

/**
 * Kill what's running under a name, and wait, handling the port meanwhile, until it's been started again or is done.
 *
 * @param supervisor The supervisor, whose entry for name is marked not running at once; its port is handled until the
 *     entry is running again with more restarts, or done, which may be never if neither happens.
 * @param name Its name; of several running under it, the last one in started is killed.
 * @param test What's killing it, for the log line, as "test_degraded".
 * @return True if it's running again; false if nothing was running under name, or it's done for good.
 */
kill_and_wait :: fn(supervisor: ptr[mut Supervisor], name: string, test: string) -> bool {
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
    log_line.write(supervisor.log, "supervisor: %: killing %", test, name)
    _ = slop_os.process_kill(supervisor.started[index].process)
    // Not running from here, though its end arrives on the port later
    supervisor.started[index].running = false
    loop {
        wait_and_handle(supervisor)
    }
    while !supervisor.started[index].done && !(supervisor.started[index].running && supervisor.started[index].restarts > restarts)
    return supervisor.started[index].running
}

/**
 * Kill a driver whose device's DMA an IOMMU blocked, if it's running, so it's started again as one that crashed.
 *
 * @param supervisor The supervisor, whose entry is marked not running; its end, arriving later, is handled by ended.
 * @param index The driver's index in started, taken modulo MAX_STARTED.
 * @param address The address the blocked DMA was to, for the log line.
 */
dma_fault :: fn(supervisor: ptr[mut Supervisor], index: usize, address: u64) {
    entry :: &supervisor.started[index % supervisor.started.count]
    if !entry.running {
        return void
    }
    log_line.write(supervisor.log, "supervisor: %'s DMA was blocked, at %{#018x}; killing it", entry.name, address)
    _ = slop_os.process_kill(entry.process)
    // Not running from here, though its end arrives on the port later
    entry.running = false
}

/**
 * Tell whether what's named name has ended for good, or wasn't started.
 *
 * @param supervisor The supervisor, whose entries in use are read; nothing in it changes.
 * @param name Its name; the first entry of that name is looked at.
 * @return True if it's done, or nothing of that name was started; false while it runs or may be started again.
 */
ended_for_good :: fn(supervisor: ptr[Supervisor], name: string) -> bool {
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.name == name {
            return entry.done
        }
    }
    return true
}

/**
 * Start a driver for a device, with what it holds of the device, and a listener for its clients if it serves any.
 *
 * The driver's Device is watched for DMA faults through a handle of the supervisor's own. The first serial line,
 * disk and input device a driver serves become first_serial, first_disk and first_keyboard. A service it doesn't know
 * as a driver isn't started. A failed launch is logged, noted missing and told to the root task.
 *
 * @param supervisor The supervisor, which is to have set relaunching to again for a restart: a new entry is placed,
 *     or again's takes the launch's budget and ring; its port watches the driver's DMA faults, and first_serial,
 *     first_disk or first_keyboard may be set.
 * @param index The driver's service, by its index in the system configuration.
 * @param device The device, as the platform service claimed or reissued it; its handles move to the driver, or are
 *     closed if it isn't started.
 * @param again The entry a restart launches into, or NOWHERE for a first start.
 */
start_driver :: fn(supervisor: ptr[mut Supervisor], index: usize, device: platform.PciDevice, again: usize) {
    service :: match service_at(supervisor, index) {
        case Some(found) => found
        case None => {
            close_device(&device)
            return void
        }
    }
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
    else if service.name == "i6300esb" {
        name = "i6300esb"
        pair :: listener_for[watchdog.Watchdog](supervisor, &device) or_return void
        listener = pair.b
        launched = launch_serving[watchdog.Watchdog](supervisor, service, device, pair.a, i6300esb.main)
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
        entry.faults = take_faults(supervisor)
        entry.image = supervisor.launched_image
    }
    entry.running = true
    entry.listener = listener
    entry.speaks = speaks
    entry.driver = true
    entry.service = index
    entry.address = device.address
    entry.done = false
    entry.watch = watch
    if name == "i6300esb" {
        supervisor.watchdog_listener = listener
        arm_watchdog(supervisor)
    }
    if watch != slop_os.NO_HANDLE
        && (slop_os.port_bind(supervisor.port, watch, slop_os.SIGNAL_DMA_FAULT, FAULT_KEY + cast[u64](slot), .Persistent) is_error) {
        log_line.write(supervisor.log, "supervisor: %'s DMA faults go unwatched", name)
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

/**
 * Make a channel for a driver's listener: its one end for the driver, its other the supervisor's.
 *
 * @tparam P The protocol the driver serves.
 * @param supervisor The supervisor, whose budget pays for it.
 * @param device The driver's device, closed if the channel can't be made, since the driver then isn't started.
 * @return Both ends, the caller's; null if it couldn't be made.
 */
listener_for :: fn[P](supervisor: ptr[mut Supervisor], device: ptr[platform.PciDevice]) -> slop_os.ChannelPair? {
    match os.channel_for[P](supervisor.block.budget, 0) {
        case Ok(made) => return made
        case Error(error) => {
            close_device(device)
            return null
        }
    }
}

/**
 * Launch a driver that serves clients, with its device and its listener's end.
 *
 * @tparam P The protocol the driver serves.
 * @param supervisor The supervisor, which launches it through its process manager connection; a launch's budget is
 *     kept in launched_budget, and a failed one's watch on its port is ended and it's noted missing.
 * @param service The driver's service, whose name, module and budget it's launched with.
 * @param device The device, whose handles move to the driver.
 * @param end The listener's end for the driver, which moves to it.
 * @param entry The driver's main, which its process runs with the grants made from device and end.
 * @return Its process, which the caller keeps; NO_HANDLE if the launch failed, which is logged, noted missing and told
 *     to the root task.
 */
launch_serving :: fn[P](supervisor: ptr[mut Supervisor], service: Service, device: platform.PciDevice,
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

/**
 * Launch a driver given only its device.
 *
 * @param supervisor The supervisor, which launches it through its process manager connection; a launch's budget is
 *     kept in launched_budget, and a failed one's watch on its port is ended and it's noted missing.
 * @param service The driver's service, whose name, module and budget it's launched with.
 * @param device The device, whose handles move to the driver.
 * @param entry The driver's main, which its process runs with the grants made from device.
 * @return Its process, which the caller keeps; NO_HANDLE if the launch failed, which is logged, noted missing and told
 *     to the root task.
 */
launch_device_only :: fn(supervisor: ptr[mut Supervisor], service: Service, device: platform.PciDevice,
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

/**
 * Make a new connection to the entropy service, for a program the supervisor starts (decisions/0101), dialed through
 * the root task's connector.
 *
 * The port the Dial is sent with is closed after it, taking its binding with it.
 *
 * @param supervisor The supervisor, whose entropy connector is dialed, and whose budget pays for the port; nothing in
 *     it changes.
 * @return The connection, which moves to the caller; null without a connector, if the dial failed, or if what was
 *     dialed doesn't speak the entropy protocol.
 */
entropy_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[entropy.Entropy]? {
    if supervisor.entropy_connector == NONE {
        return null
    }
    channel :: dial_through(supervisor, supervisor.entropy_connector) or_return null
    if !os.speaks[entropy.Entropy](channel) {
        _ = slop_os.handle_close(cast[slop_os.Handle](channel))
        return null
    }
    return os.Channel[entropy.Entropy].{end = channel}
}

/**
 * Dial through one of the root task's connectors, its answer waited for on a port of the dial's own, closed after.
 *
 * @param supervisor The supervisor, whose budget pays for the port.
 * @param through The connector, which stays the caller's.
 * @return The new connection, which moves to the caller; null if no port could be made or the dial failed.
 */
dial_through :: fn(supervisor: ptr[mut Supervisor], through: slop_os.Channel) -> slop_os.Channel? {
    port :: os.port_for(supervisor.block.budget, through) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    return connector.dial_raw(through, port)
}

/**
 * Dial the supervisor's connection to one of the root task's services through its connector, in place of one that's
 * gone (decisions/0140), and watch it for its other end closing, under ROOT_SERVICE_KEY plus which.
 *
 * The old connection, if any, is closed first, and its watch ended.
 *
 * @param supervisor The supervisor, whose manager, platform_end or scheduler_end, with its port, is replaced, and whose
 *     port watches the new one.
 * @param which The service: 0 the process manager, 1 the platform service, any other the scheduler service.
 * @return True if it's connected; false without a connector, or if the dial failed, which leaves the field holding the
 *     closed connection.
 */
dial_root_service :: fn(supervisor: ptr[mut Supervisor], which: usize) -> bool {
    through :: if which == 0 { supervisor.manager_connector } else if which == 1 { supervisor.platform_connector }
        else { supervisor.scheduler_connector }
    if through == NONE {
        return false
    }
    old :: if which == 0 { supervisor.manager.end } else if which == 1 { supervisor.platform_end } else { supervisor.scheduler_end }
    again :: old != NONE && cast[slop_os.Handle](old) != slop_os.NO_HANDLE
    if again {
        _ = slop_os.port_unbind(supervisor.port, ROOT_SERVICE_KEY + cast[u64](which))
        _ = slop_os.handle_close(cast[slop_os.Handle](old))
    }
    channel :: dial_through(supervisor, through) or_return false
    port :: os.port_for(supervisor.block.budget, channel) or_return false
    if which == 0 {
        supervisor.manager = os.Channel[process_manager.ProcessManager].{end = channel}
        supervisor.manager_port = port
    }
    else if which == 1 {
        supervisor.platform_end = channel
        supervisor.platform_port = port
    }
    else {
        supervisor.scheduler_end = channel
        supervisor.scheduler_port = port
    }
    _ = slop_os.port_bind(supervisor.port, cast[slop_os.Handle](channel), slop_os.SIGNAL_PEER_CLOSED, ROOT_SERVICE_KEY + cast[u64](which), .Once)
    if again {
        names :: string.["the process manager", "the platform service", "the scheduler service"]
        log_line.write(supervisor.log, "supervisor: dialed % again", names[which % names.count])
    }
    return true
}

/**
 * Launch a driver for a virtio entropy device, with a connection of its own to the entropy service.
 *
 * @param supervisor The supervisor, which launches it through its process manager connection and dials the entropy
 *     service for it; a launch's budget is kept in launched_budget, and a failed one is noted missing.
 * @param service The driver's service, whose name, module and budget it's launched with.
 * @param device The device, whose handles move to the driver.
 * @return Its process, which the caller keeps; NO_HANDLE if the launch failed, which is logged, noted missing and told
 *     to the root task.
 */
launch_virtio_rng :: fn(supervisor: ptr[mut Supervisor], service: Service, device: platform.PciDevice) -> slop_os.Process {
    grants := VirtioRngGrants.{log = duplicate_log(supervisor), device = device.device, config = device.config, domain = device.domain,
        bar0 = optional(device.bar0), bar1 = optional(device.bar1), bar2 = optional(device.bar2), bar3 = optional(device.bar3),
        bar4 = optional(device.bar4), bar5 = optional(device.bar5)}
    grants.entropy_service = entropy_connection(supervisor)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        virtio_rng.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => return kept(supervisor, launched)
        case Error(error) => {
            failed(supervisor, service.name, error)
            return cast[slop_os.Process](slop_os.NO_HANDLE)
        }
    }
}

/**
 * Make the options a service is launched with beyond its grants.
 *
 * Its end is watched on the supervisor's port from before it starts, under the key of the entry it's to have
 * (next_slot), so one that ends at once is seen to. It runs on the CPU budget the scheduler service gives it, and is
 * given the clock page, read-only, a lifecycle channel (decisions/0139), and a ring for its log records from the events
 * service. The supervisor keeps the lifecycle channel's other end and the ring, in launched_lifecycle and
 * launched_ring, until the entry takes them; ones kept from a launch before that no entry took are let go of.
 *
 * @param supervisor The supervisor, which is to set relaunching first for a restart; its launched_lifecycle and
 *     launched_ring are replaced, and its port watches the program's end from now.
 * @param name The service's name, which its CPU budget and its ring are asked for under.
 * @return The options, whose handles move to the program with the launch; each is left out where it couldn't be had.
 */
options_for :: fn(supervisor: ptr[mut Supervisor], name: string) -> os.LaunchOptions {
    options := os.LaunchOptions.{}
    if supervisor.scheduler_end != NONE {
        options.cpu_budget = scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, name)
    }
    // Its end watched from before it starts, under the key of the entry it's to have: one that ends at once is seen to
    options.watch = os.LaunchWatch.{port = supervisor.port, key = cast[u64](next_slot(supervisor))}
    // Its faults reported from before it starts, likewise (crashes.hsc)
    options.faults = os.LaunchFaults.{port = supervisor.port, key = CRASH_KEY + cast[u64](next_slot(supervisor))}
    if cast[slop_os.Handle](supervisor.clock_page) != slop_os.NO_HANDLE {
        rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
        match slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.clock_page), rights) {
            case Ok(copy) => options.clock = cast[slop_os.Memory](copy)
            case Error(error) => {}
        }
    }
    // A lifecycle channel (decisions/0139), which base's runtime serves in the program, the supervisor keeping its end
    if supervisor.launched_lifecycle != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.launched_lifecycle))
        supervisor.launched_lifecycle = NONE
    }
    match lifecycle.make(supervisor.block.budget) {
        case Some(pair) => {
            supervisor.launched_lifecycle = pair.a
            options.lifecycle = pair.b
        }
        case None => {}
    }
    // A ring for its records, which the supervisor keeps, giving the program a handle to it that doesn't own it
    if supervisor.events_end != NONE {
        match events.open(supervisor.events_end, supervisor.events_port, name) {
            case Some(opened) => {
                // Its records kept to the budget its configuration gives, if it gives one (decisions/0185, 12g)
                index :: system_records.index_of(supervisor.records, name)
                if index < system_records.MAX_SERVICES && index < cast[usize](supervisor.records.service_count)
                    && supervisor.records.services[index].events_budget != 0 {
                    configured :: supervisor.records.services[index].events_budget
                    if events.set_budget(supervisor.events_end, supervisor.events_port, name, configured) {
                        log_line.write(supervisor.log, "supervisor: %'s records are kept to % bytes, as its configuration says", name, configured)
                    }
                }
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

/**
 * Give a ring a program that's ended had back to the events service, which reads its last records and closes it.
 *
 * @param supervisor The supervisor, whose events service connection Retire is asked on, waiting for the answer
 *     without handling its port.
 * @param ring The ring, the supervisor's, which moves to the events service, or is closed if it isn't taken or there's
 *     no events service; NO_HANDLE does nothing.
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

/**
 * Give the rings of what's still running to an events service started again, as the last one's went with it, so it
 * reads their records from where that one stopped.
 *
 * Each is given as a copy with Adopt, under its program's name; the supervisor keeps its own handle.
 *
 * @param supervisor The supervisor, whose running entries' rings are copied, each kept as it is; it waits for each
 *     answer without handling its port.
 * @param events_slot The events service's index in started, whose own ring isn't given.
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

/**
 * Take the lifecycle channel's end kept for the program launched last, for its entry.
 *
 * @param supervisor The supervisor, whose launched_lifecycle is NONE after.
 * @return The end, which moves to the caller; NONE if there's none.
 */
take_lifecycle :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.Channel {
    end :: supervisor.launched_lifecycle
    supervisor.launched_lifecycle = NONE
    return end
}

/**
 * Take the log ring kept for the program launched last, for its entry.
 *
 * @param supervisor The supervisor, whose launched_ring is NO_HANDLE after.
 * @return The ring, which moves to the caller; NO_HANDLE if there's none.
 */
take_ring :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.Memory {
    ring :: supervisor.launched_ring
    supervisor.launched_ring = cast[slop_os.Memory](slop_os.NO_HANDLE)
    return ring
}

/**
 * Start the events service, with a listener whose other end the supervisor keeps, replacing the last one's.
 *
 * Once it's started, a connection of its own is made for the root task, which is sent it as EventsService, for the
 * services it starts again to log through (decisions/0140).
 *
 * @param supervisor The supervisor, whose events_end and events_port are replaced, and NONE if it can't be launched;
 *     the root task is told of it.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_events :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "events") or_return void
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
            // A connection of the root task's own, for the services it starts again to log through (decisions/0140)
            match os.channel_for[events.Events](supervisor.block.budget, 0) {
                case Ok(given) => {
                    out := os.Outgoing.{}
                    os.begin[events.Request](&out)^ = .Connect(os.Channel[events.Events].{end = given.a})
                    if events.send_request(supervisor.events_end, supervisor.events_port, &out) == null {
                        tell_root(supervisor, .EventsService(os.Channel[events.Events].{end = given.b}))
                    }
                    else {
                        _ = slop_os.handle_close(cast[slop_os.Handle](given.b))
                    }
                }
                case Error(error) => {}
            }
            log_through_events(supervisor)
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/**
 * Have the supervisor's own records go to the events service, under its source "supervisor", once there is one
 * (decisions/0185, 12g): it starts before the events service, so it's given no ring at its start, and its typed
 * records, like its crash reports, would go nowhere. The ring's owning handle is kept for the rest of its life.
 *
 * @param supervisor The supervisor, whose events connection opens the source; nothing's done if its logger has a ring.
 */
log_through_events :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.events_end == NONE {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[events.Request](&out)
    request^ = .Open(bytes_of(&out, "supervisor"))
    into := os.Incoming.{}
    match events.ask(supervisor.events_end, supervisor.events_port, &out, &into) {
        case Opened(source) => {
            if !runtime.slop_os_adopt_events_ring(cast[u32](source.ring), cast[u32](source.doorbell)) {
                _ = slop_os.handle_close(cast[slop_os.Handle](source.doorbell))
            }
        }
        case _ => {}
    }
}

/**
 * Start the bundle store, with the system volume's "store" directory, made if it isn't there, and a listener whose
 * other end the supervisor keeps, replacing the last one's.
 *
 * Without the directory it isn't started.
 *
 * @param supervisor The supervisor, which needs a system volume; its store_end and store_port are replaced, and NONE
 *     if it can't be launched.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_store :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "bundle_store") or_return void
    directory :: lent_directory(supervisor, "store", "bundle_store") or_return void
    if supervisor.store_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.store_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.store_port))
        supervisor.store_end = NONE
    }
    if again != NOWHERE {
        forget_stored(supervisor)
    }
    pair :: os.channel_for[bundle_store.BundleStore](supervisor.block.budget, 0) or_return void
    grants := StoreGrants.{store = directory, clients = os.Listener[bundle_store.BundleStore].{end = pair.a},
        command_line = command_line_copy(supervisor)}
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

/**
 * Let go of every program got from the bundle store, which ended with the store that gave it (decisions/0094), so
 * each is got again from the one started again when its service is next launched (decisions/0181's F6).
 *
 * @param supervisor The supervisor, whose loaded entries from the store are closed and emptied; the rest stay.
 */
forget_stored :: fn(supervisor: ptr[mut Supervisor]) {
    for &each in supervisor.loaded {
        if each.from_store {
            match each.module {
                case Some(module) => _ = slop_os.handle_close(cast[slop_os.Handle](module))
                case None => {}
            }
            each^ = Loaded.{}
        }
    }
}

/**
 * Start the config store, with the system volume's "config" directory, made if it isn't there, and two listeners.
 *
 * The supervisor keeps the admin listener's other end, which it asks for programs' connections to their values on,
 * replacing the last one's; and the users' listener's, for the session manager (decisions/0152), replacing one not
 * given yet. Without the directory it isn't started.
 *
 * @param supervisor The supervisor, which needs a system volume; its config_end and config_port are replaced, NONE if
 *     it can't be launched, and its config_users replaced too.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_config :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "config") or_return void
    directory :: lent_directory(supervisor, "config", "config") or_return void
    if supervisor.config_end != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.config_end))
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.config_port))
        supervisor.config_end = NONE
    }
    pair :: os.channel_for[config_protocol.ConfigValue](supervisor.block.budget, 0) or_return void
    grants := ConfigGrants.{store = directory, admin = os.Listener[config_protocol.ConfigValue].{end = pair.a}}
    // The session manager's connection, for users' values (decisions/0152), given to it when it's started
    if supervisor.config_users != NONE {
        _ = slop_os.handle_close(cast[slop_os.Handle](supervisor.config_users))
        supervisor.config_users = NONE
    }
    match os.channel_for[config_protocol.ConfigValue](supervisor.block.budget, 0) {
        case Ok(users) => {
            grants.users = os.Listener[config_protocol.ConfigValue].{end = users.a}
            supervisor.config_users = users.b
        }
        case Error(error) => {}
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        config_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            _ = place(supervisor, "config", kept(supervisor, launched), again)
            supervisor.config_end = pair.b
            supervisor.config_port = os.port_for(supervisor.block.budget, pair.b) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/**
 * Send one request to the config store on the admin connection, and wait for its answer.
 *
 * @param supervisor The supervisor, whose config store admin connection it's asked on, which needs to be there; its
 *     port isn't handled while it waits.
 * @param request The request, which may carry handles that move to the store.
 * @return The store's answer, or what config_protocol.ask gives when the store doesn't answer.
 */
config_request :: fn(supervisor: ptr[mut Supervisor], request: config_protocol.Request) -> config_protocol.Response {
    out := os.Outgoing.{}
    made :: os.begin[config_protocol.Request](&out)
    made^ = request
    into := os.Incoming.{}
    return config_protocol.ask(supervisor.config_end, supervisor.config_port, &out, &into)
}

/**
 * Make a connection to a value in the config store, for its program, with ValueFor.
 *
 * @tparam T The value's type, which the connection is typed for.
 * @param supervisor The supervisor, whose config store admin connection ValueFor is asked on, waiting without handling
 *     its port; nothing in it changes.
 * @param owner The value's owner, as "system" or a service's name.
 * @param name The value's name, among its owner's.
 * @return The connection, which moves to the caller; null without a config store, or if it didn't open one.
 */
config_for :: fn[T](supervisor: ptr[mut Supervisor], owner: string, name: string) -> config_protocol.Config[T]? {
    if supervisor.config_end == NONE {
        return null
    }
    out := os.Outgoing.{}
    request :: os.begin[config_protocol.Request](&out)
    request^ = .ValueFor(config_protocol.ValueFor.{owner = bytes_of(&out, owner), name = bytes_of(&out, name)})
    into := os.Incoming.{}
    return match config_protocol.ask(supervisor.config_end, supervisor.config_port, &out, &into) {
        case Opened(connection) => config_protocol.Config[T].{end = connection.end}
        case _ => null
    }
}

/**
 * Read the system configuration's override, the config store's value "services" of owner "system" (decisions/0110),
 * and apply it to the boot set's.
 *
 * What the supervisor starts from then on is started as the override says, if system_records.apply takes it; if it
 * doesn't, or it can't be read, the configuration is left as it was. It's read once the config store has started, as
 * at every boot.
 *
 * @param supervisor The supervisor, whose records are replaced.
 */
read_overrides :: fn(supervisor: ptr[mut Supervisor]) {
    settings :: overrides_connection(supervisor) or_return void
    value := os.Outgoing.{}
    match config_protocol.read(settings, supervisor.overrides_port, &value) {
        case Ok(version) => {}
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: the system configuration's override couldn't be read: %", error)
            return void
        }
    }
    overrides :: os.typed_value[system_records.SystemOverrides](os.value_bytes(&value))
    changed := supervisor.boot_records^
    match system_records.apply(&changed, overrides) {
        case Some(problem) => {
            log_line.write(supervisor.log, "supervisor: the system configuration's override %; the boot set's is used", problem.reason)
            return void
        }
        case None => {}
    }
    supervisor.records^ = changed
    log_line.write(supervisor.log, "supervisor: the system configuration's override tunes % services", overrides.count)
}

/**
 * Get the supervisor's connection to the system configuration's override, made and declared the first time, and kept.
 *
 * @param supervisor The supervisor, whose overrides_end and overrides_port are set the first time it's declared, and
 *     left NONE if it isn't.
 * @return The connection, which stays the supervisor's; null without a config store, or if it couldn't be declared.
 */
overrides_connection :: fn(supervisor: ptr[mut Supervisor]) -> config_protocol.Config[system_records.SystemOverrides]? {
    if supervisor.overrides_end != NONE {
        return config_protocol.Config[system_records.SystemOverrides].{end = supervisor.overrides_end}
    }
    settings :: config_for[system_records.SystemOverrides](supervisor, "system", "services") or_return null
    port :: os.port_for(supervisor.block.budget, settings.end) or_return null
    match config_protocol.declare(settings, port) {
        case Ok(version) => {}
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: the system configuration's override couldn't be declared: %", error)
            _ = slop_os.handle_close(cast[slop_os.Handle](settings.end))
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
            return null
        }
    }
    supervisor.overrides_end = settings.end
    supervisor.overrides_port = port
    return settings
}

/**
 * Write an override of the system configuration to the config store, if system_records.apply takes it over the boot
 * set's. It isn't applied until it's read again.
 *
 * @param supervisor The supervisor, whose boot set's records the override is tried on, a copy changed, not them; its
 *     overrides connection is made and kept the first time.
 * @param overrides The override: its first count of tuned, up to MAX_TUNED, each naming a service of the boot set's
 *     and what's set of it. Only count and tuned are written.
 * @return True if it was taken and the store kept it; false without a config store, if apply refused it, or if the
 *     store did.
 */
write_overrides :: fn(supervisor: ptr[mut Supervisor], overrides: system_records.SystemOverrides) -> bool {
    settings :: overrides_connection(supervisor) or_return false
    changed := supervisor.boot_records^
    if system_records.apply(&changed, &overrides) is_some {
        return false
    }
    value := os.Outgoing.{}
    os.begin[system_records.SystemOverrides](&value)^ = overrides
    fields :: config_protocol.field_bit[system_records.SystemOverrides]("count") | config_protocol.field_bit[system_records.SystemOverrides]("tuned")
    return config_protocol.write(settings, supervisor.overrides_port, os.value_bytes(&value), fields) is_ok
}

/**
 * Read the substitution policy the config store asks for, its value "substitutions" of owner "system"
 * (decisions/0123, 0125).
 *
 * It's what the update service is told after a healthy boot, and stages a generation with if it's new. Nothing
 * applies it live; the root task applies a generation's policy at boot.
 *
 * @param supervisor The supervisor, whose substitutions connection is made and kept the first time; it waits for the
 *     store without handling its port.
 * @return The policy; an empty one without a config store, or if it couldn't be read.
 */
read_substitutions :: fn(supervisor: ptr[mut Supervisor]) -> bundle.Substitutions {
    settings :: substitutions_connection(supervisor) or_return bundle.Substitutions.{}
    value := os.Outgoing.{}
    match config_protocol.read(settings, supervisor.substitutions_port, &value) {
        case Ok(version) => {}
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: the substitution policy couldn't be read: %", error)
            return bundle.Substitutions.{}
        }
    }
    return os.typed_value[bundle.Substitutions](os.value_bytes(&value))^
}

/**
 * Pass a substitution policy on to the update service, for the generation booted, and wait for its answer.
 *
 * @param supervisor The supervisor, whose generation the policy is for, asked on its update service connection; its
 *     port isn't handled while it waits.
 * @param policy The policy, which the update service checks.
 * @return Its answer, as Staged with the generation it staged, or Refused; Unsupported without an update service or a
 *     generation booted.
 */
ask_substitute :: fn(supervisor: ptr[mut Supervisor], policy: bundle.Substitutions) -> update_protocol.Response {
    if supervisor.update_end == NONE || supervisor.generation == 0 {
        return .Unsupported
    }
    out := os.Outgoing.{}
    os.begin[update_protocol.Request](&out)^ = .Substitute(update_protocol.SubstituteOf.{generation = supervisor.generation, policy = policy})
    into := os.Incoming.{}
    return update_protocol.ask(supervisor.update_end, supervisor.update_port, &out, &into)
}

/**
 * Get the supervisor's connection to the substitution policy, made and declared the first time, and kept.
 *
 * @param supervisor The supervisor, whose substitutions_end and substitutions_port are set the first time it's
 *     declared, and left NONE if it isn't.
 * @return The connection, which stays the supervisor's; null without a config store, or if it couldn't be declared.
 */
substitutions_connection :: fn(supervisor: ptr[mut Supervisor]) -> config_protocol.Config[bundle.Substitutions]? {
    if supervisor.substitutions_end != NONE {
        return config_protocol.Config[bundle.Substitutions].{end = supervisor.substitutions_end}
    }
    settings :: config_for[bundle.Substitutions](supervisor, "system", "substitutions") or_return null
    port :: os.port_for(supervisor.block.budget, settings.end) or_return null
    match config_protocol.declare(settings, port) {
        case Ok(version) => {}
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: the substitution policy couldn't be declared: %", error)
            _ = slop_os.handle_close(cast[slop_os.Handle](settings.end))
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
            return null
        }
    }
    supervisor.substitutions_end = settings.end
    supervisor.substitutions_port = port
    return settings
}

/**
 * Write the substitution policy to the config store, unchecked: the update service checks it.
 *
 * @param supervisor The supervisor, whose substitutions connection is made and kept the first time.
 * @param policy The policy: its first count of entries, up to MAX_SUBSTITUTIONS, each a library's hash and the hash
 *     to put in its place. Only count and entries are written.
 * @return True if the store kept it; false without a config store, or if it refused it.
 */
write_substitutions :: fn(supervisor: ptr[mut Supervisor], policy: bundle.Substitutions) -> bool {
    settings :: substitutions_connection(supervisor) or_return false
    value := os.Outgoing.{}
    os.begin[bundle.Substitutions](&value)^ = policy
    fields :: config_protocol.field_bit[bundle.Substitutions]("count") | config_protocol.field_bit[bundle.Substitutions]("entries")
    return config_protocol.write(settings, supervisor.substitutions_port, os.value_bytes(&value), fields) is_ok
}

/**
 * Find the hash of a library the supervisor itself was given, from its "library:" grant.
 *
 * @param supervisor The supervisor, whose grants are searched.
 * @param name The library's name, as "service_kit.library".
 * @return Its hash, or null if there's no such grant.
 */
own_hash :: fn(supervisor: ptr[mut Supervisor], name: string) -> bundle.Hash? {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "library:")
    text_buffer.append(&label, name)
    memory :: slop_os.find_grant(supervisor.block, text_buffer.as_string(&label), .Memory) or_return null
    return substitution.library_hash(supervisor.block, memory)
}

/**
 * Run test_substitution, over two boots of a disk, logging what's found.
 *
 * The first: a policy putting greeting in service_kit's place, refused by the update service, as it doesn't export
 * what service_kit does; then service_kit_plus, service_kit's second build with one export more, staged as the next
 * generation. The second, that generation: the supervisor's own service_kit is service_kit_plus, as the root task gave
 * it. Without the libraries' grants it does nothing.
 *
 * @param supervisor The supervisor, whose grants give the libraries' hashes; it writes the substitution policy to its
 *     config store and asks its update service, which stages a generation for the next boot.
 */
check_substitution :: fn(supervisor: ptr[mut Supervisor]) {
    original :: own_hash(supervisor, "service_kit.library") or_return void
    plus :: own_hash(supervisor, "service_kit_plus.library") or_return void
    if bundle.same(original, plus) {
        log_line.write(supervisor.log, "supervisor: test_substitution: booted generation % with service_kit_plus in service_kit's place",
            supervisor.generation)
        return void
    }
    greeting :: own_hash(supervisor, "greeting.library") or_return void
    policy := bundle.Substitutions.{count = 1}
    policy.entries[0] = bundle.Substitution.{from = original, to = greeting}
    written := write_substitutions(supervisor, policy)
    refused :: match ask_substitute(supervisor, policy) {
        case Refused => true
        case _ => false
    }
    policy.entries[0].to = plus
    written = written && write_substitutions(supervisor, policy)
    staged := cast[u64](0)
    match ask_substitute(supervisor, policy) {
        case Staged(number) => staged = number
        case _ => {}
    }
    log_line.write(supervisor.log, "supervisor: test_substitution: greeting for service_kit %, service_kit_plus staged as generation %",
        if refused && written { "refused" } else { "taken" }, staged)
}

/**
 * Run test_system_config, once everything has started, logging what's found.
 *
 * An override of hello's memory budget, 3 MiB, is written, and one of a budget of 0 refused; the override is read
 * again, as at a boot, and hello killed, and started again on its new budget.
 *
 * @param supervisor The supervisor, whose records take the override read, and whose hello is killed and started again;
 *     its port is handled meanwhile. The override is left in the config store, for later boots too.
 */
check_system_config :: fn(supervisor: ptr[mut Supervisor]) {
    tuned := system_records.Tunables.{set = system_records.TUNE_BUDGET, budget = 3 * 1024 * 1024}
    _ = system_records.set_name(&tuned.name, "hello")
    overrides := system_records.SystemOverrides.{count = 1}
    overrides.tuned[0] = tuned
    taken :: write_overrides(supervisor, overrides)
    overrides.tuned[0].budget = 0
    refused :: !write_overrides(supervisor, overrides)
    read_overrides(supervisor)
    budget :: (service_named(supervisor, "hello") or_return void).budget
    restarted :: kill_and_wait(supervisor, "hello", "test_system_config")
    log_line.write(supervisor.log, "supervisor: test_system_config: an override of hello's budget %, one of 0 %; hello % on % MiB",
        if taken { "taken" } else { "refused" }, if refused { "refused" } else { "taken" }, if restarted { "started again" } else { "not started again" },
        budget / (1024 * 1024))
}

/**
 * Open a directory of the system volume's root for a service, made if it isn't there, lent the service's CPU budget
 * (Perf's Pc, decisions/0037, 0130).
 *
 * The volume server runs the service's work in it, and what it opens there, on the service's budget, and serves it by
 * its priority. Without a scheduler service, or a budget for it, or if the server doesn't take it, it's not lent
 * anything.
 *
 * @param supervisor The supervisor, whose system volume the directory is opened on and whose scheduler service is
 *     asked for the budget; it waits for both without handling its port.
 * @param name The directory's name in the root.
 * @param service The service's name, which its CPU budget is asked for under.
 * @return The directory, which moves to the caller; null without a system volume, or if it couldn't be opened.
 */
lent_directory :: fn(supervisor: ptr[mut Supervisor], name: string, service: string) -> os.Channel[dir.Dir]? {
    directory :: system_directory(supervisor, name) or_return null
    if supervisor.scheduler_end != NONE {
        match scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, service) {
            case Some(budget) => _ = lend(supervisor, directory, budget)
            case None => {}
        }
    }
    return directory
}

/**
 * Lend a CPU budget to a dir connection, with Lend, and wait for the answer.
 *
 * @param supervisor The supervisor, whose budget pays for the port the answer is waited on.
 * @param directory The connection, which stays the caller's.
 * @param budget The CPU budget, which moves to the server with the request.
 * @return True if the server answered Done; false otherwise, or if it couldn't be sent.
 */
lend :: fn(supervisor: ptr[mut Supervisor], directory: os.Channel[dir.Dir], budget: slop_os.CpuBudget) -> bool {
    port :: os.port_for(supervisor.block.budget, directory.end) or_return false
    defer _ = slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Lend(budget)
    if dir.send_request(directory.end, port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(directory.end, port, &into, true) {
            case Received => break
            case Failed(error) => return false
            case _ => return false
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case Done => true
        case _ => false
    }
}

/**
 * For test_lending: see the volume server's time on echo's budget, lent it, in the budget's attribution
 * (cpu_budget_describe's lent, decisions/0185, 12h). Echo's is a budget of its own, which the volume server isn't on;
 * hello's is the default, which the server is on too, so what it runs on hello's loans isn't another's.
 *
 * @param supervisor The supervisor, whose scheduler service gives echo's budget.
 */
check_lent_time :: fn(supervisor: ptr[mut Supervisor]) {
    budget :: scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, "echo") or_return void
    defer _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    info :: slop_os.cpu_budget_describe(budget) or_return void
    if info.lent > 0 {
        log_line.write(supervisor.log, "supervisor: test_lending: echo's budget shows what the volume server ran on it")
    }
    else {
        log_line.write(supervisor.log, "supervisor: test_lending: echo's budget shows nothing run on it by others")
    }
}

/** How many connections test_lending makes of the lower priority, each lent hello's budget. */
LENDING_LOW :: 6
/** How many requests test_lending queues through each connection of the lower priority. */
LENDING_BACKLOG :: 4
/** How often test_lending looks for the low ones' answers while it waits for the high one's, in nanoseconds: 1 ms. */
LENDING_POLL : u64 : 1_000_000
/** The most attempts test_lending makes before it gives its last one's outcome. */
LENDING_ATTEMPTS :: 3

/** What one of test_lending's attempts found. */
LendingOutcome :: struct {
    /** How many requests lent hello's budget were answered between the high one's two being sent and answered. */
    ahead : u64,
    /** How many requests lent hello's budget were sent in all. */
    total : u64,
    /** How many of those were still unanswered when the high one's two were sent. */
    waiting : u64,
}

/**
 * Run test_lending, logging what's found: up to LENDING_ATTEMPTS attempts, until one shows priority.
 *
 * Which of its answers came first can't be known through separate connections when the host stalls this CPU for long,
 * so one attempt in which priority showed is enough, as a server taking connections in turn, or serving each queue
 * whole, would answer six or more first in every one. Without a scheduler service it does nothing.
 *
 * @param supervisor The supervisor, which needs a system volume and a scheduler service; its port isn't handled while
 *     the attempts run.
 */
check_lending :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.scheduler_end == NONE {
        return void
    }
    last := LendingOutcome.{}
    for attempt in 0..<LENDING_ATTEMPTS {
        outcome :: lending_attempt(supervisor) or_return void
        last = outcome
        // Perhaps one the server had started on, and one more each for the time between the two through the high one
        if outcome.waiting >= LENDING_LOW && outcome.ahead <= 3 && outcome.total == LENDING_LOW * LENDING_BACKLOG + 2 {
            log_line.write(supervisor.log, "supervisor: test_lending: a request lent echo's budget was answered ahead of the backlogs lent hello's")
            check_lent_time(supervisor)
            return void
        }
    }
    if last.waiting < LENDING_LOW {
        // Too little left waiting to show what's put ahead of what: the host kept this CPU from sending them in time
        log_line.write(supervisor.log, "supervisor: test_lending: inconclusive, only % of % requests still waiting when the lent ones came",
            last.waiting, last.total)
    }
    else {
        log_line.write(supervisor.log, "supervisor: test_lending: % of % requests lent hello's budget were answered first", last.ahead, last.total)
    }
}

/**
 * Make one attempt of test_lending, on a boot disk.
 *
 * Connections are made to the system volume's "lending" directory: one lent echo's CPU budget (the trusted path's is
 * never lent), of a high priority, and LENDING_LOW lent hello's, of the default's. Through the first of those, a change
 * and a Sync, which keeps the volume server committing; behind it, LENDING_BACKLOG requests through each of them; then
 * two through the high one, sent at the supervisor's priority, no higher than the volume server's, so on one CPU it
 * doesn't take them as they come; then the answers ahead of them waited for and counted on echo's budget, so the
 * server, of a lower priority, doesn't go on answering before they're counted. Served by priority, both are answered
 * next, ahead of every backlog; taking connections in turn, as the server would without loans, the second would wait
 * for one of each of the others, and serving each queue whole, for all of them.
 *
 * @param supervisor The supervisor, which needs a scheduler service.
 * @return What the attempt found; null if it couldn't be made: no system volume, no budgets, or a loan refused.
 */
lending_attempt :: fn(supervisor: ptr[mut Supervisor]) -> LendingOutcome? {
    // The high one first, so taking turns would come to it last
    high :: system_directory(supervisor, "lending") or_return null
    high_budget :: scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, "echo") or_return null
    if !lend(supervisor, high, high_budget) {
        log_line.write(supervisor.log, "supervisor: test_lending: the volume server took no loan")
        return null
    }
    high_port :: os.port_for(supervisor.block.budget, high.end) or_return null
    lows : slop_os.Channel[LENDING_LOW]
    low_ports : slop_os.Port[LENDING_LOW]
    for i in 0..<LENDING_LOW {
        low :: system_directory(supervisor, "lending") or_return null
        low_budget :: scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, "hello") or_return null
        if !lend(supervisor, low, low_budget) {
            return null
        }
        lows[i] = low.end
        low_ports[i] = os.port_for(supervisor.block.budget, low.end) or_return null
    }
    // For counting, at echo's priority, above the volume server's own
    mine :: scheduler_protocol.budget_for(supervisor.scheduler_end, supervisor.scheduler_port, "echo") or_return null
    sent : u64[LENDING_LOW]
    for i in 0..<LENDING_LOW {
        count :: if i == 0 { LENDING_BACKLOG + 2 } else { LENDING_BACKLOG }
        for j in 0..<count {
            out := os.Outgoing.{}
            request :: os.begin[dir.Request](&out)
            request^ = if i == 0 && j == 0 { dir.Request.OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "changed"), create = true}) }
                else if i == 0 && j == 1 { dir.Request.Sync } else { dir.Request.Info }
            if dir.send_request(lows[i], low_ports[i], &out) is_none {
                sent[i] += 1
            }
        }
    }
    // What the server answered while they were sent, before there was anything to put ahead of them, isn't counted: a
    // host that stalls this CPU meanwhile leaves the server to go through the backlog alone
    into := os.Incoming.{}
    answered : u64[LENDING_LOW]
    for i in 0..<LENDING_LOW {
        loop {
            match dir.receive_response(lows[i], low_ports[i], &into, false) {
                case Received => answered[i] += 1
                case _ => break
            }
        }
    }
    waiting := cast[u64](0)
    for i in 0..<LENDING_LOW {
        waiting += sent[i] - answered[i]
    }
    // Two through the high one: taking turns, the second would wait for one of every other connection's
    for i in 0..<2 {
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Info
        _ = dir.send_request(high.end, high_port, &out)
    }
    _ = slop_os.thread_use_cpu_budget(mine)
    // What they answered while the two were sent isn't counted either: a host that stalls this CPU between them leaves
    // only the first waiting, which the server answers, then takes the low ones in turn
    for i in 0..<LENDING_LOW {
        loop {
            match dir.receive_response(lows[i], low_ports[i], &into, false) {
                case Received => answered[i] += 1
                case _ => break
            }
        }
    }
    // The low ones' answered before the high one's two, looked for in turn with them: once both are in, what the low
    // ones answer after isn't counted, which another CPU's server, or a host that stalls this one, could answer meanwhile
    high_answers := 0
    ahead := cast[u64](0)
    loop {
        match dir.receive_response(high.end, high_port, &into, false) {
            case Received => {
                high_answers += 1
                continue
            }
            case Failed(error) => return null
            case _ => {}
        }
        if high_answers == 2 {
            break
        }
        for i in 0..<LENDING_LOW {
            loop {
                match dir.receive_response(lows[i], low_ports[i], &into, false) {
                    case Received => {
                        answered[i] += 1
                        ahead += 1
                    }
                    case _ => break
                }
            }
        }
        packets : slop_os.Packet[2]
        _ = slop_os.port_wait(high_port, packets, (slop_os.clock_monotonic() or_else 0) + LENDING_POLL)
    }
    _ = slop_os.thread_use_cpu_budget(cast[slop_os.CpuBudget](slop_os.NO_HANDLE))
    _ = slop_os.handle_close(cast[slop_os.Handle](mine))
    // Then the rest
    total := cast[u64](0)
    for i in 0..<LENDING_LOW {
        total += sent[i]
        loop {
            if answered[i] >= sent[i] {
                break
            }
            match dir.receive_response(lows[i], low_ports[i], &into, true) {
                case Received => answered[i] += 1
                case Failed(error) => break
                case _ => break
            }
        }
    }
    for each in slop_os.Handle.[cast[slop_os.Handle](high.end), cast[slop_os.Handle](high_port)] {
        _ = slop_os.handle_close(each)
    }
    for i in 0..<LENDING_LOW {
        _ = slop_os.handle_close(cast[slop_os.Handle](lows[i]))
        _ = slop_os.handle_close(cast[slop_os.Handle](low_ports[i]))
    }
    return LendingOutcome.{ahead = ahead, total = total, waiting = waiting}
}

/**
 * Open a directory of the system volume's root, made if it isn't there, and wait for it.
 *
 * @param supervisor The supervisor, whose system volume connection it's asked on; its port isn't handled while it
 *     waits.
 * @param name The directory's name in the root.
 * @return The directory, which moves to the caller; null without a system volume, or if it couldn't be opened.
 */
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
            case _ => return null
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case OpenedDirectory(opened) => opened
        case _ => null
    }
}

/**
 * Run test_store, once everything has started, logging what's found.
 *
 * hello's program is put in the bundle store and read back as paged memory, whole, then twice more with only
 * CACHE_TEST_BYTES of pages kept (decisions/0111); one whose bytes don't have the hash given is refused; another object
 * is kept while it's pinned, and collected once it isn't; and hello's bundle's manifest is checked against the schema
 * of its entry's type.
 *
 * @param supervisor The supervisor, whose bundle store is put to, pinned in, collected and told a cache limit, which
 *     is set back to none after; the objects put stay in the store.
 */
check_store :: fn(supervisor: ptr[mut Supervisor]) {
    if supervisor.store_end == NONE {
        log_line.write(supervisor.log, "supervisor: test_store: no bundle store")
        return void
    }
    module :: module_of(supervisor, "hello")
    size :: slop_os.memory_size(module) or_else 0
    program :: match read_copy(module, size) {
        case Some(copy) => copy
        case None => {
            log_line.write(supervisor.log, "supervisor: test_store: hello's program couldn't be read")
            return void
        }
    }
    defer runtime.free_array(program)
    hash :: bundle.hash_of(program)
    put :: put_object(supervisor, hash, program)
    wrong := hash
    wrong.bytes[0] = wrong.bytes[0] ~ 1
    refused :: !put_object(supervisor, wrong, program)
    // Read back through paged memory, every byte
    read_back :: read_whole(supervisor, hash, program)
    // Again, twice, with only CACHE_TEST_BYTES of pages kept, which pressure on the store's budget gives the rest back of
    // (decisions/0111): each page read again once it's given back
    _ = store_request(supervisor, .CacheLimit(CACHE_TEST_BYTES))
    under_pressure :: read_whole(supervisor, hash, program) && read_whole(supervisor, hash, program)
    given_back :: match store_request(supervisor, .Evictions) {
        case Collected(count) => count
        case _ => cast[u64](0)
    }
    _ = store_request(supervisor, .CacheLimit(0))
    // Another object, never read, kept while it's pinned and collected once it isn't
    other :: "an object only a pin keeps"
    other_bytes :: string_bytes(other)
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
    log_line.write(supervisor.log, "supervisor: test_store: with % KiB of pages kept, read hello's program back % twice, % given back under pressure",
        CACHE_TEST_BYTES / 1024, if under_pressure { "whole" } else { "not whole" }, if given_back * 4096 + CACHE_TEST_BYTES >= size { "the rest" } else { "too few" })
    // The manifest the build wrote for hello is the schema of its entry's type, as it's worked out here
    expected :: bundle.Hash.{bytes = schema.hash(type_info_of(type_of(hello.main)))}
    manifest :: stored_hash(supervisor, "hello", 1)
    matches :: match manifest {
        case Some(stored) => bundle.same(stored, expected)
        case None => false
    }
    log_line.write(supervisor.log, "supervisor: test_store: hello's bundle's manifest % its entry's schema", if matches { "is" } else { "isn't" })
}

/** The bytes of objects' pages the bundle store is told to keep in test_store's second reading: 64 KiB. */
CACHE_TEST_BYTES : u64 : 64 * 1024

/**
 * Get an object from the bundle store, read it, every page through its pager, and compare it with bytes, byte for
 * byte.
 *
 * @param supervisor The supervisor, which needs a bundle store; the object's copy is freed and its memory closed
 *     before it returns.
 * @param hash The object's hash, as the store knows it.
 * @param program The bytes it should hold, which stay the caller's.
 * @return True if the store gave it, it could be read, and it's program exactly; false otherwise.
 */
read_whole :: fn(supervisor: ptr[mut Supervisor], hash: bundle.Hash, program: u8[]) -> bool {
    read_back := false
    match store_request(supervisor, .Get(hash)) {
        case Got(object) => {
            if object.size == cast[u64](program.count) {
                match read_copy(object.memory, object.size) {
                    case Some(copy) => {
                        read_back = true
                        for byte, i in program {
                            if i >= copy.count || copy[i] != byte {
                                read_back = false
                                break
                            }
                        }
                        runtime.free_array(copy)
                    }
                    case None => {}
                }
            }
            _ = slop_os.handle_close(cast[slop_os.Handle](object.memory))
        }
        case _ => {}
    }
    return read_back
}

/**
 * Ask the bundle store to collect what nothing keeps.
 *
 * @param supervisor The supervisor, which needs a bundle store; it waits for its answer without handling its port.
 * @return How many objects Collect removed; 99 if it didn't answer with Collected.
 */
collected :: fn(supervisor: ptr[mut Supervisor]) -> u64 {
    return match store_request(supervisor, .Collect) {
        case Collected(count) => count
        case _ => cast[u64](99)
    }
}

/** The most bytes read_copy copies: 4 MiB, more than any program or record the supervisor reads from the store. */
MAX_COPIED : u64 : 4 << 20

/**
 * Copy memory's first bytes to the heap, through memory_read, never mapping it: for memory another process owns, the
 * bundle store's above all, whose ending meanwhile only fails the read (decisions/0098, 0181's F6).
 *
 * @param memory The memory, which stays the caller's.
 * @param size How many bytes to copy from its start; 0, or more than MAX_COPIED, gives null.
 * @return The bytes, from the context's allocator, which the caller frees; null if size is out of bounds, the heap
 *     couldn't hold them, or the memory couldn't be read (gone, or its pager gone).
 */
read_copy :: fn(memory: slop_os.Memory, size: u64) -> u8[]? {
    if size == 0 || size > MAX_COPIED {
        return null
    }
    bytes, made :: runtime.new_array(u8, cast[usize](size))
    if made != null {
        return null
    }
    if !service_kit.read_pages(memory, 0, bytes) {
        runtime.free_array(bytes)
        return null
    }
    return bytes
}

/**
 * Put an object in the bundle store, from a copy of bytes in a memory object of its own, which the store takes.
 *
 * @param supervisor The supervisor, which needs a bundle store, and whose budget pays for the copy until the store
 *     takes it.
 * @param hash The hash the object is to have; the store refuses it if the bytes don't hash to it.
 * @param bytes The bytes, which stay the caller's.
 * @return True if the store answered Done; false if it refused, or the copy couldn't be made.
 */
put_object :: fn(supervisor: ptr[mut Supervisor], hash: bundle.Hash, bytes: u8[]) -> bool {
    size :: (cast[u64](bytes.count) + 4095) & ~cast[u64](4095)
    data :: slop_os.memory_create(supervisor.block.budget, if size == 0 { cast[u64](4096) } else { size }) or_return false
    if slop_os.memory_write(data, 0, bytes) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](data))
        return false
    }
    return match store_request(supervisor, .Put(bundle_store.PutOf.{hash = hash, size = cast[u64](bytes.count), data = data})) {
        case Done => true
        case _ => false
    }
}

/**
 * Send one request to the bundle store on the supervisor's connection, and wait for its answer.
 *
 * @param supervisor The supervisor, which needs a bundle store.
 * @param request The request, which may carry handles that move to the store.
 * @return The store's answer, or what bundle_store.ask gives when it doesn't answer.
 */
store_request :: fn(supervisor: ptr[mut Supervisor], request: bundle_store.Request) -> bundle_store.Response {
    out := os.Outgoing.{}
    made :: os.begin[bundle_store.Request](&out)
    made^ = request
    into := os.Incoming.{}
    return bundle_store.ask(supervisor.store_end, supervisor.store_port, &out, &into)
}

/**
 * Give the system volume's "events" directory, made if it isn't there, to the events service to keep records in.
 *
 * Without an events service or a system volume, or if the directory can't be opened, it does nothing.
 *
 * @param supervisor The supervisor, whose system volume the directory is opened on and whose events service is given
 *     it; it waits for both without handling its port.
 */
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
            case _ => return void
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

/** A connection of the supervisor's own to the events service, on which test_events' query waits. */
Waiting :: struct {
    /** The supervisor's end of the connection; NONE without one. */
    end : slop_os.Channel,
    /** The port its answers wake; not set without one. */
    port : slop_os.Port,
}

/**
 * Start test_events' wait: make a connection of the supervisor's own to the events service, and send a query on it for
 * hello's first record that waits for it, before hello starts.
 *
 * @param supervisor The supervisor, whose events service connection the Connect is sent on, and whose budget pays for
 *     the new channel and its port; nothing in it changes.
 * @return The connection, kept for check_events; its end NONE without an events service, or if anything failed.
 */
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

/**
 * Finish test_events, once everything has started, logging what's found: the held query's answer; hello's first
 * record and the clock service's second, read back from where the events service stores them; and, the clock service
 * started again past its source's smallest budget, that its oldest records were dropped.
 *
 * @param supervisor The supervisor, whose events service is queried, waiting without handling its port.
 * @param waiting The connection wait_for_hello made, whose answer is waited for; with an end of NONE, it's skipped.
 */
check_events :: fn(supervisor: ptr[mut Supervisor], waiting: Waiting) {
    if waiting.end != NONE {
        into := os.Incoming.{}
        loop {
            match events.receive_response(waiting.end, waiting.port, &into, true) {
                case Received => break
                case Failed(error) => break
                case _ => break
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
    /*
     * The clock service started again BUDGET_RESTARTS times, past its source's smallest budget, a pause after each for
     * the events service to store what it wrote apart: so its file's moved aside more than once, and its oldest records
     * are dropped
     */
    for round in 0..<BUDGET_RESTARTS {
        _ = kill_and_wait(supervisor, "clock", "test_events")
        pause(supervisor, BUDGET_PAUSE)
    }
    out := os.Outgoing.{}
    request :: os.begin[events.Request](&out)
    request^ = .Query(events.QueryOf.{source = bytes_of(&out, "clock"), from = 0, level = 0})
    into := os.Incoming.{}
    match events.ask(supervisor.events_end, supervisor.events_port, &out, &into) {
        case Found(found) => log_line.write(supervisor.log, "supervisor: test_events: the clock service's oldest records %",
            if found.number > 0 { "were dropped past its budget" } else { "were kept, though past its budget" })
        case _ => log_line.write(supervisor.log, "supervisor: test_events: no record of the clock service")
    }
}

/** How many times test_events starts the clock service again past its budget: RESTARTS, so it's started each time. */
BUDGET_RESTARTS :: 3
/** How long test_events waits after each, for the events service to store what it wrote, in nanoseconds: 50 ms. */
BUDGET_PAUSE : u64 : 50_000_000

/**
 * Append a string's bytes to an outgoing message, for a field that refers to them.
 *
 * @param out The message being built.
 * @param text The bytes to copy in.
 * @return Where they are in the message, relative to it.
 */
bytes_of :: fn(out: ptr[mut os.Outgoing], text: string) -> slop_os.Relative[u8] {
    return os.append(out, string_bytes(text))
}

/**
 * View bytes as a string, for logging.
 *
 * @param bytes The bytes, as a received message's items; the string views them, so it's good as long as they are.
 * @return The string; empty for no bytes.
 */
text_of_items :: fn(bytes: u8[]) -> string {
    return if bytes.count > 0 { string_of(&bytes[0], bytes.count) } else { "" }
}

/**
 * Work out the entry in started the program launched next is to have, which its end is watched under.
 *
 * @param supervisor The supervisor, whose relaunching and started_count are read; nothing in it changes.
 * @return The entry a restart is launching into, or the next unused one, started_count, which may be MAX_STARTED.
 */
next_slot :: fn(supervisor: ptr[Supervisor]) -> usize {
    return if supervisor.relaunching != NOWHERE { supervisor.relaunching } else { supervisor.started_count }
}

/**
 * Start the clock service, with the real-time clock the platform service gives, the clock page to write, and a
 * listener whose other end the supervisor keeps to set the time, replacing the last one's.
 *
 * It isn't given the clock page read-only as others are, since it doesn't read the time from the page it writes.
 * Without a clock page or a real-time clock it isn't started. Its entry is marked a driver, and the clock service.
 *
 * @param supervisor The supervisor, which needs a clock page and a platform service; its clock_setting and
 *     clock_setting_port are replaced once it's launched, and its entry marked a driver and the clock.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_clock :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "clock") or_return void
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

/**
 * Start the ACPI service (decisions/0182, P3), with a connection of its own to the platform service, dialed through
 * the root task's connector, on which it claims ACPI. Without a platform service it isn't started; where there's no
 * ACPI, it ends at once, and isn't started again.
 *
 * @param supervisor The supervisor, which needs the platform service's connector; its entry is marked a driver and the
 *     ACPI service.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_acpi :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "acpi") or_return void
    if supervisor.platform_connector == NONE {
        return void
    }
    channel :: dial_through(supervisor, supervisor.platform_connector) or_return void
    grants :: AcpiGrants.{platform_service = os.Channel[platform.Platform].{end = channel}, power = power_connection(supervisor, ACPI_POWER)}
    launched := cast[slop_os.Process](slop_os.NO_HANDLE)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        acpi_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(made) => launched = kept(supervisor, made)
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](channel))
            return void
        }
    }
    slot :: place(supervisor, "acpi", launched, again)
    if slot >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[slot]
    entry.driver = true
    entry.acpi = true
}

/**
 * Start the GPIO power button's driver (decisions/0182, P3), with a platform connection of its own, on which it claims
 * the button, and its power connection. Where there's no such button, it ends at once, and isn't started again.
 *
 * @param supervisor The supervisor, which needs the platform service's connector; its entry is marked a driver and the
 *     button's.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_power_button :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "power_button") or_return void
    if supervisor.platform_connector == NONE {
        return void
    }
    channel :: dial_through(supervisor, supervisor.platform_connector) or_return void
    grants :: PowerButtonGrants.{platform_service = os.Channel[platform.Platform].{end = channel}, power = power_connection(supervisor, GPIO_POWER)}
    launched := cast[slop_os.Process](slop_os.NO_HANDLE)
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, service.name), service.budget,
        power_button.main, grants, options_for(supervisor, service.name)) {
        case Ok(made) => launched = kept(supervisor, made)
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](channel))
            return void
        }
    }
    slot :: place(supervisor, "power_button", launched, again)
    if slot >= supervisor.started.count {
        return void
    }
    entry :: &supervisor.started[slot]
    entry.driver = true
    entry.power_button = true
}

/**
 * Find a service's program.
 *
 * One outside the boot set comes from the bundle store or the system volume, read once and kept, once the storage
 * manager has given the system volume; otherwise, or where it isn't there, it's the bootloader's module.
 *
 * @param supervisor The supervisor, whose loaded may take a program read from the bundle store or the system volume,
 *     waiting for them without handling its port; its bootloader modules stay as they are.
 * @param name The service's name, as the system configuration has it; a boot set module is found by the name alone.
 * @return The program, which stays the supervisor's; NO_HANDLE if there's none for name.
 */
module_of :: fn(supervisor: ptr[mut Supervisor], name: string) -> slop_os.Memory {
    service :: service_named(supervisor, name)
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
        else if name == "terminal" { modules.terminal } else if name == "echo" { modules.echo } else if name == "input" { modules.input }
        else if name == "sessions" { modules.sessions }
        else if name == "disk_check" { modules.disk_check }
        else if name == "hello" { modules.hello } else if name == "clock" { modules.clock } else if name == "acpi" { modules.acpi }
        else if name == "power_button" { modules.power_button }
        else if name == "events" { modules.events } else if name == "bundle_store" { modules.bundle_store }
        else if name == "config" { modules.config } else if name == "update" { modules.update }
        else { cast[slop_os.Memory?](null) }
    return found or_else none
}

/**
 * Get the program a service's module names, kept in loaded once it's got.
 *
 * It comes from the bundle store, the program of the bundle its boot root names after the module, as paged memory,
 * which processes running it share; or, without one, read from the system volume's modules folder. Where it came from
 * is logged.
 *
 * @param supervisor The supervisor, which needs a system volume; its loaded keeps the program from now on, and its
 *     records give the service's place.
 * @param service The service, as service_at reads it, whose name finds its place and whose module its program.
 * @return The program, which stays the supervisor's; null if it's in neither, or the service's place is past
 *     MAX_LOADED.
 */
loaded_module :: fn(supervisor: ptr[mut Supervisor], service: Service) -> slop_os.Memory? {
    place :: system_records.index_of(supervisor.records, service.name)
    loaded :: &supervisor.loaded
    if place >= loaded.count {
        return null
    }
    match loaded[place].module {
        case Some(module) => {
            if !loaded[place].from_store || is_alive(module) {
                return module
            }
            /*
             * Gone with the store that gave it, whose end may not have been handled yet (forget_stored), as when a
             * service it paged faults first: got again, from the system volume if the store isn't back yet.
             */
            log_line.write(supervisor.log, "supervisor: %'s program went with the bundle store; getting it again", service.name)
            _ = slop_os.handle_close(cast[slop_os.Handle](module))
            loaded[place] = Loaded.{}
        }
        case None => {}
    }
    from_store :: stored_program(supervisor, service.module)
    module :: from_store or_else (read_module(supervisor, service.module) or_return null)
    if place < loaded.count {
        loaded[place] = Loaded.{module = module, from_store = from_store is_some}
    }
    log_line.write(supervisor.log, "supervisor: % from the %", service.name, if from_store is_some { "bundle store" } else { "system volume" })
    return module
}

/**
 * Tell whether a program's memory is still there to launch from: the bundle store's paged memory is destroyed with
 * the store (decisions/0094), and then can't be duplicated, as a launch has to.
 *
 * @param module The program, which stays the caller's.
 * @return Whether a read-only copy of its handle could be made; the copy is closed before it returns.
 */
is_alive :: fn(module: slop_os.Memory) -> bool {
    match slop_os.handle_duplicate(cast[slop_os.Handle](module), slop_os.RIGHT_MEMORY_READ) {
        case Ok(copy) => {
            _ = slop_os.handle_close(copy)
            return true
        }
        case Error(error) => return false
    }
}

/**
 * Get the program the bundle store's boot root names after a module, without its extension, as the store gives it.
 *
 * @param supervisor The supervisor, whose bundle store and boot root are asked; nothing in it changes.
 * @param module The module's name, its extension dropped.
 * @return The program, paged memory, read and execute only, which moves to the caller; null without a store, a root,
 *     or a bundle of that name.
 */
stored_program :: fn(supervisor: ptr[mut Supervisor], module: string) -> slop_os.Memory? {
    name := module
    for character, i in module {
        if character == '.' {
            name = module[0..<i]
            break
        }
    }
    program :: stored_hash(supervisor, name, 0) or_return null
    return match store_request(supervisor, .Get(program)) {
        case Got(object) => object.memory
        case _ => null
    }
}

/**
 * Find what a bundle the store's root names refers to, by its place.
 *
 * The root is the booted generation's, boot_root, or without one, the store's own.
 *
 * @param supervisor The supervisor, whose bundle store is asked, waiting without handling its port; the root and
 *     bundle copied are let go of before it returns.
 * @param name The bundle's name in the root.
 * @param which The place of what's wanted in the bundle's references: 0 its program, 1 its manifest.
 * @return Its hash; null without a store, a root, a bundle of that name, or a reference at which.
 */
stored_hash :: fn(supervisor: ptr[mut Supervisor], name: string, which: usize) -> bundle.Hash? {
    if supervisor.store_end == NONE {
        return null
    }
    // The root the booted generation names, or without one, the store's own
    root := bundle.Hash.{}
    match supervisor.boot_root {
        case Some(given) => root = given
        case None => match store_request(supervisor, .Root) {
            case Rooted(hash) => root = hash
            case _ => return null
        }
    }
    found := bundle.Hash.{}
    have := false
    root_object :: stored_object(supervisor, root) or_return null
    names : string[..]
    defer runtime.array_free(&names)
    bundles : bundle.Hash[..]
    defer runtime.array_free(&bundles)
    if bundle.root_entries(root_object.bytes, &names, &bundles) or_else false {
        for entry_name, i in names {
            if entry_name == name && i < bundles.count {
                match stored_object(supervisor, bundles[i]) {
                    case Some(record) => {
                        referred : bundle.Hash[..]
                        if (bundle.bundle_refers(record.bytes, &referred) or_else false) && which < referred.count {
                            found = referred[which]
                            have = true
                        }
                        runtime.array_free(&referred)
                        let_go_of_object(record)
                    }
                    case None => {}
                }
                break
            }
        }
    }
    let_go_of_object(root_object)
    return if have { found } else { null }
}

/** An object of the bundle store's, copied to the supervisor's heap to read; let go of with let_go_of_object. */
StoredObject :: struct {
    /** Its bytes, its size of them, from the context's allocator, good until let_go_of_object. */
    bytes : u8[],
}

/**
 * Get an object from the bundle store and copy it to the heap, never mapping it, so the store ending meanwhile gives
 * null rather than a fault (decisions/0098, 0181's F6). The store's memory is closed before it returns.
 *
 * @param supervisor The supervisor, which needs a bundle store.
 * @param hash The object's hash, as the store knows it.
 * @return The object, which the caller lets go of with let_go_of_object; null if the store didn't give it, or it
 *     couldn't be read (read_copy).
 */
stored_object :: fn(supervisor: ptr[mut Supervisor], hash: bundle.Hash) -> StoredObject? {
    object :: match store_request(supervisor, .Get(hash)) {
        case Got(got) => got
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](object.memory))
    bytes :: read_copy(object.memory, object.size) or_return null
    return StoredObject.{bytes = bytes}
}

/**
 * Let go of an object stored_object gave: free its bytes.
 *
 * @param object The object, whose bytes aren't to be read after.
 */
let_go_of_object :: fn(object: StoredObject) {
    runtime.free_array(object.bytes)
}

/**
 * Read modules/<module> on the system volume whole into a memory object of its own.
 *
 * The memory is given to the volume server as the read's buffer, so the file comes straight into it.
 *
 * @param supervisor The supervisor, which needs a system volume.
 * @param module The module's file name; the path is cut short past 256 bytes.
 * @return The program, which moves to the caller; null if it isn't there, is empty or bigger than MAX_MODULE_BYTES, or
 *     couldn't be read whole.
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
    opening^ = .OpenReadOnlyFile(os.append(&out, string_bytes(text)))
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

/** The most bytes a program read from the system volume may be: 8 MiB. */
MAX_MODULE_BYTES : u64 : 8 << 20

/**
 * Send one request to the system volume's server on its dir connection, and wait for its answer.
 *
 * @param end A connection to a directory of the system volume, which stays the caller's.
 * @param port A port end is bound to, which its answers wake.
 * @param out The request, built with os.begin; its handles move to the server once it's sent.
 * @param into Where the answer is received; the result's views of it are good as long as it is.
 * @return The server's answer; Unsupported if it couldn't be sent or the connection failed.
 */
ask_system_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Send one request on a program's read-only file connection, and wait for its answer.
 *
 * @param end A read-only file connection, as OpenReadOnlyFile gives, which stays the caller's.
 * @param port A port end is bound to, which its answers wake.
 * @param out The request, built with os.begin; its handles move to the server once it's sent.
 * @param into Where the answer is received; the result's views of it are good as long as it is.
 * @return The server's answer; Unsupported if it couldn't be sent or the connection failed.
 */
ask_system_file :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_file.Response {
    if read_only_file.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_file.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_file.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Start every driver the supervisor starts, in the boot set or out of it, one for every device it takes.
 *
 * Devices are claimed from the platform service until it gives no more for the driver. Without a platform service it
 * does nothing.
 *
 * @param supervisor The supervisor, whose platform service is asked for devices, waiting without handling its port;
 *     each driver started gets a new entry.
 * @param boot_set True for the boot set's drivers; false for the others.
 */
start_drivers :: fn(supervisor: ptr[mut Supervisor], boot_set: bool) {
    if cast[slop_os.Handle](supervisor.platform_end) == slop_os.NO_HANDLE {
        return void
    }
    for index in cast[usize](0)..<system_records.MAX_SERVICES {
        each :: service_at(supervisor, index) or_break
        if !is_driver(each) || each.starter != system_records.STARTER_SUPERVISOR || each.boot_set != boot_set {
            continue
        }
        loop {
            device :: request_device(supervisor, .Claim(platform.Wanted.{devices = each.devices, trusted = each.trusted_with_dma})) or_break
            start_driver(supervisor, index, device, NOWHERE)
        }
    }
}

/**
 * Start the input service, with connectors to the first four input devices and the kernel's command line (for
 * test_new_keyboards), and a listener for its client, the terminal service, whose other end the supervisor keeps.
 *
 * @param supervisor The supervisor, which serves a new connector for each input device given; once it's launched,
 *     its entry keeps the listener's end and input is set to it.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_input :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "input") or_return void
    pair :: os.channel_for[seat.Seat](supervisor.block.budget, 0) or_return void
    keyboards : MaybeConnector[4]
    found : usize = 0
    for entry, i in supervisor.started {
        if i < supervisor.started_count && entry.speaks == .Input && found < keyboards.count {
            keyboards[found] = connector_to(supervisor, i)
            found += 1
        }
    }
    grants := InputGrants.{log = duplicate_log(supervisor), keyboard0 = keyboards[0], keyboard1 = keyboards[1],
        keyboard2 = keyboards[2], keyboard3 = keyboards[3], clients = os.Listener[seat.Seat].{end = pair.a}}
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
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "input"), service.budget,
        input_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            slot :: place(supervisor, "input", kept(supervisor, launched), again)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.started[slot].speaks = .Seat
                supervisor.input = slot
            }
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/**
 * Start the terminal service, with connectors to the first serial line, the input service and the account service,
 * a connection to the session manager, the framebuffer if there's one, the boot before's panic record, and a listener
 * for its clients, whose other end the supervisor keeps.
 *
 * The framebuffer is claimed again each time, since what it held died with the last terminal service.
 *
 * @param supervisor The supervisor, which serves new connectors for what it's given and claims the framebuffer; once
 *     it's launched, its entry keeps the listener's end and terminal is set to it.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_terminal :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "terminal") or_return void
    pair :: os.channel_for[terminal.Terminal](supervisor.block.budget, terminal.RING_BYTES) or_return void
    grants := TerminalGrants.{log = duplicate_log(supervisor), serial_line = connector_to(supervisor, supervisor.first_serial),
        input = connector_to(supervisor, supervisor.input), accounts_service = connector_to(supervisor, supervisor.accounts),
        clients = os.Listener[terminal.Terminal].{end = pair.a}}
    // A connection to the session manager (decisions/0150), and the boot before's panic record
    grants.programs = session_connection(supervisor)
    grants.power = power_connection(supervisor)
    match supervisor.last_panic {
        case Some(record) => {
            rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
            match slop_os.handle_duplicate(cast[slop_os.Handle](record), rights) {
                case Ok(copy) => grants.last_panic = cast[slop_os.Memory](copy)
                case Error(error) => {}
            }
        }
        case None => {}
    }
    // The framebuffer, claimed again each time, since what it held died with the last terminal service
    match request_framebuffer(supervisor) {
        case Some(framebuffer) => {
            grants.framebuffer = framebuffer.pixels
            grants.framebuffer_layout = framebuffer.layout
        }
        case None => {}
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "terminal"), service.budget,
        terminal_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            slot :: place(supervisor, "terminal", kept(supervisor, launched), again)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.started[slot].speaks = .Terminal
                supervisor.terminal = slot
            }
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}


/**
 * Start hello, one of the console's programs, with a connector to the terminal service, and connections to the
 * process manager, the entropy service and its settings in the config store.
 *
 * The first time, how long the launch took is logged as the program_start benchmark (decisions/0112).
 *
 * @param supervisor The supervisor, which serves a new connector to its terminal service for it; once it's launched,
 *     its entry is marked one of the console's.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_hello :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "hello") or_return void
    grants := HelloGrants.{console = connector_to(supervisor, supervisor.terminal)}
    grants.manager = process_manager.connect(supervisor.manager.end, supervisor.manager_port, supervisor.block.budget)
    grants.entropy_service = entropy_connection(supervisor)
    grants.settings = config_for[hello.HelloSettings](supervisor, "hello", "settings")
    // A benchmark (decisions/0112), the first time: a program's start, from the bundle store to its process loaded
    started :: slop_os.clock_monotonic() or_else 0
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "hello"), service.budget, hello.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            if again == NOWHERE {
                log_line.write(supervisor.log, "supervisor: perf: program_start %", (slop_os.clock_monotonic() or_else 0) - started)
            }
            mark_console(supervisor, place(supervisor, "hello", kept(supervisor, launched), again))
        }
        case Error(error) => failed(supervisor, service.name, error)
    }
}

/**
 * Start the storage manager, when there's a disk, with a connector to each of the first four disks' drivers, a
 * connector to the process manager, copies of the partition, FAT, container and volume servers' modules, the kernel's
 * command line, and a listener for its clients, whose other end the supervisor keeps.
 *
 * @param supervisor The supervisor, which needs first_disk and the four server modules, copies of which are given;
 *     it serves new connectors for each disk and the process manager, and its entry keeps the listener's end.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 * @return Its index in started; NOWHERE without a disk, any of the modules, or a connector to the process manager, or
 *     if the launch failed.
 */
start_storage :: fn(supervisor: ptr[mut Supervisor], again: usize) -> usize {
    if supervisor.first_disk == NOWHERE {
        return NOWHERE
    }
    service :: service_named(supervisor, "storage_manager") or_return NOWHERE
    module :: supervisor.modules.partition_server or_return NOWHERE
    fat_module :: supervisor.modules.fat_server or_return NOWHERE
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    partition_server := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](module), rights) or_return NOWHERE)
    fat_server := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](fat_module), rights) or_return NOWHERE)
    container_module :: supervisor.modules.container_service or_return NOWHERE
    volume_module :: supervisor.modules.volume_server or_return NOWHERE
    container_service := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](container_module), rights) or_return NOWHERE)
    volume_server := cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](volume_module), rights) or_return NOWHERE)
    manager :: connector_to(supervisor, MANAGER_TARGET) or_return NOWHERE
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
            // To duplicate too, for the partition servers it starts (decisions/0112)
            text_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER)
                | cast[u32](slop_os.RIGHT_DUPLICATE))
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

/**
 * Open the files of the first partition of a type the storage manager has, through a connection of the supervisor's
 * own, closed after.
 *
 * It's waited for on the supervisor's port, which goes on handling what arrives, connectors' Dials among it, as the
 * storage manager dials its disks through them before it answers. The first 32 partitions are looked at.
 *
 * @param supervisor The supervisor, whose port is handled while it waits, under STORAGE_KEY for the answers, which is
 *     unbound before it returns.
 * @param storage_slot The storage manager's index in started.
 * @param kind The partition type's GUID, as storage_manager.ESP_TYPE for an EFI system partition's root or
 *     storage_manager.CONTAINER_TYPE for a SlopOS container's system volume's.
 * @return The root, which moves to the caller; null if the storage manager isn't running, has no partition of that
 *     type, or didn't open it.
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

/**
 * Send one request to the storage manager on a connection of its own, closed after, and wait for its answer, handling
 * what arrives on the supervisor's port meanwhile.
 *
 * @param supervisor The supervisor, whose port is handled while it waits, under STORAGE_KEY for the answer, which is
 *     unbound before it returns.
 * @param storage_slot The storage manager's index in started.
 * @param request The request, which carries no handles, as Describe, OpenFiles or TestRestart.
 * @return The storage manager's answer; Unsupported if it isn't running, or the request failed.
 */
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

/**
 * Send one request to the storage manager, and wait for its answer, handling what arrives on the supervisor's port
 * meanwhile.
 *
 * @param supervisor The supervisor, whose port end is bound to and is handled while it waits; its entries and
 *     connections may change meanwhile.
 * @param end A connection to the storage manager, bound to the supervisor's port under STORAGE_KEY.
 * @param request The request, which carries no handles, as Describe or OpenFiles.
 * @return The storage manager's answer; Unsupported if it couldn't be sent or the connection failed.
 */
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

/**
 * Start the account service, with a connector to the storage manager and a listener for its clients, whose other end
 * the supervisor keeps.
 *
 * It's started only if there's a system volume, which its accounts volume is beside and its program comes from.
 *
 * @param supervisor The supervisor, which needs first_disk and a system volume, and serves a new connector to the
 *     storage manager for it; once it's launched, its entry keeps the listener's end and accounts is set to it.
 * @param storage_slot The storage manager's index in started, or NOWHERE without one.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_accounts :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize, again: usize) {
    if supervisor.first_disk == NOWHERE || storage_slot == NOWHERE || supervisor.system == NONE {
        return void
    }
    service :: service_named(supervisor, "accounts") or_return void
    pair :: os.channel_for[accounts.Accounts](supervisor.block.budget, 0) or_return void
    grants := AccountGrants.{log = duplicate_log(supervisor), storage_service = connector_to(supervisor, storage_slot),
        clients = os.Listener[accounts.Accounts].{end = pair.a}}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "accounts"), service.budget,
        account_service.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            slot :: place(supervisor, "accounts", kept(supervisor, launched), again)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.started[slot].speaks = .Accounts
                supervisor.accounts = slot
            }
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/**
 * Start the session manager (decisions/0150), with a connector to the process manager, echo's program, which it
 * starts in each session, a listener for the terminal service, and what it runs the system's installations with
 * (0153): the bundle store, the system volume's apps directory, and the system's list.
 *
 * It's given the config store's connection for users' values, which is the session manager's from then on.
 *
 * @param supervisor The supervisor, whose config_users moves to it, NONE after; it serves a new connector to the
 *     process manager for it, and once it's launched, its entry keeps the listener's end and sessions is set to it.
 * @param again The entry it's started again into, or NOWHERE for a first start.
 */
start_sessions :: fn(supervisor: ptr[mut Supervisor], again: usize) {
    service :: service_named(supervisor, "sessions") or_return void
    manager :: connector_to(supervisor, MANAGER_TARGET) or_return void
    pair :: os.channel_for[session.Session](supervisor.block.budget, 0) or_return void
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    echo_module : slop_os.Memory? = null
    match slop_os.handle_duplicate(cast[slop_os.Handle](module_of(supervisor, "echo")), rights) {
        case Ok(copy) => echo_module = cast[slop_os.Memory](copy)
        case Error(error) => {}
    }
    grants := SessionGrants.{log = duplicate_log(supervisor), manager = manager, echo_module = echo_module,
        events_service = events_connection(supervisor), store = store_connection(supervisor), apps = system_directory(supervisor, "apps"),
        installation_list = installations_for_sessions(supervisor), command_line = command_line_copy(supervisor),
        clients = os.Listener[session.Session].{end = pair.a}}
    // Its budget to split for each session (decisions/0187)
    if supervisor.scheduler_end != NONE {
        grants.cpu_budget = scheduler_protocol.splittable_budget_for(supervisor.scheduler_end, supervisor.scheduler_port, service.name)
    }
    // The config store's connection for users' values, the session manager's from now on
    if supervisor.config_users != NONE {
        grants.settings = os.Channel[config_protocol.ConfigValue].{end = supervisor.config_users}
        supervisor.config_users = NONE
    }
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "sessions"), service.budget,
        session_manager.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => {
            slot :: place(supervisor, "sessions", kept(supervisor, launched), again)
            if slot < supervisor.started.count {
                supervisor.started[slot].listener = pair.b
                supervisor.sessions = slot
            }
        }
        case Error(error) => {
            failed(supervisor, service.name, error)
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        }
    }
}

/**
 * Make a new connection to the events service, for a service that opens rings for the programs it starts; its one end
 * is sent to the events service with Connect.
 *
 * @param supervisor The supervisor, whose events service connection the Connect is sent on, and whose budget pays for
 *     the new channel; nothing in it changes.
 * @return The other end, which moves to the caller; null without an events service, or if the Connect couldn't be
 *     sent.
 */
events_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[events.Events]? {
    if supervisor.events_end == NONE {
        return null
    }
    pair :: os.channel_for[events.Events](supervisor.block.budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[events.Request](&out)
    request^ = .Connect(os.Channel[events.Events].{end = pair.a})
    if events.send_request(supervisor.events_end, supervisor.events_port, &out) != null {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return os.Channel[events.Events].{end = pair.b}
}

/**
 * Make a new connection to the session manager, through its listener, for the terminal service.
 *
 * @param supervisor The supervisor, whose session manager's listener is connected through; nothing in it changes.
 * @return The connection, which moves to the caller; null if the session manager isn't running, or the Connect failed.
 */
session_connection :: fn(supervisor: ptr[mut Supervisor]) -> os.Channel[session.Session]? {
    if supervisor.sessions >= supervisor.started.count || !supervisor.started[supervisor.sessions].running {
        return null
    }
    listener :: supervisor.started[supervisor.sessions].listener
    if cast[slop_os.Handle](listener) == slop_os.NO_HANDLE {
        return null
    }
    port :: os.port_for(supervisor.block.budget, listener) or_return null
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    return session.connect(listener, port, supervisor.block.budget)
}

/**
 * Start the disk check, when there's a disk, with a connector to the storage manager, the first EFI system partition's
 * root as its working directory, and the system volume's root.
 *
 * It isn't started again when it ends.
 *
 * @param supervisor The supervisor, which needs first_disk; it serves a new connector to the storage manager for it,
 *     and the disk check gets a new entry.
 * @param storage_slot The storage manager's index in started, or NOWHERE without one.
 */
start_disk_check :: fn(supervisor: ptr[mut Supervisor], storage_slot: usize) {
    if supervisor.first_disk == NOWHERE || storage_slot == NOWHERE {
        return void
    }
    service :: service_named(supervisor, "disk_check") or_return void
    grants := DiskCheckGrants.{log = duplicate_log(supervisor), storage = connector_to(supervisor, storage_slot),
        working_directory = files_of_type(supervisor, storage_slot, storage_manager.ESP_TYPE),
        system = files_of_type(supervisor, storage_slot, storage_manager.CONTAINER_TYPE)}
    match os.launch(supervisor.manager, supervisor.manager_port, service.name, module_of(supervisor, "disk_check"), service.budget,
        disk_check.main, grants, options_for(supervisor, service.name)) {
        case Ok(launched) => _ = started(supervisor, "disk_check", kept(supervisor, launched))
        case Error(error) => failed(supervisor, service.name, error)
    }
}

/**
 * Make a connector to what's started at target, which the supervisor serves: each Dial on it is answered with a new
 * connection to whatever runs there then.
 *
 * Its end is bound to the supervisor's port, and anything already on it served.
 *
 * @param supervisor The supervisor, whose connectors and connector_count grow by one, the new one bound to its port
 *     under CONNECTOR_KEY plus its index and served from then on.
 * @param target What it dials: an index in started, or MANAGER_TARGET.
 * @return The client's end, which moves to the caller; null if target is NOWHERE, MAX_CONNECTORS have been made, or it
 *     couldn't be made.
 */
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

/**
 * Make a power connection (decisions/0180, 0182): the terminal service's, or that of what brings the power button,
 * the supervisor's end in place of the last one's, bound under POWER_KEY plus its slot.
 *
 * @param supervisor The supervisor, whose end in that slot is replaced, the one before closed.
 * @param slot CONSOLE_POWER, the terminal service's; ACPI_POWER; or GPIO_POWER.
 * @return The other end, which moves to whoever it's for at its launch; null if the channel or binding couldn't be
 *     had, and then the supervisor has none.
 */
power_connection :: fn(supervisor: ptr[mut Supervisor], slot: u32 = CONSOLE_POWER) -> os.Channel[power_protocol.Power]? {
    key :: POWER_KEY + cast[u64](slot)
    match power_end(supervisor, slot) {
        case Some(old) => {
            _ = slop_os.port_unbind(supervisor.port, key)
            _ = slop_os.handle_close(cast[slop_os.Handle](old))
        }
        case None => {}
    }
    set_power_end(supervisor, slot, null)
    pair :: os.channel_for[power_protocol.Power](supervisor.block.budget, 0) or_return null
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if slop_os.port_bind(supervisor.port, cast[slop_os.Handle](pair.b), signals, key, .Persistent) is_error {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    set_power_end(supervisor, slot, pair.b)
    return os.Channel[power_protocol.Power].{end = pair.a}
}

/**
 * The supervisor's end of a power connection.
 *
 * @param supervisor The supervisor.
 * @param slot CONSOLE_POWER, ACPI_POWER or GPIO_POWER.
 * @return The end; null for none.
 */
power_end :: fn(supervisor: ptr[Supervisor], slot: u32) -> slop_os.Channel? {
    if slot == CONSOLE_POWER {
        return supervisor.power
    }
    at :: cast[usize](slot - 1)
    if slot == 0 || at >= supervisor.buttons.count || supervisor.buttons[at] == NONE {
        return null
    }
    return supervisor.buttons[at]
}

/**
 * Keep, or forget, the supervisor's end of a power connection.
 *
 * @param supervisor The supervisor.
 * @param slot CONSOLE_POWER, ACPI_POWER or GPIO_POWER.
 * @param end The end; null to forget it.
 */
set_power_end :: fn(supervisor: ptr[mut Supervisor], slot: u32, end: slop_os.Channel?) {
    if slot == CONSOLE_POWER {
        supervisor.power = end
        return void
    }
    at :: cast[usize](slot - 1)
    if slot != 0 && at < supervisor.buttons.count {
        supervisor.buttons[at] = end or_else NONE
    }
}

/**
 * Answer what's asked on both power connections, the terminal service's and the button's.
 *
 * @param supervisor The supervisor.
 */
serve_power :: fn(supervisor: ptr[mut Supervisor]) {
    for slot in u32.[CONSOLE_POWER, ACPI_POWER, GPIO_POWER] {
        serve_power_on(supervisor, slot)
    }
}

/**
 * Answer what's asked on a power connection, until it's empty: ShutDown, PowerButton and Restart stop every service the
 * supervisor started, gracefully, the volumes committed (stop_everything), then are passed on to the root task, and
 * answered Done, or Refused if they couldn't be; once any's asked, all are Done. A connection whose channel failed is
 * closed.
 *
 * @param supervisor The supervisor, whose end is read, and closed and forgotten once it's gone.
 * @param slot CONSOLE_POWER, ACPI_POWER or GPIO_POWER.
 */
serve_power_on :: fn(supervisor: ptr[mut Supervisor], slot: u32) {
    end :: power_end(supervisor, slot) or_return void
    into := os.Incoming.{}
    loop {
        match power_protocol.receive_request(end, supervisor.port, &into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = power_protocol.answer_unsupported(end, supervisor.port)
                continue
            }
            case _ => {
                _ = slop_os.port_unbind(supervisor.port, POWER_KEY + cast[u64](slot))
                _ = slop_os.handle_close(cast[slop_os.Handle](end))
                set_power_end(supervisor, slot, null)
                return void
            }
        }
        out := os.Outgoing.{}
        response :: os.begin[power_protocol.Response](&out)
        asked :: os.message_of[power_protocol.Request](&into)^
        // A trace connection, for the terminal service's only, once an administrator's allowed it (system_trace.hsc)
        tracing :: match asked {
            case TraceConnection => true
            case _ => false
        }
        // An events connection, the terminal service's only too, once an administrator's allowed reading the log
        reading :: match asked {
            case EventsConnection => true
            case _ => false
        }
        if reading {
            given : os.Channel[events.Events]? = if slot == CONSOLE_POWER { admin_events_connection(supervisor) } else { null }
            match given {
                case Some(connection) => response^ = .EventsConnection(connection)
                case None => response^ = .Refused
            }
            _ = power_protocol.send_response(end, supervisor.port, &out)
            continue
        }
        if tracing {
            given : os.Channel[trace.Trace]? = if slot == CONSOLE_POWER { trace_connection(supervisor) } else { null }
            match given {
                case Some(connection) => response^ = .TraceConnection(connection)
                case None => response^ = .Refused
            }
            _ = power_protocol.send_response(end, supervisor.port, &out)
            continue
        }
        restart :: match asked {
            case Restart => true
            case _ => false
        }
        pressed :: match asked {
            case PowerButton => true
            case _ => false
        }
        // Once: committing waits, handling the port, which can read this connection again
        if supervisor.shutting_down {
            response^ = .Done
            _ = power_protocol.send_response(end, supervisor.port, &out)
            continue
        }
        supervisor.shutting_down = true
        log_line.write(supervisor.log, if pressed { "supervisor: the power button was pressed" } else if restart { "supervisor: the console asked to restart" }
            else { "supervisor: the console asked to shut down" })
        // Every service stopped, the last started first, the volumes committed before the storage manager stops
        stop_everything(supervisor)
        asking := os.Outgoing.{}
        report :: os.begin[supervision.Request](&asking)
        report^ = if restart { supervision.Request.Restart } else { supervision.Request.ShutDown }
        told :: supervision.send_request(supervisor.root, supervisor.root_port, &asking) is_none
        response^ = if told { power_protocol.Response.Done } else { power_protocol.Response.Refused }
        _ = power_protocol.send_response(end, supervisor.port, &out)
    }
}

/**
 * Answer every Dial waiting on a connector, until it's empty: each with a new connection to its target, or
 * Unavailable if it isn't running.
 *
 * A request it doesn't know is answered Unsupported. A connector whose channel failed, as when its client is gone, is
 * closed, and its end set to NONE.
 *
 * @param supervisor The supervisor, whose connector's dials grow with each Dial answered with a connection.
 * @param index The connector's index in connectors; out of range, or closed, does nothing.
 */
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
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](record.end))
                supervisor.connectors[index].end = NONE
                return void
            }
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

/**
 * Wait, on a port of its own, without handling what arrives on the supervisor's port meanwhile.
 *
 * @param supervisor The supervisor, whose budget pays for the port.
 * @param nanoseconds How long to wait, in nanoseconds; it doesn't wait if no port can be made.
 */
pause :: fn(supervisor: ptr[mut Supervisor], nanoseconds: u64) {
    waiter :: slop_os.port_create(supervisor.block.budget) or_return void
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, (slop_os.clock_monotonic() or_else 0) + nanoseconds)
    _ = slop_os.handle_close(cast[slop_os.Handle](waiter))
}

/**
 * Count how many times connectors have dialed what's started at target.
 *
 * @param supervisor The supervisor, whose connectors in use are read; nothing in it changes.
 * @param target An index in started.
 * @return The Dials answered with a connection, over every connector to target.
 */
dials_of :: fn(supervisor: ptr[Supervisor], target: usize) -> u32 {
    dials : u32 = 0
    for each, i in supervisor.connectors {
        if i < supervisor.connector_count && each.target == target {
            dials += each.dials
        }
    }
    return dials
}

/**
 * Tell whether what's started at index is running now.
 *
 * @param supervisor The supervisor, whose entry is read; nothing in it changes.
 * @param index An index in started, or NOWHERE.
 * @return True if it's running; false if it isn't, or index is out of range.
 */
is_running :: fn(supervisor: ptr[Supervisor], index: usize) -> bool {
    return index < supervisor.started.count && supervisor.started[index].running
}

/**
 * Make a new connection to what's started at target, through its listener with its protocol's Connect.
 *
 * The process manager is dialed through the root task's connector instead.
 *
 * @param supervisor The supervisor, whose entry's listener, or process manager connector, is dialed, waiting without
 *     handling its port; nothing in it changes.
 * @param target An index in started, or MANAGER_TARGET.
 * @return The connection, which moves to the caller; null if it isn't running, has no listener, or the Connect failed.
 */
dial :: fn(supervisor: ptr[mut Supervisor], target: usize) -> slop_os.Channel? {
    // The process manager, through the root task's connector to it
    if target == MANAGER_TARGET {
        return dial_through(supervisor, supervisor.manager_connector)
    }
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
        case .Terminal => (terminal.connect(entry.listener, port, budget) or_return null).end
        case .Seat => (seat.connect(entry.listener, port, budget) or_return null).end
        case .Storage => (storage.connect(entry.listener, port, budget) or_return null).end
        case .Accounts => (accounts.connect(entry.listener, port, budget) or_return null).end
        case .Nothing => null
    }
}

/**
 * Claim the real-time clock from the platform service, made anew each time, and wait for it.
 *
 * @param supervisor The supervisor, whose platform service connection it's asked on; its port isn't handled while it
 *     waits.
 * @return The clock's ports or registers, which move to the caller; null without a platform service, or if it has no
 *     clock to give.
 */
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
            case _ => return null
        }
    }
    return match os.message_of[platform.Response](&into)^ {
        case ClaimedClock(clock) => clock
        case _ => null
    }
}

/**
 * Mark what's started at slot as one of the console's programs, which the trusted path lists and may end.
 *
 * @param supervisor The supervisor, whose entry at slot is marked console.
 * @param slot An index in started; MAX_STARTED or past it does nothing.
 */
mark_console :: fn(supervisor: ptr[mut Supervisor], slot: usize) {
    if slot < supervisor.started.count {
        supervisor.started[slot].console = true
    }
}


/**
 * Claim the first framebuffer from the platform service, made anew each time, and wait for it.
 *
 * @param supervisor The supervisor, whose platform service connection it's asked on; its port isn't handled while it
 *     waits.
 * @return Its pixels and layout, which move to the caller; null without a platform service, or if there's none.
 */
request_framebuffer :: fn(supervisor: ptr[mut Supervisor]) -> platform.Framebuffer? {
    if cast[slop_os.Handle](supervisor.platform_end) == slop_os.NO_HANDLE {
        return null
    }
    out := os.Outgoing.{}
    made :: os.begin[platform.Request](&out)
    made^ = .ClaimFramebuffer
    if platform.send_request(supervisor.platform_end, supervisor.platform_port, &out) != null {
        return null
    }
    into := os.Incoming.{}
    loop {
        match platform.receive_response(supervisor.platform_end, supervisor.platform_port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => return null
        }
    }
    return match os.message_of[platform.Response](&into)^ {
        case ClaimedFramebuffer(framebuffer) => framebuffer
        case _ => null
    }
}

/**
 * Ask the platform service for a device, and wait for it.
 *
 * @param supervisor The supervisor, whose platform service connection it's asked on; its port isn't handled while it
 *     waits.
 * @param request Claim, for a device a driver takes not claimed yet, or Reissue, for a driver's device made anew.
 * @return The device's handles, which move to the caller; null without a platform service, or if it gave none.
 */
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
            case _ => return null
        }
    }
    return match os.message_of[platform.Response](&into)^ {
        case Claimed(device) => device
        case _ => null
    }
}

/**
 * Turn a handle that may be NO_HANDLE into an optional.
 *
 * @param memory The handle, which moves to the result.
 * @return Null for NO_HANDLE; memory otherwise.
 */
optional :: fn(memory: slop_os.Memory) -> slop_os.Memory? {
    return if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE { null } else { memory }
}

/**
 * Give back a device no driver takes, by closing every handle it holds.
 *
 * @param device The device; its handles are closed, and aren't to be used after.
 */
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

/**
 * Record something just started in a new entry, and tell the root task it started.
 *
 * The entry takes the budget, ring and lifecycle channel kept for the program launched last; its end is watched under
 * the entry's index, as options_for bound it.
 *
 * @param supervisor The supervisor, whose launched_budget, launched_ring and launched_lifecycle move to the new entry,
 *     and whose started_count grows by one.
 * @param name The name it's started under, which has to outlive the entry: a constant, or the system records' copy.
 * @param process Its process, which the entry takes.
 * @return Its index in started; MAX_STARTED if there's no room for it, when it's told to the root task but not kept.
 */
started :: fn(supervisor: ptr[mut Supervisor], name #escaping : string, process: slop_os.Process) -> usize {
    index :: supervisor.started_count
    tell_root(supervisor, .Started(report_of(name, 0)))
    if index >= supervisor.started.count {
        return MAX_STARTED
    }
    supervisor.started[index] = Started.{name = name, process = process, running = true, listener = NONE, budget = take_budget(supervisor),
        ring = take_ring(supervisor), lifecycle = take_lifecycle(supervisor), faults = take_faults(supervisor),
        image = supervisor.launched_image}
    supervisor.started_count = index + 1
    drain_trace(supervisor)
    return index
}

/**
 * Handle a launch that failed: end the watch made for it, log it, and either try again later or note it missing and
 * tell the root task.
 *
 * A restart that fails is tried again RESTART_RETRY later (retry_restarts), up to RESTART_RETRIES times in a row:
 * what it's started with may have ended with something else that isn't back yet, as the program the bundle store gave
 * does with the store, and as the store and the system volume can't give it while their disk's driver is started again
 * (decisions/0181's F6).
 *
 * @param supervisor The supervisor, whose port's watch under next_slot is ended; the entry being relaunched may be
 *     marked to try again (retry_later), or else is done, and its missing may grow by one.
 * @param name The service's name, as the system configuration has it, for the log, missing and the report.
 * @param error Why the launch failed; plus one, it's the code noted and told.
 */
failed :: fn(supervisor: ptr[mut Supervisor], name: string, error: os.LaunchError) {
    // Its end was watched under the key of the entry it didn't get, which the next launch is watched under
    _ = slop_os.port_unbind(supervisor.port, cast[u64](next_slot(supervisor)))
    again :: supervisor.relaunching
    if retry_later(supervisor, again) {
        log_line.write(supervisor.log, "supervisor: % didn't start again: %; trying again", name, error)
        return void
    }
    // A restart given up on is done, so start_again doesn't report it again
    if again < supervisor.started_count && again < supervisor.started.count {
        supervisor.started[again].done = true
    }
    log_line.write(supervisor.log, "supervisor: % didn't start: %", name, error)
    note_missing(supervisor, name, "didn't start", cast[u64](error) + 1)
    tell_root(supervisor, .Failed(report_of(name, cast[u64](error) + 1)))
}

/**
 * Keep a launched program's budget, faults' intercept and image's address for the entry it's placed in (take_budget,
 * take_faults), and give its process.
 *
 * The budget lasts as long as a handle to it, and goes back to the supervisor's once the entry's is closed as the
 * program ends.
 *
 * @param supervisor The supervisor, whose launched_budget, launched_faults and launched_image it replaces.
 * @param launched What the launch gave.
 * @return Its process, for the caller to place.
 */
kept :: fn(supervisor: ptr[mut Supervisor], launched: os.Launched) -> slop_os.Process {
    supervisor.launched_budget = launched.budget
    // One the entry before it didn't take, as when a launch's placing failed
    forget_launched_faults(supervisor)
    supervisor.launched_faults = launched.faults
    supervisor.launched_image = launched.image
    return launched.process
}

/**
 * Take the memory budget kept for the program launched last, for its entry.
 *
 * @param supervisor The supervisor, whose launched_budget is NO_HANDLE after.
 * @return The budget, which moves to the caller; NO_HANDLE if there's none.
 */
take_budget :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.MemoryBudget {
    budget :: supervisor.launched_budget
    supervisor.launched_budget = cast[slop_os.MemoryBudget](slop_os.NO_HANDLE)
    return budget
}

/**
 * Copy the supervisor's debug log, to give a service: writable, duplicable and transferable.
 *
 * @param supervisor The supervisor, whose debug log is copied; its own handle stays as it is.
 * @return The copy, which moves to the caller; null without a log, or if it couldn't be copied.
 */
duplicate_log :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

/**
 * Send a report to the root task on the supervision channel, without waiting for an answer.
 *
 * @param supervisor The supervisor, whose supervision channel to the root task it's sent on.
 * @param report The report, whose handles, as EventsService's, move to the root task; one that can't be sent is
 *     dropped.
 */
tell_root :: fn(supervisor: ptr[mut Supervisor], report: supervision.Request) {
    out := os.Outgoing.{}
    request :: os.begin[supervision.Request](&out)
    request^ = report
    _ = supervision.send_request(supervisor.root, supervisor.root_port, &out)
}

/**
 * Make a report of a program for the root task.
 *
 * @param name The program's name, copied into the report's label, cut short to fit.
 * @param code Its code: 0 for Started, its exit code for Ended, or its launch error plus one for Failed.
 * @return The report, its name zero-padded to GRANT_LABEL_SIZE bytes and its code as given.
 */
report_of :: fn(name: string, code: u64) -> supervision.Report {
    return supervision.Report.{name = os.label_from(name), code = code}
}
