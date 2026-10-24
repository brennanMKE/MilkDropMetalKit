/// MilkDrop 2 warp and composite shaders (handoff §5.2).
///
/// Preset shader bodies are HLSL that assume a MilkDrop prelude (`sampler_main`, `sampler_blur1`–`3`, `GetBlur1()`,
/// `q1`–`q32`, `time`, `texsize`, …). `milkconvert` wraps each body in the prelude and translates
/// HLSL → SPIR-V → MSL offline; this module loads the translated MSL and caches compiled pipelines.
///
/// Status: placeholder until milestone 4.
public enum ShaderStage: String, Sendable, CaseIterable {
    case warp
    case composite
}

/// MSL translated ahead of time for one preset stage.
public struct TranslatedShader: Sendable, Equatable {
    public var stage: ShaderStage
    public var metalSource: String
    public var entryPoint: String

    public init(stage: ShaderStage, metalSource: String, entryPoint: String) {
        self.stage = stage
        self.metalSource = metalSource
        self.entryPoint = entryPoint
    }
}
