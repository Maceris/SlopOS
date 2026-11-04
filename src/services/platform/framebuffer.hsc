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

/** The first framebuffer, as the kernel's "FB  " table describes it, found once at the platform service's start. */
Framebuffer :: struct {
    /** The physical address of its pixels' first byte. */
    physical : u64,
    /** Its layout, copied from the table: its width, height and pitch, among the rest. */
    layout : slop_os.FramebufferLayout,
}

/**
 * Find the framebuffer the firmware tables' "FB  " table describes.
 *
 * @param tables Where the firmware tables' copy is mapped, readable, in the platform service's address space.
 * @param size The firmware tables' copy's size in bytes; a table running past it isn't taken.
 * @return The first "FB  " table's framebuffer, or null if the tables are too small or malformed, or have no "FB  "
 *     table big enough for a layout.
 */
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
 * Give a client the framebuffer: its pixels, and a page holding its layout, made anew each time it's asked, since
 * what it held may have died with the service it gave it to.
 *
 * The first client to claim it keeps it: only that client is given it again. Making the pixels' memory takes the
 * framebuffer from the kernel's console.
 *
 * @param to The debug log the platform service writes to, NO_HANDLE for none; a failure to make the pixels' memory is
 *     logged there, and so is the first claim.
 * @param platform The platform capability, which the pixels' memory is made with.
 * @param state The platform service's state: its framebuffer is read, and its framebuffer_claimed and
 *     framebuffer_claimer set.
 * @param client The asking client, by its index in the platform service's clients.
 * @return ClaimedFramebuffer with the pixels, write-combining device memory rounded up to whole pages, and a page
 *     holding a slop_os.FramebufferLayout, both moving to the client with the response; or NoDevice if there's no
 *     framebuffer, another client claimed it, or its memory couldn't be made or mapped.
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
