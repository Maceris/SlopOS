# 0027: No ABI Is Frozen Until the OS Design Is Thorough and Development Is Under Way

Status: accepted
Date: 2026-10-05
Related: `0025` (when stability starts), `../design/system-abi.md` §7 (the pinned Hemera
calling convention)

## Context
`0025` makes raw syscalls and the ABI package the stable interface, starting at a declared
ABI v1, and `../design/system-abi.md` §7 names a Hemera calling-convention version
(`hemera-abi-v1`) for separately compiled libraries. Neither said when anything would be
frozen. Hemera's calling convention changed substantially on 2026-10-04 (return values through
pointers, no frame-size word, a reserved carrier register, a stack check in every prologue),
and `Context` lost and gained fields, all of which would have been breaking changes to a
frozen ABI.

## Decision
- **ABI v1 (`0025`) is not declared until the OS design is fairly thorough and development
  is well under way**, and probably not for some time after that. Until then every row of
  `../design/system-abi.md` §1 can change, and everything is rebuilt together.
- **The Hemera calling convention is named and pinned, not frozen.** SlopOS refers to the
  version it was built against (so content hashes never silently mix conventions), and moves
  to Hemera's newer conventions freely until ABI v1.
- Declaring v1 is its own future decision record, made after reviewing every surface in
  `../design/system-abi.md` §1.

## Alternatives considered
- **Freeze early, version often:** every early mistake becomes a permanent number or layout,
  for no user, since nothing outside this project runs on SlopOS yet.
- **Freeze when Hemera declares its convention stable:** ties SlopOS's schedule to Hemera's,
  but SlopOS's own surfaces (syscalls, rings, packets) need just as much settling.

## Consequences
- Design notes can keep changing ABI surfaces without compatibility shims.
- Content hashes still cover the ABI version and calling-convention version, so a change is
  visible, just never promised against.
