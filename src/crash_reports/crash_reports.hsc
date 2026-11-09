/**
 * Crash reports (decisions/0183, 12a): what a program that launched another, holding the intercept of its faults
 * (std's os.LaunchOptions.faults), makes of a fault that stopped one of its threads. The report holds the fault, the
 * thread's registers, its stack walked through frame pointers, and where its image is, so a reader with the program's
 * debug info can name each frame. The holder logs it as a typed record, `crash: %` with the report, which the events
 * service keeps by its schema, and then ends the process.
 *
 * Typical use, at a Stop packet on the faults' port:
 *
 *     for report in crash_reports.take(launched.process, faults, launched.image, name, &storage) {
 *         crash_reports.log(report)
 *     }
 *     _ = slop_os.process_kill(launched.process)
 */
package crash_reports

import runtime from "base"
import slop_os from "std/os"
import os from "std"
import lifecycle from "std/os/slop_os"
import text_buffer from "std"

/** The most frames a report's stack holds, the faulting one included; a deeper stack is cut. */
MAX_FRAMES : u32 : 32
/** The most stops take reads at once; more wait for the next call. */
MAX_STOPS : usize : 8
/** How far a frame pointer may be above the one before it, in bytes, before the walk takes the chain as broken. */
MAX_FRAME_SIZE : u64 : 1 << 20

#if TARGET_ARCH == .arm64 {
    /** Where the program counter is among thread_read_registers' registers. */
    PC_REGISTER : usize : 32
    /** Where the frame pointer (x29) is among them. */
    FRAME_REGISTER : usize : 29
    /** Where the stack pointer is among them. */
    STACK_REGISTER : usize : 31
}
#else {
    /** Where the program counter (rip) is among thread_read_registers' registers. */
    PC_REGISTER : usize : 16
    /** Where the frame pointer (rbp) is among them. */
    FRAME_REGISTER : usize : 6
    /** Where the stack pointer (rsp) is among them. */
    STACK_REGISTER : usize : 7
}

/** A crash report: a fault that stopped a program's thread, and where the thread was. */
CrashReport :: struct {
    /** The program's name, as its launcher knows it; at most os.GRANT_LABEL_SIZE bytes. */
    program : string,
    /** The faulting thread's ID in its process. */
    thread : u64,
    /** What faulted: one of slop_os's FAULT_ kinds; slop_os.fault_name names it. */
    fault : u32,
    /** For a page fault, the address it touched; 0 for the other kinds. */
    address : u64,
    /** Where the program's image is in its address space; a frame's offset in the image is its address less this. */
    image : u64,
    /**
     * The thread's registers when it faulted, as thread_read_registers gives them (slop_os.THREAD_REGISTERS of them,
     * in its order); all 0 when they couldn't be read.
     */
    registers : u64[slop_os.THREAD_REGISTERS],
    /**
     * The stack, innermost first: the faulting instruction's address, then each caller's return address, as the
     * frame pointers chain them. frame_count are used.
     */
    frames : u64[MAX_FRAMES],
    /** How many of frames are used: 1 to MAX_FRAMES, or 0 when the registers couldn't be read. */
    frame_count : u32,
}

/** Room for the reports take makes, which its result is a view of. */
Storage :: struct {
    /** The reports; take fills the first of them. */
    reports : CrashReport[MAX_STOPS],
}

/**
 * Take the fault stops waiting on a program's intercept, making a report of each, and let each stopped thread go,
 * killed. Stops that aren't faults are let go too, as they are.
 *
 * Call it at a Stop packet on the port the intercept reports to (os.LaunchFaults), then end the program, whose other
 * threads may be running still: a program that faulted is ended whole, as the kernel does without an intercept
 * (decisions/0181's F6).
 *
 * @param process The program's process, with RIGHT_PROCESS_INSPECT and RIGHT_PROCESS_READ_MEMORY (a launcher's has
 *     every right).
 * @param faults The intercept and address space the launch gave, the caller's still.
 * @param image Where the program's image is (os.Launched's image).
 * @param program The program's name, which each report points to: it has to outlive them.
 * @param storage Where the reports are made, which the result is a view of; what it held before is overwritten.
 * @return The reports made, at most MAX_STOPS; empty when there was no fault stop waiting.
 */
take :: fn(process: slop_os.Process, faults: os.LaunchedFaults, image: u64, program #escaping : string, storage: ptr[mut Storage])
    -> CrashReport[] {
    count : usize = 0
    for round in cast[usize](0)..<MAX_STOPS {
        stop := slop_os.StopInfo.{}
        match slop_os.intercept_next(faults.intercept, &stop) {
            case Ok => {}
            case Error(error) => break
        }
        if stop.point == .Fault && count < storage.reports.count {
            storage.reports[count] = make(process, faults.space, image, program, stop)
            count += 1
        }
        action :: if stop.point == .Fault { slop_os.InterceptAction.Kill } else { slop_os.InterceptAction.Continue }
        _ = slop_os.intercept_resume(faults.intercept, stop.thread, action)
    }
    return view_of(&storage.reports[0], count)
}

/**
 * A return address read from a user-mode frame, without the authentication code AArch64's pointer authentication
 * signed it with (decisions/0186): its bits above 47 cleared, as a user-mode address has none. An address that wasn't
 * signed is the same, as every x86-64 one is.
 *
 * @param address The address as the frame holds it.
 * @return The address of the code it returns to.
 */
without_authentication :: fn(address: u64) -> u64 {
    return address & 0x0000ffffffffffff
}

/**
 * Make a report of a thread stopped by a fault: its registers read, its stack walked through frame pointers.
 *
 * @param process The thread's process, with RIGHT_PROCESS_INSPECT and RIGHT_PROCESS_READ_MEMORY.
 * @param space The process's address space, a handle with any rights.
 * @param image Where its image is.
 * @param program Its name, which the report points to.
 * @param stop The stop, a fault's.
 * @return The report: registers all 0 and no frames when they couldn't be read; the stack cut at the first frame
 *     pointer that's 0, unaligned, can't be read, or isn't above the one before it by at most MAX_FRAME_SIZE.
 */
make :: fn(process: slop_os.Process, space: slop_os.AddressSpace, image: u64, program #escaping : string, stop: slop_os.StopInfo)
    -> CrashReport {
    report := CrashReport.{program = program, thread = stop.thread, fault = stop.number, address = stop.address, image = image}
    match slop_os.thread_read_registers(process, stop.thread, report.registers) {
        case Ok => {}
        case Error(error) => return CrashReport.{program = program, thread = stop.thread, fault = stop.number,
            address = stop.address, image = image}
    }
    report.frames[0] = report.registers[PC_REGISTER]
    report.frame_count = 1
    frame := report.registers[FRAME_REGISTER]
    // Each frame record: the caller's frame pointer, then the return address
    for depth in cast[u32](1)..<MAX_FRAMES {
        if frame == 0 || (frame & 7) != 0 {
            break
        }
        record : u8[16]
        match slop_os.process_read_memory(process, space, frame, record) {
            case Ok => {}
            case Error(error) => break
        }
        caller :: word_at(record, 0)
        returned :: without_authentication(word_at(record, 8))
        if returned == 0 || cast[usize](depth) >= report.frames.count {
            break
        }
        report.frames[cast[usize](depth)] = returned
        report.frame_count = depth + 1
        if caller <= frame || caller - frame > MAX_FRAME_SIZE {
            break
        }
        frame = caller
    }
    return report
}

/**
 * Read a little-endian u64.
 *
 * @param bytes The bytes; 8 from at have to be there, or the missing ones are taken as 0.
 * @param at Where it starts.
 * @return Its value.
 */
word_at :: fn(bytes: u8[], at: usize) -> u64 {
    value : u64 = 0
    for i in cast[usize](0)..<8 {
        if at + i < bytes.count {
            value |= cast[u64](bytes[at + i]) << (8 * cast[u64](i))
        }
    }
    return value
}

/**
 * Log a report as an error: a typed record, `crash: %` with the report, which the events service keeps by the report's
 * schema, so a reader asks for the records holding a CrashReport, and reads each back as one.
 *
 * @param report The report.
 */
log :: fn(report: CrashReport) {
    runtime.log_error("crash: %", report)
}

/**
 * Write a report for a person, its frames as offsets in the image, which `hemera --symbolize` or the crashes tool
 * names.
 *
 * @param report The report.
 * @param into Where the text's added, at the end: lines separated by newlines, none after the last; cut off where
 *     it's full.
 * @param frames Whether its frames are written, a line each; otherwise only the program, the fault and the thread.
 */
describe :: fn(report: ptr[CrashReport], into: ptr[mut text_buffer.TextBuffer], frames: bool = true) {
    text_buffer.append_format(into, "%: %", report.program, slop_os.fault_name(report.fault))
    if report.fault <= slop_os.FAULT_EXECUTE {
        text_buffer.append_format(into, " at %{#x}", report.address)
    }
    text_buffer.append_format(into, "\n  in thread %", report.thread)
    if !frames {
        return void
    }
    count :: if report.frame_count <= MAX_FRAMES { report.frame_count } else { MAX_FRAMES }
    for i in cast[u32](0)..<count {
        if cast[usize](i) >= report.frames.count {
            break
        }
        address :: report.frames[cast[usize](i)]
        if address >= report.image {
            text_buffer.append_format(into, "\n  #% image+%{#x}", i, address - report.image)
        }
        else {
            text_buffer.append_format(into, "\n  #% %{#x}", i, address)
        }
    }
}

/** The number a ping that wakes a program to crash it carries (make_crash). */
CRASH_PING : u32 : 0x7e57
/** How many times, a millisecond apart, make_crash tries to read a suspended thread's registers. */
CRASH_ATTEMPTS :: 100

/**
 * Make a program crash, for tests of its crash reports: its first thread suspended, woken by a ping on its lifecycle
 * channel in case it waits, its program counter sent to its own stack, which can't be run, and resumed, so it faults
 * there at once, an execute fault.
 *
 * @param process The program's process, with RIGHT_PROCESS_INSPECT and RIGHT_PROCESS_WRITE_STATE.
 * @param ping The launcher's end of its lifecycle channel, pinged so a thread that waits wakes and is suspended; null
 *     for none, when a waiting thread isn't crashed.
 * @return Ok once it's been sent to its stack; the error otherwise, when it's resumed as it was: NoSuchThread if it
 *     has none, NotStopped if it wasn't suspended within CRASH_ATTEMPTS milliseconds, or what the calls gave.
 */
make_crash :: fn(process: slop_os.Process, ping: slop_os.Channel?) -> Result[void, slop_os.ControlError] {
    ids : u64[1]
    if (slop_os.process_threads(process, ids)?) == 0 {
        return .Error(.NoSuchThread)
    }
    slop_os.thread_suspend(process, ids[0])?
    defer slop_os.thread_resume(process, ids[0])
    match ping {
        case Some(end) => _ = lifecycle.ping(end, CRASH_PING)
        case None => {}
    }
    // Suspended once it's off its CPU, or once it wakes if it waits
    waiter :: slop_os.port_create(slop_os.startup_block().budget) or_return .Error(.NotStopped)
    defer slop_os.handle_close(cast[slop_os.Handle](waiter))
    registers : u64[slop_os.THREAD_REGISTERS]
    for attempt in 0..<CRASH_ATTEMPTS {
        if slop_os.thread_read_registers(process, ids[0], registers) is_ok {
            if PC_REGISTER >= registers.count || STACK_REGISTER >= registers.count {
                return .Error(.BadBuffer)
            }
            registers[PC_REGISTER] = registers[STACK_REGISTER] & ~cast[u64](15)
            return slop_os.thread_write_registers(process, ids[0], registers)
        }
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(waiter, packets, (slop_os.clock_monotonic() or_else 0) + 1_000_000)
    }
    return .Error(.NotStopped)
}
