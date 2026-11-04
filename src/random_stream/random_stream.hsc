/**
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

/** The bytes a block gives out, after its first 32 become the key. */
BLOCK_OUTPUT : usize : 32

/**
 * A stream of random bytes, its state secret: anyone who has a copy of it can tell what it gives next, though not
 * what it gave before.
 */
Stream :: struct {
    /** The ChaCha20 key the next block is made with, replaced by each block's first 32 bytes. */
    key : crypto.Key256,
    /** The last block's bytes to give out, those from used on not given out yet. */
    output : u8[BLOCK_OUTPUT],
    /** How many of output have been given out, from 0 to BLOCK_OUTPUT; at BLOCK_OUTPUT a new block is made first. */
    used : usize,
}

/**
 * Make a stream from a seed.
 *
 * @param seed The seed, 32 bytes, which becomes the first key; the stream is only as unpredictable as it is. The
 *     caller should erase its own copy once the stream is made.
 * @return The stream, which makes its first block when it's first drawn from. Two streams of one seed give the same
 *     bytes.
 */
make :: fn(seed: u8[32]) -> Stream {
    stream := Stream.{used = BLOCK_OUTPUT}
    for byte, i in seed {
        stream.key[i] = byte
    }
    return stream
}

/**
 * Fill bytes from a stream, moving it on by as many.
 *
 * @param stream The stream, which makes a new block, and a new key, each time its last one is used up.
 * @param bytes Where the random bytes go, every one overwritten; empty draws nothing.
 */
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

/**
 * Draw a random 64-bit number.
 *
 * @param stream The stream, moved on by 8 bytes.
 * @return Any u64, each as likely as the others: the stream's next 8 bytes, little-endian.
 */
next_u64 :: fn(stream: ptr[mut Stream]) -> u64 {
    bytes : u8[8]
    fill(stream, bytes)
    return bit_cast[u64](bytes)
}

/**
 * Draw a random number below a limit, without the bias a plain remainder would have.
 *
 * Draws that land in the last, partial run of limit are thrown away and drawn again, so it may take more than one
 * draw; for any limit, fewer than half are thrown away.
 *
 * @param stream The stream, moved on by 8 bytes for each draw.
 * @param limit One past the largest number wanted; 0 draws nothing.
 * @return A number from 0 below limit, each as likely as the others; 0 for a limit of 0 or 1.
 */
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

/**
 * Make the stream's next block from its key: its first half becomes the next key, so the one it was made with is
 * gone, and its second half is what's given out.
 *
 * @param stream The stream, its key replaced, its output refilled and used set to 0.
 */
refill :: fn(stream: ptr[mut Stream]) {
    nonce : crypto.Nonce96
    block :: crypto.chacha20_block(&stream.key, 0, &nonce)
    for i in 0..<BLOCK_OUTPUT {
        stream.key[i] = cast[u8](crypto.chacha_byte(&block, i))
        stream.output[i] = compiler.declassify(cast[u8](crypto.chacha_byte(&block, BLOCK_OUTPUT + i)))
    }
    stream.used = 0
}
