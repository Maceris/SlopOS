package limine_boot

/*
 * The parts of the kernel's ELF file L0 reads: its program headers, for the loaded segments.
 */
//SPEC: System V ABI, ELF-64 Object File Format (version 1.5), sections 3 (file header) and 6 (program header)

ElfHeader :: struct {
    identification : u8[16],
    kind : u16le,
    machine : u16le,
    version : u32le,
    entry : u64le,
    program_header_offset : u64le,
    section_header_offset : u64le,
    flags : u32le,
    header_size : u16le,
    program_header_size : u16le,
    program_header_count : u16le,
    section_header_size : u16le,
    section_header_count : u16le,
    section_names_index : u16le,
}

#assert size_of(ElfHeader) == 64

ProgramHeader :: struct {
    kind : u32le,
    flags : u32le,
    offset : u64le,
    virtual_address : u64le,
    physical_address : u64le,
    file_size : u64le,
    memory_size : u64le,
    alignment : u64le,
}

#assert size_of(ProgramHeader) == 56

// 0x7f, then "ELF"
ELF_MAGIC :: u8.[0x7f, 0x45, 0x4c, 0x46]
ELF_CLASS_64 : u8 : 2
ELF_DATA_LITTLE_ENDIAN : u8 : 1
PT_LOAD : u32 : 1
PF_X : u32 : 1
PF_W : u32 : 2

// Whether elf starts like a 64-bit little-endian ELF file with program headers of the expected size.
is_kernel_elf :: fn(elf: ptr[ElfHeader]) -> bool {
    for byte, i in ELF_MAGIC {
        if elf.identification[i] != byte {
            return false
        }
    }
    return elf.identification[4] == ELF_CLASS_64
        && elf.identification[5] == ELF_DATA_LITTLE_ENDIAN
        && cast[usize](elf.program_header_size) == size_of(ProgramHeader)
}

program_header :: fn(elf: ptr[ElfHeader], i: u64) -> ptr[ProgramHeader] {
    return cast[ptr[ProgramHeader]](cast[u64](elf) + cast[u64](elf.program_header_offset) + i * cast[u64](size_of(ProgramHeader)))
}

load_segment_count :: fn(elf: ptr[ElfHeader]) -> usize {
    count : usize = 0
    for i in 0..<cast[u64](elf.program_header_count) {
        if cast[u32](program_header(elf, i).kind) == PT_LOAD {
            count += 1
        }
    }
    return count
}

// The address the kernel was linked at: its lowest loaded segment's, rounded down to a page.
link_base :: fn(elf: ptr[ElfHeader]) -> u64 {
    lowest : u64 = 0xffffffffffffffff
    for i in 0..<cast[u64](elf.program_header_count) {
        header :: program_header(elf, i)
        if cast[u32](header.kind) == PT_LOAD && cast[u64](header.virtual_address) < lowest {
            lowest = cast[u64](header.virtual_address)
        }
    }
    return align_down(lowest)
}
