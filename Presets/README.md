# Presets

Presets here are written for this package and released under its MIT licence. Third-party presets are added
only with a confirmed licence, recorded in `NOTICE`.

Each one shows a single renderer feature. `gallery.json` lists them by category, in the order MilkDrop Gallery
shows them, with the descriptions it displays. They are generated: edit `scripts/make-gallery-presets.py` and run
`python3 -I scripts/make-gallery-presets.py Presets` (it writes this file too). `spike-tunnel.milk` is the
exception, kept by hand.

| Category | File | What it shows |
|---|---|---|
| Showcase | `spike-tunnel.milk` | Everything at once: per-frame colour and zoom, per-vertex zoom and rotation, a thick additive circle wave, video echo and an outer border. |
| Waveforms | `wave-circle.milk` | nWaveMode 0 bends the waveform into a ring. A slight zoom pushes each old frame outward, so the rings spread. |
| Waveforms | `wave-scope.milk` | nWaveMode 1: the right channel sets each point's distance from the centre and the left its angle, so the wave swirls around a ring. |
| Waveforms | `wave-xy.milk` | nWaveMode 2 plots the left channel against the right, like an oscilloscope in X-Y mode, faintly. Mono sound is a diagonal line; stereo opens it up. |
| Waveforms | `wave-xy-treble.milk` | nWaveMode 3 is the X-Y scope again, but treble sets its brightness: it flares on hi-hats and cymbals. |
| Waveforms | `wave-momentum.milk` | nWaveMode 4 draws a horizontal line whose points carry momentum from their neighbours, so it ripples like a rope. wave_mystery sets how much. |
| Waveforms | `wave-products.milk` | nWaveMode 5 multiplies the channels together into a slowly rotating knot. |
| Waveforms | `wave-line.milk` | nWaveMode 6 draws a line across the screen at an angle set by wave_mystery. dy moves every frame up the screen, so the history scrolls like a waterfall. |
| Waveforms | `wave-stereo.milk` | nWaveMode 7 draws the left channel above and the right below; wave_y sets the gap. sx above 1 stretches old frames sideways. |
| Waveforms | `wave-dots.milk` | bWaveDots draws the circle wave as dots. Zoom and rotation turn the old dots into a spiral. |
| Custom Waves | `custom-wave-spiral.milk` | A custom wave's per-point code places each of its samples. Here sample (0 to 1 along the wave) winds them into a spiral, and the audio in value1 makes it bristle. |
| Custom Waves | `custom-wave-spectrum.milk` | bSpectrum gives a custom wave the frequency spectrum instead of the waveform: low notes on the left, high on the right. Two waves draw the left and right channels as mirrored bars of light. |
| Custom Waves | `custom-wave-dots.milk` | bUseDots draws a custom wave's samples as points. Per-frame code sets t1, which every per-point run then reads. |
| Custom Shapes | `shapes-basic.milk` | Custom shapes are filled polygons with a centre colour, an edge colour and an outline. Here a hexagon breathes with the bass and a triangle spins with the treble. |
| Custom Shapes | `shapes-instances.milk` | num_inst draws a shape many times per frame; instance counts them so each copy can go somewhere else. Twenty-four copies of one shape make this ring. |
| Custom Shapes | `shapes-textured.milk` | A textured shape is filled with the previous frame. Turning its texture (tex_ang) and zooming into it (tex_zoom) folds the image back on itself. |
| Motion Vectors | `motion-vectors.milk` | Motion vectors draw a grid of short lines showing where the warp is pulling each part of the image from. mv_x and mv_y set the grid, mv_l the length. |
| Motion Vectors | `darken-center.milk` | bDarkenCenter draws a faint dark spot in the middle every frame, so a zooming preset doesn't white out at its centre. |
| Motion | `motion-zoom.milk` | zoom above 1 magnifies the previous frame every frame, so everything flows outward. Here the bass drives it. |
| Motion | `motion-zoom-exponent.milk` | fZoomExponent bends the zoom by distance from the centre. Below 1 the middle races outward; above 1 the edges do. It sweeps slowly here. |
| Motion | `motion-rotate.milk` | rot turns the previous frame about (cx, cy) every frame. The centre wanders, so the spin swirls. |
| Motion | `motion-warp.milk` | warp distorts the frame with MilkDrop's animated sine field. fWarpScale sets the size of its swirls and fWarpAnimSpeed their speed. |
| Motion | `motion-stretch.milk` | sx and sy scale the previous frame horizontally and vertically. Here they take turns. |
| Motion | `motion-drift.milk` | dx and dy slide the frame a little every frame. With bTexWrap on, whatever leaves one edge comes back on the other. |
| Per-Vertex Equations | `pixel-ripples.milk` | per_pixel code runs for every point of the warp mesh. Zoom depends on rad, the distance from the centre, so rings travel outward. |
| Per-Vertex Equations | `pixel-swirl.milk` | Rotation that falls off with distance from the centre (rot depends on rad) twists the frame into a whirlpool. |
| Per-Vertex Equations | `pixel-petals.milk` | ang is each point's angle around the centre. Zoom that varies with ang pushes the image out in six petals. |
| Composite | `echo.milk` | fVideoEchoAlpha blends a zoomed copy over the image and nVideoEchoOrientation mirrors it. The mirroring changes every 5 seconds. |
| Composite | `filter-solarize.milk` | bSolarize folds bright colours back down, so the brightest parts turn dark. |
| Composite | `filter-invert.milk` | bInvert flips every colour: black becomes white. |
| Composite | `filter-brighten.milk` | bBrighten takes the square root of each colour, lifting the dim trails. |
| Composite | `filter-darken.milk` | bDarken squares each colour: dim trails sink away and only the brightest lines stay. |
| Composite | `gamma.milk` | fGammaAdj multiplies the brightness of the final image. The bass drives it here. |
| Composite | `borders.milk` | ob_ and ib_ draw an outer and an inner border every frame. Zooming out pulls the old ones inward into a tunnel of frames. |
| MilkDrop 2 Shaders | `shader-liquid.milk` | A MilkDrop 2 warp shader replaces the fixed warp. Here each pixel samples the previous frame at an offset read from a smooth noise texture that drifts, so the image flows like liquid. |
| MilkDrop 2 Shaders | `shader-palette.milk` | A composite shader decides how the feedback image reaches the screen without changing what feeds back. This one maps brightness onto a cycling cosine palette. |
| MilkDrop 2 Shaders | `shader-glow.milk` | MilkDrop 2 keeps three blurred copies of each frame for shaders to read. Adding GetBlur1 and GetBlur2 back onto the image gives it a soft glow. |
| MilkDrop 2 Shaders | `shader-noise.milk` | Shaders get MilkDrop's noise textures: 2D in three smoothnesses, and 3D volumes. Here a slice through the 3D noise, moving through time, tints and pushes the image. |
| MilkDrop 2 Shaders | `shader-kaleidoscope.milk` | Mirroring the screen coordinates in the composite folds whatever the preset draws into eight-way symmetry, without touching the feedback underneath. |
| MilkDrop 2 Shaders | `shader-edges.milk` | texsize gives a shader the size of a pixel, so it can compare neighbours. The difference between them outlines every edge in neon. |
| Audio | `audio-bands.milk` | bass, mid and treb are the band levels, where 1 is average. Bass sets the wave's red, mid its green and treble its blue; bass_att drives the zoom. |
| Audio | `audio-beat.milk` | Per-frame code can react to beats: when the bass jumps above its running average, the border flashes and the image kicks outward. |
