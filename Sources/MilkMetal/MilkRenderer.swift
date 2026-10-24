import Metal

public enum MilkRendererError: Error, Equatable {
    case unsupportedPixelFormat(MTLPixelFormat.RawValue)
}

/// Renders MilkDrop presets with Metal. Audio in through `feed`, frames out through `render`.
///
/// Main-actor bound so a display-link driven view can use it directly; `feed` is nonisolated, allocation-free
/// and lock-free so a host can call it from an audio tap.
///
/// Status: the API is in place and frames clear to black. The pipeline of handoff §2 lands from milestone 1.
@MainActor
public final class MilkRenderer {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    public private(set) var preset: MilkPreset?
    /// The warp mesh resolution in vertices; MilkDrop's default is 48×36.
    public var meshSize: (width: Int, height: Int) = (48, 36)

    nonisolated let audio = AudioRing()

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard Self.supportedPixelFormats.contains(pixelFormat) else {
            throw MilkRendererError.unsupportedPixelFormat(pixelFormat.rawValue)
        }
        self.device = device
        self.pixelFormat = pixelFormat
    }

    /// Formats a `CAMetalLayer` accepts, which is what hosts render into.
    static let supportedPixelFormats: Set<MTLPixelFormat> = [
        .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float, .rgb10a2Unorm, .bgr10a2Unorm,
    ]

    /// Called from any thread; copies into an internal ring. Interleaved Float32 at `sampleRate`
    /// (stereo expected; mono is duplicated).
    public nonisolated func feed(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        audio.write(samples: samples, channels: channels, sampleRate: sampleRate)
    }

    public func load(_ preset: MilkPreset, transition: TimeInterval = 0) throws {
        self.preset = preset
    }

    /// Renders one frame into `texture` (e.g. a `CAMetalLayer` drawable's) at `time` seconds.
    public func render(to texture: MTLTexture, commandBuffer: MTLCommandBuffer, time: TimeInterval) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "MilkRenderer.composite"
        encoder.endEncoding()
    }
}
