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

The boot image carries every program as a Limine module under `/boot/modules/`: `root_task.elf` first,
then the others in the order of their names.

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
| `abi_version: u32` | `slop_os.ABI_VERSION` of the kernel that started it: 2 |
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

## The Root Task

The kernel starts one process itself, the root task, from the first boot module (`0012`, `0060`), with the
loader above, at random places for its image, its 256 KiB stack with its startup block above it, and its
1 TiB free range. Its handles are to itself, its address space, and the root memory budget; its grants:

| Label | Kind | |
|---|---|---|
| `platform` | `Platform` | The authority over the machine's hardware (`0039`) |
| `debug_log` | `DebugLog` | Lines in the kernel's log (`debug_log`, `system_calls.md`) |
| `command_line` | `Memory` | The kernel's command line, its bytes then zeros (`0067`) |
| `test_device` | `Memory` | With `test_device` on the command line: what the firmware tables say of the emulator's test device (`src/test_device`), for `test_devices` (`0069`) |
| `module:<name>` | `Memory` | Each other boot module: a read-only memory object over the frames it was loaded into, which go back to the kernel when it's destroyed |

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
| `process_manager` | the root task, with its own loader | `log`, `entropy: Channel[Entropy]`, `clients: Listener[ProcessManager]` | Loads programs for requesters (below), drawing each one's seed, and the randomness that places its parts, from `entropy` |
| `supervisor` | the root task, through the manager | `log`, `manager`, `root: Channel[Supervision]`, `hello_module` | Starts the services `system_config` gives it with `os.launch`, owns them, and tells the root task as each starts and ends; it restarts nothing yet |
| `hello` | the supervisor, through the manager | `log?`, `manager?` | Reports that its heap and random numbers work, and given a connection to the manager, that it's still running once the manager is gone |

**Wiring**: `system_config` names each service's entry, and checks when it's compiled that every
`Channel[P]` one takes has a server: a service taking a `Listener[P]`, or the root task, which serves the
supervisor's reports. The root task holds the other end of each listener, and connects a service by sending a
new channel's end through it in the protocol's `Connect` request (each protocol package's `connect`); its own
connection to the manager is the listener itself.

**Loading a program** (`src/process_builder`, which the root task and the manager share) does through calls
what the kernel does for the root task: the image is loaded and relocated into a memory object, its segments
mapped with their protections, and its stack, startup block and free range placed at random pages; then the
process is given its address space, handles to itself and its budget, its image's, stack's and startup
block's memory objects, and its grants (`process_give_handles`), and its first thread starts
(`thread_create_in`). Everything is charged to the program's budget.

**Launching** (`os.launch` in `std/os`) takes the program's entry and a struct of its grants, whose fields the
compiler checks are the entry's parameters: it splits the budget off the caller's, makes the process and its
address space, and sends the manager a `LOAD`, each field's handle labeled with its name and tagged with its
protocol, an optional's `None` left out.

**The process manager's protocol** (`std/os/slop_os/process_manager`), generated (`0071`), on channels with 2 KiB
rings (`RING_BYTES`):
- `Load`: the program's name; the process (with `RIGHT_PROCESS_THREADS`, `RIGHT_DUPLICATE` and `RIGHT_TRANSFER`),
  its address space (owning), its budget (with `RIGHT_BUDGET_CHARGE`, `RIGHT_DUPLICATE` and `RIGHT_TRANSFER`) and the
  executable (with `RIGHT_MEMORY_READ`); and up to 12 grants, each with its label. The requester makes the process,
  its space and its budget, so the result is never the manager's. The answer is `Loaded` with the first thread's
  ID, or `NotLoaded` with a `LoadStatus`; either way the manager keeps none of the handles.
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

**Boot tests** tell the root task what to test with a word on the kernel's command line: `test_services` ends
it with 0 once the supervisor has started its services, and `test_outlive_manager` kills the manager once
`hello` has started, then ends once `hello` has, after it said it's still running.

## Test Programs

Each user-mode test is a program in `src/tests` (`0069`), which the root task runs with `test_program=<name>`:
it starts the entropy service and the manager, launches the test in place of the supervisor, and ends with 0 if
the test ended with 0 and the test's budget is back to nothing after its grace period. Every test's entry is the
same, which `system_config` checks:

```
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?) -> int
```

The root task gives every test its log, a connection to the manager and its own module, and `test_devices` the
platform capability and the `test_device` grant. A test that needs other processes launches copies of itself,
giving each a `peer` channel to tell it its part. Each test says what worked in its debug log and ends with 0, or
the number of the first check that failed (`src/test_kit`).

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
