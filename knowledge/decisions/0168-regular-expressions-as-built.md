# 0168: 11a5, Regular Expressions, as Built

Status: accepted
Date: 2026-11-02
Related: `0164` (RE2's syntax, but for what can't be linear), `0162` (M11's plan), `../roadmap.md` M11

## Context
`0164`: a regular expression engine in Hemera's `std` whose time is linear in the text, so no pattern a user or a
program gives can take exponential time, as backtracking engines can.

## Decision
- **Hemera's `std/regex`**: `compile` parses a pattern by recursive descent straight to a program (classes of code
  point ranges, any, split, jump, save, the anchors, word boundaries, match); `find`, `is_match` and `captures` run it
  as a Pike VM: every thread at one text position at once, each place in the program at most once per position, in
  priority order, so matches are leftmost-first as Perl's and RE2's are, with every group's span. The time is the
  text's length times the program's size.
- **The syntax**: literals and escapes, `.` (not a line feed), classes with ranges and `\d`, `\w` and `\s` inside, their
  negations, `^` and `$`, `\b` and `\B`, capturing and non-capturing groups, alternation, `*`, `+`, `?` and `{n}`,
  `{n,}`, `{n,m}` up to 1000, lazy forms of each, and `(?i)` or `ignore_case` folding ASCII letters. Text is matched by
  code point. A pattern that isn't one is refused with why and where.
- **Tests**: Hemera's `regex` scenario: leftmost-first alternation, greedy and lazy repetition, anchors, counted
  repetition, case folding, word boundaries, UTF-8, captures, `(a?){30}a{30}` against thirty a's (2^30 paths for a
  backtracking engine), and each kind of error.

## Consequences
- `search` (11e) and the shell's `where` with a pattern use it.
- Case folding is ASCII's; Unicode's simple folding can come with tables from the Unicode data the `unicode` package
  generates.
