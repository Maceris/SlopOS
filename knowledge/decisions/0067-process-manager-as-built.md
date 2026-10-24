# 0067: The Root Task and the Process Manager as Built

Status: accepted
Date: 2026-10-24
Related: `0012` (the root task), `0017` (the supervisor), `0011` (budgets), `0044` (the system configuration),
`0058` (the plan for M6), `0060` (the root task as built), `../../docs/specs/programs.md`,
`../../docs/specs/system_calls.md`, `../roadmap.md` M6

## Context
M6's third stage (6c): the root task becomes long-lived and starts the first services, and programs are loaded
for a requester that owns and pays for them, so a program outlives the process manager that loaded it.
`0060` left one gap: `thread_create` makes a thread only in the caller's process, so nothing could start
another process's first thread. Nothing could put handles into another process's table either, and its
startup block has to name them. `0058` placed the early entropy source but not what it runs in.

## Decision
Chosen with the project's owner:
- **`thread_create_in`** (call 47): a thread in another process, in an address space in its subtree, owned by
  it, giving the thread's ID. It needs a new process right, `RIGHT_PROCESS_THREADS`, which covers the
  subtree like the other process rights.
- **`process_give_handles`** (call 48), under the same right: handles moved out of the caller's table into the
  process's, with the value each gets there. An owning handle's object becomes the process's and is charged
  to its budget, for all of them or none, as taking a batch does.
- **The requester makes the process**, its address space and its budget, and sends the manager handles with
  only the rights it needs. What the manager builds is never the manager's, not even briefly, so its end
  can't touch it.
- **The entropy service is its own process**, loaded by the root task itself (the manager can't load
  anything without entropy), and seeded from the boot seed by the root task.
- **Boot order**: the root task loads the entropy service and the process manager itself, then asks the
  manager to start the supervisor, which the root task owns. The stub supervisor asks the manager to start
  the services `system_config` gives it (`hello`, for now), owns them, and reports to the root task as each
  starts and ends; it doesn't restart them yet.
- **`system_config`**: one compile-time constant listing each service's name, boot module, starter (the root
  task or the supervisor), whether its starter goes through the manager, its budget, and its grants by name
  (`debug_log`, `entropy`, `process_manager`, `root_task`, `module:<name>`). The root task and the supervisor
  read it; 6d checks its wiring against typed entry points.
- **Messages** are fixed-layout structs in a shared package (`src/protocols`), each starting with a tag, with
  their handles in the message's batch in a documented order, until 6d generates them.
- **The boot test**: the root task kills the manager once the supervisor reports `hello` started; `hello`,
  given a connection to the manager, waits for its other end to close, then says it's still running and ends;
  the root task ends once the supervisor reports that.

As built:
- **The kernel**: `thread_create_in` refuses a space outside the process's subtree (`BadAddress`).
  `process_give_handles` takes up to 64 handles, each with `RIGHT_TRANSFER`, and refuses an owning handle to
  the process or one above it, which would make the process own itself (`NotTransferable`), and a channel end
  whose rings are mapped. `memory_size` (call 49) gives a memory object's size, which the manager needs to map
  an executable it's sent. `ControlError` gains `TooBig` (15) and `NotTransferable` (22), sharing the tags
  of `ChannelError`'s.
- **The root task's grants** include the kernel's command line (`command_line`, its bytes then zeros), which
  boot tests use to tell the root task what to test: `test_services` ends it once the supervisor's services
  have started, `test_outlive_manager` runs the outlive test. With a root task running, the kernel no longer
  stops after a number of ticks: only the root task's end stops it.
- **`src/process_builder`**: what the kernel does for the root task, through calls, shared by the root task
  and the manager. The image is loaded and relocated straight into its memory object, mapped in the builder's
  own space for a moment; each part (image, 256 KiB stack, startup block, 1 TiB free range) is at a random
  page as the kernel places the root task's. What goes to the process: its address space (owning), handles to
  itself (`RIGHT_DUPLICATE` and `RIGHT_TRANSFER` only) and its budget, the owning handles to its image, stack
  and startup block, and its grants. Then its first thread starts.
- **`src/random_stream`**: ChaCha20 from `std/crypto`, rekeyed after every block from that block's first
  half ("fast key erasure"). The root task's stream is seeded with the boot seed; the entropy service's seed
  is drawn from it and goes in the service's startup block, the field `0060` kept for it, rather than in a
  message. The manager draws a fresh 32-byte seed from the entropy service for each program it loads.
- **The services**: `entropy` serves each channel granted as `client:<name>`. `process_manager` does the same,
  and serves ends sent with `PM_CONNECT`; each `PM_LOAD` gets a `LoadReply`. The `process_manager` grant is a
  new connection: the starter sends the manager one end and gives the program the other.
- **Found in Hemera on the way, fixed (`0047`)**: a qualified name as an array's second or later dimension
  (`u8[4][slop_os.GRANT_LABEL_SIZE]`) was parsed as separate siblings and reported undeclared. The first
  dimension worked, being parsed as a generic's arguments. Dimensions now parse a qualified name as an
  expression. And the bounds checker didn't count `or_break` or `or_continue` as leaving their loop, so after
  a loop that only `or_break` ends it took the code for unreachable and checked none of its indexes. The root
  task's loop over its port's packets was one, now checked like any other.

## Alternatives considered
- **`process_start`, for the first thread only**: a smaller power to hand out, but a second call for anything
  else that starts threads in another process, like a debugger or a runtime.
- **A bootstrap channel** the kernel installs in each new process, carrying its grants: fewer calls, but every
  program's startup reads a channel before anything else.
- **The manager makes the process** and sends back the owning handle: simpler for requesters, but a manager
  that dies mid-request takes the half-built process with it, and the process is briefly the manager's.
- **The entropy source inside the root task**: no extra process, but it puts a service in the TCB's smallest
  part that M7's hardware RNG driver would later replace.
- **The root task loading all three services**: fewer requests to the manager at boot, but more loading code
  in the root task.
- **Messages packed by hand**: nothing to replace later, but each side's layout could drift.

## Consequences
- A program's processes are the requester's, so killing the manager costs only loads in progress.
- The builder and the manager reserve part of their free range for each program they map, and never give it
  back; the 1 TiB range is plenty for now, but a manager running for long will need ranges it reuses.
- The supervisor and the root task each have code for sending a `LoadRequest`; 6d's `std/os` launching
  replaces both.
- A program the supervisor starts can't be granted `entropy` yet: the entropy service takes its clients
  from its startup grants only.
- Kernel tests: `test_control` starts a thread in its target, refuses one in a space outside its subtree,
  gives the target a handle, and refuses giving a process its own owning handle, or a handle without
  `RIGHT_TRANSFER`. Boot tests start the first services, and keep `hello` running after the manager is killed.
