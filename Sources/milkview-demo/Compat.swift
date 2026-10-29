import Foundation
import Metal
import MilkDemoSupport
import MilkMetal
import os

// `milkview-demo compat`: renders each preset of a corpus offscreen and records crashes, hangs, load failures, GPU
// errors, NaN and black frames, and frame times, one JSON line per preset. A crash or hang ends the process; the
// shell loop around it (scripts/run-tests-vm.sh --compat) starts it again, and it carries on from the report.

/// Ends the process with a `timeout` record when one preset runs too long. Its timer fires off the main thread, so
/// it still fires while the main thread is stuck in a shader compile or `waitUntilCompleted`.
final class CompatWatchdog: @unchecked Sendable {
    private struct State {
        var preset: String?
        var started = 0.0
        var stage = ""
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let report: URL
    private let limit: Double
    private let timer: DispatchSourceTimer

    init(report: URL, limit: Double) {
        self.report = report
        self.limit = limit
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [unowned self] in check() }
        timer.resume()
    }

    func begin(_ preset: String) {
        lock.withLock { $0 = State(preset: preset, started: ProcessInfo.processInfo.systemUptime, stage: "loading") }
    }

    func stage(_ stage: String) {
        lock.withLock { $0.stage = stage }
    }

    /// Appends `result` unless the watchdog has already written a timeout for it.
    func finish(_ result: CompatResult) throws {
        try lock.withLock { state in
            guard state.preset == result.preset else { return }
            state.preset = nil
            try CompatReport.append(result, to: report)
        }
    }

    private func check() {
        lock.withLock { state in
            guard let preset = state.preset else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - state.started
            guard elapsed > limit else { return }
            let detail = String(format: "over %g s, while %@", limit, state.stage)
            try? CompatReport.append(CompatResult(preset: preset, failure: .timeout, detail: detail), to: report)
            print("timeout \(preset): \(detail)")
            fflush(stdout)
            exit(3)
        }
    }
}

@MainActor
func runCompat(_ options: Options) {
    guard let dir = options.dir, let report = options.report else { fail("compat needs --dir DIR and --report FILE") }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fail("no Metal device")
    }
    try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sidecar = report.appendingPathExtension("current")

    // A preset named in the sidecar with no record is the one the last process died on.
    let lastStatus = ProcessInfo.processInfo.environment["COMPAT_LAST_STATUS"].map { " (exit status \($0))" } ?? ""
    do {
        if let crash = try CompatReport.recordCrash(report: report, sidecar: sidecar,
                                                    detail: "process died while rendering it" + lastStatus) {
            print("crash \(crash.preset)\(lastStatus)")
        }
    } catch {
        fail("cannot write \(report.path): \(error)")
    }

    let presets = CompatReport.presets(in: dir, stride: options.stride, limit: options.limit)
    guard !presets.isEmpty else { fail("no .milk files under \(dir.path)") }
    let done = Set(CompatReport.read(report).map(\.preset))
    let todo = presets.filter { !done.contains($0) }
    print("compat \(presets.count) presets, \(presets.count - todo.count) already in the report, "
        + "\(options.width)x\(options.height), \(options.count) frames, device \(device.name)")
    fflush(stdout)

    let watchdog = CompatWatchdog(report: report, limit: options.timeout)
    let started = Date()
    // One renderer for the whole run, reset before each preset: `reset()` makes it draw what a new renderer would
    // (checked frame for frame against new renderers on 771 presets).
    let renderer: MilkRenderer
    do {
        renderer = try MilkRenderer(device: device, pixelFormat: .rgba16Float)
    } catch {
        fail("cannot make a renderer: \(error)")
    }
    renderer.compilesShadersInBackground = false
    for (i, preset) in todo.enumerated() {
        do {
            try Data((preset + "\n").utf8).write(to: sidecar)
        } catch {
            fail("cannot write \(sidecar.path): \(error)")
        }
        watchdog.begin(preset)
        let result = autoreleasepool {
            compatRender(dir.appendingPathComponent(preset), name: preset, renderer: renderer, queue: queue,
                         options: options, watchdog: watchdog)
        }
        do {
            try watchdog.finish(result)
        } catch {
            fail("cannot write \(report.path): \(error)")
        }
        let status = result.passed ? "pass" : result.failures.map(\.rawValue).joined(separator: ",")
        print(String(format: "[%d/%d] %@ %@ gpu %.2f/%.2f cpu %.2f/%.2f ms", i + 1, todo.count, status, preset,
                     result.gpuMedianMs, result.gpuP99Ms, result.cpuMedianMs, result.cpuP99Ms))
        fflush(stdout)
    }
    try? FileManager.default.removeItem(at: sidecar)

    // Only this run's selection counts, in case the report holds others.
    let selected = Set(presets)
    var latest: [String: CompatResult] = [:]
    for r in CompatReport.read(report) where selected.contains(r.preset) { latest[r.preset] = r }
    let summary = CompatSummary(results: presets.compactMap { latest[$0] }, gpuBudgetMs: options.gpuBudgetMs,
                                cpuBudgetMs: options.cpuBudgetMs)
    print(String(format: "compat finished %d presets in %.0f s", todo.count, Date().timeIntervalSince(started)))
    print(summary.text)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let summaryURL = report.deletingLastPathComponent().appendingPathComponent("summary.json")
    do {
        try encoder.encode(summary).write(to: summaryURL)
    } catch {
        fail("cannot write \(summaryURL.path): \(error)")
    }
}

/// Loads and renders one preset with `renderer`, reset first so the result doesn't depend on the presets before
/// it (or on where a restart picked up): `MilkRenderer` keeps the feedback image, frame counter and random sequence
/// across `load`.
@MainActor
func compatRender(_ url: URL, name: String, renderer: MilkRenderer, queue: MTLCommandQueue, options: Options,
                  watchdog: CompatWatchdog) -> CompatResult {
    var result = CompatResult(preset: name)
    let (width, height) = (options.width, options.height)
    let device = renderer.device
    let loadStart = ProcessInfo.processInfo.systemUptime
    do {
        renderer.reset()
        try renderer.load(MilkPreset(contentsOf: url))
    } catch {
        result.failures = [.loadFailed]
        result.detail = "\(error)"
        return result
    }
    result.loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
    result.presetErrors = renderer.presetErrors

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                              height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { fail("cannot make the target texture") }

    let fps = 60.0
    var synth = SynthAudio()
    let samplesPerFrame = Int(synth.sampleRate / fps)
    let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: samplesPerFrame * 2)
    defer { buffer.deallocate() }
    var pixels = [Float16](repeating: 0, count: width * height * 4)
    var cpu: [Double] = [], gpu: [Double] = []
    var check = FrameCheck()
    var firstNonFinite: Int?

    for frame in 0..<options.count {
        watchdog.stage("rendering frame \(frame + 1)")
        synth.render(into: buffer, frames: samplesPerFrame)
        renderer.feed(samples: UnsafeBufferPointer(buffer), channels: 2, sampleRate: synth.sampleRate)
        guard let commandBuffer = queue.makeCommandBuffer() else { fail("no command buffer") }
        let t0 = ProcessInfo.processInfo.systemUptime
        renderer.render(to: texture, commandBuffer: commandBuffer, time: Double(frame) / fps)
        let t1 = ProcessInfo.processInfo.systemUptime
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        result.frames = frame + 1
        if let error = commandBuffer.error {
            result.failures.append(.gpuError)
            result.detail = "frame \(frame + 1): \(error.localizedDescription)"
            break
        }
        if frame > 0 {
            cpu.append((t1 - t0) * 1000)
            let ms = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
            gpu.append(ms)
            if ms > result.gpuMaxMs { (result.gpuMaxMs, result.gpuMaxFrame) = (ms, frame + 1) }
        }
        guard (frame + 1) % options.every == 0 || frame + 1 == options.count else { continue }
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        check = pixels.withUnsafeBufferPointer { FrameCheck(rgba16: $0) }
        if check.nonFinite > 0, firstNonFinite == nil {
            firstNonFinite = frame + 1
            result.failures.append(.nonFinite)
            result.detail = "frame \(frame + 1): \(check.nonFinite) of \(width * height) pixels not finite"
        }
    }
    result.setTimes(cpu: cpu, gpu: gpu)
    result.peak = check.peak
    result.mean = check.mean
    if !result.failures.contains(.gpuError), check.isBlack {
        result.failures.append(.black)
        result.detail = result.detail ?? String(format: "frame %d: peak %.4f", result.frames, check.peak)
    }
    return result
}
