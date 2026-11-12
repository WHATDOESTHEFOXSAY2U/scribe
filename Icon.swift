// Draws Scribe's app icon: `swift Icon.swift <folder.iconset>`. build.sh turns the folder into an .icns.
// Kept out of the app itself, so the app carries only the finished icon file.
//
// The icon is the app's one recurring mark: the ten-segment bar, part lit. Monochrome and flat.
import AppKit
import SwiftUI

func draw(_ pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024  // everything below is laid out on a 1024 canvas
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    func grey(_ hex: Int) -> CGColor { CGColor(srgbRed: CGFloat(hex) / 255, green: CGFloat(hex) / 255, blue: CGFloat(hex) / 255, alpha: 1) }

    // The standard macOS tile (824 pt, continuous corners) in the app's own dark page colour, with a
    // soft shadow so it sits on the Dock like its neighbours.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 186, style: .continuous).path(in: tile).cgPath
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(grey(0x1E))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(grey(0x3A))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Ten segments across the middle, six lit.
    let (left, width, height, gap): (CGFloat, CGFloat, CGFloat, CGFloat) = (212, 600, 190, 18)
    let segment = (width - gap * 9) / 10
    for i in 0..<10 {
        let rect = CGRect(x: left + CGFloat(i) * (segment + gap), y: 512 - height / 2, width: segment, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(grey(i < 6 ? 0xF2 : 0x3C))
        ctx.fillPath()
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
