/*
 * The supervisor (decisions/0017, 0058, 0067), a stub for now: it starts the services system_config gives
 * it, through the process manager, each in a process of its own that it owns and pays for from its budget,
 * and tells the root task as each starts and ends. Restarting them comes with M7's drivers.
 */
package supervisor

import slop_os from "std/os"
import text_buffer from "std"
import log_line from "../../log_line"
import protocols from "../../protocols"
import system_config from "../../system_config"

MAX_SERVICES :: 16

Supervisor :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    manager : slop_os.Channel,
    manager_port : slop_os.Port,
    root : slop_os.Channel,
    root_port : slop_os.Port,
}

main :: fn() -> int {
    block :: slop_os.startup_block()
    supervisor := Supervisor.{block = block}
    supervisor.log = cast[slop_os.DebugLog](slop_os.find_grant(block, "debug_log", .DebugLog) or_else slop_os.NO_HANDLE)
    supervisor.manager = cast[slop_os.Channel](slop_os.find_grant(block, "process_manager", .Channel) or_return 1)
    supervisor.manager_port = protocols.port_for(block.budget, supervisor.manager) or_return 2
    supervisor.root = cast[slop_os.Channel](slop_os.find_grant(block, "root_task", .Channel) or_return 3)
    supervisor.root_port = protocols.port_for(block.budget, supervisor.root) or_return 4
    port :: slop_os.port_create(block.budget) or_return 5
    // Each service started, by the key its process is bound under
    names : string[MAX_SERVICES]
    count : usize = 0
    for service in system_config.SERVICES {
        if service.starter != .Supervisor || count >= MAX_SERVICES {
            continue
        }
        match start(&supervisor, service) {
            case Ok(process) => {
                _ = slop_os.port_bind(port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, cast[u64](count), .Once)
                if count < names.count {
                    names[count] = service.name
                }
                count += 1
                tell_root(&supervisor, protocols.SUPERVISOR_STARTED, 0, service.name)
            }
            case Error(code) => {
                log_line.write(supervisor.log, "supervisor: % didn't start (%)", service.name, code)
                tell_root(&supervisor, protocols.SUPERVISOR_FAILED, code, service.name)
            }
        }
    }
    log_line.write(supervisor.log, "supervisor: started % services", count)
    loop {
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            key :: cast[usize](packet.key)
            if packet.kind == .Signal && key < count && key < names.count {
                name :: names[key]
                log_line.write(supervisor.log, "supervisor: % ended", name)
                tell_root(&supervisor, protocols.SUPERVISOR_ENDED, packet.data[1], name)
            }
        }
    }
}

/*
 * A service started through the process manager, in a process of its own with a budget split off the
 * supervisor's: its process, or the LoadStatus it failed with (0 if the request didn't reach the manager).
 */
start :: fn(supervisor: ptr[mut Supervisor], service: system_config.Service) -> Result[slop_os.Process, u64] {
    block :: supervisor.block
    budget :: slop_os.memory_budget_create(block.budget, service.budget) or_return .Error(0)
    process :: slop_os.process_create(budget) or_return .Error(0)
    space :: slop_os.address_space_create(budget) or_return .Error(0)
    module_label_storage : u8[slop_os.GRANT_LABEL_SIZE]
    module_label := text_buffer.make(module_label_storage)
    text_buffer.append(&module_label, "module:")
    text_buffer.append(&module_label, service.module)
    module :: slop_os.find_grant(block, text_buffer.as_string(&module_label), .Memory) or_return .Error(0)
    request := protocols.LoadRequest.{tag = protocols.PM_LOAD, name = protocols.label_from(service.name)}
    handles : slop_os.Handle[protocols.LOAD_HANDLES_AND_GRANTS]
    process_rights :: rights(slop_os.Rights.[slop_os.RIGHT_PROCESS_THREADS, slop_os.RIGHT_DUPLICATE, slop_os.RIGHT_TRANSFER])
    handles[0] = slop_os.handle_duplicate(cast[slop_os.Handle](process), process_rights) or_return .Error(0)
    handles[1] = cast[slop_os.Handle](space)
    budget_rights :: rights(slop_os.Rights.[slop_os.RIGHT_BUDGET_CHARGE, slop_os.RIGHT_DUPLICATE, slop_os.RIGHT_TRANSFER])
    handles[2] = slop_os.handle_duplicate(cast[slop_os.Handle](budget), budget_rights) or_return .Error(0)
    module_rights :: rights(slop_os.Rights.[slop_os.RIGHT_MEMORY_READ, slop_os.RIGHT_TRANSFER])
    handles[3] = slop_os.handle_duplicate(module, module_rights) or_return .Error(0)
    count : usize = protocols.LOAD_HANDLES
    for grant in service.grants {
        if grant.count == 0 {
            continue
        }
        index :: cast[usize](request.grant_count)
        if index >= request.labels.count || count >= handles.count {
            return .Error(0)
        }
        handle :: grant_for(supervisor, grant) or_return .Error(0)
        request.labels[index] = protocols.label_from(grant)
        request.grant_count += 1
        handles[count] = handle
        count += 1
    }
    reply := protocols.LoadReply.{}
    match protocols.call(supervisor.manager, supervisor.manager_port, protocols.bytes_of(&request), view_of(&handles[0], count),
        protocols.mut_bytes_of(&reply)) {
        case Ok(received) => {}
        case Error(error) => return .Error(0)
    }
    if reply.status != .Loaded {
        _ = slop_os.handle_close(cast[slop_os.Handle](process))
        return .Error(cast[u64](cast[u32](reply.status)))
    }
    return .Ok(process)
}

// A handle for a grant system_config names.
grant_for :: fn(supervisor: ptr[mut Supervisor], name: string) -> slop_os.Handle? {
    if name == "debug_log" {
        log_rights :: rights(slop_os.Rights.[slop_os.RIGHT_DEBUG_LOG_WRITE, slop_os.RIGHT_DUPLICATE, slop_os.RIGHT_TRANSFER])
        match slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.log), log_rights) {
            case Ok(handle) => return handle
            case Error(error) => return null
        }
    }
    if name == "process_manager" {
        // A connection of its own: one end to the manager, which serves it, the other to the service
        pair :: slop_os.channel_create(supervisor.block.budget, 0) or_return null
        connect := protocols.ConnectRequest.{tag = protocols.PM_CONNECT}
        ends :: slop_os.Handle.[cast[slop_os.Handle](pair.a)]
        match protocols.send(supervisor.manager, supervisor.manager_port, protocols.bytes_of(&connect), ends) {
            case Some(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                return null
            }
            case None => return cast[slop_os.Handle](pair.b)
        }
    }
    return null
}

// A SupervisorReport to the root task.
tell_root :: fn(supervisor: ptr[mut Supervisor], tag: u32, code: u64, name: string) {
    report := protocols.SupervisorReport.{tag = tag, code = code, name = protocols.label_from(name)}
    none : slop_os.Handle[1]
    _ = protocols.send(supervisor.root, supervisor.root_port, protocols.bytes_of(&report), view_of(&none[0], 0))
}

rights :: fn(each: slop_os.Rights[]) -> slop_os.Rights {
    all : u32 = 0
    for right in each {
        all = all | cast[u32](right)
    }
    return cast[slop_os.Rights](all)
}
