# Compatibility runs

Handoff §6 item 6: run the large preset packs through parse, translate and render, flag crashes, NaNs, black
frames and over-budget frames, and track the pass rate per release. `milkview-demo compat` does the rendering and
`scripts/run-tests-vm.sh --compat` runs it in the Tart VM, like every other render (see
[testing-in-vm.md](testing-in-vm.md)). Never run it on the host.

## Running

```bash
scripts/run-tests-vm.sh --compat Corpus/presets-cream-of-the-crop --compat-stride 50     # ~200 presets, ~2 min
scripts/run-tests-vm.sh --compat Corpus/presets-cream-of-the-crop --compat-frames 300    # all 9,795, ~2 h
```

Results land in `build/vm-tests/<run-id>/`: `report.jsonl` (one JSON line per preset), `summary.json` (the
totals), `compat.log` (one progress line per preset, plus restarts) and the totals in `summary.txt`.

| `run-tests-vm.sh` flag | Meaning |
|---|---|
| `--compat DIR` | Every `.milk` under DIR (any host path), folders kept; hidden folders such as `.git` skipped |
| `--compat-stride N` | Every Nth preset of the sorted list, for a quick sample (default 1, all) |
| `--compat-limit N` | At most N presets (after the stride) |
| `--compat-frames N` | Frames rendered per preset (default 120, i.e. 2 s at 60 fps). Use 300 for a release run: a few presets only draw after a couple of seconds |
| `--compat-timeout S` | Seconds one preset may take, load included, before it's recorded as a `timeout` (default 60) |
| `--compat-hours H` | Stop the step after H hours and bring back the partial report (default 10) |

The tool itself, as the VM runs it:

```
milkview-demo compat --dir DIR --report FILE.jsonl [--frames N] [--every K] [--size WxH] [--timeout S]
                     [--budget-ms MS] [--cpu-budget-ms MS] [--stride N] [--limit N]
```

`--every K` reads back and checks every Kth frame and always the last (default 30). `--size` defaults to 640x360.
`--budget-ms` and `--cpu-budget-ms` are the p99 frame-time budgets the summary counts against (default 8 and 2,
from handoff §7).

## What it does per preset

1. One `MilkRenderer` for the run (`.rgba16Float` target, `compilesShadersInBackground = false`), `reset()` before
   each preset, then `load(MilkPreset(contentsOf:))`. `load` keeps the feedback image, the frame counter and the
   random sequence, so without the reset each result would depend on the presets before it and on where a restart
   picked up; `reset()` puts the renderer back as new (feedback, clock, audio, random sequence, transition), and a
   check on 771 presets gave bit-identical frames to a new renderer per preset. Until 2026-10-29 the runner made a
   new renderer per preset, so `loadMs` in older reports includes creating it.
2. N frames at a fixed 60 fps clock, `SynthAudio` fed before each, `waitUntilCompleted` after each.
3. Every Kth frame and the last are read back as `Float16` and checked by `FrameCheck`. The target is 16-bit float
   so NaN and infinity survive; an 8-bit target would turn them into black.
4. One JSON line is appended (`CompatResult`) and fsynced.

| Failure | When |
|---|---|
| `crash` | The process died on it. Found on restart: the sidecar `FILE.jsonl.current` names the preset and it has no record |
| `timeout` | Over `--timeout` seconds. A watchdog timer off the main thread writes the record and exits 3, so a hung shader compile or `waitUntilCompleted` is caught too |
| `load-failed` | `MilkPreset(contentsOf:)` or `load` threw |
| `gpu-error` | A command buffer finished with an error |
| `nan` | Any checked frame had a NaN or infinite pixel |
| `black` | The last checked frame's brightest channel is under 1.5/255 |

Not failures, but recorded: `presetErrors` (equation blocks skipped, shaders that fell back to the fixed-function
pass, missing disk textures), the load time, and the median and p99 CPU time of `render(to:commandBuffer:time:)`
and GPU time (`gpuEndTime - gpuStartTime`), leaving out the first frame, which allocates textures. `gpuMaxFrame`
says which frame was slowest.

The restart loop in the guest runs the tool until it exits 0, which it does once every selected preset has a
record; a crash or timeout restarts it and it resumes from the report. It gives up after 1000 restarts. The step
fails only if the tool couldn't finish; the pass rate never fails a run.

## Timing caveat

The guest's GPU is `Apple Paravirtual device`. Its timings are noisy (single frames of 40–80 ms on presets whose
median is 2–3 ms; one sampled run had 60 of 196 presets over the GPU p99 budget and the next had none) and say
nothing about the slowest supported Mac. The over-budget counts are reported to spot outliers, never to pass or
fail anything. Budget numbers need a real Mac; see the open decision in [testing-in-vm.md](testing-in-vm.md).

## Results

| Date | Code | Presets | Frames, size | Passed | crash | timeout | load-failed | gpu-error | nan | black | Wall |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-29 | f0c051b + working tree | 9,795 (all of Cream of the Crop) | 300, 640x360 | **9,587 (97.88%)** | 0 | 0 | 0 | 0 | 0 | 208 | 5,860 s + reruns (see below) |
| 2026-10-29 | f783c83 + M6 tooling (working tree) | 9,795 (all of Cream of the Crop) | 300, 640x360 | **9,532 (97.31%)** | 0 | 0 | 0 | 0 | 0 | 263 | 7,198 s |
| 2026-10-29 | same | 196 (stride 50) | 120, 640x360 | 194 (98.98%) | 0 | 0 | 0 | 0 | 0 | 2 | 104 s |

Full run, also: 1,787 passing presets have `presetErrors`, almost all "textures not available, noise used
instead" (1,811 presets name a disk texture the package doesn't ship); only 16 presets have equation or shader
errors. Median preset: 0.81 ms GPU, 0.48 ms CPU per frame. Over the p99 budgets: 1,104 presets (GPU, 8 ms) and
1,693 (CPU, 2 ms), but by median only 2 presets are over 8 ms GPU and 464 over 2 ms CPU (VM numbers; see above).

A third run (stride 50, 300 frames) had its process killed with `SIGKILL` part way through: the restart loop
recorded a `crash` for that preset (exit status 137) and finished the rest, which is how the crash path was checked.
A run with `--compat-timeout 2` and 3000 frames recorded a `timeout` for each of its 5 presets and restarted after
each.

### Black frames: causes found and fixed (f0c051b + working tree)

Each failing preset was rendered four ways in the VM: as is, without its composite shader, without its warp shader
and without either, which says which pass produces the black. Then the suspects were checked against Direct3D 9,
which MilkDrop 2's HLSL actually runs on, and against passing near-variants. Fixed, each with a unit test:

| Cause | Presets fixed | Fix | Test |
|---|---|---|---|
| **0 / 0 and 0 × ∞ are NaN in IEEE, 0 in Direct3D 9.** Shaders divide by q variables the per-frame code never sets (the `moebius` remix family: `mu/(c*z+d)` with every q 0) or compute `.4/rad1 * … * q22` with both 0. The NaN reaches the 8-bit feedback or the output as black | ~38 (21 `moebius` remixes such as `Reaction/Automata/… re-m flx …` and `the green machine 2 …`; 9 `glassball dance` variants; others) | Float `/` emits `milk_div`: 0 / 0 is 0, x / 0 is ±`FLT_MAX` rather than ∞ so a later `* 0` is 0. Written with selects so fast math can't fold it | `TranslatorTests.floatDivisionFollowsDirect3D9`, `MilkRendererTests.shaderArithmeticFollowsDirect3D9` |
| **`pow` and `log` of a negative are NaN in IEEE; D3D9's `pow`/`log` use \|x\|** | 5 (`… hog rot` remixes, `square_faces_v2_alt_colours`) | `pow`, `log`, `log2`, `log10` take `abs` of the (first) operand | `TranslatorTests.logAndPowTakeTheAbsoluteValueLikeDirect3D9`, `shaderArithmeticFollowsDirect3D9` |
| **Unprefixed `sampler_main` in the composite clamped when `bTexWrap=0`.** MilkDrop 2 binds unprefixed samplers filtered and wrapping. `dotes hostile undertake` and `dinner - ratios …` presets read it at 1…4, which clamped to one edge texel | 12 | Composite: unprefixed `sampler_main`/`GetPixel` wrap. The warp keeps `bTexWrap` (below) | `TranslatorTests.unprefixedSamplerMainWrapsInTheComposite` |

Tried and left out, because each turned passing presets black:

- **`sqrt`/`rsqrt` of |x|** (D3D9's `rsq` takes |x| too). It fixed 7 (`Dancer/Blobby/suksma - floresiensis`, the
  `crystal palace` remixes, `space gelatine burst …`, `empty flow - collab`) but turned `Fractal/Nested Circle/bdrv +
  al Rovastar - Fractopia … soft death` and `… soft death roam3` black: their warp's `1/sqrt(uv6.y)` is NaN (black)
  over half the screen in IEEE, and with |x| the feedback fills and their inverted composite (`1 - blur`) goes black.
  Probably closer to MilkDrop, but a regression by this run's rule.
- **Wrapping unprefixed `sampler_main` in the warp shader too.** It fixed 4 more (`suksma - biotoxins on strings …`,
  `pladman visits the sevendys … nz`, `suksma - nontillion horrors`, `Fractopia … outsanitice`) but turned 4 black
  (`cammy told me about yeast infected loaves roam`, `Bdrv Aderrasi - Accelerator … rmx8 …`, `amandio c - log tower 1
  pig vomit …`, `Fractopia … divulgatticae roams`).

How the row above was measured: the full run (`build/vm-tests/20261029-043441-80671`, 9,594 passed) had both of
those in. After taking them out, every preset they can affect was rendered again: the 2,362 with `bTexWrap=0` whose
warp shader reads `sampler_main` (`20261029-062820-37001`) and the 1,243 whose shaders call `sqrt`/`rsqrt`
(`20261029-070416-54424`); every other preset's shaders are unchanged by them. Against the previous full run
(`20261029-013948-87982`): **55 newly passing, 0 newly failing**. The runner itself now reuses one renderer with
`reset()`; on 771 presets that gave bit-identical frames to a new renderer per preset.

Left (208, all black). By the four-way ablation:

- 44 are black whichever shaders run (2 of them transitions to black): e.g. the `Dancer/Tree Branch/shifter -
  robotopia v2 …` family and `PieturP - sunflare` (textured shapes multiplying a black image). Several depend on the
  starting image: MilkDrop carries the previous preset's image over, and this run starts from black.
- About 18 go black only with their warp shader, which wipes the feedback (`ret -= 1 - q2` with q2 never set), and
  only draw on beats (`fleekus flokus - … beat code experiment`), so frame 300 can land between flashes.
- About 130 go black only with both shaders together, or only with the composite: the `Flexi - emergencey 2 ---
  Isosceles edit*` reaction-diffusion family (from a black start the green channel fills to 1 everywhere and the
  composite `lerp(white, 0, g)` shows black), `Dancer/Comet Mirror/226` (its composite samples one 26° wedge of a
  fast-decaying image), the `Waveform/Wire Rising/1xx` family (`1/GetBlur2(…)` composite), `repressed americans -
  mess roam` and `fed's FASTBLUR -frost -neural` (still black from about frame 210), and the ones dark by design
  (`Flexi - evolution 6`, peak 0.0044).
- Not tried: D3D9's 0 × ∞ = 0 for every multiply (only division is covered), `normalize(0)`, and a non-black starting
  image.

### Black frames (f783c83, before the fixes)

All 263 failures are black frames, and they are mostly real rendering bugs, not presets that are dark by design:

- 248 of them use MilkDrop 2 shaders (3.0% of the 8,251 shader presets), against 15 of the 1,544 MilkDrop 1 presets
  (1.0%). 249 have a peak of exactly 0, which points at a whole pass producing zero (or a NaN in the 8-bit feedback
  texture, which stores as 0) rather than a dim image.
- They cluster in families of remixes (`… the green machine 2 skin lard bone beacon nz+ …`, `if it's good enough
  for me to save … re-m flx …`), so a few root causes probably cover many of them.
- Rendered again at 1280x720 with `--frames`, four were black from frame 30 to 300, and two drew for a few seconds
  and then went black (marked below).
- 3 are black by design: `! Transition/Fast transition to black …`, `! Transition/Slow transition to black - gas
  effect + zoom in …` and `… zoom out …`.
- 14 have a tiny non-zero peak (1e-4 to 0.0044) and may be dark by design, e.g. `Reaction/Liquid Ripples/Flexi -
  evolution 6.milk`.

By folder: Reaction 81, Sparkle 49, Dancer 41, Waveform 40, Fractal 20, Geometric 14, Supernova 8, `! Transition` 3,
Drawing 3, Hypnotic 2, Particles 2.

| Preset | Detail |
|---|---|
| `Dancer/Comet Mirror/226.milk` | Black from frame 30 at 1280x720 too. Warp decays hard (`(ret - 0.004) * 0.83`), composite samples along a radial line |
| `Dancer/Blobby/suksma - floresiensis.milk` | Black from frame 30 at 1280x720 too |
| `Reaction/Automata/amandio c - the green machine 2 skin lard bone beacon.milk` | Black from frame 30 at 1280x720; 9 more variants of it in Drawing/Trails and Reaction are black |
| `Reaction/Automata/if it's good enough for me to save, it's dead enough for you to re-m flx nz+.milk` | Black from frame 30 at 1280x720; 4 more variants are black |
| `Waveform/Spectrum/repressed americans - mess roam.milk` | Draws (dark green and blue) to about frame 210, black by 300. Passed in a 120-frame run |
| `Supernova/Burst/fed's FASTBLUR -frost -neural.milk` | Draws to about frame 210, black by 300 |
| `Dancer/Blobby/suksma - never bam.milk` | Black; names disk textures `grad`, `grad2` (noise stands in) |
| `Dancer/Glowsticks Mirror/205.milk` | Black; names texture `worms` |
| `Dancer/Lasers/Blendin to myself AdamFX Twist 2 martin - glassball dance with AdamFX.milk` | Black, as are 6 of its variants (b, c, e, f, g, Cope) |
| `Dancer/Comet/EoS + Phat - chasers 09 sentinel nz+ cesspratice.milk` | Black |
| `Dancer/Glowsticks Mirror/EoS + others - glowstick demon.milk` | Black |

### Equation and shader errors (passing, fixed-function fallback or block skipped)

| Preset | Error |
|---|---|
| `Supernova/Radiate/EVET - Spiracology 2.milk` | warp shader: line 15: unknown function GetBlur1 |
| `Geometric/Stripes Circle/fed's stoboscopix.milk` (and `stroboscopix`) | warp shader: can't convert float4x3 to float |
| `Particles/Blobby/$$$ Royal - Mashup (287).milk` | composite shader: line 32: unexpected "}" |
| `Fractal/Nested Circle/Nivush - Crazy Diamonds.milk` | per_frame: assignment to something that is not a variable at 764 |
| `Reaction/Automata/suksma - Hexcollie - Julian Carnival - shimmy dumb grid dogmaklyasm nz+5.milk` (and `nz+6`) | per_frame: assignment to something that is not a variable at 1119 |
| `Fractal/Nested Square/Goody's Datura Bloom.milk` | per_pixel: syntax error at 68: unexpected character "\" |
| `Fractal/Nested Square/Hexcollie - Ultra daze.milk` | per_frame_init: syntax error at 87: unexpected end |
| `Geometric/Stripes Dance/martin - beamer code 22h - lines - rhythmic and fast.milk` | per_frame: syntax error at 4432: unexpected "*" |
| `Dancer/Comet Mirror/EoS_Phat_PeterP_Sentinel_Aware_6 EoS edit C.milk` (and 2 variants) | shape_0_per_frame: syntax error at 33: expected ")" |
| `Reaction/Liquid Blobby/pheremones is spelled pheromones asshole.milk` | per_pixel: syntax error at 13: unexpected character "." |

### Slowest (VM numbers, outliers only)

| Preset | GPU median / p99 ms | CPU median / p99 ms |
|---|---|---|
| `Drawing/Explosions Mirror/suksma - feign shoulder concern when i should be executed - completely drugged yet functional with evil intent schtaezea.milk` | 8.61 / 34.24 | 1.94 / 15.80 |
| `Dancer/Comet/EoS + Phat - chasers 09 sentinel nz+ thee qlaph.milk` | 1.19 / 84.24 | 1.53 / 1.91 |
| `Geometric/Sphere Wild/va ultramix - 293 heat cannon oqult i'm stevo-o and i make people happy for a living.milk` | 3.52 / 24.64 | 4.59 / 35.29 |
| `Drawing/Liquid/to know the reason i am trapped is my own weakness and fear - the trap is the trap nz explicit chaos beasth.milk` | — | 5.52 / 6.32 |
| `Geometric/Cube/shifter + amandio c - tumbling cubes (dynamic shapes) - copin.milk` | — | 4.70 / 8.56 |
