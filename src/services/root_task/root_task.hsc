/*
 * The root task (decisions/0012, 0060, 0067, 0068): the one process the kernel starts, given everything. It
 * splits its budget and starts the services system_config gives it: the entropy service and the process
 * manager with its own loader (src/process_builder), since the manager needs both, then the supervisor
 * through the manager, with std/os's launch. It owns each, serves the supervisor's reports, and watches
 * them. A working system's root task never ends; restarting the supervisor comes later.
 *
 * Two words on the kernel's command line are for boot tests, and end it with 0:
 * - test_services, once the supervisor has started all of its services;
 * - test_outlive_manager, which kills the process manager once the supervisor reports hello started, and
 *   ends once hello has, after it said it's still running.
 */
package root_task

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import protocols from "../../protocols"
import random_stream from "../../random_stream"
import system_config from "../../system_config"
import supervisor from "../supervisor"

MAX_STARTED :: 8
// The port's key for the supervisor's reports; a started service's is its index.
SUPERVISOR_KEY : u64 : 1000

// What the supervisor is given (supervisor.main).
SupervisorGrants :: struct {
    log : slop_os.DebugLog?,
    manager : os.Channel[process_manager.ProcessManager],
    root : os.Channel[protocols.Supervision],
    hello_module : slop_os.Memory,
}

// A service the root task started, and owns.
Started :: struct {
    name : string,
    process : slop_os.Process,
}

Root :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    stream : random_stream.Stream,
    // Its ends of the entropy service's and the process manager's listeners, through which it connects
    // services to them, and the manager's also its own connection; and the ports their answers wake
    entropy : slop_os.Channel,
    entropy_port : slop_os.Port,
    manager : slop_os.Channel,
    manager_port : slop_os.Port,
    // Its end of the supervisor's reports
    supervision : slop_os.Channel,
    started : Started[MAX_STARTED],
    started_count : usize,
}

main :: fn(platform: slop_os.Platform, debug_log: slop_os.DebugLog, command_line: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    root := Root.{block = block, log = debug_log}
    log_line.write(root.log, "root task: started, with % grants", block.grant_count)
    words :: text_of(block, command_line) or_return 4
    test_services :: has_word(words, "test_services")
    test_outlive_manager :: has_word(words, "test_outlive_manager")
    root.stream = random_stream.make(block.seed)

    // The listeners the root task connects services through, its own connection to the manager among them
    entropy_pair :: slop_os.channel_create(block.budget, 0) or_return 5
    root.entropy = entropy_pair.b
    root.entropy_port = os.port_for(block.budget, root.entropy) or_return 5
    manager_pair :: slop_os.channel_create(block.budget, process_manager.RING_BYTES) or_return 5
    root.manager = manager_pair.b
    root.manager_port = os.port_for(block.budget, root.manager) or_return 5
    supervision_pair :: slop_os.channel_create(block.budget, 0) or_return 5
    root.supervision = supervision_pair.a

    entropy_tag :: os.protocol_tag[protocols.Entropy]()
    manager_tag :: os.protocol_tag[process_manager.ProcessManager]()
    // The entropy service, and the process manager, with a connection of its own to it
    entropy_grants :: process_builder.Grant.[
        process_builder.grant("log", cast[slop_os.Handle](duplicate_log(&root) or_return 6)),
        process_builder.grant("clients", cast[slop_os.Handle](entropy_pair.a), entropy_tag),
    ]
    start_itself(&root, "entropy", entropy_grants) or_return 7
    manager_entropy :: protocols.connect(root.entropy, root.entropy_port, block.budget, 0) or_return 6
    manager_grants :: process_builder.Grant.[
        process_builder.grant("log", cast[slop_os.Handle](duplicate_log(&root) or_return 6)),
        process_builder.grant("entropy", cast[slop_os.Handle](manager_entropy), entropy_tag),
        process_builder.grant("clients", cast[slop_os.Handle](manager_pair.a), manager_tag),
    ]
    start_itself(&root, "process_manager", manager_grants) or_return 7

    // The supervisor, through the manager, with a connection of its own
    service :: system_config.service("supervisor") or_return 8
    module :: find_module(block, service.module) or_return 8
    hello_service :: system_config.service("hello") or_return 8
    hello_module :: find_module(block, hello_service.module) or_return 8
    module_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    grants := SupervisorGrants.{
        log = duplicate_log(&root),
        manager = os.Channel[process_manager.ProcessManager].{
            end = protocols.connect(root.manager, root.manager_port, block.budget, process_manager.RING_BYTES) or_return 9},
        root = os.Channel[protocols.Supervision].{end = supervision_pair.b},
        hello_module = cast[slop_os.Memory](slop_os.handle_duplicate(hello_module, module_rights) or_return 9),
    }
    manager :: os.Channel[process_manager.ProcessManager].{end = root.manager}
    match os.launch(manager, root.manager_port, service.name, cast[slop_os.Memory](module), service.budget, supervisor.main, grants) {
        case Ok(launched) => {
            remember(&root, service.name, launched.process)
            log_line.write(root.log, "root task: started %", service.name)
        }
        case Error(error) => {
            log_line.write(root.log, "root task: % didn't start: %", service.name, error)
            return 10
        }
    }

    // Then it watches
    supervised : usize = 0
    for each in system_config.SERVICES {
        if each.starter == .Supervisor {
            supervised += 1
        }
    }
    port :: slop_os.port_create(block.budget) or_return 11
    for &started, i in root.started {
        if i >= root.started_count {
            break
        }
        _ = slop_os.port_bind(port, cast[slop_os.Handle](started.process), slop_os.SIGNAL_TERMINATED, cast[u64](i), .Once)
    }
    supervisor_signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    _ = slop_os.port_bind(port, cast[slop_os.Handle](root.supervision), supervisor_signals, SUPERVISOR_KEY, .Persistent)
    reported : usize = 0
    loop {
        loop {
            if cast[slop_os.Handle](root.supervision) == slop_os.NO_HANDLE {
                break
            }
            report := protocols.SupervisorReport.{}
            handles : slop_os.Handle[1]
            match os.try_receive(root.supervision, os.mut_bytes_of(&report), handles) {
                case Ok(received) => {}
                case Error(error) => {
                    // Gone, which it stays: its end is closed, so its signal doesn't wake the port again
                    if error != .Empty {
                        log_line.write(root.log, "root task: the supervisor's channel is gone (%)", error)
                        _ = slop_os.handle_close(cast[slop_os.Handle](root.supervision))
                        root.supervision = cast[slop_os.Channel](slop_os.NO_HANDLE)
                    }
                    break
                }
            }
            name :: protocols.text_of_label(&report.name)
            if report.tag == protocols.SUPERVISOR_STARTED {
                log_line.write(root.log, "root task: the supervisor started %", name)
                reported += 1
                if test_services && reported == supervised {
                    return 0
                }
                if test_outlive_manager && name == "hello" {
                    kill(&root, "process_manager")
                }
            }
            else if report.tag == protocols.SUPERVISOR_ENDED {
                log_line.write(root.log, "root task: the supervisor's % ended with %", name, report.code)
                if test_outlive_manager && name == "hello" {
                    return if report.code == 0 { 0 } else { 12 }
                }
            }
            else {
                log_line.write(root.log, "root task: the supervisor's % didn't start (%)", name, report.code)
                if test_services || test_outlive_manager {
                    return 13
                }
            }
        }
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            key :: cast[usize](packet.key)
            if packet.kind == .Signal && key < root.started_count && key < root.started.count {
                name :: root.started[key].name
                ended :: packet.data[1]
                if ended == slop_os.EXIT_KILLED {
                    log_line.write(root.log, "root task: % was killed", name)
                }
                else {
                    log_line.write(root.log, "root task: % ended with %", name, ended)
                }
            }
        }
    }
}

/*
 * A service system_config names, loaded by the root task itself into a process of its own, with a budget
 * split off the root task's, a seed drawn from its stream, and grants: its process, which it remembers, or
 * null after saying why.
 */
start_itself :: fn(root: ptr[mut Root], name #escaping : string, grants: process_builder.Grant[]) -> slop_os.Process? {
    block :: root.block
    why :: start_with_loader(root, name, grants)
    match why {
        case Ok(process) => {
            remember(root, name, process)
            log_line.write(root.log, "root task: started %", name)
            return process
        }
        case Error(failure) => {
            log_line.write(root.log, "root task: % didn't start: %", name, failure)
            return null
        }
    }
}

start_with_loader :: fn(root: ptr[mut Root], name: string, grants: process_builder.Grant[]) -> Result[slop_os.Process, string] {
    block :: root.block
    service :: system_config.service(name) or_return .Error("system_config doesn't have it")
    budget :: slop_os.memory_budget_create(block.budget, service.budget) or_return .Error("no budget")
    process :: slop_os.process_create(budget) or_return .Error("no process")
    space :: slop_os.address_space_create(budget) or_return .Error("no address space")
    module :: find_module(block, service.module) or_return .Error("its module isn't there")
    size :: slop_os.memory_size(cast[slop_os.Memory](module)) or_return .Error("its module has no size")
    address :: runtime.reserve_addresses(cast[usize](size)) or_return .Error("no room to read its module")
    slop_os.memory_map(cast[slop_os.Memory](module), block.space, address, 0, size, slop_os.PROTECTION_READ) or_return .Error("its module doesn't map")
    defer _ = slop_os.memory_unmap(block.space, address)
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    // Its seed, drawn from the root task's stream, so the two never share one
    seed : u8[32]
    random_stream.fill(&root.stream, seed)
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    match process_builder.build(target, file, grants, seed, &root.stream) {
        case Ok(thread) => return .Ok(process)
        case Error(error) => return .Error("its loader failed")
    }
}

// A service started, by its name, which is a constant's.
remember :: fn(root: ptr[mut Root], name #escaping : string, process: slop_os.Process) {
    index :: root.started_count
    if index < root.started.count {
        root.started[index] = Started.{name = name, process = process}
        root.started_count = index + 1
    }
}

// A copy of the root task's debug log, to give a service.
duplicate_log :: fn(root: ptr[mut Root]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](root.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

// A started service killed, by name.
kill :: fn(root: ptr[mut Root], name: string) {
    for &started, i in root.started {
        if i < root.started_count && started.name == name {
            log_line.write(root.log, "root task: killing %", name)
            _ = slop_os.process_kill(started.process)
        }
    }
}

// The boot module's grant, "module:<module>".
find_module :: fn(block: ptr[slop_os.StartupBlock], module: string) -> slop_os.Handle? {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "module:")
    text_buffer.append(&label, module)
    return slop_os.find_grant(block, text_buffer.as_string(&label), .Memory)
}

// The kernel's command line, the memory's bytes up to its first zero, mapped read-only.
text_of :: fn(block: ptr[slop_os.StartupBlock], memory: slop_os.Memory) -> string? {
    size :: slop_os.memory_size(memory) or_return null
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    match slop_os.memory_map(memory, block.space, address, 0, size, slop_os.PROTECTION_READ) {
        case Ok => {}
        case Error(error) => return null
    }
    count : usize = 0
    for byte in view_of(cast[ptr[u8]](address), cast[usize](size)) {
        if byte == 0 {
            break
        }
        count += 1
    }
    return string_of(cast[ptr[u8]](address), count)
}

// Whether word is one of the words of text, which spaces separate.
has_word :: fn(text: string, word: string) -> bool {
    start : usize = 0
    for character, i in text {
        if character == ' ' {
            if is_word_at(text, start, i, word) {
                return true
            }
            start = i + 1
        }
    }
    return is_word_at(text, start, text.count, word)
}

// Whether text's bytes from start to end are word.
is_word_at :: fn(text: string, start: usize, end: usize, word: string) -> bool {
    return end >= start && end - start == word.count && string_of(cast[ptr[u8]](cast[u64](text.data) + cast[u64](start)), word.count) == word
}
