import AppKit
import Foundation
import ImageIO
import Metal
import MilkDemoSupport
import MilkMetal
import UniformTypeIdentifiers

// milkview-demo: shows MilkView in a window, or renders frames offscreen, fed by SynthAudio. Plays nothing.
//
//   milkview-demo info      prints the Metal device and the GPU families it supports
//   milkview-demo window [--preset P] [--seconds N] [--size WxH] [--origin X,Y]
//       opens a borderless window at X,Y (points, from the top left of the main screen), prints
//       "window <CGWindowID> <x> <y> <w> <h>" once it is on screen, and quits after N seconds (default 10)
//   milkview-demo frames --out DIR [--preset P] [--count N] [--every K] [--size WxH]
//       renders N frames (default 300) at a fixed 60 fps clock and writes every Kth (default 30) as DIR/NNNN.png
//
// Both window and frames take [--next P2 [--switch-at T] [--transition S] [--pattern NAME]]: at T seconds
// (default 2) load P2 with an S second transition (default 2.7) in pattern NAME (random, crossfade, wipe, plasma,
// radial; default random).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("milkview-demo: " + message + "\n").utf8))
    exit(2)
}

struct Options {
    var mode = ""
    var preset: URL?
    var seconds = 10.0
    var width = 1280
    var height = 720
    var originX = 100.0
    var originY = 100.0
    var out: URL?
    var count = 300
    var every = 30
    var next: URL?
    var switchAt = 2.0
    var transition = 2.7
    var pattern = MilkTransitionPattern.random

    init(_ arguments: [String]) {
        var args = arguments[...]
        mode = args.popFirst() ?? ""
        func value(_ flag: String) -> String {
            guard let v = args.popFirst() else { fail("\(flag) needs a value") }
            return v
        }
        func pair(_ flag: String, _ separator: Character) -> (Double, Double) {
            let parts = value(flag).split(separator: separator).compactMap { Double($0) }
            guard parts.count == 2 else { fail("\(flag) needs A\(separator)B") }
            return (parts[0], parts[1])
        }
        while let flag = args.popFirst() {
            switch flag {
            case "--preset": preset = URL(fileURLWithPath: value(flag))
            case "--seconds": seconds = Double(value(flag)) ?? seconds
            case "--size": let (w, h) = pair(flag, "x"); width = Int(w); height = Int(h)
            case "--origin": (originX, originY) = pair(flag, ",")
            case "--out": out = URL(fileURLWithPath: value(flag))
            case "--count": count = Int(value(flag)) ?? count
            case "--every": every = max(1, Int(value(flag)) ?? every)
            case "--next": next = URL(fileURLWithPath: value(flag))
            case "--switch-at": switchAt = Double(value(flag)) ?? switchAt
            case "--transition": transition = Double(value(flag)) ?? transition
            case "--pattern":
                let name = value(flag)
                guard let p = MilkTransitionPattern.allCases.first(where: { "\($0)" == name }) else {
                    fail("unknown pattern \(name)")
                }
                pattern = p
            default: fail("unknown option \(flag)")
            }
        }
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))

@MainActor
func makeRenderer(pixelFormat: MTLPixelFormat) -> MilkRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
    do {
        let renderer = try MilkRenderer(device: device, pixelFormat: pixelFormat)
        // Frames and captures should show the preset's shaders from the first frame.
        renderer.compilesShadersInBackground = false
        if let url = options.preset { try renderer.load(MilkPreset(contentsOf: url)) }
        for error in renderer.presetErrors { print("preset: \(error)") }
        renderer.transitionPattern = options.pattern
        print("device \(device.name)")
        return renderer
    } catch {
        fail("\(error)")
    }
}

/// Loads `--next` with the transition, once.
@MainActor
func switchToNext(_ renderer: MilkRenderer) {
    guard let url = options.next else { return }
    do {
        try renderer.load(MilkPreset(contentsOf: url), transition: options.transition)
        for error in renderer.presetErrors { print("next preset: \(error)") }
    } catch {
        fail("\(error)")
    }
}

// MARK: - Offscreen frames

@MainActor
func renderFrames() {
    guard let out = options.out else { fail("frames needs --out DIR") }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let renderer = makeRenderer(pixelFormat: .bgra8Unorm)
    let device = renderer.device
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: options.width, height: options.height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue() else {
        fail("cannot make the target texture")
    }

    let fps = 60.0
    var synth = SynthAudio()
    let samplesPerFrame = Int(synth.sampleRate / fps)
    let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: samplesPerFrame * 2)
    defer { buffer.deallocate() }
    var pixels = [UInt8](repeating: 0, count: options.width * options.height * 4)
    let start = Date()
    let switchFrame = Int((options.switchAt * fps).rounded())

    for frame in 0..<options.count {
        if frame == switchFrame { switchToNext(renderer) }
        synth.render(into: buffer, frames: samplesPerFrame)
        renderer.feed(samples: UnsafeBufferPointer(buffer), channels: 2, sampleRate: synth.sampleRate)
        guard let commandBuffer = queue.makeCommandBuffer() else { fail("no command buffer") }
        renderer.render(to: texture, commandBuffer: commandBuffer, time: Double(frame) / fps)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard (frame + 1) % options.every == 0 else { continue }
        texture.getBytes(&pixels, bytesPerRow: options.width * 4,
                         from: MTLRegionMake2D(0, 0, options.width, options.height), mipmapLevel: 0)
        writePNG(bgra: pixels, width: options.width, height: options.height,
                 to: out.appendingPathComponent(String(format: "%04d.png", frame + 1)))
    }
    print(String(format: "frames %d in %.2f s", options.count, Date().timeIntervalSince(start)))
}

func writePNG(bgra: [UInt8], width: Int, height: Int, to url: URL) {
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    guard let provider = CGDataProvider(data: Data(bgra) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

// MARK: - Window

@MainActor
final class DemoApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var feeder: Timer?
    private var synth = SynthAudio()
    private var fedFrames = 0
    private let started = Date()
    private let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: 48_000 * 2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let renderer = makeRenderer(pixelFormat: .bgra8Unorm)
        let view: MilkView
        do { view = try MilkView(renderer: renderer) } catch { fail("\(error)") }

        // Origin is given from the top left; AppKit's is the bottom left of the main screen.
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let size = NSSize(width: options.width, height: options.height)
        let origin = NSPoint(x: options.originX, y: screenHeight - options.originY - size.height)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        self.window = window
        NSApp.activate()

        // Feed audio at the real sample rate, catching up to wall-clock time on each tick.
        feeder = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.feed(renderer) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("window \(window.windowNumber) \(Int(options.originX)) \(Int(options.originY)) \(options.width) \(options.height)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.switchAt) { switchToNext(renderer) }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { NSApp.terminate(nil) }
    }

    private func feed(_ renderer: MilkRenderer) {
        let due = Int(Date().timeIntervalSince(started) * synth.sampleRate) - fedFrames
        let frames = min(max(due, 0), buffer.count / 2)
        guard frames > 0 else { return }
        synth.render(into: buffer, frames: frames)
        renderer.feed(samples: UnsafeBufferPointer(rebasing: buffer[..<(frames * 2)]), channels: 2,
                      sampleRate: synth.sampleRate)
        fedFrames += frames
    }
}

MainActor.assumeIsolated {
    switch options.mode {
    case "info":
        guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
        print("device \(device.name)")
        let families: [(String, MTLGPUFamily)] = [("apple7", .apple7), ("apple8", .apple8), ("apple9", .apple9),
                                                 ("mac2", .mac2), ("metal3", .metal3)]
        print("families " + families.filter { device.supportsFamily($0.1) }.map(\.0).joined(separator: " "))
        print("max threads per group \(device.maxThreadsPerThreadgroup.width)")
    case "frames":
        renderFrames()
    case "window":
        let app = NSApplication.shared
        let delegate = DemoApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    default:
        fail("usage: milkview-demo window|frames [options]")
    }
}
