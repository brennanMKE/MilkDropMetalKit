import Foundation
import MilkPresetFormat

// milkconvert: .milk → preset bundle (equations checked, HLSL → MSL ahead of time).
// Status: `inspect` parses presets and reports what they contain; conversion arrives with milestone 4.

let usage = """
    usage: milkconvert inspect <file.milk | directory>...
    """

func inspect(_ url: URL) -> Bool {
    do {
        let preset = try PresetModel(contentsOf: url)
        let waves = preset.waves.filter(\.enabled).count
        let shapes = preset.shapes.filter(\.enabled).count
        var shaders: [String] = []
        if preset.warpShader != nil { shaders.append("warp ps\(preset.warpShaderVersion)") }
        if preset.compositeShader != nil { shaders.append("comp ps\(preset.compositeShaderVersion)") }
        print("ok    \(url.lastPathComponent)  v\(preset.version)  waves \(waves)  shapes \(shapes)"
              + (shaders.isEmpty ? "" : "  " + shaders.joined(separator: ", ")))
        return true
    } catch {
        print("FAIL  \(url.lastPathComponent)  \(error)")
        return false
    }
}

func presetFiles(at path: String) -> [URL] {
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [url] }
    guard isDirectory.boolValue else { return [url] }
    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
    return (enumerator?.compactMap { $0 as? URL } ?? [])
        .filter { $0.pathExtension.lowercased() == "milk" }
        .sorted { $0.path < $1.path }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "inspect", arguments.count > 1 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let files = arguments.dropFirst().flatMap(presetFiles)
let failures = files.filter { !inspect($0) }.count
print("\(files.count - failures)/\(files.count) parsed")
exit(failures == 0 ? 0 : 1)
