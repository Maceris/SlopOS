# 0187: Before M13, What Was Promised and Not Built, Planned

Status: accepted; built
Date: 2026-11-09
Related: `0011` (memory budgets), `0037` and `0093` (CPU budgets and scheduling), `0096` (robustness, R6), `0185`
(12h, a child CPU budget for each shell job), `../design/scheduling.md`, `../design/services.md`, `../roadmap.md`
Before M13

## Context
The roadmap's Before M13 stage gathers what earlier plans promised and nothing schedules: sessions' CPU budgets (C1),
Hemera's atomics intercepted for a model checker (C2), and R6's schedule exploration of the kernel's lock-free code on
it (C3). C2 is planned in Hemera, with its owner, so this record plans C1 now and C2 and C3 once those choices are made.

A survey for C1 found:
- **The scheduler service** splits the root CPU budget into the default budget and one for each service the system
  configuration gives a share (`CpuShare`). It gives only bind-only copies away (`RIGHT_CPU_BUDGET_BIND` and
  `RIGHT_TRANSFER`), to the root task and the supervisor, which launch each service on its own.
- **The root is fully split**: the default's half a CPU and five interactive services' tenth each.
- **Sessions have no share**: the session manager runs on the default budget, and so does every program of every
  session, since its launches give no CPU budget; the shell has nothing to split for its jobs (`0185`, 12h).
- **A budget's run time isn't kept**: `CpuBudgetInfo` has its share and what was lent on it, and `process_cpu_info` a
  process's time, but nothing says what ran on a budget.

## Decision: C1, Sessions' CPU Budgets
- **A share for sessions** in the system configuration: the `sessions` service gets `SESSIONS_CPU`, a tenth of a CPU
  at priority 150, between the default's 100 and the interactive services' 200, taken from the default, which goes from
  half a CPU to four tenths. `Service.cpu_splits` marks a service that splits its budget for others, which only
  `sessions` does.
- **The scheduler gives a budget that can be split** to whoever asks for one of a service with `cpu_splits`
  (`SplittableBudgetFor`): a copy with `RIGHT_CPU_BUDGET_SPLIT` besides bind and transfer, so its children can be made
  but its own share isn't changed. Its clients are the root task and the supervisor, which already decide every
  service's budget.
- **The supervisor gives it to the session manager**, as its grant `cpu_budget`, besides the bind-only copy it runs on.
- **Each session gets a child of it**, made at login, its share the user's `SessionSettings.cpu_share` in millionths
  of a CPU, or else a quarter of the sessions' share, so four sessions, the most there are, fit. Its priority and
  period are the sessions'. Every program of the session runs on it; it's destroyed when the session ends, what runs
  on it going to the session manager's. One that can't be made is logged, and the session runs as before.
- **The shell gets its session's budget to split**, as its grant `cpu_budget`, and each job runs on a child of it: an
  eighth of the session's share, at its priority. A job whose child can't be made runs on the shell's. The child is
  destroyed when the job ends.
- **A budget's run time**: the kernel counts the nanoseconds its own threads ran on it (not its children's), given as
  `CpuBudgetInfo.ran` (ABI 14). `processes` shows each session's budget and each job's: share and time.
- **These are guarantees, not limits**: a budget past its time runs in the background band, so an idle CPU is still
  used; what a share bounds is what one session or job takes from another when the CPUs are busy.
- **Tests:** two sessions each run a program that spins, and each session's budget ran, not the session manager's;
  a job's time shows on its own budget.

## Alternatives considered
- **Sessions as children of the default budget**: the default's services would lose time to sessions without the
  configuration saying so; a share of their own is explicit.
- **The session manager asking the scheduler itself**: it has no connection to the scheduler, and a splittable budget
  is authority the supervisor should decide on, as it does every service's budget.
- **Each session's share the whole sessions' share**: children's shares can't pass their parent's, so four sessions
  couldn't all have one.

## As Built: C1
- **As planned**: `SESSIONS_CPU` (priority 150, a tenth of a CPU, the default down to four tenths), `cpu_splits`, the
  scheduler's `SplittableBudgetFor`, the supervisor's `cpu_budget` grant to the session manager, a child for each
  session from `SessionSettings.cpu_share` or a quarter of the sessions', its programs launched on it, and the shell
  given it to split. The scheduler's split is six budgets and the default, the root's whole CPU still.
- **A child for each program the shell starts**, rather than each job: a job's programs each get an eighth of the
  session's share, kept by its call and destroyed when the call ends, so a pipeline's programs each show their own time.
- **`CpuBudgetInfo.ran`** (ABI 14): what ran on a budget, counted where the scheduler charges a thread's time.
  `processes` shows the session first, its budget's share and time, then each program, and a job's share and time.
- **Tests**: `test_session_cpu` checks, once two sessions are logged in, that each has a budget of its own of a quarter
  of the sessions' share, and that the first's programs ran on it; a boot test starts a job and finds its share, an
  eighth of the session's, and the time run on it in `processes`.
- **Found on the way: long terminal output was dropped.** A terminal connection was made with the default ring, 1
  KiB, whose messages take under 500 bytes, while `write` sends up to `MAX_TEXT_BYTES`, 2 KiB, at a time, so any line
  or table longer was silently not sent: `processes`, two columns wider, stopped showing. Terminal connections are made
  with the protocol's `RING_BYTES`, 8 KiB, now.
- **Found by the system call fuzzer: a race in the scheduler's accounting.** `account` read a thread's budget object
  twice without `kernel.cpu_budgets_lock`, checking it wasn't 0 and then adding to it, while another CPU could take the
  thread off it between the two: the fuzzer's destroyed budgets made it fault at the end of a run. The `run_by_others`
  count of 12h had the same two reads; both now use one read, the object's memory kept until a quiescent point.

## Decision: C2, Hemera's Atomics Intercepted
Chosen with the project's owner: **weak memory modelled too**, as `loom` does, not only interleavings; and interleavings
chosen **systematically within a preemption bound, and at random from a seed** for longer runs.

A survey of Hemera found its atomics generated from one table (`base/intrinsics/atomics.hsc`): loads, stores,
exchanges, compare-exchanges and read-modify-writes for every integer width, the memory order in the name (seq_cst
unsuffixed, `_acquire`, `_release`, `_acquire_release`, `_no_fence`); fences by hand; `spin_hint`; and the runtime's
`wait_on_value` and wakes. The compiler emits all of them in one place (`emit_intrinsic`). Fibers can run several of a
test's threads on one carrier, switched where a scheduler chooses.

In four parts, in Hemera:
- **C2a, the option.** `TargetOptions.model_checked`: each atomic operation, fence and `spin_hint` becomes a call to the
  runtime (`base/runtime/model.hsc`), with its address, operands, width and order. The call does the operation itself,
  since a weak-memory checker chooses what a load reads; outside a check it does it as the hardware would. Without the
  option nothing changes: the calls aren't emitted.
- **C2b, the checker** (`std/testing`'s model): a test's threads are fibers on one carrier, switched only at those
  calls and at waits and wakes. Every interleaving within a preemption bound (2 by default) is tried, depth first, or
  schedules are drawn at random from a seed; a failure prints its schedule, which replays it.
- **C2c, weak memory**: each atomic location keeps its stores in modification order, each with its thread's vector
  clock; a load may read any store coherence and its order allow, that choice another of the search's branches;
  acquire and release synchronise through the clocks, seq_cst operations and fences keep one total order. A location's
  first value is what memory held when it was first touched; the newest store is also written to memory, for code that
  reads it plainly.
- **C2d, std's lock-free code**: `SpinLock`, the fiber pool's local queues and stealing, `SharedPtr`'s counts, as
  hosted tests in the model-checked build; what they find fixed and kept as tests.

Not modelled: plain (non-atomic) accesses racing with atomic ones, which `loom` models only through its own cells, and
consume ordering, which Hemera hasn't got.

## As Built: C2
- **C2a**: `TargetOptions.model_checked` and `--model-checked`, the hooks in `base/runtime/model.hsc` and
  `CarrierBlock.model`. base's own atomics aren't routed to the hooks: they're the runtime's machinery, its allocator's
  and `morestack`'s among them, and a hook switching fibers in the middle of one broke the heap.
- **C2b**: `testing.check_model`, `spawn` and `join` (`std/testing/model.hsc`), as planned. A thread at a spin hint or a
  join isn't chosen again until another thread changes memory or ends, unless it last read an old store, so two waiting
  threads don't hand the turn to each other for ever; the schedule's choices print as `ModelOptions.replay` takes them.
- **C2c**: the memory model (`std/testing/model_memory.hsc`), as planned, with two choices closer to CPUs than to C11:
  a sequentially consistent load reads the newest store, and a thread's first load after a spin hint reads the newest,
  as a waiting thread relies on stores becoming visible. A location whose memory no longer holds its newest store, as a
  plain write or reused memory leaves it, starts again. The model's work is done on the driver's stack, as the hooks run
  on the test's threads' stacks, which it overran.
- **C2d**: Hemera's `model_checking` scenario: a lost update found; atomic and `SpinLock` increments, `SharedPtr`'s
  counts and upgrades, and the fiber pool's carrier queues with a thief, correct under every schedule; relaxed message
  passing found, released passing not. Each of std's was checked by weakening it on purpose: a relaxed `release` fails
  210 schedules, a `take_local` without its compare-exchange 2592.
- **Model-checked tests need stack checks that grow fibers' stacks** (`--stack-check=morestack`): without them, a test's
  threads, which are fibers, overran their first segments.
- **Found on the way: the LLVM patches couldn't be applied again** on a reconfigure: an earlier patch a later one
  overlaps doesn't reverse on its own, so it was taken as not applied. They're checked from the last back now.

## Decision: C3, R6's Schedule Exploration
The roadmap named the frame caches and the slab magazines, but neither has an atomic: both are per-CPU or under a lock.
The kernel's lock-free protocols are elsewhere, and in its own package, which isn't built hosted. So C3 takes each
protocol's core into a package of its own, as `frames` and `slab` are, which the kernel uses and a hosted test builds:
- **The handle entry's tag** (`handles.hsc`): lookups read an entry without the table's lock, its tag before and after;
  closes and installs change it under the lock. Checked: a lookup racing a close and the entry's reuse sees the old
  entry whole, or fails, never one entry's object with another's rights.
- **The TLB shootdown's handshake** (`shootdown.hsc`): one at a time, each other CPU asked to flush and counted down.
  Checked: an initiator doesn't go on before every CPU has flushed its batch, and two initiators at once take turns,
  each flushing the other's batch while it waits, never waiting on each other.
- **The tests are built model-checked**: the build package's tests target takes `model_checked=on`, with stack checks
  that grow fibers' stacks, which `unit_tests.py` passes. A model check in a build without it runs one schedule.

Run-queue stealing, quiescent states and the events and trace rings follow the same way, in a later stage if they're
worth it.

## As Built: C3
- **`kernel/handle_entries`**: `HandleEntry` and its tag, and `start`, `fill`, `read`, `empty` and `peek`, which
  `handles.hsc`'s install, lookup, remove and freeing use. Its kind and rights are plain numbers, so it needs nothing of
  the kernel's.
- **`kernel/shootdowns`**: the handshake's `Handshake` (`running` and `pending`) and its steps, `try_start`,
  `expect_flushes`, `request`, `is_requested`, `flushed`, `all_flushed` and `finish`, of which `shootdown.hsc`'s
  shootdown and flush are made; the batch, the IPIs and the flushes stay the kernel's. Its test runs the kernel's steps
  on two CPUs with a number for a batch, each flushing whatever it's asked to while it waits to start and once it's
  done, as an idle CPU takes the IPI.
- **Found: a lookup could take one handle's object with another's tag.** An entry's object and generation were plain
  fields, read without the lock between two loads of its tag. A close's release store of the next generation orders
  what's before it, not the reuse's writes after it, so a lookup could read the reuse's object, then the old tag again,
  and take them together. The CPUs SlopOS runs on don't do it, as the lock between the close and the reuse orders them
  there, but C11 doesn't promise it. The fields are relaxed atomics now, so the race is defined, and `fill` fences
  (release) before it writes them: a lookup that reads one then sees the close's tag. Without the fence the check
  fails in its 1300th schedule.
- **The shootdown's handshake was right**: an initiator goes on only once every CPU flushed its batch, and two at once
  take turns, under every schedule with two preemptions. A flush's decrement weakened to relaxed fails in the 95th.
- **Found in the checker: spinning threads deadlocked, or spun for ever.** A thread at a spin hint was taken as waiting
  whenever its last load read the newest store, though its loop hadn't read everything it checks since the last change:
  a CPU reading its flush request, then whether every shootdown had finished, was left waiting after the last one had,
  and the check reported a deadlock. And a spinning thread could read an old request for ever, as only its first load
  after a spin hint read the newest. Now a spin hint waits only once nothing changed since the thread's previous one,
  and at a spin hint a thread sees every store made so far (Hemera's `docs/testing.md`, Model Checking). Before, the
  check stopped at its 500,000 executions; now it explores every schedule in about 3 seconds.
- **The tests target takes `model_checked=on`**, which `unit_tests.py` passes; built without it, a check runs one
  schedule, in which the shootdown's spinning CPUs never end, so its test is only run model-checked.
- **Failures go to the test's `T`** from its threads, through its address, so the first failing schedule is reported
  with its replay; `handle_entries_test` and `shootdowns_test` are in `RAW_POINTERS` for that address.
