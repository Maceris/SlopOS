# 0174: Documentation Comments, and the Rest of 11d

Status: accepted
Date: 2026-11-03
Related: `0162` (M11's plan), `0172` (11c), `../design/shell.md` §6

## Context
11d's `help` shows a program's documentation, which has to reach its manifest. Hemera's compiler drops comments, and
neither codebase has a documentation format: comments above declarations are prose, with a function's parameters,
results and errors described in sentences. Tools need a standard, so a format, the compiler's support for it, and a
rewrite of both codebases come first, as a phase of their own before the rest of 11d. Chosen with the owner as 11d
started.

## Decision
- **Doxygen's style, literally**: a documentation comment is `/** ... */` directly above a declaration (a package,
  function, type, field, enum member, union variant, constant or alias); `/**< ... */` after a field or member
  documents it. Its first sentence, or `@brief`, is its summary. Tags start with `@`: `@param name`, `@tparam T`,
  `@return`, `@note`, `@see`, `@example`, `@deprecated`, `@since`, and one of Hemera's own, `@error Variant`, for an
  error a function returns, checked against its `Result`'s error type. Ordinary `//` and `/* */` comments are never
  documentation.
- **The compiler** keeps documentation comments, attaches them to declarations, parses their tags, and gives them to
  compile-time code through reflection. Malformed documentation (an unknown tag, an `@param` or `@error` naming
  nothing, a duplicate, a documentation comment attached to nothing) is a compile error, which a setting turns off.
- **Missing documentation** isn't the compiler's to report: a build's metaprogram can check for it through reflection.
  SlopOS's build does, as a house rule; other programs don't unless they choose to.
- **The rewrite** converts every comment above a declaration in Hemera's `base` and `std` and in SlopOS: a script
  changes the form, and the prose about parameters, results and errors is split into tags by hand, file by file,
  checked by the compiler and SlopOS's house rule.
- **Manifests**: the build writes each program's documentation beside its manifest as `<name>.docs`, which its bundle
  refers to; the manifest stays exactly its entry's schema, whose hash the session manager checks.
- **The rest of 11d**: `help`, and completion with summaries, from `.docs`; history; jobs, with a trailing `&` for a
  background job (no terminal), `jobs`, `wait n` and `stop n`; Ctrl-C sending the foreground job `Stop`, killed after a
  grace period; `Progress` on the lifecycle channel; then the shell as the session's first program.

## Consequences
- Two large mechanical changes land across both repositories before any more of 11d.
- `@param` repeats a parameter's name; the compiler's check is what keeps it from going stale.
