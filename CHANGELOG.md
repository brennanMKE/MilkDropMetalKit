# Changelog

All notable changes to MilkDropMetalKit. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and from 1.0.0 the package follows [Semantic Versioning](https://semver.org) as described in
[docs/api-1.0.md §5](docs/api-1.0.md#5-semver-policy).

## Unreleased: 1.0.0

The first tagged release. `MilkRenderer`, `MilkPreset`, `MilkView` and `MilkTransitionPattern` make up the stable
API. Requires macOS 14 and Swift 6. No third-party dependencies, no network access, no entitlements.

### Added

**Spike (milestone 1)**
- `MilkRenderer`: renders a MilkDrop 1 preset with per-frame and per-vertex equations, a 48×36 warp mesh over
  double-buffered 8-bit feedback, and the composite pass.
- `MilkView`: an `NSView` backed by `CAMetalLayer` that draws on every display refresh.
- `MilkRenderer.feed(samples:channels:sampleRate:)`: nonisolated, allocation-free, lock-free audio input from any
  audio thread.
- Audio analysis with Accelerate: a 1,024-sample window, a 512-bin spectrum, and `bass`/`mid`/`treb` with `_att`
  smoothing relative to a running average. Silence reads as normal levels.
- `MilkPresetFormat`: a `.milk` parser that tries UTF-8, then Windows-1252, and accepts CRLF.

**EEL complete (milestone 2)**
- `MilkEEL`: the full ns-eel2 language, compiled to a slot-resolved closure tree. Covers every function, `megabuf`
  and `gmegabuf`, the `reg00`–`reg99` registers shared between a preset's contexts, `loop`/`while`, assignment
  operators, ns-eel1 compatibility names, and MilkDrop's quirks (division by zero gives 0, the comparison epsilon,
  truncating `int`, integer `rand`).
- `milkconvert inspect`: parses and compiles every preset in a folder and reports failures. 99.8% of the 9,795-preset
  "Cream of the Crop" pack's equations compile.

**Overlays (milestone 3)**
- All eight built-in waveforms, custom waves (up to 4, with per-frame and per-point equations), custom shapes
  (instanced and textured), motion vectors, inner and outer borders, darken-centre, and the composite's echo, gamma,
  invert, brighten, darken and solarize. MilkDrop 1 presets render fully.

**MilkDrop 2 shaders (milestone 4)**
- An HLSL-to-Metal translator (internal `MilkShaders` target) with MilkDrop's shader prelude. Runs at load, with
  pipelines compiled in the background by default (`compilesShadersInBackground`), or ahead of time with
  `milkconvert shaders` and `milkconvert convert`, which writes `.milkpreset` bundles that `MilkPreset(contentsOf:)`
  loads.
- Blur levels 1–3 and the noise textures. Disk textures that presets name are replaced by noise and reported.
- Fallbacks: an equation block that doesn't compile is skipped, and a shader that doesn't translate or compile runs
  the fixed-function pass instead. Both are listed in `MilkRenderer.presetErrors`. 99.97% of the corpus's 15,895
  shaders translate and compile.
- MilkDrop Gallery: a SwiftUI app with 42 feature presets in `Presets/` that plays an audio file. Includes
  `scripts/build-app.sh` and `scripts/make-dmg.sh` (Developer ID signed, optionally notarized).

**Transitions (milestone 5)**
- `load(_:transition:)` blends two presets over a given time. Both presets' equations run. The warp mesh, warp pass
  and composite mix per vertex. Numeric settings ease on a cosine and switches flip halfway. Custom waves and shapes
  fade, and the basic waveform morphs between modes.
- `MilkTransitionPattern`: `random` (the default, as in MilkDrop 2), `crossfade`, `wipe`, `plasma`, `radial`.
  Exposed as `transitionPattern`, with `isTransitioning`.

**Compatibility (milestone 6)**
- A corpus runner that loads every preset in a folder, renders frames offscreen and flags crashes, timeouts, load
  failures, GPU errors, NaN or infinite pixels, black frames, and frames over the CPU or GPU budget. It writes a
  resumable per-preset report and a pass-rate summary, and runs in the test VM.
- Pass rate (2026-10-29, Cream of the Crop, all 9,795 presets, 300 frames at 640x360 in the VM): 9,532 passed (97.31%); every failure is a black frame (263); no crashes, timeouts, load failures or NaNs. Median preset 0.81 ms GPU, 0.48 ms CPU per frame (VM timing). See docs/compatibility.md.

**Tooling**
- `scripts/run-tests-vm.sh`: builds and tests in a disposable Tart VM (never on the host), with offscreen frames,
  window screenshots, screen recordings, a Gallery app check, corpus runs and transition captures (`--next`).
- `milkview-demo`: `MilkView` in a window, or offscreen frames, fed by a generated test signal. Plays nothing.

### Known limitations
- Disk textures that presets name aren't loaded (noise stands in).
- No pixel-level comparison against Butterchurn yet.
- macOS only.
