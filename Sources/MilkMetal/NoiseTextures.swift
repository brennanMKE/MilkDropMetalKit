import Foundation
import Metal

/// MilkDrop 2's noise textures, which preset shaders sample: random RGBA at several smoothnesses. `lq` is raw noise;
/// `mq` and `hq` are coarser random grids filled in with cubic interpolation (every 4th and 8th texel random), so
/// they're smooth. The `vol` ones are 3D. A port of Butterchurn's `Noise`, with a fixed seed so frames are
/// reproducible.
struct NoiseTextures {
    let lq: MTLTexture
    let lqLite: MTLTexture
    let mq: MTLTexture
    let hq: MTLTexture
    let volLQ: MTLTexture
    let volHQ: MTLTexture

    /// In shader-slot order: noise_lq, noise_lq_lite, noise_mq, noise_hq, noisevol_lq, noisevol_hq.
    var all: [MTLTexture] { [lq, lqLite, mq, hq, volLQ, volHQ] }

    init(device: MTLDevice, seed: UInt64 = 0x4D69_6C6B) throws(MilkRendererError) {
        var random = SplitMix(seed: seed)
        lq = try Self.texture2D(device, size: 256, data: Self.noise2D(size: 256, zoom: 1, &random), label: "noise_lq")
        lqLite = try Self.texture2D(device, size: 32, data: Self.noise2D(size: 32, zoom: 1, &random), label: "noise_lq_lite")
        mq = try Self.texture2D(device, size: 256, data: Self.noise2D(size: 256, zoom: 4, &random), label: "noise_mq")
        hq = try Self.texture2D(device, size: 256, data: Self.noise2D(size: 256, zoom: 8, &random), label: "noise_hq")
        volLQ = try Self.texture3D(device, size: 32, data: Self.noise3D(size: 32, zoom: 1, &random), label: "noisevol_lq")
        volHQ = try Self.texture3D(device, size: 32, data: Self.noise3D(size: 32, zoom: 4, &random), label: "noisevol_hq")
    }

    // MARK: Generation

    /// Random bytes; with zoom > 1 a narrower range around 128, since interpolation overshoots.
    private static func random(_ count: Int, zoom: Int, _ rng: inout SplitMix) -> [Float] {
        let range = zoom > 1 ? 216.0 : 256.0
        return (0..<count).map { _ in Float((rng.unit() * range + 128 - range / 2).rounded(.down)) }
    }

    private static func cubic(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
        let t2 = t * t, t3 = t * t2
        let a0 = y3 - y2 - y0 + y1, a1 = y0 - y1 - a0, a2 = y2 - y0, a3 = y1
        return a0 * t3 + a1 * t2 + a2 * t + a3
    }

    /// Fills the texels between every `zoom`th one along one axis by cubic interpolation, wrapping at the edges.
    /// `at(i)` maps an index along the axis to an offset into the 4-channel array.
    private static func interpolate(_ data: inout [Float], size: Int, zoom: Int, at index: (Int) -> Int) {
        for x in 0..<size where x % zoom != 0 {
            let base = (x / zoom) * zoom + size
            let t = Float(x % zoom) / Float(zoom)
            for c in 0..<4 {
                func v(_ k: Int) -> Float { data[index(k % size) + c] }
                data[index(x) + c] = cubic(v(base - zoom), v(base), v(base + zoom), v(base + zoom * 2), t)
            }
        }
    }

    static func noise2D(size: Int, zoom: Int, _ rng: inout SplitMix) -> [UInt8] {
        var data = random(size * size * 4, zoom: zoom, &rng)
        if zoom > 1 {
            for y in stride(from: 0, to: size, by: zoom) {
                interpolate(&data, size: size, zoom: zoom) { x in (y * size + x) * 4 }
            }
            for x in 0..<size {
                interpolate(&data, size: size, zoom: zoom) { y in (y * size + x) * 4 }
            }
        }
        return data.map { UInt8(min(max($0, 0), 255)) }
    }

    static func noise3D(size: Int, zoom: Int, _ rng: inout SplitMix) -> [UInt8] {
        var data = random(size * size * size * 4, zoom: zoom, &rng)
        if zoom > 1 {
            let slice = size * size
            for z in stride(from: 0, to: size, by: zoom) {
                for y in stride(from: 0, to: size, by: zoom) {
                    interpolate(&data, size: size, zoom: zoom) { x in (z * slice + y * size + x) * 4 }
                }
            }
            for z in stride(from: 0, to: size, by: zoom) {
                for x in 0..<size {
                    interpolate(&data, size: size, zoom: zoom) { y in (z * slice + y * size + x) * 4 }
                }
            }
            for y in 0..<size {
                for x in 0..<size {
                    interpolate(&data, size: size, zoom: zoom) { z in (z * slice + y * size + x) * 4 }
                }
            }
        }
        return data.map { UInt8(min(max($0, 0), 255)) }
    }

    // MARK: Textures

    private static func texture2D(_ device: MTLDevice, size: Int, data: [UInt8],
                                  label: String) throws(MilkRendererError) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size,
                                                         mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else {
            throw MilkRendererError.resourceCreation(resource: label)
        }
        t.label = "MilkRenderer.\(label)"
        t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: data, bytesPerRow: size * 4)
        return t
    }

    private static func texture3D(_ device: MTLDevice, size: Int, data: [UInt8],
                                  label: String) throws(MilkRendererError) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = size
        d.height = size
        d.depth = size
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else {
            throw MilkRendererError.resourceCreation(resource: label)
        }
        t.label = "MilkRenderer.\(label)"
        t.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0, withBytes: data,
                  bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        return t
    }
}
