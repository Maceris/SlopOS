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

## Alternatives considered
- **A CPU budget set per process**, by its handle: less kernel work, but nothing to split or hand on, and a budget
  couldn't cover several processes.
- **TSS I/O permission bitmaps**: `in` and `out` straight from user mode, but switched with every process that has one,
  and x86-only state in the arch interface.
- **The kernel reading the RTC once at boot**: no ports in user space, but the RTC never read again or set.
- **Records in memory only until M10**: less now, but nothing kept across a restart of the service.
- **An events channel as an entry parameter**: explicit, but every program that logs would have to say so.
- **Restarting only services marked stateless**: safer at first, but every other service ending would stay fatal.

## Consequences
