# MilkDropMetalKit

A Swift package that renders [MilkDrop](https://en.wikipedia.org/wiki/MilkDrop) presets, the music visualizer from
Winamp, with Metal. Stereo PCM goes in and frames come out. It is being built as a dependency of the Roadie music player,
and any macOS app can use it.

The full design spec is [docs/handoff.md](docs/handoff.md).

> **Status: scaffold (before milestone 1).** The `.milk` parser and the lock-free audio feed work. The expression
> evaluator, the warp/composite pipeline, the shaders and the transitions are not built yet, so `render` clears to black.

## Requirements

- macOS 14 or later
- Swift 6 (Xcode 16 or later); strict concurrency
- No third-party dependencies, no network access, no entitlements

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/brennanMKE/MilkDropMetalKit.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "MilkMetal", package: "MilkDropMetalKit"),
    ]),
]
```

Depend on a tagged version once 1.0 ships.

## Usage

```swift
import MilkMetal

let device = MTLCreateSystemDefaultDevice()!
let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
try renderer.load(MilkPreset(contentsOf: presetURL))

// A ready-made view: CAMetalLayer plus a display link. The host owns windows, menus and preset browsing.
let view = try MilkView(renderer: renderer)

// From an audio tap, on any thread. Interleaved Float32; it never allocates or locks.
renderer.feed(samples: buffer, channels: 2, sampleRate: 48_000)
```

`MilkRenderer` is `@MainActor`. Only `feed` is nonisolated. To draw into your own Metal layer, call
`render(to:commandBuffer:time:)` with the drawable's texture.

## Modules

| Product | Role | Status |
|---|---|---|
| `MilkMetal` | `MilkRenderer`, `MilkPreset`, `MilkView`, audio input and analysis | API in place; renders black |
| `MilkPresetFormat` | `.milk` → `PresetModel` (settings, equations, shader bodies). No Metal. | Working |
| `MilkEEL` | ns-eel2 expression language → slot-resolved evaluator | Variable table and quirks only |
| `MilkShaders` (internal) | MilkDrop HLSL prelude, translated MSL, pipeline cache | Placeholder |
| `milkconvert` | Host CLI: `.milk` → preset bundle | `inspect` only |

## Development

```sh
swift build
swift test
swift run milkconvert inspect path/to/presets/   # parse every .milk file and report failures
```

Reference checkouts go in `References/` and preset packs with unclear licences go in `Corpus/`. Both are git-ignored.
Record any ported code in [NOTICE](NOTICE) before it lands. Butterchurn (MIT) is the port source. Do not copy from
projectM (LGPL) or from the 2024 Winamp source release.

## Roadmap

1. **Spike**: one MilkDrop 1 preset, per-frame and per-vertex equations, warp and composite at 60 fps in `MilkView`.
2. **EEL complete**: the full function set, `megabuf`, loops and quirks, with a corpus run.
3. **Overlays**: waveforms, custom waves and shapes, borders, motion vectors.
4. **MilkDrop 2 shaders**: HLSL → SPIR-V → MSL in `milkconvert`, plus blur and noise textures.
5. **Transitions**: preset blending and the MilkDrop 2 blend patterns.
6. **Compatibility**: corpus runs that track a pass rate.
7. **1.0**: a stable, documented API and a tagged release.

The open questions are in [docs/handoff.md §9](docs/handoff.md#9-open-questions-for-the-package-owner).

## License

MIT. See [LICENSE](LICENSE). Third-party notices are in [NOTICE](NOTICE).
