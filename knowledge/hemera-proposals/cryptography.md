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

**Done** 2026-10-19 (Hemera's `docs/memory.md`, *Secrets*; `docs/directives.md`). As built, with the
boundary rule chosen with the Hemera author (types must say so):

- `#secret` marks a struct, or a distinct alias (`Word :: distinct alias u32 #secret`), whose public form
  is what it aliases. A value is secret when its type is, or when it's worked out from a secret: operators,
  casts, literals holding one, a secret's fields and elements (through pointers too), and locals made from one.
- A secret can't decide a branch (`if`, `match`, `switch`, `&&`/`||`, `or_else`, `or_return`, `?`), a loop's
  range, an index or a pointer, and can't be divided or divide. All E4037.
- **Boundaries are types:** a secret goes only into a parameter, result or assignment of a `#secret` type, or a
  place already holding secrets (a secret local, a secret's field). `&` of a secret of a public type is an
  error, since the pointer would lose it. `.count` and `.capacity` are public. Ciphertext written to an output
  buffer is `compiler.declassify`d.
- **`#constant_time` is required where it shows:** a function whose parameters or results reach a secret.
  Any function may hold secrets, and the rules hold everywhere, so `main` making a key needs no marking (the
  plan's "computes with secrets" would have marked every caller). W4002 warns about a `#constant_time`
  function with no secret, except a generic's instances.
- `compiler.declassify` and `compiler.secret`; `intrinsics.select` chooses between integers, bools and enums
  as well as lanes (rather than a separate `compiler.select`), with its mask passed through an empty assembly
  block, so it stays `cmp`/`sbb`/`and` with no branch; `intrinsics.secure_zero` is a volatile memset.
- Intrinsics take secrets anywhere, and give a secret back for one.
- **Not yet:** value barriers beyond `select`'s own mask, and checking the machine code. The `#owned` key types
  that wipe themselves come with `std/crypto`.

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
2. **Secrets** (done 2026-10-19): `#secret`, `#constant_time` and its checks, `compiler.declassify` and
   `secret`, `intrinsics.select` without a branch, and `secure_zero` (`docs/memory.md`, *Secrets*).
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
