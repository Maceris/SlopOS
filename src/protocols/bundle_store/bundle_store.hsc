package bundle_store

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import bundle from "../../bundle"

/*
 * The bundle store's protocol (roadmap 9b, decisions/0094, design/software.md §2): objects by their BLAKE3-256 hashes.
 * Get gives an object as paged memory, read-only, which the store pages in as it's touched, one memory object per
 * object however many ask for it; Put takes one from memory given, kept only if its bytes have the hash given. Roots
 * keep objects, and what bundles and roots they are refer to, from Collect, which removes everything else: the boot
 * root, and pins by name. Connections arrive on its listener, and as Connects. The pages it has supplied are a cache
 * it gives back under pressure on its budget (decisions/0111): CacheLimit sets how much of them it keeps, and
 * Evictions says how many it's given back.
 */

/**
 * The bundle store protocol, for the channels between the bundle store and its clients, and its listener: the clients
 * send the requests, and the bundle store answers them.
 */
BundleStore :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the bundle store, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "bundle_store", major_version = 1, lending = .Server}

/** An object to put: its hash, and the memory holding its bytes. */
PutOf :: struct {
    /** The object's BLAKE3-256 hash, which its bytes have to have, or it's Refused. */
    hash : bundle.Hash,
    /** How many bytes it has: the first size bytes of data's, which has to hold that many. */
    size : u64,
    /** The memory holding its bytes, which moves to the store, and is closed there whatever happens. */
    data : slop_os.Memory,
}

/** A pin: a name that keeps an object, and what it's kept by, from Collect. */
PinOf :: struct {
    /** The pin's name, 1 to 32 bytes, each a lowercase ASCII letter, a digit or an underscore. */
    name : slop_os.Relative[u8],
    /** The hash of the object it keeps, and so what that object refers to. */
    hash : bundle.Hash,
}

/** An object: read-only paged memory, and how many of its bytes are the object's. */
Object :: struct {
    /**
     * The object's memory, paged in by the store as it's touched, read-only and executable, whole pages; the handle
     * moves to the client, and the memory object is the same one however many ask for it.
     */
    memory : slop_os.Memory,
    /** How many bytes from memory's start are the object's. */
    size : u64,
}

/** What a client asks the bundle store. */
Request :: union {
    /** Ask for an object, by its hash. Answered with Got, or Missing. */
    Get(bundle.Hash),
    /**
     * Put an object, kept only if its bytes have the hash given, written whole before it's in the store. Answered
     * with Done, kept now or before, or Refused.
     */
    Put(PutOf),
    /** Pin an object under a name, replacing a pin of that name. Answered with Done, or Refused. */
    Pin(PinOf),
    /** Take a pin away, by its name, as UTF-8. Answered with Done, or Missing when there's no such pin. */
    Unpin(slop_os.Relative[u8]),
    /** Set the boot root's hash; the root object itself is put first. Answered with Done, or Refused without it. */
    SetRoot(bundle.Hash),
    /** Ask for the boot root's hash. Answered with Rooted, or Missing when none is set. */
    Root,
    /** Remove everything no root reaches, the boot root's or a pin's. Answered with Collected. */
    Collect,
    /**
     * Have the store serve another client, on the end given, which moves to it; it's closed if the store already has
     * as many clients as it takes. Answered with nothing.
     */
    Connect(os.Channel[BundleStore]),
    /**
     * Have the store use this connection to its directory from now on, the same one served again, as when its volume
     * server was started again; the end moves to the store. Answered with Done, or Refused when it couldn't be used,
     * the connection before kept.
     */
    UseDirectory(os.Channel[dir.Dir]),
    /**
     * Set the most bytes of objects' pages the store keeps in memory from now on, giving back what's past it now; 0
     * for as much as its budget's threshold allows. Answered with Done.
     */
    CacheLimit(u64),
    /**
     * Ask how many pages the store has given back in all, under pressure or past its limit. Answered with Collected.
     */
    Evictions,
}

/** What the bundle store answers. */
Response :: union {
    /** Get's answer: the object, whose memory handle moves to the client. */
    Got(Object),
    /** The answer when what was asked is done. */
    Done,
    /** Root's answer: the boot root's hash. */
    Rooted(bundle.Hash),
    /** Collect's answer, how many objects it removed; or Evictions', how many pages the store has given back. */
    Collected(u64),
    /** The answer when there's no object, pin or root by that, or the object couldn't be opened. */
    Missing,
    /**
     * The answer for bytes that don't have the hash given, a name that isn't one, a root not put, or what the store
     * couldn't write or use.
     */
    Refused,
    /** The answer to a request the store doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: putting, pinning or collecting again changes nothing more.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

/**
 * Send a request to the bundle store and wait for its answer.
 *
 * Responses that aren't one, unknown or invalid, are skipped while it waits.
 *
 * @param end A connection to the bundle store, kept by the caller.
 * @param port A port bound to end, waited on for the answer and while end's ring is full.
 * @param out The request, begun with os.begin; sent as it is, any handles in it moving to the store.
 * @param into Where the answer is received, with any handles it brought, which are the caller's from then on.
 * @return The answer, copied out of into; Unsupported if the request couldn't be sent or the connection's gone.
 */
ask :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> Response {
    if send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match receive_response(end, port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
    return os.message_of[Response](into)^
}
