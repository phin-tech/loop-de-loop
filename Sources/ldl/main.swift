import CoreGraphics
import CoreText
import Foundation
import LoupedeckKit

// `ldl` — a small probe tool for LoupedeckKit.
//   ldl list          list connected devices
//   ldl info          print serial number and firmware version
//   ldl listen        print input events until Ctrl-C
//   ldl demo          paint keys, strips and button LEDs, then listen

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "info"

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

switch command {
case "list":
    let found = Discovery.devices()
    if found.isEmpty { print("No devices found") }
    for d in found {
        print("\(d.path)\t\(d.model?.name ?? "unknown") vid=0x\(String(d.vendorID, radix: 16)) pid=0x\(String(d.productID, radix: 16)) serial=\(d.serialNumber ?? "-")")
    }

case "info", "listen", "demo", "bench", "keys", "raw":
    do {
        let device = try await LoupedeckDevice.connect()
        log("Connected: \(device.model.name) at \(device.path)")
        log("Serial:   \(try await device.serialNumber())")
        log("Firmware: \(try await device.firmwareVersion())")
        if command == "demo" { try await demo(device) }
        if command == "bench" { try await bench(device) }
        if command == "keys" {
            // ldl keys 3 4 5 — draw solid keys one at a time, reporting acks
            for key in args.dropFirst().compactMap({ Int($0) }) {
                let r = device.model.rect(forKey: key)
                var fb: [UInt8] = [0x00, UInt8(ascii: "M")]
                for v in [r.x, r.y, r.width, r.height] { fb += [UInt8(v >> 8), UInt8(v & 0xff)] }
                let rgb = (ProcessInfo.processInfo.environment["COLOR"] ?? "200,60,0").split(separator: ",").compactMap { UInt8($0) }
                fb += RGB565.solid(red: rgb[0], green: rgb[1], blue: rgb[2], pixelCount: r.width * r.height)
                let t = Date()
                let fbAck = (try? await device.request(.framebuffer, fb, timeout: 1)) != nil
                let drawAck = (try? await device.request(.draw, [0x00, UInt8(ascii: "M")], timeout: 1)) != nil
                log(String(format: "  key %2d at x=%3d y=%3d  framebuffer %@  draw %@  %.0f ms", key, r.x, r.y,
                           fbAck ? "ack" : "NO ACK", drawAck ? "ack" : "NO ACK", Date().timeIntervalSince(t) * 1000))
            }
        }
        if command == "raw" {
            // ldl raw <key> <file.bin> — upload raw RGB565 pixels to a key
            let a = Array(args.dropFirst())
            let key = Int(a[0])!, r = device.model.rect(forKey: key)
            let px = [UInt8](try Data(contentsOf: URL(fileURLWithPath: a[1])))
            var fb: [UInt8] = [0x00, UInt8(ascii: "M")]
            for v in [r.x, r.y, r.width, r.height] { fb += [UInt8(v >> 8), UInt8(v & 0xff)] }
            let ok = (try? await device.request(.framebuffer, fb + px, timeout: 1)) != nil
            _ = try? await device.request(.draw, [0x00, UInt8(ascii: "M")], timeout: 1)
            print(ok ? "ACK" : "HANG")
        }
        if !["info", "bench", "keys", "raw"].contains(command) {
            log("Listening… (Ctrl-C to quit)")
            for await event in device.events { print(event); fflush(stdout) }
        }
        device.close()
    } catch {
        log("Error: \(error)")
        exit(1)
    }

default:
    log("usage: ldl [list|info|listen|demo]")
    exit(2)
}

func demo(_ device: LoupedeckDevice) async throws {
    try await device.setBrightness(1)
    let start = Date()
    let only = ProcessInfo.processInfo.environment["DEMO_KEYS"]?.split(separator: ",").compactMap { Int($0) }
    let dump = ProcessInfo.processInfo.environment["DUMP"]
    for key in only ?? Array(0..<device.model.keyCount) {
        if let dump {
            let px = RGB565.encode(width: 90, height: 90) { ctx in
                ctx.setFillColor(color(hue: CGFloat(key) / CGFloat(device.model.keyCount)))
                ctx.fill(CGRect(x: 4, y: 4, width: 82, height: 82))
                drawText("\(key)", in: ctx, size: 90)
            }
            try Data(px).write(to: URL(fileURLWithPath: "\(dump)/key\(key).bin"))
        }
        let hue = CGFloat(key) / CGFloat(device.model.keyCount)
        let t = Date()
        defer { log(String(format: "  key %d: %.0f ms", key, Date().timeIntervalSince(t) * 1000)) }
        try await device.drawKey(key) { ctx in
            ctx.setFillColor(color(hue: hue))
            ctx.fill(CGRect(x: 4, y: 4, width: 82, height: 82))
            drawText("\(key)", in: ctx, size: 90)
        }
    }
    for strip in Strip.allCases {
        try await device.drawStrip(strip) { ctx in
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
            ctx.fill(CGRect(x: 4, y: 4, width: 52, height: 262))
            drawText(strip == .left ? "L" : "R", in: ctx, size: CGSize(width: 60, height: 270))
        }
    }
    try await device.refresh()
    log(String(format: "Drew 12 keys + 2 strips in %.0f ms", Date().timeIntervalSince(start) * 1000))
    for button in 0..<device.model.roundButtons {
        let c = color(hue: CGFloat(button) / 8)
        try await device.setButtonColor(button, red: UInt8(c.components![0] * 255),
                                        green: UInt8(c.components![1] * 255), blue: UInt8(c.components![2] * 255))
    }
    try await device.vibrate(.short)
}

/// Time each command type and report whether the device acknowledges it.
func bench(_ device: LoupedeckDevice) async throws {
    func time(_ label: String, _ command: Command, _ data: [UInt8]) async {
        let t = Date()
        do {
            let r = try await device.request(command, data, timeout: 3)
            log(String(format: "%-28@ ack in %4.0f ms  (%d bytes back)", label as NSString, Date().timeIntervalSince(t) * 1000, r.count))
        } catch {
            log(String(format: "%-28@ NO ACK after %4.0f ms", label as NSString, Date().timeIntervalSince(t) * 1000))
        }
    }
    let key = device.model.rect(forKey: 0)
    var fb: [UInt8] = [0x00, UInt8(ascii: "M")]
    for v in [key.x, key.y, key.width, key.height] { fb += [UInt8(v >> 8), UInt8(v & 0xff)] }
    fb += RGB565.solid(red: 255, green: 0, blue: 0, pixelCount: key.width * key.height)
    await time("setBrightness", .setBrightness, [10])
    await time("setColor button 0", .setColor, [0x07, 255, 255, 255])
    await time("framebuffer 90x90 key", .framebuffer, fb)
    await time("draw (refresh)", .draw, [0x00, UInt8(ascii: "M")])
    var full: [UInt8] = [0x00, UInt8(ascii: "M"), 0, 0, 0, 0, 0x01, 0xe0, 0x01, 0x0e]
    full += RGB565.solid(red: 0, green: 0, blue: 80, pixelCount: 480 * 270)
    await time("framebuffer full 480x270", .framebuffer, full)
    await time("draw (refresh)", .draw, [0x00, UInt8(ascii: "M")])
}

func color(hue: CGFloat) -> CGColor {
    // Simple HSV(h, 0.8, 0.9) → RGB
    let h = hue * 6, i = floor(h), f = h - i
    let v: CGFloat = 0.9, p = v * 0.2, q = v * (1 - 0.8 * f), t = v * (1 - 0.8 * (1 - f))
    let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(i) % 6 {
    case 0: (v, t, p)
    case 1: (q, v, p)
    case 2: (p, v, t)
    case 3: (p, q, v)
    case 4: (t, p, v)
    default: (v, p, q)
    }
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

func drawText(_ s: String, in ctx: CGContext, size: CGFloat) {
    drawText(s, in: ctx, size: CGSize(width: size, height: size))
}

func drawText(_ s: String, in ctx: CGContext, size: CGSize) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
    let attr = NSAttributedString(string: s, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: (size.width - bounds.width) / 2 - bounds.minX,
                               y: (size.height - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, ctx)
}
