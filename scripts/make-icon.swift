// Turns a square artwork PNG into App/Assets.xcassets/AppIcon.appiconset, shaped like a macOS icon:
// the artwork clipped to Apple's rounded square (824 of 1024 px, leaving the standard margin), with a soft shadow.
//
//   swift scripts/make-icon.swift art/icon-raw.png
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 2, let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift artwork.png\n".utf8))
    exit(2)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    // Shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // Artwork, center-cropped to a square and clipped to the tile.
    let side = min(src.width, src.height)
    let crop = src.cropping(to: CGRect(x: (src.width - side) / 2, y: (src.height - side) / 2, width: side, height: side))!
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(crop, in: tile)
    // A faint inner edge, like Apple's icons.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(3 * s)
    ctx.strokePath()
    ctx.restoreGState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"))
print("Wrote \(dir.path)")
