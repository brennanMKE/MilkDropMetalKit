import Foundation
import MilkPresetFormat
import MilkShaders

/// Errors from reading a `.milkpreset` bundle in `MilkPreset(contentsOf:)`.
///
/// The text in `description` is for display only; its wording is not API.
public enum MilkPresetError: Error, Equatable {
    /// A bundle without `preset.milk`.
    case bundleMissingPreset
}

extension MilkPresetError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .bundleMissingPreset: "The .milkpreset bundle has no preset.milk."
        }
    }

    public var errorDescription: String? { description }
}

/// A preset ready to hand to `MilkRenderer.load(_:transition:)`.
public struct MilkPreset: Sendable {
    /// The preset's name: the file name without its extension.
    public let name: String
    /// The parsed preset: its settings, equations, custom waves and shapes, and shader text.
    public let model: PresetModel
    /// Metal source translated ahead of time by `milkconvert convert`, by stage name ("warp", "composite"); the
    /// renderer uses it instead of translating at load. Empty for a plain `.milk`.
    let convertedShaders: [String: ConvertedShader]

    /// Wraps an already-parsed `model` (e.g. from `PresetModel(text:)`) under `name`. Shaders are translated when
    /// the preset is loaded.
    public init(name: String, model: PresetModel) {
        self.init(name: name, model: model, convertedShaders: [:])
    }

    private init(name: String, model: PresetModel, convertedShaders: [String: ConvertedShader]) {
        self.name = name
        self.model = model
        self.convertedShaders = convertedShaders
    }

    /// Reads a `.milk` file, or a `.milkpreset` bundle written by `milkconvert convert`.
    ///
    /// Throws `MilkPresetError.bundleMissingPreset` for a bundle without `preset.milk`, `PresetParseError` for text
    /// that can't be read or is empty, and Foundation's file errors (`CocoaError`) for a file that can't be opened.
    public init(contentsOf url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            self.init(name: url.deletingPathExtension().lastPathComponent, model: try PresetModel(contentsOf: url))
            return
        }
        let presetURL = url.appendingPathComponent("preset.milk")
        guard FileManager.default.fileExists(atPath: presetURL.path) else { throw MilkPresetError.bundleMissingPreset }
        let model = try PresetModel(contentsOf: presetURL)
        let manifestURL = url.appendingPathComponent("manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(BundleManifest.self, from: $0) }
        var shaders: [String: ConvertedShader] = [:]
        for (stage, entry) in manifest?.shaders ?? [:] {
            guard let source = try? String(contentsOf: url.appendingPathComponent(entry.file), encoding: .utf8) else { continue }
            shaders[stage] = ConvertedShader(metalSource: source, blurLevel: entry.blurLevel, userTextures: entry.userTextures)
        }
        self.init(name: url.deletingPathExtension().lastPathComponent, model: model, convertedShaders: shaders)
    }
}

/// A shader stage `milkconvert convert` translated.
struct ConvertedShader: Sendable {
    var metalSource: String
    var blurLevel: Int
    var userTextures: [String]
}
