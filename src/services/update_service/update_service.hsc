/**
 * The update service (roadmap 9d3, decisions/0113, 0116): it writes generations onto the EFI system partition, and
 * nothing else writes its boot directory. It's given the ESP's root, the system volume's updates directory, a
 * connection to the bundle store, and a listener the supervisor's connection arrives on.
 *
 * Once each boot is assessed, the supervisor says which generation booted and whether it's healthy (Booted):
 * - a tentative generation that booted healthy is made permanent; one that booted degraded is rolled back, its record
 *   removed, so the generation before it is the default again;
 * - an update staged in updates/pending (a generation's record, its kernel and boot set in the bundle store) is
 *   installed: each object read from the store and checked by its hash, the ESP's room checked first, the objects
 *   written as boot/objects/<hex>, then its record, tentative, which the bootloader boots next, the newest. One whose
 *   kernel, boot set and command line are the booted generation's changes only services, and is answered Live, for the
 *   supervisor to apply now (decisions/0126);
 * - what isn't kept is collected: the records of all but the generation that booted, any newer one, the newest
 *   permanent one before it, and the recovery generation, and every object none of those names; and a newer tentative
 *   generation the bootloader gave up on, out of tries (decisions/0134), is rolled back.
 *
 * And when the supervisor passes on the substitution policy the config store asks for (Substitute, decisions/0123,
 * 0125): unless the newest generation has it already, each entry is checked, from a library of the booted generation's
 * boot set and to one there or in the bundle store, by library_interface.check; if every one passes, the booted
 * generation is staged again, numbered after the newest, with the policy as its substitutions.records and each
 * substitute in its boot set, tentative and the default, so the next boot runs with it and a bad one is rolled back.
 */
package update_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import bundle from "../../bundle"
import generations from "../../generations"
import service_kit from "../../libraries/service_kit"
import library_interface from "../../library_interface"
import strings from "std"
import text_buffer from "std"
import substitution from "../../substitution"
import bundle_store from "../../protocols/bundle_store"
import update from "../../protocols/update"

PENDING :: "pending"

Service :: struct {
    block : ptr[slop_os.StartupBlock],
    port : slop_os.Port,
    connected : service_kit.Clients,
    // The ESP's root: one connection for its Room, one std's files use
    esp_raw : slop_os.Channel,
    esp_port : slop_os.Port,
    esp : os.Directory,
    updates : os.Directory,
    store : slop_os.Channel,
    store_port : slop_os.Port,
}

main :: fn(esp: os.Channel[dir.Dir], updates: os.Channel[dir.Dir], store: os.Channel[bundle_store.BundleStore],
    clients: os.Listener[update.Update]) -> int {
    made, error :: runtime.new_aligned(Service, align_of(Service))
    if error != null {
        return 99
    }
    service :: made
    service.block = slop_os.startup_block()
    service.port = slop_os.port_create(service.block.budget) or_return 1
    service.esp_raw = esp.end
    service.esp_port = os.port_for(service.block.budget, esp.end) or_return 2
    second :: dir.connect(esp.end, service.esp_port, service.block.budget) or_return 2
    esp_directory, esp_error :: os.directory_on(second.end)
    if esp_error != null {
        return 2
    }
    service.esp = esp_directory
    updates_directory, updates_error :: os.directory_on(updates.end)
    if updates_error != null {
        return 3
    }
    service.updates = updates_directory
    service.store = store.end
    service.store_port = os.port_for(service.block.budget, store.end) or_return 4
    if !service_kit.add_client(&service.connected, service.port, clients.end) {
        return 5
    }
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(service, i, &into)
            i += 1
        }
        while i < service.connected.count
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

serve :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.connected.ends.count {
        return void
    }
    end :: service.connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match update.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = update.answer_unsupported(end, service.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(&service.connected, index)
                return void
            }
        }
        answer := update.Response.Done
        match os.message_of[update.Request](into)^ {
            case Booted(booted) => answer = booted_as(service, booted)
            case Substitute(asked) => answer = substitute(service, asked)
        }
        out := os.Outgoing.{}
        os.begin[update.Response](&out)^ = answer
        _ = update.send_response(end, service.port, &out)
    }
}

/**
 * A boot's assessment acted on: its generation made permanent or rolled back, a staged update installed, and collection.
 */
booted_as :: fn(service: ptr[mut Service], booted: update.Booted) -> update.Response {
    current := booted.generation
    match read_record(service, booted.generation) {
        case Some(found) => {
            record := found
            if record.state == generations.STATE_TENTATIVE {
                if booted.healthy {
                    record.state = generations.STATE_PERMANENT
                    record.tries_left = 0
                    if write_record(service, &record) {
                        runtime.log_info("generation % made permanent", record.number)
                    }
                }
                else {
                    path_storage : u8[128]
                    _ = os.delete_file_in(service.esp, generations.record_path(record.number, &path_storage))
                    runtime.log_info("generation % booted degraded, and is rolled back", record.number)
                    current = 0
                }
            }
        }
        case None => {}
    }
    give_up_on_spent(service, booted.generation)
    installed :: install(service)
    collect(service, current)
    // One that changes only services applies now
    match installed {
        case Some(found) => match read_record(service, booted.generation) {
            case Some(booted_record) => {
                running := booted_record
                staged := found
                if booted.healthy && same_but_services(&running, &staged) {
                runtime.log_info("generation % changes only services, and is applied live", staged.number)
                return .Live(update.LiveOf.{generation = staged.number, store_root = staged.store_root})
            }
            }
            case None => {}
        }
        case None => {}
    }
    return .Done
}

/**
 * Tentative generations newer than the one booted that have no tries left (generations.tries_left): the bootloader
 * booted an older one as they never came up healthy, so they're rolled back, their records removed.
 */
give_up_on_spent :: fn(service: ptr[mut Service], booted: u64) {
    listed :: os.list_directory_in(service.esp, generations.RECORDS) or_return void
    defer os.free_directory_listing(listed)
    for entry in listed {
        number :: number_of(entry.name) or_continue
        found :: read_record(service, number) or_continue
        if number > booted && found.state == generations.STATE_TENTATIVE && found.tries_left == 0 {
            path_storage : u8[128]
            _ = os.delete_file_in(service.esp, generations.record_path(number, &path_storage))
            runtime.log_info("generation % never came up healthy in its tries, and is rolled back", number)
        }
    }
}

/**
 * Whether two generations have the same kernel, boot set and command line, so they differ only in their store roots.
 */
same_but_services :: fn(a: ptr[generations.Generation], b: ptr[generations.Generation]) -> bool {
    if !bundle.same(a.kernel, b.kernel) || a.file_count != b.file_count || a.kaslr != b.kaslr
        || generations.line_of(&a.command_line) != generations.line_of(&b.command_line) {
        return false
    }
    for i in cast[usize](0)..<a.files.count {
        if i < cast[usize](a.file_count) && (generations.text_of(&a.files[i].name) != generations.text_of(&b.files[i].name)
            || !bundle.same(a.files[i].hash, b.files[i].hash)) {
            return false
        }
    }
    return true
}

/**
 * The update staged in updates/pending installed, if there's one, and it's a generation's record whose objects the store
 * has with their hashes, and the ESP has room for them: its objects, then its record, tentative.
 */
install :: fn(service: ptr[mut Service]) -> generations.Generation? {
    pending_bytes :: os.read_entire_file_in(service.updates, PENDING) or_return null
    defer runtime.free_array(bit_cast[u8[]](pending_bytes))
    staged := match generations.generation_of(bit_cast[u8[]](pending_bytes)) {
        case Some(found) => found
        case None => {
            runtime.log_warn("updates/pending isn't a generation's record")
            return null
        }
    }
    // The recovery generation is written once, with the system, and never by an update
    if staged.state == generations.STATE_RECOVERY {
        runtime.log_warn("updates/pending is a recovery generation, which an update can't install")
        _ = os.delete_file_in(service.updates, PENDING)
        return null
    }
    if read_record(service, staged.number) is_some {
        runtime.log_warn("generation % is installed already", staged.number)
        _ = os.delete_file_in(service.updates, PENDING)
        return null
    }
    // What the ESP lacks, read from the store and checked first, so nothing's written that doesn't fit
    wanted : bundle.Hash[..]
    defer runtime.array_free(&wanted)
    staged_hashes := hashes_of(&staged)
    defer runtime.array_free(&staged_hashes)
    for hash in staged_hashes {
        if !on_esp(service, hash) && !has_hash(&wanted, hash) {
            runtime.array_add(&wanted, hash)
        }
    }
    objects : Object[..]
    defer free_all(&objects)
    needed := cast[u64](size_of(generations.Generation))
    for hash in wanted {
        bytes :: match object_of(service, hash) {
            case Some(read) => read
            case None => {
                runtime.log_warn("the store hasn't an object generation % names, whole", staged.number)
                return null
            }
        }
        runtime.array_add(&objects, Object.{bytes = bytes})
        needed += cast[u64](bytes.count)
    }
    room :: room_of(service) or_else files.Room.{}
    if room.size != 0 && needed > room.free {
        runtime.log_warn("generation % doesn't fit on the ESP: it needs % bytes, which has %", staged.number, needed, room.free)
        return null
    }
    for object, i in objects {
        if i < wanted.count {
            path_storage : u8[128]
            if os.write_entire_file_in(service.esp, generations.object_path(wanted[i], &path_storage), bit_cast[string](object.bytes)) != null {
                runtime.log_warn("generation %'s objects couldn't be written", staged.number)
                return null
            }
        }
    }
    staged.state = generations.STATE_TENTATIVE
    staged.tries_left = generations.TRIES
    if !write_record(service, &staged) {
        return null
    }
    _ = os.delete_file_in(service.updates, PENDING)
    runtime.log_info("installed generation %, tentative", staged.number)
    return staged
}

/**
 * What's kept: the generation booted (0 if it was rolled back) and any newer, the newest
 * permanent one before it, and the recovery generation; every other record removed, and every object none of those
 * names.
 */
collect :: fn(service: ptr[mut Service], current: u64) {
    records : generations.Generation[..]
    defer runtime.array_free(&records)
    listed :: os.list_directory_in(service.esp, generations.RECORDS) or_return void
    defer os.free_directory_listing(listed)
    for entry in listed {
        number :: number_of(entry.name) or_continue
        found :: read_record(service, number) or_continue
        runtime.array_add(&records, found)
    }
    previous := cast[u64](0)
    for each in records {
        if each.state == generations.STATE_PERMANENT && (current == 0 || each.number < current) && each.number > previous {
            previous = each.number
        }
    }
    kept : generations.Generation[..]
    defer runtime.array_free(&kept)
    for each in records {
        keep :: each.state == generations.STATE_RECOVERY || each.number == previous || (current != 0 && each.number >= current)
        if keep {
            runtime.array_add(&kept, each)
        }
        else {
            path_storage : u8[128]
            _ = os.delete_file_in(service.esp, generations.record_path(each.number, &path_storage))
            runtime.log_info("generation % collected", each.number)
        }
    }
    // Objects no kept generation names
    used : bundle.Hash[..]
    defer runtime.array_free(&used)
    for &each in kept {
        hashes := hashes_of(each)
        for hash in hashes {
            runtime.array_add(&used, hash)
        }
        runtime.array_free(&hashes)
    }
    objects :: os.list_directory_in(service.esp, generations.OBJECTS) or_return void
    defer os.free_directory_listing(objects)
    for entry in objects {
        hash :: bundle.from_hex(entry.name) or_continue
        if !has_hash(&used, hash) {
            path_storage : u8[128]
            _ = os.delete_file_in(service.esp, generations.object_path(hash, &path_storage))
        }
    }
}

/**
 * The substitution policy asked for: nothing if the newest generation has it, refused if an entry doesn't pass the
 * check, or the booted generation staged again with it.
 */
substitute :: fn(service: ptr[mut Service], asked: update.SubstituteOf) -> update.Response {
    booted :: read_record(service, asked.generation) or_return .Refused
    newest :: newest_number(service)
    current :: read_record(service, newest) or_else booted
    if same_policy(policy_in(service, &current), asked.policy) {
        return .Done
    }
    made := booted
    made.number = newest + 1
    made.state = generations.STATE_TENTATIVE
    made.tries_left = generations.TRIES
    // Its boot set without the booted generation's policy
    kept := cast[u32](0)
    for i in cast[usize](0)..<made.files.count {
        if i < cast[usize](made.file_count) && generations.text_of(&made.files[i].name) != substitution.POLICY_FILE {
            if cast[usize](kept) < made.files.count {
                made.files[kept] = made.files[i]
            }
            kept += 1
        }
    }
    made.file_count = kept
    for &entry, i in asked.policy.entries {
        if cast[u64](i) >= asked.policy.count {
            break
        }
        old :: library_in(service, &booted, entry.from) or_else bundle.Hash.{}
        if !bundle.same(old, entry.from) {
            runtime.log_warn("a substitution is refused: generation % has no library with its hash", booted.number)
            return .Refused
        }
        old_bytes :: object_on_esp(service, entry.from) or_return .Refused
        defer runtime.free_array(old_bytes)
        new_bytes :: match object_on_esp(service, entry.to) {
            case Some(found) => found
            case None => match object_of(service, entry.to) {
                case Some(found) => found
                case None => {
                    runtime.log_warn("a substitution is refused: its substitute is neither on the ESP nor in the store")
                    return .Refused
                }
            }
        }
        defer runtime.free_array(new_bytes)
        match library_interface.check(old_bytes, new_bytes) {
            case Some(why) => {
                runtime.log_warn("a substitution is refused: %", why)
                return .Refused
            }
            case None => {}
        }
        // The substitute in the boot set, as <the start of its hash>.library, unless it's there already
        if library_in(service, &made, entry.to) is_none {
            if !on_esp(service, entry.to) && !write_object(service, entry.to, new_bytes) {
                return .Refused
            }
            hex_storage : u8[64]
            hex :: bundle.hex(entry.to, &hex_storage)
            name_storage : u8[64]
            name := text_buffer.make(name_storage)
            text_buffer.append(&name, if hex.count >= 16 { hex[0..<16] } else { hex })
            text_buffer.append(&name, ".library")
            if !add_file(&made, text_buffer.as_string(&name), entry.to) {
                return .Refused
            }
        }
    }
    record :: substitution.policy_record(asked.policy)
    record_hash :: bundle.hash_of(record)
    if !on_esp(service, record_hash) && !write_object(service, record_hash, record) {
        return .Refused
    }
    if !add_file(&made, substitution.POLICY_FILE, record_hash) || (generations.check(&made) is_some) || !write_record(service, &made) {
        return .Refused
    }
    runtime.log_info("generation % staged with % substitutions, booted next", made.number, asked.policy.count)
    collect(service, asked.generation)
    return .Staged(made.number)
}

/** The policy a generation's boot set has, or none. */
policy_in :: fn(service: ptr[mut Service], generation: ptr[generations.Generation]) -> bundle.Substitutions {
    for i in cast[usize](0)..<generation.files.count {
        if i >= cast[usize](generation.file_count) || generations.text_of(&generation.files[i].name) != substitution.POLICY_FILE {
            continue
        }
        bytes :: object_on_esp(service, generation.files[i].hash) or_return bundle.Substitutions.{}
        defer runtime.free_array(bytes)
        return substitution.policy_of(bytes) or_else bundle.Substitutions.{}
    }
    return bundle.Substitutions.{}
}

same_policy :: fn(a: bundle.Substitutions, b: bundle.Substitutions) -> bool {
    if a.count != b.count {
        return false
    }
    for i in cast[usize](0)..<a.entries.count {
        if cast[u64](i) < a.count && (!bundle.same(a.entries[i].from, b.entries[i].from) || !bundle.same(a.entries[i].to, b.entries[i].to)) {
            return false
        }
    }
    return true
}

/** The hash of a library in a generation's boot set whose file has hash, or null. */
library_in :: fn(service: ptr[mut Service], generation: ptr[generations.Generation], hash: bundle.Hash) -> bundle.Hash? {
    for i in cast[usize](0)..<generation.files.count {
        if i < cast[usize](generation.file_count) && strings.ends_with(generations.text_of(&generation.files[i].name), ".library")
            && bundle.same(generation.files[i].hash, hash) {
            return hash
        }
    }
    return null
}

/** A file added to a generation's boot set: whether there was room and the name fits. */
add_file :: fn(generation: ptr[mut generations.Generation], name: string, hash: bundle.Hash) -> bool {
    at :: cast[usize](generation.file_count)
    if at >= generation.files.count || !generations.set_name(&generation.files[at].name, name) {
        return false
    }
    generation.files[at].hash = hash
    generation.file_count += 1
    return true
}

/** The newest generation's number but the recovery generation's, 0 if there's none. */
newest_number :: fn(service: ptr[mut Service]) -> u64 {
    newest := cast[u64](0)
    listed :: os.list_directory_in(service.esp, generations.RECORDS) or_return 0
    defer os.free_directory_listing(listed)
    for entry in listed {
        number :: number_of(entry.name) or_continue
        if number != generations.RECOVERY_NUMBER && number > newest {
            newest = number
        }
    }
    return newest
}

/** An object's bytes from the ESP, which the caller frees, or null. */
object_on_esp :: fn(service: ptr[mut Service], hash: bundle.Hash) -> u8[]? {
    path_storage : u8[128]
    text :: os.read_entire_file_in(service.esp, generations.object_path(hash, &path_storage)) or_return null
    return bit_cast[u8[]](text)
}

write_object :: fn(service: ptr[mut Service], hash: bundle.Hash, bytes: u8[]) -> bool {
    path_storage : u8[128]
    if os.write_entire_file_in(service.esp, generations.object_path(hash, &path_storage), bit_cast[string](bytes)) != null {
        runtime.log_warn("an object couldn't be written to the ESP")
        return false
    }
    return true
}

/** The kernel's hash, and every boot-set file's. */
hashes_of :: fn(generation: ptr[generations.Generation]) -> bundle.Hash[..] {
    made : bundle.Hash[..]
    runtime.array_add(&made, generation.kernel)
    for i in cast[usize](0)..<generation.files.count {
        if i < cast[usize](generation.file_count) {
            runtime.array_add(&made, generation.files[i].hash)
        }
    }
    return made
}

/** The generation numbered number's record on the ESP, checked, or null. */
read_record :: fn(service: ptr[mut Service], number: u64) -> generations.Generation? {
    if number == 0 {
        return null
    }
    path_storage : u8[128]
    bytes :: os.read_entire_file_in(service.esp, generations.record_path(number, &path_storage)) or_return null
    defer runtime.free_array(bit_cast[u8[]](bytes))
    return generations.generation_of(bit_cast[u8[]](bytes))
}

write_record :: fn(service: ptr[mut Service], generation: ptr[generations.Generation]) -> bool {
    path_storage : u8[128]
    if os.write_entire_file_in(service.esp, generations.record_path(generation.number, &path_storage),
        bit_cast[string](generations.bytes_of(generation))) != null {
        runtime.log_warn("generation %'s record couldn't be written", generation.number)
        return false
    }
    return true
}

/** Whether the ESP has an object. */
on_esp :: fn(service: ptr[mut Service], hash: bundle.Hash) -> bool {
    path_storage : u8[128]
    return os.path_kind_in(service.esp, generations.object_path(hash, &path_storage)) == .FILE
}

/**
 * An object's bytes from the bundle store, which the caller frees, if it has the object and its bytes have its hash.
 */
object_of :: fn(service: ptr[mut Service], hash: bundle.Hash) -> u8[]? {
    out := os.Outgoing.{}
    os.begin[bundle_store.Request](&out)^ = .Get(hash)
    into := os.Incoming.{}
    object :: match bundle_store.ask(service.store, service.store_port, &out, &into) {
        case Got(got) => got
        case _ => return null
    }
    defer slop_os.handle_close(cast[slop_os.Handle](object.memory))
    size :: (object.size + 4095) & ~cast[u64](4095)
    if size == 0 {
        return null
    }
    address :: runtime.reserve_addresses(cast[usize](size)) or_return null
    if slop_os.memory_map(object.memory, service.block.space, address, 0, size, slop_os.PROTECTION_READ) is_error {
        return null
    }
    defer slop_os.memory_unmap(service.block.space, address)
    copy, error :: runtime.new_array(u8, cast[usize](object.size))
    if error != null {
        return null
    }
    for i in 0..<copy.count {
        copy[i] = cast[ptr[u8]](address + cast[u64](i))^
    }
    if !bundle.same(bundle.hash_of(copy), hash) {
        runtime.free_array(copy)
        return null
    }
    return copy
}

/** The ESP's room, as its file server says, or null if it doesn't. */
room_of :: fn(service: ptr[mut Service]) -> files.Room? {
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Room
    if dir.send_request(service.esp_raw, service.esp_port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    loop {
        match dir.receive_response(service.esp_raw, service.esp_port, &into, true) {
            case Received => break
            case Failed(error) => return null
            case _ => continue
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case Room(room) => room
        case _ => null
    }
}

has_hash :: fn(hashes: ptr[bundle.Hash[..]], hash: bundle.Hash) -> bool {
    for each in hashes^ {
        if bundle.same(each, hash) {
            return true
        }
    }
    return false
}

/** An object's bytes, read from the store, which free_all frees. */
Object :: struct {
    bytes : u8[],
}

free_all :: fn(all: ptr[mut Object[..]]) {
    for each in all^ {
        runtime.free_array(each.bytes)
    }
    runtime.array_free(all)
}

/** A decimal number, or null. */
number_of :: fn(text: string) -> u64? {
    if text.count == 0 {
        return null
    }
    value := cast[u64](0)
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}
