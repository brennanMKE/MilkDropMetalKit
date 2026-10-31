import Foundation

package enum PresetParseError: Error, Equatable {
    /// The data isn't text in any encoding `.milk` files use.
    case unreadableText
    /// The file has no `key=value` lines at all.
    case empty
}

extension PresetModel {
    /// Reads a `.milk` file. Files from the Winamp era are often Windows-1252, so that is tried after UTF-8.
    package init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    package init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw PresetParseError.unreadableText
        }
        try self.init(text: text)
    }

    package init(text: String) throws {
        var parser = Parser()
        var sawKey = false
        // Split on any newline flavour; `.milk` files use CRLF.
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if key.isEmpty { continue }
            sawKey = true
            parser.add(key: key, value: String(line[line.index(after: eq)...]))
        }
        guard sawKey else { throw PresetParseError.empty }
        self = parser.finish()
    }
}

/// Equation and shader lines are numbered (`per_frame_3=…`); they are collected by number and joined in order.
private struct Parser {
    typealias Lines = [Int: String]

    var values: [String: Double] = [:]
    var strings: [String: String] = [:]
    var perFrameInit: Lines = [:]
    var perFrame: Lines = [:]
    var perPixel: Lines = [:]
    var warp: Lines = [:]
    var comp: Lines = [:]
    var waveValues = Array(repeating: [String: Double](), count: PresetModel.customWaveCount)
    var waveInit = Array(repeating: Lines(), count: PresetModel.customWaveCount)
    var wavePerFrame = Array(repeating: Lines(), count: PresetModel.customWaveCount)
    var wavePerPoint = Array(repeating: Lines(), count: PresetModel.customWaveCount)
    var shapeValues = Array(repeating: [String: Double](), count: PresetModel.customShapeCount)
    var shapeInit = Array(repeating: Lines(), count: PresetModel.customShapeCount)
    var shapePerFrame = Array(repeating: Lines(), count: PresetModel.customShapeCount)

    mutating func add(key: String, value: String) {
        if let n = Self.lineNumber(key, prefix: "per_frame_init_") {
            perFrameInit[n] = value
        } else if let n = Self.lineNumber(key, prefix: "per_frame_") {
            perFrame[n] = value
        } else if let n = Self.lineNumber(key, prefix: "per_pixel_") {
            perPixel[n] = value
        } else if let n = Self.lineNumber(key, prefix: "warp_") {
            warp[n] = Self.shaderLine(value)
        } else if let n = Self.lineNumber(key, prefix: "comp_") {
            comp[n] = Self.shaderLine(value)
        } else if let (i, rest) = Self.indexed(key, prefix: "wavecode_", count: PresetModel.customWaveCount) {
            if let d = Self.number(value) { waveValues[i][rest] = d }
        } else if let (i, rest) = Self.indexed(key, prefix: "shapecode_", count: PresetModel.customShapeCount) {
            if let d = Self.number(value) { shapeValues[i][rest] = d }
        } else if addCustomEquation(key: key, value: value) {
            return
        } else if let d = Self.number(value) {
            values[key] = d
        } else {
            strings[key] = value.trimmingCharacters(in: .whitespaces)
        }
    }

    /// `wave_N_…` and `shape_N_…` equation lines. Returns false for anything else, including plain settings.
    private mutating func addCustomEquation(key: String, value: String) -> Bool {
        if let (i, rest) = Self.indexed(key, prefix: "wave_", count: PresetModel.customWaveCount) {
            return addWaveLine(i, rest, value)
        }
        if let (i, rest) = Self.indexed(key, prefix: "shape_", count: PresetModel.customShapeCount) {
            return addShapeLine(i, rest, value)
        }
        return false
    }

    private mutating func addWaveLine(_ i: Int, _ rest: String, _ value: String) -> Bool {
        if let n = Self.lineNumber(rest, prefix: "init") {
            waveInit[i][n] = value
        } else if let n = Self.lineNumber(rest, prefix: "per_frame") {
            wavePerFrame[i][n] = value
        } else if let n = Self.lineNumber(rest, prefix: "per_point") {
            wavePerPoint[i][n] = value
        } else {
            return false
        }
        return true
    }

    private mutating func addShapeLine(_ i: Int, _ rest: String, _ value: String) -> Bool {
        if let n = Self.lineNumber(rest, prefix: "init") {
            shapeInit[i][n] = value
        } else if let n = Self.lineNumber(rest, prefix: "per_frame") {
            shapePerFrame[i][n] = value
        } else {
            return false
        }
        return true
    }

    func finish() -> PresetModel {
        let shaderVersion = Int(values["psversion"] ?? 0)
        let warpSource = Self.joined(warp)
        let compSource = Self.joined(comp)
        return PresetModel(
            version: Int(values["milkdrop_preset_version"] ?? 100),
            warpShaderVersion: warpSource.isEmpty ? 0 : Int(values["psversion_warp"] ?? Double(shaderVersion)),
            compositeShaderVersion: compSource.isEmpty ? 0 : Int(values["psversion_comp"] ?? Double(shaderVersion)),
            values: values,
            strings: strings,
            perFrameInit: Self.equations(perFrameInit),
            perFrame: Self.equations(perFrame),
            perPixel: Self.equations(perPixel),
            waves: (0..<PresetModel.customWaveCount).map {
                CustomWave(
                    values: waveValues[$0],
                    initCode: Self.equations(waveInit[$0]),
                    perFrame: Self.equations(wavePerFrame[$0]),
                    perPoint: Self.equations(wavePerPoint[$0])
                )
            },
            shapes: (0..<PresetModel.customShapeCount).map {
                CustomShape(
                    values: shapeValues[$0],
                    initCode: Self.equations(shapeInit[$0]),
                    perFrame: Self.equations(shapePerFrame[$0])
                )
            },
            warpShader: warpSource.isEmpty ? nil : warpSource,
            compositeShader: compSource.isEmpty ? nil : compSource
        )
    }

    /// `per_frame_12` with prefix `per_frame_` → 12. The remainder must be all digits.
    static func lineNumber(_ key: String, prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(rest)
    }

    /// `wave_2_per_point3` with prefix `wave_` → (2, "per_point3"). Plain settings such as `wave_mode` don't match.
    static func indexed(_ key: String, prefix: String, count: Int) -> (Int, String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        let digits = rest.prefix(while: \.isASCIIDigit)
        guard !digits.isEmpty, let i = Int(digits), i < count else { return nil }
        let tail = rest.dropFirst(digits.count)
        guard tail.first == "_" else { return nil }
        return (i, String(tail.dropFirst()))
    }

    static func number(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespaces))
    }

    /// Shader lines start with a backtick so leading whitespace survives MilkDrop's own trimming.
    static func shaderLine(_ value: String) -> String {
        value.hasPrefix("`") ? String(value.dropFirst()) : value
    }

    static func joined(_ lines: Lines) -> String {
        lines.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
    }

    /// Equation lines the way MilkDrop joins them: each line's `//` comment removed, then concatenated with no
    /// separator. Presets rely on it: a long expression wrapped across lines can split an identifier or number.
    static func equations(_ lines: Lines) -> String {
        lines.sorted { $0.key < $1.key }.map { line in
            line.value.range(of: "//").map { String(line.value[..<$0.lowerBound]) } ?? line.value
        }.joined()
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
