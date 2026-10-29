import AVFoundation
import MilkDemoSupport
import MilkMetal
import Observation
import QuartzCore
import os

/// Plays one audio file on a loop through AVAudioEngine and hands what the mixer outputs to the renderer.
///
/// The engine's tap feeds the renderer directly, in whatever chunks it delivers (often about 100 ms): the renderer
/// plays fed audio out in step with its frames. While paused the tap delivers, and feeds, silence. Until a file is
/// chosen the renderer gets the built-in beat instead, generated (never played) by a 10 Hz timer that also updates
/// the transport position.
@MainActor
@Observable
final class AudioPlayer {
    enum PlayerError: LocalizedError {
        case noOutputDevice

        var errorDescription: String? { "This Mac has no audio output device." }
    }

    private(set) var file: AVAudioFile?
    private(set) var fileName: String?
    private(set) var duration: TimeInterval = 0
    private(set) var position: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let feeder: TapFeeder
    @ObservationIgnored private var tapInstalled = false
    /// The file frame the current segment started at; the player's own clock counts from there.
    @ObservationIgnored private var segmentStart: AVAudioFramePosition = 0
    /// Bumped on every stop or reschedule, so a completion from an old segment is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var synth = SynthAudio()
    @ObservationIgnored private var scratch = [Float](repeating: 0, count: 24_000 * 2)
    @ObservationIgnored private var owedFrames = 0.0
    @ObservationIgnored private var lastTick = CACurrentMediaTime()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var hasFile: Bool { file != nil }

    init(renderer: MilkRenderer?) {
        feeder = TapFeeder(renderer: renderer)
        engine.attach(player)
        let timer = Timer(timeInterval: 1.0 / 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common, so the beat continues while a menu is open or the slider is dragged.
        RunLoop.main.add(timer, forMode: .common)
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        })
    }

    // MARK: Controls

    func open(_ url: URL) {
        do {
            let newFile = try AVAudioFile(forReading: url)
            guard newFile.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
            stopPlayer()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: newFile.processingFormat)
            try startEngine()
            file = newFile
            feeder.feedsTap = true
            fileName = url.lastPathComponent
            duration = Double(newFile.length) / newFile.processingFormat.sampleRate
            position = 0
            error = nil
            play(from: 0)
        } catch {
            self.error = "Can't play \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard file != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            do {
                try startEngine()
                player.play()
                isPlaying = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let file else { return }
        let wasPlaying = isPlaying
        play(from: AVAudioFramePosition(seconds * file.processingFormat.sampleRate))
        if !wasPlaying {
            player.pause()
            isPlaying = false
        }
        position = seconds
    }

    /// Stops the file and goes back to the built-in beat.
    func useBeat() {
        stopPlayer()
        feeder.feedsTap = false
        file = nil
        fileName = nil
        duration = 0
        position = 0
        error = nil
    }

    // MARK: Engine

    private func startEngine() throws {
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0 else { throw PlayerError.noOutputDevice }
        if !tapInstalled {
            Self.installTap(on: engine.mainMixerNode, feeder: feeder)
            tapInstalled = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func play(from frame: AVAudioFramePosition) {
        guard let file else { return }
        stopPlayer()
        do { try startEngine() } catch {
            self.error = error.localizedDescription
            return
        }
        let start = max(0, min(frame, file.length - 1))
        segmentStart = start
        let generation = generation
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start),
                               at: nil, completionCallbackType: .dataPlayedBack,
                               completionHandler: { @Sendable [weak self] _ in
                                   Task { @MainActor in self?.segmentEnded(generation) }
                               })
        player.play()
        isPlaying = true
    }

    private func stopPlayer() {
        generation += 1
        player.stop()
        isPlaying = false
    }

    /// The file reached its end: loop it.
    private func segmentEnded(_ generation: Int) {
        guard generation == self.generation, isPlaying else { return }
        play(from: 0)
    }

    /// The output device changed (or went away), which stops the engine.
    private func engineConfigurationChanged() {
        guard file != nil else { return }
        let wasPlaying = isPlaying
        let resumeAt = position
        stopPlayer()
        guard wasPlaying else { return }
        seek(to: resumeAt)
    }

    // The tap and completion blocks run on AVAudioEngine's threads. A closure written in a main-actor context is
    // main-actor isolated and traps there unless it's @Sendable, so the tap is made in a nonisolated function.
    private nonisolated static func installTap(on node: AVAudioNode, feeder: TapFeeder) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in feeder.write(buffer) }
    }

    // MARK: Feeding

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(now - lastTick, 0.5)
        lastTick = now
        updatePosition()
        // With a file, the tap feeds the renderer (silence while paused).
        guard file == nil else {
            owedFrames = 0
            return
        }
        let sampleRate = synth.sampleRate
        owedFrames += elapsed * sampleRate
        let frames = min(Int(owedFrames), scratch.count / 2)
        owedFrames -= Double(frames)
        guard frames > 0 else { return }
        scratch.withUnsafeMutableBufferPointer { buffer in
            synth.render(into: buffer, frames: frames)
            feeder.feedBeat(UnsafeBufferPointer(rebasing: buffer[..<(frames * 2)]), sampleRate: sampleRate)
        }
    }

    private func updatePosition() {
        guard file != nil, isPlaying, let nodeTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: nodeTime), time.sampleRate > 0 else { return }
        let seconds = min(duration, Double(segmentStart + time.sampleTime) / time.sampleRate)
        // A tenth of a second is enough for the transport bar; finer updates only redraw SwiftUI.
        if abs(seconds - position) >= 0.1 { position = max(0, seconds) }
    }
}

/// Feeds the renderer from the engine's tap, and the built-in beat from the main thread.
///
/// The tap's buffers go straight to `feed`, interleaved into preallocated storage; the renderer paces them. `feed`
/// takes one producer at a time, so a lock keeps the tap and the beat from feeding at once, and `feedsTap` says
/// which one the renderer hears. The tap thread isn't the real-time render thread, so the lock is fine there.
final class TapFeeder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let renderer: MilkRenderer?
    private let capacity = 8_192   // frames interleaved per `feed`; larger buffers are fed in pieces
    private let interleaved: UnsafeMutablePointer<Float>
    private var tapFeeds = false

    init(renderer: MilkRenderer?) {
        self.renderer = renderer
        interleaved = .allocate(capacity: capacity * 2)
    }

    deinit {
        interleaved.deallocate()
    }

    /// True while a file is loaded: the tap feeds the renderer and the beat doesn't.
    var feedsTap: Bool {
        get { lock.withLockUnchecked { tapFeeds } }
        set { lock.withLockUnchecked { tapFeeds = newValue } }
    }

    /// Tap side. Mono is copied to both channels; channels past the second are ignored.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let renderer, let data = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        let left = data[0]
        let right = buffer.format.channelCount < 2 ? left : (buffer.format.isInterleaved ? data[0] + 1 : data[1])
        let sampleRate = buffer.format.sampleRate
        lock.lock()
        defer { lock.unlock() }
        guard tapFeeds else { return }
        var done = 0
        while done < frames {
            let n = min(capacity, frames - done)
            for i in 0..<n {
                interleaved[i * 2] = left[(done + i) * stride]
                interleaved[i * 2 + 1] = right[(done + i) * stride]
            }
            renderer.feed(samples: UnsafeBufferPointer(start: interleaved, count: n * 2), channels: 2,
                          sampleRate: sampleRate)
            done += n
        }
    }

    /// Main-thread side: interleaved stereo from the built-in beat, fed only while no file is loaded.
    func feedBeat(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard let renderer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !tapFeeds else { return }
        renderer.feed(samples: samples, channels: 2, sampleRate: sampleRate)
    }
}
