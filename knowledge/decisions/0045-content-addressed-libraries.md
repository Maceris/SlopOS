# 0045: Content-Addressed Libraries with Checked Compatibility

Status: accepted
Date: 2026-10-13
Related: `0013` (trusting code), `0025` (ABI package checks), `0038` (calling convention pinned per
version), `0040` (protocol evolution rules), `0044`

## Context
`../problems-and-directions.md` §5 leaned toward content-addressed libraries and compiler-checked
compatibility, to avoid both DLL hell and libc-style version breakage without falling back to
fully static binaries. How libraries are shared, versioned and patched was open.

## Decision
- **A library's identity is the hash of its contents**: its built code and its exported interface,
  built for a pinned calling-convention version (`../design/system-abi.md` §7). Libraries live in
  the bundle store.
- **Programs reference the exact hashes they were built with.** There is no global "current
  version" of a library.
- **The loader maps each hash once and shares it** between every program that uses it. Identical
  hashes share memory and disk; different hashes coexist.
- **The toolchain checks compatibility** by comparing a library's exported functions and types with
  an earlier version: types follow the append-only rules for protocols (`0040`), and functions must
  keep their signatures.
- **Security fixes are substituted by policy:** an entry "hash X is replaced by hash Y" is accepted
  only if Y's interface passes the compatibility check against X. Entries live in the config store,
  are recorded, and can be reversed.

## Alternatives considered
- **Names and human-assigned version numbers** (sonames, semver): the version says nothing checked
  about compatibility, and one global location means one version for everyone.
- **Static linking only:** no sharing, and every program must be rebuilt for a fix.
- **Substitution without a check:** a "fixed" library that changed its interface would break
  programs silently.

## Consequences
- The loader resolves hashes through the substitution policy before mapping.
- The compatibility check is shared with the ABI package's and protocols' release checks (`0025`,
  `0040`).
- A program's hash covers the hashes of the libraries it references, so substitution doesn't change
  a program's identity; the policy is applied when loading.
