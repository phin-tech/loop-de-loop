import CoreGraphics

/// Converts images to the device's 16-bit RGB 5-6-5 little-endian pixel format.
public enum RGB565 {
    /// Render `image` scaled to `width`×`height` and encode it.
    public static func encode(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        encode(width: width, height: height) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Draw with Core Graphics (origin bottom-left) and encode the result.
    public static func encode(width: Int, height: Int, draw: (CGContext) -> Void) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(ctx)
        }
        return fromRGBA(rgba, pixelCount: width * height)
    }

    public static func fromRGBA(_ rgba: [UInt8], pixelCount: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixelCount * 2)
        for i in 0..<pixelCount {
            let r = UInt16(rgba[i * 4]), g = UInt16(rgba[i * 4 + 1]), b = UInt16(rgba[i * 4 + 2])
            let color = (r & 0xf8) << 8 | (g & 0xfc) << 3 | b >> 3
            out[i * 2] = UInt8(color & 0xff)
            out[i * 2 + 1] = UInt8(color >> 8)
        }
        return out
    }

    public static func solid(red: UInt8, green: UInt8, blue: UInt8, pixelCount: Int) -> [UInt8] {
        fromRGBA([red, green, blue, 255], pixelCount: 1).repeated(pixelCount)
    }
}

private extension Array where Element == UInt8 {
    func repeated(_ times: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * times)
        for _ in 0..<times { out += self }
        return out
    }
}
