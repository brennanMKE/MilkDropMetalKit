import Foundation
import Testing
@testable import MilkDemoSupport

/// RGBA pixels, Float16 per channel.
private func check(_ pixels: [[Float]]) -> FrameCheck {
    let flat = pixels.flatMap { $0 }.map { Float16($0) }
    return flat.withUnsafeBufferPointer { FrameCheck(rgba16: $0) }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct FrameCheckTests {
    @Test func nanAndInfinityAreCountedNotMeasured() {
        let c = check([[.nan, 0, 0, 1], [0, .infinity, 0, 1], [0.5, 0.25, 0, 1], [0, 0, -.infinity, 1]])
        #expect(c.nonFinite == 3)
        #expect(c.peak == 0.5)
        #expect(abs(c.mean - 0.25) < 0.001)
        #expect(!c.isBlack)
    }

    @Test func blackIsUnderOneDisplayStep() {
        #expect(check([[0, 0, 0, 1], [1 / 255, 0, 1 / 255, 1]]).isBlack)
        #expect(!check([[0, 0, 0, 1], [0, 2 / 255, 0, 1]]).isBlack)
    }

    @Test func alphaIsIgnored() {
        let c = check([[0, 0, 0, .nan], [0, 0, 0, 1]])
        #expect(c.nonFinite == 0)
        #expect(c.isBlack)
    }

    @Test func brightFrameIsNotBlack() {
        let c = check([[1, 0.5, 0.2, 1], [0.1, 0.1, 0.1, 1]])
        #expect(!c.isBlack)
        #expect(c.peak == 1)
        #expect(abs(c.mean - (1.7 / 3 + 0.1) / 2) < 0.001)
    }
}

struct CompatReportTests {
    @Test func medianAndP99() {
        #expect(CompatResult.medianAndP99([]) == (0, 0))
        #expect(CompatResult.medianAndP99([4]) == (4, 4))
        // 1...100 shuffled: the median sits at round(99 * 0.5) = index 50, the p99 at round(98.01) = 98.
        let samples = (1...100).map(Double.init).shuffled()
        #expect(CompatResult.medianAndP99(samples) == (51, 99))
        // One slow frame in 120 shows in the p99 only when it's past the 99th percentile.
        let frames = Array(repeating: 1.0, count: 119) + [50]
        #expect(CompatResult.medianAndP99(frames) == (1, 1))
        #expect(CompatResult.medianAndP99(frames + [50, 50]) == (1, 50))
    }

    @Test func summaryCountsAndPassRate() {
        var a = CompatResult(preset: "a.milk"); a.frames = 120; a.gpuP99Ms = 9; a.cpuP99Ms = 1; a.gpuMedianMs = 3
        var b = CompatResult(preset: "b.milk"); b.frames = 120; b.presetErrors = ["warp shader fell back"]
        b.cpuP99Ms = 3; b.gpuMedianMs = 1
        var c = CompatResult(preset: "c.milk", failure: .nonFinite, detail: nil); c.failures.append(.black)
        c.frames = 120; c.gpuMedianMs = 2
        let d = CompatResult(preset: "d.milk", failure: .crash, detail: "died")
        let summary = CompatSummary(results: [a, b, c, d], gpuBudgetMs: 8, cpuBudgetMs: 2)
        #expect(summary.presets == 4)
        #expect(summary.passed == 2)
        #expect(summary.passRate == 0.5)
        #expect(summary.failures == ["nan": 1, "black": 1, "crash": 1])
        #expect(summary.withPresetErrors == 1)
        #expect(summary.overGPUBudget == 1)
        #expect(summary.overCPUBudget == 1)
        #expect(summary.gpuMedianMs == 2)  // over a, b and c; d rendered nothing
        #expect(summary.text.hasPrefix("compat 4 presets, 2 passed (50.00%)"))
        #expect(CompatSummary(results: [], gpuBudgetMs: 8).passRate == 0)
    }

    @Test func jsonLinesRoundTripSkipsATornLine() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.jsonl")
        var a = CompatResult(preset: "Dancer/a b!.milk")
        a.frames = 120
        a.setTimes(cpu: [1, 2, 3], gpu: [4, 5, 6])
        a.presetErrors = ["per-frame: unknown function foo"]
        let b = CompatResult(preset: "b.milk", failure: .timeout, detail: "over 60 s")
        try CompatReport.append(a, to: url)
        try CompatReport.append(b, to: url)
        #expect(CompatReport.read(url) == [a, b])

        // A crash mid-write leaves a torn line with no newline; it's skipped, and the next record still decodes.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"preset":"torn.mi"#.utf8))
        try handle.close()
        #expect(CompatReport.read(url) == [a, b])
        let c = CompatResult(preset: "c.milk", failure: .crash, detail: nil)
        try CompatReport.append(c, to: url)
        #expect(CompatReport.read(url) == [a, b, c])
        #expect(CompatReport.read(folder.appendingPathComponent("missing.jsonl")).isEmpty)
    }

    @Test func presetsAreFoundSortedAndSampled() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fm = FileManager.default
        for path in ["b/2.milk", "b/1.MILK", "a.milk", "c/d/e.milk", "notes.txt", ".git/x.milk"] {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        #expect(CompatReport.presets(in: folder) == ["a.milk", "b/1.MILK", "b/2.milk", "c/d/e.milk"])
        #expect(CompatReport.presets(in: folder, stride: 2) == ["a.milk", "b/2.milk"])
        #expect(CompatReport.presets(in: folder, stride: 1, limit: 3) == ["a.milk", "b/1.MILK", "b/2.milk"])
    }

    @Test func sidecarWithoutARecordBecomesACrash() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appendingPathComponent("report.jsonl")
        let sidecar = folder.appendingPathComponent("report.jsonl.current")

        // Nothing to recover without a sidecar.
        #expect(try CompatReport.recordCrash(report: report, sidecar: sidecar, detail: "died") == nil)

        // The watchdog already wrote a timeout for it: no second record.
        let timedOut = CompatResult(preset: "slow.milk", failure: .timeout, detail: nil)
        try CompatReport.append(timedOut, to: report)
        try Data("slow.milk\n".utf8).write(to: sidecar)
        #expect(try CompatReport.recordCrash(report: report, sidecar: sidecar, detail: "died") == nil)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        try Data("bad.milk\n".utf8).write(to: sidecar)
        let crash = try CompatReport.recordCrash(report: report, sidecar: sidecar, detail: "died")
        #expect(crash == CompatResult(preset: "bad.milk", failure: .crash, detail: "died"))
        #expect(CompatReport.read(report) == [timedOut, crash!])
    }
}
