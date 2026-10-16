# 0033: Package Structure

Status: accepted
Date: 2026-10-13
Related: `0002` (layers), `0025` (ABI package), `0028` (build package), `0029` (checks), `0030`
(Hemera's `std`), `0031`, `0032`

## Context
`0025` and `0028` left the locations of the ABI package and the build package to be decided with
the package structure, and the layers document only sketched a layout. M0 code needs real
locations.

The ABI package has to be imported by Hemera `std`'s `OS == .SlopOS` code. Hemera's `std` can't
import from the SlopOS repository, since it must build without it. Some service protocols are spoken
by `std` too (the clock for `time.now()`, entropy, storage for files).

## Decision
- **The ABI package is `slop_os`, in Hemera's `std/os/slop_os/`** (freestanding tier), imported as
  `import slop_os from "std/os"`, like Zig's `std.os.linux`. This is the one piece of
  SlopOS-specific code in Hemera's `std` besides its `OS == .SlopOS` branches, and it is allowed
  for the same reason (`0030`).
- **Service protocols `std` speaks** are packages in subfolders of it (`std/os/slop_os/clock/`,
  and so on). Every other protocol lives in SlopOS's `src/protocols/`.
- Hemera's imports take paths below built-in locations (`from "std/os"`) to make this possible
  (Hemera `docs/packages.md`, *Imports*).
- **`src/` layout:** one folder per package, the folder named like its `package` statement:

  ```
  src/
    build/                  build package (0028)
    build_settings/         setting names shared by the build and its consumers (0028)
    checks/                 house-rule checks (0029)
    boot/limine/            L0: package limine_boot (0031)
    boot_info/              BootInfo (0031)
    arch_interface/         the --- declarations (0032)
    arch/x86_64/            L1: package arch_x86_64 (later arch_aarch64, arch_riscv64)
    kernel/                 L2: package kernel
    kernel/entry/           package kernel_entry (0032)
    platform/               L3 platform service
    drivers/<device>/       one package per driver: virtio_block, ps2, ...
    protocols/<class>/      one package per protocol: block, net, input, ...
    services/<name>/        L4: root_task, process_manager, supervisor, ...
    apps/<name>/            L6
  ```

- **Naming:** folders and packages are `snake_case`. Architecture packages are prefixed `arch_`,
  since they import Hemera's `intrinsics.x86_64` as `x86_64`; the kernel imports the selected one
  as `arch`. Drivers are named after the device, protocols after the device class, services after
  their role.
- **Tests:** a package's tests are a separate package in its `test/` subfolder, with
  `PROGRAM_KIND :: .Test`, found by the build package's discovery: a `test` subfolder, loaded
  with `compiler.load_package` (`0028`).
- **Kernel frame size:** the kernel target sets Hemera's `TargetOptions.max_frame_size`, a compile
  error for any larger frame. The limit is chosen once M1 code shows real frame sizes (probably
  about 1 KiB, on a 16 KiB kernel stack). It's a compiler option rather than a house-rule check,
  because checks run after type checking and frame sizes only exist after code generation.

## Alternatives considered
- **The ABI package in `src/` next to `protocols/`:** keeps SlopOS code out of Hemera, but then
  Hemera's `std` couldn't implement `OS == .SlopOS` without depending on this repository.
- **One `protocols` package for every protocol:** simpler imports, but every driver would import
  every protocol, and the dependency graph would say nothing about which driver speaks what.
- **`import slop_os from "std" in "os"`** for subfolders: reads well, but splits one path in two,
  and `in` already means something in `for` loops.

## Consequences
- `0025`'s and `0028`'s open locations are settled; the *Scope* open question is closed.
- Adding a protocol that `std` speaks means a change in the Hemera repository.
- The layers document's build-shape sketch (`../design/layers.md`) is superseded by this layout.
