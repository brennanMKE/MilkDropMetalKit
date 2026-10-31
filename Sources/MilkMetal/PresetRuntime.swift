import Foundation
internal import MilkEEL
internal import MilkPresetFormat

/// A variable a preset's equations see with a value from the `.milk` file: its name in equations, the file keys
/// that set it (first match wins), and MilkDrop's default for files that don't.
struct BaseVariable {
    var name: String
    var keys: [String]
    var value: Double

    init(_ name: String, _ keys: [String], _ value: Double) {
        self.name = name
        self.keys = keys
        self.value = value
    }

    /// A variable set by the file key of the same name.
    init(_ name: String, _ value: Double) {
        self.init(name, [name], value)
    }

    /// The value for this variable from `values` (lowercased file keys), or the default.
    func value(in values: [String: Double]) -> Double {
        keys.lazy.compactMap { values[$0] }.first ?? value
    }
}

/// MilkDrop's aspect multipliers (Butterchurn's `aspectx`/`aspecty`): 1 for the shorter side, below 1 for the
/// longer, so shapes drawn with them stay round.
struct Aspect: Equatable {
    var x: Double
    var y: Double

    init(width: Int, height: Int) {
        let w = Double(max(width, 1)), h = Double(max(height, 1))
        x = h > w ? w / h : 1
        y = w > h ? h / w : 1
    }
}

/// The per-frame globals every equation context reads.
struct FrameInputs {
    var time = 0.0
    var fps = 60.0
    var frame = 0
    var levels = AudioLevels()
    var mesh = (width: 48, height: 36)
    var pixels = (width: 1, height: 1)
    var aspect = Aspect(width: 1, height: 1)
}

/// Slots of the globals in one variable table.
struct InputSlots {
    let time, fps, frame, progress, bass, mid, treb, bassAtt, midAtt, trebAtt: Int
    let meshx, meshy, pixelsx, pixelsy, aspectx, aspecty: Int

    init(_ table: inout EELVariableTable) {
        func s(_ name: String) -> Int { table.slot(for: name) }
        time = s("time"); fps = s("fps"); frame = s("frame"); progress = s("progress")
        bass = s("bass"); mid = s("mid"); treb = s("treb")
        bassAtt = s("bass_att"); midAtt = s("mid_att"); trebAtt = s("treb_att")
        meshx = s("meshx"); meshy = s("meshy"); pixelsx = s("pixelsx"); pixelsy = s("pixelsy")
        aspectx = s("aspectx"); aspecty = s("aspecty")
    }

    func write(_ i: FrameInputs, to m: EELMemory) {
        m[time] = i.time
        m[fps] = i.fps
        m[frame] = Double(i.frame)
        m[progress] = 0
        m[bass] = i.levels.bass
        m[mid] = i.levels.mid
        m[treb] = i.levels.treb
        m[bassAtt] = i.levels.bassAtt
        m[midAtt] = i.levels.midAtt
        m[trebAtt] = i.levels.trebAtt
        m[meshx] = Double(i.mesh.width)
        m[meshy] = Double(i.mesh.height)
        m[pixelsx] = Double(i.pixels.width)
        m[pixelsy] = Double(i.pixels.height)
        // Equations see the inverse factors, as in Butterchurn.
        m[aspectx] = 1 / i.aspect.x
        m[aspecty] = 1 / i.aspect.y
    }
}

/// Compiles equation blocks against one table, collecting errors; failing blocks are skipped.
struct BlockCompiler {
    var table = EELVariableTable()
    var errors: [String] = []
    let prefix: String

    init(prefix: String = "") {
        self.prefix = prefix
    }

    mutating func compile(_ label: String, _ source: String) -> EELProgram? {
        do {
            let program = try EELProgram(source: source, table: &table)
            return program.isEmpty ? nil : program
        } catch {
            errors.append("\(prefix)\(label): \(error)")
            return nil
        }
    }
}

/// Everything the renderer needs from one run of the per-frame equations.
struct FrameState {
    var time = 0.0
    var levels = AudioLevels()
    var decay = 0.98
    var wrap = true
    var gamma = 2.0
    var echoZoom = 2.0, echoAlpha = 0.0
    var echoOrient = 0
    var brighten = false, darken = false, solarize = false, invert = false
    var fShader = 0.0
    var darkenCenter = false
    var waveMode = 0
    var waveColor: SIMD4<Double> = [1, 1, 1, 0.8]
    var waveX = 0.5, waveY = 0.5, waveMystery = 0.0, waveScale = 1.0, waveSmoothing = 0.75
    var waveDots = false, waveThick = false, waveAdditive = false, waveBrighten = true
    var modWaveAlphaByVolume = false
    var modWaveAlphaStart = 0.75, modWaveAlphaEnd = 0.95
    var outerBorder: (size: Double, color: SIMD4<Double>) = (0.01, [0, 0, 0, 0])
    var innerBorder: (size: Double, color: SIMD4<Double>) = (0.01, [0.25, 0.25, 0.25, 0])
    var motionVectors = MotionVectorSettings()
    var blurMin: SIMD3<Double> = [0, 0, 0]
    var blurMax: SIMD3<Double> = [1, 1, 1]
    var blur1EdgeDarken = 0.25
}

struct MotionVectorSettings {
    var x = 12.0, y = 9.0, dx = 0.0, dy = 0.0, length = 0.9
    var color: SIMD4<Double> = [1, 1, 1, 0]
}

/// A preset's equations compiled into EEL contexts, plus the state that persists between frames.
///
/// Follows Butterchurn's `PresetEquationRunner`: per_frame_init runs once; every frame the base variables are
/// reset to the preset's values, q1–q32 to what per_frame_init left, the globals are set, and per_frame runs.
/// Variables the preset makes up keep their values between frames. Per-vertex code then runs over the mesh on a
/// copy of that state. Custom waves and shapes get their own contexts, fed q1–q32 from per_frame.
final class PresetRuntime {
    static let frameVariables: [BaseVariable] = [
        .init("zoom", 1), .init("zoomexp", ["fzoomexponent", "zoomexp"], 1), .init("rot", 0), .init("warp", 1),
        .init("cx", 0.5), .init("cy", 0.5), .init("dx", 0), .init("dy", 0), .init("sx", 1), .init("sy", 1),
        .init("decay", ["fdecay", "decay"], 0.98),
        .init("gamma", ["fgammaadj", "gamma"], 2),
        .init("echo_zoom", ["fvideoechozoom", "echo_zoom"], 2),
        .init("echo_alpha", ["fvideoechoalpha", "echo_alpha"], 0),
        .init("echo_orient", ["nvideoechoorientation", "echo_orient"], 0),
        .init("wave_mode", ["nwavemode", "wave_mode"], 0),
        .init("wave_additive", ["badditivewaves", "wave_additive"], 0),
        .init("wave_usedots", ["bwavedots", "wave_usedots"], 0),
        .init("wave_thick", ["bwavethick", "wave_thick"], 0),
        .init("wave_brighten", ["bmaximizewavecolor", "wave_brighten"], 1),
        .init("modwavealphabyvolume", ["bmodwavealphabyvolume"], 0),
        .init("modwavealphastart", ["fmodwavealphastart"], 0.75),
        .init("modwavealphaend", ["fmodwavealphaend"], 0.95),
        .init("wrap", ["btexwrap", "wrap"], 1),
        .init("darken_center", ["bdarkencenter", "darken_center"], 0),
        .init("red_blue", ["bredbluestereo"], 0),
        .init("brighten", ["bbrighten", "brighten"], 0), .init("darken", ["bdarken", "darken"], 0),
        .init("solarize", ["bsolarize", "solarize"], 0), .init("invert", ["binvert", "invert"], 0),
        .init("wave_a", ["fwavealpha", "wave_a"], 0.8),
        .init("wave_scale", ["fwavescale", "wave_scale"], 1),
        .init("wave_smoothing", ["fwavesmoothing", "wave_smoothing"], 0.75),
        .init("wave_mystery", ["fwaveparam", "wave_mystery"], 0),
        .init("warpanimspeed", ["fwarpanimspeed", "warpanimspeed"], 1),
        .init("warpscale", ["fwarpscale", "warpscale"], 1),
        .init("fshader", ["fshader"], 0),
        .init("wave_r", 1), .init("wave_g", 1), .init("wave_b", 1), .init("wave_x", 0.5), .init("wave_y", 0.5),
        .init("ob_size", 0.01), .init("ob_r", 0), .init("ob_g", 0), .init("ob_b", 0), .init("ob_a", 0),
        .init("ib_size", 0.01), .init("ib_r", 0.25), .init("ib_g", 0.25), .init("ib_b", 0.25), .init("ib_a", 0),
        .init("mv_x", ["nmotionvectorsx", "mv_x"], 12), .init("mv_y", ["nmotionvectorsy", "mv_y"], 9),
        .init("mv_dx", 0), .init("mv_dy", 0), .init("mv_l", 0.9),
        .init("mv_r", 1), .init("mv_g", 1), .init("mv_b", 1),
        // MilkDrop saves mv_a in every preset; a hand-written file without it gets no motion vectors.
        .init("mv_a", 0),
        .init("blur1_min", ["b1n", "blur1_min"], 0), .init("blur1_max", ["b1x", "blur1_max"], 1),
        .init("blur2_min", ["b2n", "blur2_min"], 0), .init("blur2_max", ["b2x", "blur2_max"], 1),
        .init("blur3_min", ["b3n", "blur3_min"], 0), .init("blur3_max", ["b3x", "blur3_max"], 1),
        .init("blur1_edge_darken", ["b1ed", "blur1_edge_darken"], 0.25),
        .init("monitor", 0),
    ]

    static let qCount = 32

    let errors: [String]
    /// `fWaveScale` from the file; custom waves scale by it whatever per_frame does.
    let waveScale: Double
    let waves: [CustomWaveRuntime]
    let shapes: [CustomShapeRuntime]
    let shared = EELShared()

    private let perFrame: EELProgram?
    private let perPixel: EELProgram?
    private let memory: EELMemory
    private let vertexMemory: EELMemory
    private let inputs: InputSlots
    /// Preset values of the base variables, restored at the start of every frame.
    private let base: [(slot: Int, value: Double)]
    private let named: [String: Int]
    private let q: [Int]
    private let qAfterInit: [Double]
    /// q1–q32 after the latest per_frame: what waves, shapes and shaders read.
    private(set) var qAfterFrame: [Double]
    private let vertex: (x: Int, y: Int, rad: Int, ang: Int)
    private let motion: [Int]

    init(model: PresetModel, seed: UInt64 = 1) {
        var compiler = BlockCompiler()
        var named: [String: Int] = [:]
        for variable in Self.frameVariables {
            let slot = compiler.table.slot(for: variable.name)
            compiler.table.values[slot] = variable.value(in: model.values)
            named[variable.name] = slot
        }
        q = (1...Self.qCount).map { compiler.table.slot(for: "q\($0)") }
        inputs = InputSlots(&compiler.table)
        vertex = (compiler.table.slot(for: "x"), compiler.table.slot(for: "y"), compiler.table.slot(for: "rad"),
                  compiler.table.slot(for: "ang"))
        let initProgram = compiler.compile("per_frame_init", model.perFrameInit)
        perFrame = compiler.compile("per_frame", model.perFrame)
        perPixel = compiler.compile("per_pixel", model.perPixel)

        self.named = named
        waveScale = compiler.table.values[named["wave_scale"]!]
        base = Self.frameVariables.map { (named[$0.name]!, compiler.table.values[named[$0.name]!]) }
        motion = ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"].map { named[$0]! }

        let memory = EELMemory(table: compiler.table, seed: seed, shared: shared)
        self.memory = memory
        vertexMemory = EELMemory(table: compiler.table, seed: seed &+ 1, shared: shared)
        initProgram?.run(memory)
        qAfterInit = q.map { memory[$0] }

        // Butterchurn runs per_frame once at load; the q values it leaves seed the waves' and shapes' init code.
        let loadInputs = FrameInputs()
        inputs.write(loadInputs, to: memory)
        perFrame?.run(memory)
        let qLoaded = q.map { memory[$0] }
        qAfterFrame = qLoaded

        var errors = compiler.errors
        let shared = shared
        waves = model.waves.enumerated().map { i, wave in
            CustomWaveRuntime(index: i, wave: wave, shared: shared, seed: seed &+ 10 &+ UInt64(i), q: qLoaded,
                              inputs: loadInputs)
        }
        shapes = model.shapes.enumerated().map { i, shape in
            CustomShapeRuntime(index: i, shape: shape, shared: shared, seed: seed &+ 20 &+ UInt64(i), q: qLoaded,
                               inputs: loadInputs)
        }
        errors += waves.flatMap(\.errors) + shapes.flatMap(\.errors)
        self.errors = errors
    }

    private func value(_ name: String) -> Double {
        let x = memory[named[name]!]
        return x.isFinite ? x : Self.frameVariables.first { $0.name == name }!.value
    }

    /// Runs per_frame and returns the frame's settings.
    func runFrame(_ frameInputs: FrameInputs) -> FrameState {
        for (slot, value) in base { memory[slot] = value }
        for (i, slot) in q.enumerated() { memory[slot] = qAfterInit[i] }
        inputs.write(frameInputs, to: memory)
        perFrame?.run(memory)
        qAfterFrame = q.map { memory[$0] }

        func flag(_ name: String) -> Bool { value(name) != 0 }
        func color(_ prefix: String, alpha: String) -> SIMD4<Double> {
            [value(prefix + "r"), value(prefix + "g"), value(prefix + "b"), value(alpha)]
        }
        var s = FrameState()
        s.time = frameInputs.time
        s.levels = frameInputs.levels
        s.decay = min(max(value("decay"), 0), 1)
        s.wrap = flag("wrap")
        s.gamma = value("gamma")
        s.echoZoom = value("echo_zoom")
        s.echoAlpha = min(max(value("echo_alpha"), 0), 1)
        s.echoOrient = Int(value("echo_orient")) & 3
        s.brighten = flag("brighten")
        s.darken = flag("darken")
        s.solarize = flag("solarize")
        s.invert = flag("invert")
        s.fShader = value("fshader")
        s.darkenCenter = flag("darken_center")
        s.waveMode = ((Int(value("wave_mode")) % 8) + 8) % 8
        s.waveColor = color("wave_", alpha: "wave_a")
        s.waveX = value("wave_x")
        s.waveY = value("wave_y")
        s.waveMystery = value("wave_mystery")
        s.waveScale = value("wave_scale")
        s.waveSmoothing = value("wave_smoothing")
        s.waveDots = flag("wave_usedots")
        s.waveThick = flag("wave_thick")
        s.waveAdditive = flag("wave_additive")
        s.waveBrighten = flag("wave_brighten")
        s.modWaveAlphaByVolume = flag("modwavealphabyvolume")
        s.modWaveAlphaStart = value("modwavealphastart")
        s.modWaveAlphaEnd = value("modwavealphaend")
        s.outerBorder = (value("ob_size"), color("ob_", alpha: "ob_a"))
        s.innerBorder = (value("ib_size"), color("ib_", alpha: "ib_a"))
        s.motionVectors = MotionVectorSettings(x: value("mv_x"), y: value("mv_y"), dx: value("mv_dx"),
                                               dy: value("mv_dy"), length: value("mv_l"),
                                               color: color("mv_", alpha: "mv_a"))
        s.blurMin = [value("blur1_min"), value("blur2_min"), value("blur3_min")]
        s.blurMax = [value("blur1_max"), value("blur2_max"), value("blur3_max")]
        s.blur1EdgeDarken = value("blur1_edge_darken")
        return s
    }

    /// Fills `out` with the warp mesh, row by row from the bottom of the screen: each vertex's clip-space position
    /// and the texture coordinate it samples the previous frame at (Metal convention: v = 0 at the top).
    ///
    /// A port of Butterchurn's `runPixelEquations`. Its clip space is upside down relative to ours (it flips the
    /// image in the composite), so its clip y is negated here; texture coordinates are the same in both.
    func computeMesh(_ frameInputs: FrameInputs, into out: UnsafeMutablePointer<MeshVertex>) {
        let (gw, gh) = frameInputs.mesh
        let aspectx = frameInputs.aspect.x, aspecty = frameInputs.aspect.y
        let warpTime = frameInputs.time * value("warpanimspeed")
        let warpScale = value("warpscale")
        let warpScaleInv = warpScale == 0 ? 1 : 1 / warpScale
        let f0 = 11.68 + 4.0 * cos(warpTime * 1.413 + 10)
        let f1 = 8.77 + 3.0 * cos(warpTime * 1.113 + 7)
        let f2 = 10.54 + 3.0 * cos(warpTime * 1.233 + 3)
        let f3 = 11.49 + 4.0 * cos(warpTime * 0.933 + 5)

        func m(_ memory: EELMemory, _ i: Int, _ fallback: Double) -> Double {
            let x = memory[motion[i]]
            return x.isFinite ? x : fallback
        }
        if perPixel != nil { vertexMemory.copyValues(from: memory) }
        let frameMotion = motion.map { memory[$0] }

        var k = 0
        for iz in 0...gh {
            for ix in 0...gw {
                let x = Double(ix) / Double(gw) * 2 - 1
                let y = Double(iz) / Double(gh) * 2 - 1
                let rad = (x * x * aspectx * aspectx + y * y * aspecty * aspecty).squareRoot()
                let source: EELMemory
                if let perPixel {
                    let ang = (2 * iz == gh && 2 * ix == gw) ? 0 : atan2(y * aspecty, x * aspectx)
                    vertexMemory[vertex.x] = x * 0.5 * aspectx + 0.5
                    vertexMemory[vertex.y] = y * -0.5 * aspecty + 0.5
                    vertexMemory[vertex.rad] = rad
                    vertexMemory[vertex.ang] = ang
                    for (i, slot) in motion.enumerated() { vertexMemory[slot] = frameMotion[i] }
                    perPixel.run(vertexMemory)
                    source = vertexMemory
                } else {
                    source = memory
                }
                let zoom = m(source, 0, 1), zoomExp = m(source, 1, 1), rot = m(source, 2, 0)
                let warp = m(source, 3, 0), cx = m(source, 4, 0.5), cy = m(source, 5, 0.5)
                let dx = m(source, 6, 0), dy = m(source, 7, 0), sx = m(source, 8, 1), sy = m(source, 9, 1)

                let zoom2 = pow(zoom, pow(zoomExp, rad * 2 - 1))
                let zoom2Inv = zoom2 == 0 || !zoom2.isFinite ? 1 : 1 / zoom2
                var u = x * 0.5 * aspectx * zoom2Inv + 0.5
                var v = -y * 0.5 * aspecty * zoom2Inv + 0.5
                u = sx == 0 ? u : (u - cx) / sx + cx
                v = sy == 0 ? v : (v - cy) / sy + cy
                if warp != 0 {
                    u += warp * 0.0035 * sin(warpTime * 0.333 + warpScaleInv * (x * f0 - y * f3))
                    v += warp * 0.0035 * cos(warpTime * 0.375 - warpScaleInv * (x * f2 + y * f1))
                    u += warp * 0.0035 * cos(warpTime * 0.753 - warpScaleInv * (x * f1 - y * f2))
                    v += warp * 0.0035 * sin(warpTime * 0.825 + warpScaleInv * (x * f0 + y * f3))
                }
                let u2 = u - cx, v2 = v - cy
                let c = cos(rot), s = sin(rot)
                u = u2 * c - v2 * s + cx
                v = u2 * s + v2 * c + cy
                u -= dx
                v -= dy
                u = (u - 0.5) / aspectx + 0.5
                v = (v - 0.5) / aspecty + 0.5

                out[k] = MeshVertex(x: Float(x), y: Float(y),
                                    u: Float(u.isFinite ? u : x * 0.5 + 0.5),
                                    v: Float(v.isFinite ? v : 0.5 - y * 0.5))
                k += 1
            }
        }
    }
}

/// One warp-mesh vertex as the shader reads it: clip-space position and source texture coordinate.
struct MeshVertex {
    var x, y, u, v: Float
}
