/**
 * An interpreter of ACPI's AML (decisions/0182, P2): it loads the DSDT's and SSDTs' definition blocks into a namespace,
 * and evaluates its objects and runs its methods, for the ACPI service. It holds no authority: what AML reaches of the
 * machine, its operation regions, sleeping and notifications, goes through the Host its user gives, so it runs hosted
 * as well as in the service.
 *
 * The bytecode isn't trusted, so everything is bounded: each evaluation has a budget of steps (terms run) and of
 * memory for what it makes along the way, calls and nested terms have depths they can't pass, and the namespace's own
 * memory has a budget too. A method that passes any of them fails with the reason, and the namespace is as it was
 * before what failed, but for what it had already stored. Nothing the bytecode does can fault the interpreter: every
 * read of it is checked against its end, and every index against what it indexes.
 *
 * What it runs: names, scopes, aliases and every named object; methods, their locals and arguments, and the control
 * flow in them; integers, strings, buffers and packages, references to them and their elements, and the conversions
 * between them; fields in operation regions, index and bank fields, and buffer fields; mutexes and events, which one
 * thread's evaluations can only hold or signal; Notify, Sleep, Stall, the timer and the debug object. What it doesn't:
 * loading tables from AML (Load, LoadTable, Unload), which fail as Unsupported, and the global lock, which it takes as
 * always free, as there's no other agent here to share it with until an embedded controller needs one.
 */
//SPEC: ACPI 6.5, §5.4 (definition blocks), §19 (ASL), §20 (AML grammar)
package aml

import runtime from "base"
import memory from "std"

/** Why loading or evaluating failed. */
Error :: enum {
    /** The bytecode ends inside a term, or a package's length runs past what holds it. */
    Truncated,
    /** An opcode that isn't AML's, or one where it can't be. */
    BadOpcode,
    /** A name that isn't in the namespace, where one has to be. */
    NotFound,
    /** A name defined where something of that name already is. */
    AlreadyExists,
    /** An operand of a type the operation can't take, nor be converted to. */
    WrongType,
    /** An index past a package's, buffer's or string's end, or a field past its region's. */
    OutOfRange,
    /** A divisor of 0. */
    DivideByZero,
    /** The evaluation's budget of steps ran out: a loop or a recursion that doesn't end. */
    Steps,
    /** Calls or nested terms went deeper than the limits allow. */
    Depth,
    /** The evaluation's or the namespace's budget of memory ran out. */
    Memory,
    /** The host couldn't read or write an operation region, as for an address space it doesn't serve. */
    RegionFailed,
    /** Something AML can ask that this interpreter doesn't do: loading a table from AML, or unloading one. */
    Unsupported,
    /** The AML ran Fatal, which says the firmware found a fatal error. */
    Fatal,
    /** A table whose header is too short, whose length is past its bytes, or that isn't a DSDT or an SSDT. */
    BadTable,
}

/** What an evaluation and the namespace may use: every one bounds what the bytecode can make it do. */
Limits :: struct {
    /** The most terms one evaluation runs, its methods' and their calls' together; past it, Steps. */
    steps : u64 = 2_000_000,
    /** The most methods called inside one another, the first included; past it, Depth. */
    calls : u32 = 32,
    /** The most terms nested inside one another, across calls, which bounds the interpreter's own stack; past it, Depth. */
    nesting : u32 = 256,
    /** The most bytes one evaluation makes along the way, in its arena; past it, Memory. */
    evaluation_bytes : usize = 1024 * 1024,
    /** The most bytes the namespace holds: its nodes, the tables' bytecode and what's stored in it; past it, Memory. */
    namespace_bytes : usize = 4 * 1024 * 1024,
    /** The most milliseconds Sleep sleeps at once, and Stall stalls (in microseconds, 100 as ACPI allows). */
    sleep_milliseconds : u64 = 2000,
}

/**
 * An operation region's address space (ACPI 6.5 §19.6.100), as the host is asked to read and write it. The numbers
 * are AML's; any other is passed on as it is, and a host that doesn't serve it fails the access.
 */
RegionSpace :: enum #backed_by(u8) {
    /** Memory, by its physical address. */
    SystemMemory = 0,
    /** I/O ports, by their numbers. */
    SystemIo = 1,
    /** A PCI function's configuration space: the address as pci_address makes it. */
    PciConfig = 2,
    /** The embedded controller's registers, 0 to 255. */
    EmbeddedControl = 3,
    /** The SMBus. */
    SmBus = 4,
    /** CMOS RAM. */
    Cmos = 5,
    /** A PCI BAR's space. */
    PciBarTarget = 6,
    /** IPMI. */
    Ipmi = 7,
    /** General-purpose I/O. */
    GeneralPurposeIo = 8,
    /** A generic serial bus. */
    GenericSerialBus = 9,
    /** The platform communications channel. */
    Pcc = 10,
}

/**
 * What AML reaches outside itself, given by the interpreter's user. Each function is passed state as it is; an
 * address the user casts back to its own state, so the interpreter holds no pointer of a type it doesn't know.
 */
Host :: struct {
    /** The host's own state, as an address, passed to each function; the interpreter only passes it back. */
    state : u64,
    /**
     * Read an operation region: width bits at address in space. Returns the value, its upper bits 0, or null if the
     * host can't, which fails the access with RegionFailed.
     */
    read : fn(state: u64, space: u8, address: u64, width: u32) -> u64?,
    /** Write an operation region: value's low width bits at address in space. Returns false if it couldn't. */
    write : fn(state: u64, space: u8, address: u64, width: u32, value: u64) -> bool,
    /** Sleep for milliseconds, at most Limits.sleep_milliseconds; letting other work run. */
    sleep : fn(state: u64, milliseconds: u64),
    /** Wait for microseconds without giving up the CPU, at most 100. */
    stall : fn(state: u64, microseconds: u64),
    /** The timer: a monotonic count of 100-nanosecond units, from any start. */
    timer : fn(state: u64) -> u64,
    /** Notify(node, value): the object notified, for the host to act on (0x80 on a power button: it was pressed). */
    notify : fn(state: u64, node: ptr[Node], value: u64),
    /** What AML stores to the debug object, as text, for the host's log. */
    debug : fn(state: u64, text: string),
}

/** The interpreter: its namespace, its limits, the host, and what an evaluation in progress uses. */
Interpreter :: struct {
    /** The namespace's root, `\`, which every table loads beneath. */
    root : ptr[mut Node],
    /** What it reaches outside itself. */
    host : Host,
    /** Its limits. */
    limits : Limits,
    /** Whether integers are 64 bits, as a DSDT of revision 2 or more says; 32 bits, masked, before one says so. */
    wide : bool,
    /** The bytes the namespace holds now, its nodes, tables and stored values, at most limits.namespace_bytes. */
    namespace_bytes : usize,
    /** Where an evaluation's temporary values come from, emptied when the outermost evaluation ends. */
    arena : ptr[mut memory.Arena],
    /** The bytes the arena has given in this evaluation, at most limits.evaluation_bytes. */
    evaluation_bytes : usize,
    /** Steps run in this evaluation. */
    steps : u64,
    /** Methods called now, inside one another. */
    calls : u32,
    /** Terms nested now, inside one another. */
    nesting : u32,
    /** Whether an evaluation is in progress, so one started from inside another (none is) doesn't reset the arena. */
    evaluating : bool,
    /** The strings `_OSI` answers true for, beside the Windows versions it always does. */
    interfaces : string[],
    /** Whether the last evaluation or load noted where it failed, in failed_at and failed_bytes. */
    failure_noted : bool,
    /** Where the innermost term that failed starts, in the bytecode it's in: a table's AML, or a method's body. */
    failed_at : usize,
    /** The bytes the innermost term that failed starts with, for the host's log; zeros past the bytecode's end. */
    failed_bytes : u8[16],
    /** The last segment of the last name that wasn't found, for the host's log; 0 before one. */
    missing : u32,
}

/**
 * Make an interpreter with an empty namespace but its predefined objects: the scopes `\_GPE`, `\_PR`, `\_SB`, `\_SI`
 * and `\_TZ`, `\_GL` (the global lock, a mutex), `\_OS` ("Microsoft Windows NT"), `\_REV` (2) and `\_OSI`, which
 * answers true for the Windows versions firmware asks after, as Linux does, and the interfaces given.
 *
 * @param host What AML reaches outside itself; kept.
 * @param limits What it may use.
 * @param interfaces More strings `_OSI` answers true for; kept, so they have to live as long as it.
 * @return The interpreter, on the heap from context's allocator; null without the memory for it.
 */
make :: fn(host: Host, limits: Limits, interfaces #escaping : string[]) -> ptr[mut Interpreter]? {
    made, error :: runtime.new_aligned(Interpreter, align_of(Interpreter))
    if error != null {
        return null
    }
    arena :: memory.make_arena() or_return null
    root_made, root_error :: runtime.new_aligned(Node, align_of(Node))
    if root_error != null {
        return null
    }
    root_made^ = Node.{name = ROOT_NAME, kind = .Scope}
    made^ = Interpreter.{root = root_made, host = host, limits = limits, arena = arena, interfaces = interfaces}
    made.namespace_bytes = size_of(Node)
    if predefine(made) is_some {
        return null
    }
    return made
}

/**
 * Add the predefined objects to a new interpreter's namespace.
 *
 * @param interpreter The interpreter, its root alone.
 * @return Null once they're added; Memory if the namespace's budget can't hold them.
 */
predefine :: fn(interpreter: ptr[mut Interpreter]) -> Error? {
    for scope in string.["_GPE", "_PR_", "_SB_", "_SI_", "_TZ_"] {
        _ = add_node(interpreter, interpreter.root, segment_of(scope), .Scope, false) or_return .Memory
    }
    lock :: add_node(interpreter, interpreter.root, segment_of("_GL_"), .Mutex, false) or_return .Memory
    lock.sync_level = 0
    os :: add_node(interpreter, interpreter.root, segment_of("_OS_"), .Name, false) or_return .Memory
    os.value = persistent_string(interpreter, "Microsoft Windows NT") or_return .Memory
    revision :: add_node(interpreter, interpreter.root, segment_of("_REV"), .Name, false) or_return .Memory
    revision.value = .Integer(2)
    osi :: add_node(interpreter, interpreter.root, segment_of("_OSI"), .Builtin, false) or_return .Memory
    osi.argument_count = 1
    return null
}

/** The Windows versions `_OSI` answers true for, as Linux's does, so firmware takes its tested paths. */
WINDOWS_INTERFACES :: string.["Windows 2000", "Windows 2001", "Windows 2001 SP1", "Windows 2001.1", "Windows 2001 SP2",
    "Windows 2001.1 SP1", "Windows 2006", "Windows 2006.1", "Windows 2006 SP1", "Windows 2006 SP2", "Windows 2009",
    "Windows 2012", "Windows 2013", "Windows 2015", "Windows 2016", "Windows 2017", "Windows 2017.2", "Windows 2018",
    "Windows 2018.2", "Windows 2019", "Windows 2020", "Windows 2021", "Windows 2022", "Module Device",
    "Processor Device", "3.0 Thermal Model", "3.0 _SCP Extensions", "Processor Aggregator Device"]

/** A definition block's header's bytes, before its AML (ACPI 6.5 §5.2.6). */
TABLE_HEADER : usize : 36

/**
 * Load a definition block, a DSDT or an SSDT, into the namespace: its AML is run at the root, defining what it
 * defines, as its own evaluation. A DSDT of revision 2 or more makes integers 64 bits for every table after it.
 *
 * @param interpreter The interpreter, not evaluating.
 * @param table The table, header and all; copied, so it needn't outlive the call.
 * @return Null once it's loaded. BadTable for a table that's too short, whose length is past its bytes, or that's
 *     neither a DSDT nor an SSDT; Memory if the namespace can't hold it; or why its AML failed, which leaves what it
 *     had defined before that.
 */
load_table :: fn(interpreter: ptr[mut Interpreter], table: u8[]) -> Error? {
    if table.count < TABLE_HEADER {
        return .BadTable
    }
    length :: cast[usize](table[4]) | (cast[usize](table[5]) << 8) | (cast[usize](table[6]) << 16) | (cast[usize](table[7]) << 24)
    if length < TABLE_HEADER || length > table.count {
        return .BadTable
    }
    dsdt :: table[0] == cast[u8]('D') && table[1] == cast[u8]('S') && table[2] == cast[u8]('D') && table[3] == cast[u8]('T')
    ssdt :: table[0] == cast[u8]('S') && table[1] == cast[u8]('S') && table[2] == cast[u8]('D') && table[3] == cast[u8]('T')
    if !dsdt && !ssdt {
        return .BadTable
    }
    if dsdt && table[8] >= 2 {
        interpreter.wide = true
    }
    // The AML is kept, since its methods' bodies are run from it later
    kept, failed :: persistent_bytes(interpreter, length - TABLE_HEADER)
    if failed is_some {
        return .Memory
    }
    for i in 0..<kept.count {
        at :: TABLE_HEADER + i
        if at < length && at < table.count {
            kept[i] = table[at]
        }
    }
    begin(interpreter)
    defer end(interpreter)
    frame := Frame.{scope = interpreter.root}
    match run_terms(interpreter, &frame, kept, 0, kept.count) {
        case Ok(_) => return null
        case Error(error) => return error
    }
}

/**
 * Evaluate an object by its path: a method is run with the arguments given, and anything else's value given as it
 * is, a field read.
 *
 * @param interpreter The interpreter, not evaluating.
 * @param path The path, as ASL writes it: `\_SB.PCI0._CRS`, absolute, or relative to the root without `\`.
 * @param arguments The arguments, for a method; as many as it takes are used, and Uninitialized for any it takes that
 *     aren't given. They may be values another evaluation gave only if they're integers.
 * @return The value, good until the next evaluation or load: copy what's kept out of it first. A method that returns
 *     nothing gives Uninitialized.
 * @error NotFound No object at the path.
 */
evaluate :: fn(interpreter: ptr[mut Interpreter], path: string, arguments: Value[]) -> Result[Value, Error] #unrestricted {
    node :: find(interpreter, path) or_return .Error(.NotFound)
    return evaluate_node(interpreter, node, arguments)
}

/**
 * Evaluate a node: a method run with the arguments given, anything else's value given as it is, a field read.
 *
 * @param interpreter The interpreter, not evaluating.
 * @param node The node, from find or walk.
 * @param arguments As evaluate's.
 * @return As evaluate's.
 */
evaluate_node :: fn(interpreter: ptr[mut Interpreter], node #escaping : ptr[mut Node], arguments: Value[]) -> Result[Value, Error] #unrestricted {
    begin(interpreter)
    defer end(interpreter)
    if node.kind == .Method || node.kind == .Builtin {
        frame := Frame.{scope = node}
        return call(interpreter, &frame, node, arguments)
    }
    frame := Frame.{scope = interpreter.root}
    return value_of_node(interpreter, &frame, node)
}

/**
 * Start an evaluation: its budgets counted from nothing, and its arena emptied of the last one's values.
 *
 * @param interpreter The interpreter.
 */
begin :: fn(interpreter: ptr[mut Interpreter]) {
    memory.reset_arena(interpreter.arena)
    interpreter.evaluation_bytes = 0
    interpreter.steps = 0
    interpreter.calls = 0
    interpreter.nesting = 0
    interpreter.evaluating = true
    interpreter.failure_noted = false
}

/**
 * End an evaluation; its values stay good until the next begins.
 *
 * @param interpreter The interpreter.
 */
end :: fn(interpreter: ptr[mut Interpreter]) {
    interpreter.evaluating = false
}

/**
 * Find a node by its path.
 *
 * @param interpreter The interpreter.
 * @param path As evaluate's: segments of up to four characters, a shorter one padded with `_`, separated by `.`,
 *     after an optional `\`; `^` goes up from the root, which is no further.
 * @return The node, which lives as long as the interpreter; null if there's none, or the path isn't one.
 */
find :: fn(interpreter: ptr[mut Interpreter], path: string) -> ptr[mut Node]? {
    bytes :: string_bytes(path)
    node := interpreter.root
    at : usize = 0
    if at < bytes.count && bytes[at] == cast[u8]('\\') {
        at += 1
    }
    loop {
        if at >= bytes.count {
            break
        }
        segment : u32 = 0
        length : u32 = 0
        loop {
            if at >= bytes.count || bytes[at] == cast[u8]('.') {
                break
            }
            if length >= 4 {
                return null
            }
            segment |= cast[u32](bytes[at]) << (8 * length)
            length += 1
            at += 1
        }
        if length == 0 {
            return null
        }
        for padded in length..<4 {
            segment |= cast[u32]('_') << (8 * padded)
        }
        node = child_of(node, segment) or_return null
        if at < bytes.count {
            at += 1
        }
    }
    return node
}
