import Foundation

/// One preset's line in a compatibility report (`milkview-demo compat`), written as JSON Lines so a crash loses at
/// most the preset it was on.
public struct CompatResult: Codable, Sendable, Equatable {
    /// Problems that make a preset fail the run.
    public enum Failure: String, Codable, Sendable, CaseIterable {
        /// The process died while rendering it.
        case crash
        /// It took longer than the per-preset time limit.
        case timeout
        /// `MilkPreset(contentsOf:)` or `load` threw.
        case loadFailed = "load-failed"
        /// A command buffer finished with an error (a GPU fault or a hang the driver gave up on).
        case gpuError = "gpu-error"
        /// A checked frame had NaN or infinite pixels.
        case nonFinite = "nan"
        /// The last checked frame was black.
        case black
    }

    /// The preset's path, relative to the corpus folder.
    public var preset: String
    public var failures: [Failure] = []
    /// `MilkRenderer.presetErrors` after load: equation blocks skipped, shaders that fell back, missing textures.
    /// The preset still renders, so these don't fail it.
    public var presetErrors: [String] = []
    /// The load error, or what the crash, timeout or check knows.
    public var detail: String?
    public var frames = 0
    /// Wall time of `render(to:commandBuffer:time:)` on the CPU (encoding, equations) and GPU time of its command
    /// buffer, ms. The first frame, which allocates the renderer's textures, is left out.
    public var cpuMedianMs = 0.0, cpuP99Ms = 0.0
    public var gpuMedianMs = 0.0, gpuP99Ms = 0.0
    /// The slowest GPU frame and its number (1-based), to tell warm-up stalls from steady cost.
    public var gpuMaxMs = 0.0, gpuMaxFrame = 0
    /// Load time (parse, equations, synchronous shader compile), ms.
    public var loadMs = 0.0
    /// The last checked frame's brightest channel and mean brightness.
    public var peak: Float = 0, mean: Float = 0

    public var passed: Bool { failures.isEmpty }

    public init(preset: String) {
        self.preset = preset
    }

    public init(preset: String, failure: Failure, detail: String?) {
        self.preset = preset
        failures = [failure]
        self.detail = detail
    }

    /// Fills the timing fields from per-frame samples (ms).
    public mutating func setTimes(cpu: [Double], gpu: [Double]) {
        (cpuMedianMs, cpuP99Ms) = Self.medianAndP99(cpu)
        (gpuMedianMs, gpuP99Ms) = Self.medianAndP99(gpu)
    }

    /// Nearest-rank median and 99th percentile: the sample at `round((n - 1) * q)` of the sorted samples.
    public static func medianAndP99(_ samples: [Double]) -> (Double, Double) {
        guard !samples.isEmpty else { return (0, 0) }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        return (at(0.5), at(0.99))
    }
}

/// Totals over a report, for the summary a run prints and keeps.
public struct CompatSummary: Codable, Sendable, Equatable {
    public var presets = 0
    public var passed = 0
    /// Presets per failure (a preset can have more than one).
    public var failures: [String: Int] = [:]
    /// Presets that passed but reported `presetErrors`.
    public var withPresetErrors = 0
    /// Presets whose p99 GPU or CPU frame time is over its budget. Reported, not failed: a VM's GPU is not the
    /// slowest supported Mac.
    public var overGPUBudget = 0, overCPUBudget = 0
    public var gpuBudgetMs: Double, cpuBudgetMs: Double
    /// Medians over the presets that rendered, of each preset's median frame time.
    public var gpuMedianMs = 0.0, cpuMedianMs = 0.0
    public var passRate: Double { presets > 0 ? Double(passed) / Double(presets) : 0 }

    public init(results: [CompatResult], gpuBudgetMs: Double = 8, cpuBudgetMs: Double = 2) {
        self.gpuBudgetMs = gpuBudgetMs
        self.cpuBudgetMs = cpuBudgetMs
        presets = results.count
        var gpu: [Double] = [], cpu: [Double] = []
        for r in results {
            if r.passed {
                passed += 1
                if !r.presetErrors.isEmpty { withPresetErrors += 1 }
            }
            for f in r.failures { failures[f.rawValue, default: 0] += 1 }
            guard r.frames > 0 else { continue }
            if r.gpuP99Ms > gpuBudgetMs { overGPUBudget += 1 }
            if r.cpuP99Ms > cpuBudgetMs { overCPUBudget += 1 }
            gpu.append(r.gpuMedianMs)
            cpu.append(r.cpuMedianMs)
        }
        gpuMedianMs = CompatResult.medianAndP99(gpu).0
        cpuMedianMs = CompatResult.medianAndP99(cpu).0
    }

    public var text: String {
        var lines = [String(format: "compat %d presets, %d passed (%.2f%%)", presets, passed, passRate * 100)]
        for f in CompatResult.Failure.allCases {
            if let n = failures[f.rawValue] { lines.append("  \(f.rawValue): \(n)") }
        }
        lines.append("  passed with preset errors: \(withPresetErrors)")
        lines.append(String(format: "  over a %g ms p99 GPU budget: %d (median preset %.2f ms)",
                            gpuBudgetMs, overGPUBudget, gpuMedianMs))
        lines.append(String(format: "  over a %g ms p99 CPU budget: %d (median preset %.2f ms)",
                            cpuBudgetMs, overCPUBudget, cpuMedianMs))
        return lines.joined(separator: "\n")
    }
}

/// Reads and appends a JSON Lines report. Lines that don't decode (a torn last line after a crash) are skipped.
public enum CompatReport {
    public static func read(_ url: URL) -> [CompatResult] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(CompatResult.self, from: $0) }
    }

    /// Appends one line. If the file ends in a torn line, a newline goes first so the new record stands alone.
    public static func append(_ result: CompatResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(result)
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { line.insert(UInt8(ascii: "\n"), at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// The `.milk` files under `folder` as paths relative to it, sorted, skipping hidden folders; then every
    /// `stride`th of them, then the first `limit`.
    public static func presets(in folder: URL, stride: Int = 1, limit: Int? = nil) -> [String] {
        let base = folder.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "milk" else { continue }
            let path = url.standardizedFileURL.path
            paths.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
        }
        paths.sort()
        let sampled = paths.enumerated().filter { $0.offset % max(1, stride) == 0 }.map(\.element)
        return limit.map { Array(sampled.prefix($0)) } ?? sampled
    }

    /// After a restart: when `sidecar` names a preset that has no record in `report`, the process died on it, so a
    /// `crash` record is appended and returned. The sidecar is removed either way.
    @discardableResult
    public static func recordCrash(report: URL, sidecar: URL, detail: String) throws -> CompatResult? {
        defer { try? FileManager.default.removeItem(at: sidecar) }
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let preset = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.isEmpty, !read(report).contains(where: { $0.preset == preset }) else { return nil }
        let result = CompatResult(preset: preset, failure: .crash, detail: detail)
        try append(result, to: report)
        return result
    }
}
