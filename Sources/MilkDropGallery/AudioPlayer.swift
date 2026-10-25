import AVFoundation
import MilkDemoSupport
import MilkMetal
import Observation
import QuartzCore
import os

/// Plays one audio file on a loop through AVAudioEngine and hands what the mixer outputs to the renderer.
///
/// Until a file is chosen the renderer gets the built-in beat, generated and never played; while paused it gets
/// silence. A 120 Hz timer on the main thread does all the feeding, so the visuals advance smoothly even though
/// the engine's tap delivers audio in large chunks.
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

    @ObservationIgnored private let renderer: MilkRenderer?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let sink = TapSink()
    @ObservationIgnored private var tapInstalled = false
    /// The file frame the current segment started at; the player's own clock counts from there.
    @ObservationIgnored private var segmentStart: AVAudioFramePosition = 0
    /// Bumped on every stop or reschedule, so a completion from an old segment is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var synth = SynthAudio()
    @ObservationIgnored private var scratch = [Float](repeating: 0, count: 8_192 * 2)
    @ObservationIgnored private var owedFrames = 0.0
    @ObservationIgnored private var lastTick = CACurrentMediaTime()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var hasFile: Bool { file != nil }

    init(renderer: MilkRenderer?) {
        self.renderer = renderer
        engine.attach(player)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common, so feeding continues while a menu is open or the slider is dragged.
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
            sink.reset()
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
            Self.installTap(on: engine.mainMixerNode, sink: sink)
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
        sink.reset()
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
    private nonisolated static func installTap(on node: AVAudioNode, sink: TapSink) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in sink.write(buffer) }
    }

    // MARK: Feeding

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(now - lastTick, 0.1)
        lastTick = now
        updatePosition()
        guard let renderer else { return }

        if file != nil, isPlaying {
            sink.drain(seconds: elapsed) { samples, sampleRate in
                renderer.feed(samples: samples, channels: 2, sampleRate: sampleRate)
            }
            return
        }
        // The built-in beat before a file is chosen, silence while paused.
        let sampleRate = synth.sampleRate
        owedFrames += elapsed * sampleRate
        let frames = min(Int(owedFrames), scratch.count / 2)
        owedFrames -= Double(frames)
        guard frames > 0 else { return }
        let beat = file == nil
        scratch.withUnsafeMutableBufferPointer { buffer in
            if beat {
                synth.render(into: buffer, frames: frames)
            } else {
                buffer.update(repeating: 0)
            }
            renderer.feed(samples: UnsafeBufferPointer(rebasing: buffer[..<(frames * 2)]), channels: 2,
                          sampleRate: sampleRate)
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

/// The hand-off between the engine's tap and the main thread.
///
/// AVAudioEngine delivers the mixer output in chunks (often about 100 ms), so the tap queues interleaved stereo
/// here and the main thread drains it at the playback rate. Feeding each chunk as it arrives would make the visuals
/// jump ten times a second. The queue holds at most a quarter second; older audio is dropped.
final class TapSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let capacity = 192_000 / 4   // frames: a quarter second at up to 192 kHz
    private let storage: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private var head = 0      // oldest queued frame
    private var count = 0     // queued frames
    private var sampleRate = 48_000.0
    private var owedFrames = 0.0

    init() {
        storage = .allocate(capacity: capacity * 2)
        output = .allocate(capacity: capacity * 2)
    }

    deinit {
        storage.deallocate()
        output.deallocate()
    }

    /// Tap side. Mono is copied to both channels; channels past the second are ignored.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        let left = data[0]
        let right = buffer.format.channelCount < 2 ? left : (buffer.format.isInterleaved ? data[0] + 1 : data[1])
        lock.lock()
        defer { lock.unlock() }
        sampleRate = buffer.format.sampleRate
        let limit = min(capacity, Int(sampleRate / 4))
        let skip = max(0, frames - limit)
        for i in skip..<frames {
            let slot = (head + count) % capacity
            storage[slot * 2] = left[i * stride]
            storage[slot * 2 + 1] = right[i * stride]
            if count < limit {
                count += 1
            } else {
                head = (head + 1) % capacity
            }
        }
    }

    /// Main-thread side: hands `feed` the frames due in the last `seconds`, oldest first.
    func drain(seconds: Double, feed: (UnsafeBufferPointer<Float>, Double) -> Void) {
        lock.lock()
        owedFrames += seconds * sampleRate
        let frames = min(Int(owedFrames), count)
        // On an underrun, don't build up debt that would later release a burst.
        owedFrames = frames < count ? owedFrames - Double(frames) : 0
        for i in 0..<frames {
            let slot = (head + i) % capacity
            output[i * 2] = storage[slot * 2]
            output[i * 2 + 1] = storage[slot * 2 + 1]
        }
        head = (head + frames) % capacity
        count -= frames
        let rate = sampleRate
        lock.unlock()
        if frames > 0 { feed(UnsafeBufferPointer(start: output, count: frames * 2), rate) }
    }

    func reset() {
        lock.lock()
        head = 0
        count = 0
        owedFrames = 0
        lock.unlock()
    }
}
