# Programs

What a SlopOS program is, and how it starts: the executable its build makes, what its loader does with it,
and what it's given when it starts.

Status: **implemented in part** (roadmap M6, stages 6a to 6c): programs build, the kernel loads and starts
the root task, and the root task starts the first services, the process manager loading programs for the
rest; typed entry points come with 6d. Choices and alternatives are in
`../../knowledge/decisions/0058-user-space-plan.md`, `0059-user-programs-as-built.md`,
`0060-root-task-as-built.md` and `0067-process-manager-as-built.md`. Four-digit numbers like `0004` refer to decision records in
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
zero (`0026`). The startup code keeps the address, sets up the thread's carrier block and its `Context`,
calls `main`, and ends the process with `process_exit` and `main`'s result as its code, or 0 for a `main`
without one.

`slop_os.StartupBlock`, written by the loader in memory it maps into the process, read-only, for the
process's life:

| Field | |
|---|---|
| `abi_version: u32` | `slop_os.ABI_VERSION` of the kernel that started it |
| `size: u32` | `size_of(StartupBlock)` as its writer knew it |
| `process: Process` | The process itself |
| `space: AddressSpace` | Its address space, with `RIGHT_SPACE_MAP` |
| `budget: MemoryBudget` | Its memory budget, with `RIGHT_BUDGET_CHARGE` |
| `grant_count: u32` | How many grants there are |
| `free_base: u64`, `free_size: u64` | A free range of the address space, page-aligned, at a random place, where the program's runtime maps its own memory: its heap, and later its threads' stacks. Nothing else in the space uses it |
| `stack_base: u64`, `stack_size: u64` | The first thread's stack, which the runtime takes its stack limit from |
| `grants: u64` | Where the grants are, as bytes from the block's start |
| `seed: u8[32]` | A random seed: the boot's for the root task, one drawn from it for the entropy service; zeros for other processes |
| `cpu_features: CpuFeatures` | The CPU's features (`0019`) |

Each **grant** (`slop_os.Grant`, 40 bytes) is a handle the process starts with besides its own three: a
label of up to 32 bytes, in UTF-8 and padded with zeros, then its kind and the handle. `slop_os.find_grant`
looks one up by label and kind. The entry point's typed arguments (`0044`) come with 6d, as grants named
after their parameters.

## The Root Task

The kernel starts one process itself, the root task, from the first boot module (`0012`, `0060`), with the
loader above, at random places for its image, its 256 KiB stack with its startup block above it, and its
1 TiB free range. Its handles are to itself, its address space, and the root memory budget; its grants:

| Label | Kind | |
|---|---|---|
| `platform` | `Platform` | The authority over the machine's hardware (`0039`) |
| `debug_log` | `DebugLog` | Lines in the kernel's log (`debug_log`, `system_calls.md`) |
| `command_line` | `Memory` | The kernel's command line, its bytes then zeros (`0067`) |
| `module:<name>` | `Memory` | Each other boot module: a read-only memory object over the frames it was loaded into, which go back to the kernel when it's destroyed |

When the root task ends, the kernel logs how and stops (`StopReason.RootTaskEnded`, 7), and nothing else
stops a kernel with a root task: a working system's root task never ends. CPU budgets aren't objects yet, so its threads run with the kernel's default.

## The First Services

The root task starts the services `src/system_config` lists, in its order (`0067`), each in a process of its
own with a memory budget split off its starter's, which owns it:

| Service | Started by | |
|---|---|---|
| `entropy` | the root task, with its own loader | Random bytes from a ChaCha20 stream seeded from the boot's seed, for each channel it was granted as `client:<name>` |
| `process_manager` | the root task, with its own loader | Loads programs for requesters (below), drawing a fresh seed from `entropy` for each |
| `supervisor` | the root task, through the manager | Starts the services `system_config` gives it through the manager, owns them, and tells the root task as each starts and ends; it restarts nothing yet |
| `hello` | the supervisor, through the manager | Reports that its heap works, and given a connection to the manager, that it's still running once the manager is gone |

A grant `system_config` names is made by the service's starter: `debug_log` a duplicate of its own,
`entropy` a channel to the entropy service, `process_manager` a new connection to the manager (one end sent
to it in a `PM_CONNECT`), `root_task` a channel to the root task, and `module:<name>` a boot module, read-only.

**Loading a program** (`src/process_builder`, which the root task and the manager share) does through calls
what the kernel does for the root task: the image is loaded and relocated into a memory object, its segments
mapped with their protections, and its stack, startup block and free range placed at random pages; then the
process is given its address space, handles to itself and its budget, its image's, stack's and startup
block's memory objects, and its grants (`process_give_handles`), and its first thread starts
(`thread_create_in`). Everything is charged to the program's budget.

**The process manager's requests** (`src/protocols`), each a fixed-layout struct starting with its tag:
- `PM_LOAD`, a `LoadRequest`: the program's name, then a label for each grant (up to 12). Its batch has the
  process (with `RIGHT_PROCESS_THREADS`, `RIGHT_DUPLICATE` and `RIGHT_TRANSFER`), its address space (owning),
  its budget (with `RIGHT_BUDGET_CHARGE`, `RIGHT_DUPLICATE` and `RIGHT_TRANSFER`), the executable (with
  `RIGHT_MEMORY_READ`), then the grants. The requester makes the process, its space and its budget, so the
  result is never the manager's. The answer, a `LoadReply`, has a `LoadStatus` and the first thread's ID;
  either way the manager keeps none of the handles.
- `PM_CONNECT`: its one handle, a channel end, becomes another client.

**Boot tests** tell the root task what to test with a word on the kernel's command line: `test_services` ends
it with 0 once the supervisor has started its services, and `test_outlive_manager` kills the manager once
`hello` has started, then ends once `hello` has, after it said it's still running.

## The Runtime

Hemera's `base` runtime for `os = .SlopOS` (`base/runtime/slop_os.hsc`) makes these calls itself, with its
own copies of their numbers and of the startup block's first fields, which the ABI package checks against
its own when it's compiled:
- **memory:** its heap is Hemera's page heap, whose pages are memory objects of their own from `budget`,
  each mapped read-write in the free range, with its handle in a page in front of it;
- **the clock:** `clock_monotonic`; there's no wall clock yet;
- **ending:** `process_exit`, also for a failed assertion.

A program writes output through a debug log, if it's given one (`slop_os.debug_log`); `context.logger` has
nowhere to go yet. There are no threads, and `context.random` has no source yet: the entropy service
answers requests on a channel, which 6d's `std/os` turns into one.

`runtime.reserve_addresses(size)` gives a program a page-aligned part of the free range of its own, for
mapping something itself, like a module the root task reads.
