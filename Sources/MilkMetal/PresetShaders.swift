import Foundation
import Metal
internal import MilkPresetFormat
internal import MilkShaders

/// A preset's MilkDrop 2 shaders, translated and compiled into pipelines. A stage whose shader is missing or fails
/// to translate or compile is nil, and the renderer runs its fixed-function pass instead.
///
/// Translation is quick (a few milliseconds) and happens at load. Compiling with Metal takes tens of milliseconds
/// per shader, so by default it runs off the main actor and each stage switches over when its pipeline is ready;
/// until then the fixed-function pass stands in.
@MainActor
final class PresetShaders {
    struct Program {
        let pipeline: MTLRenderPipelineState
        let shader: TranslatedShader
    }

    private(set) var warp: Program?
    private(set) var composite: Program?
    private(set) var errors: [String] = []
    private let translated: [TranslatedShader]
    private var pending = 0

    /// The highest blur level either shader reads, known from translation.
    var blurLevel: Int { translated.map(\.blurLevel).max() ?? 0 }

    /// Disk textures the shaders name, which aren't available; noise stands in for them.
    var missingTextures: [String] { Array(Set(translated.flatMap(\.userTextures))).sorted() }

    /// True while a shader is still compiling.
    var isCompiling: Bool { pending > 0 }

    static let none = PresetShaders()

    private init() {
        translated = []
    }

    init(preset: MilkPreset, device: MTLDevice, warpFormat: MTLPixelFormat, compositeFormat: MTLPixelFormat,
         cache: PipelineCache, synchronous: Bool) {
        let model = preset.model
        var errors: [String] = []
        var translated: [(TranslatedShader, MTLPixelFormat)] = []
        for (text, stage, format) in [(model.warpShader, ShaderStage.warp, warpFormat),
                                      (model.compositeShader, .composite, compositeFormat)] {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let converted = preset.convertedShaders[stage.rawValue] {
                // Translated ahead of time by milkconvert.
                translated.append((TranslatedShader(
                    stage: stage, metalSource: converted.metalSource,
                    vertexFunction: stage == .warp ? "milk_warp_vertex" : "milk_quad_vertex",
                    fragmentFunction: "milk_fragment", blurLevel: converted.blurLevel,
                    userTextures: converted.userTextures), format))
                continue
            }
            do {
                translated.append((try ShaderTranslator.translate(text, stage: stage), format))
            } catch {
                errors.append("\(stage.rawValue) shader: \(error)")
            }
        }
        self.translated = translated.map(\.0)
        self.errors = errors

        for (shader, format) in translated {
            if synchronous {
                do {
                    install(Program(pipeline: try cache.pipeline(for: shader, format: format, device: device),
                                    shader: shader))
                } catch {
                    self.errors.append("\(shader.stage.rawValue) shader: \(Self.summary(of: error))")
                }
            } else {
                pending += 1
                Task { [weak self] in
                    do {
                        let pipeline = try await cache.compile(shader, format: format, device: device)
                        self?.install(Program(pipeline: pipeline, shader: shader))
                    } catch {
                        self?.errors.append("\(shader.stage.rawValue) shader: \(Self.summary(of: error))")
                    }
                    self?.pending -= 1
                }
            }
        }
    }

    private func install(_ program: Program) {
        switch program.shader.stage {
        case .warp: warp = program
        case .composite: composite = program
        }
    }

    /// The first line of a Metal compiler error, or the translator's message.
    nonisolated static func summary(of error: Error) -> String {
        let text = "\(error)"
        if let line = text.split(separator: "\n").first(where: { $0.contains("error:") }) {
            return String(line.drop(while: { $0 != "e" }).prefix(200))
        }
        return String(text.prefix(200))
    }
}

/// Compiled pipelines by MSL source and pixel format, so switching back to a preset doesn't recompile.
@MainActor
final class PipelineCache {
    private struct Key: Hashable {
        var source: String
        var format: MTLPixelFormat
    }

    private var pipelines: [Key: MTLRenderPipelineState] = [:]
    private var order: [Key] = []
    private let capacity = 64

    /// Compiles on the calling thread.
    func pipeline(for shader: TranslatedShader, format: MTLPixelFormat, device: MTLDevice) throws -> MTLRenderPipelineState {
        let key = Key(source: shader.metalSource, format: format)
        if let p = pipelines[key] { return p }
        let library = try device.makeLibrary(source: shader.metalSource, options: nil)
        let pipeline = try device.makeRenderPipelineState(descriptor: Self.descriptor(shader, format, library))
        store(pipeline, for: key)
        return pipeline
    }

    /// Compiles without blocking the main actor.
    func compile(_ shader: TranslatedShader, format: MTLPixelFormat, device: MTLDevice) async throws -> MTLRenderPipelineState {
        let key = Key(source: shader.metalSource, format: format)
        if let p = pipelines[key] { return p }
        let pipeline = try await Self.build(shader, format: format, device: device)
        store(pipeline, for: key)
        return pipeline
    }

    /// Off the main actor: Metal compiles on its own threads and calls back.
    private nonisolated static func build(_ shader: TranslatedShader, format: MTLPixelFormat,
                                          device: MTLDevice) async throws -> MTLRenderPipelineState {
        try await withCheckedThrowingContinuation { continuation in
            device.makeLibrary(source: shader.metalSource, options: nil) { library, error in
                guard let library else {
                    continuation.resume(throwing: error ?? MilkRendererError.pipelineCompilation(
                        function: shader.stage.rawValue, message: "Metal returned no library"))
                    return
                }
                device.makeRenderPipelineState(descriptor: descriptor(shader, format, library)) { pipeline, error in
                    if let pipeline {
                        continuation.resume(returning: pipeline)
                    } else {
                        continuation.resume(throwing: error ?? MilkRendererError.pipelineCompilation(
                            function: shader.stage.rawValue, message: "Metal returned no pipeline"))
                    }
                }
            }
        }
    }

    private func store(_ pipeline: MTLRenderPipelineState, for key: Key) {
        pipelines[key] = pipeline
        order.append(key)
        if order.count > capacity { pipelines[order.removeFirst()] = nil }
    }

    private nonisolated static func descriptor(_ shader: TranslatedShader, _ format: MTLPixelFormat,
                                   _ library: MTLLibrary) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.label = "MilkRenderer.\(shader.stage.rawValue)Shader"
        d.vertexFunction = library.makeFunction(name: shader.vertexFunction)
        d.fragmentFunction = library.makeFunction(name: shader.fragmentFunction)
        d.colorAttachments[0].pixelFormat = format
        return d
    }
}
