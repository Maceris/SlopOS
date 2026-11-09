/**
 * The system configuration as data (roadmap 9c3, decisions/0107, 0110): system_config's services, serialized by the
 * build into the boot set as system.records, which the root task checks at boot with check, the code the build checks
 * them with, and gives the supervisor and the scheduler service, which read their services from it rather than linking
 * system_config. Each service's entry is a manifest of its parameters: each one's name, its kind and its protocol's
 * tag, enough for the wiring check (every channel served).
 *
 * An override, SystemOverrides, changes services' tunables, their memory budgets, CPU shares, restart policies and DMA
 * trust, and nothing else: it's kept in the config store, owner "system", name "services", and applied by the
 * supervisor with apply, which checks the result with check too.
 *
 * Everything here is fixed-size plain data, flags and enums as bytes, so a copy's bytes are checked before they're
 * trusted, by check, wherever they came from.
 *
 * Dependencies (roadmap 9d2, decisions/0113, 0115): a channel parameter is required, or optional if its type is, and a
 * service is late if the system needn't have it to be healthy. A required channel's server can't be late unless what
 * requires it is too. Each service has a deadline to be up by, its own or the configuration's default.
 */
package system_records

/** What system records start with, "SLOPSYS1" as little-endian bytes; records without it aren't system records. */
MAGIC : u64 : 0x31535953504f4c53
/** The most services records hold: 32. */
MAX_SERVICES :: 32
/** The most parameters records hold, every service's together: 256. */
MAX_PARAMETERS :: 256
/** The most protocols records say a starter serves itself: 8. */
MAX_SERVED :: 8
/** The bytes of a name's place, its zero included, so a name has at most 31 bytes. */
NAME_BYTES :: 32
/** The most an override tunes at once, so it fits the config store's values. */
MAX_TUNED :: 16
/** The largest memory budget a service is given, in bytes: 1 GiB. */
MAX_BUDGET : u64 : 1024 * 1024 * 1024

// ---- Who starts a service, as system_config.Starter

/** The root task starts it. */
STARTER_ROOT_TASK : u8 : 0
/** The supervisor starts it. */
STARTER_SUPERVISOR : u8 : 1
/** The storage manager starts it. */
STARTER_STORAGE_MANAGER : u8 : 2

// ---- What a parameter of an entry is

/** Anything but a channel, a listener or a Config, like a debug log. */
KIND_OTHER : u8 : 0
/** An os.Channel[P]: a connection to a server of P, which something has to serve. */
KIND_CHANNEL : u8 : 1
/** An os.Listener[P]: the service serves P. */
KIND_LISTENER : u8 : 2
/** A Config[T], a channel to the config store's values. */
KIND_CONFIG : u8 : 3

// ---- What serves a protocol without taking a listener for it in its entry

/** The root task serves it. */
SERVED_BY_ROOT_TASK : u8 : 0
/** The supervisor serves it. */
SERVED_BY_SUPERVISOR : u8 : 1
/** The storage manager serves it. */
SERVED_BY_STORAGE_MANAGER : u8 : 2
/** The session manager serves it, through the powerbox it starts in each session. */
SERVED_BY_SESSION_MANAGER : u8 : 3

/** A CPU share, as system_config.CpuShare, present if has is 1. */
CpuRecord :: struct {
    /** 1 if there's a share, 0 for none, when the default's used; anything else doesn't check. */
    has : u32,
    /** Its priority while it has time; higher runs first. */
    priority : u32,
    /** Its period, in nanoseconds; not 0 when there's a share. */
    period_ns : u64,
    /** Its time each period, in nanoseconds: 1 to period_ns when there's a share. */
    time_ns : u64,
    /** The CPUs its threads run on, a bit per CPU's index; 0 for every CPU. */
    cpus : u64,
}

/**
 * A service, as system_config.Service, its entry as parameters[first_parameter..<first_parameter + parameter_count].
 */
ServiceRecord :: struct {
    /** Its name, letters, digits and underscores, ended by zeros. */
    name : u8[NAME_BYTES],
    /** The module it's started from, as its name, dots allowed too. */
    module : u8[NAME_BYTES],
    /** Its memory budget, in bytes: 1 to MAX_BUDGET. */
    budget : u64,
    /** Its own CPU share, or none for the default. */
    cpu : CpuRecord,
    /** A driver's devices' PCI vendor ID, platform.ANY_ID for any; 0 for a service that isn't a driver. */
    vendor : u16,
    /** A driver's devices' PCI device ID, platform.ANY_ID for any; 0 for a service that isn't a driver. */
    device : u16,
    /** A driver's devices' class, the class register's top 24 bits, platform.ANY_CLASS for any; 0 for a non-driver. */
    class : u32,
    /** Who starts it, a STARTER_ value; a driver's has to be STARTER_SUPERVISOR. */
    starter : u8,
    /** 1 if its starter asks the process manager to load it, 0 if it loads it itself. */
    by_manager : u8,
    /** For a driver, 1 if it's trusted with DMA where no IOMMU confines its device, 0 if not. */
    trusted_with_dma : u8,
    /** 1 if it's in the boot set, loaded by the bootloader as a module, 0 if it's loaded from the system volume. */
    boot_set : u8,
    /** 1 if its starter leaves it ended when it fails, rather than starting it again, 0 if not. */
    not_restarted : u8,
    /** 1 if the system is healthy without it (decisions/0115), 0 if not. */
    late : u8,
    /** Zeros, to align what follows. */
    padding : u8[2],
    /** How long it has to be up, from boot, in milliseconds; 0 for the configuration's default. */
    deadline_ms : u32,
    /** Its entry's first parameter's index in the records' parameters. */
    first_parameter : u32,
    /** How many parameters its entry has, all within the records' parameter_count. */
    parameter_count : u32,
    /** Zeros, to align what follows. */
    padding_more : u32,
    /**
     * The bytes of records the events service keeps of it (decisions/0185, 12g); 0 for the events service's default
     * for the system's services.
     */
    events_budget : u64,
}

/** A parameter of a service's entry: its name, what it is, and its protocol's tag. */
ParameterRecord :: struct {
    /** The parameter's name, the grant it's given, letters, digits and underscores, ended by zeros. */
    name : u8[NAME_BYTES],
    /** Its protocol's channel end tag (os.end_tag), for a channel, a listener or a Config; 0 otherwise. */
    tag : u64,
    /** What it is, a KIND_ value. */
    kind : u8,
    /** 1 if it's optional, so the service starts without it, 0 if it's required. */
    optional : u8,
    /** Zeros, to align what follows. */
    padding : u8[6],
}

/** The system configuration as data, as the build writes it into the boot set as system.records. */
SystemRecords :: struct {
    /** MAGIC, or the records aren't system records; the build makes it 0 for a configuration that doesn't fit. */
    magic : u64,
    /** How many of services are used, from the first: 0 to MAX_SERVICES. */
    service_count : u32,
    /** How many of parameters are used, from the first: 0 to MAX_PARAMETERS. */
    parameter_count : u32,
    /** How many of served and served_by are used, from the first: 0 to MAX_SERVED. */
    served_count : u32,
    /** A service's deadline to be up by, in milliseconds, unless it has its own. */
    default_deadline_ms : u32,
    /** The CPU share of every service without one of its own, as system_config.DEFAULT_CPU; it has to be there. */
    default_cpu : CpuRecord,
    /**
     * The tags of protocols the root task, the supervisor, the storage manager or the session manager serve themselves.
     */
    served : u64[MAX_SERVED],
    /** Which of them serves each of served, a SERVED_BY_ value. */
    served_by : u8[MAX_SERVED],
    /** The services, in the order they start. */
    services : ServiceRecord[MAX_SERVICES],
    /** Every service's parameters, each service's together, in its entry's order. */
    parameters : ParameterRecord[MAX_PARAMETERS],
    /**
     * The system's installations as the build made them (decisions/0117), which the config store's override replaces.
     */
    installations : Installations,
}

// ---- What an override can change about a service, a bit each in Tunables' set

/** The override sets the service's memory budget. */
TUNE_BUDGET : u32 : 1
/** The override sets the service's CPU share. */
TUNE_CPU : u32 : 2
/** The override sets whether the service is restarted. */
TUNE_RESTART : u32 : 4
/** The override sets whether the driver is trusted with DMA. */
TUNE_DMA : u32 : 8

/** A service's tunables an override sets: those set names, the rest are the service's own. */
Tunables :: struct {
    /** The service's name, as its record has it. */
    name : u8[NAME_BYTES],
    /** Which tunables are set, TUNE_ bits or'd; any other bit refuses the override. */
    set : u32,
    /** With TUNE_RESTART, the service's not_restarted, 1 or 0. */
    not_restarted : u8,
    /** With TUNE_DMA, the driver's trusted_with_dma, 1 or 0. */
    trusted_with_dma : u8,
    /** Zeros, to align what follows. */
    padding : u8[2],
    /** With TUNE_BUDGET, the service's memory budget, in bytes: 1 to MAX_BUDGET. */
    budget : u64,
    /** With TUNE_CPU, the service's CPU share, or none for the default. */
    cpu : CpuRecord,
}

/** The most installations the system has: 8. */
MAX_INSTALLATIONS :: 8

/**
 * An installation (roadmap 9d4, decisions/0113, 0117): its name, which names its data directory and its configuration's
 * owner; the program it runs, a bundle the bundle store's boot root names; and the bundle it runs instead, by hash, all
 * zeros to run the one the root names.
 */
InstallationRecord :: struct {
    /** Its name, letters, digits and underscores, ended by zeros, unique among the installations. */
    name : u8[NAME_BYTES],
    /** The program it runs, as a name, the bundle's in the boot root. */
    program : u8[NAME_BYTES],
    /** The bundle it runs instead, by its hash; all zeros to run the one the root names. */
    bundle : u8[32],
}

/**
 * The system's installations: the build's, in the records, and as the config store's value "installations" of owner
 * "system".
 */
Installations :: struct {
    /** How many of entries are used, from the first: 0 to MAX_INSTALLATIONS. */
    count : u32,
    /**
     * 1 once it's been written: the config store's default, all zeros, is no list at all, and the build's stands.
     */
    set : u32,
    /** The installations, the first count of them. */
    entries : InstallationRecord[MAX_INSTALLATIONS],
}

/**
 * Check that installations are well formed: within their array, named and with programs, no two of one name.
 *
 * @param installations The installations, as records or the config store hold them.
 * @return Null if they're well formed; otherwise what's wrong, as a phrase following "the configuration", static text.
 */
installations_check :: fn(installations: ptr[Installations]) -> string? {
    if installations.count > MAX_INSTALLATIONS {
        return "has more installations than there's room for"
    }
    for i in cast[usize](0)..<installations.entries.count {
        if i >= cast[usize](installations.count) {
            break
        }
        entry :: &installations.entries[i]
        if !valid_name(&entry.name, false) || !valid_name(&entry.program, false) {
            return "has an installation without a name or a program"
        }
        for j in cast[usize](0)..<i {
            if j < installations.entries.count && text_of(&installations.entries[j].name) == text_of(&entry.name) {
                return "has two installations of one name"
            }
        }
    }
    return null
}

/** The system configuration's override, the config store's value "services" of owner "system". */
SystemOverrides :: struct {
    /** How many of tuned are used, from the first: 0 to MAX_TUNED. */
    count : u32,
    /** The services tuned, each by its name, the first count of them. */
    tuned : Tunables[MAX_TUNED],
}

/** Why records, or an override, were refused: what, and the service it's about, or MAX_SERVICES for none. */
Problem :: struct {
    /** What's wrong, a phrase following the service's name or "the configuration", static text. */
    reason : string,
    /** The index of the service it's about, in the records' services; MAX_SERVICES for none. */
    service : u32,
}

/**
 * Check that records are a system configuration, before they're trusted, wherever they came from.
 *
 * They have to have MAGIC, counts within their arrays, well-formed installations and a default CPU share; every
 * service named and with a module, a starter, flags that are 0 or 1, a budget within MAX_BUDGET and a CPU share within
 * its period, its parameters within the parameters and well formed, no two services of one name, a driver started by
 * the supervisor; and every channel, and every Config, a service takes, served by a service's listener or by what
 * serves its protocol itself, a required channel of a service that isn't late not served only by late ones.
 *
 * @param records The records, which aren't changed.
 * @return Null if they check; otherwise the first problem found, with the service it's about.
 */
check :: fn(records: ptr[SystemRecords]) -> Problem? {
    if records.magic != MAGIC {
        return Problem.{reason = "isn't system records", service = MAX_SERVICES}
    }
    if records.service_count > MAX_SERVICES || records.parameter_count > MAX_PARAMETERS || records.served_count > MAX_SERVED {
        return Problem.{reason = "has more than there's room for", service = MAX_SERVICES}
    }
    match installations_check(&records.installations) {
        case Some(reason) => return Problem.{reason = reason, service = MAX_SERVICES}
        case None => {}
    }
    if records.default_cpu.has != 1 || !cpu_holds(records.default_cpu) {
        return Problem.{reason = "has no default CPU share within its period", service = MAX_SERVICES}
    }
    for i in cast[usize](0)..<records.served.count {
        if i < cast[usize](records.served_count) && i < records.served_by.count && records.served_by[i] > SERVED_BY_SESSION_MANAGER {
            return Problem.{reason = "has a protocol served by nothing it knows", service = MAX_SERVICES}
        }
    }
    for i in cast[usize](0)..<records.parameters.count {
        if i >= cast[usize](records.parameter_count) {
            break
        }
        parameter :: &records.parameters[i]
        if !valid_name(&parameter.name, false) || parameter.kind > KIND_CONFIG || parameter.optional > 1 {
            return Problem.{reason = "has a parameter that isn't one", service = MAX_SERVICES}
        }
    }
    for i in cast[usize](0)..<records.services.count {
        if i >= cast[usize](records.service_count) {
            break
        }
        service :: &records.services[i]
        at :: cast[u32](i)
        if !valid_name(&service.name, false) {
            return Problem.{reason = "has a service without a name", service = at}
        }
        if !valid_name(&service.module, true) {
            return Problem.{reason = "has a service without a module", service = at}
        }
        for j in cast[usize](0)..<i {
            if j < records.services.count && text_of(&records.services[j].name) == text_of(&service.name) {
                return Problem.{reason = "has two services of one name", service = at}
            }
        }
        if service.starter > STARTER_STORAGE_MANAGER || service.by_manager > 1 || service.trusted_with_dma > 1 || service.boot_set > 1
            || service.not_restarted > 1 || service.late > 1 {
            return Problem.{reason = "has a service with a flag that isn't one", service = at}
        }
        if service.budget == 0 || service.budget > MAX_BUDGET {
            return Problem.{reason = "has a service whose budget isn't within MAX_BUDGET", service = at}
        }
        if !cpu_holds(service.cpu) {
            return Problem.{reason = "has a service whose CPU share isn't within its period", service = at}
        }
        if is_driver(service) && service.starter != STARTER_SUPERVISOR {
            return Problem.{reason = "has a driver the supervisor doesn't start", service = at}
        }
        if cast[u64](service.first_parameter) + cast[u64](service.parameter_count) > cast[u64](records.parameter_count) {
            return Problem.{reason = "has a service whose parameters aren't there", service = at}
        }
        for parameter in parameters_of(records, service) {
            if (parameter.kind == KIND_CHANNEL || parameter.kind == KIND_CONFIG) && !served(records, parameter.tag) {
                return Problem.{reason = "has a channel no service serves", service = at}
            }
            // What the system needs can't require what it doesn't
            if parameter.kind == KIND_CHANNEL && parameter.optional == 0 && service.late == 0 && served_only_late(records, parameter.tag) {
                return Problem.{reason = "requires a channel only a late service serves", service = at}
            }
        }
    }
    return null
}

/**
 * Tell whether a CPU share is one: none, or time within a period that isn't 0.
 *
 * @param cpu The share, as a record or an override has it.
 * @return True if has is 0, or has is 1 with a period that isn't 0 and a time from 1 to it.
 */
cpu_holds :: fn(cpu: CpuRecord) -> bool {
    if cpu.has > 1 {
        return false
    }
    return cpu.has == 0 || (cpu.period_ns != 0 && cpu.time_ns != 0 && cpu.time_ns <= cpu.period_ns)
}

/**
 * Tell whether a protocol is served: some service takes a listener for it, or a starter serves it itself.
 *
 * @param records The records, whose served protocols and parameters are looked through.
 * @param tag The protocol's channel end tag.
 * @return True if it's served.
 */
served :: fn(records: ptr[SystemRecords], tag: u64) -> bool {
    for i in cast[usize](0)..<records.served.count {
        if i < cast[usize](records.served_count) && records.served[i] == tag {
            return true
        }
    }
    for i in cast[usize](0)..<records.parameters.count {
        if i < cast[usize](records.parameter_count) && records.parameters[i].kind == KIND_LISTENER && records.parameters[i].tag == tag {
            return true
        }
    }
    return false
}

/**
 * Tell whether only late services serve a protocol: no service that isn't late takes a listener for it, nor does a
 * starter serve it itself.
 *
 * @param records The records, whose served protocols and services' listeners are looked through.
 * @param tag The protocol's channel end tag.
 * @return True if some late service serves it and nothing else does; false if something else does, or nothing does.
 */
served_only_late :: fn(records: ptr[SystemRecords], tag: u64) -> bool {
    for i in cast[usize](0)..<records.served.count {
        if i < cast[usize](records.served_count) && records.served[i] == tag {
            return false
        }
    }
    late_server := false
    for i in cast[usize](0)..<records.services.count {
        if i >= cast[usize](records.service_count) {
            break
        }
        service :: &records.services[i]
        for parameter in parameters_of(records, service) {
            if parameter.kind == KIND_LISTENER && parameter.tag == tag {
                if service.late == 0 {
                    return false
                }
                late_server = true
            }
        }
    }
    return late_server
}

/**
 * Give a service's deadline to be up by, from boot.
 *
 * @param records The records, for their default deadline.
 * @param service The service, one of records'.
 * @return Its deadline in nanoseconds: its own, or the configuration's default when it has none.
 */
deadline_of :: fn(records: ptr[SystemRecords], service: ptr[ServiceRecord]) -> u64 {
    milliseconds :: if service.deadline_ms != 0 { service.deadline_ms } else { records.default_deadline_ms }
    return cast[u64](milliseconds) * 1_000_000
}

/**
 * Apply an override's tunables to records, and check the result as check checks records.
 *
 * @param records The records, changed only if the override is taken.
 * @param overrides The override, from the config store.
 * @return Null once it's taken; otherwise why not: it tunes more than MAX_TUNED, names a service records don't have,
 *     sets something it can't, or leaves them something check refuses.
 */
apply :: fn(records: ptr[mut SystemRecords], overrides: ptr[SystemOverrides]) -> Problem? {
    if overrides.count > MAX_TUNED {
        return Problem.{reason = "tunes more than MAX_TUNED", service = MAX_SERVICES}
    }
    changed := records^
    for i in cast[usize](0)..<overrides.tuned.count {
        if i >= cast[usize](overrides.count) {
            break
        }
        tuned :: &overrides.tuned[i]
        if tuned.set > (TUNE_BUDGET | TUNE_CPU | TUNE_RESTART | TUNE_DMA) {
            return Problem.{reason = "tunes something it can't", service = MAX_SERVICES}
        }
        at :: index_of(&changed, text_of(&tuned.name))
        if at >= changed.services.count {
            return Problem.{reason = "tunes a service there isn't", service = MAX_SERVICES}
        }
        service :: &changed.services[at]
        if tuned.set & TUNE_BUDGET != 0 {
            service.budget = tuned.budget
        }
        if tuned.set & TUNE_CPU != 0 {
            service.cpu = tuned.cpu
        }
        if tuned.set & TUNE_RESTART != 0 {
            service.not_restarted = tuned.not_restarted
        }
        if tuned.set & TUNE_DMA != 0 {
            service.trusted_with_dma = tuned.trusted_with_dma
        }
    }
    match check(&changed) {
        case Some(problem) => return problem
        case None => {}
    }
    records^ = changed
    return null
}

/**
 * Find a service's index by its name.
 *
 * @param records The records, their first service_count services looked through.
 * @param name The service's name, compared exactly.
 * @return Its index in services; MAX_SERVICES if there's none of that name.
 */
index_of :: fn(records: ptr[SystemRecords], name: string) -> usize {
    for i in cast[usize](0)..<records.services.count {
        if i < cast[usize](records.service_count) && text_of(&records.services[i].name) == name {
            return i
        }
    }
    return MAX_SERVICES
}

/**
 * Find a service by its name.
 *
 * @param records The records, their first service_count services looked through.
 * @param name The service's name, compared exactly.
 * @return The service's record, in records; null if there's none of that name.
 */
service_of :: fn(records: ptr[SystemRecords], name: string) -> ptr[ServiceRecord]? {
    at :: index_of(records, name)
    if at >= records.services.count {
        return null
    }
    return &records.services[at]
}

/**
 * Give a service's parameters, its entry's, in records that check took.
 *
 * @param records The records, which the parameters are in.
 * @param service The service, one of records'.
 * @return Its parameters, a view into records; empty if it has none, or they aren't within the parameters.
 */
parameters_of :: fn(records: ptr[SystemRecords], service: ptr[ServiceRecord]) -> ParameterRecord[] {
    first :: cast[usize](service.first_parameter)
    count :: cast[usize](service.parameter_count)
    if first >= records.parameters.count || count > records.parameters.count - first || count == 0 {
        return view_of(&records.parameters[0], 0)
    }
    return view_of(&records.parameters[first], count)
}

/**
 * Tell whether a service is a driver, with devices it takes.
 *
 * @param service A service's record, only read; just its vendor, device and class are looked at.
 * @return True if any of its vendor, device and class isn't 0.
 */
is_driver :: fn(service: ptr[ServiceRecord]) -> bool {
    return service.vendor != 0 || service.device != 0 || service.class != 0
}

/**
 * Give a name's text.
 *
 * @param name A name field, as a record holds it; only read, and not checked to be well formed (valid_name does that).
 * @return Its bytes up to the first zero, all of them without one: a view into name, good while it is.
 */
text_of :: fn(name: ptr[u8[NAME_BYTES]]) -> string {
    count := cast[usize](0)
    for byte in name^ {
        if byte == 0 {
            break
        }
        count += 1
    }
    return string_of(&name^[0], count)
}

/**
 * Set a name's bytes from text, zeros after it.
 *
 * @param name The name's place, every byte of which is written.
 * @param text The name, at most NAME_BYTES - 1 bytes, so a zero ends it.
 * @return True if it fits; false, the place all zeros, if it doesn't.
 */
set_name :: fn(name: ptr[mut u8[NAME_BYTES]], text: string) -> bool {
    for i in cast[usize](0)..<name.count {
        name^[i] = 0
    }
    if text.count >= NAME_BYTES {
        return false
    }
    at := cast[usize](0)
    for character in text {
        if at < name.count {
            name^[at] = cast[u8](character)
            at += 1
        }
    }
    return true
}

/**
 * Tell whether a name is well formed: 1 or more ASCII letters, digits and underscores, and dots in a module's, ended
 * by a zero, every byte after it a zero.
 *
 * @param name A name field, as a record holds it; only read, every one of its NAME_BYTES.
 * @param module Whether it's a module's name, which may have dots.
 * @return True if it's well formed.
 */
valid_name :: fn(name: ptr[u8[NAME_BYTES]], module: bool) -> bool {
    ended := false
    count := cast[usize](0)
    for byte in name^ {
        if ended {
            if byte != 0 {
                return false
            }
            continue
        }
        if byte == 0 {
            ended = true
            continue
        }
        letter :: (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
        if !letter && !(module && byte == 46) {
            return false
        }
        count += 1
    }
    return ended && count != 0
}

/**
 * Work out a protocol's tag from its own name, as std/os's end_tag does: FNV-1a, 64-bit.
 *
 * @param protocol The name of the protocol's type, P in os.Channel[P], without its package, its bytes hashed.
 * @return The tag, as os.end_tag gives a Channel[P]'s.
 */
tag_of :: fn(protocol: string) -> u64 {
    hash : u64 = 0xcbf29ce484222325
    for character in protocol {
        hash = (hash ~ cast[u64](cast[u8](character))) * 0x100000001b3
    }
    return hash
}
