# Proposal: Cryptography in `std`

Status: **planned** 2026-10-19, with directions chosen with the Hemera author: the algorithms SSH,
volume keys and password hashes need, plus BLAKE3; hardware AES from the start, through a general
`vector[T, n]` and fixed-width `v128`/`v256`/`v512`; a `#constant_time` directive that the compiler
checks, with secrets marked on types (`#secret`); one freestanding `std/crypto` package. Raised by
`../decisions/0042` (Argon2id, wrapped volume keys), `0043` (SSH, then a native protocol) and
`0019` (AES instructions picked at startup, with a software fallback).

## What's Needed

| Use | Algorithms |
|---|---|
| SSH (`0043`): `curve25519-sha256`, `ssh-ed25519`, `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com` | X25519, SHA-256, Ed25519 (defined with SHA-512), ChaCha20-Poly1305, AES-256-GCM |
| Volume keys wrapped for each user's public keys, FIDO2 `hmac-secret` (`0042`) | X25519, HKDF, an AEAD |
| Encryption at rest (`0016`, `0019`) | AES-256-GCM, picked at startup from `CpuFeatures` |
| Password hashes in the account database (`0042`) | Argon2id (built on BLAKE2b) |
| SlopOS's own fast hash (content hashes, the native protocol) | BLAKE3 |
| Everything | HMAC, HKDF, constant-time comparison, wiping secrets |

The first version: SHA-256, SHA-512, BLAKE2b, BLAKE3, HMAC, HKDF, ChaCha20-Poly1305, AES-256-GCM,
X25519, Ed25519 and Argon2id. Nothing here is invented: each follows its RFC or FIPS document.

## 1. Vectors

**Done** 2026-10-19 (Hemera's `docs/types.md`, *Vectors*; `docs/directives.md`, `#target_features`). As built:

- `vector[T, n]` for `T` an integer or float of up to 64 bits, or `bool`, `n` a power of two, at most 64 bytes;
  aligned to its size. Lowered to LLVM vectors, so a target without SIMD, like the kernel built with `-sse`,
  still runs vector code, one lane at a time.
- Literals are `vector[u32, 4].{a, b, c, d}` and `.{}` for zeros, since `T.[...]` is already an array of `T`.
- Element-wise operators, including shifts and the bitwise ones, with a literal going in every lane;
  comparisons give `vector[bool, n]`, whose lanes are bytes of 0 or 1. Integer division isn't on vectors
  yet, since a lane of 0 has nothing like the scalar panic.
- A lane is chosen by a constant (`v[2]`), never at run time, which also keeps secrets from choosing one.
- `base/intrinsics`: `splat[V]`, `select`, `rotate_lanes` (a constant count, instead of general shuffles),
  `reduce_add`/`and`/`or`/`xor`, `any_true`, `all_true`, and `rotate_left`, `rotate_right` and `byte_swap`,
  which take plain integers too, as SHA and ChaCha need.

`v128`, `v256` and `v512` are bits of that size, `bit_cast` to and from any vector of the same size,
for intrinsics that don't care about lanes: `aesenc` works on bytes, `pclmulqdq` on `u64`s.

**Target features per function.** AES-NI and PCLMULQDQ aren't in x86-64-v3 (`0003`), so a function
using them is marked `#target_features("aes,pclmul")` (LLVM's `target-features` attribute) and only
called once `CpuFeatures` says the CPU has them. The rest of the program stays at its baseline. LLVM
takes a function's features instead of the target's, so the compiler joins them: the target's (like the
kernel's `-sse`), the reserved carrier register, and the function's.

**Intrinsics** in `base/intrinsics/x86_64`: `aes_encrypt_round`, `aes_encrypt_last`,
`aes_decrypt_round`, `aes_decrypt_last`, `aes_inverse_mix` and `aes_key_assist(key, round_constant)`, on
`v128`; `carryless_multiply(a, b, selector)` (`pclmulqdq`). An immediate is a constant argument, which the
checker requires and the generator puts in the instruction, rather than a compile-time parameter. Tested
against FIPS-197's AES-128 example. AArch64's `aese`/`aesmc`/`pmull` follow with the AArch64 port.

The kernel is built without SIMD state (`0023`), so kernel code uses the software path unless it
saves vector state around the call. User space takes the hardware path.

## 2. Secrets and `#constant_time`

**`#secret` marks a type**: `Key :: distinct u8[32] #secret`, or a struct holding one. A value of a
secret type is secret, and so is anything computed from one: operators, fields, elements, casts
and `bit_cast`. Lengths and counts stay public, since they're of public types.

**What a secret can't do**, anywhere, checked by the compiler with its own error code:

- Decide a branch: `if`, `match`, `while` and `for` conditions, `&&` and `||` (they short-circuit),
  `or_else` and `or_return`.
- Decide a memory address: an index, a pointer offset, a slice's bounds. A secret array indexed
  by a public index is fine.
- Be divided, or divide: `/`, `%` and `%%` take a variable time on most CPUs.
- Decide a loop's count, or how many times a call happens.

**`#constant_time` marks a function** that takes, returns or computes with secrets. A secret may only
be given to a `#constant_time` function, or to an intrinsic known to take constant time. So whether a
function handles secrets is visible in its signature, and std's ordinary helpers can't be handed
one by accident. A generic instance whose arguments are secret is checked by the same rules.

**A `#constant_time` function that touches no secret is warned about**: once its body is checked, no
secret parameter (through pointers and fields too), no secret result, and no secret value in its
body. That catches a marking left behind when a refactor moved the secrets elsewhere, which would
mislead a reviewer and pay for hardening it doesn't need. Generic declarations aren't warned about,
since `#constant_time` on one, like `array_copy[T]`, is what lets its secret instances exist, and
neither are declarations without a body. Not an error, since an unneeded marking is harmless; the
opposite, a function handling secrets without one, is.

**Leaving secrecy** is explicit: `compiler.declassify(value)` gives the value as its public type.
It's for results that are public by design, like whether a tag matched after a constant-time
comparison, and it's easy to find in review.

**What the compiler does in a `#constant_time` function**, since LLVM gives no constant-time
guarantee and can turn a mask back into a branch: every secret value that feeds a selection goes
through a value barrier the optimizer can't see through (an empty inline assembly taking it in a
register, as BoringSSL does by hand), and selections use `compiler.select(condition, a, b)`, generated
as a `cmov` or a mask, never a branch.

**Also in `base`:** `intrinsics.secure_zero(bytes)`, a wipe the optimizer never removes (a volatile
`memset`), and secret key types that are `#owned` with a release that wipes them, so a key on the
stack is wiped on every path out of its scope (`docs/memory.md`, *Owned Types*).

## 3. `std/crypto`

One freestanding package, each algorithm in its own file. Callers pass every buffer, including
Argon2id's memory, so the kernel and boot code can use it. Allocating conveniences can sit on top.
A sketch of its shape:

```
digest := crypto.sha256(data)                       // crypto.Sha256Digest, u8[32]

hasher := crypto.Sha512.{}
crypto.update(&hasher, header)
crypto.update(&hasher, body)
digest := crypto.finish(&hasher)

crypto.seal(&key, nonce, plaintext, associated, ciphertext, &tag)               // ChaCha20-Poly1305
crypto.open(&key, nonce, ciphertext, associated, tag, plaintext) or_return ...  // Result, AuthenticationFailed

shared := crypto.x25519(&my_secret, their_public) or_return ...                // LowOrderPoint for all-zero results
signature := crypto.ed25519_sign(&signing_key, message)
valid := crypto.ed25519_verify(public_key, message, signature)

crypto.argon2id(password, salt, crypto.Argon2Parameters.{memory_kib = 65536, passes = 3, lanes = 4},
    blocks, hash)                                   // blocks: the caller's memory, a crypto.Argon2Block[..]
```

- Keys, nonces, digests and tags are fixed-size arrays of distinct types, so a nonce can't be
  passed as a key. Secret keys are `#secret`.
- `open` writes nothing readable when the tag doesn't match: the output is wiped.
- AES-256-GCM picks AES-NI and PCLMULQDQ when `CpuFeatures` has them, otherwise a constant-time
  software AES (fixsliced, like BearSSL's `ct64`) and GHASH.
- Generating keys reads `context.random`, so it's only as strong as the context's generator: the
  system's in a hosted program, one seeded from `RDSEED` in the kernel.

## Phases

1. **Vectors** (done 2026-10-19): `vector[T, n]`, `v128`/`v256`/`v512`, `#target_features`, and the x86-64
   AES and carryless-multiply intrinsics (Hemera `docs/types.md`, `docs/directives.md`, `base/intrinsics`).
2. **Secrets**: `#secret`, `#constant_time` and its checks, `compiler.declassify`, `compiler.select`,
   value barriers, and `secure_zero` (`docs/directives.md`, a new section in `docs/memory.md`).
3. **Hashes**: SHA-256, SHA-512, BLAKE2b, BLAKE3, HMAC and HKDF.
4. **Encryption**: ChaCha20-Poly1305, and AES-256-GCM with both paths.
5. **Curves**: X25519 and Ed25519, on 64-bit limbs with `u128` products.
6. **Passwords**: Argon2id, its lanes worked one after another until threads are wanted.

Each algorithm is tested against its published vectors (FIPS 180-4, RFC 7693, BLAKE3's, RFC 4231,
RFC 5869, RFC 8439, NIST SP 800-38D, RFC 7748, RFC 8032, RFC 9106) and Wycheproof's edge cases,
hosted on Windows and Linux, and AES-GCM on both paths.

## Open Questions

- **Checking the generated code.** The compiler's rules catch secret-dependent source, and value
  barriers keep LLVM from undoing masks, but nothing proves the machine code. A test that the
  `#constant_time` functions' assembly has no conditional branch on a secret, or timing tests like
  dudect, could back it.
- **Secret types and std's generics.** Copying a key with `array_copy` makes a secret instance of a
  generic that isn't `#constant_time`. Checking generic instances by the rules (above) covers it,
  but may need std's basic helpers marked `#constant_time` once they're checked to be.
- **Vector lanes by a variable index** are a memory access on most targets; with a secret index
  that's the same leak as a table lookup, so it falls under the address rule.
