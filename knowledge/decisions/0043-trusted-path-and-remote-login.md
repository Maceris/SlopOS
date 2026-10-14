# 0043: The Trusted Path and Remote Login

Status: accepted
Date: 2026-10-13
Related: `0016` (users), `0018` (powerbox prompts), `0042` (unlocking)

## Context
The powerbox asks the user to approve grants (`0018`). The user has to be able to tell a real prompt
from a program imitating one, on the local console and remotely. Remote login itself needed a
protocol choice: SSH for existing clients, or a native protocol that carries typed values and
capabilities.

## Decision
- **Local console:** the terminal service owns a **reserved status line** that programs can't write
  to, and a **secure attention key**: a key combination only the terminal service receives, which
  brings up the pending powerbox prompt (or a lock screen). The system never asks for a password
  inside a session's own output. No per-user secret phrases.
- **Remote, native protocol:** prompts travel as their own message type, which the client shows
  outside the terminal stream.
- **Remote, SSH:** no interactive powerbox. A byte stream can't prove where a prompt came from, so
  grants for SSH sessions are configured in advance. This is a documented limitation.
- **Protocols, in order:**
  1. **SSH** (RFC 4251–4254), once networking exists, for existing clients, as byte-stream
     sessions.
  2. **A native protocol** later, carrying typed values, capabilities, prompts outside the stream,
     and unlocking the volume from the client (`0042`).

  Both plug into the account service and the session manager.

## Alternatives considered
- **Per-user secret phrases shown with each prompt:** easily shoulder-surfed, and the status line
  gives the same assurance without a secret.
- **The native protocol only:** no existing clients would work.
- **SSH only:** no capabilities or typed values across the connection, and no trusted prompts.

## Consequences
- Hemera's `std` needs a cryptography package (X25519, Ed25519, ChaCha20-Poly1305 or AES-GCM, a
  hash and Argon2id), logged in `../hemera-feedback.md`.
- The terminal service's design includes the status line and the secure attention key.
