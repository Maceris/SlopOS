/**
 * The disk check (decisions/0076, 0077, 0086, 0175): given a connector to the storage manager, it dials it, finds the
 * partition named CHECKED among every disk's, opens a block connection narrowed to it, describes it, takes its buffer,
 * reads the mark tools/boot.py wrote in the partition's block 0, writes its own into block 1, flushes, reads it back,
 * and reads blocks 2 to 9 with eight requests in flight at once, each holding its number as boot.py wrote it; then a
 * read of the block past the partition's end is refused. Then, given the first EFI system partition's root as its
 * working directory, it uses std's files there (decisions/0087): it reads the files tools/boot.py put in EFI/SlopOS,
 * one with a long name, writes one of its own, makes a directory and moves its file into it, lists them, reads its file
 * back through the directory opened, and is refused a path above its working directory; and through the protocols
 * themselves, narrows EFI/SlopOS to read only, selects its files by a pattern, and is refused a file made in the set
 * the read-only directory gave. Given the system volume, it reads, writes and moves files there (system_check.hsc),
 * checks transactions (transaction_check.hsc) and time zones (zone_check.hsc), and unlocks an encrypted volume beside
 * it through the storage manager (sealed_check.hsc), keeps links from one to the other (link_check.hsc), takes, reads
 * and clones snapshots of them (snapshot_check.hsc), sets a quota on a clone (quota_check.hsc), and makes volumes of
 * its own (made_check.hsc).
 *
 * Each of those is a #test function (Hemera's docs/testing.md), run by main with test_kit.run in ORDER, as each builds
 * on what those before it did to the disk, and reported to its debug log as "disk_check: <line>". A test finds what
 * main was given, and what tests before it made, like the storage manager's connection, in Given, through
 * test_kit.given. A test whose grant wasn't given skips itself, so the summary always counts every one.
 */
package disk_check

import compiler from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import testing from "std"
import text_buffer from "std"
import dir from "std/os/slop_os"
import file_set from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import block from "../../protocols/block"
import connector from "../../protocols/connector"
import partitions from "../../protocols/partitions"
import storage from "../../protocols/storage"
import test_kit from "../../test_kit"

/** The name the check's lines in the debug log start with, as boot_tests.py looks for them. */
NAME :: "disk_check"
/** The name of the partition the check reads and writes, which tools/boot.py makes, among every disk's. */
CHECKED :: "SlopOS check"
/** A file tools/boot.py put on the EFI system partition, relative to the working directory. */
HOST_FILE :: "EFI/SlopOS/hello.txt"
/** What HOST_FILE holds, exactly. */
HOST_TEXT :: "Hello from the host's FAT32"
/** A file with a long name tools/boot.py put on the EFI system partition. */
LONG_FILE :: "EFI/SlopOS/A long name, from the host.txt"
/** What LONG_FILE holds, exactly. */
LONG_TEXT :: "A long name, from the host"
/** The file the check writes on the EFI system partition, then moves into EFI/SlopOS/made. */
GUEST_FILE :: "EFI/SlopOS/Written by the guest.txt"
/** What the check writes in GUEST_FILE. */
GUEST_TEXT :: "Written by the guest, through std's files"
/** What tools/boot.py wrote at the start of the checked partition's block 0. */
HOST_MARK :: "SlopOS disk check: from the host"
/** What the check writes at the start of the checked partition's block 1. */
GUEST_MARK :: "SlopOS disk check: from the guest"
/** Where in the block buffer block 0 is read to, and a read past the end is asked for, in bytes. */
READ_AT : u32 : 0
/** Where in the block buffer the check's mark is written from, in bytes. */
WRITE_AT : u32 : 4096
/** Where in the block buffer block 1 is read back to, in bytes. */
CHECK_AT : u32 : 8192
/** Where in the block buffer the blocks read at once go, a block apart, in bytes. */
MANY_AT : u32 : 16384
/** How many blocks are read at once, blocks 2 onward, each its own request in flight. */
MANY :: 8
/** How many partitions the storage manager is asked to describe at most, looking for one. */
MOST_PARTITIONS : u32 : 64

/**
 * The tests' names in the order main runs them, each after what it builds on: the links need the sealed volume
 * unlocked, the quota the snapshot's clone. A #test function not named here runs after these.
 */
ORDER :: string.[
    "dials_the_storage_manager",
    "the_checked_partition_reads_writes_and_refuses_past_its_end",
    "std_files_work_on_the_efi_system_partition",
    "a_read_only_directory_selects_files_and_refuses_making_one",
    "the_system_volume_reads_writes_and_moves_files",
    "typed_files_keep_their_type",
    "transactions_replace_commit_conflict_and_undo",
    "time_zones_read_from_the_system_volume",
    "the_sealed_volume_opens_only_with_its_passphrase",
    "links_reach_another_volume_and_grant_nothing_further",
    "snapshots_read_as_the_volume_was_and_clone",
    "a_quota_refuses_what_is_past_it",
    "volumes_are_made_at_run_time",
]

/** A connection to the storage manager, and the port its answers wake. */
Manager :: struct {
    /** The connection, dialed through the connector main was given. */
    end : slop_os.Channel,
    /** A port bound to end. */
    port : slop_os.Port,
}

/**
 * What main was given, and what the tests make for those after them: each test reaches it through test_kit.given, as
 * test_kit.run keeps it on the heap while they run, and those that make something store it here.
 */
Given :: struct {
    /** The debug log, NO_HANDLE when there's none. */
    log : slop_os.DebugLog,
    /** A connector to the storage manager. */
    storage : os.Channel[connector.Connector]?,
    /** The first EFI system partition's root, the process's working directory; null if there's none. */
    working_directory : os.Channel[dir.Dir]?,
    /** The system volume's root; null if there's none. */
    system : os.Channel[dir.Dir]?,
    /** The storage manager's connection, once dials_the_storage_manager has dialed it; null before, or if it failed. */
    manager : Manager?,
    /** The SlopOS container's index among the storage manager's partitions, once the sealed volume's test found it. */
    container : u32?,
    /** The encrypted volume's root, unlocked, once the sealed volume's test opened it. */
    sealed : os.Channel[dir.Dir]?,
    /** The root of the clone named CLONE, writable, once the snapshots' test made it. */
    clone : os.Channel[dir.Dir]?,
    /** The buffer file connections read and write through, valid once has_buffer is set; shared by every test. */
    buffer : Buffer,
    /** Whether buffer has been made, by buffer_of. */
    has_buffer : bool,
}

/** A block connection to the checked partition, and where its buffer is mapped. */
Disk :: struct {
    /** The debug log what's found is said in; NO_HANDLE when there's none. */
    log : slop_os.DebugLog,
    /** The block connection, narrowed to the checked partition. */
    end : slop_os.Channel,
    /** A port bound to end, waited on for its answers. */
    port : slop_os.Port,
    /** Where the connection's buffer is mapped, readable and writable, in the process's address space. */
    buffer : u64,
}

/**
 * Check the storage stack end to end: a partition through the storage manager, block by block; the EFI system
 * partition through std's files and the protocols beneath them; and the system volume, an encrypted volume beside it,
 * links, snapshots, quotas, volumes made, and time zones.
 *
 * It's a test: it writes to the partition named CHECKED's block 1, to EFI/SlopOS on the EFI system partition, and to
 * the system volume. Each test runs in ORDER, skipping itself when what it needs wasn't given, and is reported in its
 * debug log.
 *
 * @param log The debug log the tests are reported in; without one, they're reported nowhere.
 * @param storage A connector to the storage manager. Without it there's nothing to check, and it ends with 0.
 * @param working_directory The first EFI system partition's root, the process's working directory, which std's files
 *     use. Without it, its two tests skip themselves.
 * @param system The system volume's root. Without it, the tests of it and the volumes beside it skip themselves.
 * @return How many tests failed: 0 when every one passed or skipped itself, or with no storage manager.
 */
main :: fn(log: slop_os.DebugLog?, storage: os.Channel[connector.Connector]?, working_directory: os.Channel[dir.Dir]?,
    system: os.Channel[dir.Dir]?) -> int {
    to :: log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    if storage is_none {
        runtime.log_info("no storage manager")
        return 0
    }
    given :: Given.{log = to, storage = storage, working_directory = working_directory, system = system}
    every := #insert testing.tests_of(compiler.load_package("."))
    chosen := in_order(every)
    defer runtime.array_free(&chosen)
    return test_kit.run(to, NAME, chosen[0..<chosen.count], given)
}

/**
 * Put the package's tests in ORDER.
 *
 * @param tests Every #test function of the package, as tests_of gives them; only read.
 * @return The tests to run, from the context's allocator, which the caller frees: ORDER's, in its order, then any test
 *     it doesn't name, in the order tests has them.
 */
in_order :: fn(tests: testing.Test[]) -> testing.Test[..] {
    chosen : testing.Test[..]
    for name in ORDER {
        for test in tests {
            if test.name == name {
                runtime.array_add(&chosen, test)
            }
        }
    }
    for test in tests {
        named := false
        for name in ORDER {
            named = named || name == test.name
        }
        if !named {
            runtime.array_add(&chosen, test)
        }
    }
    return chosen
}

/**
 * Record a failure for a step whose answer wasn't the one it should have been, and stop the test there.
 *
 * @param t The test's state, which the failure is recorded in.
 * @param message What the step should have done, and why it should have.
 * @param location Where the step is; the caller's own.
 * @return Error(Failed), for the test to return.
 */
stopped :: fn(t: ptr[mut testing.T], message: string, location := #caller_location) -> testing.Outcome {
    testing.fail(t, message, location)
    return .Error(.Failed)
}

/**
 * Find the storage manager's connection, which dials_the_storage_manager made.
 *
 * @param t The test's state, which a failure is recorded in if there's none.
 * @param given What main was given.
 * @param location Where the test asked; the caller's own.
 * @return The connection; Error(Failed), recorded, if it wasn't dialed.
 */
manager_of :: fn(t: ptr[mut testing.T], given: ptr[Given], location := #caller_location) -> Result[Manager, testing.Stopped] {
    return testing.require_some(t, given.manager, "dials_the_storage_manager, run first, dialed the storage manager", location)
}

/**
 * Find the system volume's root, for a test of it or of the volumes beside it, or skip the test when there's none.
 *
 * @param t The test's state, marked skipped if there's none.
 * @param given What main was given.
 * @return The root, borrowed from given; Error(Skipped) if it wasn't given, for the test to return with ?.
 */
system_of :: fn(t: ptr[mut testing.T], given: ptr[Given]) -> Result[os.Channel[dir.Dir], testing.Stopped] {
    match given.system {
        case Some(system) => return .Ok(system)
        case None => {
            _ = testing.skip(t, "no system volume")
            return .Error(.Skipped)
        }
    }
}

/**
 * Find the EFI system partition's root, the working directory, for a test of it, or skip the test when there's none.
 *
 * @param t The test's state, marked skipped if there's none.
 * @param given What main was given.
 * @return The root, borrowed from given; Error(Skipped) if it wasn't given, for the test to return with ?.
 */
working_directory_of :: fn(t: ptr[mut testing.T], given: ptr[Given]) -> Result[os.Channel[dir.Dir], testing.Stopped] {
    match given.working_directory {
        case Some(directory) => return .Ok(directory)
        case None => {
            _ = testing.skip(t, "no EFI system partition")
            return .Error(.Skipped)
        }
    }
}

/**
 * Dial the storage manager through the connector main was given, for the tests after this one.
 *
 * @param t The test's state.
 * @return Ok once it's dialed, kept in Given's manager; Error if a port couldn't be made or the dial failed.
 */
dials_the_storage_manager #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    dialing :: testing.require_some(t, given.storage, "main runs the tests only with a connector to the storage manager")?
    budget :: slop_os.startup_block().budget
    dial_port :: os.port_for(budget, dialing.end)
    port_for_dial :: testing.require_some(t, dial_port, "the budget has room for a port")?
    dialed :: connector.dial[storage.Storage](dialing.end, port_for_dial)
    manager :: testing.require_some(t, dialed, "the storage manager answers its connector with a connection")?
    manager_port :: os.port_for(budget, manager.end)
    bound :: testing.require_some(t, manager_port, "the budget has room for a port")?
    given.manager = Manager.{end = manager.end, port = bound}
    return .Ok
}

/**
 * Check a partition through the storage manager, block by block: find the one named CHECKED, open a block connection
 * narrowed to it, read the host's mark, write, flush and read back its own, read eight blocks at once, and be refused
 * the block past its end.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the partition couldn't be found, opened or described, its buffer had or mapped,
 *     it's too small, or a read or write the rest builds on failed.
 */
the_checked_partition_reads_writes_and_refuses_past_its_end #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    manager :: manager_of(t, given)?
    block_of_startup :: slop_os.startup_block()
    // The partition, among every disk's
    found := cast[u32](0xffffffff)
    partition := storage.Partition.{}
    for index in 0..<MOST_PARTITIONS {
        match ask(manager.end, manager.port, .Describe(index)) {
            case Described(described) => {
                info := described.info
                if partitions.name_of(&info) == CHECKED {
                    found = index
                    partition = described
                    break
                }
            }
            case _ => break
        }
    }
    testing.require_ne(t, found, cast[u32](0xffffffff), "tools/boot.py makes a partition named CHECKED, which the storage manager describes")?
    connection := os.Channel[block.Block].{end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    match ask(manager.end, manager.port, .Open(found)) {
        case Opened(opened) => connection = opened
        case _ => return stopped(t, "the storage manager opens a block connection to a partition it described")
    }
    checked := Disk.{log = given.log, end = connection.end}
    block_port :: os.port_for(block_of_startup.budget, connection.end)
    checked.port = testing.require_some(t, block_port, "the budget has room for a port")?
    // What it is, and its buffer
    send(&checked, .Describe)
    info := block.Info.{}
    match receive(&checked) {
        case Described(described) => info = described
        case _ => return stopped(t, "a block connection describes its device when asked")
    }
    send(&checked, .GetBuffer)
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match receive(&checked) {
        case Buffer(memory) => window = memory
        case _ => return stopped(t, "a block connection gives its buffer when asked")
    }
    reserved :: runtime.reserve_addresses(cast[usize](info.buffer_bytes))
    checked.buffer = testing.require_some(t, reserved, "the process has addresses free for the block buffer")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    mapped :: slop_os.memory_map(window, block_of_startup.space, checked.buffer, 0, info.buffer_bytes, read_write)
    testing.require_ok(t, mapped, "the block buffer maps read/write at addresses reserved for it")?
    testing.require_ge(t, info.block_count, 10, "tools/boot.py makes the partition 2048 blocks, past the 10 the check uses")?

    // The host's mark, in block 0
    testing.require_eq(t, run(&checked, .Read(block.Transfer.{tag = 1, first = 0, count = 1, offset = READ_AT})), block.Status.Done,
        "block 0 of the partition reads")?
    testing.expect(t, starts_with(&checked, READ_AT, HOST_MARK), "tools/boot.py wrote its mark at the start of block 0")
    // Its own, in block 1, flushed, and read back
    put(&checked, WRITE_AT, GUEST_MARK)
    testing.require_eq(t, run(&checked, .Write(block.Transfer.{tag = 2, first = 1, count = 1, offset = WRITE_AT})), block.Status.Done,
        "block 1 of the partition is written")?
    testing.require_eq(t, run(&checked, .Flush(3)), block.Status.Done, "what was written is flushed to the disk")?
    testing.require_eq(t, run(&checked, .Read(block.Transfer.{tag = 4, first = 1, count = 1, offset = CHECK_AT})), block.Status.Done,
        "block 1 reads back")?
    testing.expect(t, starts_with(&checked, CHECK_AT, GUEST_MARK), "block 1 reads back as it was written")
    // Eight at once, answered in whatever order the device finishes them
    for i in 0..<MANY {
        send(&checked, .Read(block.Transfer.{tag = 100 + cast[u64](i), first = 2 + cast[u64](i), count = 1,
            offset = MANY_AT + cast[u32](i) * cast[u32](block.BLOCK_BYTES)}))
    }
    answered := cast[u32](0)
    for i in 0..<MANY {
        match receive(&checked) {
            case Finished(completion) => {
                if completion.status == .Done && completion.tag >= 100 && completion.tag < 100 + MANY {
                    answered |= cast[u32](1) << cast[u32](completion.tag - 100)
                }
            }
            case _ => {}
        }
    }
    testing.expect_eq(t, answered, (cast[u32](1) << MANY) - 1, "eight reads in flight at once are each answered Done, by its tag")
    // The block past the partition's end, refused before it reaches the disk
    testing.expect_eq(t, info.block_count, partition.info.count, "the connection is narrowed to the partition, so it has the partition's blocks")
    testing.expect_eq(t, run(&checked, .Read(block.Transfer.{tag = 5, first = info.block_count, count = 1, offset = READ_AT})),
        block.Status.OutOfRange, "a read past the partition's end is refused before it reaches the disk")
    wrong : u64? = null
    for i in 0..<MANY {
        storage_bytes : u8[16]
        label := text_buffer.make(storage_bytes)
        text_buffer.append_format(&label, "block %", 2 + i)
        if (wrong is_none) && !starts_with(&checked, MANY_AT + cast[u32](i) * cast[u32](block.BLOCK_BYTES), text_buffer.as_string(&label)) {
            wrong = 2 + cast[u64](i)
        }
    }
    testing.expect_none(t, wrong, "tools/boot.py wrote each block's number at its start, and each read at once landed in its own place")
    return .Ok
}

/**
 * Check the EFI system partition, the process's working directory, through std's files: read the host's files, one
 * with a long name; write a file, make a directory and move the file into it; list EFI/SlopOS; read the file back
 * through the directory opened; and be refused a path above the working directory.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if a host's file couldn't be read, or writing, making the directory, moving, listing
 *     or opening it failed.
 */
std_files_work_on_the_efi_system_partition #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    _ = working_directory_of(t, given)?
    host_read :: os.read_entire_file(HOST_FILE)
    host :: testing.require_ok(t, host_read, "tools/boot.py put HOST_FILE on the EFI system partition")?
    long_read :: os.read_entire_file(LONG_FILE)
    long :: testing.require_ok(t, long_read, "tools/boot.py put a file with a long name on the EFI system partition")?
    testing.expect_eq(t, host, HOST_TEXT, "HOST_FILE holds what tools/boot.py wrote")
    testing.expect_eq(t, long, LONG_TEXT, "the file with a long name holds what tools/boot.py wrote, found by its long name")
    written :: os.write_entire_file(GUEST_FILE, GUEST_TEXT)
    testing.require_none(t, written, "the EFI system partition takes a new file")?
    made_directory :: os.make_directory("EFI/SlopOS/made")
    testing.require_none(t, made_directory, "the EFI system partition takes a new directory")?
    renamed :: os.rename(GUEST_FILE, "EFI/SlopOS/made/Written by the guest.txt")
    testing.require_none(t, renamed, "a file moves into a directory beside it")?
    testing.expect(t, !os.exists(GUEST_FILE), "a file moved isn't where it was")
    listed :: os.list_directory("EFI/SlopOS")
    entries :: testing.require_ok(t, listed, "EFI/SlopOS lists")?
    names := 0
    // The bootloader's own files there, its seed and its last panic record (decisions/0134), aside
    count := entries.count
    for entry in entries {
        if (entry.name == "hello.txt" && !entry.is_directory) || (entry.name == "made" && entry.is_directory)
            || entry.name == "A long name, from the host.txt" {
            names += 1
        }
        if entry.name == "SEED" || entry.name == "LAST_PANIC" {
            count -= 1
        }
    }
    os.free_directory_listing(entries)
    testing.expect_eq(t, names, 3, "EFI/SlopOS lists the host's two files, and the directory made, as a directory")
    testing.expect_eq(t, count, 3, "EFI/SlopOS lists nothing else but the bootloader's own files, the file having moved")
    opened :: os.open_directory("EFI/SlopOS/made")
    made :: testing.require_ok(t, opened, "the directory made opens")?
    defer os.close_directory(made)
    back_read :: os.read_entire_file_in(made, "Written by the guest.txt")
    back :: testing.require_ok(t, back_read, "the file moved is in the directory it was moved to")?
    testing.expect_eq(t, back, GUEST_TEXT, "the file moved holds what was written, moved with it")
    above :: os.read_entire_file("../EFI/SlopOS/hello.txt")
    testing.expect_error(t, above, .InvalidPath, "a path above the working directory is refused, as nothing above it is the process's")
    return .Ok
}

/**
 * Send one request to the storage manager, and wait for its answer.
 *
 * @param end The connection to the storage manager.
 * @param port A port bound to end.
 * @param request The request, which holds no handles or arrays.
 * @return The answer, a copy; Unsupported if it couldn't be sent or the connection failed.
 */
ask :: fn(end: slop_os.Channel, port: slop_os.Port, request: storage.Request) -> storage.Response {
    out := os.Outgoing.{}
    made :: os.begin[storage.Request](&out)
    made^ = request
    if storage.send_request(end, port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match storage.receive_response(end, port, &into, true) {
            case Received => return os.message_of[storage.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/**
 * Send a request on the block connection, without waiting for its answer; a failure to send shows as no answer.
 *
 * @param disk The check's disk, whose end and port the request goes on; nothing in it changes. Its answer is the next
 *     one receive gives only when no other request is in flight.
 * @param request The request, copied into the message whole; it holds no handles or arrays to move.
 */
send :: fn(disk: ptr[Disk], request: block.Request) {
    out := os.Outgoing.{}
    made :: os.begin[block.Request](&out)
    made^ = request
    _ = block.send_request(disk.end, disk.port, &out)
}

/**
 * Wait for the next answer on the block connection.
 *
 * @param disk The check's disk, whose end and port are waited on, blocking until an answer comes or the connection
 *     fails.
 * @return The answer, a copy; Unsupported if the connection's gone.
 */
receive :: fn(disk: ptr[Disk]) -> block.Response {
    into := os.Incoming.{}
    loop {
        match block.receive_response(disk.end, disk.port, &into, true) {
            case Received => return os.message_of[block.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/**
 * Send one request on the block connection, and wait for how it finished.
 *
 * @param disk The block connection, with no other request in flight, so the next answer is this one's.
 * @param request The request sent, copied whole: a Read or Write uses the connection's buffer, which disk.buffer maps.
 * @return Its completion's status; DeviceError if the answer wasn't a completion, as when the connection's gone.
 */
run :: fn(disk: ptr[Disk], request: block.Request) -> block.Status {
    send(disk, request)
    return match receive(disk) {
        case Finished(completion) => completion.status
        case _ => .DeviceError
    }
}

/**
 * Put text at the start of a block in the buffer, the rest of the block zeros.
 *
 * @param disk The block connection, with its buffer mapped.
 * @param offset Where in the buffer the block starts, in bytes; it and a block after it must be in the buffer.
 * @param text The text, at most block.BLOCK_BYTES bytes; what's past them is dropped.
 */
put :: fn(disk: ptr[Disk], offset: u32, text: string) {
    bytes :: view_of(cast[ptr[mut u8]](disk.buffer + cast[u64](offset)), cast[usize](block.BLOCK_BYTES))
    for &byte, i in bytes {
        byte^ = if i < text.count { cast[u8](text[i]) } else { cast[u8](0) }
    }
}

/**
 * Tell whether the buffer holds text at an offset.
 *
 * @param disk The block connection, with its buffer mapped.
 * @param offset Where in the buffer to look, in bytes; it and text's bytes after it must be in the buffer.
 * @param text The bytes looked for, compared exactly; empty is always there.
 * @return Whether the bytes there are text's.
 */
starts_with :: fn(disk: ptr[Disk], offset: u32, text: string) -> bool {
    bytes :: view_of(cast[ptr[u8]](disk.buffer + cast[u64](offset)), text.count)
    for character, i in text {
        if i >= bytes.count || bytes[i] != cast[u8](character) {
            return false
        }
    }
    return true
}

/**
 * Check the EFI system partition beneath std's files, through the protocols: open EFI/SlopOS, narrow it to read only,
 * select a set of its files by a pattern, which FAT matches ignoring case, and be refused a file made through that
 * set.
 *
 * The connections it makes aren't closed; the process ends soon after.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if EFI/SlopOS couldn't be opened or narrowed, the set selected or listed, or a port
 *     made.
 */
a_read_only_directory_selects_files_and_refuses_making_one #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    working_directory :: working_directory_of(t, given)?
    budget :: slop_os.startup_block().budget
    into := os.Incoming.{}
    root_port :: os.port_for(budget, working_directory.end)
    port :: testing.require_some(t, root_port, "the budget has room for a port")?
    out := os.Outgoing.{}
    opening :: os.begin[dir.Request](&out)
    opening^ = .OpenDirectory(dir.OpenDirectory.{path = bytes_of(&out, "EFI/SlopOS")})
    directory := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_dir(working_directory.end, port, &out, &into) {
        case OpenedDirectory(made) => directory = made.end
        case _ => return stopped(t, "EFI/SlopOS, which tools/boot.py made, opens through the dir protocol")
    }
    opened_port :: os.port_for(budget, directory)
    directory_port :: testing.require_some(t, opened_port, "the budget has room for a port")?
    out = os.Outgoing.{}
    narrowing :: os.begin[dir.Request](&out)
    narrowing^ = .Narrow
    read_only := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_dir(directory, directory_port, &out, &into) {
        case Narrowed(made) => read_only = made.end
        case _ => return stopped(t, "a directory narrows to a read-only one when asked")
    }
    narrowed_port :: os.port_for(budget, read_only)
    read_only_port :: testing.require_some(t, narrowed_port, "the budget has room for a port")?
    out = os.Outgoing.{}
    selecting :: os.begin[read_only_dir.Request](&out)
    selecting^ = .Select(bytes_of(&out, "*.TXT"))
    set := cast[slop_os.Channel](slop_os.NO_HANDLE)
    match ask_read_only_dir(read_only, read_only_port, &out, &into) {
        case Selected(made) => set = made.end
        case _ => return stopped(t, "a read-only directory selects a set of its files by a pattern")
    }
    selected_port :: os.port_for(budget, set)
    set_port :: testing.require_some(t, selected_port, "the budget has room for a port")?
    matched := 0
    cursor : u64 = 0
    ended := false
    loop {
        out = os.Outgoing.{}
        listing :: os.begin[file_set.Request](&out)
        listing^ = .List(cursor)
        match ask_file_set(set, set_port, &out, &into) {
            case Listed(entry) => {
                matched += 1
                cursor = entry.next
            }
            case End => ended = true
            case _ => return stopped(t, "a file set lists its files, to its end")
        }
    }
    while !ended && matched < 8
    testing.expect_eq(t, matched, 2, "*.TXT matches the host's two files, ignoring case as FAT does, and not the directory the check made")
    out = os.Outgoing.{}
    creating :: os.begin[file_set.Request](&out)
    creating^ = .OpenFile(file_set.OpenFile.{name = bytes_of(&out, "Made through the set.txt"), creation = .New})
    match ask_file_set(set, set_port, &out, &into) {
        case Failed(error) => testing.expect_eq(t, error, .ReadOnly, "a set from a read-only directory makes no file, as it can't write")
        case _ => testing.fail(t, "a set from a read-only directory makes no file, as it can't write")
    }
    return .Ok
}

/**
 * Append text's bytes to a message being built.
 *
 * @param out The message being built; the bytes are appended after what it holds, and the result is relative to its
 *     start.
 * @param text The text, as a path or a pattern.
 * @return Where the bytes are in the message, for a request's field.
 */
bytes_of :: fn(out: ptr[mut os.Outgoing], text: string) -> slop_os.Relative[u8] {
    return os.append(out, string_bytes(text))
}

/**
 * Send one request on a dir connection, and wait for its answer.
 *
 * @param end The dir connection, kept by the caller and not closed.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
ask_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> dir.Response {
    if dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/**
 * Send one request on a read_only_dir connection, and wait for its answer.
 *
 * @param end The read_only_dir connection, kept by the caller and not closed.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
ask_read_only_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> read_only_dir.Response {
    if read_only_dir.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match read_only_dir.receive_response(end, port, into, true) {
            case Received => return os.message_of[read_only_dir.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

/**
 * Send one request on a file_set connection, and wait for its answer.
 *
 * @param end The file_set connection, kept by the caller and not closed.
 * @param port A port bound to end.
 * @param out The request; its handles are moved out when it's sent.
 * @param into Where the answer is read into.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
ask_file_set :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> file_set.Response {
    if file_set.send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match file_set.receive_response(end, port, into, true) {
            case Received => return os.message_of[file_set.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}
