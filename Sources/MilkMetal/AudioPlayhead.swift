/// Plays the fed audio out in step with the render clock, so the analyzer sees the audio that should be "now"
/// whatever size of chunks the host feeds.
///
/// The playhead is a position in the stream of fed frames. It starts at the first frame fed (or the oldest still
/// within `maxLatency`) and advances by the render clock's elapsed time at the stream's sample rate. Each render
/// analyzes the window that ends at it. So a 4,800-frame chunk fed at once is played out over the next 100 ms of
/// renders, exactly as if it had been fed in small pieces just in time.
///
/// - **Underrun** (the playhead catches up with the newest frame): it holds there, so the last window repeats, and
///   carries on from that frame when more arrives. Each hold adds that much delay, which absorbs a host's jitter.
/// - **Stopped feeding**: after holding for `holdLimit`, the playhead moves on into silence, so the waveform and
///   spectrum fall to zero and the levels decay as they would for fed silence. Audio fed after that starts again
///   from its first frame.
/// - **Overrun** (more than `maxLatency` fed ahead of the playhead): the oldest is dropped, the playhead jumping to
///   `maxLatency` behind the newest frame.
/// - **Sample-rate change**: the frames still unplayed at the old rate are dropped and the new audio plays from its
///   first frame, at its rate.
/// - The clock running backwards (a new `MilkView` restarts at 0) is treated as no time passing.
///
/// A host that feeds just in time, one render's worth before each render, sees each window one render late.
struct AudioPlayhead {
    /// The most fed audio kept ahead of the playhead, in seconds.
    static let maxLatency = 0.25
    /// How long an underrun holds the last window before playing out silence, in seconds.
    static let holdLimit = 0.25

    /// The window to analyze, by stream position.
    struct Window: Equatable {
        /// One past the window's last frame.
        var end: Int64
        /// Frames from here on haven't been fed (or are past where the host stopped): they read as zero.
        var validEnd: Int64
        /// Frames before this read as zero: audio from before a stop.
        var floor: Int64 = 0
    }

    /// The stream position that is "now", once audio has arrived; nil before that and while playing out silence.
    private(set) var position: Double?
    private var lastTime: Double?
    private var sampleRate: Double?
    /// When the current underrun began, by the render clock.
    private var stalledSince: Double?
    /// Where the next audio to arrive starts playing from, and the floor below which nothing is heard.
    private var startFrom: Int64 = 0
    /// While playing out silence: the frame the host stopped at and the virtual position past it.
    private var silence: (validEnd: Int64, end: Double)?

    /// The most frames that may wait ahead of the playhead at `sampleRate`, within a ring of `capacity` frames that
    /// also has to hold the `windowSize` frames behind it.
    static func maxLag(sampleRate: Double, capacity: Int, windowSize: Int) -> Int64 {
        Int64(max(0, min(maxLatency * sampleRate, Double(capacity - 2 * windowSize))))
    }

    /// Moves the playhead to render-clock `time`, given the ring's `state`, and returns the window to analyze.
    mutating func advance(to time: Double, _ state: AudioRing.State, maxLag: Int64) -> Window {
        let elapsed = lastTime.map { time - $0 } ?? 0
        let frames = elapsed.isFinite && elapsed > 0 ? elapsed * state.sampleRate : 0
        if time.isFinite { lastTime = time }

        if let rate = sampleRate, rate != state.sampleRate, let p = position {
            position = max(p, Double(state.rateStart))
        }
        sampleRate = state.sampleRate

        if var s = silence {
            guard state.written > s.validEnd else {
                s.end += frames
                silence = s
                return Window(end: Int64(s.end.rounded()), validEnd: s.validEnd, floor: startFrom)
            }
            // Audio again: play it from its start, with nothing from before the stop.
            silence = nil
            startFrom = s.validEnd
        }

        guard var p = position else {
            guard state.written > startFrom else {
                return Window(end: state.written, validEnd: state.written, floor: startFrom)
            }
            let start = max(Double(startFrom), Double(state.written - maxLag))
            position = start
            stalledSince = nil
            return Window(end: Int64(start), validEnd: state.written, floor: startFrom)
        }

        p += frames
        let newest = Double(state.written)
        if p > newest {
            let since = stalledSince ?? time
            stalledSince = since
            if time - since >= Self.holdLimit {
                // The host has stopped: slide on into silence from the newest frame.
                position = nil
                silence = (state.written, newest)
                return Window(end: state.written, validEnd: state.written, floor: startFrom)
            }
            p = newest
        } else {
            stalledSince = nil
        }
        p = max(p, newest - Double(maxLag))
        position = p
        return Window(end: Int64(p.rounded()), validEnd: state.written, floor: startFrom)
    }

    /// After a torn read: the writer moved on, so keep within `maxLag` of its newest frame.
    mutating func catchUp(_ state: AudioRing.State, maxLag: Int64) -> Window? {
        guard let p = position else { return nil }
        let caught = max(p, Double(state.written - maxLag))
        position = caught
        return Window(end: Int64(caught.rounded()), validEnd: state.written, floor: startFrom)
    }
}
