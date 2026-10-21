# 0047: Build the Compiler as We Go

Status: accepted
Date: 2026-10-20
Related: supersedes `0030`'s amendment (compiler changes on request) and, in `0005`, writing code
before the compiler can build it; `0007` (checks), `0028` (build package)

## Context
SlopOS was planned on the assumption that Hemera's compiler wouldn't build meaningful programs for
a long time: code was written against the language as documented and proposed, gaps were marked in
the source and logged, and building and running the system was a bonus (`0005`). The compiler
(`apps/`) was changed only when the Hemera author asked for each change (`0030`, amendment).

That has shifted. The compiler now builds and boots the M1 kernel, runs compile-time code, checks
pointers into the stack, bounds, ownership and secrets, and builds `std` on Windows, Linux and
freestanding targets (`../compiler-plan.md`). Most of it was built at the Hemera author's request
while SlopOS needed it, and that worked: real code found real compiler bugs, and code that's built
and tested is better evidence about Hemera than code that's only written.

## Decision
- **The compiler is built out as SlopOS needs it.** When SlopOS code needs something the compiler
  can't do yet, a bug fixed or a feature implemented, that compiler work is part of the task, done in
  Hemera's `apps/` with tests in `apps/compiler/test`, and logged in `../hemera-feedback.md` like any
  other change to Hemera. It doesn't wait for a request each time.
- **SlopOS code builds and runs.** New code is written to build, and is tested by the boot and unit
  tests (`tools/`). When the compiler falls short, fix the compiler rather than write code it can't
  build. `//HEMERA(...)` markers are for what's deliberately left for later, with the reason.
- **Language design still goes to the Hemera author.** New syntax or semantics, and anything that
  changes what Hemera code means, are proposed and decided with them first (`../hemera-proposals/`),
  as before. Implementing what's already documented, and fixing what doesn't match the docs, aren't.
- Stress-testing Hemera's design, compiler and `std` stays the purpose (`0005`); now it includes
  running the code.

## Alternatives considered
- **Keep writing ahead of the compiler:** more of the OS on paper sooner, but much of it unbuilt and
  untested, with guesses that drift from the language as it's really implemented.
- **Keep asking per compiler change:** keeps the compiler's direction with its author, but most
  changes SlopOS needs are implementing what's already documented, and a request for each slows both.
  Design decisions stay with the author either way.

## Consequences
- Milestones mean running code: a roadmap step is done when it builds, boots and passes its tests.
- Compiler work shows up in SlopOS tasks, so a task may change both repositories; each is committed
  in its own repository.
- Existing code written ahead of the compiler, and its `//HEMERA(gap)` markers, are worked down as
  that code is built, rather than all at once.
- `0005`'s *real implementations, narrow scope, full depth* is unchanged.
