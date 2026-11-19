/**
 * A std/ui window's test client (decisions/0192, 15g): started by the supervisor with test_gui on the kernel's command
 * line, it opens a window through gui_kit with a form as the greeter's, a name and a secret password, and logs what's
 * submitted, for boot.py to type into through the seat and the compositor, as it does the GUI's login:
 *
 * - "showing its window" once its first frame's submitted;
 * - "submitted <name>, <n> bytes of password" each time Enter's pressed in a field, the fields emptied after;
 * - "<n> frames" every 20 frames, so a stall shows as frames that stop.
 *
 * It runs until the system stops.
 */
package test_gui

import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import ui from "std:ui"
import gui_kit from "../../gui_kit"
import connector from "../../protocols/connector"
import service_kit from "../../libraries/service_kit"

/**
 * Show the window, and log what's submitted in its form.
 *
 * @param log The debug log its lines go to.
 * @param compositor A connector to the compositor.
 * @return 2 without the compositor, or when the window can't be made; 0 once the system's stopping or the window's
 *     closed.
 */
main :: fn(log : slop_os.DebugLog?, compositor : os.Channel[connector.Connector]?) -> int {
    window :: gui_kit.open(compositor or_return 2, "Typing", 360, 230) or_return 2
    name : u8[..]
    password : u8[..]
    frames := cast[u64](0)
    shown := false
    loop {
        if !gui_kit.take(window) || window.closing || service_kit.stopping() {
            return 0
        }
        if window.due {
            u :: gui_kit.begin(window)
            _ = ui.open(u, "body", ui.Box.{width = ui.grow(), height = ui.grow(), padding_x = 12, padding_y = 12, gap = 8})
            _ = ui.text_field(u, "Name", &name)
            _ = ui.text_field(u, "Password", &password, secret = true)
            ui.close(u)
            submitted := false
            for event in gui_kit.finish(window) {
                submitted = submitted || event.kind == .Submitted
            }
            frames += 1
            if !shown {
                shown = true
                runtime.log_info("showing its window")
            }
            if frames % 20 == 0 {
                runtime.log_info("% frames", frames)
            }
            if submitted {
                held :: name[0..<name.count]
                runtime.log_info("submitted %, % bytes of password", if held.count > 0 { string_of(&held[0], held.count) } else { "" },
                    password.count)
                runtime.array_reset(&name)
                runtime.array_reset(&password)
            }
        }
        gui_kit.wait(window, (slop_os.clock_monotonic() or_else 0) + 250_000_000)
    }
}
