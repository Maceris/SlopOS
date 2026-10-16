package limine_boot

/*
 * The Limine boot protocol's requests and responses, base revision 6, as the bootloader lays
 * them out: native byte order, since the bootloader runs on the same CPU.
 *
 * Pointers the bootloader may leave null are optional (ptr[T]?, cstring?), which is a single
 * pointer, null for none (Hemera docs/types.md, Optional Types).
 */
//SPEC: Limine boot protocol, PROTOCOL.md and limine.h (limine-protocol repository, base revision 6)

// The first two words of every request's ID.
COMMON_MAGIC_0 :: 0xc7b1dd30df4c8b88
COMMON_MAGIC_1 :: 0x0a82e883a194f07b

// The base revision tag: [2] is set to 0 by a bootloader that supports the revision asked for.
BASE_REVISION_MAGIC_0 :: 0xf9562b2d5c95a6c8
BASE_REVISION_MAGIC_1 :: 0x6a7b384944536bdc
BASE_REVISION :: 6

REQUESTS_START_MARKER :: u64.[0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9]
REQUESTS_END_MARKER :: u64.[0xadc0e0531bb10d03, 0x9572709f31764c62]

// A request with no fields of its own, answered with a T.
Request :: struct[T] {
    id : u64[4],
    revision : u64,
    // Written by the bootloader, or left null if it doesn't support the request.
    response : ptr[T]?,
}

#assert size_of(Request[HhdmResponse]) == 48

Uuid :: struct {
    a : u32,
    b : u16,
    c : u16,
    d : u8[8],
}

// A file the bootloader loaded: the kernel itself, or a module.
File :: struct {
    revision : u64,
    // In the direct map.
    address : ptr[u8],
    size : u64,
    path : cstring?,
    // The module's command line, from the boot configuration.
    string : cstring?,
    media_type : u32,
    unused : u32,
    tftp_ipv4 : u8[4],
    tftp_port : u32,
    partition_index : u32,
    mbr_disk_id : u32,
    gpt_disk_uuid : Uuid,
    gpt_part_uuid : Uuid,
    part_uuid : Uuid,
}

#assert size_of(File) == 112

// Bootloader info

BootloaderInfoResponse :: struct {
    revision : u64,
    name : cstring?,
    version : cstring?,
}

// Executable command line

ExecutableCommandLineResponse :: struct {
    revision : u64,
    command_line : cstring?,
}

// Firmware type

FIRMWARE_X86_BIOS :: 0
FIRMWARE_EFI32 :: 1
FIRMWARE_EFI64 :: 2
FIRMWARE_SBI :: 3

FirmwareTypeResponse :: struct {
    revision : u64,
    firmware_type : u64,
}

// Stack size

StackSizeResponse :: struct {
    revision : u64,
}

StackSizeRequest :: struct {
    id : u64[4],
    revision : u64,
    response : ptr[StackSizeResponse]?,
    stack_size : u64,
}

// Higher-half direct map

HhdmResponse :: struct {
    revision : u64,
    offset : u64,
}

// Framebuffer

FRAMEBUFFER_RGB :: 1

LimineFramebuffer :: struct {
    // In the direct map.
    address : u64,
    width : u64,
    height : u64,
    pitch : u64,
    bits_per_pixel : u16,
    memory_model : u8,
    red_mask_size : u8,
    red_mask_shift : u8,
    green_mask_size : u8,
    green_mask_shift : u8,
    blue_mask_size : u8,
    blue_mask_shift : u8,
    unused : u8[7],
    edid_size : u64,
    edid : ptr[u8]?,
    // Response revision 1
    mode_count : u64,
    modes : rawptr,
}

#assert size_of(LimineFramebuffer) == 80

FramebufferResponse :: struct {
    revision : u64,
    framebuffer_count : u64,
    framebuffers : ptr[ptr[LimineFramebuffer]]?,
}

// Paging mode

PAGING_MODE_X86_64_4_LEVEL :: 0
PAGING_MODE_AARCH64_4_LEVEL :: 0
PAGING_MODE_RISCV_SV48 :: 1

PagingModeResponse :: struct {
    revision : u64,
    mode : u64,
}

PagingModeRequest :: struct {
    id : u64[4],
    revision : u64,
    response : ptr[PagingModeResponse]?,
    mode : u64,
    max_mode : u64,
    min_mode : u64,
}

// Multiprocessor

MP_REQUEST_X86_64_X2APIC :: 1
MP_RESPONSE_X86_64_X2APIC :: 1

// One CPU, as x86-64 describes it.
MpInfo :: struct {
    processor_id : u32,
    lapic_id : u32,
    reserved : u64,
    // An atomic write here starts the parked CPU there, with this MpInfo's address in rdi.
    goto_address : u64,
    extra_argument : u64,
}

#assert size_of(MpInfo) == 32

MpResponse :: struct {
    revision : u64,
    flags : u32,
    bsp_lapic_id : u32,
    cpu_count : u64,
    cpus : ptr[ptr[MpInfo]]?,
}

MpRequest :: struct {
    id : u64[4],
    revision : u64,
    response : ptr[MpResponse]?,
    flags : u64,
}

// Memory map

MEMORY_USABLE :: 0
MEMORY_RESERVED :: 1
MEMORY_ACPI_RECLAIMABLE :: 2
MEMORY_ACPI_NVS :: 3
MEMORY_BAD_MEMORY :: 4
MEMORY_BOOTLOADER_RECLAIMABLE :: 5
MEMORY_EXECUTABLE_AND_MODULES :: 6
MEMORY_FRAMEBUFFER :: 7
MEMORY_RESERVED_MAPPED :: 8

MemoryMapEntry :: struct {
    base : u64,
    length : u64,
    kind : u64,
}

MemoryMapResponse :: struct {
    revision : u64,
    entry_count : u64,
    entries : ptr[ptr[MemoryMapEntry]]?,
}

// Executable file

ExecutableFileResponse :: struct {
    revision : u64,
    executable_file : ptr[File],
}

// Modules

ModuleResponse :: struct {
    revision : u64,
    module_count : u64,
    modules : ptr[ptr[File]]?,
}

// Firmware tables, each in the direct map, or null when the firmware has none

AddressResponse :: struct {
    revision : u64,
    address : rawptr,
}

SmbiosResponse :: struct {
    revision : u64,
    entry_32 : rawptr,
    entry_64 : rawptr,
}

// Date at boot

DateAtBootResponse :: struct {
    revision : u64,
    timestamp : i64,
}

// Executable address

ExecutableAddressResponse :: struct {
    revision : u64,
    physical_base : u64,
    virtual_base : u64,
}

// TSC frequency (x86-64)

TscFrequencyResponse :: struct {
    revision : u64,
    frequency : u64,
}

// Entropy

EntropyResponse :: struct {
    revision : u64,
    value_count : u64,
    values : ptr[u64]?,
}

EntropyRequest :: struct {
    id : u64[4],
    revision : u64,
    response : ptr[EntropyResponse]?,
    value_count : u64,
}

// The pointers in one of Limine's lists, or none when the list is missing.
pointers :: fn[T](list: ptr[ptr[T]]?, count: u64) -> ptr[T][] {
    empty : ptr[T][]
    first :: list or_return empty
    return view_of(first, cast[usize](count))
}
