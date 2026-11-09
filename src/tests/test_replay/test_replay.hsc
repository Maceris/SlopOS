/**
 * test_replay (decisions/0183, 12c): a program of several threads for the shell's record and replay. Its WORKERS
 * threads each take a lock count times, and under it mix the clock and their number into a total they share; then
 * the first thread reads the CPU's counter directly, and mixes it in too. What it writes on the shell's terminal, the
 * total, depends on the order the threads took the lock in, the clock and the counter: so only an exact replay gives it
 * again. Given a channel too, it sends itself a channel end and uses what it receives, which a replay has only from the
 * recording (decisions/0185, 12g).
 */
package test_replay

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import os from "std"
import terminal from "std"
import text_buffer from "std"
import slop_os from "std/os"
import terminal as protocol from "std/os/slop_os"
#if TARGET_ARCH == .x86_64 {
    import x86_64 from "base/intrinsics"
}
#else_if TARGET_ARCH == .arm64 {
    import aarch64 from "base/intrinsics"
}

/** How many threads mix into the total. */
WORKERS :: 3

/** What the threads share. */
Shared :: struct {
    /** Held while total changes. */
    lock : concurrency.SpinLock,
    /** The total, mixed by each turn. */
    total : u64,
    /** How many turns each thread takes. */
    count : u64,
    /** The next thread's number, from 0, taken atomically as each starts. */
    next : u32,
}

/**
 * Run the threads, and write what they made on the terminal.
 *
 * @param session_terminal The shell's terminal, which the total's written on; without it, nothing is.
 * @param count How many turns each thread takes, at least 1.
 * @param channel Any number to send itself a channel end, and write on and close the end it receives; none not to.
 * @return 0 once it's written; 2 if a thread couldn't be started, 3 if the terminal couldn't be opened, 4 if the end
 *     couldn't be passed.
 */
main :: fn(session_terminal: os.Channel[protocol.Terminal]?, count: u64, channel: u64?) -> int {
    shared :: runtime.new(Shared)
    shared.count = if count == 0 { 1 } else { count }
    shared.total = 1
    threads : ptr[mut runtime.Thread][WORKERS]
    node := runtime.extension_node(cast[ptr[Shared]](shared))
    push_context with_shared (extensions = &node) {
        for i in 0..<WORKERS {
            threads[i] = runtime.thread_create(work)
            if !runtime.thread_start(threads[i]) {
                return 2
            }
        }
    }
    for thread in threads {
        runtime.thread_join(thread)
    }
    if channel is_some {
        passed :: pass_an_end() or_return 4
        shared.total = shared.total * 31 + passed
    }
    match session_terminal {
        case Some(given) => {
            console := terminal.open(given) or_return 3
            storage : u8[128]
            line := text_buffer.make(storage)
            text_buffer.append_format(&line, "test_replay: % turns, total %{#x}", shared.count, shared.total)
            _ = terminal.write_line(&console, text_buffer.as_string(&line))
        }
        case None => {}
    }
    return 0
}

/**
 * Take the lock count times, each time mixing the clock and the thread's number into the total; the first thread
 * mixes in the counter too, read directly.
 *
 * @param data Nothing: what's shared is the context's extension.
 */
work : runtime.ThreadFunction : fn(data #escaping : any) {
    found :: runtime.get_extension(Shared) or_return void
    shared :: cast[ptr[mut Shared]](found)
    number :: cast[u64](intrinsics.interlocked_exchange_add_u32_no_fence(&shared.next, 1))
    for turn in cast[u64](0)..<shared.count {
        now :: slop_os.clock_monotonic() or_else 0
        concurrency.lock(&shared.lock)
        shared.total = shared.total * 31 + number * 7 + (now & 0xff)
        concurrency.unlock(&shared.lock)
    }
    if number == 0 {
        counter :: read_counter()
        concurrency.lock(&shared.lock)
        shared.total = shared.total ~ (counter & 0xffff)
        concurrency.unlock(&shared.lock)
    }
}

/**
 * Read the CPU's counter directly, which a recording traps.
 *
 * @return x86-64's time-stamp counter, or AArch64's CNTVCT_EL0.
 */
read_counter :: fn() -> u64 {
    #if TARGET_ARCH == .x86_64 {
        return x86_64.rdtsc()
    }
    #else {
        return aarch64.read_system_register(.CNTVCT_EL0)
    }
}

/**
 * Send itself a channel end over another channel, receive it, write on it, and close it: what it receives is a handle
 * a replay has only from the recording.
 *
 * @return The handle received, as a number; null if a channel couldn't be made, or the end wasn't passed.
 */
pass_an_end :: fn() -> u64? {
    budget :: slop_os.startup_block().budget
    carrier :: slop_os.channel_create(budget, 0, 0) or_return null
    passed :: slop_os.channel_create(budget, 0, 0) or_return null
    port :: os.port_for(budget, carrier.b) or_return null
    sent :: slop_os.Handle.[cast[slop_os.Handle](passed.a)]
    if os.send(carrier.a, port, u8.[1, 2, 3], sent) != null {
        return null
    }
    bytes : u8[16]
    handles : slop_os.Handle[1]
    got :: os.receive(carrier.b, port, bytes, handles) or_return null
    if got.handle_count == 0 {
        return null
    }
    end :: cast[slop_os.Channel](handles[0])
    _ = slop_os.channel_write(end, u8.[4, 5], slop_os.NO_BATCH)
    _ = slop_os.handle_close(cast[slop_os.Handle](end))
    return cast[u64](handles[0])
}

