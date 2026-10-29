import CMilkAtomics

/// Single-producer, single-consumer stereo sample ring between the host's audio thread and the renderer.
///
/// `write` never allocates or locks: it copies into preallocated storage and publishes the frame count with a
/// release store. `copyLatest` reads the newest frames and retries if the writer lapped it mid-copy.
final class AudioRing: @unchecked Sendable {
    /// Frames (per channel) held; a power of two so the index wraps with a mask.
    let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Total frames ever written. Written by the producer only.
    private let written: UnsafeMutablePointer<Int64>
    /// Bit pattern of the latest `sampleRate`, so the reader can see it without a lock.
    private let sampleRateBits: UnsafeMutablePointer<Int64>

    init(capacity: Int = 4096) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
        written = .allocate(capacity: 1)
        written.initialize(to: 0)
        sampleRateBits = .allocate(capacity: 1)
        sampleRateBits.initialize(to: Int64(bitPattern: 44_100.0.bitPattern))
    }

    deinit {
        left.deallocate()
        right.deallocate()
        written.deallocate()
        sampleRateBits.deallocate()
    }

    var sampleRate: Double {
        Double(bitPattern: UInt64(bitPattern: cma_load_acquire(sampleRateBits)))
    }

    /// Producer side. Interleaved samples; mono is duplicated to both channels, channels past two are ignored.
    func write(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        guard channels > 0, let base = samples.baseAddress else { return }
        cma_store_release(sampleRateBits, Int64(bitPattern: sampleRate.bitPattern))
        let frames = samples.count / channels
        var total = cma_load_acquire(written)
        let rightOffset = channels > 1 ? 1 : 0
        for frame in 0..<frames {
            let i = Int(total) & mask
            left[i] = base[frame * channels]
            right[i] = base[frame * channels + rightOffset]
            total += 1
        }
        cma_store_release(written, total)
    }

    /// Forgets every frame written, as if the ring were new. Not synchronised with `write`: a write racing it
    /// leaves some of its frames in place (harmless, but then the ring isn't exactly as new).
    func clear() {
        cma_store_release(written, 0)
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
    }

    /// Consumer side. Copies the newest `count` frames per channel (oldest first) and returns how many were
    /// available; earlier slots are zero-filled when fewer than `count` frames have ever been written.
    @discardableResult
    func copyLatest(count: Int, left outLeft: UnsafeMutableBufferPointer<Float>,
                    right outRight: UnsafeMutableBufferPointer<Float>) -> Int {
        precondition(count <= capacity && count <= outLeft.count && count <= outRight.count)
        for _ in 0..<4 {
            let end = cma_load_acquire(written)
            let available = Int(min(end, Int64(count)))
            let pad = count - available
            for i in 0..<pad {
                outLeft[i] = 0
                outRight[i] = 0
            }
            var src = Int(end) - available
            for i in pad..<count {
                outLeft[i] = left[src & mask]
                outRight[i] = right[src & mask]
                src += 1
            }
            cma_fence_acquire()
            // Torn if the writer advanced far enough to overwrite slots we were reading.
            if cma_load_acquire(written) - end <= Int64(capacity - count) { return available }
        }
        return 0
    }
}
