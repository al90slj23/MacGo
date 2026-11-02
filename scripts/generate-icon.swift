import AppKit
import Foundation

// Original code-drawn toolbox glyph, no downloaded image or third-party asset.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 208, yRadius: 208)
        NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.37, blue: 0.95, alpha: 1),
                   ending: NSColor(srgbRed: 0.48, green: 0.26, blue: 0.84, alpha: 1))!.draw(in: tile, angle: 45)
        NSColor.white.setStroke(); NSColor.white.setFill()
        let handle = NSBezierPath(roundedRect: NSRect(x: 372, y: 650, width: 280, height: 136), xRadius: 50, yRadius: 50)
        handle.lineWidth = 44; handle.stroke()
        let body = NSBezierPath(roundedRect: NSRect(x: 190, y: 238, width: 644, height: 440), xRadius: 76, yRadius: 76)
        body.lineWidth = 44; body.stroke()
        let lid = NSBezierPath(); lid.move(to: NSPoint(x: 198, y: 498)); lid.line(to: NSPoint(x: 826, y: 498)); lid.lineWidth = 40; lid.stroke()
        NSBezierPath(roundedRect: NSRect(x: 464, y: 440, width: 96, height: 116), xRadius: 22, yRadius: 22).fill()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}
