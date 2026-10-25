import Foundation
import Metal
import MilkEEL
import MilkPresetFormat
import MilkShaders

// milkconvert: checks presets ahead of time.
//
//   milkconvert inspect <file.milk | directory>...
//       parses each preset, compiles its equations, and reports what it contains
//   milkconvert shaders [--compile] [--dump DIR] <file.milk | directory>...
//       translates each preset's MilkDrop 2 shaders to Metal; --compile also compiles them with the Metal compiler;
//       --dump writes each translation to DIR/<preset>.<stage>.metal
//   milkconvert convert --out DIR <file.milk | directory>...
//       writes DIR/<preset>.milkpreset bundles: preset.milk, the translated warp.metal / composite.metal, and
//       manifest.json. MilkPreset(contentsOf:) loads them and skips translation.

let usage = """
    usage: milkconvert inspect <file.milk | directory>...
           milkconvert shaders [--compile] [--dump DIR] <file.milk | directory>...
           milkconvert convert --out DIR <file.milk | directory>...
    """

func inspect(_ url: URL) -> Bool {
    do {
        let preset = try PresetModel(contentsOf: url)
        let errors = equationErrors(preset)
        let waves = preset.waves.filter(\.enabled).count
        let shapes = preset.shapes.filter(\.enabled).count
        var shaders: [String] = []
        if preset.warpShader != nil { shaders.append("warp ps\(preset.warpShaderVersion)") }
        if preset.compositeShader != nil { shaders.append("comp ps\(preset.compositeShaderVersion)") }
        print((errors.isEmpty ? "ok    " : "EEL   ") + "\(url.lastPathComponent)  v\(preset.version)  waves \(waves)  shapes \(shapes)"
              + (shaders.isEmpty ? "" : "  " + shaders.joined(separator: ", "))
              + (errors.isEmpty ? "" : "  EEL errors \(errors.count)"))
        for error in errors { print("        \(error)") }
        return errors.isEmpty
    } catch {
        print("FAIL  \(url.lastPathComponent)  \(error)")
        return false
    }
}

/// Compiles every equation block; each block gets its own table, as the renderer's contexts will.
func equationErrors(_ preset: PresetModel) -> [String] {
    var blocks = [("per_frame_init", preset.perFrameInit), ("per_frame", preset.perFrame),
                  ("per_pixel", preset.perPixel)]
    for (i, wave) in preset.waves.enumerated() {
        blocks += [("wave_\(i)_init", wave.initCode), ("wave_\(i)_per_frame", wave.perFrame),
                   ("wave_\(i)_per_point", wave.perPoint)]
    }
    for (i, shape) in preset.shapes.enumerated() {
        blocks += [("shape_\(i)_init", shape.initCode), ("shape_\(i)_per_frame", shape.perFrame)]
    }
    return blocks.compactMap { label, source in
        var table = EELVariableTable()
        do {
            _ = try EELProgram(source: source, table: &table)
            return nil
        } catch {
            return "\(label): \(error)"
        }
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

/// Translates (and optionally compiles) one preset's shaders. Returns the failures as "stage: message".
func shaderFailures(_ url: URL, device: MTLDevice?, dump: URL?) -> (stages: Int, failures: [String]) {
    guard let preset = try? PresetModel(contentsOf: url) else { return (0, ["parse: unreadable preset"]) }
    var stages = 0
    var failures: [String] = []
    for (stage, text) in [(ShaderStage.warp, preset.warpShader), (.composite, preset.compositeShader)] {
        guard let text else { continue }
        stages += 1
        do {
            let shader = try ShaderTranslator.translate(text, stage: stage)
            if let dump {
                let name = url.deletingPathExtension().lastPathComponent + ".\(stage.rawValue).metal"
                try? shader.metalSource.write(to: dump.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            if let device {
                let library = try device.makeLibrary(source: shader.metalSource, options: nil)
                guard library.makeFunction(name: shader.fragmentFunction) != nil else {
                    throw ShaderError.unsupported("no fragment function")
                }
            }
        } catch let error as ShaderError {
            failures.append("\(stage.rawValue): translate: \(error)")
        } catch {
            // Metal compiler output: keep the first error line.
            let text = "\(error)"
            let line = text.split(separator: "\n").first { $0.contains("error:") } ?? Substring(text.prefix(200))
            failures.append("\(stage.rawValue): metal: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
    return (stages, failures)
}

/// Writes `<out>/<name>.milkpreset`. Returns false if a shader didn't translate (it's listed in the manifest).
func convert(_ url: URL, into out: URL) throws -> Bool {
    let preset = try PresetModel(contentsOf: url)
    let bundle = out.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".milkpreset")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data(contentsOf: url).write(to: bundle.appendingPathComponent("preset.milk"))
    var shaders: [String: BundleManifest.Shader] = [:]
    var errors: [String] = []
    for (stage, text) in [(ShaderStage.warp, preset.warpShader), (.composite, preset.compositeShader)] {
        guard let text else { continue }
        do {
            let shader = try ShaderTranslator.translate(text, stage: stage)
            let file = "\(stage.rawValue).metal"
            try shader.metalSource.write(to: bundle.appendingPathComponent(file), atomically: true, encoding: .utf8)
            shaders[stage.rawValue] = .init(file: file, blurLevel: shader.blurLevel, userTextures: shader.userTextures)
        } catch {
            errors.append("\(stage.rawValue): \(error)")
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(BundleManifest(shaders: shaders, errors: errors))
        .write(to: bundle.appendingPathComponent("manifest.json"))
    return errors.isEmpty
}

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "inspect" where arguments.count > 1:
    let files = arguments.dropFirst().flatMap(presetFiles)
    let failures = files.filter { !inspect($0) }.count
    print("\(files.count - failures)/\(files.count) parsed")
    exit(failures == 0 ? 0 : 1)
case "shaders" where arguments.count > 1:
    arguments.removeFirst()
    var compile = false
    var dump: URL?
    var paths: [String] = []
    while let a = arguments.first {
        arguments.removeFirst()
        if a == "--compile" { compile = true }
        else if a == "--dump", let d = arguments.first {
            arguments.removeFirst()
            dump = URL(fileURLWithPath: d)
            try? FileManager.default.createDirectory(at: dump!, withIntermediateDirectories: true)
        } else { paths.append(a) }
    }
    let device = compile ? MTLCreateSystemDefaultDevice() : nil
    if compile && device == nil { FileHandle.standardError.write(Data("no Metal device\n".utf8)); exit(2) }
    var total = 0, failed = 0
    var reasons: [String: Int] = [:]
    for url in paths.flatMap(presetFiles) {
        let (stages, failures) = shaderFailures(url, device: device, dump: dump)
        total += stages
        failed += failures.count
        for f in failures {
            print("FAIL  \(url.lastPathComponent)  \(f)")
            // Group by message with the specifics (names, line numbers) trimmed.
            let key = f.replacingOccurrences(of: #"line \d+: "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"program_source:\d+:\d+: "#, with: "", options: .regularExpression)
            reasons[String(key.prefix(90)), default: 0] += 1
        }
    }
    print("\(total - failed)/\(total) shaders \(compile ? "compiled" : "translated")")
    for (reason, count) in reasons.sorted(by: { $0.value > $1.value }).prefix(25) { print("  \(count)  \(reason)") }
    exit(failed == 0 ? 0 : 1)
case "convert" where arguments.count > 2:
    arguments.removeFirst()
    guard let o = arguments.firstIndex(of: "--out"), o + 1 < arguments.count else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
    let out = URL(fileURLWithPath: arguments[o + 1])
    arguments.removeSubrange(o...(o + 1))
    var converted = 0, partial = 0
    for url in arguments.flatMap(presetFiles) {
        do {
            if try convert(url, into: out) { converted += 1 } else { partial += 1 }
        } catch {
            print("FAIL  \(url.lastPathComponent)  \(error)")
        }
    }
    print("\(converted) converted, \(partial) with a shader that fell back to fixed function")
    exit(0)
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
