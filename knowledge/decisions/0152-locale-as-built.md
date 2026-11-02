# 0152: 10c3, Locale, as Built

Status: accepted
Date: 2026-11-02
Related: `0149` (10c's plan), `0150` (login, the session manager), `0107` and `0109` (the config store),
`../design/lessons.md` §3.4, `../design/console-and-sessions.md` §5

## Context
`0149`'s 10c3: `Locale`, a context value from the user's configuration, read only by human-facing formatters
(`lessons.md` §3.4). Chosen with the owner as it started: Hemera's `std/locale`, a context extension, so base's
`Context` doesn't change; formatters of its own, so `text_buffer`'s formatting and the runtime's logging stay
locale-free; en-US and en-GB, and a neutral ISO default; and the locale kept as the user's setting in the config store,
which the session manager gives each of the session's programs as a grant.

## Decision
- **Hemera's `std/locale`**: a `Locale` (its name, decimal and grouping marks, the date's order and separator, a 12- or
  24-hour clock, the week's first day); `NEUTRAL` (2026-12-31, 1234567.89, 24 hours, Monday), `EN_US` (12/31/2026,
  1,234,567.89, 2:05 pm, Sunday) and `EN_GB` (31/12/2026, 1,234,567.89, 14:05, Monday); `find` by name; `current()`,
  the context's, else the process's, else `NEUTRAL`; and `append_integer`, `append_fixed`, `append_date` and
  `append_time`, which take the current one unless given one.
- **The process's locale**: base's runtime keeps only its name, `runtime.locale_name()`, read on SlopOS from the
  grant "locale", a page holding it, which `os.launch` gives as `LaunchOptions.locale`; base doesn't know what a locale
  is, and nothing in base changes with it.
- **The user's setting**: the config store's value "session" of owner "user:" and the account's name, a
  `SessionSettings` with its locale. The config service has a second connection for users' values, which the supervisor
  gives the session manager: on it, `ValueFor` reaches only owners named "user:" something, and `Forget` nothing.
- **The session manager** reads the user's setting at `Start`; with none, it takes the locale the keyboard layout
  they logged in with suggests (UK, en-GB; US, en-US) and keeps it as their setting. It gives each program of the
  session a read-only copy of a page holding the locale's name, which it keeps while the session lasts. A session with
  no user has none, so its programs write as `NEUTRAL` does.
- **echo** writes a number and the last day of 2026 the session's way.
- **Tests**: Hemera's `locale` scenario, the formatters for each locale and the one in effect from the context; on
  SlopOS, a login with the UK layout gets en-GB's dates, the next login reads the setting the first kept, and a boot
  with no accounts writes as `NEUTRAL` does.

## Alternatives considered
- **A field of base's `Context`**: every program would carry it, for what only human-facing text needs.
- **A specifier in `text_buffer`'s formatting**: one formatter for both kinds of output.
- **The locale in the account record**: the record would grow past what unlocking needs.
- **The session manager on the config store's admin connection**: it would reach every owner's values.

## Consequences
- More locales are more `Locale` constants; time zones (11a) follow the same path.
- The session manager's connection for users' values is given once: if the config service is started again, sessions
  made after that write as `NEUTRAL` does until the session manager is.
