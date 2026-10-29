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

IoPortRange :: struct #align(16) {
    header : ObjectHeader,
    first : u32,
    count : u32,
}

IoPortError :: enum {
    OutOfMemory,
    OwnerGone,
    BudgetExceeded,
    InvalidArgument,
}

// The ports first to first + count - 1, owned by owner and charged to budget.
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

// The port at offset in the range, if it and the width's bytes after it are in it.
port_at :: fn(ports: ptr[IoPortRange], offset: u32, width: u32) -> u16? {
    if (width != 1 && width != 2 && width != 4) || cast[u64](offset) + cast[u64](width) > cast[u64](ports.count) {
        return null
    }
    return cast[u16](ports.first + offset)
}

destroy_io_port_range :: fn(kernel: ptr[mut Kernel], ports: ptr[mut IoPortRange]) {
}

release_io_port_range :: fn(kernel: ptr[mut Kernel], ports: ptr[mut IoPortRange]) {
}
