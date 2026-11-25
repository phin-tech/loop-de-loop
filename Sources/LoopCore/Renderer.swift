import AppKit
import CoreGraphics
import CoreText
import LoupedeckKit

/// Draws key appearances and strip labels with Core Graphics.
/// All drawing uses CG's bottom-left origin.
@MainActor
public enum Renderer {
    public static let defaultTitleColor = RGB.white
    public static let defaultBackground = RGB(24, 24, 24)

    /// Render a whole page as the device's full framebuffer (RGB565).
    public static func page(_ page: Page, overrides: [Int: Appearance], model: LoupedeckModel,
                            images: ImageStore) -> [UInt8] {
        RGB565.encode(width: model.screenWidth, height: model.screenHeight) { ctx in
            for i in 0..<model.keyCount {
                let r = model.rect(forKey: i)
                let rect = CGRect(x: r.x, y: model.screenHeight - r.y - r.height, width: r.width, height: r.height)
                drawKey(page.key(i).appearance.merged(with: overrides[i]), in: rect, ctx: ctx, images: images)
            }
            if model.stripWidth > 0 {
                for strip in Strip.allCases {
                    let r = model.rect(for: strip)
                    drawStrip(page, strip: strip, in: CGRect(x: r.x, y: 0, width: r.width, height: r.height), ctx: ctx)
                }
            }
        }
    }

    /// Render one key (keySize × keySize, RGB565).
    public static func key(_ appearance: Appearance, size: Int, images: ImageStore) -> [UInt8] {
        RGB565.encode(width: size, height: size) { ctx in
            drawKey(appearance, in: CGRect(x: 0, y: 0, width: size, height: size), ctx: ctx, images: images)
        }
    }

    /// Render a key to a CGImage (for the editor preview).
    public static func keyImage(_ appearance: Appearance, size: Int, scale: Int = 2, images: ImageStore) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size * scale, height: size * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawKey(appearance, in: CGRect(x: 0, y: 0, width: size, height: size), ctx: ctx, images: images)
        return ctx.makeImage()
    }

    static func drawKey(_ a: Appearance, in rect: CGRect, ctx: CGContext, images: ImageStore) {
        let inset = rect.insetBy(dx: 3, dy: 3)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Keys with nothing configured stay black so the grid reads as empty.
        guard !a.isEmpty else { return }

        let bg = a.background ?? defaultBackground
        let path = CGPath(roundedRect: inset, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(bg.cgColor)
        ctx.fillPath()

        let hasTitle = !(a.title ?? "").isEmpty
        let titleHeight: CGFloat = hasTitle ? 22 : 0
        let graphicRect = CGRect(x: inset.minX + 8, y: inset.minY + titleHeight + 4,
                                 width: inset.width - 16, height: inset.height - titleHeight - 12)

        if let name = a.image, let image = images.image(named: name) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let target = hasTitle ? graphicRect : inset
            ctx.interpolationQuality = .high
            ctx.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: target))
            ctx.restoreGState()
        } else if let symbol = a.symbol, let image = symbolImage(symbol, color: a.symbolColor ?? a.titleColor ?? .white,
                                                                     pointSize: hasTitle ? 34 : 46) {
            ctx.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: graphicRect))
        }

        if let title = a.title, !title.isEmpty {
            let onlyText = a.image == nil && a.symbol == nil
            let size = CGFloat(a.fontSize ?? (onlyText ? 18 : 13))
            let box = onlyText ? inset.insetBy(dx: 4, dy: 4) : CGRect(x: inset.minX + 3, y: inset.minY + 4, width: inset.width - 6, height: titleHeight)
            drawText(title, in: box, size: size, color: a.titleColor ?? defaultTitleColor, ctx: ctx)
        }
    }

    /// Each strip is split into three 90-px segments, one per knob on that side.
    static func drawStrip(_ page: Page, strip: Strip, in rect: CGRect, ctx: CGContext) {
        let knobs: [Knob] = strip == .left ? [.topLeft, .centerLeft, .bottomLeft] : [.topRight, .centerRight, .bottomRight]
        let segment = rect.height / 3
        for (i, knob) in knobs.enumerated() {
            guard let label = page.knob(knob).label, !label.isEmpty else { continue }
            let seg = CGRect(x: rect.minX, y: rect.maxY - CGFloat(i + 1) * segment, width: rect.width, height: segment)
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fill(seg.insetBy(dx: 2, dy: 2))
            drawText(label, in: seg.insetBy(dx: 3, dy: 6), size: 12, color: .white, ctx: ctx)
        }
    }

    // MARK: - Helpers

    static func drawText(_ s: String, in box: CGRect, size: CGFloat, color: RGB, ctx: CGContext) {
        var fontSize = size
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        // Shrink until the text fits.
        while true {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attr = NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: color.cgColor) ?? .white, .paragraphStyle: para,
            ])
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                  CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
            if fit.height <= box.height || fontSize <= 8 {
                // Center vertically.
                let frameRect = CGRect(x: box.minX, y: box.midY - fit.height / 2, width: box.width, height: ceil(fit.height))
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
                CTFrameDraw(frame, ctx)
                return
            }
            fontSize -= 1
        }
    }

    static func symbolImage(_ name: String, color: RGB, pointSize: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [NSColor(cgColor: color.cgColor) ?? .white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        // Render at 2x so the downscale to the key stays crisp.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return image.cgImage(forProposedRect: &rect, context: nil, hints: nil) }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

extension RGB {
    var cgColor: CGColor { CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1) }
}
