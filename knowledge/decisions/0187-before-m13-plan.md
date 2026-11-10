# 0187: Before M13, What Was Promised and Not Built, Planned

Status: accepted; C1 built, C2 and C3 to be planned with the project's owner
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
