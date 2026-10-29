import CMilkAtomics

/// Single-producer, single-consumer stereo sample ring between the host's audio thread and the renderer.
///
/// Frames are addressed by their position in the stream: frame `n` is the `n`th frame ever written. The ring holds
/// the newest `capacity` of them, so the renderer can read a window that ends behind the newest frame (the
/// `AudioPlayhead` decides where).
///
/// `write` never allocates or locks: it announces how far it will write, copies into preallocated storage and
/// publishes the frame count with a release store (a seqlock). `copy` reads a window and reports a tear if the
/// writer reached any of its slots on the next lap.
final class AudioRing: @unchecked Sendable {
    /// Frames (per channel) held; a power of two so the index wraps with a mask.
    let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Total frames ever written. Written by the producer only.
    private let written: UnsafeMutablePointer<Int64>
    /// What `written` will be when the write in progress finishes, announced before its samples are stored, so a
    /// reader can tell whether it may have read a slot that was being overwritten.
    private let writeEnd: UnsafeMutablePointer<Int64>
    /// Bit pattern of the latest `sampleRate`, so the reader can see it without a lock.
    private let sampleRateBits: UnsafeMutablePointer<Int64>
    /// The stream position of the first frame written at the latest `sampleRate`. Stored before the rate, so a
    /// reader that sees a new rate also sees where it starts.
    private let rateStart: UnsafeMutablePointer<Int64>

    /// What the reader sees of the stream at one moment.
    struct State {
        /// Frames written so far; the newest is `written - 1`.
        var written: Int64
        var sampleRate: Double
        /// Where audio at `sampleRate` begins.
        var rateStart: Int64
    }

    /// 65,536 frames: room for `AudioPlayhead.maxLatency` plus the analysis window at up to 192 kHz.
    init(capacity: Int = 65_536) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
        written = .allocate(capacity: 1)
        written.initialize(to: 0)
        writeEnd = .allocate(capacity: 1)
        writeEnd.initialize(to: 0)
        sampleRateBits = .allocate(capacity: 1)
        sampleRateBits.initialize(to: Int64(bitPattern: 44_100.0.bitPattern))
        rateStart = .allocate(capacity: 1)
        rateStart.initialize(to: 0)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        written.deallocate()
        writeEnd.deallocate()
        sampleRateBits.deallocate()
        rateStart.deallocate()
    }

    var sampleRate: Double {
        Double(bitPattern: UInt64(bitPattern: cma_load_acquire(sampleRateBits)))
    }

    /// Consumer side: the stream as it stands now.
    func state() -> State {
        // The rate before its start: the writer stores them the other way round.
        let rate = sampleRate
        return State(written: cma_load_acquire(written), sampleRate: rate, rateStart: cma_load_acquire(rateStart))
    }

    /// Producer side. Interleaved samples; mono is duplicated to both channels, channels past two are ignored.
    /// A `sampleRate` that isn't a positive, finite number drops the write.
    func write(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        guard channels > 0, sampleRate > 0, sampleRate.isFinite, let base = samples.baseAddress else { return }
        var total = cma_load_acquire(written)
        let bits = Int64(bitPattern: sampleRate.bitPattern)
        if bits != cma_load_acquire(sampleRateBits) {
            cma_store_release(rateStart, total)
            cma_store_release(sampleRateBits, bits)
        }
        let frames = samples.count / channels
        guard frames > 0 else { return }
        cma_store_release(writeEnd, total + Int64(frames))
        cma_fence_release()
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
        cma_store_release(writeEnd, 0)
        cma_store_release(rateStart, 0)
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
    }

    /// Consumer side. Copies the `count` frames per channel that end just before stream position `window.end`
    /// (oldest first). Frames before `window.floor`, at or past `window.validEnd`, or before the stream began read as
    /// zero. Returns false, with the output zeroed, if the writer overwrote frames of the window while it was copied
    /// (it had already, or it lapped the copy); the caller can move the window and try again.
    func copy(_ window: AudioPlayhead.Window, count: Int, left outLeft: UnsafeMutableBufferPointer<Float>,
              right outRight: UnsafeMutableBufferPointer<Float>) -> Bool {
        precondition(count <= capacity && count <= outLeft.count && count <= outRight.count)
        let start = window.end - Int64(count)
        let first = max(start, window.floor, 0)
        let last = min(window.end, window.validEnd)
        for i in 0..<count {
            let frame = start + Int64(i)
            if frame >= first && frame < last {
                outLeft[i] = left[Int(frame) & mask]
                outRight[i] = right[Int(frame) & mask]
            } else {
                outLeft[i] = 0
                outRight[i] = 0
            }
        }
        cma_fence_acquire()
        // Torn if the writer has started on a slot we read, on its next lap.
        if first < last && cma_load_acquire(writeEnd) - Int64(capacity) > first {
            for i in 0..<count {
                outLeft[i] = 0
                outRight[i] = 0
            }
            return false
        }
        return true
    }
}
