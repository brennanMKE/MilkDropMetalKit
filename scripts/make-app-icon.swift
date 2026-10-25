// make-app-icon.swift — turn a square frame into the gallery's app icon (Design/AppIcon.png).
//
// Usage: swift scripts/make-app-icon.swift <frame.png> [out.png]
// The frame is drawn into a 1024×1024 canvas as a rounded square on Apple's macOS icon grid (an 824-point body,
// 100 points of margin for the shadow), with a soft drop shadow and a thin inner rim. Uses Core Graphics only.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-app-icon.swift <frame.png> [out.png]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args.count > 2 ? args[2] : "Design/AppIcon.png")

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(input.path)\n".utf8))
    exit(1)
}

let size = 1024
let bodySize: CGFloat = 824
let radius: CGFloat = 185
let body = CGRect(x: (CGFloat(size) - bodySize) / 2, y: (CGFloat(size) - bodySize) / 2 + 10,
                  width: bodySize, height: bodySize)
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Shadow under the body.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
context.addPath(shape)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fillPath()
context.restoreGState()

// The frame, centre-cropped to a square and clipped to the body.
context.saveGState()
context.addPath(shape)
context.clip()
let side = min(frame.width, frame.height)
let crop = CGRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
context.interpolationQuality = .high
if let square = frame.cropping(to: crop) { context.draw(square, in: body) }
context.restoreGState()

// A thin light rim, so a dark icon still reads against a dark Dock.
context.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1,
                       transform: nil))
context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
context.setLineWidth(2)
context.strokePath()

guard let image = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("wrote \(output.path)")
