# 0177: A Message That Breaks Its Protocol Ends Its Connection; and Two of 11d's Limits

Status: accepted
Date: 2026-11-05
Related: `0040` (protocols), `0176` (11d), `../design/protocols.md` §1, `../design/shell.md` §6

## Context
Building 11d, a shell request built in the wrong order was refused by the session manager's validator, and the shell
waited for its answer forever. Every server did the same: a request that failed validation, or carried a channel of
another protocol, was skipped with `continue`, and nothing was logged. Every client did the same with a response it
couldn't read, waiting for another that would never come, since answers come in order. `0040` and the protocol design
said messages are validated on arrival, and not what then becomes of one that fails. Chosen with the owner after 11d,
with two of `0176`'s limits: a background job's output waiting for `wait`, and Ctrl-C unseen behind type-ahead.

## Decision
- **A message that isn't its protocol ends its connection**, as in Cap'n Proto: one that fails validation, holds a
  channel of another protocol, or is a response of a variant the client doesn't know. The side that got it closes its
  end, as when the connection fails, so the other side sees it gone. A request of a variant the server doesn't know is
  evolution, and is still answered `Unsupported`.
- **`std` logs it**: the generated `receive_request` and `receive_response` call `os.report_broken`, naming the
  protocol (its package's `PROTOCOL`, which every protocol declares), the side and what's wrong.
- **Every receive loop** in SlopOS and `std` treats such an arrival as it treats the connection failing: servers drop
  the client (the arms that skipped `Invalid` and `WrongProtocol` are gone, the `Failed` arm the catch-all), clients
  give up waiting with the error they give for a gone connection, and a stream's reader ends the stream. A script made
  the change where the loop's shape allowed (46 files); the root task's channel to the supervisor was changed by hand.
  A loop that doesn't wait has to name `Empty`, since a catch-all would take it for a break: the terminal's prompts
  from the powerbox didn't, and dropped the powerbox until they did.
- **A job's output is read as it's written**: the shell binds a background job's output stream to its port, under the
  job's first key plus `OUTPUT_KEY`, and reads what's come whenever it wakes, keeping the records for `wait`. So a job
  runs to its end on its own, and the prompt says when it has.
- **Ctrl-C behind type-ahead**: `std`'s terminal client keeps its events and text in growing arrays, adding each Input
  after what's still to be read, so `interrupted` holds a Read whatever's waiting and sees an Interrupt wherever it is.
- **Tests**: `test_protocols` sends the process manager a message too short to have a tag, on a connection of its own,
  and finds the connection closed and the manager still serving; the jobs boot test checks a job's end said at the
  prompt, and Ctrl-C after type-ahead.

## Alternatives
- **Answer a broken request with `Unsupported`**: the client stops waiting, but `Unsupported` says the variant's
  unknown, which isn't what happened, and a client that sends broken messages has a bug or worse; closing says so.
- **A new `ChannelError` for it**, so `Failed` covers it: `ChannelError` is the kernel's ABI, and this isn't the
  kernel's.

## Consequences
- A client that breaks a protocol loses its connection, and has to make another; a service whose one connection that
  is (the root task's to the supervisor) loses it for good, as when the other side goes.
- The log line reaches the system's log only where the program's logger does: the process manager's and other early
  services' `log_info` goes nowhere yet.
- A background job's records are held by the shell until `wait`, however many there are.
