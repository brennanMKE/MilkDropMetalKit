import Foundation
import MilkPresetFormat
import MilkShaders

/// Errors from reading a preset with `MilkPreset(contentsOf:)`. It throws nothing else.
///
/// Each case carries the file it's about. The text in `description` (and in `reason`) is for display only; its
/// wording is not API. Switch over the cases with a `default`: new cases may be added in a minor release.
///
/// The parser skips lines it doesn't understand rather than failing, so no case points at a line; a preset's
/// equations and shaders that don't compile are reported by `MilkRenderer.presetErrors` once it's loaded.
public enum MilkPresetError: Error, Equatable {
    /// The file couldn't be read: it doesn't exist or isn't readable. `reason` is the system's description of the
    /// failure.
    case unreadableFile(URL, reason: String)
    /// The file isn't text in an encoding `.milk` files use (UTF-8 or Windows-1252).
    case unreadableText(URL)
    /// The file has no `key=value` lines at all.
    case empty(URL)
    /// A folder (a `.milkpreset` bundle) without `preset.milk`; the URL is the bundle's.
    case bundleMissingPreset(URL)
}

extension MilkPresetError: CustomStringConvertible, LocalizedError {
    /// The file the error is about.
    public var url: URL {
        switch self {
        case .unreadableFile(let url, _), .unreadableText(let url), .empty(let url), .bundleMissingPreset(let url): url
        }
    }

    public var description: String {
        let name = url.lastPathComponent
        return switch self {
        case .unreadableFile(_, let reason): "Can't read \(name): \(reason)"
        case .unreadableText: "\(name) isn't text in UTF-8 or Windows-1252."
        case .empty: "\(name) has no preset settings (no key=value lines)."
        case .bundleMissingPreset: "The .milkpreset bundle \(name) has no preset.milk."
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
    /// Throws `MilkPresetError` only: `.unreadableFile` for a file that can't be opened, `.unreadableText` or
    /// `.empty` for one that isn't a preset, and `.bundleMissingPreset` for a bundle without `preset.milk`.
    public init(contentsOf url: URL) throws(MilkPresetError) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            self.init(name: url.deletingPathExtension().lastPathComponent, model: try Self.readModel(url))
            return
        }
        let presetURL = url.appendingPathComponent("preset.milk")
        guard FileManager.default.fileExists(atPath: presetURL.path) else { throw .bundleMissingPreset(url) }
        let model = try Self.readModel(presetURL)
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

extension MilkPreset {
    /// Parses the `.milk` file at `url`, mapping file and parse errors to `MilkPresetError`.
    private static func readModel(_ url: URL) throws(MilkPresetError) -> PresetModel {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadableFile(url, reason: error.localizedDescription)
        }
        do {
            return try PresetModel(data: data)
        } catch PresetParseError.unreadableText {
            throw .unreadableText(url)
        } catch PresetParseError.empty {
            throw .empty(url)
        } catch {
            throw .unreadableFile(url, reason: "\(error)")
        }
    }
}

/// A shader stage `milkconvert convert` translated.
struct ConvertedShader: Sendable {
    var metalSource: String
    var blurLevel: Int
    var userTextures: [String]
}
