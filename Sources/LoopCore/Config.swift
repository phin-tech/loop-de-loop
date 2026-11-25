import Foundation
import LoupedeckKit

/// sRGB color stored as a hex string ("#RRGGBB") in JSON.
public struct RGB: Codable, Hashable, Sendable {
    public var red: UInt8, green: UInt8, blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGB(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad color \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(255, 255, 255)
}

/// How a touch key looks. Every field is optional so the same type works for
/// saved appearance and for partial runtime overrides from the CLI/URL scheme.
public struct Appearance: Codable, Hashable, Sendable {
    public var title: String?
    public var titleColor: RGB?
    public var fontSize: Double?
    public var background: RGB?
    /// File name inside the app's images folder (images are copied there on import).
    public var image: String?
    /// SF Symbol name.
    public var symbol: String?
    public var symbolColor: RGB?

    public init(title: String? = nil, titleColor: RGB? = nil, fontSize: Double? = nil, background: RGB? = nil,
                image: String? = nil, symbol: String? = nil, symbolColor: RGB? = nil) {
        self.title = title
        self.titleColor = titleColor
        self.fontSize = fontSize
        self.background = background
        self.image = image
        self.symbol = symbol
        self.symbolColor = symbolColor
    }

    /// Fields set in `overlay` win.
    public func merged(with overlay: Appearance?) -> Appearance {
        guard let o = overlay else { return self }
        return Appearance(
            title: o.title ?? title, titleColor: o.titleColor ?? titleColor, fontSize: o.fontSize ?? fontSize,
            background: o.background ?? background, image: o.image ?? image, symbol: o.symbol ?? symbol,
            symbolColor: o.symbolColor ?? symbolColor
        )
    }

    public var isEmpty: Bool { self == Appearance() }
}

/// Actions bound to a pressable control. Hold fires after `holdDelay` if set;
/// when hold actions exist, press actions wait for release so the two don't both fire.
public struct Bindings: Codable, Hashable, Sendable {
    public var press: [Action] = []
    public var release: [Action] = []
    public var hold: [Action] = []

    public init(press: [Action] = [], release: [Action] = [], hold: [Action] = []) {
        self.press = press
        self.release = release
        self.hold = hold
    }

    public var isEmpty: Bool { press.isEmpty && release.isEmpty && hold.isEmpty }
}

public struct KeyConfig: Codable, Hashable, Sendable {
    public var appearance = Appearance()
    public var actions = Bindings()
    public init(appearance: Appearance = Appearance(), actions: Bindings = Bindings()) {
        self.appearance = appearance
        self.actions = actions
    }
}

public struct ButtonConfig: Codable, Hashable, Sendable {
    public var color: RGB?
    public var actions = Bindings()
    public init(color: RGB? = nil, actions: Bindings = Bindings()) {
        self.color = color
        self.actions = actions
    }
}

public struct KnobConfig: Codable, Hashable, Sendable {
    /// Shown on the side strip next to the knob.
    public var label: String?
    public var left: [Action] = []
    public var right: [Action] = []
    public var actions = Bindings()
    public init(label: String? = nil, left: [Action] = [], right: [Action] = [], actions: Bindings = Bindings()) {
        self.label = label
        self.left = left
        self.right = right
        self.actions = actions
    }
}

extension Knob: CodingKeyRepresentable {}

public struct Page: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// Touch keys by index (0-11 on a Live). Missing entries are blank.
    public var keys: [String: KeyConfig] = [:]
    /// Round buttons by index (0-7).
    public var buttons: [String: ButtonConfig] = [:]
    public var knobs: [Knob: KnobConfig] = [:]

    public init(name: String) { self.name = name }

    public func key(_ i: Int) -> KeyConfig { keys[String(i)] ?? KeyConfig() }
    public func button(_ i: Int) -> ButtonConfig { buttons[String(i)] ?? ButtonConfig() }
    public func knob(_ k: Knob) -> KnobConfig { knobs[k] ?? KnobConfig() }
    public mutating func setKey(_ i: Int, _ c: KeyConfig) { keys[String(i)] = c }
    public mutating func setButton(_ i: Int, _ c: ButtonConfig) { buttons[String(i)] = c }
}

public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var pages: [Page]
    /// Switch to this profile automatically when one of these apps is frontmost.
    public var appBundleIDs: [String] = []

    public init(name: String, pages: [Page], appBundleIDs: [String] = []) {
        self.name = name
        self.pages = pages
        self.appBundleIDs = appBundleIDs
    }
}

public struct Settings: Codable, Hashable, Sendable {
    public var brightness: Double = 1
    /// Seconds before a held control fires its hold actions.
    public var holdDelay: Double = 0.5
    public var hapticOnPress: Bool = false
    /// Switch profiles to match the frontmost app.
    public var autoSwitchProfiles: Bool = true
    /// Optional BTT shared secret (BTT → Advanced → Scripting).
    public var bttSharedSecret: String?
    public init() {}
}

public struct Config: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public var version = Config.currentVersion
    public var settings = Settings()
    public var profiles: [Profile]
    public var defaultProfileID: UUID

    public init(profiles: [Profile]) {
        precondition(!profiles.isEmpty)
        self.profiles = profiles
        self.defaultProfileID = profiles[0].id
    }

    public func profile(id: UUID) -> Profile? { profiles.first { $0.id == id } }

    public func profile(named name: String) -> Profile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A starter layout so a fresh install does something visible.
    public static func starter() -> Config {
        var home = Page(name: "Home")
        home.setKey(0, KeyConfig(appearance: Appearance(title: "Finder", symbol: "folder", symbolColor: RGB(90, 170, 255)),
                                 actions: Bindings(press: [.openApp(path: "/System/Library/CoreServices/Finder.app")])))
        home.setKey(1, KeyConfig(appearance: Appearance(title: "Play", symbol: "playpause.fill"),
                                 actions: Bindings(press: [.media(.playPause)])))
        home.setKey(2, KeyConfig(appearance: Appearance(title: "Screenshot", symbol: "camera.viewfinder"),
                                 actions: Bindings(press: [.keystroke(KeyStroke(key: "4", modifiers: [.command, .shift]))])))
        home.setKey(11, KeyConfig(appearance: Appearance(title: "Next page", background: RGB(40, 40, 40), symbol: "arrow.right.circle"),
                                  actions: Bindings(press: [.page(.next)])))
        home.knobs[.topLeft] = KnobConfig(label: "Volume", left: [.media(.volumeDown)], right: [.media(.volumeUp)],
                                          actions: Bindings(press: [.media(.mute)]))
        home.knobs[.topRight] = KnobConfig(label: "Bright", left: [.brightness(.adjust(-0.1))], right: [.brightness(.adjust(0.1))])
        home.setButton(0, ButtonConfig(color: RGB(255, 255, 255), actions: Bindings(press: [.page(.index(0))])))
        home.setButton(1, ButtonConfig(color: RGB(0, 120, 255), actions: Bindings(press: [.page(.index(1))])))

        var second = Page(name: "Page 2")
        second.setKey(11, KeyConfig(appearance: Appearance(title: "Back", background: RGB(40, 40, 40), symbol: "arrow.left.circle"),
                                    actions: Bindings(press: [.page(.previous)])))
        second.setButton(0, ButtonConfig(color: RGB(255, 255, 255), actions: Bindings(press: [.page(.index(0))])))
        second.setButton(1, ButtonConfig(color: RGB(0, 120, 255), actions: Bindings(press: [.page(.index(1))])))
        return Config(profiles: [Profile(name: "Default", pages: [home, second])])
    }
}
