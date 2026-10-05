# 0017: Service Restart, Reconnection, and Process-Control Rights

Status: accepted
Date: 2026-10-02

## Context
Restartable services (`../problems-and-directions.md` §2) mean every client will see
`ObjectGone` sooner or later, so there needs to be a standard way back. Debuggers, profilers
and process monitors need authority over other processes without anything like `root`.

## Decision
**Restart and reconnection:**
- Clients hold a **connector** owned by the supervisor, not a direct channel to a server.
  On `ObjectGone`, they reconnect through the connector, which leads to the restarted
  instance.
- `std` reconnects **automatically for protocols marked idempotent** (requests carry IDs, so
  a retried request isn't applied twice). For other protocols, `ObjectGone` is returned and
  the program decides.
- **The root task restarts the supervisor.** It's the one piece of policy the root task has
  (an addition to `0012`). The supervisor restarts everything else.

**Process-control rights** (kernel rights on a process handle, `0010`):

| Right | Allows |
|---|---|
| `inspect` | List children, read state and resource usage |
| `read_memory` | Read the process's memory |
| `write_state` | Write memory and registers |
| `intercept` | Syscall interception (`0009`) |
| `kill` | Destroy the process |

- Rights on a process **cover its whole subtree**, including children created later, since
  they're owned within it.
- Whoever creates a process receives a handle with all of these and can hand out
  attenuated copies (`inspect` only for a process monitor, everything but `kill` for a
  debugger).
- **There are no undebuggable processes.** A process's creator chose its code and its
  capabilities, so the process already depends on its creator entirely. Hiding from the
  creator protects nothing.

## Alternatives considered
- **Clients reconnect by asking a directory service each time:** another round trip, and
  the directory becomes a restart dependency itself.
- **A single `debug` right:** too coarse; a process monitor shouldn't be able to write
  another process's memory.

## Consequences
- Protocols must declare whether they're idempotent, which belongs to the protocol type.
  That is a requirement on how protocol types are written (open question with the IPC wire
  format).
- State held per connection in a server is lost when it restarts unless the server persists
  it. Services decide what to persist.
- The interception facility and `read_memory`/`write_state` are designed together with the
  syscall ABI.
