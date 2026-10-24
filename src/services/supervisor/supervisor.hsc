/*
 * The supervisor (decisions/0017, 0058, 0067, 0068), a stub for now: it starts the services system_config
 * gives it through the process manager, with std/os's launch, each in a process of its own that it owns
 * and pays for from its budget, and tells the root task as each starts and ends. Restarting them comes
 * with M7's drivers.
 */
package supervisor

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import protocols from "../../protocols"
import system_config from "../../system_config"
import hello from "../../apps/hello"

// What hello is given (hello.main).
HelloGrants :: struct {
    log : slop_os.DebugLog?,
    manager : os.Channel[process_manager.ProcessManager]?,
}

Supervisor :: struct {
    block : ptr[slop_os.StartupBlock],
    log : slop_os.DebugLog,
    manager : os.Channel[process_manager.ProcessManager],
    manager_port : slop_os.Port,
    root : slop_os.Channel,
    root_port : slop_os.Port,
}

main :: fn(log: slop_os.DebugLog?, manager: os.Channel[process_manager.ProcessManager], root: os.Channel[protocols.Supervision],
    hello_module: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    supervisor := Supervisor.{block = block, manager = manager, root = root.end}
    supervisor.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    supervisor.manager_port = os.port_for(block.budget, manager.end) or_return 1
    supervisor.root_port = os.port_for(block.budget, root.end) or_return 2
    port :: slop_os.port_create(block.budget) or_return 3
    // hello, the one service it starts so far
    service :: system_config.service("hello") or_return 4
    grants := HelloGrants.{}
    match duplicate_log(&supervisor) {
        case Some(copy) => grants.log = copy
        case None => {}
    }
    match protocols.connect(manager.end, supervisor.manager_port, block.budget, process_manager.RING_BYTES) {
        case Some(end) => grants.manager = os.Channel[process_manager.ProcessManager].{end = end}
        case None => {}
    }
    started := false
    match os.launch(manager, supervisor.manager_port, service.name, hello_module, service.budget, hello.main, grants) {
        case Ok(launched) => {
            _ = slop_os.port_bind(port, cast[slop_os.Handle](launched.process), slop_os.SIGNAL_TERMINATED, 0, .Once)
            started = true
            tell_root(&supervisor, protocols.SUPERVISOR_STARTED, 0, service.name)
        }
        case Error(error) => {
            log_line.write(supervisor.log, "supervisor: % didn't start: %", service.name, error)
            tell_root(&supervisor, protocols.SUPERVISOR_FAILED, cast[u64](error) + 1, service.name)
        }
    }
    log_line.write(supervisor.log, "supervisor: started % services", if started { 1 } else { 0 })
    loop {
        packets : slop_os.Packet[8]
        taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
        for packet, i in packets {
            if i >= cast[usize](taken) {
                break
            }
            if packet.kind == .Signal && packet.key == 0 {
                log_line.write(supervisor.log, "supervisor: % ended", service.name)
                tell_root(&supervisor, protocols.SUPERVISOR_ENDED, packet.data[1], service.name)
            }
        }
    }
}

// A copy of the supervisor's debug log, to give a service.
duplicate_log :: fn(supervisor: ptr[mut Supervisor]) -> slop_os.DebugLog? {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    match slop_os.handle_duplicate(cast[slop_os.Handle](supervisor.log), rights) {
        case Ok(handle) => return cast[slop_os.DebugLog](handle)
        case Error(error) => return null
    }
}

// A SupervisorReport to the root task.
tell_root :: fn(supervisor: ptr[mut Supervisor], tag: u32, code: u64, name: string) {
    report := protocols.SupervisorReport.{tag = tag, code = code, name = os.label_from(name)}
    none : slop_os.Handle[1]
    _ = os.send(supervisor.root, supervisor.root_port, os.bytes_of(&report), view_of(&none[0], 0))
}
