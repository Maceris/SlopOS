# 0093: The First System Services, as Built

Status: accepted
Date: 2026-10-28
Related: `0092` (the plan for M9), `0037` (scheduling in user space), `0011` (budgets), `0077` (connectors and restarts),
`0058` (the debug log), `../design/observability.md` §2, `../design/scheduling.md`, `../roadmap.md` M9

## Context
M9's first stage (9a, `0092`): the scheduler service, the clock service, the events service, and restarts for the
services the supervisor starts. The kernel's CPU budgets were its own (`src/kernel/budgets.hsc`), with no handle to hold
or split one, so every user thread ran in the background band; user mode couldn't reach I/O ports, where x86-64's RTC
is; and every program logged lines through the debug log. Chosen with the project's owner:
- **CPU budgets as kernel objects**, like memory budgets: the root task gets the root budget; `cpu_budget_create` splits
  a child off one, with a priority, a period and a share; `process_create` takes the budget a process's threads run
  on; `cpu_budget_set` adjusts one later. The scheduler service holds what it split; if it ends, every budget keeps its
  last parameters (`0037`).
- **I/O port objects**: the platform capability makes one for a range of ports, which the platform service gives to
  what needs it, as it gives device memory; reads and writes are system calls on it.
- **The clock service gives UTC**: nanoseconds since 1970 without leap seconds, the RTC's reading at start plus the
  monotonic clock since; setting it is on a protocol of its own, which the administrator holds.
- **The events service keeps records in memory, then on the system volume** once the storage manager is up, with a
  budget per source; queries and `Watch` read both.
- **Every program's events connection is a startup grant**, which whoever starts it asks the events service for, as the
  debug log is given now; `base`'s SlopOS logger writes `context.logger`'s records there (`typed log records`,
  `../hemera-proposals/typed-log-records.md`). The debug log stays for the root task and boot.
- **The supervisor restarts every service it starts**, by the drivers' policy, unless `system_config` says not to;
  clients redial through connectors (`0077`). The storage manager's restart restarts its servers, and locks encrypted
  volumes again.
Delivered in four parts, each committed as it passes, with one report at the end: 9a1 the kernel's CPU budget and I/O
port objects, 9a2 the scheduler and clock services, 9a3 the events service and the logger, 9a4 restarts. This record
grows with each part.

## Decision
### 9a1: CPU budget and I/O port objects
- **CPU budgets** (`src/kernel/cpu_budgets.hsc`, ABI 7): a `CpuBudget` object holds the kernel's CPU time accounting
  (`CpuTime`, `budgets.hsc`, as before: a priority, time per period, sporadic-server refills), its parent, and its
  share, time over period in millionths of a CPU. The root, made once the CPUs are up and the kernel's own tests are
  done, is every CPU's whole time at priority 255; the root task gets a handle to it (grant `cpu_budget`) without
  `RIGHT_CPU_BUDGET_SET`. `cpu_budget_create` splits a child off a budget with `RIGHT_CPU_BUDGET_SPLIT`, its share out
  of what its parent has left and its priority at most its parent's (`BudgetExceeded` otherwise); `cpu_budget_set`
  changes one within the same limits and above its own children's; `cpu_budget_info` gives its priority, period, time,
  share and its children's.
- **Who runs on what**: every process runs on its creator's budget, the root task's processes on the root, and its
  threads with it; the system call table is append-only, so rather than a new parameter of `process_create`,
  `process_set_cpu_budget` moves a process and its threads to another budget (`RIGHT_PROCESS_THREADS` and
  `RIGHT_CPU_BUDGET_BIND`). A destroyed budget's threads, processes and children go to its parent, which gets its
  share back; a tick still charging it is safe, as its memory stays until every CPU has passed a quiescent point. The
  tree's shape changes under `kernel.cpu_budgets_lock`; what a budget has left, under its own lock, as the scheduler
  charges it.
- **I/O ports** (`src/kernel/io_ports.hsc`): `io_ports_create` with the platform capability makes an `IoPortRange`;
  `io_port_read` and `io_port_write` reach a port in it, 1, 2 or 4 bytes wide (`InvalidArgument` otherwise, and for
  any range where the architecture has no ports). The arch interface has `has_io_ports`, `port_read` and `port_write`;
  AArch64's say there are none.
- **The root budget is never charged**: its threads can't use more than every CPU has, and charging it let refills
  merged past `MAX_REFILLS` hold back time it had, so it ran out now and then.
- **A thread whose budget comes back is moved up at the next tick** (`scheduler.hsc`, `relevel`): a thread's level was
  worked out only when it was queued, so one queued in the background band while its budget was spent waited behind
  every thread running at that budget's priority. A budget its threads keep every CPU busy with never runs out again,
  so on AArch64 `test_threads` and `test_control` waited for good once the root budget had run out. The kernel's
  `test_budgets` now has two threads sharing a budget, which share its time alike only with the fix (a quarter to
  three quarters without it).
- **A launch watched from the start** (`os.launch`'s `LaunchWatch`): the root task bound its test's end only once the
  launch returned, so a test that ended at once, as `test_protocols` and `test_io_ports` can on AArch64, was gone
  before it was watched (the root task's exit 23). The binding is now made before the manager starts it.
- **The root task's grants**: up to 64, its startup block sized for all of them; 32 had been the most, which two more
  test programs and the CPU budget passed, silently dropping the last boot modules. A grant past the most is now
  reported.
- **Tests**: `test_cpu_budgets` splits a child and a grandchild, is refused a share past the root's, a priority above
  the parent's and a period of 0, sets the child around its grandchild's share, is refused setting the root, puts a
  process on the child and destroys it, the process and grandchild going to the root and its time coming back whole.
  `test_io_ports` reads the RTC's status register A through ports 0x70 and 0x71 on x86-64, its divider 32.768 kHz's,
  and is refused ports outside the range and a width of 3; on AArch64, every range is refused. `boot_tests.py` runs
  only some tests with `SLOPOS_BOOT_TESTS`.

### 9a2: The scheduler and clock services
Chosen with the project's owner: budgets come from `system_config` and are bound at launch, by whoever starts a service
asking the scheduler service for it by name; the clock service is the real-time clock's driver, which the platform
service finds and the supervisor starts like a driver; programs read the time from a startup grant; the supervisor
holds the connection that sets it, for now.
- **The scheduler service** (`src/services/scheduler`, the `scheduler` protocol): the root task starts it through the
  manager right after the process manager, with a handle to the root budget that can split and bind. It splits a budget
  off for each service whose `system_config` entry has a `CpuShare` (`cpu`: the console and the virtio console and
  keyboard drivers, `INTERACTIVE_CPU`, a tenth of a CPU each at priority 200) and one more, the default
  (`DEFAULT_CPU`, half a CPU at priority 100), for every other service. `BudgetFor(name)` gives a handle that can only
  bind, to the service's budget or the default. The entropy service and the process manager, which the root task
  starts before it, stay on the root budget with the root task; so do the tests `test_program=` runs.
- **Bound at launch**: `os.launch` takes `LaunchOptions` (Hemera's `std/os`), which replaced its `watch` parameter: a
  `LaunchWatch`, a CPU budget, which it moves the process to with `process_set_cpu_budget` before the manager loads it,
  and the clock page. The root task launches the platform service and the supervisor so, and gives the supervisor a
  connection of its own to the scheduler service (grant `scheduler`), which it asks for everything it starts. What the
  storage manager starts runs on the storage manager's budget.
- **The supervisor watches what it starts from its launch**: it bound each program's end only once the launch
  returned, as the root task had (9a1), and binding a port to a process that has already ended never fires; on budgets
  the timing changed enough that a fast `edu_dma` ended first now and then, and the supervisor waited for it for good.
  Each launch now watches its end under the key of the entry it's to have (the next one, or a restart's), and a launch
  that fails gives the key up.
- **The clock page** (Hemera's `runtime.SlopOsClockPage`): a page holding a UTC time, in nanoseconds since 1970 without
  leap seconds, at a monotonic reading, under a sequence its writer makes odd while it writes and even after, 0 until
  the time is known. Rather than a connection to the clock service, which `base` can't speak protocols over, every
  program the supervisor starts after the clock service is given the page read-only as its grant `clock`, whatever its
  entry takes; `base`'s SlopOS runtime maps it the first time the wall clock is read, and gives the page's time plus the
  monotonic clock since its reading, read again if it was being written, `NotSynchronized` while the sequence is 0, and
  `Unavailable` without the grant. The supervisor makes the page; only the clock service can write it.
- **The real-time clock** (the platform protocol's `ClaimClock`, major version 3): on x86-64, the MC146818 at ports 0x70
  and 0x71, as an `IoPortRange`, unless the FADT's `IAPC_BOOT_ARCH` says there's no CMOS RTC; on AArch64, the device
  tree's `arm,pl031`, as device memory, disabled or not, since UEFI marks it disabled for its runtime services, which
  SlopOS doesn't call. One client claims it, and may claim it again, made anew, for a restart.
- **The clock service** (`src/services/clock`, the `clock_setting` protocol): it reads the clock when it starts, to the
  second, and writes that time on the page at the monotonic reading; `Set(utc)` writes the clock and then the page, and
  is refused for a year outside 2000 to 2099. An MC146818 is read outside its update, until two reads agree, in BCD or
  binary and 12 or 24 hours as its status register B says, and written with `SET` held; its century is register 0x32's
  if that holds 19 to 21, and 20 otherwise, as grants can't carry the FADT's century index. A PL031 is its 32-bit
  seconds (`RTCDR`, `RTCLR`), started if it wasn't.
- **The supervisor and the clock**: it starts the clock service first, before the boot set's drivers, so everything
  after it gets the page; and starts it again, as a driver, with the clock claimed again, if it ends other than with 0.
  It keeps the other end of the clock service's listener; `test_clock` on the command line sets the time to
  2030-01-02T03:04:05Z before anything else starts.
- **Tests**: "starts the first services" expects the scheduler's line, with its budgets, and the root task's 34
  grants; "keeps the time with the real-time clock, and sets it", on both architectures, expects the clock claimed, the
  time set and read back, and hello saying the wall clock's date is 2030-01-02, through `base`'s runtime and the page.
  A restart of the clock service isn't tested yet (9a4).
- **Hemera**: a constant struct or array holding an optional of a struct, like `system_config`'s `cpu`, failed to lower,
  each `Some` being built in its own shape; those constants now take their parts' shapes (`MakesOptionalConstants`).

### 9a3: The events service and the logger
Chosen with the project's owner: `base` writes the records itself, the schema code and a BLAKE3 moving into it; until
the bundle store (9b) a ring carries each format string's text and each type's schema the first time a process uses
it; the events service shows every record on the debug log too, and hello and the clock service log through `base`
now, the other services moving later.
- **The ring** (Hemera's `runtime.SlopOsEventsRing`, `base/runtime/slop_os_events.hsc`): 16 KiB of shared memory per
  program, a header and 8-byte-aligned entries that never wrap (a `Pad` fills the end): a `Format` (an image offset
  and its text), a `Schema` (a hash and its bytes), a `Record` (monotonic time, level, the format string's offset or,
  for one that isn't a literal, the string as its first argument, then each argument's schema hash and its value as
  `schema_write_value` writes it) and `Dropped` (records the writer dropped while the ring was full, the newest).
  `written` and `read` only grow. A reader sets `waiting` before it waits, and a writer that finds it set clears it and
  writes one byte on the doorbell channel, so a record is no system call unless the service sleeps.
- **`base`'s SlopOS logger** (`SLOP_OS_LOGGER`, the hosted context's on SlopOS): maps the grants `events` (the ring's
  memory and its doorbell) the first time it logs, and keeps which format strings and types (up to 128 and 64) it has
  given; a process without them logs as the standard logger does, which on SlopOS writes nowhere. `base` gained
  `schema_write`, `schema_hash`, `schema_write_value` (std's `schema` calls them now) and `hash_blake3`, a plain BLAKE3
  that `Hosted.HashesSchemas` checks against std's at chunk and block edges. std's `schema.render` reads a value back
  by its schema as `output_format` writes it, the same scenario checking each kind and option; a pointer renders as
  `<pointer>`, its address gone.
- **The events service** (`src/services/events_service`, the `events` protocol): `Open(name)` makes a ring for a
  program its client starts, the source labeled with that name (lowercase letters, digits and underscores), several
  rings to a source as a service's processes come and go; each ring is an instance, and its records are numbered
  with the source's. It reads each ring when it's woken, shows each record on the debug log as `source: text` (`source:
  level: text` past info), and keeps them as they'd be stored, behind a `StoredStart` (this boot's random number and
  the first record's number) and a `StoredInstance` per batch. Until `Store` gives a directory, a source keeps up to
  32 KiB in memory, dropping records past it; from then on each source's go to `<source>.events` there, what memory had
  first, opened, appended and closed each time; a file past 256 KiB is renamed `<source>.old` and the next started with
  every format string and schema its records could need. `Query(source, from, level, wait)` gives one record of this
  boot at a time, rendered, from the .old file, the file, then memory, saying whether it was stored; one with `wait`
  is held until there's a record for it.
- **The supervisor** starts the events service first, then the clock service, and asks it for a ring for everything it
  starts after, by the service's name, which `os.launch` gives as the grants `events` (`os.LaunchOptions.events`); once
  the storage manager has given the system volume, it gives the events service the volume's `events` directory, made
  if it isn't there.
- **The doorbell needs a read first**: a channel's next message wakes a port only after a read has found it empty, so
  the service reads each doorbell once as it opens the ring; without it, a program that wrote while the service slept
  was never read, which only a boot with nothing else going on showed.
- **Tests**: "keeps every program's log records on the system volume once it's there", on both architectures: a query
  for hello's first record, held from before hello starts, is answered; hello's first record and the clock service's
  second are read back from the system volume, the clock's written there from memory when `Store` came. The clock and
  hello lines the other tests expect now come through the events service.
- **Not yet**: queries by the arguments' typed fields, records of earlier boots, `Watch` as its own request (a waiting
  query stands in), a budget per source paid by its owner (the service pays for every ring), and the root task's
  programs, which keep the debug log.

### 9a4: Restarts
- **Everything the supervisor starts is started again** when it ends other than by exiting with 0, as drivers were, up
  to three times a minute, unless its `system_config` entry is `not_restarted`, as the disk check is, whose checks
  write to the disks once a boot. Each start function takes the entry it restarts into (`place`); a service with a
  listener gets a new one, which its clients' connectors dial (`0077`).
- **The events service** is given the system volume's `events` directory again. Rings it gave the last one's programs
  went with it: their records are lost until they're started again (their writers find the doorbell's other end gone,
  and keep writing to a ring nothing reads). It draws a new boot number, so its queries don't reach records stored
  before its restart.
- **The storage manager**: killing it destroys its subtree, its partition, FAT, container and volume servers with it,
  so a restart starts them anew as they're asked for, and its encrypted volumes are locked again, as only their
  volume servers held their keys. The supervisor asks the new one for the system volume and gives the events service
  its `events` directory again.
- **A restart waits for its budget** (`wait_for_budget`, up to two seconds): what the last process had comes back once
  its subtree is gone and a grace period has passed, and the storage manager's 64 MiB can't be split off the
  supervisor's 96 MiB twice.
- **The supervisor kept every program's budget alive**: `os.launch` gives the launcher a handle to the program's
  budget, which the supervisor never closed, so a killed program's budget never came back; closing it at once destroys
  the program's budget and the program with it. Each entry keeps it now, closed when the program ends.
- **Tests**: "starts the events service, the clock service and the storage manager again when they're killed", on both
  architectures, from the disk: with `test_restart_services`, once everything has started, the supervisor kills each in
  turn and waits for it to be back; the clock service sets the time again, the events service has the new clock
  service's records, and the storage manager gives the system volume again. That encrypted volumes are locked again
  isn't checked by a test.

## Alternatives considered
- **A CPU budget set per process**, by its handle: less kernel work, but nothing to split or hand on, and a budget
  couldn't cover several processes.
- **TSS I/O permission bitmaps**: `in` and `out` straight from user mode, but switched with every process that has one,
  and x86-only state in the arch interface.
- **The kernel reading the RTC once at boot**: no ports in user space, but the RTC never read again or set.
- **Reading the time over a connection to the clock service**: one protocol for reading and setting, but `base` would
  have to speak SlopOS's protocols, and every read would be a round trip.
- **A CPU budget as an entry parameter**: explicit, but every service's entry would change, and the launcher would
  still have to ask the scheduler for it.
- **Records in memory only until M10**: less now, but nothing kept across a restart of the service.
- **An events channel as an entry parameter**: explicit, but every program that logs would have to say so.
- **The logger in std, installed by each program**: no move into `base`, but a program that didn't install it would
  log nowhere.
- **Every record carrying its format string and schemas until 9b**: no definitions to keep track of, but every record
  far bigger.
- **Every service moving to the logger in 9a3**: the debug log left to the root task at once, but a far larger change
  for the same tests.
- **Restarting only services marked stateless**: safer at first, but every other service ending would stay fatal.

## Consequences
- 9a is done: every service the supervisor starts runs on a CPU budget it was configured for, can read the wall
  clock, logs records the events service keeps on the system volume, and is started again if it fails.
- What the root task starts (the entropy service, the process manager, the scheduler, the platform service, the
  supervisor) still logs through the debug log and isn't restarted; a supervisor of its own for them is later work.
- 9b's bundle store can replace the format strings and schemas the ring carries, and the events service's queries can
  reach earlier boots once a boot's number is kept rather than drawn.
- Every other service moves from `log_line` to `base`'s logger as it's next changed.
