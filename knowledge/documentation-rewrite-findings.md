# Possible Bugs Found While Rewriting the Documentation

The documentation rewrite (`decisions/0174`, November 2026) read every declaration in SlopOS and in Hemera's `base` and
`std` against its code. Where the code didn't do what the old comments said, or did something questionable, the new
documentation describes what the code does, and the code was left alone. These are those findings. Each was
confirmed against the code before it was fixed; what each became is marked on it.

## Serious: memory safety, security, or data loss

- **Kernel, x86-64 `paging.hsc` `unmap`**: never checks the address with `may_map`, so unmapping a kernel-half address
  through a user address space would edit the shared kernel tables.
  *Fixed, on both architectures, with a paging test.*
- **Kernel, `devices.hsc` `create_device`**: the duplicate-device loop dereferences null when `first_device` is 0.
  *Fixed.*
- **Kernel, `channels.hsc`**: the header says a space's lock is never held with a channel core's, but `channel_write`,
  `channel_read` and `channel_take_handles` take it (through user copies) while holding the core's. A lock-order
  problem, or an out-of-date note.
  *An out-of-date note: the lock ranks allow it (a channel core's is below a space's). The note is corrected.*
- **Kernel, `timers.hsc` `cancel_timer`**: reads the entry's CPU and index before taking the heap lock.
  *Fixed: it checks under the lock, and follows an entry armed again elsewhere.*
- **Kernel, `kernel_entry.hsc` `nmi`**: logs through the console spin lock, which can deadlock on the CPU holding it.
  *Fixed: it only counts.*
- **Kernel, `translation.hsc` `refill_iommu_tables`**: returns true when a charge fails partway, so `map_dma_memory` and
  `map_doorbell` may loop forever.
  *Fixed.*
- **Kernel, `user_memory.hsc` / `paging.hsc`**: `copy_user` and `supply_page` reach pages through the direct map, which is
  wrong for device memory.
  *Fixed for pages past RAM and memory that isn't write-back; write-back device memory inside a hole in RAM can't be
  told apart, which only the platform could make.*
- **Kernel, `memory_budgets.hsc`**: `limit - used` wraps if `used` exceeds `limit`, which a rollback in `move_charges` allows.
  *Fixed.*
- **Kernel, `ports.hsc`**: `finish_or_block` loses packets when the copy-out fails; `is_user_writable` checks only page
  tables, so an untouched mapped page fails with BadBuffer.
  *Fixed: the kernel's user copies bring an untouched page in, so a good buffer no longer fails.*
- **AArch64, `its.hsc`**: `add_msi_device` sizes each device's table for 32 events but doesn't cap MAPD, so a device with
  more lets the ITS use memory past its table; `route_msi`/`move_msi` record a route for a CPU the LPI doesn't go to.
  *Fixed. Lower risk than it read, as MAX_DEVICE_MSIS is 32; events are capped at the table's size anyway, and a CPU
  with no collection gets no route.*
- **AArch64, `gic.hsc`**: `end_of_interrupt` does nothing if no route matches, leaving the interrupt active.
  *Fixed: the interrupt acknowledged is recorded, and that one is ended.*
- **SMMUv3, `submit`**: writes a command when the queue is still full, possibly over one the SMMU hasn't consumed.
  *Fixed: it waits while the queue is full.*
- **VT-d**: `remap_interrupt`/`unmap_interrupt` choose an entry modulo the table but invalidate the raw index.
  *Fixed.*
- **Process builder**: staging addresses are never given back (a long-lived process manager runs out); RELRO's start is
  rounded down, making writable bytes read-only.
  *Fixed: callers that build many keep their staging (process_builder.Staging). RELRO's rounding is not a bug: it's
  glibc's convention, and the linker pads to it.*
- **Update service**: after a degraded boot `collect(service, 0)` removes the update `install` just put on the ESP;
  objects are written in place, so a crash leaves a partial object that's never rewritten.
  *Fixed: collect keeps the installed generation, and objects are written to a .part file renamed over.*
- **SlopFS**: `tree_put`'s failed split has already removed the key's old value; `tree_delete` leaves `tree.root` on a
  discarded node if `new_node` fails; `delete_snapshot` deletes the record before reserving memory; `create_sealed_volume`
  leaves stray key records on a bad name; `rotate` doesn't restore `keys.current` on failure; `write_chunk` leaks blocks
  on two error paths.
  *Fixed. A create_sealed_volume that runs out of memory after its key records are put still leaves them, unused; the
  next sealed volume of that ID overwrites them.*
- **FAT**: `rename`'s crash comment is wrong (a crash can lose the target); `write` past the end doesn't zero the gap in
  the old last cluster, so stale bytes show; a case-only rename is refused.
  *Fixed, with checks in fat_test: rename never loses both names, a case-only rename works, and the gap is zeroed.*
- **Bundle store**: `collect` silently skips a pin it can't parse, so what it pins can be collected; served objects are
  never closed, so at most 64 can ever be served.
  *The pin is fixed: an unreadable pin or root stops the collection. Never closing objects is open: an object can't be
  closed safely while a client may still map it, and the kernel has no way to tell the store none does. That needs a
  design (a signal on paged memory when only its pager holds it, say).*
- **Account records and service**: X25519 agreements, share and home plaintext, a lowercased password copy, and the
  recovery code's text are left unwiped; `seal_home` uses an all-zero nonce, reused if keys are set twice under the same
  home secret.
  *Fixed: each is wiped, and the answer with a recovery code is wiped once sent. The key pair's seal has a nonce made
  from its public key; records sealed before open with the zero nonce still.*
- **Storage manager**: a server launched but not recorded (when `port_for` fails after launch) is launched again on the
  same partition.
  *Fixed, for every server it launches: ports and bindings are made before the launch.*

## Wrong results

- **Hemera `std/text_buffer/format.hsc` `digit_count`**: returns 2 for 0 to 9, so `append_shifted`'s exponent can be one
  too high.
  *Fixed, with a check in the format scenario (1e27 wrote e+28).*
- **Hemera `std/os/windows.hsc`**: the `_in` path functions and directory listing mishandle non-ASCII paths (trailing NULs
  in NT names, a cut search pattern); `system_path_kind_in` doesn't check the length limit; `system_open` with APPEND
  appends once, not on every write.
  *Fixed, with checks in the files scenario: NT names are the converted length, the pattern isn't cut,
  system_path_kind_in checks the length, and APPEND opens to append only.*
- **Hemera `std/os/linux.hsc`**: closing the zero File or Directory closes descriptor 0.
  *Fixed: the zero File or Directory closes nothing.*
- **Hemera `std/logger`**: Options without `stream` write to standard output, though the comment says standard error.
  *Fixed: Options has to_output, false by default, so a literal leaving it out logs to standard error.*
- **Hemera `std/crypto/blake2b.hsc` `blake2b_finish`**: output past the hasher's size is zeros, then repeats.
  *Fixed: zeros past the digest, however long.*
- **Hemera `std/time`**: tiered Freestanding, but `parse_zone` allocates.
  *Fixed: time zones are their own package, time_zones, Allocating; time stays Freestanding, as locale needs.*
- **Hemera `base/runtime/slop_os.hsc` `os_entry_grant`**: reads grant 0 when there are none.
  *Fixed.*
- **Hemera compiler reflection**: `FunctionInfo.generic_bindings` is never filled in, `FunctionParameter.default_value`
  is always None, and `BuildOptions.configuration`, `TargetOptions.linker` and `max_frame_size` aren't read.
  *Open: these are features to build, not slips; the documentation says they aren't read or filled in yet.*
- **PCI**: configuration space is read in the CPU's byte order (right only on little-endian targets).
  *Fixed: configuration space is read and written little-endian.*
- **Virtio**: `start` spins forever if the device never finishes resetting; `offer_chain` with no parts offers an index
  never taken; `set_vector` writes the MSI-X entry before finding the capability.
  *Fixed: start gives up after RESET_SPINS; offer_chain refuses no parts and gives back descriptors taken when it runs
  out partway (which it didn't either); set_vector finds the capability first.*
- **ELF loader test**: check 10 passes even if loading into a too-small image succeeds; check 22 fails on an arm64 build.
  *Fixed.*
- **Terminal service**: `take_accounts` resets only the Making step on failure, so Sharing and LoggingIn stay stuck.
  *Fixed: LoggingIn and Sharing go back to where they were asked from.*
- **Root task**: a failed start leaves a stale `launched_budget` given to the next service.
  *Fixed: a failed start destroys its budget, process and address space, and leaves launched_budget alone.*
- **Entropy**: a source's slot is never reused, so at most 4 can ever be added.
  *Fixed: a gone source's slot and key are reused.*
- **Test failure numbers that overlap**: `disk_check` 60 to 85, `sealed_test` 800 to 900, `test_msi_dma` 30.
  *Fixed: disk_check's typed-file checks are 51 to 58, transactions 170 to 195, sealed volumes 200 to 212; sealed_test
  1400 to 1500; test_msi_dma's budget 110. A testing framework would make numbers unnecessary.*
- **`test_threads`** reports the last failing thread, not the first; **`test_perf`** never notices a wrong echo.
  *Fixed, both.*

## The shell (11b, 11c: to fix with 11d)

- Each line read is never freed; `wait_for` spins if `port_wait` errors; `start_call` doesn't close its lifecycle end
  when a launch fails; `write_given` keeps a stale writer after a failed put; `encode` takes a list's start before
  aligning; grouping by a field named `count` or `items` collides; `append_signed` overflows on the smallest i64; table
  widths count bytes, not columns; arithmetic doesn't check for overflow; `interpolate` stops names at `-`.

## Leaks on error paths

Handles, ports, addresses or memory not given back when a step fails partway: the supervisor (`lending_attempt`,
`connector_to`, `start_storage`, `start_driver`, `map_in`, `dial_root_service`), the root task (`start_platform`,
`start_scheduler`), the terminal service (`dial_serial`, `dial_seat`, `start_session`), the session manager
(`launch_powerbox`, `launch_echo`, `launch_shell`, `map_in`), the FAT and volume servers (`use_buffer`), the container
service (`add`), the volume server (`transaction_connection`), the bundle store (`use_directory`, `reopen`), virtio_blk
(`buffer_for`), the powerbox (`serve`), the platform (`claim_framebuffer`), Hemera's stream openers (`opened_writer`,
`opened_reader`) and `slop_os_ends.hsc` `call`, and the UEFI bootloader before a failed boot.
