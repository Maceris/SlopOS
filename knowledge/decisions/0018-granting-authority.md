# 0018: Granting Authority: Launch Grants, Runtime Requests, and the Powerbox

Status: accepted
Date: 2026-10-02

## Context
Programs get authority from whoever starts them and, sometimes, from the user while they
run. The shell is where most of this happens before there's a GUI. Without a global
namespace, a capability also has no path to print, so tools like `ls` and error messages
need something to show.

## Decision
**The shell language is not Hemera.** It's a separate language designed for interactive
use and scripting. A script still gets only the authority it's given.

**Launch grants:**
- Arguments on a command line are grants: the shell opens what the user named and passes
  capabilities to the program.
- **Globs become a `FileSet`:** a capability issued by the storage service for a directory
  plus a filter, not one handle per matching file. Explicitly named files are passed as
  individual handles.
- **Capabilities carry an informational name**, supplied by the server that issued them (the
  path or name they were opened as). It's for display only and never used for access.

**Runtime requests:**
- **Command-line programs may ask for more authority while running**, not only at launch.
- Requests go to the **powerbox**: a protocol a program holds a connection to, saying what
  it wants and why. The powerbox asks the user and returns the capability the user chose,
  or a refusal.
- The powerbox has **two front ends**: the console (terminal service) now, and the GUI
  later. Both implement the same protocol, so programs don't care which one answers.
- The prompt names the requester by its connection label (`0014`).
- While a console prompt is active, the user's keystrokes go only to the powerbox, never
  to the program that asked.

## Alternatives considered
- **Hemera as the shell language:** a poor fit for interactive use (`::` definitions,
  compile step, explicit types).
- **Launch-only grants for CLI programs:** simpler, but forces users to guess everything a
  program will need before running it.
- **One handle per glob match:** thousands of handles for one command, and none for files
  created while the command runs.

## Consequences
- A spoofed grant prompt can't grant anything, because only the real powerbox can. The
  remaining risks are a program printing misleading text around a real prompt, and fake
  *password* prompts. Credentials are therefore never typed into a program's terminal;
  re-authentication uses the console's trusted path. How the console marks its own prompts
  as genuine, locally and over remote login, is an open question.
- The storage service needs `FileSet` and informational names in its protocol.
- How the shell maps typed program parameters to grants waits on what executables look like
  (`../open-questions.md`, *Executables, libraries and program reuse*).
