# 0132: B1, Hemera's UEFI Target, as Built

Status: accepted
Date: 2026-10-31
Related: `0131` (B's plan), Hemera's `docs/compilation.md` (*UEFI Applications*) and `docs/directives.md`

## Context
`0131`, with the owner: Hemera gains `OS == .UEFI`, `base`'s runtime on the boot services, PE32+ EFI applications on
x86-64 and AArch64, so the bootloader is ordinary Hemera. The compiler already knew the OS's name, mapped it to LLVM's
`uefi` triple and to PE/COFF, and linked PE/COFF through `lld-link` for Windows.

## Decision
- **The entry**: for `OS == .UEFI` the compiler's entry takes the image's handle and the system table, in UEFI's
  convention (LLVM's C convention for the `uefi` triple, Microsoft's on x86-64), keeps both in the process state, and
  ends the program with `main`'s result through `base`'s `os_exit_process`. It's linked with `/subsystem:efi_application`
  and nothing else, under the name it's given.
- **`base`'s runtime** (`runtime/uefi.hsc`): the context's allocator is the boot services' pool (aligned, zeroed, any
  alignment); output goes to the console as UTF-16, lines ended with a carriage return; the end is `Exit`, with
  `EFI_SUCCESS` for 0 and `EFI_ABORTED` otherwise. No threads, clock or random numbers yet.
- **`std/os/uefi`**: the firmware's tables beyond what `base` uses, so far the runtime services and `ResetSystem`
  (`uefi.reset(.Shutdown)`); the bootloader adds the protocols it needs (B2).
- **Function types with a calling convention** (with the owner): the firmware is reached only through the pointers in
  its tables, so a function type written on its own takes the directives a declaration puts after its name,
  `#calling_convention(...)` among them, as in `fn(this: rawptr, text: ptr[u16]) -> usize #calling_convention(.c)
  #no_context`. Function types already carried their convention; only the grammar lacked it.
- **Windows' code on UEFI**: on x86-64 a frame over a page calls `__chkstk`, which the compiler defines as it does for
  Windows; on AArch64 Windows' code gets SEH unwind information, which Hemera's prologue, with its stack check, doesn't
  fit, so no UEFI function has any (nothing of Hemera's unwinds through an exception).
- **SlopOS's build** makes every folder of `src/uefi` a UEFI application, `<name>.efi`, for the programs'
  architecture. **`boot.py --efi=<name>`** boots one by itself, as the firmware's default boot file on a FAT drive,
  counts turning the machine off as exit 0, and checks its lines with the console's escape sequences taken out.
- **Tests**: `uefi_hello`, on both architectures, adds up a thousand numbers in memory from the pool, says so through
  `base`'s logger, and turns the machine off; Hemera's own tests, its `std` resolved for the host as ever.

## Alternatives considered
- **A `cfn` type, or an intrinsic call through a `rawptr`** for foreign function pointers (put to the owner): a second
  way to write a type the language already has, or calls unchecked against any type.

## Consequences
- B2 writes the bootloader as a UEFI application in `src/uefi`, with the file system, loaded image and memory map
  protocols added to `std/os/uefi`.
