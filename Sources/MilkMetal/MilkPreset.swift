import Foundation
package import MilkPresetFormat
internal import MilkShaders

/// Errors from reading a preset with `MilkPreset(contentsOf:)`, `MilkPreset(data:name:)` or
/// `MilkPreset(text:name:)`. They throw nothing else.
///
/// Each case carries the file it's about. For a preset read from `data` or `text`, the URL is a placeholder whose
/// last path component is `<name>.milk`; it names the preset rather than pointing at a file. The text in
/// `description` (and in `reason`) is for display only; its wording is not API. Switch over the cases with a `default`: new cases may be added in a minor release.
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
    /// True for a MilkDrop 2 preset: `MILKDROP_PRESET_VERSION` 200 or later, or a warp or composite shader.
    public var isMilkDrop2: Bool {
        model.version >= 200 || model.warpShader != nil || model.compositeShader != nil
    }
    /// The parsed preset: its settings, equations, custom waves and shapes, and shader text.
    package let model: PresetModel
    /// Metal source translated ahead of time by `milkconvert convert`, by stage name ("warp", "composite"); the
    /// renderer uses it instead of translating at load. Empty for a plain `.milk`.
    let convertedShaders: [String: ConvertedShader]

    /// Wraps an already-parsed `model` (e.g. from `PresetModel(text:)`) under `name`. Shaders are translated when
    /// the preset is loaded.
    package init(name: String, model: PresetModel) {
        self.init(name: name, model: model, convertedShaders: [:])
    }

    private init(name: String, model: PresetModel, convertedShaders: [String: ConvertedShader]) {
        self.name = name
        self.model = model
        self.convertedShaders = convertedShaders
    }

    /// Parses `.milk` text, e.g. from a host's own storage, under `name`. Shaders are translated when the preset is
    /// loaded.
    ///
    /// Throws `MilkPresetError.empty` when the text has no `key=value` lines.
    public init(text: String, name: String) throws(MilkPresetError) {
        let url = Self.placeholderURL(name)
        do {
            self.init(name: name, model: try PresetModel(text: text))
        } catch {
            throw Self.presetError(error, url: url)
        }
    }

    /// Parses the bytes of a `.milk` file (UTF-8 or Windows-1252) under `name`. Shaders are translated when the
    /// preset is loaded.
    ///
    /// Throws `MilkPresetError.unreadableText` or `.empty` when the data isn't a preset.
    public init(data: Data, name: String) throws(MilkPresetError) {
        let url = Self.placeholderURL(name)
        do {
            self.init(name: name, model: try PresetModel(data: data))
        } catch {
            throw Self.presetError(error, url: url)
        }
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
        } catch {
            throw presetError(error, url: url)
        }
    }

    /// Maps a parser error to `MilkPresetError` for `url`.
    private static func presetError(_ error: any Error, url: URL) -> MilkPresetError {
        switch error {
        case PresetParseError.unreadableText: .unreadableText(url)
        case PresetParseError.empty: .empty(url)
        default: .unreadableFile(url, reason: "\(error)")
        }
    }

    /// The URL errors carry for a preset parsed from memory: `<name>.milk`, not a real file.
    private static func placeholderURL(_ name: String) -> URL {
        URL(fileURLWithPath: name, isDirectory: false).appendingPathExtension("milk")
    }
}

/// A shader stage `milkconvert convert` translated.
struct ConvertedShader: Sendable {
    var metalSource: String
    var blurLevel: Int
    var userTextures: [String]
}
