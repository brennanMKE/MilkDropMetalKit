import Metal
import Testing
@testable import MilkMetal

struct AudioRingTests {
    @Test func zeroFillsBeforeEnoughFrames() {
        let ring = AudioRing(capacity: 8)
        let input: [Float] = [1, -1, 2, -2]  // two stereo frames
        input.withUnsafeBufferPointer { ring.write(samples: $0, channels: 2, sampleRate: 48_000) }
        var left = [Float](repeating: 9, count: 4)
        var right = [Float](repeating: 9, count: 4)
        let available = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in ring.copyLatest(count: 4, left: l, right: r) }
        }
        #expect(available == 2)
        #expect(left == [0, 0, 1, 2])
        #expect(right == [0, 0, -1, -2])
        #expect(ring.sampleRate == 48_000)
    }

    @Test func keepsNewestFramesAfterWrapping() {
        let ring = AudioRing(capacity: 4)
        let input: [Float] = (1...6).map(Float.init)  // six mono frames
        input.withUnsafeBufferPointer { ring.write(samples: $0, channels: 1, sampleRate: 44_100) }
        var left = [Float](repeating: 0, count: 3)
        var right = [Float](repeating: 0, count: 3)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in _ = ring.copyLatest(count: 3, left: l, right: r) }
        }
        #expect(left == [4, 5, 6])
        #expect(right == [4, 5, 6])
    }
}

@MainActor
struct MilkRendererTests {
    @Test func rendersSilenceToBlack() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        renderer.render(to: texture, commandBuffer: commandBuffer, time: 0)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0x7F, count: 4 * 4 * 4)
        texture.getBytes(&pixels, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        #expect(pixels.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 })
    }

    @Test func rejectsFormatsALayerCannotShow() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(throws: MilkRendererError.self) { try MilkRenderer(device: device, pixelFormat: .r8Unorm) }
    }
}
