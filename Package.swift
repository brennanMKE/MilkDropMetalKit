// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MilkDropMetalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MilkMetal", targets: ["MilkMetal"]),
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
        .testTarget(name: "MilkShadersTests", dependencies: ["MilkShaders"]),
        // The renderer: public API, Metal pipeline, mesh, waves, shapes, transitions, audio analysis, MilkView.
        .target(name: "MilkMetal", dependencies: ["CMilkAtomics", "MilkPresetFormat", "MilkEEL", "MilkShaders"]),
        .testTarget(name: "MilkMetalTests", dependencies: ["MilkMetal", "MilkShaders"]),
        // Host tool: .milk → preset bundle (equations checked, HLSL → MSL ahead of time). Never shipped in an app.
        .executableTarget(name: "milkconvert", dependencies: ["MilkPresetFormat", "MilkEEL", "MilkShaders"]),
        // Shared by the demos: SynthAudio, a generated test signal, and the compatibility run's frame checks and report.
        .target(name: "MilkDemoSupport"),
        .testTarget(name: "MilkDemoSupportTests", dependencies: ["MilkDemoSupport"]),
        // Demo and capture tool: MilkView in a window, or offscreen frames, fed by a generated signal. Plays nothing.
        .executableTarget(name: "milkview-demo", dependencies: ["MilkMetal", "MilkDemoSupport"]),
        // MilkDrop Gallery: a SwiftUI app that steps through Presets/gallery.json and reacts to an audio file it plays.
        // scripts/build-app.sh bundles it as an .app; scripts/make-dmg.sh signs and packages it.
        .executableTarget(name: "MilkDropGallery", dependencies: ["MilkMetal", "MilkDemoSupport"]),
    ]
)
