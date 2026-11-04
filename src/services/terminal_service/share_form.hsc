/**
 * Shared volumes (decisions/0158), on the trusted path: H on the secure attention key's screen opens this form, for the
 * session's user, the volume's owner. They type a shared volume's name, made the first time, and another user's:
 * Enter shares it with them, Delete takes them out of it, which revokes every link into it and starts its next key
 * generation. The account service does it (Share, Unshare) and answers with a grant of the volume's root, which is
 * linked here as shared/<name> in the owner's home; a member's link is made when they next log in. Escape goes back.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import terminal from "std/os/slop_os"
import dir from "std/os/slop_os"
import grant from "std/os/slop_os"
import account_records from "../../account_records"
import accounts from "../../protocols/accounts"
import screen from "../../screen"

/** The status line's text while the share form is up. */
STATUS_SHARING :: " SlopOS │ console │ sharing a volume"
/** The USB HID usage of the H key, which opens the share form from the secure attention key's screen. */
USAGE_H : u16 : 0x0b

/**
 * Open the share form over the active view, for its session's user, the owner of the volumes it shares.
 *
 * It does nothing without the account service, without a connection to the session's home, or when no user is logged
 * in to the view. Otherwise the secure attention key's screen is left for it, the form asks for the volume's name, and
 * every key goes to setup_key until it's closed.
 *
 * @param service The service, its secure attention key's screen up.
 */
enter_share_form :: fn(service: ptr[mut Service]) {
    if service.accounts_end == NONE || view(service).home_end == NONE || !view(service).logged_in || view(service).user_count == 0 {
        return void
    }
    service.attention = false
    service.sharing = true
    service.share_name_count = 0
    runtime.log_info("sharing a volume")
    say(service, "")
    setup_step(service, .ShareName)
    update_status(service)
}

/**
 * Close the share form: zero the field being typed, put setup back to Off, and draw the session again from the screen
 * model.
 *
 * @param service The service, its share form up.
 */
end_share_form :: fn(service: ptr[mut Service]) {
    service.sharing = false
    service.setup = .Off
    wipe(service.field[0..<service.field.count])
    service.field_count = 0
    update_status(service)
    screen.show_panel(&view(service).screen, false)
    redraw(service)
}

/**
 * Ask the account service to share the volume named with the member typed, or to take them out of it, without waiting
 * for its answer.
 *
 * The request (Share or Unshare) names the view's user as the owner, the volume's name taken at the first step, and the
 * member's name in the field. Nothing is sent while the member's field is empty. If it can't be sent, it says so and
 * asks for the member again; otherwise the form waits at the Sharing step, where keys are ignored, for take_accounts to
 * hand the answer to shared or say why it was refused.
 *
 * @param service The service, its share form at the member's step.
 * @param unshare Whether to take the member out of the volume (Delete), which revokes every link into it, rather than
 *     share it with them (Enter).
 */
send_share :: fn(service: ptr[mut Service], unshare: bool) {
    member :: field_bytes(service)
    if member.count == 0 || service.share_name_count > service.share_name.count {
        return void
    }
    owner :: first_of(view(service).user[0..<view(service).user.count], view(service).user_count)
    out := os.Outgoing.{}
    request :: os.begin[accounts.Request](&out)
    asked :: accounts.ShareOf.{owner = os.append(&out, owner), name = os.append(&out, first_of(service.share_name[0..<service.share_name.count], service.share_name_count)),
        member = os.append(&out, member)}
    request^ = if unshare { accounts.Request.Unshare(asked) } else { accounts.Request.Share(asked) }
    if accounts.send_request(service.accounts_end, service.port, &out) != null {
        say(service, "The account service isn't there.")
        setup_step(service, .ShareMember)
        return void
    }
    service.unsharing = unshare
    say(service, if unshare { "Taking them out of it." } else { "Sharing it." })
    setup_step(service, .Sharing)
}

/**
 * Take the account service's Shared answer: link the volume's root as shared/<name> in the owner's home, in place of
 * any link there, and close the form.
 *
 * On the view's home connection it makes the shared directory if it's missing, removes whatever is at shared/<name>,
 * and links the grant there, each request waited for. A failed step is only logged; the form closes either way.
 *
 * @param service The service, its share form at the Sharing step.
 * @param given The grant of the volume's root, which moves here: it goes to the home in the Link request, or is closed
 *     if the home can't be reached.
 */
shared :: fn(service: ptr[mut Service], given: os.Channel[grant.Grant]) {
    home :: view(service).home_end
    name :: first_of(service.share_name[0..<service.share_name.count], service.share_name_count)
    linked := false
    port :: os.port_for(slop_os.startup_block().budget, home) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](port) != slop_os.NO_HANDLE {
        storage : u8[PATH_BYTES]
        count : usize = 0
        add_part(&storage, &count, string_bytes("shared/"))
        add_part(&storage, &count, name)
        path :: first_of(storage[0..<storage.count], count)
        out := os.Outgoing.{}
        making :: os.begin[dir.Request](&out)
        making^ = .OpenDirectory(dir.OpenDirectory.{path = os.append(&out, string_bytes("shared")), create = true})
        into := os.Incoming.{}
        match ask_home(home, port, &out, &into) {
            case OpenedDirectory(made) => _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
            case _ => {}
        }
        out = os.Outgoing.{}
        removing :: os.begin[dir.Request](&out)
        removing^ = .Remove(os.append(&out, path))
        _ = ask_home(home, port, &out, &into)
        out = os.Outgoing.{}
        linking :: os.begin[dir.Request](&out)
        linking^ = .Link(dir.LinkTo.{path = os.append(&out, path), grant = given})
        match ask_home(home, port, &out, &into) {
            case Done => linked = true
            case _ => {}
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](port))
    }
    else {
        _ = slop_os.handle_close(cast[slop_os.Handle](given.end))
    }
    runtime.log_info("% %, % shared/% in the owner's home", if service.unsharing { "took a member out of" } else { "shared" }, bytes_text(name),
        if linked { "linked" } else { "couldn't link" }, bytes_text(name))
    end_share_form(service)
}

/**
 * Take Enter on the share form: at the volume's step, keep the name and ask for the member; at the member's, send the
 * share.
 *
 * A volume's name has to be valid as an account's name is (account_records.valid_name); one that isn't is refused with
 * a message, and asked for again.
 *
 * @param service The service, its share form up.
 */
share_enter :: fn(service: ptr[mut Service]) {
    typed :: field_bytes(service)
    if service.setup == .ShareName {
        if !account_records.valid_name(typed) {
            say(service, "A volume's name is 1 to 32 letters, digits, - or _, and starts with a lowercase letter.")
            setup_step(service, .ShareName)
            return void
        }
        service.share_name_count = copy_bytes(typed, service.share_name[0..<service.share_name.count])
        say(service, "")
        setup_step(service, .ShareMember)
    }
    else if service.setup == .ShareMember {
        send_share(service, false)
    }
}

/**
 * Draw the share form on the active view's panel: the volume's name, the member's, what it last said, and its keys,
 * with the cursor at the end of the field being typed.
 *
 * @param service The service, its share form up.
 * @param whole Whether to show the panel and draw every row of it; false clears and draws only the rows of the fields
 *     and the message, which is all a key changes.
 */
draw_share_form :: fn(service: ptr[mut Service], whole: bool) {
    panel :: &view(service).screen.panel
    rows : u16 = 7
    if whole {
        screen.show_panel(&view(service).screen, true)
    }
    else {
        screen.clear(panel, terminal.Area.{row = SETUP_FIELDS_ROW, columns = COLUMNS, rows = rows})
    }
    plain :: terminal.Style.{}
    screen.write_at(panel, 1, 2, "Share a volume", terminal.Style.{attributes = terminal.BOLD})
    screen.write_at(panel, 3, 2, "A volume of yours, made the first time you name it, shared with another user, who", plain)
    screen.write_at(panel, 4, 2, "finds it in shared/ in their home once they next log in.", plain)
    top :: SETUP_FIELDS_ROW
    column : u16 = 13
    screen.write_at(panel, top, 2, "Volume:", plain)
    screen.write_at(panel, top + 1, 2, "Member:", plain)
    typed :: field_bytes(service)
    name :: first_of(service.share_name[0..<service.share_name.count], service.share_name_count)
    screen.write_at(panel, top, column, bytes_text(if service.setup == .ShareName { typed } else { name }), plain)
    if service.setup == .ShareMember {
        screen.write_at(panel, top + 1, column, bytes_text(typed), plain)
    }
    if service.message_count > 0 && service.message_count <= service.message.count {
        screen.write_at(panel, top + 3, 2, string_of(&service.message[0], service.message_count), plain)
    }
    screen.write_at(panel, top + 5, 2, "Enter shares it with them, Delete takes them out of it, Esc goes back.", plain)
    panel.row = if service.setup == .ShareName { top } else { top + 1 }
    panel.column = column + cast[u16](min_count(typed.count, 40))
    if whole {
        redraw(service)
    }
    else {
        redraw_rows(service, SETUP_FIELDS_ROW, SETUP_FIELDS_ROW + rows)
    }
}
