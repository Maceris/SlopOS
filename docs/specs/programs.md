# Programs

What a SlopOS program is, and how it starts: the executable its build makes, what its loader does with it,
and what it's given when it starts.

Status: **implemented** (roadmap M6, stages 6a to 6e): programs build, the kernel loads and starts the root
task, the root task starts the first services, the process manager loading programs for the rest, a program's
entry takes its grants as typed parameters, and the kernel's user-mode tests are programs. Choices and
alternatives are in `../../knowledge/decisions/0058-user-space-plan.md`, `0059-user-programs-as-built.md`,
`0060-root-task-as-built.md`, `0067-process-manager-as-built.md`, `0068-typed-entry-points-as-built.md` and
`0069-tests-as-programs-as-built.md`. Four-digit numbers like `0004` refer to decision records in
`../../knowledge/decisions/`.

## Executables

A program is a package in `src/apps/`, `src/services/` or `src/drivers/`, built by the build package
(`src/build`, `targets=programs`) as `<name>.elf` for `os = .SlopOS` and x86-64-v3 (`0003`): a
position-independent ELF executable (`ET_DYN`, `0004`) linked statically, with no interpreter, no shared
libraries and no thread-local storage, whose only relocations are `R_X86_64_RELATIVE`. Its entry is the
compiler's startup code, which calls the package's `main`.

The boot ISO carries every program as a module of its generation's boot set (`0135`): `root_task.elf` first, then
the others in the order of their names.

## Loading

`src/elf_loader` checks an executable and loads it into memory the loader provides, allocating nothing:

1. `read(file)` checks the file and gives its `Executable`: the entry and each loadable segment, from the
   image's base; the image's size, a whole number of pages; its relocations; and what's read-only once
   it's relocated (`PT_GNU_RELRO`). It refuses anything else: another kind of file or machine, a
   segment that's writable and executable or shares a page with another, an entry outside an executable
   segment, a relocation of another kind or into a segment that isn't writable, and an executable stack.
2. `load(executable, file, image)` copies each segment's bytes into `image`, zeroed and at least the
   image's size.
3. `relocate(executable, file, image, base)` writes each relocation for the image to run at `base`.

The image is then mapped at `base`, a random, page-aligned address (ASLR), each segment's pages with its
own protection, and the RELRO pages without write.

## Starting

The process's first thread starts at the entry, with the stack pointer 8 below a multiple of 16 (as a call
leaves it) and the **startup block**'s address in its first argument register; every other register is
zero (`0026`). The startup code keeps the address, checks the block's version, sets up the thread's carrier
block and its `Context`, finds `main`'s parameters among the grants (below), calls `main`, and ends the
process with `process_exit` and `main`'s result as its code, or 0 for a `main` without one. A block of another
version ends the process with `slop_os.EXIT_WRONG_ABI` (125) before anything reads it.

`slop_os.StartupBlock`, written by the loader in memory it maps into the process, read-only, for the
process's life:

| Field | |
|---|---|
| `abi_version: u32` | `slop_os.ABI_VERSION` of the kernel that started it: 12 |
| `size: u32` | `size_of(StartupBlock)` as its writer knew it |
| `process: Process` | The process itself |
| `space: AddressSpace` | Its address space, with `RIGHT_SPACE_MAP` |
| `budget: MemoryBudget` | Its memory budget, with `RIGHT_BUDGET_CHARGE` |
| `grant_count: u32` | How many grants there are |
| `free_base: u64`, `free_size: u64` | A free range of the address space, page-aligned, at a random place, where the program's runtime maps its own memory: its heap, and later its threads' stacks. Nothing else in the space uses it |
| `stack_base: u64`, `stack_size: u64` | The first thread's stack, which the runtime takes its stack limit from |
| `grants: u64` | Where the grants are, as bytes from the block's start |
| `seed: u8[32]` | A random seed, which `context.random` is seeded from (`0068`): the boot's for the root task, and one its loader drew for any other |
| `cpu_features: CpuFeatures` | The CPU's features (`0019`) |

Each **grant** (`slop_os.Grant`, 40 bytes) is a handle the process starts with besides its own three: a
label of up to 32 bytes, in UTF-8 and padded with zeros, then its kind and the handle. `slop_os.find_grant` looks
one up by label and kind.

**The entry's parameters** are grants (`0044`, `0068`): each is the grant labeled with its name, of its type's
kind, so a program's `main` is its manifest:

```
main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager]?) -> int
```

A parameter is a handle type (`slop_os.DebugLog`, `slop_os.Memory`, `os.Channel[P]`, `os.Listener[P]`, ...) or
an optional of one, which is `None` without its grant. A `Channel[P]` or `Listener[P]` needs a channel made with
`P`'s tag (`0071`). Without a grant a required parameter needs, or with one of another kind or protocol, the process
ends before `main` with `slop_os.EXIT_MISSING_GRANT` (126). Other grants, like boot
modules, are still found by label.

**The entry's result** (`0179`): an integer is the exit code. Any other type `main` gives back, most usefully a
`Result`, is written for the launcher in the memory it gave as the grant `result` (`os.LaunchOptions.result`), and
read back once the program has ended (`os.entry_result`); the exit code is 1 for a `Result`'s `Error` and 0 otherwise,
with the grant or without. The shell gives the grant to every program whose manifest says its entry gives back a
value, 64 KiB, and shows an `Error` by its variant, the parameter it names (a field of type `os.ParameterName` in the
variant's payload) and the `@error` line documenting it.

**The shell's directory** (`0179`): a `dir` parameter named `here` is given the shell's directory without asking, or
another with `--here path`; the file tools (`list`, `copy`, `move`, `remove`, `recover`) take paths beneath it. A path
the shell can't find, whose name matches an entry of its directory without case or spaces at its ends, is answered
"did you mean" that entry.

**Scripts** (`0179`): a `.shell` file run as a command starts the `shell` program again, given the grant `script`,
the file, and only what its `param` line asks for: a grant of each `Dir`, `File` or `ReadOnlyFile` parameter by its
name (`here`'s as `home`), and a value of each other, of type `i64`, `u64`, `bool` or `string`, by its name, which
the script's shell reads with `slop_os_argument`. It's also given `session_terminal`, `manager`, and a `programs`
connection that only finds programs. A program the shell starts that can't run without the terminal is given its
input, and Ctrl-C with it, until it ends (the terminal protocol's `ReleaseInput`).

**Typed files in the shell** (`0179`): the shell's `view` reads a typed file's value by the type whose schema hash the
file has, found among the types of the manifests of the programs the shell can run. A program whose files should be
viewable writes them as a type its entry's signature has, a parameter's, a record's or its result's.

**Typed libraries** (`0120`, `0121`): a program built calling a Hemera typed library is given it as a grant labeled
`library:<file>`, `Memory` holding the library's file. Before `main`, `base`'s runtime binds every library its import
table names from those grants: the library's unwritten segments mapped straight from the memory (so every process
using it shares their pages, its code read and execute), its written ones copied and relocated (only relative
relocations, only within the copies), its interface record checked, and its process state the program's. A library
that's missing or doesn't match ends the process before `main` with exit code 1.

## The Root Task

The kernel starts one process itself, the root task, from the first boot module (`0012`, `0060`), with the
loader above, at random places for its image, its 256 KiB stack with its startup block above it, and its
1 TiB free range. Its handles are to itself, its address space, and the root memory budget; its grants:

| Label | Kind | |
|---|---|---|
| `platform` | `Platform` | The authority over the machine's hardware (`0039`) |
| `debug_log` | `DebugLog` | Lines in the kernel's log (`debug_log`, `system_calls.md`) |
| `command_line` | `Memory` | The kernel's command line, its bytes then zeros (`0067`) |
| `firmware` | `Memory` | The firmware tables, which the kernel copied before boot memory was reclaimed, read-only, if the boot has them (`0073`): a `slop_os.FirmwareTables` (its magic, `FIRMWARE_MAGIC`; its kind, `Acpi` or `DeviceTree`; how many tables), then a `FirmwareTable` for each (its signature, size, offset in the copy, and the physical address it was at, which ACPI's tables point at one another by), then the tables. ACPI's are the RSDP, every table the XSDT (or RSDT) lists, and the FADT's DSDT and FACS; the device tree's is its blob, `DTB `. Then the kernel's own `RAM `, a `slop_os.PhysicalRange` for each range of RAM it owns, at physical address 0 (`0074`), and, with a framebuffer, its own `FB  `, the first framebuffer's `slop_os.FramebufferLayout` at the framebuffer's physical address (`0138`) |
| `test_device` | `Memory` | With `test_device` on the command line: what the firmware tables say of the emulator's test device (`src/test_device`), for `test_devices` (`0069`) |
| `module:<name>` | `Memory` | Each other boot module: a memory object over the frames it was loaded into, which go back to the kernel when it's destroyed, mappable to read or run but never written |
| `library:<name>` | `Memory` | A boot module whose name ends in `.library`, a typed library, which the root task's runtime binds as any program's does (`0121`) |

When the root task ends, the kernel logs how, destroys everything it owned, waits a grace period of 20 ticks,
logs what's left in its pools, which should be only its own (the root budget and the platform capability), and
stops (`StopReason.RootTaskEnded`, 7). Nothing else stops a kernel with a root task: a working system's root task
never ends. CPU budgets aren't objects yet, so its threads run with the kernel's default.

## The First Services

The root task starts the services `src/system_config` lists, in its order (`0067`, `0068`), each in a process
of its own with a memory budget split off its starter's, which owns it:

| Service | Started by | Entry | |
|---|---|---|---|
| `entropy` | the root task, with its own loader | `log`, `clients: Listener[Entropy]` | Random bytes from a ChaCha20 stream seeded from its startup block, for each connection |
| `process_manager` | the root task, with its own loader | `log`, `entropy: Channel[Connector]`, `clients: Listener[ProcessManager]` | Loads programs for requesters (below), drawing each one's seed, and the randomness that places its parts, from `entropy` |
| `platform` | the root task, through the manager | `log`, `platform`, `firmware`, `clients: Listener[Platform]`, `command_line?` | Finds the PCIe host bridge in the firmware tables, numbers its buses and places its BARs where firmware didn't, and gives each device to the supervisor once (below) |
| `supervisor` | the root task, through the manager | `log`, `manager: Channel[Connector]`, `root: Channel[Supervision]`, `hello_module`, `platform_service: Channel[Connector]?`, `entropy_service: Channel[Connector]?`, `scheduler: Channel[Connector]?`, each driver's module, `command_line?` | Starts the services `system_config` gives it with `os.launch`, and a driver for each device it claims from the platform service, owns them, serves the connectors they're reached through, restarts a driver that crashes or is killed (below), and tells the root task as each starts and ends, and once all have |
| `input` | the supervisor, through the manager, once the drivers have started | `log`, `keyboard0` to `keyboard3: Channel[Connector]?`, `clients: Listener[Seat]`, `command_line?` | The seat's keyboards: what they type, through a keymap, for the terminal service, the secure attention key first, and a new keyboard only once its code is typed (below, `0138`) |
| `terminal` | the supervisor, through the manager, after the input service | `log`, `serial_line: Channel[Connector]?`, `input: Channel[Connector]?`, `framebuffer?`, `framebuffer_layout?`, `programs: Channel[Session]?`, `last_panic?`, `accounts_service: Channel[Connector]?`, `clients: Listener[Terminal]` | The console's terminal: its clients' output on the first serial line through the VT adapter and on the framebuffer, and what's typed there or through the input service as typed input for the client that reads first (below, `0136`, `0138`); with no accounts, first-boot setup on its own screen, which makes the administrator through the account service and shows the recovery code once (`0148`) |
| `sessions` | the supervisor, through the manager, before the terminal service | `log`, `manager: Channel[Connector]`, `echo_module?`, `events_service: Channel[Events]?`, `settings: Channel[ConfigValue]?`, `clients: Listener[Session]` | The session manager: makes sessions once the terminal service has logged someone in, or the one with no user of a boot with no accounts, and starts the shell in each, or echo without a shell in the bundle store or with `use_echo` on the command line, with the user's locale from the config store; serves the session protocol (`0150` to `0152`), and a shell's programs connection, which finds programs, lists them and gives their documentation (`0170`, `0174`) and debug files (`0185`) |
| `shell` | the session manager, through the manager, in each session, from the bundle store | `log?`, `session_terminal: Channel[Terminal]`, `home: Channel[Dir]?`, `manager: Channel[ProcessManager]?`, `programs: Channel[Programs]?`, `data: AppData?` | A session's first program: the shell language, its programs called through their manifests, `help` from their documentation, completion, history kept in `data` (`apps/.shell`), and jobs, with `crashes`, `debug`, `record`, `replay` and `profile`, which read programs' debug files when the system has them; its session ends when it does (`0169` to `0172`, `0174`, `0183`, `0185`) |
| `echo` | the session manager, through the manager, in each session without a shell, or with `use_echo` | `log`, `session_terminal: Channel[Terminal]`, `home: Channel[Dir]?` | Says how many entries the home directory has, shows what's typed, and answers each line with `echo: ` and the line (below) |
| `hello` | the supervisor, through the manager | `log?`, `manager?`, `console: Channel[Connector]?` | Reports that its heap and random numbers work, in its debug log and on the console, and given a connection to the manager, that it's still running once the manager is gone |
| `virtio_rng` | the supervisor, through the manager, for each modern virtio entropy device | its device's bundle (below), `entropy_service: Channel[Entropy]?` | Offers the device's bytes to the entropy service as a source, on a channel of the `rng` protocol |
| `virtio_console` | the supervisor, through the manager, for each modern virtio console | its device's bundle, `clients: Listener[Serial]` | Its device's first port as the `serial` protocol |
| `virtio_blk` | the supervisor, through the manager, for each modern virtio block device | its device's bundle, `clients: Listener[Block]` | The disk as the `block` protocol (below) |
| `virtio_input` | the supervisor, through the manager, for each modern virtio input device | its device's bundle, `clients: Listener[Input]` | Its keyboard, mouse or tablet as the `input` protocol (below) |
| `edu_dma` | the supervisor, through the manager, for each QEMU edu device | its device's bundle | A driver that isn't trusted with DMA: writes outside its domain, for the test that it's stopped (`0084`) |
| `storage_manager` | the supervisor, through the manager, once the drivers have started, if there's a disk | `log`, `manager: Channel[Connector]`, `partition_server_module`, `fat_server_module`, `container_service_module`, `volume_server_module`, `disk0` to `disk3: Channel[Connector]?`, `clients: Listener[Storage]` | Starts a partition server for each disk, and serves every disk's partitions, block connections narrowed to one, a FAT partition's files, and a SlopOS container's system volume, as the `storage` protocol (`0086`, `0087`, `0089`) |
| `partition_server` | the storage manager, through the manager, for each disk | `log`, `disk: Channel[Block]`, `clients: Listener[Partitions]` | Reads its disk's GPT, and serves its partitions and block connections narrowed to one as the `partitions` protocol, holding nothing but its disk (`0086`) |
| `fat_server` | the storage manager, through the manager, for each FAT partition whose files are asked for | `log`, `partition: Channel[Block]`, `clients: Listener[Dir]` | Serves the FAT32 volume on its partition as the file protocols (below), holding nothing but a connection narrowed to that partition (`0087`) |
| `container_service` | the storage manager, through the manager, for each SlopOS container whose files are asked for | `log`, `partition: Channel[Block]`, `clients: Listener[Container]` | Owns a container's space map, owners and checkpoints, and serves the `container` protocol to its volumes' servers (below), holding nothing but a connection narrowed to its partition (`0089`) |
| `volume_server` | the storage manager, through the manager, for each volume in use | `log`, `volume: Channel[Container]`, `clients: Listener[Dir]` | Holds a volume's tree and serves it as the file protocols, reaching nothing but its own extents, through the container service (`0089`) |
| `accounts` | the supervisor, through the manager, if there's a disk | `log`, `storage_service: Channel[Connector]?`, `clients: Listener[Accounts]` | Keeps every account's record on the accounts volume, which it has the storage manager make the first time, and each account's sealed home volume; serves the `accounts` protocol: the first account made is the administrator, a home volume is opened with its password and only its root is handed out, a password is changed or replaced with the recovery code, and wrong attempts are rate-limited per account and per client (`0141`, `0143`) |
| `disk_check` | the supervisor, through the manager, if there's a disk | `log`, `storage: Channel[Connector]?`, `working_directory: Channel[Dir]?`, `system: Channel[Dir]?` | Opens the partition named `SlopOS check` through the storage manager, reads, writes, flushes and reads back its blocks, and is refused the block past its end; then uses `std`'s files and the file protocols on the first EFI system partition, its working directory (`0087`), and the file protocols on the first SlopOS container's system volume (`0089`); and says what it found. The supervisor says everything has started once it has ended |

**Where programs come from** (`0089`): the **boot set**, the services `system_config` marks `boot_set` (the root
task's four, `virtio_blk`, the storage manager, the partition server, the FAT server, the container service and the
volume server), are the bootloader's modules, the generation's boot set: enough to reach the system volume. The supervisor starts the boot set's drivers
and the storage manager first, asks it for the first SlopOS container's system volume, and reads every other program
from its `modules` folder, each once, straight into a memory object of its own given to the volume server as the
read's buffer, before starting the other drivers and services. Where there's no system volume, as on the ISO, or a
program isn't there, the boot set's module stands in.

**Wiring**: `system_config` names each service's entry, and checks when it's compiled that every
`Channel[P]` one takes has a server: a service taking a `Listener[P]`, the root task, which serves the
supervisor's reports, or the supervisor, which serves connectors. The root task holds the other end of each
listener, and connects a service by sending a new channel's end through it in the protocol's `Connect` request
(each protocol package's `connect`); its own connection to the manager is the listener itself.

**Connectors** (`src/protocols/connector`, `0077`): a service the supervisor starts doesn't get connections to a
driver, which may be restarted, but a connector to it: a channel the supervisor serves, whose `Dial` is answered with
`Dialed` and a new connection to whichever process serves it now, made through that driver's listener with its
protocol's `Connect`, or `Unavailable` while nothing does. `connector.dial[P]` dials, tries again every 100 ms while
it's unavailable, up to 50 times, and checks the connection speaks `P`; a client whose connection's other end goes
dials again. The input service is given connectors to the first four input devices, the terminal service one to the
first serial line and one to the input service, `hello` and `echo` one each to the terminal service, the
storage manager one to each of the first four disks, and the disk check one to the storage manager. The disk check's
working directory is the first EFI system partition's root, which the supervisor asks the storage manager for
(`OpenFiles`) on a connection of its own, while its port goes on serving connectors, which the storage manager dials
its disks through before it answers.

**Restarts**: a driver that ends other than by exiting with 0, killed or crashed, is started again: the platform
service reissues its device (`Reissue` with its address, answered with `Claimed` and its bundle made anew, to the one
that claimed it), and the supervisor launches the driver with it and a new listener, in the same place among what it
started, which it reports started again. A driver that ends a fourth time within a minute isn't. Its device's objects
were the driver's, given to it, so they went with it.

**Loading a program** (`src/process_builder`, which the root task and the manager share) does through calls
what the kernel does for the root task: the image is loaded and relocated into a memory object, its segments
mapped with their protections, and its stack, startup block and free range placed at random pages; then the
process is given its address space, handles to itself and its budget, its image's, stack's and startup
block's memory objects, and its grants (`process_give_handles`), and its first thread starts
(`thread_create_in`). Everything is charged to the program's budget.

**Launching** (`os.launch` in `std/os`) takes the program's entry and a struct of its grants, whose fields the
compiler checks are the entry's parameters: it splits the budget off the caller's, makes the process and its
address space, and sends the manager a `LOAD`, each field's handle labeled with its name and tagged with its
protocol, an optional's `None` left out. The executable goes with `RIGHT_MEMORY_EXECUTE` where the caller's handle has
it, so its code is mapped from it, shared. The program is given each library its launcher holds, `library:<file>`,
except those `LaunchOptions.libraries` names, which it's given instead (`0121`).

**The root task's services started again** (`0140`): the entropy service, the process manager, the scheduler service
and the platform service are started again when they end, up to three times in a minute, and their clients reach them
through connectors the root task serves on a thread of its own: the supervisor's connections to the process manager,
the platform service and the scheduler service are dialed again when their other ends close, the process manager dials
the entropy service again when a draw fails, and the storage manager dials the process manager through a connector the
supervisor serves. A platform service started again registers its controllers and IOMMUs again, which the kernel
answers with those already registered, and takes a reissued device nothing's claimed from it as the asker's. Once the
events service is up, the supervisor gives the root task a connection to it (`EventsService`), and a service started
again is given a ring for its log records.

**The lifecycle channel** (`0139`, `std/os/slop_os`'s `lifecycle`): `LaunchOptions.lifecycle` gives the program its
end of a channel, as the grant `lifecycle`, the launcher keeping the other. Hemera's runtime serves it on a thread of
its own, started before `main` on a 16 KiB stack: `Ping` is answered with `Pong` and its sequence whatever `main` is
doing, and `Stop` with `Stopping`, after which `lifecycle.stop_requested()` is true and a port the program asked with
`lifecycle.on_stop` gets a `User` packet. Messages are 8 bytes, a kind and a sequence. The supervisor gives every
program it launches one.

**The process manager's protocol** (`std/os/slop_os/process_manager`), generated (`0071`), on channels with 4 KiB
rings (`RING_BYTES`):
- `Load`: the program's name; the process (with `RIGHT_PROCESS_THREADS`, `RIGHT_DUPLICATE` and `RIGHT_TRANSFER`),
  its address space (owning), its budget (with `RIGHT_BUDGET_CHARGE`, `RIGHT_DUPLICATE` and `RIGHT_TRANSFER`) and the
  executable (with `RIGHT_MEMORY_READ`, and `RIGHT_MEMORY_EXECUTE` to share its code); and up to 32 grants (16
  before version 2, 24 before 9c3), each with its label. The requester makes the process,
  its space and its budget, so the result is never the manager's. The answer is `Loaded` with the first thread's
  ID, where the image was loaded and the seeds it was built with (`Started`), or `NotLoaded` with a `LoadStatus`; a
  `Load` may give the seeds, its own and its layout's, for a replay (`0183`), or leave them to the manager to draw.
  Either way the manager keeps none of the handles.
- `Connect`: a `Channel[ProcessManager]`, which becomes another client.

## Protocols

A protocol is a package (`0040`, `0071`): a `Request` and a `Response` union, a type named after the protocol for
`os.Channel[P]`, a `PROTOCOL` and an `is_idempotent`, and `#insert os.protocol_code(Request, Response)`, which
generates its validators and its send and receive functions. A message is its union's own layout, then its
variable-size data (`slop_os.Relative[T]`, an offset from the message's start and a count); each handle in it
travels as its index in the message's batch. Receiving checks every bool, enum, handle index and Relative, and
that each `Channel[P]` in it has `P`'s tag, before anything reads it; a variant the receiver doesn't know gets
`answer_unsupported`. SlopOS's own are in `src/protocols/<name>`; those `std` speaks, in
`std/os/slop_os/<name>`.

## Devices and Drivers

The platform service (`src/services/platform`, `0074`) finds the host bridge through `src/pci`: on x86-64 the MCFG's
ECAM, and as windows for BARs, the gaps in the `RAM ` table below the I/O APICs at 0xFEC00000 and 64 GiB above
everything else, since ACPI's real windows are AML; on AArch64 the device tree's `pci-host-ecam-generic`, its
`bus-range`, `ranges` and `msi-map`. It walks every bus depth first, keeping what firmware assigned where it holds:
a bridge without bus numbers gets the next free ones, and a memory BAR that's unplaced, outside a window it may be
in, or overlapping a BAR, RAM, the ECAM or a window of a bridge it isn't behind is placed first-fit, aligned to its
size, in its bridge's window or the host's. I/O BARs aren't placed.

**The `platform` protocol** (`src/protocols/platform`): `Claim` with a `DeviceMatch` (a vendor and device ID, or a
class, each `ANY` for any) gives `Claimed` with the next unclaimed device that matches, which is never given again,
or `NoDevice`. A claimed device is a `PciDevice`: its address, IDs and class; its `Device`; a window onto its 4 KiB of
configuration space; each BAR it has as device memory at its CPU address (`NO_HANDLE` for one it hasn't); and a DMA
domain it's attached to. The supervisor claims devices for each driver `system_config` lists with `devices`, and
starts the driver with those as its entry's parameters (`device`, `config`, `bar0` to `bar5`, `domain`), so a
driver holds its own device and nothing else, and needs the platform service no further.

**Drivers** are in `src/drivers`. A virtio device is reached through `src/virtio`: the modern virtio-pci transport,
its registers through its vendor capabilities, its features (`VERSION_1` always), MSI-X with one vector per queue,
and split virtqueues of up to 64 descriptors in a page of DMA memory, laid out in little-endian types.

**Drivers that serve clients** take a listener (`clients: Listener[P]`), whose other end the supervisor keeps and
connects the services that use them through, so `system_config`'s wiring check sees the driver as `P`'s server (`0075`).

**Serial lines** (`src/protocols/serial`): `Write` with bytes, answered with how many were taken; `Read` with the most
to take, held by the driver until at least one byte has arrived, then answered with `Data`; `Features`, answered with
the line's speed (0 for a virtual console); and `Connect`. `virtio_console` serves its device's first port (no
multiport): four receive buffers always offered to the device, and one buffer to send at a time, waited for.

**The terminal** (`src/services/terminal_service`, `std/os/slop_os`'s `terminal`, `0136`): its clients `Write`
UTF-8 text in styled runs (colours from a palette or 24-bit, bold, dim, italic, underline, inverse, strikethrough, a
link's target), which isn't answered; `MoveCursor`, `ShowCursor`, `Clear`, `Scroll`, `Screen` (a screen of the
program's own, or back to its lines) and `Bell` too. `Describe` is answered with the terminal's `Features` (80 by 24,
24-bit colour, links, Unicode 17's widths). `Read` is held until there's input, then answered with `Input`: `Key`s
(a USB HID usage, modifiers and the text typed), a `Paste` as one event, and `Interrupt` for Ctrl-C; the first client
to read owns the input until it goes. Text is shown a grapheme cluster at a time (`std/unicode`), made safe
(`src/safe_text`): C0 controls as their Control Pictures, C1, bidirectional and invisible characters written out as
`⟨U+202E⟩`, bytes that aren't UTF-8 as U+FFFD, a line break as one, a tab as spaces to the next stop of 8. The VT
adapter (`src/vt`) is the only place escape sequences exist: it turns styles, moves, clears, scrolls and links into
ECMA-48 for the first serial line, with at most two `Write`s in flight on it, and decodes what's typed there (keys,
xterm's modifiers, bracketed paste). The terminal service keeps what it shows in a screen model (`src/screen`), 80 by
24: the top row is the **status line**, which only it writes (inverse: `SlopOS │ console │ no session`, and a new
keyboard's code while one waits); programs have the 23 rows below it, which on the serial line are the ones that
scroll (DECSTBM), the status line drawn between a saved and a restored cursor. The **secure attention key**,
Ctrl+Alt+Delete (from the input service, or on the serial line as a terminal sends it, CSI 3;7~), brings up its own
screen over the program's, which every key goes to and none reaches a program, until Esc or Enter leaves it and the
program's rows are drawn again from the model. That screen (`0139`) shows the boot before's panic, if it stopped for
one (the status line says so until it's been seen), and the console's programs from the `session` protocol
(`src/protocols/session`), which the supervisor serves until sessions: `List` gives each running one's name, memory in
use and budget, and whether it answered a `Ping` on its lifecycle channel within 250 ms, those that didn't marked "not
responding"; Up and Down choose one, and E or Delete sends `End`, which asks it to `Stop`, kills it if it hasn't ended
2 s later, and doesn't start it again. The input and terminal services run on the trusted path's CPU share, priority
250, which they lend to nothing. With a framebuffer (`0138`), the same console is drawn there too
(`src/glyph_screen`): each cell's glyph from Spleen's PSF fonts (`src/psf2`: 12×24, or 8×16 where 80 by 24 of those
don't fit), in its style's colours, the grid centered, only rows that changed drawn again. The banner,
`SlopOS console`, is shown on each serial line dialed; a serial line or the input service that goes is dialed again. **echo** (`src/apps/echo`) reads the console's input: it shows each key's text as typed, takes
Backspace back a cluster, drops the line at Ctrl-C, and answers each line with `echo: ...`, which it logs
(`echo: read ...`).

**The seat** (`src/services/input_service`, `src/protocols/seat`, `0138`): the input service owns up to four
keyboards, types their keys through a keymap (`src/keymaps`, US), and holds a `Read` from the terminal service until
it has events: `Key`s (a HID usage, modifiers, the text typed), `SecureAttention` for Ctrl+Alt+Delete from any
keyboard, which is never a key, and `Waiting` and `Accepted` for a new keyboard. Keyboards there when it starts are
accepted; one found later, or every one with `test_new_keyboards`, waits: its first key makes a random six-digit
code, which the terminal service shows on the status line, and nothing it types goes anywhere until that code is typed
on it and Enter.

**The framebuffer** (`0138`): the platform service gives the first framebuffer, from the `FB  ` table, to the client
that asks (`ClaimFramebuffer`), as `Framebuffer`: its pixels, write-combining device memory, and a page holding its
layout. Making the pixels' memory takes the framebuffer from the kernel's console, whose log stays on the serial
console. The supervisor claims it each time it starts the terminal service.

**Input devices** (`src/protocols/input`, `0077`): events in SlopOS's own terms, each a kind (`Key`, `Motion`,
`Position`, `Button`, `Wheel`), whether it's pressed, a code and x and y: a key by its USB HID usage (page 7), a button
from 0 for the left, a pointer's motion or position, how far a wheel turned. `Read` with the most to take, held until
there's at least one, is answered with `Events`; every client sees every event from when it connected. `virtio_input`
turns its device's evdev events into these: keys 0 to 127 by a table, buttons, relative and absolute axes, the wheel.

**Disks** (`src/protocols/block`, `0076`): a disk is 512-byte blocks. Each connection has a buffer, DMA memory the
driver makes at its first `GetBuffer` and gives a read-write window onto, 64 KiB for `virtio_blk`, which the device
reads and writes with no copies. `Read` and `Write` name a first block, a count and an offset in the buffer, with the
client's tag; `Flush` makes what's written durable; each is answered with `Finished`, its tag and a status (`Done`,
`OutOfRange`, `ReadOnly`, `DeviceError`, or `Busy` when every slot is in flight), as the device finishes it, in any
order. `Describe` gives the block count, the buffer's size, and whether the disk is read-only and flushes.
`virtio_blk` keeps up to 16 requests in flight across its clients, each a chain of a header, the data and a status
byte. A device without a flush writes durably, and its `Flush` is `Done` at once.

**Files** (`std/os/slop_os`'s `files`, `dir`, `read_only_dir`, `file`, `read_only_file` and `file_set`, `0087`): a
`dir` connection is a directory and everything beneath it, and nothing above it: paths are UTF-8 with `/` between
components, resolved beneath the directory they're sent on, where `.` and `..` aren't components. `OpenFile` (with
`Existing`, `New`, `Either` or `Truncate`), `OpenReadOnlyFile` and `OpenDirectory` (`create` making it and any missing
directory before it) give connections of their own; `List` gives the entry at or after a cursor, and the cursor after
it; `Remove` takes a file or an empty directory, `Rename` moves what's at one path to another, replacing a file;
`Narrow` gives the directory as `read_only_dir`, and `Select` a `file_set`: the files whose names match a pattern
(`*`, `?`), compared as the directory compares names, found when it's used, so files made later match too, and a set
from a read-only directory refuses `OpenFile`. `Sync` makes everything changed beneath it durable; `Features` says
what the file system does beyond the least, for FAT only ignoring case. A file's bytes move through a buffer the
client gives its connection once (`UseBuffer`, a memory object the server maps, at most 16 MiB): `Read` and `Write`
name the file's offset, a count and an offset in the buffer; `SetSize` cuts or extends with zeros; `Narrow` gives the
file as `read_only_file`. `Info` gives the kind, the size and an informational name, the path it was opened as, for
display only (`0018`). Errors are a `FileError`: `NotFound`, `NotADirectory`, `IsADirectory`, `AlreadyExists`,
`DirectoryNotEmpty`, `InvalidPath`, `NoSpace`, `ReadOnly`, `DeviceError`, `Corrupt`, `NoBuffer` or `Conflict`.

What the native filesystem adds (`0089`), which FAT answers `Unsupported`, as `Features` says: `Replace` with a path
gives a file connection to a new file, which its `Install` swaps in for the one at the path, whole, and makes durable,
while a reader of the old one goes on reading it until it closes; `Begin`, with a memory object for its log, gives a
transaction's connection, speaking `dir` beneath the same directory, whose opens, writes, sizes, removals and renames
are logged until `Commit` applies them all at once and makes them durable, or answers `Conflict` if anything they read
or changed was changed meanwhile, or the error that stopped it with none of it done; `Abort`, or closing it, drops
them, and reads on it see the directory as it is. `Changes` with a cursor gives the first change beneath the directory
at or after it (`Created`, `Written`, `Removed`, `MovedOut`, `MovedIn` or `Replaced`, with the path from the
directory and the cursor after it), or `UpToDate`, or `Resync` with where to ask from once the directory's been
listed again, for a cursor older than the volume's history keeps (1 MiB of changes).

`std`'s files (`std/os/slop_os_files.hsc`) are these: `os.Directory` a `dir` connection, `os.File` a `file` or
`read_only_file` one with a 64 KiB buffer of its own, and the path functions (`open`, `read_entire_file` and the rest)
resolve beneath the program's `working_directory` grant, failing with `NotFound` without one and `InvalidPath` for a
path above it.

The **FAT server** (`src/services/fat_server`, over `src/fat`) serves FAT32 with long names, read and write: a new
name gets an 8.3 alias (`~N`), names compare ignoring ASCII case, times are 1980-01-01, and FAT12 and FAT16 are
refused. Each request re-reads its directory entry, so a file renamed or removed through another connection is seen
at once. Up to 64 connections.

A **SlopOS container** (`src/slopfs`, `0088`, `0089`) is served by two kinds of process. The **container service**
(`src/services/container_service`) mounts it and keeps every extent a volume has, and serves the `container` protocol
(`src/protocols/container`): on its listener, `OpenVolume` with a name gives a connection for that volume, on which
its server describes it (its record, and the transaction its changes go into), allocates extents (`Allocate`) and
gives them back (`Release`, refused with `NotYours` if they aren't the volume's), opens block connections
(`OpenBlocks`) whose reads and writes the container service checks against the volume's extents, in whole 4 KiB
blocks, before passing them to the driver with no copies, and commits (`Commit` with its record, its root in its own
extents). A commit takes that volume's changes and the container's own, flushes, writes a checkpoint and flushes
again; another volume's changes wait for its own commit. The **volume server** (`src/services/volume_server`) holds the
volume's tree and serves the file protocols as the FAT server does, names compared exactly; it commits when a `Sync`
asks, answering once that's durable, and a second after a change otherwise.

**Volumes made at run time** (`0141`, `0142`): the storage protocol's `CreateVolume` (a name, a cipher and a
passphrase, or neither) has the container service register the volume with nothing in it (`CreateVolume` on its
listener, answered with `Created`), then opens it as `OpenVolume` does. The volume server, finding no root, fills it:
for a sealed one, the first `Unlock` makes its key from the passphrase, wraps it with Argon2id inside the volume
server's budget (4 MiB, 3 passes), and hands the container service only the wrapped records (`AddWrap`, refused once
the volume has a root, and `AddGeneration`); then it writes the root directory and commits.

**Hardware randomness** (`src/protocols/rng`): an RNG's driver makes a channel of the `rng` protocol (`Read` with a
count, answered with `Bytes`) and offers it to the entropy service with `entropy.AddSource`. The entropy service
reads 32 bytes from each source when it's added, and again each time 64 KiB more have been handed out, and reseeds
its stream with its own next 32 bytes XORed with the source's.

**Boot tests** tell the root task what to test with a word on the kernel's command line: `test_services` ends
it with 0 a second after the supervisor says it has started everything (`AllStarted`), for drivers to come up;
`test_outlive_manager` kills the manager once `hello` has started, then ends once `hello` has, after it said it's
still running; and `test_reassign` has the platform service take every virtio device's BARs and every bridge's bus
numbers as unset, so assigning them is tested where firmware assigns everything. The supervisor's `test_restart`
kills the first serial line's driver once the console has dialed it, and says it has started everything only once
the driver's been restarted and dialed again. With `--boot-disk`, `tools/boot.py` boots from a disk the image builder
made (`0088`) rather than the ISO, the bootloader read from its EFI system partition. `tools/boot.py` can link a virtio console to a TCP socket on the
loopback (`--console-input`, `--expect-console-line`), which it types its i-th line into at the console's i-th
banner, and whose lines it checks; add a virtio keyboard it types on through QEMU's machine protocol
(`--keyboard-input`); and add a virtio disk, an image it marks (`--disk`) and checks afterwards
(`--expect-disk-block`).

## Test Programs

Each user-mode test is a program in `src/tests` (`0069`), which the root task runs with `test_program=<name>`:
it starts the entropy service and the manager, launches the test in place of the supervisor, and ends with 0 if
the test ended with 0 and the test's budget is back to nothing after its grace period. Every test's entry is the
same, which `system_config` checks:

```
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?) -> int
```

The root task gives every test its log, a connection to the manager and its own module, and `test_devices` and
`test_msi_dma` the platform capability, the `test_device` grant and the firmware tables. A test that needs other processes launches copies of itself,
giving each a `peer` channel to tell it its part. Each test's checks are `#test` functions it runs with
`test_kit.run`, reporting each to its debug log, and it ends with how many failed (`src/test_kit`, decisions/0175).

## The Runtime

Hemera's `base` runtime for `os = .SlopOS` (`base/runtime/slop_os.hsc`) makes these calls itself, with its
own copies of their numbers and of the startup block's first fields, which the ABI package checks against
its own when it's compiled:
- **memory:** its heap is Hemera's page heap, whose pages are memory objects of their own from `budget`,
  each mapped read-write in the free range, with its handle in a page in front of it;
- **the clock:** `clock_monotonic`; there's no wall clock yet;
- **ending:** `process_exit`, also for a failed assertion.

A program writes output through a debug log, if it's given one (`slop_os.debug_log`); `context.logger` has
nowhere to go yet. There are no threads. `context.random` is ChaCha20 from the startup block's seed, rekeyed
after every block, so `std/random` works in any program.

`runtime.reserve_addresses(size)` gives a program a page-aligned part of the free range of its own, for
mapping something itself, like a module the root task reads.
