import Foundation

/// What a compatibility run looks for in one rendered frame, read back from an `rgba16Float` target so that NaNs and
/// infinities survive (an 8-bit target would turn them into black).
public struct FrameCheck: Sendable, Equatable {
    /// Pixels with a NaN or infinite channel.
    public var nonFinite = 0
    /// The brightest red, green or blue value of any finite pixel.
    public var peak: Float = 0
    /// Mean of (r + g + b) / 3 over the finite pixels.
    public var mean: Float = 0

    /// Below this peak a frame counts as black: under one step of an 8-bit display.
    public static let blackPeak: Float = 1.5 / 255

    public var isBlack: Bool { nonFinite == 0 && peak < Self.blackPeak }

    public init(nonFinite: Int = 0, peak: Float = 0, mean: Float = 0) {
        self.nonFinite = nonFinite
        self.peak = peak
        self.mean = mean
    }

    /// Checks RGBA pixels, four `Float16` channels each; alpha is ignored.
    public init(rgba16: UnsafeBufferPointer<Float16>) {
        var sum: Double = 0
        var finite = 0
        var i = 0
        while i + 3 < rgba16.count {
            let r = Float(rgba16[i]), g = Float(rgba16[i + 1]), b = Float(rgba16[i + 2])
            i += 4
            guard r.isFinite, g.isFinite, b.isFinite else { nonFinite += 1; continue }
            peak = max(peak, r, g, b)
            sum += Double(r + g + b) / 3
            finite += 1
        }
        mean = finite > 0 ? Float(sum / Double(finite)) : 0
    }
}
