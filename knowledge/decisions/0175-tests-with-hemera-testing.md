# 0175: Tests With Hemera's Testing Framework

Status: accepted
Date: 2026-11-04
Related: `0033` (tests), `0069` (test programs), `0096`/`0104` (robustness sweeps), `0174`

## Context
Every SlopOS test said what failed with a number: a unit test's main returned the first failed check's, a test program
the same through the root task, and the kernel's tests a stop code. Numbers said nothing without the source beside them,
only the first failure was ever seen, and nothing kept two tests' numbers apart: the documentation review found
`disk_check`, `sealed_test` and `test_msi_dma` overlapping others'. Hemera now has a testing framework (its
`docs/testing.md`): `#test` functions, assertions that record a message, the caller's location and the values compared,
and a runner that reports each test and a summary. Chosen with the owner after the review's fixes: an explicit `t`,
tests that return `testing.Outcome` so `require_` assertions stop them with `?`, `hemera --test`, and converting every
test rather than only new ones.

## Decision
- **Every test is a `#test` function**, its checks `testing.expect_`/`require_` assertions with a message saying why the
  check holds. Failure numbers are retired.
- **Unit tests** (`src/**/test`): a test package without a `main` is built as a test program (`BuildOptions.test`),
  whose entry Hemera gives runs its tests and reports to standard output; one with a `main` of its own, as those the
  robustness sweeps run through `robustness/hosted` are, runs them itself with `testing.run`. Either ends with how many
  tests failed, which `unit_tests.py` reports.
- **Test programs** (`src/tests`): `main` keeps its grants, and runs its tests with `test_kit.run`, which reports each
  line to the debug log after the program's name and pushes what main was given as a context extension, which a test
  finds with `test_kit.given`. `boot_tests.py`'s `program_test` takes how many tests the program has and expects the
  summary line saying they all passed.
- **Any boot**: `boot.py` fails a run whose serial output has a test's `FAILED` line, and says it with the failures
  beneath it, so a test the expected lines don't name still can't fail unseen.
- **The kernel's tests** report the same way, through the kernel's log.

## Alternatives
- **Only new tests use it**: leaves two ways to say a test failed, and the numbered ones keep their problems.
- **Tests find their grants through a parameter**: every test's signature would differ by program; the context
  extension keeps `fn(t: ptr[mut testing.T]) -> testing.Outcome` everywhere.

## Consequences
- A failure says what was expected, what was found, and where, and every failed check in a run is seen.
- `program_test`'s count has to change when a program gains or loses a test; a test silently left out shows as a
  wrong count.
- Under a robustness sweep, a run that fails an allocation fails tests rather than returning a check's number; the
  sweep still only requires that it doesn't crash.
