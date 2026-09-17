import AppKit

enum ClankerIcon {
    // A 16×16 sprite, aligned to pixels at both menu-bar display scales.
    private static let sprite = [
        "0000000110000000",
        "0000000110000000",
        "0000000110000000",
        "0001111111111000",
        "0011111111111100",
        "0011111111111100",
        "1111001111001111",
        "1111001111001111",
        "1111111111111111",
        "0011111111111100",
        "0011100000011100",
        "0011111111111100",
        "0001111111111000",
        "0000001111000000",
        "0000111111110000",
        "0000000000000000"
    ]
    private static func draw(in rect: NSRect, color: NSColor) {
        let pixel = rect.width / 16
        NSGraphicsContext.current?.shouldAntialias = false
        color.setFill()
        for (y, row) in sprite.enumerated() {
            for (x, value) in row.enumerated() where value == "1" {
                NSRect(x: rect.minX + CGFloat(x) * pixel,
                       y: rect.maxY - CGFloat(y + 1) * pixel,
                       width: pixel, height: pixel).fill()
            }
        }
    }
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(in: NSRect(x: 1, y: 1, width: 16, height: 16), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AgentsPanel pixel robot"
        return image
    }
    static func appBitmap(pixels: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let size = CGFloat(pixels)
        let background = NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88)
        NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: background, xRadius: size * 0.2, yRadius: size * 0.2).fill()
        let pixel = max(0.5, floor(size * 0.64 / 16))
        let width = pixel * 16
        draw(in: NSRect(x: (size - width) / 2, y: (size - width) / 2, width: width, height: width),
             color: NSColor(calibratedRed: 0.71, green: 0.74, blue: 1, alpha: 1))
        return bitmap
    }
}
