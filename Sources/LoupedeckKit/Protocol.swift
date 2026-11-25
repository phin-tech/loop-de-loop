// Wire-level constants for the Loupedeck serial protocol (firmware 0.2.x).
// Ported from foxxyz/loupedeck (MIT): constants.js, device.js.

/// Command bytes. Outgoing and incoming messages share this space.
public enum Command: UInt8, Sendable {
    case buttonPress = 0x00
    case knobRotate = 0x01
    case setColor = 0x02
    case serial = 0x03
    case reset = 0x06
    case version = 0x07
    case setBrightness = 0x09
    case mcu = 0x0d
    case draw = 0x0f
    case framebuffer = 0x10
    case setVibration = 0x1b
    case touch = 0x4d
    case touchCT = 0x52
    case touchEnd = 0x6d
    case touchEndCT = 0x72
}

/// One of the six rotary encoders on a Loupedeck Live (they also click).
public enum Knob: String, CaseIterable, Codable, Hashable, Sendable {
    case topLeft, centerLeft, bottomLeft, topRight, centerRight, bottomRight

    init?(wireID: UInt8) {
        switch wireID {
        case 0x01: self = .topLeft
        case 0x02: self = .centerLeft
        case 0x03: self = .bottomLeft
        case 0x04: self = .topRight
        case 0x05: self = .centerRight
        case 0x06: self = .bottomRight
        default: return nil
        }
    }

    var wireID: UInt8 {
        switch self {
        case .topLeft: 0x01
        case .centerLeft: 0x02
        case .bottomLeft: 0x03
        case .topRight: 0x04
        case .centerRight: 0x05
        case .bottomRight: 0x06
        }
    }
}

/// A physical control that can be pressed: a knob click or one of the round buttons.
public enum Control: Hashable, Codable, Sendable {
    case knob(Knob)
    /// Round buttons along the bottom, 0...7, left to right. These have RGB LEDs.
    case button(Int)

    init?(wireID: UInt8) {
        if let knob = Knob(wireID: wireID) {
            self = .knob(knob)
        } else if (0x07...0x0e).contains(wireID) {
            self = .button(Int(wireID - 0x07))
        } else if (0x1b...0x29).contains(wireID) {
            // Razer Stream Controller X keys
            self = .button(Int(wireID - 0x1b))
        } else {
            return nil
        }
    }

    var wireID: UInt8? {
        switch self {
        case .knob(let knob): knob.wireID
        case .button(let n): (0...7).contains(n) ? UInt8(0x07 + n) : nil
        }
    }
}

/// Built-in vibration patterns.
public enum Haptic: UInt8, CaseIterable, Sendable {
    case short = 0x01
    case medium = 0x0a
    case long = 0x0f
    case low = 0x31
    case shortLow = 0x32
    case shortLower = 0x33
    case lower = 0x40
    case lowest = 0x41
    case descendSlow = 0x46
    case descendMed = 0x47
    case descendFast = 0x48
    case ascendSlow = 0x52
    case ascendMed = 0x53
    case ascendFast = 0x58
    case revSlowest = 0x5e
    case revSlow = 0x5f
    case revMed = 0x60
    case revFast = 0x61
    case revFaster = 0x62
    case revFastest = 0x63
    case riseFall = 0x6a
    case buzz = 0x70
    case rumble5 = 0x77
    case rumble4 = 0x78
    case rumble3 = 0x79
    case rumble2 = 0x7a
    case rumble1 = 0x7b
}

public let maxBrightness: UInt8 = 10
