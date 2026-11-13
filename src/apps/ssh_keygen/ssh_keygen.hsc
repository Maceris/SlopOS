/**
 * ssh_keygen (decisions/0191, 14f): make your SSH key, Ed25519, in .ssh beneath the shell's directory, your home:
 * id_ed25519, OpenSSH's private key text, unencrypted, as the home is; and id_ed25519.pub, its public key's line, for a
 * server's authorized_keys or SlopOS's keys. A key that's there already is kept, not made again.
 *
 *     ssh_keygen
 */
package ssh_keygen

import crypto from "std"
import os from "std"
import ssh from "std"
import dir from "std/os/slop_os"
import file_tools from "../../file_tools"

/** The key made: where, and its fingerprint. */
Made :: struct {
    /** Its private key's file, beneath the shell's directory. */
    file : string,
    /** Its fingerprint, SHA256:..., as ssh-keygen -l shows it. */
    fingerprint : string,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    parameter : os.ParameterName,
}

/** Why it couldn't. */
KeygenError :: union {
    /** .ssh/id_ed25519 is there already: it's kept. */
    AlreadyExists(Problem),
    /** The key couldn't be written. */
    Unwritable(Problem),
}

/**
 * Make an Ed25519 key in .ssh.
 *
 * @param here The shell's directory, given without asking, which .ssh is made in.
 * @return The key's file and fingerprint.
 * @error AlreadyExists There's a key already; its .pub has its public key.
 * @error Unwritable .ssh or the key's files couldn't be written.
 */
main :: fn(here: os.Channel[dir.Dir]) -> Result[Made, KeygenError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "here"}}
    directory, opened :: os.directory_on(here.end)
    if opened != null {
        return .Error(.Unwritable(problem))
    }
    if os.path_kind_in(directory, ".ssh/id_ed25519") != .NOTHING {
        return .Error(.AlreadyExists(problem))
    }
    if os.path_kind_in(directory, ".ssh") == .NOTHING && (os.make_directory_in(directory, ".ssh") is_some) {
        return .Error(.Unwritable(problem))
    }
    printed :: write_key(directory) or_return .Error(.Unwritable(problem))
    return .Ok(Made.{file = ".ssh/id_ed25519", fingerprint = file_tools.copy_of(printed[0..<50]) or_else ""})
}

/** Make a key and write its files; its fingerprint, or null if they couldn't be written. */
write_key #constant_time :: fn(directory: os.Directory) -> u8[50]? {
    random : u8[32]
    ssh.random_bytes(random[0..<32])
    key : crypto.Ed25519SecretKey
    for i in cast[usize](0)..<32 {
        key[i] = random[i]
        random[i] = 0
    }
    text : u8[ssh.PRIVATE_KEY_TEXT_BYTES]
    length :: ssh.private_key_text(&key, "slopos", text[0..<ssh.PRIVATE_KEY_TEXT_BYTES])
    if length == 0 || length > text.count || (os.write_entire_file_in(directory, ".ssh/id_ed25519", string_of(&text[0], length)) is_some) {
        return null
    }
    for &byte in text {
        byte^ = 0
    }
    public :: crypto.ed25519_public_key(&key)
    blob :: ssh.ed25519_blob(&public)
    made :: ssh.parse_public_key(blob[0..<ssh.ED25519_BLOB_BYTES]) or_return null
    line : u8[200]
    line_length :: ssh.key_line(&made, "slopos", line[0..<200])
    if line_length == 0 || line_length >= line.count {
        return null
    }
    line[line_length] = 0x0a
    if os.write_entire_file_in(directory, ".ssh/id_ed25519.pub", string_of(&line[0], line_length + 1)) is_some {
        return null
    }
    return ssh.fingerprint(blob[0..<ssh.ED25519_BLOB_BYTES])
}
