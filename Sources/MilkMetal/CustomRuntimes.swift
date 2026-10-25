import Foundation
import MilkEEL
import MilkPresetFormat

/// One custom wave: per-frame code sets its colour and sample count, then per-point code places each sample.
/// A port of Butterchurn's `CustomWaveform` and the wave half of `PresetEquationRunner`.
final class CustomWaveRuntime {
    static let variables: [BaseVariable] = [
        .init("enabled", 0), .init("samples", 512), .init("sep", 0), .init("scaling", 1), .init("smoothing", 0.5),
        .init("spectrum", ["bspectrum", "spectrum"], 0), .init("usedots", ["busedots", "usedots"], 0),
        .init("thick", ["bdrawthick", "thick"], 0), .init("additive", ["badditive", "additive"], 0),
        .init("r", 1), .init("g", 1), .init("b", 1), .init("a", 1),
    ]
    static let maxSamples = 512

    let index: Int
    let enabled: Bool
    let errors: [String]
    /// Draw style: from the file, not the equations.
    let usesDots: Bool
    let isThick: Bool
    let isAdditive: Bool

    private let perFrame: EELProgram?
    private let perPoint: EELProgram?
    private let memory: EELMemory?
    private let named: [String: Int]
    private let base: [(slot: Int, value: Double)]
    private let q: [Int], t: [Int]
    private let tAfterInit: [Double]
    private let inputs: InputSlots
    private let point: (sample: Int, value1: Int, value2: Int, x: Int, y: Int, r: Int, g: Int, b: Int, a: Int)
    private var left = [Double](repeating: 0, count: maxSamples)
    private var right = [Double](repeating: 0, count: maxSamples)

    init(index: Int, wave: CustomWave, shared: EELShared, seed: UInt64, q qValues: [Double], inputs frameInputs: FrameInputs) {
        self.index = index
        var table = EELVariableTable()
        var named: [String: Int] = [:]
        var base: [(Int, Double)] = []
        for variable in Self.variables {
            let slot = table.slot(for: variable.name)
            table.values[slot] = variable.value(in: wave.values)
            named[variable.name] = slot
            base.append((slot, table.values[slot]))
        }
        q = (1...PresetRuntime.qCount).map { table.slot(for: "q\($0)") }
        t = (1...8).map { table.slot(for: "t\($0)") }
        inputs = InputSlots(&table)
        point = (table.slot(for: "sample"), table.slot(for: "value1"), table.slot(for: "value2"),
                 table.slot(for: "x"), table.slot(for: "y"), named["r"]!, named["g"]!, named["b"]!, named["a"]!)
        self.named = named
        self.base = base
        enabled = wave.enabled
        usesDots = (wave.values["busedots"] ?? 0) != 0
        isThick = (wave.values["bdrawthick"] ?? 0) != 0
        isAdditive = (wave.values["badditive"] ?? 0) != 0

        var compiler = BlockCompiler(prefix: "wave_\(index)_")
        compiler.table = table
        let initProgram = enabled ? compiler.compile("init", wave.initCode) : nil
        perFrame = enabled ? compiler.compile("per_frame", wave.perFrame) : nil
        perPoint = enabled ? compiler.compile("per_point", wave.perPoint) : nil
        errors = compiler.errors

        guard enabled else {
            memory = nil
            tAfterInit = Array(repeating: 0, count: 8)
            return
        }
        let memory = EELMemory(table: compiler.table, seed: seed, shared: shared)
        for (i, slot) in q.enumerated() { memory[slot] = qValues[i] }
        inputs.write(frameInputs, to: memory)
        initProgram?.run(memory)
        tAfterInit = t.map { memory[$0] }
        // Init code may change the base values; they go back to the file's.
        for (slot, value) in base { memory[slot] = value }
        self.memory = memory
    }

    /// A drawn wave: positions in clip space (ours, y up) and colours, one per sample.
    struct Points {
        var positions: [SIMD2<Float>]
        var colors: [SIMD4<Float>]
    }

    /// Runs per_frame and per_point and returns the wave's points, or nil if it draws nothing this frame.
    /// `waveScale` is the preset's `fWaveScale` from the file.
    func run(_ frameInputs: FrameInputs, q qValues: [Double], audio: AudioAnalyzer, waveScale: Double,
             alpha: Double = 1) -> Points? {
        guard enabled, let memory else { return nil }
        for (slot, value) in base { memory[slot] = value }
        for (i, slot) in q.enumerated() { memory[slot] = qValues[i] }
        for (i, slot) in t.enumerated() { memory[slot] = tAfterInit[i] }
        inputs.write(frameInputs, to: memory)
        perFrame?.run(memory)

        func v(_ name: String) -> Double {
            let x = memory[named[name]!]
            return x.isFinite ? x : 0
        }
        var samples = min(Self.maxSamples, Int(v("samples").rounded(.down)))
        let sep = Int(v("sep").rounded(.down))
        let scaling = v("scaling"), smoothing = v("smoothing")
        let useSpectrum = v("spectrum") != 0
        let frameColor = (v("r"), v("g"), v("b"), v("a"))
        samples -= sep
        guard samples >= 2 || (usesDots && samples >= 1) else { return nil }

        let scale = (useSpectrum ? 0.15 : 0.004) * scaling * waveScale
        let pointsLeft = useSpectrum ? audio.spectrumLeft : audio.waveLeft
        let pointsRight = useSpectrum ? audio.spectrumRight : audio.waveRight
        let max = Self.maxSamples
        let j0 = useSpectrum ? 0 : (max - samples) / 2 - sep / 2
        let j1 = useSpectrum ? 0 : (max - samples) / 2 + sep / 2
        let step = useSpectrum ? Double(max - sep) / Double(samples) : 1
        let mix1 = (smoothing * 0.98).squareRoot()
        let mix2 = 1 - mix1
        func at(_ array: [Float], _ i: Int) -> Double { Double(array[Swift.min(Swift.max(i, 0), array.count - 1)]) }

        // MilkDrop smooths forward, then backward, then scales.
        left[0] = at(pointsLeft, j0)
        right[0] = at(pointsRight, j1)
        if samples > 1 {
            for j in 1..<samples {
                left[j] = at(pointsLeft, Int(Double(j) * step) + j0) * mix2 + left[j - 1] * mix1
                right[j] = at(pointsRight, Int(Double(j) * step) + j1) * mix2 + right[j - 1] * mix1
            }
            for j in stride(from: samples - 2, through: 0, by: -1) {
                left[j] = left[j] * mix2 + left[j + 1] * mix1
                right[j] = right[j] * mix2 + right[j + 1] * mix1
            }
        }

        var positions = [SIMD2<Float>]()
        var colors = [SIMD4<Float>]()
        positions.reserveCapacity(samples)
        colors.reserveCapacity(samples)
        let invAspectX = 1 / frameInputs.aspect.x, invAspectY = 1 / frameInputs.aspect.y
        for j in 0..<samples {
            let value1 = left[j] * scale, value2 = right[j] * scale
            memory[point.sample] = samples > 1 ? Double(j) / Double(samples - 1) : 0
            memory[point.value1] = value1
            memory[point.value2] = value2
            memory[point.x] = 0.5 + value1
            memory[point.y] = 0.5 + value2
            memory[point.r] = frameColor.0
            memory[point.g] = frameColor.1
            memory[point.b] = frameColor.2
            memory[point.a] = frameColor.3
            perPoint?.run(memory)
            let x = (memory[point.x] * 2 - 1) * invAspectX
            let y = (memory[point.y] * 2 - 1) * invAspectY
            positions.append(SIMD2(Float(x), Float(y)))
            colors.append(clampedColor(memory[point.r], memory[point.g], memory[point.b], memory[point.a] * alpha))
        }
        return Points(positions: positions, colors: colors)
    }
}

/// One custom shape: a filled polygon (optionally textured with the previous frame) with an outline, drawn
/// `num_inst` times per frame. A port of Butterchurn's `CustomShape` and the shape half of `PresetEquationRunner`.
final class CustomShapeRuntime {
    static let variables: [BaseVariable] = [
        .init("enabled", 0), .init("sides", 4), .init("additive", 0), .init("thickoutline", 0),
        .init("textured", 0), .init("num_inst", 1), .init("x", 0.5), .init("y", 0.5), .init("rad", 0.1),
        .init("ang", 0), .init("tex_ang", 0), .init("tex_zoom", 1),
        .init("r", 1), .init("g", 0), .init("b", 0), .init("a", 1),
        .init("r2", 0), .init("g2", 1), .init("b2", 0), .init("a2", 0),
        .init("border_r", 1), .init("border_g", 1), .init("border_b", 1), .init("border_a", 0.1),
    ]
    /// Variables reset to the file's values before every instance.
    private static let perInstance = [
        "x", "y", "rad", "ang", "r", "g", "b", "a", "r2", "g2", "b2", "a2",
        "border_r", "border_g", "border_b", "border_a", "thickoutline", "textured", "tex_zoom", "tex_ang", "additive",
    ]

    let index: Int
    let enabled: Bool
    let errors: [String]
    let instanceCount: Int

    private let perFrame: EELProgram?
    private let memory: EELMemory?
    private let named: [String: Int]
    private let base: [(slot: Int, value: Double)]
    private let instanceBase: [(slot: Int, value: Double)]
    private let q: [Int], t: [Int]
    private let tAfterInit: [Double]
    private let inputs: InputSlots
    private let instanceSlot: Int

    init(index: Int, shape: CustomShape, shared: EELShared, seed: UInt64, q qValues: [Double], inputs frameInputs: FrameInputs) {
        self.index = index
        var table = EELVariableTable()
        var named: [String: Int] = [:]
        var base: [(Int, Double)] = []
        for variable in Self.variables {
            let slot = table.slot(for: variable.name)
            table.values[slot] = variable.value(in: shape.values)
            named[variable.name] = slot
            base.append((slot, table.values[slot]))
        }
        q = (1...PresetRuntime.qCount).map { table.slot(for: "q\($0)") }
        t = (1...8).map { table.slot(for: "t\($0)") }
        inputs = InputSlots(&table)
        instanceSlot = table.slot(for: "instance")
        self.named = named
        self.base = base
        instanceBase = Self.perInstance.map { name in (named[name]!, table.values[named[name]!]) }
        enabled = shape.enabled
        instanceCount = min(max(Int(shape.values["num_inst"] ?? 1), 1), 1024)

        var compiler = BlockCompiler(prefix: "shape_\(index)_")
        compiler.table = table
        let initProgram = enabled ? compiler.compile("init", shape.initCode) : nil
        perFrame = enabled ? compiler.compile("per_frame", shape.perFrame) : nil
        errors = compiler.errors

        guard enabled else {
            memory = nil
            tAfterInit = Array(repeating: 0, count: 8)
            return
        }
        let memory = EELMemory(table: compiler.table, seed: seed, shared: shared)
        for (i, slot) in q.enumerated() { memory[slot] = qValues[i] }
        inputs.write(frameInputs, to: memory)
        initProgram?.run(memory)
        tAfterInit = t.map { memory[$0] }
        for (slot, value) in base { memory[slot] = value }
        self.memory = memory
    }

    /// One drawn instance, in clip space (ours, y up).
    struct Instance {
        var sides: Int
        var center: SIMD2<Float>
        var centerColor: SIMD4<Float>
        var ring: [SIMD2<Float>]
        var ringColor: SIMD4<Float>
        /// Texture coordinates into the previous frame, centre first, when textured.
        var uvs: [SIMD2<Float>]?
        var borderColor: SIMD4<Float>
        var thickBorder: Bool
        var additive: Bool
    }

    /// Runs per_frame once per instance and returns what to draw.
    func run(_ frameInputs: FrameInputs, q qValues: [Double], alpha: Double = 1) -> [Instance] {
        guard enabled, let memory else { return [] }
        for (slot, value) in base { memory[slot] = value }
        inputs.write(frameInputs, to: memory)
        if perFrame == nil {
            for (i, slot) in q.enumerated() { memory[slot] = qValues[i] }
            for (i, slot) in t.enumerated() { memory[slot] = tAfterInit[i] }
        }
        func v(_ name: String) -> Double {
            let x = memory[named[name]!]
            return x.isFinite ? x : 0
        }
        let aspecty = frameInputs.aspect.y
        var instances: [Instance] = []
        instances.reserveCapacity(instanceCount)
        for j in 0..<instanceCount {
            memory[instanceSlot] = Double(j)
            for (slot, value) in instanceBase { memory[slot] = value }
            if let perFrame {
                for (i, slot) in q.enumerated() { memory[slot] = qValues[i] }
                for (i, slot) in t.enumerated() { memory[slot] = tAfterInit[i] }
                perFrame.run(memory)
            }
            let sides = min(max(Int(v("sides").rounded(.down)), 3), 100)
            let rad = v("rad"), ang = v("ang")
            let cx = v("x") * 2 - 1, cy = v("y") * 2 - 1
            let textured = abs(v("textured")) >= 1
            let texZoom = v("tex_zoom"), texAng = v("tex_ang")
            var ring: [SIMD2<Float>] = []
            var uvs: [SIMD2<Float>]? = textured ? [SIMD2(0.5, 0.5)] : nil
            ring.reserveCapacity(sides + 1)
            for k in 0...sides {
                let p = Double(k) / Double(sides) * 2 * .pi
                let a = p + ang + .pi / 4
                // Butterchurn's y is upside down; negating it mirrors the angle, as its final flip does.
                ring.append(SIMD2(Float(cx + rad * cos(a) * aspecty), Float(cy - rad * sin(a))))
                if textured {
                    let ta = p + texAng + .pi / 4
                    let zoom = texZoom == 0 ? 1 : texZoom
                    uvs?.append(SIMD2(Float(0.5 + 0.5 * cos(ta) / zoom * aspecty), Float(0.5 + 0.5 * sin(ta) / zoom)))
                }
            }
            instances.append(Instance(
                sides: sides, center: SIMD2(Float(cx), Float(cy)),
                centerColor: clampedColor(v("r"), v("g"), v("b"), v("a") * alpha),
                ring: ring, ringColor: clampedColor(v("r2"), v("g2"), v("b2"), v("a2") * alpha),
                uvs: uvs,
                borderColor: clampedColor(v("border_r"), v("border_g"), v("border_b"), v("border_a") * alpha),
                thickBorder: abs(v("thickoutline")) >= 1, additive: abs(v("additive")) >= 1))
        }
        return instances
    }
}

/// Colours are clamped as an 8-bit render target would.
func clampedColor(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> SIMD4<Float> {
    SIMD4(Float(r), Float(g), Float(b), Float(a)).clamped(lowerBound: .zero, upperBound: .one)
}
