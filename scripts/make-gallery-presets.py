# make-gallery-presets.py — writes the gallery presets (Presets/*.milk) and Presets/gallery.json.
#
# Usage: python3 -I scripts/make-gallery-presets.py Presets
# Every preset is written for this repo and released under its MIT licence. Each shows one renderer feature; edit
# them here and regenerate rather than editing the .milk files.
import json, sys, os, re
out = sys.argv[1]

BASE = [("MILKDROP_PRESET_VERSION","100"),("fRating",3),("fGammaAdj",1.5),("fDecay",0.95),("fVideoEchoZoom",1),
  ("fVideoEchoAlpha",0),("nVideoEchoOrientation",0),("nWaveMode",0),("bAdditiveWaves",0),("bWaveDots",0),
  ("bWaveThick",1),("bMaximizeWaveColor",1),("bTexWrap",0),("bBrighten",0),("bDarken",0),("bSolarize",0),
  ("bInvert",0),("fWaveAlpha",0.8),("fWaveScale",1),("fWaveParam",0),("fWarpAnimSpeed",1),("fWarpScale",1),
  ("fZoomExponent",1),("zoom",1),("rot",0),("cx",0.5),("cy",0.5),("dx",0),("dy",0),("warp",0),("sx",1),("sy",1),
  ("wave_r",1),("wave_g",1),("wave_b",1),("wave_x",0.5),("wave_y",0.5),
  ("ob_size",0.01),("ob_r",0),("ob_g",0),("ob_b",0),("ob_a",0),("ib_size",0.01),("ib_r",0.25),("ib_g",0.25),("ib_b",0.25),("ib_a",0)]

_phase = [0]
def cycle():
    # Colour cycling, with a different starting hue per preset so the gallery isn't one colour at a time.
    _phase[0] += 1; k = _phase[0] * 1.7 % 6.28
    return [f"wave_r = 0.5 + 0.5*sin(time*1.13 + {k:.2f});", f"wave_g = 0.5 + 0.5*sin(time*0.91 + {k + 2:.2f});",
            f"wave_b = 0.5 + 0.5*sin(time*0.77 + {k + 4:.2f});"]

def fmt(k, v):
    if isinstance(v, str): return v
    # nWaveMode, bTexWrap, ...: integers, as MilkDrop writes them.
    if re.match(r"^[nb][A-Z]", k): return str(int(v))
    return f"{float(v):.6f}"

def write(name, settings, per_frame=(), per_pixel=(), init=(), raw=(), warp=None, comp=None):
    values = dict(BASE); values.update(settings)
    if warp or comp:
        values["MILKDROP_PRESET_VERSION"] = "201"
    lines = ["[preset00]"] + [f"{k}={fmt(k, values[k])}" for k, _ in BASE]
    lines += [f"{k}={fmt(k, v)}" for k, v in settings.items() if k not in dict(BASE)]
    lines += [f"per_frame_init_{i+1}={l}" for i, l in enumerate(init)]
    lines += [f"per_frame_{i+1}={l}" for i, l in enumerate(per_frame)]
    lines += [f"per_pixel_{i+1}={l}" for i, l in enumerate(per_pixel)]
    lines += list(raw)
    if warp or comp:
        lines += ["PSVERSION=2", "PSVERSION_WARP=2", "PSVERSION_COMP=2"]
    for prefix, text in (("warp", warp), ("comp", comp)):
        if text:
            lines += [f"{prefix}_{i+1}=`{l}" for i, l in enumerate(text.strip("\n").split("\n"))]
    with open(os.path.join(out, name + ".milk"), "w") as f:
        f.write("\n".join(lines) + "\n")

catalog = []
def category(name): catalog.append({"name": name, "presets": []})
def preset(file, title, summary, settings, per_frame=(), per_pixel=(), init=(), raw=(), warp=None, comp=None):
    write(file, settings, per_frame, per_pixel, init, raw, warp, comp)
    catalog[-1]["presets"].append({"file": file + ".milk", "title": title, "summary": summary})

category("Showcase")
catalog[-1]["presets"].append({"file": "spike-tunnel.milk", "title": "Spike Tunnel",
  "summary": "Everything at once: per-frame colour and zoom, per-vertex zoom and rotation, a thick additive circle wave, video echo and an outer border."})

category("Waveforms")
preset("wave-circle", "Mode 0: Circle",
  "nWaveMode 0 bends the waveform into a ring. A slight zoom pushes each old frame outward, so the rings spread.",
  {"fDecay": 0.93, "fWaveParam": -0.2}, cycle() + ["zoom = 1.02;"])
preset("wave-scope", "Mode 1: Radial Scope",
  "nWaveMode 1: the right channel sets each point's distance from the centre and the left its angle, so the wave swirls around a ring.",
  {"nWaveMode": 1, "fDecay": 0.94, "fWaveScale": 1.2}, cycle() + ["zoom = 0.99;", "rot = 0.02;"])
preset("wave-xy", "Mode 2: XY Scope",
  "nWaveMode 2 plots the left channel against the right, like an oscilloscope in X-Y mode, faintly. Mono sound is a diagonal line; stereo opens it up.",
  {"nWaveMode": 2, "fDecay": 0.97, "fWaveScale": 1.4, "fWaveAlpha": 1.0, "bAdditiveWaves": 1}, cycle() + ["rot = 0.01;"])
preset("wave-xy-treble", "Mode 3: XY Scope, Treble",
  "nWaveMode 3 is the X-Y scope again, but treble sets its brightness: it flares on hi-hats and cymbals.",
  {"nWaveMode": 3, "fDecay": 0.96, "fWaveScale": 1.4, "fWaveAlpha": 1.0, "bAdditiveWaves": 1}, cycle() + ["zoom = 1.01;"])
preset("wave-momentum", "Mode 4: Momentum Line",
  "nWaveMode 4 draws a horizontal line whose points carry momentum from their neighbours, so it ripples like a rope. wave_mystery sets how much.",
  {"nWaveMode": 4, "fDecay": 0.985, "fWaveParam": 0.3, "wave_y": 0.3}, cycle() + ["dy = -0.006;"])
preset("wave-products", "Mode 5: Rotating Products",
  "nWaveMode 5 multiplies the channels together into a slowly rotating knot.",
  {"nWaveMode": 5, "fDecay": 0.95, "fWaveScale": 2.0, "fWaveAlpha": 1.0, "bAdditiveWaves": 1}, cycle() + ["zoom = 1.015;"])
preset("wave-line", "Mode 6: Angled Line",
  "nWaveMode 6 draws a line across the screen at an angle set by wave_mystery. dy moves every frame up the screen, so the history scrolls like a waterfall.",
  {"nWaveMode": 6, "fDecay": 0.985, "fWaveScale": 1.5, "wave_y": 0.15, "fWaveAlpha": 0.7}, cycle() + ["dy = -0.008;"])
preset("wave-stereo", "Mode 7: Stereo Lines",
  "nWaveMode 7 draws the left channel above and the right below; wave_y sets the gap. sx above 1 stretches old frames sideways.",
  {"nWaveMode": 7, "fDecay": 0.92, "sx": 1.02, "wave_y": 0.7}, cycle())
preset("wave-dots", "Dot Spiral",
  "bWaveDots draws the circle wave as dots. Zoom and rotation turn the old dots into a spiral.",
  {"bWaveDots": 1, "fDecay": 0.96, "fWaveParam": -0.3}, cycle() + ["zoom = 1.03;", "rot = 0.08;"])

category("Custom Waves")
preset("custom-wave-spiral", "Custom Wave: Spiral",
  "A custom wave's per-point code places each of its samples. Here sample (0 to 1 along the wave) winds them into a spiral, and the audio in value1 makes it bristle.",
  {"fDecay": 0.9, "fWaveAlpha": 0.0, "zoom": 1.0},
  ["rot = 0.01;"],
  raw=["wavecode_0_enabled=1", "wavecode_0_samples=512", "wavecode_0_bAdditive=1", "wavecode_0_scaling=1.000000",
       "wavecode_0_smoothing=0.500000", "wavecode_0_r=1.000000", "wavecode_0_g=1.000000", "wavecode_0_b=1.000000",
       "wavecode_0_a=0.900000",
       "wave_0_per_frame1=t1 = time*0.7;",
       "wave_0_per_point1=r0 = 0.05 + sample*0.4 + value1*0.6;",
       "wave_0_per_point2=a0 = sample*24 + t1;",
       "wave_0_per_point3=x = 0.5 + r0*cos(a0);",
       "wave_0_per_point4=y = 0.5 + r0*sin(a0);",
       "wave_0_per_point5=r = 0.5 + 0.5*sin(sample*6 + time); g = 0.5 + 0.5*sin(sample*6 + time + 2); b = 0.5 + 0.5*sin(sample*6 + time + 4);"])
preset("custom-wave-spectrum", "Custom Wave: Spectrum",
  "bSpectrum gives a custom wave the frequency spectrum instead of the waveform: low notes on the left, high on the right. Two waves draw the left and right channels as mirrored bars of light.",
  {"fDecay": 0.86, "fWaveAlpha": 0.0},
  ["dy = -0.004;"],
  raw=["wavecode_0_enabled=1", "wavecode_0_samples=256", "wavecode_0_bSpectrum=1", "wavecode_0_bAdditive=1",
       "wavecode_0_bDrawThick=1", "wavecode_0_scaling=3.000000", "wavecode_0_smoothing=0.300000", "wavecode_0_a=1.000000",
       "wave_0_per_point1=x = sample; y = 0.5 + min(value1*0.6, 0.45);",
       "wave_0_per_point2=r = sample; g = 0.4 + 0.6*value1; b = 1 - sample;",
       "wavecode_1_enabled=1", "wavecode_1_samples=256", "wavecode_1_bSpectrum=1", "wavecode_1_bAdditive=1",
       "wavecode_1_bDrawThick=1", "wavecode_1_scaling=3.000000", "wavecode_1_smoothing=0.300000", "wavecode_1_a=1.000000",
       "wave_1_per_point1=x = sample; y = 0.5 - min(value2*0.6, 0.45);",
       "wave_1_per_point2=r = 1 - sample; g = 0.4 + 0.6*value2; b = sample;"])
preset("custom-wave-dots", "Custom Wave: Dots",
  "bUseDots draws a custom wave's samples as points. Per-frame code sets t1, which every per-point run then reads.",
  {"fDecay": 0.97, "fWaveAlpha": 0.0, "zoom": 1.02},
  [],
  raw=["wavecode_0_enabled=1", "wavecode_0_samples=200", "wavecode_0_bUseDots=1", "wavecode_0_bDrawThick=1",
       "wavecode_0_bAdditive=1", "wavecode_0_a=1.000000",
       "wave_0_per_frame1=t1 = 0.25 + 0.1*bass_att;",
       "wave_0_per_point1=ang0 = sample*6.2832*3 + time;",
       "wave_0_per_point2=x = 0.5 + t1*cos(ang0)*(0.6 + 0.4*sin(sample*31 + time*3));",
       "wave_0_per_point3=y = 0.5 + t1*sin(ang0)*(0.6 + 0.4*sin(sample*31 + time*3));",
       "wave_0_per_point4=r = 1; g = 0.6 + 0.4*sin(time + sample*9); b = 0.3;"])

category("Custom Shapes")
preset("shapes-basic", "Shapes",
  "Custom shapes are filled polygons with a centre colour, an edge colour and an outline. Here a hexagon breathes with the bass and a triangle spins with the treble.",
  {"fDecay": 0.94, "fWaveAlpha": 0.0, "zoom": 1.01},
  [],
  raw=["shapecode_0_enabled=1", "shapecode_0_sides=6", "shapecode_0_additive=1", "shapecode_0_rad=0.250000",
       "shapecode_0_r=1.000000", "shapecode_0_g=0.400000", "shapecode_0_b=0.100000", "shapecode_0_a=0.800000",
       "shapecode_0_r2=0.200000", "shapecode_0_g2=0.000000", "shapecode_0_b2=0.600000", "shapecode_0_a2=0.000000",
       "shapecode_0_border_a=0.600000",
       "shape_0_per_frame1=rad = 0.2 + 0.08*bass_att; ang = time*0.2;",
       "shapecode_1_enabled=1", "shapecode_1_sides=3", "shapecode_1_thickOutline=1", "shapecode_1_rad=0.120000",
       "shapecode_1_r=0.200000", "shapecode_1_g=1.000000", "shapecode_1_b=0.800000", "shapecode_1_a=0.600000",
       "shapecode_1_a2=0.200000", "shapecode_1_border_a=1.000000",
       "shape_1_per_frame1=ang = time*(0.5 + treb_att); x = 0.5 + 0.25*cos(time*0.6); y = 0.5 + 0.25*sin(time*0.6);"])
preset("shapes-instances", "Shape Instances",
  "num_inst draws a shape many times per frame; instance counts them so each copy can go somewhere else. Twenty-four copies of one shape make this ring.",
  {"fDecay": 0.92, "fWaveAlpha": 0.0, "zoom": 0.99, "rot": 0.02},
  [],
  raw=["shapecode_0_enabled=1", "shapecode_0_sides=4", "shapecode_0_num_inst=24", "shapecode_0_additive=1",
       "shapecode_0_rad=0.040000", "shapecode_0_a=0.900000", "shapecode_0_a2=0.300000", "shapecode_0_border_a=0.000000",
       "shape_0_per_frame1=p = instance/24*6.2832 + time*0.3;",
       "shape_0_per_frame2=x = 0.5 + 0.3*cos(p); y = 0.5 + 0.3*sin(p); ang = p;",
       "shape_0_per_frame3=r = 0.5 + 0.5*sin(p); g = 0.5 + 0.5*sin(p + 2.1); b = 0.5 + 0.5*sin(p + 4.2);",
       "shape_0_per_frame4=r2 = b; g2 = r; b2 = g; rad = 0.03 + 0.02*bass_att;"])
preset("shapes-textured", "Textured Shape",
  "A textured shape is filled with the previous frame. Turning its texture (tex_ang) and zooming into it (tex_zoom) folds the image back on itself.",
  {"fDecay": 0.97, "fWaveAlpha": 0.6, "fWaveParam": -0.3, "bAdditiveWaves": 1},
  cycle() + ["zoom = 1.01;"],
  raw=["shapecode_0_enabled=1", "shapecode_0_sides=40", "shapecode_0_textured=1", "shapecode_0_rad=0.400000",
       "shapecode_0_r=1.000000", "shapecode_0_g=1.000000", "shapecode_0_b=1.000000", "shapecode_0_a=0.900000",
       "shapecode_0_r2=1.000000", "shapecode_0_g2=1.000000", "shapecode_0_b2=1.000000", "shapecode_0_a2=0.300000",
       "shapecode_0_tex_zoom=1.100000", "shapecode_0_border_a=0.000000",
       "shape_0_per_frame1=tex_ang = time*0.1; tex_zoom = 1.05 + 0.05*sin(time*0.4);"])

category("Motion Vectors")
preset("motion-vectors", "Motion Vectors",
  "Motion vectors draw a grid of short lines showing where the warp is pulling each part of the image from. mv_x and mv_y set the grid, mv_l the length.",
  {"fDecay": 0.9, "fWaveParam": -0.3, "nMotionVectorsX": 32, "nMotionVectorsY": 20, "mv_l": 4.0, "mv_r": 1.0,
   "mv_g": 1.0, "mv_b": 1.0, "mv_a": 0.6},
  cycle() + ["zoom = 1.02 + 0.03*sin(time*0.5);", "rot = 0.03*sin(time*0.3);", "mv_r = wave_r; mv_g = wave_g; mv_b = wave_b;"])
preset("darken-center", "Darken Centre",
  "bDarkenCenter draws a faint dark spot in the middle every frame, so a zooming preset doesn't white out at its centre.",
  {"bDarkenCenter": 1, "fDecay": 0.975, "fWaveParam": -0.25},
  cycle() + ["zoom = 1.04;", "rot = 0.02;"])

category("Motion")
preset("motion-zoom", "Zoom",
  "zoom above 1 magnifies the previous frame every frame, so everything flows outward. Here the bass drives it.",
  {"fWaveParam": -0.35}, cycle() + ["zoom = 1.01 + 0.06*max(bass_att - 1, 0);"])
preset("motion-zoom-exponent", "Zoom Exponent",
  "fZoomExponent bends the zoom by distance from the centre. Below 1 the middle races outward; above 1 the edges do. It sweeps slowly here.",
  {"fWaveParam": -0.3, "fDecay": 0.95}, cycle() + ["zoom = 1.04;", "zoomexp = 1 + 0.8*sin(time*0.35);"])
preset("motion-rotate", "Rotation",
  "rot turns the previous frame about (cx, cy) every frame. The centre wanders, so the spin swirls.",
  {"nWaveMode": 1, "fDecay": 0.96, "fWaveScale": 0.8},
  cycle() + ["rot = 0.04 + 0.03*sin(time*0.5);", "cx = 0.5 + 0.15*sin(time*0.37);", "cy = 0.5 + 0.15*cos(time*0.29);"])
preset("motion-warp", "Warp",
  "warp distorts the frame with MilkDrop's animated sine field. fWarpScale sets the size of its swirls and fWarpAnimSpeed their speed.",
  {"warp": 2.0, "fWarpScale": 1.3, "fWarpAnimSpeed": 1.5, "fDecay": 0.96}, cycle() + ["zoom = 1.005;"])
preset("motion-stretch", "Stretch",
  "sx and sy scale the previous frame horizontally and vertically. Here they take turns.",
  {"fDecay": 0.95, "fWaveParam": -0.25}, cycle() + ["sx = 1.01 + 0.03*sin(time*0.8);", "sy = 1.01 + 0.03*cos(time*0.8);"])
preset("motion-drift", "Drift and Wrap",
  "dx and dy slide the frame a little every frame. With bTexWrap on, whatever leaves one edge comes back on the other.",
  {"bTexWrap": 1, "fDecay": 0.985, "fWaveParam": -0.3, "fWaveAlpha": 0.6},
  cycle() + ["dx = 0.006;", "dy = 0.004*sin(time*0.3);"])

category("Per-Vertex Equations")
preset("pixel-ripples", "Ripples",
  "per_pixel code runs for every point of the warp mesh. Zoom depends on rad, the distance from the centre, so rings travel outward.",
  {"fDecay": 0.97, "fWaveParam": -0.3}, cycle(), ["zoom = 1.005 + 0.04*sin(rad*16 - time*4);"])
preset("pixel-swirl", "Swirl",
  "Rotation that falls off with distance from the centre (rot depends on rad) twists the frame into a whirlpool.",
  {"fDecay": 0.96, "fWaveParam": -0.2}, cycle(),
  ["rot = 0.12*(1 - rad)*(1 + 0.5*sin(time*0.6));", "zoom = 0.995 + 0.03*rad;"])
preset("pixel-petals", "Petals",
  "ang is each point's angle around the centre. Zoom that varies with ang pushes the image out in six petals.",
  {"fDecay": 0.95, "fWaveParam": -0.3}, cycle(), ["zoom = 1.02 + 0.03*sin(ang*6 + time);"])

FILTER_BASE = {"fDecay": 0.95, "fWaveParam": -0.2, "warp": 0.3}
FILTER_FRAME = lambda: cycle() + ["zoom = 1.02;", "rot = 0.01;"]
category("Composite")
preset("echo", "Video Echo",
  "fVideoEchoAlpha blends a zoomed copy over the image and nVideoEchoOrientation mirrors it. The mirroring changes every 5 seconds.",
  {"fVideoEchoAlpha": 0.5, "fVideoEchoZoom": 1.35, "nWaveMode": 1, "wave_x": 0.35, "fDecay": 0.95},
  cycle() + ["echo_orient = (time/5) % 4;", "rot = 0.01;"])
preset("filter-solarize", "Solarize", "bSolarize folds bright colours back down, so the brightest parts turn dark.",
  dict(FILTER_BASE, bSolarize=1), FILTER_FRAME())
preset("filter-invert", "Invert", "bInvert flips every colour: black becomes white.",
  dict(FILTER_BASE, bInvert=1), FILTER_FRAME())
preset("filter-brighten", "Brighten", "bBrighten takes the square root of each colour, lifting the dim trails.",
  dict(FILTER_BASE, bBrighten=1, fDecay=0.9), FILTER_FRAME())
preset("filter-darken", "Darken",
  "bDarken squares each colour: dim trails sink away and only the brightest lines stay.",
  dict(FILTER_BASE, bDarken=1, fGammaAdj=2.0), FILTER_FRAME())
preset("gamma", "Gamma", "fGammaAdj multiplies the brightness of the final image. The bass drives it here.",
  dict(FILTER_BASE), FILTER_FRAME() + ["gamma = 0.8 + 2*min(max(bass_att - 0.6, 0), 1);"])
preset("borders", "Borders",
  "ob_ and ib_ draw an outer and an inner border every frame. Zooming out pulls the old ones inward into a tunnel of frames.",
  {"ob_size": 0.02, "ob_a": 0.9, "ib_size": 0.01, "ib_a": 0.7, "fWaveAlpha": 0.5, "fDecay": 0.97, "fWaveParam": -0.3},
  cycle() + ["zoom = 0.96;", "ob_r = 0.5 + 0.5*sin(time*0.6); ob_g = 0.3; ob_b = 0.5 + 0.5*cos(time*0.6);",
           "ib_r = 1 - ob_r; ib_g = 0.8; ib_b = 1 - ob_b;"])

category("MilkDrop 2 Shaders")
preset("shader-liquid", "Warp Shader: Liquid",
  "A MilkDrop 2 warp shader replaces the fixed warp. Here each pixel samples the previous frame at an offset read from a smooth noise texture that drifts, so the image flows like liquid.",
  {"fDecay": 1.0, "fWaveParam": -0.3, "bAdditiveWaves": 1, "fWaveAlpha": 0.7},
  cycle() + ["zoom = 1.005;"],
  warp="""
shader_body {
    float2 flow = tex2D(sampler_noise_mq, uv * 0.4 + time * float2(0.013, 0.007)).xy - 0.5;
    ret = tex2D(sampler_main, uv + flow * 0.006).xyz * 0.982 - 0.003;
}
""")
preset("shader-palette", "Composite Shader: Palette",
  "A composite shader decides how the feedback image reaches the screen without changing what feeds back. This one maps brightness onto a cycling cosine palette.",
  {"fDecay": 0.96, "fWaveParam": -0.25},
  cycle() + ["zoom = 1.02;", "rot = 0.01;", "q1 = bass_att;"],
  comp="""
shader_body {
    float3 c = tex2D(sampler_main, uv).xyz;
    float l = lum(c);
    ret = 0.5 + 0.5 * cos(6.2832 * (l * 1.5 + time * 0.07 + float3(0.0, 0.33, 0.67)));
    ret *= saturate(l * 3.0) * (0.8 + 0.2 * q1);
}
""")
preset("shader-glow", "Blur: Glow",
  "MilkDrop 2 keeps three blurred copies of each frame for shaders to read. Adding GetBlur1 and GetBlur2 back onto the image gives it a soft glow.",
  {"fDecay": 0.94, "fWaveParam": -0.3, "fWaveScale": 1.2},
  cycle() + ["zoom = 1.015;", "rot = 0.015*sin(time*0.4);"],
  comp="""
shader_body {
    ret = tex2D(sampler_main, uv).xyz + GetBlur1(uv) * 0.9 + GetBlur2(uv) * 0.7 + GetBlur3(uv) * 0.4;
    ret *= 0.9;
}
""")
preset("shader-noise", "Noise Textures",
  "Shaders get MilkDrop's noise textures: 2D in three smoothnesses, and 3D volumes. Here a slice through the 3D noise, moving through time, tints and pushes the image.",
  {"fDecay": 1.0, "fWaveParam": -0.3, "fWaveAlpha": 0.6},
  cycle(),
  warp="""
shader_body {
    float3 n = tex3D(sampler_noisevol_hq, float3(uv * 1.5, time * 0.05)).xyz;
    float2 push = (n.xy - 0.5) * 0.004 + (uv - 0.5) * 0.004;
    ret = tex2D(sampler_main, uv - push).xyz * 0.975 + (n - 0.5) * 0.01;
}
""")
preset("shader-kaleidoscope", "Composite Shader: Kaleidoscope",
  "Mirroring the screen coordinates in the composite folds whatever the preset draws into eight-way symmetry, without touching the feedback underneath.",
  {"fDecay": 0.95, "fWaveParam": -0.1, "bAdditiveWaves": 1, "fWaveScale": 1.3},
  cycle() + ["zoom = 1.015;", "rot = 0.03;", "wave_x = 0.5 + 0.25*sin(time*0.7);", "wave_y = 0.5 + 0.25*cos(time*0.5);"],
  comp="""
shader_body {
    float2 p = (uv - 0.5) * aspect.zw;
    p = abs(p);
    if (p.y > p.x) p = p.yx;
    ret = tex2D(sampler_main, p * aspect.xy + 0.5).xyz * 1.3;
}
""")
preset("shader-edges", "Composite Shader: Edges",
  "texsize gives a shader the size of a pixel, so it can compare neighbours. The difference between them outlines every edge in neon.",
  {"fDecay": 0.97, "fWaveParam": -0.25, "fWaveScale": 1.3},
  cycle() + ["zoom = 1.02;", "rot = 0.01;"],
  comp="""
shader_body {
    float2 d = texsize.zw * 1.5;
    float3 dx = tex2D(sampler_main, uv + float2(d.x, 0)).xyz - tex2D(sampler_main, uv - float2(d.x, 0)).xyz;
    float3 dy = tex2D(sampler_main, uv + float2(0, d.y)).xyz - tex2D(sampler_main, uv - float2(0, d.y)).xyz;
    float3 edge = sqrt(dx * dx + dy * dy) * 3.0;
    ret = edge * (0.6 + 0.4 * hue_shader) + tex2D(sampler_main, uv).xyz * 0.15;
}
""")

category("Audio")
preset("audio-bands", "Bass, Mid, Treble",
  "bass, mid and treb are the band levels, where 1 is average. Bass sets the wave's red, mid its green and treble its blue; bass_att drives the zoom.",
  {"fDecay": 0.94, "fWaveParam": -0.2, "bMaximizeWaveColor": 0},
  ["wave_r = min(bass*0.6, 1);", "wave_g = min(mid*0.6, 1);", "wave_b = min(treb*0.6, 1);",
   "zoom = 1 + 0.04*max(bass_att - 0.8, 0);"])
preset("audio-beat", "Beat Flash",
  "Per-frame code can react to beats: when the bass jumps above its running average, the border flashes and the image kicks outward.",
  {"ob_size": 0.02, "fDecay": 0.9, "fWaveParam": -0.25, "nWaveMode": 0},
  cycle() + ["beat = above(bass, bass_att*1.2 + 0.1);", "kick = max(kick*0.85, beat);",
           "ob_r = 1; ob_g = 0.8; ob_b = 0.4; ob_a = kick*0.9;", "zoom = 1 + 0.08*kick;", "rot = 0.02*sin(time*0.4);"])


readme = ["# Presets", "",
  "Presets here are written for this package and released under its MIT licence. Third-party presets are added",
  "only with a confirmed licence, recorded in `NOTICE`.", "",
  "Each one shows a single renderer feature. `gallery.json` lists them by category, in the order MilkDrop Gallery",
  "shows them, with the descriptions it displays. They are generated: edit `scripts/make-gallery-presets.py` and run",
  "`python3 -I scripts/make-gallery-presets.py Presets` (it writes this file too). `spike-tunnel.milk` is the",
  "exception, kept by hand.", "",
  "| Category | File | What it shows |", "|---|---|---|"]
for c in catalog:
    for p in c["presets"]:
        readme.append(f"| {c['name']} | `{p['file']}` | {p['summary']} |")
with open(os.path.join(out, "README.md"), "w") as f:
    f.write("\n".join(readme) + "\n")

with open(os.path.join(out, "gallery.json"), "w") as f:
    json.dump({"categories": catalog}, f, indent=2)
    f.write("\n")
print(sum(len(c["presets"]) for c in catalog), "presets")
