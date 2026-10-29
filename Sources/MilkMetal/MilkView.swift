import AppKit
import Metal
import QuartzCore

/// An `NSView` backed by a `CAMetalLayer` that draws a `MilkRenderer` on every display refresh.
/// The host owns windows, menus, preset browsing and full screen.
@MainActor
public final class MilkView: NSView {
    /// The renderer the view draws. Load presets, change settings and `feed` audio through it.
    public let renderer: MilkRenderer
    private let commandQueue: MTLCommandQueue
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?

    /// Creates a view that draws `renderer` in the renderer's `pixelFormat`. It starts drawing once it's in a
    /// window, with its own clock starting at 0. Throws `MilkRendererError.noCommandQueue` if the device can't make
    /// a command queue.
    public init(renderer: MilkRenderer, frame: NSRect = .zero) throws(MilkRendererError) {
        guard let queue = renderer.device.makeCommandQueue() else { throw MilkRendererError.noCommandQueue }
        self.renderer = renderer
        commandQueue = queue
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = renderer.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let metalLayer, let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let start = startTime ?? link.targetTimestamp
        startTime = start
        renderer.render(to: drawable.texture, commandBuffer: commandBuffer, time: link.targetTimestamp - start)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
