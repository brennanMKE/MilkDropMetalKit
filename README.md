# MilkDropMetalKit

A Swift package that renders [MilkDrop](https://en.wikipedia.org/wiki/MilkDrop) presets, the music visualizer from
Winamp, with Metal. Stereo PCM goes in and frames come out. It is being built as a dependency of the Roadie music player,
and any macOS app can use it.

The full design spec is [docs/handoff.md](docs/handoff.md).

> **Status: milestones 1–5.** MilkDrop 1 and 2 presets render: the expression language (EEL), per-frame and
> per-vertex equations, audio analysis, the warp mesh and feedback, all eight built-in waveforms, custom waves and
> shapes (instanced and textured), motion vectors, borders, the composite, and MilkDrop 2 warp and composite shaders
> translated from HLSL to Metal at load, with blur and noise textures. Presets blend into each other with MilkDrop 2's
> transitions (wipe, plasma and radial patterns, or a plain crossfade). Over the 9,795-preset "Cream of the Crop"
> pack, 99.8% of presets' equations compile and 99.97% of their 15,895 shaders translate and compile. Not yet: disk
> textures that presets name (noise stands in), and a pixel-level comparison against Butterchurn.

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
import Metal
import MilkMetal

let device = MTLCreateSystemDefaultDevice()!
let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
try renderer.load(MilkPreset(contentsOf: presetURL))

// Later: blend into the next preset over 2.7 seconds, in a random MilkDrop 2 pattern (see `transitionPattern`).
try renderer.load(MilkPreset(contentsOf: nextURL), transition: 2.7)

// A ready-made view: CAMetalLayer plus a display link. The host owns windows, menus and preset browsing.
let view = try MilkView(renderer: renderer)

// From an audio tap, on any thread but one thread at a time. Interleaved Float32; it never allocates, locks or
// blocks. Feed each buffer as it arrives, whatever its size: the renderer plays it out in step with its frames.
renderer.feed(samples: buffer, channels: 2, sampleRate: 48_000)
```

`MilkRenderer` is `@MainActor`. Only `feed` is nonisolated, and it's single-producer: call it from one thread at a
time. The renderer paces fed audio itself: an `AVAudioEngine` tap's ~100 ms buffers can go straight to `feed`, and
each frame analyzes the audio that should be playing at its `time` (the visuals trail the feed by up to one buffer).
If audio stops arriving, the last window holds for a quarter of a second and then decays to silence, so there's no
need to feed silence while paused. Errors are MilkMetal's own: `MilkRendererError` from creating a renderer or
view, and `MilkPresetError` (which names the file) from `MilkPreset(contentsOf:)`. To draw into your own Metal layer, call `render(to:commandBuffer:time:)` with the drawable's texture. The
texture's pixel format must equal the renderer's `pixelFormat`, and you must commit every command buffer you pass:
the renderer keeps up to three frames in flight and waits for one to complete, so an uncommitted buffer stalls the
main thread a few frames later.

## Modules

| Product | Role | Status |
|---|---|---|
| `MilkMetal` | `MilkRenderer`, `MilkPreset`, `MilkView`, audio input and analysis | Working: the full MilkDrop 1 and 2 frame |
| `MilkPresetFormat` | `.milk` → `PresetModel` (settings, equations, shader bodies). No Metal. | Working |
| `MilkEEL` | ns-eel2 expression language → slot-resolved closure tree | Working: full function set, `megabuf`, loops |
| `MilkShaders` (internal) | MilkDrop 2 HLSL → Metal translator and the shader prelude | Working ([docs/shaders.md](docs/shaders.md)) |
| `milkconvert` | Host CLI: check presets, translate shaders, write `.milkpreset` bundles | Working: `inspect`, `shaders`, `convert` |
| `milkview-demo` | `MilkView` in a window, offscreen frames, or a corpus compatibility run, fed by a generated signal | Working ([docs/compatibility.md](docs/compatibility.md): 97.3% of 9,795 presets pass) |
| `MilkDropGallery` | SwiftUI gallery app: presets by feature, plays an audio file | Working |

## MilkDrop Gallery

A SwiftUI app that steps through the presets in [Presets/](Presets/), each showing one renderer feature, with a
note on what to look for. Open an audio file (or drop one on the window) and the visuals react to it; until then a
built-in beat drives them silently. Each preset you pick blends in over the last one. You can also add your own
`.milk` files.

```sh
swift run MilkDropGallery          # run from the repo
scripts/build-app.sh               # build/app/MilkDrop Gallery.app (universal, signed)
scripts/make-dmg.sh                # build/dist/MilkDrop-Gallery-<version>.dmg, Developer ID signed
scripts/make-dmg.sh --notary-profile <profile>   # also notarized and stapled, so it opens cleanly anywhere
```

Space plays and pauses, ⌘[ and ⌘] step through presets, ⌘I toggles the info card, and the timer button
auto-advances every 20 seconds. It's also the reference for embedding `MilkView` in SwiftUI (`MilkDropView` in
`Sources/MilkDropGallery/ContentView.swift`) and feeding it from AVAudioEngine (`AudioPlayer.swift`: the mixer's
tap feeds the renderer directly).

## Development

```sh
swift build
scripts/run-tests-vm.sh                          # tests in a Tart VM
scripts/run-tests-vm.sh --record 15 --preset Presets/spike-tunnel.milk   # plus a 15 s screen recording
scripts/run-tests-vm.sh --frames --every 10 --preset Presets/echo.milk --next Presets/shader-glow.milk   # a transition
scripts/run-tests-vm.sh --compat Corpus/presets-cream-of-the-crop --compat-stride 50   # sampled compatibility run
swift run milkconvert inspect path/to/presets/   # parse every .milk file and report failures
swift run milkconvert shaders --compile path/to/presets/   # translate and compile every MilkDrop 2 shader
swift run milkconvert convert --out Converted/ path/to/presets/   # write .milkpreset bundles
python3 -I scripts/make-gallery-presets.py Presets   # regenerate the gallery presets
```

Test automation (tests, golden images, screenshots, screen recordings) runs in a disposable Tart VM, never on
the host. See [docs/testing-in-vm.md](docs/testing-in-vm.md).

Reference checkouts go in `References/` and preset packs with unclear licences go in `Corpus/`. Both are git-ignored.
Record any ported code in [NOTICE](NOTICE) before it lands. Butterchurn (MIT) is the port source. Do not copy from
projectM (LGPL) or from the 2024 Winamp source release.

## Roadmap

1. **Spike** (done): one MilkDrop 1 preset, per-frame and per-vertex equations, warp and composite at 60 fps in `MilkView`.
2. **EEL complete** (done): the full function set, `megabuf`, loops and quirks, with a corpus run.
3. **Overlays** (done): waveforms, custom waves and shapes, borders, motion vectors.
4. **MilkDrop 2 shaders** (done): HLSL → MSL, in the library at load and in `milkconvert` ahead of time, plus blur
   and noise textures.
5. **Transitions** (done): preset blending and the MilkDrop 2 blend patterns.
6. **Compatibility**: corpus runs that track a pass rate.
7. **1.0**: a stable, documented API and a tagged release.

The open questions are in [docs/handoff.md §9](docs/handoff.md#9-open-questions-for-the-package-owner).

## License

MIT. See [LICENSE](LICENSE). Third-party notices are in [NOTICE](NOTICE).
