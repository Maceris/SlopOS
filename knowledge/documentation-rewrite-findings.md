# Possible Bugs Found While Rewriting the Documentation

The documentation rewrite (`decisions/0174`, November 2026) read every declaration in SlopOS and in Hemera's `base` and
`std` against its code. Where the code didn't do what the old comments said, or did something questionable, the new
documentation describes what the code does, and the code was left alone. These are those findings, for review; none
is fixed yet, and each needs confirming before it's acted on.

## Serious: memory safety, security, or data loss

- **Kernel, x86-64 `paging.hsc` `unmap`**: never checks the address with `may_map`, so unmapping a kernel-half address
  through a user address space would edit the shared kernel tables.
- **Kernel, `devices.hsc` `create_device`**: the duplicate-device loop dereferences null when `first_device` is 0.
- **Kernel, `channels.hsc`**: the header says a space's lock is never held with a channel core's, but `channel_write`,
  `channel_read` and `channel_take_handles` take it (through user copies) while holding the core's. A lock-order
  problem, or an out-of-date note.
- **Kernel, `timers.hsc` `cancel_timer`**: reads the entry's CPU and index before taking the heap lock.
- **Kernel, `kernel_entry.hsc` `nmi`**: logs through the console spin lock, which can deadlock on the CPU holding it.
- **Kernel, `translation.hsc` `refill_iommu_tables`**: returns true when a charge fails partway, so `map_dma_memory` and
  `map_doorbell` may loop forever.
- **Kernel, `user_memory.hsc` / `paging.hsc`**: `copy_user` and `supply_page` reach pages through the direct map, which is
  wrong for device memory.
- **Kernel, `memory_budgets.hsc`**: `limit - used` wraps if `used` exceeds `limit`, which a rollback in `move_charges` allows.
- **Kernel, `ports.hsc`**: `finish_or_block` loses packets when the copy-out fails; `is_user_writable` checks only page
  tables, so an untouched mapped page fails with BadBuffer.
- **AArch64, `its.hsc`**: `add_msi_device` sizes each device's table for 32 events but doesn't cap MAPD, so a device with
  more lets the ITS use memory past its table; `route_msi`/`move_msi` record a route for a CPU the LPI doesn't go to.
- **AArch64, `gic.hsc`**: `end_of_interrupt` does nothing if no route matches, leaving the interrupt active.
- **SMMUv3, `submit`**: writes a command when the queue is still full, possibly over one the SMMU hasn't consumed.
- **VT-d**: `remap_interrupt`/`unmap_interrupt` choose an entry modulo the table but invalidate the raw index.
- **Process builder**: staging addresses are never given back (a long-lived process manager runs out); RELRO's start is
  rounded down, making writable bytes read-only.
- **Update service**: after a degraded boot `collect(service, 0)` removes the update `install` just put on the ESP;
  objects are written in place, so a crash leaves a partial object that's never rewritten.
- **SlopFS**: `tree_put`'s failed split has already removed the key's old value; `tree_delete` leaves `tree.root` on a
  discarded node if `new_node` fails; `delete_snapshot` deletes the record before reserving memory; `create_sealed_volume`
  leaves stray key records on a bad name; `rotate` doesn't restore `keys.current` on failure; `write_chunk` leaks blocks
  on two error paths.
- **FAT**: `rename`'s crash comment is wrong (a crash can lose the target); `write` past the end doesn't zero the gap in
  the old last cluster, so stale bytes show; a case-only rename is refused.
- **Bundle store**: `collect` silently skips a pin it can't parse, so what it pins can be collected; served objects are
  never closed, so at most 64 can ever be served.
- **Account records and service**: X25519 agreements, share and home plaintext, a lowercased password copy, and the
  recovery code's text are left unwiped; `seal_home` uses an all-zero nonce, reused if keys are set twice under the same
  home secret.
- **Storage manager**: a server launched but not recorded (when `port_for` fails after launch) is launched again on the
  same partition.

## Wrong results

- **Hemera `std/text_buffer/format.hsc` `digit_count`**: returns 2 for 0 to 9, so `append_shifted`'s exponent can be one
  too high.
- **Hemera `std/os/windows.hsc`**: the `_in` path functions and directory listing mishandle non-ASCII paths (trailing NULs
  in NT names, a cut search pattern); `system_path_kind_in` doesn't check the length limit; `system_open` with APPEND
  appends once, not on every write.
- **Hemera `std/os/linux.hsc`**: closing the zero File or Directory closes descriptor 0.
- **Hemera `std/logger`**: Options without `stream` write to standard output, though the comment says standard error.
- **Hemera `std/crypto/blake2b.hsc` `blake2b_finish`**: output past the hasher's size is zeros, then repeats.
- **Hemera `std/time`**: tiered Freestanding, but `parse_zone` allocates.
- **Hemera `base/runtime/slop_os.hsc` `os_entry_grant`**: reads grant 0 when there are none.
- **Hemera compiler reflection**: `FunctionInfo.generic_bindings` is never filled in, `FunctionParameter.default_value`
  is always None, and `BuildOptions.configuration`, `TargetOptions.linker` and `max_frame_size` aren't read.
- **PCI**: configuration space is read in the CPU's byte order (right only on little-endian targets).
- **Virtio**: `start` spins forever if the device never finishes resetting; `offer_chain` with no parts offers an index
  never taken; `set_vector` writes the MSI-X entry before finding the capability.
- **ELF loader test**: check 10 passes even if loading into a too-small image succeeds; check 22 fails on an arm64 build.
- **Terminal service**: `take_accounts` resets only the Making step on failure, so Sharing and LoggingIn stay stuck.
- **Root task**: a failed start leaves a stale `launched_budget` given to the next service.
- **Entropy**: a source's slot is never reused, so at most 4 can ever be added.
- **Test failure numbers that overlap**: `disk_check` 60 to 85, `sealed_test` 800 to 900, `test_msi_dma` 30.
- **`test_threads`** reports the last failing thread, not the first; **`test_perf`** never notices a wrong echo.

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
