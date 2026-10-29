import Foundation
import Metal
import MilkPresetFormat
import MilkShaders

/// Errors from creating a `MilkRenderer`, and from compiling a preset's shaders (those are reported through
/// `MilkRenderer.presetErrors`, not thrown to the host).
///
/// The text in `description` and in the associated strings is for display only; its wording is not API.
public enum MilkRendererError: Error, Equatable {
    /// The pixel format, by raw value, isn't one the renderer draws into; see `MilkRenderer.supportedPixelFormats`.
    case unsupportedPixelFormat(MTLPixelFormat.RawValue)
    /// A shader didn't compile. For the renderer's built-in shaders this is a package bug; the string is Metal's
    /// message or the stage that failed.
    case shaderCompilation(String)
    /// The device couldn't make a resource (a command queue, buffer, texture or sampler); the string names it.
    case resourceCreation(String)
}

extension MilkRendererError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .unsupportedPixelFormat(let raw):
            "Unsupported pixel format (MTLPixelFormat raw value \(raw)). Use one of bgra8Unorm, bgra8Unorm_srgb, "
                + "rgba16Float, rgb10a2Unorm or bgr10a2Unorm."
        case .shaderCompilation(let message):
            "A shader didn't compile: \(message)"
        case .resourceCreation(let resource):
            "The Metal device couldn't create a resource: \(resource)."
        }
    }

    public var errorDescription: String? { description }
}

/// Renders MilkDrop presets with Metal. Audio in through `feed`, frames out through `render`.
///
/// Main-actor bound so a display-link driven view can use it directly; `feed` is nonisolated, allocation-free
/// and lock-free so a host can call it from an audio tap.
///
/// Each frame, in MilkDrop's (and Butterchurn's) order: per-frame equations; per-vertex equations over the mesh;
/// the warp pass from the previous feedback texture into the next; the blur levels the preset's shaders read;
/// motion vectors, custom shapes, custom waves, the built-in waveform, the darkened centre and the borders on top;
/// then the composite to `texture`. A MilkDrop 2 preset's warp and composite shaders, translated to Metal at load,
/// replace the fixed-function warp and composite.
///
/// A transition (`load(_:transition:)`) runs both presets' equations each frame. The incoming preset takes over
/// vertex by vertex in a blend pattern: the warp mesh, the warp pass and the composite are mixed per vertex, frame
/// settings ease across, and each preset's custom waves and shapes fade with it.
@MainActor
public final class MilkRenderer {
    /// The device the renderer was created with. Textures and command buffers passed to `render` must come from it.
    public let device: MTLDevice
    /// The format `render(to:commandBuffer:time:)` draws in. The target texture's `pixelFormat` must equal it.
    public let pixelFormat: MTLPixelFormat
    /// The current preset; during a transition, the incoming one.
    public var preset: MilkPreset? { active.preset }
    /// Problems with the current preset: equation blocks that didn't compile (they're skipped), shaders that didn't
    /// translate or compile (the fixed-function warp or composite runs instead), and disk textures it names that
    /// aren't available. Compile errors can arrive shortly after `load` when shaders compile in the background.
    public var presetErrors: [String] {
        let shaders = active.shaders
        var errors = active.runtime.errors + shaders.errors
        if !shaders.missingTextures.isEmpty {
            errors.append("textures not available, noise used instead: \(shaders.missingTextures.joined(separator: ", "))")
        }
        return errors
    }
    /// The pattern the next transitions use. MilkDrop 2 picks one at random each time (`.random`, the default).
    public var transitionPattern = MilkTransitionPattern.random
    /// True from a `load` with a transition until the outgoing preset has gone.
    public var isTransitioning: Bool { transition != nil }
    /// Compile preset shaders in the background (the default), so loading never stalls drawing; the fixed-function
    /// passes stand in for the fraction of a second it takes. Offscreen rendering that must be reproducible sets this
    /// to false.
    public var compilesShadersInBackground = true
    /// True while the current preset's shaders are still compiling.
    public var isCompilingShaders: Bool { active.shaders.isCompiling }
    /// The warp mesh resolution in cells; MilkDrop's default is 48×36.
    public var meshSize: (width: Int, height: Int) = (48, 36) {
        didSet {
            meshSize = (max(1, min(meshSize.width, 512)), max(1, min(meshSize.height, 512)))
            indexBuffer = nil
        }
    }

    nonisolated let audio = AudioRing()

    /// The feedback texture format: 8-bit like MilkDrop's and Butterchurn's. Presets are tuned for its rounding
    /// (dim trails settle instead of fading to black) and its clamping at 1.
    static let feedbackFormat = MTLPixelFormat.rgba8Unorm
    /// Frames the CPU may run ahead of the GPU; each has its own vertex buffers.
    private static let framesInFlight = 3

    private let commandQueue: MTLCommandQueue
    private let warpPipeline: MTLRenderPipelineState
    private let overlayPipelines: [OverlayKey: MTLRenderPipelineState]
    private let compositePipeline: MTLRenderPipelineState
    private let blurPipelines: (horizontal: MTLRenderPipelineState, vertical: MTLRenderPipelineState)
    /// Lays a transition's incoming warp or composite over the outgoing one, weighted per vertex.
    private let blendPipelines: (feedback: MTLRenderPipelineState, output: MTLRenderPipelineState)
    let samplers: Samplers
    private let inFlight = DispatchSemaphore(value: MilkRenderer.framesInFlight)
    private var frameSlots: [FrameSlot] = []
    private var slotIndex = 0
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var feedback: [MTLTexture] = []
    private var current = 0
    private(set) var blur = BlurTextures()
    private let noise: NoiseTextures
    private let pipelineCache = PipelineCache()

    private var analyzer = AudioAnalyzer()
    private var active: LoadedPreset
    private var transition: Transition?
    /// The outgoing preset's mesh during a transition, before it's mixed into the frame slot's.
    private var outgoingMesh: [MeshVertex] = []
    /// What a transition's incoming warp and composite render into before they're blended over the outgoing ones.
    private var scratch: (warp: MTLTexture, composite: MTLTexture)?
    private var overlays = OverlayBuilder()
    private var frame = 0
    private var lastTime: TimeInterval?
    private var fps = 60.0
    private var random = SplitMix(seed: 1)
    /// Set by `reset`: the current preset restarts at the next `render` unless `load` replaces it first.
    private var restartPending = false

    /// A preset with its compiled equations and shaders, and the randomness drawn for it at load.
    private struct LoadedPreset {
        var preset: MilkPreset?
        var runtime: PresetRuntime
        var shaders: PresetShaders
        /// For the composite's hue corners (Butterchurn's `rand_start`).
        var randStart: SIMD4<Double>
        /// For shaders (`rand_preset`) and the axes of the `rot_*` matrices.
        var randPreset: SIMD4<Double>
        var rotationAxes: [SIMD3<Double>]
    }

    private struct Transition {
        var outgoing: LoadedPreset
        var duration: TimeInterval
        /// Set by the first frame rendered after `load`, since `load` doesn't know the clock.
        var start: TimeInterval?
        /// Made by the first frame too, for its mesh size and aspect ratio.
        var pattern: BlendPattern?
    }

    /// A frame of a transition in progress.
    private struct Blend {
        var outgoing: LoadedPreset
        var state: FrameState
        var progress: Double
    }

    private struct FrameSlot {
        var mesh: MTLBuffer
        var overlay: MTLBuffer
        /// The incoming preset's weight at each mesh vertex during a transition.
        var weights: MTLBuffer
    }

    struct OverlayKey: Hashable {
        var points: Bool
        var textured: Bool
        var additive: Bool
    }

    struct Samplers {
        let linearWrap, linearClamp, pointWrap, pointClamp: MTLSamplerState
    }

    /// The three blur levels: each a horizontal pass into `horizontal[i]`, then vertical into `vertical[i]`.
    struct BlurTextures {
        var horizontal: [MTLTexture] = []
        var vertical: [MTLTexture] = []
    }

    /// Creates a renderer that draws into textures of `pixelFormat` on `device`, with no preset loaded (it draws
    /// the default waveform until `load` is called).
    ///
    /// Compiles the built-in pipelines and allocates noise textures, so it takes a moment; create one renderer and
    /// keep it. Throws `MilkRendererError.unsupportedPixelFormat` when `pixelFormat` isn't in
    /// `supportedPixelFormats`, `.resourceCreation` when the device runs out of resources, and `.shaderCompilation`
    /// if a built-in shader doesn't compile (a package bug).
    public init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard Self.supportedPixelFormats.contains(pixelFormat) else {
            throw MilkRendererError.unsupportedPixelFormat(pixelFormat.rawValue)
        }
        self.device = device
        self.pixelFormat = pixelFormat
        guard let queue = device.makeCommandQueue() else { throw MilkRendererError.resourceCreation("command queue") }
        commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw MilkRendererError.shaderCompilation("\(error)")
        }
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat,
                      blend: (MTLBlendFactor, MTLBlendFactor)? = nil,
                      keepAlpha: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            if let (source, destination) = blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = source
                a.destinationRGBBlendFactor = destination
                a.sourceAlphaBlendFactor = keepAlpha ? .zero : source
                a.destinationAlphaBlendFactor = keepAlpha ? .one : destination
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                throw MilkRendererError.shaderCompilation("\(fragment): \(error)")
            }
        }
        warpPipeline = try pipeline("warp_vertex", "warp_fragment", format: Self.feedbackFormat)
        var overlayPipelines: [OverlayKey: MTLRenderPipelineState] = [:]
        for points in [false, true] {
            for textured in [false, true] where !(points && textured) {
                for additive in [false, true] {
                    let fragment = points ? "overlay_point_fragment"
                        : (textured ? "overlay_textured_fragment" : "overlay_fragment")
                    overlayPipelines[OverlayKey(points: points, textured: textured, additive: additive)] =
                        try pipeline(points ? "overlay_point_vertex" : "overlay_vertex", fragment,
                                     format: Self.feedbackFormat,
                                     blend: (.sourceAlpha, additive ? .one : .oneMinusSourceAlpha))
                }
            }
        }
        self.overlayPipelines = overlayPipelines
        compositePipeline = try pipeline("quad_vertex", "composite_fragment", format: pixelFormat)
        blurPipelines = (try pipeline("quad_vertex", "blur_horizontal_fragment", format: Self.feedbackFormat),
                         try pipeline("quad_vertex", "blur_vertical_fragment", format: Self.feedbackFormat))
        // The feedback's alpha stays 1: textured shapes multiply by it.
        blendPipelines = (try pipeline("blend_vertex", "blend_fragment", format: Self.feedbackFormat,
                                       blend: (.sourceAlpha, .oneMinusSourceAlpha), keepAlpha: true),
                          try pipeline("blend_vertex", "blend_fragment", format: pixelFormat,
                                       blend: (.sourceAlpha, .oneMinusSourceAlpha), keepAlpha: true))

        func sampler(_ filter: MTLSamplerMinMagFilter, _ mode: MTLSamplerAddressMode) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.sAddressMode = mode
            d.tAddressMode = mode
            d.rAddressMode = mode
            guard let s = device.makeSamplerState(descriptor: d) else {
                throw MilkRendererError.resourceCreation("sampler")
            }
            return s
        }
        samplers = Samplers(linearWrap: try sampler(.linear, .repeat), linearClamp: try sampler(.linear, .clampToEdge),
                            pointWrap: try sampler(.nearest, .repeat), pointClamp: try sampler(.nearest, .clampToEdge))
        noise = try NoiseTextures(device: device)
        active = LoadedPreset(preset: nil, runtime: PresetRuntime(model: PresetModel()), shaders: .none,
                              randStart: .zero, randPreset: .zero, rotationAxes: [])
        active = loaded(nil, runtime: active.runtime, shaders: .none)
    }

    private func loaded(_ preset: MilkPreset?, runtime: PresetRuntime, shaders: PresetShaders) -> LoadedPreset {
        let randStart = random.vector()
        let randPreset = random.vector()
        let axes = (0..<24).map { _ in SIMD3(random.unit() - 0.5, random.unit() - 0.5, random.unit() - 0.5) }
        return LoadedPreset(preset: preset, runtime: runtime, shaders: shaders, randStart: randStart,
                            randPreset: randPreset, rotationAxes: axes)
    }

    /// The pixel formats `init(device:pixelFormat:)` accepts: the ones a `CAMetalLayer` can show. Check this before
    /// creating a renderer for a format you didn't choose.
    public nonisolated static let supportedPixelFormats: Set<MTLPixelFormat> = [
        .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float, .rgb10a2Unorm, .bgr10a2Unorm,
    ]

    /// Hands the renderer audio. Interleaved Float32 at `sampleRate`; stereo is expected, one channel is duplicated
    /// to both sides, and channels past two are ignored.
    ///
    /// Nonisolated: call it from any thread (typically the audio tap's), but **from one thread at a time**. The ring
    /// behind it is single-producer, so two threads feeding at once (two taps, or a tap plus a main-thread synth)
    /// race. It copies into a 4,096-frame ring without allocating, locking or blocking, so it is safe on a real-time
    /// audio thread. The analyzer reads the newest 1,024 frames at each `render`.
    ///
    /// Feed audio in small chunks as it plays. The renderer doesn't pace what it's given: a large tap buffer (an
    /// `AVAudioEngine` tap often delivers about 100 ms at once) is seen as the same window for several frames, so
    /// the visuals step. Split such buffers and feed them over time, as the MilkDrop Gallery's `AudioPlayer` does.
    public nonisolated func feed(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        audio.write(samples: samples, channels: channels, sampleRate: sampleRate)
    }

    /// Switches to `preset`. Equations that don't compile are skipped and listed in `presetErrors`.
    ///
    /// With a `transition` of more than 0 seconds the current preset keeps running and hands over to the new one
    /// in `transitionPattern` over that time (a few seconds is typical); otherwise the switch is a cut.
    /// Either way the feedback image carries over, as in MilkDrop. Loading during a transition makes the preset
    /// that was coming in the outgoing one.
    public func load(_ preset: MilkPreset, transition: TimeInterval = 0) throws {
        restartPending = false
        let runtime = PresetRuntime(model: preset.model, seed: random.next())
        let shaders = PresetShaders(preset: preset, device: device, warpFormat: Self.feedbackFormat,
                                    compositeFormat: pixelFormat, cache: pipelineCache,
                                    synchronous: !compilesShadersInBackground)
        let outgoing = active
        active = loaded(preset, runtime: runtime, shaders: shaders)
        self.transition = transition > 0 && outgoing.preset != nil
            ? Transition(outgoing: outgoing, duration: transition) : nil
    }

    /// Puts the renderer back in the state a new one is in, so it can be reused and draw the frames a new renderer
    /// would: the feedback image and blur levels are cleared to black, the frame counter, clock and fps estimate
    /// start again, the random sequence restarts from its seed, any transition is dropped, the audio fed so far is
    /// forgotten and the audio levels start from their defaults.
    ///
    /// The current preset stays loaded. If `load` comes next, the result is a new renderer that loaded that preset;
    /// otherwise the current preset starts again from its `per_frame_init` equations at the next `render`, as if a
    /// new renderer had loaded it. Compiled shaders and settings (`transitionPattern`, `meshSize`,
    /// `compilesShadersInBackground`) are kept.
    ///
    /// Call it when nothing is feeding audio on another thread, or a few of those samples may survive the reset.
    public func reset() {
        transition = nil
        outgoingMesh = []
        frame = 0
        lastTime = nil
        fps = 60
        audio.clear()
        analyzer = AudioAnalyzer()
        // The random draws `init` makes; `load`, or the restart at the next `render`, makes the rest.
        random = SplitMix(seed: 1)
        _ = loaded(nil, runtime: active.runtime, shaders: .none)
        restartPending = true
        if !feedback.isEmpty { clear(feedback + blur.horizontal + blur.vertical) }
    }

    /// After `reset`, restarts the current preset the way `load` would have loaded it, unless `load` came first.
    private func restartIfPending() {
        guard restartPending else { return }
        restartPending = false
        guard let preset = active.preset else { return }
        let runtime = PresetRuntime(model: preset.model, seed: random.next())
        active = loaded(preset, runtime: runtime, shaders: active.shaders)
    }

    /// Renders one frame into `texture` (e.g. a `CAMetalLayer` drawable's) at `time` seconds, encoding into
    /// `commandBuffer`. `MilkView` calls this for you; call it yourself to draw into your own layer or offscreen.
    ///
    /// The contract:
    /// - `texture.pixelFormat` must equal `pixelFormat`, and the texture needs `.renderTarget` usage. A mismatched
    ///   format fails Metal's pipeline validation (debug builds also assert).
    /// - **Commit every command buffer you pass.** The renderer keeps up to three frames in flight, waiting on a
    ///   semaphore that is signalled only when a buffer completes. A buffer that's never committed never completes,
    ///   so the fourth call after it blocks the main thread forever. The wait also means `render` blocks the main
    ///   actor whenever the GPU is three frames behind.
    /// - `time` is the preset's `time` and drives its `fps` and transition progress, so it should rise steadily
    ///   (e.g. seconds since you started drawing). Each `MilkView` starts its own clock at 0.
    /// - If the renderer can't allocate its textures or buffers for this size (or the texture is 0×0), it returns
    ///   without encoding anything; the command buffer is left untouched and the frame is skipped.
    public func render(to texture: MTLTexture, commandBuffer: MTLCommandBuffer, time: TimeInterval) {
        assert(texture.pixelFormat == pixelFormat,
               "MilkRenderer.render: texture pixelFormat \(texture.pixelFormat.rawValue) != renderer's \(pixelFormat.rawValue)")
        let width = texture.width, height = texture.height
        guard width > 0, height > 0 else { return }
        do {
            try prepareResources(width: width, height: height)
        } catch {
            return
        }
        restartIfPending()
        inFlight.wait()
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        let slot = frameSlots[slotIndex]
        slotIndex = (slotIndex + 1) % frameSlots.count

        // Clock and audio.
        if let lastTime, time > lastTime {
            let instant = 1 / (time - lastTime)
            fps = min(max(fps * 0.93 + instant * 0.07, 1), 240)
        }
        lastTime = time
        analyzer.update(from: audio, fps: fps)

        // Equations.
        let inputs = FrameInputs(time: time, fps: fps, frame: frame, levels: analyzer.levels, mesh: meshSize,
                                 pixels: (width, height), aspect: Aspect(width: width, height: height))
        var state = active.runtime.runFrame(inputs)
        let (gw, gh) = meshSize
        let vertexCount = (gw + 1) * (gh + 1)
        let mesh = slot.mesh.contents().bindMemory(to: MeshVertex.self, capacity: vertexCount)
        active.runtime.computeMesh(inputs, into: mesh)
        let blend = blendFrame(inputs, mesh: mesh, weights: slot.weights)
        if let blend { state = FrameState.mixed(from: blend.state, to: state, progress: blend.progress) }
        frame += 1

        // Overlays, in MilkDrop's order. During a transition each preset's shapes and waves fade with it.
        overlays.reset(width: width, height: height, aspect: inputs.aspect)
        overlays.addMotionVectors(state, mesh: mesh, meshSize: meshSize)
        addCustomOverlays(active, inputs, alpha: blend?.progress ?? 1)
        if let blend { addCustomOverlays(blend.outgoing, inputs, alpha: 1 - blend.progress) }
        overlays.addBasicWave(state, left: analyzer.waveLeft, right: analyzer.waveRight,
                              oldMode: blend?.state.waveMode, progress: blend?.progress ?? 1)
        overlays.addDarkenCenter(state)
        overlays.addBorders(state)
        let overlayBuffer = overlayBuffer(for: slot, count: overlays.vertices.count)
        overlays.vertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            overlayBuffer.contents().copyMemory(from: base, byteCount: raw.count)
        }

        // Warp into the next feedback texture, blur it, then draw the overlays on top. In a transition the
        // outgoing preset warps first and the incoming one is laid over it.
        let previous = feedback[current]
        current = 1 - current
        let target = feedback[current]
        let uniforms = shaderUniforms(active, state, blur: state, inputs, width: width, height: height)
        var outgoingUniforms: [SIMD4<Float>] = []
        var blurLevel = active.shaders.blurLevel
        if let blend, let scratch = scratchTextures(width: width, height: height) {
            outgoingUniforms = shaderUniforms(blend.outgoing, blend.state, blur: state, inputs, width: width,
                                              height: height)
            blurLevel = max(blurLevel, blend.outgoing.shaders.blurLevel)
            encodeWarpPass(commandBuffer, blend.outgoing, state: blend.state, uniforms: outgoingUniforms,
                           from: previous, into: target, mesh: slot.mesh)
            encodeWarpPass(commandBuffer, active, state: state, uniforms: uniforms, from: previous,
                           into: scratch.warp, mesh: slot.mesh)
            encodeBlend(commandBuffer, scratch.warp, over: target, mesh: slot.mesh, weights: slot.weights,
                        pipeline: blendPipelines.feedback)
        } else {
            encodeWarpPass(commandBuffer, active, state: state, uniforms: uniforms, from: previous, into: target,
                           mesh: slot.mesh)
        }
        if blurLevel > 0 {
            encodeBlur(commandBuffer, from: target, levels: blurLevel, state: state)
        }
        encodeOverlays(commandBuffer, into: target, previous: previous, buffer: overlayBuffer)

        // Composite to the caller's texture.
        if let blend, let scratch = scratchTextures(width: width, height: height) {
            encodeCompositePass(commandBuffer, blend.outgoing, state: blend.state, uniforms: outgoingUniforms,
                                from: target, into: texture)
            encodeCompositePass(commandBuffer, active, state: state, uniforms: uniforms, from: target,
                                into: scratch.composite)
            encodeBlend(commandBuffer, scratch.composite, over: texture, mesh: slot.mesh, weights: slot.weights,
                        pipeline: blendPipelines.output)
        } else {
            encodeCompositePass(commandBuffer, active, state: state, uniforms: uniforms, from: target, into: texture)
        }
    }

    // MARK: Transitions

    /// Advances the transition, if there is one: runs the outgoing preset's equations, mixes its mesh into `mesh`
    /// by the blend pattern and writes each vertex's incoming weight to `weights`. Nil when not transitioning.
    private func blendFrame(_ inputs: FrameInputs, mesh: UnsafeMutablePointer<MeshVertex>,
                            weights: MTLBuffer) -> Blend? {
        guard var t = transition else { return nil }
        let start = t.start ?? inputs.time
        let progress = (inputs.time - start) / t.duration
        guard progress < 1 else {
            transition = nil
            return nil
        }
        t.start = start
        let pattern: BlendPattern
        if let p = t.pattern, p.meshSize == inputs.mesh, p.aspect == inputs.aspect {
            pattern = p
        } else {
            pattern = BlendPattern(transitionPattern, meshSize: inputs.mesh, aspect: inputs.aspect, random: &random)
            t.pattern = pattern
        }
        transition = t

        let state = t.outgoing.runtime.runFrame(inputs)
        let count = (inputs.mesh.width + 1) * (inputs.mesh.height + 1)
        if outgoingMesh.count != count {
            outgoingMesh = [MeshVertex](repeating: MeshVertex(x: 0, y: 0, u: 0, v: 0), count: count)
        }
        outgoingMesh.withUnsafeMutableBufferPointer { t.outgoing.runtime.computeMesh(inputs, into: $0.baseAddress!) }
        let w = weights.contents().bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            let weight = pattern.weight(i, progress: max(progress, 0))
            let old = outgoingMesh[i]
            mesh[i].u = mesh[i].u * weight + old.u * (1 - weight)
            mesh[i].v = mesh[i].v * weight + old.v * (1 - weight)
            w[i] = weight
        }
        return Blend(outgoing: t.outgoing, state: state, progress: max(progress, 0))
    }

    /// A preset's custom shapes, then its custom waves, with their alpha scaled by `alpha`.
    private func addCustomOverlays(_ p: LoadedPreset, _ inputs: FrameInputs, alpha: Double) {
        let runtime = p.runtime
        for shape in runtime.shapes {
            for instance in shape.run(inputs, q: runtime.qAfterFrame, alpha: alpha) { overlays.addShape(instance) }
        }
        for wave in runtime.waves {
            if let points = wave.run(inputs, q: runtime.qAfterFrame, audio: analyzer, waveScale: runtime.waveScale,
                                     alpha: alpha) {
                overlays.addCustomWave(points, dots: wave.usesDots, thick: wave.isThick, additive: wave.isAdditive)
            }
        }
    }

    /// Draws `incoming` over `target` through the mesh, each vertex weighted by the incoming preset's share.
    private func encodeBlend(_ commandBuffer: MTLCommandBuffer, _ incoming: MTLTexture, over target: MTLTexture,
                             mesh: MTLBuffer, weights: MTLBuffer, pipeline: MTLRenderPipelineState) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass), let indexBuffer else { return }
        encoder.label = "MilkRenderer.blend"
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(mesh, offset: 0, index: 0)
        encoder.setVertexBuffer(weights, offset: 0, index: 1)
        encoder.setFragmentTexture(incoming, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
    }

    /// Render targets the size of the screen for a transition's incoming passes, made on first use.
    private func scratchTextures(width: Int, height: Int) -> (warp: MTLTexture, composite: MTLTexture)? {
        if let scratch, scratch.warp.width == width, scratch.warp.height == height { return scratch }
        scratch = try? (makeTarget(width: width, height: height, label: "transitionWarp"),
                        makeTarget(width: width, height: height, label: "transitionComposite", format: pixelFormat))
        return scratch
    }

    // MARK: Passes

    /// A preset's warp: its shader if it has one, otherwise the fixed-function pass.
    private func encodeWarpPass(_ commandBuffer: MTLCommandBuffer, _ p: LoadedPreset, state: FrameState,
                                uniforms: [SIMD4<Float>], from previous: MTLTexture, into target: MTLTexture,
                                mesh: MTLBuffer) {
        if let warp = p.shaders.warp {
            encodeShaderPass(commandBuffer, warp, main: previous, into: target, uniforms: uniforms, state: state,
                             mesh: mesh)
        } else {
            encodeWarp(commandBuffer, from: previous, into: target, mesh: mesh, state: state)
        }
    }

    /// A preset's composite: its shader if it has one, otherwise the fixed-function pass.
    private func encodeCompositePass(_ commandBuffer: MTLCommandBuffer, _ p: LoadedPreset, state: FrameState,
                                     uniforms: [SIMD4<Float>], from source: MTLTexture, into texture: MTLTexture) {
        if let composite = p.shaders.composite {
            encodeShaderPass(commandBuffer, composite, main: source, into: texture, uniforms: uniforms, state: state,
                             mesh: nil)
        } else {
            encodeComposite(commandBuffer, from: source, into: texture, state: state, randStart: p.randStart)
        }
    }

    private func encodeWarp(_ commandBuffer: MTLCommandBuffer, from previous: MTLTexture, into target: MTLTexture,
                            mesh: MTLBuffer, state: FrameState) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass), let indexBuffer else { return }
        encoder.label = "MilkRenderer.warp"
        encoder.setRenderPipelineState(warpPipeline)
        encoder.setVertexBuffer(mesh, offset: 0, index: 0)
        encoder.setFragmentTexture(previous, index: 0)
        encoder.setFragmentSamplerState(state.wrap ? samplers.linearWrap : samplers.linearClamp, index: 0)
        var uniforms = WarpUniforms(decay: Float(state.decay))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WarpUniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
    }

    private func encodeOverlays(_ commandBuffer: MTLCommandBuffer, into target: MTLTexture, previous: MTLTexture,
                                buffer: MTLBuffer) {
        guard !overlays.batches.isEmpty else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "MilkRenderer.overlays"
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(previous, index: 0)
        encoder.setFragmentSamplerState(samplers.linearWrap, index: 0)
        // One pixel in clip units, for the thick-line offsets.
        let px = SIMD2<Float>(2 / Float(target.width), 2 / Float(target.height))
        for batch in overlays.batches {
            let points = batch.primitive == .points
            guard let pipeline = overlayPipelines[OverlayKey(points: points, textured: batch.textured && !points,
                                                             additive: batch.additive)] else { continue }
            encoder.setRenderPipelineState(pipeline)
            let type: MTLPrimitiveType = switch batch.primitive {
            case .triangles: .triangle
            case .lines: .line
            case .lineStrip: .lineStrip
            case .points: .point
            }
            let offsets: [SIMD2<Float>] = batch.thick ? [.zero, [px.x, 0], [0, -px.y], [px.x, -px.y]] : [.zero]
            let edge = batch.primitive == .triangles ? SIMD2<Float>.zero : px / 2
            for offset in offsets {
                var uniforms = OverlayUniforms(offset: offset, edge: edge, pointSize: batch.pointSize)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: type, vertexStart: batch.start, vertexCount: batch.count)
            }
        }
        encoder.endEncoding()
    }

    private func encodeComposite(_ commandBuffer: MTLCommandBuffer, from source: MTLTexture, into texture: MTLTexture,
                                 state: FrameState, randStart: SIMD4<Double>) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "MilkRenderer.composite"
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(samplers.linearWrap, index: 0)
        let hue = Self.hueCorners(time: state.time, randStart: randStart)
        var uniforms = CompositeUniforms(
            hue: (hue[0], hue[1], hue[2], hue[3]), gamma: Float(state.gamma),
            echoZoom: Float(state.echoZoom == 0 ? 1 : state.echoZoom), echoAlpha: Float(state.echoAlpha),
            fShader: Float(state.fShader), echoOrient: Int32(state.echoOrient),
            brighten: state.brighten ? 1 : 0, darken: state.darken ? 1 : 0,
            solarize: state.solarize ? 1 : 0, invert: state.invert ? 1 : 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Preset shaders

    /// A translated warp (`mesh` set) or composite (full-screen) shader pass.
    private func encodeShaderPass(_ commandBuffer: MTLCommandBuffer, _ program: PresetShaders.Program,
                                  main: MTLTexture, into target: MTLTexture, uniforms: [SIMD4<Float>],
                                  state: FrameState, mesh: MTLBuffer?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = mesh == nil ? .dontCare : .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "MilkRenderer.\(program.shader.stage.rawValue)Shader"
        encoder.setRenderPipelineState(program.pipeline)
        uniforms.withUnsafeBytes { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: MilkShaderLayout.uniformsIndex)
        }
        encoder.setFragmentSamplerState(state.wrap ? samplers.linearWrap : samplers.linearClamp, index: 0)
        var textures: [MTLTexture?] = [main] + blur.vertical + noise.all
        textures += Array(repeating: noise.mq, count: program.shader.userTextures.count)
        encoder.setFragmentTextures(textures, range: 0..<textures.count)
        if let mesh, let indexBuffer {
            encoder.setVertexBuffer(mesh, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    /// Everything `p`'s translated shaders read: `MilkShaderUniforms`, then the `rot_*` matrices. Empty when it has
    /// no shaders. The blur ranges come from `blur`, the settings the blur textures were made with.
    private func shaderUniforms(_ p: LoadedPreset, _ s: FrameState, blur: FrameState, _ inputs: FrameInputs,
                                width: Int, height: Int) -> [SIMD4<Float>] {
        guard p.shaders.warp != nil || p.shaders.composite != nil else { return [] }
        var u = MilkShaderUniforms()
        func f(_ x: Double) -> Float { Float(x) }
        let l = s.levels
        u.c0 = [f(s.time), f(inputs.fps), Float(inputs.frame), 0]
        u.c1 = [f(l.bass), f(l.mid), f(l.treb), f((l.bass + l.mid + l.treb) / 3)]
        u.c2 = [f(l.bassAtt), f(l.midAtt), f(l.trebAtt), f((l.bassAtt + l.midAtt + l.trebAtt) / 3)]
        u.aspect = [f(inputs.aspect.x), f(inputs.aspect.y), f(1 / inputs.aspect.x), f(1 / inputs.aspect.y)]
        u.texsize = [Float(width), Float(height), 1 / Float(width), 1 / Float(height)]
        u.setQ(p.runtime.qAfterFrame)
        u.randFrame = SIMD4<Float>(random.vector())
        u.randPreset = SIMD4<Float>(p.randPreset)
        let t = s.time
        func roam(_ rates: [Double], _ f: (Double) -> Double) -> SIMD4<Float> {
            SIMD4(rates.map { Float(0.5 + 0.5 * f(t * $0)) })
        }
        u.slowRoamCos = roam([0.005, 0.008, 0.013, 0.022], cos)
        u.slowRoamSin = roam([0.005, 0.008, 0.013, 0.022], sin)
        u.roamCos = roam([0.3, 1.3, 5.0, 20.0], cos)
        u.roamSin = roam([0.3, 1.3, 5.0, 20.0], sin)
        let (mins, maxs) = Self.blurRange(blur)
        u.blurMin = [f(mins[0]), f(mins[1]), f(mins[2]), f(s.decay)]
        u.blurMax = [f(maxs[0]), f(maxs[1]), f(maxs[2]), 0]
        u.blurScale = [f(maxs[0] - mins[0]), f(maxs[1] - mins[1]), f(maxs[2] - mins[2]), 0]
        u.blurBias = [f(mins[0]), f(mins[1]), f(mins[2]), 0]
        func size(_ n: Float) -> SIMD4<Float> { [n, n, 1 / n, 1 / n] }
        u.texsizeNoise = (size(256), size(32), size(256), size(256), size(32), size(32))
        let user = size(Float(noise.mq.width))
        u.texsizeUser = (user, user, user, user, user, user, user, user)
        let hue = Self.hueCorners(time: s.time, randStart: p.randStart)
        u.hue = (hue[0], hue[1], hue[2], hue[3])

        var out = [SIMD4<Float>](repeating: .zero, count: MemoryLayout<MilkShaderUniforms>.stride / 16)
        out.withUnsafeMutableBytes { raw in
            withUnsafeBytes(of: u) { raw.copyMemory(from: $0) }
        }
        out += MilkShaderUniforms.rotationMatrices(time: t, axes: p.rotationAxes,
                                                   frameRandom: [random.unit(), random.unit(), random.unit(), random.unit()])
        return out
    }

    // MARK: Blur

    /// The preset's blur ranges, each level inside the one before and at least 0.1 wide (Butterchurn's
    /// `getBlurValues`, with its collapsed-range case fixed to stay 0.1 wide).
    nonisolated static func blurRange(_ s: FrameState) -> ([Double], [Double]) {
        var mins = [s.blurMin.x, s.blurMin.y, s.blurMin.z]
        var maxs = [s.blurMax.x, s.blurMax.y, s.blurMax.z]
        let minDistance = 0.1
        for i in 0..<3 {
            if i > 0 {
                maxs[i] = min(maxs[i - 1], maxs[i])
                mins[i] = max(mins[i - 1], mins[i])
            }
            if maxs[i] - mins[i] < minDistance {
                let average = (mins[i] + maxs[i]) * 0.5
                mins[i] = average - minDistance * 0.5
                maxs[i] = average + minDistance * 0.5
            }
        }
        return (mins, maxs)
    }

    private static let blurWeights: [Float] = [4.0, 3.8, 3.5, 2.9, 1.9, 1.2, 0.7, 0.3]

    /// Blur levels 1…`levels` from `source`: each a horizontal pass that also normalises into the level's range,
    /// then a vertical pass that darkens the edges (level 1 only).
    private func encodeBlur(_ commandBuffer: MTLCommandBuffer, from source: MTLTexture, levels: Int, state: FrameState) {
        let w = Self.blurWeights
        let wH: SIMD4<Float> = [w[0] + w[1], w[2] + w[3], w[4] + w[5], w[6] + w[7]]
        let dH: SIMD4<Float> = [2 * w[1] / wH[0], 2 + 2 * w[3] / wH[1], 4 + 2 * w[5] / wH[2], 6 + 2 * w[7] / wH[3]]
        let w1V = w[0] + w[1] + w[2] + w[3], w2V = w[4] + w[5] + w[6] + w[7]
        let wV: SIMD4<Float> = [w1V, w2V, 0, 0]
        let dV: SIMD4<Float> = [2 * (w[2] + w[3]) / w1V, 2 + 2 * (w[6] + w[7]) / w2V, 0, 0]

        let (mins, maxs) = Self.blurRange(state)
        var scale = [1.0, 1.0, 1.0], bias = [0.0, 0.0, 0.0]
        scale[0] = 1 / (maxs[0] - mins[0])
        bias[0] = -mins[0] * scale[0]
        for i in 1..<3 {
            let lo = (mins[i] - mins[i - 1]) / (maxs[i - 1] - mins[i - 1])
            let hi = (maxs[i] - mins[i - 1]) / (maxs[i - 1] - mins[i - 1])
            scale[i] = 1 / (hi - lo)
            bias[i] = -lo * scale[i]
        }

        var input = source
        for level in 0..<min(levels, 3) {
            let horizontal = blur.horizontal[level], vertical = blur.vertical[level]
            func pass(_ pipeline: MTLRenderPipelineState, from src: MTLTexture, into dst: MTLTexture,
                      _ uniforms: BlurUniforms) {
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = dst
                d.colorAttachments[0].loadAction = .dontCare
                d.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: d) else { return }
                encoder.label = "MilkRenderer.blur\(level + 1)"
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(src, index: 0)
                encoder.setFragmentSamplerState(samplers.linearClamp, index: 0)
                var u = uniforms
                encoder.setFragmentBytes(&u, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            func texsize(_ t: MTLTexture) -> SIMD4<Float> {
                [Float(t.width), Float(t.height), 1 / Float(t.width), 1 / Float(t.height)]
            }
            pass(blurPipelines.horizontal, from: input, into: horizontal,
                 BlurUniforms(texsize: texsize(input), weights: wH, offsets: dH,
                              divisor: 0.5 / (wH[0] + wH[1] + wH[2] + wH[3]),
                              scale: Float(scale[level]), bias: Float(bias[level]), edgeDarken: 0))
            pass(blurPipelines.vertical, from: horizontal, into: vertical,
                 BlurUniforms(texsize: texsize(horizontal), weights: wV, offsets: dV, divisor: 1 / ((w1V + w2V) * 2),
                              scale: 1, bias: 0, edgeDarken: level == 0 ? Float(state.blur1EdgeDarken) : 0))
            input = vertical
        }
    }

    /// The composite's four corner tints (`hue_shader`): bottom right, bottom left, top right, top left.
    nonisolated static func hueCorners(time: Double, randStart r: SIMD4<Double>) -> [SIMD4<Float>] {
        (0..<4).map { i in
            let d = Double(i)
            var c = SIMD3<Double>(
                0.6 + 0.3 * sin(time * 30 * 0.0143 + 3 + d * 21 + r[3]),
                0.6 + 0.3 * sin(time * 30 * 0.0107 + 1 + d * 13 + r[1]),
                0.6 + 0.3 * sin(time * 30 * 0.0129 + 6 + d * 9 + r[2]))
            c = 0.5 + 0.5 * c / max(c.x, c.y, c.z)
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
        }
    }

    // MARK: Resources

    private func overlayBuffer(for slot: FrameSlot, count: Int) -> MTLBuffer {
        let needed = max(count, 1) * MemoryLayout<OverlayVertex>.stride
        if slot.overlay.length >= needed { return slot.overlay }
        // Rare: a preset with many shape instances. Grow this slot's buffer.
        let length = max(needed, slot.overlay.length * 2)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return slot.overlay }
        frameSlots[(slotIndex + frameSlots.count - 1) % frameSlots.count].overlay = buffer
        return buffer
    }

    private func prepareResources(width: Int, height: Int) throws {
        let (gw, gh) = meshSize
        let vertexCount = (gw + 1) * (gh + 1)
        if frameSlots.isEmpty || frameSlots[0].mesh.length < vertexCount * MemoryLayout<MeshVertex>.stride {
            frameSlots = try (0..<Self.framesInFlight).map { _ in
                guard let mesh = device.makeBuffer(length: vertexCount * MemoryLayout<MeshVertex>.stride,
                                                   options: .storageModeShared),
                      let overlay = device.makeBuffer(length: 65_536 * MemoryLayout<OverlayVertex>.stride,
                                                      options: .storageModeShared),
                      let weights = device.makeBuffer(length: vertexCount * MemoryLayout<Float>.stride,
                                                      options: .storageModeShared)
                else { throw MilkRendererError.resourceCreation("vertex buffers") }
                return FrameSlot(mesh: mesh, overlay: overlay, weights: weights)
            }
            slotIndex = 0
        }
        if indexBuffer == nil {
            var indices: [UInt32] = []
            indices.reserveCapacity(gw * gh * 6)
            let row = UInt32(gw + 1)
            for j in 0..<UInt32(gh) {
                for i in 0..<UInt32(gw) {
                    let a = j * row + i, b = a + 1, c = a + row, d = c + 1
                    indices += [a, c, b, b, c, d]
                }
            }
            indexCount = indices.count
            indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            guard indexBuffer != nil else { throw MilkRendererError.resourceCreation("index buffer") }
        }
        if feedback.first?.width != width || feedback.first?.height != height {
            feedback = try (0..<2).map { i in try makeTarget(width: width, height: height, label: "feedback\(i)") }
            blur = try makeBlurTextures(width: width, height: height)
            clear(feedback + blur.horizontal + blur.vertical)
        }
    }

    func makeTarget(width: Int, height: Int, label: String,
                    format: MTLPixelFormat = MilkRenderer.feedbackFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw MilkRendererError.resourceCreation(label) }
        t.label = "MilkRenderer.\(label)"
        return t
    }

    /// Butterchurn's blur sizes: each level's horizontal pass renders at its first ratio and the vertical pass at
    /// its second (half then quarter size, then an eighth, then a sixteenth). Widths round to 16, heights to 4.
    private func makeBlurTextures(width: Int, height: Int) throws -> BlurTextures {
        let ratios: [(Double, Double)] = [(0.5, 0.25), (0.125, 0.125), (0.0625, 0.0625)]
        func size(_ ratio: Double) -> (Int, Int) {
            let x = max(Double(width) * ratio, 16), y = max(Double(height) * ratio, 16)
            return (Int((x + 3) / 16) * 16, Int((y + 3) / 4) * 4)
        }
        var textures = BlurTextures()
        for (i, ratio) in ratios.enumerated() {
            let h = size(ratio.0), v = size(ratio.1)
            textures.horizontal.append(try makeTarget(width: h.0, height: h.1, label: "blur\(i + 1)h"))
            textures.vertical.append(try makeTarget(width: v.0, height: v.1, label: "blur\(i + 1)"))
        }
        return textures
    }

    /// New render targets start black; their initial contents are undefined.
    private func clear(_ textures: [MTLTexture]) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        for t in textures {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}

/// A small deterministic generator for per-preset randomness (`rand_start`, `rand_preset`, seeds).
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func vector() -> SIMD4<Double> {
        [unit(), unit(), unit(), unit()]
    }
}
