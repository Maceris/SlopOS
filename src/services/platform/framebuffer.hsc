package platform

import runtime from "base"
import slop_os from "std/os"
import protocol from "../../protocols/platform"
import pci from "../../pci"
import log_line from "../../log_line"

/*
 * The first framebuffer (decisions/0138), from the kernel's "FB  " table: given to the client that claims it, the
 * terminal service's supervisor, as its pixels, write-combining device memory, and a page holding its layout. Making
 * the pixels' memory takes the framebuffer from the kernel's console.
 */

Framebuffer :: struct {
    physical : u64,
    layout : slop_os.FramebufferLayout,
}

/** The framebuffer the firmware tables' "FB  " table describes, or null. */
find_framebuffer :: fn(tables: u64, size: u64) -> Framebuffer? {
    header :: cast[ptr[slop_os.FirmwareTables]](tables)
    if size < cast[u64](size_of(slop_os.FirmwareTables)) || header.magic != slop_os.FIRMWARE_MAGIC {
        return null
    }
    entries :: view_of(cast[ptr[slop_os.FirmwareTable]](tables + cast[u64](size_of(slop_os.FirmwareTables))), cast[usize](header.count))
    for &entry in entries {
        if pci.signature_of(entry) == "FB  " && entry.size >= cast[u32](size_of(slop_os.FramebufferLayout))
            && entry.offset + cast[u64](entry.size) <= size {
            return Framebuffer.{physical = entry.physical, layout = cast[ptr[slop_os.FramebufferLayout]](tables + entry.offset)^}
        }
    }
    return null
}

/**
 * The framebuffer for client, made anew each time it's asked, since what it held may have died with the service it gave
 * it to; NoDevice if there's none, or another client claimed it.
 */
claim_framebuffer :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], client: usize) -> protocol.Response {
    framebuffer :: state.framebuffer or_return .NoDevice
    if state.framebuffer_claimed && state.framebuffer_claimer != client {
        return .NoDevice
    }
    block :: slop_os.startup_block()
    layout :: framebuffer.layout
    bytes :: (cast[u64](layout.pitch) * cast[u64](layout.height) + PAGE - 1) & ~(PAGE - 1)
    pixels :: match slop_os.memory_create_physical(platform, block.budget, framebuffer.physical, bytes, .WriteCombining) {
        case Ok(made) => made
        case Error(error) => {
            log_line.write(to, "platform: the framebuffer at %{#018x} can't be given out: %", framebuffer.physical, error)
            return .NoDevice
        }
    }
    // Its layout, on a page made for the client, given to it with the pixels
    page :: slop_os.memory_create(block.budget, PAGE) or_return .NoDevice
    at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return .NoDevice
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(page, block.space, at, 0, PAGE, read_write) or_return .NoDevice
    cast[ptr[mut slop_os.FramebufferLayout]](at)^ = layout
    _ = slop_os.memory_unmap(block.space, at)
    if !state.framebuffer_claimed {
        log_line.write(to, "platform: the framebuffer (%x%) claimed", layout.width, layout.height)
    }
    state.framebuffer_claimed = true
    state.framebuffer_claimer = client
    return .ClaimedFramebuffer(protocol.Framebuffer.{pixels = pixels, layout = page})
}
