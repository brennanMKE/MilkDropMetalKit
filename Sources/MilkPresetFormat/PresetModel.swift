import Foundation

/// A parsed `.milk` preset: settings, equation source and shader source, before any compilation.
///
/// Keys are stored lowercased (MilkDrop reads them case-insensitively). Equation and shader bodies keep their
/// line order and are joined with newlines; nothing here evaluates or validates them.
package struct PresetModel: Sendable, Equatable {
    /// `MILKDROP_PRESET_VERSION` (100 for MilkDrop 1 files that omit it, 200/201 for MilkDrop 2).
    package var version: Int
    /// Pixel shader model of the warp shader (`PSVERSION_WARP`, else `PSVERSION`); 0 means none.
    package var warpShaderVersion: Int
    /// Pixel shader model of the composite shader (`PSVERSION_COMP`, else `PSVERSION`); 0 means none.
    package var compositeShaderVersion: Int

    /// Numeric `key=value` settings such as `zoom`, `fdecay`, `nwavemode`, `wave_r`.
    package var values: [String: Double]
    /// Non-numeric settings, kept so nothing in the file is silently lost.
    package var strings: [String: String]

    package var perFrameInit: String
    package var perFrame: String
    /// Per-vertex equations (`per_pixel_N` in the file; they run per mesh vertex, not per screen pixel).
    package var perPixel: String

    /// Always `PresetModel.customWaveCount` entries; unused waves have `enabled == false`.
    package var waves: [CustomWave]
    /// Always `PresetModel.customShapeCount` entries; unused shapes have `enabled == false`.
    package var shapes: [CustomShape]

    /// MilkDrop 2 warp shader body (HLSL, without the prelude), or nil.
    package var warpShader: String?
    /// MilkDrop 2 composite shader body (HLSL, without the prelude), or nil.
    package var compositeShader: String?

    package static let customWaveCount = 4
    package static let customShapeCount = 4

    package init(
        version: Int = 100,
        warpShaderVersion: Int = 0,
        compositeShaderVersion: Int = 0,
        values: [String: Double] = [:],
        strings: [String: String] = [:],
        perFrameInit: String = "",
        perFrame: String = "",
        perPixel: String = "",
        waves: [CustomWave] = Array(repeating: CustomWave(), count: PresetModel.customWaveCount),
        shapes: [CustomShape] = Array(repeating: CustomShape(), count: PresetModel.customShapeCount),
        warpShader: String? = nil,
        compositeShader: String? = nil
    ) {
        self.version = version
        self.warpShaderVersion = warpShaderVersion
        self.compositeShaderVersion = compositeShaderVersion
        self.values = values
        self.strings = strings
        self.perFrameInit = perFrameInit
        self.perFrame = perFrame
        self.perPixel = perPixel
        self.waves = waves
        self.shapes = shapes
        self.warpShader = warpShader
        self.compositeShader = compositeShader
    }

    /// The numeric setting for `key` (case-insensitive), or nil when the file doesn't set it.
    package func value(_ key: String) -> Double? {
        values[key.lowercased()]
    }
}

/// One of the four custom waves (`wavecode_N_*` settings, `wave_N_*` equations).
package struct CustomWave: Sendable, Equatable {
    /// `wavecode_N_*` settings with the prefix removed (`enabled`, `samples`, `bspectrum`, `r`, …).
    package var values: [String: Double]
    package var initCode: String
    package var perFrame: String
    package var perPoint: String

    package init(values: [String: Double] = [:], initCode: String = "", perFrame: String = "", perPoint: String = "") {
        self.values = values
        self.initCode = initCode
        self.perFrame = perFrame
        self.perPoint = perPoint
    }

    package var enabled: Bool { (values["enabled"] ?? 0) != 0 }
}

/// One of the four custom shapes (`shapecode_N_*` settings, `shape_N_*` equations).
package struct CustomShape: Sendable, Equatable {
    /// `shapecode_N_*` settings with the prefix removed (`enabled`, `sides`, `rad`, `textured`, …).
    package var values: [String: Double]
    package var initCode: String
    package var perFrame: String

    package init(values: [String: Double] = [:], initCode: String = "", perFrame: String = "") {
        self.values = values
        self.initCode = initCode
        self.perFrame = perFrame
    }

    package var enabled: Bool { (values["enabled"] ?? 0) != 0 }
}
