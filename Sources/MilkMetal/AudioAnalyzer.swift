import Accelerate

/// What presets see of the audio each frame.
struct AudioLevels: Equatable {
    /// Instant band energy relative to its long-term average: about 1 is "normal".
    var bass = 1.0, mid = 1.0, treb = 1.0
    /// The same, smoothed.
    var bassAtt = 1.0, midAtt = 1.0, trebAtt = 1.0
}

/// Turns the newest PCM in an `AudioRing` into what presets read, the way Butterchurn (and MilkDrop) do:
///
/// - `waveLeft`/`waveRight`: 512 points per channel in MilkDrop's byte scale (−128…127), each the mean of two
///   neighbouring samples of the 1024-sample window, for the waveforms.
/// - `spectrumLeft`/`spectrumRight`: 512 equalised FFT magnitudes per channel, for spectrum waves.
/// - `levels`: bass (20–320 Hz), mid (320–2800 Hz) and treble (2800–11025 Hz) energy of the mono mix, relative to a
///   long-term average, with MilkDrop's attack/release smoothing.
///
/// Runs on the render thread.
final class AudioAnalyzer {
    static let windowSize = 1024
    static let pointCount = 512
    private static let log2n = vDSP_Length(10)

    private(set) var waveLeft = [Float](repeating: 0, count: pointCount)
    private(set) var waveRight = [Float](repeating: 0, count: pointCount)
    private(set) var spectrumLeft = [Float](repeating: 0, count: pointCount)
    private(set) var spectrumRight = [Float](repeating: 0, count: pointCount)
    private(set) var levels = AudioLevels()

    private let fft: FFTSetup
    /// Butterchurn's equaliser: lifts the high bins, which carry less energy.
    private let equalize: [Float]
    private var left = [Float](repeating: 0, count: windowSize)
    private var right = [Float](repeating: 0, count: windowSize)
    private var mono = [Float](repeating: 0, count: windowSize)
    private var spectrumMono = [Float](repeating: 0, count: pointCount)
    private var real = [Float](repeating: 0, count: windowSize / 2)
    private var imag = [Float](repeating: 0, count: windowSize / 2)
    private var average = [Double](repeating: 1, count: 3)
    private var longAverage = [Double](repeating: 1, count: 3)
    private var frames = 0

    init() {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        fft = setup
        equalize = (0..<Self.pointCount).map { i in
            Float(-0.02 * log(Double(Self.pointCount - i) / Double(Self.pointCount)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    /// Reads the ring and updates everything. `fps` adapts the smoothing so it behaves the same at any frame rate.
    func update(from ring: AudioRing, fps: Double) {
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                _ = ring.copyLatest(count: Self.windowSize, left: l, right: r)
            }
        }
        // Byte scale, as the WebAudio analyser hands Butterchurn its samples.
        vDSP.multiply(128, left, result: &left)
        vDSP.multiply(128, right, result: &right)
        vDSP.add(left, right, result: &mono)
        vDSP.multiply(0.5, mono, result: &mono)

        Self.undersample(left, into: &waveLeft)
        Self.undersample(right, into: &waveRight)
        spectrum(of: left, into: &spectrumLeft)
        spectrum(of: right, into: &spectrumRight)
        spectrum(of: mono, into: &spectrumMono)
        updateLevels(sampleRate: ring.sampleRate, fps: fps)
    }

    /// 1024 samples → 512 points, each the mean of a sample and the one before it.
    private static func undersample(_ samples: [Float], into out: inout [Float]) {
        for j in 0..<pointCount {
            let i = j * 2
            out[j] = 0.5 * (samples[i] + samples[max(i - 1, 0)])
        }
    }

    /// Equalised magnitudes of the unwindowed 1024-point FFT, bins 0–511.
    private func spectrum(of samples: [Float], into out: inout [Float]) {
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                              vDSP_Length(Self.windowSize / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_zvabs(&split, 1, o.baseAddress!, 1, vDSP_Length(Self.pointCount))
                }
            }
        }
        // zrip packs the Nyquist term into imag[0] and scales by 2; bin 0 is only DC.
        out[0] = abs(real[0])
        vDSP.multiply(0.5, out, result: &out)
        vDSP.multiply(out, equalize, result: &out)
    }

    private func updateLevels(sampleRate: Double, fps: Double) {
        let bucketHz = max(sampleRate, 1) / Double(Self.windowSize)
        func bin(_ hz: Double) -> Int { min(max(Int((hz / bucketHz).rounded()) - 1, 0), Self.pointCount - 1) }
        let edges = [bin(20), bin(320), bin(2800), bin(11025)]

        let effectiveFPS = fps.isFinite ? min(max(fps, 15), 144) : 15
        func adjust(_ rate: Double) -> Double { pow(rate, 30 / effectiveFPS) }
        var values = [Double](repeating: 1, count: 3)
        var smoothed = [Double](repeating: 1, count: 3)
        for b in 0..<3 {
            var immediate = 0.0
            for j in edges[b]..<max(edges[b], edges[b + 1]) { immediate += Double(spectrumMono[j]) }

            let rate = adjust(immediate > average[b] ? 0.2 : 0.5)
            average[b] = average[b] * rate + immediate * (1 - rate)
            let longRate = adjust(frames < 50 ? 0.9 : 0.992)
            longAverage[b] = longAverage[b] * longRate + immediate * (1 - longRate)
            // Silence (or no input at all) reads as "normal" so presets keep moving.
            if longAverage[b] >= 0.001 {
                values[b] = immediate / longAverage[b]
                smoothed[b] = average[b] / longAverage[b]
            }
        }
        frames += 1
        levels = AudioLevels(bass: values[0], mid: values[1], treb: values[2],
                             bassAtt: smoothed[0], midAtt: smoothed[1], trebAtt: smoothed[2])
    }
}
