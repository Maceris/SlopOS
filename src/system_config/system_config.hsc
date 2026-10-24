/*
 * The system's configuration (decisions/0044, 0058, 0067, 0068): the services it starts at boot, a
 * compile-time value compiled into the root task and the supervisor. Each service names its entry, whose
 * parameters are what it's given, each the grant of its name: so the wiring is checked when it's compiled
 * (check_wiring, below), every os.Channel[P] a service takes needing a service, or the root task, that serves P
 * with an os.Listener[P].
 */
package system_config

import compiler from "base"
import runtime from "base"
import text_buffer from "std"
import os from "std"
import entropy from "../services/entropy"
import process_manager from "../services/process_manager"
import supervisor from "../services/supervisor"
import hello from "../apps/hello"
import protocols from "../protocols"

// Who starts a service, and owns it: the root task, or the supervisor.
Starter :: enum {
    RootTask,
    Supervisor,
}

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
    // Its entry's type, whose parameters are what it's given
    entry : type,
}

MIB : u64 : 1024 * 1024

/*
 * In the order they start. The entropy service comes first, since the process manager draws from it, and the
 * supervisor's budget pays for what it starts too.
 */
SERVICES :: Service.[
    Service.{name = "entropy", module = "entropy.elf", starter = .RootTask, by_manager = false, budget = 2 * MIB,
        entry = type_of(entropy.main)},
    Service.{name = "process_manager", module = "process_manager.elf", starter = .RootTask, by_manager = false, budget = 8 * MIB,
        entry = type_of(process_manager.main)},
    Service.{name = "supervisor", module = "supervisor.elf", starter = .RootTask, by_manager = true, budget = 16 * MIB,
        entry = type_of(supervisor.main)},
    Service.{name = "hello", module = "hello.elf", starter = .Supervisor, by_manager = true, budget = 2 * MIB,
        entry = type_of(hello.main)},
]

// What the root task serves itself: the supervisor's reports.
ROOT_TASK_SERVES :: type.[os.Listener[protocols.Supervision]]

// The service named name.
service :: fn(name: string) -> Service? {
    for each in SERVICES {
        if each.name == name {
            return each
        }
    }
    return null
}

/*
 * Every os.Channel[P] a service takes, or an optional one, has a server: a service taking an os.Listener[P], or
 * the root task, which serves ROOT_TASK_SERVES. One without fails the build, saying which.
 */
check_wiring :: fn() {
    for each in SERVICES {
        for input in cast[ptr[compiler.TypeInfoFunction]](type_info_of(each.entry)).input {
            held :: held_type(input.type)
            if !is_named(held, "Channel[") {
                continue
            }
            served := false
            tag :: os.end_tag(held)
            for server in SERVICES {
                for offered in cast[ptr[compiler.TypeInfoFunction]](type_info_of(server.entry)).input {
                    served = served || (is_named(offered.type, "Listener[") && os.end_tag(offered.type) == tag)
                }
            }
            for offered in ROOT_TASK_SERVES {
                served = served || os.end_tag(type_info_of(offered)) == tag
            }
            if !served {
                storage : u8[160]
                message := text_buffer.make(storage)
                text_buffer.append_format(&message, "system_config: %'s % has no service that serves it", each.name, input.name)
                runtime.assert(false, text_buffer.as_string(&message))
            }
        }
    }
}

#run check_wiring()

// What an optional holds, or the type itself.
held_type :: fn(type: ptr[compiler.TypeInfo]) -> ptr[compiler.TypeInfo] {
    if type.variant == .UNION {
        optional :: cast[ptr[compiler.TypeInfoUnion]](type)
        if optional.variants.count != 0 && optional.variants[0].types.count == 1 {
            return optional.variants[0].types[0]
        }
    }
    return type
}

// Whether type is a struct whose name starts with prefix, like an instance of Channel.
is_named :: fn(type: ptr[compiler.TypeInfo], prefix: string) -> bool {
    if type.variant != .STRUCT {
        return false
    }
    name :: cast[ptr[compiler.TypeInfoStruct]](type).name
    return os.starts_with(name, prefix)
}
