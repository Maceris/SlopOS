# SlopOS Knowledge

The project's planning and memory: ideas, open questions, decisions, design notes,
conventions and Hemera feedback. Official, user- and developer-facing documentation of the
system as built lives in `../docs/` instead.

| File | What it's for |
|------|---------------|
| `roadmap.md` | Milestones of real subsystems, and what each stresses in Hemera |
| `conventions.md` | How to write Hemera before the compiler can build it (marker comments, layout asserts) |
| `problems-and-directions.md` | Brainstorm: what's wrong with modern OSes, and clean-slate alternatives |
| `open-questions.md` | Unresolved questions; delete an entry once it's answered in `decisions/` |
| `decisions/` | Numbered decision records: what we chose and why |
| `design/layers.md` | The layered architecture (L0 boot → L6 apps) and its two hardware boundaries |
| `design/arch-x86-64.md` | What the boot and arch layers must handle on x86-64 |
| `design/threads.md` | Making threads cheap: memory and creation cost |
| `design/kernel.md` | What the kernel does (and doesn't), per-CPU state, syscall interception |
| `design/ipc.md` | Shared-ring channels, ports, handle transfer, replay |
| `design/scheduling.md` | CPU budgets, scheduler policy in user space, budget lending |
| `design/system-abi.md` | The Hemera-native system ABI: syscalls, process start, libraries, C interop |
| `design/security.md` | The security design: threat model, capabilities, users, grants (overview of decisions 0008–0018) |
| `design/services.md` | The user-space system services: what each does, what it holds, whether it's trusted |
| `hemera-proposals/` | Designs for Hemera changes: what SlopOS needs, and what the compiler (`apps/`, not changed from this project) must implement |
| `hemera-feedback.md` | Log of where Hemera helped, hurt or was missing something. The experiment's real output |
| `prior-art.md` | Other systems and papers worth studying |

## Suggested flow

1. Ideas start in `problems-and-directions.md`.
2. Questions they raise go in `open-questions.md`.
3. When something is settled, write `decisions/NNNN-title.md` and link to it.
4. `design/` holds per-subsystem design notes (layers, arch notes, and later IPC, storage…).
   Once a design is settled and implemented, its official description (spec, API, diagrams)
   is written in `../docs/`; the design note stays here as the history of how it was reached.
5. Anything the language makes easy, hard or impossible goes in `hemera-feedback.md`.
