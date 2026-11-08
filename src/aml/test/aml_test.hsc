/**
 * The AML interpreter on the host (decisions/0182, P2): tables built by the tests' assembler loaded and their
 * methods run against a host whose operation regions are a few bytes of memory, every kind of term and every bound;
 * and bytes drawn at random loaded, which fail or load but never fault.
 */
package aml_test

import runtime from "base"
import testing from "std"
import text_buffer from "std"
import aml from ".."

// ---- The host

/** The tests' host: a space of bytes that every region reads and writes, and what AML told it. */
TestHost :: struct {
    /** The bytes SystemIO and SystemMemory regions reach, at their addresses' low 8 bits. */
    space : u8[256],
    /** How many accesses went through it. */
    accesses : u32,
    /** The last value notified, and how many notifications there were. */
    notified : u64,
    /** How many notifications there were. */
    notifications : u32,
    /** The last text stored to the debug object. */
    debug : u8[..],
    /** The milliseconds slept, all told. */
    slept : u64,
    /** The address of the last PCI_Config access, which reads PCI_VALUE. */
    pci : u64,
}

/** What every PCI_Config read gives. */
PCI_VALUE : u64 : 0x12345678

/**
 * Read the host's space.
 *
 * @param state The TestHost's address.
 * @param space The region's space: SystemMemory (0) and SystemIO (1) are the space; PCI_Config (2) reads PCI_VALUE
 *     and keeps the address.
 * @param address The address, of which the low 8 bits are used.
 * @param width The bits, 8 to 64.
 * @return The value; null for another space.
 */
host_read :: fn(state: u64, space: u8, address: u64, width: u32) -> u64? {
    host :: cast[ptr[mut TestHost]](state)
    if space == 2 {
        host.pci = address
        return PCI_VALUE
    }
    if space > 1 {
        return null
    }
    host.accesses += 1
    value : u64 = 0
    for i in 0..<(width / 8) {
        at :: cast[usize]((address + cast[u64](i)) & 0xff)
        if at < host.space.count {
            value |= cast[u64](host.space[at]) << (8 * cast[u64](i))
        }
    }
    return value
}

/**
 * Write the host's space.
 *
 * @param state The TestHost's address.
 * @param space As host_read's; a PCI_Config write keeps its address and is dropped.
 * @param address As host_read's.
 * @param width As host_read's.
 * @param value What's written.
 * @return False for a space other than those three.
 */
host_write :: fn(state: u64, space: u8, address: u64, width: u32, value: u64) -> bool {
    host :: cast[ptr[mut TestHost]](state)
    if space == 2 {
        host.pci = address
        return true
    }
    if space > 1 {
        return false
    }
    host.accesses += 1
    for i in 0..<(width / 8) {
        at :: cast[usize]((address + cast[u64](i)) & 0xff)
        if at < host.space.count {
            host.space[at] = cast[u8]((value >> (8 * cast[u64](i))) & 0xff)
        }
    }
    return true
}

/** Count the milliseconds slept. */
host_sleep :: fn(state: u64, milliseconds: u64) {
    host :: cast[ptr[mut TestHost]](state)
    host.slept += milliseconds
}

/** Stall: nothing to wait for here. */
host_stall :: fn(state: u64, microseconds: u64) {}

/** The timer: a count that goes up by one each time it's read. */
host_timer :: fn(state: u64) -> u64 {
    host :: cast[ptr[mut TestHost]](state)
    host.accesses += 1
    return cast[u64](host.accesses)
}

/** Keep what was notified. */
host_notify :: fn(state: u64, node: ptr[aml.Node], value: u64) {
    host :: cast[ptr[mut TestHost]](state)
    host.notified = value
    host.notifications += 1
}

/** Keep what was stored to the debug object. */
host_debug :: fn(state: u64, text: string) {
    host :: cast[ptr[mut TestHost]](state)
    runtime.array_free(&host.debug)
    for byte in string_bytes(text) {
        runtime.array_add(&host.debug, byte)
    }
}

/** An interpreter with a table loaded, and its host. */
Loaded :: struct {
    /** The interpreter. */
    interpreter : ptr[mut aml.Interpreter],
    /** Its host. */
    host : ptr[mut TestHost],
}

/**
 * Make an interpreter over a new TestHost, with a table loaded.
 *
 * @param t The test.
 * @param body The table's AML.
 * @param limits The limits.
 * @param revision The DSDT's revision.
 * @return The interpreter and its host, both on the heap, never freed; or the test failed if the table didn't load.
 */
loaded :: fn(t: ptr[mut testing.T], body: ptr[Assembler], limits: aml.Limits = aml.Limits.{}, revision: u8 = 2)
    -> Result[Loaded, testing.Stopped] {
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, limits), "the interpreter's made")?
    problem :: aml.load_table(interpreter, table(body, "DSDT", revision))
    testing.require(t, problem is_none, "the table loads")?
    return .Ok(Loaded.{interpreter = interpreter, host = host})
}

/** The interface `_OSI` claims beside Windows', in the tests. */
INTERFACES :: string.["SlopOS Test"]

/**
 * Make an interpreter over a host.
 *
 * @param host The host.
 * @param limits The limits.
 * @return The interpreter; null without the memory.
 */
made :: fn(host: ptr[mut TestHost], limits: aml.Limits) -> ptr[mut aml.Interpreter]? {
    callbacks :: aml.Host.{state = cast[u64](host), read = host_read, write = host_write, sleep = host_sleep, stall = host_stall,
        timer = host_timer, notify = host_notify, debug = host_debug}
    return aml.make(callbacks, limits, INTERFACES[0..<INTERFACES.count])
}

/**
 * The integer an evaluation gave.
 *
 * @param result What evaluate gave.
 * @return The integer; null if it failed, or gave something else.
 */
integer_from :: fn(result: Result[aml.Value, aml.Error]) -> u64? {
    match result {
        case Ok(value) => match value {
            case Integer(number) => return number
            case _ => return null
        }
        case Error(_) => return null
    }
    return null
}

/**
 * The error an evaluation failed with.
 *
 * @param result What evaluate gave.
 * @return The error; null if it didn't fail.
 */
error_from :: fn(result: Result[aml.Value, aml.Error]) -> aml.Error? {
    match result {
        case Ok(_) => return null
        case Error(error) => return error
    }
}

/** No arguments. */
NONE : aml.Value[0] : aml.Value.[]

// ---- Names, integers and methods

/** A Name's integer is its value, and a method returns what it computes from its arguments. */
names_and_methods #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Name (INT1, 0x1234)
    op(&a, 0x08)
    name(&a, "INT1")
    integer(&a, 0x1234)
    // Method (ADDM, 2) { Return (Add (Arg0, Arg1)) }
    method :: open(&a, u8.[0x14])
    name(&a, "ADDM")
    op(&a, 2)
    op(&a, 0xa4)
    raw(&a, u8.[0x72, 0x68, 0x69, 0x00])
    close(&a, method)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(aml.evaluate(interpreter, "\\INT1", NONE[0..<0])) or_else 0, 0x1234, "INT1 is 0x1234")
    arguments :: aml.Value.[.Integer(40), .Integer(2)]
    testing.expect_eq(t, integer_from(aml.evaluate(interpreter, "ADDM", arguments[0..<2])) or_else 0, 42, "ADDM(40, 2) is 42")
    return .Ok
}

// ---- Helpers for writing tables

/**
 * Start a Method; close ends it.
 *
 * @param a The assembler.
 * @param method Its name.
 * @param arguments How many arguments it takes, 0 to 7.
 * @return The mark for close.
 */
method :: fn(a: ptr[mut Assembler], method: string, arguments: u8) -> usize {
    mark :: open(a, u8.[0x14])
    name(a, method)
    op(a, arguments)
    return mark
}

/**
 * Write Name (n, value) for an integer.
 *
 * @param a The assembler.
 * @param n The name.
 * @param value The integer.
 */
name_integer :: fn(a: ptr[mut Assembler], n: string, value: u64) {
    op(a, 0x08)
    name(a, n)
    integer(a, value)
}

/**
 * The text an evaluation gave, a string.
 *
 * @param result What evaluate gave.
 * @return The text; "" if it failed, or gave something else.
 */
text_from :: fn(result: Result[aml.Value, aml.Error]) -> string {
    match result {
        case Ok(value) => match value {
            case String(text) => return aml.text_of(text.data)
            case _ => return ""
        }
        case Error(_) => return ""
    }
    return ""
}

/**
 * Evaluate a path with no arguments.
 *
 * @param interpreter The interpreter.
 * @param path The path.
 * @return What evaluate gave.
 */
run :: fn(interpreter: ptr[mut aml.Interpreter], path: string) -> Result[aml.Value, aml.Error] {
    return aml.evaluate(interpreter, path, NONE[0..<0])
}

/**
 * Evaluate a path with one integer argument.
 *
 * @param interpreter The interpreter.
 * @param path The path.
 * @param argument The argument.
 * @return What evaluate gave.
 */
run_with :: fn(interpreter: ptr[mut aml.Interpreter], path: string, argument: u64) -> Result[aml.Value, aml.Error] {
    arguments :: aml.Value.[.Integer(argument)]
    return aml.evaluate(interpreter, path, arguments[0..<1])
}

// ---- Control flow

/** While, a local and Increment sum the numbers to an argument, and If and Else choose. */
loops_and_conditions #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    /*
     * Method (SUMN, 1) { Store (0, Local0) Store (0, Local1) While (LLess (Local1, Arg0)) { Increment (Local1)
     * Add (Local0, Local1, Local0) } Return (Local0) }
     */
    sum :: method(&a, "SUMN", 1)
    raw(&a, u8.[0x70, 0x00, 0x60, 0x70, 0x00, 0x61])
    loop_mark :: open(&a, u8.[0xa2])
    raw(&a, u8.[0x95, 0x61, 0x68, 0x75, 0x61, 0x72, 0x60, 0x61, 0x60])
    close(&a, loop_mark)
    raw(&a, u8.[0xa4, 0x60])
    close(&a, sum)
    // Method (SIGN, 1) { If (LLess (Arg0, 5)) { Return (1) } Else { Return (2) } }
    sign :: method(&a, "SIGN", 1)
    taken :: open(&a, u8.[0xa0])
    raw(&a, u8.[0x95, 0x68, 0x0a, 0x05, 0xa4, 0x01])
    close(&a, taken)
    otherwise :: open(&a, u8.[0xa1])
    raw(&a, u8.[0xa4, 0x0a, 0x02])
    close(&a, otherwise)
    close(&a, sign)
    /*
     * Method (BRK_, 0) { Store (0, Local0) While (One) { Increment (Local0) If (LEqual (Local0, 7)) { Break } }
     * Return (Local0) }
     */
    broken :: method(&a, "BRK", 0)
    raw(&a, u8.[0x70, 0x00, 0x60])
    forever :: open(&a, u8.[0xa2])
    raw(&a, u8.[0x01, 0x75, 0x60])
    inner :: open(&a, u8.[0xa0])
    raw(&a, u8.[0x93, 0x60, 0x0a, 0x07, 0xa5])
    close(&a, inner)
    close(&a, forever)
    raw(&a, u8.[0xa4, 0x60])
    close(&a, broken)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run_with(interpreter, "SUMN", 10)) or_else 0, 55, "1 to 10 sum to 55")
    testing.expect_eq(t, integer_from(run_with(interpreter, "SIGN", 3)) or_else 0, 1, "3 takes the If")
    testing.expect_eq(t, integer_from(run_with(interpreter, "SIGN", 9)) or_else 0, 2, "9 takes the Else")
    testing.expect_eq(t, integer_from(run(interpreter, "BRK")) or_else 0, 7, "Break ends the While at 7")
    return .Ok
}

/** A name of one segment is found in the scopes its scope is in, and a path finds what's in a device. */
scopes_and_searching #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    name_integer(&a, "INT1", 0x55)
    // Scope (\_SB) { Device (PCI0) { Method (_STA) { Return (0x0F) } Method (UP__) { Return (INT1) } } }
    scope :: open(&a, u8.[0x10])
    name(&a, "\\_SB")
    device :: open(&a, u8.[0x5b, 0x82])
    name(&a, "PCI0")
    status :: method(&a, "_STA", 0)
    raw(&a, u8.[0xa4, 0x0a, 0x0f])
    close(&a, status)
    up :: method(&a, "UP", 0)
    op(&a, 0xa4)
    name(&a, "INT1")
    close(&a, up)
    close(&a, device)
    close(&a, scope)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run(interpreter, "\\_SB.PCI0._STA")) or_else 0, 0x0f, "_STA is found by its path")
    testing.expect_eq(t, integer_from(run(interpreter, "\\_SB.PCI0.UP")) or_else 0, 0x55, "INT1 is found from the root")
    testing.expect(t, aml.find(interpreter, "\\_SB.PCI1") is_none, "a device that isn't there isn't found")
    node :: testing.require_some(t, aml.find(interpreter, "\\_SB.PCI0"), "the device is found")?
    testing.expect(t, node.kind == .Device, "PCI0 is a device")
    return .Ok
}

/** Objects a method makes go when it returns, so it makes them again each call; CondRefOf finds what's there. */
temporary_objects_and_conditional_references #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    name_integer(&a, "INT1", 9)
    // Method (TMPN) { Name (TMP_, 5) Return (TMP_) }
    temporary :: method(&a, "TMPN", 0)
    name_integer(&a, "TMP", 5)
    op(&a, 0xa4)
    name(&a, "TMP")
    close(&a, temporary)
    /*
     * Method (CREF) { If (CondRefOf (\NOPE, Local0)) { Return (1) } If (CondRefOf (\INT1, Local0)) {
     * Return (DerefOf (Local0)) } Return (0) }
     */
    reference :: method(&a, "CREF", 0)
    missing :: open(&a, u8.[0xa0])
    raw(&a, u8.[0x5b, 0x12])
    name(&a, "\\NOPE")
    raw(&a, u8.[0x60, 0xa4, 0x01])
    close(&a, missing)
    present :: open(&a, u8.[0xa0])
    raw(&a, u8.[0x5b, 0x12])
    name(&a, "\\INT1")
    raw(&a, u8.[0x60, 0xa4, 0x83, 0x60])
    close(&a, present)
    raw(&a, u8.[0xa4, 0x00])
    close(&a, reference)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run(interpreter, "TMPN")) or_else 0, 5, "the method's Name has its value")
    testing.expect_eq(t, integer_from(run(interpreter, "TMPN")) or_else 0, 5, "and the second call makes it again")
    testing.expect(t, aml.find(interpreter, "\\TMPN.TMP") is_none, "the Name is gone once the method's returned")
    testing.expect_eq(t, integer_from(run(interpreter, "CREF")) or_else 0, 9, "CondRefOf passes over \\NOPE and finds \\INT1")
    return .Ok
}

// ---- Data

/** A package's element is changed through Index, and kept in the namespace; SizeOf counts its elements. */
packages_and_index #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Name (PKG_, Package (3) { 1, "two", Buffer (2) { 3, 4 } })
    op(&a, 0x08)
    name(&a, "PKG")
    package :: open(&a, u8.[0x12])
    op(&a, 3)
    op(&a, 0x01)
    text(&a, "two")
    buffer :: open(&a, u8.[0x11])
    raw(&a, u8.[0x0a, 0x02, 0x03, 0x04])
    close(&a, buffer)
    close(&a, package)
    // Method (SETP) { Store (42, Index (PKG_, 0)) Return (DerefOf (Index (PKG_, 0))) }
    set :: method(&a, "SETP", 0)
    raw(&a, u8.[0x70, 0x0a, 0x2a, 0x88])
    name(&a, "PKG")
    raw(&a, u8.[0x00, 0x00, 0xa4, 0x83, 0x88])
    name(&a, "PKG")
    raw(&a, u8.[0x00, 0x00])
    close(&a, set)
    // Method (SIZE) { Return (SizeOf (PKG_)) }
    size :: method(&a, "SIZE", 0)
    raw(&a, u8.[0xa4, 0x87])
    name(&a, "PKG")
    close(&a, size)
    // Method (BYTE) { Return (DerefOf (Index (DerefOf (Index (PKG_, 2)), 1))) }
    byte :: method(&a, "BYTE", 0)
    raw(&a, u8.[0xa4, 0x83, 0x88, 0x83, 0x88])
    name(&a, "PKG")
    raw(&a, u8.[0x0a, 0x02, 0x00, 0x01, 0x00])
    close(&a, byte)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run(interpreter, "SETP")) or_else 0, 42, "the element stored through Index reads back")
    testing.expect_eq(t, integer_from(run(interpreter, "SIZE")) or_else 0, 3, "the package has 3 elements")
    testing.expect_eq(t, integer_from(run(interpreter, "BYTE")) or_else 0, 4, "the buffer in it has 4 at 1")
    match run(interpreter, "PKG") {
        case Ok(value) => match value {
            case Package(found) => {
                testing.require(t, found.elements.count == 3, "PKG has its 3 elements")?
                first :: found.elements[0 % found.elements.count]
                match first {
                    case Integer(number) => testing.expect_eq(t, number, 42, "the change is kept in the namespace")
                    case _ => testing.fail(t, "the first element isn't an integer")
                }
            }
            case _ => testing.fail(t, "PKG isn't a package")
        }
        case Error(_) => testing.fail(t, "PKG doesn't evaluate")
    }
    return .Ok
}

/** Strings concatenate, convert to and from integers, and compare. */
strings_and_conversions #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Method (CATS) { Return (Concatenate ("ab", "cd")) }
    joined :: method(&a, "CATS", 0)
    raw(&a, u8.[0xa4, 0x73])
    text(&a, "ab")
    text(&a, "cd")
    op(&a, 0x00)
    close(&a, joined)
    // Method (HEXS) { Return (ToHexString (0x1F)) }
    hex :: method(&a, "HEXS", 0)
    raw(&a, u8.[0xa4, 0x98, 0x0a, 0x1f, 0x00])
    close(&a, hex)
    // Method (DECS) { Return (ToDecimalString (1234)) }
    decimal :: method(&a, "DECS", 0)
    raw(&a, u8.[0xa4, 0x97, 0x0b, 0xd2, 0x04, 0x00])
    close(&a, decimal)
    // Method (TOIN) { Return (ToInteger ("0x2A")) }
    to_integer :: method(&a, "TOIN", 0)
    raw(&a, u8.[0xa4, 0x99])
    text(&a, "0x2A")
    op(&a, 0x00)
    close(&a, to_integer)
    // Method (EQLS) { Return (LEqual ("abc", "abc")) }
    equal :: method(&a, "EQLS", 0)
    raw(&a, u8.[0xa4, 0x93])
    text(&a, "abc")
    text(&a, "abc")
    close(&a, equal)
    // Method (LESS) { Return (LLess ("abc", "abd")) }
    less :: method(&a, "LESS", 0)
    raw(&a, u8.[0xa4, 0x95])
    text(&a, "abc")
    text(&a, "abd")
    close(&a, less)
    // Method (MIDS) { Return (Mid ("hello", 1, 3)) }
    middle :: method(&a, "MIDS", 0)
    raw(&a, u8.[0xa4, 0x9e])
    text(&a, "hello")
    raw(&a, u8.[0x01, 0x0a, 0x03, 0x00])
    close(&a, middle)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, text_from(run(interpreter, "CATS")), "abcd", "two strings concatenate")
    testing.expect_eq(t, text_from(run(interpreter, "HEXS")), "000000000000001F", "0x1F in hex, 64 bits of it")
    testing.expect_eq(t, text_from(run(interpreter, "DECS")), "1234", "1234 in decimal")
    testing.expect_eq(t, integer_from(run(interpreter, "TOIN")) or_else 0, 0x2a, "\"0x2A\" is 42")
    testing.expect_eq(t, integer_from(run(interpreter, "EQLS")) or_else 0, 0xffffffffffffffff, "equal strings are equal: Ones")
    testing.expect_eq(t, integer_from(run(interpreter, "LESS")) or_else 0, 0xffffffffffffffff, "abc is less than abd")
    testing.expect_eq(t, text_from(run(interpreter, "MIDS")), "ell", "Mid takes 3 from 1")
    return .Ok
}

/** Before a DSDT of revision 2, integers are 32 bits: Ones is 0xFFFFFFFF, and adding past it wraps. */
integers_are_32_bits_before_revision_2 #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Method (WRAP) { Return (Add (0xFFFFFFFF, 1)) } Method (ONES) { Return (Ones) }
    wrap :: method(&a, "WRAP", 0)
    raw(&a, u8.[0xa4, 0x72, 0x0c, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00])
    close(&a, wrap)
    all :: method(&a, "ONES", 0)
    raw(&a, u8.[0xa4, 0xff])
    close(&a, all)
    setup :: loaded(t, &a, aml.Limits.{}, 1)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run(interpreter, "WRAP")) or_else 1, 0, "0xFFFFFFFF + 1 wraps to 0")
    testing.expect_eq(t, integer_from(run(interpreter, "ONES")) or_else 0, 0xffffffff, "Ones is 32 bits")
    return .Ok
}

// ---- Fields

/** A field's write keeps the bits of its unit that aren't its, and reads back; others in the unit are untouched. */
fields_in_a_region #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // OperationRegion (REG0, SystemIO, 0x10, 0x10)
    raw(&a, u8.[0x5b, 0x80])
    name(&a, "REG0")
    raw(&a, u8.[0x01, 0x0a, 0x10, 0x0a, 0x10])
    // Field (REG0, ByteAcc, NoLock, Preserve) { F1__, 8, F2__, 4, F3__, 4, F4__, 16 }
    fields :: open(&a, u8.[0x5b, 0x81])
    name(&a, "REG0")
    op(&a, 0x01)
    raw(&a, u8.[0x46, 0x31, 0x5f, 0x5f, 0x08, 0x46, 0x32, 0x5f, 0x5f, 0x04, 0x46, 0x33, 0x5f, 0x5f, 0x04, 0x46, 0x34, 0x5f, 0x5f, 0x10])
    close(&a, fields)
    // Method (WRIT) { Store (0xAB, F1__) Store (5, F3__) Store (3, F2__) Store (0xBEEF, F4__) Return (F2__) }
    write :: method(&a, "WRIT", 0)
    raw(&a, u8.[0x70, 0x0a, 0xab])
    name(&a, "F1")
    raw(&a, u8.[0x70, 0x0a, 0x05])
    name(&a, "F3")
    raw(&a, u8.[0x70, 0x0a, 0x03])
    name(&a, "F2")
    raw(&a, u8.[0x70, 0x0b, 0xef, 0xbe])
    name(&a, "F4")
    op(&a, 0xa4)
    name(&a, "F2")
    close(&a, write)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    host :: setup.host
    testing.expect_eq(t, integer_from(run(interpreter, "WRIT")) or_else 0, 3, "F2 reads back what was written")
    testing.expect_eq(t, host.space[0x10], 0xab, "F1 is the region's first byte")
    testing.expect_eq(t, host.space[0x11], 0x53, "F2 and F3 share the second, each keeping the other's bits")
    testing.expect_eq(t, host.space[0x12], 0xef, "F4's low byte")
    testing.expect_eq(t, host.space[0x13], 0xbe, "F4's high byte")
    testing.expect_eq(t, integer_from(run(interpreter, "F4")) or_else 0, 0xbeef, "F4 is read, a unit at a time")
    return .Ok
}

/** An index field's unit is reached by writing its offset to the index field, then the data field. */
index_fields #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // OperationRegion (IDXR, SystemIO, 0x20, 2) Field (IDXR, ByteAcc, NoLock, Preserve) { INDX, 8, DATA, 8 }
    raw(&a, u8.[0x5b, 0x80])
    name(&a, "IDXR")
    raw(&a, u8.[0x01, 0x0a, 0x20, 0x0a, 0x02])
    fields :: open(&a, u8.[0x5b, 0x81])
    name(&a, "IDXR")
    op(&a, 0x01)
    raw(&a, u8.[0x49, 0x4e, 0x44, 0x58, 0x08, 0x44, 0x41, 0x54, 0x41, 0x08])
    close(&a, fields)
    // IndexField (INDX, DATA, ByteAcc, NoLock, Preserve) { Offset (2), RG02, 8 }
    indexed :: open(&a, u8.[0x5b, 0x86])
    name(&a, "INDX")
    name(&a, "DATA")
    op(&a, 0x01)
    raw(&a, u8.[0x00, 0x10, 0x52, 0x47, 0x30, 0x32, 0x08])
    close(&a, indexed)
    // Method (SETR) { Store (0x77, RG02) }
    set :: method(&a, "SETR", 0)
    raw(&a, u8.[0x70, 0x0a, 0x77])
    name(&a, "RG02")
    close(&a, set)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    host :: setup.host
    testing.require(t, run(interpreter, "SETR") is_ok, "SETR runs")?
    testing.expect_eq(t, host.space[0x20], 2, "the index register is given the unit's offset")
    testing.expect_eq(t, host.space[0x21], 0x77, "the data register is written")
    return .Ok
}

/** A buffer field is bits of its buffer, and storing into it changes the buffer. */
buffer_fields #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Name (BUF_, Buffer (8) {})
    op(&a, 0x08)
    name(&a, "BUF")
    buffer :: open(&a, u8.[0x11])
    raw(&a, u8.[0x0a, 0x08])
    close(&a, buffer)
    // Method (BFLD) { CreateDWordField (BUF_, 2, DW__) Store (0x11223344, DW__) Return (DerefOf (Index (BUF_, 2))) }
    field :: method(&a, "BFLD", 0)
    op(&a, 0x8a)
    name(&a, "BUF")
    raw(&a, u8.[0x0a, 0x02])
    name(&a, "DW")
    raw(&a, u8.[0x70, 0x0c, 0x44, 0x33, 0x22, 0x11])
    name(&a, "DW")
    raw(&a, u8.[0xa4, 0x83, 0x88])
    name(&a, "BUF")
    raw(&a, u8.[0x0a, 0x02, 0x00])
    close(&a, field)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run(interpreter, "BFLD")) or_else 0, 0x44, "the field's low byte is the buffer's byte 2")
    testing.expect_eq(t, integer_from(run(interpreter, "BFLD")) or_else 0, 0x44, "and the field's made again on the next call")
    return .Ok
}

/** A PCI_Config region's accesses name its device's function, from its _ADR. */
pci_config_regions #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    /*
     * Device (PCI0) { Name (_ADR, 0x00030001) OperationRegion (PCFG, PCI_Config, 0x40, 4)
     * Field (PCFG, DWordAcc, NoLock, Preserve) { VAL_, 32 } }
     */
    device :: open(&a, u8.[0x5b, 0x82])
    name(&a, "PCI0")
    name_integer(&a, "_ADR", 0x00030001)
    raw(&a, u8.[0x5b, 0x80])
    name(&a, "PCFG")
    raw(&a, u8.[0x02, 0x0a, 0x40, 0x0a, 0x04])
    fields :: open(&a, u8.[0x5b, 0x81])
    name(&a, "PCFG")
    op(&a, 0x03)
    raw(&a, u8.[0x56, 0x41, 0x4c, 0x5f, 0x20])
    close(&a, fields)
    close(&a, device)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    host :: setup.host
    testing.expect_eq(t, integer_from(run(interpreter, "\\PCI0.VAL")) or_else 0, PCI_VALUE, "the field reads what the host gives")
    testing.expect_eq(t, host.pci, aml.pci_address(0, 0, 3, 1, 0x40), "device 3, function 1, offset 0x40")
    return .Ok
}

// ---- The host

/** Notify reaches the host with its value, Debug shows it what's stored, and _OSI answers for what's claimed. */
notify_debug_and_interfaces #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Device (DEV_) {} Method (NTFY) { Notify (DEV_, 0x80) Store ("hello", Debug) }
    device :: open(&a, u8.[0x5b, 0x82])
    name(&a, "DEV")
    close(&a, device)
    notify :: method(&a, "NTFY", 0)
    op(&a, 0x86)
    name(&a, "DEV")
    raw(&a, u8.[0x0a, 0x80, 0x70])
    text(&a, "hello")
    raw(&a, u8.[0x5b, 0x31])
    close(&a, notify)
    // Method (OSIW) { Return (\_OSI ("Windows 2015")) } and the same for "Linux" and "SlopOS Test"
    asks :: string.["OSIW", "OSIL", "OSIS"]
    interfaces :: string.["Windows 2015", "Linux", "SlopOS Test"]
    for asked, i in asks {
        body :: method(&a, asked, 0)
        op(&a, 0xa4)
        name(&a, "\\_OSI")
        if i < interfaces.count {
            text(&a, interfaces[i])
        }
        close(&a, body)
    }
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    host :: setup.host
    testing.require(t, run(interpreter, "NTFY") is_ok, "NTFY runs")?
    testing.expect_eq(t, host.notified, 0x80, "the host is notified with 0x80")
    testing.expect_eq(t, aml.text_of(host.debug[0..<host.debug.count]), "hello", "the debug object shows the host hello")
    testing.expect_eq(t, integer_from(run(interpreter, "OSIW")) or_else 0, 0xffffffffffffffff, "Windows 2015 is claimed")
    testing.expect_eq(t, integer_from(run(interpreter, "OSIL")) or_else 1, 0, "Linux isn't")
    testing.expect_eq(t, integer_from(run(interpreter, "OSIS")) or_else 0, 0xffffffffffffffff, "the interface given is")
    return .Ok
}

// ---- Bounds

/** A loop that doesn't end runs out of steps, a recursion out of depth, and growing without end out of memory. */
every_bound_ends_what_passes_it #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    // Method (SPIN) { While (One) {} }
    spin :: method(&a, "SPIN", 0)
    forever :: open(&a, u8.[0xa2])
    op(&a, 0x01)
    close(&a, forever)
    close(&a, spin)
    // Method (RECR) { RECR () }
    recursion :: method(&a, "RECR", 0)
    name(&a, "RECR")
    close(&a, recursion)
    // Method (GROW) { Store (Buffer (16) {}, Local0) While (One) { Concatenate (Local0, Local0, Local0) } }
    grow :: method(&a, "GROW", 0)
    op(&a, 0x70)
    buffer :: open(&a, u8.[0x11])
    raw(&a, u8.[0x0a, 0x10])
    close(&a, buffer)
    op(&a, 0x60)
    growing :: open(&a, u8.[0xa2])
    raw(&a, u8.[0x01, 0x73, 0x60, 0x60, 0x60])
    close(&a, growing)
    close(&a, grow)
    name_integer(&a, "INT1", 3)
    setup :: loaded(t, &a, aml.Limits.{steps = 100_000})?
    interpreter :: setup.interpreter
    testing.expect(t, error_from(run(interpreter, "SPIN")) == .Steps, "a loop that doesn't end runs out of steps")
    testing.expect(t, error_from(run(interpreter, "RECR")) == .Depth, "a method calling itself runs out of depth")
    testing.expect(t, error_from(run(interpreter, "GROW")) == .Memory, "a buffer that grows without end runs out of memory")
    testing.expect_eq(t, integer_from(run(interpreter, "INT1")) or_else 0, 3, "and the interpreter goes on after each")
    return .Ok
}

/** A namespace's budget bounds what a table loads. */
the_namespace_has_a_budget #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    names :: string.["NA00", "NA01", "NA02", "NA03", "NA04", "NA05", "NA06", "NA07", "NA08", "NA09"]
    for each in names {
        name_integer(&a, each, 1)
    }
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, aml.Limits.{namespace_bytes = 16 * size_of(aml.Node)}), "it's made")?
    testing.expect(t, aml.load_table(interpreter, table(&a)) == .Memory, "ten names and the table don't fit in 16 nodes' room")
    return .Ok
}

/** What a table's header says is checked: a short table, a length past its bytes, a signature that isn't a DSDT's. */
tables_are_checked #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, aml.Limits.{}), "it's made")?
    a := Assembler.{}
    name_integer(&a, "INT1", 1)
    whole :: table(&a)
    if whole.count < 40 {
        return testing.require(t, false, "the table has its header and a Name")
    }
    testing.expect(t, aml.load_table(interpreter, whole[0..<20]) == .BadTable, "20 bytes are no table")
    testing.expect(t, aml.load_table(interpreter, whole[0..<(whole.count - 1)]) == .BadTable, "a length past the bytes is refused")
    testing.expect(t, aml.load_table(interpreter, table(&a, "FACP")) == .BadTable, "a FACP is no definition block")
    testing.expect(t, aml.load_table(interpreter, table(&a, "SSDT")) is_none, "an SSDT loads")
    return .Ok
}

/** Bytes drawn at random as a table's AML fail or load, never fault; any methods they make run within the bounds. */
random_tables_never_fault #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    a := Assembler.{}
    // A valid start sometimes, so what's drawn after it is run inside a method or a scope
    if testing.draw_bool(source) {
        _ = open(&a, u8.[0x14])
        name(&a, "RAND")
        op(&a, 0)
    }
    raw(&a, testing.draw_bytes(source, 256))
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, aml.Limits.{steps = 10_000, evaluation_bytes = 64 * 1024}), "it's made")?
    _ = aml.load_table(interpreter, table(&a))
    match aml.find(interpreter, "\\RAND") {
        case Some(node) => _ = aml.evaluate_node(interpreter, node, NONE[0..<0])
        case None => {}
    }
    return .Ok
}

/**
 * Write a table with much of what AML has: a region and its fields, an index field, a package, a buffer, strings,
 * loops, references, buffer fields and methods calling each other.
 *
 * @param a The assembler.
 */
rich_table :: fn(a: ptr[mut Assembler]) {
    raw(a, u8.[0x5b, 0x80])
    name(a, "REG0")
    raw(a, u8.[0x01, 0x0a, 0x10, 0x0a, 0x20])
    fields :: open(a, u8.[0x5b, 0x81])
    name(a, "REG0")
    op(a, 0x01)
    raw(a, u8.[0x46, 0x31, 0x5f, 0x5f, 0x08, 0x46, 0x32, 0x5f, 0x5f, 0x04, 0x46, 0x33, 0x5f, 0x5f, 0x04, 0x49, 0x4e, 0x44, 0x58, 0x08,
        0x44, 0x41, 0x54, 0x41, 0x08, 0x01, 0x03, 0x00, 0x46, 0x34, 0x5f, 0x5f, 0x20])
    close(a, fields)
    indexed :: open(a, u8.[0x5b, 0x86])
    name(a, "INDX")
    name(a, "DATA")
    op(a, 0x21)
    raw(a, u8.[0x00, 0x10, 0x52, 0x47, 0x30, 0x32, 0x10])
    close(a, indexed)
    op(a, 0x08)
    name(a, "PKG")
    package :: open(a, u8.[0x12])
    op(a, 4)
    op(a, 0x01)
    text(a, "two")
    name(a, "\\INT1")
    buffer :: open(a, u8.[0x11])
    raw(a, u8.[0x0a, 0x04, 0x03, 0x04])
    close(a, buffer)
    close(a, package)
    name_integer(a, "INT1", 0x1234)
    op(a, 0x08)
    name(a, "BUF")
    empty :: open(a, u8.[0x11])
    raw(a, u8.[0x0a, 0x10])
    close(a, empty)
    // A method using most of it, and another calling it
    body :: method(a, "WORK", 2)
    raw(a, u8.[0x70, 0x00, 0x60, 0x70, 0x00, 0x61])
    loop_mark :: open(a, u8.[0xa2])
    raw(a, u8.[0x95, 0x61, 0x68, 0x75, 0x61, 0x72, 0x60, 0x61, 0x60])
    close(a, loop_mark)
    raw(a, u8.[0x70, 0x60])
    name(a, "F1")
    raw(a, u8.[0x70, 0x69])
    name(a, "RG02")
    op(a, 0x8a)
    name(a, "BUF")
    raw(a, u8.[0x0a, 0x04])
    name(a, "DW")
    raw(a, u8.[0x70, 0x60])
    name(a, "DW")
    raw(a, u8.[0x70, 0x88])
    name(a, "PKG")
    raw(a, u8.[0x01, 0x00, 0x62, 0x70, 0x73, 0x83, 0x62])
    text(a, "!")
    raw(a, u8.[0x63, 0x5b, 0x31])
    taken :: open(a, u8.[0xa0])
    raw(a, u8.[0x93, 0x87])
    name(a, "PKG")
    raw(a, u8.[0x0a, 0x04, 0xa4, 0x99, 0x97, 0x60, 0x00, 0x00])
    close(a, taken)
    raw(a, u8.[0xa4, 0x60])
    close(a, body)
    caller :: method(a, "CALL", 0)
    op(a, 0xa4)
    name(a, "WORK")
    raw(a, u8.[0x0a, 0x05, 0x0a, 0x09])
    close(a, caller)
}

/** The rich table loads, and its methods run as they're written. */
the_rich_table_runs #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    a := Assembler.{}
    rich_table(&a)
    setup :: loaded(t, &a)?
    interpreter :: setup.interpreter
    testing.expect_eq(t, integer_from(run(interpreter, "CALL")) or_else 0, 15, "WORK sums 1 to 5 and gives it back")
    testing.expect_eq(t, setup.host.space[0x10], 15, "F1 is written with the sum")
    return .Ok
}

/** Methods a fuzzed table defines, kept by visit_methods. */
Methods :: struct {
    /** The methods. */
    found : ptr[mut aml.Node][..],
}

/**
 * Keep a node if it's a method.
 *
 * @param node The node.
 * @param state The Methods' address.
 * @return True, to go on.
 */
visit_methods :: fn(node #escaping : ptr[mut aml.Node], state: u64) -> bool {
    if node.kind == .Method {
        methods :: cast[ptr[mut Methods]](state)
        runtime.array_add(&methods.found, node)
    }
    return true
}

/** The rich table with bytes changed at random loads or fails, and its methods run or fail, but never fault. */
changed_tables_never_fault #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    a := Assembler.{}
    rich_table(&a)
    for change in 0..<testing.draw_count(source, 6) {
        if a.bytes.count == 0 {
            break
        }
        at :: cast[usize](testing.draw_below(source, cast[u64](a.bytes.count)))
        byte :: testing.draw_byte(source)
        if at < a.bytes.count {
            a.bytes[at] = byte
        }
    }
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, aml.Limits.{steps = 20_000, evaluation_bytes = 64 * 1024}), "it's made")?
    _ = aml.load_table(interpreter, table(&a))
    methods := Methods.{}
    _ = aml.walk(interpreter.root, visit_methods, cast[u64](&methods))
    for node in methods.found {
        arguments :: aml.Value.[.Integer(testing.draw_below(source, 300)), .Integer(testing.draw_below(source, 300))]
        _ = aml.evaluate_node(interpreter, node, arguments[0..<2])
    }
    return .Ok
}

// ---- QEMU's own DSDT

/*
 * QEMU's q35 DSDT, as its firmware tables gave it to the platform service (saved once from a boot, 2026-11-07): real
 * firmware's AML, with methods, fields in SystemIO, SystemMemory and PCI_Config, and a host bridge's _CRS.
 */
QEMU_Q35_DSDT :: #file_data("qemu_q35_dsdt.aml")

/**
 * Make an interpreter over a new TestHost with QEMU's DSDT loaded.
 *
 * @param t The test.
 * @return The interpreter and its host; or the test failed if the table didn't load.
 */
qemu_loaded :: fn(t: ptr[mut testing.T]) -> Result[Loaded, testing.Stopped] {
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, aml.Limits.{}), "the interpreter's made")?
    problem :: aml.load_table(interpreter, QEMU_Q35_DSDT[0..<QEMU_Q35_DSDT.count])
    if problem is_some {
        testing.note(t, "% at % missing %: %", problem, interpreter.failed_at, interpreter.missing, interpreter.failed_bytes)
    }
    testing.require(t, problem is_none, "QEMU's DSDT loads")?
    return .Ok(Loaded.{interpreter = interpreter, host = host})
}

/** QEMU's DSDT loads; its \_S5 gives S5's sleep types, and its host bridge is PNP0A08, with resources. */
qemu_dsdt_loads_and_answers #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    setup :: qemu_loaded(t)?
    interpreter :: setup.interpreter
    match run(interpreter, "\\_S5") {
        case Ok(value) => match value {
            case Package(package) => {
                testing.require(t, package.elements.count >= 2, "\\_S5 has its two sleep types")?
                first :: package.elements[0 % package.elements.count]
                match first {
                    case Integer(number) => testing.expect_eq(t, number, 0, "q35's S5 sleep type is 0")
                    case _ => testing.fail(t, "\\_S5's first element isn't an integer")
                }
            }
            case _ => testing.fail(t, "\\_S5 isn't a package")
        }
        case Error(error) => {
            testing.fail(t, "\\_S5 doesn't evaluate")
            testing.note(t, "%", error)
        }
    }
    // EisaId ("PNP0A08"), a PCI Express host bridge
    testing.expect_eq(t, integer_from(run(interpreter, "\\_SB.PCI0._HID")) or_else 0, 0x080ad041, "PCI0 is PNP0A08")
    match run(interpreter, "\\_SB.PCI0._CRS") {
        case Ok(value) => match value {
            case Buffer(bytes) => {
                data :: bytes.data
                if data.count < 2 {
                    return testing.require(t, false, "_CRS has at least an end tag")
                }
                testing.expect_eq(t, data[data.count - 2], 0x79, "_CRS ends with an end tag")
            }
            case _ => testing.fail(t, "_CRS isn't a buffer")
        }
        case Error(error) => {
            testing.fail(t, "_CRS doesn't evaluate")
            testing.note(t, "%", error)
        }
    }
    return .Ok
}

/**
 * Every method in QEMU's DSDT runs to its end, given zeros as its arguments, but those that need a buffer for one:
 * `_SRS` and `_OSC`, which fail as WrongType.
 */
every_qemu_method_runs_or_fails_cleanly #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    setup :: qemu_loaded(t)?
    interpreter :: setup.interpreter
    methods := Methods.{}
    _ = aml.walk(interpreter.root, visit_methods, cast[u64](&methods))
    testing.require(t, methods.found.count > 20, "QEMU's DSDT has its methods")?
    ran : usize = 0
    for node in methods.found {
        arguments :: aml.Value.[.Integer(0), .Integer(0), .Integer(0), .Integer(0), .Integer(0), .Integer(0), .Integer(0)]
        match aml.evaluate_node(interpreter, node, arguments[0..<7]) {
            case Ok(_) => ran += 1
            case Error(error) => {
                if error != .WrongType {
                    storage : u8[128]
                    out := text_buffer.make(storage)
                    aml.write_path(&out, node)
                    testing.note(t, "%", text_buffer.as_string(&out))
                    testing.note(t, "%", error)
                    testing.fail(t, "a method of QEMU's fails for something other than its arguments")
                }
            }
        }
    }
    testing.expect(t, ran + 9 >= methods.found.count, "all but the 8 _SRS and the _OSC run to their end")
    return .Ok
}

/** QEMU's DSDT with bytes changed at random loads or fails, and its methods run or fail, but never fault. */
changed_qemu_dsdts_never_fault #test :: fn(t: ptr[mut testing.T], source: ptr[mut testing.Source]) -> testing.Outcome {
    changed : u8[..]
    defer runtime.array_free(&changed)
    for byte in QEMU_Q35_DSDT {
        runtime.array_add(&changed, byte)
    }
    for change in 0..<testing.draw_count(source, 8) {
        // Past the header, so the table's still taken as one
        at :: 36 + cast[usize](testing.draw_below(source, cast[u64](changed.count - 36)))
        byte :: testing.draw_byte(source)
        if at < changed.count {
            changed[at] = byte
        }
    }
    host :: runtime.new(TestHost)
    interpreter :: testing.require_some(t, made(host, aml.Limits.{steps = 50_000, evaluation_bytes = 256 * 1024}), "it's made")?
    _ = aml.load_table(interpreter, changed[0..<changed.count])
    methods := Methods.{}
    _ = aml.walk(interpreter.root, visit_methods, cast[u64](&methods))
    for node in methods.found {
        arguments :: aml.Value.[.Integer(testing.draw_below(source, 4)), .Integer(0), .Integer(0), .Integer(0)]
        _ = aml.evaluate_node(interpreter, node, arguments[0..<4])
    }
    return .Ok
}
