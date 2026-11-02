# 0140: 10a4, the Root Task's Services Started Again, as Built

Status: accepted
Date: 2026-11-01
Related: `0136` (M10's plan), `0101` (the catch-up's items placed in 10a), `0093` (restarts, the events service),
`0049` (interrupt controllers; its plan to unregister them on a platform service restart is superseded here), `0077`
(connectors), `0139` (the runtime's threads), `../../docs/specs/programs.md`

## Context
`0136`'s 10a4, from the catch-up (`0101`): the root task's services, the entropy service, the process manager, the
scheduler service and the platform service, started again when they end, and logging to the events service; and
interrupt controllers unregistered when the platform service is started again (`0049`). Their clients held direct
connections, which die with them. Chosen with the owner as 10a4 started: clients reach them through connectors the root
task serves, as the supervisor's clients reach drivers (`0077`); and a platform service started again registers its
interrupt controllers and IOMMUs again, which the kernel answers with the ones already registered, rather than the
kernel unregistering them, since the IRQs of drivers still running were made through those registrations.

## Decision
- **The root task serves connectors** to its four services, on a thread of its own (`runtime.thread_create`, `0139`)
  with a port of its own: a client dialing one, as the process manager dials the entropy service while the root task
  waits on it to launch something, is answered whatever the root task's main thread is waiting on. Each service's end
  of its listener has a lock, held by the main thread while it launches through the process manager or asks the
  scheduler service, and by the connector thread while it connects a client; adding a connector wakes the thread, whose
  first read arms the channel, since a channel wakes its reader only once it's found empty.
- **Clients dial**: the supervisor's connections to the process manager, the platform service and the scheduler
  service are dialed through connectors, each watched for its other end closing and dialed again then; the entropy
  service is dialed for each client that needs a connection; the process manager dials the entropy service again when
  a draw fails; the storage manager's connection to the process manager comes through a connector the supervisor serves
  (`MANAGER_TARGET`), which dials the root task's.
- **Started again**: a service of the four that ends is started again, up to three times in a minute as the supervisor's
  are, with a new listener, watched under the same key; the scheduler service on the root's CPU budget, so what ran on
  the budgets it made runs on the root's meanwhile (a destroyed budget's threads go to its parent).
- **A platform service started again** registers its interrupt controllers and IOMMUs again, which the kernel already
  answered with the existing ones (`register_controller`, `register_iommu` find them first), so running drivers' IRQs
  keep working; it treats a device nothing has claimed from it, when a client asks to have it reissued, as that
  client's, since it was claimed from the platform service before it. This supersedes `0049`'s plan to unregister them.
- **Logging**: once the events service is up, the supervisor gives the root task a connection to it (supervision's
  `EventsService`), and a service started again is given a ring for its records, as the supervisor's are. These four
  log through their debug log grant themselves, since they start before the events service at boot, so what reaches
  the ring is what base's logger writes.
- **Test**: `test_restart_root_services` kills the four in turn once everything's started, the process manager after
  the entropy service and before the two it launches; each is started again and answers through a connector before the
  next, and the supervisor and the storage manager dial theirs again.

## Alternatives considered
- **The root task sending fresh connections over the supervision channel**: each client would need its own way of being
  handed one.
- **Unregistering controllers and restarting every driver**: what `0049` planned, at the cost of every driver.
- **A single lock**: the main thread holds the process manager's while it launches, which waits on the process
  manager's dial of the entropy service, which the connector thread answers.

## Consequences
- 10a is done: the trusted path's services, the lifecycle channel, and the services every other depends on started
  again. R5 (chaos) can start.
- The root task has a second thread, and every client of its services holds a connector.
