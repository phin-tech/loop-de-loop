import Foundation
import LoupedeckKit

/// Something a control does. Strings in actions may contain placeholders that are
/// filled in at run time: {delta} (knob turn), {control}, {page}, {profile}.
public enum Action: Codable, Hashable, Sendable {
    case keystroke(KeyStroke)
    case typeText(String)
    case openApp(path: String)
    case openURL(String)
    case shell(command: String)
    case appleScript(source: String)
    /// Runs a Shortcuts.app shortcut by name, with optional text input.
    case shortcut(name: String, input: String? = nil)
    /// BetterTouchTool named trigger ("Other" tab). `variable` sets BTT string variable
    /// `loopdeloop_value` first, so the trigger can read e.g. the knob delta.
    case bttNamedTrigger(name: String, value: String? = nil)
    /// Keyboard Maestro macro by name or UID; `parameter` arrives as %TriggerValue%.
    case keyboardMaestro(macro: String, parameter: String? = nil)
    /// Alfred workflow External Trigger.
    case alfredTrigger(trigger: String, workflow: String, argument: String? = nil)
    case media(MediaKey)
    case page(PageTarget)
    case profile(name: String)
    case brightness(BrightnessChange)
    case vibrate(Haptic)
    case delay(seconds: Double)

    public var summary: String {
        switch self {
        case .keystroke(let k): "Keystroke \(k)"
        case .typeText(let t): "Type “\(t)”"
        case .openApp(let p): "Open \(URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent)"
        case .openURL(let u): "Open \(u)"
        case .shell(let c): "Shell: \(c)"
        case .appleScript: "AppleScript"
        case .shortcut(let n, _): "Shortcut “\(n)”"
        case .bttNamedTrigger(let n, _): "BTT “\(n)”"
        case .keyboardMaestro(let m, _): "KM “\(m)”"
        case .alfredTrigger(let t, let w, _): "Alfred \(w) → \(t)"
        case .media(let m): m.label
        case .page(let p): "Page: \(p)"
        case .profile(let n): "Profile: \(n)"
        case .brightness(let b): "Brightness \(b)"
        case .vibrate(let h): "Vibrate \(h)"
        case .delay(let s): "Wait \(s)s"
        }
    }
}

extension Haptic: Codable {}

public enum MediaKey: String, Codable, CaseIterable, Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    /// NX_KEYTYPE_* values for system-defined media key events.
    var nxKeyType: Int32 {
        switch self {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .mute: 7
        case .playPause: 16
        case .next: 17
        case .previous: 18
        }
    }

    public var label: String {
        switch self {
        case .playPause: "Play/Pause"
        case .next: "Next track"
        case .previous: "Previous track"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        case .brightnessUp: "Display brightness up"
        case .brightnessDown: "Display brightness down"
        }
    }
}

public enum PageTarget: Codable, Hashable, Sendable, CustomStringConvertible {
    case next, previous
    case index(Int)
    case named(String)

    public var description: String {
        switch self {
        case .next: "next"
        case .previous: "previous"
        case .index(let i): "#\(i + 1)"
        case .named(let n): n
        }
    }

    /// "next", "prev", "2" (1-based), or a page name.
    public init(argument s: String) {
        switch s.lowercased() {
        case "next": self = .next
        case "prev", "previous": self = .previous
        default:
            if let n = Int(s), n >= 1 { self = .index(n - 1) } else { self = .named(s) }
        }
    }
}

public enum BrightnessChange: Codable, Hashable, Sendable, CustomStringConvertible {
    case set(Double)
    case adjust(Double)

    public var description: String {
        switch self {
        case .set(let v): "= \(Int(v * 100))%"
        case .adjust(let d): d >= 0 ? "+\(Int(d * 100))%" : "\(Int(d * 100))%"
        }
    }
}

/// A key plus modifiers, written like "cmd+shift+4" or "ctrl+opt+left".
public struct KeyStroke: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case control, option, shift, command, function
        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            case .function: "fn"
            }
        }
    }

    public var key: String
    public var modifiers: [Modifier]

    public init(key: String, modifiers: [Modifier] = []) {
        self.key = key.lowercased()
        self.modifiers = Modifier.allCases.filter(modifiers.contains)
    }

    /// Parse "cmd+shift+4".
    public init?(parsing s: String) {
        var mods: [Modifier] = []
        var key: String?
        for raw in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch raw {
            case "cmd", "command", "⌘": mods.append(.command)
            case "shift", "⇧": mods.append(.shift)
            case "opt", "option", "alt", "⌥": mods.append(.option)
            case "ctrl", "control", "⌃": mods.append(.control)
            case "fn", "function": mods.append(.function)
            case "": continue
            default: key = raw
            }
        }
        guard let key, KeyCodes.code(for: key) != nil else { return nil }
        self.init(key: key, modifiers: mods)
    }

    public var keyCode: UInt16? { KeyCodes.code(for: key) }

    public var description: String {
        modifiers.map(\.symbol).joined() + (key.count == 1 ? key.uppercased() : key)
    }
}

/// US-layout virtual key codes (Carbon kVK_*).
public enum KeyCodes {
    static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
            "v": 0x09, "b": 0x0b, "q": 0x0c, "w": 0x0d, "e": 0x0e, "r": 0x0f, "y": 0x10, "t": 0x11, "1": 0x12,
            "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1a, "-": 0x1b,
            "8": 0x1c, "0": 0x1d, "]": 0x1e, "o": 0x1f, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
            "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2a, ",": 0x2b, "/": 0x2c, "n": 0x2d, "m": 0x2e,
            ".": 0x2f, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74,
            "pagedown": 0x79, "left": 0x7b, "right": 0x7c, "down": 0x7d, "up": 0x7e,
        ]
        let fkeys: [UInt16] = [0x7a, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6d, 0x67, 0x6f,
                               0x69, 0x6b, 0x71, 0x6a, 0x40, 0x4f, 0x50, 0x5a]
        for (i, code) in fkeys.enumerated() { t["f\(i + 1)"] = code }
        return t
    }()

    public static func code(for key: String) -> UInt16? { table[key.lowercased()] }
    public static var names: [String] { table.keys.sorted() }
}
