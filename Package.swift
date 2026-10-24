// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MilkDropMetalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MilkMetal", targets: ["MilkMetal"]),
        .library(name: "MilkPresetFormat", targets: ["MilkPresetFormat"]),
        .library(name: "MilkEEL", targets: ["MilkEEL"]),
        .executable(name: "milkconvert", targets: ["milkconvert"]),
    ],
    targets: [
        // Tiny local C shim for acquire/release atomics (`Synchronization.Atomic` needs macOS 15).
        .target(name: "CMilkAtomics"),
        // .milk parser → PresetModel (values, equations, shader source). Foundation only, no Metal.
        .target(name: "MilkPresetFormat"),
        .testTarget(name: "MilkPresetFormatTests", dependencies: ["MilkPresetFormat"], resources: [.copy("Fixtures")]),
        // ns-eel2 expression language: lexer, parser, AST, compiler to a fast evaluator. No Metal.
        .target(name: "MilkEEL"),
        .testTarget(name: "MilkEELTests", dependencies: ["MilkEEL"]),
        // MilkDrop HLSL prelude, translated MSL loading and the runtime shader cache.
        .target(name: "MilkShaders"),
        // The renderer: public API, Metal pipeline, mesh, waves, shapes, transitions, audio analysis, MilkView.
        .target(name: "MilkMetal", dependencies: ["CMilkAtomics", "MilkPresetFormat", "MilkEEL", "MilkShaders"]),
        .testTarget(name: "MilkMetalTests", dependencies: ["MilkMetal"]),
        // Host tool: .milk → preset bundle (equations checked, HLSL → MSL ahead of time). Never shipped in an app.
        .executableTarget(name: "milkconvert", dependencies: ["MilkPresetFormat", "MilkEEL"]),
    ]
)
