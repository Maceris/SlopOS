/**
 * sftp_server (decisions/0191): SFTP for one connection, the program a session runs for SSH's sftp subsystem, given
 * only its user's home and the pipe to the SSH service, as OpenSSH's sftp-server is run. What the client sends comes
 * on the pipe, and SFTP's answers go back on it (src/sftp), until the client finishes.
 */
package sftp_server

import os from "std"
import ssh from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import pipe from "../../protocols/pipe"
import sftp from "../../sftp"

/**
 * Serve SFTP on a pipe, on a home.
 *
 * @param home The user's home, SFTP's root.
 * @param stream The pipe to the SSH service, the client's bytes on it.
 * @return 0 once the client's finished; 1 if a packet couldn't be one; 2 if the home or the pipe couldn't be used.
 */
main :: fn(home: os.Channel[dir.Dir], stream: os.Channel[pipe.Pipe]) -> int {
    directory, opened :: os.directory_on(home.end)
    if opened != null {
        return 2
    }
    port :: os.port_for(slop_os.startup_block().budget, stream.end) or_return 2
    state :: sftp.start_sftp(directory)
    defer sftp.end_sftp(state)
    loop {
        // Answers out first, in chunks a Write takes
        loop {
            if state.outbox_count == 0 {
                break
            }
            chunk :: if state.outbox_count < pipe.CHUNK_BYTES { state.outbox_count } else { cast[usize](pipe.CHUNK_BYTES) }
            out := os.Outgoing.{}
            request :: os.begin[pipe.Request](&out)
            request^ = .Write(os.append(&out, ssh.range(state.outbox[0..<sftp.OUTBOX_BYTES], 0, chunk)))
            if pipe.send_request(stream.end, port, &out) is_some {
                return 2
            }
            sftp.sent(state, chunk)
        }
        while true
        // Requests that came already, answered before reading more: one's answer can fill the outbox, and the client
        // waits on the rest
        waiting :: state.inbox_count
        if !sftp.serve(state) {
            return 1
        }
        if state.inbox_count < waiting {
            continue
        }
        // Then what's come in, as much as there's room for
        room :: sftp.SFTP_PACKET_BYTES - state.inbox_count
        if room == 0 {
            return 1
        }
        asking := os.Outgoing.{}
        os.begin[pipe.Request](&asking)^ = .Read(cast[u32](if room < pipe.CHUNK_BYTES { room } else { cast[usize](pipe.CHUNK_BYTES) }))
        if pipe.send_request(stream.end, port, &asking) is_some {
            return 2
        }
        into := os.Incoming.{}
        match pipe.receive_response(stream.end, port, &into, true) {
            case Received => {}
            case _ => return 2
        }
        match os.message_of[pipe.Response](&into)^ {
            case Data(bytes) => {
                for byte in os.items(&into, bytes) {
                    ssh.set_byte(state.inbox[0..<sftp.SFTP_PACKET_BYTES], state.inbox_count, byte)
                    if state.inbox_count < state.inbox.count {
                        state.inbox_count += 1
                    }
                }
            }
            case Ended => return 0
            case _ => return 2
        }
        if !sftp.serve(state) {
            return 1
        }
    }
    while true
    return 0
}
