package kernel

import intrinsics from "base"
import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * The kernel's own control-flow integrity, tested from the command line (decisions/0186, Hd): test_tamper returns
 * through a tampered return address, test_branch branches into a function's middle and test_shadow_write writes to
 * the kernel's shadow stack, each stopping the kernel with its fault named where the CPU has what refuses it, and
 * saying it's skipped where it hasn't. They run at a tick on the
 * boot CPU, which has gone idle by then, as pointer authentication is turned on there.
 */

/** The boot CPU's tick the tests run at. */
CONTROL_FLOW_TEST_TICK : u64 : 2
/** How many words tamper_with_return looks through, up from a local, for its saved return address. */
TAMPERING_REACH :: 64
/** How far above a frame record its caller's may be, in bytes, for tamper_with_return to take it as one. */
TAMPERING_FRAME_REACH : u64 : 64 * 1024
/** How many bytes into landing_target the branch goes: past its landing pad and the instruction after. */
MIDDLE_OFFSET : u64 : 8
/** A virtual address's bits, without a pointer authentication code or the bits above 48 that say which half it's in. */
ADDRESS_BITS : u64 : 0x0000ffffffffffff

/**
 * Run the control-flow tests the command line asks for, at the boot CPU's CONTROL_FLOW_TEST_TICK.
 *
 * @param kernel The kernel, whose options say which run.
 * @param ticks The boot CPU's ticks so far.
 */
control_flow_test_tick :: fn(kernel: ptr[Kernel], ticks: u64) {
    if ticks != CONTROL_FLOW_TEST_TICK {
        return void
    }
    on :: arch.kernel_control_flow()
    if kernel.options.test_tamper {
        if !on.signed_returns && !on.shadow_stack {
            runtime.log_info("test_tamper: skipped: the kernel has neither signed returns nor a shadow stack on this CPU")
        }
        else {
            runtime.log_info("test_tamper: returning through a tampered return address")
            call_unseen(cast[u64](tamper_with_return))
            runtime.log_error("test_tamper: the tampered return wasn't refused")
        }
    }
    if kernel.options.test_branch {
        if !on.landing_pads {
            runtime.log_info("test_branch: skipped: the kernel's indirect branches aren't checked for landing pads on this CPU")
        }
        else {
            runtime.log_info("test_branch: branching into the middle of a function")
            call_unseen(cast[u64](landing_target) + MIDDLE_OFFSET)
            runtime.log_error("test_branch: the branch wasn't refused")
        }
    }
    if kernel.options.test_shadow_write {
        if !on.shadow_stack {
            runtime.log_info("test_shadow_write: skipped: the kernel has no shadow stack on this CPU")
        }
        else {
            runtime.log_info("test_shadow_write: writing to the kernel's shadow stack")
            intrinsics.volatile_store_u64(cast[ptr[mut u64]](cast[rawptr](cast[uintptr](on.shadow_stack_pointer))), 0)
            runtime.log_error("test_shadow_write: the write wasn't refused")
        }
    }
}

/**
 * Call a function by its address, read back through memory, so the compiler can't see which it is and inline it.
 *
 * @param address The function's address, or one inside it; it takes nothing and gives nothing.
 */
call_unseen :: fn(address: u64) {
    kept := address
    unseen :: intrinsics.volatile_load_u64(&kept)
    cast[fn()](cast[rawptr](cast[uintptr](unseen)))()
}

/**
 * Change this function's own saved return address, where its frame keeps it, and return through it. On AArch64 a bit
 * of its pointer authentication code is flipped, so it fails to authenticate; on x86-64 the address is moved on by one,
 * which the shadow stack doesn't hold. Its return address is found with capture_stack_trace, and its saved copy by
 * looking up from a local for the word whose address bits match, in a frame record: after a frame pointer to a little
 * further up, its caller's, so a copy of the address among its locals isn't taken for it.
 */
tamper_with_return :: fn() {
    addresses : rawptr[1]
    if intrinsics.capture_stack_trace(addresses) == 0 {
        return void
    }
    target :: cast[u64](cast[uintptr](addresses[0])) & ADDRESS_BITS
    local : u64 = 0
    from :: cast[u64](cast[uintptr](&local))
    for i in cast[u64](1)..<TAMPERING_REACH {
        at :: from + i * 8
        slot :: cast[ptr[mut u64]](cast[rawptr](cast[uintptr](at)))
        value :: intrinsics.volatile_load_u64(slot)
        saved :: intrinsics.volatile_load_u64(cast[ptr[u64]](cast[rawptr](cast[uintptr](at - 8))))
        if value & ADDRESS_BITS == target && saved > at && saved - at < TAMPERING_FRAME_REACH {
            #if TARGET_ARCH == .arm64 {
                intrinsics.volatile_store_u64(slot, value ~ (cast[u64](1) << 53))
            }
            #else {
                intrinsics.volatile_store_u64(slot, value + 1)
            }
            return void
        }
    }
}

/** What test_branch branches into the middle of: a function that does a little, so it's more than its landing pad. */
landing_target :: fn() {
    count : u64 = 0
    for i in 0..<16 {
        count = intrinsics.volatile_load_u64(&count) + 1
    }
}
