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

/**
 * The file in the updates directory an update is staged in: a generation's record, whose kernel and boot set are in
 * the bundle store. It's removed once installed, or once it's found to be one that can't be.
 */
PENDING :: "pending"

/** The update service's state, made once in main, on the heap, and kept for as long as it runs. */
Service :: struct {
    /** The process's startup block, whose budget pays for the ports and the memory objects are read into. */
    block : ptr[slop_os.StartupBlock],
    /** The port the clients are bound to, waited on in main. */
    port : slop_os.Port,
    /** The clients' ends: the supervisor's, from the listener. */
    connected : service_kit.Clients,
    /** The ESP's root: a connection of its own, for asking its Room. */
    esp_raw : slop_os.Channel,
    /** A port bound to esp_raw, waited on for its answers. */
    esp_port : slop_os.Port,
    /** A second connection to the ESP's root, which std's files use: records and objects are read and written here. */
    esp : os.Directory,
    /** The system volume's updates directory, where an update is staged as PENDING. */
    updates : os.Directory,
    /** A connection to the bundle store, which a staged update's objects, and substitutes, are read from. */
    store : slop_os.Channel,
    /** A port bound to store, waited on for its answers. */
    store_port : slop_os.Port,
}

/**
 * Write generations onto the EFI system partition: make a booted one permanent or roll it back, install a staged
 * update, collect what isn't kept, and stage a generation with a substitution policy, as the supervisor asks.
 *
 * Runs until it's stopped, answering the supervisor's requests as they come.
 *
 * @param esp The ESP's root directory, whose boot directory only this service writes.
 * @param updates The system volume's updates directory, where an update is staged as pending.
 * @param store A connection to the bundle store, which a staged update's kernel and boot set, and substitutes, are
 *     read from.
 * @param clients The listener the supervisor's connection arrives on.
 * @return 99 without the memory for its state, 1 if its port couldn't be made, 2 if esp couldn't be connected to and
 *     opened as a directory, 3 if updates couldn't be opened as one, 4 if a port for store couldn't be made, and 5 if
 *     clients couldn't be added as a client. It doesn't return otherwise.
 */
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

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * Each request is acted on and answered before the next is read. One the protocol doesn't know is answered with
 * Unsupported; one that can't be read is skipped. A client whose end fails is dropped, its end closed.
 *
 * @param service The service's state: requests are read from, and answered on, service.connected's ends through its
 *     port, and Booted and Substitute act on the ESP, updates and the store; a client whose end fails is dropped from
 *     connected.
 * @param index The client's index in service.connected; one past them, or one already dropped, is left alone.
 * @param into Where each request is read into, reused from one to the next.
 */
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
            case _ => {
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
 * Act on a boot's assessment: make its generation permanent or roll it back, roll back newer tentative generations
 * with no tries left, install a staged update, and collect what isn't kept, in that order.
 *
 * A tentative generation that booted healthy has its record written again, permanent, with no tries left; one that
 * booted degraded has its record removed, so the generation before it is the default again. A generation that isn't
 * tentative, or has no record, is left as it is.
 *
 * @param service The service's state: records and objects on the ESP are read, written and removed through esp, pending
 *     is read and removed in updates, objects are read from store, and the ESP's room is asked on esp_raw.
 * @param booted The generation booted, 0 for none, as from an ISO, and whether it came up healthy.
 * @return Live, with the generation installed and its store root, when the update installed has the healthy booted
 *     generation's kernel, boot set and command line, so it changes only services and the supervisor applies it now
 *     (decisions/0126); Done otherwise, whatever failed along the way, which is logged.
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
    installed_number := cast[u64](0)
    match installed {
        case Some(found) => installed_number = found.number
        case None => {}
    }
    collect(service, current, installed_number)
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
 * Roll back the tentative generations newer than the one booted that have no tries left (generations.tries_left),
 * removing their records: the bootloader booted an older one as they never came up healthy (decisions/0134).
 *
 * @param service The service's state, through whose esp the records are listed, read and removed.
 * @param booted The generation booted's number; 0 makes every spent tentative generation newer than none.
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
 * Tell whether two generations have the same kernel, boot set and command line, so they differ only in their store
 * roots, and so in the services they run.
 *
 * @param a One, the generation running.
 * @param b The other, the one installed.
 * @return Whether their kernels, KASLR, command lines and boot sets, each file's name and hash in order, are the same.
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
 * Install the update staged in updates/pending, if there's one: its objects, then its record, tentative, with
 * generations.TRIES tries, which the bootloader boots next, the newest.
 *
 * The objects the ESP lacks are each read from the bundle store and checked by their hash, and the ESP's room checked
 * against them and the record, before anything's written, so nothing's written that doesn't fit. Objects are written
 * as boot/objects/<hex> before the record, so a record never names an object that isn't there; but an object is
 * written in place, not renamed into it, so a crash while writing one can leave it partial.
 *
 * Pending is removed once installed, and when it's a recovery generation or one installed already; it's kept when it
 * isn't a generation's record, the store lacks an object, the ESP hasn't the room, or a write fails, each logged.
 *
 * @param service The service's state: pending is read and removed through updates, objects are read from store, the
 *     room is asked on esp_raw, and the objects and the record are written through esp.
 * @return The generation installed, as its record was written; null if nothing was.
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
 * Collect what isn't kept on the ESP: every record but the generation booted and any newer, the newest permanent one
 * before it, the recovery generation, and the one just installed; then every object none of those names.
 *
 * Failures to list or remove are passed over: what's left is collected another time.
 *
 * @param service The service's state, through whose esp records and objects are listed, read and removed.
 * @param current The generation booted's number; 0 if it was rolled back, or none was booted, when only the newest
 *     permanent generation and the recovery generation are kept, and no newer one but installed.
 * @param installed The generation install just put on the ESP, tentative and not yet booted, which is kept whatever
 *     current is, so an update installed after a rollback isn't collected at once; 0 for none.
 */
collect :: fn(service: ptr[mut Service], current: u64, installed: u64) {
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
            || (installed != 0 && each.number == installed)
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
 * Act on the substitution policy the config store asks for (decisions/0123, 0125): stage the booted generation again
 * with it, unless the newest generation has it already.
 *
 * Each entry is checked, from a library in the booted generation's boot set to one on the ESP or in the bundle store,
 * by library_interface.check. If every one passes, a copy of the booted generation, numbered after the newest, with
 * the policy as its substitutions.records and each substitute in its boot set as <the start of its hash>.library, is
 * written, tentative with generations.TRIES tries, the default for the next boot, so a bad one is rolled back. Then
 * what isn't kept is collected.
 *
 * @param service The service's state: records and objects are read and written through esp, a substitute the ESP lacks
 *     is read from store, and what isn't kept is collected.
 * @param asked The policy, and the generation booted, which the new one is a copy of.
 * @return Done if the newest generation has the policy already; Staged with the new generation's number; or Refused
 *     if the booted generation has no record, an entry's library isn't in its boot set or on the ESP, its substitute
 *     can't be had or doesn't pass the check, or the generation can't be made or written. Objects written before a
 *     refusal are left for collection.
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
    collect(service, asked.generation, 0)
    return .Staged(made.number)
}

/**
 * Read the substitution policy a generation's boot set has.
 *
 * @param service The service's state, through whose ESP connection the policy's object is read.
 * @param generation The generation whose boot set is searched, its first file_count files only; only read.
 * @return The policy in its substitution.POLICY_FILE; an empty one if it has none, or it can't be read from the ESP.
 */
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

/**
 * Tell whether two substitution policies are the same.
 *
 * @param a The first policy compared, its first count entries; only read.
 * @param b The second policy compared, its first count entries; only read.
 * @return Whether they have as many entries, each the same from and to, in the same order.
 */
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

/**
 * Find a library in a generation's boot set by its hash.
 *
 * @param service Unused.
 * @param generation The generation whose boot set is searched, its first file_count files only; only read.
 * @param hash The library's object's hash, compared with each file's whole.
 * @return hash, if a file in the boot set whose name ends in .library has it; null otherwise.
 */
library_in :: fn(service: ptr[mut Service], generation: ptr[generations.Generation], hash: bundle.Hash) -> bundle.Hash? {
    for i in cast[usize](0)..<generation.files.count {
        if i < cast[usize](generation.file_count) && strings.ends_with(generations.text_of(&generation.files[i].name), ".library")
            && bundle.same(generation.files[i].hash, hash) {
            return hash
        }
    }
    return null
}

/**
 * Add a file to a generation's boot set, after those it has.
 *
 * @param generation The generation, changed only in memory.
 * @param name The file's name in the boot set.
 * @param hash The file's object's hash.
 * @return Whether it was added; false if the boot set is full, or the name doesn't fit a file's name.
 */
add_file :: fn(generation: ptr[mut generations.Generation], name: string, hash: bundle.Hash) -> bool {
    at :: cast[usize](generation.file_count)
    if at >= generation.files.count || !generations.set_name(&generation.files[at].name, name) {
        return false
    }
    generation.files[at].hash = hash
    generation.file_count += 1
    return true
}

/**
 * Find the newest generation on the ESP, by its record's number.
 *
 * @param service The service's state, only read: the records are listed through esp.
 * @return The highest number among the records but the recovery generation's; 0 if there's none, or the records
 *     can't be listed.
 */
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

/**
 * Read an object from the ESP, as boot/objects/<hex>, without checking its hash.
 *
 * @param service The service's state, only read: the object's file is read through esp.
 * @param hash The hash naming boot/objects/<hex>; the bytes read aren't checked against it.
 * @return Its bytes, from the context's allocator, which the caller frees; null if it isn't there or can't be read.
 */
object_on_esp :: fn(service: ptr[mut Service], hash: bundle.Hash) -> u8[]? {
    path_storage : u8[128]
    text :: os.read_entire_file_in(service.esp, generations.object_path(hash, &path_storage)) or_return null
    return bit_cast[u8[]](text)
}

/**
 * Write an object to the ESP, as boot/objects/<hex>: first whole as boot/objects/<hex>.part, then renamed into place,
 * so a crash while writing leaves at most a .part file, which nothing names, never a partial object that on_esp would
 * take as there and a generation would boot.
 *
 * @param service The service's state, through whose esp the file is written.
 * @param hash The object's hash, which bytes are trusted to have.
 * @param bytes The bytes written, all of them, in place of any file there; only read, and not checked against hash.
 * @return Whether it was written and renamed into place; a failure is logged, and leaves no object under its name.
 */
write_object :: fn(service: ptr[mut Service], hash: bundle.Hash, bytes: u8[]) -> bool {
    path_storage : u8[128]
    path :: generations.object_path(hash, &path_storage)
    part_storage : u8[160]
    part := text_buffer.make(part_storage)
    text_buffer.append(&part, path)
    text_buffer.append(&part, ".part")
    if part.truncated || os.write_entire_file_in(service.esp, text_buffer.as_string(&part), bit_cast[string](bytes)) != null {
        runtime.log_warn("an object couldn't be written to the ESP")
        return false
    }
    if os.rename_in(service.esp, text_buffer.as_string(&part), path) != null {
        _ = os.delete_file_in(service.esp, text_buffer.as_string(&part))
        runtime.log_warn("an object written to the ESP couldn't be renamed into place")
        return false
    }
    return true
}

/**
 * List the objects a generation names.
 *
 * @param generation The generation whose kernel and first file_count boot-set files are listed; only read.
 * @return The kernel's hash, then every boot-set file's, in order, repeats kept, from the context's allocator, which
 *     the caller frees.
 */
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

/**
 * Read a generation's record from the ESP, checked by generations.generation_of.
 *
 * @param service The service's state, only read: the record is read through esp.
 * @param number The generation's number; 0, no generation, gives null.
 * @return The generation; null if its record isn't there, can't be read, or isn't a valid record.
 */
read_record :: fn(service: ptr[mut Service], number: u64) -> generations.Generation? {
    if number == 0 {
        return null
    }
    path_storage : u8[128]
    bytes :: os.read_entire_file_in(service.esp, generations.record_path(number, &path_storage)) or_return null
    defer runtime.free_array(bit_cast[u8[]](bytes))
    return generations.generation_of(bit_cast[u8[]](bytes))
}

/**
 * Write a generation's record to the ESP, in place of any it has.
 *
 * The record is written in place, not renamed into it, so a crash while writing can leave it partial, which
 * read_record then refuses.
 *
 * @param service The service's state, through whose esp the record is written.
 * @param generation The generation, whose number names the record.
 * @return Whether it was written; a failure is logged.
 */
write_record :: fn(service: ptr[mut Service], generation: ptr[generations.Generation]) -> bool {
    path_storage : u8[128]
    if os.write_entire_file_in(service.esp, generations.record_path(generation.number, &path_storage),
        bit_cast[string](generations.bytes_of(generation))) != null {
        runtime.log_warn("generation %'s record couldn't be written", generation.number)
        return false
    }
    return true
}

/**
 * Tell whether the ESP has an object, by its file's being there; its bytes aren't checked.
 *
 * @param service The service's state, only read: the file is looked for through esp.
 * @param hash The hash naming boot/objects/<hex>, looked for as a file; nothing's read.
 * @return Whether boot/objects/<hex> is a file.
 */
on_esp :: fn(service: ptr[mut Service], hash: bundle.Hash) -> bool {
    path_storage : u8[128]
    return os.path_kind_in(service.esp, generations.object_path(hash, &path_storage)) == .FILE
}

/**
 * Read an object from the bundle store, and check its bytes have its hash.
 *
 * The store's memory is mapped read-only, copied, and let go of.
 *
 * @param service The service's state: Get is sent on store and its answer waited for on store_port, and the memory got
 *     is mapped read-only in its block's address space, then unmapped and closed.
 * @param hash The object's hash, asked for with Get and checked against the bytes got; bytes that don't have it give
 *     null.
 * @return Its bytes, from the context's allocator, which the caller frees; null if the store hasn't it, it's empty,
 *     it couldn't be mapped or copied, or its bytes don't have its hash.
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

/**
 * Ask the ESP's file server for its room.
 *
 * @param service The service's state: Room is sent on esp_raw and its answer waited for on esp_port, until it comes or
 *     the connection fails.
 * @return Its size and what's free, in bytes; null if it couldn't be asked, or didn't answer with its room.
 */
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
            case _ => return null
        }
    }
    return match os.message_of[dir.Response](&into)^ {
        case Room(room) => room
        case _ => null
    }
}

/**
 * Tell whether a list of hashes has one.
 *
 * @param hashes The hashes looked through, read and not changed; empty has none.
 * @param hash The hash looked for, compared whole.
 * @return Whether it's among them.
 */
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
    /** The bytes, from the context's allocator, checked to have the object's hash. */
    bytes : u8[],
}

/**
 * Free a list of objects read from the store: each one's bytes, then the list.
 *
 * @param all The list, empty afterwards.
 */
free_all :: fn(all: ptr[mut Object[..]]) {
    for each in all^ {
        runtime.free_array(each.bytes)
    }
    runtime.array_free(all)
}

/**
 * Read a record's name as its generation's number.
 *
 * @param text The record's file name, a directory entry's, as read; only read.
 * @return Its number, in decimal; null if it's empty or has anything but digits. Too many digits overflow unchecked.
 */
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
