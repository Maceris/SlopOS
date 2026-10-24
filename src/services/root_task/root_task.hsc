/*
 * The root task (decisions/0012, 0060, 0067): the one process the kernel starts, given everything. It
 * splits its budget and starts the services system_config gives it: the entropy service and the process
 * manager with its own loader (src/process_builder), since the manager needs both, then the supervisor
 * through the manager. It owns each, and watches them and the supervisor's reports. A working system's
 * root task never ends; restarting the supervisor comes later.
 *
 * Two words on the kernel's command line are for boot tests, and end it with 0:
 * - test_services, once the supervisor has started all of its services;
 * - test_outlive_manager, which kills the process manager once the supervisor reports hello started, and
 *   ends once hello has, after it said it's still running.
 */
package root_task

import runtime from "base"
import slop_os from "std/os"
import text_buffer from "std"
import log_line from "../../log_line"
import process_builder from "../../process_builder"
import protocols from "../../protocols"
import random_stream from "../../random_stream"
import system_config from "../../system_config"

MAX_STARTED :: 8
// The most services system_config can list.
MAX_SERVICES :: 8
// What the root task's port's keys are: a started service's index, or the supervisor's reports.
SUPERVISOR_KEY : u64 : 1000

// A service the root task started, and owns.
Started :: struct {
    name : string,
    process : slop_os.Process,
}

Root :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    stream : random_stream.Stream,
    // Its connection to the process manager, and the port it waits on for its replies
    manager : slop_os.Channel,
    manager_port : slop_os.Port,
    // The other end, the manager's "client:root_task", until it goes to the manager
    manager_client : slop_os.Channel,
    // Its end of the supervisor's "root_task" channel
    supervisor : slop_os.Channel,
    // Each service's end of a channel to the entropy service, and the entropy service's end, by service
    entropy_ends : slop_os.Channel[MAX_SERVICES],
    entropy_clients : slop_os.Channel[MAX_SERVICES],
    started : Started[MAX_STARTED],
    started_count : usize,
}

main :: fn() -> int {
    block :: slop_os.startup_block()
    if block.abi_version != slop_os.ABI_VERSION || block.size != cast[u32](size_of(slop_os.StartupBlock)) {
        return 1
    }
    root := Root.{block = block}
    root.log = cast[slop_os.DebugLog](slop_os.find_grant(block, "debug_log", .DebugLog) or_return 2)
    log_line.write(root.log, "root task: started, with % grants", block.grant_count)
    if (slop_os.find_grant(block, "platform", .Platform) is_none) {
        log_line.write(root.log, "root task: no platform capability")
        return 3
    }
    test_services := false
    test_outlive_manager := false
    match command_line(block) {
        case Some(words) => {
            test_services = has_word(words, "test_services")
            test_outlive_manager = has_word(words, "test_outlive_manager")
        }
        case None => {
            log_line.write(root.log, "root task: no command line")
            return 4
        }
    }
    root.stream = random_stream.make(block.seed)
    if !wire(&root) {
        log_line.write(root.log, "root task: no channels for its services")
        return 5
    }
    supervised : usize = 0
    for service in system_config.SERVICES {
        if service.starter == .Supervisor {
            supervised += 1
            continue
        }
        match start(&root, service) {
            case Ok(process) => {
                if root.started_count < MAX_STARTED {
                    root.started[root.started_count] = Started.{name = service.name, process = process}
                    root.started_count += 1
                }
                log_line.write(root.log, "root task: started %", service.name)
            }
            case Error(why) => {
                log_line.write(root.log, "root task: % didn't start: %", service.name, why)
                return 6
            }
        }
    }

    // Then it watches
    port :: slop_os.port_create(block.budget) or_return 7
    for &started, i in root.started {
        if i >= root.started_count {
            break
        }
        _ = slop_os.port_bind(port, cast[slop_os.Handle](started.process), slop_os.SIGNAL_TERMINATED, cast[u64](i), .Once)
    }
    supervisor_signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    _ = slop_os.port_bind(port, cast[slop_os.Handle](root.supervisor), supervisor_signals, SUPERVISOR_KEY, .Persistent)
    reported : usize = 0
    loop {
        loop {
            if cast[slop_os.Handle](root.supervisor) == slop_os.NO_HANDLE {
                break
            }
            report := protocols.SupervisorReport.{}
            handles : slop_os.Handle[1]
            match protocols.try_receive(root.supervisor, protocols.mut_bytes_of(&report), handles) {
                case Ok(received) => {}
                case Error(error) => {
                    // Gone, which it stays: its end is closed, so its signal doesn't wake the port again
                    if error != .Empty {
                        log_line.write(root.log, "root task: the supervisor's channel is gone (%)", error)
                        _ = slop_os.handle_close(cast[slop_os.Handle](root.supervisor))
                        root.supervisor = cast[slop_os.Channel](slop_os.NO_HANDLE)
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
                    return if report.code == 0 { 0 } else { 8 }
                }
            }
            else {
                log_line.write(root.log, "root task: the supervisor's % didn't start (%)", name, report.code)
                if test_services || test_outlive_manager {
                    return 9
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
 * The channels its services' grants need before they start: each service granted "entropy" gets an end of
 * its own to the entropy service, and the root task one to the manager.
 */
wire :: fn(root: ptr[mut Root]) -> bool {
    budget :: root.block.budget
    for service, i in system_config.SERVICES {
        if has_grant(service, "entropy") {
            pair :: slop_os.channel_create(budget, 0) or_return false
            root.entropy_clients[i] = pair.a
            root.entropy_ends[i] = pair.b
        }
    }
    pair :: slop_os.channel_create(budget, 0) or_return false
    root.manager = pair.b
    root.manager_client = pair.a
    root.manager_port = protocols.port_for(budget, root.manager) or_return false
    return true
}

/*
 * A service started in a process of its own, with a budget split off the root task's: by the root task's
 * own loader, or through the process manager. Its process, owned by the root task, or why not.
 */
start :: fn(root: ptr[mut Root], service: system_config.Service) -> Result[slop_os.Process, string] {
    block :: root.block
    budget :: slop_os.memory_budget_create(block.budget, service.budget) or_return .Error("no budget")
    process :: slop_os.process_create(budget) or_return .Error("no process")
    space :: slop_os.address_space_create(budget) or_return .Error("no address space")
    grants : process_builder.Grant[process_builder.MAX_GRANTS]
    count : usize = 0
    for grant in service.grants {
        if grant.count == 0 {
            continue
        }
        if count >= grants.count {
            return .Error("too many grants")
        }
        handle :: grant_for(root, service, grant) or_return .Error("a grant it needs isn't there")
        grants[count] = process_builder.grant(grant, handle)
        count += 1
    }
    // The entropy service's clients, and the manager's first, the root task
    if service.name == "entropy" {
        for other, i in system_config.SERVICES {
            if cast[slop_os.Handle](root.entropy_clients[i]) != slop_os.NO_HANDLE && count < grants.count {
                grants[count] = process_builder.Grant.{label = label_of_client(other.name), handle = cast[slop_os.Handle](root.entropy_clients[i])}
                count += 1
            }
        }
    }
    if service.name == "process_manager" && count < grants.count {
        grants[count] = process_builder.Grant.{label = label_of_client("root_task"), handle = cast[slop_os.Handle](root.manager_client)}
        count += 1
    }
    module :: find_module(block, service.module) or_return .Error("its module isn't there")
    if service.by_manager {
        load(root, service, process, space, budget, module, view_of(&grants[0], count))?
        return .Ok(process)
    }
    size :: slop_os.memory_size(cast[slop_os.Memory](module)) or_return .Error("its module has no size")
    address :: runtime.reserve_addresses(cast[usize](size)) or_return .Error("no room to read its module")
    slop_os.memory_map(cast[slop_os.Memory](module), block.space, address, 0, size, slop_os.PROTECTION_READ) or_return .Error("its module doesn't map")
    defer _ = slop_os.memory_unmap(block.space, address)
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    // The entropy service's seed is drawn from the root task's stream, so the two never share one
    seed : u8[32]
    if service.name == "entropy" {
        random_stream.fill(&root.stream, seed)
    }
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    match process_builder.build(target, file, view_of(&grants[0], count), seed, &root.stream) {
        case Ok(thread) => return .Ok(process)
        case Error(error) => return .Error("its loader failed")
    }
}

// A service loaded through the process manager, with grants.
load :: fn(root: ptr[mut Root], service: system_config.Service, process: slop_os.Process, space: slop_os.AddressSpace,
    budget: slop_os.MemoryBudget, module: slop_os.Handle, grants: process_builder.Grant[]) -> Result[void, string] {
    request := protocols.LoadRequest.{tag = protocols.PM_LOAD, name = protocols.label_from(service.name)}
    handles : slop_os.Handle[protocols.LOAD_HANDLES_AND_GRANTS]
    handles[0] = slop_os.handle_duplicate(cast[slop_os.Handle](process), rights(slop_os.Rights.[slop_os.RIGHT_PROCESS_THREADS,
        slop_os.RIGHT_DUPLICATE, slop_os.RIGHT_TRANSFER])) or_return .Error("no handle to its process")
    handles[1] = cast[slop_os.Handle](space)
    handles[2] = slop_os.handle_duplicate(cast[slop_os.Handle](budget), rights(slop_os.Rights.[slop_os.RIGHT_BUDGET_CHARGE,
        slop_os.RIGHT_DUPLICATE, slop_os.RIGHT_TRANSFER])) or_return .Error("no handle to its budget")
    handles[3] = slop_os.handle_duplicate(module, rights(slop_os.Rights.[slop_os.RIGHT_MEMORY_READ, slop_os.RIGHT_TRANSFER]))
        or_return .Error("no handle to its module")
    count : usize = protocols.LOAD_HANDLES
    for grant in grants {
        index :: cast[usize](request.grant_count)
        if index >= request.labels.count || count >= handles.count {
            return .Error("too many grants")
        }
        request.labels[index] = grant.label
        request.grant_count += 1
        handles[count] = grant.handle
        count += 1
    }
    reply := protocols.LoadReply.{}
    match protocols.call(root.manager, root.manager_port, protocols.bytes_of(&request), view_of(&handles[0], count),
        protocols.mut_bytes_of(&reply)) {
        case Ok(received) => {}
        case Error(error) => return .Error("the process manager didn't answer")
    }
    if reply.status != .Loaded {
        return .Error("the process manager couldn't load it")
    }
    return .Ok
}

// A handle for a grant system_config names, for service.
grant_for :: fn(root: ptr[mut Root], service: system_config.Service, name: string) -> slop_os.Handle? {
    block :: root.block
    if name == "debug_log" {
        match slop_os.handle_duplicate(cast[slop_os.Handle](root.log), rights(slop_os.Rights.[slop_os.RIGHT_DEBUG_LOG_WRITE,
            slop_os.RIGHT_DUPLICATE, slop_os.RIGHT_TRANSFER])) {
            case Ok(handle) => return handle
            case Error(error) => return null
        }
    }
    if name == "entropy" {
        for other, i in system_config.SERVICES {
            if other.name == service.name {
                end :: root.entropy_ends[i]
                return if cast[slop_os.Handle](end) == slop_os.NO_HANDLE { null } else { cast[slop_os.Handle](end) }
            }
        }
        return null
    }
    if name == "process_manager" {
        // A connection of its own: one end to the manager, which serves it, the other to the service
        pair :: slop_os.channel_create(block.budget, 0) or_return null
        connect := protocols.ConnectRequest.{tag = protocols.PM_CONNECT}
        ends :: slop_os.Handle.[cast[slop_os.Handle](pair.a)]
        match protocols.send(root.manager, root.manager_port, protocols.bytes_of(&connect), ends) {
            case Some(error) => return null
            case None => return cast[slop_os.Handle](pair.b)
        }
    }
    if name == "root_task" {
        pair :: slop_os.channel_create(block.budget, 0) or_return null
        root.supervisor = pair.a
        return cast[slop_os.Handle](pair.b)
    }
    if name.count > 7 && string_of(cast[ptr[u8]](name.data), 7) == "module:" {
        module :: slop_os.find_grant(block, name, .Memory) or_return null
        match slop_os.handle_duplicate(module, rights(slop_os.Rights.[slop_os.RIGHT_MEMORY_READ, slop_os.RIGHT_DUPLICATE,
            slop_os.RIGHT_TRANSFER])) {
            case Ok(handle) => return handle
            case Error(error) => return null
        }
    }
    return null
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

has_grant :: fn(service: system_config.Service, name: string) -> bool {
    for grant in service.grants {
        if grant == name {
            return true
        }
    }
    return false
}

// "client:<name>", as a grant's label.
label_of_client :: fn(name: string) -> u8[slop_os.GRANT_LABEL_SIZE] {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "client:")
    text_buffer.append(&label, name)
    return protocols.label_from(text_buffer.as_string(&label))
}

// The boot module's grant, "module:<module>".
find_module :: fn(block: ptr[slop_os.StartupBlock], module: string) -> slop_os.Handle? {
    storage : u8[slop_os.GRANT_LABEL_SIZE]
    label := text_buffer.make(storage)
    text_buffer.append(&label, "module:")
    text_buffer.append(&label, module)
    return slop_os.find_grant(block, text_buffer.as_string(&label), .Memory)
}

// The kernel's command line, from the "command_line" grant: its bytes, mapped read-only.
command_line :: fn(block: ptr[slop_os.StartupBlock]) -> string? {
    memory :: cast[slop_os.Memory](slop_os.find_grant(block, "command_line", .Memory) or_return null)
    size :: slop_os.memory_size(memory) or_return null
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    match slop_os.memory_map(memory, block.space, address, 0, size, slop_os.PROTECTION_READ) {
        case Ok => {}
        case Error(error) => return null
    }
    bytes :: view_of(cast[ptr[u8]](address), cast[usize](size))
    count : usize = 0
    for byte in bytes {
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

rights :: fn(each: slop_os.Rights[]) -> slop_os.Rights {
    all : u32 = 0
    for right in each {
        all = all | cast[u32](right)
    }
    return cast[slop_os.Rights](all)
}
