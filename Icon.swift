// Draws Scribe's app icon: `swift Icon.swift <folder.iconset>`. build.sh turns the folder into an .icns.
// Kept out of the app itself, so the app carries only the finished icon file.
//
// The icon is one reading from the app: a label, a value, a ten-segment bar. Black, white, flat.
import AppKit
import SwiftUI

func draw(_ pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024  // everything below is laid out on a 1024 canvas
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    func grey(_ hex: Int) -> CGColor { CGColor(srgbRed: CGFloat(hex) / 255, green: CGFloat(hex) / 255, blue: CGFloat(hex) / 255, alpha: 1) }

    // The standard macOS tile (824 pt, continuous corners) in flat black, edged with one hairline so
    // it still has a shape on a dark Dock. No gradient, no shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 186, style: .continuous).path(in: tile).cgPath
    ctx.addPath(shape)
    ctx.setFillColor(grey(0x00))
    ctx.fillPath()
    ctx.addPath(shape)
    ctx.setStrokeColor(grey(0x33))
    ctx.setLineWidth(6)
    ctx.strokePath()

    let left: CGFloat = 236
    let width: CGFloat = 552

    // The bar: ten square segments, six lit.
    let gap: CGFloat = 16
    let segment = (width - gap * 9) / 10
    for i in 0..<10 {
        ctx.setFillColor(grey(i < 6 ? 0xFF : 0x29))
        ctx.fill(CGRect(x: left + CGFloat(i) * (segment + gap), y: 300, width: segment, height: 86))
    }

    // Above it, the label and the value, set in the system monospace at one weight.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func text(_ string: String, size: CGFloat, color: Int, kern: CGFloat, at point: CGPoint) {
        NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .kern: kern,
                .foregroundColor: NSColor(srgbRed: CGFloat(color) / 255, green: CGFloat(color) / 255, blue: CGFloat(color) / 255, alpha: 1),
            ]
        ).draw(at: point)
    }
    text("SCR", size: 96, color: 0x8A, kern: 18, at: CGPoint(x: left - 4, y: 640))
    text("60", size: 250, color: 0xFF, kern: 0, at: CGPoint(x: left - 14, y: 392))
    text("%", size: 96, color: 0x8A, kern: 0, at: CGPoint(x: left + 316, y: 430))
    NSGraphicsContext.restoreGraphicsState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// Up to 512 px; the 1024 px size alone would double the file for a view almost nobody opens.
for points in [16, 32, 128, 256, 512] {
    try draw(points).write(to: folder.appendingPathComponent("icon_\(points)x\(points).png"))
    if points < 512 { try draw(points * 2).write(to: folder.appendingPathComponent("icon_\(points)x\(points)@2x.png")) }
}
