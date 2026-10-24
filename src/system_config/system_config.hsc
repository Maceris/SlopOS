/*
 * The system's configuration (decisions/0044, 0058, 0067): the services it starts at boot, a compile-time
 * value compiled into the root task and the supervisor, which read it. 6d checks its wiring against each
 * program's typed entry point; until then a grant is a name the starter knows how to make:
 * - "debug_log": a debug log;
 * - "entropy": a channel to the entropy service;
 * - "process_manager": a channel to the process manager;
 * - "root_task": a channel to the root task, for the supervisor's reports;
 * - "module:<name>": a boot module, read-only, for the supervisor to start a program from.
 */
package system_config

// Who starts a service, and owns it: the root task, or the supervisor.
Starter :: enum {
    RootTask,
    Supervisor,
}

MAX_SERVICE_GRANTS :: 6

Service :: struct {
    // Its name, as the supervisor reports it, and the boot module it's started from
    name : string,
    module : string,
    starter : Starter,
    // Whether its starter asks the process manager to load it, rather than loading it itself as the root task
    // does the services the manager needs
    by_manager : bool,
    // Its memory budget, split off its starter's, in bytes
    budget : u64,
    // What it's given, by name, then ""
    grants : string[MAX_SERVICE_GRANTS],
}

MIB : u64 : 1024 * 1024

/*
 * In the order they start. The entropy service comes first, since the process manager draws from it, and the
 * supervisor's budget pays for what it starts too.
 */
SERVICES :: Service.[
    Service.{name = "entropy", module = "entropy.elf", starter = .RootTask, by_manager = false, budget = 2 * MIB,
        grants = string.["debug_log", "", "", "", "", ""]},
    Service.{name = "process_manager", module = "process_manager.elf", starter = .RootTask, by_manager = false, budget = 8 * MIB,
        grants = string.["debug_log", "entropy", "", "", "", ""]},
    Service.{name = "supervisor", module = "supervisor.elf", starter = .RootTask, by_manager = true, budget = 16 * MIB,
        grants = string.["debug_log", "process_manager", "root_task", "module:hello.elf", "", ""]},
    Service.{name = "hello", module = "hello.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        grants = string.["debug_log", "process_manager", "", "", "", ""]},
]
