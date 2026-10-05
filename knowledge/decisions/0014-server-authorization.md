# 0014: Servers Authorize by Connection Only; Connection Labels Are Trusted

Status: accepted
Date: 2026-10-02

## Context
A server that checks *who* is calling against a list of permissions (an ACL) brings back
the confused-deputy problem: a deputy acting for someone else uses its own identity, not
the authority it was given for that job. `0010` already removed badges and sender identity
from messages. This decision makes the rule explicit and says how servers learn anything
about their clients.

## Decision
- **No caller identity, ever.** The kernel delivers no sender process or identity with
  messages and offers no syscall to find the process on the other end of a channel.
- **A server authorizes a request only by the connection it arrived on**: which protocol
  the connection speaks, and the rights the server attached to that connection when it
  issued it.
- **Connection labels.** Whoever creates or issues a connection may attach a label
  ("issued to app X in session Y"). A label is trusted to the same degree as the authority
  that issued it: a holder of authority who hands out access is acting as an agent of
  whoever gave it that authority, so its description of the recipient is believed. Labels
  are for audit logs, quotas, and prompts that name the requester ("Editor wants to open a
  file"). A label never grants anything by itself.

## Alternatives considered
- **Expose sender identity for audit only:** it would be used for access checks the moment
  it existed, and it breaks substituting a proxy or recorder for a real client (`0009`).

## Consequences
- Every server-side permission is a property of a connection. "User B may read this" has
  to be expressed as "B holds a connection (or a stored link, `../design/security.md`) that
  reads this".
- Labels must be attached when a connection is created, so services that hand out
  connections (process manager, powerbox, session manager) are responsible for honest
  labels. They're already in the trusted computing base (`0013`).
- A candidate house-rule check for `std`'s server framework: request handlers receive the
  connection and its state, never anything identifying the peer.
