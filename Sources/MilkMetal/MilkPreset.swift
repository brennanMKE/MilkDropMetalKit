import Foundation
import MilkPresetFormat

public enum MilkPresetError: Error, Equatable {
    /// Converted preset bundles (milestone 4) aren't readable yet.
    case bundlesUnsupported
}

/// A preset ready to hand to `MilkRenderer.load(_:transition:)`.
public struct MilkPreset: Sendable {
    public let name: String
    public let model: PresetModel

    public init(name: String, model: PresetModel) {
        self.name = name
        self.model = model
    }

    /// Reads a `.milk` file (shaders translated at runtime once that path exists) or a converted bundle.
    public init(contentsOf url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw MilkPresetError.bundlesUnsupported
        }
        self.init(name: url.deletingPathExtension().lastPathComponent, model: try PresetModel(contentsOf: url))
    }
}
