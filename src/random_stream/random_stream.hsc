/*
 * Random bytes from a 32-byte seed (decisions/0012, 0067): ChaCha20's keystream, rekeyed as it goes, so
 * what it gave can't be worked out from its state later ("fast key erasure"). Each block's first 32 bytes
 * become the next key and the rest are given out. The entropy service draws its bytes from one seeded
 * with the boot's seed, and the root task and the process manager use one for ASLR.
 *
 *     stream := random_stream.make(seed)
 *     base :: random_stream.below(&stream, pages)
 *
 * It's no better than its seed: one from the entropy service, or the boot's.
 */
package random_stream

import compiler from "base"
import crypto from "std"

// The bytes a block gives out, after its first 32 become the key.
BLOCK_OUTPUT : usize : 32

Stream :: struct {
    key : crypto.Key256,
    // The bytes of the last block not yet given out, from used
    output : u8[BLOCK_OUTPUT],
    used : usize,
}

// A stream from seed.
make :: fn(seed: u8[32]) -> Stream {
    stream := Stream.{used = BLOCK_OUTPUT}
    for byte, i in seed {
        stream.key[i] = byte
    }
    return stream
}

// bytes, filled from the stream.
fill :: fn(stream: ptr[mut Stream], bytes: mut u8[]) {
    for &byte in bytes {
        if stream.used >= BLOCK_OUTPUT {
            refill(stream)
        }
        used :: stream.used
        if used < stream.output.count {
            byte^ = stream.output[used]
        }
        stream.used = used + 1
    }
}

next_u64 :: fn(stream: ptr[mut Stream]) -> u64 {
    bytes : u8[8]
    fill(stream, bytes)
    return bit_cast[u64](bytes)
}

// A number from 0 up to limit, not including it, each as likely as the others; 0 for a limit of 0.
below :: fn(stream: ptr[mut Stream], limit: u64) -> u64 {
    if limit == 0 {
        return 0
    }
    // Draws in the last, partial run of limit would make low numbers likelier
    fair :: 0xffffffffffffffff - (0xffffffffffffffff % limit)
    loop {
        value :: next_u64(stream)
        if value < fair {
            return value % limit
        }
    }
}

// One block: its first half the next key, its second what's given out.
refill :: fn(stream: ptr[mut Stream]) {
    nonce : crypto.Nonce96
    block :: crypto.chacha20_block(&stream.key, 0, &nonce)
    for i in 0..<BLOCK_OUTPUT {
        stream.key[i] = cast[u8](crypto.chacha_byte(&block, i))
        stream.output[i] = compiler.declassify(cast[u8](crypto.chacha_byte(&block, BLOCK_OUTPUT + i)))
    }
    stream.used = 0
}
