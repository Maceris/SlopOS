package screen

import os from "std:os"
import slop_os from "std:os/slop_os"

/*
 * The firmware framebuffer handed over (decisions/0192, 15g): on a machine whose one screen is the framebuffer the
 * firmware left, the console's and the GUI's, the terminal service lends it to the framebuffer display, the
 * compositor's display there, while the seat's lent to the compositor, and takes it back, drawing the console again,
 * on the secure attention key. The terminal service sends the requests; the framebuffer display answers.
 *
 * While it's lent, the display copies what the compositor presents onto it, and draws the last frame whole when it's
 * lent again; while it isn't, the display draws nothing, and still answers the compositor, as a screen no one sees.
 */

/**
 * The screen protocol, for the channel between the terminal service and the framebuffer display: the terminal service
 * sends the requests, and the display answers them.
 */
Screen :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the framebuffer display, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "screen", major_version = 1, lending = .Server}

/** The framebuffer, lent. */
Lent :: struct {
    /** The framebuffer's pixels, a duplicate the display maps to draw on, readable and writable; it moves to it. */
    pixels : slop_os.Memory,
    /** The page of its layout (slop_os.FramebufferLayout): its width, height and pitch; it moves to the display. */
    layout : slop_os.Memory,
}

/** What the terminal service asks the framebuffer display. */
Request :: union {
    /**
     * Draw on the framebuffer from now on: the last frame presented, whole, then each frame's damage. Answered with
     * Done once the last frame's drawn, or Refused if the framebuffer couldn't be mapped, its handles then closed.
     */
    Lend(Lent),
    /**
     * Stop drawing on the framebuffer, and give it back: unmapped and its handles closed. Answered with Done once
     * nothing more will be drawn, so the terminal service draws the console after; also when it wasn't lent.
     */
    TakeBack,
}

/** What the framebuffer display answers. */
Response :: union {
    /** Lend's or TakeBack's answer: done. */
    Done,
    /** Lend's answer when the framebuffer couldn't be mapped or wasn't one the display could draw on. */
    Refused,
    /** The answer to a request the display doesn't know, as from a newer terminal service; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Lend, whose handles were given away; true for TakeBack.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Lend(_) => false
        case TakeBack => true
    }
}

#insert os.protocol_code(Request, Response)
