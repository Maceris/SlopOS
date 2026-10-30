/*
 * The system configuration as data (roadmap 9c3, decisions/0107, 0110): system_config's services, serialized by the
 * build into the boot set as system.records, which the root task checks at boot with check, the code the build checks
 * them with, and gives the supervisor and the scheduler service, which read their services from it rather than linking
 * system_config. Each service's entry is a manifest of its parameters: each one's name, its kind and its protocol's tag,
 * enough for the wiring check (every channel served).
 *
 * An override, SystemOverrides, changes services' tunables, their memory budgets, CPU shares, restart policies and DMA
 * trust, and nothing else: it's kept in the config store, owner "system", name "services", and applied by the supervisor
 * with apply, which checks the result with check too.
 *
 * Everything here is fixed-size plain data, flags and enums as bytes, so a copy's bytes are checked before they're
 * trusted, by check, wherever they came from.
 */
package system_records

MAGIC : u64 : 0x31535953504f4c53
MAX_SERVICES :: 32
MAX_PARAMETERS :: 256
MAX_SERVED :: 8
NAME_BYTES :: 32
// The most an override tunes at once, so it fits the config store's values
MAX_TUNED :: 16
// The largest memory budget a service is given
MAX_BUDGET : u64 : 1024 * 1024 * 1024

// Who starts a service, as system_config.Starter
STARTER_ROOT_TASK : u8 : 0
STARTER_SUPERVISOR : u8 : 1
STARTER_STORAGE_MANAGER : u8 : 2

// What a parameter of an entry is
KIND_OTHER : u8 : 0
KIND_CHANNEL : u8 : 1
KIND_LISTENER : u8 : 2
// A Config[T], a channel to the config store's values
KIND_CONFIG : u8 : 3

// What serves a protocol without taking a listener for it in its entry
SERVED_BY_ROOT_TASK : u8 : 0
SERVED_BY_SUPERVISOR : u8 : 1
SERVED_BY_STORAGE_MANAGER : u8 : 2

// A CPU share, as system_config.CpuShare, present if has is 1.
CpuRecord :: struct {
    has : u32,
    priority : u32,
    period_ns : u64,
    time_ns : u64,
    cpus : u64,
}

// A service, as system_config.Service, its entry as parameters[first_parameter..<first_parameter + parameter_count].
ServiceRecord :: struct {
    name : u8[NAME_BYTES],
    module : u8[NAME_BYTES],
    budget : u64,
    cpu : CpuRecord,
    vendor : u16,
    device : u16,
    class : u32,
    starter : u8,
    by_manager : u8,
    trusted_with_dma : u8,
    boot_set : u8,
    not_restarted : u8,
    padding : u8[3],
    first_parameter : u32,
    parameter_count : u32,
}

ParameterRecord :: struct {
    name : u8[NAME_BYTES],
    // Its protocol's tag, for a channel, a listener or a Config; 0 otherwise
    tag : u64,
    kind : u8,
    optional : u8,
    padding : u8[6],
}

SystemRecords :: struct {
    magic : u64,
    service_count : u32,
    parameter_count : u32,
    served_count : u32,
    padding : u32,
    // The CPU share of every service without one of its own, as system_config.DEFAULT_CPU
    default_cpu : CpuRecord,
    // Protocols served by the root task, the supervisor or the storage manager themselves: their tags, and by which
    served : u64[MAX_SERVED],
    served_by : u8[MAX_SERVED],
    services : ServiceRecord[MAX_SERVICES],
    parameters : ParameterRecord[MAX_PARAMETERS],
}

// What an override can change about a service
TUNE_BUDGET : u32 : 1
TUNE_CPU : u32 : 2
TUNE_RESTART : u32 : 4
TUNE_DMA : u32 : 8

// A service's tunables an override sets: those set names, the rest are the service's own.
Tunables :: struct {
    name : u8[NAME_BYTES],
    set : u32,
    not_restarted : u8,
    trusted_with_dma : u8,
    padding : u8[2],
    budget : u64,
    cpu : CpuRecord,
}

// The system configuration's override, the config store's value "services" of owner "system".
SystemOverrides :: struct {
    count : u32,
    tuned : Tunables[MAX_TUNED],
}

// Why records, or an override, were refused: what, and the service it's about, or MAX_SERVICES for none.
Problem :: struct {
    reason : string,
    service : u32,
}

/*
 * Whether records are a system configuration: counts within their arrays, every service named and with a module, a
 * starter, a budget within MAX_BUDGET and a CPU share within its period, its parameters within the parameters and
 * well formed, no two services of one name, a driver started by the supervisor; and every channel, and every Config,
 * a service takes, served by a service's listener or by what serves its protocol itself.
 */
check :: fn(records: ptr[SystemRecords]) -> Problem? {
    if records.magic != MAGIC {
        return Problem.{reason = "isn't system records", service = MAX_SERVICES}
    }
    if records.service_count > MAX_SERVICES || records.parameter_count > MAX_PARAMETERS || records.served_count > MAX_SERVED {
        return Problem.{reason = "has more than there's room for", service = MAX_SERVICES}
    }
    if records.default_cpu.has != 1 || !cpu_holds(records.default_cpu) {
        return Problem.{reason = "has no default CPU share within its period", service = MAX_SERVICES}
    }
    for i in cast[usize](0)..<records.served.count {
        if i < cast[usize](records.served_count) && i < records.served_by.count && records.served_by[i] > SERVED_BY_STORAGE_MANAGER {
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
            || service.not_restarted > 1 {
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
        }
    }
    return null
}

// Whether a CPU share is one: none, or time within a period that isn't 0, on CPUs of a 64-bit mask.
cpu_holds :: fn(cpu: CpuRecord) -> bool {
    if cpu.has > 1 {
        return false
    }
    return cpu.has == 0 || (cpu.period_ns != 0 && cpu.time_ns != 0 && cpu.time_ns <= cpu.period_ns)
}

// Whether some service takes a listener for tag, or the root task, the supervisor or the storage manager serves it.
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

/*
 * records with an override's tunables applied, checked as check checks records: why not, if the override names a
 * service records don't have, sets something it can't, or leaves them something check refuses. records are changed
 * only if it's taken.
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

// The index of the service named name, or MAX_SERVICES.
index_of :: fn(records: ptr[SystemRecords], name: string) -> usize {
    for i in cast[usize](0)..<records.services.count {
        if i < cast[usize](records.service_count) && text_of(&records.services[i].name) == name {
            return i
        }
    }
    return MAX_SERVICES
}

// The service named name, or null.
service_of :: fn(records: ptr[SystemRecords], name: string) -> ptr[ServiceRecord]? {
    at :: index_of(records, name)
    if at >= records.services.count {
        return null
    }
    return &records.services[at]
}

// A service's parameters, its entry's, in records that check took.
parameters_of :: fn(records: ptr[SystemRecords], service: ptr[ServiceRecord]) -> ParameterRecord[] {
    first :: cast[usize](service.first_parameter)
    count :: cast[usize](service.parameter_count)
    if first >= records.parameters.count || count > records.parameters.count - first || count == 0 {
        return view_of(&records.parameters[0], 0)
    }
    return view_of(&records.parameters[first], count)
}

// Whether a service is a driver, with devices it takes.
is_driver :: fn(service: ptr[ServiceRecord]) -> bool {
    return service.vendor != 0 || service.device != 0 || service.class != 0
}

// A name's text: its bytes up to the first zero.
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

// A name's bytes from text, zeros after it: false if it doesn't fit, with room for its zero.
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

// Whether a name is letters, digits and underscores, and dots in a module's, ended by a zero, and some.
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

// A protocol's tag, from its own name, as std/os's end_tag works it out: FNV-1a, 64-bit.
tag_of :: fn(protocol: string) -> u64 {
    hash : u64 = 0xcbf29ce484222325
    for character in protocol {
        hash = (hash ~ cast[u64](cast[u8](character))) * 0x100000001b3
    }
    return hash
}
