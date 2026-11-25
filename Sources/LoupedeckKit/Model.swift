/// Screen layout for a device family. All Live-style devices expose a single
/// framebuffer ("M") that spans the left strip, the key grid and the right strip.
public struct LoupedeckModel: Hashable, Sendable {
    public let name: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let columns: Int
    public let rows: Int
    public let keySize: Int
    /// X offset of the key grid within the framebuffer.
    public let gridX: Int
    /// Width of the side strips (0 if the device has none).
    public let stripWidth: Int
    public let roundButtons: Int
    public let knobs: [Knob]
    public let hasButtonLEDs: Bool
    public let hasHaptics: Bool

    public var keyCount: Int { columns * rows }

    static let displayID: [UInt8] = [0x00, UInt8(ascii: "M")]

    public static let live = LoupedeckModel(
        name: "Loupedeck Live", screenWidth: 480, screenHeight: 270, columns: 4, rows: 3,
        keySize: 90, gridX: 60, stripWidth: 60, roundButtons: 8,
        knobs: [.topLeft, .centerLeft, .bottomLeft, .topRight, .centerRight, .bottomRight],
        hasButtonLEDs: true, hasHaptics: true
    )

    public static let liveS = LoupedeckModel(
        name: "Loupedeck Live S", screenWidth: 480, screenHeight: 270, columns: 5, rows: 3,
        keySize: 90, gridX: 15, stripWidth: 0, roundButtons: 4,
        knobs: [.topLeft, .centerLeft],
        hasButtonLEDs: true, hasHaptics: true
    )

    public static let razerStreamController = LoupedeckModel(
        name: "Razer Stream Controller", screenWidth: 480, screenHeight: 270, columns: 4, rows: 3,
        keySize: 90, gridX: 60, stripWidth: 60, roundButtons: 8,
        knobs: [.topLeft, .centerLeft, .bottomLeft, .topRight, .centerRight, .bottomRight],
        hasButtonLEDs: true, hasHaptics: true
    )

    public static func forUSB(vendorID: Int, productID: Int) -> LoupedeckModel? {
        switch (vendorID, productID) {
        case (0x2ec2, 0x0004): .live
        case (0x2ec2, 0x0006): .liveS
        case (0x1532, 0x0d06): .razerStreamController
        default: nil
        }
    }

    /// Framebuffer rectangle for a key index.
    public func rect(forKey index: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        (gridX + (index % columns) * keySize, (index / columns) * keySize, keySize, keySize)
    }

    public func rect(for strip: Strip) -> (x: Int, y: Int, width: Int, height: Int) {
        switch strip {
        case .left: (0, 0, stripWidth, screenHeight)
        case .right: (screenWidth - stripWidth, 0, stripWidth, screenHeight)
        }
    }

    func target(x: Int, y: Int) -> TouchTarget {
        if stripWidth > 0 {
            if x < stripWidth { return .strip(.left) }
            if x >= screenWidth - stripWidth { return .strip(.right) }
        }
        let gridWidth = columns * keySize
        guard x >= gridX, x < gridX + gridWidth else { return .none }
        let column = (x - gridX) / keySize
        let row = min(y / keySize, rows - 1)
        return .key(row * columns + column)
    }
}

public enum Strip: String, CaseIterable, Codable, Hashable, Sendable {
    case left, right
}

public enum TouchTarget: Hashable, Sendable {
    case key(Int)
    case strip(Strip)
    case none
}

public struct Touch: Hashable, Sendable {
    public let id: UInt8
    public let x: Int
    public let y: Int
    public let target: TouchTarget
}

public enum LoupedeckEvent: Sendable {
    case pressed(Control)
    case released(Control)
    case rotated(Knob, delta: Int)
    case touchBegan(Touch)
    case touchMoved(Touch)
    case touchEnded(Touch)
    case disconnected
}
