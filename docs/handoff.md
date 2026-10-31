# MilkDrop on Metal: handoff for a new Swift package

Handoff spec for starting a separate Swift package that renders MilkDrop presets with Metal. Roadie adopts it as a
dependency when it is ready; until then Roadie keeps its Winamp 2.x visualizer (spectrum, oscilloscope) and plans no
MilkDrop work of its own beyond a blocked integration issue.

Working name: **MilkMetal** (rename freely). Status: not started.

## 1. Why a separate package

- MilkDrop is a self-contained engine with a small interface: audio in, frames out. Nothing in it depends on skins,
  playback or Music Assistant.
- It is a large, open-ended job (an expression language, a shader translator, a render pipeline, preset compatibility).
  Keeping it out of Roadie means its own tests, corpus runs and release cadence, and Roadie's milestones are not held up
  by it.
- Other apps could use it.

## 2. Background: what MilkDrop is

MilkDrop (Ryan Geiss, 2001; MilkDrop 2 in Winamp 5.5, 2007) is a preset-driven, feedback-based visualizer. Each frame:

1. **Per-frame equations** (CPU) read audio levels and time and set frame variables: `zoom`, `rot`, `warp`, `cx`/`cy`,
   `dx`/`dy`, `sx`/`sy`, `decay`, wave colors and mode, `q1`–`q32` (passed on to later stages), and more.
2. **Per-vertex ("per-pixel") equations** run over a coarse mesh (default 48×36, so about 1.7k vertices, not per screen
   pixel) and produce each vertex's texture coordinate into the previous frame. This mesh is what makes the image swirl
   and zoom.
3. **Warp pass**: the previous frame is resampled through the mesh into a new feedback texture. MilkDrop 2 presets can
   replace the fixed function here with a **warp shader** (HLSL).
4. **Overlays** are drawn into the feedback texture: the audio **waveform** (built-in modes), up to 4 **custom waves**
   and 4 **custom shapes** (each with their own per-frame and per-point equations), borders, motion vectors.
5. **Composite pass** draws the feedback texture to the screen with gamma, echo, invert, brighten/darken/solarize, or a
   MilkDrop 2 **composite shader** (HLSL). The composite never feeds back.
6. **Transitions** blend two presets for a few seconds (MilkDrop 2 has many blend patterns).

Presets are `.milk` text files: `key=value` settings, equation lines (`per_frame_1=…`, `per_pixel_1=…`,
`wave_0_per_point1=…`, `shape_0_per_frame1=…`), and for MilkDrop 2, `warp_1=…` / `comp_1=…` shader lines.

Audio inputs a preset sees: `bass`, `mid`, `treb` (instant, relative to a running average, so about 1.0 is "normal"),
`bass_att`, `mid_att`, `treb_att` (smoothed), plus the stereo waveform and spectrum for the waves. Also `time`, `fps`,
`frame`, `progress`, mouse, and the `rand` seed.

## 3. References and licenses

Check each license before reading code to port it, and record what was used in the package's `NOTICE`.

| Reference | What it is | License | Use |
|---|---|---|---|
| [Butterchurn](https://github.com/jberg/butterchurn) | WebGL port of MilkDrop 2, used by [Webamp](https://webamp.org) | MIT | **Primary port source.** Readable, modern, structured like the stages above. |
| [milkdrop-preset-converter](https://github.com/jberg/milkdrop-preset-converter) and the eel parser beside it | Turns `.milk` into Butterchurn's JSON (equations to JS, HLSL to GLSL) | check each repo | Model for our offline converter. |
| [butterchurn-presets](https://github.com/jberg/butterchurn-presets) | Converted preset packs | per-preset authors; check | Test corpus. Do not ship until licences are clear. |
| MilkDrop 2 original source | Nullsoft/Geiss C++ and DirectX 9 | check: older releases were BSD-style; the 2024 Winamp source release has its own non-free licence, so **do not copy from it** | Ground truth for behaviour questions only. |
| [projectM](https://github.com/projectM-visualizer/projectm) | Native C++ MilkDrop engine (OpenGL) | LGPL-2.1 | Behaviour reference and a second opinion. Avoid copying: LGPL is awkward to link statically into an app. |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross), [DXC](https://github.com/microsoft/DirectXShaderCompiler) / [glslang](https://github.com/KhronosGroup/glslang) | Shader translation toolchain | Apache-2.0 / NCSA / BSD-style | HLSL to SPIR-V to MSL in the converter (host tool, not shipped in the app). |

Decision: **port from Butterchurn, verify against MilkDrop's behaviour.** Not projectM, for licence and because its
OpenGL architecture maps less directly to Metal than Butterchurn's staged design.

## 4. Package shape

> The shipped 1.0 API differs from this pre-build sketch: see the [README](../README.md) and [api-1.0.md](api-1.0.md).

Swift 6 package, `platforms: [.macOS(.v14)]` (Roadie's floor; add iOS later if wanted), strict concurrency on.

```
MilkMetal/
├── Package.swift
├── Sources/
│   ├── MilkPreset/        # .milk parser → PresetModel (values, equations, shader source); no Metal
│   ├── MilkEEL/           # the expression language: lexer, parser, AST, compiler to a fast evaluator
│   ├── MilkShaders/       # MilkDrop HLSL prelude + translated MSL loading; runtime cache
│   ├── MilkMetal/         # the renderer: public API, Metal pipeline, mesh, waves, shapes, transitions
│   └── milkconvert/       # CLI: .milk → preset bundle (equations checked, HLSL → MSL ahead of time)
├── Tests/ …               # per module, plus golden-image tests (§7)
└── Presets/               # a small set with confirmed licences, as bundles
```

### Public API (first cut; keep it small)

```swift
public final class MilkRenderer {
    public init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws
    /// Called from any thread; copies into an internal ring. Interleaved stereo Float32 at `sampleRate`.
    public nonisolated func feed(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double)
    public func load(_ preset: MilkPreset, transition: TimeInterval = 0) throws
    /// Renders one frame into `texture` (e.g. a CAMetalLayer drawable's) at `time`.
    public func render(to texture: MTLTexture, commandBuffer: MTLCommandBuffer, time: TimeInterval)
    public var meshSize: (width: Int, height: Int) { get set }   // 48×36 default
}

public struct MilkPreset: Sendable {
    public init(contentsOf url: URL) throws        // .milk (runtime shader translation) or converted bundle
    public var name: String { get }
}
```

Plus a convenience `MilkView` (an `NSView` backed by `CAMetalLayer` with a display link) so a host app can show it in a
few lines. The host owns windows, menus, preset browsing and full screen; the package owns rendering only.

## 5. The hard parts

### 5.1 The expression language (MilkEEL)

MilkDrop equations use Nullsoft's EEL (ns-eel2): C-like expressions over doubles, `;`-separated statements, variables
created on first use, functions such as `sin cos tan asin acos atan atan2 sqr sqrt pow exp log log10 abs min max sign
rand int above below equal if bnot band bor sigmoid`, `megabuf`/`gmegabuf` arrays, and in newer presets `loop`/`while`
and assignment operators. Presets rely on exact quirks (division by zero gives 0, `int` truncation, `rand(n)` integer
range, comparison epsilon); collect them in tests as they are found.

- Parse once at preset load into an AST, then compile to a tight evaluator: a closure tree or a register bytecode
  over a flat `[Double]` variable table (variables resolved to slots at compile time). No string lookups per frame.
- Per-frame code runs once per frame; per-vertex code runs about 1.7k times per frame; custom-wave per-point code up to
  512 points × 4 waves. CPU evaluation is fine at these counts (Butterchurn does all of it in JavaScript). Measure before
  considering GPU evaluation of per-vertex code.
- The evaluator must be deterministic given a seed (for golden tests).

### 5.2 Shaders (MilkDrop 2 warp and composite)

Preset shaders are HLSL (Shader Model 2/3 era) bodies that assume a MilkDrop prelude: samplers such as `sampler_main`,
`sampler_fw_main`, `sampler_noise_lq`, `sampler_blur1`–`3`, helpers like `GetBlur1()`, uniforms `q1`–`q32`, `time`,
`rand_frame`, `texsize`, and so on.

- Write the prelude once (from Butterchurn's GLSL prelude, re-expressed as HLSL), wrap each preset body in it, compile
  HLSL to SPIR-V (DXC or glslang), then SPIR-V to MSL with SPIRV-Cross. Do this **offline in `milkconvert`**, producing a
  bundle the app loads with no translator on board. A runtime path for user `.milk` files can come later (bundle the
  translator as a library, or translate on first load and cache).
- Expect per-preset failures; the converter reports them, and the renderer falls back to the fixed-function warp or
  composite for a preset whose shader didn't translate.
- Blur textures (three levels) and noise textures are part of the pipeline the prelude expects; build them in the
  renderer.

### 5.3 The render pipeline

Double-buffered feedback textures (RGBA16Float or BGRA8; compare against Butterchurn's precision before choosing),
the warp mesh as a vertex buffer updated per frame, render passes in the order of §2, and a second pipeline instance
for the outgoing preset during transitions. Match MilkDrop's texture wrap and filtering per preset (`wrap`,
`bTexWrap`) and its aspect-ratio handling.

### 5.4 Audio analysis

Feed raw stereo PCM; the package computes what presets need, the way MilkDrop does: a time-domain window per channel
(Butterchurn uses 1024 samples per channel), an FFT (512 bins), and `bass`/`mid`/`treb` as band energies relative to
a long-term average, with the `_att` smoothing. Use Accelerate (`vDSP`) for the FFT. Never allocate or lock on the
`feed` path; it can run on an audio thread.

## 6. Milestones inside the package

Each ends with something visible and a test that pins it.

1. **Spike.** Parse one simple MilkDrop 1 preset (no shaders, no custom waves); per-frame and per-vertex equations
   through a first EEL evaluator; warp + composite at 60 fps in `MilkView`. Measure frame time. Go/no-go for the rest.
2. **EEL complete.** Full function set, `megabuf`, loops, quirks; a corpus run that parses and evaluates every
   equation in the preset packs and reports failures.
3. **Waveforms, custom waves, custom shapes, borders, motion vectors.** MilkDrop 1 presets render fully.
4. **MilkDrop 2 shaders.** `milkconvert` with the HLSL to MSL path, blur and noise textures; MilkDrop 2 presets render.
5. **Transitions.** Blend two presets; MilkDrop 2 blend patterns.
6. **Compatibility.** Corpus runs over the large preset packs: parse, translate, render N frames offscreen, flag
   crashes, NaNs, black frames and over-budget frames. Track the pass rate per release.
7. **1.0.** Stable API, documented, tagged; Roadie can depend on it.

## 7. Testing

- **Unit tests** per module: preset parsing, EEL (each function, precedence, quirks), audio band levels from synthetic
  signals.
- **Golden images.** Render a preset offscreen with fixed time steps, a fixed seed and a recorded audio clip, and
  compare frames against reference frames rendered by Butterchurn from the same inputs (headless browser), with a
  per-pixel tolerance. Feedback amplifies tiny differences, so compare early frames tightly and later frames loosely,
  and prefer a few dozen well-chosen presets to thousands.
- **Performance.** A benchmark target: median and p99 frame time at 1920×1080 on the slowest supported Mac, for a set
  of heavy presets. Budget: 60 fps with headroom (under about 8 ms of GPU time and 2 ms of CPU per frame).
- **No audio output in tests.** Feed recorded or generated PCM; nothing plays.

## 8. How Roadie will integrate it (later, in Roadie's Visualization milestone)

Roadie side, for whoever writes the package API: these constraints shape it.

- **Audio source.** Roadie's `AnalyzerTap` (`Packages/PlayerKit/Sources/AudioCore/Analyzer/AnalyzerTap.swift`) taps the
  output node with a 1024-frame tap, but it **mixes to mono** into a lock-free `VisSampleRing` for the 75-column
  spectrum and 76-point scope. MilkDrop needs stereo, so Roadie will add a stereo sink beside it and call
  `MilkRenderer.feed` from the tap block. Hence `feed` must be nonisolated, allocation-free and lock-free.
- **Remote playback.** When Roadie plays on a Music Assistant speaker, no PCM passes through this Mac, so MilkDrop has
  no input (the built-in visualizer has the same limit). The host shows a quiet idle state; the package should render
  sensibly with silence.
- **Window.** A separate resizable native window (Webamp draws a skinned frame from the skin's `gen.bmp`; Roadie may do
  that later), opened from the clutter bar's V menu and the main menu, with full screen, next/previous/random preset
  and a preset browser. All host-side.
- **Presets.** Roadie ships the package's licence-clean set and lets users add a folder of `.milk` files (so the
  runtime translation path matters for Roadie, after milestone 4).
- **Dependency.** Swift Package Manager by tagged version in `project.yml`; Roadie's checks (`check-identifiers.sh`,
  entitlements) must still pass, so no new entitlements and no network access from the package.

## 9. Open questions for the package owner

- Feedback texture format: 8-bit like MilkDrop 1, or float (closer to Butterchurn and fewer banding artefacts)?
- Ship `milkconvert`'s translator in the library for runtime `.milk` loading, or require conversion?
- Which preset packs can be redistributed, and under what terms?
- iOS/iPadOS support from the start, or macOS only until 1.0?
