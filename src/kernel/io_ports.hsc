package kernel

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Ranges of I/O ports as kernel objects (roadmap 9a, decisions/0093): made with the platform capability, as device
 * memory is, and given to what drives what's behind them, like the clock service the RTC's. Every read and write is a
 * system call on the range, checked against it; where the architecture has no ports, none can be made.
 */

/**
 * A range of I/O ports, a kernel object: the right to read and write the ports from first to first + count - 1.
 *
 * It holds nothing but the range; the ports aren't reserved, so two ranges may overlap.
 */
IoPortRange :: struct #align(16) {
    /** The object's header; first, as for every kernel object. */
    header : ObjectHeader,
    /** The range's first port number, below 0x10000. */
    first : u32,
    /** How many ports the range holds, at least 1; first + count is at most 0x10000. */
    count : u32,
}

/** Why a range of I/O ports couldn't be made. */
IoPortError :: enum {
    /** The pool of ranges couldn't get memory for another. */
    OutOfMemory,
    /** The process that would own it is being destroyed. */
    OwnerGone,
    /** The memory budget paying for it hasn't room for it, or is closed. */
    BudgetExceeded,
    /** A count of 0, a range past port 0xffff, or an architecture without I/O ports. */
    InvalidArgument,
}

/**
 * Make a range of I/O ports, an object owned by a process.
 *
 * @param kernel The kernel, whose pool of ranges the object comes from.
 * @param owner The Process to own the range, as its address, or 0 for the kernel itself.
 * @param budget The MemoryBudget the object's memory is charged to, as its address, or 0 for the kernel's own.
 * @param first The range's first port number.
 * @param count How many ports, from 1 to 0x10000 - first.
 * @return The range, owned by owner and charged to budget; the caller makes a handle to it.
 * @error InvalidArgument count was 0, the range went past port 0xffff, or the architecture has no I/O ports.
 * @error OutOfMemory No memory could be had for the object.
 * @error BudgetExceeded budget hadn't room for the object, or is closed.
 * @error OwnerGone owner is being destroyed; the range made for it is destroyed again.
 */
create_io_ports :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, first: u32, count: u32) -> Result[ptr[mut IoPortRange], IoPortError] {
    if !arch.has_io_ports() || count == 0 || cast[u64](first) + cast[u64](count) > 0x10000 {
        return .Error(.InvalidArgument)
    }
    object := cast[u64](0)
    match new_object(kernel, .IoPortRange, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { IoPortError.BudgetExceeded } else { IoPortError.OutOfMemory })
    }
    ports :: cast[ptr[mut IoPortRange]](object)
    ports.first = first
    ports.count = count
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.OwnerGone)
        }
    }
    return .Ok(ports)
}

/**
 * Find the port a read or write at an offset in a range goes to, checking it's all in the range.
 *
 * @param ports The range, which isn't changed.
 * @param offset The port's offset from the range's first, in ports.
 * @param width How many bytes are read or written: 1, 2 or 4, so ports offset to offset + width - 1 are touched.
 * @return The port number, or null for another width, or when the ports touched aren't all in the range.
 */
port_at :: fn(ports: ptr[IoPortRange], offset: u32, width: u32) -> u16? {
    if (width != 1 && width != 2 && width != 4) || cast[u64](offset) + cast[u64](width) > cast[u64](ports.count) {
        return null
    }
    return cast[u16](ports.first + offset)
}

/**
 * Destroy a range of I/O ports, as destroy_object does each kind: it holds nothing to let go of, so this does nothing.
 *
 * @param kernel Unused: the range holds nothing of the kernel's.
 * @param ports The range being destroyed.
 */
destroy_io_port_range :: fn(kernel: ptr[mut Kernel], ports: ptr[mut IoPortRange]) {
}

/**
 * Release a destroyed range of I/O ports' memory, as release_object does each kind once no CPU can still use it:
 * a range holds nothing besides itself, so this does nothing; release_object frees the object.
 *
 * @param kernel Unused: the range holds nothing of the kernel's.
 * @param ports The destroyed range, whose memory release_object frees after this.
 */
release_io_port_range :: fn(kernel: ptr[mut Kernel], ports: ptr[mut IoPortRange]) {
}
