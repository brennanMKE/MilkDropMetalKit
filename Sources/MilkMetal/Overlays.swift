import Foundation

/// One overlay vertex: clip-space position, colour, and a texture coordinate for textured shapes.
/// Matches `OverlayVertex` in the shaders (packed, 32 bytes).
struct OverlayVertex {
    var x, y: Float
    var r, g, b, a: Float
    var u, v: Float

    init(_ p: SIMD2<Float>, _ c: SIMD4<Float>, uv: SIMD2<Float> = .zero) {
        x = p.x; y = p.y
        r = c.x; g = c.y; b = c.z; a = c.w
        u = uv.x; v = uv.y
    }
}

enum OverlayPrimitive {
    case triangles, lines, lineStrip, points
}

/// A run of vertices drawn with one primitive type and blend mode.
struct OverlayBatch {
    var primitive: OverlayPrimitive
    var start: Int
    var count: Int
    var additive = false
    /// Samples the previous frame (textured custom shapes).
    var textured = false
    /// Drawn four times, offset by a pixel right, down and diagonally, as MilkDrop draws thick lines.
    var thick = false
    var pointSize: Float = 1
}

/// Builds everything drawn into the feedback texture after the warp: motion vectors, custom shapes, custom waves,
/// the built-in waveform, the darkened centre and the borders, in MilkDrop's order. Ports of Butterchurn's
/// `MotionVectors`, `CustomShape`, `CustomWaveform`, `BasicWaveform`, `DarkenCenter` and `Border`.
///
/// Butterchurn's clip space is upside down relative to ours (it flips the image in the composite), so its clip
/// y is negated throughout; texture coordinates are the same in both.
struct OverlayBuilder {
    private(set) var width = 1
    private(set) var height = 1
    private(set) var aspect = Aspect(width: 1, height: 1)
    private(set) var vertices: [OverlayVertex] = []
    private(set) var batches: [OverlayBatch] = []

    init() {
        vertices.reserveCapacity(16_384)
    }

    mutating func reset(width: Int, height: Int, aspect: Aspect) {
        self.width = width
        self.height = height
        self.aspect = aspect
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
    }

    private mutating func add(_ primitive: OverlayPrimitive, _ new: [OverlayVertex], additive: Bool = false,
                              textured: Bool = false, thick: Bool = false, pointSize: Float = 1) {
        guard !new.isEmpty else { return }
        batches.append(OverlayBatch(primitive: primitive, start: vertices.count, count: new.count, additive: additive,
                                    textured: textured, thick: thick, pointSize: pointSize))
        vertices += new
    }

    // MARK: Motion vectors

    /// A grid of short lines pointing from each point toward where the warp pulls its pixels from.
    mutating func addMotionVectors(_ s: FrameState, mesh: UnsafePointer<MeshVertex>, meshSize: (width: Int, height: Int)) {
        let mv = s.motionVectors
        var nX = Int(mv.x.rounded(.down)), nY = Int(mv.y.rounded(.down))
        guard mv.color.w > 0.001, nX > 0, nY > 0 else { return }
        var dx = mv.x - Double(nX), dy = mv.y - Double(nY)
        if nX > 64 { nX = 64; dx = 0 }
        if nY > 48 { nY = 48; dy = 0 }
        let (gw, gh) = meshSize
        let minLength = 1 / Double(width)

        /// The source texture coordinate at (fx, fy), both 0…1 from the bottom left, bilinear in the mesh.
        func source(_ fx: Double, _ fy: Double) -> (Double, Double) {
            let gx = fx * Double(gw), gy = fy * Double(gh)
            let x0 = min(max(Int(gx), 0), gw - 1), y0 = min(max(Int(gy), 0), gh - 1)
            let tx = gx - Double(x0), ty = gy - Double(y0)
            func uv(_ i: Int, _ j: Int) -> (Double, Double) {
                let m = mesh[j * (gw + 1) + i]
                return (Double(m.u), Double(m.v))
            }
            let a = uv(x0, y0), b = uv(x0 + 1, y0), c = uv(x0, y0 + 1), d = uv(x0 + 1, y0 + 1)
            let u = a.0 * (1 - tx) * (1 - ty) + b.0 * tx * (1 - ty) + c.0 * (1 - tx) * ty + d.0 * tx * ty
            let v = a.1 * (1 - tx) * (1 - ty) + b.1 * tx * (1 - ty) + c.1 * (1 - tx) * ty + d.1 * tx * ty
            return (u, 1 - v)
        }

        let color = SIMD4<Float>(Float(mv.color.x), Float(mv.color.y), Float(mv.color.z), Float(mv.color.w))
            .clamped(lowerBound: .zero, upperBound: .one)
        var lines: [OverlayVertex] = []
        lines.reserveCapacity(nX * nY * 2)
        for j in 0..<nY {
            let fy = (Double(j) + 0.25) / (Double(nY) + dy + 0.25 - 1) - mv.dy
            guard fy > 0.0001, fy < 0.9999 else { continue }
            for i in 0..<nX {
                let fx = (Double(i) + 0.25) / (Double(nX) + dx + 0.25 - 1) + mv.dx
                guard fx > 0.0001, fx < 0.9999 else { continue }
                let (sx, sy) = source(fx, fy)
                var vx = (sx - fx) * mv.length, vy = (sy - fy) * mv.length
                let length = (vx * vx + vy * vy).squareRoot()
                if length < minLength {
                    if length > 0.00000001 {
                        vx *= minLength / length
                        vy *= minLength / length
                    } else {
                        vx = minLength
                        vy = minLength
                    }
                }
                lines.append(OverlayVertex(SIMD2(Float(2 * fx - 1), Float(2 * fy - 1)), color))
                lines.append(OverlayVertex(SIMD2(Float(2 * (fx + vx) - 1), Float(2 * (fy + vy) - 1)), color))
            }
        }
        add(.lines, lines)
    }

    // MARK: Custom shapes and waves

    mutating func addShape(_ shape: CustomShapeRuntime.Instance) {
        // The fan as triangles: centre, ring[k], ring[k + 1].
        var fill: [OverlayVertex] = []
        fill.reserveCapacity(shape.sides * 3)
        for k in 0..<shape.sides {
            fill.append(OverlayVertex(shape.center, shape.centerColor, uv: shape.uvs?[0] ?? .zero))
            fill.append(OverlayVertex(shape.ring[k], shape.ringColor, uv: shape.uvs?[k + 1] ?? .zero))
            fill.append(OverlayVertex(shape.ring[k + 1], shape.ringColor, uv: shape.uvs?[k + 2] ?? .zero))
        }
        add(.triangles, fill, additive: shape.additive, textured: shape.uvs != nil)
        if shape.borderColor.w > 0 {
            add(.lineStrip, shape.ring.map { OverlayVertex($0, shape.borderColor) }, thick: shape.thickBorder)
        }
    }

    mutating func addCustomWave(_ points: CustomWaveRuntime.Points, dots: Bool, thick: Bool, additive: Bool) {
        if dots {
            let size: Float = (thick ? 2 : 1) + (width >= 1024 ? 1 : 0)
            add(.points, zip(points.positions, points.colors).map { OverlayVertex($0, $1) }, additive: additive,
                pointSize: size)
        } else {
            let (positions, colors) = Self.smooth(points.positions, colors: points.colors)
            add(.lineStrip, zip(positions, colors).map { OverlayVertex($0, $1) }, additive: additive, thick: thick)
        }
    }

    /// MilkDrop's wave smoothing: a point between every pair, from a four-tap filter. n points become 2n − 1.
    static func smooth(_ p: [SIMD2<Float>], colors: [SIMD4<Float>]? = nil) -> ([SIMD2<Float>], [SIMD4<Float>]) {
        let n = p.count
        guard n > 1 else { return (p, colors ?? []) }
        let c1: Float = -0.15, c2: Float = 1.15, c3: Float = 1.15, c4: Float = -0.15
        let invSum = 1 / (c1 + c2 + c3 + c4)
        var out: [SIMD2<Float>] = []
        var outColors: [SIMD4<Float>] = []
        out.reserveCapacity(n * 2 - 1)
        var below = 0
        for i in 0..<(n - 1) {
            let above = i + 1, above2 = min(n - 1, i + 2)
            out.append(p[i])
            out.append((c1 * p[below] + c2 * p[i] + c3 * p[above] + c4 * p[above2]) * invSum)
            if let colors { outColors += [colors[i], colors[i]] }
            below = i
        }
        out.append(p[n - 1])
        if let colors { outColors.append(colors[n - 1]) }
        return (out, outColors)
    }

    // MARK: Built-in waveform

    /// The waveform of `wave_mode` 0–7 from the 512-point byte-scale channels. During a transition from a preset
    /// with another mode (`oldMode`), the line morphs from that mode's shape into this one's as `progress` goes
    /// from 0 to 1.
    mutating func addBasicWave(_ s: FrameState, left timeLeft: [Float], right timeRight: [Float],
                               oldMode: Int? = nil, progress: Double = 1) {
        let vol = (s.levels.bass + s.levels.mid + s.levels.treb) / 3
        guard vol > -0.01, s.waveColor.w > 0.001, !timeLeft.isEmpty else { return }

        func process(_ samples: [Float]) -> [Double] {
            let scale = s.waveScale / 128, smooth = s.waveSmoothing, smooth2 = scale * (1 - smooth)
            var out = [Double](repeating: 0, count: samples.count)
            out[0] = Double(samples[0]) * scale
            for i in 1..<samples.count { out[i] = Double(samples[i]) * smooth2 + out[i - 1] * smooth }
            return out
        }
        let waveL = process(timeLeft), waveR = process(timeRight)
        var wave = basicWave(s, mode: s.waveMode, waveL: waveL, waveR: waveR, vol: vol)
        if let oldMode, oldMode != s.waveMode {
            let old = basicWave(s, mode: oldMode, waveL: waveL, waveR: waveR, vol: vol)
            wave = Self.morph(from: old, oldMode: oldMode, to: wave, mode: s.waveMode, progress: progress)
        }

        var r = min(max(s.waveColor.x, 0), 1), g = min(max(s.waveColor.y, 0), 1), b = min(max(s.waveColor.z, 0), 1)
        if s.waveBrighten {
            let peak = max(r, g, b)
            if peak > 0.01 { r /= peak; g /= peak; b /= peak }
        }
        let color = SIMD4<Float>(Float(r), Float(g), Float(b), Float(wave.alpha))
        for line in [wave.points, wave.points2] where line.count > 1 {
            let (smoothed, _) = Self.smooth(line.map { SIMD2(Float($0.x), Float($0.y)) })
            let primitive: OverlayPrimitive = s.waveDots ? .points : .lineStrip
            add(primitive, smoothed.map { OverlayVertex($0, color) }, additive: s.waveAdditive,
                thick: s.waveThick || s.waveDots)
        }
    }

    /// The built-in waveform's line or lines (mode 7 draws two) and its alpha.
    struct BasicWave {
        var points: [SIMD2<Double>] = []
        var points2: [SIMD2<Double>] = []
        var alpha = 0.0
    }

    /// One mode's waveform from the smoothed channels.
    private func basicWave(_ s: FrameState, mode: Int, waveL: [Double], waveR: [Double], vol: Double) -> BasicWave {
        let posX = s.waveX * 2 - 1, posY = s.waveY * 2 - 1
        let ax = aspect.x, ay = aspect.y
        var mystery = s.waveMystery
        if (mode == 0 || mode == 1 || mode == 4) && (mystery < -1 || mystery > 1) {
            mystery = mystery * 0.5 + 0.5
            mystery -= mystery.rounded(.down)
            mystery = abs(mystery) * 2 - 1
        }
        func texScale(_ small: Double, _ medium: Double, _ large: Double) -> Double {
            width < 1024 ? small : (width < 2048 ? medium : large)
        }

        var alpha = s.waveColor.w
        var points: [SIMD2<Double>] = []
        var points2: [SIMD2<Double>] = []
        let count = waveL.count
        switch mode {
        case 0:
            let n = count / 2 + 1
            let inv = 1 / Double(n - 1)
            let offset = (count - n) / 2
            for i in 0..<(n - 1) {
                var rad = 0.5 + 0.4 * waveR[i + offset] + mystery
                let ang = Double(i) * inv * 2 * .pi + s.time * 0.2
                if Double(i) < Double(n) / 10 {
                    var mix = Double(i) / (Double(n) * 0.1)
                    mix = 0.5 - 0.5 * cos(mix * .pi)
                    let rad2 = 0.5 + 0.4 * waveR[min(i + n + offset, count - 1)] + mystery
                    rad = (1 - mix) * rad2 + rad * mix
                }
                points.append([rad * cos(ang) * ay + posX, rad * sin(ang) * ax + posY])
            }
            points.append(points[0])
        case 1:
            alpha *= 1.25
            let n = count / 2
            for i in 0..<n {
                let rad = 0.53 + 0.43 * waveR[i] + mystery
                let ang = waveL[min(i + 32, count - 1)] * 0.5 * .pi + s.time * 2.3
                points.append([rad * cos(ang) * ay + posX, rad * sin(ang) * ax + posY])
            }
        case 2, 3:
            if mode == 2 {
                alpha *= texScale(0.09, 0.11, 0.13)
            } else {
                alpha *= texScale(0.15, 0.22, 0.33) * 1.3 * s.levels.treb * s.levels.treb
            }
            for i in 0..<count {
                points.append([waveR[i] * ay + posX, waveL[(i + 32) % count] * ax + posY])
            }
        case 4:
            let n = min(count, width / 3)
            let inv = 1 / Double(max(n, 1))
            let offset = (count - n) / 2
            let w1 = 0.45 + 0.5 * (mystery * 0.5 + 0.5), w2 = 1 - w1
            for i in 0..<n {
                var x = 2 * Double(i) * inv + (posX - 1) + waveR[(i + 25 + offset) % count] * 0.44
                var y = waveL[i + offset] * 0.47 + posY
                if i > 1 {
                    x = x * w2 + w1 * (points[i - 1].x * 2 - points[i - 2].x)
                    y = y * w2 + w1 * (points[i - 1].y * 2 - points[i - 2].y)
                }
                points.append([x, y])
            }
        case 5:
            alpha *= texScale(0.09, 0.11, 0.13)
            let c = cos(s.time * 0.3), sn = sin(s.time * 0.3)
            for i in 0..<count {
                let j = (i + 32) % count
                let x0 = waveR[i] * waveL[j] + waveL[i] * waveR[j]
                let y0 = waveR[i] * waveR[i] - waveL[j] * waveL[j]
                points.append([(x0 * c - y0 * sn) * (ay + posX), (x0 * sn + y0 * c) * (ax + posY)])
            }
        default:
            // 6: a line across the screen at an angle set by wave_mystery; 7: two, left and right.
            let n = min(count / 2, width / 3)
            let offset = (count - n) / 2
            let ang = .pi * 0.5 * mystery
            var dx = cos(ang), dy = sin(ang)
            var edgeX = [posX * cos(ang + .pi * 0.5) - dx * 3, posX * cos(ang + .pi * 0.5) + dx * 3]
            var edgeY = [posX * sin(ang + .pi * 0.5) - dy * 3, posX * sin(ang + .pi * 0.5) + dy * 3]
            for i in 0..<2 {
                for j in 0..<4 {
                    var t = 0.0
                    var clip = false
                    switch j {
                    case 0: if edgeX[i] > 1.1 { t = (1.1 - edgeX[1 - i]) / (edgeX[i] - edgeX[1 - i]); clip = true }
                    case 1: if edgeX[i] < -1.1 { t = (-1.1 - edgeX[1 - i]) / (edgeX[i] - edgeX[1 - i]); clip = true }
                    case 2: if edgeY[i] > 1.1 { t = (1.1 - edgeY[1 - i]) / (edgeY[i] - edgeY[1 - i]); clip = true }
                    default: if edgeY[i] < -1.1 { t = (-1.1 - edgeY[1 - i]) / (edgeY[i] - edgeY[1 - i]); clip = true }
                    }
                    if clip {
                        let dxi = edgeX[i] - edgeX[1 - i], dyi = edgeY[i] - edgeY[1 - i]
                        edgeX[i] = edgeX[1 - i] + dxi * t
                        edgeY[i] = edgeY[1 - i] + dyi * t
                    }
                }
            }
            dx = (edgeX[1] - edgeX[0]) / Double(n)
            dy = (edgeY[1] - edgeY[0]) / Double(n)
            let ang2 = atan2(dy, dx)
            let perpX = cos(ang2 + .pi * 0.5), perpY = sin(ang2 + .pi * 0.5)
            let sep = mode == 7 ? pow(posY * 0.5 + 0.5, 2) : 0
            for i in 0..<n {
                let sample = waveL[i + offset]
                points.append([edgeX[0] + dx * Double(i) + perpX * (0.25 * sample + sep),
                               edgeY[0] + dy * Double(i) + perpY * (0.25 * sample + sep)])
            }
            if mode == 7 {
                for i in 0..<n {
                    let sample = waveR[i + offset]
                    points2.append([edgeX[0] + dx * Double(i) + perpX * (0.25 * sample - sep),
                                    edgeY[0] + dy * Double(i) + perpY * (0.25 * sample - sep)])
                }
            }
        }
        if s.modWaveAlphaByVolume {
            alpha *= (vol - s.modWaveAlphaStart) / (s.modWaveAlphaEnd - s.modWaveAlphaStart)
        }
        return BasicWave(points: points, points2: points2, alpha: min(max(alpha, 0), 1))
    }

    /// Moves each point of `new` toward the matching point of `old` (resampled to the same count), weighted by
    /// the eased progress. Mode 7's two lines pair with the two halves of a single-line mode.
    static func morph(from old: BasicWave, oldMode: Int, to new: BasicWave, mode: Int, progress: Double) -> BasicWave {
        let mix = 0.5 - 0.5 * cos(progress * .pi), mix2 = 1 - mix
        var out = new
        out.alpha = mix * new.alpha + mix2 * old.alpha
        /// `line` at fractional index `f`, linearly interpolated.
        func at(_ line: [SIMD2<Double>], _ f: Double) -> SIMD2<Double> {
            let i = min(max(Int(f), 0), line.count - 2), t = f - Double(i)
            return line[i] * (1 - t) + line[i + 1] * t
        }
        let n = new.points.count
        guard n > 0, old.points.count > 1 else { return out }
        if mode == 7 {
            let m = Double(old.points.count - 1) / Double(n * 2)
            for i in 0..<n { out.points[i] = new.points[i] * mix + at(old.points, Double(i) * m) * mix2 }
            for i in 0..<min(n, new.points2.count) {
                out.points2[i] = new.points2[i] * mix + at(old.points, Double(i + n) * m) * mix2
            }
        } else if oldMode == 7, old.points2.count > 1 {
            let half = n / 2
            guard half > 0 else { return out }
            let m = Double(old.points.count - 1) / Double(half)
            let m2 = Double(old.points2.count - 1) / Double(half)
            out.points = (0..<half).map { new.points[$0] * mix + at(old.points, Double($0) * m) * mix2 }
            out.points2 = (0..<half).map { new.points[$0 + half] * mix + at(old.points2, Double($0) * m2) * mix2 }
        } else {
            let m = Double(old.points.count - 1) / Double(n)
            for i in 0..<n { out.points[i] = new.points[i] * mix + at(old.points, Double(i) * m) * mix2 }
        }
        return out
    }

    // MARK: Darkened centre and borders

    mutating func addDarkenCenter(_ s: FrameState) {
        guard s.darkenCenter else { return }
        let h: Float = 0.05, ay = Float(aspect.y)
        let center = OverlayVertex(.zero, SIMD4(0, 0, 0, 3.0 / 32))
        let ring: [SIMD2<Float>] = [[-h * ay, 0], [0, h], [h * ay, 0], [0, -h], [-h * ay, 0]]
        var fan: [OverlayVertex] = []
        for k in 0..<(ring.count - 1) {
            fan += [center, OverlayVertex(ring[k], .zero), OverlayVertex(ring[k + 1], .zero)]
        }
        add(.triangles, fan)
    }

    /// The outer border at the screen edge, the inner one just inside it. Sizes are in clip units.
    mutating func addBorders(_ s: FrameState) {
        addBorder(size: s.outerBorder.size, color: s.outerBorder.color, inset: 0)
        addBorder(size: s.innerBorder.size, color: s.innerBorder.color, inset: s.outerBorder.size)
    }

    private mutating func addBorder(size: Double, color c: SIMD4<Double>, inset: Double) {
        guard size > 0, c.w > 0 else { return }
        let color = SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), Float(c.w)).clamped(lowerBound: .zero, upperBound: .one)
        let o = Float(1 - inset), i = Float(1 - inset - size)
        var quads: [OverlayVertex] = []
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
            let a = OverlayVertex(SIMD2(x0, y0), color), b = OverlayVertex(SIMD2(x1, y0), color)
            let c = OverlayVertex(SIMD2(x0, y1), color), d = OverlayVertex(SIMD2(x1, y1), color)
            quads += [a, b, c, b, d, c]
        }
        rect(-o, i, o, o)        // top
        rect(-o, -o, o, -i)      // bottom
        rect(-o, -i, -i, i)      // left
        rect(i, -i, o, i)        // right
        add(.triangles, quads)
    }
}
