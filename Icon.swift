// Draws Scribe's app icon: `swift Icon.swift <folder.iconset>`. build.sh turns the folder into an .icns.
// Kept out of the app itself, so the app carries only the finished icon file (about 200 KB).
import AppKit
import SwiftUI

func draw(_ pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024  // everything below is laid out on a 1024 canvas
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    func color(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: white, green: white, blue: white * 1.02, alpha: alpha) }

    // The standard macOS tile: 824 pt square with continuous corners, floating on a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 186, style: .continuous).path(in: tile).cgPath
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let graphite = CGGradient(colorsSpace: space, colors: [color(0.25), color(0.075)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(graphite, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint light edge along the top, the way a real object catches light.
    ctx.addPath(shape)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: space, colors: [color(1, 0.22), color(1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // A voice as seven bars.
    let heights: [CGFloat] = [0.24, 0.50, 0.82, 0.40, 1.00, 0.62, 0.30]
    let (bar, gap, tallest): (CGFloat, CGFloat, CGFloat) = (42, 36, 400)
    var x = 512 - (CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap) / 2
    let silver = CGGradient(colorsSpace: space, colors: [color(1), color(0.8)] as CFArray, locations: [0, 1])!
    for h in heights {
        let rect = CGRect(x: x, y: 512 - tallest * h / 2, width: bar, height: tallest * h)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(silver, start: CGPoint(x: 512, y: 512 + tallest / 2), end: CGPoint(x: 512, y: 512 - tallest / 2), options: [])
        ctx.restoreGState()
        x += bar + gap
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// Up to 512 px; the 1024 px size alone would double the file for a view almost nobody opens.
for points in [16, 32, 128, 256, 512] {
    try draw(points).write(to: folder.appendingPathComponent("icon_\(points)x\(points).png"))
    if points < 512 { try draw(points * 2).write(to: folder.appendingPathComponent("icon_\(points)x\(points)@2x.png")) }
}
