# 1.0 API review

Milestone 7 (handoff §6): a stable, documented API and a tagged release that Roadie can depend on. This page stages
that decision for the owner. The non-breaking documentation items are applied (marked **Done** below), as are F2
and F5, which the owner approved as breaking changes before 1.0; everything else is still a proposal awaiting the
owner's decision.

Reviewed at `ce8d9c1` (M5 transitions committed) plus the uncommitted M6 compatibility runner, 2026-10-29. The
public symbols were listed with `swift-symbolgraph-extract -minimum-access-level public`.

**Contents:** [Inventory](#1-public-api-inventory) · [Roadie fit](#2-roadie-integration-handoff-8) ·
[Findings](#3-findings) · [Docs](#4-documentation) · [Semver](#5-semver-policy) · [Checklist](#6-release-checklist)

## 1. Public API inventory

Library products (`Package.swift:7-11`): `MilkMetal`, `MilkPresetFormat`, `MilkEEL`. Executable product:
`milkconvert`. `MilkShaders`, `CMilkAtomics` and `MilkDemoSupport` are targets, not products.

A dash marks a public symbol with no doc comment.

### MilkMetal

| Symbol | Kind | Notes |
|---|---|---|
| `MilkRenderer` | `@MainActor final class` | `MilkRenderer.swift:27` |
| `init(device:pixelFormat:) throws(MilkRendererError)` | init | Typed throws since F2. Accepts `bgra8Unorm`, `bgra8Unorm_srgb`, `rgba16Float`, `rgb10a2Unorm`, `bgr10a2Unorm` (`:242`) |
| `device: MTLDevice`, `pixelFormat: MTLPixelFormat` | `let` | — no doc |
| `preset: MilkPreset?` | get | |
| `presetErrors: [String]` | get | Free-form text (`:35`) |
| `transitionPattern: MilkTransitionPattern` | var | Default `.random` (`:44`) |
| `isTransitioning: Bool` | get | |
| `compilesShadersInBackground: Bool` | var | Default `true` (`:50`) |
| `isCompilingShaders: Bool` | get | |
| `meshSize: (width: Int, height: Int)` | var | Clamped to 1…512 in `didSet` (`:54`) |
| `feed(samples:channels:sampleRate:)` | `nonisolated` func | Any chunk size; the renderer paces it (F5) |
| `load(_:transition:) throws` | func | Never actually throws today (`:258`) |
| `render(to:commandBuffer:time:)` | func | `:270` |
| `reset()` | func | Back to a new renderer's state (feedback, clock, audio, random sequence, transition); the preset stays loaded and restarts. Added 2026-10-29 |
| `MilkRendererError` | enum | `unsupportedPixelFormat(MTLPixelFormat)`, `noCommandQueue`, `pipelineCompilation(function:message:)`, `resourceCreation(resource:)` (F2) |
| `MilkPreset` | `Sendable` struct | `name`, `model: PresetModel` (both — no doc), `init(name:model:)` (—), `init(contentsOf:) throws(MilkPresetError)` (`.milk` or `.milkpreset` bundle) |
| `MilkPresetError` | enum | `unreadableFile(URL, reason:)`, `unreadableText(URL)`, `empty(URL)`, `bundleMissingPreset(URL)`; `url` (F2) |
| `MilkTransitionPattern` | `Sendable, CaseIterable` enum | `random`, `crossfade`, `wipe`, `plasma`, `radial` (`Transitions.swift:5`) |
| `MilkView` | `@MainActor final class: NSView` | `renderer` (—), `init(renderer:frame:) throws(MilkRendererError)` (—), and four `NSView` overrides |
| ~~`MilkViewError`~~ | — | Removed: folded into `MilkRendererError.noCommandQueue` (F2) |

### MilkPresetFormat

| Symbol | Kind | Notes |
|---|---|---|
| `PresetModel` | `Sendable, Equatable` struct | 12 `public var` stored properties; `value(_:)`; `customWaveCount`, `customShapeCount` (—); memberwise init (—) |
| `PresetModel.init(contentsOf:)`, `init(data:)`, `init(text:)` | throwing inits | `data:` and `text:` — no doc |
| `CustomWave`, `CustomShape` | `Sendable, Equatable` structs | All-`var`; `initCode`, `perFrame`, `perPoint`, `enabled` — no doc |
| `PresetParseError` | enum | `unreadableText`, `empty`. Enum itself — no doc |

### MilkEEL

| Symbol | Kind | Notes |
|---|---|---|
| `EELVariableTable` | struct | `names` (`private(set)`), `values` (`var`), `count`, `slot(for:)`, `existingSlot(for:)`, subscript |
| `EELShared` | `@unchecked Sendable` class | `registerCount`, `registers: UnsafeMutablePointer<Double>` |
| `EELMemory` | `@unchecked Sendable` class | `count`, `values: UnsafeMutablePointer<Double>`, `randomState` (`var`), `shared`, subscript, `copyValues(from:)` |
| `EELProgram` | `Sendable` struct | `source`, `init(source:table:) throws`, `isEmpty`, `run(_:)` |
| `EELCompileError` | enum, `CustomStringConvertible` | `syntax`, `unknownFunction`, `wrongArgumentCount`, `notAssignable` |
| `EELQuirks` | caseless enum | `closeFactor`, `@inlinable` `divide`, `isTrue`, `toInt`, `modulo` |

### Persisted formats and the CLI

- `.milkpreset` bundles: `preset.milk`, `warp.metal`/`composite.metal`, `manifest.json` (`BundleManifest`, with
  `format = 1`, in `MilkShaders`). `MilkPreset(contentsOf:)` reads them.
- `milkconvert inspect | shaders [--compile] [--dump DIR] | convert --out DIR`.

## 2. Roadie integration (handoff §8)

| Roadie need | Covered? |
|---|---|
| Stereo `feed` from a tap block: nonisolated, allocation-free, lock-free | **Yes.** `AudioRing` is SPSC with acquire/release atomics. But it is **single-producer**, and the public doc doesn't say so (F4) |
| Tap delivers `AVAudioPCMBuffer` (planar Float32) | **Partly.** `feed` takes interleaved samples only, so the host needs a preallocated interleave buffer in the tap (F9) |
| Tap delivers large chunks (often ~100 ms regardless of `bufferSize`) | **Yes (F5, done).** The renderer plays fed audio out against its render clock, so a tap can call `feed` with each buffer as it arrives. The Gallery's tap now does exactly that |
| Remote playback: no PCM, render sensibly in silence | **Yes.** Silence reads as level 1.0 (`AudioAnalyzer.swift:125`), tested by `longSilenceReadsAsNormal` and `silenceDrawsTheDefaultWaveCircle` |
| Separate resizable window, full screen, next/previous/random, browser | **Yes, host side.** `MilkView` + `load(_:transition:)`. No pause or frame-rate control on `MilkView` (F10) |
| Users add a folder of `.milk` files (runtime translation) | **Yes.** `MilkPreset(contentsOf:)` translates at load. It's `Sendable`, so a browser can parse off the main actor |
| Ship the package's licence-clean presets | **Yes:** `Presets/*.milk`, or bundles from `milkconvert convert` (bundle versioning: F8) |
| SwiftPM by tagged version, no entitlements, no network | **Yes.** No dependencies, no network APIs, no entitlements. Blocked only on the tag |

## 3. Findings

Ranked by what becomes a breaking change once 1.0 is tagged. Line numbers are as of `ce8d9c1`.

### Must fix before 1.0

**F1. Decide whether `MilkPresetFormat` and `MilkEEL` stay products.** (`Package.swift:9-10`)
Once tagged, everything public in them is frozen until 2.0. `MilkEEL` exposes raw storage
(`EELMemory.values`/`EELShared.registers` as `UnsafeMutablePointer<Double>`, `EEL.swift:45,69`), marks
non-thread-safe classes `@unchecked Sendable` (`EEL.swift:42,67`, whose own docs say "Not thread-safe"), and leaves
`randomState` and `EELVariableTable.values` writable. `PresetModel` and `CustomWave`/`CustomShape` are all-`var`
structs whose doc'd invariants ("always 4 entries", `PresetModel.swift:25-28`) any caller can break. No host needs
them: the Gallery and the demo import only `MilkMetal`. Their only outside users are `milkconvert` and the tests,
which are in the same package.
*Proposal (recommended):* ship `MilkMetal` as the only library product. Turn `public` into `package` in
`MilkPresetFormat` and `MilkEEL`. Make `MilkPreset.model` `package`, and give `MilkPreset` what a host needs instead:

```diff
 // Package.swift
     products: [
         .library(name: "MilkMetal", targets: ["MilkMetal"]),
-        .library(name: "MilkPresetFormat", targets: ["MilkPresetFormat"]),
-        .library(name: "MilkEEL", targets: ["MilkEEL"]),
         .executable(name: "milkconvert", targets: ["milkconvert"]),
     ],
```

```swift
// MilkPreset.swift
public struct MilkPreset: Sendable {
    /// The file name without its extension.
    public let name: String
    /// True for a MilkDrop 2 preset (`MILKDROP_PRESET_VERSION` 200 or later, or any warp or composite shader).
    public var isMilkDrop2: Bool { ... }
    package let model: PresetModel
    /// Parses `.milk` text, e.g. from a host's own storage. Throws `MilkPresetError`.
    public init(text: String, name: String) throws
    public init(data: Data, name: String) throws
    public init(contentsOf url: URL) throws
}
```

Then `internal import MilkPresetFormat`/`MilkEEL`/`MilkShaders`/`CMilkAtomics` in MilkMetal keeps them out of its
interface (see F13). Adding the products back in 1.x is additive. Removing them after 1.0 is not.
*Alternative:* keep `MilkPresetFormat` as a read-only parser product (`public internal(set)` on every property, plus
doc comments). Drop `MilkEEL` regardless.

**F2. Make the error types stable and descriptive.** (`MilkRenderer.swift:6-10`, `MilkView.swift:5-7`,
`MilkPreset.swift:5-8`, `PresetParser.swift:3-8`)
`unsupportedPixelFormat` carries `MTLPixelFormat.RawValue`, not the format. `shaderCompilation(String)` and
`resourceCreation(String)` embed `"\(error)"` text, which makes `Equatable` on them depend on Metal's wording. None of
the four types has a description, so hosts show `"\(error)"` (the Gallery does: `GalleryModel.swift:113`).
`MilkPreset(contentsOf:)` can also throw `PresetParseError` and Foundation's file errors, which isn't documented.
*Proposal:*

```swift
/// Errors from creating a `MilkRenderer` or `MilkView`.
public enum MilkRendererError: Error, Equatable, CustomStringConvertible {
    /// The pixel format isn't one a `CAMetalLayer` can show; see `MilkRenderer.supportedPixelFormats`.
    case unsupportedPixelFormat(MTLPixelFormat)
    /// The device couldn't make a command queue (also replaces `MilkViewError.noCommandQueue`).
    case noCommandQueue
    /// One of the renderer's built-in pipelines didn't compile. A package bug; `message` is Metal's text.
    case pipelineCompilation(function: String, message: String)
    /// The device couldn't allocate a buffer, texture or sampler; `resource` names it.
    case resourceCreation(resource: String)
    public var description: String { ... }
}

/// Errors from reading a preset.
public enum MilkPresetError: Error, Equatable, CustomStringConvertible {
    case unreadableText          // was PresetParseError.unreadableText
    case empty                   // was PresetParseError.empty
    case bundleMissingPreset
    public var description: String { ... }
}
```

Fold `MilkViewError` into `MilkRendererError`. Map `PresetParseError` to `MilkPresetError` inside
`MilkPreset.init`. Document which inits throw what (file errors pass through as `CocoaError`). Also make
`supportedPixelFormats` (`MilkRenderer.swift:242`) `public` so a host can check before it throws.
*Status:* **Done (additive part).** `MilkRendererError`, `MilkViewError` and `MilkPresetError` have doc comments
and `CustomStringConvertible` + `LocalizedError` conformances (so `localizedDescription` reads well).
`MilkRenderer.supportedPixelFormats` is `public nonisolated static let`. `MilkPreset(contentsOf:)` documents what it
throws. **Still open (owner):** case renames, associated-value changes, folding `MilkViewError` into
`MilkRendererError`, and mapping `PresetParseError` to `MilkPresetError`.
*Status:* **Done (2026-10-29, owner-approved breaking change).** As proposed, with these choices:
- `MilkRendererError`: `unsupportedPixelFormat(MTLPixelFormat)`, `noCommandQueue` (from `MilkRenderer.init` and
  `MilkView.init`; `MilkViewError` is gone), `pipelineCompilation(function:message:)` (was `shaderCompilation`),
  `resourceCreation(resource:)`. The description names the pixel format.
- `MilkPresetError`: every case carries the file. `unreadableFile(URL, reason: String)` replaces the `CocoaError`
  that used to escape (`reason` is the system's text), `unreadableText(URL)` and `empty(URL)` replace
  `PresetParseError`, `bundleMissingPreset(URL)` names the bundle. A `url` property returns the file for any case.
  No case carries a line number: the parser skips lines it doesn't understand instead of failing, so nothing has a
  line to report (equation and shader errors go to `presetErrors`).
- Typed throws make the contract checkable: `MilkPreset.init(contentsOf:) throws(MilkPresetError)`,
  `MilkRenderer.init(device:pixelFormat:)` and `MilkView.init(renderer:frame:)` `throws(MilkRendererError)`.
  `load(_:transition:)` keeps an untyped `throws` (F17). A host catches only MilkMetal's types.
- Both keep `CustomStringConvertible` + `LocalizedError`, and their docs say to switch with a `default`.

**F3. Document and check the `render(to:commandBuffer:time:)` contract.** (`MilkRenderer.swift:269-280`)
Several requirements aren't written down:
- `texture.pixelFormat` must equal `pixelFormat`, or pipeline validation fails. Nothing checks this.
- The texture needs `.renderTarget` usage.
- **The caller must commit every command buffer it passes.** `render` waits on a three-frame semaphore that is
  signalled only on completion (`:278-280`), so a buffer that's never committed stalls the main thread on the fourth
  call.
- `render` blocks the main actor while the GPU is three frames behind.
- `time` is the preset's `time` and drives `fps` and transition progress. It should rise steadily. A new `MilkView`
  on the same renderer restarts it at 0.
- If allocation fails, `render` returns without encoding anything (`:273-277`).

*Proposal:* write these into the doc comment, and add `precondition(texture.pixelFormat == pixelFormat)`. Both are
internal changes, but the stall behaviour has to be stated as part of the contract before 1.0.
*Status:* **Done.** All six points are in the `render` doc comment. The check is a debug-only `assert`, not a
`precondition`, so release behaviour is unchanged.

**F4. Document the `feed` contract.** (`MilkRenderer.swift:246-250`, `AudioRing.swift:3-7`)
The ring is single-producer, single-consumer. Two threads calling `feed` at once (two taps, or a tap plus a
main-thread synth) race on `written`, and only `AudioRing`'s internal doc says so. Also unstated: channels past two
are dropped, a `sampleRate` change applies to the whole window, and it holds 4,096 frames.
*Proposal:*

```swift
/// Hands the renderer audio. Call from one thread at a time (typically the audio tap's); it copies into a
/// 4,096-frame ring without allocating, locking or blocking. Interleaved Float32; one channel is duplicated to
/// both sides, channels past two are ignored. The analyzer reads the newest 1,024 frames each `render`.
public nonisolated func feed(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double)
```

*Status:* **Done.** The `feed` doc comment states single-producer, the ring size (now 65,536 frames), channel
handling and the 1,024-frame window. Since F5 it also states the pacing rules (any chunk size; hold, silence,
latency bound, sample-rate changes).

**F5. Decide where audio pacing lives before Roadie copies the Gallery's workaround.** (`AudioPlayer.swift:8-12`,
`AudioAnalyzer.swift:76`)
Fed straight from an AVAudioEngine tap, which delivers about 100 ms at a time, the visuals step in chunks. The
Gallery fixed this outside the library. If 1.x moves pacing into `MilkRenderer` (for example, consuming fed audio at
its sample rate against `render` time), `feed` changes meaning: a host that already paces would then be paced
twice.
*Proposal:* decide now. Either (a) document that hosts feed audio "as it plays" and publish the Gallery's sink as a
recipe, or (b) add internal pacing in 1.0, with `feed` documented as "any chunk size, in playback order". (b) is
better for Roadie, which plans to call `feed` straight from the tap block.
*Status:* **Done (2026-10-29): option (b).** `feed` takes any chunk size in playback order and the renderer paces
it (`AudioPlayhead.swift`). The ring holds 65,536 frames, indexed by stream position. At each `render` a playhead
advances by the render clock's elapsed `time` at the stream's sample rate, and the analyzer reads the 1,024 frames
ending there, not the newest written. Playback starts at the first frame fed, so a 4,800-frame chunk plays out over
six frames at 60 fps. Underrun holds the last window (and the delay it adds absorbs the host's jitter); after
0.25 s with no audio it slides into silence, so the waveform falls flat and the levels decay as for fed silence.
At most 0.25 s waits ahead of the playhead; more drops the oldest. A sample-rate change drops the unplayed audio at
the old rate. A clock that goes backwards counts as no time passing. `feed` still never allocates, locks or
blocks; the writer now announces each write before storing samples (a seqlock), so the reader can detect a lap.
The Gallery's paced `TapSink` and 120 Hz feeding timer are gone: its tap feeds `feed` directly, and a 10 Hz timer
feeds only the built-in beat (none of it while a file is loaded) and updates the transport position.
Behaviour change: a host that feeds just in time (one frame's audio before each `render`, as `milkview-demo` does)
now sees each window one frame later. A host that already paced its feed is not paced twice: just-in-time audio
plays straight through with a constant one-chunk delay.

### Should fix

**F6. Structured, observable diagnostics.** (`MilkRenderer.swift:35-42`, `GalleryModel.swift:108`)
`presetErrors` is `[String]`, and shader errors arrive later with no notification: the Gallery polls
`isCompilingShaders` every 50 ms. Add these without breaking anything:

```swift
public struct MilkPresetDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable { case equation, warpShader, compositeShader, missingTexture }
    public let kind: Kind
    public let message: String          // human-readable; wording is not API
}
public var diagnostics: [MilkPresetDiagnostic] { get }
/// Returns once the current preset's shaders are compiled (or have failed).
public func shadersReady() async
```

Keep `presetErrors` as `diagnostics.map(\.description)`. Either way, state that the text isn't API (see §5).

**F7. `MilkView` lifecycle and options.** (`MilkView.swift:43-52`, `:71-79`)
The view can't be paused (for a minimized window, remote playback, or a hidden tab) except by removing it from its
window. It has no frame-rate cap, and its time base restarts at 0 for each view. It also sets no `colorspace` on the
layer. Add `public var isPaused: Bool`, `public var preferredFrameRateRange: CAFrameRateRange` (forwarded to the
display link), and an elapsed-time clock that survives pause and resume. Add doc comments to `renderer` and `init`.
Add a SwiftUI wrapper (`MilkDropView` from `ContentView.swift:192`) to the library, or at least to the docs, since
every SwiftUI host will write it.

**F8. Version `.milkpreset` bundles against the translator.** (`MilkPreset.swift:38-45`)
`MilkPreset` ignores `manifest.format` and has no translator version, so a bundle converted by 1.0 and loaded by 1.3
uses 1.0's MSL against 1.3's prelude and uniform layout. *Proposal:* write `translator: <n>` in the manifest. When the
format or translator doesn't match, load `preset.milk` and translate at runtime (the existing path). A bundle then
never breaks rendering, only gets slower to load.

**F9. Planar `feed` overload.** `AVAudioPCMBuffer.floatChannelData` is planar, so every AVAudioEngine host has to
interleave. An overload is additive and needs a matching `AudioRing.write`:

```swift
public nonisolated func feed(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>?, sampleRate: Double)
```

**F10. Replace the `meshSize` tuple** (`MilkRenderer.swift:54-59`). A tuple can't be `Equatable` or `Codable`, and the
silent clamp to 1…512 isn't documented. Replace it with `public struct MilkMeshSize: Sendable, Hashable { width,
height; static let milkDrop = MilkMeshSize(width: 48, height: 36) }`, or keep the tuple and document the clamp. This
has to happen before 1.0, because changing the type later is breaking.

**F11. sRGB targets.** `bgra8Unorm_srgb` is accepted (`MilkRenderer.swift:243`). Writing MilkDrop's display-referred
output into an sRGB target encodes it again, so it should look washed out. Verify in the VM, then either drop it from
`supportedPixelFormats` or document that `bgra8Unorm` matches MilkDrop.

**F12. Doc comments** on every public symbol marked "—" in §1, at minimum `MilkRenderer.init`, `device`,
`pixelFormat`, `MilkPreset.name`/`init(name:model:)`, `MilkView.init`/`renderer` and the error enums. Add a DocC
catalog (§4).
*Status:* **Done for `MilkMetal`** (`MilkRenderer.init`, `device`, `pixelFormat`, `MilkPreset.name`/`model`/
`init(name:model:)`, `MilkView.init`/`renderer`, the three error enums). Not done: `MilkPresetFormat`/`MilkEEL`
symbols (wait on F1), the DocC catalog, and `MilkView` docs beyond F7.

### Could fix

**F13.** `internal import` (Swift 6 access-level imports) for `CMilkAtomics` (`AudioRing.swift:1`), `MilkShaders` and,
after F1, `MilkPresetFormat`/`MilkEEL`. Today, loading MilkMetal's module needs `CMilkAtomics`'s module map:
`swift-symbolgraph-extract` failed without it.
**F14.** `MilkTransitionPattern: String` raw values (`"random"`, `"wipe"`, …) so hosts can persist a preference. The
demo already matches on `"\($0)"` (`milkview-demo/main.swift:89`).
**F15.** `MilkPreset: Hashable` (by name and model), useful for a browser's selection.
**F16.** `init(device:pixelFormat:seed:)`. Output is deterministic from the fixed seed 1 (`MilkRenderer.swift:99`), but
a host can't choose the seed or reset it.
**F17.** `load(_:transition:)` is `throws` but never throws. Keep the `throws` so it can validate later (adding it
after 1.0 would break callers), and document that "it currently throws nothing".
**F18.** Equation compiling and shader translation run on the main actor in `load` (a few ms). Moving them into an
`async` `MilkPreset.prepared(for:)` would let a browser preload the next preset. Additive.

## 4. Documentation

### README accuracy (proposed edits; README not changed here)

Items 1, 2 and 4 are **done** in the README's Usage section.

1. **The usage snippet doesn't compile as written.** It calls `MTLCreateSystemDefaultDevice()` and `.bgra8Unorm`
   with only `import MilkMetal`. MilkMetal doesn't re-export Metal. Add `import Metal`, plus `import AppKit` where
   the view is placed.
2. "it never allocates or locks" (`feed`) is true, but the snippet says "on any thread" and leaves out *one thread at
   a time* (F4).
3. "MilkDrop Gallery … feeding it from AVAudioEngine (`AudioPlayer.swift`)" is accurate. **Done:** since F5 its tap
   feeds the renderer directly, and the README says so.
4. "To draw into your own Metal layer, call `render(to:commandBuffer:time:)`" should add: the texture's format must
   match, and you must commit the command buffer (F3).
5. Status and roadmap mark **Transitions (done)**. M5 is committed (`ce8d9c1`), but whether its tests passed in the
   VM isn't recorded anywhere. Confirm before tagging.
6. The pass rates (99.8% of equations, 99.97% of 15,895 shaders) come from the M2/M4 corpus runs. They aren't
   reproducible from the repo, since `Corpus/` is git-ignored. Fine as stated, but say which pack and date, and
   replace them with M6's render pass rate when it lands.
7. The Modules table lists `MilkPresetFormat` and `MilkEEL` as products. Update it if F1 is taken.
8. Installation: switch to `from: "1.0.0"` at the tag (§6). Drop "Depend on a tagged version once 1.0 ships".
9. Not in the README yet: `milkview-demo compat` and `run-tests-vm.sh --corpus`. The M6 agent is adding them.

### Other docs

- `docs/handoff.md` §4 is the pre-build spec: a `Sources/MilkPreset/` target, a non-isolated `MilkRenderer`,
  "Status: not started". Add a line at the top saying the shipped API is in this page and the README, so nobody
  takes §4 as current.
- `docs/handoff.md` §9 open questions: three are now answered in code (8-bit feedback, `MilkRenderer.swift:63`;
  runtime translator shipped; macOS only). Record the answers. iOS stays open; adding it later is additive.
- `docs/compatibility.md` is referenced by `milkview-demo/main.swift:25` but doesn't exist yet (M6).
- No DocC catalog. Proposed `Sources/MilkMetal/MilkMetal.docc/MilkMetal.md`, below. It can't be created now because
  `Sources/` is off limits.

### Draft DocC overview (`MilkMetal.docc/MilkMetal.md`)

~~~markdown
# ``MilkMetal``

Render MilkDrop presets with Metal: stereo audio in, frames out.

## Overview

MilkMetal plays MilkDrop 1 and 2 presets (`.milk` files) the way Winamp's MilkDrop 2 does, ported from
Butterchurn. A ``MilkRenderer`` runs a preset's equations, warp mesh, waveforms, custom waves and shapes, and its
MilkDrop 2 warp and composite shaders (translated from HLSL to Metal at load), and blends between presets.

The host owns windows, menus, preset browsing and audio capture. MilkMetal owns rendering.

```swift
import Metal
import MilkMetal

let device = MTLCreateSystemDefaultDevice()!
let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
try renderer.load(MilkPreset(contentsOf: presetURL))
let view = try MilkView(renderer: renderer)        // add to a window; it draws every display refresh
```

### Threading

``MilkRenderer`` and ``MilkView`` are main-actor types. The exception is
``MilkRenderer/feed(samples:channels:sampleRate:)``: it's nonisolated, and it doesn't allocate, lock or block, so
it's safe from a real-time audio thread. Call it from one thread at a time. ``MilkPreset`` is `Sendable`, so you can
read presets on a background task and hand them to the renderer on the main actor.

### Audio

Feed interleaved Float32 PCM in playback order, in chunks of any size (straight from an audio tap): the renderer
plays it out in step with its frames. Stereo is expected; mono is duplicated. With no audio (paused, or playing
on another device) presets keep moving: silence reads as normal levels.

### Errors and fallbacks

Creating a renderer throws ``MilkRendererError``, and reading a preset throws ``MilkPresetError``. Loading never
fails because of the preset's content. An equation block that doesn't compile is skipped. A shader that doesn't
translate or compile falls back to MilkDrop's fixed-function pass. ``MilkRenderer/presetErrors`` lists what
happened, for display only.

### Drawing into your own layer

Call ``MilkRenderer/render(to:commandBuffer:time:)`` once per frame with a texture in the renderer's
``MilkRenderer/pixelFormat``, a steadily rising `time` in seconds, and a command buffer you then commit. The renderer
keeps up to three frames in flight and waits if the GPU falls further behind.

## Topics

### Rendering
- ``MilkRenderer``
- ``MilkView``
- ``MilkRendererError``

### Presets
- ``MilkPreset``
- ``MilkPresetError``

### Transitions
- ``MilkTransitionPattern``
- ``MilkRenderer/load(_:transition:)``
~~~

## 5. Semver policy

Proposal for `README.md` § Versioning, from 1.0.0 on.

**Major (breaking):**
- Removing or renaming a public symbol or library product. Changing a signature, a type, isolation (`@MainActor`,
  `nonisolated`) or `Sendable`-ness. Adding `throws` or `async` to an existing API.
- Raising the deployment floor (macOS 14) or dropping a supported pixel format.
- A `.milkpreset` bundle that 1.x wrote stops loading. Bundles may fall back to runtime translation (F8); they may
  not fail.
- Removing a `milkconvert` subcommand or flag listed in the README.

**Minor:**
- New API, products, platforms (iOS) or pixel formats.
- **New cases in public enums** (`MilkTransitionPattern`, the error enums). Clients switch with `default`, and the
  docs say so. The package isn't built with library evolution, so this is a source-level promise, not one the
  compiler enforces.
- **Rendering changes that move closer to MilkDrop or Butterchurn** (new features such as disk textures, fidelity
  fixes, analyzer tuning), listed under "Rendering" in the changelog.
- Raising the Swift tools version (also called out in the changelog).

**Patch:** bug fixes with no API change, including rendering fixes for presets that drew wrongly, crashed or went
black.

**Not covered by semver:**
- Bit-exact output across versions.
- The text of `presetErrors`, error descriptions and CLI output.
- Performance. A regression past the handoff budget (8 ms GPU / 2 ms CPU at 1080p) is treated as a bug.

**Guaranteed within a version:** the same preset, seed, mesh size, target size, frame times and audio give the same
frames on the same GPU family. Golden-image tests rely on this.

**Compatibility pass rate:** recorded for each release in the changelog. A drop is a regression and has to be
explained in that release's notes.

## 6. Release checklist

Owner approval is needed for the items marked ✱.

1. ✱ Decide F1–F5 (F2–F5 done; F1 open), and land the accepted fixes plus F10 (it changes a type) in `Sources/` once the M5 and M6 agents
   are done.
2. Doc comments on every public symbol (F12). `swift build` is clean with no warnings. Re-run
   `swift-symbolgraph-extract` and check the inventory in §1 against the result.
3. VM: `scripts/run-tests-vm.sh` on a clean tree, with all tests passing including M5's transition tests (run ID
   recorded). Also run `--frames --preset Presets/echo.milk --next Presets/shader-glow.milk` and look at the frames.
4. VM: M6 compatibility run over the corpus (`--corpus Corpus/…`). Record the pack, preset count, pass rate, failure
   breakdown and median/p99 frame times in `CHANGELOG.md` under 1.0.0 and in `docs/compatibility.md`.
5. README: the edits in §4, the Versioning section from §5, Installation switched to
   `.package(url: "https://github.com/brennanMKE/MilkDropMetalKit.git", from: "1.0.0")`, and status "1.0".
6. `CHANGELOG.md`: change "Unreleased" to `1.0.0 – <date>` and fill in the M6 numbers.
7. `scripts/build-app.sh:20`: `VERSION="1.0.0"` (it's `0.1.0` now), so the Gallery DMG name matches the tag.
8. Commit, then ✱ `git tag -a 1.0.0 -m "MilkDropMetalKit 1.0.0"` and `git push origin main 1.0.0`. Use no `v`
   prefix: SwiftPM resolves either, and the README will say `from: "1.0.0"`.
9. Check from a scratch package that depends on `from: "1.0.0"` that it resolves and builds (a host build only, no
   rendering).
10. ✱ Optional: `scripts/make-dmg.sh --notary-profile <profile>` uploads the DMG to Apple's notary service. Attach
    the notarized `build/dist/MilkDrop-Gallery-1.0.0.dmg` to a GitHub release (`gh release create 1.0.0`) with the
    changelog entry.
11. Roadie: bump `project.yml` to `from: 1.0.0`, then run `check-identifiers.sh` and the entitlement checks.
