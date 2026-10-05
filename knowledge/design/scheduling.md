# Scheduling and CPU Budgets

Status: **proposed**. Answers the *Kernel* open questions on scheduler policy and CPU-budget
scheduling, including lending a client's budget to a server. Builds on `0011` (separate CPU
budget objects) and `0023` (cheap threads). The starting direction was scheduler policy
outside the kernel, in the spirit of Linux's `sched_ext`.

## Goal: Soft Real-Time, Not Hard Real-Time

- **Not a goal:** hard real-time guarantees (proven deadlines, admission analysis for
  control loops).
- **A goal:** soft real-time. Audio and similar work must not pop or glitch because of the
  kernel. Concretely:
  - a high-priority thread that becomes runnable runs promptly, because kernel
    non-preemptible sections are short and bounded (§2, "Latency");
  - a runaway high-priority thread can't starve the rest of the system.

## 1. Where the Policy Lives

Three ways to put scheduling policy outside a kernel:

| Approach | Examples | Problem |
|---|---|---|
| **The user-space scheduler makes every decision** (upcalls on every block, wake and tick) | Scheduler activations, some L4 user-level scheduling research | A process switch per scheduling decision. If the scheduler process stalls, so does everything. |
| **Policy code loaded into the kernel** | Linux `sched_ext` (BPF), SPIN | Needs a verifier or sandbox to keep the kernel safe. SlopOS has none, and Hemera code loaded into the kernel is fully trusted. |
| **Fixed kernel mechanism, user space sets its parameters** | seL4 MCS, Linux `SCHED_DEADLINE`, cgroup weights | The policy can only be expressed through the parameters the mechanism offers. |

**Recommendation: the third, with `sched_ext`'s safety property built in.**
- The kernel runs a small, fixed dispatcher on every CPU (§2) and **never waits on user
  space to make a decision**.
- A **scheduler service** in user space holds the root CPU budget (from the root task,
  `0012`). It splits it into budgets for sessions, services and drivers, sets their
  parameters, watches usage statistics, and adjusts parameters on a slow timescale
  (milliseconds to seconds).
- If the scheduler service crashes, the system runs on the last parameters until the
  supervisor restarts it. This is the property `sched_ext` gets from its watchdog, here
  without the watchdog, because the policy holder is never on the dispatch path.
- A later `sched_ext`-like extension (policy code in the kernel) stays possible if a
  verifiable subset of Hemera ever exists. Not planned.

## 2. The Kernel Mechanism

A **CPU budget** (`0011`) is a scheduling context:
```
CpuBudgetParams :: struct {
    priority: u8,              // 0 = lowest
    period: Duration,
    budget: Duration,          // CPU time per period, summed over all CPUs
    on_exhausted: Exhaustion,  // only Demote at first (see below)
    limit: Duration?,          // optional total lifetime quantity, for lending (§4)
}
Exhaustion :: enum {
    Throttle,                  // hard reservation: don't run until the next period
    Demote,                    // soft: keep running at the background priority
}
```
- **Priority belongs to the budget, not the thread.** A thread runs at the priority of the
  budget it's currently bound to. That's what makes lending also solve priority inversion
  (§4).
- **`Throttle` isn't implemented at first.** Hard reservations matter only for hard
  real-time, which isn't a goal. The enum keeps the variant so it can be added later
  without an ABI break.
- **Dispatch:** each CPU runs the highest-priority runnable thread whose budget has time
  left, round robin within a priority. When a budget runs out, its threads either wait for
  replenishment (`Throttle`, later, if ever) or drop to the background priority
  (`Demote`, for everything else). The background band is round robin, so the CPU is never
  idle while anything can run.
- **Proportional sharing falls out of `Demote`.** Ordinary programs share their session's
  `Demote` budget. Each session gets at least its budget/period share when the machine is
  busy, and everything competes round robin for idle time. That's weighted fairness without
  a fair-queuing algorithm in the kernel.
- **Replenishment** uses the sporadic-server rule (seL4 MCS), so a budget can't save up time
  across periods and burst past its share.
- **Admission is checked only when a budget is split.** A child's utilization
  (budget/period) can't exceed what remains of its parent's. At run time budgets are flat
  and dispatch is O(1), with no hierarchical scheduling as in cgroups.
- **Soft real-time work gets a high-priority `Demote` budget** sized to its need (an audio
  mixer: a few percent of one CPU). Within that budget it preempts ordinary work at once. If it
  runs away, it drops to the background band instead of starving the system.
- **Budgets shared by threads on several CPUs** are charged with an atomic subtract at
  ticks and switches. Exhaustion is noticed by each CPU at its next accounting point, so the
  overrun is bounded by one tick per CPU. Accepted.

### Latency
Glitch-free audio depends more on the kernel's worst-case latency than on the policy:
- **Bounded non-preemptible sections.** Long kernel operations have preemption points
  (`kernel.md` §2, "Long operations"), and interrupts are disabled only for short, bounded
  windows.
- **Wakeup to run:** waking a higher-priority thread on another CPU sends an IPI at once.
  On the same CPU, the wake preempts on return from the kernel.
- **Timers:** deadline packets with zero slack fire on time. Slack is only for coalescing
  work that tolerates it.
- **IRQ path:** IRQ → port packet → driver thread at the driver's budget priority, with no
  deferred kernel work in between.
- **Measured, not assumed:** a latency test (in the spirit of Linux's `cyclictest`) runs in
  CI once SlopOS boots. It reports worst-case wakeup latency of a high-priority thread under
  load. The target number is set once there is something to measure.

## 3. What Threads Run On

- By default a thread is bound to its creator's current budget (`0023`, `cpu: null`). Most
  programs never touch a CPU budget, which is what `0011` intended.
- A process given its own budget (a driver, a service, a real-time task) binds its threads to
  it.
- **Switching a thread's binding must be cheap**, since a fiber-based server switches budgets
  when it switches between connections' fibers (§4). Two options:
  - a `thread_bind_budget(budget)` syscall;
  - **proposed:** the binding is a handle stored in a per-thread page the kernel and the
    thread share. The kernel resolves it at its next accounting point (tick, block, switch),
    and if the handle is stale or lacks the right, falls back to the thread's own budget.
    No syscall per fiber switch. An invalid handle costs the thread its loan, never the
    kernel's safety.
  - The fiber scheduler writes the binding on its resume path, just before
    `intrinsics.fiber_resume`, and finds its own state through the carrier block
    (`scheduler_data`).

## 4. Lending Budgets for Calls

seL4 MCS lends a client's scheduling context to a *passive* server for the duration of a
synchronous call. SlopOS has no kernel-level call (IPC is asynchronous, `ipc.md`), so lending
is explicit, and is set up between client and server through the protocol: a negotiation.

**The mechanism** is just budgets and handles:
- The client splits a **child budget** off its own: a quantity (`limit`, say 5 ms in total),
  usually `Demote`, at the client's priority.
- It sends the server a non-owning handle to it, either once per connection or with a
  request.
- The server binds the thread or fiber doing that client's work to it, so the work is
  charged to the client and runs at the client's priority. Priority inversion through a
  server goes away.
- The client still **owns** the lent budget. It can destroy it at any time, which revokes
  the loan; the server falls back to its own budget. A loan can never cost more than its
  `limit`, and unused time returns to the client when the loan is destroyed.

**Levels of negotiation**, from simplest to richest:

| Level | What happens | Good for |
|---|---|---|
| 0. No lending | The server runs on its own budget and rate-limits each connection itself | Cheap requests; servers that don't care |
| 1. **Per-connection loan** (proposed default) | The client attaches a loan when it connects. The server's `std` framework binds it whenever it runs that connection's fibers. The loan belongs to the connection, so closing the connection ends it (`0010`) | Most services: storage, network, display |
| 2. Per-request loan | A request carries its own loan, overriding the connection's | Expensive one-off requests (compile this, compress that) |
| 3. Priced requests | The protocol declares a cost estimate per request. The server can refuse with `NeedsBudget(minimum)` and the client decides whether to pay | Servers that must not be exhausted by any one client |

Whether a server *requires* a loan is the server's choice. A server may refuse connections or
requests for its own reasons, and the OS imposes no rule either way.

Two cases the levels cover without extra kernel features:
- **Work a server does later on a client's behalf** (write-back, prefetch) runs on that
  connection's level-1 loan, so the client pays for it.
- **Passive servers** (seL4's term): a server whose own budget only covers housekeeping, and
  which does client work only on loans. It never runs unless a client pays.

A protocol type declares which level it uses. This belongs with how protocol types declare
idempotence (`0017`) and protocol tags, all under *IPC and data* in `../open-questions.md`.

## 5. Open Questions
- Level 1 (per-connection loan) as the default for lending: right default? Servers may refuse
  connections for their own reasons, including a missing loan. That's server behaviour, not
  an OS policy.
- Do CPU budgets need CPU affinity (pin to a set of CPUs), or is that a later hint?
- Per-thread page for the budget binding (§3): also the place for other cheap per-thread
  state the kernel reads (for example a fiber scheduler's "don't preempt me" hint)? Is it
  separate from Hemera's carrier block (which is private to the program's `std`), or reached
  from it? Note that Hemera's no-yield regions only stop fiber switches, not kernel
  preemption.
