import Foundation

/// A deterministic stereo test signal, so runs need no audio file: kick on every beat, snare on 2 and 4,
/// hi-hats on the off-beats, and a slow pad chord. 120 BPM. Nothing here plays; samples only go to `feed`.
public struct SynthAudio: Sendable {
    public let sampleRate: Double
    public private(set) var frame: Int = 0
    private var noise: UInt32 = 0x9E37_79B9

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    /// Writes `frames` interleaved stereo frames into `out` (which holds at least `2 * frames` floats).
    public mutating func render(into out: UnsafeMutableBufferPointer<Float>, frames: Int) {
        let beat = 0.5  // seconds
        for i in 0..<frames {
            let t = Double(frame) / sampleRate
            let inBeat = t.truncatingRemainder(dividingBy: beat)
            let beatIndex = Int(t / beat)
            let inEighth = t.truncatingRemainder(dividingBy: beat / 2)

            // Kick: a sine whose pitch drops from ~150 Hz to 50 Hz.
            let kickPhase = 2 * Double.pi * (50 * inBeat + (100 / 30) * (1 - exp(-inBeat * 30)))
            let kick = sin(kickPhase) * exp(-inBeat * 6) * 0.9

            let n = nextNoise()
            // Snare on beats 2 and 4 of each bar.
            let snare = beatIndex % 2 == 1 ? (n * 0.5 + sin(2 * .pi * 180 * inBeat) * 0.3) * exp(-inBeat * 15) : 0
            // Hi-hat on the off-beat eighths, panned right.
            let hat = inEighth < beat / 2 && (Int(t / (beat / 2)) % 2 == 1) ? n * exp(-inEighth * 60) * 0.25 : 0

            // Pad: A minor triad with a slow swell, slightly detuned between channels.
            let swell = 0.5 + 0.5 * sin(t * 0.4)
            let pad = { (detune: Double) -> Double in
                [220.0, 261.63, 329.63].reduce(0) { sum, f in
                    let p = 2 * Double.pi * f * detune * t
                    return sum + sin(p) + 0.3 * sin(2 * p) + 0.15 * sin(3 * p)
                } * 0.06 * swell
            }

            out[2 * i] = Float(kick + snare + hat * 0.4 + pad(1.0))
            out[2 * i + 1] = Float(kick + snare + hat + pad(1.003))
            frame += 1
        }
    }

    private mutating func nextNoise() -> Double {
        noise = noise &* 1_664_525 &+ 1_013_904_223
        return Double(noise) / Double(UInt32.max) * 2 - 1
    }
}
