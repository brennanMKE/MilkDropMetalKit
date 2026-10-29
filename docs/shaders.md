# MilkDrop 2 shaders

MilkDrop 2 presets can replace the warp and the composite with pixel shaders written in HLSL, Shader Model 2/3 era,
inside a prelude MilkDrop provides. `MilkShaders` translates them to Metal Shading Language in Swift, and the renderer
compiles the result with `makeLibrary(source:)`.

## Why a translator in Swift

The handoff suggested HLSL → SPIR-V (DXC or glslang) → MSL (SPIRV-Cross) in `milkconvert`. We translate directly
instead:

- **Runtime presets.** Roadie lets users add a folder of `.milk` files. A Swift translator runs at load in any app,
  with no toolchain on board and no new entitlements. The offline path (`milkconvert convert`) uses the same code.
- **The dialect.** DXC accepts only Shader Model 6 syntax and rejects `tex2D` and friends, which every preset uses.
  glslang's HLSL front end is closer, but MilkDrop shaders also lean on fxc's leniency: vectors truncate silently on
  assignment, uniforms are writable, and `%` works on floats. Patching those after SPIR-V is harder than typing them in
  one pass.
- **Coverage.** Over the 9,795-preset "Cream of the Crop" pack, 15,891 of 15,895 shaders (99.97%) translate and
  compile with Metal. Run `swift run milkconvert shaders --compile <dir>` to check a pack.

## Pipeline

1. **Lexer** (`Lexer.swift`): tokens; comments removed; newlines kept for the preprocessor.
2. **Preprocessor** (`Preprocessor.swift`): `#define` (object and function-like), `#undef`, `#if`/`#ifdef`/
   `#ifndef`/`#elif`/`#else`/`#endif`. MilkDrop's helpers are predefined: `GetMain`, `GetPixel`, `GetBlur1`–`3`,
   `lum`, `tex2d`, `tex3d`.
3. **Parser** (`Parser.swift`): global declarations (variables, `static const` tables, samplers, `sampler_state`
   blocks, which are skipped), functions with `in`/`out`/`inout` parameters, and `shader_body { … }`. Statements:
   blocks, declarations, `if`, `for`, `while`, `do`, `return`, `break`, `continue`, `discard`. Expressions: the C
   operators, casts, constructors, swizzles, indexing and initializer lists.
4. **Emitter** (`Emitter.swift`): infers each expression's type and writes MSL, inserting the conversions HLSL
   does implicitly:
   - vector truncation (`float3 c = tex2D(…)`), scalar broadcast (`float3 a = 1`), and int to float;
   - mixed vector sizes in operations truncate to the smaller, as fxc does;
   - `%` on floats becomes `fmod`, and `lerp`/`frac`/`ddx`/`rsqrt`… become their MSL names;
   - `sincos`, `modf` and `clip` become small helpers;
   - a uniform the shader assigns (`q25 = q24;`) becomes a local copy.

### Representation choices

- **Names.** User names get a prefix (`v_` locals, `g_` globals, `f_` functions), so a variable called `mix` or
  `sample` can't collide with MSL.
- **Matrices are stored transposed.** HLSL `float2x2(a, b, c, d)` lists rows and MSL lists columns, so the same text
  builds the transpose. Then `m[i]` is still row i, `mul(a, b)` becomes `(b * a)`, and componentwise `*` on two
  matrices becomes `milk_cmul`.
- **Samplers.** `sampler_[fw_|fc_|pw_|pc_]NAME` becomes a texture plus a sampler state: filtered or point, wrap or
  clamp. Unprefixed `sampler_main` uses the preset's `bTexWrap`.
- **Uniforms** live in one `MilkUniforms` buffer. Functions that read uniforms, textures or mutable globals get them
  as extra parameters, since MSL has no mutable or texture globals. HLSL requires functions to be defined before use,
  so one pass collects what each function needs.

## What a shader sees

| Name | Value |
|---|---|
| `uv`, `uv_orig` | The warped and unwarped texture coordinate (MilkDrop's convention: v = 0 at the top). |
| `rad`, `ang` | Distance from the centre (texture units) and angle, as Butterchurn computes them. |
| `ret` | The output colour, `float3`. Saturated, with NaN as black. |
| `hue_shader` | The composite's corner tints, interpolated. |
| `time`, `fps`, `frame`, `progress` | Clock. `progress` is 0: in MilkDrop it is how far the preset is through its display time, which the host decides here. |
| `bass`…`vol_att` | Band levels and their smoothed versions; `vol` is their mean. |
| `q1`–`q32`, `_qa`–`_qh` | The per-frame equations' q variables. |
| `aspect`, `texsize` | Aspect factors and inverses; texture size and inverse. |
| `rand_frame`, `rand_preset` | Random each frame / per preset. |
| `roam_cos`, `roam_sin`, `slow_roam_*` | Slowly drifting values in 0…1. |
| `blur1_min`…`blur3_max`, `GetBlur1`–`3` | The blur ranges and the three blur levels. |
| `sampler_noise_lq`/`_lq_lite`/`_mq`/`_hq`, `sampler_noisevol_lq`/`_hq` | Noise, 2D and 3D, with `texsize_*`. |
| `rot_s1`…`rot_rand4` | Rotation matrices (static, slow, fast, very fast, ultra fast, random). |

## Known gaps

- **Disk textures.** A preset can name textures from MilkDrop's folder (`sampler_clouds2`, `sampler_rand00`). None
  ship with the package, so the smooth noise texture stands in, and `presetErrors` lists the missing names.
- **`rot_*` rates.** MilkDrop's exact rotation speeds aren't documented; ours are an approximation.
- **No mipmaps on the feedback texture.** A shader that samples it heavily minified looks sharper than MilkDrop.
- **Shader Model 3 features beyond the corpus** (`tex2Dgrad` aside) are untested.
- **Fidelity.** Correct compilation isn't proof of a correct image. The planned golden-image comparison against
  Butterchurn (milestone 6) is the real check.

## Loading and compiling

`MilkRenderer.load` translates at once, which takes a few milliseconds. It then compiles in the background by default,
because the Metal compiler takes about 30 ms per shader. Until a stage's pipeline is ready, the fixed-function pass
stands in. Offscreen tools and tests set `compilesShadersInBackground = false` so the first frame already uses the
shaders. Compiled pipelines are cached by source.

`milkconvert convert --out DIR presets/` writes `.milkpreset` bundles: `preset.milk`, the translated
`warp.metal`/`composite.metal`, and `manifest.json`. `MilkPreset(contentsOf:)` loads a bundle and skips translation.
