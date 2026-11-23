/**
 * Steering a program the shell started, on the user's say (decisions/0195, 18b): a program to debug, record or replay
 * is started held at its first call by an intercept the shell can't steer with, and the shell asks the session's
 * powerbox to steer it, which the user allows on the trusted path, as debugging their own program. Allowed, the process
 * manager gives the shell the intercept and the process with the rights to steer; refused, the program's ended.
 */
package shell

import os from "std:os"
import slop_os from "std:os/slop_os"
import process_manager from "std:os/slop_os/process_manager"
import powerbox from "../../protocols/powerbox"
import shell_language as language from "../../shell_language"

/**
 * Ask the powerbox to let the shell steer a program it's started, and wait for the user: allowed, the call's launched
 * has the steering handles, its process the steering one and its owner the owning one, which end_call closes too.
 *
 * @param shell The shell, whose powerbox connection asks.
 * @param call The call, its program started held by its intercept.
 * @param purpose Why, as the user's shown it: "to debug it", "to record it", "to replay it".
 * @return Null once it's steered; why not otherwise, the program then ended: no powerbox, the powerbox busy, or the
 *     user refused.
 */
steer_started :: fn(shell : ptr[mut Shell], call : ptr[mut Call], purpose : string) -> EvalError? {
    steered :: ask_to_steer(shell, call, purpose)
    if steered is_some {
        _ = slop_os.process_kill(call.launched.process)
    }
    return steered
}

/**
 * Ask, as steer_started says, without ending the program when it's refused.
 *
 * @return Null once it's steered; why not otherwise.
 */
ask_to_steer :: fn(shell : ptr[mut Shell], call : ptr[mut Call], purpose : string) -> EvalError? {
    tree :: call.tree
    end :: powerbox_connection(shell, "shell")
        or_return EvalError.{message = message("% needs the session's powerbox, which this session hasn't", tree.text), at = tree.at}
    defer slop_os.handle_close(cast[slop_os.Handle](end))
    port :: os.port_for(slop_os.startup_block().budget, end)
        or_return EvalError.{message = "the powerbox can't be reached", at = tree.at}
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    process :: slop_os.handle_duplicate(
        cast[slop_os.Handle](call.launched.process),
        cast[slop_os.Rights](cast[u32](slop_os.RIGHT_PROCESS_KILL)
            | cast[u32](slop_os.RIGHT_DUPLICATE)
            | cast[u32](slop_os.RIGHT_TRANSFER))
    ) or_return EvalError.{message = "its process can't be given to the powerbox", at = tree.at}
    out := os.Outgoing.{}
    request :: os.begin[powerbox.Request](&out)
    request^ = .RequestSteer(
        powerbox.SteerRequest.{
            name = os.append(&out, string_bytes(tree.text)),
            purpose = os.append(&out, string_bytes(purpose)),
            process = cast[slop_os.Process](process),
        }
    )
    if powerbox.send_request(end, port, &out) != null {
        return EvalError.{message = "the powerbox can't be reached", at = tree.at}
    }
    say(shell, "Press Ctrl+Alt+Delete: Enter allows it.")
    into := os.Incoming.{}
    match powerbox.receive_response(end, port, &into, true) {
        case Received => {}
        case _ => return EvalError.{message = "the powerbox can't be reached", at = tree.at}
    }
    // What came, read apart from the errors made of it, so none is taken to point into into
    given := powerbox_steering_none()
    busy := false
    match os.message_of[powerbox.Response](&into)^ {
        case Steered(steering) => given = steering
        case Busy => busy = true
        case _ => {}
    }
    if busy {
        return EvalError.{message = "the powerbox is asking the user something else; try again once that's answered", at = tree.at}
    }
    if cast[slop_os.Handle](given.process) == slop_os.NO_HANDLE {
        return EvalError.{message = message("% wasn't allowed", tree.text), at = tree.at}
    }
    // The steering handles in place of the launch's, its owning handle kept apart
    match call.launched.faults {
        case Some(faults) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](faults.intercept))
            _ = slop_os.handle_close(cast[slop_os.Handle](faults.space))
        }
        case None => {}
    }
    call.launched.faults = os.LaunchedFaults.{intercept = given.intercept, space = given.space}
    call.owner = call.launched.process
    call.launched.process = given.process
    return null
}

/** No steering handles, before they're given. */
powerbox_steering_none :: fn() -> process_manager.Steering {
    return process_manager.Steering.{
        intercept = cast[slop_os.Intercept](slop_os.NO_HANDLE),
        process = cast[slop_os.Process](slop_os.NO_HANDLE),
        space = cast[slop_os.AddressSpace](slop_os.NO_HANDLE),
    }
}
