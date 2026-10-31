import Foundation

/// MilkDrop 2 warp and composite shaders (handoff §5.2).
///
/// Preset shader bodies are HLSL (Shader Model 2/3 era) that assume MilkDrop's prelude: `sampler_main`,
/// `sampler_blur1`–`3`, `GetBlur1()`, `q1`–`q32`, `time`, `texsize`, and so on. `ShaderTranslator` translates a body
/// to Metal Shading Language directly in Swift, at preset load, so user `.milk` files work with no toolchain on
/// board; `milkconvert` runs the same translator ahead of time to check a pack.
package enum ShaderStage: String, Sendable, CaseIterable {
    case warp
    case composite
}

/// A preset shader translated to MSL. Compile `metalSource` with `makeLibrary(source:)` and build a pipeline from
/// `vertexFunction` and `fragmentFunction`; bind resources as `MilkShaderLayout` describes.
package struct TranslatedShader: Sendable, Equatable {
    package var stage: ShaderStage
    package var metalSource: String
    package var vertexFunction: String
    package var fragmentFunction: String
    /// The highest blur level the shader reads (0–3); the renderer computes that many.
    package var blurLevel: Int
    /// Disk textures the shader names (`sampler_clouds2` → "clouds2"), bound after the standard ones.
    package var userTextures: [String]

    package init(stage: ShaderStage, metalSource: String, vertexFunction: String, fragmentFunction: String,
                blurLevel: Int, userTextures: [String]) {
        self.stage = stage
        self.metalSource = metalSource
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction
        self.blurLevel = blurLevel
        self.userTextures = userTextures
    }
}

package enum ShaderTranslator {
    /// Translates a preset's warp or composite shader (the text of its `warp_N`/`comp_N` lines).
    package static func translate(_ hlsl: String, stage: ShaderStage) throws -> TranslatedShader {
        var preprocessor = try Prelude.preprocessor()
        let tokens = try preprocessor.process(try Lexer.tokenize(hlsl))
        var parser = Parser(tokens: tokens)
        let program = try parser.parseProgram()
        var emitter = Emitter(stage: stage)
        let source = try emitter.emit(program)
        return TranslatedShader(stage: stage, metalSource: source,
                                vertexFunction: stage == .warp ? "milk_warp_vertex" : "milk_quad_vertex",
                                fragmentFunction: "milk_fragment", blurLevel: emitter.blurLevel,
                                userTextures: emitter.userTextures)
    }
}

/// Where the renderer binds what translated shaders read.
package enum MilkShaderLayout {
    /// Fragment textures 0…9, then user textures from 10.
    package static let standardTextures = Prelude.standardTextures
    package static let maxUserTextures = Prelude.maxUserTextures
    /// Fragment buffer 0: `MilkShaderUniforms`. Fragment sampler 0: the main texture's default sampler (filtered;
    /// wrapped or clamped by the preset's `bTexWrap`). Vertex buffer 0 (warp only): the mesh.
    package static let uniformsIndex = 0
}

/// The uniforms translated shaders read, matching `MilkUniforms` in `Prelude`. All `float4`, so the Swift and MSL
/// layouts agree without padding rules. In the buffer, `MemoryLayout<MilkShaderUniforms>.stride` bytes are followed
/// by `rotationFloat4Count` float4s: MilkDrop 2's `rot_*` matrices (see `rotationMatrices`).
package struct MilkShaderUniforms: Sendable {
    /// time, fps, frame, progress
    package var c0: SIMD4<Float> = .zero
    /// bass, mid, treb, vol
    package var c1: SIMD4<Float> = .zero
    /// bass_att, mid_att, treb_att, vol_att
    package var c2: SIMD4<Float> = .zero
    /// aspectx, aspecty (≤ 1), and their inverses
    package var aspect: SIMD4<Float> = .one
    /// width, height, 1/width, 1/height
    package var texsize: SIMD4<Float> = .one
    /// q1–q32, four per vector
    package var q: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                   SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero,
                                                                              .zero, .zero, .zero, .zero)
    package var randFrame: SIMD4<Float> = .zero
    package var randPreset: SIMD4<Float> = .zero
    package var roamCos: SIMD4<Float> = .zero
    package var roamSin: SIMD4<Float> = .zero
    package var slowRoamCos: SIMD4<Float> = .zero
    package var slowRoamSin: SIMD4<Float> = .zero
    /// blur1_min, blur2_min, blur3_min, decay
    package var blurMin: SIMD4<Float> = .zero
    /// blur1_max, blur2_max, blur3_max, 0
    package var blurMax: SIMD4<Float> = .one
    /// scale1–3 for GetBlur1–3
    package var blurScale: SIMD4<Float> = .one
    /// bias1–3 for GetBlur1–3
    package var blurBias: SIMD4<Float> = .zero
    /// texsize_noise_lq, _lq_lite, _mq, _hq, texsize_noisevol_lq, _hq
    package var texsizeNoise: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.one, .one, .one, .one, .one, .one)
    package var texsizeUser: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                             SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.one, .one, .one, .one,
                                                                                      .one, .one, .one, .one)
    /// The composite's corner tints (`hue_shader`): bottom right, bottom left, top right, top left.
    package var hue: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.one, .one, .one, .one)

    package init() {}

    package static let rotationFloat4Count = 96

    package mutating func setQ(_ values: [Double]) {
        func v(_ i: Int) -> SIMD4<Float> {
            SIMD4((0..<4).map { k in i * 4 + k < values.count ? Float(values[i * 4 + k]) : 0 })
        }
        q = (v(0), v(1), v(2), v(3), v(4), v(5), v(6), v(7))
    }
}

package extension MilkShaderUniforms {
    /// MilkDrop 2's `rot_s1`…`rot_rand4`: 24 rotations, as float4x3 columns (four float3 columns, padded to float4).
    /// Each group turns about four fixed random axes at its own speed: static, slow, fast, very fast, ultra fast;
    /// the `rand` group is new every frame. MilkDrop's exact rates aren't documented; these are an approximation.
    static func rotationMatrices(time: Double, axes: [SIMD3<Double>], frameRandom: [Double]) -> [SIMD4<Float>] {
        let speeds = [0.0, 0.03, 0.15, 0.6, 2.4]
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(rotationFloat4Count)
        for group in 0..<6 {
            for k in 0..<4 {
                let axisIndex = (group * 4 + k) % max(axes.count, 1)
                let axis = axes.isEmpty ? SIMD3<Double>(0, 0, 1) : axes[axisIndex]
                let angle = group == 5
                    ? (frameRandom.isEmpty ? 0 : frameRandom[k % frameRandom.count] * 2 * .pi)
                    : Double(group * 4 + k) * 1.7 + time * speeds[group] * (1 + 0.25 * Double(k))
                let m = rotation(axis: axis, angle: angle)
                // HLSL float4x3: rows 0–2 the rotation, row 3 zero; stored transposed, so these are its rows.
                for row in 0..<3 { out.append(SIMD4(Float(m[row].x), Float(m[row].y), Float(m[row].z), 0)) }
                out.append(.zero)
            }
        }
        return out
    }

    private static func rotation(axis a: SIMD3<Double>, angle: Double) -> [SIMD3<Double>] {
        let length = (a * a).sum().squareRoot()
        let n = length > 0 ? a / length : SIMD3(0, 0, 1)
        let c = cos(angle), s = sin(angle), t = 1 - c
        return [
            SIMD3(t * n.x * n.x + c, t * n.x * n.y - s * n.z, t * n.x * n.z + s * n.y),
            SIMD3(t * n.x * n.y + s * n.z, t * n.y * n.y + c, t * n.y * n.z - s * n.x),
            SIMD3(t * n.x * n.z - s * n.y, t * n.y * n.z + s * n.x, t * n.z * n.z + c),
        ]
    }
}

/// `manifest.json` in a `.milkpreset` bundle.
package struct BundleManifest: Codable, Sendable {
    package struct Shader: Codable, Sendable {
        package var file: String
        package var blurLevel: Int
        package var userTextures: [String]

        package init(file: String, blurLevel: Int, userTextures: [String]) {
            self.file = file
            self.blurLevel = blurLevel
            self.userTextures = userTextures
        }
    }

    package var format = 1
    /// Translated stages by name: "warp", "composite".
    package var shaders: [String: Shader]
    /// Stages that didn't translate; the renderer runs its fixed-function pass for them.
    package var errors: [String]

    package init(shaders: [String: Shader], errors: [String]) {
        self.shaders = shaders
        self.errors = errors
    }
}
