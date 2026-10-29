import Foundation

/// How the incoming preset spreads over the screen during a transition. MilkDrop 2 picks one of the three
/// patterns at random for each blend.
public enum MilkTransitionPattern: Sendable, CaseIterable {
    /// One of `wipe`, `plasma` and `radial`, chosen per transition, as MilkDrop 2 does.
    case random
    /// The whole screen fades evenly.
    case crossfade
    /// A soft-edged band sweeps across the screen at a random angle.
    case wipe
    /// Fractal plasma clouds: patches switch over at different times.
    case plasma
    /// A ring grows out from the centre, or shrinks in from the corners.
    case radial
}

/// The per-vertex timing of a transition: vertex `i` shows the incoming preset with weight
/// `clamp(a[i] * progress + c[i], 0, 1)`. Every pattern starts at 0 and ends at 1 everywhere; the patterns
/// differ in when each vertex makes the change. A port of Butterchurn's `BlendPattern`.
struct BlendPattern {
    let meshSize: (width: Int, height: Int)
    let aspect: Aspect
    private(set) var a: [Float]
    private(set) var c: [Float]

    init(_ pattern: MilkTransitionPattern, meshSize: (width: Int, height: Int), aspect: Aspect,
         random: inout SplitMix) {
        self.meshSize = meshSize
        self.aspect = aspect
        let (gw, gh) = meshSize
        let count = (gw + 1) * (gh + 1)
        a = [Float](repeating: 1, count: count)
        c = [Float](repeating: 0, count: count)

        var pattern = pattern
        if pattern == .random {
            pattern = [.wipe, .plasma, .radial][Int(random.unit() * 3) % 3]
        }
        let ax = aspect.x, ay = aspect.y
        /// Stores `t` (0…1, when the vertex switches) as a band `band` wide.
        func set(_ i: Int, _ t: Double, band: Double) {
            let invBand = 1 / band
            a[i] = Float(invBand * (1 + band))
            c[i] = Float(-invBand + invBand * t)
        }
        switch pattern {
        case .random, .crossfade:
            break
        case .wipe:
            let angle = random.unit() * 6.28
            let vx = cos(angle), vy = sin(angle)
            let band = 0.1 + 0.2 * random.unit()
            for y in 0...gh {
                let fy = Double(y) / Double(gh) * ay
                for x in 0...gw {
                    let fx = Double(x) / Double(gw) * ax
                    var t = (fx - 0.5) * vx + (fy - 0.5) * vy + 0.5
                    t = (t - 0.5) / 2.0.squareRoot() + 0.5
                    set(y * (gw + 1) + x, t, band: band)
                }
            }
        case .plasma:
            let band = 0.12 + 0.13 * random.unit()
            var heights = [Double](repeating: 0, count: count)
            heights[0] = random.unit()
            heights[gw] = random.unit()
            heights[gh * (gw + 1)] = random.unit()
            heights[gh * (gw + 1) + gw] = random.unit()
            Self.plasma(&heights, 0, gw, 0, gh, 0.25, width: gw, aspect: aspect, random: &random)
            let lo = heights.min() ?? 0, hi = heights.max() ?? 1
            let scale = hi > lo ? 1 / (hi - lo) : 0
            for i in 0..<count { set(i, (heights[i] - lo) * scale, band: band) }
        case .radial:
            let band = 0.02 + 0.14 * random.unit() + 0.34 * random.unit()
            let inward = random.unit() < 0.5
            for y in 0...gh {
                let dy = (Double(y) / Double(gh) - 0.5) * ay
                for x in 0...gw {
                    let dx = (Double(x) / Double(gw) - 0.5) * ax
                    let t = (dx * dx + dy * dy).squareRoot() * 1.41421
                    set(y * (gw + 1) + x, inward ? 1 - t : t, band: band)
                }
            }
        }
    }

    /// Midpoint displacement over the mesh rectangle (x0, y0)–(x1, y1), whose corners are already set
    /// (Butterchurn's `genPlasma`).
    private static func plasma(_ h: inout [Double], _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ dt: Double,
                               width gw: Int, aspect: Aspect, random: inout SplitMix) {
        let row = gw + 1
        let midX = (x0 + x1) / 2, midY = (y0 + y1) / 2
        func jitter(_ scale: Double) -> Double { (random.unit() * 2 - 1) * dt * scale }
        var t00 = h[y0 * row + x0], t01 = h[y0 * row + x1], t10 = h[y1 * row + x0], t11 = h[y1 * row + x1]
        if y1 - y0 >= 2 {
            if x0 == 0 { h[midY * row + x0] = 0.5 * (t00 + t10) + jitter(aspect.y) }
            h[midY * row + x1] = 0.5 * (t01 + t11) + jitter(aspect.y)
        }
        if x1 - x0 >= 2 {
            if y0 == 0 { h[y0 * row + midX] = 0.5 * (t00 + t01) + jitter(aspect.x) }
            h[y1 * row + midX] = 0.5 * (t10 + t11) + jitter(aspect.x)
        }
        guard y1 - y0 >= 2, x1 - x0 >= 2 else { return }
        t00 = h[midY * row + x0]
        t01 = h[midY * row + x1]
        t10 = h[y0 * row + midX]
        t11 = h[y1 * row + midX]
        h[midY * row + midX] = 0.25 * (t00 + t01 + t10 + t11) + jitter(1)
        plasma(&h, x0, midX, y0, midY, dt * 0.5, width: gw, aspect: aspect, random: &random)
        plasma(&h, midX, x1, y0, midY, dt * 0.5, width: gw, aspect: aspect, random: &random)
        plasma(&h, x0, midX, midY, y1, dt * 0.5, width: gw, aspect: aspect, random: &random)
        plasma(&h, midX, x1, midY, y1, dt * 0.5, width: gw, aspect: aspect, random: &random)
    }

    /// The incoming preset's weight at vertex `i`.
    func weight(_ i: Int, progress: Double) -> Float {
        min(max(a[i] * Float(progress) + c[i], 0), 1)
    }
}

extension FrameState {
    /// The settings drawn while blending from `old` to `new`: numbers ease across on a cosine, switches flip
    /// halfway, and everything else is the incoming preset's (Butterchurn's `mixFrameEquations`).
    static func mixed(from old: FrameState, to new: FrameState, progress: Double) -> FrameState {
        let mix = 0.5 - 0.5 * cos(progress * .pi)
        func m(_ a: Double, _ b: Double) -> Double { mix * b + (1 - mix) * a }
        func m(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> SIMD4<Double> { mix * b + (1 - mix) * a }
        func m(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> { mix * b + (1 - mix) * a }
        func snap<T>(_ a: T, _ b: T) -> T { mix < 0.5 ? a : b }

        var s = new
        s.decay = m(old.decay, new.decay)
        s.waveColor = m(old.waveColor, new.waveColor)
        s.waveX = m(old.waveX, new.waveX)
        s.waveY = m(old.waveY, new.waveY)
        s.waveMystery = m(old.waveMystery, new.waveMystery)
        s.outerBorder = (m(old.outerBorder.size, new.outerBorder.size), m(old.outerBorder.color, new.outerBorder.color))
        s.innerBorder = (m(old.innerBorder.size, new.innerBorder.size), m(old.innerBorder.color, new.innerBorder.color))
        let a = old.motionVectors, b = new.motionVectors
        s.motionVectors = MotionVectorSettings(x: m(a.x, b.x), y: m(a.y, b.y), dx: m(a.dx, b.dx), dy: m(a.dy, b.dy),
                                               length: m(a.length, b.length), color: m(a.color, b.color))
        s.echoZoom = m(old.echoZoom, new.echoZoom)
        s.echoAlpha = m(old.echoAlpha, new.echoAlpha)
        s.echoOrient = snap(old.echoOrient, new.echoOrient)
        s.waveDots = snap(old.waveDots, new.waveDots)
        s.waveThick = snap(old.waveThick, new.waveThick)
        s.waveAdditive = snap(old.waveAdditive, new.waveAdditive)
        s.waveBrighten = snap(old.waveBrighten, new.waveBrighten)
        s.darkenCenter = snap(old.darkenCenter, new.darkenCenter)
        s.gamma = snap(old.gamma, new.gamma)
        s.wrap = snap(old.wrap, new.wrap)
        s.invert = snap(old.invert, new.invert)
        s.brighten = snap(old.brighten, new.brighten)
        s.darken = snap(old.darken, new.darken)
        // Butterchurn snaps from the old preset's `brighten` here, a typo; MilkDrop uses `solarize`.
        s.solarize = snap(old.solarize, new.solarize)
        s.blurMin = m(old.blurMin, new.blurMin)
        s.blurMax = m(old.blurMax, new.blurMax)
        s.blur1EdgeDarken = m(old.blur1EdgeDarken, new.blur1EdgeDarken)
        return s
    }
}
