package limine_boot

/*
 * The requests the kernel makes (docs/specs/boot_info.md, Requests). Limine finds them by scanning
 * the image between the start and end markers, and writes each response pointer into its
 * request before entering the kernel, so they're #externally_initialized: read from memory, never
 * folded, and kept even though nothing refers to the markers.
 *
 * The kernel's linker script places the three sections in this order, in a loaded segment.
 *
 * Each ID is the common magic followed by the request's own two words.
 */
//HEMERA(gap): calling a function in a constant's initializer crashes the compiler (no compile-time
//execution yet), so every header is written out instead of built by a function

REQUESTS_START #externally_initialized #section(".limine_requests_start") : u64[4] : REQUESTS_START_MARKER

BASE_REVISION_TAG #externally_initialized #section(".limine_requests") : u64[3] : u64.[
    BASE_REVISION_MAGIC_0, BASE_REVISION_MAGIC_1, BASE_REVISION,
]

// Required

MEMORY_MAP_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62], revision = 0, response = null},
}

HHDM_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b], revision = 0, response = null},
}

EXECUTABLE_ADDRESS_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x71ba76863cc55f63, 0xb2644a48c516a487], revision = 0, response = null},
}

EXECUTABLE_FILE_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69], revision = 0, response = null},
}

// x2APIC mode where the CPUs support it
MP_REQUEST #externally_initialized #section(".limine_requests") : MpRequest : MpRequest.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x95a67b819a1b857e, 0xa0b61b723b6a73e0], revision = 0, response = null},
    flags = MP_REQUEST_X86_64_X2APIC,
}

MODULE_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x3e7e279702be32af, 0xca1c4f3bd1280cee], revision = 0, response = null},
}

// 4-level paging, and nothing else (Sv48 on RISC-V)
PAGING_MODE_REQUEST #externally_initialized #section(".limine_requests") : PagingModeRequest : PagingModeRequest.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a], revision = 0, response = null},
    mode = PAGING_MODE_X86_64_4_LEVEL,
    max_mode = PAGING_MODE_X86_64_4_LEVEL,
    min_mode = PAGING_MODE_X86_64_4_LEVEL,
}

// Every CPU's boot stack
BOOT_STACK_SIZE :: 64 * 1024

STACK_SIZE_REQUEST #externally_initialized #section(".limine_requests") : StackSizeRequest : StackSizeRequest.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d], revision = 0, response = null},
    stack_size = BOOT_STACK_SIZE,
}

// Optional

BOOTLOADER_INFO_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0xf55038d8e2a1202f, 0x279426fcf5f59740], revision = 0, response = null},
}

FIRMWARE_TYPE_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x8c2f75d90bef28a8, 0x7045a4688eac00c3], revision = 0, response = null},
}

EXECUTABLE_COMMAND_LINE_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x4b161536e598651e, 0xb390ad4a2f1f303a], revision = 0, response = null},
}

FRAMEBUFFER_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b], revision = 0, response = null},
}

RSDP_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0xc5e77b6b397e7b43, 0x27637845accdcf3c], revision = 0, response = null},
}

DEVICE_TREE_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0xb40ddb48fb54bac7, 0x545081493f81ffb7], revision = 0, response = null},
}

SMBIOS_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x9e9046f11e095391, 0xaa4a520fefbde5ee], revision = 0, response = null},
}

EFI_SYSTEM_TABLE_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x5ceba5163eaaf6d6, 0x0a6981610cf65fcc], revision = 0, response = null},
}

// BootInfo.bootloader_entropy is 32 bytes
ENTROPY_VALUES :: 4

ENTROPY_REQUEST #externally_initialized #section(".limine_requests") : EntropyRequest : EntropyRequest.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x65ea80255d5682c5, 0x9117240723f493eb], revision = 0, response = null},
    value_count = ENTROPY_VALUES,
}

TSC_FREQUENCY_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x10f2ee1d87d195e4, 0xf747a2b78f6ddb31], revision = 0, response = null},
}

DATE_AT_BOOT_REQUEST #externally_initialized #section(".limine_requests") : Request : Request.{
    header = RequestHeader.{id = u64.[COMMON_MAGIC_0, COMMON_MAGIC_1, 0x502746e184c088aa, 0xfbc5ec83e6327893], revision = 0, response = null},
}

REQUESTS_END #externally_initialized #section(".limine_requests_end") : u64[2] : REQUESTS_END_MARKER

// Whether the bootloader acknowledged BASE_REVISION, by clearing the tag's last word.
base_revision_supported :: fn() -> bool {
    return BASE_REVISION_TAG[2] == 0
}

// A request's response, or null if the bootloader didn't answer it.
response_of :: fn(header: ptr[RequestHeader]) -> rawptr {
    return header.response
}
